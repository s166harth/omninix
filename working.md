# How nixmarchy works

`nixmarchy` is a **Quickshell host for third-party Omarchy plugins** on NixOS / plain Nix.
An Omarchy plugin expects its host to provide two things: a `qs.Commons` / `qs.Ui` QML
portal to import, and a `shell` object injected into each component it mounts. Omarchy
ships both inside Arch's `omarchy` package tree. This repo reimplements them so a plugin
checkout can be mounted from `~/.config` without Arch, without Omarchy, and without a
`nixos-rebuild`.

Repo status: **seed snapshot**, extracted verbatim from a home-manager flake
(`modules/home/nixmarchy/`). Nothing is renamed or packaged into a flake yet — `ROADMAP.md`
milestone **M0** is the extraction/rename to `omninix` (remote already points at
`git@github.com:s166harth/omninix.git`).

---

## 1. The four layers

| Layer | Files | Owned by | Mutability |
|---|---|---|---|
| Host | `shell/shell.qml`, `shell/AppLibrary.qml`, `shell/AppSearch.js`, `shell/Cat.qml` | Nix store / `~/.config/nixmarchy-shell` | immutable |
| Portal | `Commons.qs/qs/{Commons,Ui}/*` | Nix store, put on `QML_IMPORT_PATH` | immutable |
| CLI | `bin/nixmarchy` (+ 5 shims) | Nix store | immutable |
| Plugin data | `~/.local/state/nixmarchy/**`, `~/.config/nixmarchy/plugins/<id>` | user | mutable, network-at-user-time |

The split is the architecture invariant: adding a plugin never touches layer 1–3, so it
never needs a rebuild. The host picks changes up by `rescan` (IPC) or a `qs` restart.

```mermaid
flowchart LR
  subgraph store["Nix store (immutable)"]
    CLI["bin/nixmarchy\ninstall/enable/list"]
    HOST["shell/shell.qml\nShellRoot"]
    PORTAL["Commons.qs/qs\nqs.Commons + qs.Ui"]
    SHIMS["omarchy-* shims"]
  end
  subgraph user["User state (mutable)"]
    REG["registry.json"]
    SHELLJSON["shell.json"]
    SVCS["services.json"]
    CHK["plugins/&lt;id&gt;/ checkouts"]
  end
  CATALOG[("plugins.omarchy.org\ncatalog.json")]
  CATALOG --> CLI
  CLI -->|git clone + rev| CHK
  CLI -->|nix store add + profile add\n(GC root)| REG
  CLI --> SHELLJSON
  REG -->|priority / installedAt| SHELLJSON
  CHK -->|symlink farm\n~/.config/nixmarchy/plugins/&lt;id&gt;| HOST
  SHELLJSON --> HOST
  SVCS --> HOST
  PORTAL -->|"QML_IMPORT_PATH (ahead)"| HOST
  HOST -->|"mount by kind"| PLUGIN["plugin entryPoint QML"]
  CLI -.->|"qs ipc call shell …"| HOST
```

---

## 2. What a plugin provides

`manifest.json`, **schemaVersion 1** (validated in `bin/nixmarchy:147-187`):

```json
{ "id": "evindor.keystroke", "name": "…", "version": "…",
  "kinds": ["menu"], "entryPoints": { "menu": "Keystroke.qml" } }
```

Required: `id`, `name`, `version`, `kinds` (non-empty array), `entryPoints` (object).
`kinds` are not free-form keys — each maps to a fixed `entryPoints` key
(`bin/nixmarchy:179-187`):

| kind | required `entryPoints` key |
|---|---|
| `bar` | `bar` |
| `bar-widget` | `barWidget` |
| `menu` | `menu` |
| `overlay` | `overlay` |
| `panel` | `panel` |
| `service` | `service` |

`nixmarchy validate` also rejects: id outside `[A-Za-z0-9][A-Za-z0-9._-]*`, ids containing
`..`, ids in the reserved `omarchy.*` namespace, absolute or `..`-containing entry-point
paths, missing entry-point files, symlinks anywhere inside the plugin folder, and a
`barWidget.defaultSection` other than `left` / `center` / `right`.

### Kinds

| Kind | Hosted now | Mount behaviour (`shell.qml:225-262`) |
|---|---|---|
| `service` | yes | headless `QtObject`, no UI |
| `overlay`, `panel`, `menu` | yes | created hidden; first UI kind is the summon target |
| `bar`, `bar-widget` | **no** | logged as `kind '<k>' not hosted (need bar host)`, skipped (M5) |

Unknown/absent kind → precise `warn`, never a silent skip.

---

## 3. Host: discovery → precedence → mount

`ShellRoot` in `shell/shell.qml` (~550 lines) does, on startup and on every `rescan`:

1. **Scan** — `scanner` `Process` finds `~/.config/nixmarchy/plugins/*/manifest.json`
   (`pluginRoot`), reads each manifest to `{__id, __dir, …}`.
2. **Enable list** — `readStateJson` reads `shell.json` `plugins[]` (`readStateJson:105`).
3. **Service table** — `readServicesJson` reads `services.json` (`:111`).
4. **Order** — `prioAtOf` (`:119`) reads the state-dir sidecars `priority/<id>` and
   `installedAt/<id>` the CLI writes at install time (`bin/nixmarchy:587-593`), then
   `rescan` sorts (`:155-203`):
   explicit `priority` desc → `installedAt` desc (last-installed wins) → `id` asc.
5. **Slot arbitration** — `excludeSlotLosers` (`:138`) drops `barWidget.slot` losers so
   only one widget claims a slot.
6. **Mount** — `loadPlugin` (`:225`) per kind: `Qt.createComponent(file://entryPoint)`,
   `createObject(root, { shell: shellFacade(id), manifest: p.manifest })`. A component
   error is stored in `p.error` and surfaced through IPC `list`, not swallowed.
7. **Unload** — `unloadPlugin` (`:204`) destroys instances of plugins that are now
   disabled or removed.

### The injected facade

`shellFacade(id)` (`:465`) returns a **per-plugin scoped** object, so one plugin cannot
reach another's state. Exactly nine members:

| Member | Source |
|---|---|
| `manifest` | the plugin's own `manifest.json` (second `createObject` arg, `:244`) |
| `appLibrary` | `hostAppLibrary` = `shell/AppLibrary.qml` + `AppSearch.js` (DesktopEntries-backed; launch via `DesktopEntry.execute()`) |
| `idleConfig` | `cachedIdle` binding over state (fallback `idleDefaults`) |
| `serviceFor(id)` / `firstPartyServiceFor(id)` | capability routing, §4 |
| `summon` / `hide` / `toggle` / `isOpen` | the summon contract, bound to this plugin by default (`target || id`) |

Root-level host helpers not on the facade: `readFileSync` (`:59`, synchronous reads
without `FileView`, backed by `shell/Cat.qml`), `warn`, `shellQuote`.

Same Qt 6.11 divergence the plugin ledger records for omadex is worked around in host
code too: `AppLibrary.qml`'s `Connections` is held in a `property Connections` rather
than a bare child, because Quickshell 0.3 / Qt 6.11 rejects bare children under a
`QtObject` root.

### Summon contract

`open()` / `close()` / `opened`, implemented host-side by `summon` / `hide` / `isOpen` /
`toggle` (`:483-510`). `targetInstance` (`:478`) resolves the plugin's first UI instance.
`callPlugin` (`:512`) invokes an arbitrary plugin function (plugins expose `inspect()`,
`state()`, …) — used by `nixmarchy ipc shell call`.

### IPC

`IpcHandler` target **`shell`** (`:522`): `ping`, `list`, `summon`, `hide`, `toggle`,
`isOpen`, `rescan`, `call` — reachable as
`qs --path ~/.config/nixmarchy-shell ipc call shell <fn> …`, wrapped by `bin/nixmarchy-ipc`.

---

## 4. Service capability routing

Plugins ask for host capabilities by id: `shell.serviceFor("omarchy.<name>")`. The mapping
lives **outside** the flake, in `~/.local/state/nixmarchy/services.json`:

```json
{ "omarchy.media":      { "provider": "builtin", "impl": "mpris" },
  "omarchy.battery":    { "provider": "stub", "capacity": 80, "charging": false },
  "omarchy.<unknown>":  { "provider": "reject", "reason": "…" } }
```

`serviceFor` (`:263`) returns a **narrow proxy** built by `makeBuiltinProxy` /
`makeStubProxy` / `makeRejectProxy` (`:283-327`). Every proxy carries the full no-op
surface (`setIdleEnabled`, `setNightlight`, `setDoNotDisturb`, `runAction`, `playerKey`,
`selectPlayer`), so a plugin that needs 5 of 10 capabilities degrades on the rest instead
of crashing. Unknown id / missing file / `builtin` without `impl` → reject proxy with
reason `not routed`.

Builtin implementations shipping today:

| Impl | Capability | Mechanism |
|---|---|---|
| `hyprsunset` | `omarchy.nightlight` | `hyprsunsetProxy` (`:330`) — temp < 6000 K detection, `hyprsunset -t <temp>` |
| `mpris` | `omarchy.media` | `mprisProxy` (`:399`) — `Quickshell.Mpris` players, `mediaRunAction` / `playerKey` / `selectPlayer`, live via `Connections.onValuesChanged` (`:461`) |

