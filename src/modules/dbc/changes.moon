--- What the editor has changed, and the Lua that reproduces it.
--
-- Two things in one place because they are one contract: the set describes the
-- net effect of an editing session, and `script` is the only thing that turns
-- it into text. The preview panel and the file export call the same function,
-- because two functions that both claim to describe the same edits will
-- eventually disagree about them.
--
--     set = changes.new { table: "Spell", rows: 49866, has_id: true }
--     changes.cell set, { key: "p:12", id: 133, index: 12 },
--       column, "Fireball", "Firebolt"
--     source = changes.script set
--
-- **The net result, not the history.** A cell edited five times is one write;
-- a row added and then edited is one creation carrying the final values; a row
-- added and then deleted is nothing at all; a cell put back to the value it
-- started with is nothing. The undo stack is the history and is deliberately
-- not consulted here - a panel that showed the history would be a keystroke
-- log, and what it is for is showing what the file will become.
--
-- **Rows are identified by where they were in the file that was opened.** The
-- grid works in indices and a deletion moves every index after it, so an index
-- taken now means nothing to a script replayed later. The key is therefore the
-- row's index in the pristine file, which nothing can move, and the editor
-- keeps the mapping (see editor.moon). What gets *emitted* is an ID wherever
-- the table has one, because that is stable for a reader as well as for the
-- machine.
--
-- **The emitted order is what makes indices survive.** Creations first - they
-- append, so they move nothing - then edits, then deletions last and in
-- descending index order. Every index the script names is therefore still the
-- index it was in the file the script was pointed at.
---@module modules.dbc.changes

M = {}

--- A new, empty change set.
---@param options table table, rows, build, has_id, id_field, ordinal_note
---@return table
M.new = (options = {}) ->
  {
    table: options.table or "Table"
    build: options.build or "3.3.5.12340"

    -- How many records the file had when it was opened. A created row lands
    -- at `rows + n` when the script replays, which is how one creation can
    -- name another as the row it duplicates.
    rows: options.rows or 0

    has_id: options.has_id and true or false

    entries: {}
    by_key: {}
  }

--- The entry for a row, created on first touch.
--
-- `row` is how the editor names one: `key` is the identity nothing can move,
-- `id` and `index` are what the script will use to find it again. Both are
-- recorded as they were the first time the row was touched, because that is
-- what the file the script replays onto still has.
---@param set table
---@param row table key, id, index
---@return table
---@private
entry_for = (set, row) ->
  found = set.by_key[row.key]
  return found if found

  found = {
    key: row.key, id: row.id, index: row.index
    kind: "edit", fields: {}, order: {}
  }
  set.by_key[row.key] = found
  table.insert set.entries, found
  found

--- Forgets an entry entirely.
---@private
drop = (set, entry) ->
  set.by_key[entry.key] = nil
  for index, held in ipairs set.entries
    if held == entry
      table.remove set.entries, index
      return

--- Which cell a write names, within a row.
-- The field alone is not enough: an inline array is one field and several
-- cells, and a localised column is one field and one slot per locale.
---@param column table field, extra
---@return string
---@private
cell_key = (column) -> "#{column.field}/#{tostring column.extra}"

--- Records a cell write, coalescing it with whatever that cell already held.
--
-- `original` is the value the cell had before this session touched it; a write
-- back to it removes the cell from the set rather than recording a write that
-- changes nothing. It is only consulted for rows that existed in the file: a
-- created row has no original, and every one of its values has to be written.
---@param set table
---@param row table key, id, index
---@param column table field, kind, extra, label
---@param value any
---@param original any
M.cell = (set, row, column, value, original) ->
  entry = entry_for set, row
  slot = cell_key column

  if entry.kind != "add" and value == original
    entry.fields[slot] = nil
    for index, held in ipairs entry.order
      if held == slot
        table.remove entry.order, index
        break

    drop set, entry if #entry.order == 0
    return

  table.insert entry.order, slot unless entry.fields[slot]
  entry.fields[slot] = { :column, :value }

--- Records a row that did not exist before.
--
-- A duplicate names its source twice: `source` is where that row was in the
-- pristine file, and `source_key` is the row it was taken from whichever file
-- that was. One of them answers; which one depends on whether a copy was taken
-- of a copy, and that is resolved when the script is written.
--
-- The source's own pending edits are copied onto the new row. The editor
-- copied the bytes as they are *now*, and a script that duplicates first and
-- edits afterwards would otherwise take the copy from an unedited record.
---@param set table
---@param row table key, id, index
---@param how table kind ("create" or "duplicate"), source, source_key
M.added = (set, row, how) ->
  entry = entry_for set, row
  entry.kind = "add"
  entry.created = how.kind
  entry.source = how.source
  entry.source_key = how.source_key

  source = how.source_key and set.by_key[how.source_key]
  if source and source.kind != "delete"
    for slot in *source.order
      table.insert entry.order, slot
      entry.fields[slot] = source.fields[slot]

