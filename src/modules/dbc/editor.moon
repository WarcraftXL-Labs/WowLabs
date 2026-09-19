--- One open table, and everything that can be done to it.
--
-- A session is a table, the grid's view of it, and the stack that can take
-- back what was done to it. There is one per table the user has opened, so
-- moving between two tables does not lose either one's edits.
--
-- Four rules run through all of it:
--
-- **A row is its 1-based index, never its ID.** 22 of the 246 tables in 3.3.5
-- keep no ID in their records and `GetID` answers the ordinal for those, so an
-- editor that keyed on the ID would be editing row 1 whenever it meant row 1.
-- What the *script* emits is an ID wherever there is one, which is a different
-- question - see changes.moon.
--
-- **A localised column is read and written at one named slot.** With no locale
-- a read answers the first non-empty slot and a write goes to slot 0, so the
-- two disagree the moment the client is not enUS: one edit, and the row has
-- the old name in one language and the new one in another. The locale comes
-- from the workspace and is passed on both sides, every time.
--
-- **A structural edit invalidates every row proxy at or after it.** Nothing
-- here holds one: every read and write fetches the row by index and lets it
-- go, which costs a table lookup and removes the failure entirely.
--
-- **The stack is the only source of structural change, and it unwinds LIFO.**
-- That is what keeps the indices in it correct without rewriting any of them:
-- the entry on top is the last thing that happened, so the index it names is
-- still the index it named.
---@module modules.dbc.editor

ffi = require "ffi"
Neutrino = require "neutrino"
changes = require "modules.dbc.changes"
query = require "modules.dbc.query"

fs = Neutrino.fs
json = Neutrino.json

M = {}

--- What a column is wide before anyone drags it.
-- Wide enough for a spell name at 12px, which is the longest thing most
-- tables hold; everything else is narrower and can be dragged in.
---@type integer
M.DEFAULT_WIDTH = 150

-- ═══════════════════════════════════════════════════════════════════════════
-- Columns
-- ═══════════════════════════════════════════════════════════════════════════

--- The locale slots, in record order.
--
-- Mirrors lua-dbc's own table. Slots 14 and 15 exist in the record and have
-- no name in any client, so they are not offered: a column headed "[14]" is a
-- column nobody can act on.
---@type string[]
M.LOCALES = {
  "enUS", "koKR", "frFR", "deDE", "enCN", "zhCN", "zhTW"
  "enTW", "ruRU", "esES", "esMX", "ptPT", "ptBR", "itIT"
}

--- Which locale slots a table actually carries text in.
--
-- Sampled rather than scanned: a table of fifty thousand rows answers this in
-- the first few hundred, and the question being asked - "which languages is
-- this file translated into" - is a property of the file, not of any row.
--
-- A slot counts as populated when any sampled row has something in it.
---@param tbl table DbcTable.
---@param schema table
---@param sample? integer How many rows to look at. Defaults to 256.
---@return string[] slots In record order.
M.populated_locales = (tbl, schema, sample = 256) ->
  fields = [field for field in *schema.fields when field.kind == "loc" and not field.is_non_inline]
  return {} if #fields == 0

  total = tbl\Count!
  looked = math.min total, sample
  seen = {}

  for index = 1, looked
    ok, row = pcall tbl.GetRowByIndex, tbl, index
    continue unless ok

    for field in *fields
      for slot in *M.LOCALES
        continue if seen[slot]
        read, value = pcall row.GetField, row, field.name, slot
        seen[slot] = true if read and type(value) == "string" and value != ""

  [slot for slot in *M.LOCALES when seen[slot]]

