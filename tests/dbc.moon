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

t.section "The pages the grid asks for"

-- The grid holds what was scrolled past and nothing more, so a page is the
-- unit everything below it is built on.

first = editor.page session, 1, 4

t.check "only the rows asked for come back", #first.data == 4,
  "#{#first.data} rows"
t.check "and the number of pages comes with them", first.last_page == 2,
  "#{first.last_page}"
t.check "a row is named by its index in the file, and carries its ID",
  first.data[2]._i == 2 and first.data[2]._id == 2
t.check "a cell is keyed by its column's index",
  first.data[2].c2 == "Sac 2", tostring first.data[2].c2

-- The same index is the same row whichever page it arrives on, which is the
-- whole basis of asking for one page at a time.
second = editor.page session, 2, 4
t.check "the next page carries on where the first stopped",
  second.data[1]._i == 5, tostring second.data[1]._i
t.check "and reads the same values a single page would",
  second.data[1].c2 == "Sac 5", tostring second.data[1].c2

t.check "a page past the end is empty rather than an error",
  #(editor.page session, 9, 4).data == 0

-- What the grid is built from, which is a different question from what it
-- shows: the list carries every column, and says which are on screen.
grid = editor.grid_columns session
t.check "the columns come with a key per index", grid[2].key == "c2",
  tostring grid[2].key
t.check "and every one of them starts on screen",
  #[column for column in *grid when column.shown] == #session.columns

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
  (editor.row_at session, 3)._d.c2 == true

bad, bad_err = editor.set_cell locs, 1, (locs.columns[2]), "not a number"
t.check "a value the column cannot hold is refused", bad == false, tostring bad_err
t.check "and the record is left as it was",
  (editor.read locs, 1, locs.columns[2]) == "10"

refused = editor.row_at locs, 1
t.check "but the edit is kept, with the reason",
  refused.c2 == "not a number" and refused._e.c2 != nil,
  tostring refused._e and refused._e.c2

-- Correcting it clears the refusal rather than leaving it stuck.
editor.set_cell locs, 1, locs.columns[2], "11"
corrected = editor.row_at locs, 1
t.check "and a good value afterwards clears it",
  corrected.c2 == "11" and corrected._e == nil, tostring corrected._e

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Verifying a foreign key"

-- Row 2, so that what this section leaves behind is not what the sections
-- below read. Continent points at Map, and the kind check cannot help here:
-- every id that points nowhere is a perfectly good number.
continent = locs.columns[2]
t.check "the column refers to another table", continent.foreign == "Map",
  tostring continent.foreign

t.check "verification is off to begin with",
  (library.setting "verify_fk") == false, tostring library.setting "verify_fk"

loose, loose_err = editor.set_cell locs, 2, continent, "4242"
t.check "so an id pointing nowhere is written", loose, tostring loose_err
t.check "and the record holds it",
  (editor.read locs, 2, continent) == "4242", editor.read locs, 2, continent

library.set "verify_fk", true

linked, link_err = editor.set_cell locs, 2, continent, "4343"
t.check "with it on the same write is refused", linked == false, tostring link_err
t.check "and it says which table has no such row",
  link_err != nil and link_err\match("Map") != nil, tostring link_err
t.check "the record is left as it was",
  (editor.read locs, 2, continent) == "4242", editor.read locs, 2, continent

held = editor.row_at locs, 2
t.check "while what was typed is kept, with the reason",
  held.c2 == "4343" and held._e.c2 != nil, tostring held.c2

-- Nothing is what 0 means on nearly every column that refers anywhere, so it
-- is not a link at all and cannot be a broken one.
zeroed, zero_err = editor.set_cell locs, 2, continent, "0"
t.check "zero is not a broken link", zeroed, tostring zero_err

good, good_err = editor.set_cell locs, 2, continent, "2"
t.check "nor is a row the referenced table has", good, tostring good_err
t.check "and that one reached the record",
  (editor.read locs, 2, continent) == "2", editor.read locs, 2, continent

library.set "verify_fk", false

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

t.section "A paste is one step"

-- A block of cells arriving at once, which is what DBC work is made of. Two
-- hundred presses of Ctrl+Z to take one back would be unusable.

pasted = editor.session (library.open "WorldSafeLocs"), "WorldSafeLocs", "enUS",
  BUILD
paste_continent = pasted.columns[2]

-- Read rather than assumed: lua-dbc hands out one table per name, so this is
-- the same records the section above has been writing to.
was = [editor.read pasted, index, paste_continent for index = 1, 3]

before_paste = #pasted.stack
written, refused = editor.paste pasted, {
  { row: 1, column: 2, value: "71" }
  { row: 2, column: 2, value: "72" }
  { row: 3, column: 2, value: "73" }
}

t.check "every cell in the block reaches the record", written == 3,
  "#{written} written"
t.check "and none of them was refused", #refused == 0,
  refused[1] and refused[1].message

t.check "the values are the pasted ones",
  (editor.read pasted, 1, paste_continent) == "71" and
    (editor.read pasted, 3, paste_continent) == "73",
  editor.read pasted, 3, paste_continent

t.check "and the whole paste is one step on the stack",
  #pasted.stack == before_paste + 1, "#{#pasted.stack} entries"

editor.undo pasted
t.check "so one undo takes all of it back",
  (editor.read pasted, 1, paste_continent) == was[1] and
    (editor.read pasted, 2, paste_continent) == was[2] and
    (editor.read pasted, 3, paste_continent) == was[3],
  "#{editor.read pasted, 1, paste_continent}, " ..
    "#{editor.read pasted, 2, paste_continent}, " ..
    "#{editor.read pasted, 3, paste_continent}"

