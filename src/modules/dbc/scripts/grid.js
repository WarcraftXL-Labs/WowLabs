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

// Taking a value from the reference list.
//
// Exposed, because the choice is made in the page's own markup, which
// cannot reach the helpers in this scope. It writes and applies, so a
// value arrives in a cell one way rather than two: the markup used to
// invoke `dbc:set` and drop the answer, and the cell went on showing the
// old text until a reload or the changed-rows view forced a redraw.
window.dbcChoose = async (row, column, value) => {
  // The editor behind the list goes first. It holds what the cell said before
  // the choice, and on blur it commits that - over the value being chosen
  // here. While it is open it also has the arrow keys.
  const editing = picking
  picking = null
  if (editing) { try { editing.cancelEdit() } catch (err) { /* already gone */ } }

  const answer = await neutrino.invoke('dbc:set', {
    row: row, column: column, value: String(value),
  })

  if (answer && answer.row) dbcApply([answer.row])
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
      column.index, column.foreign, cell)
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