--- The grid's columns, one per editable value in a record.
--
-- An inline array is one field and `count` cells: showing it as one cell would
-- mean editing a Lua table in a text box. A localised column is the opposite -
-- 17 words of record, and how many cells depends on what is being asked for.
--
-- With `slots` given, a localised field becomes one column per slot named in
-- it, which is how a translator sees every language side by side. With none,
-- it is a single column at the workspace's own locale. Sixteen columns per
-- localised field regardless would put two hundred columns on a table that
-- carries one language.
---@param schema table
---@param locale string Which slot a localised column reads and writes.
---@param slots? string[] Locale slots to give a column each.
---@return table[]
M.columns = (schema, locale, slots) ->
  columns = {}
  spread = slots and #slots > 0 and slots or nil

  for field in *schema.fields
    -- A non-inline column is declared but not in the record; it has no bytes
    -- to show and writing one would write over its neighbour.
    continue if field.is_non_inline

    if field.count > 1
      for index = 1, field.count
        table.insert columns, {
          field: field.name
          label: "#{field.name}[#{index}]"
          kind: field.kind
          extra: index
          offset: field.offset + (index - 1) * field.width
          width: field.width
          is_id: false
        }
    elseif field.kind == "loc" and spread
      for slot in *spread
        table.insert columns, {
          field: field.name
          label: "#{field.name} #{slot}"
          kind: field.kind
          extra: slot
          offset: field.offset
          width: field.width
          locale: slot
          is_id: false
        }
    else
      table.insert columns, {
        field: field.name
        label: field.name
        kind: field.kind
        extra: field.kind == "loc" and locale or nil
        offset: field.offset
        width: field.width
        locale: field.kind == "loc" and locale or nil

        -- Only when the ID is really in the record: on the 22 tables where it
        -- is not, the column marked isID describes the ordinal and there is
        -- nothing at that offset to write.
        is_id: (field.is_id and schema.has_id_inline) and true or false
      }

  columns

-- ═══════════════════════════════════════════════════════════════════════════
-- Sessions
-- ═══════════════════════════════════════════════════════════════════════════

--- Opens a session on a table.
---@param tbl table DbcTable.
---@param name string Table name.
---@param locale string Locale slot to edit.
---@param build string
---@return table session
M.session = (tbl, name, locale, build, spread) ->
  schema = tbl\GetSchema!
  rows = tbl\Count!
  slots = M.populated_locales tbl, schema

  session = {
    :name
    :locale
    table: tbl
    :schema
    slots: slots
    spread: spread and true or false
    columns: M.columns schema, locale, spread and slots or nil
    has_id: schema.has_id_inline and true or false
    format: tbl\GetFormatName!

    -- Which rows the grid pages over, in the order it shows them. Left nil
    -- while the table is unsorted and unfiltered, because the answer is then
    -- "every row, in order" and building fifty thousand entries to say so
    -- would cost more than every other thing opening a table does.
    view: nil
    query: nil
    query_text: ""
    sort: nil

    -- Per column, and only where the user has moved one. Kept on the session
    -- rather than in settings: a width is a reaction to what is on screen
    -- now, and a file of them for 246 tables would outlive its usefulness.
    widths: {}

    -- Where each row was in the file that was opened. A row that was not
    -- there has no such index, and the key is what names it instead. This is
    -- rewritten by every insertion and deletion, which is what lets a change
    -- recorded now still name the right row after ten more.
    origin: [{ key: "p:#{index}", pristine: index } for index = 1, rows]
    created: 0

    stack: {}
    redo: {}

    -- The value each touched cell had before this session, so a cell put back
    -- to it can be dropped from the change set rather than written again.
    originals: {}

    -- A write that failed, by cell: what was typed and why it would not go in.
    -- Kept so the grid can show the text back rather than silently replacing
    -- it with the value that is still in the record.
    pending: {}

    set: changes.new { table: name, :build, :rows, has_id: schema.has_id_inline }

    -- How deep the stack was when the file was last written, so "are there
    -- changes since the last save" is answerable without a second flag to
    -- keep in step.
    saved_at: 0

    -- GetMaxID is a scan of the whole ID map. Cached, and only ever raised:
    -- an ID freed by a deletion is not worth handing out again, and reusing
    -- one would collide with anything that already referred to it.
    max_id: nil
  }

  session

--- The stable key for the row at an index.
---@param session table
---@param index integer
---@return string|nil
---@private
key_at = (session, index) ->
  entry = session.origin[index]
  entry and entry.key or nil

