--- The tools the application holds, as data.
--
-- A tool is a category in the bar under the menus. Choosing one changes the
-- action rail down the left edge and, when the tool asks for one, the strip
-- under the category bar - and changes nothing else. Open tabs belong to the
-- tools that opened them and survive switching, the way they do in any editor.
--
-- Registered rather than listed: a module owns its tool and the shell knows
-- only what every tool has in common.
--
--     tools.register {
--       id: "dbc"
--       label: "Database"
--       icon: "database"
--       actions: {
--         { id: "open", icon: "folder", title: "Open table", action: "..." }
--       }
--       context: '<div class="...">...</div>'   -- optional
--     }
---@module shell.tools

M = {}

--- Every registered tool, in bar order.
---@type table[]
M.list = {}

--- Adds a tool. A second registration of the same id replaces the first, so a
--- module reloaded during development does not double its own entry.
---@param tool table id, label, icon, actions?, context?
---@return table The tool.
M.register = (tool) ->
  error "a tool needs an id" unless tool.id
  error "a tool needs a label" unless tool.label

  tool.actions or= {}

  for index, existing in ipairs M.list
    if existing.id == tool.id
      M.list[index] = tool
      return tool

  table.insert M.list, tool
  tool

--- Finds a tool by id.
---@param id string
---@return table|nil
M.find = (id) ->
  for tool in *M.list
    return tool if tool.id == id
  nil

--- The id the interface should start on: the first registered tool.
---@return string
M.first = -> #M.list > 0 and M.list[1].id or ""

-- ═══════════════════════════════════════════════════════════════════════════
-- Built in
-- ═══════════════════════════════════════════════════════════════════════════

-- The one tool that is not a module: where a workspace is opened and where the
-- settings live. Everything else arrives with the module that owns it.
M.register {
  id: "workspace"
  label: "Workspace"
  icon: "home"
  actions: {
    {
      id: "open"
      icon: "folder"
      title: "Open workspace"
      action: "neutrino.invoke('shell:open-workspace')"
    }
    {
      id: "settings"
      icon: "settings"
      title: "Settings"
      action: "neutrino.invoke('shell:settings')"
    }
  }
}

M
