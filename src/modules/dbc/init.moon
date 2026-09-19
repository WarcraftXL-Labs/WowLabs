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
  say = (message) -> state\set "dbc_message", message or ""

  --- Tells the page to read the table again from the first page.
  --
  -- A counter rather than the data itself: what changed is which rows exist
  -- and in what order, and the grid asks for them a page at a time. Bumping
  -- this is the one way the data source is restarted, so there is one place to
  -- look when the grid is showing the wrong thing.
  reload = ->
    state\set "dbc_reload", (tonumber(state\get "dbc_reload") or 0) + 1

  --- Installs what the page needs that markup cannot express.
  --
  -- Two libraries, laid out and driven from here: the relations graph and the
  -- grid. Both are the same kind of thing - a container, a configuration and a
  -- handful of callbacks - and neither can be expressed as markup with data-
  -- attributes on it.
  install_page_helpers = ->
    -- The numbers the page and Lua both work from, handed over rather than
    -- written twice. A long string does not interpolate, so this goes first.
    window\exec_js "window.DBC = { page: #{view.METRICS.page},
      row: #{view.METRICS.row}, index: #{view.METRICS.index} }"

    window\exec_js [==[
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

      // ── The grid ─────────────────────────────────────────────────────────
      //
      // Tabulator draws it. It does not own the data: a cell is a field in an
      // FFI buffer that only Lua can read or write, so the rows arrive a page
      // at a time over IPC and every edit goes back the same way.
      //
      // Spell is 49,839 rows by 105 columns. Handing the library all of it is
      // five million values, which is neither serialisable nor holdable, so
      // progressive loading is not a refinement here - it is the only shape
      // that works at all.

      let grid = null
      let building = 0
      let seenShape = null
      let seenReload = null

      // A cell's text, and what Lua said about it. Returned as a text node
      // rather than as a string: a formatter's string return is assigned
      // through innerHTML, and a DBC holds whatever bytes somebody put in it.
      const dbcFormat = (cell) => {
        const data = cell.getRow().getData()
        const field = cell.getField()
        const el = cell.getElement()
        const refused = data._e ? data._e[field] : null

        el.classList.toggle('is-bad', !!refused)
        el.classList.toggle('is-dirty', !refused && !!(data._d && data._d[field]))
        if (refused) el.setAttribute('title', refused)
        else el.removeAttribute('title')

        const value = cell.getValue()
        return document.createTextNode(
          value === undefined || value === null ? '' : String(value))
      }

      // The frozen first column: which row this is in the file - which is its
      // identity, and all the 22 tables without an ID have - and its ID beside
      // it when the two differ.
      const dbcRowHead = (cell) => {
        const data = cell.getRow().getData()
        cell.getElement().classList.toggle('is-new', !!data._new)

        const box = document.createElement('span')
        box.className = 'dbc-rowhead'

        const number = document.createElement('span')
        number.textContent = String(data._i)
        box.appendChild(number)

        if (data._id !== undefined && data._id !== null && data._id !== data._i) {
          const id = document.createElement('span')
          id.className = 'dbc-rowid'
          id.textContent = String(data._id)
          box.appendChild(id)
        }

        return box
      }

      // Not a URL. The loader is asked for a page and answered by Lua, which
      // is the only thing that can read a record, so `ajaxURL` is a marker the
      // loader checks for rather than something anybody fetches.
      const dbcRequest = (url, config, params) => neutrino.invoke('dbc:page', {
        page: params.page || 1,
        size: params.size || window.DBC.page,
        sorters: params.sort || [],
      })

      // A paste is a block of cells, and every one of them is a write only Lua
      // can make. This works out which cells the range means and hands the
      // list over; nothing here writes a row. One message, and one group on
      // the undo stack: two hundred presses of Ctrl+Z to take back one paste
      // would be unusable.
      const dbcPasteAction = function (parsed) {
        const ranges = this.table.modules.selectRange
        const active = ranges && ranges.activeRange
        if (!active || !parsed.length) return []

        const bounds = active.getBounds()
        if (!bounds.start) return []

        // One cell selected means "paste what is on the clipboard, at its own
        // size"; a block means "fill this block, repeating if it is larger".
        const single = bounds.start === bounds.end
        const rows = this.table.rowManager.activeRows.slice()
        const at = rows.indexOf(bounds.start.row)
        if (at < 0) return []

        const height = single ? parsed.length : rows.indexOf(bounds.end.row) - at + 1
        const target = rows.slice(at, at + height)

        const cells = []
        target.forEach((row, offset) => {
          const values = parsed[offset % parsed.length]
          for (const field of Object.keys(values)) {
            if (field.charAt(0) !== 'c') continue
            cells.push({
              row: row.getData()._i,
              column: Number(field.slice(1)),
              value: values[field],
            })
          }
        })

        neutrino.invoke('dbc:paste', { cells: cells })
          .then((answer) => dbcApply(answer && answer.rows))

        // Nothing was written here, so nothing is reported as having changed.
        return []
      }

      // Puts what Lua now holds into the rows the grid is showing.
      //
      // Redrawn as well as updated. A cell whose text did not change - a
      // refused write keeps what was typed, and a successful one was already
      // showing it - is not redrawn by an update alone, and the mark saying
      // "changed" or "refused" lives on the element rather than in the value.
      const dbcApply = async (rows) => {
        if (!grid || !rows || !rows.length) return
        await grid.updateData(rows)

        for (const data of rows) {
          const row = grid.getRow(data._i)
          if (row) row.reformat()
        }
      }

      const dbcColumns = (columns) => {
        const defs = []

        for (const column of columns) {
          if (!column.shown) continue
          defs.push({
            title: column.label,
            field: column.key,
            width: column.w,
            headerSortStartingDir: 'asc',
            headerTooltip: column.extra
              ? column.kind + ' ' + column.extra : column.kind,
            cssClass: column.foreign ? 'dbc-value is-link' : 'dbc-value',
            formatter: dbcFormat,
            editor: 'input',
          })
        }

        return defs
      }

      // Which column a field names. The key is the column's index in the
      // session, because two localised columns of one field differ only by
      // slot and a label is for people.
      const dbcIndex = (field) => Number(String(field).slice(1))

      const buildGrid = async (columns) => {
        const mine = ++building
        const host = document.querySelector('.dbc-grid')
        if (!host) return

        // The same trap as the relations graph, and the same helper: the work
        // area is hidden until the store update that opened the table has been
        // drawn, and a grid measured against a box of no height lays itself
        // out into a point. Every count right, and nothing on screen.
        if (!await withSize(host)) return
        if (mine !== building) return

        if (grid) { grid.destroy(); grid = null }

        const defs = dbcColumns(columns)
        if (defs.length === 0) return

        grid = new Tabulator(host, {
          height: '100%',
          index: '_i',
          layout: 'fitDataFill',
          columns: defs,
          placeholder: ' ',

          // Columns as well as rows. Spell is 170 cells to a record, and a
          // row drawn in full is 170 elements for the dozen that are in
          // view - which is the same mistake as holding every row.
          renderHorizontal: 'virtual',

          // The row's place in the file, frozen down the left. A row header
          // rather than an ordinary column, so a range never covers it and a
          // click on it takes the whole row.
          rowHeader: {
            title: '#',
            field: '_i',
            width: window.DBC.index,
            headerSort: false,
            resizable: false,
            editor: false,
            frozen: true,
            cssClass: 'dbc-rownum',
            formatter: dbcRowHead,
          },

          // Fed forwards a page at a time, so what the grid holds is what was
          // actually scrolled past rather than what the table contains.
          ajaxURL: 'dbc:page',
          ajaxRequestFunc: dbcRequest,
          progressiveLoad: 'scroll',
          progressiveLoadDelay: 0,

          // How close to the bottom a scroll has to get before the next page
          // is asked for. Named rather than left at two screenfuls, which on a
          // tall window pulls several pages in before anything has been
          // scrolled at all.
          progressiveLoadScrollMargin: 300,
          paginationSize: window.DBC.page,

          // Lua sorts, over the whole table. Tabulator can only sort what it
          // holds, which is whatever has been scrolled past so far.
          sortMode: 'remote',

          // Range selection, the clipboard and the keyboard that comes with
          // them - which is the whole reason this is a library and not a
          // hand-written grid.
          selectableRange: 1,
          selectableRangeColumns: true,
          selectableRangeRows: true,

          // Delete would write empty values straight into the row data. Lua
          // owns every write, so it stays off.
          selectableRangeClearCells: false,

          editTriggerEvent: 'dblclick',
          movableColumns: true,

          clipboard: true,
          clipboardCopyStyled: false,
          clipboardCopyRowRange: 'range',
          clipboardPasteParser: 'range',
          clipboardPasteAction: dbcPasteAction,
        })

        grid.on('cellEdited', async (cell) => {
          const answer = await neutrino.invoke('dbc:set', {
            row: cell.getRow().getData()._i,
            column: dbcIndex(cell.getField()),
            value: cell.getValue(),
          })

          // What Lua actually holds now, which is not what was typed when the
          // column refused it. The text is kept either way.
          if (answer && answer.row) dbcApply([answer.row])
        })

        // The list of rows a foreign key could point at, under the cell being
        // edited - when the setting asks for it.
        grid.on('cellEditing', (cell) => {
          const column = (nui.get('dbc_columns') || [])
            .find((c) => c.key === cell.getField())
          if (!nui.get('dbc_resolver') || !column || !column.foreign) return
          window.dbcPick(cell.getElement(), cell.getRow().getData()._i,
            column.index, column.foreign)
        })

        grid.on('columnResized', (column) => {
          const field = column.getField()
          if (!field || field === '_i') return
          neutrino.invoke('dbc:resize', {
            column: dbcIndex(field), width: Math.round(column.getWidth()),
          })
        })

        grid.on('columnMoved', (column, columns) => {
          const order = columns.map((c) => c.getField())
            .filter((f) => f && f !== '_i').map(dbcIndex)
          neutrino.invoke('dbc:columns', { order: order })
        })

        // Which row the rail's Duplicate and Delete act on. The range is where
        // the user is, so it is what answers.
        grid.on('rangeChanged', (range) => {
          const rows = range.getRows()
          if (rows.length > 0) nui.set('dbc_row', rows[0].getData()._i)
        })
      }

      // Rebuilt when the columns change - another table, another language, a
      // column taken off the screen - and told to read again from the first
      // page when Lua says the rows or their order have. Two different things:
      // one throws the grid away, the other asks it for the data again.
      nui.effect(() => {
        const columns = nui.get('dbc_columns') || []
        const token = nui.get('dbc_reload')
        const shape = JSON.stringify(columns.filter((c) => c.shown))

        if (shape !== seenShape) {
          seenShape = shape
          seenReload = token
          // After the frame that shows the work area, for the same reason the
          // graph waits: a container with no size yet is a grid nobody sees.
          requestAnimationFrame(() => buildGrid(columns))
          return
        }

        if (token === seenReload) return
        seenReload = token
        if (grid) grid.setData()
      })

      // Enter and Tab commit and move, which a table editor lives on.
      //
      // Tabulator's own navigation is turned off while range selection is on,
      // and the range module's answer to Tab mid-edit is to throw the edit
      // away - which is the opposite of committing it. So the commit is made
      // here, through the editor's own change handler, and the range is moved
      // afterwards. Capture, so this runs before the editor sees the key.
      document.addEventListener('keydown', (event) => {
        const editing = grid && grid.modules.edit && grid.modules.edit.currentCell
        if (!editing) return

        let direction = null
        if (event.key === 'Enter') direction = event.shiftKey ? 'up' : 'down'
        else if (event.key === 'Tab') direction = event.shiftKey ? 'left' : 'right'
        if (!direction) return

        event.preventDefault()
        event.stopPropagation()

        // `change` rather than a blur: an input that never took focus has no
        // blur to give, and the editor listens for both.
        const input = editing.getElement().querySelector('input')
        if (input) {
          input.dispatchEvent(new Event('change'))
          if (grid.modules.edit.currentCell) input.blur()
        }

        // Next tick: the commit clears the cell being edited, and the range
        // refuses to move while one is set.
        setTimeout(() => {
          const ranges = grid && grid.modules.selectRange
          if (ranges) ranges.navigate(false, false, direction)
        }, 0)
      }, true)

      // ── What the suite can see ───────────────────────────────────────────

      // The table itself, so a suite can drive the real thing rather than a
      // second set of hooks that answer for it. Everything else here measures
      // something that cannot be got at from outside.
      window.__grid = () => grid

      // Cells on screen, with a size, inside the host. Everything short of
      // this was true of a grid laid out into a box of no height: the counts
      // right, the elements there, and nothing visible.
      //
      // The intersection with the host, not merely an overlap with it. A
      // container collapsed to nothing still has cells hanging out of it that
      // an overlap test counts - which is how this measured a full grid while
      // the screen was blank.
      window.__gridDrawn = () => {
        const host = document.querySelector('.dbc-grid')
        if (!host || !grid) return 0

        const box = host.getBoundingClientRect()
        let seen = 0

        for (const cell of host.querySelectorAll('.tabulator-cell')) {
          const rect = cell.getBoundingClientRect()
          const height = Math.min(rect.bottom, box.bottom) - Math.max(rect.top, box.top)
          const width = Math.min(rect.right, box.right) - Math.max(rect.left, box.left)
          if (height >= 2 && width >= 2) seen += 1
        }

        return seen
      }

      window.__gridDebug = () => {
        const host = document.querySelector('.dbc-grid')
        if (!host) return 'no host'
        return host.clientWidth + 'x' + host.clientHeight +
          ' held=' + (grid ? grid.getDataCount() : -1) +
          ' cells=' + host.querySelectorAll('.tabulator-cell').length +
          ' drawn=' + window.__gridDrawn()
      }

    ]==]

  --- Pushes the columns the grid draws, in the order and the visibility the
  --- user has left them.
  --
  -- The grid is rebuilt when this changes and only then: a column appearing,
  -- disappearing or moving is a different table as far as the library is
  -- concerned, and the rows are asked for again afterwards.
  push_columns = ->
    state\set "dbc_columns", active and editor.grid_columns(active) or json.array {}
    state\set "dbc_changed_only", active and active.changed_only or false

  --- Pushes everything about the open table that is not the rows themselves.
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

      -- Where paging begins. Non-zero only after a jump to a row, and said on
      -- the strip because everything above it is off the top until it is put
      -- back to zero.
      from: active and active.from or 0
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
  --
  -- `rows` says the order or the contents have moved on, which is what makes
  -- the grid read again. Left out after an edit that only changed one cell:
  -- the answer to `dbc:set` carries that row, and rereading the table to show
  -- one new value would throw away everything that had been scrolled past.
  refresh = (rows) ->
    push_info!
    push_columns!
    reload! if rows

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
    active.from = 0
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

    -- The columns are this table's, so the grid is rebuilt rather than told to
    -- read again - and a new grid starts at the first page, which is also how
    -- the scrollbar ends up back at the top.
    refresh true

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

  --- One row, in the shape the grid holds it.
  --
  -- Handed back from a write so the grid can show what Lua actually holds
  -- without asking for the table again. Rereading it to show one new value
  -- would throw away every page that had been scrolled past.
  ---@param index integer
  ---@return table|nil
  row_payload = (index) -> active and editor.row_at active, index

  --- One page of rows, as Tabulator asks for them.
  --
  -- Where the sort is applied too. The library sends the field and the
  -- direction; Lua sorts the whole table, which Tabulator cannot - it holds
  -- only what has been scrolled past. The field is a column index rather than
  -- a label, because two localised columns of one field differ only by slot.
  window\handle "dbc:page", (payload) ->
    empty = { data: json.array({}), last_page: 1 }
    return empty unless active and type(payload) == "table"

    sorters = type(payload.sorters) == "table" and payload.sorters or {}
    first = sorters[1]

    column, descending = nil, false
    if first and type(first.field) == "string"
      column = tonumber first.field\match "^c(%d+)$"
      descending = first.dir == "desc"

    held = active.sort
    same = if column == nil
      held == nil
    else
      held != nil and held.column == column and held.descending == descending

    unless same
      editor.sort_by active, column, descending
      push_info!

    editor.page active, payload.page, payload.size

  window\handle "dbc:set", (payload) ->
    return nil unless active and type(payload) == "table"

    column = column_at payload.column
    return nil unless column

    index = tonumber(payload.row) or 0
    ok, err = editor.set_cell active, index, column, tostring payload.value
    if ok then say nil else say "#{column.label}: #{err}"

    -- Editing is the other way a table stops being something you glanced at.
    pin_active!

    -- The changed-rows view is a filter over the change set, so a write can
    -- put a row into it or take one out. Everywhere else one cell moved, and
    -- the row handed back below is enough to show it.
    refresh active.changed_only
    { row: row_payload index }

  --- Writes a block of cells as one step.
  --
  -- What a paste is. Every cell goes through `editor.set_cell` and nothing
  -- else does, each one pcalled, so a cell the column will not take keeps its
  -- text and its reason while the rest go in - and the whole block is one
  -- thing to take back.
  window\handle "dbc:paste", (payload) ->
    return nil unless active and type(payload) == "table"

    cells = type(payload.cells) == "table" and payload.cells or {}
    written, refused = editor.paste active, cells

    if #refused > 0
      say "#{#refused} of #{written + #refused} cells were refused:
        #{refused[1].message}"
    else
      say nil

    pin_active!
    refresh active.changed_only

    -- Every row the paste touched, so the grid shows what Lua holds rather
    -- than what was on the clipboard.
    touched, rows = {}, {}
    for cell in *cells
      index = tonumber cell.row
      continue unless index and not touched[index]
      touched[index] = true
      row = row_payload index
      table.insert rows, row if row

    { :written, refused: #refused, rows: json.array rows }

  --- Which columns the grid shows, and in what order.
  window\handle "dbc:columns", (payload) ->
    return nil unless active and type(payload) == "table"

    if payload.every != nil
      hidden = {}
      unless payload.every
        hidden[index] = true for index = 1, #active.columns
      editor.set_layout active, nil, hidden

    elseif payload.column
      index = tonumber payload.column
      if index
        hidden = { key, value for key, value in pairs active.hidden }
        hidden[index] = (not payload.shown) or nil
        editor.set_layout active, nil, hidden

    elseif type(payload.order) == "table"
      editor.set_layout active, payload.order, nil

    -- The columns are what the grid is built from, so this rebuilds it, and
    -- the rows come with it: a hidden column is one nothing reads, and the
    -- pages already fetched were read without it.
    push_info!
    push_columns!
    reload!
    nil

  --- Pages over the changed rows alone, or over all of them again.
  window\handle "dbc:changed-only", ->
    return nil unless active

    editor.set_changed_only active, not active.changed_only
    refresh true
    nil

  --- Back to the first row, after a jump left the grid partway down.
  window\handle "dbc:top", ->
    return nil unless active

    editor.set_from active, 0
    refresh true
    nil

  window\handle "dbc:add", ->
    return nil unless active

    index, err = editor.add_row active
    unless index
      say err
      return nil

    say nil
    state\set "dbc_row", index
    refresh true
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
    refresh true
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
    refresh true
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

    -- Back to the first page: the rows under the bar are a different set now,
    -- and an anchor left by a jump points into the set they replaced.
    editor.set_from active, 0
    refresh true
    nil

  --- Sets one column's width.
  --
  -- The grid is not told. The drag it came from is what moved the column, and
  -- pushing the width back would answer a question nobody asked.
  window\handle "dbc:resize", (payload) ->
    return nil unless active and type(payload) == "table"

    editor.set_width active, (tonumber payload.column), (tonumber(payload.width) or 0)
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

    -- Every cell reads differently now, so the pages already fetched are
    -- showing numbers where they should be showing names.
    refresh true
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

    -- The grid is fed forwards, so a row deep in a large table is reached by
    -- starting there rather than by scrolling to it: pulling the 39,999 rows
    -- above it through the window first is the thing this design exists to
    -- avoid. A few rows above it, so it is not pinned under the header, and
    -- the strip says where the view begins with the way back beside it.
    position = editor.position_of active, found
    editor.set_from active, math.max 0, (position or found) - 4
    refresh true
    nil

  window\handle "dbc:preview", ->
    state\set "dbc_preview", active and editor.script(active) or ""
    nil

  -- A step back can be a row coming or going as easily as a cell changing, so
  -- the rows are asked for again rather than guessed at.
  undo = ->
    return "Nothing is open" unless active
    ok, err = editor.undo active
    refresh true
    ok and "Undone" or err

  redo = ->
    return "Nothing is open" unless active
    ok, err = editor.redo active
    refresh true
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
    refresh false
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

    refresh false
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

    state\set "dbc_preview", ""

    open_tabs = state\get("tabs") or {}
    kept = [tab for tab in *open_tabs when tab.tool != "dbc"]
    state\set "tabs", json.array kept

    showing = state\get("active_tab") or ""
    state\set "active_tab", "" if showing\match "^dbc:"

    reload_tables!
    refresh true

  -- Not now: mount runs while the window is still coming up, and the store is
  -- inlined into the document, so `nui` does not exist yet and the whole
  -- script would fail - taking the column drag with it, silently.
  window\on "did-finish-load", (detail) ->
    return unless detail.url and detail.url\match "^neutrino://app/"
    install_page_helpers!

  reload_tables!
  refresh false

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
        -- The column list is a different list, so everything keyed on a column
        -- index describes columns that are no longer there.
        session.widths = {}
        session.hidden = {}
        session.order = nil
        session.sort = nil
        session.from = 0
        session.stale = true

    true
}

M
