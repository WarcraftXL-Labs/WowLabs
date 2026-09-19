--- What points at what, and how to say a row out loud.
--
-- Three features rest on this and it is written once for all of them: showing
-- `12 (Kalimdor)` instead of `12`, offering the rows of the referenced table
-- when one is being picked, and drawing the chain a table sits in.
--
-- **The links are in the schema, not in a list we keep.** A DBD column says
-- which table it refers to, so `AreaTable.ContinentID` knows it means `Map`
-- without anybody writing that down. The relations index lua-dbc can also read
-- is not shipped and is not needed: it holds the same answer, in a file.
--
-- **A row's name is a guess, and it is the right one.** A DBC has no column
-- marked "this is the name"; what it has is a localised column, or failing
-- that a string column, and in practice the first of either is the name. When
-- there is neither - a table of numbers - the id stands alone, which is honest
-- rather than wrong.
---@module modules.dbc.relations

Neutrino = require "neutrino"
library = require "modules.dbc.library"

dbc = require "dbc"
log = Neutrino.log

M = {}

-- name -> { ids, labels, by_id }, built on the first ask and kept.
--
-- Worth keeping: reading a whole string column off Spell's fifty thousand rows
-- is six milliseconds, and the same question is asked for every cell of every
-- redraw. Dropped when the workspace changes, because the files did.
cache = {}

--- Forgets every table's labels.
M.reset = -> cache = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Links
-- ═══════════════════════════════════════════════════════════════════════════

--- The tables a schema points at.
---@param schema table
---@return table[] links { column, table, key }
M.outbound = (schema) ->
  links = {}

  for field in *schema.fields
    continue unless field.foreign_table and field.foreign_table != ""
    continue if field.is_non_inline

    table.insert links, {
      column: field.name
      table: field.foreign_table
      key: field.foreign_column or "ID"
      count: field.count or 1
    }

  links

--- The tables that point at this one.
--
-- Answered by reading every schema, because nothing indexes it the other way
-- round. 246 schemas parse in about a sixth of a second and are cached in
-- lua-dbc for the rest of the process, so this is slow once.
---@param name string
---@param build string
---@return table[] links { table, column }
M.inbound = (name, build) ->
  wanted = name\lower!
  links = {}

  for entry in *library.tables!
    continue unless entry.editable
    continue if entry.name == name

    ok, schema = pcall dbc.Schemas.Get, entry.name, build
    continue unless ok and schema

    for field in *schema.fields
      continue if field.is_non_inline
      continue unless field.foreign_table
      continue unless field.foreign_table\lower! == wanted

      table.insert links, { table: entry.name, column: field.name }

  table.sort links, (a, b) ->
    return a.column < b.column if a.table == b.table
    a.table < b.table

  links

--- Every link between the tables this client ships.
--
-- The whole picture, for when no table is open: which tables refer to which,
-- and through what. Only the ones with a link at either end - a table nothing
-- points at and which points at nothing is a dot in the corner, and there are
-- dozens of them.
--
-- One pass over every definition, which is the same pass `inbound` makes; it
-- is a sixth of a second and the schemas stay parsed afterwards.
---@param build string
---@return table nodes { name, out, inn }
---@return table edges { from, to, column }
M.graph = (build) ->
  present = {}
  present[entry.name] = true for entry in *library.tables! when entry.editable

  edges = {}
  degree = {}

  for name in pairs present
    ok, schema = pcall dbc.Schemas.Get, name, build
    continue unless ok and schema

    for link in *M.outbound schema
      -- Only where both ends are here. A definition can name a table this
      -- client does not ship, and an edge to nothing is a lie in a picture.
      continue unless present[link.table]

      table.insert edges, { from: name, to: link.table, column: link.column }
      degree[name] = (degree[name] or 0) + 1
      degree[link.table] = (degree[link.table] or 0) + 1

  nodes = {}
  for name, count in pairs degree
    table.insert nodes, { :name, links: count }

  table.sort nodes, (a, b) -> a.name < b.name
  table.sort edges, (a, b) ->
    return a.column < b.column if a.from == b.from and a.to == b.to
    return a.to < b.to if a.from == b.from
    a.from < b.from

  nodes, edges