--- How the change set names the row at an index.
--
-- The key is what nothing can move; the ID and the pristine index are what a
-- replayed script will use to find the row again, and both are taken as they
-- are the first time the row is touched.
---@param session table
---@param index integer
---@return table|nil
---@private
row_ref = (session, index) ->
  entry = session.origin[index]
  return nil unless entry

  -- Parenthesised: inside a table literal a comma ends the entry, so the
  -- unparenthesised call would take `session` alone and leave `index` as a
  -- positional element of the table.
  { key: entry.key, index: entry.pristine, id: (M.id_at session, index) }

--- Which cell, within a row.
---@private
cell_of = (key, column) -> "#{key}|#{column.field}|#{tostring column.extra}"

--- The next ID to hand out.
---@private
next_id = (session) ->
  unless session.max_id
    ok, found = pcall session.table.GetMaxID, session.table
    session.max_id = ok and found or 0

  session.max_id += 1
  session.max_id

-- ═══════════════════════════════════════════════════════════════════════════
-- Reading
-- ═══════════════════════════════════════════════════════════════════════════

--- A value as the grid shows it.
-- An integer column prints as an integer: a record holding 3 that reads back
-- as "3.0" is a record nobody can search for.
---@param kind string
---@param value any
---@return string
---@private
shown = (kind, value) ->
  return "" if value == nil
  return value and "true" or "false" if type(value) == "boolean"
  return tostring value unless type(value) == "number"

  return string.format "%d", value if value == math.floor value
  string.format "%.9g", value

--- Reads one cell.
---@param session table
---@param index integer 1-based row index.
---@param column table
---@return string text
---@return string|nil err
M.read = (session, index, column) ->
  ok, row = pcall session.table.GetRowByIndex, session.table, index
  return "", tostring row unless ok

  read, value = pcall row.GetField, row, column.field, column.extra
  return "", tostring value unless read

  (shown column.kind, value), nil

--- A row's ID, or its ordinal on a table that keeps none.
---@param session table
---@param index integer
---@return integer|nil
M.id_at = (session, index) ->
  ok, row = pcall session.table.GetRowByIndex, session.table, index
  return nil unless ok

  read, id = pcall row.GetID, row
  read and id or nil

-- ═══════════════════════════════════════════════════════════════════════════
-- Order
-- ═══════════════════════════════════════════════════════════════════════════

--- The real row index behind a position in the grid.
--
-- Sorting and filtering change which row is drawn where, and nothing else may
-- change with them: a row is still its index in the file, that is still what
-- an edit records, and this is the one place the two meet.
---@param session table
---@param position integer 1-based position in the grid.
---@return integer|nil index
M.at = (session, position) ->
  return nil unless type(position) == "number" and position >= 1
  M.reindex session if session.stale
  return session.view[position] if session.view
  position <= #session.origin and position or nil

--- How many rows the grid has to show.
---@param session table
---@return integer
M.visible = (session) ->
  M.reindex session if session.stale
  session.view and #session.view or #session.origin

--- Where a row index sits in the grid, or nil when the filter hides it.
---@param session table
---@param index integer
---@return integer|nil position
M.position_of = (session, index) ->
  M.reindex session if session.stale
  return index unless session.view
  for position = 1, #session.view
    return position if session.view[position] == index
  nil

--- The column a name refers to, by label first and field name second.
---@private
column_named = (session, name) ->
  return nil unless type(name) == "string"
  lowered = name\lower!

  for column in *session.columns
    return column if column.label\lower! == lowered
  for column in *session.columns
    return column if column.field\lower! == lowered
  nil

