--- The settings page.
--
-- A page, not a modal. It takes the work area as a tab, so it stays open while
-- the user changes something else and comes back — which is what settings are
-- actually used for. A modal would force the sequence "stop, decide, dismiss"
-- onto a task whose whole shape is "try it, look, adjust".
--
-- Sections register themselves, exactly as tools and menus do:
--
--     settings.register {
--       id: "dbc"
--       label: "Database"
--       icon: "database"
--       fields: {
--         { type: "folder", path: "settings.dbc.definitions", label: "Definitions" }
--       }
--       values: -> { definitions: ... }       -- what the store starts from
--       apply: (values) -> ok, err            -- what Save does
--     }
--
-- "Workspace" below is built the same way and gets no help from the shell, so
-- the general case and the module case are one mechanism rather than two.
--
-- **Saving is explicit.** A Save button per section, not a write per keystroke
-- and not a write on blur. Every field here is a path or a build number — half
-- of one is meaningless, and saving on blur would write that half to disk and
-- then report a failure while the user was still tabbing. One button is one
-- moment where the write either worked or did not, and one place to say so.
---@module shell.settings

Neutrino = require "neutrino"
resources = require "resources"
workspace = require "workspace"

async = Neutrino.async
json = Neutrino.json
log = Neutrino.log

M = {}

--- Every registered section, in nav order.
---@type table[]
M.list = {}

--- Adds a section. A second registration of the same id replaces the first, the
--- way `tools.register` does, so reloading a module does not double its entry.
---@param section table id, label, icon?, fields, values?, apply?
---@return table The section.
M.register = (section) ->
  error "a settings section needs an id" unless section.id
  error "a settings section needs a label" unless section.label

  section.fields or= {}

  for field in *section.fields
    error "a settings field needs a path" unless field.path
    error "a settings field needs a type" unless field.type

  for index, existing in ipairs M.list
    if existing.id == section.id
      M.list[index] = section
      return section

  table.insert M.list, section
  section

--- Finds a section by id.
---@param id string
---@return table|nil
M.find = (id) ->
  for section in *M.list
    return section if section.id == id
  nil

--- The id the page opens on: the first registered section.
---@return string
M.first = -> #M.list > 0 and M.list[1].id or ""

--- The store keys the page reads.
--
-- Folded into `window.initial_state`, because the runtime only answers for keys
-- it was given and a section's values are no exception: a field bound to a path
-- that was never declared binds to nothing at all.
---@return table
M.state = ->
  values = {}
  for section in *M.list
    values[section.id] = section.values and section.values! or {}

  {
    settings: values
    settings_section: M.first!
    settings_dirty: false
    settings_error: ""
    settings_status: ""
  }

-- ═══════════════════════════════════════════════════════════════════════════
-- Markup
-- ═══════════════════════════════════════════════════════════════════════════

--- The whole page.
--
-- `icon` arrives as an argument rather than through a require: `shell.page`
-- already requires this module in order to place the page, and requiring it
-- back would be a cycle that resolves to a half-built table.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.render = (icon) ->
  template = resources.template "shell/views/settings.etlua"
  template { sections: M.list, :icon }

-- ═══════════════════════════════════════════════════════════════════════════
-- Behaviour
-- ═══════════════════════════════════════════════════════════════════════════

--- The tab the page occupies. One of them, reused.
---@type string
M.TAB = "settings"

--- Wires the channels the page invokes.
---@param window BrowserWindow
---@param state State
M.mount = (window, state) ->
  -- Puts the section's saved values back into the store. What went to disk may
  -- not be what was typed - a path gets normalised, a value gets rejected - and
  -- showing the typed version after a save would be showing a lie.
  refresh = (section) ->
    return unless section.values
    state\set "settings.#{section.id}", section.values!

  -- True while this page is the one changing the model.
  --
  -- A model change announces itself whether or not it reached the disk, and a
  -- save that got halfway announces the half that landed in memory. Letting the
  -- listener below run then would overwrite the fields with what it managed to
  -- apply and clear "unsaved changes" - telling the user their edits were saved
  -- at the exact moment they were not. The two branches of the save handler say
  -- what should happen instead, each for its own case.
  applying = false

  window\handle "shell:settings", ->
    tabs = state\get("tabs") or {}

    -- One settings tab, reused. Opening it twice should bring it forward, not
    -- put a second copy of the same page beside the first.
    already = false
    for tab in *tabs
      already = true if tab.id == M.TAB

    unless already
      table.insert tabs, { id: M.TAB, title: "Settings", tool: "workspace" }
      state\set "tabs", json.array tabs

    state\set "active_tab", M.TAB
    state\set "settings_error", ""
    state\set "settings_status", ""
    nil

  window\handle "shell:settings-browse", (path) ->
    return nil unless type(path) == "string"

    async.run ->
      current = state\get path
      chosen = window\show_folder_dialog {
        title: "Choose a folder"
        default_path: type(current) == "string" and current or ""
      }
      return unless chosen and chosen[1]

      state\set path, chosen[1]
      state\set "settings_dirty", true
      state\set "settings_status", ""
    nil

  window\handle "shell:settings-save", (id) ->
    section = M.find id
    unless section
      log.warn "settings: no section '%s'", tostring id
      return nil

    unless section.apply
      state\set "settings_dirty", false
      return nil

    values = state\get("settings.#{section.id}") or {}

    applying = true
    -- A section's `apply` is a module's own code. It raising is that module's
    -- bug, and showing it on the page beats taking the window down over it.
    called, result, failure = pcall section.apply, values
    applying = false

    ok = called and result
    err = if called then failure else tostring result

    if ok
      state\set "settings_error", ""
      state\set "settings_status", "Saved"
      state\set "settings_dirty", false
      refresh section
    else
      -- Left dirty on purpose: nothing reached the disk, so the edits are still
      -- the only copy and the button has to stay live.
      state\set "settings_status", ""
      state\set "settings_error", err and tostring(err) or "could not be saved"
      log.warn "settings: %s could not be saved: %s", section.id, tostring err

    nil

  -- The page follows the model rather than the other way round, so a workspace
  -- opened from the File menu shows up here without the menu knowing the page
  -- exists.
  workspace.on_change ->
    return if applying

    refresh (M.find "workspace")
    state\set "settings_dirty", false

