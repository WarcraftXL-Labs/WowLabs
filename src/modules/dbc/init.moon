--- The DBC table editor.
--
-- The tool that opens a client's DBC files, shows one as a grid, edits it and
-- writes it back. It registers itself with the shell - a category, a rail, a
-- strip, a panel and a work area - and the shell knows nothing about tables.
--
-- Three files underneath: `library` finds and opens them, `editor` holds one
-- open table with the stack that can take back what was done to it, and
-- `changes` says what the session amounts to and writes the Lua that
-- reproduces it. This file is the wiring.
--
-- One session per table, kept when the user looks at another one. Closing a
-- tab hides a table, it does not discard the edits: the tab bar is where you
-- are, not what is loaded, and a click that silently threw away an afternoon
-- would be the worst button in the application.
---@module modules.dbc

Neutrino = require "neutrino"

changes = require "modules.dbc.changes"
editor = require "modules.dbc.editor"
library = require "modules.dbc.library"
relations = require "modules.dbc.relations"
view = require "modules.dbc.view"

-- Read directly for the graph, which is drawn around a table whether or not
-- one is open: a schema is a question about the definitions, and opening a
-- session to ask it would open a table nobody asked for.
dbc = require "dbc"

menus = require "shell.menus"
page = require "shell.page"
sections = require "shell.settings"
tools = require "shell.tools"
workspace = require "workspace"

fs = Neutrino.fs
json = Neutrino.json

M = {}

-- The answers the "Localised columns" setting accepts. A file written by
-- hand with something else in it falls back rather than showing no columns.
LOCALE_MODES = { present: true, all: true, workspace: true }

-- One per table the user has opened, by name.
sessions = {}

-- The one on screen, or nil.
active = nil

--- The tab a table occupies.
---@param name string
---@return string
---@private
tab_id = (name) -> "dbc:#{name}"

-- ═══════════════════════════════════════════════════════════════════════════
-- Behaviour
-- ═══════════════════════════════════════════════════════════════════════════