Cost of a new capability: one provider impl + one table row. No plugin edits.

---

## 5. CLI: `bin/nixmarchy` (861 lines, bash + jq)

```
install <git-url|plugin-page-url> [--yes] [--priority N]
list [--json]
enable <id> [--priority N]   disable <id>
summon <id> [json]           hide <id>   toggle <id> [json]
update [id]   relink [id]   remove <id>   validate [dir]
```

`install` pipeline:

1. **Resolve** — `plugin.html?id=<id>` → git URL via the pinned marketplace catalog
   `plugins.omarchy.org/catalog.json`, 24 h cache at `$STATE_DIR/catalog.json`
   (`fetch_catalog:84`, `catalog_entry:95`). Git URLs normalised to `.git`.
2. **Harden transport** — `omarchy-git-url-check`-style refusal of git transport tricks
   *before* touching the network (`:120`).
3. **Clone + rev** — checkout into `$STATE_DIR/plugins/<id>`, rev recorded in `registry.json`.
4. **Validate manifest** — schemaVersion 1 + required fields + kind/entryPoint agreement
   (`cmd_validate:141`, reusable standalone as `nixmarchy validate [dir]`).
5. **Normalise shebangs** — `#!/nix/store/...` interpreters copied to `$STATE_DIR/patched/`
   and re-pointed to `#!/usr/bin/env <base>` (`normalize_plugin_shebangs:507`).
6. **Pin immutably** — `nix store add --name nixmarchy-plugin-<id> $work` then
   `nix profile add --priority 10 <storepath>` (`:502-557`), giving a store path plus a
   GC root. `nix profile remove` + retry on conflict.
7. **Expose** — symlink farm `~/.config/nixmarchy/plugins/<id>` → store path (what the host
   scans); plugin CLIs linked into `~/.local/bin` with collision refusal recorded in
   `cli.json` (`:221`).
8. **Publish state** — `registry.json` entry (`url/rev/enabled/priority/installedAt`),
   `shell.json` `plugins[]`, plus `priority/<id>` / `installedAt/<id>` sidecars the host
   reads for precedence B.
9. **`rescan_shell`** — tells the live host to re-scan, so the mount happens with **no
   rebuild and no restart**.

`update` deliberately **refuses to fast-forward a diverged checkout**; those are activated
by `relink [id]` instead. All network use is here, at the user's command — never at
activation. No sudo anywhere.

### Shims

| Bin | Purpose | Evidence in tree |
|---|---|---|
| `nixmarchy-shell-run` | launch host with portal ahead on `QML_IMPORT_PATH`; `@commonsQml@` substituted at build time to `${./Commons.qs}` (`nixmarchy.nix:24-28`) | `bin/nixmarchy-shell-run` |
| `nixmarchy-ipc` | `qs ipc` wrapper; prefers `--path` of the running config, falls back to `-c nixmarchy-shell`; non-zero on `skip` | `bin/nixmarchy-ipc` |
| `omarchy-menu-keybindings` | Omarchy's keybinding resolver reimplemented against `hyprctl -j binds` (plugin `bin/keybinds` exits 1 without it → zero bindings) | `bin/omarchy-menu-keybindings` |
| `omarchy-notification-send` | upstream signature `-g <glyph> -t <ms> <title> [body]` (libnotify) so plugin helper scripts work unmodified | `bin/omarchy-notification-send` |
| `nixmarchy-notification-send` | same, native name | `bin/nixmarchy-notification-send` |

---

## 6. Portal: `Commons.qs/`

A hand-maintained subset of Omarchy's `shell/Commons` + `shell/Ui`, mounted on the QML
import path **ahead of** the user config dir by `nixmarchy-shell-run`, so
`import qs.Commons` resolves here and never to the user's own module.

| Module | Members |
|---|---|
| `qs.Commons` | `Color`, `Style`, `Util`, `Border` (+ `BorderGeometry.js`) — all `pragma Singleton` |
| `qs.Ui` | 14 names / 13 components: `Panel` ≡ `UiDummy`, `PanelKeyCatcher`, `Button`, `BorderSurface`, `BorderOverlay`, `TextField`, `BarIconButton`, `CursorSurface`, `KeyboardPanel`, `PanelSectionHeader`, `PluginBarApi`, `ToggleSwitch`, `PointerMoveGate` |

`qs.Ui/Panel` is a port of `omacom/omarchy@quattro` `shell/Ui/Panel.qml` + `PanelController`
minus `ShellIpc` (absent from Quickshell 0.3.0); `UiDummy` is that port carrying the
`open()/close()/opened` contract the host drives.

---

## 7. State layout