t.check "with nothing left to undo", editor.can_undo(pasted) == false

editor.redo pasted
t.check "and one redo puts all of it back",
  (editor.read pasted, 1, paste_continent) == "71" and
    (editor.read pasted, 3, paste_continent) == "73",
  editor.read pasted, 3, paste_continent

editor.undo pasted

-- A group holds what happened, not what was attempted. A cell the column will
-- not take never reaches the record, so there is nothing about it to undo -
-- but the text it was given is kept, exactly as a typed edit's is.
mixed_written, mixed_refused = editor.paste pasted, {
  { row: 1, column: 2, value: "81" }
  { row: 2, column: 2, value: "not a number" }
  { row: 3, column: 2, value: "83" }
}

t.check "a cell the column refuses does not stop the rest",
  mixed_written == 2 and #mixed_refused == 1,
  "#{mixed_written} written, #{#mixed_refused} refused"

t.check "the ones that took are in the record",
  (editor.read pasted, 1, paste_continent) == "81" and
    (editor.read pasted, 3, paste_continent) == "83",
  editor.read pasted, 3, paste_continent

t.check "the one that did not left the record alone",
  (editor.read pasted, 2, paste_continent) == was[2],
  editor.read pasted, 2, paste_continent

kept = editor.row_at pasted, 2
t.check "but kept what was typed, with the reason",
  kept.c2 == "not a number" and kept._e.c2 != nil,
  tostring kept._e and kept._e.c2

editor.undo pasted
t.check "and one undo takes back exactly the writes that happened",
  (editor.read pasted, 1, paste_continent) == was[1] and
    (editor.read pasted, 3, paste_continent) == was[3] and
    editor.can_undo(pasted) == false,
  editor.read pasted, 1, paste_continent

-- Every cell refused is not a step at all: a Ctrl+Z spent undoing nothing is
-- a Ctrl+Z that does not reach the edit before it.
none_written = editor.paste pasted, {
  { row: 1, column: 2, value: "rubbish" }
}
t.check "a paste that takes nothing leaves nothing on the stack",
  none_written == 0 and editor.can_undo(pasted) == false

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The changed rows on their own"

-- What you want in front of you before saving, and a filter over the change
-- set rather than a second record of what happened.

watched = editor.session (library.open "WorldSafeLocs"), "WorldSafeLocs",
  "enUS", BUILD
watched_continent = watched.columns[2]

editor.set_changed_only watched, true
t.check "with nothing changed the view is empty",
  editor.visible(watched) == 0, tostring editor.visible watched

editor.set_cell watched, 3, watched_continent, "44"
t.check "an edit puts its row into the view",
  editor.visible(watched) == 1 and (editor.at watched, 1) == 3,
  "#{editor.visible watched} rows"

editor.set_cell watched, 5, watched_continent, "55"
t.check "and a second edit puts a second one in",
  editor.visible(watched) == 2, tostring editor.visible watched

t.check "the page over it holds those rows and no others",
  #(editor.page watched, 1, 50).data == 2 and
    (editor.page watched, 1, 50).data[1]._i == 3,
  tostring (editor.page watched, 1, 50).data[1]._i

-- A cell put back where it started is not a change, so its row leaves the
-- view. Anything that recorded the keystroke rather than the net effect would
-- keep it.
editor.set_cell watched, 3, watched_continent, "30"
t.check "a row edited back to where it started leaves again",
  editor.visible(watched) == 1 and (editor.at watched, 1) == 5,
  "#{editor.visible watched} rows"

editor.undo watched
t.check "and an undo is felt by the view too",
  editor.visible(watched) == 2, tostring editor.visible watched

editor.set_changed_only watched, false
t.check "turning it off puts every row back",
  editor.visible(watched) == 5, tostring editor.visible watched

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Starting partway down"

-- The grid is fed forwards, so a row deep in a large table is reached by
-- beginning there rather than by scrolling to it.

anchored = editor.session (library.open "Spell"), "Spell", "enUS", BUILD

t.check "by default the first page is the first rows",
  (editor.page anchored, 1, 10).data[1]._i == 1

editor.set_from anchored, 1500
jumped = editor.page anchored, 1, 10

t.check "an anchor moves where the first page starts",
  jumped.data[1]._i == 1501, tostring jumped.data[1]._i
t.check "and the page count is of what is left below it",
  jumped.last_page == 50, tostring jumped.last_page
t.check "while the page says where it began",
  jumped.from == 1500, tostring jumped.from

editor.set_from anchored, 0
t.check "putting it back starts from the first row again",
  (editor.page anchored, 1, 10).data[1]._i == 1

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

editor.sort_by finder, by_name, false
t.check "ascending puts the first name first",
  (editor.read finder, (editor.at finder, 1), names) == "Sac 1",
  editor.read finder, (editor.at finder, 1), names

sort = editor.sort_by finder, by_name, true
t.check "the other direction is asked for rather than cycled to",
  sort.descending == true
t.check "and the last name is now first",
  (editor.read finder, (editor.at finder, 1), names) == "Sac 6",
  editor.read finder, (editor.at finder, 1), names

-- The grid sends the direction with every page it asks for, so the same sort
-- arrives over and over. A cycle would turn it off on the second page.
editor.sort_by finder, by_name, true
t.check "and asking for the same one twice does not turn it off",
  finder.sort != nil and finder.sort.descending == true,
  tostring finder.sort

