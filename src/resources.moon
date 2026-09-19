--- The files a module ships beside its code.
--
-- Markup is etlua and behaviour the page cannot express is JavaScript, and
-- both belong in files of their own kind: an editor that knows the language,
-- a linter that reads it, and a diff about the change rather than about a
-- string. Kept as Lua long strings they are none of those things, and a
-- mistake in one is found by running the application.
--
-- They are read from the build rather than compiled into it, so `paths.resolve`
-- is what finds them - `dist/` in development, the install root when packaged,
-- and nothing above here has to know which.
---@module resources

Neutrino = require "neutrino"
etlua = require "etlua"

fs = Neutrino.fs
paths = Neutrino.paths

M = {}

-- Read once, compiled once. The same bytes produce the same template every
-- time, and none of these files changes while the application is running.
texts = {}
templates = {}

--- One file, by its path under the application root.
---@param relative string
---@return string
M.text = (relative) ->
  cached = texts[relative]
  return cached if cached

  full = paths.resolve relative
  body, err = fs.read full, true
  error "resource #{relative}: #{err or "not found"} (#{full})" unless body

  texts[relative] = body
  body

--- Several files, joined in the order they are named.
--
-- One string rather than several, because the caller evaluates it as one
-- script: top-level declarations share a lexical scope, so evaluating the
-- parts separately would split the namespace they are written against.
---@param ... string
---@return string
M.joined = (...) ->
  parts = {}
  for relative in *{...}
    table.insert parts, M.text relative

  table.concat parts, "\n"

--- One etlua template, compiled and ready to render.
---@param relative string
---@return fun(env: table): string
M.template = (relative) ->
  cached = templates[relative]
  return cached if cached

  compiled, err = etlua.compile M.text relative
  error "template #{relative}: #{err}" unless compiled

  templates[relative] = compiled
  compiled

M
