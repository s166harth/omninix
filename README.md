# OMNINIX

Run **Omarchy Quickshell plugins** on **NixOS / plain Nix** — no Arch, no Omarchy, no rebuild:
a Quickshell host that mounts third-party plugins by `manifest.json` kind, the
`qs.Commons` / `qs.Ui` portal they import, and a CLI that installs, pins and enables them.

Status: **seed snapshot**, extracted verbatim from a home-manager flake. Nothing is renamed or
packaged yet — see `ROADMAP.md` (milestone **M0**: extract → rename to `omninix` → flake outputs).

## Layout

| Path | What it is |
|---|---|
| `bin/nixmarchy` | CLI: `install`, `list`, `enable`/`disable`, `summon`/`hide`/`toggle`, `update`, `relink`, `remove`, `validate` (bash + jq) |
| `bin/*` (5 more) | shims: `nixmarchy-ipc` (host IPC), `nixmarchy-shell-run` (launch host), `nixmarchy-notification-send` / `omarchy-notification-send`, `omarchy-menu-keybindings` |
| `shell/shell.qml` | the host: discovery, kind→entry-point mounting, priority/slot precedence, summon contract, IPC target `shell` |
| `shell/{AppLibrary.qml,AppSearch.js,Cat.qml}` | app library + sync file reads exposed to plugins as `shell.appLibrary` |
| `Commons.qs/qs/{Commons,Ui}` | the portal: `qs.Commons` (`Color`,`Style`,`Util`,`Border`) + `qs.Ui` (13 components under 14 names — `Panel` ≡ `UiDummy`); put `Commons.qs`, the tree root, on `QML_IMPORT_PATH` ahead of the plugin |
| `nixmarchy.nix` | home-manager module (packages, autostart, state) + per-plugin divergence ledger |
| `tests/` | unit tests for everything above |

State: `~/.local/state/nixmarchy/` (`registry.json`, `shell.json`, `plugins/<id>/`, `cli.json`,
`patched/`); checkouts are exposed through `~/.config/nixmarchy/plugins/<id>`.

## Tests

```sh
tests/run-all.sh              # every suite
tests/run-all.sh cli bins     # filter by filename
bash tests/cli-interface.test.sh   # one suite
```

Zero dependencies beyond `bash`, `jq` and `python3`; hermetic (temp `$HOME`, stubbed `git`/`nix`/`qs`/`curl`,
no network, no writes outside the temp dir). `tests/js` runs a lane per JS engine it finds (`node`, `bun`,
`deno` — PATH first, then `/nix/store`), and any suite that needs something this box lacks — no JS engine
at all, or the real `quickshell` for the runtime layer of `tests/qml` — prints a counted `SKIP` with the
reason instead of passing silently.

## Contracts plugins hard-code — never rename

`import qs.Commons` / `import qs.Ui`, the `shell` IPC target, `omarchy-*` tool names,
`manifest.json` `schemaVersion` 1, and the `open()` / `close()` / `opened` summon contract.
