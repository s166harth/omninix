# omninix — Roadmap

Status: **plan only. Nothing in this document is implemented.** Written 2026-10-09.
Seed code: `~/nixos-config/modules/home/nixmarchy/` (host + portal + CLI), currently a
home-manager module inside a personal flake.

---

## 0. Purpose

Turn the working-but-personal `nixmarchy` implementation into **omninix**: a standalone,
publicly installable repo that lets anyone on **NixOS or plain Nix (`nix shell` /
`nix run`)** install and run **third-party Omarchy Quickshell plugins** without Arch,
without Omarchy, and without rebuilding their system.

Definition of done for the whole roadmap:

> A user on a fresh NixOS + Hyprland box runs `nix run github:OWNER/omninix`, then
> `omninix install https://plugins.omarchy.org/plugin.html?id=<id>`, and the plugin
> mounts and works — for **any** plugin in the Omarchy marketplace catalog, across
> every plugin kind, with no manual patching.

---

## 1. Current state (what already exists)

### 1.1 Host — `shell/shell.qml` (Quickshell `ShellRoot`, ~550 lines)
| Capability | Where |
|---|---|
| Plugin discovery: `$XDG_CONFIG_HOME/nixmarchy/plugins/*/manifest.json` | `scanner` Process, `pluginRoot` |
| Enable list: `$XDG_STATE_HOME/nixmarchy/shell.json` `plugins[]` | `readStateJson` |
| Entry-point mount by kind: `overlay`, `service`, `panel`, `menu` | `loadPlugin` |
| Precedence B ordering: explicit priority → installedAt → id | `rescan`/`prioAtOf` |
| `barWidget.slot` collision exclusion | `excludeSlotLosers` |
| Scoped per-plugin facade `shell` + `manifest` injection | `shellFacade(id)` |
| `open()/close()/opened` summon contract | `summon`/`hide`/`isOpen`/`toggle` |
| IPC target `shell`: `ping/list/summon/hide/toggle/isOpen/rescan/call` | `IpcHandler` |
| Service capability routing `builtin`/`stub`/`reject` | `serviceFor`, `services.json` |
| Builtin service impls: `hyprsunset` (nightlight), `mpris` (media) | `hyprsunsetProxy`, `mprisProxy` |
| App library exposed as `shell.appLibrary` (DesktopEntries-backed) | `AppLibrary.qml` + `AppSearch.js` |
| `shell.idleConfig` | `cachedIdle` |
| Sync file reads without FileView | `readFileSync` + `Cat.qml` |

### 1.2 Portal — `Commons.qs/` (shim for Omarchy's `qs.Commons` / `qs.Ui`)
`qs.Commons`: `Color`, `Style`, `Util`, `Border` (singletons).
`qs.Ui`: `Panel`/`UiDummy`, `PanelKeyCatcher`, `Button`, `BorderSurface`,
`BorderOverlay`, `TextField`, `BarIconButton`, `CursorSurface`, `KeyboardPanel`,
`PanelSectionHeader`, `PluginBarApi`, `ToggleSwitch`, `PointerMoveGate`.
Placed on `QML_IMPORT_PATH` **ahead of** the user's config dir by `nixmarchy-shell-run`.

### 1.3 CLI — `bin/nixmarchy` (861 lines)
`install <git-url|plugin-page-url> [--yes] [--priority N]`, `list [--json]`,
`enable`/`disable`, `summon`/`hide`/`toggle` (with plugin-CLI fallback),
`update [id]`, `relink [id]`, `remove <id>`, `validate [dir]`.
Mechanics: URL normalisation + `omarchy-git-url-check`-style transport hardening;
catalog fetch (`plugins.omarchy.org/catalog.json`, 24h cache); manifest schema
validation; `nix store add --name nixmarchy-plugin-<id>` + `nix profile add`
(GC root); symlink farm `~/.config/nixmarchy/plugins/<id>`; plugin CLI linking into
`~/.local/bin` with collision refusal (`cli.json`); shebang normalisation into
`$STATE/patched/`.

