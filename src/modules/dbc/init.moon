--- The DBC table editor.
--
-- The tool that opens a client's DBC files, shows one as a grid, edits it and
-- writes it back. It registers itself with the shell - a category, a rail, a
-- strip, a panel and a work area - and the shell knows nothing about tables.
--
-- Three files underneath: `library` finds and opens them, `editor` holds one
-- open table with the stack that can take back what was done to it, and
-- `changes` says what the session amounts to and writes the Lua that
-- reproduces it. This file is the wiring.
--
-- One session per table, kept when the user looks at another one. Closing a
-- tab hides a table, it does not discard the edits: the tab bar is where you
-- are, not what is loaded, and a click that silently threw away an afternoon
-- would be the worst button in the application.
---@module modules.dbc

Neutrino = require "neutrino"

changes = require "modules.dbc.changes"
editor = require "modules.dbc.editor"
library = require "modules.dbc.library"
view = require "modules.dbc.view"

menus = require "shell.menus"
page = require "shell.page"
sections = require "shell.settings"
tools = require "shell.tools"
workspace = require "workspace"

fs = Neutrino.fs
json = Neutrino.json

M = {}

-- One per table the user has opened, by name.
sessions = {}

-- The one on screen, or nil.
active = nil

--- The tab a table occupies.
---@param name string
---@return string
---@private
tab_id = (name) -> "dbc:#{name}"

-- ═══════════════════════════════════════════════════════════════════════════
-- Behaviour
-- ═══════════════════════════════════════════════════════════════════════════