```
~/.local/state/nixmarchy/
  registry.json        id -> url/rev/enabled/priority/installedAt/storePath/clis
  shell.json           enabled plugin ids (+ idle config) — read by the host
  services.json        omarchy.<name> -> builtin/stub/reject (read by the host)
  cli.json             plugin CLI -> link bookkeeping (collision refusal)
  catalog.json         24 h marketplace catalog cache
  plugins/<id>/        git checkouts (git dirs, rev-pinned)
  patched/             shebang-normalised copies
  priority/<id>        1-byte precedence sidecar
  installedAt/<id>     precedence sidecar
~/.config/nixmarchy/plugins/<id>   symlink farm -> store path (host scans here)
~/.config/nixmarchy-shell/        host config (shell.qml, Cat.qml, AppLibrary.qml, AppSearch.js)
~/.config/nixmarchy/Commons.qs    portal copy (module option; store path preferred)
```

`NIXMARCHY_*` env overrides: `STATE_DIR`, `SHELL_DIR`, `SHELL_CONFIG`, `COMMONS_DIR`,
`CATALOG_URL`, `QUIET`.

---

## 8. Tests

```sh
tests/run-all.sh              # every suite
tests/run-all.sh cli bins     # filter by filename
bash tests/cli-interface.test.sh   # one suite
```

Five suites (`cli-interface`, `cli-lifecycle`, `bins`, `qml`, `js`). Zero deps beyond
`bash`, `jq`, `python3`; hermetic — temp `$HOME`, stubbed `git`/`nix`/`qs`/`curl`, no
network, no writes outside the temp dir. `tests/js` runs one lane per JS engine found
(`node`, `bun`, `deno` — PATH then `/nix/store`). Suites that lack a runtime print a
counted `SKIP` with the reason rather than passing silently.

Last observed run on this box: **ALL 5 SUITES PASSED, 18.7 s**; the `qml` suite reported
`41 passed, 0 failed, 2 skipped` — the two skips are real findings, not runtime absence:

| Skip | Meaning |
|---|---|
| `drift, fix bin/nixmarchy: shipped but unlisted: PointerMoveGate UiDummy` | `NIXMARCHY_SUPPORTED_UI` (`bin/nixmarchy:353`) is out of sync with the shipped `qs.Ui/qmldir` |
| `BarIconButton … OpticalGlyph is not a type` | `qs.Ui/BarIconButton.qml:33` depends on a QML type the portal does not carry |

---

## 9. What does *not* work yet

| Gap | Where it shows |
|---|---|
| `bar` / `bar-widget` kinds unhosted | `loadPlugin` warn; bar-widget plugins still validate via `entryPoints` |
| Portal is a subset — one missing type breaks a whole plugin | §8 `BarIconButton` skip; keystroke previously died on `PointerMoveGate is not a type` |
| Omarchy tool layer absent (`uwsm-app`, `omarchy-shell`, launch OSD, `omarchy-remove-launcher-entry`); `AppLibrary.launch()` falls back to `gtk-launch`, also absent here, so `DesktopEntry.execute()` is the live path | `AppLibrary.qml` comments, `makeRejectProxy` reasons |
| Service routing covers a handful of ids, 2 with real impls | `services.json` |
| Divergence patches live in the user's checkout, not the repo | ledger header of `nixmarchy.nix` (omadex / key-promoter / keystroke) |
| Hyprland-specific (`hyprctl`, layer namespaces) | `shell.qml`, `omarchy-menu-keybindings` |
| Rename + packaging + distribution pending | `ROADMAP.md` M0 |

Measured, per-plugin divergence ledger (top of `nixmarchy.nix`) is the source of truth for
what each known plugin needed: `io.github.jacklapinza.omadex` (Quickshell 0.3 / Qt 6.11
rejects bare children under a `QtObject` root), `fkcodes.key-promoter` (arms on Omarchy's
menu layer + a `uwsm-app -- gtk-launch` scope; this host uses rofi, so the patch arms on
`closelayer rofi`), `evindor.keystroke` (unmodified once the portal carries
`PointerMoveGate` + `Style.font.heading` + `Style.controlFill()` + `Util.*`).

---

## 10. Contracts that must never be renamed

Plugins hard-code these. Renaming any of them silently breaks the whole ecosystem:

- `import qs.Commons`, `import qs.Ui`
- `manifest.json` `schemaVersion` 1
- `open()` / `close()` / `opened`
- IPC target `shell`
- the `omarchy-*` tool names
- `omarchy.<name>` service ids

`ROADMAP.md` §6.2 lists the same set, and §6.1 the full `nixmarchy` → `omninix` rename
inventory (bins, state dirs, env vars, profile element names, HM namespace) with a
one-release migration path.