--- Records a deletion.
--
-- A row created in this session leaves no trace: creating it and removing it
-- again is not something the file should be told about.
---@param set table
---@param row table key, id, index
M.removed = (set, row) ->
  entry = entry_for set, row

  if entry.kind == "add"
    drop set, entry
    return

  entry.kind = "delete"
  entry.fields = {}
  entry.order = {}

--- How many rows the set has something to say about.
---@param set table
---@return integer
M.count = (set) -> #set.entries

--- Whether anything at all has changed.
---@param set table
---@return boolean
M.any = (set) -> #set.entries > 0

--- What this set says about one row: "edit", "add", "delete" or nil.
---@param set table
---@param key string
---@return string|nil
M.kind = (set, key) ->
  entry = set.by_key[key]
  entry and entry.kind or nil

--- What this set says about one cell, or nil.
-- What the grid marks a modified cell from.
---@param set table
---@param key string
---@param column table
---@return table|nil
M.field = (set, key, column) ->
  entry = set.by_key[key]
  return nil unless entry
  entry.fields[cell_key column]

--- A copy of what the set holds about one row.
--
-- The undo stack's hook. Every operation captures this before it changes
-- anything and hands it back when it is taken back, which is what keeps the
-- set describing the file rather than describing the keystrokes: working out
-- what an undo means for a coalesced set, case by case, would be a second
-- implementation of the coalescing rules with its own bugs.
---@param set table
---@param key string
---@return table|nil
M.capture = (set, key) ->
  entry = set.by_key[key]
  return nil unless entry

  copied = { name, value for name, value in pairs entry }
  copied.fields = { name, value for name, value in pairs entry.fields }
  copied.order = [slot for slot in *entry.order]
  copied

--- Puts back what `capture` took, or removes the row from the set when there
--- was nothing there to take.
---@param set table
---@param key string
---@param captured table|nil
M.reinstate = (set, key, captured) ->
  existing = set.by_key[key]

  unless captured
    drop set, existing if existing
    return

  unless existing
    set.by_key[key] = captured
    table.insert set.entries, captured
    return

  -- Kept in place rather than swapped in, so the entry holds its position in
  -- the emitted script: the order rows were first touched in is the order they
  -- are written, and an undo should not move one to the end.
  for name in pairs existing
    existing[name] = nil
  for name, value in pairs captured
    existing[name] = value

-- ═══════════════════════════════════════════════════════════════════════════
-- The generator
-- ═══════════════════════════════════════════════════════════════════════════

--- A Lua literal for a value about to be written to a column of this kind.
--
-- Text goes through `%q`, which is the only spelling that survives a DBC
-- string containing a quote, a backslash or a newline. An integer column emits
-- an integer: `3.0` is the same number to Lua and a different one to read.
---@param kind string Field kind from the schema.
---@param value any
---@return string
---@private
literal = (kind, value) ->
  return "nil" if value == nil

  switch kind
    when "str", "loc"
      string.format "%q", tostring value
    when "bool"
      value and "true" or "false"
    when "f32"
      -- Nine significant digits is what round-trips a 32-bit float through
      -- decimal, and no more than that: a shorter form reads back as a
      -- different number and a longer one is noise.
      number = tonumber(value) or 0
      number == math.floor(number) and string.format("%d", number) or
        string.format "%.9g", number
    else
      number = tonumber(value) or 0
      number == math.floor(number) and string.format("%d", number) or
        string.format "%.17g", number

--- The third argument to SetField, or "" when there is none.
-- Always present on a localised column. A two-argument write to one of those
-- goes to slot 0 whatever was being edited, which is how a frFR client ends up
-- with two different names in one row.
---@param column table
---@return string
---@private
extra_of = (column) ->
  return "" if column.extra == nil
  return ", " .. string.format "%q", column.extra if type(column.extra) == "string"
  ", " .. tostring column.extra

--- A name for the table's local, when the table name can be one.
---@param name string
---@return string
---@private
local_name = (name) ->
  name\match("^[%a_][%w_]*$") and name or "tbl"

--- How the script reaches a row that was in the file already.
---@param set table
---@param entry table
---@param handle string The table's local name.
---@return string
---@private
lookup = (set, entry, handle) ->
  return "#{handle}:GetRowById(#{entry.id})" if set.has_id and entry.id
  "#{handle}:GetRowByIndex(#{entry.index})"

