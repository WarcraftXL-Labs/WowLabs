--- Settings on disk, one JSON file per context.
--
-- In `src/` rather than inside a module because every module will want it: the
-- shell keeps `workspace.json`, the DBC editor will keep `dbc.json`, and none
-- of them should be writing their own file format.
--
--     values = settings.load "workspace", { build: "3.3.5.12340" }
--     ok, err = settings.save "workspace", values
--
-- Three decisions worth knowing about:
--
-- **`<root>/config/<name>.json`, beside the executable.** Not under app data.
-- These are files a developer opens in an editor while the tool is running, and
-- a path they have to go looking for is a path they will not edit. It also
-- makes a WowLabs folder something you can copy to another machine whole.
--
-- **Pretty-printed, with sorted keys.** For the same reason. `json.encode`
-- walks a table with `pairs`, so the same settings encode to a different byte
-- string on every run and the diff is the whole file whether or not anything
-- changed.
--
-- **Nothing here raises, and nothing here relocates.** A read-only folder is an
-- ordinary thing to find on somebody else's machine, not a bug; `save` says so
-- and returns the message, so the interface can show it. What it must never do
-- is quietly write somewhere else — settings that moved without being asked are
-- worse than settings that failed to save, because the failure is visible.
---@module settings

Neutrino = require "neutrino"

fs = Neutrino.fs
json = Neutrino.json
log = Neutrino.log
paths = Neutrino.paths

M = {}

--- The folder the files live in.
---@return string
M.folder = -> "#{paths.root}/config"

--- Where one context's file is.
---@param name string Context name, such as "workspace".
---@return string
M.path = (name) -> "#{M.folder!}/#{name}.json"

-- penlight raises on some argument shapes and returns nil plus a message on the
-- rest. A caller that has to handle both handles one, so both are funnelled
-- into the same pair here.
---@param action function
---@return boolean ok, string|nil err
---@private
attempt = (action, ...) ->
  ok, result, err = pcall action, ...
  return false, tostring result unless ok
  return false, (err and tostring(err) or "failed") unless result
  true

--- A deep copy, with the array marker preserved.
-- Defaults belong to the caller: merging into the table it handed over would
-- mean the second `load` of the same context started from the first one's
-- values.
---@param value any
---@return any
---@private
copy = nil
copy = (value) ->
  return value unless type(value) == "table"

  result = {}
  result[key] = copy item for key, item in pairs value
  result = json.array result if json.is_array value
  result

--- Merges what is on disk over the defaults.
--
-- Recursive, so a nested group of settings gains a key without the file having
-- to be rewritten. A list is taken from disk whole rather than merged item by
-- item: merging two lists by index gives a result neither side wrote.
--
-- Keys on disk that the defaults do not mention are kept. They are usually a
-- setting from a newer version, or a hand-written note, and dropping them would
-- mean opening an older build silently deleted them.
---@param defaults table
---@param stored table|nil
---@return table
---@private
merge = (defaults, stored) ->
  return copy defaults unless type(stored) == "table"

  result = {}

  for key, value in pairs defaults
    incoming = stored[key]

    if incoming == nil or incoming == json.null
      result[key] = copy value
    elseif json.is_array value
      -- The marker does not survive a round trip through cjson, so an empty
      -- list read back from disk has to be told it is one again.
      result[key] = json.array (type(incoming) == "table" and incoming or {})
    elseif type(value) == "table" and type(incoming) == "table"
      result[key] = merge value, incoming
    else
      result[key] = incoming

  for key, value in pairs stored
    result[key] = value if result[key] == nil and value != json.null

  result

--- Reads a context's settings, falling back to the defaults.
--
-- A missing file is not an error: it is what every context looks like the first
-- time. A corrupt one is reported and then ignored — the file is left exactly
-- as it is, because it is the only copy of whatever the developer was in the
-- middle of typing, and overwriting it with defaults would destroy the evidence
-- along with the settings.
---@param name string Context name.
---@param defaults? table Merged under whatever is on disk.
---@return table values Always a table, never nil.
---@return string|nil err What went wrong, when something did.
M.load = (name, defaults = {}) ->
  path = M.path name

  return (merge defaults, nil), nil unless fs.is_file path

  text, read_err = fs.read path, true
  unless text
    message = "cannot read #{path}: #{tostring read_err}"
    log.warn "settings: %s", message
    return (merge defaults, nil), message

  -- Notepad, PowerShell's Set-Content and several editors put a UTF-8 byte
  -- order mark at the front, and cjson rejects it as an invalid token at
  -- character 1 - a message that points at the one character nobody typed.
  -- These files exist to be edited by hand, so the editors people actually
  -- have must not be able to break them.
  text = text\gsub "^\239\187\191", ""

  stored, decode_err = json.try_decode text
  unless type(stored) == "table"
    reason = decode_err and tostring(decode_err) or "it is not a JSON object"
    message = "#{path} could not be read: #{reason}"
    log.warn "settings: %s - using defaults, the file is left alone", message
    return (merge defaults, nil), message

  (merge defaults, stored), nil

--- Writes a context's settings.
--
-- Returns the message rather than raising, and rather than finding somewhere
-- else to write. The caller is expected to show it.
---@param name string Context name.
---@param values table
---@return boolean|nil ok True, or nil on failure.
---@return string|nil err
M.save = (name, values) ->
  encoded_ok, encoded = pcall json.encode_pretty, values
  unless encoded_ok
    message = "#{name} settings could not be encoded: #{tostring encoded}"
    log.error "settings: %s", message
    return nil, message

  folder = M.folder!
  unless fs.is_dir folder
    made, make_err = attempt fs.make_dir, folder
    unless made
      message = "cannot create #{folder}: #{make_err}"
      log.error "settings: %s", message
      return nil, message

  path = M.path name

  -- A trailing newline, because this is a text file and every editor expects
  -- one.
  written, write_err = attempt fs.write, path, encoded .. "\n", true
  unless written
    message = "cannot write #{path}: #{write_err}"
    log.error "settings: %s", message
    return nil, message

  log.debug "settings: wrote %s", path
  true

M
