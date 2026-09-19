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