--- Rebuilds the order from the query and the sort.
--
-- Called after anything that changes which rows exist or where they are. The
-- whole order is built again rather than repaired: a deletion moves every row
-- after it, and a repair that got one case wrong would show the wrong row
-- under the right number, which is the worst failure this grid has.
---@param session table
M.reindex = (session) ->
  total = #session.origin
  session.stale = false

  unless session.query or session.sort
    session.view = nil
    return

  kept = {}

  if session.query
    -- A bare term searches the text columns only. Every column of every row
    -- would be five million reads on Spell, and nobody typing "fireball"
    -- means "or any record whose SpellLevel is 3".
    text_columns = [c for c in *session.columns when c.kind == "str" or c.kind == "loc"]

    at = 0
    get = (name, needle) ->
      if name == nil
        lowered = needle\lower!
        for column in *text_columns
          value = M.read session, at, column
          return true if value != "" and (value\lower!\find lowered, 1, true) != nil
        return false

      column = column_named session, name
      return nil unless column
      (M.read session, at, column)

    for index = 1, total
      at = index
      ok, matched = pcall session.query, get
      table.insert kept, index if ok and matched
  else
    table.insert kept, index for index = 1, total

  if session.sort
    column = session.columns[session.sort.column]
    if column
      -- The key is read once per row rather than on every comparison: a sort
      -- of fifty thousand rows makes about eight hundred thousand of those,
      -- and each one is a field read through a proxy.
      numeric = column.kind != "str" and column.kind != "loc"
      keys = {}
      for index in *kept
        value = M.read session, index, column
        keys[index] = numeric and (tonumber(value) or 0) or value\lower!

      descending = session.sort.descending
      table.sort kept, (a, b) ->
        left, right = keys[a], keys[b]
        -- The index breaks every tie, so two equal rows keep their order and
        -- the sort does not reshuffle them on each redraw.
        return a < b if left == right
        if descending then left > right else left < right

  session.view = kept

--- Sets the query, and answers whether it could be read.
---@param session table
---@param text string
---@return boolean ok, string|nil err
M.set_query = (session, text) ->
  text = tostring(text or "")
  predicate, err = query.compile text

  if err
    -- The old order stays: a half-typed query should not empty the grid.
    return false, err

  session.query_text = text
  session.query = predicate
  M.reindex session
  true, nil

--- Sorts by a column, or stops sorting.
--
-- Three states in one action, because a header has one place to click:
-- ascending, then descending, then back to the file's own order. A sort that
-- could only be turned off somewhere else is a sort people leave on.
---@param session table
---@param index integer Column index, or nil to clear.
---@return table|nil sort
M.set_sort = (session, index) ->
  if index == nil or not session.columns[index]
    session.sort = nil
  elseif session.sort and session.sort.column == index
    if session.sort.descending
      session.sort = nil
    else
      session.sort = { column: index, descending: true }
  else
    session.sort = { column: index, descending: false }

  M.reindex session
  session.sort

--- The block of cells the grid is showing.
--
-- Bound to the visible window and nothing else: a table of forty thousand rows
-- is ordinary, every proxy is a live view rather than a copy, and the cost of
-- answering is the cost of what is on screen.
---@param session table
---@param first_row integer 0-based offset of the first row wanted.
---@param first_col integer 0-based offset of the first column wanted.
---@param row_count integer
---@param col_count integer
---@return table window
--- A column's width, as the user left it.
---@param session table
---@param index integer
---@return integer
M.width_of = (session, index) -> session.widths[index] or M.DEFAULT_WIDTH

--- Sets one column's width, within what is usable.
--
-- Bounded because a column dragged to nothing cannot be dragged back: the
-- handle would have no width to grab.
---@param session table
---@param index integer
---@param width number
M.set_width = (session, index, width) ->
  return unless session.columns[index]
  session.widths[index] = math.max 48, math.min 900, math.floor width