### 1.4 Compatibility shims already shipped
`omarchy-menu-keybindings` (hyprctl-based resolver), `omarchy-notification-send`,
`nixmarchy-notification-send`.

### 1.5 Divergence ledger (manual, per-plugin)
Documented in `nixmarchy.nix` header: `io.github.jacklapinza.omadex`,
`fkcodes.key-promoter`, `evindor.keystroke` (+ portal deps each needed).

### 1.6 Known gaps (measured, not guessed)
| Gap | Evidence |
|---|---|
| `bar` / `bar-widget` kinds **not hosted** | `loadPlugin`: `"kind '<k>' not hosted (need bar host)"` |
| Portal is a hand-maintained subset; a single missing type breaks a whole plugin | keystroke failed on `PointerMoveGate is not a type` |
| Omarchy tools absent (`uwsm-app`, `gtk-launch`, `omarchy-remove-launcher-entry`, launch OSD, `omarchy-shell`) | `AppLibrary.qml` comments; `makeRejectProxy` reasons |
| Service routing covers 5 ids, 2 with real impls | `services.json` |
| Patches live in the user's checkout, not in a repo | ledger header; `relink` "activates a local divergence patch" |
| No test suite (`tests/` is empty) | `ls tests/` |
| Hyprland-specific (`hyprctl`, layer namespaces) | `shell.qml`, shim |
| Rename + extraction + distribution all pending | this doc |

---

## 2. Goal & non-goals

**Goal.** Any Omarchy marketplace plugin installs and runs on NixOS / plain Nix.

**Non-goals.**
- Reimplementing Omarchy (no Hyprland config, no themes, no installer).
- Running on non-Hyprland compositors (Omarchy is Hyprland-only; document it).
- Replacing Omarchy's own bar/desktop for Arch users.
- Sandboxing untrusted plugins beyond URL validation + no-root (see §13).
- Porting the `omarchy.*` reserved-namespace plugins (they are Omarchy first-party).

---

## 3. Architecture invariant (must not break)

Two layers, deliberately split:

1. **Nix-owned, immutable, reproducible:** the host, the portal, the shims, the CLI,
   the compat patches. Shipped as store paths.
2. **User-owned, mutable, network-at-user-time:** plugin checkouts under
   `~/.local/state/<state>/plugins/<id>`, enabled list, priorities, service routing.

The host must keep working with **zero rebuilds** when a plugin is installed
(`qs` hot-reload + `rescan` IPC). Any proposal that requires `nixos-rebuild` to add
a plugin is rejected for the imperative path (§5.1); the declarative path (§5.2) is
additive.

**Plugin-facing contracts that MUST NOT be renamed** (plugins hard-code them):
`import qs.Commons` / `import qs.Ui`, the `shell` facade + `manifest` injection,
`open/close/opened`, IPC target `shell`, the `omarchy-*` CLI names, `manifest.json`
schemaVersion 1.

---

## 4. Standalone repo: layout & flake outputs

```
omninix/
  flake.nix                    flake.lock
  README.md  ROADMAP.md  LICENSE  CONTRIBUTING.md
  docs/  architecture.md  compatibility.md  portal.md  patches.md  install.md
  modules/
    home.nix                   # homeModules.default
    nixos.nix                  # nixosModules.default (per-user HM + Hyprland glue)
  pkgs/
    host/                      # shell.qml Cat.qml AppLibrary.qml AppSearch.js
    portal/                    # qs/Commons/*, qs/Ui/*  (today: Commons.qs/)
    cli/                       # omninix, omninix-ipc
    shims/                     # omarchy-*, uwsm-app, gtk-launch shims
    services/                  # service provider impls (QML) + routing defaults
  patches/
    index.json                 # plugin-id -> [patch files + reason + upstream PR link]
    <plugin-id>/*.patch
  tests/
    fixtures/                  # vendored, pinned sample plugins, one per kind
    conformance.sh
  scripts/
```

