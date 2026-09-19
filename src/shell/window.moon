--- The application window and the chrome it draws itself.
--
-- Frameless, because the title bar is also the menu bar and both belong to the
-- application rather than to Windows. Everything the system would have drawn -
-- dragging, minimise, maximise, close - is wired here to what the page asks
-- for, and the page asks through IPC like any other action.
---@module shell.window

Neutrino = require "neutrino"
menus = require "shell.menus"
page = require "shell.page"
settings = require "shell.settings"
tools = require "shell.tools"
workspace = require "workspace"

async = Neutrino.async
json = Neutrino.json
log = Neutrino.log
ui = Neutrino.ui

M = {}

--- The store the interface starts from.
--
-- Declared in one place and in full: the runtime only answers for keys it was
-- given, so a key that appears later is a key no expression can read.
---@return table
initial_state = ->
  open = workspace.current!

  state = {
    -- Chrome
    menu: ""                  -- the open menu, or ""
    maximized: false
    side_open: true
    status_open: true
    dialog: ""                -- the open dialog, or ""

    -- The active category. Its rail, its strip and its panel are the ones
    -- shown; everything else stays rendered and hidden.
    tool: tools.first!

    -- Workspace
    workspace: open and open.path or ""   -- the folder, shown in the title bar
    build: open and open.build or ""      -- the client build it was opened as
    recent: workspace.recent!             -- the File menu's list
    status: "Ready"

    -- The tools starred on the home page, most useful first. Kept in the
    -- workspace's own settings: which tools someone reaches for is a property
    -- of what they are working on.
    favourites: json.array (workspace.setting("favourites") or {})

    -- Work
    tabs: json.array {}
    active_tab: ""
    dirty: false
    can_undo: false
    can_redo: false

    -- Two glyphs the chrome swaps between. Markup rather than a class, because
    -- they are different shapes and not the same shape restyled.
    icon_maximize: page.icon "maximize"
    icon_restore: page.icon "restore"
  }

  -- The settings page's keys, from the sections that registered, and each
  -- tool's own. Merged here rather than declared here: the shell does not know
  -- what a module's settings are, and a key it had to be told about would be a
  -- key modules could not add.
  state[key] = value for key, value in pairs settings.state!
  state[key] = value for key, value in pairs tools.state!

  state

