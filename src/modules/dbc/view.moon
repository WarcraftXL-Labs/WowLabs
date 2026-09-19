--- The table editor's markup.
--
-- Three regions, rendered once with the page and shown by which tool and which
-- tab are active: the strip under the category bar, the panel down the side,
-- and the grid in the work area.
--
-- **The grid binds the window, not the table.** DBC tables run to tens of
-- thousands of rows and two hundred columns, and the runtime rebuilds a
-- `data-for` wholesale whenever its list changes - so the list is what is on
-- screen. A box the size of the whole table holds the scrollbars, the header
-- and the visible block are placed inside it at the offset that matches the
-- scroll, and scrolling asks Lua for the block that is now in view.
--
-- Every row is the same height, which is what makes the vertical arithmetic a
-- division. Columns are **not** the same width any more, so Lua sends where
-- each one starts and the page searches that list instead of dividing.
---@module modules.dbc.view

etlua = require "etlua"

M = {}

--- The grid's geometry, in pixels.
--
-- Shared between the markup and the module that fills it: the page works out
-- which block is in view from these, and Lua answers with exactly that block.
-- Two copies of these numbers would be two copies that drift.
---@type table
M.METRICS = {
  row: 22        -- a row, dense enough to read a screenful at once
  head: 26       -- the frozen header
  index: 72      -- the frozen row-index column

  -- How much is fetched around what is visible. The window is asked for again
  -- only when the first visible row or column leaves this margin, so an
  -- ordinary scroll redraws from what is already here.
  rows: 64
  columns: 16
  margin_rows: 6
  margin_columns: 1
}

-- ═══════════════════════════════════════════════════════════════════════════
-- The strip under the category bar
-- ═══════════════════════════════════════════════════════════════════════════

CONTEXT = [==[
<div class="flex w-full items-center gap-3">
  <span class="font-medium text-ink" data-text="dbc_open || 'No table open'"></span>

  <span class="text-ink-faint" data-show="dbc_open !== ''"
        data-text="dbc_info.shown === dbc_info.rows
          ? dbc_info.rows + ' rows, ' + dbc_info.columns + ' columns'
          : dbc_info.shown + ' of ' + dbc_info.rows + ' rows'"></span>

  <!-- Which slot a localised column is being read and written at. Silence here
       is how a frFR client ends up with an enUS name written over it. -->
  <span class="rounded border border-line px-1.5 text-[11.5px] text-ink-dim"
        data-show="dbc_open !== '' && !dbc_info.spread"
        data-text="'Text: ' + dbc_info.locale"></span>

  <span class="rounded border border-line px-1.5 text-[11.5px] text-ink-faint"
        data-show="dbc_open !== '' && dbc_info.spread">All languages</span>

  <span class="rounded border border-line px-1.5 text-[11.5px] text-ink-faint"
        data-show="dbc_open !== '' && !dbc_info.has_id"
        title="This table keeps no ID in its records, so a row is named by its position."
      >No ID column</span>

  <!-- The search. The box is the whole query: a picker that set a second,
       hidden filter beside it would mean two places to look when the grid
       shows something unexpected. What the list of columns was for is served
       better by the help beside it, which can say what to do with them. -->
  <form class="ml-auto flex items-center gap-1" data-show="dbc_open !== ''"
        data-on-submit="$event.preventDefault(); neutrino.invoke('dbc:query', dbc_query)">

    <input type="text" spellcheck="false"
           placeholder="Name LIKE 'Fire%' AND SpellLevel > 10"
           class="w-[300px] rounded border border-line bg-base-950 px-2 py-0.5
                  text-[12px] text-ink"
           data-class-is-bad="dbc_query_error !== ''"
           data-attr-title="dbc_query_error"
           data-model="dbc_query"
           data-on-keydown="if ($event.key === 'Escape') {
             dbc_query = ''; neutrino.invoke('dbc:query', '') }">

    <button type="button" class="dbc-chip" data-show="dbc_query !== ''"
            data-on-click="dbc_query = ''; neutrino.invoke('dbc:query', '')"
            title="Clear the search">Clear</button>

    <button type="button" class="dbc-help-button" title="How to write a filter"
            data-on-click="dbc_help = true">?</button>
  </form>

  <span class="truncate pl-3 text-danger" data-show="dbc_message !== ''"
        data-text="dbc_message"></span>
</div>
]==]

