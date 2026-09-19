-- The table editor: what it reads, what it writes, what it can take back, and
-- whether the Lua it generates means the same thing.
--
-- No browser. Everything here is the model underneath the grid, and a suite
-- that drove the page to reach it would be testing the page.
--
-- The tables are built with lua-dbc rather than copied from a client: a suite
-- that needed somebody's 3.3.5a install would pass on one machine.
--
--   Run from dist\:  ..\vendor\neutrino\deps\luajit\bin\luajit.exe tests\dbc.lua

Neutrino = require "neutrino"
t = require "harness"

fs = Neutrino.fs
json = Neutrino.json

dbc = require "dbc"
settings = require "settings"
workspace = require "workspace"

changes = require "modules.dbc.changes"
editor = require "modules.dbc.editor"
library = require "modules.dbc.library"

print "WowLabs: dbc"

BUILD = "3.3.5.12340"

-- ═══════════════════════════════════════════════════════════════════════════
-- A client folder to work in
-- ═══════════════════════════════════════════════════════════════════════════

base = ((os.getenv("TEMP") or os.getenv("TMP") or ".")\gsub "\\", "/")
temp = "#{base}/wowlabs-dbc-#{os.time!}-#{os.clock! * 1000000 % 100000}"
client = "#{temp}/client"
source = "#{client}/DBFilesClient"

fs.make_dir source
fs.make_dir "#{temp}/config"

-- Redirected, so the suite writes its own settings rather than the ones the
-- application is using.
settings.folder = -> "#{temp}/config"
workspace.reload!
library.reload!

--- Writes a table built in memory into the fixture folder.
---@param name string
---@param fill fun(tbl: table)
write_fixture = (name, fill) ->
  tbl = dbc.Create name, "WDBC", BUILD
  fill tbl
  tbl\Save "#{source}/#{name}.dbc"

write_fixture "ItemBagFamily", (tbl) ->
  for id = 1, 6
    row = tbl\Create id
    row\SetField "Name_lang", "Bag #{id}", "enUS"
    row\SetField "Name_lang", "Sac #{id}", "frFR"

write_fixture "WorldSafeLocs", (tbl) ->
  for id = 1, 5
    row = tbl\Create id
    row\SetField "Continent", id * 10
    row\SetField "Loc", id + 0.5, 1
    row\SetField "Loc", id + 0.25, 2
    row\SetField "Loc", id + 0.125, 3
    row\SetField "AreaName_lang", "Place #{id}", "enUS"

-- One of the 22 tables that keep no ID in their records: the row's ordinal is
-- its only identity, and everything that assumes otherwise breaks here first.
write_fixture "CharBaseInfo", (tbl) ->
  for ordinal = 1, 4
    row = tbl\InsertRow ordinal
    row\SetField "RaceID", ordinal
    row\SetField "ClassID", ordinal + 1

-- Long and wide, for the grid. Spell is the table this tool exists for and
-- the one that makes binding the whole thing impossible: 234 columns, and
-- tens of thousands of rows in a real client.
write_fixture "Spell", (tbl) ->
  for id = 1, 2000
    tbl\Create id

-- A second long one. Switching from a long table to a short one proves
-- nothing about putting the scrollbar back: the short table's content is
-- shorter than the scroll position, so the browser clamps it to the top on
-- its own and a reset that never ran looks exactly the same.
write_fixture "SpellIcon", (tbl) ->
  for id = 1, 2000
    tbl\Create id

-- What WorldSafeLocs.Continent refers to, so the links between tables can be
-- followed rather than only listed.
write_fixture "Map", (tbl) ->
  for id, name in ipairs { "Azeroth", "Kalimdor", "Outland" }
    row = tbl\Create id
    row\SetField "Directory", name
    row\SetField "MapName_lang", name, "enUS"

-- Not a table at all. A client folder has files in it that no definition
-- describes, and the list has to survive them.
fs.write "#{source}/NotATable.dbc", "rubbish"

opened, open_err = workspace.open client
t.check "the fixture workspace opens", opened != nil, tostring open_err

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Finding the tables"

entries = library.tables!
by_name = {}
by_name[entry.name] = entry for entry in *entries

t.check "the folder is listed", #entries == 7, "#{#entries} entries"
t.check "and in a stable order", entries[1].name == "CharBaseInfo",
  entries[1].name

t.check "a table with a definition for this build can be opened",
  by_name.ItemBagFamily and by_name.ItemBagFamily.editable == true

t.check "and one without says so rather than being hidden",
  by_name.NotATable != nil and by_name.NotATable.editable == false

t.check "opening a table that is not there is reported, not raised",
  (select 1, library.open "Nonexistent") == nil

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Columns"

bags = library.open "ItemBagFamily"
t.check "a real table opens", bags != nil

session = editor.session bags, "ItemBagFamily", "frFR", BUILD

t.check "one column per value in the record", #session.columns == 2,
  "#{#session.columns} columns"
t.check "the ID is marked as one", session.columns[1].is_id == true
t.check "a localised column carries the locale it edits",
  session.columns[2].extra == "frFR", tostring session.columns[2].extra
t.check "and its width is the whole block, not one slot",
  session.columns[2].width == 68, tostring session.columns[2].width

locs = editor.session (library.open "WorldSafeLocs"), "WorldSafeLocs", "enUS", BUILD
array_columns = [column for column in *locs.columns when column.field == "Loc"]

t.check "an inline array becomes one column per element",
  #array_columns == 3, "#{#array_columns} columns"
t.check "and each names its own element",
  array_columns[2].extra == 2 and array_columns[2].label == "Loc[2]",
  array_columns[2].label
t.check "and points at its own bytes",
  array_columns[2].offset == array_columns[1].offset + 4

ordinals = editor.session (library.open "CharBaseInfo"), "CharBaseInfo", "enUS", BUILD

t.check "a table with no inline ID says so", ordinals.has_id == false
t.check "and no column claims to be one",
  #[column for column in *ordinals.columns when column.is_id] == 0

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The window the grid binds"

window = editor.window session, 0, 0, 4, 8

t.check "only the rows asked for come back", #window.rows == 4,
  "#{#window.rows} rows"
t.check "and the whole size comes with them", window.total_rows == 6,
  "#{window.total_rows}"
