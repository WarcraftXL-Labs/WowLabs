-- Settings on disk, the workspace model on top of them, and the page that
-- edits both.
--
-- The first two thirds touch only the filesystem and need nothing. The last
-- third opens the real window, because "the page shows one section at a time"
-- is a claim about what is on screen and only a browser can settle it.
--
--   Run from dist\:  ..\vendor\neutrino\deps\luajit\bin\luajit.exe tests\settings.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
fs = Neutrino.fs
json = Neutrino.json

settings = require "settings"

print "WowLabs: settings"

t.load_native!

-- Everything here writes, so it writes somewhere disposable. `folder` being a
-- function is what makes that possible: the module is told where its files
-- are rather than working the answer out twice.
base = ((os.getenv("TEMP") or os.getenv("TMP") or ".")\gsub "\\", "/")
temp = "#{base}/wowlabs-settings-#{os.time!}-#{os.clock! * 1000000 % 100000}"
fs.make_dir temp

settings.folder = -> temp

DEFAULTS = {
  build: "3.3.5.12340"
  output: ""
  nested: { depth: 1, keep: "yes" }
  recent: json.array {}
}

-- ═══════════════════════════════════════════════════════════════════════════
-- Defaults
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Defaults"

fresh = settings.load "absent", DEFAULTS

t.check "a missing file is not an error", fresh.build == "3.3.5.12340"
t.check "and an empty list comes back a list", json.is_array fresh.recent

-- The caller's table is the caller's. Merging into it would mean the second
-- load of a context started from whatever the first one was handed.
fresh.build = "scribbled on"
again = settings.load "absent", DEFAULTS
t.check "the defaults are copied rather than handed out",
  again.build == "3.3.5.12340", again.build

settings.save "partial", { build: "3.3.5.12213" }
merged = settings.load "partial", DEFAULTS

t.check "a file that predates a setting still gets that setting's default",
  merged.output == "" and merged.nested.depth == 1,
  "#{tostring merged.output} / #{tostring merged.nested.depth}"
t.check "and what the file does say wins", merged.build == "3.3.5.12213",
  merged.build

settings.save "grouped", { nested: { depth: 9 } }
grown = settings.load "grouped", DEFAULTS
t.check "a nested group merges key by key",
  grown.nested.depth == 9 and grown.nested.keep == "yes",
  "#{tostring grown.nested.depth} / #{tostring grown.nested.keep}"

-- Usually a setting from a newer build, or a note somebody left themselves.
-- Dropping it would mean opening an older build silently deleted it.
settings.save "extra", { build: "3.3.5.12340", from_a_later_build: 7 }
kept = settings.load "extra", DEFAULTS
t.check "a key the defaults do not mention is kept",
  kept.from_a_later_build == 7, tostring kept.from_a_later_build

-- ═══════════════════════════════════════════════════════════════════════════
-- A round trip through disk
-- ═══════════════════════════════════════════════════════════════════════════

t.section "A round trip through disk"

document = {
  build: "3.3.5.12340"
  locale: "frFR"
  reopen: false
  recent: json.array { "E:/one", "E:/two" }
}

ok, err = settings.save "trip", document
t.check "saving reports success", ok == true, tostring err

path = settings.path "trip"
t.check "and there is a file where it said there would be", fs.is_file path

text = fs.read path, true
_, lines = text\gsub "\n", ""
t.check "written over several lines rather than one", lines > 3, text

-- Sorted, so a hand edit shows up as one changed line rather than as a whole
-- new file.
t.check "and with its keys in a stable order",
  (text\find '"build"') < (text\find '"locale"') and
    (text\find '"locale"') < (text\find '"recent"'), text

settings.save "trip", document
t.check "the same values produce the same bytes",
  (fs.read path, true) == text

back = settings.load "trip", {}
t.check "the values come back", back.locale == "frFR" and back.reopen == false,
  "#{tostring back.locale} / #{tostring back.reopen}"
t.check "and a list comes back a list", back.recent[2] == "E:/two",
  tostring back.recent[2]

-- ═══════════════════════════════════════════════════════════════════════════
-- A corrupt file
-- ═══════════════════════════════════════════════════════════════════════════

t.section "A corrupt file"

broken_path = settings.path "broken"
fs.write broken_path, '{ "build": "3.3.5.12340",\n  oops\n', true

values, broken_err = settings.load "broken", DEFAULTS

