--- The channels the page invokes, and the two the shell changes under it.
--
-- One `window\handle` per thing the interface can ask for. They are thin on
-- purpose: read the payload, call into `session` or `editor`, tell the page
-- what changed. Anything longer than that belongs in one of those.
--
-- Nothing here holds state. What is open lives in `session`, which is a module
-- rather than a closure precisely so that this file and the tool's own
-- registration can both see it.
---@module modules.dbc.handlers

changes = require "modules.dbc.changes"
editor = require "modules.dbc.editor"
library = require "modules.dbc.library"
relations = require "modules.dbc.relations"
session = require "modules.dbc.session"
workspace = require "workspace"

-- Read directly for the graph, which is drawn around a table whether or not
-- one is open: a schema is a question about the definitions, and opening a
-- session to ask it would open a table nobody asked for.
dbc = require "dbc"

json = (require "neutrino").json

M = {}

--- Registers every channel on the window.
---@param ctx table The module context: `window` and `state`.
M.install = (ctx) ->
  { :window, :state } = ctx

  -- Bound once rather than reached through the module at each call site: the
  -- bodies below read as they did when they were one file, and the only thing
  -- that has to be looked up every time is which table is in front.
  { :say, :reload, :refresh, :push_info, :push_columns, :reload_tables,
    :open_table, :column_at, :pin_active, :row_payload, :undo, :redo,
    :save } = session

  -- Re-reads the folder, and the settings with it: asking for the list again
  -- is what somebody does after changing where the files are or how the list
  -- behaves, and a list that came back with the old behaviour would look like
  -- the setting had not taken.
  window\handle "dbc:tables", ->
    reload_tables!
    push_info!
    nil

  -- A name, or a name and whether it keeps its own tab. The bare form is what
  -- the menus and the tests use, and it keeps.
  window\handle "dbc:open", (payload) ->
    if type(payload) == "table"
      open_table payload.name, (payload.pinned and true or false)
    else
      open_table payload, true
    nil

  --- One page of rows, as Tabulator asks for them.
  --
  -- Where the sort is applied too. The library sends the field and the
  -- direction; Lua sorts the whole table, which Tabulator cannot - it holds
  -- only what has been scrolled past. The field is a column index rather than
  -- a label, because two localised columns of one field differ only by slot.
  window\handle "dbc:page", (payload) ->
    empty = { data: json.array({}), last_page: 1 }
    return empty unless session.active and type(payload) == "table"

    sorters = type(payload.sorters) == "table" and payload.sorters or {}
    first = sorters[1]

    column, descending = nil, false
    if first and type(first.field) == "string"
      column = tonumber first.field\match "^c(%d+)$"
      descending = first.dir == "desc"

    held = session.active.sort
    same = if column == nil
      held == nil
    else
      held != nil and held.column == column and held.descending == descending

    unless same
      editor.sort_by session.active, column, descending
      push_info!

    editor.page session.active, payload.page, payload.size

  window\handle "dbc:set", (payload) ->
    return nil unless session.active and type(payload) == "table"

    column = column_at payload.column
    return nil unless column

    index = tonumber(payload.row) or 0
    ok, err = editor.set_cell session.active, index, column, tostring payload.value
    if ok then say nil else say "#{column.label}: #{err}"

    -- Editing is the other way a table stops being something you glanced at.
    pin_active!

    -- The changed-rows view is a filter over the change set, so a write can
    -- put a row into it or take one out. Everywhere else one cell moved, and
    -- the row handed back below is enough to show it.
    refresh session.active.changed_only
    { row: row_payload index }

  --- Writes a block of cells as one step.
  --
  -- What a paste is. Every cell goes through `editor.set_cell` and nothing
  -- else does, each one pcalled, so a cell the column will not take keeps its
  -- text and its reason while the rest go in - and the whole block is one
  -- thing to take back.
  window\handle "dbc:paste", (payload) ->
    return nil unless session.active and type(payload) == "table"

    cells = type(payload.cells) == "table" and payload.cells or {}
    written, refused = editor.paste session.active, cells

    if #refused > 0
      say "#{#refused} of #{written + #refused} cells were refused:
        #{refused[1].message}"
    else
      say nil

    pin_active!
    refresh session.active.changed_only

    -- Every row the paste touched, so the grid shows what Lua holds rather
    -- than what was on the clipboard.
    touched, rows = {}, {}
    for cell in *cells
      index = tonumber cell.row
      continue unless index and not touched[index]
      touched[index] = true
      row = row_payload index
      table.insert rows, row if row

    { :written, refused: #refused, rows: json.array rows }

  --- Which columns the grid shows, and in what order.
  window\handle "dbc:columns", (payload) ->
    return nil unless session.active and type(payload) == "table"

    if payload.every != nil
      hidden = {}
      unless payload.every
        hidden[index] = true for index = 1, #session.active.columns
      editor.set_layout session.active, nil, hidden

    elseif payload.column
      index = tonumber payload.column
      if index
        hidden = { key, value for key, value in pairs session.active.hidden }
        hidden[index] = (not payload.shown) or nil
        editor.set_layout session.active, nil, hidden

    elseif type(payload.order) == "table"
      editor.set_layout session.active, payload.order, nil

    -- The columns are what the grid is built from, so this rebuilds it, and
    -- the rows come with it: a hidden column is one nothing reads, and the
    -- pages already fetched were read without it.
    push_info!
    push_columns!
    reload!
    nil

  --- Pages over the changed rows alone, or over all of them again.
  window\handle "dbc:changed-only", ->
    return nil unless session.active

    editor.set_changed_only session.active, not session.active.changed_only
    refresh true
    nil

  --- Back to the first row, after a jump left the grid partway down.
  window\handle "dbc:top", ->
    return nil unless session.active

    editor.set_from session.active, 0
    refresh true
    nil

  window\handle "dbc:add", ->
    return nil unless session.active

    index, err = editor.add_row session.active
    unless index
      say err
      return nil

    say nil
    state\set "dbc_row", index
    refresh true
    nil

  window\handle "dbc:duplicate", ->
    return nil unless session.active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click the number of the row to copy."
      return nil

    made, err = editor.duplicate_row session.active, index
    unless made
      say err
      return nil

    say nil
    state\set "dbc_row", made
    refresh true
    nil

  -- Asking first, because a deletion is the one thing here that cannot be seen
  -- to be wrong afterwards: the row is simply gone from the grid.
  window\handle "dbc:delete", ->
    return nil unless session.active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click the number of the row to delete."
      return nil

    id = editor.id_at session.active, index
    named = session.active.has_id and " (ID #{tostring id})" or ""
    state\set "dbc_confirm",
      "Row #{index}#{named} of #{session.active.name} will be removed. This can be
      undone, and nothing is written to disk until you save."
    nil

  window\handle "dbc:delete-row", ->
    return nil unless session.active

    index = tonumber(state\get "dbc_row") or 0
    return nil unless index > 0

    ok, err = editor.delete_row session.active, index
    if ok then say nil else say err

    -- The row that took its place is the sensible thing to be on, unless the
    -- one deleted was the last.
    state\set "dbc_row", math.min index, session.active.table\Count!
    refresh true
    nil

  --- Searches the open table.
  --
  -- A query that will not parse leaves the grid as it was and says why. The
  -- alternative - emptying the grid on every keystroke that is not yet a
  -- whole query - would make the box unusable to type into.
  window\handle "dbc:query", (text) ->
    return nil unless session.active

    ok, err = editor.set_query session.active, text
    state\set "dbc_query_error", ok and "" or tostring err

    -- Back to the first page: the rows under the bar are a different set now,
    -- and an anchor left by a jump points into the set they replaced.
    editor.set_from session.active, 0
    refresh true
    nil

  --- Sets one column's width.
  --
  -- The grid is not told. The drag it came from is what moved the column, and
  -- pushing the width back would answer a question nobody asked.
  window\handle "dbc:resize", (payload) ->
    return nil unless session.active and type(payload) == "table"

    editor.set_width session.active, (tonumber payload.column), (tonumber(payload.width) or 0)
    nil

  --- Reopens the table reading and writing at another language.
  --
  -- The columns change with it, so the session is rebuilt - but only after the
  -- change set has been checked: rebuilding one with edits in it would leave
  -- them recorded against slots nothing shows.
  window\handle "dbc:use-locale", (slot) ->
    return nil unless session.active and type(slot) == "string" and slot != ""

    state\set "dbc_locale_hint", ""

    if changes.count(session.active.set) > 0
      say "#{session.active.name} has unsaved changes. Save or undo them before
        changing language."
      return nil

    name = session.active.name
    session.all[name] = nil
    session.active = nil
    workspace.set "locale", slot
    open_table name
    nil

  --- Shows referenced rows by name instead of by number, or stops.
  --
  -- One state for the whole tool rather than one per table: it is how somebody
  -- reads a client, and having to switch it on again for every table opened
  -- would make it something nobody switches on.
  window\handle "dbc:readable", ->
    wanted = not library.setting "readable"
    library.set "readable", wanted

    session.readable = wanted for _, session in pairs session.all
    state\set "dbc_readable", wanted

    -- Resolving reads the referenced tables, and the first draw after turning
    -- it on is when that happens. Said rather than left as a pause.
    say wanted and "Reading the referenced tables..." or nil

    -- Every cell reads differently now, so the pages already fetched are
    -- showing numbers where they should be showing names.
    refresh true
    say nil
    nil

  --- The rows a foreign key could point at, narrowed by what has been typed.
  window\handle "dbc:resolve", (payload) ->
    return nil unless session.active and type(payload) == "table"

    column = column_at payload.column
    unless column and column.foreign
      state\set "dbc_choices", json.array {}
      return nil

    ok, found = pcall relations.search, column.foreign, session.active.locale,
      tostring(payload.needle or ""), 60

    unless ok
      say "#{column.foreign} could not be read: #{tostring found}"
      state\set "dbc_choices", json.array {}
      return nil

    state\set "dbc_choices", json.array found
    nil

  --- The graph of what refers to what.
  --
  -- With a table open it is that table and its immediate neighbours, which is
  -- the question somebody looking at a column has. With none it is every
  -- linked table in the client, which is the map you want before you know what
  -- you are looking for.
  window\handle "dbc:relations", (name) ->
    build = workspace.setting "build"
    say "Reading the definitions..."

    -- Which table the picture is drawn around. Re-rooting it on a neighbour
    -- does not open that table: looking at the shape and working in it are
    -- different things to want, and one should not drag the other along.
    --
    -- "*" asks for the whole client. It has to be askable: the table in front
    -- stays in front after its tab is closed, so "nothing is open" is a state
    -- almost nobody gets back to once they have started.
    focus = if name == "*"
      ""
    else
      type(name) == "string" and name != "" and name or
        (session.active and session.active.name or "")

    nodes, edges = {}, {}

    if focus != ""
      -- Whether a neighbour is one this client ships. A definition can name a
      -- table nobody has, and an edge to nothing is a lie in a picture.
      known = {}
      known[entry.name] = entry.editable for entry in *library.tables!

      got, schema = pcall dbc.Schemas.Get, focus, build
      if got and schema
        seen = { [focus]: true }
        table.insert nodes, { name: focus, focus: true }

        for link in *relations.outbound schema
          continue unless known[link.table]
          unless seen[link.table]
            seen[link.table] = true
            table.insert nodes, { name: link.table }
          table.insert edges, { from: focus, to: link.table, column: link.column }

        ok, inn = pcall relations.inbound, focus, build
        if ok
          for link in *inn
            unless seen[link.table]
              seen[link.table] = true
              table.insert nodes, { name: link.table }
            table.insert edges, { from: link.table, to: focus, column: link.column }
    else
      ok, all_nodes, all_edges = pcall relations.graph, build
      nodes, edges = (ok and all_nodes or {}), (ok and all_edges or {})

    state\set "dbc_graph", {
      :focus
      nodes: json.array nodes
      edges: json.array edges
    }
    state\set "dbc_graph_open", true
    say nil
    nil

  window\handle "dbc:find", (text) ->
    return nil unless session.active and session.active.has_id

    id = tonumber text
    unless id
      say "Type the ID of the row to go to."
      return nil

    -- Through the table's own ID index, which is a lookup rather than a scan:
    -- a table of forty thousand rows is ordinary and a search that walked it
    -- would be felt.
    ok, row = pcall session.active.table.FindById, session.active.table, id
    found = (ok and row) and row\GetIndex! or nil

    unless found
      say "#{session.active.name} has no row with ID #{id}."
      return nil

    say nil
    state\set "dbc_row", found

    -- The grid is fed forwards, so a row deep in a large table is reached by
    -- starting there rather than by scrolling to it: pulling the 39,999 rows
    -- above it through the window first is the thing this design exists to
    -- avoid. A few rows above it, so it is not pinned under the header, and
    -- the strip says where the view begins with the way back beside it.
    position = editor.position_of session.active, found
    editor.set_from session.active, math.max 0, (position or found) - 4
    refresh true
    nil

  window\handle "dbc:preview", ->
    state\set "dbc_preview", session.active and editor.script(session.active) or ""
    nil

  window\handle "dbc:undo", ->
    state\set "status", undo!
    nil

  window\handle "dbc:redo", ->
    state\set "status", redo!
    nil

  window\handle "dbc:save", ->
    state\set "status", save!
    nil

  -- The tab bar is the page's; clicking one changes the store and nothing
  -- else. This is how the tool hears that a different table is in front.
  state\on "active_tab", (value) ->
    return unless type(value) == "string"

    name = value\match "^dbc:(.+)$"
    return unless name
    return if session.active and session.active.name == name

    open_table name

  -- The tables belong to the folder that was open. A different workspace is a
  -- different set of files, and the session.all describing the old ones would be
  -- describing rows nobody can see. The names a foreign key resolves to came
  -- out of those files too, so they go with them.
  workspace.on_change ->
    relations.reset!
    session.all = {}
    session.active = nil

    state\set "dbc_preview", ""

    open_tabs = state\get("tabs") or {}
    kept = [tab for tab in *open_tabs when tab.tool != "dbc"]
    state\set "tabs", json.array kept

    showing = state\get("active_tab") or ""
    state\set "active_tab", "" if showing\match "^dbc:"

    reload_tables!
    refresh true


M