t.check "a row knows its index and its ID",
  window.rows[2].index == 2 and window.rows[2].id == 2
t.check "a cell holds what is in the record",
  window.rows[2].cells[2].v == "Sac 2", window.rows[2].cells[2].v

-- The same index is the same row whichever window it arrives in, which is the
-- whole basis of asking for one block at a time.
far = editor.window session, 4, 0, 4, 8
t.check "a later window starts where it was asked to", far.row == 4,
  "#{far.row}"
t.check "and reads the same rows as a full one would",
  far.rows[1].cells[2].v == "Sac 5", far.rows[1].cells[2].v

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Writing a cell"

name_column = session.columns[2]

ok, err = editor.set_cell session, 3, name_column, "Sac de feu"
t.check "a write reports success", ok, tostring err
t.check "and the record holds it", (editor.read session, 3, name_column) == "Sac de feu"

-- The locale is passed on both sides, always. With it left out, a read
-- answers the first non-empty slot and a write goes to slot 0, so one edit
-- leaves two different names in one row and neither side notices.
english = bags\GetRowByIndex(3)\GetField "Name_lang", "enUS"
t.check "and the other locales are untouched", english == "Bag 3", english

t.check "the cell is marked as changed",
  (editor.window session, 2, 0, 1, 8).rows[1].cells[2].d == true

bad, bad_err = editor.set_cell locs, 1, (locs.columns[2]), "not a number"
t.check "a value the column cannot hold is refused", bad == false, tostring bad_err
t.check "and the record is left as it was",
  (editor.read locs, 1, locs.columns[2]) == "10"

refused = (editor.window locs, 0, 0, 1, 8).rows[1].cells[2]
t.check "but the edit is kept, with the reason",
  refused.v == "not a number" and refused.e != nil, tostring refused.e

-- Correcting it clears the refusal rather than leaving it stuck.
editor.set_cell locs, 1, locs.columns[2], "11"
corrected = (editor.window locs, 0, 0, 1, 8).rows[1].cells[2]
t.check "and a good value afterwards clears it",
  corrected.v == "11" and corrected.e == nil, tostring corrected.e

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Undo and redo"

editor.set_cell session, 3, name_column, "Sac de glace"
t.check "there is something to take back", editor.can_undo session

editor.undo session
t.check "one step back is the value before it",
  (editor.read session, 3, name_column) == "Sac de feu",
  editor.read session, 3, name_column

editor.undo session
t.check "and another is what the file had",
  (editor.read session, 3, name_column) == "Sac 3",
  editor.read session, 3, name_column

t.check "with nothing left to take back", editor.can_undo(session) == false
t.check "and two things to put back", editor.can_redo session

editor.redo session
t.check "redo puts the first one back",
  (editor.read session, 3, name_column) == "Sac de feu"

editor.redo session
t.check "and the second", (editor.read session, 3, name_column) == "Sac de glace"

-- Back to where the section started, so what follows is not reading a value
-- three edits deep.
editor.undo session
editor.undo session

t.section "Undo across the row operations"

before_rows = bags\Count!
added = editor.add_row session
t.check "a row can be added where there is an ID", added == before_rows + 1,
  tostring added
t.check "and it gets an ID of its own",
  (editor.id_at session, added) == 7, tostring editor.id_at session, added

editor.set_cell session, added, name_column, "Sac neuf"

copy_index = editor.duplicate_row session, 2
t.check "a row can be duplicated", copy_index == bags\Count!
t.check "and carries the bytes it was copied from",
  (editor.read session, copy_index, name_column) == "Sac 2"

deleted, delete_err = editor.delete_row session, 1
t.check "a row can be deleted", deleted, tostring delete_err
t.check "and the table is one shorter", bags\Count! == before_rows + 1,
  tostring bags\Count!

-- A structural edit invalidates every proxy at or after it. Nothing here holds
-- one, so reading straight after a deletion is reading the row that moved up.
t.check "the row after it moved up", (editor.read session, 1, name_column) == "Sac 2",
  editor.read session, 1, name_column

editor.undo session
t.check "undoing the deletion puts it back where it was",
  bags\Count! == before_rows + 2 and
    (editor.read session, 1, name_column) == "Sac 1",
  editor.read session, 1, name_column

editor.undo session
t.check "undoing the duplicate takes it away again",
  bags\Count! == before_rows + 1, tostring bags\Count!

editor.undo session
editor.undo session
t.check "and undoing the addition leaves the table as it was",
  bags\Count! == before_rows, tostring bags\Count!
t.check "with nothing left on the stack", editor.can_undo(session) == false

-- ═══════════════════════════════════════════════════════════════════════════

t.section "What the change set says"

t.check "a session that was undone to the start has nothing to say",
  changes.count(session.set) == 0, "#{changes.count session.set} rows"

-- A cell edited five times is one write. The panel is meant to say what the
-- file will become, not what the keyboard did.
for attempt = 1, 5
  editor.set_cell session, 2, name_column, "Sac numero #{attempt}"

t.check "five edits of one cell are one changed row",
  changes.count(session.set) == 1, "#{changes.count session.set} rows"

script = changes.script session.set
_, writes = script\gsub "SetField", ""
t.check "and one write", writes == 1, "#{writes} writes"
t.check "carrying the last value",
  (script\match "Sac numero 5") != nil, script

-- A cell put back to where it started is not a change.
editor.set_cell session, 2, name_column, "Sac 2"
t.check "a cell edited back to its original value says nothing",
  changes.count(session.set) == 0, changes.script session.set

-- A row added and then deleted is not a change either.
fresh = editor.add_row session
editor.set_cell session, fresh, name_column, "Temporary"
editor.delete_row session, fresh
t.check "a row added and then deleted says nothing",
  changes.count(session.set) == 0, changes.script session.set

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The emitted script"

-- Back to a clean session for the shape checks.
clean = editor.session (library.open "ItemBagFamily"), "ItemBagFamily", "frFR", BUILD

-- Every DBC string is allowed a quote, a backslash and a newline, and a
-- generator that formats one by hand gets all three wrong.
AWKWARD = 'a "quoted" \\ back\nslash'
editor.set_cell clean, 1, clean.columns[2], AWKWARD

emitted = editor.script clean