--- Wires the channels the page invokes.
---@param window BrowserWindow
---@param state State
M.mount = (window, state) ->
  -- Where the grid is looking, in rows and columns from the top left. Held
  -- here as well as in the store because the page asks for a window it has
  -- already decided on, and answering the same question twice is a redraw.
  at_row, at_col = 0, 0

  say = (message) -> state\set "dbc_message", message or ""

  --- Moves the grid's scrollbars, which belong to the page.
  --
  -- Lua decides which block is drawn and the page decides where it is looking,
  -- so anything that moves the view from here has to move both or the grid
  -- shows one part of the table while the bar says another.
  scroll_to = (top) ->
    window\exec_js "
      const scroller = document.querySelector('.dbc-scroller')
      if (scroller) { scroller.scrollTop = #{top}; scroller.scrollLeft = 0 }"

  --- Pushes the block the grid is showing.
  push_window = ->
    unless active
      state\set "dbc_grid", {
        row: 0, col: 0, total_rows: 0, total_cols: 0
        columns: json.array {}, rows: json.array {}
      }
      return

    state\set "dbc_grid", editor.window active, at_row, at_col,
      view.METRICS.rows, view.METRICS.columns

  --- Pushes everything about the open table that is not the grid itself.
  push_info = ->
    state\set "dbc_open", active and active.name or ""

    state\set "dbc_info", {
      rows: active and active.table\Count! or 0
      columns: active and #active.columns or 0
      has_id: active and active.has_id or false
      locale: active and active.locale or ""
      format: active and active.format or ""
      changes: active and changes.count(active.set) or 0
    }

    -- The shell's own keys: the menu entries and their shortcuts are guarded
    -- on these, and the status bar reads the first.
    state\set "dirty", active and editor.is_dirty(active) or false
    state\set "can_undo", active and editor.can_undo(active) or false
    state\set "can_redo", active and editor.can_redo(active) or false

    -- Regenerated only while it is on screen. It is the whole script every
    -- time, and nobody is reading it with the panel shut.
    if active and state\get "dbc_preview_open"
      state\set "dbc_preview", editor.script active

  --- Everything the page knows about the table, after something changed it.
  refresh = ->
    push_info!
    push_window!

  --- Reads the workspace's folder again.
  reload_tables = ->
    entries, err = library.tables!
    state\set "dbc_tables", entries

    -- Having no workspace is where everyone starts rather than something that
    -- went wrong, and the home page already says what to do about it. Anything
    -- else - a folder that is not there, one that cannot be read - is worth
    -- the strip.
    say (workspace.current! != nil) and err or nil

  --- Shows a table, opening it if this is the first time.
  open_table = (name) ->
    return unless type(name) == "string" and name != ""

    session = sessions[name]
    unless session
      tbl, err = library.open name
      unless tbl
        say err
        return

      build = workspace.setting "build"
      locale = workspace.setting "locale"
      ok, made = pcall editor.session, tbl, name, locale, build
      unless ok
        say "#{name} could not be read: #{tostring made}"
        return

      session = made
      sessions[name] = session

    active = session
    at_row, at_col = 0, 0
    say nil

    -- One tab per table, reused. Opening the same one again brings it
    -- forward rather than putting a second copy beside the first.
    id = tab_id name
    tabs = state\get("tabs") or {}
    known = false
    known = true for tab in *tabs when tab.id == id

    unless known
      table.insert tabs, { :id, title: name, tool: "dbc" }
      state\set "tabs", json.array tabs

    state\set "active_tab", id
    state\set "tool", "dbc"
    state\set "dbc_row", 0
    refresh!

    -- Back to the top. The block being drawn is this table's first, and a
    -- scrollbar left where the last table was would disagree with it.
    scroll_to 0

  --- The column the page named, or nil.
  column_at = (index) ->
    return nil unless active and type(index) == "number"
    active.columns[index]

  window\handle "dbc:tables", ->
    reload_tables!
    nil

  window\handle "dbc:open", (name) ->
    open_table name
    nil

  window\handle "dbc:window", (payload) ->
    return nil unless active and type(payload) == "table"

    row = math.max 0, math.floor tonumber(payload.row) or 0
    col = math.max 0, math.floor tonumber(payload.col) or 0
    return nil if row == at_row and col == at_col

    at_row, at_col = row, col
    push_window!
    nil

  window\handle "dbc:set", (payload) ->
    return nil unless active and type(payload) == "table"

    column = column_at payload.column
    return nil unless column

    ok, err = editor.set_cell active, payload.row, column, tostring payload.value
    if ok then say nil else say "#{column.label}: #{err}"
    refresh!
    nil

  window\handle "dbc:add", ->
    return nil unless active

    index, err = editor.add_row active
    unless index
      say err
      return nil

    say nil
    state\set "dbc_row", index
    refresh!
    nil

  window\handle "dbc:duplicate", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click a cell in the one to copy."
      return nil

    made, err = editor.duplicate_row active, index
    unless made
      say err
      return nil

    say nil
    state\set "dbc_row", made
    refresh!
    nil

  -- Asking first, because a deletion is the one thing here that cannot be seen
  -- to be wrong afterwards: the row is simply gone from the grid.
  window\handle "dbc:delete", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click a cell in the one to delete."
      return nil

    id = editor.id_at active, index
    named = active.has_id and " (ID #{tostring id})" or ""
    state\set "dbc_confirm",
      "Row #{index}#{named} of #{active.name} will be removed. This can be
      undone, and nothing is written to disk until you save."
    nil

  window\handle "dbc:delete-row", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    return nil unless index > 0

    ok, err = editor.delete_row active, index
    if ok then say nil else say err

    -- The row that took its place is the sensible thing to be on, unless the
    -- one deleted was the last.
    state\set "dbc_row", math.min index, active.table\Count!
    refresh!
    nil

  window\handle "dbc:find", (text) ->
    return nil unless active and active.has_id

    id = tonumber text
    unless id
      say "Type the ID of the row to go to."
      return nil

    -- Through the table's own ID index, which is a lookup rather than a scan:
    -- a table of forty thousand rows is ordinary and a search that walked it
    -- would be felt.
    ok, row = pcall active.table.FindById, active.table, id
    found = (ok and row) and row\GetIndex! or nil

    unless found
      say "#{active.name} has no row with ID #{id}."
      return nil

    say nil
    state\set "dbc_row", found

    -- Put it a few rows below the top, where it is easier to see than pinned
    -- against the header.
    at_row = math.max 0, found - 4
    refresh!

    -- The scroller is the page's, so the page is what has to be moved.
    scroll_to at_row * view.METRICS.row
    nil

  window\handle "dbc:preview", ->
    state\set "dbc_preview", active and editor.script(active) or ""
    nil

  undo = ->
    return "Nothing is open" unless active
    ok, err = editor.undo active
    refresh!
    ok and "Undone" or err

  redo = ->
    return "Nothing is open" unless active
    ok, err = editor.redo active
    refresh!
    ok and "Redone" or err

  save = ->
    return "Nothing is open" unless active

    folder = workspace.output_dir!
    return "There is nowhere to write: open a workspace first." unless folder

    path = fs.join folder, "#{active.name}.dbc"
    written, err = editor.save active, path
    refresh!

    unless written
      say err
      return "#{active.name} could not be saved: #{err}"

    say nil
    "#{active.name} written to #{path} (#{written} bytes)"

  window\handle "dbc:undo", ->
    state\set "status", undo!
    nil

  window\handle "dbc:redo", ->
    state\set "status", redo!
    nil

  window\handle "dbc:save", ->
    state\set "status", save!
    nil

  -- What File > Save and Edit > Undo reach when this tool is the active one.
  M.tool.commands = {
    :undo
    :redo
    :save
    "save-all": save
  }

  -- The tab bar is the page's; clicking one changes the store and nothing
  -- else. This is how the tool hears that a different table is in front.
  state\on "active_tab", (value) ->
    return unless type(value) == "string"

    name = value\match "^dbc:(.+)$"
    return unless name
    return if active and active.name == name

    open_table name

  -- The tables belong to the folder that was open. A different workspace is a
  -- different set of files, and the sessions describing the old ones would be
  -- describing rows nobody can see.
  workspace.on_change ->
    sessions = {}
    active = nil
    at_row, at_col = 0, 0

    state\set "dbc_preview", ""

    open_tabs = state\get("tabs") or {}
    kept = [tab for tab in *open_tabs when tab.tool != "dbc"]
    state\set "tabs", json.array kept

    showing = state\get("active_tab") or ""
    state\set "active_tab", "" if showing\match "^dbc:"

    reload_tables!
    refresh!

  reload_tables!
  refresh!

-- ═══════════════════════════════════════════════════════════════════════════
-- Registration
-- ═══════════════════════════════════════════════════════════════════════════

icon = page.icon

M.tool = tools.register {
  id: "dbc"
  label: "Tables"
  icon: "table"
  description: "Open the client's DBC tables and edit them row by row."

  actions: {
    {
      id: "list"
      icon: "table"
      title: "Tables"
      action: "side_open = !side_open"
    }
    {
      id: "add"
      icon: "plus"
      title: "New row"
      action: "neutrino.invoke('dbc:add')"

      -- Not on the 22 tables that keep no ID in their records: a new row there
      -- would be a row nothing can name. Duplicating one works everywhere,
      -- because that copies bytes rather than inventing a key.
      shown: "dbc_open !== '' && dbc_info.has_id"
    }
    {
      id: "duplicate"
      icon: "copy"
      title: "Duplicate row"
      action: "neutrino.invoke('dbc:duplicate')"
    }
    {
      id: "delete"
      icon: "trash"
      title: "Delete row"
      action: "neutrino.invoke('dbc:delete')"
    }
    {
      id: "undo"
      icon: "undo"
      title: "Undo"
      action: "neutrino.invoke('dbc:undo')"
    }
    {
      id: "redo"
      icon: "redo"
      title: "Redo"
      action: "neutrino.invoke('dbc:redo')"
    }
    {
      id: "save"
      icon: "save"
      title: "Save as DBC"
      action: "neutrino.invoke('dbc:save')"
    }
  }

  context: view.context icon
  panel: view.panel icon
  view: view.grid icon

  state: -> {
    -- Read here rather than pushed from `mount`: the store is inlined into
    -- the document, so anything the module knows before the page loads has to
    -- be in this table or the first paint is of an empty list.
    dbc_tables: library.tables!

    dbc_filter: ""
    dbc_open: ""
    dbc_row: 0
    dbc_find: ""
    dbc_message: ""
    dbc_confirm: ""
    dbc_preview: ""
    dbc_preview_open: false

    dbc_info: {
      rows: 0, columns: 0, has_id: false, format: "", changes: 0
      locale: workspace.setting "locale"
    }

    dbc_grid: {
      row: 0, col: 0, total_rows: 0, total_cols: 0
      columns: json.array {}, rows: json.array {}
    }
  }

  mount: M.mount
}

menus.extend "tools", {
  { label: "Refresh table list", action: "neutrino.invoke('dbc:tables')" }
}

sections.register {
  id: "dbc"
  label: "Tables"
  icon: "table"
  description: "Where the client's DBC files are, and where edited ones go.
    The output folder is the workspace's."

  fields: {
    {
      type: "folder"
      path: "settings.dbc.source"
      label: "DBC folder"
      placeholder: "DBFilesClient, inside the workspace"
      help: "Left empty, this is DBFilesClient inside the workspace, then
        Data\\DBFilesClient, then the workspace folder itself."
    }
  }

  values: -> { source: library.setting "source" }

  apply: (values) ->
    ok, err = library.set "source", type(values.source) == "string" and values.source or ""
    return nil, err unless ok

    -- The folder moving means a different set of files; what is open belongs
    -- to the folder it came from.
    library.close!
    sessions = {}
    active = nil
    true
}

M
