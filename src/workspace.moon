--- The open workspace.
--
-- A workspace is a folder of client files plus the build they came from.
-- Everything a tool reads follows from it: which MPQs to open, which DBC layout
-- to apply, where a modified file is written back.
--
--     ok, err = workspace.open "E:/WoW/3.3.5a"
--     workspace.on_change (open) -> ...
--
-- A model with listeners rather than a store key. The store is what the page
-- draws from; it is not where the application keeps its data. A tool that had
-- to watch the store to learn the workspace changed would be a tool that reads
-- the change late, in the wrong process, and only while a window is open.
--
-- There is one workspace at a time and it is persisted through `settings`, so
-- the tool comes up where it was left rather than asking again every morning.
---@module workspace

Neutrino = require "neutrino"
settings = require "settings"

fs = Neutrino.fs
json = Neutrino.json
log = Neutrino.log

M = {}

--- What a workspace is, before anyone has opened one.
--
-- The build is 3.3.5.12340 and only 3.3.5.12340: this tool targets 3.3.5a, and
-- a default that suggested otherwise would be a promise the rest of it does not
-- keep. It is a field rather than a constant because a private server's client
-- reports its own build, and the tool should follow the client rather than
-- argue with it.
---@type table
M.DEFAULTS = {
  path: ""
  build: "3.3.5.12340"
  output: ""

  -- Which of the client's locale folders to read. A 3.3.5a client keeps its
  -- text and several of its DBCs under Data/<locale>/, so nothing can be read
  -- without knowing this, and there is no way to guess it that is right more
  -- often than asking.
  locale: "enUS"

  -- Reopen on the next launch. On by default: this is a tool somebody works in
  -- all day, and being asked which folder every morning is the kind of friction
  -- that is only noticed after the hundredth time.
  reopen: true

  recent: json.array {}
}

--- The locales a 3.3.5a client ships in.
-- The list Blizzard used for Wrath, in the order the client itself lists them.
---@type string[]
M.LOCALES = {
  "enUS", "enGB", "frFR", "deDE", "esES", "esMX", "ruRU", "koKR", "zhCN", "zhTW"
}

-- The persisted document. Read once, on the first call that needs it, so that
-- requiring this module does not touch the disk.
document = nil
listeners = Neutrino.EventEmitter!

--- Reads the document, the first time anything asks for it.
---@return table
---@private
loaded = ->
  unless document
    values, err = settings.load "workspace", M.DEFAULTS
    document = values
    log.warn "workspace: %s", err if err
  document

--- The workspace that is open, or nil.
-- A fresh table each call: the document is this module's to change, and a
-- caller that edited the one it was handed would be editing what gets written.
---@return table|nil path, build, output
M.current = ->
  doc = loaded!
  return nil if doc.path == ""

  { path: doc.path, build: doc.build, output: doc.output }

--- Reads one field of the document.
--
-- Separate from `current`, which answers nil when nothing is open. Some of
-- these are answerable without a workspace — the locale and the startup
-- preference survive closing one — and a page that had to open a folder before
-- it could show a preference would be a page nobody could use.
---@param field string
---@return any
M.setting = (field) -> loaded![field]

--- The paths opened before, most recent first.
---@return string[]
M.recent = ->
  doc = loaded!
  json.array [entry for entry in *doc.recent]

--- Writes the document back.
---@return boolean|nil ok
---@return string|nil err
M.save = -> settings.save "workspace", loaded!

--- Tells the listeners what the workspace is now.
---@private
announce = -> listeners\emit "change", M.current!

--- Calls back whenever the workspace changes, including when it closes.
-- The argument is what `current` would return: a table, or nil.
---@param callback fun(workspace: table|nil)
M.on_change = (callback) -> listeners\on "change", callback

--- Stops a listener registered with `on_change`.
---@param callback fun(workspace: table|nil)
M.off_change = (callback) -> listeners\off "change", callback

-- How many paths the File menu is willing to offer. Long enough to cover the
-- handful of clients somebody actually works on, short enough to stay a menu.
RECENT_LIMIT = 10

--- Moves a path to the front of the recent list.
---@param path string
---@private
remember = (path) ->
  doc = loaded!
  wanted = fs.comparable path

  -- Compared as the filesystem compares them, so the same folder reached
  -- through a different spelling of its name does not appear twice.
  kept = [entry for entry in *doc.recent when (fs.comparable entry) != wanted]
  table.insert kept, 1, path

  while #kept > RECENT_LIMIT
    table.remove kept

  doc.recent = json.array kept

--- Opens a folder as the workspace.
--
-- Reports failure rather than raising. A folder that has gone missing since it
-- was last opened is ordinary — an external drive that is not plugged in, a
-- client that was moved — and the interface should say so, not stop.
--
-- A workspace that opened but could not be persisted is still open: `err` says
-- the settings could not be written, and the first return says it worked.
---@param path string
---@return table|nil workspace nil when the folder cannot be opened.
---@return string|nil err
M.open = (path) ->
  return nil, "no folder was given" unless type(path) == "string" and path != ""

  path = fs.normalize path
  return nil, "there is no folder at #{path}" unless fs.is_dir path

  doc = loaded!
  doc.path = path
  remember path

  ok, err = M.save!
  log.info "workspace opened: %s", path
  announce!

  M.current!, err

--- Closes the workspace, leaving the recent list alone.
---@return boolean|nil ok
---@return string|nil err
M.close = ->
  doc = loaded!
  return true if doc.path == ""

  log.info "workspace closed: %s", doc.path
  doc.path = ""

  ok, err = M.save!
  announce!
  ok, err

--- Reopens the workspace that was open when the tool last exited.
--
-- Quiet about a path that is no longer there: it is the first thing that
-- happens at startup, and a folder on a drive that is not plugged in is not
-- worth a message before the window is even up. The path stays in the document
-- so that plugging the drive back in and restarting is all it takes.
---@return table|nil workspace
M.restore = ->
  doc = loaded!
  return nil if doc.path == ""

  unless fs.is_dir doc.path
    log.info "workspace: %s is not there, staying closed", doc.path
    return nil

  announce!
  M.current!

FIELDS = {
  path: true, build: true, output: true, locale: true, reopen: true
}

--- Changes one field and persists it.
-- `path` is not settable here: moving the workspace is `open`, which checks the
-- folder is there first.
---@param field string "build", "output", "locale" or "reopen".
---@param value any
---@return boolean|nil ok
---@return string|nil err
M.set = (field, value) ->
  return nil, "unknown workspace setting '#{tostring field}'" unless FIELDS[field]
  return nil, "the workspace path is changed by opening one" if field == "path"

  doc = loaded!
  return true if doc[field] == value

  doc[field] = value

  ok, err = M.save!
  announce!
  ok, err

--- Where modified files are written.
-- The configured folder when there is one, and `output` inside the workspace
-- when there is not — so the tool has an answer before anybody has chosen.
---@return string|nil
M.output_dir = ->
  doc = loaded!
  return doc.output if doc.output != ""
  return nil if doc.path == ""

  fs.join doc.path, "output"

--- Forgets what was read, so the next call reads the disk again.
-- For the suites, and for a settings file edited by hand while the tool runs.
M.reload = ->
  document = nil
  loaded!
  announce!

M