t.check "it does not raise", values != nil
t.check "the defaults are used instead", values.build == "3.3.5.12340",
  tostring values.build
t.check "it is reported rather than swallowed",
  broken_err != nil and (broken_err\find "broken") != nil, tostring broken_err

-- The file is the only copy of whatever was being typed. Replacing it with
-- defaults would destroy the evidence along with the settings.
t.check "and the bad file is left exactly as it was",
  ((fs.read broken_path, true)\find "oops") != nil,
  "the corrupt file was overwritten"

-- A file saved by Notepad, or by PowerShell's Set-Content, begins with a UTF-8
-- byte order mark. cjson calls that an invalid token at character 1, which
-- points at the one character nobody typed.
fs.write (settings.path "marked"), "\239\187\191{ \"build\": \"3.3.5.12213\" }", true
marked, marked_err = settings.load "marked", DEFAULTS
t.check "a byte order mark does not make a file corrupt",
  marked.build == "3.3.5.12213", "#{tostring marked.build} / #{tostring marked_err}"

-- ═══════════════════════════════════════════════════════════════════════════
-- Somewhere it cannot write
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Somewhere it cannot write"

-- A directory standing where the file goes. Reliable on every platform, and
-- indistinguishable, from inside the module, from a folder it has no
-- permission for.
blocked = "#{temp}/blocked"
fs.make_dir "#{blocked}/unwritable.json"

settings.folder = -> blocked
blocked_ok, blocked_err = settings.save "unwritable", { build: "3.3.5.12340" }

t.check "saving reports failure rather than raising", blocked_ok == nil
t.check "and names the path it could not write",
  blocked_err != nil and (blocked_err\find "unwritable.json") != nil,
  tostring blocked_err

-- A file standing where the folder goes: the other half of the same problem.
obstacle = "#{temp}/obstacle"
fs.write obstacle, "not a folder", true
settings.folder = -> "#{obstacle}/config"

folder_ok, folder_err = settings.save "anything", { a: 1 }
t.check "a folder that cannot be created is reported too", folder_ok == nil,
  tostring folder_err
t.check "and says which folder", folder_err != nil and
  (folder_err\find "obstacle") != nil, tostring folder_err

settings.folder = -> temp

-- The point of the whole exercise. A tool that quietly moved the settings
-- somewhere writable would be worse than one that said it could not save,
-- because the failure would be invisible until they were looked for.
t.check "and nothing was written anywhere else",
  not fs.is_file "#{temp}/unwritable.json"
t.check "nor under app data",
  not fs.is_file "#{Neutrino.paths.data_dir "WowLabs"}/config/unwritable.json"

-- ═══════════════════════════════════════════════════════════════════════════
-- The workspace
-- ═══════════════════════════════════════════════════════════════════════════

t.section "The workspace"

workspace = require "workspace"
workspace.reload!

t.check "nothing is open to begin with", workspace.current! == nil
t.check "and the build defaults to 3.3.5a",
  (workspace.setting "build") == "3.3.5.12340", workspace.setting "build"

missing, missing_err = workspace.open "#{temp}/not-there"
t.check "opening a folder that is not there fails rather than raising",
  missing == nil
t.check "and says which folder", missing_err != nil and
  (missing_err\find "not%-there") != nil, tostring missing_err

client = "#{temp}/client"
fs.make_dir client

-- Other code learns about a change through a listener, not by polling.
heard = {}
workspace.on_change (open) -> table.insert heard, open and open.path or "(closed)"

opened, open_err = workspace.open client
t.check "opening a folder that is there works", opened != nil, tostring open_err
t.check "the listener was told", #heard == 1, "#{#heard} announcements"
t.check "and told what was opened",
  heard[1] != nil and (fs.comparable heard[1]) == (fs.comparable client),
  tostring heard[1]

current = workspace.current!
t.check "current reports it", current != nil and
  (fs.comparable current.path) == (fs.comparable client),
  current and current.path or "nothing open"

recent = workspace.recent!
t.check "and it reaches the recent list",
  recent[1] != nil and (fs.comparable recent[1]) == (fs.comparable client),
  tostring recent[1]

workspace.open client
listed = workspace.recent!
t.check "opening it again does not list it twice", #listed == 1,
  "#{#listed} entries"