--- Where each column starts, cumulatively.
--
-- The grid drew every column at the same width, which made "which column is
-- under this scroll offset" a division. With widths of their own it becomes a
-- search, so the offsets are computed here, once, and the page is given them
-- rather than each cell's width alone.
---@param session table
---@return number[] offsets 1-based; offsets[n] is where column n starts.
---@return number total
---@private
column_offsets = (session) ->
  offsets = {}
  running = 0

  for index = 1, #session.columns
    offsets[index] = running
    running += M.width_of session, index

  offsets[#session.columns + 1] = running
  offsets, running

M.window = (session, first_row, first_col, row_count, col_count) ->
  total_rows = M.visible session
  total_cols = #session.columns
  offsets, total_width = column_offsets session

  first_row = math.max 0, (math.min first_row, (math.max 0, total_rows - 1))
  first_col = math.max 0, (math.min first_col, (math.max 0, total_cols - 1))

  sorted = session.sort and session.sort.column or 0

  columns = {}
  for offset = 1, col_count
    at = first_col + offset
    column = session.columns[at]
    break unless column
    table.insert columns, {
      label: column.label
      kind: column.kind
      extra: type(column.extra) == "string" and column.extra or nil
      index: at
      w: M.width_of session, at
      sorted: at == sorted and (session.sort.descending and "desc" or "asc") or nil
    }

  rows = {}
  for offset = 1, row_count
    index = M.at session, first_row + offset
    break unless index

    key = key_at session, index
    cells = {}

    for position = 1, #columns
      column = session.columns[first_col + position]
      cell = cell_of key, column
      failed = session.pending[cell]

      if failed
        -- What was typed, not what is in the record: the edit is still the
        -- only copy of what the user meant.
        table.insert cells, { v: failed.text, e: failed.message, d: true }
      else
        text, err = M.read session, index, column
        table.insert cells, {
          v: text
          e: err
          d: (changes.field session.set, key, column) != nil or nil
        }

    table.insert rows, {
      index: index
      id: M.id_at session, index
      new: (changes.kind session.set, key) == "add" or nil
      cells: json.array cells
    }

  {
    row: first_row
    col: first_col
    columns: json.array columns
    rows: json.array rows
    total_rows: total_rows
    total_cols: total_cols

    -- Where the drawn block starts, and how wide the whole table is. The page
    -- can no longer work either out by multiplying, so it is told.
    x: offsets[first_col + 1] or 0
    offsets: json.array offsets
    total_width: total_width
  }

-- ═══════════════════════════════════════════════════════════════════════════
-- Writing
-- ═══════════════════════════════════════════════════════════════════════════

--- Turns what was typed into what the column holds.
---@param column table
---@param text string
---@return any value, string|nil err
M.parse = (column, text) ->
  text = tostring text

  switch column.kind
    when "str", "loc"
      text, nil
    when "bool"
      lowered = text\lower!
      return true, nil if lowered == "true" or lowered == "1"
      return false, nil if lowered == "false" or lowered == "0" or lowered == ""
      nil, "expected true or false"
    when "f32"
      number = tonumber text
      return nil, "expected a number" unless number
      number, nil
    else
      number = tonumber text
      return nil, "expected a whole number" unless number
      return nil, "expected a whole number" unless number == math.floor number
      number, nil

--- The one place a value reaches a record.
--
-- Every write goes through here, including the ones undo makes. The generated
-- setters would work and are deliberately not used: they are compiled onto the
-- schema object, which is shared by every table of this name in the process,
-- and a write that went round this function would be a change nothing recorded.
--
-- The ID is not a column like the others. Written through SetField the record
-- changes and the table's ID index does not, and the next lookup by ID finds
-- the wrong row - so it goes through SetID, which maintains both.
---@param row table RowProxy.
---@param column table
---@param value any
---@private
apply = (row, column, value) ->
  return row\SetID value if column.is_id
  row\SetField column.field, value, column.extra

--- A field's raw bytes, exactly.
--
-- Bytes rather than the value, because a value is not enough to put back: a
-- localised column is 68 bytes of 17 slots and reading it answers one of them,
-- so restoring "the value" would write one slot and leave sixteen as the edit
-- left them.
---@param row table
---@param column table
---@return string
---@private
snapshot = (row, column) ->
  ffi.string row\GetAddress(column.offset), column.width

--- Puts a field's bytes back.
---@private
restore = (session, row, column, bytes) ->
  ffi.copy row\GetAddress(column.offset), bytes, #bytes

  -- A write through the library sets this; one straight into the buffer has
  -- to say so itself, or the table saves as though nothing had happened.
  session.table\GetFile!.dirty = true

--- Writes one cell, and records enough to take it back.
--
-- A failed write keeps the edit: the text is remembered against the cell, the
-- message goes back to the interface, and the record is left as it was. What
-- the user typed is the only copy of what they meant, and replacing it with
-- the old value to make the grid tidy would throw that away.
---@param session table
---@param index integer
---@param column table
---@param text string What was typed.
---@return boolean ok, string|nil err
M.set_cell = (session, index, column, text) ->
  key = key_at session, index
  return false, "row #{index} is not in this table" unless key

  cell = cell_of key, column

  value, parse_err = M.parse column, text
  if parse_err
    session.pending[cell] = { text: tostring(text), message: parse_err }
    return false, parse_err

  ok, row = pcall session.table.GetRowByIndex, session.table, index
  return false, tostring row unless ok

  -- Before the write, and only the first time this cell is touched: what it
  -- held when the session started is what "back to where it was" means.
  if session.originals[cell] == nil
    before, read_err = M.read session, index, column
    session.originals[cell] = read_err and "" or before

  reference = row_ref session, index
  bytes = snapshot row, column
  captured = changes.capture session.set, key

  written, err = pcall apply, row, column, value
  unless written
    session.pending[cell] = { text: tostring(text), message: tostring err }
    return false, tostring err

  session.pending[cell] = nil

  table.insert session.stack, {
    kind: "cell", :index, :column, :bytes, :key, :captured
  }
  session.redo = {}

  changes.cell session.set, reference, column,
    (shown column.kind, value), session.originals[cell]

  true

-- ═══════════════════════════════════════════════════════════════════════════
-- Rows
-- ═══════════════════════════════════════════════════════════════════════════

--- Takes a row out, and hands back what is needed to put it back.
---@private
remove_row = (session, index) ->
  ok, bytes = pcall session.table.CopyRecord, session.table, index
  return nil, tostring bytes unless ok

  deleted, err = pcall session.table.DeleteRow, session.table, index
  return nil, tostring err unless deleted

  entry = table.remove session.origin, index

  -- Every row after this one just moved, so whatever order the grid was
  -- paging over describes rows that are no longer where it says. Marked
  -- rather than rebuilt, because a deletion is often one of several and the
  -- query only has to run again before the next draw.
  session.stale = true
  bytes, entry

--- Puts one back where it was.
---@private
restore_row = (session, index, bytes, origin) ->
  ok, err = pcall session.table.InsertRow, session.table, index, bytes
  return false, tostring err unless ok

  table.insert session.origin, index, origin
  session.stale = true
  true

--- Adds a blank row at the end.
-- Offered only where the table keeps an ID: without one there is nothing to
-- distinguish a new row from the row above it, and `Create` has nowhere to
-- write the key it was given.
---@param session table
---@return integer|nil index, string|nil err
M.add_row = (session) ->
  unless session.has_id
    return nil, "#{session.name} keeps no ID in its records, so a new row
      cannot be told apart from the rows around it. Duplicate one instead."

  id = next_id session

  ok, err = pcall session.table.Create, session.table, id
  return nil, tostring err unless ok

  index = session.table\Count!
  session.created += 1
  key = "n:#{session.created}"

  table.insert session.origin, { :key, created: true }
  session.stale = true
  changes.added session.set, { :key, :id }, { kind: "create" }

  table.insert session.stack, { kind: "add", :index, :key }
  session.redo = {}

  index

--- Copies a row, appending the copy.
-- Works on every table, including the 22 with no ID: it takes an index and
-- copies bytes, which is something every record has.
---@param session table
---@param index integer
---@return integer|nil index, string|nil err
M.duplicate_row = (session, index) ->
  source = session.origin[index]
  return nil, "row #{index} is not in this table" unless source

  id = session.has_id and next_id(session) or nil

  ok, err = pcall session.table.DuplicateRowByIndex, session.table, index, id
  return nil, tostring err unless ok

  at = session.table\Count!
  session.created += 1
  key = "n:#{session.created}"

  table.insert session.origin, { :key, created: true }
  session.stale = true
  changes.added session.set, { :key, :id }, {
    kind: "duplicate"
    source: source.pristine
    source_key: source.key
  }

  table.insert session.stack, { kind: "add", index: at, :key }
  session.redo = {}

  at

--- Deletes a row.
---@param session table
---@param index integer
---@return boolean ok, string|nil err
M.delete_row = (session, index) ->
  origin = session.origin[index]
  return false, "row #{index} is not in this table" unless origin

  reference = row_ref session, index
  captured = changes.capture session.set, origin.key

  bytes, err = remove_row session, index
  return false, err unless bytes

  changes.removed session.set, reference

  table.insert session.stack, {
    kind: "delete", :index, :bytes, key: origin.key, :origin, :captured
  }
  session.redo = {}

  true

-- ═══════════════════════════════════════════════════════════════════════════
-- Undo and redo
-- ═══════════════════════════════════════════════════════════════════════════

--- Turns one entry inside out, leaving it ready to be turned back.
--
-- The same function serves undo and redo: an entry describes a change and
-- carries what the opposite change needs, so applying it twice returns to
-- where it started. A cell keeps the bytes to write and takes back the ones it
-- replaced; a row keeps its record and takes back the index it left.
---@param session table
---@param entry table
---@return boolean ok, string|nil err
---@private
invert = (session, entry) ->
  captured = changes.capture session.set, entry.key

  switch entry.kind
    when "cell"
      ok, row = pcall session.table.GetRowByIndex, session.table, entry.index
      return false, tostring row unless ok

      current = snapshot row, entry.column
      restore session, row, entry.column, entry.bytes
      entry.bytes = current

      -- The pending text belonged to a write that is no longer the last word
      -- on this cell.
      session.pending[cell_of entry.key, entry.column] = nil

    when "add"
      bytes, origin = remove_row session, entry.index
      return false, origin unless bytes

      entry.bytes = bytes
      entry.origin = origin
      entry.kind = "delete"

    when "delete"
      ok, err = restore_row session, entry.index, entry.bytes, entry.origin
      return false, err unless ok

      entry.kind = "add"

  changes.reinstate session.set, entry.key, entry.captured
  entry.captured = captured
  true

--- Whether there is anything to take back.
---@param session table
---@return boolean
M.can_undo = (session) -> #session.stack > 0

--- Whether there is anything to put back.
---@param session table
---@return boolean
M.can_redo = (session) -> #session.redo > 0

--- Takes back the last change.
---@param session table
---@return boolean ok, string|nil err
M.undo = (session) ->
  entry = session.stack[#session.stack]
  return false, "there is nothing to undo" unless entry

  ok, err = invert session, entry
  return false, err unless ok

  table.remove session.stack
  table.insert session.redo, entry
  true

--- Puts back the last change taken back.
---@param session table
---@return boolean ok, string|nil err
M.redo = (session) ->
  entry = session.redo[#session.redo]
  return false, "there is nothing to redo" unless entry

  ok, err = invert session, entry
  return false, err unless ok

  table.remove session.redo
  table.insert session.stack, entry
  true

-- ═══════════════════════════════════════════════════════════════════════════
-- Out
-- ═══════════════════════════════════════════════════════════════════════════

--- Whether anything has happened since the file was last written.
---@param session table
---@return boolean
M.is_dirty = (session) -> #session.stack != session.saved_at

--- Writes the table as a DBC.
--
-- Through a temporary file and a move, because `Save` truncates its target
-- before it writes: a failure partway through the direct version leaves a
-- shorter file where the client's used to be.
---@param session table
---@param path string Where the .dbc goes.
---@return integer|nil bytes, string|nil err
M.save = (session, path) ->
  folder = fs.dirname path
  unless fs.is_dir folder
    made, make_err = fs.make_dir folder
    return nil, "cannot create #{folder}: #{tostring make_err}" unless made

  temporary = "#{path}.writing"

  ok, written = pcall session.table.Save, session.table, temporary
  unless ok
    fs.remove temporary
    return nil, tostring written

  moved, move_err = fs.move temporary, path
  unless moved
    fs.remove temporary
    return nil, "cannot write #{path}: #{tostring move_err}"

  session.saved_at = #session.stack
  written

--- The Lua that reproduces this session's edits.
-- One function, and the only one: the preview panel and anything that writes
-- the script to disk both come through here.
---@param session table
---@return string
M.script = (session) -> changes.script session.set

M