-- ═══════════════════════════════════════════════════════════════════════════
-- Naming a row
-- ═══════════════════════════════════════════════════════════════════════════

--- The column a row should be named by, or nil.
--
-- A localised column first: that is the name a player would see. Then a plain
-- string, which on the tables without localised text is the internal name -
-- `Map.Directory` is "Kalimdor", which is exactly what somebody picking a map
-- is looking for.
---@param schema table
---@return table|nil field
M.label_field = (schema) ->
  for field in *schema.fields
    continue if field.is_non_inline
    return field if field.kind == "loc" and field.count == 1

  for field in *schema.fields
    continue if field.is_non_inline
    return field if field.kind == "str" and field.count == 1

  nil

--- Every row of a table, by id, with something readable beside it.
--
-- Built in one pass and kept. Answers nil when the table cannot be opened,
-- which is ordinary: a definition can name a table the client does not ship.
---@param name string
---@param locale string The locale to read a localised name at.
---@return table|nil entries { ids, by_id, order }
M.rows = (name, locale) ->
  return cache[name] if cache[name]

  tbl = library.open name
  return nil unless tbl

  ok, schema = pcall tbl.GetSchema, tbl
  return nil unless ok and schema

  field = M.label_field schema
  count = tbl\Count!

  by_id = {}
  order = {}

  for index = 1, count
    got, row = pcall tbl.GetRowByIndex, tbl, index
    continue unless got

    read, id = pcall row.GetID, row
    continue unless read

    label = ""
    if field
      -- Whichever language the file is written in, not whichever the
      -- workspace is set to: this is a name to recognise a row by, and an
      -- empty one because the client is French helps nobody.
      if field.kind == "loc"
        for slot in *{ locale, "enUS", "frFR", "deDE", "esES", "ruRU", "koKR", "zhCN" }
          shown, value = pcall row.GetField, row, field.name, slot
          if shown and type(value) == "string" and value != ""
            label = value
            break
      else
        shown, value = pcall row.GetField, row, field.name
        label = value if shown and type(value) == "string"

    by_id[id] = label
    table.insert order, { :id, :label }

  entries = { :by_id, :order, field: field and field.name or nil, table: name }
  cache[name] = entries
  entries

--- How a referenced id reads.
--
-- `0` is how a DBC says "nothing", on nearly every column that refers to
-- anything, so it is named rather than looked up and missed.
---@param name string The referenced table.
---@param locale string
---@param id number
---@return string
M.describe = (name, locale, id) ->
  return "0" unless id and id != 0

  entries = M.rows name, locale
  return tostring id unless entries

  label = entries.by_id[id]
  return "#{id} (?)" unless label
  return tostring id if label == ""
  "#{id} (#{label})"

--- The rows of a table whose id or name matches, most useful first.
--
-- Capped: a column pointing at Spell has fifty thousand candidates and a list
-- of fifty thousand is not a list, it is the table again. The cap is a promise
-- that typing narrows it rather than that everything is on screen.
---@param name string
---@param locale string
---@param needle string
---@param limit? integer Defaults to 50.
---@return table[] matches { id, label, text }
M.search = (name, locale, needle, limit = 50) ->
  entries = M.rows name, locale
  return {} unless entries

  wanted = tostring(needle or "")\lower!
  found = {}

  for entry in *entries.order
    break if #found >= limit

    if wanted == ""
      table.insert found, entry
      continue

    -- By id first, because somebody who knows the number types the number.
    if (tostring entry.id) == wanted
      table.insert found, 1, entry
      continue

    haystack = "#{entry.id} #{entry.label}"\lower!
    table.insert found, entry if (haystack\find wanted, 1, true) != nil

  matches = {}
  for entry in *found
    text = entry.label == "" and tostring(entry.id) or
      "#{entry.id} (#{entry.label})"
    table.insert matches, { id: entry.id, label: entry.label, :text }

  matches

M
