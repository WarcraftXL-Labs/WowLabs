--- The shell's markup.
--
-- One screen, built as a desktop application rather than as a page: a title bar
-- that is also the menu bar, an activity rail, a side panel, the work area, and
-- a status bar. Nothing scrolls except the panes meant to.
--
-- The window is frameless, so this draws its own chrome. `.drag` marks what the
-- system should treat as a title bar, `.no-drag` takes it back for anything
-- clickable inside it.
--
-- Written as an etlua template rather than as concatenated strings: the markup
-- is the majority of this file and it should read as markup. Inside the tags
-- the language is Lua - `<%= %>` escapes, `<%- %>` does not.
---@module shell.page

etlua = require "etlua"
menus = require "shell.menus"

-- 16px, stroke-based, inheriting colour. Drawn here rather than fetched: a
-- handful of glyphs is not worth a font file or a sprite sheet, and inline SVG
-- takes the colour of whatever it sits in.
ICONS = {
  database: '<path d="M8 2.75c3 0 5.25.8 5.25 1.75S11 6.25 8 6.25 2.75 5.45 2.75 4.5 5 2.75 8 2.75Z"/><path d="M13.25 4.5v7c0 .95-2.25 1.75-5.25 1.75s-5.25-.8-5.25-1.75v-7"/><path d="M13.25 8c0 .95-2.25 1.75-5.25 1.75S2.75 8.95 2.75 8"/>'
  folder: '<path d="M2.25 12.25v-8.5a1 1 0 0 1 1-1h3l1.5 2h5a1 1 0 0 1 1 1v6.5a1 1 0 0 1-1 1h-9.5a1 1 0 0 1-1-1Z"/>'
  search: '<circle cx="7.25" cy="7.25" r="4.5"/><path d="m10.5 10.5 3 3"/>'
  settings: '<circle cx="8" cy="8" r="2.25"/><path d="M8 1.75v1.5M8 12.75v1.5M14.25 8h-1.5M3.25 8h-1.5M12.42 3.58l-1.06 1.06M4.64 11.36l-1.06 1.06M12.42 12.42l-1.06-1.06M4.64 4.64 3.58 3.58"/>'
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

-- Level 2 brackets: the markup below contains ]] in nothing today, and this
-- costs nothing to be sure of.
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

    <!-- The draggable middle, which also carries what the window is showing,
         the way a title bar does. -->
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

  <!-- Body --------------------------------------------------------------- -->
  <div class="flex min-h-0 flex-1">

    <nav class="flex w-11 shrink-0 flex-col items-center border-r border-line
                bg-base-850 py-1">
      <% for _, entry in ipairs(activities) do %>
        <button type="button" class="activity-button" title="<%= entry.title %>"
                data-class-is-active="activity === '<%= entry.id %>'"
                data-on-click="activity = activity === '<%= entry.id %>' ? '' : '<%= entry.id %>'"
        ><%- icon(entry.icon, 18) %></button>
        <% if entry.id == "search" then %><div class="flex-1"></div><% end %>
      <% end %>
    </nav>

    <aside class="flex w-64 shrink-0 flex-col border-r border-line bg-base-850"
           data-show="side_open && activity !== ''">
      <div class="flex h-8 shrink-0 items-center px-3 text-[11px] font-semibold
                  uppercase tracking-wider text-ink-faint"
           data-text="activity"></div>
      <div class="min-h-0 flex-1 overflow-auto px-3 pb-3 text-[12.5px]">
        <p class="text-ink-faint">Nothing open yet.</p>
      </div>
    </aside>

    <main class="flex min-w-0 flex-1 flex-col bg-base-900">
      <div class="flex h-9 shrink-0 items-end border-b border-line bg-base-850 px-1"
           data-show="tabs.length > 0">
        <div class="flex gap-px" data-for="tab in tabs">
          <template>
            <button type="button"
                    class="flex h-8 items-center gap-2 rounded-t-sm border border-b-0
                           border-transparent px-3 text-[12.5px] text-ink-dim"
                    data-class-bg-base-900="tab.id === active_tab"
                    data-class-border-line="tab.id === active_tab"
                    data-class-text-ink="tab.id === active_tab"
                    data-on-click="active_tab = tab.id">
              <span data-text="tab.title"></span>
            </button>
          </template>
        </div>
      </div>

      <!-- A tool with nothing open should say what to do next, not show an
           empty grid and leave you to guess. -->
      <div class="grid min-h-0 flex-1 place-items-center" data-show="tabs.length === 0">
        <div class="max-w-sm text-center">
          <div class="mx-auto mb-4 grid h-14 w-14 place-items-center rounded-full
                      border border-line bg-base-850 text-ink-faint">
            <%- icon("database", 24) %>
          </div>
          <h1 class="mb-1 text-[15px] font-semibold text-ink">No workspace open</h1>
          <p class="mb-5 text-[12.5px] leading-relaxed text-ink-dim">
            A workspace points at a folder of client database files and the build
            they came from. Everything else follows from that.
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
       above everything else. -->
  <div class="fixed inset-0 z-40" data-show="menu !== ''" data-on-click="menu = ''"></div>
</div>
]==]

-- The activity rail, in order. A module will add to this the same way it adds
-- to a menu.
ACTIVITIES = {
  { id: "explorer", icon: "folder", title: "Explorer" }
  { id: "tables", icon: "database", title: "Tables" }
  { id: "search", icon: "search", title: "Search" }
  { id: "settings", icon: "settings", title: "Settings" }
}

template = nil

--- The whole shell.
---@return string html
render = ->
  -- Compiled on first use and kept: the template does not change between
  -- renders, and parsing it once is the difference between a helper and a cost.
  unless template
    compiled, err = etlua.compile SOURCE
    error "shell template: #{err}" unless compiled
    template = compiled

  template { menus: menus.bar, activities: ACTIVITIES, :icon }

{ :render, :icon, :ICONS, :ACTIVITIES }