-- ═══════════════════════════════════════════════════════════════════════════
-- The side panel
-- ═══════════════════════════════════════════════════════════════════════════

PANEL = [==[
<div class="flex min-h-0 flex-1 flex-col">
  <div class="flex shrink-0 items-center gap-2 border-b border-line px-2 py-1.5">
    <input type="text" spellcheck="false" placeholder="Filter tables"
           class="w-full rounded border border-line bg-base-950 px-2 py-1
                  text-[12px] text-ink"
           data-model="dbc_filter">
  </div>

  <div class="min-h-0 flex-1 overflow-y-auto p-1"
       data-for="entry in dbc_tables.filter(e => e.name.toLowerCase().includes(dbc_filter.toLowerCase()))">
    <template>
      <!-- One click reads, two keep. In the two-click mode a single click
           still opens the table - you can read it, sort it, search it - but
           into one reused tab that the next single click replaces. A double
           click, or the first edit, gives it a tab of its own.

           In the one-click mode every click keeps, which is the simpler
           behaviour for somebody working in two or three tables all day. -->
      <button type="button" class="dbc-table"
              data-class-is-open="entry.name === dbc_open"
              data-class-is-picked="entry.name === dbc_picked && entry.name !== dbc_open"
              data-attr-data-disabled="!entry.editable"
              data-attr-title="entry.editable ? entry.name : entry.name + ': no definition for this build'"
              data-on-click="dbc_picked = entry.name;
                if (entry.editable) neutrino.invoke('dbc:open', {
                  name: entry.name, pinned: dbc_open_on === 'single' })"
              data-on-dblclick="if (entry.editable) neutrino.invoke('dbc:open', {
                name: entry.name, pinned: true })">
        <span class="truncate" data-text="entry.name"></span>
      </button>
    </template>
  </div>

  <div class="shrink-0 border-t border-line px-2 py-1.5 text-[11.5px] text-ink-faint"
       data-text="dbc_tables.length + ' tables'"></div>
</div>
]==]

-- ═══════════════════════════════════════════════════════════════════════════
-- The work area
-- ═══════════════════════════════════════════════════════════════════════════

