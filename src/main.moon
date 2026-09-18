--- WowLabs: a development environment for World of Warcraft modding.
--
-- The entry point, and nothing else: it brings up logging, the scheme server
-- and the shell window, then hands over. Everything the application does lives
-- in a module under src/modules/.
--
--   .\tools\run.ps1
---@module main

Neutrino = require "neutrino"

log = Neutrino.log
paths = Neutrino.paths

APP_NAME = "WowLabs"

-- Before anything else can fail. A packaged build has no console, so without
-- this the first real problem is invisible - and the first real problem is the
-- one worth seeing.
log.open log.app_data_path APP_NAME
log.capture!
log.info "%s starting from %s", APP_NAME, tostring paths.root

Neutrino.cef.setup paths.bin

app = Neutrino.App {
  cache_path: "#{paths.data_dir APP_NAME}/cache"
  resources_path: paths.bin
  locales_path: "#{paths.bin}/locales"
  subprocess_path: "#{paths.bin}/neutrinocef_helper.exe"

  -- The window is frameless and draws its own chrome, so the background behind
  -- it has to match or the first frame flashes white.
  background: { 14, 14, 17 }
}

server = app\server!
server\static "/assets", "static"

shell = require "shell.window"
shell.mount app, server

app\run!

log.info "%s exited", APP_NAME
log.close!
