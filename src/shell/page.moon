--- The shell's markup.
--
-- Four bars and a work area, in the shape a development tool has rather than
-- the shape a page has:
--
--   title bar      the application mark, the menus, the window buttons
--   category bar   one icon per tool; the name appears on hover
--   context bar    the active tool's own strip, when it asks for one
--   action rail    the active tool's actions, down the left edge
--
-- Every tool's rail, strip and panel are rendered once and shown by which tool
-- is active. Nothing pushes markup through state: what a tool contributes is
-- known when the page is built, and a region that is not the active tool's is
-- simply hidden.
--
-- The window is frameless, so this draws its own chrome. `.drag` marks what the
-- system should treat as a title bar, `.no-drag` takes it back for anything
-- clickable inside it.
--
-- Written as an etlua template: inside the tags the language is Lua, `<%= %>`
-- escapes and `<%- %>` does not.
---@module shell.page

etlua = require "etlua"
menus = require "shell.menus"
settings = require "shell.settings"
tools = require "shell.tools"

-- 16px, stroke-based, inheriting colour. Drawn here rather than fetched: a
-- handful of glyphs is not worth a font file or a sprite sheet, and inline SVG
-- takes the colour of whatever it sits in.
ICONS = {
  home: '<path d="M2.75 7 8 2.75 13.25 7v6.25a1 1 0 0 1-1 1h-8.5a1 1 0 0 1-1-1Z"/><path d="M6.25 14.25v-4.5h3.5v4.5"/>'
  database: '<path d="M8 2.75c3 0 5.25.8 5.25 1.75S11 6.25 8 6.25 2.75 5.45 2.75 4.5 5 2.75 8 2.75Z"/><path d="M13.25 4.5v7c0 .95-2.25 1.75-5.25 1.75s-5.25-.8-5.25-1.75v-7"/><path d="M13.25 8c0 .95-2.25 1.75-5.25 1.75S2.75 8.95 2.75 8"/>'
  folder: '<path d="M2.25 12.25v-8.5a1 1 0 0 1 1-1h3l1.5 2h5a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1Z"/>'
  search: '<circle cx="7.25" cy="7.25" r="4.5"/><path d="m10.5 10.5 3 3"/>'
  settings: '<circle cx="8" cy="8" r="2.25"/><path d="M8 1.75v1.5M8 12.75v1.5M14.25 8h-1.5M3.25 8h-1.5M12.42 3.58l-1.06 1.06M4.64 11.36l-1.06 1.06M12.42 12.42l-1.06-1.06M4.64 4.64 3.58 3.58"/>'
  table: '<path d="M2.75 3.75h10.5v8.5H2.75Z"/><path d="M2.75 6.75h10.5M6.25 6.75v5.5"/>'
  plus: '<path d="M8 3.5v9M3.5 8h9"/>'
  copy: '<rect x="5.5" y="5.5" width="7.75" height="7.75" rx="1"/><path d="M10.5 3.5v-.25a1 1 0 0 0-1-1H3.75a1 1 0 0 0-1 1V9.5a1 1 0 0 0 1 1H4"/>'
  trash: '<path d="M3.25 4.75h9.5M6.5 4.75V3.5a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1v1.25"/><path d="M4.75 4.75 5.25 13a1 1 0 0 0 1 .9h3.5a1 1 0 0 0 1-.9l.5-8.25"/>'
  undo: '<path d="M3 8.25h7a3 3 0 0 1 0 6H7"/><path d="m5.5 5.5-2.75 2.75L5.5 11"/>'
  redo: '<path d="M13 8.25H6a3 3 0 0 0 0 6h3"/><path d="m10.5 5.5 2.75 2.75L10.5 11"/>'
  save: '<path d="M3.75 2.75h6.5l3 3v7.5a1 1 0 0 1-1 1h-8.5a1 1 0 0 1-1-1v-9.5a1 1 0 0 1 1-1Z"/><path d="M5.25 2.75v4h5.5v-4M5.25 13.25v-3.5h5.5v3.5"/>'
  chevron: '<path d="m4.5 6.25 3.5 3.5 3.5-3.5"/>'
  minimize: '<path d="M3 8h10"/>'
  maximize: '<rect x="3.5" y="3.5" width="9" height="9" rx="1"/>'
  restore: '<rect x="3.5" y="5.5" width="7" height="7" rx="1"/><path d="M5.5 3.5h7v7"/>'
  close: '<path d="m4 4 8 8M12 4l-8 8"/>'
}