--- Wires the channels the page invokes.
---@param window BrowserWindow
---@param state State
M.mount = (window, state) ->
  -- Where the grid is looking, in rows and columns from the top left. Held
  -- here as well as in the store because the page asks for a window it has
  -- already decided on, and answering the same question twice is a redraw.
  at_row, at_col = 0, 0

  say = (message) -> state\set "dbc_message", message or ""

  --- Asks the page to put the grid back at the top.
  --
  -- Through the store rather than by reaching in and setting scrollTop, which
  -- races the redraw in both directions: done too early the incoming table's
  -- layout undoes it, done too late it throws away a scroll made in between.
  -- The counter says *that* the view should go home and the page does it once
  -- it has drawn what it is going home to.
  scroll_to = (top) ->
    state\set "dbc_top", (tonumber(state\get "dbc_top") or 0) + 1

  --- Installs what the page needs that markup cannot express.
  --
  -- Written into the page once rather than inlined in the header: the column
  -- drag is twenty lines of pointer handling, and a copy per column would be
  -- a copy per column to keep right.
  --
  -- The columns are left alone while the pointer moves and a single guide line
  -- follows it instead. Redrawing six hundred inputs on every mousemove would
  -- make dragging the slowest thing in the grid.
  install_page_helpers = ->
    window\exec_js [==[
      // Puts the grid back at the top when Lua says the view has moved on to
      // something else - another table, a search, a sort. Driven by a counter
      // rather than by a position, because "should it be at the top" is an
      // intention and scrollTop is a measurement that layout also changes.
      let seenTop = null
      nui.effect(() => {
        const token = nui.get('dbc_top')
        if (seenTop === token) return
        const first = seenTop === null
        seenTop = token
        if (first) return

        // Decided now, acted on next frame. A view already at the top has
        // nothing to put back, and scheduling a reset anyway would undo a
        // scroll made in the frame between the two.
        const scroller = document.querySelector('.dbc-scroller')
        if (!scroller || scroller.scrollTop === 0) return

        requestAnimationFrame(() => {
          scroller.scrollTop = 0
          scroller.scrollLeft = 0
        })
      })

      // ── The relations graph ──────────────────────────────────────────────
      //
      // Cytoscape, loaded the first time the panel is opened rather than with
      // the page: it is 365 KB to parse for a view most sessions never open.

      let cytoscapeReady = null
      let graph = null

      const loadCytoscape = () => {
        if (cytoscapeReady) return cytoscapeReady

        cytoscapeReady = new Promise((resolve, reject) => {
          const tag = document.createElement('script')
          tag.src = 'neutrino://app/assets/cytoscape.min.js'
          tag.onload = () => resolve(window.cytoscape)
          tag.onerror = () => reject(new Error('cytoscape.min.js did not load'))
          document.head.appendChild(tag)
        })

        return cytoscapeReady
      }

      // Read off the stylesheet rather than written here, so the graph follows
      // the theme instead of being a second copy of it that drifts.
      const token = (name, fallback) => {
        const value = getComputedStyle(document.documentElement)
          .getPropertyValue(name).trim()
        return value || fallback
      }

      // Cytoscape measures its container when it starts, and the panel is
      // hidden until the store update that opens it has been drawn. Started
      // against a box of no size, it lays the whole graph out into a point and
      // then fits the viewport to that point: every node is there, the counts
      // are right, and the screen is empty.
      const withSize = (host) => new Promise((resolve) => {
        let tries = 0
        const tick = () => {
          if (host.clientWidth > 0 && host.clientHeight > 0) return resolve(true)
          if (tries++ > 90) return resolve(false)
          requestAnimationFrame(tick)
        }
        tick()
      })

      const drawGraph = async () => {
        const data = nui.get('dbc_graph')
        const host = document.querySelector('.dbc-canvas')
        if (!host || !data || data.nodes.length === 0) return

        let cytoscape
        try { cytoscape = await loadCytoscape() }
        catch (err) { host.textContent = String(err); return }

        if (!await withSize(host)) return
        if (graph) { graph.destroy(); graph = null }

        const accent = token('--color-accent', '#d2a15a')
        const ink = token('--color-ink', '#e8e6e3')
        const dim = token('--color-ink-dim', '#a8a5a0')
        const line = token('--color-line', '#2a2a30')
        const base = token('--color-base-800', '#1c1c22')

        const elements = []
        for (const node of data.nodes) {
          elements.push({ data: {
            id: node.name,
            label: node.name,
            focus: node.name === data.focus ? 1 : 0,
          }})
        }
        for (const edge of data.edges) {
          elements.push({ data: {
            id: edge.from + '|' + edge.column + '|' + edge.to,
            source: edge.from, target: edge.to, label: edge.column,
          }})
        }

        // The whole client is hundreds of nodes; one table and its neighbours
        // is a dozen. A force layout reads well at the first size and wastes
        // the second, where a ring around the focus says "these are its
        // neighbours" at a glance.
        const wide = data.focus === ''
        const layout = wide
          ? { name: 'cose', animate: false, nodeRepulsion: 9000,
              idealEdgeLength: 110, nestingFactor: 0.8, gravity: 0.6,
              numIter: 900, randomize: true }
          : { name: 'concentric', animate: false, minNodeSpacing: 40,
              concentric: (n) => n.data('focus') ? 10 : 1,
              levelWidth: () => 1 }

        graph = cytoscape({
          container: host,
          elements,
          minZoom: 0.15,
          maxZoom: 3,
          wheelSensitivity: 0.25,
          style: [
            { selector: 'node', style: {
              'background-color': base,
              'border-width': 1,
              'border-color': line,
              'shape': 'round-rectangle',
              'width': 'label', 'height': 18,
              'padding': '7px',
              'label': 'data(label)',
              'color': dim,
              'font-size': wide ? 9 : 11,
              'font-family': 'Inter, system-ui, sans-serif',
              'text-valign': 'center', 'text-halign': 'center',
            }},
            { selector: 'node[focus = 1]', style: {
              'border-color': accent, 'border-width': 2, 'color': ink,
              'font-size': 13,
            }},
            { selector: 'node:selected', style: { 'border-color': accent, 'color': ink }},
            { selector: 'edge', style: {
              'width': 1,
              'line-color': line,
              'target-arrow-color': line,
              'target-arrow-shape': 'triangle',
              'arrow-scale': 0.7,
              'curve-style': 'bezier',
              // Only where there is room to read them. Two hundred column
              // names over a graph of the whole client is a grey haze.
              'label': wide ? '' : 'data(label)',
              'font-size': 9,
              'color': dim,
              'text-background-color': base,
              'text-background-opacity': 0.9,
              'text-background-padding': 2,
            }},
            { selector: 'node.dim, edge.dim', style: { 'opacity': 0.15 }},
          ],
        })

        // Hovering a table picks out what it touches. On the whole-client
        // graph this is the only way to follow one thread through the rest.
        graph.on('mouseover', 'node', (event) => {
          const near = event.target.closedNeighborhood()
          graph.elements().difference(near).addClass('dim')
        })
        graph.on('mouseout', 'node', () => graph.elements().removeClass('dim'))

        graph.on('tap', 'node', (event) => {
          nui.set('dbc_graph_open', false)
          neutrino.invoke('dbc:open', { name: event.target.id(), pinned: true })
        })

        graph.on('dbltap', 'node', (event) => {
          neutrino.invoke('dbc:relations', event.target.id())
        })

        // Run here rather than handed to the constructor, and fitted when it
        // stops: a fit taken while the layout is still moving frames the
        // positions it happened to catch, which is how a graph ends up with
        // half its nodes off the edge.
        const run = graph.layout(layout)
        run.on('layoutstop', () => {
          graph.resize()
          graph.fit(undefined, 40)
        })
        run.run()

        if (window.ResizeObserver) {
          const watcher = new ResizeObserver(() => {
            if (!graph) return
            graph.resize()
            graph.fit(undefined, 40)
          })
          watcher.observe(host)
          graph.on('destroy', () => watcher.disconnect())
        }
      }

      // How many nodes the graph actually holds, which is the only way from
      // outside to tell "the data arrived" from "the picture was drawn".
      window.__cyNodes = () => (graph ? graph.nodes().length : -1)

      // Whether anything is actually on screen: the nodes drawn inside the
      // container, with a size. Everything short of this was true while the
      // graph was being laid out into a single point.
      window.__cyDrawn = () => {
        if (!graph) return 0
        const host = document.querySelector('.dbc-canvas')
        if (!host) return 0

        const width = host.clientWidth
        const height = host.clientHeight
        let seen = 0

        graph.nodes().forEach((node) => {
          const box = node.renderedBoundingBox()
          if (box.w < 2 || box.h < 2) return
          if (box.x2 < 0 || box.y2 < 0 || box.x1 > width || box.y1 > height) return
          seen += 1
        })

        return seen
      }

      // For the suite, which is the only thing that can see this fail. Without
      // the container's size a failure reads "1 of 2 drawn" and says nothing
      // about why - and the why was a box with no height.
      window.__cyDebug = () => {
        if (!graph) return 'no graph'
        const host = document.querySelector('.dbc-canvas')
        const parts = [host.clientWidth + 'x' + host.clientHeight,
                       'zoom=' + graph.zoom().toFixed(2)]
        graph.nodes().forEach((n) => {
          const b = n.renderedBoundingBox()
          parts.push(n.id() + ':' + Math.round(b.x1) + ',' + Math.round(b.y1) +
                     ' ' + Math.round(b.w) + 'x' + Math.round(b.h))
        })
        return parts.join(' | ')
      }

      window.dbcGraphFit = () => { if (graph) graph.fit(undefined, 40) }
      window.dbcGraphLayout = () => {
        if (!graph) return
        const wide = nui.get('dbc_graph').focus === ''
        graph.layout(wide
          ? { name: 'cose', animate: false, numIter: 900, randomize: true }
          : { name: 'concentric', animate: false, minNodeSpacing: 40,
              concentric: (n) => n.data('focus') ? 10 : 1,
              levelWidth: () => 1 }).run()
        graph.fit(undefined, 40)
      }

      // Redrawn whenever the data changes while the panel is open, which is
      // what makes double-clicking a neighbour re-root the picture.
      let seenGraph = null
      nui.effect(() => {
        const open = nui.get('dbc_graph_open')
        const data = nui.get('dbc_graph')
        const mark = open ? JSON.stringify(data) : null

        if (mark === seenGraph) return
        seenGraph = mark

        if (!open) {
          if (graph) { graph.destroy(); graph = null }
          return
        }

        // After the frame that shows the panel: a container with no size
        // lays a graph out into a single point.
        requestAnimationFrame(() => drawGraph())
      })

      // Opens the list of rows a foreign key could point at, under the cell
      // being edited. Positioned from the cell's own rectangle: the list has
      // to be beside the thing it is answering for, and only the page knows
      // where that ended up after the grid laid itself out.
      window.dbcPick = (el, row, column, table) => {
        const box = el.getBoundingClientRect()
        const pop = document.querySelector('.dbc-choices')
        if (!pop) return

        nui.set('dbc_picker', { row: row, column: column, table: table, label: '' })
        neutrino.invoke('dbc:resolve', { column: column, needle: '' })

        // Above the cell when there is no room below it, which on the last
        // rows of a full window is most of the time.
        const height = 280
        const below = window.innerHeight - box.bottom
        pop.style.left = Math.min(box.left, window.innerWidth - 320) + 'px'
        pop.style.top = (below < height ? Math.max(8, box.top - height) : box.bottom) + 'px'
      }

      window.dbcResize = (event, column, width) => {
        event.preventDefault()
        event.stopPropagation()

        const startX = event.clientX
        const guide = document.createElement('div')
        guide.className = 'dbc-guide'
        guide.style.left = startX + 'px'
        document.body.appendChild(guide)

        let next = width

        const move = (moved) => {
          next = Math.max(48, Math.min(900, width + (moved.clientX - startX)))
          guide.style.left = (startX + (next - width)) + 'px'
        }

        const done = () => {
          document.removeEventListener('pointermove', move)
          document.removeEventListener('pointerup', done)
          guide.remove()
          neutrino.invoke('dbc:resize', { column: column, width: next })
        }

        document.addEventListener('pointermove', move)
        document.addEventListener('pointerup', done)
      }
    ]==]

  --- Pushes the block the grid is showing.
  push_window = ->
    unless active
      state\set "dbc_grid", {
        row: 0, col: 0, total_rows: 0, total_cols: 0, total_width: 0, x: 0
        columns: json.array {}, rows: json.array {}, offsets: json.array { 0 }
      }
      return

    state\set "dbc_grid", editor.window active, at_row, at_col,
      view.METRICS.rows, view.METRICS.columns

  --- Pushes everything about the open table that is not the grid itself.
  push_info = ->
    state\set "dbc_open", active and active.name or ""

    state\set "dbc_info", {
      rows: active and active.table\Count! or 0

      -- What the search left. Equal to `rows` when nothing is filtered, which
      -- is how the strip knows to say "2307 rows" rather than "2307 of 2307".
      shown: active and editor.visible(active) or 0

      columns: active and #active.columns or 0
      has_id: active and active.has_id or false
      locale: active and active.locale or ""
      spread: active and active.spread or false
      format: active and active.format or ""
      changes: active and changes.count(active.set) or 0
    }

    -- Read on every refresh rather than once: the setting can change while
    -- the tool is open, and the list would keep the old behaviour otherwise.
    state\set "dbc_open_on", library.setting "open_on"
    state\set "dbc_resolver", library.setting "resolver"
    state\set "dbc_readable", library.setting("readable") and true or false

    -- The shell's own keys: the menu entries and their shortcuts are guarded
    -- on these, and the status bar reads the first.
    state\set "dirty", active and editor.is_dirty(active) or false
    state\set "can_undo", active and editor.can_undo(active) or false
    state\set "can_redo", active and editor.can_redo(active) or false

    -- Regenerated only while it is on screen. It is the whole script every
    -- time, and nobody is reading it with the panel shut.
    if active and state\get "dbc_preview_open"
      state\set "dbc_preview", editor.script active

  --- Everything the page knows about the table, after something changed it.
  refresh = ->
    push_info!
    push_window!

  --- Reads the workspace's folder again.
  reload_tables = ->
    entries, err = library.tables!
    state\set "dbc_tables", entries

    -- Having no workspace is where everyone starts rather than something that
    -- went wrong, and the home page already says what to do about it. Anything
    -- else - a folder that is not there, one that cannot be read - is worth
    -- the strip.
    say (workspace.current! != nil) and err or nil

  --- Shows a table, opening it if this is the first time.
  ---@param name string
  ---@param pinned boolean Whether it keeps a tab of its own.
  open_table = (name, pinned) ->
    return unless type(name) == "string" and name != ""

    session = sessions[name]
    unless session
      tbl, err = library.open name
      unless tbl
        say err
        return

      build = workspace.setting "build"
      locale = workspace.setting "locale"
      mode = library.setting "locales"
      ok, made = pcall editor.session, tbl, name, locale, build, mode
      unless ok
        say "#{name} could not be read: #{tostring made}"
        return

      session = made
      session.readable = library.setting "readable"
      sessions[name] = session

    active = session
    at_row, at_col = 0, 0
    say nil

    -- A file written in one language, opened at another, is the quiet way to
    -- end up with a row holding two names: a read answers the slot that has
    -- something in it and a write goes to the one the workspace named. Said
    -- once, here, and only when the file disagrees with the setting.
    state\set "dbc_locale_hint", ""
    state\set "dbc_locale_offer", ""

    -- What the file carries, not what the grid is showing: with one column
    -- per language the question does not arise, and with one column at the
    -- workspace's locale the shown list is empty by definition.
    if library.setting("locale_hint") and not session.spread
      present = session.present or {}
      carries_ours = false
      carries_ours = true for slot in *present when slot == session.locale

      if #present > 0 and not carries_ours
        state\set "dbc_locale_offer", present[1]
        state\set "dbc_locale_hint",
          "#{name} has no text at #{session.locale}. It is written in
          #{table.concat present, ", "}."

    -- One tab per table, reused. Opening the same one again brings it forward
    -- rather than putting a second copy beside the first.
    --
    -- An unpinned tab is the one being read rather than worked in: there is at
    -- most one, and the next table read replaces it. Pinning is a double click
    -- or the first edit - the two moments where the table stops being
    -- something you glanced at.
    id = tab_id name
    tabs = state\get("tabs") or {}

    kept = [tab for tab in *tabs when tab.id == id or not tab.preview]
    known = nil
    known = tab for tab in *kept when tab.id == id

    if known
      known.preview = nil if pinned
    else
      table.insert kept, {
        :id, title: name, tool: "dbc"
        preview: (not pinned) or nil
      }

    state\set "tabs", json.array kept
    state\set "active_tab", id
    state\set "tool", "dbc"
    state\set "dbc_row", 0
    refresh!

    -- Back to the top. The block being drawn is this table's first, and a
    -- scrollbar left where the last table was would disagree with it.
    scroll_to 0

  --- The column the page named, or nil.
  column_at = (index) ->
    return nil unless active and type(index) == "number"
    active.columns[index]

  -- Re-reads the folder, and the settings with it: asking for the list again
  -- is what somebody does after changing where the files are or how the list
  -- behaves, and a list that came back with the old behaviour would look like
  -- the setting had not taken.
  window\handle "dbc:tables", ->
    reload_tables!
    push_info!
    nil

  -- A name, or a name and whether it keeps its own tab. The bare form is what
  -- the menus and the tests use, and it keeps.
  window\handle "dbc:open", (payload) ->
    if type(payload) == "table"
      open_table payload.name, (payload.pinned and true or false)
    else
      open_table payload, true
    nil

  --- Gives the open table a tab of its own, if it was only being read.
  --
  -- Called after the first thing that is not reading. A table being edited in
  -- a tab the next click would replace is a table whose edits look lost.
  pin_active = ->
    return unless active

    id = tab_id active.name
    tabs = state\get("tabs") or {}
    changed = false

    for tab in *tabs
      continue unless tab.id == id and tab.preview
      tab.preview = nil
      changed = true

    state\set "tabs", json.array tabs if changed

  window\handle "dbc:window", (payload) ->
    return nil unless active and type(payload) == "table"

    row = math.max 0, math.floor tonumber(payload.row) or 0
    col = math.max 0, math.floor tonumber(payload.col) or 0
    return nil if row == at_row and col == at_col

    at_row, at_col = row, col
    push_window!
    nil

  window\handle "dbc:set", (payload) ->
    return nil unless active and type(payload) == "table"

    column = column_at payload.column
    return nil unless column

    ok, err = editor.set_cell active, payload.row, column, tostring payload.value
    if ok then say nil else say "#{column.label}: #{err}"

    -- Editing is the other way a table stops being something you glanced at.
    pin_active!
    refresh!
    nil

  window\handle "dbc:add", ->
    return nil unless active

    index, err = editor.add_row active
    unless index
      say err
      return nil

    say nil
    state\set "dbc_row", index
    refresh!
    nil

  window\handle "dbc:duplicate", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click the number of the row to copy."
      return nil

    made, err = editor.duplicate_row active, index
    unless made
      say err
      return nil

    say nil
    state\set "dbc_row", made
    refresh!
    nil

  -- Asking first, because a deletion is the one thing here that cannot be seen
  -- to be wrong afterwards: the row is simply gone from the grid.
  window\handle "dbc:delete", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    unless index > 0
      say "Choose a row first: click the number of the row to delete."
      return nil

    id = editor.id_at active, index
    named = active.has_id and " (ID #{tostring id})" or ""
    state\set "dbc_confirm",
      "Row #{index}#{named} of #{active.name} will be removed. This can be
      undone, and nothing is written to disk until you save."
    nil

  window\handle "dbc:delete-row", ->
    return nil unless active

    index = tonumber(state\get "dbc_row") or 0
    return nil unless index > 0

    ok, err = editor.delete_row active, index
    if ok then say nil else say err

    -- The row that took its place is the sensible thing to be on, unless the
    -- one deleted was the last.
    state\set "dbc_row", math.min index, active.table\Count!
    refresh!
    nil

  --- Searches the open table.
  --
  -- A query that will not parse leaves the grid as it was and says why. The
  -- alternative - emptying the grid on every keystroke that is not yet a
  -- whole query - would make the box unusable to type into.
  window\handle "dbc:query", (text) ->
    return nil unless active

    ok, err = editor.set_query active, text
    state\set "dbc_query_error", ok and "" or tostring err

    -- Back to the top: the rows under the bar are a different set now, and a
    -- scrollbar left where the unfiltered table had it would point past them.
    at_row = 0
    refresh!
    scroll_to 0 if ok
    nil

  --- Sorts by a column, through ascending, descending and back to file order.
  window\handle "dbc:sort", (index) ->
    return nil unless active

    editor.set_sort active, tonumber index
    at_row = 0
    refresh!
    scroll_to 0
    nil

  --- Sets one column's width.
  window\handle "dbc:resize", (payload) ->
    return nil unless active and type(payload) == "table"

    editor.set_width active, (tonumber payload.column), (tonumber(payload.width) or 0)
    push_window!
    nil

  --- Reopens the table reading and writing at another language.
  --
  -- The columns change with it, so the session is rebuilt - but only after the
  -- change set has been checked: rebuilding one with edits in it would leave
  -- them recorded against slots nothing shows.
  window\handle "dbc:use-locale", (slot) ->
    return nil unless active and type(slot) == "string" and slot != ""

    state\set "dbc_locale_hint", ""

    if changes.count(active.set) > 0
      say "#{active.name} has unsaved changes. Save or undo them before
        changing language."
      return nil

    name = active.name
    sessions[name] = nil
    active = nil
    workspace.set "locale", slot
    open_table name
    nil

  --- Shows referenced rows by name instead of by number, or stops.
  --
  -- One state for the whole tool rather than one per table: it is how somebody
  -- reads a client, and having to switch it on again for every table opened
  -- would make it something nobody switches on.
  window\handle "dbc:readable", ->
    wanted = not library.setting "readable"
    library.set "readable", wanted

    session.readable = wanted for _, session in pairs sessions
    state\set "dbc_readable", wanted

    -- Resolving reads the referenced tables, and the first draw after turning
    -- it on is when that happens. Said rather than left as a pause.
    say wanted and "Reading the referenced tables..." or nil
    refresh!
    say nil
    nil

  --- The rows a foreign key could point at, narrowed by what has been typed.
  window\handle "dbc:resolve", (payload) ->
    return nil unless active and type(payload) == "table"

    column = column_at payload.column
    unless column and column.foreign
      state\set "dbc_choices", json.array {}
      return nil

    ok, found = pcall relations.search, column.foreign, active.locale,
      tostring(payload.needle or ""), 60

    unless ok
      say "#{column.foreign} could not be read: #{tostring found}"
      state\set "dbc_choices", json.array {}
      return nil

    state\set "dbc_choices", json.array found
    nil

  --- The graph of what refers to what.
  --
  -- With a table open it is that table and its immediate neighbours, which is
  -- the question somebody looking at a column has. With none it is every
  -- linked table in the client, which is the map you want before you know what
  -- you are looking for.
  window\handle "dbc:relations", (name) ->
    build = workspace.setting "build"
    say "Reading the definitions..."

    -- Which table the picture is drawn around. Re-rooting it on a neighbour
    -- does not open that table: looking at the shape and working in it are
    -- different things to want, and one should not drag the other along.
    --
    -- "*" asks for the whole client. It has to be askable: the table in front
    -- stays in front after its tab is closed, so "nothing is open" is a state
    -- almost nobody gets back to once they have started.
    focus = if name == "*"
      ""
    else
      type(name) == "string" and name != "" and name or
        (active and active.name or "")

    nodes, edges = {}, {}

    if focus != ""
      -- Whether a neighbour is one this client ships. A definition can name a
      -- table nobody has, and an edge to nothing is a lie in a picture.
      known = {}
      known[entry.name] = entry.editable for entry in *library.tables!

      got, schema = pcall dbc.Schemas.Get, focus, build
      if got and schema
        seen = { [focus]: true }
        table.insert nodes, { name: focus, focus: true }

        for link in *relations.outbound schema
          continue unless known[link.table]
          unless seen[link.table]
            seen[link.table] = true
            table.insert nodes, { name: link.table }
          table.insert edges, { from: focus, to: link.table, column: link.column }

        ok, inn = pcall relations.inbound, focus, build
        if ok
          for link in *inn
            unless seen[link.table]
              seen[link.table] = true
              table.insert nodes, { name: link.table }
            table.insert edges, { from: link.table, to: focus, column: link.column }
    else
      ok, all_nodes, all_edges = pcall relations.graph, build
      nodes, edges = (ok and all_nodes or {}), (ok and all_edges or {})

    state\set "dbc_graph", {
      :focus
      nodes: json.array nodes
      edges: json.array edges
    }
    state\set "dbc_graph_open", true
    say nil
    nil

  window\handle "dbc:find", (text) ->
    return nil unless active and active.has_id

    id = tonumber text
    unless id
      say "Type the ID of the row to go to."
      return nil

    -- Through the table's own ID index, which is a lookup rather than a scan:
    -- a table of forty thousand rows is ordinary and a search that walked it
    -- would be felt.
    ok, row = pcall active.table.FindById, active.table, id
    found = (ok and row) and row\GetIndex! or nil

    unless found
      say "#{active.name} has no row with ID #{id}."
      return nil

    say nil
    state\set "dbc_row", found

    -- Put it a few rows below the top, where it is easier to see than pinned
    -- against the header.
    at_row = math.max 0, found - 4
    refresh!

    -- The scroller is the page's, so the page is what has to be moved.
    scroll_to at_row * view.METRICS.row
    nil

  window\handle "dbc:preview", ->
    state\set "dbc_preview", active and editor.script(active) or ""
    nil

  undo = ->
    return "Nothing is open" unless active
    ok, err = editor.undo active
    refresh!
    ok and "Undone" or err

  redo = ->
    return "Nothing is open" unless active
    ok, err = editor.redo active
    refresh!
    ok and "Redone" or err

  --- Writes one session, whether or not it is the one on screen.
  --
  -- Takes the session rather than reading `active`, because saving everything
  -- has to reach tables the user is not looking at - which is most of them
  -- when the timer fires.
  ---@param session table
  ---@return boolean ok, string line
  ---@private
  save_session = (session) ->
    folder = workspace.output_dir!
    return false, "There is nowhere to write: open a workspace first." unless folder

    -- The table, or the script that reproduces it. The same edits either way;
    -- what differs is whether the result is a file a client can read or one a
    -- person can review.
    if library.setting("save_as") == "lua"
      path = fs.join folder, "#{session.name}.lua"
      ok, err = fs.write path, editor.script session
      return false, "#{session.name} could not be saved: #{tostring err}" unless ok
      return true, "#{session.name} written to #{path} as Lua"

    path = fs.join folder, "#{session.name}.dbc"
    written, err = editor.save session, path
    return false, "#{session.name} could not be saved: #{tostring err}" unless written
    true, "#{session.name} written to #{path} (#{written} bytes)"

  save = ->
    return "Nothing is open" unless active

    ok, line = save_session active
    say ok and nil or line
    refresh!
    line

  --- Writes every table holding changes.
  --
  -- What the shell calls on the way out and on the timer. The first failure
  -- stops it: the rest are probably the same failure, and a status line
  -- naming five tables that could not be written for one reason is five times
  -- the words and none of the information.
  save_all = ->
    written = {}

    for name, session in pairs sessions
      continue unless editor.is_dirty session

      ok, line = save_session session
      error line unless ok
      table.insert written, name

    refresh!
    return "Nothing to save" if #written == 0
    "Saved #{table.concat written, ", "}"

  window\handle "dbc:undo", ->
    state\set "status", undo!
    nil

  window\handle "dbc:redo", ->
    state\set "status", redo!
    nil

  window\handle "dbc:save", ->
    state\set "status", save!
    nil

  -- What File > Save and Edit > Undo reach when this tool is the active one.
  M.tool.commands = {
    :undo
    :redo
    :save
    "save-all": save_all
  }

  -- The tab bar is the page's; clicking one changes the store and nothing
  -- else. This is how the tool hears that a different table is in front.
  state\on "active_tab", (value) ->
    return unless type(value) == "string"

    name = value\match "^dbc:(.+)$"
    return unless name
    return if active and active.name == name

    open_table name

  -- The tables belong to the folder that was open. A different workspace is a
  -- different set of files, and the sessions describing the old ones would be
  -- describing rows nobody can see. The names a foreign key resolves to came
  -- out of those files too, so they go with them.
  workspace.on_change ->
    relations.reset!
    sessions = {}
    active = nil
    at_row, at_col = 0, 0

    state\set "dbc_preview", ""

    open_tabs = state\get("tabs") or {}
    kept = [tab for tab in *open_tabs when tab.tool != "dbc"]
    state\set "tabs", json.array kept

    showing = state\get("active_tab") or ""
    state\set "active_tab", "" if showing\match "^dbc:"

    reload_tables!
    refresh!

  -- Not now: mount runs while the window is still coming up, and the store is
  -- inlined into the document, so `nui` does not exist yet and the whole
  -- script would fail - taking the column drag with it, silently.
  window\on "did-finish-load", (detail) ->
    return unless detail.url and detail.url\match "^neutrino://app/"
    install_page_helpers!

  reload_tables!
  refresh!