--- The whole script.
--
-- One string, no timestamp and nothing else that changes between two runs over
-- the same edits: the point of a script rather than a dump is that it can be
-- read in a diff, and a file that differs from itself every time cannot be.
--
-- One limit worth knowing: on a table with an ID, a row is reached by that ID,
-- so a file with two rows sharing one is a file this cannot describe. Every
-- 3.3.5 table with an inline ID has unique ones.
---@param set table
---@return string lua
M.script = (set) ->
  handle = local_name set.table
  out = {}
  add = (line) -> table.insert out, line

  adds = [entry for entry in *set.entries when entry.kind == "add"]
  edits = [entry for entry in *set.entries when entry.kind == "edit"]
  deletes = [entry for entry in *set.entries when entry.kind == "delete"]

  -- Where each created row lands when the script replays. Every creation
  -- appends and the deletions are last, so the nth of them is at the nth index
  -- after the end of the file that was opened - which is what lets one
  -- creation name another as the row it copies.
  replay = {}
  for position, entry in ipairs adds
    replay[entry.key] = set.rows + position

  add "-- #{set.table}: #{M.count set} changed rows, from WowLabs."
  add "--"
  add "-- Replays them with lua-dbc. Point SOURCE at the folder holding"
  add "-- #{set.table}.dbc and run it:"
  add "--"
  add "--     luajit #{set.table\lower!}.lua"

  unless set.has_id
    add "--"
    add "-- #{set.table} keeps no ID in its records, so its rows are named by"
    add "-- position. Replay this against the file it was made from, once:"
    add "-- against anything else, or twice, it edits whatever is at those"
    add "-- positions now."

  add ""
  add "local SOURCE = \"DBFilesClient\""
  add "local OUT    = \"output\""
  add "local BUILD  = #{string.format "%q", set.build}"
  add ""
  add "local dbc = require(\"dbc\")"
  add ""
  add "local ws = dbc.Workspace{ source = SOURCE, out = OUT, build = BUILD }"
  add "local #{handle} = ws:GetTable(#{string.format "%q", set.table})"
  add ""

  -- The ID is not a column like the others: written through SetField the
  -- record changes and the table's index does not, and every lookup after it
  -- finds the wrong row.
  write_line = (target, field) ->
    if set.has_id and field.column.is_id
      return "#{target}:SetID(#{literal field.column.kind, field.value})"

    "#{target}:SetField(#{string.format "%q", field.column.field}, " ..
      "#{literal field.column.kind, field.value}#{extra_of field.column})"

  writes = (entry, target) ->
    for slot in *entry.order
      field = entry.fields[slot]
      add write_line target, field if field

  -- One local, reassigned, rather than one per row: a script touching two
  -- hundred rows would otherwise run into Lua's limit on locals per function.
  needs_row = false
  for entry in *set.entries
    needs_row = true if #entry.order > 1 or (entry.kind == "add" and #entry.order > 0)

  if needs_row
    add "local row"
    add ""

  -- Creations first: they append, so nothing that follows has to account for
  -- them having happened.
  for entry in *adds
    target = #entry.order > 0 and "row = " or ""

    if entry.created == "duplicate"
      id = entry.id and ", #{entry.id}" or ""
      source = entry.source or replay[entry.source_key] or 1
      add "#{target}#{handle}:DuplicateRowByIndex(#{source}#{id})"
    else
      add "#{target}#{handle}:Create(#{entry.id})"

    writes entry, "row"
    add ""

  for entry in *edits
    target = lookup set, entry, handle

    -- One field reads better as one statement. More than one, and the lookup
    -- is worth doing once.
    if #entry.order == 1
      add write_line target, entry.fields[entry.order[1]]
    else
      add "row = #{target}"
      writes entry, "row"
    add ""

  -- Deletions last, highest index first, so that an index named here is the
  -- index it had in the file this script was pointed at.
  if #deletes > 0
    ordered = [entry for entry in *deletes]
    table.sort ordered, (a, b) -> (a.index or 0) > (b.index or 0)

    for entry in *ordered
      if set.has_id and entry.id
        -- Resolved through the ID rather than written as a number: the rows
        -- above this one may have moved, and the ID has not.
        add "#{handle}:DeleteRow(#{handle}:GetRowById(#{entry.id}):GetIndex())"
      else
        add "#{handle}:DeleteRow(#{entry.index})"
    add ""

  add "#{handle}:Save()"
  add ""

  table.concat out, "\n"

M