Flake outputs:

| Output | Contents |
|---|---|
| `packages.<sys>.default` / `omninix` | buildEnv: `omninix` + `omninix-ipc` + `omninix-shell-run` + shims (one PATH entry point) |
| `packages.<sys>.omninix-portal` | the `qs.Commons`/`qs.Ui` portal tree |
| `packages.<sys>.omninix-host` | the Quickshell host config tree |
| `apps.<sys>.default` | `nix run …#` → `omninix run` |
| `homeModules.default` | HM module (packages + autostart + state) |
| `nixosModules.default` | system module (HM for users + Hyprland `exec-once` + optional systemd user unit) |
| `overlays.default` | exposes the packages |
| `checks.<sys>.conformance` | §9 harness |
| `devShells.<sys>.default` | quickshell + qmlls + jq + git for plugin hacking |

Design notes:
- `omninix-shell-run` **bakes the store paths** for host dir and portal
  (`builtins.replaceStrings` on `@hostDir@` / `@portalDir@`, the pattern already used
  for `@commonsQml@`), so no env vars are needed after `nix shell`.
- Keep `nixpkgs.follows` discipline: the flake must follow the consumer's nixpkgs for
  `quickshell` so the QML/Qt ABI matches the user's session (see §12, quickshell pin).

---

## 5. Install paths

### 5.1 Imperative (primary, zero-config)
```sh
nix run github:OWNER/omninix                 # launch host (first run creates state)
nix shell github:OWNER/omninix               # omninix, omninix-ipc, omninix-shell-run on PATH
omninix install https://plugins.omarchy.org/plugin.html?id=evindor.keystroke
omninix enable evindor.keystroke
omninix run                                  # or: omninix-shell-run
```
Requirements: Hyprland session, `quickshell` (from the flake closure), no root.
State + GC rooting as today (§1.3).

### 5.2 Declarative (reproducible)
```nix
inputs.omninix.url = "github:OWNER/omninix";
# home-manager
programs.omninix = {
  enable = true;
  plugins = [
    { id = "evindor.keystroke"; url = "github:evindor/omarchy-keystroke"; rev = "c9cf1a0"; }
  ];
  services."omarchy.media" = { provider = "builtin"; impl = "mpris"; };
  autostart = true;
};
```
Plugin sources become **fixed-output derivations** (`fetchgit` with `rev`+`hash`) and
the symlink farm is materialised at activation — pure, offline, reproducible. Keep the
imperative path for casual use; both write the same registry format.

### 5.3 Distribution
`nix profile install github:OWNER/omninix` for a persistent CLI; `flake.lock` pinning +
tagged releases; a `cachix`-free story (only quickshell substitutes from cache).

---

## 6. Rename plan: `nixmarchy` → `omninix`

> Target name: **omninix**. Chosen over the earlier proposal `omnix`, which
> collides with the existing nix-community/juspay Omnix (`om` CLI, omnix.page)
> and with `omnixy` (TheArctesian/omnixy, an opinionated Nix/Hyprland setup).

### 6.1 Rename inventory
| Kind | From | To | Note |
|---|---|---|---|
| CLI bins | `nixmarchy`, `nixmarchy-ipc`, `nixmarchy-shell-run`, `nixmarchy-notification-send` | `omninix`, `omninix-ipc`, `omninix-shell-run`, `omninix-notification-send` | `omninix ipc …` subcommand preferred over separate bin |
| State dir | `~/.local/state/nixmarchy` | `~/.local/state/omninix` | migration shim (below) |
| Config dirs | `~/.config/nixmarchy`, `~/.config/nixmarchy-shell` | `~/.config/omninix`, host config no longer installed under `~/.config` (use store `--path`) | |
| Env vars | `NIXMARCHY_*` | `OMNINIX_*` | keep `NIXMARCHY_*` read-only fallback for one release |
| nix profile element | `nixmarchy-plugin-<id>` | `omninix-plugin-<id>` | migrate on first `omninix` run |
| HM/NixOS namespace | `nixmarchy.*` | `programs.omninix.*` | |
| Ledger/docs | "nixmarchy" | "omninix" | |
| Repo path | `modules/home/nixmarchy` | repo root | |

