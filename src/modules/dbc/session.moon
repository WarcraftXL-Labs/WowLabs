--- The tables the editor has open, and what the page is told about them.
--
-- One session per table, kept when the user looks at another one: closing a
-- tab hides a table, it does not discard the edits. `all` is every table that
-- has been opened, by name, and `active` is the one in front.
--
-- Both are fields rather than locals because two callers need them and they
-- change while the tool runs: the channels in `handlers`, and the tool's own
-- registration in `init`, which reports what is unsaved on the way out.
--
-- Everything here that talks to the page needs the store, which does not exist
-- until the window does, so those are bound by `attach` rather than written
-- against a value captured at load.
---@module modules.dbc.session

Neutrino = require "neutrino"

changes = require "modules.dbc.changes"
editor = require "modules.dbc.editor"
library = require "modules.dbc.library"
workspace = require "workspace"

fs = Neutrino.fs
json = Neutrino.json

M = {
  -- One per table the user has opened, by name.
  all: {}

  -- The one on screen, or nil.
  active: nil
}

--- The tab a table occupies.
---@param name string
---@return string
M.tab_id = (name) -> "dbc:#{name}"
tab_id = M.tab_id

--- Binds everything that needs the window's store.
--
-- Called once, by the module's `mount`. What comes back is this module, so a
-- caller can hold one name and reach both the state and the operations on it.
---@param ctx table The module context: `window` and `state`.
---@return table
M.attach = (ctx) ->
  state = ctx.state

  say = (message) -> state\set "dbc_message", message or ""

  --- Tells the page to read the table again from the first page.
  --
  -- A counter rather than the data itself: what changed is which rows exist
  -- and in what order, and the grid asks for them a page at a time. Bumping
  -- this is the one way the data source is restarted, so there is one place to
  -- look when the grid is showing the wrong thing.
  reload = ->
    state\set "dbc_reload", (tonumber(state\get "dbc_reload") or 0) + 1

  --- Pushes the columns the grid draws, in the order and the visibility the
  --- user has left them.
  --
  -- The grid is rebuilt when this changes and only then: a column appearing,
  -- disappearing or moving is a different table as far as the library is
  -- concerned, and the rows are asked for again afterwards.
  push_columns = ->
    state\set "dbc_columns", M.active and editor.grid_columns(M.active) or json.array {}
    state\set "dbc_changed_only", M.active and M.active.changed_only or false

  --- Pushes everything about the open table that is not the rows themselves.
  push_info = ->
    state\set "dbc_open", M.active and M.active.name or ""

    state\set "dbc_info", {
      rows: M.active and M.active.table\Count! or 0

      -- What the search left. Equal to `rows` when nothing is filtered, which
      -- is how the strip knows to say "2307 rows" rather than "2307 of 2307".
      shown: M.active and editor.visible(M.active) or 0

      columns: M.active and #M.active.columns or 0
      has_id: M.active and M.active.has_id or false
      locale: M.active and M.active.locale or ""
      spread: M.active and M.active.spread or false
      format: M.active and M.active.format or ""
      changes: M.active and changes.count(M.active.set) or 0

      -- Where paging begins. Non-zero only after a jump to a row, and said on
      -- the strip because everything above it is off the top until it is put
      -- back to zero.
      from: M.active and M.active.from or 0
    }

    -- Read on every refresh rather than once: the setting can change while
    -- the tool is open, and the list would keep the old behaviour otherwise.
    state\set "dbc_open_on", library.setting "open_on"
    state\set "dbc_resolver", library.setting "resolver"
    state\set "dbc_readable", library.setting("readable") and true or false

    -- The shell's own keys: the menu entries and their shortcuts are guarded
    -- on these, and the status bar reads the first.
    state\set "dirty", M.active and editor.is_dirty(M.active) or false
    state\set "can_undo", M.active and editor.can_undo(M.active) or false
    state\set "can_redo", M.active and editor.can_redo(M.active) or false

    -- Regenerated only while it is on screen. It is the whole script every
    -- time, and nobody is reading it with the panel shut.
    if M.active and state\get "dbc_preview_open"
      state\set "dbc_preview", editor.script M.active

  --- Everything the page knows about the table, after something changed it.
  --
  -- `rows` says the order or the contents have moved on, which is what makes
  -- the grid read again. Left out after an edit that only changed one cell:
  -- the answer to `dbc:set` carries that row, and rereading the table to show
  -- one new value would throw away everything that had been scrolled past.
  refresh = (rows) ->
    push_info!
    push_columns!
    reload! if rows

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
  ---@param name string
  ---@param pinned boolean Whether it keeps a tab of its own.
  open_table = (name, pinned) ->
    return unless type(name) == "string" and name != ""

    session = M.all[name]
    unless session
      tbl, err = library.open name
      unless tbl
        say err
        return

      build = workspace.setting "build"
      locale = workspace.setting "locale"
      mode = library.setting "locales"
      ok, made = pcall editor.session, tbl, name, locale, build, mode
      unless ok
        say "#{name} could not be read: #{tostring made}"
        return

      session = made
      session.readable = library.setting "readable"
      M.all[name] = session

    M.active = session
    M.active.from = 0
    say nil

    -- A file written in one language, opened at another, is the quiet way to
    -- end up with a row holding two names: a read answers the slot that has
    -- something in it and a write goes to the one the workspace named. Said
    -- once, here, and only when the file disagrees with the setting.
    state\set "dbc_locale_hint", ""
    state\set "dbc_locale_offer", ""

    -- What the file carries, not what the grid is showing: with one column
    -- per language the question does not arise, and with one column at the
    -- workspace's locale the shown list is empty by definition.
    if library.setting("locale_hint") and not session.spread
      present = session.present or {}
      carries_ours = false
      carries_ours = true for slot in *present when slot == session.locale

      if #present > 0 and not carries_ours
        state\set "dbc_locale_offer", present[1]
        state\set "dbc_locale_hint",
          "#{name} has no text at #{session.locale}. It is written in
          #{table.concat present, ", "}."

    -- One tab per table, reused. Opening the same one again brings it forward
    -- rather than putting a second copy beside the first.
    --
    -- An unpinned tab is the one being read rather than worked in: there is at
    -- most one, and the next table read replaces it. Pinning is a double click
    -- or the first edit - the two moments where the table stops being
    -- something you glanced at.
    id = tab_id name
    tabs = state\get("tabs") or {}

    kept = [tab for tab in *tabs when tab.id == id or not tab.preview]
    known = nil
    known = tab for tab in *kept when tab.id == id

    if known
      known.preview = nil if pinned
    else
      table.insert kept, {
        :id, title: name, tool: "dbc"
        preview: (not pinned) or nil
      }

    state\set "tabs", json.array kept
    state\set "active_tab", id
    state\set "tool", "dbc"
    state\set "dbc_row", 0

    -- The columns are this table's, so the grid is rebuilt rather than told to
    -- read again - and a new grid starts at the first page, which is also how
    -- the scrollbar ends up back at the top.
    refresh true

  --- The column the page named, or nil.
  column_at = (index) ->
    return nil unless M.active and type(index) == "number"
    M.active.columns[index]

  --- Gives the open table a tab of its own, if it was only being read.
  --
  -- Called after the first thing that is not reading. A table being edited in
  -- a tab the next click would replace is a table whose edits look lost.
  pin_active = ->
    return unless M.active

    id = tab_id M.active.name
    tabs = state\get("tabs") or {}
    changed = false

    for tab in *tabs
      continue unless tab.id == id and tab.preview
      tab.preview = nil
      changed = true

    state\set "tabs", json.array tabs if changed

  --- One row, in the shape the grid holds it.
  --
  -- Handed back from a write so the grid can show what Lua actually holds
  -- without asking for the table again. Rereading it to show one new value
  -- would throw away every page that had been scrolled past.
  ---@param index integer
  ---@return table|nil
  row_payload = (index) -> M.active and editor.row_at M.active, index

  -- A step back can be a row coming or going as easily as a cell changing, so
  -- the rows are asked for again rather than guessed at.
  undo = ->
    return "Nothing is open" unless M.active
    ok, err = editor.undo M.active
    refresh true
    ok and "Undone" or err

  redo = ->
    return "Nothing is open" unless M.active
    ok, err = editor.redo M.active
    refresh true
    ok and "Redone" or err

  --- Writes one session, whether or not it is the one on screen.
  --
  -- Takes the session rather than reading `M.active`, because saving everything
  -- has to reach tables the user is not looking at - which is most of them
  -- when the timer fires.
  ---@param session table
  ---@return boolean ok, string line
  ---@private
  save_session = (session) ->
    folder = workspace.output_dir!
    return false, "There is nowhere to write: open a workspace first." unless folder

    -- The table, or the script that reproduces it. The same edits either way;
    -- what differs is whether the result is a file a client can read or one a
    -- person can review.
    if library.setting("save_as") == "lua"
      path = fs.join folder, "#{session.name}.lua"
      ok, err = fs.write path, editor.script session
      return false, "#{session.name} could not be saved: #{tostring err}" unless ok
      return true, "#{session.name} written to #{path} as Lua"

    path = fs.join folder, "#{session.name}.dbc"
    written, err = editor.save session, path
    return false, "#{session.name} could not be saved: #{tostring err}" unless written
    true, "#{session.name} written to #{path} (#{written} bytes)"

  save = ->
    return "Nothing is open" unless M.active

    ok, line = save_session M.active
    say ok and nil or line
    refresh false
    line

  --- Writes every table holding changes.
  --
  -- What the shell calls on the way out and on the timer. The first failure
  -- stops it: the rest are probably the same failure, and a status line
  -- naming five tables that could not be written for one reason is five times
  -- the words and none of the information.
  save_all = ->
    written = {}

    for name, session in pairs M.all
      continue unless editor.is_dirty session

      ok, line = save_session session
      error line unless ok
      table.insert written, name

    refresh false
    return "Nothing to save" if #written == 0
    "Saved #{table.concat written, ", "}"

  -- What `handlers` and the tool's registration call them by. Assigned rather
  -- than declared above, because each one closes over the store that `attach`
  -- was given.
  M.say = say
  M.reload = reload
  M.refresh = refresh
  M.push_info = push_info
  M.push_columns = push_columns
  M.reload_tables = reload_tables
  M.open_table = open_table
  M.column_at = column_at
  M.pin_active = pin_active
  M.row_payload = row_payload
  M.undo = undo
  M.redo = redo
  M.save = save
  M.save_all = save_all

  M

M
