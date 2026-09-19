--- The DBC table editor.
--
-- The tool that opens a client's DBC files, shows one as a grid, edits it and
-- writes it back. It registers itself with the shell - a category, a rail, a
-- strip, a panel and a work area - and the shell knows nothing about tables.
--
-- This file is the manifest: what the tool contributes to the shell, what it
-- puts in the store, what its settings are, and the `mount` that hands the
-- window and the store to the two halves below.
--
--   library   finds the client's tables and opens them
--   editor    one open table, with the stack that takes back what was done
--   changes   what a session amounts to, and the Lua that reproduces it
--   query     the search language
--   relations what points at what, across the whole client
--   session   which tables are open, which is in front, what the page is told
--   handlers  one channel per thing the interface can ask for
--   view      the markup, from `views/`; `scripts/` is what drives the page
--
-- One session per table, kept when the user looks at another one. Closing a
-- tab hides a table, it does not discard the edits: the tab bar is where you
-- are, not what is loaded, and a click that silently threw away an afternoon
-- would be the worst button in the application.
---@module modules.dbc

Neutrino = require "neutrino"

editor = require "modules.dbc.editor"
handlers = require "modules.dbc.handlers"
library = require "modules.dbc.library"
session = require "modules.dbc.session"
view = require "modules.dbc.view"

menus = require "shell.menus"
page = require "shell.page"
resources = require "resources"
sections = require "shell.settings"
tools = require "shell.tools"
workspace = require "workspace"

json = Neutrino.json

M = {}

-- The answers the "Localised columns" setting accepts. A file written by
-- hand with something else in it falls back rather than showing no columns.
LOCALE_MODES = { present: true, all: true, workspace: true }

-- ═══════════════════════════════════════════════════════════════════════════
-- Behaviour
-- ═══════════════════════════════════════════════════════════════════════════

--- Wires the channels the page invokes.
---@param window BrowserWindow
---@param state State
M.mount = (window, state) ->

  --- Installs what the page needs that markup cannot express.
  --
  -- Two libraries, laid out and driven from `scripts/`: the relations graph and
  -- the grid. Both are the same kind of thing - a container, a configuration
  -- and a handful of callbacks - and neither can be expressed as markup with
  -- data-attributes on it.
  --
  -- Run here rather than fetched by a tag in the document head, because they
  -- are written against `nui` and `neutrino`, which the page does not have
  -- until it has loaded. That timing is the whole reason this is a function
  -- and not markup, and it is what caught us out once already.
  install_page_helpers = ->
    -- The numbers the page and Lua both work from, handed over rather than
    -- written twice. A long string does not interpolate, so this goes first.
    window\exec_js "window.DBC = { page: #{view.METRICS.page},
      row: #{view.METRICS.row}, index: #{view.METRICS.index} }"

    -- One evaluation rather than three. The scripts are written against a
    -- shared top-level scope - the grid waits on the guard the graph declared -
    -- so they are joined and run as one, which is what they were when they
    -- were a single string. The order is the order they depend on.
    window\exec_js resources.joined "modules/dbc/scripts/graph.js",
      "modules/dbc/scripts/picker.js",
      "modules/dbc/scripts/grid.js"

  -- What the two halves of this tool are given instead of capturing it. The
  -- window and the store arrive here and nowhere else, so there is one place
  -- to look when something needs them.
  ctx = { :window, :state }

  session.attach ctx
  handlers.install ctx

  -- What File > Save and Edit > Undo reach when this tool is the active one.
  M.tool.commands = {
    undo: session.undo
    redo: session.redo
    save: session.save
    "save-all": session.save_all
  }

  -- Not now: mount runs while the window is still coming up, and the store is
  -- inlined into the document, so `nui` does not exist yet and the whole
  -- script would fail - taking the column drag with it, silently.
  window\on "did-finish-load", (detail) ->
    return unless detail.url and detail.url\match "^neutrino://app/"
    install_page_helpers!

  session.reload_tables!
  session.refresh false

-- ═══════════════════════════════════════════════════════════════════════════
-- Registration
-- ═══════════════════════════════════════════════════════════════════════════

icon = page.icon

