-- The shell: what it renders, and what it does once a browser has it.
--
-- The first half is string handling and needs nothing. The second opens the
-- real window, because the whole point of the chrome is that it replaces the
-- one Windows would have drawn, and only a browser can say whether it did.
--
--   Run from dist\:  ..\vendor\neutrino\deps\luajit\bin\luajit.exe tests\shell.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json
ui = Neutrino.ui

page = require "shell.page"
menus = require "shell.menus"

print "WowLabs: shell"

t.load_native!

-- ═══════════════════════════════════════════════════════════════════════════
-- Rendering
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Markup"

markup = page.render!

t.check "the shell renders", #markup > 1000, "#{#markup} bytes"
t.check "the title bar is draggable", markup\match('class="drag') != nil
t.check "and its buttons are not",
  markup\match('class="no%-drag') != nil
t.check "every menu reaches the bar",
  #[1 for _ in markup\gmatch 'class="menu%-title"'] == #menus.bar,
  "#{#[1 for _ in markup\gmatch 'class="menu%-title"']} of #{#menus.bar}"
t.check "an accelerator is shown beside its command",
  markup\match("Ctrl%+S") != nil
t.check "a command that depends on state says so",
  markup\match('data%-attr%-data%-disabled="!%(dirty%)"') != nil

-- The template escapes by default, which is what keeps a label from becoming
-- markup. Worth an assertion because it is the kind of thing that only breaks
-- once somebody writes a label with an ampersand in it.
menus.extend "help", { { label: "A <b>label</b> & more", action: "void 0" } }
escaped = page.render!
t.check "a label is escaped rather than inserted",
  escaped\match("<b>label</b>") == nil and
    escaped\match("&lt;b&gt;label") != nil

t.section "Menus as data"

t.check "a module can add to a menu", menus.extend "file", {
  { label: "Open table...", action: "neutrino.invoke('dbc:open')" }
}
t.check "and is told when the menu does not exist",
  (menus.extend "nowhere", {}) == false
t.check "the addition reaches the markup",
  (page.render!)\match("Open table") != nil

-- ═══════════════════════════════════════════════════════════════════════════
-- In a window
-- ═══════════════════════════════════════════════════════════════════════════

app = Neutrino.App {
  cache_path: "#{Neutrino.paths.root}/cache"
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

  t.task "shell suite", ->
    -- mount creates the window on "ready", which has just fired; the wait is
    -- for the handler order rather than for anything slow.
    t.wait_until -> shell.window != nil
    window = shell.window

    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    t.section "The window"

    t.check "it is frameless", window\is_valid!
    t.check "and hidden until the interface has rendered",
      (t.wait_until -> window\is_visible!), "never shown"

    t.section "The stylesheet reached it"

    -- Tailwind is compiled at build time into static/app.css and served over
    -- the scheme. If that path breaks, everything still renders - unstyled -
    -- and the window looks like a broken web page rather than a tool.
    background = window\eval "getComputedStyle(document.body).backgroundColor"
    t.check "the theme's background is applied", background == "rgb(14, 14, 17)",
      tostring background

    t.check "and a token colour resolved",
      (window\eval "getComputedStyle(document.documentElement)
        .getPropertyValue('--color-accent').trim()") == "#d2a15a",
      window\eval "getComputedStyle(document.documentElement)
        .getPropertyValue('--color-accent').trim()"

    t.section "The menu bar"

    open_menus = -> window\eval "
      [...document.querySelectorAll('.menu-title')]
        .filter(el => el.classList.contains('is-open')).length"

    t.check "nothing is open to start with", open_menus! == 0

    window\exec_js "document.querySelectorAll('.menu-title')[0].click()"
    t.check "clicking a title opens it", (t.wait_until -> open_menus! == 1)

    t.check "and its panel is on screen",
      (window\eval "[...document.querySelectorAll('.menu-title')][0]
        .nextElementSibling.hidden") == false

    -- The backdrop is what makes a menu behave like a menu rather than like a
    -- panel that stays open until clicked again.
    window\exec_js "document.querySelector('.fixed.inset-0').click()"
    t.check "clicking away closes it", (t.wait_until -> open_menus! == 0)

    t.section "The window buttons"

    t.check "the chrome draws three of them",
      (window\eval "document.querySelectorAll('.window-button').length") == 3

    window\exec_js "document.querySelectorAll('.window-button')[1].click()"
    t.check "maximise reaches the window",
      (t.wait_until -> window\is_maximized!), "not maximised"
    t.check "and the interface is told",
      (t.wait_until -> (window\eval "nui.get('maximized')") == true)

    window\exec_js "document.querySelectorAll('.window-button')[1].click()"
    t.check "and again restores it",
      (t.wait_until -> not window\is_maximized!), "still maximised"

    t.section "The empty state"

    t.check "it says what to do next",
      (window\eval "document.body.innerText")\match("No workspace open") != nil

    window\close true

    t.done!
    app\quit!

app\run!
t.finish!