### 6.2 MUST NOT rename (plugin contract)
`qs.Commons`, `qs.Ui`, the `shell` IPC target, `omarchy-*` shim names,
`manifest.json` schemaVersion, the `open/close/opened` contract,
`omarchy.<name>` service ids.

### 6.3 Migration (one release)
- On first `omninix` run: if `~/.local/state/nixmarchy` exists and `…/omninix` does not,
  `mv` it (or symlink) and log. Same for `~/.config/nixmarchy{,-shell}` links.
- Re-point `~/.config/nixmarchy/plugins/*` symlinks and re-add profile elements under
  the new names; leave old profile elements removed after a successful migration.
- Deprecation window: accept `NIXMARCHY_*` env and the old state dir, warn once.
- The user's own box is the first migration target (it has 6 installed plugins).

---

## 7. Feature roadmap (milestones)

### M0 — Extract, rename, package, ship *(blocking everything)*
- Create the repo from `modules/home/nixmarchy`; move the host/portal/CLI into `pkgs/`.
- `flake.nix` with the outputs in §4; `omninix` buildEnv; baked store paths.
- Rename per §6 (+ migration).
- `nix run` / `nix shell` verified on a bare box (no HM, no NixOS module).
- **Accept:** `nix run github:OWNER/omninix` starts the host; `omninix install` + a
  reloaded host mounts an already-working plugin (`evindor.keystroke`).