M.tool = tools.register {
  id: "dbc"
  label: "DBC Editor"
  icon: "table"
  description: "Open the client's DBC tables and edit them row by row."

  -- Tabulator's own, loaded with the page rather than on demand the way
  -- Cytoscape is: the graph is a view most sessions never open, and the grid
  -- is what this tool *is*. Deferring it would put a promise in the one path
  -- that must not race the container's measurement.
  --
  -- Before the application's stylesheet, so a rule of ours beats one of
  -- Tabulator's at the same specificity.
  head: '<link rel="stylesheet" href="neutrino://app/assets/tabulator.min.css">' ..
    '<script src="neutrino://app/assets/tabulator.min.js"></script>'

  actions: {
    {
      id: "list"
      icon: "table"
      title: "Tables"
      action: "side_open = !side_open"
    }
    {
      id: "add"
      icon: "plus"
      title: "New row"
      action: "neutrino.invoke('dbc:add')"

      -- Not on the 22 tables that keep no ID in their records: a new row there
      -- would be a row nothing can name. Duplicating one works everywhere,
      -- because that copies bytes rather than inventing a key.
      shown: "dbc_open !== '' && dbc_info.has_id"
    }
    {
      id: "duplicate"
      icon: "copy"
      title: "Duplicate row"
      action: "neutrino.invoke('dbc:duplicate')"
    }
    {
      id: "delete"
      icon: "trash"
      title: "Delete row"
      action: "neutrino.invoke('dbc:delete')"
    }
    {
      id: "undo"
      icon: "undo"
      title: "Undo"
      action: "neutrino.invoke('dbc:undo')"
    }
    {
      id: "redo"
      icon: "redo"
      title: "Redo"
      action: "neutrino.invoke('dbc:redo')"
    }
    {
      id: "save"
      icon: "save"
      title: "Save"
      action: "neutrino.invoke('dbc:save')"
    }

    -- These two answer questions about the table rather than changing it, so
    -- they are kept apart from the ones that do.
    { separator: true }
    {
      id: "readable"
      html: "dbc_readable ? dbc_icon_eye : dbc_icon_eye_shut"
      title: "Show referenced rows by name"
      action: "neutrino.invoke('dbc:readable')"
      active: "dbc_readable"
    }
    {
      id: "relations"
      icon: "link"
      title: "What this table is linked to"
      action: "neutrino.invoke('dbc:relations')"
    }
  }

  context: view.context icon
  panel: view.panel icon
  view: view.grid icon

  -- What the shell warns about on the way out, and saves on the timer. Named
  -- the way the user thinks of them, because these are the words the warning
  -- shows - not "3 sessions" but "Spell, AreaTable".
  pending: ->
    [name for name, open in pairs session.all when editor.is_dirty open]

  state: -> {
    -- Read here rather than pushed from `mount`: the store is inlined into
    -- the document, so anything the module knows before the page loads has to
    -- be in this table or the first paint is of an empty list.
    dbc_tables: library.tables!

    dbc_filter: ""
    dbc_open: ""
    dbc_row: 0
    dbc_find: ""
    dbc_message: ""
    dbc_confirm: ""
    dbc_preview: ""
    dbc_preview_open: false

    -- The search over rows: what was typed, why it could not be read, and
    -- whether the reference for writing one is open.
    dbc_query: ""
    dbc_query_error: ""
    dbc_help: false

    -- The banner offering the language the file is actually written in.
    dbc_locale_hint: ""
    dbc_locale_offer: ""

    -- Whether the table list opens on one click or two, and which entry is
    -- merely picked out while waiting for the second.
    dbc_open_on: library.setting "open_on"
    dbc_picked: ""

    -- Bumped whenever the rows or their order have moved on and the grid has
    -- to read them again from the first page. The page watches it; the number
    -- itself means nothing.
    dbc_reload: 0

    -- The columns the grid draws, in order, each saying whether it is on
    -- screen. The grid is rebuilt when this changes and only then.
    dbc_columns: json.array {}
    dbc_cols_open: false

    -- Whether the grid is paging over the changed rows alone.
    dbc_changed_only: false

    -- Referenced ids shown with the row they refer to, and whether a cell
    -- offers that table's rows when it is edited.
    dbc_readable: library.setting("readable") and true or false

    -- Two glyphs the rail swaps between, rather than one restyled: an eye that
    -- is open and an eye that is shut are different shapes.
    dbc_icon_eye: page.icon "eye"
    dbc_icon_eye_shut: page.icon "eye-off"
    dbc_resolver: library.setting "resolver"

    -- The cell being picked for, and what it could be set to.
    dbc_picker: { row: 0, column: 0, table: "", label: "" }
    dbc_choices: json.array {}

    -- The tables that refer to each other, and which one is being looked at.
    dbc_graph: { focus: "", nodes: json.array({}), edges: json.array {} }
    dbc_graph_open: false

    dbc_info: {
      rows: 0, shown: 0, columns: 0, has_id: false, format: "", changes: 0
      spread: false
      from: 0
      locale: workspace.setting "locale"
    }
  }

  mount: M.mount
}

menus.extend "tools", {
  { label: "Refresh table list", action: "neutrino.invoke('dbc:tables')" }
}