t.check "while asking for none puts the file's own order back",
  (editor.sort_by finder, nil, false) == nil and (editor.at finder, 1) == 1

-- Sorting must not move a row, only where it is drawn: everything recorded
-- about an edit names the index, and a sort that renumbered rows would make
-- every change in the set point somewhere else.
editor.sort_by finder, by_name, false
sorted_page = editor.page finder, 1, 6
t.check "a sorted page still reports each row's real index",
  sorted_page.data[1]._i == 1 and sorted_page.data[6]._i == 6,
  "#{sorted_page.data[1]._i}..#{sorted_page.data[6]._i}"

-- A filter and a sort are one order, not two that fight.
editor.set_query finder, "ID > 3"
editor.sort_by finder, by_name, false
t.check "a sort applies to what the search left",
  editor.visible(finder) == 3 and (editor.at finder, 1) == 4,
  "#{editor.visible finder} rows, first #{tostring editor.at finder, 1}"
editor.sort_by finder, nil, false
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
sized = editor.grid_columns finder

t.check "the grid's columns carry the width each was left at",
  sized[1].w == 200 and sized[2].w == editor.DEFAULT_WIDTH,
  "#{tostring sized[1].w}, #{tostring sized[2].w}"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Which columns are on screen, and in what order"

-- Spell has 105 columns and nobody wants all of them, so this is a property of
-- the session beside the widths rather than of the page.

editor.set_layout finder, nil, { [1]: true }
hidden_layout = editor.grid_columns finder

t.check "a hidden column is still in the list, marked",
  #hidden_layout == 2 and hidden_layout[1].shown == false,
  "#{#hidden_layout} columns"

t.check "and its values are not read at all",
  (editor.page finder, 1, 1).data[1].c1 == nil,
  tostring (editor.page finder, 1, 1).data[1].c1

t.check "while the ones on screen still are",
  (editor.page finder, 1, 1).data[1].c2 == "Sac 1",
  tostring (editor.page finder, 1, 1).data[1].c2

editor.set_layout finder, nil, {}
t.check "putting it back brings its values with it",
  (editor.page finder, 1, 1).data[1].c1 == "1",
  tostring (editor.page finder, 1, 1).data[1].c1

editor.set_layout finder, { 2, 1 }, nil
reordered = editor.grid_columns finder
t.check "a reorder moves the columns and not the keys",
  reordered[1].key == "c2" and reordered[2].key == "c1",
  "#{reordered[1].key}, #{reordered[2].key}"

-- A column the order does not mention has to appear rather than disappear:
-- changing the locale mode adds columns to a session that already has one.
editor.set_layout finder, { 2 }, nil
partial = editor.grid_columns finder
t.check "and one the order leaves out goes to the end rather than away",
  #partial == 2 and partial[2].key == "c1", "#{#partial} columns"