-- A fresh read of the same file: what the next launch would see.
workspace.reload!
restored = workspace.current!
t.check "it is still open after a reload", restored != nil and
  (fs.comparable restored.path) == (fs.comparable client),
  restored and restored.path or "nothing open"

t.check "a setting can be changed", (workspace.set "locale", "frFR") == true
workspace.reload!
t.check "and survives a reload", (workspace.setting "locale") == "frFR",
  workspace.setting "locale"

t.check "the output folder falls back to one inside the workspace",
  (fs.comparable workspace.output_dir!) == (fs.comparable fs.join client, "output"),
  workspace.output_dir!

workspace.close!
t.check "closing leaves nothing open", workspace.current! == nil
kept_recent = workspace.recent!
t.check "but keeps the recent list", #kept_recent == 1, "#{#kept_recent} entries"

-- ═══════════════════════════════════════════════════════════════════════════
-- The page, as markup
-- ═══════════════════════════════════════════════════════════════════════════

t.section "The page"

settings_page = require "shell.settings"

-- Registered the way a module registers one, and before the page is rendered.
-- That is the whole claim being tested: the shell knows nothing about this
-- section and renders it anyway.
settings_page.register {
  id: "example"
  label: "Example"
  icon: "search"
  fields: {
    { type: "text", path: "settings.example.name", label: "Name" }
    {
      type: "choice"
      path: "settings.example.mode"
      label: "Mode"
      options: { { value: "first", label: "First" }, { value: "second", label: "Second" } }
    }
    { type: "toggle", path: "settings.example.on", label: "On" }
    { type: "folder", path: "settings.example.where", label: "Where" }
  }
  values: -> { name: "", mode: "first", on: true, where: "" }
}

t.check "a section without an id is refused",
  (pcall settings_page.register, { label: "No id" }) == false
t.check "and a field without a type is refused",
  (pcall settings_page.register, {
    id: "bad", label: "Bad", fields: { { path: "settings.bad.x" } }
  }) == false

page = require "shell.page"
markup = page.render!

navs = #[1 for _ in markup\gmatch 'class="settings%-nav"']
t.check "every registered section reaches the nav", navs == #settings_page.list,
  "#{navs} of #{#settings_page.list}"

t.check "a text field binds to the store path it declared",
  (markup\match 'data%-model="settings.example.name"') != nil
t.check "a choice renders its options",
  (markup\match '<option value="second">') != nil
t.check "a toggle renders a checkbox",
  (markup\match 'type="checkbox"') != nil
t.check "and a folder field gets a button that opens the dialog",
  (markup\match "shell:settings%-browse") != nil

-- A field bound to a path the store was never given binds to nothing at all,
-- so the declaration and the field have to agree.
declared = settings_page.state!
t.check "every field's path is declared in the store",
  declared.settings.example.name != nil and
    declared.settings.example.mode != nil and
    declared.settings.example.on != nil and
    declared.settings.example.where != nil
t.check "and the page opens on the first section",
  declared.settings_section == settings_page.first!,
  declared.settings_section

-- A label is data. It is escaped for the same reason a menu label is.
settings_page.register {
  id: "escaping"
  label: "A <b>label</b> & more"
  fields: {}
  values: -> {}
}
escaped = page.render!
t.check "a section label is escaped rather than inserted",
  (escaped\match "<b>label</b>") == nil and
    (escaped\match "&lt;b&gt;label") != nil