t.check "a row is named by its ID, not its index",
  (emitted\match "GetRowById%(1%)") != nil, emitted
t.check "and a localised write names its locale",
  (emitted\match '"Name_lang", .-, "frFR"') != nil, emitted
t.check "no timestamp, so two exports of the same edits are the same file",
  emitted == editor.script clean

loaded, load_err = loadstring emitted
t.check "the script is valid Lua", loaded != nil, tostring load_err

-- The awkward string has to survive being written as a literal and read back,
-- which is the whole of what %q is for and the whole of what hand-rolled
-- quoting gets wrong.
written = emitted\match 'SetField%("Name_lang", (.*), "frFR"%)'
extracted = written and loadstring "return " .. written
t.check "a quote, a backslash and a newline survive the literal",
  extracted != nil and extracted! == AWKWARD, tostring written

ordinal_session = editor.session (library.open "CharBaseInfo"), "CharBaseInfo", "enUS", BUILD
editor.set_cell ordinal_session, 2, ordinal_session.columns[1], "9"
ordinal_script = editor.script ordinal_session

t.check "a table with no ID is addressed by position instead",
  (ordinal_script\match "GetRowByIndex%(2%)") != nil, ordinal_script
t.check "and the script says so at the top",
  (ordinal_script\match "position") != nil, ordinal_script

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Replaying it onto a client"

-- The only check that settles whether the export means what the editor did:
-- make the edits, save the DBC, run the generated script over a copy of the
-- same source file with LuaJIT, and compare the two results byte for byte.
--
-- Every kind of change at once, including the ones the coalescing rules are
-- about: a cell written three times, a cell put back where it started, a
-- duplicate taken after a deletion moved the row it copies, and a new row.

lfs = require "lfs"

-- Fresh, because the tables above have been edited and the file on disk has
-- not. Dropping the workspace is what makes the next open read the disk.
library.close!

replay = editor.session (library.open "WorldSafeLocs"), "WorldSafeLocs", "enUS", BUILD
continent = replay.columns[2]
height = replay.columns[4]
place = replay.columns[6]

t.check "the scenario's columns are the ones it means",
  continent.field == "Continent" and height.label == "Loc[2]" and
    place.field == "AreaName_lang",
  "#{continent.field}, #{height.label}, #{place.field}"

-- Three writes to one cell.
editor.set_cell replay, 2, continent, "97"
editor.set_cell replay, 2, continent, "98"
editor.set_cell replay, 2, continent, "99"

-- Out and back again.
was = editor.read replay, 3, height
editor.set_cell replay, 3, height, "7.5"
editor.set_cell replay, 3, height, was

editor.set_cell replay, 4, place, AWKWARD

-- A deletion first, so that the duplicate below names a row whose index has
-- already moved. The script has to emit the index the row had in the file it
-- will be replayed onto, not the one it has here.
editor.delete_row replay, 1
moved = editor.duplicate_row replay, 1
editor.set_cell replay, moved, continent, "123"

added_row = editor.add_row replay
editor.set_cell replay, added_row, continent, "55"

t.check "the change set holds one row per row touched",
  changes.count(replay.set) == 5, "#{changes.count replay.set} rows"

-- Saved the way the tool saves: through a temporary file and a move.
fs.make_dir "#{temp}/editor"
written, save_err = editor.save replay, "#{temp}/editor/WorldSafeLocs.dbc"
t.check "the table saves as a DBC", written != nil, tostring save_err
t.check "and nothing is left behind from the write",
  not fs.is_file "#{temp}/editor/WorldSafeLocs.dbc.writing"

-- The script runs against its own copy of the file the session opened, from
-- its own directory, exactly as it stands.
fs.make_dir "#{temp}/replay/DBFilesClient"
fs.copy "#{source}/WorldSafeLocs.dbc", "#{temp}/replay/DBFilesClient/WorldSafeLocs.dbc"

generated = editor.script replay
chunk, chunk_err = loadstring generated
t.check "the generated script compiles", chunk != nil, tostring chunk_err

here = lfs.currentdir!
lfs.chdir "#{temp}/replay"
ran, run_err = pcall chunk
lfs.chdir here

t.check "and runs without raising", ran, tostring run_err

produced = fs.read "#{temp}/replay/output/WorldSafeLocs.dbc"
expected = fs.read "#{temp}/editor/WorldSafeLocs.dbc"

t.check "it wrote a file", produced != nil and #produced > 0,
  produced and "#{#produced} bytes" or "nothing"

t.check "and it is byte for byte what the editor saved",
  produced == expected,
  "#{produced and #produced or 0} bytes against #{expected and #expected or 0}"

-- What differs, when something does. Comparing the bytes says whether they
-- agree; comparing the cells says where they do not.
compare = (left_path, right_path) ->
  left = editor.session (dbc.Open left_path, "WorldSafeLocs", BUILD),
    "WorldSafeLocs", "enUS", BUILD
  right = editor.session (dbc.Open right_path, "WorldSafeLocs", BUILD),
    "WorldSafeLocs", "enUS", BUILD

  if left.table\Count! != right.table\Count!
    return "row counts differ: #{left.table\Count!} and #{right.table\Count!}"

  for index = 1, left.table\Count!
    for column in *left.columns
      mine = editor.read left, index, column
      theirs = editor.read right, index, column
      if mine != theirs
        return "row #{index} #{column.label}: #{mine} against #{theirs}"

  nil

difference = compare "#{temp}/editor/WorldSafeLocs.dbc",
  "#{temp}/replay/output/WorldSafeLocs.dbc"

t.check "and every cell in it reads the same", difference == nil,
  tostring difference

-- ═══════════════════════════════════════════════════════════════════════════
-- In a window
--
-- Everything above is the model. What is left is whether the grid that binds
-- one visible block at a time draws the right rows in the right places, and
-- whether an edit typed into a cell reaches the record - neither of which any
-- amount of Lua can settle.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The search language"

-- Against a made-up row, so what is being tested is the language rather than
-- the records underneath it.
query = require "modules.dbc.query"
row = { Name: "Fireball", Level: 9, Icon: 0 }

matches = (text) ->
  predicate, err = query.compile text
  return nil, err unless predicate
  predicate (name, needle) ->
    if name == nil
      found = false
      for _, value in pairs row
        continue unless type(value) == "string"
        found = true if (value\lower!\find needle\lower!, 1, true) != nil
      return found
    row[name]