--- Serves the shell and opens the window.
---@param app App
---@param server Server
---@return table The window and its state, once the app is ready.
M.mount = (app, server) ->
  server.router\get "/", (req, res) ->
    res\html ui.document {
      title: "WowLabs"
      lang: "en"
      head: '<link rel="stylesheet" href="neutrino://app/assets/app.css">'
      state: initial_state!
      body: page.render!
    }

  app\on "ready", ->
    window = Neutrino.BrowserWindow {
      title: "WowLabs"
      url: "neutrino://app/"
      -- 1280x720 is both the size it opens at and the smallest it goes. A tool
      -- with this much chrome has a floor below which panes start fighting
      -- each other, and it is better to refuse than to degrade. Above it the
      -- layout is fluid, because this is usually run maximised on 1920x1080.
      width: 1280
      height: 720
      min_width: 1280
      min_height: 720
      frameless: true
      background: { 14, 14, 17 }

      -- Shown once the interface has rendered rather than on creation, so the
      -- first thing on screen is the application and not an empty frame.
      show: false
    }

    state = ui.State window, initial_state!
    M.window = window
    M.state = state

    -- ── Window chrome ─────────────────────────────────────────────────────

    sync_maximized = -> state\set "maximized", window\is_maximized!

    window\handle "shell:minimize", ->
      window\minimize!
      nil

    window\handle "shell:maximize", ->
      if window\is_maximized! then window\restore! else window\maximize!
      sync_maximized!
      nil

    window\handle "shell:close", ->
      window\close!
      nil

    window\handle "shell:devtools", ->
      window\toggle_devtools!
      nil

    -- Dragging a maximised window by its title bar restores it, and snapping
    -- it to an edge maximises it, neither of which goes through our buttons.
    window\on "bounds-changed", -> sync_maximized!

    -- ── Keyboard ──────────────────────────────────────────────────────────
    --
    -- Straight from the menu data, so a shortcut and the entry that shows it
    -- cannot disagree. A menu that prints "Ctrl+S" beside a command that does
    -- nothing when you press Ctrl+S is worse than one that prints nothing.

    for menu in *menus.bar
      for item in *menu.items
        continue unless item.accelerator and item.action

        -- Run through nui rather than as bare JavaScript: the action is
        -- written against the store, the same as the menu entry's, and this is
        -- what puts the store in scope. `enabled` guards it for the same
        -- reason the entry is greyed out.
        source = item.enabled and
          "if (#{item.enabled}) { #{item.action} }" or item.action
        script = "nui.run(#{json.encode source})"

        ok, err = window\register_accelerator item.accelerator, ->
          window\exec_js script
          true

        log.warn "shortcut %s: %s", item.accelerator, tostring err unless ok

    -- ── The workspace ─────────────────────────────────────────────────────
    --
    -- The chrome follows the model rather than being set alongside it. A title
    -- bar written at the same moment as the workspace opens is a title bar that
    -- is wrong the first time anything else opens one.

    workspace.on_change (open) ->
      state\set "workspace", open and open.path or ""
      state\set "build", open and open.build or ""
      state\set "recent", workspace.recent!
      state\set "status", open and "Workspace open" or "No workspace"

    -- Reports failure rather than raising, and says so on the status bar: a
    -- folder that has gone missing since it was last opened is ordinary.
    open_path = (path) ->
      opened, err = workspace.open path
      unless opened
        state\set "status", "Could not open: #{tostring err}"
        return false

      -- Opened, but the settings could not be written. The workspace is usable
      -- and the next launch will not remember it, which is worth saying.
      state\set "status", "Opened, but not saved: #{err}" if err
      true

    window\handle "shell:open-workspace", ->
      async.run ->
        paths = window\show_folder_dialog { title: "Open workspace" }
        return unless paths and paths[1]
        open_path paths[1]
      nil

    window\handle "shell:open-recent", (path) ->
      return nil unless type(path) == "string"
      open_path path
      nil

    window\handle "shell:close-workspace", ->
      ok, err = workspace.close!
      state\set "status", "Could not save: #{tostring err}" unless ok
      nil

    -- ── The work area ─────────────────────────────────────────────────────

    window\handle "shell:close-tab", (id) ->
      tabs = state\get("tabs") or {}
      kept = [tab for tab in *tabs when tab.id != id]
      state\set "tabs", json.array kept

      -- Falls back to whatever is left rather than to nothing, so closing one
      -- of several tabs does not drop you on the empty state. Of this tool's
      -- own tabs: the strip only shows those, and landing on another tool's
      -- would move the whole window somewhere nobody asked to go.
      if state\get("active_tab") == id
        current = state\get "tool"
        mine = [tab for tab in *kept when (tab.tool or "workspace") == current]
        state\set "active_tab", mine[#mine] and mine[#mine].id or ""
      nil

    --- Moves to a tool, and to whatever of its work was last on screen.
    --
    -- A tab belongs to the tool that opened it, so changing tool changes which
    -- tabs exist as far as the strip is concerned. Without this the active tab
    -- would stay pointing at a tab the strip no longer shows, and the work
    -- area would draw another tool's page under this tool's rail.
    window\handle "shell:tool", (id) ->
      return nil unless type(id) == "string" and tools.find id
      state\set "tool", id

      tabs = state\get("tabs") or {}
      mine = [tab for tab in *tabs when (tab.tool or "workspace") == id]
      state\set "active_tab", mine[#mine] and mine[#mine].id or ""
      nil

    --- Stars a tool, or unstars it.
    window\handle "shell:favourite", (id) ->
      return nil unless type(id) == "string" and tools.find id

      current = state\get("favourites") or {}
      kept = [name for name in *current when name != id]
      table.insert kept, id if #kept == #current

      state\set "favourites", json.array kept
      workspace.set "favourites", kept
      nil

    settings.mount window, state
    tools.mount window, state

    -- ── The menu's own commands ───────────────────────────────────────────
    --
    -- Save, undo and redo are one thing to the user and a different thing in
    -- every tool, so each is handed to whichever tool is active. A tool that
    -- has no answer says so rather than the menu quietly doing nothing: an
    -- entry that does nothing at all is worse than one that admits it.
    --
    -- A command returns the line for the status bar, or nil to leave it.

    for channel in *{ "shell:save", "shell:save-all", "shell:undo", "shell:redo" }
      do
        name = channel\match ":(.+)$"
        window\handle channel, ->
          active = tools.find state\get "tool"
          command = active and active.commands and active.commands[name]

          unless command
            state\set "status", "#{name}: nothing here does that yet"
            return nil

          -- A tool's command is a module's own code, and it raising is that
          -- module's bug. Showing it beats taking the window down over it.
          ok, said = pcall command
          unless ok
            log.warn "%s: %s", channel, tostring said
            state\set "status", "#{name} failed: #{tostring said}"
            return nil

          state\set "status", said if type(said) == "string"
          nil

    -- ── Ready ─────────────────────────────────────────────────────────────

    window\on "did-finish-load", (detail) ->
      return unless detail.url and detail.url\match "^neutrino://app/"

      -- Maximised on open. 1280x720 is the floor, not the working size: this
      -- is a tool with four bars of chrome, and at its minimum there is barely
      -- room for the thing you came to edit. Restoring gives that size back.
      window\show!
      window\maximize!
      sync_maximized!

      -- Only now: the store is inlined into the document, so before the page
      -- has loaded there is nothing for a listener to push to. The preference
      -- is honoured here rather than inside the model, because "reopen at
      -- startup" is a question about this window rather than about workspaces.
      if workspace.setting "reopen"
        workspace.restore!
      else
        state\set "status", "Ready"

      log.info "shell ready"

    window

M