-- The other way people look for this: not "what do I type in the box" but
-- "where is the documentation". Same reference either way.
menus.extend "help", {
  { label: "Filtering rows", action: "dbc_help = true" }
}

sections.register {
  id: "dbc"
  label: "DBC Editor"
  icon: "table"
  description: "Where the client's DBC files are, what Save writes, and how
    the grid behaves. The output folder is the workspace's."

  fields: {
    {
      type: "folder"
      path: "settings.dbc.source"
      label: "DBC folder"
      placeholder: "DBFilesClient, inside the workspace"
      help: "Left empty, this is DBFilesClient inside the workspace, then
        Data\\DBFilesClient, then the workspace folder itself."
    }
    {
      type: "choice"
      path: "settings.dbc.save_as"
      label: "Save as"
      options: {
        { value: "dbc", label: "DBC file" }
        { value: "lua", label: "Lua script" }
      }
      help: "The table itself, or the script that reproduces your changes
        through lua-dbc. The script is the one to keep under version control:
        a binary DBC in a diff says only that it changed."
    }
    {
      type: "choice"
      path: "settings.dbc.locales"
      label: "Localised columns"
      options: {
        { value: "present", label: "Languages in the file" }
        { value: "all", label: "All 14 languages" }
        { value: "workspace", label: "The workspace's language only" }
      }
      help: "A localised field holds fourteen strings. Showing the ones the
        file carries is right for reading and for translating; all fourteen is
        how you fill in a language that is not there yet, since the column has
        to exist before anything can be typed into it."
    }
    {
      type: "toggle"
      path: "settings.dbc.locale_hint"
      label: "Offer the file's own language"
      help: "When a table holds text in a language other than the workspace's,
        offer to read and write at that one. Writing at the wrong slot leaves
        a row holding two different names."
    }
    {
      type: "toggle"
      path: "settings.dbc.resolver"
      label: "Pick referenced rows from a list"
      help: "A column like AreaTable.ContinentID refers to another table. With
        this on, editing one offers that table's rows - 12 (Kalimdor) - instead
        of a box to type a number into. It reads the referenced table the first
        time, which is a moment on a large one."
    }
    {
      type: "toggle"
      path: "settings.dbc.verify_fk"
      label: "Verify foreign keys"
      help: "Refuse a value that names a row the referenced table does not
        have. The column would take it - 47 is a good number - and the client
        finds out instead. Off by default: it reads the referenced table to
        answer, and a client being built up has columns pointing at rows that
        are not there yet. Worth switching on to go over a table before
        shipping it."
    }
    {
      type: "choice"
      path: "settings.dbc.open_on"
      label: "Open a table on"
      options: {
        { value: "single", label: "Single click" }
        { value: "double", label: "Double click" }
      }
      help: "Double click keeps a single click for selecting, which is what
        you want when moving through the list rather than opening everything
        on the way past."
    }
  }

  values: -> {
    source: library.setting "source"
    save_as: library.setting "save_as"
    locales: library.setting "locales"
    locale_hint: library.setting "locale_hint"
    resolver: library.setting "resolver"
    verify_fk: library.setting "verify_fk"
    open_on: library.setting "open_on"
  }

  apply: (values) ->
    wanted = type(values.source) == "string" and values.source or ""
    moved = wanted != library.setting "source"

    ok, err = library.set "source", wanted
    return nil, err unless ok

    library.set "save_as", values.save_as == "lua" and "lua" or "dbc"
    library.set "locales", LOCALE_MODES[values.locales] and values.locales or "present"
    library.set "locale_hint", values.locale_hint and true or false
    library.set "resolver", values.resolver and true or false
    library.set "verify_fk", values.verify_fk and true or false
    library.set "open_on", values.open_on == "double" and "double" or "single"

    -- The folder moving means a different set of files, so what is open
    -- belongs to a folder that is no longer the one being edited. Nothing
    -- else here does: a column that appears or disappears is a different view
    -- of the same records, and dropping the sessions for it would throw away
    -- every unsaved change to make a display setting take effect.
    if moved
      library.close!
      session.all = {}
      session.active = nil
    else
      mode = library.setting "locales"
      for _, open in pairs session.all
        open.mode = mode
        open.slots = editor.slots_for mode, open.present
        open.spread = open.slots != nil
        open.columns = editor.columns open.schema, open.locale, open.slots
        -- The column list is a different list, so everything keyed on a column
        -- index describes columns that are no longer there.
        open.widths = {}
        open.hidden = {}
        open.order = nil
        open.sort = nil
        open.from = 0
        open.stale = true

    true
}

M