t.check "a comparison reads the column it names", (matches "Level > 5") == true
t.check "and compares numbers as numbers", (matches "Level > 10") == false

-- The one that bit: a quoted literal is text, and "9" > "10" is true where
-- 9 > 10 is not. Getting this wrong made every quoted value a number.
t.check "quoting asks for a text comparison", (matches "Level > '10'") == true
t.check "and leaving it off asks for a number", (matches "Level > 10") == false

t.check "LIKE takes SQL's wildcards", (matches "Name LIKE 'Fire%'") == true
t.check "and anchors what it is given", (matches "Name LIKE 'ball'") == false
t.check "_ stands for one character", (matches "Name LIKE 'F_reball'") == true
t.check "CONTAINS looks anywhere", (matches "Name CONTAINS 'reba'") == true
t.check "text comparisons ignore case", (matches "Name = FIREBALL") == true

t.check "AND wants both", (matches "Level = 9 AND Icon = 0") == true
t.check "OR wants either", (matches "Level = 99 OR Icon = 0") == true
t.check "NOT turns one round", (matches "NOT (Level = 9)") == false
t.check "and brackets group", (matches "(Level = 99 OR Icon = 0) AND Name CONTAINS 'fire'") == true

t.check "one bare word searches the text columns", (matches "ball") == true
t.check "several are one phrase, not a syntax error",
  (matches "Fireball") == true and (matches "Fire ball") == false

t.check "a column that is not there matches nothing",
  (matches "Missing = 1") == false

for bad_text in *{ "Name =", "Name LIKE 'x", "(Level > 1", "= 3" }
  found, why = matches bad_text
  t.check "#{bad_text} is refused rather than guessed", found == nil and why != nil,
    tostring why

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Searching"

-- Its own session: a query, a sort and a width all live on one, and the
-- sections above would be reading a filtered table if this shared theirs.
finder = editor.session (library.open "ItemBagFamily"), "ItemBagFamily", "frFR", BUILD

t.check "with no query the grid pages over every row",
  editor.visible(finder) == 6, tostring editor.visible finder
t.check "and position is index", (editor.at finder, 4) == 4

ok, err = editor.set_query finder, "ID > 3"
t.check "a comparison keeps the rows that match", ok and editor.visible(finder) == 3,
  "#{tostring ok} #{tostring err} #{editor.visible finder}"
t.check "and position now maps to the row it kept",
  (editor.at finder, 1) == 4, tostring editor.at finder, 1

editor.set_query finder, "Name_lang CONTAINS 'Sac 2'"
t.check "a text operator reads the column it names",
  editor.visible(finder) == 1 and (editor.at finder, 1) == 2,
  "#{editor.visible finder} rows"

-- The whole point of the bare form: type what you are looking for.
editor.set_query finder, "Sac 5"
t.check "a bare term searches the text columns",
  editor.visible(finder) == 1 and (editor.at finder, 1) == 5,
  "#{editor.visible finder} rows"

t.check "and finds nothing when there is nothing",
  (editor.set_query finder, "Sac 99") and editor.visible(finder) == 0,
  tostring editor.visible finder

editor.set_query finder, "ID > 3"
bad, why = editor.set_query finder, "ID >"
t.check "a query that will not parse is refused", bad == false and why != nil,
  tostring why
t.check "and leaves the rows that were there alone",
  editor.visible(finder) == 3, tostring editor.visible finder

editor.set_query finder, ""
t.check "an empty query puts every row back", editor.visible(finder) == 6,
  tostring editor.visible finder

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Sorting"

names = finder.columns[2]
by_name = 2

editor.set_sort finder, by_name
t.check "ascending puts the first name first",
  (editor.read finder, (editor.at finder, 1), names) == "Sac 1",
  editor.read finder, (editor.at finder, 1), names

sort = editor.set_sort finder, by_name
t.check "the same column again turns it round", sort.descending == true
t.check "and the last name is now first",
  (editor.read finder, (editor.at finder, 1), names) == "Sac 6",
  editor.read finder, (editor.at finder, 1), names

t.check "a third time puts the file's own order back",
  (editor.set_sort finder, by_name) == nil and (editor.at finder, 1) == 1

-- Sorting must not move a row, only where it is drawn: everything recorded
-- about an edit names the index, and a sort that renumbered rows would make
-- every change in the set point somewhere else.
editor.set_sort finder, by_name
window_sorted = editor.window finder, 0, 0, 6, 4
t.check "a sorted window still reports each row's real index",
  window_sorted.rows[1].index == 1 and window_sorted.rows[6].index == 6,
  "#{window_sorted.rows[1].index}..#{window_sorted.rows[6].index}"
editor.set_sort finder, nil

-- A filter and a sort are one order, not two that fight.
editor.set_query finder, "ID > 3"
editor.set_sort finder, by_name
t.check "a sort applies to what the search left",
  editor.visible(finder) == 3 and (editor.at finder, 1) == 4,
  "#{editor.visible finder} rows, first #{tostring editor.at finder, 1}"
editor.set_sort finder, nil
editor.set_query finder, ""

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Column widths"

t.check "a column starts at the default width",
  (editor.width_of finder, 1) == editor.DEFAULT_WIDTH

editor.set_width finder, 1, 300
t.check "and keeps what it is dragged to", (editor.width_of finder, 1) == 300

editor.set_width finder, 1, 4
t.check "dragged to nothing it stays grabbable",
  (editor.width_of finder, 1) == 48, tostring editor.width_of finder, 1

editor.set_width finder, 1, 99999
t.check "and cannot be dragged past what fits",
  (editor.width_of finder, 1) == 900, tostring editor.width_of finder, 1

editor.set_width finder, 1, 200
sized = editor.window finder, 0, 0, 2, 4

t.check "the window carries each column's width", sized.columns[1].w == 200,
  tostring sized.columns[1].w
t.check "and where every column starts",
  sized.offsets[1] == 0 and sized.offsets[2] == 200,
  "#{tostring sized.offsets[1]}, #{tostring sized.offsets[2]}"
