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

t.check "the folder is listed", #entries == 5, "#{#entries} entries"
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
      (window\eval "nui.get('dbc_tables').length") == 5,
      tostring window\eval "nui.get('dbc_tables').length"

    -- The list is the page's own filter over the store, so the entries
    -- rendered are the ones that matched rather than the ones Lua sent.
    window\exec_js "nui.set('dbc_filter', 'Bag')"
    t.check "the filter narrows it",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-table').length") == 1)

    window\exec_js "nui.set('dbc_filter', '')"
    t.check "and clearing it brings the rest back",
      (t.wait_until -> (window\eval "document.querySelectorAll('.dbc-table').length") == 5)

    -- A file no definition describes is shown and cannot be clicked. Hiding
    -- it would mean somebody looking for it concluded it was not there.
    t.check "a table with no definition for this build is offered but refused",
      (window\eval "[...document.querySelectorAll('.dbc-table')]
        .filter(el => el.hasAttribute('data-disabled'))
        .map(el => el.innerText.trim()).join(',')") == "NotATable",
      window\eval "[...document.querySelectorAll('.dbc-table')]
        .filter(el => el.hasAttribute('data-disabled'))
        .map(el => el.innerText.trim()).join(',')"

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

    t.check "and the strip saying which locale is being edited",
      (window\eval "[...document.querySelectorAll('span')]
        .some(el => el.getClientRects().length > 0 &&
          el.textContent.trim() === 'Text: frFR')") == true

    -- The whole table sizes the scroller; only what is visible is drawn.
    t.check "the scroller is the size of the whole table",
      (window\eval "document.querySelector('.dbc-scroller').firstElementChild
        .getBoundingClientRect().height") == 6 * 22 + 26,
      tostring window\eval "document.querySelector('.dbc-scroller')
        .firstElementChild.getBoundingClientRect().height"

    t.check "the header names the columns and their kinds",
      (window\eval "[...document.querySelectorAll('.dbc-head')]
        .map(el => el.innerText.replace(/\\s+/g, ' ').trim()).join('|')")\match("Name_lang loc") != nil,
      window\eval "[...document.querySelectorAll('.dbc-head')]
        .map(el => el.innerText.replace(/\\s+/g, ' ').trim()).join('|')"

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

    -- Back to the small table for what follows.
    window\exec_js "[...document.querySelectorAll('.dbc-table')]
      .find(el => el.innerText.trim() === 'ItemBagFamily').click()"
    t.wait_until -> (window\eval "nui.get('dbc_open')") == "ItemBagFamily"

    t.check "switching back puts the scrollbar where the new table starts",
      (t.wait_until -> (window\eval "document.querySelector('.dbc-scroller').scrollTop") == 0),
      tostring window\eval "document.querySelector('.dbc-scroller').scrollTop"

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