--- An inline icon.
---@param name string Key in ICONS.
---@param size? integer Pixels. Defaults to 16.
---@return string html
icon = (name, size = 16) ->
  body = ICONS[name]
  return "" unless body

  '<svg width="' .. size .. '" height="' .. size .. '" viewBox="0 0 16 16" ' ..
    'fill="none" stroke="currentColor" stroke-width="1.25" ' ..
    'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' ..
    body .. '</svg>'

SOURCE = [==[
<div class="flex h-screen flex-col bg-base-900 text-ink">

  <!-- Title bar ---------------------------------------------------------- -->
  <header class="drag flex h-8 shrink-0 items-center border-b border-line
                 bg-base-850 pl-2">

    <div class="flex items-center gap-2 pr-3 text-accent">
      <%- icon("database", 15) %>
      <span class="text-[12px] font-semibold tracking-wide text-ink">WowLabs</span>
    </div>

    <nav class="flex items-center gap-0.5 text-[12.5px]">
      <% for _, menu in ipairs(menus) do %>
        <div class="relative no-drag">
          <button type="button" class="menu-title"
                  data-class-is-open="menu === '<%= menu.id %>'"
                  data-on-click="menu = menu === '<%= menu.id %>' ? '' : '<%= menu.id %>'"
                  data-on-mouseenter="if (menu !== '') menu = '<%= menu.id %>'"
          ><%= menu.label %></button>

          <div class="surface-float absolute left-0 top-[calc(100%+4px)] z-50
                      min-w-[248px] rounded-panel p-1 text-[12.5px]"
               data-show="menu === '<%= menu.id %>'">
            <% for _, item in ipairs(menu.items) do %>
              <% if item.separator then %>
                <div class="menu-separator"></div>
              <% elseif item.heading then %>
                <div class="px-3 pb-0.5 pt-1.5 text-[11px] font-semibold
                            uppercase tracking-wider text-ink-faint"><%= item.heading %></div>
              <% elseif item.list then %>
                <!-- A menu whose entries are not known when the page is built:
                     a list in the store, one item per element. `entry` is the
                     row, so the action is written against it. -->
                <div data-for="entry in <%= item.list %>">
                  <template>
                    <button type="button" class="menu-item"
                            data-on-click="menu = ''; <%= item.action %>">
                      <span class="truncate" data-text="entry"></span>
                    </button>
                  </template>
                </div>
                <div class="menu-item" data-disabled
                     data-show="<%= item.list %>.length === 0"><%= item.empty or "Nothing yet" %></div>
              <% else %>
                <button type="button" class="menu-item"
                  <% if item.enabled then %>
                        data-attr-data-disabled="!(<%= item.enabled %>)"
                  <% end %>
                        data-on-click="menu = ''; <%= item.action %>">
                  <span><%= item.label %></span>
                  <% if item.accelerator then %>
                    <span class="ml-auto pl-6 text-ink-faint"><%= item.accelerator %></span>
                  <% end %>
                </button>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </nav>

    <div class="flex-1 text-center text-[12px] text-ink-faint"
         data-text="workspace || 'No workspace'"></div>

    <div class="no-drag flex h-full items-stretch">
      <button type="button" class="window-button" title="Minimise"
              data-on-click="neutrino.invoke('shell:minimize')"><%- icon("minimize") %></button>
      <button type="button" class="window-button"
              data-attr-title="maximized ? 'Restore' : 'Maximise'"
              data-on-click="neutrino.invoke('shell:maximize')"
              data-html="maximized ? icon_restore : icon_maximize"></button>
      <button type="button" class="window-button is-close" title="Close"
              data-on-click="neutrino.invoke('shell:close')"><%- icon("close") %></button>
    </div>
  </header>

  <!-- Category bar ------------------------------------------------------- -->
  <!-- Icons only. The name appears under the cursor, because a row of labels
       is a menu bar and this is not one. -->
  <div class="flex h-10 shrink-0 items-center gap-1 border-b border-line
              bg-base-900 px-2">
    <% for _, entry in ipairs(tools) do %>
      <button type="button" class="category-button group"
              data-class-is-active="tool === '<%= entry.id %>'"
              data-on-click="neutrino.invoke('shell:tool', '<%= entry.id %>')">
        <%- icon(entry.icon or "home", 17) %>
        <span class="surface-float tip tip-below"><%= entry.label %></span>
      </button>
    <% end %>
  </div>

  <!-- Context bar -------------------------------------------------------- -->
  <!-- The active tool's own strip, when it declares one. -->
  <% for _, entry in ipairs(tools) do %>
    <% if entry.context then %>
      <div class="flex h-9 shrink-0 items-center gap-1 border-b border-line
                  bg-base-850 px-2 text-[12.5px]"
           data-show="tool === '<%= entry.id %>'"><%- entry.context %></div>
    <% end %>
  <% end %>

  <!-- Body --------------------------------------------------------------- -->
  <div class="flex min-h-0 flex-1">

    <!-- Action rail: the active tool's, one column of them. -->
    <nav class="flex w-11 shrink-0 flex-col items-center border-r border-line
                bg-base-850 py-1">
      <% for _, entry in ipairs(tools) do %>
        <div class="flex w-full flex-col items-center"
             data-show="tool === '<%= entry.id %>'">
          <% for _, action in ipairs(entry.actions) do %>
            <!-- An action may be one this tool cannot always offer. A button
                 that is there and refuses is worse than one that is not: the
                 refusal has to be read, and by then it has been clicked. -->
            <button type="button" class="action-button group"
                    <% if action.shown then %>data-show="<%= action.shown %>"<% end %>
                    data-on-click="<%= action.action %>">
              <%- icon(action.icon or "settings", 17) %>
              <span class="surface-float tip tip-right"><%= action.title %></span>
            </button>
          <% end %>
        </div>
      <% end %>
    </nav>

    <!-- Side panel: also the active tool's, when it has one. -->
    <% for _, entry in ipairs(tools) do %>
      <% if entry.panel then %>
        <aside class="flex w-64 shrink-0 flex-col border-r border-line bg-base-850"
               data-show="side_open && tool === '<%= entry.id %>'"><%- entry.panel %></aside>
      <% end %>
    <% end %>

    <!-- Work area -->
    <main class="flex min-w-0 flex-1 flex-col bg-base-900">
      <!-- One tool's tabs, not everyone's. A tab belongs to the tool that
           opened it, so moving to another tool puts that tool's work on
           screen rather than a row of everything ever opened. A tab with no
           tool of its own is the shell's, and the shell lives in Workspace. -->
      <!-- Open twenty tables and the strip runs past the window, so it
           scrolls. The wheel is turned sideways here: there is nothing to
           scroll vertically in a row of tabs, and a wheel that did nothing
           would read as the strip being stuck. -->
      <div class="tab-strip flex h-9 shrink-0 items-end overflow-x-auto
                  border-b border-line bg-base-850 px-1"
           data-show="tabs.filter(t => (t.tool || 'workspace') === tool).length > 0"
           data-on-wheel="if ($event.deltaY !== 0) {
             $event.preventDefault(); $el.scrollLeft += $event.deltaY }">
        <div class="flex gap-px"
             data-for="tab in tabs.filter(t => (t.tool || 'workspace') === tool)">
          <template>
            <button type="button"
                    class="flex h-8 shrink-0 items-center gap-2 rounded-t-sm border
                           border-b-0 border-transparent px-3 text-[12.5px] text-ink-dim"
                    data-class-bg-base-900="tab.id === active_tab"
                    data-class-border-line="tab.id === active_tab"
                    data-class-text-ink="tab.id === active_tab"
                    data-class-is-preview="tab.preview"
                    data-attr-title="tab.preview
                      ? tab.title + ' — being read. Double-click it in the list, or edit it, to keep it.'
                      : tab.title"
                    data-on-mousedown="if ($event.button === 1) {
                      $event.preventDefault();
                      neutrino.invoke('shell:close-tab', tab.id) }"
                    data-on-click="active_tab = tab.id; tool = tab.tool || tool">
              <span data-text="tab.title"></span>
              <!-- A page that takes the work area has to be dismissable, or it
                   is a modal that forgot to draw its own frame. -->
              <span class="tab-close"
                    data-on-click="event.stopPropagation(); neutrino.invoke('shell:close-tab', tab.id)"
              ><%- icon("close", 11) %></span>
            </button>
          </template>
        </div>
      </div>

      <!-- The settings page. A tab in the work area rather than a dialog, so
           it stays open while something else is changed and comes back to
           where it was. -->
      <div class="flex min-h-0 flex-1" data-show="active_tab === 'settings'">
        <%- settings_page %>
      </div>

      <!-- A tool's own work area, shown while one of its tabs is the active
           one. Rendered once, like its rail and its strip: which tab a tab
           belongs to is data the shell already has. -->
      <% for _, entry in ipairs(tools) do %>
        <% if entry.view then %>
          <div class="flex min-h-0 flex-1 flex-col"
               data-show="tabs.some(tab => tab.id === active_tab && tab.tool === '<%= entry.id %>')"
          ><%- entry.view %></div>
        <% end %>
      <% end %>

      <!-- A tool with nothing open should say what to do next, not show an
           empty grid and leave you to guess - and once that has been done, it
           should stop saying it. -->
      <div class="grid min-h-0 flex-1 place-items-center"
           data-show="tabs.filter(t => (t.tool || 'workspace') === tool).length === 0
                      && workspace === ''">
        <div class="max-w-md text-center">
          <div class="mx-auto mb-4 grid h-14 w-14 place-items-center rounded-full
                      border border-line bg-base-850 text-ink-faint">
            <%- icon("database", 24) %>
          </div>
          <h1 class="mb-1 text-[15px] font-semibold text-ink">No workspace open</h1>
          <p class="mb-5 text-[12.5px] leading-relaxed text-ink-dim">
            A workspace points at a folder of client files and the build they came
            from. Every tool reads its settings from there.
          </p>
          <div class="flex items-center justify-center gap-2">
            <button type="button"
                    class="rounded border border-accent-dim bg-accent-deep px-3 py-1.5
                           text-[12.5px] text-ink transition-colors
                           hover:border-accent hover:bg-base-700"
                    data-on-click="neutrino.invoke('shell:open-workspace')">
              Open workspace
            </button>
            <button type="button"
                    class="rounded border border-line bg-base-800 px-3 py-1.5
                           text-[12.5px] text-ink-dim transition-colors
                           hover:border-base-600 hover:text-ink"
                    data-on-click="nui.set('dialog', 'new-workspace')">
              New workspace
            </button>
          </div>
        </div>
      </div>

      <!-- With one open, the same space offers the tools. Built from the
           registry rather than from a list here: a tool appears by registering
           itself, the way it appears in the category bar.

           The active tool is left out. This is the home page of whichever tool
           you are in, so its own entry would be the one card that does
           nothing. -->
      <div class="min-h-0 flex-1 overflow-y-auto"
           data-show="tabs.filter(t => (t.tool || 'workspace') === tool).length === 0
                      && workspace !== ''">
        <div class="mx-auto w-full max-w-3xl px-8 py-10">
          <h1 class="text-[15px] font-semibold text-ink">Workspace open</h1>
          <p class="mb-6 truncate text-[12.5px] text-ink-faint" data-text="workspace"></p>

          <!-- Starred first, and only when there are any. An empty heading
               over an empty row would be the picker teaching itself. -->
          <div class="mb-6" data-show="favourites.length > 0">
            <h2 class="tool-section">Favourites</h2>
            <div class="tool-grid">
              <% for _, entry in ipairs(tools) do %>
                <div class="tool-card" data-tool="<%= entry.id %>"
                     data-show="favourites.includes('<%= entry.id %>')
                                && tool !== '<%= entry.id %>'">
                  <%- tool_card(entry, icon) %>
                </div>
              <% end %>
            </div>
          </div>

          <!-- The active tool is left out. This is the home page of whichever
               tool you are in, so its own card would be the one that does
               nothing. -->
          <h2 class="tool-section">All tools</h2>
          <div class="tool-grid">
            <% for _, entry in ipairs(tools) do %>
              <div class="tool-card" data-tool="<%= entry.id %>"
                   data-show="tool !== '<%= entry.id %>'">
                <%- tool_card(entry, icon) %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </main>
  </div>

  <!-- Status bar --------------------------------------------------------- -->
  <footer class="flex h-[22px] shrink-0 items-center border-t border-line
                 bg-base-850 text-[11.5px]" data-show="status_open">
    <div class="status-item" data-show="build !== ''">
      <span data-text="'Build ' + build"></span>
    </div>
    <div class="status-item" data-show="dirty">
      <span class="text-accent">Unsaved changes</span>
    </div>
    <div class="flex-1"></div>
    <div class="status-item" data-text="status"></div>
  </footer>

  <!-- Closes an open menu on the next click anywhere: under the dropdowns,
       above everything else. Marked, because "the full-screen one" stopped
       being a description of it as soon as a tool drew a dialog. -->
  <div class="fixed inset-0 z-40" data-backdrop data-show="menu !== ''"
       data-on-click="menu = ''"></div>