-- ═══════════════════════════════════════════════════════════════════════════
-- Built in
-- ═══════════════════════════════════════════════════════════════════════════

locale_options = [{ value: code, label: code } for code in *workspace.LOCALES]

M.register {
  id: "workspace"
  label: "Workspace"
  icon: "home"
  description: "A workspace is a folder of client files and the build they came
    from. Every tool reads from it."

  fields: {
    {
      type: "folder"
      path: "settings.workspace.path"
      label: "Client folder"
      placeholder: "No workspace open"
      help: "The folder holding Data\\ and the client executable."
    }
    {
      type: "text"
      path: "settings.workspace.build"
      label: "Client build"
      help: "3.3.5.12340 is retail 3.3.5a. A private server's client reports its
        own, and the tool follows the client."
    }
    {
      type: "choice"
      path: "settings.workspace.locale"
      label: "Locale"
      options: locale_options
      help: "Which folder under Data\\ holds the localised files."
    }
    {
      type: "folder"
      path: "settings.workspace.output"
      label: "Output folder"
      placeholder: "output, inside the workspace"
      help: "Where modified files are written. Left empty, it is output\\ inside
        the workspace, so nothing is written over the client by accident."
    }
    {
      type: "toggle"
      path: "settings.workspace.reopen"
      label: "Reopen this workspace at startup"
    }
    {
      type: "choice"
      path: "settings.workspace.autosave"
      label: "Save unsaved work"
      options: {
        { value: "300", label: "Every 5 minutes" }
        { value: "60", label: "Every minute" }
        { value: "180", label: "Every 3 minutes" }
        { value: "600", label: "Every 10 minutes" }
        { value: "0", label: "Shortly after each change" }
        { value: "-1", label: "Never" }
      }
      help: "Applies to every tool, not just the one in front of you. A tool
        that has nothing unsaved is not asked, so this costs nothing while you
        are reading. \"Shortly after each change\" waits a few seconds for
        you to stop: a DBC table is tens of megabytes and writing one per
        keystroke would make the grid unusable."
    }
    {
      type: "toggle"
      path: "settings.workspace.backup"
      label: "Keep the previous version of a file"
      help: "Before writing over a file, copy it beside itself as .bak. One per
        file, replaced each time - the version before this save, not a history,
        so the folder does not fill up. Applies to every tool. Off by default:
        a save already writes to a temporary file and renames it over the
        target, so an interrupted write cannot leave a broken table either way."
    }
  }

  values: ->
    {
      path: workspace.setting "path"
      build: workspace.setting "build"
      output: workspace.setting "output"
      locale: workspace.setting "locale"
      reopen: workspace.setting "reopen"
      backup: workspace.setting "backup"

      -- A choice hands back the string it was given; the model keeps seconds.
      autosave: tostring workspace.setting "autosave"
    }

  -- The path is applied through `open`, which is what checks the folder is
  -- there. The rest go straight through, and the first failure is the one
  -- reported: a half-applied section reported as a success is worse than one
  -- reported as a failure.
  apply: (values) ->
    typed = type(values.path) == "string" and values.path or ""
    current = workspace.current!
    open_now = current and current.path or ""

    if typed == ""
      ok, err = workspace.close!
      return nil, err unless ok
    elseif typed != open_now
      opened, err = workspace.open typed
      return nil, err unless opened

    workspace.set "autosave", (tonumber(values.autosave) or 300)

    for field in *{ "build", "output", "locale", "reopen", "backup" }
      value = values[field]
      continue if value == nil

      ok, err = workspace.set field, value
      return nil, err unless ok

    true
}

M