-- ═══════════════════════════════════════════════════════════════════════════
-- The page, in a window
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

  t.task "settings suite", ->
    t.wait_until -> shell.window != nil
    window = shell.window

    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    state = shell.state

    -- Which section is on screen, by the heading it draws. Exactly one should
    -- ever answer.
    showing = -> window\eval "
      [...document.querySelectorAll('h2')]
        .filter(el => el.offsetParent !== null)
        .map(el => el.textContent.trim()).join('|')"

    t.section "Opening the page"

    t.check "nothing is open in the work area to start with",
      (window\eval "nui.get('tabs').length") == 0

    window\exec_js "neutrino.invoke('shell:settings')"
    t.check "the settings action opens it",
      (t.wait_until -> (window\eval "nui.get('active_tab')") == "settings")

    -- A page, not a modal: it is a tab in the work area, so it can be left
    -- open while something else is done.
    t.check "as a tab rather than as a dialog",
      (window\eval "nui.get('tabs').length") == 1 and
        (window\eval "nui.get('dialog')") == ""

    window\exec_js "neutrino.invoke('shell:settings')"
    async.sleep 120
    t.check "and opening it twice does not open two",
      (window\eval "nui.get('tabs').length") == 1,
      window\eval "nui.get('tabs').length"

    t.section "Switching sections"

    t.check "it opens on the first section", showing! == "Workspace", showing!

    window\exec_js "document.querySelectorAll('.settings-nav')[1].click()"
    t.check "choosing another shows that one instead",
      (t.wait_until -> showing! == "Example"), showing!

    t.check "and only one section is on screen at a time",
      (showing!\find "|", 1, true) == nil, showing!

    t.check "the chosen one is marked in the nav",
      (window\eval "[...document.querySelectorAll('.settings-nav')]
        .filter(el => el.classList.contains('is-active')).length") == 1

    t.section "Saving"

    window\exec_js "document.querySelectorAll('.settings-nav')[0].click()"
    t.check "back on the workspace section",
      (t.wait_until -> showing! == "Workspace"), showing!

    window\exec_js "nui.set('settings.workspace.locale', 'deDE')"
    t.check "a field edit reaches Lua",
      (t.wait_until -> (state\get "settings.workspace.locale") == "deDE")

    -- Saving is the button, not the keystroke and not the blur. Asserted
    -- against the bytes on disk rather than against the model: reloading the
    -- model here would announce a change, and the page would answer it by
    -- refreshing the very field under test.
    before_save = fs.read (settings.path "workspace"), true
    t.check "and nothing is written until Save is pressed",
      (before_save\find "deDE") == nil, before_save

    window\exec_js "nui.set('settings_dirty', true)"
    window\exec_js "neutrino.invoke('shell:settings-save', 'workspace')"

    t.check "pressing it writes through to the model",
      (t.wait_until -> (workspace.setting "locale") == "deDE"),
      workspace.setting "locale"
    t.check "and the page stops saying there are unsaved changes",
      (t.wait_until -> (window\eval "nui.get('settings_dirty')") == false)
    t.check "and says so where it can be seen",
      (window\eval "nui.get('settings_status')") == "Saved",
      window\eval "nui.get('settings_status')"

    t.section "A save that fails"

    -- The same directory-in-the-way, so the write fails for a reason the page
    -- has no way to fix.
    obstructed = "#{temp}/obstructed"
    fs.make_dir "#{obstructed}/workspace.json"
    settings.folder = -> obstructed

    window\exec_js "nui.set('settings.workspace.build', '3.3.5.12213')"
    t.wait_until -> (state\get "settings.workspace.build") == "3.3.5.12213"
    window\exec_js "nui.set('settings_dirty', true)"
    window\exec_js "neutrino.invoke('shell:settings-save', 'workspace')"

    t.check "a failure is shown on the page rather than only in the log",
      (t.wait_until -> (window\eval "nui.get('settings_error')") != ""),
      window\eval "nui.get('settings_error')"
    t.check "and names the file it could not write",
      (window\eval "nui.get('settings_error')")\find("workspace.json") != nil,
      window\eval "nui.get('settings_error')"

    -- Nothing reached the disk, so the edits are still the only copy of them
    -- and the button has to stay live.
    t.check "and the changes are still there to try again",
      (window\eval "nui.get('settings_dirty')") == true

    settings.folder = -> temp

    t.section "The workspace reaches the chrome"

    workspace.open client
    t.check "the title bar follows the model",
      (t.wait_until -> (window\eval "nui.get('workspace')") != ""),
      window\eval "nui.get('workspace')"
    t.check "the status bar is told the build",
      (window\eval "nui.get('build')") != "",
      window\eval "nui.get('build')"
    t.check "and the recent list reaches the File menu",
      (window\eval "nui.get('recent').length") > 0

    t.check "the File menu draws one entry per recent workspace",
      (t.wait_until -> (window\eval "[...document.querySelectorAll('.menu-item span')]
        .filter(el => el.textContent.includes('client')).length") > 0)

    t.section "Closing the page"

    window\exec_js "neutrino.invoke('shell:close-tab', 'settings')"
    t.check "the tab closes",
      (t.wait_until -> (window\eval "nui.get('tabs').length") == 0)
    t.check "and nothing is left active",
      (window\eval "nui.get('active_tab')") == ""

    window\close true

    t.done!
    app\quit!

app\run!
t.finish!