-- ═══════════════════════════════════════════════════════════════════════════
-- Registration
-- ═══════════════════════════════════════════════════════════════════════════

icon = page.icon

M.tool = tools.register {
  id: "dbc"
  label: "DBC Editor"
  icon: "table"
  description: "Open the client's DBC tables and edit them row by row."

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
    [name for name, session in pairs sessions when editor.is_dirty session]

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

    -- Bumped whenever the view should return to the top. The page watches it;
    -- the number itself means nothing.
    dbc_top: 0

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
      locale: workspace.setting "locale"
    }

    dbc_grid: {
      row: 0, col: 0, total_rows: 0, total_cols: 0, total_width: 0, x: 0
      columns: json.array {}, rows: json.array {}, offsets: json.array { 0 }
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
    library.set "open_on", values.open_on == "double" and "double" or "single"

    -- The folder moving means a different set of files, so what is open
    -- belongs to a folder that is no longer the one being edited. Nothing
    -- else here does: a column that appears or disappears is a different view
    -- of the same records, and dropping the sessions for it would throw away
    -- every unsaved change to make a display setting take effect.
    if moved
      library.close!
      sessions = {}
      active = nil
    else
      mode = library.setting "locales"
      for _, session in pairs sessions
        session.mode = mode
        session.slots = editor.slots_for mode, session.present
        session.spread = session.slots != nil
        session.columns = editor.columns session.schema, session.locale,
          session.slots
        session.widths = {}
        session.sort = nil
        session.stale = true

    true
}

M