</div>
]==]

template = nil

--- The whole shell.
--
ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }

--- HTML-escapes a value built into markup from Lua.
--
-- etlua's `<%= %>` does this inside a template; a fragment assembled here has
-- to do it itself. A tool's label is ours today and a module's tomorrow.
---@param text any
---@return string
---@private
escape = (text) -> (tostring(text or "")\gsub "[&<>\"']", ESCAPES)

CARD = [[
<button type="button" class="tool-star"
        data-class-is-on="favourites.includes('%s')"
        data-attr-title="favourites.includes('%s') ? 'Remove from favourites'
          : 'Add to favourites'"
        data-on-click="event.stopPropagation();
                       neutrino.invoke('shell:favourite', '%s')">&#9733;</button>

<button type="button" class="flex w-full flex-col items-center gap-2"
        data-on-click="neutrino.invoke('shell:tool', '%s')">
  <span class="grid h-10 w-10 place-items-center rounded border border-line
               bg-base-800 text-ink-faint">%s</span>
  <span data-name class="text-[12.5px] text-ink">%s</span>
  <span data-about class="text-[11px] leading-snug text-ink-faint">%s</span>
</button>
]]

--- The inside of one card on the home page's picker.
--
-- Two buttons rather than one: a star nested inside the button that opens the
-- tool could not be clicked without also opening it.
---@param entry table A registered tool.
---@param icon fun(name: string, size?: integer): string
---@return string html
---@private
tool_card = (entry, icon) ->
  id = escape entry.id
  string.format CARD, id, id, id, id,
    (icon entry.icon or "home", 20),
    (escape entry.label),
    (escape entry.description or "")

-- Rendered after every tool has registered, since what a tool contributes is
-- built into the markup rather than pushed in later.
---@return string html
render = ->
  unless template
    compiled, err = etlua.compile SOURCE
    error "shell template: #{err}" unless compiled
    template = compiled

  -- The settings page is rendered in, not pushed through state: like a tool's
  -- rail, what it contains is known once every section has registered.
  template {
    menus: menus.bar
    tools: tools.list
    settings_page: settings.render icon
    :icon
    :tool_card
  }

{ :render, :icon, :ICONS }
