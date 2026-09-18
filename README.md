# WowLabs

A development environment for World of Warcraft modding. Not a viewer and not a
converter: a tool you keep open while you work, in the shape of an IDE rather
than of a web page in a window.

Built on [Neutrino](https://github.com/WarcraftXL-Labs/Neutrino) (CEF + LuaJIT)
and [lua-dbc](https://github.com/WarcraftXL-Labs/lua-dbc), both vendored as
submodules so the three move together.

Windows only at present. Targets client build 3.3.5a.

## Getting started

```powershell
git clone --recurse-submodules git@github.com:WarcraftXL-Labs/WowLabs.git
cd WowLabs

.\tools\get-deps.ps1        # CEF, LuaJIT, rocks, the native layer, Tailwind
.\tools\build.ps1           # framework, application, styles
.\tools\run.ps1
```

`get-deps.ps1` runs Neutrino's own dependency script and builds its native
layer, then fetches the Tailwind compiler. Everything is pinned to an exact
version, and whatever is already there is skipped.

If the clone came without `vendor/`:

```powershell
git submodule update --init --recursive
```

## How it is put together

```
src/main.moon        entry point: logging, the server, the shell
src/shell/           the window and the chrome it draws itself
src/modules/         one folder per tool, each a Neutrino module
static/tailwind.css  design tokens, and the components that repeat
vendor/neutrino/     the framework, as a submodule
vendor/lua-dbc/      client database access, as a submodule
```

The window is **frameless**: the title bar is also the menu bar, and both belong
to the application rather than to Windows. `-webkit-app-region` says what drags,
and minimise, maximise and close reach Lua through IPC like any other action.

Styles are **Tailwind compiled at build time** by the standalone binary — no
Node, no npm, and the application never touches the network. Tokens live in
`static/tailwind.css` under `@theme`; anything that repeats becomes a component
class, and everything else stays as utilities beside the markup it applies to.

Each tool is a **Neutrino module**: it owns an origin, its IPC channels and its
session, and it can be taken back down while the application runs. The shell
knows nothing about what any of them do.

## Working on it

The framework and the tool are built together on purpose. When the application
needs something a framework of this kind is supposed to provide, it goes into
Neutrino rather than being worked around here — and a package that already
exists is installed rather than written again.

```powershell
.\tools\build.ps1 -Runtime   # also refresh dist\bin (400 MB, rarely needed)
```

The log is at `%LOCALAPPDATA%\WowLabs\WowLabs.log`, and it collects `print` and
the framework's own diagnostics as well as anything the application writes.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