t.check "and how wide the whole table is",
  sized.total_width == 200 + editor.DEFAULT_WIDTH, tostring sized.total_width

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Every language at once"

slots = editor.populated_locales bags, bags\GetSchema!
t.check "the languages a file carries are found",
  (table.concat slots, ",") == "enUS,frFR", table.concat slots, ","

spread = editor.session (library.open "ItemBagFamily"), "ItemBagFamily", "frFR",
  BUILD, "present"
localised = [column for column in *spread.columns when column.field == "Name_lang"]

t.check "each one gets a column", #localised == 2, "#{#localised} columns"
t.check "and reads the slot it names",
  (editor.read spread, 1, localised[1]) == "Bag 1" and
  (editor.read spread, 1, localised[2]) == "Sac 1",
  "#{editor.read spread, 1, localised[1]} / #{editor.read spread, 1, localised[2]}"

-- Two columns over one field, so a snapshot has to be the whole block or
-- undoing one language would write over the other.
t.check "and both cover the whole localised block",
  localised[1].width == 68 and localised[2].width == 68

t.check "a language the file has nothing in gets no column",
  #[column for column in *spread.columns when column.extra == "deDE"] == 0

-- The one thing "the languages present" cannot do: there is no column to type
-- into for a language the file does not carry yet.
every = editor.session (library.open "ItemBagFamily"), "ItemBagFamily", "frFR",
  BUILD, "all"
all_localised = [column for column in *every.columns when column.field == "Name_lang"]

t.check "asking for all of them gives a column per slot",
  #all_localised == #editor.LOCALES, "#{#all_localised} columns"
t.check "including one the file has nothing in",
  #[column for column in *every.columns when column.extra == "deDE"] == 1

t.check "and the workspace's own locale alone is still a choice",
  #[column for column in *session.columns when column.field == "Name_lang"] == 1

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Naming a localised column in a filter"

-- Its label carries a space, and the filter splits on whitespace - so the two
-- spellings that survive tokenising both have to reach the same column.
editor.set_query spread, "'Name_lang frFR' CONTAINS 'Sac 3'"
t.check "quoted, it finds the row",
  editor.visible(spread) == 1 and (editor.at spread, 1) == 3,
  "#{editor.visible spread} rows"

editor.set_query spread, "Name_lang.enUS CONTAINS 'Bag 4'"
t.check "dotted, it finds the row in the other language",
  editor.visible(spread) == 1 and (editor.at spread, 1) == 4,
  "#{editor.visible spread} rows"

-- The dot has to pick the language, not ignore it.
editor.set_query spread, "Name_lang.enUS CONTAINS 'Sac 4'"
t.check "and does not answer for a language it was not given",
  editor.visible(spread) == 0, "#{editor.visible spread} rows"

editor.set_query spread, ""

-- ═══════════════════════════════════════════════════════════════════════════

t.section "What points at what"

relations = require "modules.dbc.relations"

locs_schema = locs.schema
links = relations.outbound locs_schema

t.check "a column that refers to another table is found",
  #[link for link in *links when link.table == "Map"] == 1,
  "#{#links} links"

map_schema = (library.open "Map")\GetSchema!
t.check "a row is named by its localised column",
  (relations.label_field map_schema).name == "MapName_lang",
  (relations.label_field map_schema).name

-- CharBaseInfo is two numbers and nothing else, which is what a table with
-- no name to show looks like. Spell has Name_lang and would have one.
t.check "a table of numbers has nothing to name a row by",
  (relations.label_field (library.open "CharBaseInfo")\GetSchema!) == nil

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Saying a referenced row out loud"

t.check "an id reads as itself and the row it points at",
  (relations.describe "Map", "enUS", 2) == "2 (Kalimdor)",
  relations.describe "Map", "enUS", 2

-- Nearly every column that refers to anything uses 0 for "nothing", so it is
-- named rather than looked up and missed.
t.check "zero means nothing rather than a missing row",
  (relations.describe "Map", "enUS", 0) == "0",
  relations.describe "Map", "enUS", 0

t.check "an id that is not there says so rather than inventing one",
  (relations.describe "Map", "enUS", 99) == "99 (?)",
  relations.describe "Map", "enUS", 99

t.check "a table that cannot be read falls back to the number",
  (relations.describe "Nonexistent", "enUS", 4) == "4",
  relations.describe "Nonexistent", "enUS", 4

found = relations.search "Map", "enUS", "kalim"
t.check "searching by name narrows the list", #found == 1 and found[1].id == 2,
  "#{#found} matches"
t.check "and each match reads the way the cell will",
  found[1].text == "2 (Kalimdor)", found[1].text

by_number = relations.search "Map", "enUS", "3"
t.check "searching by id puts the exact one first",
  by_number[1].id == 3, tostring by_number[1] and by_number[1].id

t.check "an empty search offers everything there is",
  #(relations.search "Map", "enUS", "") == 3

t.check "and a cap is a cap", #(relations.search "Map", "enUS", "", 2) == 2

-- Reading every definition is the only way round: nothing indexes the links
-- backwards, so this is the slow one and it is slow once.
back = relations.inbound "Map", BUILD
t.check "the tables pointing at one are found",
  #[link for link in *back when link.table == "WorldSafeLocs"] == 1,
  "#{#back} referrers"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The whole picture"

graph_nodes, graph_edges = relations.graph BUILD
named = {}
named[node.name] = node.links for node in *graph_nodes

t.check "both ends of a link are nodes",
  named.WorldSafeLocs != nil and named.Map != nil,
  table.concat [node.name for node in *graph_nodes], ", "

continent_edges = 0
for edge in *graph_edges
  if edge.from == "WorldSafeLocs" and edge.to == "Map" and edge.column == "Continent"
    continent_edges += 1

t.check "and the link between them is an edge", continent_edges == 1,
  "#{continent_edges} of #{#graph_edges} edges"

-- A link to a table the client does not have is a line to nothing. The
-- definitions name plenty of those; the picture should not.
t.check "a link to a table this client does not ship is left out",
  #[edge for edge in *graph_edges when named[edge.to] == nil] == 0

t.check "and a table with no links at all is not a dot in the corner",
  named.ItemBagFamily == nil

t.check "a node counts what touches it", named.Map >= 1, tostring named.Map

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Showing names in the grid"

