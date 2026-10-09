#!/usr/bin/env bash
# tests/cli-lifecycle.test.sh — install/lifecycle half of bin/nixmarchy.
#
# Observable contract (all external tools stubbed; no network, no nix store):
#   install <url> --yes clones the repo under $XDG_STATE_HOME/nixmarchy/plugins/<id>,
#   writes {url,rev,enabled,priority,installedAt,storePath,clis} to registry.json,
#   pins the checkout as a `nixmarchy-plugin-<id>` nix-profile element, points the
#   ~/.config/nixmarchy/plugins/<id> symlink farm at that store path, links every
#   bin//scripts/ executable into ~/.local/bin and records it in cli.json, then
#   enables the plugin (shell.json) and rescans the shell. Re-installing the same
#   rev is a no-op; a different rev refuses and points at `update`. An existing
#   checkout with the same rev is adopted, a mismatched one refused. Non-TTY
#   installs refuse without --yes. compat warnings (bar-widget kind, unported
#   qs.Ui symbols) go to stderr yet install with --yes. A cross-plugin CLI name
#   collision refuses naming the owner, without relinking. update/relink/remove
#   keep registry, profile element, symlink farm, cli.json and ~/.local/bin in sync.

set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

suite cli-lifecycle

# ---- fixtures & stubs -------------------------------------------------------

setup_stubs() {
    # git: clone copies file:// fixture content; rev is tracked in .git-rev.
    stub git <<'STUB'
case "$1" in
  clone)
    url="${@: -2:1}"; dest="${@: -1}"; src="${url#file://}"
    rm -rf "$dest"; mkdir -p "$dest/.git"
    cp -a "$src/." "$dest/"
    printf '%s' "$(cat "$src/REV" 2>/dev/null || echo rev1)" >"$dest/.git-rev"
    printf '%s' "$src" >"$dest/.git-src"
    ;;
  -C)
    dir="$2"; sub="$3"
    case "$sub" in
      rev-parse) cat "$dir/.git-rev" 2>/dev/null ;;
      pull)
        src="$(cat "$dir/.git-src" 2>/dev/null)" || exit 1
        [ -n "$src" ] || exit 1
        cp -a "$src/." "$dir/"
        printf '%s' "$(cat "$src/REV" 2>/dev/null || echo rev1)" >"$dir/.git-rev"
        ;;
      reset) printf '%s' "${@: -1}" >"$dir/.git-rev" ;;
    esac
    ;;
esac
STUB

    # nix: store add materializes a real dir; profile add/remove/list keep a
    # JSON elements map under $T, element name = basename of the store path.
    stub nix <<'STUB'
prof="$T/nix-profile.json"
[ -f "$prof" ] || echo '{"elements":{}}' >"$prof"
case "$1" in
  store)
    if [ "${2:-}" = add ]; then
      name="$4"; dir="$5"; dest="$T/store/$name"
      mkdir -p "$T/store"; rm -rf "$dest"; cp -a "$dir" "$dest"
      printf '%s\n' "$dest"
    fi
    ;;
  profile)
    case "${2:-}" in
      list) cat "$prof" ;;
      add)
        spath="${@: -1}"; name="$(basename "$spath")"
        jq --arg n "$name" --arg sp "$spath" '.elements[$n]={storePaths:[$sp]}' "$prof" >"$prof.tmp" && mv "$prof.tmp" "$prof"
        ;;
      remove)
        jq --arg n "${3:-}" 'del(.elements[$n])' "$prof" >"$prof.tmp" && mv "$prof.tmp" "$prof"
        ;;
    esac
    ;;
esac
STUB

    stub nixmarchy-ipc <<'STUB'
echo "ipc $*"
STUB
}

# mkplugin <dir> <id> <rev> [kinds-json] [entrypoints-json]
mkplugin() {
    local dir="$1" id="$2" rev="$3"
    local kinds eps
    kinds="${4:-}"; [[ -n $kinds ]] || kinds='["service"]'
    eps="${5:-}"; [[ -n $eps ]] || eps='{"service":"Main.qml"}'
    mkdir -p "$dir"
    jq -cn --arg id "$id" --argjson k "$kinds" --argjson e "$eps" \
        '{schemaVersion:1,id:$id,name:$id,version:"1.0.0",kinds:$k,entryPoints:$e}' >"$dir/manifest.json"
    local f
    while IFS= read -r f; do
        mkdir -p "$dir/$(dirname "$f")"
        printf '// %s\n' "$f" >"$dir/$f"
    done < <(jq -r '.entryPoints | to_entries[] | .value' "$dir/manifest.json")
    printf '%s' "$rev" >"$dir/REV"
}