editor.set_layout finder, { 1, 2 }, {}

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

    -- ── The grid ──────────────────────────────────────────────────────────
    --
    -- Tabulator is handed the container only once that container has a size,
    -- so it is built a frame or two after the table opens. Nothing below may
    -- assume it is already there.

    -- Cells on screen, with a size, inside the host. A count of rows or of
    -- elements is true of a grid laid out into a box of no height.
    drawn = -> window\eval "window.__gridDrawn ? window.__gridDrawn() : 0"

    -- How many rows the library is holding, which is how "fed a page at a
    -- time" is told apart from "handed the whole table".
    held = -> window\eval "window.__grid && window.__grid()
      ? window.__grid().getDataCount() : -1"

    elements = -> window\eval "document.querySelectorAll('.dbc-grid .tabulator-cell').length"

    why = -> tostring window\eval "window.__gridDebug ? window.__gridDebug() : 'no grid'"

    columns_shown = -> window\eval "nui.get('dbc_columns').filter(c => c.shown).length"

    -- The grid is destroyed and rebuilt whenever the columns change, so "there
    -- are cells on screen" is true of the table before this one for as long as
    -- the rebuild takes. This waits for the grid to be the one the store is
    -- describing, and then for it to have drawn something.
    matches_store = -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      if (!g) return 0
      const want = nui.get('dbc_columns').filter(c => c.shown).length
      const have = g.getColumns()
        .filter(c => (c.getField() || '').charAt(0) === 'c').length
      return want > 0 && want === have && g.getDataCount() > 0 ? 1 : 0
    })()"

    showing = ->
      settled = t.wait_until -> matches_store! == 1
      settled and (t.wait_until -> drawn! > 0)

    --- What one cell holds, by row index in the file and column index.
    value_at = (index, column) -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      const row = g && g.getRow(#{index})
      return row ? String(row.getData()['c#{column}']) : ''
    })()"

    --- A theme token, as the browser computes it.
    --
    -- Through a probe element rather than read off the custom property: the
    -- property is the text "#131317" and every computed colour is "rgb(19,
    -- 19, 23)", and comparing the two forms would never match.
    token = (name) -> window\eval "(() => {
      const probe = document.createElement('span')
      probe.style.color = getComputedStyle(document.documentElement)
        .getPropertyValue(#{json.encode name}).trim()
      document.body.appendChild(probe)
      const value = getComputedStyle(probe).color
      probe.remove()
      return value
    })()"

    --- What the browser actually paints one element with.
    styled = (selector, property) -> window\eval "(() => {
      const el = document.querySelector('.dbc-grid ' + #{json.encode selector})
      return el ? getComputedStyle(el)[#{json.encode property}] : ''
    })()"

    --- A painted colour as four numbers, whatever spelling the browser used.
    --
    -- A mix computes to `color(srgb 0.82 0.63 0.35 / 0.14)` rather than to
    -- `rgba(...)`, and comparing those two as text never matches however
    -- right the colour is.
    channels = (selector, property) -> window\eval "(() => {
      const el = document.querySelector('.dbc-grid ' + #{json.encode selector})
      if (!el) return ''
      const value = getComputedStyle(el)[#{json.encode property}]
      const mix = value.match(/color\\(srgb ([\\d.]+) ([\\d.]+) ([\\d.]+)(?: \\/ ([\\d.]+))?\\)/)
      if (mix) return [Math.round(mix[1] * 255), Math.round(mix[2] * 255),
        Math.round(mix[3] * 255), mix[4] === undefined ? 1 : Number(mix[4])].join(',')
      const plain = value.match(/rgba?\\(([^)]+)\\)/)
      if (!plain) return ''
      const parts = plain[1].split(',').map(Number)
      return [parts[0], parts[1], parts[2],
        parts[3] === undefined ? 1 : parts[3]].join(',')
    })()"

    --- Anything inside the grid still wearing the library's own palette.
    --
    -- Cheap, and it catches the whole class of "that part was not styled" at
    -- once: white is not in this interface, so anything computing to it is
    -- something the theme never reached.
    white = -> window\eval "(() => {
      const host = document.querySelector('.dbc-grid')
      if (!host) return 'no host'
      const found = []
      for (const el of [host, ...host.querySelectorAll('*')]) {
        const style = getComputedStyle(el)
        const name = el.className && el.className.baseVal === undefined
          ? String(el.className).split(' ')[0] : el.tagName
        if (style.backgroundColor === 'rgb(255, 255, 255)') found.push('bg ' + name)
        if (style.color === 'rgb(255, 255, 255)') found.push('text ' + name)
      }
      return found.slice(0, 6).join(', ')
    })()"

    --- Types into a cell the way a person does: open it, type, commit.
    type_into = (index, column, text) -> window\exec_js "(() => {
      const g = window.__grid()
      const cell = g.getRow(#{index}).getCell('c#{column}')
      const el = cell.getElement()
      el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
      const input = el.querySelector('input')
      if (!input) return
      input.value = #{json.encode text}
      input.dispatchEvent(new Event('change', { bubbles: true }))
    })()"

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

    showing!
    type_into 1, 2, "12"

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

    -- Not "a grid was built" and not "six rows arrived", both of which are
    -- true of a grid laid out into a box of no height. Cells on screen, with
    -- a size, inside the host.
    t.check "the grid draws cells on screen, inside its box, with a size",
      showing!, why!

    -- One per value of every row, plus the row's own number frozen beside it.
    t.check "one for every value the table holds",
      (t.wait_until -> drawn! == 6 * (columns_shown! + 1)),
      "#{drawn!} of #{6 * (columns_shown! + 1)} :: #{why!}"

    t.check "and holds only the rows it asked for", held! == 6, tostring held!

    t.check "with the table list beside it",
      (window\eval "document.querySelector('.dbc-table').getClientRects().length") > 0

    -- Every language the file carries gets a column of its own by default, so
    -- the strip says that rather than naming one slot. Silence either way is
    -- how a row ends up holding two different names.
    t.check "and the strip saying every language is on screen",
      (window\eval "[...document.querySelectorAll('span')]
        .some(el => el.getClientRects().length > 0 &&
          el.textContent.trim() === 'All languages')") == true

    headers = -> window\eval "[...document.querySelectorAll(
      '.dbc-grid .tabulator-col-title')].map(el => el.textContent.trim()).join('|')"

    t.check "the header names the columns",
      (headers!)\match("Name_lang enUS") != nil, headers!

    -- The second language, which is the point of showing them all: a file
    -- translated into four and showing one looks like it lost three.
    t.check "and one column per language the file carries",
      (headers!)\match("Name_lang frFR") != nil, headers!

    -- The row's place in the file is its identity, and all that the 22 tables
    -- without an ID have. It is frozen beside the values, not inferred.
    t.check "and the row's own index is beside it",
      (window\eval "document.querySelector('.dbc-grid .dbc-rowhead')
        .textContent.trim()") == "1",
      tostring window\eval "document.querySelector('.dbc-grid .dbc-rowhead')
        .textContent.trim()"

    t.section "The grid wears the theme"

    -- Not "the rules are in the stylesheet" and not "the class is on the
    -- element": either would pass against a grid rendering white on white.
    -- What the browser computed, against the tokens it was meant to compute
    -- from.

    t.check "the header is the raised surface",
      (styled '.tabulator-header', 'backgroundColor') == token '--color-base-850',
      "#{styled '.tabulator-header', 'backgroundColor'} against
        #{token '--color-base-850'}"

    -- The one that was missed: Tabulator paints this white, and rows left
    -- transparent show it through rather than the surface beneath them.
    t.check "and the table under the rows is the work area's own colour",
      (styled '.tabulator-tableholder .tabulator-table', 'backgroundColor') ==
        token '--color-base-900',
      "#{styled '.tabulator-tableholder .tabulator-table', 'backgroundColor'} against
        #{token '--color-base-900'}"

    t.check "a row is that colour too, rather than banded",
      (styled '.tabulator-row', 'backgroundColor') == token '--color-base-900',
      styled '.tabulator-row', 'backgroundColor'

    t.check "and so is the second one",
      (styled '.tabulator-row.tabulator-row-even', 'backgroundColor') ==
        token '--color-base-900',
      styled '.tabulator-row.tabulator-row-even', 'backgroundColor'

    -- The third row, deliberately: the grid opens with a range on the first
    -- one, and a highlighted cell is painted for being selected rather than
    -- for being a cell.
    plain_cell = '.tabulator-row:nth-child(3) .tabulator-cell[tabulator-field="c2"]'
    plain_number = '.tabulator-row:nth-child(3) .tabulator-cell.dbc-rownum'

    t.check "a cell is the ink colour",
      (styled plain_cell, 'color') == token '--color-ink',
      "#{styled plain_cell, 'color'} against #{token '--color-ink'}"

    t.check "on the line colour, faintly",
      (styled plain_cell, 'borderRightColor') == token '--color-line-soft',
      "#{styled plain_cell, 'borderRightColor'} against
        #{token '--color-line-soft'}"

    -- Numbers in a column have to line up to be read down, which is what the
    -- monospace stack is for.
    t.check "and set in the monospace face",
      (styled plain_cell, 'fontFamily')\match("Cascadia") != nil,
      styled plain_cell, 'fontFamily'

    t.check "the frozen row number is opaque, so cells scroll under it",
      (styled plain_number, 'backgroundColor') == token '--color-base-850',
      "#{styled plain_number, 'backgroundColor'} against
        #{token '--color-base-850'}"

    -- Setting `scrollbar-width` makes Chromium draw its own and ignore every
    -- ::-webkit-scrollbar rule. One or the other, never both - and the rules
    -- are the application's, so this has to stay at auto.
    t.check "and the scroller keeps the application's scrollbars",
      (styled '.tabulator-tableholder', 'scrollbarWidth') == "auto",
      styled '.tabulator-tableholder', 'scrollbarWidth'

    -- The whole class of "that part was never styled", in one line.
    t.check "nothing in the grid is still wearing the library's own palette",
      white! == "", white!

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

    showing!

    -- Typed and committed the way a person does: double-click the cell, type,
    -- and let the change event fire.
    type_into 1, 2, "Sac modifie"

    t.check "the edit reaches the record",
      (t.wait_until -> (value_at 1, 2) == "Sac modifie"), value_at 1, 2

    marked = -> window\eval "document.querySelectorAll(
      '.dbc-grid .tabulator-cell.is-dirty').length"

    t.check "and the cell is marked as changed",
      (t.wait_until -> marked! == 1), tostring marked!

    -- The accent, not some other amber: colour is information here, and a
    -- changed cell is the one thing it says.
    t.check "in the accent",
      (styled '.tabulator-cell.is-dirty', 'color') == token '--color-accent',
      "#{styled '.tabulator-cell.is-dirty', 'color'} against
        #{token '--color-accent'}"

    t.check "the shell is told there is something to undo",
      (window\eval "nui.get('can_undo')") == true
    t.check "and something unsaved", (window\eval "nui.get('dirty')") == true

    -- A value the column cannot hold keeps the text and says why, rather than
    -- quietly putting back what is still in the record.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'WorldSafeLocs').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "WorldSafeLocs"
    showing!

    type_into 1, 2, "not a number"

    t.check "a refused write keeps what was typed",
      (t.wait_until -> (value_at 1, 2) == "not a number"), value_at 1, 2

    t.check "and marks the cell as refused, with the reason",
      (t.wait_until -> (window\eval "(() => {
        const bad = document.querySelector('.dbc-grid .tabulator-cell.is-bad')
        return bad ? bad.getAttribute('title') || '' : ''
      })()")\match("number") != nil),
      tostring window\eval "(() => {
        const bad = document.querySelector('.dbc-grid .tabulator-cell.is-bad')
        return bad ? bad.getAttribute('title') || '' : ''
      })()"

    t.check "and paints it in danger",
      (styled '.tabulator-cell.is-bad', 'color') == token '--color-danger',
      "#{styled '.tabulator-cell.is-bad', 'color'} against
        #{token '--color-danger'}"

    t.section "Picking a value off the reference list"

    -- The other way a value gets into a cell. It writes through `dbc:set`
    -- like a typed edit, but from the markup rather than from a cell editor,
    -- and it is the one write that used to leave the old text on screen.

    window\exec_js "nui.set('dbc_resolver', true)"

    link = window\eval "(() => {
      const column = (nui.get('dbc_columns') || []).find((c) => c.foreign)
      return column ? column.index : 0
    })()"

    -- The cell reads as the id alone, or as the id with the row it points at
    -- beside it when names are on. Either form is that id and not the one
    -- that was there before.
    reads_as = (text, id) -> text == id or (text\sub 1, #id + 2) == "#{id} ("

    -- The row above was left holding a refused write, so this works on the
    -- one below it: what is being covered is the picker, not what the last
    -- section left behind.
    before = value_at 2, link

    choices = -> window\eval "document.querySelectorAll('.dbc-choice').length"

    window\exec_js "(() => {
      const g = window.__grid()
      const el = g.getRow(2).getCell('c#{link}').getElement()
      el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
    })()"

    t.check "editing a column that points elsewhere offers the rows it can point at",
      (t.wait_until -> choices! > 0), tostring choices!

    -- Any row but the one already in the cell, so that a cell which never
    -- changed cannot pass for one that did.
    chosen = window\eval "(() => {
      const before = #{json.encode before}
      for (const el of document.querySelectorAll('.dbc-choice')) {
        const id = el.querySelector('.dbc-choice-id').textContent.trim()
        if (id !== before) { el.click(); return id }
      }
      return ''
    })()"

    t.check "and one of them can be picked",
      chosen != "" and chosen != before,
      "#{tostring chosen} against #{tostring before}"

    t.check "the value reaches the record",
      (t.wait_until -> reads_as (value_at 2, link), chosen),
      "#{value_at 2, link} against #{chosen}"

    -- What there is to look at. The record took the new value even with the
    -- bug this covers; the cell went on drawing the old one until a reload.
    seen = -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      const row = g && g.getRow(2)
      const cell = row && row.getCell('c#{link}')
      return cell ? cell.getElement().textContent.trim() : ''
    })()"

    t.check "and the cell on screen says so, with nothing reloaded",
      (t.wait_until -> reads_as seen!, chosen), "#{seen!} against #{chosen}"

    t.check "and the list closed behind it",
      (t.wait_until -> (window\eval "nui.get('dbc_picker').table") == ""),
      tostring window\eval "nui.get('dbc_picker').table"

    -- The editor the list opened over has to go with it. Left open it holds
    -- what the cell said before the choice and commits that on blur, over the
    -- value just picked - and it has the arrow keys in the meantime.
    editors = -> window\eval "document.querySelectorAll('.dbc-grid input').length"

    t.check "and the cell is no longer being edited",
      (t.wait_until -> editors! == 0), tostring editors!

    window\exec_js "nui.set('dbc_resolver', false)"

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"
    showing!

    t.section "Moving about with the keyboard"

    -- The friction the whole replacement is for: every cell had to be clicked.

    window\exec_js "(() => {
      const g = window.__grid()
      g.addRange(g.getRow(2).getCell('c2'))
    })()"

    where = -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      const ranges = g && g.modules.selectRange
      const active = ranges && ranges.activeRange
      if (!active) return ''
      const bounds = active.getBounds()
      if (!bounds.start) return ''
      return bounds.start.row.getData()._i + ':' + bounds.start.column.getField()
    })()"

    t.check "a cell can be picked out", (t.wait_until -> (where!) == "2:c2"),
      tostring where!

    press = (key, shift) -> window\exec_js "window.__grid().element
      .dispatchEvent(new KeyboardEvent('keydown', { key: '#{key}',
        shiftKey: #{shift and "true" or "false"}, bubbles: true }))"

    press "ArrowDown"
    t.check "an arrow moves to the cell below",
      (t.wait_until -> (where!) == "3:c2"), tostring where!

    press "ArrowLeft"
    t.check "and another to the one beside it",
      (t.wait_until -> (where!) == "3:c1"), tostring where!

    press "ArrowUp"
    press "ArrowRight"
    t.check "and back again", (t.wait_until -> (where!) == "2:c2"), tostring where!

    -- Shift extends the selection rather than moving it, which is the other
    -- half of what a block of cells is selected with.
    press "ArrowDown", true
    press "ArrowDown", true

    span = -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      const active = g && g.modules.selectRange && g.modules.selectRange.activeRange
      return active ? active.getRows().length : 0
    })()"

    t.check "and holding shift extends the block instead of moving it",
      (t.wait_until -> (span!) == 3), tostring span!

    -- Tabulator fills a selected range with its own blue, which is the one
    -- colour this interface does not have. Asserted as channels rather than
    -- as the exact mix: what matters is that it reads amber and washes rather
    -- than covers, not that it is one particular percentage.
    fill = channels '.tabulator-cell.tabulator-range-selected', 'backgroundColor'
    red, _, blue, alpha = fill\match "^(%d+),(%d+),(%d+),([%d%.]+)$"

    t.check "the selected block is an amber wash, not the library's blue fill",
      red != nil and (tonumber(red) > tonumber blue) and (tonumber(alpha) < 1),
      fill

    t.check "and nothing has gone white under the selection", white! == "", white!

    -- Enter commits and moves down, which is what makes a column of numbers
    -- typeable without reaching for the mouse between each one.
    window\exec_js "(() => {
      const g = window.__grid()
      g.addRange(g.getRow(4).getCell('c2'))
      const el = g.getRow(4).getCell('c2').getElement()
      el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
      const input = el.querySelector('input')
      input.value = 'Sac au clavier'
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    })()"

    t.check "Enter commits what was typed",
      (t.wait_until -> (value_at 4, 2) == "Sac au clavier"), value_at 4, 2

    t.check "and moves to the row below",
      (t.wait_until -> (where!) == "5:c2"), tostring where!

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
      (window\eval "nui.get('dbc_columns').length") == 170,
      tostring window\eval "nui.get('dbc_columns').length"

    -- One page, not two thousand rows. This is the whole design: the library
    -- wants every row it will ever show, and Spell in a real client is 49,839
    -- by 105 - five million values that cannot be handed over at all.
    t.check "and it holds one page of them rather than all two thousand",
      (t.wait_until -> held! == 200), "#{held!} held :: #{why!}"

    t.check "which is drawn", showing!, why!

    -- The point of the whole arrangement. 2000 rows of 170 columns is 340,000
    -- cells, and what is drawn has to be bounded by the window rather than by
    -- the table - columns as well as rows.
    t.check "and draws a window of cells rather than a table of them",
      (drawn! > 0) and (drawn! < 2000), "#{drawn!} drawn :: #{why!}"

    -- In the document too, and not only on screen. The library keeps a buffer
    -- around what is visible in both directions; what matters is that it is a
    -- buffer rather than the table.
    in_document = elements!
    t.check "with a buffer around it rather than the whole table",
      (in_document > 0) and (in_document < 5000), "#{in_document} elements"

    -- Scrolled to the bottom of what has arrived, the next page is asked for
    -- and appended. This is the check that the progressive model works at all.
    scroller = "document.querySelector('.dbc-grid .tabulator-tableholder')"
    window\exec_js "#{scroller}.scrollTop = #{scroller}.scrollHeight"

    t.check "scrolling to the end asks for the next page",
      (t.wait_until -> held! > 200), "#{held!} held :: #{why!}"

    t.check "which is appended rather than replacing what was there",
      (window\eval "window.__grid().getRow(1) ? 1 : 0") == 1

    t.check "and the window of cells is still bounded",
      (drawn! > 0) and (drawn! < 2000), "#{drawn!} drawn :: #{why!}"

    t.check "with no more in the document than before it grew",
      elements! <= in_document * 2, "#{elements!} against #{in_document}"

    -- Sorting is Lua's, over the whole table rather than over the pages that
    -- happen to have arrived. Row 2000 cannot be at the top of a descending
    -- sort unless something outside the library did the ordering.
    window\exec_js "window.__grid().setSort([{ column: 'c1', dir: 'desc' }])"

    t.check "sorting reaches past what the grid holds",
      (t.wait_until -> (window\eval "(() => {
        const g = window.__grid()
        const rows = g.getRows()
        return rows.length ? rows[0].getData()._i : 0
      })()") == 2000),
      tostring window\eval "(() => {
        const g = window.__grid()
        const rows = g.getRows()
        return rows.length ? rows[0].getData()._i : 0
      })()"

    t.check "and reading again starts from one page once more",
      (t.wait_until -> (held! > 0) and (held! <= 400)), "#{held!} held"

    window\exec_js "window.__grid().clearSort()"
    t.wait_until -> (window\eval "(() => {
      const rows = window.__grid().getRows()
      return rows.length ? rows[0].getData()._i : 0
    })()") == 1

    -- To the other long table, deliberately: a grid that failed to start over
    -- would still look right if the table it moved to were short.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'SpellIcon').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "SpellIcon"

    t.check "opening another long table starts it at the first row",
      (t.wait_until -> (window\eval "(() => {
        const g = window.__grid && window.__grid()
        const rows = g ? g.getRows() : []
        return rows.length ? rows[0].getData()._i : 0
      })()") == 1),
      why!

    t.check "and puts the scrollbar back at the top",
      (window\eval "#{scroller}.scrollTop") == 0,
      tostring window\eval "#{scroller}.scrollTop"

    -- Back to the small table for what follows.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"
    showing!

    t.section "Pasting a block in"

    -- DBC work is bulk work: a column copied out of a spreadsheet and dropped
    -- into the grid. The clipboard is not something a browser will hand a
    -- test, so the event is built here - but the listener, the parser and the
    -- action that run are the real ones.

    paste = (text) -> window\exec_js "(() => {
      const data = new DataTransfer()
      data.setData('text/plain', #{json.encode text})
      window.__grid().element.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: data, bubbles: true, cancelable: true }))
    })()"

    undo_depth = -> window\eval "nui.get('can_undo')"

    -- Read rather than assumed: the sections above have been editing this
    -- table, so what the rows hold now is a fact and not a fixture.
    was_pasted = [value_at index, 2 for index = 1, 3]

    window\exec_js "(() => {
      const g = window.__grid()
      g.addRange(g.getRow(1).getCell('c2'))
    })()"

    paste "Sac colle 1\nSac colle 2\nSac colle 3"

    t.check "a pasted column lands in the rows below the one selected",
      (t.wait_until -> (value_at 3, 2) == "Sac colle 3"), value_at 3, 2

    -- Read straight out of the record, through a session of the suite's own.
    -- A paste that had only updated the library's copy of the row would look
    -- exactly like one that reached the file.
    in_record = editor.session (library.open "ItemBagFamily"), "ItemBagFamily",
      "frFR", BUILD, "present"

    t.check "and reaches the record rather than the grid's own copy",
      (editor.read in_record, 2, in_record.columns[2]) == "Sac colle 2",
      editor.read in_record, 2, in_record.columns[2]

    t.check "every pasted cell is marked as changed",
      (t.wait_until -> marked! >= 3), tostring marked!

    t.check "and the shell has something to undo", undo_depth! == true

    -- The design question the whole feature turns on: two hundred presses of
    -- Ctrl+Z to take back one paste would be unusable.
    window\exec_js "neutrino.invoke('shell:undo')"

    t.check "one undo takes the whole paste back",
      (t.wait_until -> (value_at 3, 2) == was_pasted[3]),
      "#{value_at 3, 2} against #{was_pasted[3]}"

    t.check "all of it, not the last cell of it",
      (value_at 1, 2) == was_pasted[1] and (value_at 2, 2) == was_pasted[2],
      "#{value_at 1, 2}, #{value_at 2, 2}"

    -- A cell the column will not take keeps its text and says why, exactly as
    -- a typed edit does - and the ones around it still go in.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'WorldSafeLocs').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "WorldSafeLocs"
    showing!

    window\exec_js "(() => {
      const g = window.__grid()
      g.addRange(g.getRow(1).getCell('c2'))
    })()"

    paste "61\nrubbish\n63"

    t.check "a refused cell in a paste keeps its text",
      (t.wait_until -> (value_at 2, 2) == "rubbish"), value_at 2, 2

    t.check "while the cells around it go in",
      (value_at 1, 2) == "61" and (value_at 3, 2) == "63",
      "#{value_at 1, 2}, #{value_at 3, 2}"

    t.check "and the strip says how many were refused",
      (window\eval "nui.get('dbc_message')")\match("refused") != nil,
      tostring window\eval "nui.get('dbc_message')"

    window\exec_js "neutrino.invoke('shell:undo')"

    t.section "Choosing the columns"

    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'Spell').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "Spell"
    showing!

    -- Read off the store rather than written here: which column is which is
    -- the definition's business, and a suite that named them would be a
    -- second copy of the definition.
    label_of = (index) -> window\eval "nui.get('dbc_columns').find(c => c.index === #{index}).label"

    -- Not "the store says it is hidden": the header has to be gone from the
    -- grid, and the values have to stop arriving.
    on_header = (label) -> window\eval "[...document.querySelectorAll(
      '.dbc-grid .tabulator-col-title')].some(el => el.textContent.trim() === #{json.encode label})"

    -- Which column is leftmost, ignoring the frozen row number.
    leftmost = -> window\eval "(() => {
      const g = window.__grid && window.__grid()
      const columns = g ? g.getColumns().filter(c => (c.getField() || '').charAt(0) === 'c') : []
      return columns.length ? columns[0].getField() : ''
    })()"

    second = label_of 2

    t.check "the column list offers every column there is",
      (window\eval "nui.get('dbc_columns').length") == 170,
      tostring window\eval "nui.get('dbc_columns').length"

    t.check "and the second of them is on the header to begin with",
      on_header(second) == true, second

    columns_drawn = -> window\eval "document.querySelectorAll(
      '.dbc-grid .tabulator-col[tabulator-field]').length"

    -- Settled, not caught mid-rebuild. Hiding a column throws the grid away
    -- and builds another, and for a frame in between there are no headers at
    -- all - which would make "the header is gone" true for the wrong reason.
    settled = -> (matches_store! == 1) and (drawn! > 0)

    window\exec_js "neutrino.invoke('dbc:columns', { column: 2, shown: false })"

    t.check "hiding one gives a grid with one column fewer",
      (t.wait_until -> settled! and columns_drawn! == 170),
      "#{columns_drawn!} columns :: #{why!}"

    t.check "and its header is not on it", on_header(second) == false, second

    t.check "and stops its values being read at all",
      (t.wait_until -> (window\eval "(() => {
        const g = window.__grid && window.__grid()
        const row = g && g.getRow(1)
        return row && row.getData().c2 === undefined ? 1 : 0
      })()") == 1),
      tostring window\eval "(() => {
        const g = window.__grid && window.__grid()
        const row = g && g.getRow(1)
        return row ? String(row.getData().c2) : 'no row'
      })()"

    window\exec_js "neutrino.invoke('dbc:columns', { every: false })"
    t.check "and hiding all of them leaves a grid with no columns",
      (t.wait_until -> columns_drawn! == 0), tostring columns_drawn!

    window\exec_js "neutrino.invoke('dbc:columns', { every: true })"
    t.check "while showing all of them puts every one back",
      (t.wait_until -> on_header(second) == true), second

    -- The order lives on the session beside the widths, and moving a column
    -- moves it in the grid rather than only in the list.
    t.check "the first column is the first one to begin with",
      (t.wait_until -> (leftmost!) == "c1"), tostring leftmost!

    window\exec_js "neutrino.invoke('dbc:columns', { order: [3, 2, 1] })"
    t.check "reordering moves the columns the grid draws",
      (t.wait_until -> (leftmost!) == "c3"), tostring leftmost!

    window\exec_js "neutrino.invoke('dbc:columns', { order: [1, 2, 3] })"
    t.wait_until -> (leftmost!) == "c1"

    t.section "The changed rows on their own"

    -- What you want in front of you before saving. On CharBaseInfo, which
    -- nothing above has edited through the interface - and which keeps no ID
    -- in its records, so a row here is its position and nothing else.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'CharBaseInfo').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "CharBaseInfo"
    showing!

    rows_drawn = -> window\eval "document.querySelectorAll('.dbc-grid .tabulator-row').length"

    t.check "every row is there to begin with", (t.wait_until -> rows_drawn! == 4),
      "#{rows_drawn!} rows :: #{why!}"

    type_into 2, 1, "9"
    t.check "and an edit reaches the record",
      (t.wait_until -> (value_at 2, 1) == "9"), value_at 2, 1

    window\exec_js "neutrino.invoke('dbc:changed-only')"

    t.check "the view narrows to the rows this session has changed",
      (t.wait_until -> rows_drawn! == 1), "#{rows_drawn!} rows :: #{why!}"

    t.check "and it is that row",
      (window\eval "window.__grid().getRows()[0].getData()._i") == 2,
      tostring window\eval "window.__grid().getRows()[0].getData()._i"

    t.check "with the strip saying the view is on",
      (window\eval "nui.get('dbc_changed_only')") == true

    window\exec_js "neutrino.invoke('dbc:changed-only')"
    t.check "and turning it off brings the rest back",
      (t.wait_until -> rows_drawn! == 4), tostring rows_drawn!

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
