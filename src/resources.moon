--- The files a module ships beside its code.
--
-- Markup is etlua and behaviour the page cannot express is JavaScript, and
-- both belong in files of their own kind: an editor that knows the language,
-- a linter that reads it, and a diff about the change rather than about a
-- string. Kept as Lua long strings they are none of those things, and a
-- mistake in one is found by running the application.
--
-- They are read from the build rather than compiled into it, so where they are
-- is where the Lua tree is. That is not the application root: in development
-- the two are the same folder, and a package puts the tree under `app/` beside
-- `static/` and `bin/`. Resolving against the root works in exactly one of
-- those, and the one it fails in is the one nobody runs until the end.
--
-- So it is derived rather than assumed. This file compiles to the top of that
-- tree in both layouts, and it can say where it was loaded from.
---@module resources

Neutrino = require "neutrino"
etlua = require "etlua"

fs = Neutrino.fs
paths = Neutrino.paths

M = {}

--- The folder the application's Lua was loaded from.
---@return string
---@private
tree = ->
  source = debug.getinfo(1, "S").source or ""
  folder = source\match "^@(.*)[/\\][^/\\]+$"
  folder and (folder\gsub "\\", "/") or nil

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

  -- The Lua tree first, then the application root. Both are named in the
  -- failure, because "not found" without the paths tried is the start of the
  -- search rather than the end of it.
  tried = {}
  found = nil

  for base in *{ tree!, paths.root }
    continue unless base

    candidate = "#{base}/#{relative}"
    table.insert tried, candidate

    if fs.is_file candidate
      found = candidate
      break

  unless found
    error "resource #{relative} is not there. Looked in:
      #{table.concat tried, ", "}"

  body, err = fs.read found, true
  error "resource #{relative}: #{err or "could not be read"} (#{found})" unless body

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
