--- The application window and the chrome it draws itself.
--
-- Frameless, because the title bar is also the menu bar and both belong to the
-- application rather than to Windows. Everything the system would have drawn -
-- dragging, minimise, maximise, close - is wired here to what the page asks
-- for, and the page asks through IPC like any other action.
---@module shell.window

Neutrino = require "neutrino"
menus = require "shell.menus"
page = require "shell.page"
tools = require "shell.tools"

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
    dialog: ""                -- the open dialog, or ""

    -- The active category. Its rail, its strip and its panel are the ones
    -- shown; everything else stays rendered and hidden.
    tool: tools.first!

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

    -- ── Keyboard ──────────────────────────────────────────────────────────
    --
    -- Straight from the menu data, so a shortcut and the entry that shows it
    -- cannot disagree. A menu that prints "Ctrl+S" beside a command that does
    -- nothing when you press Ctrl+S is worse than one that prints nothing.

    for menu in *menus.bar
      for item in *menu.items
        continue unless item.accelerator and item.action

        -- Run through nui rather than as bare JavaScript: the action is
        -- written against the store, the same as the menu entry's, and this is
        -- what puts the store in scope. `enabled` guards it for the same
        -- reason the entry is greyed out.
        source = item.enabled and
          "if (#{item.enabled}) { #{item.action} }" or item.action
        script = "nui.run(#{json.encode source})"

        ok, err = window\register_accelerator item.accelerator, ->
          window\exec_js script
          true

        log.warn "shortcut %s: %s", item.accelerator, tostring err unless ok

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

      -- Maximised on open. 1280x720 is the floor, not the working size: this
      -- is a tool with four bars of chrome, and at its minimum there is barely
      -- room for the thing you came to edit. Restoring gives that size back.
      window\show!
      window\maximize!
      sync_maximized!

      log.info "shell ready"

    window

M
