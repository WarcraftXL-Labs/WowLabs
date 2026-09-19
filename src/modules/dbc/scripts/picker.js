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
