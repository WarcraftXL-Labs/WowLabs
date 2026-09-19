--- The table editor's markup.
--
-- Three regions, rendered once with the page and shown by which tool and which
-- tab are active: the strip under the category bar, the panel down the side,
-- and the grid in the work area. Each is an etlua template under `views/`;
-- this file is what hands them what they need and nothing else.
--
-- **The grid is Tabulator's; the data is not.** The library virtualises the
-- document and not the data - it wants every row it will ever show, which on
-- Spell is 49,839 by 105 - so it is fed forwards a page at a time through
-- `dbc:page` and holds only what was actually scrolled past. Lua owns every
-- write: a cell is a field in an FFI buffer reached through a proxy, and the
-- only way a value gets into one is `editor.set_cell`.
--
-- The host is a flex child with a real size rather than a box positioned
-- inside one. A library that measures its container and is handed a box of no
-- height lays the whole thing out into a point: every count correct, the
-- screen empty. That is what happened to the relations graph, and it is the
-- same mistake here.
---@module modules.dbc.view

resources = require "resources"

M = {}

--- The grid's geometry, in pixels, and how much of it is asked for at a time.
--
-- Shared between the markup and the module that fills it. Two copies of these
-- numbers would be two copies that drift.
---@type table
M.METRICS = {
  row: 22        -- a row, dense enough to read a screenful at once
  head: 26       -- the header
  index: 74      -- the frozen row-index column

  -- Rows per request. Large enough that an ordinary scroll does not ask for
  -- another page every second, small enough that opening a table is one read
  -- of a few hundred records rather than of fifty thousand.
  page: 200
}

--- Renders one of the regions.
---@param name string Template basename under `views/`.
---@param icon fun(name: string, size?: integer): string
---@return string html
---@private
render = (name, icon) ->
  template = resources.template "modules/dbc/views/#{name}.etlua"
  template { metrics: M.METRICS, :icon }

--- The strip under the category bar.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.context = (icon) -> render "context", icon

--- The table list.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.panel = (icon) -> render "panel", icon

--- The grid, the preview and the confirmation.
---@param icon fun(name: string, size?: integer): string
---@return string html
M.grid = (icon) -> render "grid", icon

M
