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
--       description: "Edit the client's DBC tables."
--       actions: {
--         { id: "open", icon: "folder", title: "Open table", action: "..." }
--         { id: "new", icon: "plus", title: "New row", action: "...",
--           shown: "dbc_info.has_id" }
--       }
--       context: '<div class="...">...</div>'   -- optional
--       panel: '<div>...</div>'                 -- optional
--       view: '<div>...</div>'                  -- optional
--       state: -> { dbc_open: "" }              -- optional
--       mount: (window, state) -> ...           -- optional
--       commands: { save: -> ..., undo: -> ... }
--     }
--
-- `description` is one line, shown where the tools are offered rather than
-- chosen from the bar: an icon says which tool you are in and says nothing at
-- all to somebody who has not used it yet.
--
-- An action's `shown` is a JavaScript expression against the store: the rail
-- draws that button only while it holds. For the ones a tool can always offer,
-- leave it out.
--
-- `view` is the tool's work area, shown whenever the active tab belongs to it.
-- Like the rail and the strip it is rendered once, with the page: a tool's
-- markup is known when the page is built, and only its data arrives later.
--
-- `state` is folded into the store before the window opens, because the
-- runtime only answers for keys it was given. `mount` is called once the
-- window exists, and is where a tool wires its own channels.
--
-- `commands` is how the shell's own menu entries reach the active tool. Save,
-- undo and redo are one command to the user and a different one in every tool,
-- so the menu asks whichever tool is active and says so when that tool has no
-- answer. They are usually filled in from `mount`, where the window is.
--
-- `pending` is how the shell knows there is work to lose. A tool answers with
-- the names of what it has not written; the shell warns on the way out and
-- saves on a timer. Tools that answer it get both without doing anything
-- else, and a tool that does not answer is assumed to have nothing at stake.
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
  tool.commands or= {}

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

--- Every tool's store keys, merged.
--
-- Declared before the window opens, the way the settings sections' are: the
-- runtime answers for the keys it was given and for no others, so a key a tool
-- adds later is a key none of its own expressions can read.
---@return table
M.state = ->
  values = {}
  for tool in *M.list
    continue unless tool.state
    values[key] = value for key, value in pairs tool.state!
  values

--- Calls every tool's `mount`.
---@param window BrowserWindow
---@param state State
M.mount = (window, state) ->
  for tool in *M.list
    tool.mount window, state if tool.mount

-- ═══════════════════════════════════════════════════════════════════════════
-- Unsaved work
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every tool answers the same two questions - what have you not written, and
-- write it - and the shell does the rest: the warning on the way out, and the
-- timer that saves without being asked.
--
-- Here rather than in a module, because losing work is not a property of any
-- one tool. A tool that arrives next year gets this by answering `pending`.

--- What every tool is holding that is not on disk.
--
-- A tool answers with a list of names - the tables, the files, whatever it
-- calls the things it edits. The names are what the warning shows, so they
-- should read the way the user thinks of them.
---@return table[] entries { tool = id, label = string }
M.pending = ->
  entries = {}

  for tool in *M.list
    continue unless tool.pending

    -- Through pcall: this runs on the way out of the application, and a tool
    -- that raises here would take the warning with it - which is precisely
    -- when the warning matters.
    ok, found = pcall tool.pending
    unless ok
      io.stderr\write "[wowlabs] #{tool.id}: pending failed: #{tostring found}\n"
      continue

    continue unless type(found) == "table"
    for label in *found
      table.insert entries, { tool: tool.id, label: tostring label }

  entries

--- Writes what every tool is holding.
--
-- Answers what could not be written rather than raising: a save that fails
-- part way through still has to say which parts, and the caller decides
-- whether that is worth stopping for.
---@return integer written, table[] failures { tool = id, error = string }
M.save_all = ->
  written = 0
  failures = {}

  for tool in *M.list
    command = tool.commands and tool.commands["save-all"]
    continue unless command

    ok, err = pcall command
    if ok
      written += 1
    else
      table.insert failures, { tool: tool.id, error: tostring err }

  written, failures

-- ═══════════════════════════════════════════════════════════════════════════
-- Built in
-- ═══════════════════════════════════════════════════════════════════════════

-- The one tool that is not a module: where a workspace is opened and where the
-- settings live. Everything else arrives with the module that owns it.
M.register {
  id: "workspace"
  label: "Workspace"
  icon: "home"
  description: "Choose the client folder every other tool reads, and the
    settings that go with it."
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