GRID = [==[
<div class="flex min-h-0 flex-1 flex-col">

  <!-- Nothing open yet. The panel beside this is the list, so the thing to
       say is where it is. -->
  <div class="grid min-h-0 flex-1 place-items-center" data-show="dbc_open === ''">
    <div class="max-w-sm text-center">
      <h2 class="mb-1 text-[14px] font-semibold text-ink">No table open</h2>
      <p class="text-[12.5px] leading-relaxed text-ink-dim">
        Choose one from the list on the left. A table with no definition for
        this build is there but cannot be opened.
      </p>
    </div>
  </div>

  <div class="flex min-h-0 flex-1 flex-col" data-show="dbc_open !== ''">

    <!-- The language this file is really written in is not always the one the
         workspace is set to, and writing a cell at the wrong slot leaves the
         row holding two names. Offered rather than done, unless the setting
         says otherwise. -->
    <div class="dbc-banner" data-show="dbc_locale_hint !== ''">
      <span data-text="dbc_locale_hint"></span>
      <button type="button" class="dbc-chip"
              data-on-click="neutrino.invoke('dbc:use-locale', dbc_locale_offer)"
              data-text="'Switch to ' + dbc_locale_offer"></button>
      <button type="button" class="dbc-chip" data-on-click="dbc_locale_hint = ''"
        >Keep <span data-text="dbc_info.locale"></span></button>
    </div>

    <!-- The scroller. Its content is the size of the whole table, so the bars
         are the table's; what is drawn inside is the visible block. -->
    <div class="dbc-scroller min-h-0 flex-1 overflow-auto"
         data-on-scroll="
           const first = Math.max(0, Math.floor($el.scrollTop / <%= metrics.row %>) - <%= metrics.margin_rows %>);
           const offs = dbc_grid.offsets;
           let lo = 0, hi = offs.length - 1;
           while (lo < hi) {
             const mid = (lo + hi + 1) >> 1;
             if (offs[mid] <= $el.scrollLeft) lo = mid; else hi = mid - 1;
           }
           const left = Math.max(0, lo - <%= metrics.margin_columns %>);
           if (first !== dbc_grid.row || left !== dbc_grid.col)
             neutrino.invoke('dbc:window', { row: first, col: left })">

      <div class="relative"
           data-attr-style="'height:' + (dbc_grid.total_rows * <%= metrics.row %> + <%= metrics.head %>)
             + 'px;width:' + (dbc_grid.total_width + <%= metrics.index %>) + 'px'">

        <!-- Header. Frozen at the top by sticking to the scroller, so it
             scrolls sideways with the columns it names. -->
        <div class="sticky top-0 z-20 flex bg-base-850"
             style="height: <%= metrics.head %>px">
          <div class="dbc-index sticky left-0 z-30 border-b border-line">#</div>
          <div class="flex" data-for="column in dbc_grid.columns"
               data-attr-style="'margin-left:' + dbc_grid.x + 'px'">
            <template>
              <div class="dbc-head" data-attr-style="'width:' + column.w + 'px'">
                <button type="button" class="dbc-sort"
                        data-attr-title="'Sort by ' + column.label"
                        data-on-click="neutrino.invoke('dbc:sort', column.index)">
                  <span class="truncate" data-text="column.label"></span>
                  <span class="dbc-arrow" data-show="column.sorted"
                        data-text="column.sorted === 'desc' ? '▼' : '▲'"></span>
                </button>

                <span class="pl-1.5 text-[10.5px] text-ink-faint"
                      data-text="column.extra ? column.kind + ' ' + column.extra : column.kind"></span>

                <!-- The drag handle. Its own element rather than the cell's
                     edge, so clicking a header still sorts. -->
                <span class="dbc-grip"
                      data-on-mousedown="window.dbcResize($event, column.index, column.w)"></span>
              </div>
            </template>
          </div>
        </div>

        <!-- The visible block, put where the rows it holds belong. -->
        <div class="absolute left-0" data-for="row in dbc_grid.rows"
             data-attr-style="'top:' + (<%= metrics.head %> + dbc_grid.row * <%= metrics.row %>) + 'px'">
          <template>
            <div class="flex" style="height: <%= metrics.row %>px">
              <!-- The row's own number, and where a row is acted on. Picking a
                   row by clicking a cell meant the act of reading one selected
                   it; here the number is the handle and the cells are text. -->
              <div class="dbc-index dbc-handle sticky left-0 z-10"
                   data-class-is-new="row.new"
                   data-class-is-current="row.index === dbc_row"
                   data-on-click="dbc_row = row.index">
                <span data-text="row.index"></span>
                <span class="ml-auto text-[10.5px] text-ink-faint"
                      data-show="dbc_info.has_id && dbc_row !== row.index"
                      data-text="row.id"></span>

                <span class="dbc-rowacts" data-show="dbc_row === row.index">
                  <button type="button" title="Duplicate this row"
                          data-on-click="dbc_row = row.index; neutrino.invoke('dbc:duplicate')"
                    ><%- icon("copy", 12) %></button>
                  <button type="button" title="Delete this row"
                          data-on-click="dbc_row = row.index; neutrino.invoke('dbc:delete')"
                    ><%- icon("trash", 12) %></button>
                </span>
              </div>

              <div class="flex" data-for="cell, at in row.cells"
                   data-attr-style="'margin-left:' + dbc_grid.x + 'px'">
                <template>
                  <!-- One input per visible cell. A cell that is a field means
                       focus, selection and typing come from the browser rather
                       than from an editor overlay of our own.

                       The commit is on change, which is blur or Enter, and
                       Enter blurs first so both take the same path. -->
                  <input type="text" spellcheck="false" class="dbc-cell"
                         data-attr-style="'width:' + dbc_grid.columns[at].w + 'px'"
                         data-attr-value="cell.v"
                         data-attr-title="cell.e || ''"
                         data-class-is-dirty="cell.d"
                         data-class-is-bad="cell.e"
                         data-class-is-link="dbc_grid.columns[at].foreign"
                         data-on-focus="dbc_row = row.index;
                           if (dbc_resolver && dbc_grid.columns[at].foreign)
                             window.dbcPick($el, row.index,
                               dbc_grid.col + at + 1,
                               dbc_grid.columns[at].foreign)"
                         data-on-keydown="
                           if ($event.key === 'Enter') $el.blur();
                           else if ($event.key === 'Escape') { $el.value = cell.v; $el.blur() }"
                         data-on-change="neutrino.invoke('dbc:set', {
                           row: row.index,
                           column: dbc_grid.col + at + 1,
                           value: $el.value })">
                </template>
              </div>
            </div>
          </template>
        </div>
      </div>
    </div>

    <!-- The generated Lua, along the bottom. Closed to a single bar, because
         it answers a question you only sometimes have. -->
    <div class="shrink-0 border-t border-line bg-base-850">
      <button type="button" class="flex w-full items-center gap-2 px-2 py-1
                                   text-[11.5px] text-ink-dim"
              data-on-click="dbc_preview_open = !dbc_preview_open;
                             if (dbc_preview_open) neutrino.invoke('dbc:preview')">
        <span class="dbc-caret" data-class-is-open="dbc_preview_open"
        ><%- icon("chevron", 14) %></span>
        <span>Lua</span>
        <span class="text-ink-faint"
              data-text="dbc_info.changes === 1 ? '1 changed row'
                : dbc_info.changes + ' changed rows'"></span>
      </button>

      <pre class="dbc-preview selectable" data-show="dbc_preview_open"
           data-text="dbc_preview"></pre>
    </div>
  </div>

  <!-- The rows a foreign key could point at. Anchored to the cell rather than
       centred, because what is being answered is "what goes in *there*" and a
       dialog in the middle of the screen loses the there. -->
  <div class="surface-float dbc-choices" data-show="dbc_picker.table !== ''">
    <div class="flex items-center gap-2 border-b border-line px-2 py-1.5">
      <span class="text-[11px] text-ink-faint" data-text="dbc_picker.table"></span>
      <button type="button" class="ml-auto text-ink-faint hover:text-ink"
              data-on-click="dbc_picker = { row: 0, column: 0, table: '', label: '' }"
        ><%- icon("close", 12) %></button>
    </div>

    <input type="text" spellcheck="false" placeholder="Search by name or id"
           class="w-full border-b border-line bg-base-950 px-2 py-1
                  text-[12px] text-ink"
           data-on-input="neutrino.invoke('dbc:resolve', {
             column: dbc_picker.column, needle: $el.value })">

    <div class="max-h-56 overflow-y-auto" data-for="choice in dbc_choices">
      <template>
        <button type="button" class="dbc-choice"
                data-on-click="neutrino.invoke('dbc:set', {
                    row: dbc_picker.row, column: dbc_picker.column,
                    value: String(choice.id) });
                  dbc_picker = { row: 0, column: 0, table: '', label: '' }">
          <span class="dbc-choice-id" data-text="choice.id"></span>
          <span class="truncate" data-text="choice.label"></span>
        </button>
      </template>
    </div>

    <div class="border-t border-line px-2 py-1 text-[11px] text-ink-faint"
         data-show="dbc_choices.length === 0">Nothing matches.</div>
  </div>

  <!-- Where this table sits among the ones that refer to each other, drawn
       rather than listed: the shape of the thing is the answer, and a column
       of names does not have a shape.

       The canvas is Cytoscape's, laid out and drawn by it. A graph is pan,
       zoom, hit-testing and a force layout, which is a library's work and not
       a page's. -->
  <div class="fixed inset-0 z-50 grid place-items-center bg-base-950/60"
       data-show="dbc_graph_open"
       data-on-click="if ($event.target === $el) dbc_graph_open = false">
    <div class="surface-float flex h-[82vh] w-[88vw] flex-col rounded-panel">
      <div class="flex shrink-0 items-center gap-3 border-b border-line px-4 py-2.5">
        <h2 class="text-[13.5px] font-semibold text-ink">
          Linked tables<span data-show="dbc_graph.focus !== ''"
            data-text="': ' + dbc_graph.focus"></span>
        </h2>

        <span class="text-[11.5px] text-ink-faint"
              data-text="dbc_graph.nodes.length + ' tables, ' +
                dbc_graph.edges.length + ' links'"></span>

        <span class="text-[11.5px] text-ink-faint" data-show="dbc_graph.focus !== ''"
          >Click a table to open it. Double-click to centre the graph on it.</span>
        <span class="text-[11.5px] text-ink-faint" data-show="dbc_graph.focus === ''"
          >Every linked table in the client. Drag to pan, wheel to zoom.</span>

        <div class="ml-auto flex items-center gap-1">
          <!-- The whole client, whether or not a table is in front. Without
               this the wide view is only reachable before the first table is
               opened, because the one in front stays in front. -->
          <button type="button" class="dbc-chip"
                  data-class-is-on="dbc_graph.focus === ''"
                  data-on-click="neutrino.invoke('dbc:relations', '*')"
            >Whole client</button>
          <button type="button" class="dbc-chip" data-show="dbc_open !== ''"
                  data-class-is-on="dbc_graph.focus !== ''"
                  data-on-click="neutrino.invoke('dbc:relations', dbc_open)"
                  data-text="dbc_open"></button>

          <span class="mx-1 h-4 w-px bg-line"></span>

          <button type="button" class="dbc-chip"
                  data-on-click="window.dbcGraphFit()">Fit</button>
          <button type="button" class="dbc-chip"
                  data-on-click="window.dbcGraphLayout()">Re-arrange</button>
          <button type="button" class="ml-1 text-ink-faint hover:text-ink"
                  data-on-click="dbc_graph_open = false"><%- icon("close", 14) %></button>
        </div>
      </div>

      <!-- The host is the flex child itself. Wrapped in a relative box with
           the canvas absolutely inside it, the canvas took its width from the
           wrapper and no height at all - and a graph laid out into a box of
           no height is a graph nobody can see. -->
      <div class="dbc-canvas min-h-0 flex-1"
           data-show="dbc_graph.nodes.length > 0"></div>

      <div class="dbc-graph-empty" data-show="dbc_graph.nodes.length === 0">
        Nothing is linked to anything here. Either the definitions carry no
        foreign keys for this build, or the client has none of the tables
        they name.
      </div>
    </div>
  </div>

  <!-- What the filter box understands. Reachable from the box itself and from
       Help, because the two ways people look for this are "what do I type
       here" and "where is the documentation". -->
  <div class="fixed inset-0 z-50 grid place-items-center bg-base-950/60"
       data-show="dbc_help"
       data-on-click="if ($event.target === $el) dbc_help = false">
    <div class="surface-float flex max-h-[80vh] w-[620px] flex-col rounded-panel">
      <div class="flex shrink-0 items-center border-b border-line px-4 py-2.5">
        <h2 class="text-[13.5px] font-semibold text-ink">Filtering rows</h2>
        <button type="button" class="ml-auto text-ink-faint hover:text-ink"
                data-on-click="dbc_help = false"><%- icon("close", 14) %></button>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3 text-[12.5px]
                  leading-relaxed text-ink-dim selectable">

        <p class="mb-3">
          Type a phrase to search every text column, or a condition to search
          one column by name.
        </p>

        <dl class="dbc-help">
          <dt>fire bolt</dt>
          <dd>Rows holding that text in any string or localised column.</dd>

          <dt>SpellLevel &gt; 60</dt>
          <dd>Numbers compare as numbers. Also <code>&lt;</code>
              <code>&lt;=</code> <code>&gt;=</code> <code>=</code>
              <code>!=</code>.</dd>

          <dt>Name LIKE 'Fire%'</dt>
          <dd><code>%</code> stands for any run of characters and
              <code>_</code> for exactly one. The whole value has to match.</dd>

          <dt>Name CONTAINS 'bolt'</dt>
          <dd>Anywhere in the value. <code>STARTS</code> and <code>ENDS</code>
              work the same way.</dd>

          <dt>SpellLevel &gt;= 60 AND Category = 0</dt>
          <dd><code>AND</code>, <code>OR</code>, <code>NOT</code> and brackets.</dd>
        </dl>

        <h3 class="mb-1 mt-4 text-[12.5px] font-semibold text-ink">
          Localised columns
        </h3>
        <p class="mb-2">
          A localised field has one column per language, and its name carries a
          space &mdash; which the filter reads as two words. Quote it, or join
          it with a dot:
        </p>
        <dl class="dbc-help">
          <dt>'Name_lang frFR' CONTAINS 'feu'</dt>
          <dd>The French column of <code>Name_lang</code>.</dd>

          <dt>Name_lang.frFR LIKE 'Boule%'</dt>
          <dd>The same column, without reaching for the quote key.</dd>

          <dt>Name_lang CONTAINS 'feu'</dt>
          <dd>Falls back to the field's first column, which is whichever
              language is leftmost.</dd>
        </dl>

        <h3 class="mb-1 mt-4 text-[12.5px] font-semibold text-ink">
          Two things worth knowing
        </h3>
        <p class="mb-2">
          Text comparisons ignore case, all of them.
        </p>
        <p>
          Quoting a number asks for a text comparison, which is not the same
          answer: <code>SpellLevel &gt; 10</code> keeps 11 and up, while
          <code>SpellLevel &gt; '10'</code> keeps 2, 9 and 11 &mdash; because
          "2" sorts after "10" as text.
        </p>
      </div>
    </div>
  </div>

  <!-- Deleting asks first. A row is gone from the grid the moment it goes, and
       the only way back is an undo the user has to know about. -->
  <div class="fixed inset-0 z-50 grid place-items-center bg-base-950/60"
       data-show="dbc_confirm !== ''">
    <div class="surface-float w-[380px] rounded-panel p-4">
      <h2 class="mb-1 text-[13.5px] font-semibold text-ink">Delete row</h2>
      <p class="mb-4 text-[12.5px] leading-relaxed text-ink-dim"
         data-text="dbc_confirm"></p>
      <div class="flex justify-end gap-2">
        <button type="button"
                class="rounded border border-line bg-base-800 px-3 py-1.5
                       text-[12.5px] text-ink-dim transition-colors
                       hover:border-base-600 hover:text-ink"
                data-on-click="dbc_confirm = ''">Cancel</button>
        <button type="button"
                class="rounded border border-danger bg-base-800 px-3 py-1.5
                       text-[12.5px] text-ink transition-colors hover:bg-danger"
                data-on-click="dbc_confirm = ''; neutrino.invoke('dbc:delete-row')"
        >Delete</button>
      </div>
    </div>
  </div>
</div>
]==]

--- Renders one of the regions.
---@param source string Template source.
---@param icon fun(name: string, size?: integer): string
---@return string html
---@private
render = (source, icon) ->
  compiled, err = etlua.compile source
  error "dbc template: #{err}" unless compiled
  compiled { metrics: M.METRICS, :icon }

--- The strip under the category bar.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.context = (icon) -> render CONTEXT, icon

--- The table list.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.panel = (icon) -> render PANEL, icon

--- The grid, the preview and the confirmation.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.grid = (icon) -> render GRID, icon

M