readable = editor.session (library.open "WorldSafeLocs"), "WorldSafeLocs",
  "enUS", BUILD
continent = nil
continent = column for column in *readable.columns when column.field == "Continent"

t.check "a foreign key column knows what it refers to",
  continent.foreign == "Map", tostring continent.foreign

-- Row 1's Continent is 10 in the fixture, which is no map at all - so this
-- also checks the fallback rather than only the happy path.
editor.set_cell readable, 1, continent, "2"
t.check "with names off a cell is its number",
  (editor.read readable, 1, continent) == "2",
  editor.read readable, 1, continent

readable.readable = true
t.check "and with them on it is the row it points at",
  (editor.read readable, 1, continent) == "2 (Kalimdor)",
  editor.read readable, 1, continent

-- What comes out of the cell has to go back into it, or every cell touched
-- while names are on would have to be retyped from scratch.
value, err = editor.parse continent, "3 (Outland)"
t.check "and what it shows can be typed straight back", value == 3, tostring err

plain, plain_err = editor.parse continent, "3"
t.check "as can the number on its own", plain == 3, tostring plain_err

t.load_native!

-- The locale the tool edits comes from the workspace, so this is also what
-- puts frFR in front of the grid below.
workspace.set "locale", "frFR"

require "modules.dbc"

app = Neutrino.App {
  cache_path: "#{temp}/cache"
  resources_path: Neutrino.paths.bin
  locales_path: "#{Neutrino.paths.bin}/locales"
  subprocess_path: "#{Neutrino.paths.bin}/neutrinocef_helper.exe"
  quit_on_last_window: false
}

server = app\server!
server\static "/assets", "static"

shell = require "shell.window"
shell.mount app, server

t.expect_completion!