# mkcli <plugin-dir> <relpath-under-bin-or-scripts>  -> executable shim that
# records a run into $T/cli-ran.
mkcli() {
    local dir="$1" rel="$2"
    mkdir -p "$dir/$(dirname "$rel")"
    cat >"$dir/$rel" <<SH
#!/usr/bin/env bash
echo "ran $rel \$*" >>"$T/cli-ran"
SH
    chmod +x "$dir/$rel"
}

reg()    { printf '%s/registry.json' "$(state_dir)"; }
cliidx() { printf '%s/cli.json' "$(state_dir)"; }
shellj() { printf '%s/shell.json' "$(state_dir)"; }
proff()  { printf '%s/nix-profile.json' "$T"; }
rj()     { jq -r "$1" "$(reg)"; }

# ---- install: full happy path ----------------------------------------------

it "install --yes lands checkout, registry entry, profile pin, farm symlink, CLI links"
new_home install_happy
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkcli "$T/fx/alpha" bin/foo
mkcli "$T/fx/alpha" scripts/bar
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
assert_contains "$OUT" "Installed and enabled alpha" "install summary"
assert_file "$(plugins_dir)/alpha/manifest.json" "checkout manifest"
assert_jq '.plugins.alpha | .rev=="abc123" and .enabled==true and .priority==0 and (.installedAt|type)=="string"' "$(cat "$(reg)")"
assert_eq "file://$T/fx/alpha" "$(rj '.plugins.alpha.url')" "recorded url"
assert_eq "nixmarchy-plugin-alpha" "$(basename "$(rj '.plugins.alpha.storePath')")" "store path basename"
assert_jq '.elements | has("nixmarchy-plugin-alpha")' "$(cat "$(proff)")"
assert_symlink_to "$HOME/.config/nixmarchy/plugins/alpha" "nixmarchy-plugin-alpha"
assert_symlink_to "$HOME/.local/bin/foo" "/plugins/alpha/bin/foo"
assert_symlink_to "$HOME/.local/bin/bar" "/plugins/alpha/scripts/bar"
assert_jq '.links.foo.id=="alpha" and .links.bar.id=="alpha"' "$(cat "$(cliidx)")"
assert_eq "bar foo" "$(rj '[.plugins.alpha.clis[]]|sort|join(" ")')" "registry clis"
assert_eq "alpha" "$(jq -r '.plugins[]|select(.=="alpha")' "$(shellj)")" "shell.json enabled"
assert_contains "$(stub_log_matching 'profile add')" "nix profile add --priority 10" "profile add argv"
assert_not_contains "$ERR" "COMPAT WARNING" "no compat warning for plain plugin"

# ---- re-install / idempotence ----------------------------------------------

it "re-installing the same rev is a no-op leaving identical JSON state"
new_home reinstall
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
before_reg="$(cat "$(reg)")"; before_shell="$(cat "$(shellj)")"; before_cli="$(cat "$(cliidx)")"
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
assert_contains "$OUT" "no-op" "re-install summary"
assert_eq "$before_reg" "$(cat "$(reg)")" "registry unchanged"
assert_eq "$before_shell" "$(cat "$(shellj)")" "shell.json unchanged"
assert_eq "$before_cli" "$(cat "$(cliidx)")" "cli.json unchanged"

it "running enable twice leaves identical JSON state"
new_home idem_enable
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
run bash "$BIN/nixmarchy" enable alpha
assert_status 0
s1="$(cat "$(reg)")"; h1="$(cat "$(shellj)")"
run bash "$BIN/nixmarchy" enable alpha
assert_status 0
assert_eq "$s1" "$(cat "$(reg)")" "registry stable"
assert_eq "$h1" "$(cat "$(shellj)")" "shell.json stable"

it "same id at a different rev refuses and points at update"
new_home reinstall_rev
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
printf 'def456' >"$T/fx/alpha/REV"
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 1
assert_contains "$ERR" "already installed at abc123" "names existing rev"
assert_contains "$ERR" "update" "points at update"
assert_eq "abc123" "$(rj '.plugins.alpha.rev')" "rev unchanged"

# ---- orphan adoption --------------------------------------------------------

