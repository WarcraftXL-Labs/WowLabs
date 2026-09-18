--- The application window and the chrome it draws itself.
--
-- Frameless, because the title bar is also the menu bar and both belong to the
-- application rather than to Windows. Everything the system would have drawn -
-- dragging, minimise, maximise, close - is wired here to what the page asks
-- for, and the page asks through IPC like any other action.
---@module shell.window

Neutrino = require "neutrino"
page = require "shell.page"

async = Neutrino.async
json = Neutrino.json
log = Neutrino.log
ui = Neutrino.ui

M = {}

--- The store the interface starts from.
--
-- Declared in one place and in full: the runtime only answers for keys it was
-- given, so a key that appears later is a key no expression can read.
---@return table
initial_state = ->
  {
    -- Chrome
    menu: ""                  -- the open menu, or ""
    maximized: false
    side_open: true
    status_open: true
    activity: "explorer"
    dialog: ""                -- the open dialog, or ""

    -- Workspace
    workspace: ""             -- the folder, shown in the title bar
    build: ""                 -- the client build it was opened as
    status: "Ready"

    -- Work
    tabs: json.array {}
    active_tab: ""
    dirty: false
    can_undo: false
    can_redo: false

    -- Two glyphs the chrome swaps between. Markup rather than a class, because
    -- they are different shapes and not the same shape restyled.
    icon_maximize: page.icon "maximize"
    icon_restore: page.icon "restore"
  }

--- Serves the shell and opens the window.
---@param app App
---@param server Server
---@return table The window and its state, once the app is ready.
M.mount = (app, server) ->
  server.router\get "/", (req, res) ->
    res\html ui.document {
      title: "WowLabs"
      lang: "en"
      head: '<link rel="stylesheet" href="neutrino://app/assets/app.css">'
      state: initial_state!
      body: page.render!
    }

  app\on "ready", ->
    window = Neutrino.BrowserWindow {
      title: "WowLabs"
      url: "neutrino://app/"
      -- 1280x720 is both the size it opens at and the smallest it goes. A tool
      -- with this much chrome has a floor below which panes start fighting
      -- each other, and it is better to refuse than to degrade. Above it the
      -- layout is fluid, because this is usually run maximised on 1920x1080.
      width: 1280
      height: 720
      min_width: 1280
      min_height: 720
      frameless: true
      background: { 14, 14, 17 }

      -- Shown once the interface has rendered rather than on creation, so the
      -- first thing on screen is the application and not an empty frame.
      show: false
    }

    state = ui.State window, initial_state!
    M.window = window
    M.state = state

    -- ── Window chrome ─────────────────────────────────────────────────────

    sync_maximized = -> state\set "maximized", window\is_maximized!

    window\handle "shell:minimize", ->
      window\minimize!
      nil

    window\handle "shell:maximize", ->
      if window\is_maximized! then window\restore! else window\maximize!
      sync_maximized!
      nil

    window\handle "shell:close", ->
      window\close!
      nil

    window\handle "shell:devtools", ->
      window\toggle_devtools!
      nil

    -- Dragging a maximised window by its title bar restores it, and snapping
    -- it to an edge maximises it, neither of which goes through our buttons.
    window\on "bounds-changed", -> sync_maximized!

    -- ── Placeholders ──────────────────────────────────────────────────────
    --
    -- Wired so the interface is honest about what exists: a menu entry that
    -- does nothing at all is worse than one that says so.

    window\handle "shell:open-workspace", ->
      async.run ->
        paths = window\show_folder_dialog { title: "Open workspace" }
        return unless paths and paths[1]

        state\set "workspace", paths[1]
        state\set "status", "Workspace opened"
        log.info "workspace opened: %s", paths[1]
      nil

    for channel in *{ "shell:save", "shell:save-all", "shell:undo", "shell:redo" }
      do
        name = channel\match ":(.+)$"
        window\handle channel, ->
          state\set "status", "#{name}: not implemented yet"
          log.warn "%s is not implemented yet", channel
          nil

    -- ── Ready ─────────────────────────────────────────────────────────────

    window\on "did-finish-load", (detail) ->
      return unless detail.url and detail.url\match "^neutrino://app/"

      sync_maximized!
      window\show!
      log.info "shell ready"

    window

M
