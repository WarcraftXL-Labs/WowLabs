// The cell whose editor is open behind the list.
//
// It has to come down when a choice is made. Left open it still holds what
// was in the cell before, it commits that on blur, and the value just picked
// is written over by the one it replaced. It also takes the arrow keys, so
// the grid stops responding to them until something else is clicked.
let picking = null

// Opens the list of rows a foreign key could point at, under the cell
// being edited. Positioned from the cell's own rectangle: the list has
// to be beside the thing it is answering for, and only the page knows
// where that ended up after the grid laid itself out.
window.dbcPick = (el, row, column, table, cell) => {
  picking = cell || null

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