app\on "ready", ->
  t.deadline app

  t.task "dbc in a window", ->
    t.wait_until -> shell.window != nil
    window = shell.window

    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    t.wait_until -> window\is_visible!

    t.section "The table list"

    t.check "the tables are there on the first paint",
      (window\eval "nui.get('dbc_tables').length") == 7,
      tostring window\eval "nui.get('dbc_tables').length"

    -- The list is the page's own filter over the store, so the entries
    -- rendered are the ones that matched rather than the ones Lua sent.
    window\exec_js "nui.set('dbc_filter', 'Bag')"
    t.check "the filter narrows it",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-table').length") == 1)

    window\exec_js "nui.set('dbc_filter', '')"
    t.check "and clearing it brings the rest back",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-table').length") == 7)

    -- A file no definition describes is shown and cannot be clicked. Hiding
    -- it would mean somebody looking for it concluded it was not there.
    t.check "a table with no definition for this build is offered but refused",
      (window\eval "[...document.querySelectorAll('.dbc-table')]
        .filter(el => el.hasAttribute('data-disabled'))
        .map(el => el.innerText.trim()).join(',')") == "NotATable",
      window\eval "[...document.querySelectorAll('.dbc-table')]
        .filter(el => el.hasAttribute('data-disabled'))
        .map(el => el.innerText.trim()).join(',')"

    t.section "Reading before keeping"

    -- With two clicks to keep, one click still opens the table - you can read
    -- it, sort it, search it - but into a tab the next one replaces. Nothing
    -- about that is visible from the store alone, so this drives the list.
    library.set "open_on", "double"
    window\exec_js "neutrino.invoke('dbc:tables')"

    -- The setting reaches the page through an invoke and a store push, so it
    -- is not there the instant Lua wrote it. Clicking before it arrives tests
    -- the behaviour that is being changed away from.
    t.check "the list is told that opening now takes two clicks",
      (t.wait_until -> (window\eval "nui.get('dbc_open_on')") == "double"),
      tostring window\eval "nui.get('dbc_open_on')"

    tab_titles = -> window\eval "nui.get('tabs').map(t => t.id).join(',')"
    click = (name) -> window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === '#{name}').click()"

    click "ItemBagFamily"
    t.check "a single click opens the table",
      (t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"),
      tostring window\eval "nui.get('dbc_open')"

    t.check "into a tab marked as being read",
      (window\eval "nui.get('tabs').some(t => t.id === 'dbc:ItemBagFamily' && t.preview)") == true,
      tab_titles!

    click "WorldSafeLocs"
    t.check "reading another one replaces it rather than stacking up",
      (t.wait_until -> (tab_titles!) == "dbc:WorldSafeLocs"), tab_titles!

    -- Double click keeps it. So does an edit, which is the other moment a
    -- table stops being something you glanced at.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily')
      .dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))"

    bags_kept = -> window\eval "nui.get('tabs').some(t => t.id === 'dbc:ItemBagFamily' && !t.preview)"
    none_previewed = -> window\eval "nui.get('tabs').every(t => !t.preview)"

    t.check "a double click gives it a tab of its own",
      (t.wait_until -> bags_kept! == true), tab_titles!

    click "WorldSafeLocs"
    t.check "and a kept tab is no longer replaced by the next read",
      (t.wait_until -> (tab_titles!)\match("dbc:ItemBagFamily") != nil), tab_titles!

    window\exec_js "document.querySelector('.dbc-cell').value = '12';
      document.querySelector('.dbc-cell').dispatchEvent(new Event('change'))"

    t.check "editing a read-only tab keeps it too",
      (t.wait_until -> none_previewed! == true), tab_titles!

    -- Back to opening on one click for everything that follows.
    library.set "open_on", "single"
    window\exec_js "neutrino.invoke('dbc:tables')"
    window\exec_js "nui.get('tabs').forEach(t => neutrino.invoke('shell:close-tab', t.id))"
    t.wait_until -> (window\eval "nui.get('tabs').length") == 0

    -- ═══════════════════════════════════════════════════════════════════════

    t.section "Opening one"

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"

    t.check "clicking it opens the table",
      (t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"),
      tostring window\eval "nui.get('dbc_open')"

    t.check "and it arrives as a tab of its own",
      (window\eval "nui.get('active_tab')") == "dbc:ItemBagFamily"

    t.check "the grid draws a row for each one in the window",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-cell').length") > 0),
      "no cells"

    -- On screen, not merely in the document: the tool's work area is shown by
    -- which tab is active, and a region left hidden would still be counted.
    t.check "and it is the region on screen",
      (window\eval "document.querySelector('.dbc-cell').getClientRects().length") > 0

    t.check "with the table list beside it",
      (window\eval "document.querySelector('.dbc-table').getClientRects().length") > 0

    -- Every language the file carries gets a column of its own by default, so
    -- the strip says that rather than naming one slot. Silence either way is
    -- how a row ends up holding two different names.
    t.check "and the strip saying every language is on screen",
      (window\eval "[...document.querySelectorAll('span')]
        .some(el => el.getClientRects().length > 0 &&
          el.textContent.trim() === 'All languages')") == true

    -- The whole table sizes the scroller; only what is visible is drawn.
    t.check "the scroller is the size of the whole table",
      (window\eval "document.querySelector('.dbc-scroller').firstElementChild
        .getBoundingClientRect().height") == 6 * 22 + 26,
      tostring window\eval "document.querySelector('.dbc-scroller')
        .firstElementChild.getBoundingClientRect().height"

    headers = -> window\eval "[...document.querySelectorAll('.dbc-head')]
      .map(el => el.innerText.replace(/\\s+/g, ' ').trim()).join('|')"

    t.check "the header names the columns and their kinds",
      (headers!)\match("Name_lang enUS loc enUS") != nil, headers!

    -- The second language, which is the point of showing them all: a file
    -- translated into four and showing one looks like it lost three.
    t.check "and one column per language the file carries",
      (headers!)\match("Name_lang frFR loc frFR") != nil, headers!

    -- "New row" is offered where a new row can be told apart from its
    -- neighbours, and nowhere else.
    on_rail = (title) -> window\eval "[...document.querySelectorAll('.action-button')]
      .filter(el => el.innerText.trim() === '#{title}' &&
        el.getClientRects().length > 0).length"

    t.check "the rail offers a new row on a table with an ID",
      (on_rail "New row") == 1, tostring on_rail "New row"

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'CharBaseInfo').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "CharBaseInfo"

    t.check "and not on one that keeps none",
      (t.wait_until -> (on_rail "New row") == 0), tostring on_rail "New row"

    t.check "though duplicating a row is offered there too",
      (on_rail "Duplicate row") == 1, tostring on_rail "Duplicate row"

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"

    t.section "Editing a cell"

    -- Typed and committed the way a person commits: the value goes in, and
    -- the change event fires on blur.
    window\exec_js "
      const cell = document.querySelectorAll('.dbc-cell')[1]
      cell.focus()
      cell.value = 'Sac modifie'
      cell.dispatchEvent(new Event('change', { bubbles: true }))"

    t.check "the edit reaches the record",
      (t.wait_until ->
        (window\eval "nui.get('dbc_grid').rows[0].cells[1].v") == "Sac modifie"),
      tostring window\eval "nui.get('dbc_grid').rows[0].cells[1].v"

    t.check "and the cell is marked as changed",
      (t.wait_until -> (window\eval "[...document.querySelectorAll('.dbc-cell')]
        .filter(el => el.classList.contains('is-dirty')).length") == 1)

    t.check "the shell is told there is something to undo",
      (window\eval "nui.get('can_undo')") == true
    t.check "and something unsaved", (window\eval "nui.get('dirty')") == true

    t.section "The Lua panel"

    t.check "it is closed to start with",
      (window\eval "document.querySelector('.dbc-preview').hidden") == true

    window\exec_js "document.querySelector('.dbc-caret').parentElement.click()"

    t.check "clicking the bar opens it",
      (t.wait_until ->
        (window\eval "document.querySelector('.dbc-preview').hidden") == false)

    t.check "and it holds the script for what was just done",
      (t.wait_until ->
        (window\eval "document.querySelector('.dbc-preview').innerText")\match("Sac modifie") != nil),
      window\eval "document.querySelector('.dbc-preview').innerText"

    t.section "A long, wide table"

    -- Spell is the case the grid is built for: more rows than anything can
    -- draw and more columns than fit on a screen.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'Spell').click()"

    t.check "it opens", (t.wait_until -> (window\eval "nui.get('dbc_open')") == "Spell"),
      tostring window\eval "nui.get('dbc_open')"

    -- 170 cells to a Spell record: 234 words, of which four sets of seventeen
    -- are the localised columns, each of them one cell at one locale.
    t.check "with a column for every value in a record",
      (window\eval "nui.get('dbc_grid').total_cols") == 170,
      tostring window\eval "nui.get('dbc_grid').total_cols"

    t.check "and the scroller is the size of all two thousand rows",
      (window\eval "Math.round(document.querySelector('.dbc-scroller')
        .firstElementChild.getBoundingClientRect().height)") == 2000 * 22 + 26,
      tostring window\eval "Math.round(document.querySelector('.dbc-scroller')
        .firstElementChild.getBoundingClientRect().height)"

    -- Opening asks the page to put the grid back at the top, one frame
    -- later. Scrolling before that has happened is a scroll the reset then
    -- undoes - so wait for it, rather than racing it.
    t.wait_until -> (window\eval "document.querySelector('.dbc-scroller').scrollTop") == 0

    -- The point of the whole arrangement: what is drawn is bounded by the
    -- window, not by the table. 2000 rows of 234 columns is 468,000 cells.
    drawn = window\eval "document.querySelectorAll('.dbc-cell').length"
    t.check "but only a window of cells is drawn", drawn > 0 and drawn <= 64 * 16,
      "#{drawn} cells"

    t.check "and a window of headers with them",
      (window\eval "document.querySelectorAll('.dbc-head').length") <= 16,
      tostring window\eval "document.querySelectorAll('.dbc-head').length"

    window\exec_js "document.querySelector('.dbc-scroller').scrollTop = 1000 * 22"

    t.check "scrolling down asks for the rows that came into view",
      (t.wait_until -> (window\eval "nui.get('dbc_grid').row") == 1000 - 6),
      tostring window\eval "nui.get('dbc_grid').row"

    t.check "which are the rows it draws",
      (window\eval "nui.get('dbc_grid').rows[0].index") == 995,
      tostring window\eval "nui.get('dbc_grid').rows[0].index"

    t.check "and the block is put where those rows belong",
      (window\eval "document.querySelector('.dbc-cell')
        .getBoundingClientRect().top") > 0

    t.check "with no more of it drawn than before",
      (window\eval "document.querySelectorAll('.dbc-cell').length") <= 64 * 16

    window\exec_js "document.querySelector('.dbc-scroller').scrollLeft = 100 * 150"

    t.check "scrolling sideways asks for those columns",
      (t.wait_until -> (window\eval "nui.get('dbc_grid').col") == 99),
      tostring window\eval "nui.get('dbc_grid').col"

    t.check "and the header follows them",
      (window\eval "document.querySelector('.dbc-head').innerText")\match("%S") != nil,
      window\eval "document.querySelector('.dbc-head').innerText"

    -- To the other long table, deliberately: this is the check that a reset
    -- doing nothing would still pass if the table it moved to were short.
    window\exec_js "document.querySelector('.dbc-scroller').scrollTop = 900 * 22"
    t.wait_until -> (window\eval "nui.get('dbc_grid').row") > 0

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'SpellIcon').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "SpellIcon"

    t.check "opening another long table puts the scrollbar back at its top",
      (t.wait_until -> (window\eval "document.querySelector('.dbc-scroller').scrollTop") == 0),
      tostring window\eval "document.querySelector('.dbc-scroller').scrollTop"

    t.check "and the grid is drawing that table's first rows",
      (t.wait_until -> (window\eval "nui.get('dbc_grid').row") == 0),
      tostring window\eval "nui.get('dbc_grid').row"

    -- Back to the small table for what follows.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"

    t.section "The relations graph"

    -- The one piece no model test can reach: a graph library, loaded on
    -- demand, laying out and drawing into a canvas in a real window.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'WorldSafeLocs').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "WorldSafeLocs"

    window\exec_js "neutrino.invoke('dbc:relations')"

    t.check "the panel opens on the table in front",
      (t.wait_until -> (window\eval "nui.get('dbc_graph').focus") == "WorldSafeLocs"),
      tostring window\eval "nui.get('dbc_graph').focus"

    t.check "with the table it refers to in it",
      (window\eval "nui.get('dbc_graph').nodes.some(n => n.name === 'Map')") == true,
      window\eval "nui.get('dbc_graph').nodes.map(n => n.name).join(',')"

    -- Drawn, not merely described: the library has to arrive over the scheme
    -- handler and put a canvas on screen, and neither is provable from Lua.
    t.check "and the library draws it",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-canvas canvas').length") > 0),
      tostring window\eval "document.querySelectorAll('.dbc-canvas canvas').length"

    t.check "every node it was given is in the graph",
      (t.wait_until -> (window\eval "window.__cyNodes ? window.__cyNodes() : -1") ==
        (window\eval "nui.get('dbc_graph').nodes.length")),
      tostring window\eval "window.__cyNodes ? window.__cyNodes() : -1"

    -- The one that matters, and the one the checks above cannot make: every
    -- node on screen, with a size, inside the box. Started against a hidden
    -- container Cytoscape lays the whole graph into a single point - the
    -- counts are right, the canvas is there, and nothing is visible.
    drawn = -> window\eval "window.__cyDrawn ? window.__cyDrawn() : 0"
    wanted = -> window\eval "nui.get('dbc_graph').nodes.length"

    t.check "and every node is on screen with a size",
      (t.wait_until -> drawn! == wanted!),
      "#{drawn!} of #{wanted!} drawn :: " .. tostring window\eval "window.__cyDebug()"

    -- The wide view has to be askable rather than only arrived at: the table
    -- in front stays in front after its tab is closed, so "nothing is open"
    -- is a state almost nobody gets back to.
    window\exec_js "neutrino.invoke('dbc:relations', '*')"

    t.check "the whole client can be asked for while a table is open",
      (t.wait_until -> (window\eval "nui.get('dbc_graph').focus") == ""),
      tostring window\eval "nui.get('dbc_graph').focus"

    t.check "and it holds every linked table rather than one's neighbours",
      (t.wait_until -> drawn! == wanted!) and wanted! > 0,
      "#{drawn!} of #{wanted!} drawn"

    window\exec_js "neutrino.invoke('dbc:relations', 'WorldSafeLocs')"
    t.check "and going back to one table re-roots it",
      (t.wait_until -> (window\eval "nui.get('dbc_graph').focus") == "WorldSafeLocs"),
      tostring window\eval "nui.get('dbc_graph').focus"

    window\exec_js "nui.set('dbc_graph_open', false)"
    t.check "and closing it takes the canvas away",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-canvas canvas').length") == 0),
      tostring window\eval "document.querySelectorAll('.dbc-canvas canvas').length"

    -- Back to the small table, which is what follows expects to be looking at.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"

    t.section "Deleting asks first"

    window\exec_js "nui.set('dbc_row', 2); neutrino.invoke('dbc:delete')"

    t.check "the dialog appears rather than the row going",
      (t.wait_until -> (window\eval "nui.get('dbc_confirm')") != ""),
      "no dialog"
    t.check "and the table is untouched while it is up",
      (window\eval "nui.get('dbc_info').rows") == 6

    window\exec_js "[...document.querySelectorAll('button')]
      .find(el => el.innerText.trim() === 'Cancel').click()"
    t.check "cancelling leaves it alone",
      (t.wait_until -> (window\eval "nui.get('dbc_confirm')") == "") and
        (window\eval "nui.get('dbc_info').rows") == 6

    window\exec_js "neutrino.invoke('dbc:delete')"
    t.wait_until -> (window\eval "nui.get('dbc_confirm')") != ""

    window\exec_js "[...document.querySelectorAll('button')]
      .find(el => el.innerText.trim() === 'Delete').click()"

    t.check "confirming removes the row",
      (t.wait_until -> (window\eval "nui.get('dbc_info').rows") == 5),
      tostring window\eval "nui.get('dbc_info').rows"

    -- Undo is one command in the menu and a different one in every tool, so
    -- the shell hands it to whichever tool is active.
    window\exec_js "neutrino.invoke('shell:undo')"
    t.check "and the shell's own Undo reaches this tool",
      (t.wait_until -> (window\eval "nui.get('dbc_info').rows") == 6),
      tostring window\eval "nui.get('dbc_info').rows"

    window\close true

    t.done!
    app\quit!

app\run!
t.finish!
