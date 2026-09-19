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
relations = require "modules.dbc.relations"

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
          foreign: field.foreign_table
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

        -- Which table this refers to, when it refers to one. Read straight
        -- off the definition, so nothing here is a list somebody maintains.
        foreign: (field.kind != "str" and field.kind != "loc") and
          field.foreign_table or nil

        -- Only when the ID is really in the record: on the 22 tables where it
        -- is not, the column marked isID describes the ordinal and there is
        -- nothing at that offset to write.
        is_id: (field.is_id and schema.has_id_inline) and true or false
      }

  columns

-- ═══════════════════════════════════════════════════════════════════════════
-- Sessions
-- ═══════════════════════════════════════════════════════════════════════════

--- Which locale slots a session shows a column for.
--
-- Three answers, because they serve three different jobs: editing a client in
-- one language, checking a translation against the others, and filling in a
-- language the file does not carry yet - which is the only one "the languages
-- present" cannot do, since the column would not be there to type into.
---@param mode string "workspace", "present" or "all".
---@param present string[] What the file actually carries.
---@return string[]|nil slots nil for one column at the workspace's locale.
M.slots_for = (mode, present) ->
  return M.LOCALES if mode == "all"
  return present if mode == "present"
  nil

--- Opens a session on a table.
---@param tbl table DbcTable.
---@param name string Table name.
---@param locale string Locale slot to edit.
---@param build string
---@param mode? string "workspace", "present" or "all". Defaults to the
--- workspace's own locale: a caller that says nothing gets the simplest
--- shape, and the application always says.
---@return table session
M.session = (tbl, name, locale, build, mode) ->
  schema = tbl\GetSchema!
  rows = tbl\Count!
  present = M.populated_locales tbl, schema
  slots = M.slots_for (mode or "workspace"), present

  session = {
    :name
    :locale
    table: tbl
    :schema
    present: present
    slots: slots
    mode: mode or "workspace"
    spread: slots != nil
    columns: M.columns schema, locale, slots
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

    -- Which columns are on screen and in what order, for the same reason and
    -- in the same place. `order` stays nil while the record's own order is
    -- what is shown, so the common case costs nothing; `hidden` is a map of
    -- column index to true. Spell has 105 columns and nobody wants all of
    -- them, which is the whole point of both.
    hidden: {}
    order: nil

    -- Whether the grid pages over the changed rows alone, which is the view
    -- you want in front of you before saving.
    changed_only: false

    -- Where paging begins, as an offset into the order. Non-zero only after
    -- a jump to a particular row: the grid is fed forwards a page at a time,
    -- so reaching row 40,000 means starting there rather than pulling the
    -- 39,999 above it through the window first.
    from: 0

    -- Where each row was in the file that was opened. A row that was not
    -- there has no such index, and the key is what names it instead. This is
    -- rewritten by every insertion and deletion, which is what lets a change
    -- recorded now still name the right row after ten more.
    origin: [{ key: "p:#{index}", pristine: index } for index = 1, rows]
    created: 0

    stack: {}
    redo: {}

    -- The group being recorded into, and how deep the calls to open one are
    -- nested. A paste of two hundred cells is one thing the user did, so it
    -- has to be one thing to take back.
    group: nil
    group_depth: 0

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

--- Names a referenced row, and gives up quietly.
--
-- Through pcall because this reads another file: a definition can name a table
-- the client does not ship, and a cell that could not be resolved should show
-- its number rather than take the grid down.
---@private
pcall_describe = (name, locale, id) ->
  ok, text = pcall relations.describe, name, locale, id
  ok and text or nil

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

  -- With names on, a column that refers to another table reads as the row it
  -- refers to. Only for showing: what goes back into the record is the id,
  -- and `parse` takes the name off again.
  if session.readable and column.foreign and type(value) == "number"
    named = pcall_describe column.foreign, session.locale, value
    return named, nil if named

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

--- The column a name refers to.
--
-- Three spellings, because a localised column's label carries a space -
-- `Name_lang frFR` - and the query language splits on whitespace. Quoting it
-- works, and so does a dot, which is the form that can be typed without
-- reaching for the quote key:
--
--     'Name_lang frFR' CONTAINS 'feu'
--     Name_lang.frFR CONTAINS 'feu'
--
---@param session table
---@param name string
---@return table|nil column
---@private
column_named = (session, name) ->
  return nil unless type(name) == "string"
  lowered = name\lower!

  for column in *session.columns
    return column if column.label\lower! == lowered

  -- field.locale, and field[n] for an array element.
  field, part = lowered\match "^(.-)%.(.+)$"
  if field
    for column in *session.columns
      continue unless column.field\lower! == field
      return column if tostring(column.extra)\lower! == part

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

  unless session.query or session.sort or session.changed_only
    session.view = nil
    return

  -- The rows the session has touched, by the key nothing can move. Taken once
  -- rather than asked per row: the walk below is over every record in the
  -- file, and a table of fifty thousand deserves the one map.
  changed = session.changed_only and (changes.keys session.set) or nil

  keep = (index) ->
    return true unless changed
    key = key_at session, index
    key != nil and changed[key] == true

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
      table.insert kept, index if ok and matched and (keep index)
  else
    for index = 1, total
      table.insert kept, index if keep index

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

--- Sorts by a column, in the direction asked for.
--
-- Over the whole table, which is why this is here rather than in the grid: the
-- grid holds what has been scrolled past and nothing else, and sorting that is
-- sorting an arbitrary prefix.
--
-- The direction is given rather than cycled. A header with one place to click
-- has to cycle through ascending, descending and off, because there is nowhere
-- to say which of the three is wanted - but the grid sends the direction with
-- every page it asks for, and a cycle would turn the sort off on the second
-- page of the same sorted table.
---@param session table
---@param index integer|nil Column index, or nil to stop sorting.
---@param descending boolean
---@return table|nil sort
M.sort_by = (session, index, descending) ->
  if index == nil or not session.columns[index]
    session.sort = nil
  else
    session.sort = { column: index, descending: descending and true or false }

  M.reindex session
  session.sort

--- Pages over the changed rows alone, or over all of them again.
---@param session table
---@param wanted boolean
M.set_changed_only = (session, wanted) ->
  session.changed_only = wanted and true or false
  session.from = 0
  M.reindex session

--- Where paging begins, as an offset into the order.
--
-- The grid is fed forwards from here, so this is how a row deep in a large
-- table is reached at all: everything above the anchor is off the top until
-- it is put back to zero.
---@param session table
---@param offset integer 0-based.
M.set_from = (session, offset) ->
  total = M.visible session
  wanted = math.floor(tonumber(offset) or 0)
  session.from = math.max 0, (math.min wanted, (math.max 0, total - 1))

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

--- The column indices in the order the grid shows them, hidden ones included.
--
-- Whatever the user has arranged first, then anything the arrangement does not
-- mention. A column added after the order was set - which is what changing the
-- locale mode does - would otherwise disappear rather than appear at the end.
---@param session table
---@return integer[]
M.layout = (session) ->
  seen = {}
  order = {}

  for index in *(session.order or {})
    continue unless session.columns[index]
    continue if seen[index]
    seen[index] = true
    table.insert order, index

  for index = 1, #session.columns
    continue if seen[index]
    table.insert order, index

  order

--- Arranges the columns: which are on screen, and in what order.
--
-- Both at once, because both arrive from the same control and applying one
-- without the other would draw the grid twice.
---@param session table
---@param order? integer[] Column indices. nil leaves the order alone.
---@param hidden? table<integer, boolean> nil leaves visibility alone.
M.set_layout = (session, order, hidden) ->
  if type(order) == "table"
    kept = {}
    for index in *order
      number = tonumber index
      table.insert kept, number if number and session.columns[number]
    session.order = #kept > 0 and kept or nil

  if type(hidden) == "table"
    marked = {}
    for index, on_screen in pairs hidden
      number = tonumber index
      marked[number] = true if number and session.columns[number] and on_screen
    session.hidden = marked

--- The columns as the grid draws them: in order, each saying whether it shows.
--
-- Keyed by index rather than by label. Two localised columns of one field
-- differ only by slot, and a label is for people.
---@param session table
---@return table[]
M.grid_columns = (session) ->
  sorted = session.sort and session.sort.column or 0
  columns = {}

  for index in *M.layout session
    column = session.columns[index]
    table.insert columns, {
      key: "c#{index}"
      :index
      label: column.label
      kind: column.kind
      extra: type(column.extra) == "string" and column.extra or nil
      w: M.width_of session, index
      shown: not session.hidden[index]
      sorted: index == sorted and (session.sort.descending and "desc" or "asc") or nil

      -- Which cells can offer a list of rows to pick from, and which are only
      -- numbers.
      foreign: column.foreign
    }

  json.array columns

--- One row, in the shape the grid holds it.
--
-- `_i` is its 1-based index in the file, which is its identity: 22 of the 246
-- tables in 3.3.5 keep no ID in their records. `_d` marks the cells this
-- session has changed and `_e` the ones whose write was refused, both keyed by
-- the same `c<index>` the values are.
---@param session table
---@param index integer
---@param on_screen integer[] Column indices to read.
---@return table
---@private
row_shape = (session, index, on_screen) ->
  key = key_at session, index

  -- Parenthesised: inside a table literal a comma ends the entry, so the
  -- unparenthesised call would take `session` alone and leave `index` as a
  -- positional element of the row.
  row = { _i: index, _id: (M.id_at session, index) }
  row._new = true if (changes.kind session.set, key) == "add"

  dirty, refused = nil, nil

  for at in *on_screen
    column = session.columns[at]
    field = "c#{at}"
    failed = session.pending[cell_of key, column]

    if failed
      -- What was typed, not what is in the record: the edit is still the only
      -- copy of what the user meant.
      row[field] = failed.text
      refused or= {}
      refused[field] = failed.message
    else
      text, err = M.read session, index, column
      row[field] = text

      if err
        refused or= {}
        refused[field] = err
      elseif (changes.field session.set, key, column) != nil
        dirty or= {}
        dirty[field] = true

  row._d = dirty
  row._e = refused
  row

--- Which columns the grid is reading: those on screen, in order.
---@param session table
---@return integer[]
---@private
shown_columns = (session) ->
  [index for index in *M.layout session when not session.hidden[index]]

--- One row by its index in the file, whether or not it is on a page.
--
-- What a write hands back, so the grid can show what Lua holds without asking
-- for the table again - which would throw away every page scrolled past.
---@param session table
---@param index integer
---@return table|nil
M.row_at = (session, index) ->
  return nil unless session.origin[index]
  row_shape session, index, shown_columns session

--- One page of rows, as the grid asks for them.
--
-- The grid library virtualises the document and not the data: it wants every
-- row it is ever going to show, which on Spell is 49,839 by 105 - five million
-- values that are neither serialisable nor holdable. So it is fed forwards a
-- page at a time, and what it holds is what was actually scrolled past.
---@param session table
---@param page integer 1-based.
---@param size integer Rows per page.
---@return table { data, last_page, total, from }
M.page = (session, page, size) ->
  total = M.visible session
  page = math.max 1, math.floor(tonumber(page) or 1)
  size = math.max 1, math.floor(tonumber(size) or 100)

  -- `from` is the second half of `import x from y`, so it cannot be a local:
  -- the parse fails and the compiler blames the line rather than the name.
  anchor = session.from or 0
  begins = math.max 0, (math.min anchor, (math.max 0, total - 1))
  remaining = math.max 0, total - begins
  last = math.max 1, (math.ceil remaining / size)

  -- Only the columns on screen. Hiding 95 of Spell's 105 is a twentieth of the
  -- reads and a twentieth of the JSON, which is most of what this costs.
  --
  -- Not named `shown`: that is the module-level function that formats a value,
  -- and MoonScript would assign to it rather than declare a second one.
  on_screen = shown_columns session

  rows = {}
  for offset = 1, size
    position = begins + (page - 1) * size + offset
    break if position > total

    index = M.at session, position
    break unless index

    table.insert rows, row_shape session, index, on_screen

  { data: json.array(rows), last_page: last, :total, from: begins }

-- ═══════════════════════════════════════════════════════════════════════════
-- Writing
-- ═══════════════════════════════════════════════════════════════════════════

--- Turns what was typed into what the column holds.
---@param column table
---@param text string
---@return any value, string|nil err
M.parse = (column, text) ->
  text = tostring text

  -- "12 (Kalimdor)" came out of a cell with names on, so it has to go back in
  -- the same shape it left. Stripped rather than refused: the alternative is a
  -- grid where every cell you touch has to be retyped from scratch.
  if column.foreign
    number = text\match "^%s*(%-?%d+)%s*%b()%s*$"
    text = number if number

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

-- ═══════════════════════════════════════════════════════════════════════════
-- Grouping
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A paste of two hundred cells is one thing the user did, and two hundred
-- presses of Ctrl+Z to take it back would be unusable. So everything recorded
-- between `begin_group` and `end_group` becomes a single entry on the stack.
--
-- A group holds what actually happened, not what was attempted. A cell the
-- column would not take never reaches the record and never reaches the group:
-- its text stays pending and its message stays on screen, exactly as a typed
-- edit's does, and there is nothing about it to undo. So "half applied" is not
-- a state a group can be left in - the entries it carries are precisely the
-- writes that took.
--
-- Undoing one is all or nothing, which is the other half of the same promise:
-- see `invert_group`.

--- Puts an entry on the stack, or into the group if one is open.
---@param session table
---@param entry table
---@private
record = (session, entry) ->
  if session.group
    table.insert session.group.entries, entry
    return

  table.insert session.stack, entry
  session.redo = {}

--- Starts recording into a group.
--
-- Nested calls are counted rather than refused, so a caller that groups a
-- paste cannot be broken by a caller that groups the operation around it.
---@param session table
M.begin_group = (session) ->
  session.group_depth = (session.group_depth or 0) + 1
  session.group = { kind: "group", entries: {} } if session.group_depth == 1

--- Closes the group, leaving one step on the stack.
---@param session table
---@return integer members How many writes it holds.
M.end_group = (session) ->
  return 0 unless session.group_depth and session.group_depth > 0

  session.group_depth -= 1
  return 0 if session.group_depth > 0

  group = session.group
  session.group = nil
  return 0 unless group

  members = #group.entries

  -- A group that took nothing is not a step. Every cell in the paste was
  -- refused, and one Ctrl+Z should not be spent undoing nothing at all.
  return 0 if members == 0

  -- One entry is its own step: wrapping it changes nothing and costs a level
  -- of indirection on every undo that walks past it afterwards.
  table.insert session.stack, members == 1 and group.entries[1] or group
  session.redo = {}
  members

-- ═══════════════════════════════════════════════════════════════════════════

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

  record session, { kind: "cell", :index, :column, :bytes, :key, :captured }

  -- The changed-rows view is a filter over the change set, so a write that
  -- adds a row to it has changed which rows the grid pages over.
  session.stale = true if session.changed_only

  changes.cell session.set, reference, column,
    (shown column.kind, value), session.originals[cell]

  true

--- Writes a block of cells as one step.
--
-- What a paste is. Every cell goes through `set_cell` and nothing else does -
-- a write that went round it would be a change nothing recorded - and each is
-- pcalled, so one cell the column will not take does not stop the other
-- hundred and ninety-nine. A refused cell keeps the text and the reason,
-- exactly as a typed edit does.
---@param session table
---@param cells table[] { row, column (index), value }
---@return integer written How many reached the record.
---@return table[] refused { row, column, message }
M.paste = (session, cells) ->
  M.begin_group session

  written = 0
  refused = {}

  for cell in *cells
    continue unless type(cell) == "table"

    index = tonumber cell.row
    column = session.columns[tonumber(cell.column) or 0]
    continue unless index and column

    ok, took, err = pcall M.set_cell, session, index, column, tostring(cell.value or "")

    if ok and took
      written += 1
    else
      message = ok and tostring(err) or tostring(took)
      table.insert refused, { row: index, column: cell.column, :message }

  M.end_group session
  written, refused

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

  record session, { kind: "add", :index, :key }

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

  record session, { kind: "add", index: at, :key }

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

  record session, {
    kind: "delete", :index, :bytes, key: origin.key, :origin, :captured
  }

  true

-- ═══════════════════════════════════════════════════════════════════════════
-- Undo and redo
-- ═══════════════════════════════════════════════════════════════════════════

-- Declared before `invert_group`, which calls it. A local referenced above its
-- own assignment compiles to a global, and the failure would be an undo that
-- silently did nothing to a group.
invert = nil

--- Takes a whole group back, or leaves it exactly where it was.
--
-- LIFO within the group for the same reason the stack itself is LIFO: the
-- entry applied last names indices the ones before it have not moved.
--
-- All or nothing. A member that refuses - a row proxy that will not resolve,
-- a record the library has since shortened - puts the ones already turned back
-- where they were and reports why. The alternative is a stack entry describing
-- a change that is now only half in the file, and nothing afterwards could be
-- trusted to name the right row.
---@param session table
---@param entry table
---@return boolean ok, string|nil err
---@private
invert_group = (session, entry) ->
  moved = {}

  for position = #entry.entries, 1, -1
    member = entry.entries[position]
    ok, err = invert session, member

    unless ok
      for at = #moved, 1, -1
        invert session, moved[at]
      return false, err

    table.insert moved, member

  -- Reversed, so applying the group again replays it in the order it happened.
  entry.entries = [entry.entries[at] for at = #entry.entries, 1, -1]
  true

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
  -- Before the capture: a group has no key of its own, and each member takes
  -- and puts back its own row's entry in the change set.
  if entry.kind == "group"
    ok, err = invert_group session, entry
    session.stale = true if session.changed_only
    return ok, err

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

  -- The changed-rows view is a filter over the change set, and this just
  -- changed it.
  session.stale = true if session.changed_only
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