### M1 — Host completeness
- Host the remaining kinds: **`bar`** and **`bar-widget`** (see M5 for the bar itself).
- Add `ShellIpc` (Quickshell 0.3 lacks Omarchy's; port a compatible shim) — several
  plugins use it (`UiDummy`/`Panel` already work around it).
- Complete the kind contract: `manifest.kinds` → entry points, per-kind lifecycle
  (`opened`, `close`, `destroy`), and a per-plugin `error` surfaced through `list`.
- **Accept:** every kind mounts or reports a precise, actionable error; no silent skip.

### M2 — Portal parity (`qs.Commons` / `qs.Ui`)
- Diff our portal against `omacom/omarchy@quattro` `shell/Commons/*` + `shell/Ui/*`;
  port the remainder, keeping the same singleton names/signatures.
- Add **`omninix doctor --portal`**: statically scan installed plugins' QML for
  `qs.Commons`/`qs.Ui` symbol usage and report missing ones *before* launching.
- Track `Style.*` key coverage (keystroke needed `font.heading`, `controlFill`).
- **Accept:** doctor reports 0 missing symbols for the whole fixture set; keystroke,
  omadex, key-promoter mount with zero `WARN`/`ReferenceError`.

### M3 — Omarchy CLI shim layer
- **Discovery:** scan each plugin tree for `omarchy-[a-z0-9-]+`, `uwsm-app`,
  `gtk-launch`, `hyprctl`-adjacent tooling; emit a report of what the plugin expects.
- **Implement** a shim framework + concrete shims: `omarchy-shell` (IPC parity),
  `omarchy-launch-*`, `omarchy-toggle-*`, `omarchy-cmd-*`, `omarchy-theme-*`,
  `omarchy-screenshot`, `omarchy-remove-launcher-entry`, `uwsm-app`, `gtk-launch`.
- Ship each shim only when it can be implemented honestly; otherwise a documented
  no-op that logs, never a fake success.
- **Accept:** `omninix doctor --tools` reports every tool a plugin calls as
  `implemented` / `stub` / `missing`, and no plugin dies on a missing binary.

### M4 — Compatibility patch index
- Move the ad-hoc ledger into `patches/index.json` + `patches/<id>/*.patch`, applied
  automatically by `install`/`relink` (currently manual).
- Encode the **known incompatibility classes** as detectors so new plugins are
  auto-diagnosed: (a) bare child elements under a `QtObject` root
  (jacklapinza.omadex), (b) `ShellIpc` usage, (c) `uwsm-app`/`gtk-launch` scope
  assumptions (fkcodes.key-promoter), (d) missing portal symbols (M2).
- Every patch entry carries: reason, upstream commit, and an upstream PR link.
- Policy: prefer upstream PRs; the index is for unmerged/abandoned plugins.
- **Accept:** `omninix install <url>` applies patches with no manual `relink`.

### M5 — Bar host / bar-widget support
- Decide (see §12): ship a minimal bar, or a `PluginBarApi` mounting slot for an
  existing bar (this box runs its own `quickshell` bar in `modules/home/quickshell`).
- Implement `bar` + `bar-widget` hosting with sections `left|center|right` and the
  existing `barWidget.slot` exclusion.
- **Accept:** a bar-widget fixture plugin renders in the host bar and its click
  handlers fire.

### M6 — Service capability routing coverage
- Enumerate the full `omarchy.*` id space used by catalog plugins (idle, lock,
  notifications/DND, battery, network, bluetooth, audio, power-profiles, nightlight,
  media, calendar, weather, clipboard, screenshot, theme, wallpaper, tray,
  brightness, updates, …).
- For each: `builtin` (real impl), `stub` (honest static values), or `reject`
  (documented reason). Today: 5 ids, 2 real.
- New builtins worth wiring: `omarchy.idle` → hypridle/hyprlock;
  `omarchy.notifications` → DND state; `omarchy.battery` → UPower.
- Default routing table ships in the repo (not per-host), overridable by the user.
- **Accept:** a plugin reading any routed service gets a live value or an honest
  `enabled:false`, never a crash.

### M7 — Session integration
- Autostart: Hyprland `exec-once` (HM/NixOS module) **and** an optional systemd user
  unit with `Restart=always` (learned: `on-failure` misses clean SIGTERM).
- Keybind helper: `omninix bind` / documented `bind = SUPER, D, exec, omninix toggle <id>`.
- Idle/lock, notifications, and the launch OSD once M3/M6 land.
- **Accept:** fresh login → host running; a bound key summons a plugin.

### M8 — Marketplace UX & lifecycle hardening
- `omninix search <term>`, `omninix browse`, `omninix install <id>` by catalog id,
  `omninix outdated` / `omninix upgrade`.
- `omninix doctor` (portal + tools + version matrix + registry integrity).
- Offline reinstall from cache; `--pin rev`; integrity check of fetched trees.
- **Accept:** the catalog is browsable and installable by id; `doctor` exits 0 on a
  healthy box and non-zero with a reason otherwise.

---

## 8. Compatibility strategy

1. **Version matrix, documented and enforced by `doctor`:** Omarchy shell API version
   (`docs/omarchy-shell.md`) ↔ omninix; `manifest.schemaVersion`; Quickshell
   (nixpkgs pin, currently 0.3.x) ↔ plugin expectations; Qt 6.x minor.
2. **Prefer upstream fixes.** omninix should shrink its patch index over time; each
   entry links a PR. Target: patches only for abandoned plugins.
3. **Never fake capability.** A missing tool/service is `reject`/`missing` with a
   reason, surfaced in `doctor` and in the host log — not a silent no-op that makes a
   plugin appear to work.
4. **Portal is versioned** with the flake; a plugin built for a newer Omarchy Qt may
   need a compat overlay (the `QtObject` default-property case) — keep these as
   `pkgs/compat/` overlays rather than plugin patches where possible.

---

## 9. Testing & CI

- `tests/fixtures/`: vendored, pinned sample plugins — at least one per kind
  (`bar`, `bar-widget`, `menu`, `overlay`, `panel`, `service`) plus the three known
  diverged ones.
- `tests/conformance.sh`: headless Quickshell (offscreen platform), install each
  fixture into a throwaway `XDG_STATE_HOME`/`XDG_CONFIG_HOME`, run the host, and
  assert: every plugin `list` entry has `error:""`, no `WARN`/`ReferenceError` in the
  log, and each summonable kind opens.
- `nix flake check` runs it; CI on `x86_64-linux` against the pinned nixpkgs, plus a
  canary job against `nixpkgs-unstable`.
- Screenshot assertions for UI kinds (grim/ffmpeg) where deterministic.
- **Regression rule:** every bug fixed gets a fixture or a doctor check that fails
  before and passes after (e.g. the `PointerMoveGate` failure becomes a doctor
  symbol check).

---

## 10. Docs

- `README.md`: 60-second quickstart for `nix run`, `nix shell`, HM, NixOS.
- `docs/install.md`: the four install paths + troubleshooting.
- `docs/compatibility.md`: **per-plugin matrix** (id, kind, status, patches needed,
  upstream PR) — the thing users actually search for.
- `docs/portal.md`: what `qs.Commons`/`qs.Ui` covers vs upstream Omarchy.
- `docs/patches.md`: how to author/submit a patch and how to upstream it.
- `CONTRIBUTING.md`: fixture-per-bug rule, patch policy, rename/contract rules (§3).

---

## 11. Sequencing

```
M0 ─▶ M1 ─▶ M2 ─▶ M3 ─▶ M4 ─▶ M5
        └──────────▶ M6 ─▶ M7
                          └──▶ M8
                     §9 (tests) and §10 (docs) run alongside from M0
```
M0 is the gate. M2 (portal) + M3 (shims) + M4 (patches) are what actually make
"any plugin" true; M5 (bar) and M6 (services) close the biggest remaining classes.

---

## 12. Open decisions

1. **Bar: ship one or integrate?** Ship a minimal bar (self-contained, more work) vs
   a `PluginBarApi` slot into an existing bar (this box's bar is separate). Affects
   M5 scope substantially.
2. **Imperative + declarative, or declarative only?** Recommend both (§5), imperative
   default.
3. **Patch home:** local index vs upstream PRs. Recommend upstream-first with a
   shrinking index.
4. **Quickshell source:** nixpkgs `quickshell` (follow the consumer) vs the
   quickshell flake input (track master). Recommend nixpkgs + `follows` for ABI
   stability; the master-tracking flake only in the canary CI job.
5. **Multi-compositor:** confirm Hyprland-only is acceptable (Omarchy is
   Hyprland-only) — recommend yes, documented.
6. **State-dir rename migration** (§6.3): move vs symlink vs copy. Recommend `mv`
   with a one-release `NIXMARCHY_*` fallback.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| Upstream Omarchy shell API drifts (Quickshell/Qt bumps) | version matrix + canary CI (§8, §9) |
| Portal gaps break plugins silently | M2 `doctor --portal` static symbol check |
| Plugins assume Arch/Omarchy binaries | M3 discovery + honest shim/stub reporting |
| Patch index rots | upstream-first policy; per-entry PR link; fixture per patch |
| Rename churn breaks existing users (incl. this box) | §6.3 migration + one-release compat |
| Security: plugin code runs unsandboxed at user level | URL hardening (done), no root, `doctor` shows what a plugin calls; document the trust model |
| GC of plugin store paths | profile GC roots (done) + `doctor` integrity check |

---

## 14. Immediate next actions (when work resumes)

1. M0: extract + rename + flake outputs; migrate this box's state dir.
2. Stand up `tests/fixtures` + `conformance.sh` (M9 pulled forward) so M1–M6 are
   measurable.
3. M2 `doctor --portal` first — it is the cheapest lever on "any plugin works".
