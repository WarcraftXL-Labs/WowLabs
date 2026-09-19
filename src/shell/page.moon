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
-- The markup is `views/shell.etlua`, and one card on the home page is
-- `views/tool-card.etlua`. Inside the tags the language is Lua: `<%= %>`
-- escapes and `<%- %>` does not.
---@module shell.page

menus = require "shell.menus"
resources = require "resources"
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
  eye: '<path d="M1.75 8S4.25 3.75 8 3.75 14.25 8 14.25 8 11.75 12.25 8 12.25 1.75 8 1.75 8Z"/><circle cx="8" cy="8" r="1.75"/>'
  "eye-off": '<path d="M2.5 6.25S4.5 10.25 8 10.25s5.5-4 5.5-4"/><path d="m4 9.5-1.25 1.75M8 10.25v2M12 9.5l1.25 1.75"/>'
  link: '<path d="M6.75 9.25a2.5 2.5 0 0 0 3.54 0l2-2a2.5 2.5 0 0 0-3.54-3.54l-.75.75"/><path d="M9.25 6.75a2.5 2.5 0 0 0-3.54 0l-2 2a2.5 2.5 0 0 0 3.54 3.54l.75-.75"/>'
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

--- The inside of one card on the home page's picker.
--
-- Two buttons rather than one: a star nested inside the button that opens the
-- tool could not be clicked without also opening it.
--
-- A template rather than `string.format`: the id appeared four times in a row
-- as `%s`, which is four chances to miscount, and the escaping was done by
-- hand on the way in. `<%= %>` does it, and `<%- %>` lets the icon through as
-- the markup it is.
---@param entry table A registered tool.
---@param icon fun(name: string, size?: integer): string
---@return string html
---@private
tool_card = (entry, icon) ->
  template = resources.template "shell/views/tool-card.etlua"
  template {
    id: entry.id
    glyph: icon entry.icon or "home", 20
    label: entry.label
    about: entry.description or ""
  }

-- Rendered after every tool has registered, since what a tool contributes is
-- built into the markup rather than pushed in later.
---@return string html
render = ->
  template = resources.template "shell/views/shell.etlua"

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