it "adopts an existing rev-matching checkout, refuses a mismatched one"
new_home orphan
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkdir -p "$(plugins_dir)"
mkplugin "$(plugins_dir)/alpha" alpha abc123
printf 'abc123' >"$(plugins_dir)/alpha/.git-rev"
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
assert_contains "$OUT" "adopting" "adoption message"
assert_jq '.plugins | has("alpha")' "$(cat "$(reg)")" "adopted plugin registered"
# same shape, wrong rev -> refuse
new_home orphan_bad
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkdir -p "$(plugins_dir)"
mkplugin "$(plugins_dir)/alpha" alpha abc123
printf 'stale99' >"$(plugins_dir)/alpha/.git-rev"
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 1
assert_contains "$ERR" "not a clean abc123 checkout" "mismatched rev refusal"
assert_jq '.plugins|has("alpha")|not' "$(cat "$(reg)")" "refused orphan not registered"

# ---- non-TTY refusal + priority propagation ---------------------------------

it "refuses a non-TTY install without --yes"
new_home notty
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha"
assert_status 1
assert_contains "$ERR" "pass --yes" "refusal contract"
assert_no_file "$(plugins_dir)/alpha" "nothing cloned"

it "--priority N propagates to the registry"
new_home priority
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes --priority 7
assert_status 0
assert_eq "7" "$(rj '.plugins.alpha.priority')" "install priority"
run bash "$BIN/nixmarchy" enable alpha --priority 3
assert_status 0
assert_eq "3" "$(rj '.plugins.alpha.priority')" "enable priority"

# ---- compat warnings --------------------------------------------------------

it "bar-widget manifest warns on stderr but installs with --yes"
new_home compat_bar
setup_stubs
mkplugin "$T/fx/barplug" barplug abc123 '["bar-widget"]' '{"barWidget":"Widget.qml"}'
run bash "$BIN/nixmarchy" install "file://$T/fx/barplug" --yes
assert_status 0
assert_contains "$ERR" "COMPAT WARNING" "bar-widget warning"
assert_contains "$ERR" "bar-widget" "names bar-widget kind"
assert_jq '.plugins | has("barplug")' "$(cat "$(reg)")" "installed anyway"

it "unported qs.Ui symbol warns, ported symbol does not"
new_home compat_ui
setup_stubs
mkplugin "$T/fx/unported" unported abc123
printf 'import qs.Ui\nUi.Frobnicator { }\n' >"$T/fx/unported/Extra.qml"
run bash "$BIN/nixmarchy" install "file://$T/fx/unported" --yes
assert_status 0
assert_contains "$ERR" "not ported" "unported warning"
assert_contains "$ERR" "Frobnicator" "names missing symbol"
assert_jq '.plugins | has("unported")' "$(cat "$(reg)")" "installed anyway"
new_home compat_ok
setup_stubs
mkplugin "$T/fx/ported" ported abc123
printf 'import qs.Ui\nUi.Panel { }\n' >"$T/fx/ported/Extra.qml"
run bash "$BIN/nixmarchy" install "file://$T/fx/ported" --yes
assert_status 0
assert_not_contains "$ERR" "COMPAT WARNING" "ported symbol is silent"

# ---- CLI name collisions ----------------------------------------------------

it "a cross-plugin CLI name collision refuses, names the owner and does not relink"
new_home collide
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkcli "$T/fx/alpha" bin/foo
mkplugin "$T/fx/beta" beta def456
mkcli "$T/fx/beta" bin/foo
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
alpha_target="$(readlink "$HOME/.local/bin/foo")"
run bash "$BIN/nixmarchy" install "file://$T/fx/beta" --yes
assert_status 1
assert_contains "$ERR" "already owned by plugin 'alpha'" "names owner"
assert_eq "$alpha_target" "$(readlink "$HOME/.local/bin/foo")" "existing link intact"
assert_eq "alpha" "$(jq -r '.links.foo.id' "$(cliidx)")" "index still owned by alpha"
assert_jq '[.links[]|select(.id=="beta")]|length==0' "$(cat "$(cliidx)")"

# ---- enable/disable/list + summon/hide/toggle -------------------------------

