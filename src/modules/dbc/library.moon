--- lua-dbc, as this application reaches it.
--
-- Everything that knows where the client's files are and which of them can be
-- opened. Kept apart from the editor so that the editor deals only in an open
-- table: finding one is a question about the workspace, and editing one is
-- not.
--
-- **Nothing here raises.** Every entry point in lua-dbc reports failure by
-- raising - there is no `nil, err` anywhere in it - and a missing file, a
-- truncated one and a table nobody wrote a definition for are all ordinary
-- things to find in a client folder. So each crossing is wrapped once, here,
-- and the interface is handed a message instead of losing the window.
---@module modules.dbc.library

Neutrino = require "neutrino"
dbc = require "dbc"
settings = require "settings"
workspace = require "workspace"

fs = Neutrino.fs
json = Neutrino.json
log = Neutrino.log
paths = Neutrino.paths

M = {}

-- The build's own definitions, trimmed to one build by tools/build.ps1 and
-- laid beside the executable. Set here, once, because lua-dbc keeps the
-- directory in a process-global: doing it per open would be the same call with
-- more chances to forget it.
M.DEFINITIONS = "#{paths.root}/definitions"
dbc.SetDefinitionsDir M.DEFINITIONS

--- What this module keeps of its own.
---@type table
M.DEFAULTS = {
  -- Where the .dbc files are. Empty means "work it out from the workspace",
  -- which is right for an extracted client and wrong for the half-dozen
  -- layouts people actually have, so it can be said outright.
  source: ""

  -- What Save writes. The table itself, or the script that would produce it -
  -- which is the one to keep under version control, since a binary DBC in a
  -- diff says only that it changed.
  save_as: "dbc"

  -- How many columns a localised field becomes. "present" is the default: a
  -- table holding four translations and showing one looks like it lost three,
  -- and all fourteen on a file carrying one would be thirteen empty columns.
  -- "all" is for filling a language in that is not there yet, which is the
  -- one case "present" cannot serve.
  locales: "present"

  -- Offer to read and write at the language the file is actually written in,
  -- when that is not the workspace's.
  locale_hint: true

  -- Show a referenced id with the row it points at beside it. Persisted, so
  -- it survives opening another table and restarting: it is how somebody
  -- reads a client, not a thing to switch on per file. Changed from the rail
  -- rather than the settings page, which is why it is not a field there.
  readable: false

  -- Offer the rows of the referenced table when a foreign key is being
  -- edited, instead of a box to type a number into. Off by default: it reads
  -- the referenced table to build the list, and somebody who knows the number
  -- they want is slowed down rather than helped.
  resolver: false

  -- Refuse a foreign key that names a row the referenced table does not have.
  -- Off by default: it reads the referenced table to answer, which is a moment
  -- on a large one, and a client being built up piece by piece has columns
  -- pointing at rows that are not there *yet*. Worth switching on to go over a
  -- table before shipping it, rather than to work in.
  verify_fk: false

  -- Whether a click opens a table or only selects it. Double is for people
  -- who move through the list with the keyboard and do not want a fifty
  -- thousand row table opened at every step.
  open_on: "single"
}

document = nil

--- The settings document, read on the first call that needs it.
---@return table
---@private
loaded = ->
  unless document
    values, err = settings.load "dbc", M.DEFAULTS
    document = values
    log.warn "dbc: %s", err if err
  document

--- One of this module's settings.
---@param field string
---@return any
M.setting = (field) -> loaded![field]

--- Changes one setting and persists it.
---@param field string
---@param value any
---@return boolean|nil ok, string|nil err
M.set = (field, value) ->
  doc = loaded!
  return true if doc[field] == value

  doc[field] = value
  settings.save "dbc", doc

--- Forgets what was read, so the next call reads the disk again.
M.reload = -> document = nil

--- The folder holding the client's DBC files, or nil.
--
-- The configured one when it is a folder, and otherwise the places a 3.3.5a
-- client keeps them: an extraction usually lands as DBFilesClient beside the
-- executable, and MPQ tools that keep the archive's own layout put it under
-- Data. The workspace folder itself is the last guess, because somebody who
-- pointed the tool straight at a folder of DBCs meant that folder.
---@return string|nil folder
---@return string|nil err
M.source_dir = ->
  configured = M.setting "source"
  if type(configured) == "string" and configured != ""
    return configured if fs.is_dir configured
    return nil, "the configured DBC folder is not there: #{configured}"

  open = workspace.current!
  return nil, "no workspace is open" unless open

  for candidate in *{
    fs.join open.path, "DBFilesClient"
    fs.join open.path, "Data", "DBFilesClient"
  }
    return candidate if fs.is_dir candidate

  return open.path if fs.is_dir open.path
  nil, "there is nothing at #{open.path}"

-- One workspace object per (folder, build, output). lua-dbc caches the tables
-- it opens on it, which is what keeps a table's edits alive while the user
-- looks at another one - so it must not be rebuilt for every question.
held = nil

--- The lua-dbc workspace for what is open now.
---@return table|nil ws, string|nil err
M.workspace = ->
  dir, err = M.source_dir!
  return nil, err unless dir

  build = workspace.setting "build"
  out = workspace.output_dir! or dir

  if held and held.dir == dir and held.build == build and held.out == out
    return held.ws

  ok, ws = pcall dbc.Workspace, { source: dir, out: out, :build }
  return nil, "the DBC workspace could not be opened: #{tostring ws}" unless ok

  held = { :dir, :build, :out, :ws }
  ws

--- Drops the open tables, edits included.
-- Called when the workspace changes: the tables belong to the folder that was
-- open, and answering questions about them afterwards would be answering about
-- files nobody is looking at any more.
M.close = ->
  held = nil

--- The tables in the workspace's DBC folder.
--
-- Listed from the folder rather than from lua-dbc, which has no enumeration:
-- it answers about a table you name. `editable` is whether a definition for
-- this build exists - without one the file can be seen but not opened, and
-- saying so in the list beats saying it when somebody clicks.
---@return table[] entries { name, editable }
---@return string|nil err
M.tables = ->
  dir, err = M.source_dir!
  return (json.array {}), err unless dir

  build = workspace.setting "build"

  ok, listed = pcall fs.list, dir, "*.dbc"
  return (json.array {}), "cannot read #{dir}: #{tostring listed}" unless ok

  entries = {}
  openable = 0

  for path in *listed
    name = (fs.basename path)\gsub "%.[dD][bB][cC]$", ""
    editable = dbc.Schemas.Has name, build
    openable += 1 if editable

    table.insert entries, { :name, :editable }

  table.sort entries, (a, b) -> a.name\lower! < b.name\lower!

  -- Logged because the two numbers are the whole diagnosis when something is
  -- wrong: none found is the wrong folder, none openable is the definitions
  -- not being where this build put them, and there is nothing on screen that
  -- tells those two apart.
  log.info "dbc: %d tables in %s, %d openable for %s",
    #entries, dir, openable, build

  (json.array entries), nil

--- Opens one table.
-- `GetTable` answers nil for a file that is not there, where `Open` raises;
-- everything else it does still raises, which is what the pcall is for.
---@param name string
---@return table|nil tbl
---@return string|nil err
M.open = (name) ->
  ws, err = M.workspace!
  return nil, err unless ws

  ok, tbl = pcall ws.GetTable, ws, name
  return nil, "#{name} could not be opened: #{tostring tbl}" unless ok
  return nil, "there is no #{name}.dbc in the workspace" unless tbl

  tbl

-- The workspace moving invalidates everything above.
workspace.on_change -> M.close!

M
