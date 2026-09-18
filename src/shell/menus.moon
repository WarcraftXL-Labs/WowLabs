--- The menu bar, as data.
--
-- A table rather than markup, so a module can add to it. The DBC editor will
-- want "File > Open table..." without the shell knowing what a table is, and
-- the shell will want to grey out "Save" when nothing is open.
--
-- Each entry is one of:
--
--   { label, action, accelerator?, enabled? }   a command
--   { separator: true }                         a rule
--   { heading: "Recent" }                       a caption
--   { list: "recent", action, empty? }          one command per list element
--
-- A `list` entry names a key in the store rather than holding its own items:
-- the recent workspaces are not known when the menu is built, and a menu that
-- had to be rebuilt to show them would mean rebuilding the page. Inside its
-- action, `entry` is the element.
--
-- `action` is JavaScript run in the page, because that is where a menu click
-- lands. Reaching Lua is `invoke("channel")` like anywhere else.
---@module shell.menus

M = {}

--- The menus, in bar order.
-- Modules add to this before the window is created.
---@type table[]
M.bar = {
  {
    id: "file"
    label: "File"
    items: {
      { label: "New workspace...", action: "nui.set('dialog', 'new-workspace')", accelerator: "Ctrl+Shift+N" }
      { label: "Open workspace...", action: "neutrino.invoke('shell:open-workspace')", accelerator: "Ctrl+O" }
      { label: "Close workspace", action: "neutrino.invoke('shell:close-workspace')", enabled: "workspace !== ''" }
      { separator: true }
      { heading: "Recent" }
      {
        list: "recent"
        empty: "Nothing opened yet"
        action: "neutrino.invoke('shell:open-recent', entry)"
      }
      { separator: true }
      { label: "Save", action: "neutrino.invoke('shell:save')", accelerator: "Ctrl+S", enabled: "dirty" }
      { label: "Save all", action: "neutrino.invoke('shell:save-all')", accelerator: "Ctrl+Alt+S", enabled: "dirty" }
      { separator: true }
      { label: "Settings", action: "neutrino.invoke('shell:settings')", accelerator: "Ctrl+," }
      { separator: true }
      { label: "Exit", action: "neutrino.invoke('shell:close')" }
    }
  }
  {
    id: "edit"
    label: "Edit"
    items: {
      { label: "Undo", action: "neutrino.invoke('shell:undo')", accelerator: "Ctrl+Z", enabled: "can_undo" }
      { label: "Redo", action: "neutrino.invoke('shell:redo')", accelerator: "Ctrl+Y", enabled: "can_redo" }
      { separator: true }
      { label: "Find...", action: "nui.set('dialog', 'find')", accelerator: "Ctrl+F" }
    }
  }
  {
    id: "view"
    label: "View"
    items: {
      { label: "Toggle side panel", action: "nui.set('side_open', !nui.get('side_open'))", accelerator: "Ctrl+B" }
      { label: "Toggle status bar", action: "nui.set('status_open', !nui.get('status_open'))" }
      { separator: true }
      { label: "Developer tools", action: "neutrino.invoke('shell:devtools')", accelerator: "F12" }
    }
  }
  {
    id: "tools"
    label: "Tools"
    items: {
      { label: "Reload interface", action: "location.reload()", accelerator: "Ctrl+R" }
    }
  }
  {
    id: "help"
    label: "Help"
    items: {
      { label: "About WowLabs", action: "nui.set('dialog', 'about')" }
    }
  }
}

--- Adds items to the end of a menu, creating nothing if the menu is unknown.
-- How a module contributes: `menus.extend "file", { ... }`.
---@param id string Menu id, such as "file".
---@param items table[] Entries to append.
---@return boolean Whether the menu existed.
M.extend = (id, items) ->
  for menu in *M.bar
    continue unless menu.id == id
    table.insert menu.items, item for item in *items
    return true
  false

M