it "list reports installed plugins and enable/disable drive shell.json"
new_home listenable
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
run bash "$BIN/nixmarchy" list --json
assert_status 0
assert_jq 'map(.id)|index("alpha")!=null' "$OUT" "list --json includes id"
run bash "$BIN/nixmarchy" list
assert_contains "$OUT" "alpha" "list text id"
assert_contains "$OUT" "enabled" "list text state"
run bash "$BIN/nixmarchy" disable alpha
assert_status 0
assert_eq "false" "$(rj '.plugins.alpha.enabled')" "registry disabled"
assert_jq '.plugins|index("alpha")==null' "$(cat "$(shellj)")" "not enabled in shell.json"
run bash "$BIN/nixmarchy" enable alpha
assert_status 0
assert_jq '.plugins|index("alpha")!=null' "$(cat "$(shellj)")" "enabled in shell.json"

it "summon/hide/toggle forward to the shell IPC"
new_home ipc
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
run bash "$BIN/nixmarchy" summon alpha '{}'
assert_status 0
assert_contains "$OUT" "ipc summon alpha" "summon forwarded"
run bash "$BIN/nixmarchy" hide alpha
assert_status 0
assert_contains "$OUT" "ipc hide alpha" "hide forwarded"
run bash "$BIN/nixmarchy" toggle alpha
assert_status 0
assert_contains "$OUT" "ipc toggle alpha" "toggle forwarded"

it "summon falls back to the plugin CLI when the shell is unreachable"
new_home fallback
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkcli "$T/fx/alpha" bin/foo
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
stub nixmarchy-ipc <<'STUB'
exit 1
STUB
run bash "$BIN/nixmarchy" summon alpha
assert_status 0
assert_contains "$ERR" "no mounted UI" "fallback notice"
assert_file "$T/cli-ran" "plugin CLI ran"

# ---- update / relink --------------------------------------------------------

it "update fast-forwards, re-pins and relinks"
new_home update
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkcli "$T/fx/alpha" bin/foo
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
printf 'def456' >"$T/fx/alpha/REV"
printf 'new content\n' >"$T/fx/alpha/NEW.txt"
run bash "$BIN/nixmarchy" update alpha
assert_status 0
assert_contains "$OUT" "Updated alpha abc123 -> def456" "update summary"
assert_eq "def456" "$(rj '.plugins.alpha.rev')" "rev bumped"
assert_file "$(rj '.plugins.alpha.storePath')/NEW.txt" "new content pinned"
assert_eq "alpha" "$(jq -r '.links.foo.id' "$(cliidx)")" "CLI relinked"
run bash "$BIN/nixmarchy" update alpha
assert_status 0
assert_contains "$OUT" "already at def456" "second update is a no-op"

it "relink re-pins a divergent local checkout"
new_home relink
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
printf '// LOCAL PATCH\n' >"$(plugins_dir)/alpha/Main.qml"
printf 'localrev1' >"$(plugins_dir)/alpha/.git-rev"
run bash "$BIN/nixmarchy" relink alpha
assert_status 0
assert_eq "localrev1" "$(rj '.plugins.alpha.rev')" "rev re-pinned"
assert_contains "$(cat "$(rj '.plugins.alpha.storePath')/Main.qml")" "LOCAL PATCH" "patch pinned"
run bash "$BIN/nixmarchy" relink nope
assert_status 1
assert_contains "$ERR" "unknown plugin" "unknown id refused"

# ---- remove cleanup ---------------------------------------------------------

it "remove clears registry, profile element, farm symlink, CLI links and checkout"
new_home remove
setup_stubs
mkplugin "$T/fx/alpha" alpha abc123
mkcli "$T/fx/alpha" bin/foo
run bash "$BIN/nixmarchy" install "file://$T/fx/alpha" --yes
assert_status 0
run bash "$BIN/nixmarchy" remove alpha
assert_status 0
assert_contains "$OUT" "Removed alpha" "remove summary"
assert_jq '.plugins|has("alpha")|not' "$(cat "$(reg)")" "registry cleared"
assert_jq '.elements|has("nixmarchy-plugin-alpha")|not' "$(cat "$(proff)")" "profile element removed"
assert_no_file "$HOME/.config/nixmarchy/plugins/alpha" "farm symlink removed"
assert_no_file "$HOME/.local/bin/foo" "CLI link removed"
assert_jq '.links|has("foo")|not' "$(cat "$(cliidx)")" "cli.json row removed"
assert_no_file "$(plugins_dir)/alpha" "checkout removed"
assert_jq '.plugins|index("alpha")==null' "$(cat "$(shellj)")" "shell.json cleared"

finish
