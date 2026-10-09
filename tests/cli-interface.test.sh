#!/usr/bin/env bash
# tests/cli-interface.test.sh — interface/validation contract of bin/nixmarchy.
#
# Observable contract (driven only through the public CLI):
#   * dispatch: no args / --help / -h print usage and exit 0; unknown command,
#     unknown install option, missing positional args exit 1 with a nixmarchy:
#     message on stderr.
#   * install URL handling: plugin.html?id=<id> resolves through the pinned
#     catalog cache ($XDG_STATE_HOME/nixmarchy/catalog.json, no network when
#     fresh); otherwise a page URL missing/empty id falls through and is
#     treated as a plain git URL. git URLs are normalised (strip ?/#, strip
#     trailing slash, append .git unless already .git or a file:// / local
#     path). Hostile URLs (non-git scheme, transport overrides --upload-pack=,
#     --exec=, --receive-pack=, ext::, fd::, control chars, leading dash) are
#     refused before any clone.
#   * validate <dir>: enforces schemaVersion 1, required fields (id name version
#     kinds entryPoints), a safe non-omarchy.* id, non-empty kinds array, object
#     entryPoints, barWidget.defaultSection ∈ {left,center,right}, relative
#     in-tree existing entry-point files, kind↔entryPoints pairing, and no
#     symlinks. Success prints "valid: <id>" and exits 0.
#   * list [--json] renders registry.json rows (enabled/disabled, priority,
#     short rev) or a compact JSON array.
#   * enable/disable rewrite registry.json .enabled and shell.json (enabled ids
#     + idle config), then ask the host to rescan via `nixmarchy-ipc shell
#     rescan` (→ `qs ipc call shell rescan`). summon/hide/toggle forward to
#     `nixmarchy-ipc <verb> <id> [payload]`.
#
# Hermetic: stubs git/nix/qs/curl; never touches the real HOME or the network.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

suite cli-interface

# A failing git clone lets install tests observe URL resolution/normalisation
# (echoed + passed as clone argv) without needing nix or a real repository.
stub_git_fail() {
    stub git <<'EOF'
exit 1
EOF
}
stub_nix_ok() {
    stub nix <<'EOF'
exit 0
EOF
}

write_registry() { # write_registry <json>
    mkdir -p "$(state_dir)"
    printf '%s' "$1" >"$(state_dir)/registry.json"
}
read_state() { cat "$1"; }

# ---------------------------------------------------------------------------
# argument dispatch
# ---------------------------------------------------------------------------

it "no args prints usage and exits 0"
new_home dispatch
run "$BIN/nixmarchy"
assert_status 0
assert_contains "$OUT" "Usage: nixmarchy"

it "--help and -h print usage and exit 0"
run "$BIN/nixmarchy" --help
assert_status 0
assert_contains "$OUT" "Usage: nixmarchy"
run "$BIN/nixmarchy" -h
assert_status 0
assert_contains "$OUT" "Usage: nixmarchy"

it "unknown command exits 1 naming the command"
new_home dispatch
run "$BIN/nixmarchy" frobnicate
assert_status 1
assert_contains "$ERR" "unknown command: frobnicate"

it "install with no URL exits 1"
new_home dispatch
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install
assert_status 1
assert_contains "$ERR" "a git URL or plugin page URL is required"

it "install with only --yes still requires a URL"
new_home dispatch
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install --yes
assert_status 1
assert_contains "$ERR" "a git URL or plugin page URL is required"

it "install rejects an unknown option"
new_home dispatch
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install --bogus https://github.com/o/r
assert_status 1
assert_contains "$ERR" "unknown install option"

it "install rejects a second positional argument"
new_home dispatch
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install https://github.com/o/r https://github.com/x/y
assert_status 1
assert_contains "$ERR" "unexpected argument"

it "enable/disable/remove/validate require their positional argument"
new_home dispatch
run "$BIN/nixmarchy" enable
assert_status 1
assert_contains "$ERR" "plugin id is required"
run "$BIN/nixmarchy" disable
assert_status 1
assert_contains "$ERR" "plugin id is required"
run "$BIN/nixmarchy" remove
assert_status 1
assert_contains "$ERR" "plugin id is required"
run "$BIN/nixmarchy" validate
assert_status 1
assert_contains "$ERR" "plugin folder not found"

# ---------------------------------------------------------------------------
# plugin-page URL → id resolution against the catalog cache (no network)
# ---------------------------------------------------------------------------

it "plugin-page install resolves the catalog repo URL"
new_home catalog
mkdir -p "$(state_dir)"
cat >"$(state_dir)/catalog.json" <<'EOF'
{"version":1,"plugins":[{"id":"myid","repo":"https://github.com/owner/repo/"}]}
EOF
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'https://plugins.omarchy.org/plugin.html?id=myid' --yes
assert_status 1
assert_contains "$OUT" "Resolved myid -> https://github.com/owner/repo"
assert_contains "$(stub_log_matching 'git clone')" "https://github.com/owner/repo.git"

it "plugin-page id resolves amid extra query parameters"
new_home catalog
mkdir -p "$(state_dir)"
cat >"$(state_dir)/catalog.json" <<'EOF'
{"items":[{"id":"myid","repo":"https://github.com/owner/repo"}]}
EOF
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://plugins.omarchy.org/plugin.html?section=top&id=myid&x=1' --yes
assert_status 1
assert_contains "$OUT" "Resolved myid -> https://github.com/owner/repo"

it "catalog miss reports the id is absent"
new_home catalog
mkdir -p "$(state_dir)"
echo '{"version":1,"plugins":[{"id":"other","repo":"https://github.com/o/r"}]}' >"$(state_dir)/catalog.json"
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://plugins.omarchy.org/plugin.html?id=missing' --yes
assert_status 1
assert_contains "$ERR" "has no repo in the catalog"

it "missing catalog cache reports marketplace lookup failure (no network)"
new_home catalog
stub curl <<'EOF'
exit 1
EOF
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://plugins.omarchy.org/plugin.html?id=missing' --yes
assert_status 1
assert_contains "$ERR" "not found in marketplace catalog"

it "plugin-page URL with an empty id is not resolved (falls through)"
new_home catalog
mkdir -p "$(state_dir)"
echo '{"version":1,"plugins":[{"id":"myid","repo":"https://github.com/owner/repo"}]}' >"$(state_dir)/catalog.json"
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://plugins.omarchy.org/plugin.html?id=' --yes
assert_status 1
assert_not_contains "$OUT" "Resolved"
assert_contains "$ERR" "failed to clone"

# ---------------------------------------------------------------------------
# git URL normalisation (observed as the argv the clone receives)
# ---------------------------------------------------------------------------

it "normalises query, fragment and trailing slash, appending .git"
new_home urlnorm
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'https://github.com/o/r/?a=1#frag' --yes
assert_status 1
assert_contains "$(stub_log_matching 'git clone')" "https://github.com/o/r.git"

it ".git suffix is idempotent"
new_home urlnorm
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'https://github.com/o/r.git' --yes
assert_status 1
assert_contains "$(stub_log_matching 'git clone')" "https://github.com/o/r.git"

it "file:// URLs are left untouched (no .git appended)"
new_home urlnorm
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'file:///tmp/foo/bar' --yes
assert_status 1
assert_contains "$(stub_log_matching 'git clone')" "file:///tmp/foo/bar "
assert_not_contains "$(stub_log_matching 'git clone')" "bar.git"

it "a bare local path is refused (not a git transport)"
new_home urlnorm
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install /tmp/some/dir --yes
assert_status 1
assert_contains "$ERR" "refusing non-git URL"
assert_eq "" "$(stub_log_matching 'git clone')" "no clone attempted"

# ---------------------------------------------------------------------------
# hostile URL refusals (must fail before any clone)
# ---------------------------------------------------------------------------

it "refuses a URL that looks like a git option (leading dash)"
new_home hostile
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install -- '-evil'
# main() treats any leading dash as an unknown option, so the URL never reaches
# check_git_url; the observable contract is still refusal-before-clone.
assert_status 1
assert_eq "" "$(stub_log_matching 'git clone')" "no clone attempted"

it "refuses --upload-pack= transport override"
new_home hostile
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'https://evil.example/repo--upload-pack=/tmp/x' --yes
assert_status 1
assert_contains "$ERR" "transport override"
assert_eq "" "$(stub_log_matching 'git clone')" "no clone attempted"

it "refuses --exec= and --receive-pack= overrides"
new_home hostile
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://evil.example/repo--exec=/tmp/x' --yes
assert_status 1
assert_contains "$ERR" "transport override"
run "$BIN/nixmarchy" install 'https://evil.example/repo--receive-pack=/tmp/x' --yes
assert_status 1
assert_contains "$ERR" "transport override"

it "refuses ext:: and fd:: transport helpers"
new_home hostile
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install 'https://evil.example/ext::sh' --yes
assert_status 1
assert_contains "$ERR" "transport override"
run "$BIN/nixmarchy" install 'https://evil.example/repofd::x' --yes
assert_status 1
assert_contains "$ERR" "transport override"

it "refuses a non-git scheme"
new_home hostile
stub_git_fail
stub_nix_ok
reset_stub_log
run "$BIN/nixmarchy" install 'ftp://example.com/repo' --yes
assert_status 1
assert_contains "$ERR" "refusing non-git URL"
assert_eq "" "$(stub_log_matching 'git clone')" "no clone attempted"

it "refuses URLs containing control characters"
new_home hostile
stub_git_fail
stub_nix_ok
run "$BIN/nixmarchy" install $'https://evil.example/a\nb' --yes
assert_status 1
assert_contains "$ERR" "control characters"
run "$BIN/nixmarchy" install $'https://evil.example/a\rb' --yes
assert_status 1
assert_contains "$ERR" "control characters"

# ---------------------------------------------------------------------------
# validate matrix
# ---------------------------------------------------------------------------

VALID='{"schemaVersion":1,"id":"myplug","name":"My","version":"1.0.0","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}'

mkvalid() { # mkvalid <dir> — a manifest that passes, plus its entry-point file
    mkdir -p "$1"
    printf '%s' "$VALID" >"$1/manifest.json"
    : >"$1/Bar.qml"
}
mkmanifest() { # mkmanifest <dir> <json>
    mkdir -p "$1"
    printf '%s' "$2" >"$1/manifest.json"
}

it "validate accepts a well-formed plugin (success contract)"
new_home validate
mkvalid "$T/plug"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 0
assert_eq "valid: myplug" "$OUT"

it "validate rejects a missing folder"
new_home validate
run "$BIN/nixmarchy" validate "$T/nope"
assert_status 1
assert_contains "$ERR" "plugin folder not found"

it "validate rejects a missing manifest"
new_home validate
mkdir -p "$T/plug"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "missing manifest.json"

it "validate rejects invalid JSON"
new_home validate
mkmanifest "$T/plug" '{not json'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "not valid JSON"

it "validate rejects schemaVersion other than 1"
new_home validate
mkvalid "$T/plug"
printf '%s' '{"schemaVersion":2,"id":"x","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}' >"$T/plug/manifest.json"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "unsupported or missing schemaVersion"

it "validate rejects each missing required field"
new_home validate
for f in id name version kinds entryPoints; do
    mkvalid "$T/plug"
    jq "del(.$f)" "$T/plug/manifest.json" >"$T/plug/m2" && mv "$T/plug/m2" "$T/plug/manifest.json"
    run "$BIN/nixmarchy" validate "$T/plug"
    assert_status 1
    assert_contains "$ERR" "manifest missing required field '$f'"
done

it "validate rejects an empty id"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}'
: >"$T/plug/Bar.qml"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "'id' is empty"

it "validate rejects an invalid id"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"bad id","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "invalid plugin id"

it "validate rejects an id containing '..'"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"a..b","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "invalid plugin id"

it "validate rejects the reserved omarchy.* namespace"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"omarchy.widget","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "reserved omarchy.* namespace"

it "validate rejects kinds that are not a non-empty array"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":[],"entryPoints":{"bar":"Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "'kinds' must be a non-empty array"

it "validate rejects entryPoints that are not an object"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["bar"],"entryPoints":[]}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "'entryPoints' must be an object"

it "validate rejects a bad barWidget.defaultSection"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Bar.qml"},"barWidget":{"defaultSection":"top"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "barWidget.defaultSection"

it "validate rejects an absolute entry-point path"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"/abs/Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "must be a relative path"

it "validate rejects an entry-point path containing '..'"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"../Bar.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "may not contain '..'"

it "validate rejects a missing entry-point file"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["bar"],"entryPoints":{"bar":"Missing.qml"}}'
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "entry point file not found"

it "validate enforces the kind↔entryPoints requirement matrix"
new_home validate
mkmanifest "$T/plug" '{"schemaVersion":1,"id":"p","name":"n","version":"1","kinds":["menu"],"entryPoints":{"bar":"Bar.qml"}}'
: >"$T/plug/Bar.qml"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "kind 'menu' requires an 'entryPoints.menu'"

it "validate rejects a symlink inside the plugin folder"
new_home validate
mkvalid "$T/plug"
ln -s Bar.qml "$T/plug/link.qml"
run "$BIN/nixmarchy" validate "$T/plug"
assert_status 1
assert_contains "$ERR" "symlinks are not allowed"

# ---------------------------------------------------------------------------
# list / list --json
# ---------------------------------------------------------------------------

it "list on an empty registry initialises it and prints only the header"
new_home list
run "$BIN/nixmarchy" list
assert_status 0
assert_contains "$OUT" "ID"
assert_not_contains "$OUT" "enabled"
assert_file "$(state_dir)/registry.json"

it "list renders enabled/disabled state, priority and short rev"
new_home list
write_registry '{"version":1,"plugins":{"alpha":{"url":"u","rev":"0123456789abcdef0123","enabled":true,"priority":5,"installedAt":"t"},"beta":{"url":"u","rev":"fedcba9876543210fedc","enabled":false,"priority":0,"installedAt":"t"}}}'
run "$BIN/nixmarchy" list
assert_status 0
assert_contains "$OUT" "alpha"
assert_contains "$OUT" "enabled"
assert_contains "$OUT" "0123456789ab"
assert_contains "$OUT" "beta"
assert_contains "$OUT" "disabled"
assert_not_contains "$OUT" "abcdef0123"

it "list --json emits a compact array with id merged in"
new_home list
write_registry '{"version":1,"plugins":{"alpha":{"url":"u","rev":"0123456789abcdef0123","enabled":true,"priority":5,"installedAt":"t"},"beta":{"url":"u","rev":"fedcba9876543210fedc","enabled":false,"priority":0,"installedAt":"t"}}}'
run "$BIN/nixmarchy" list --json
assert_status 0
assert_jq 'length == 2' "$OUT"
assert_jq 'map(select(.id=="alpha"))[0].enabled == true' "$OUT"
assert_jq 'map(select(.id=="beta"))[0].priority == 0' "$OUT"

it "list --json on an empty registry is the empty array"
new_home list
run "$BIN/nixmarchy" list --json
assert_status 0
assert_jq '. == []' "$OUT"

# ---------------------------------------------------------------------------
# enable / disable / summon / hide / toggle
# ---------------------------------------------------------------------------

# Real nixmarchy-ipc (symlinked) + stubbed qs lets us assert the qs argv the
# host actually receives.
ipc_stub_qs() {
    ln -sf "$BIN/nixmarchy-ipc" "$STUB_BIN/nixmarchy-ipc"
    stub qs <<'EOF'
echo ok
EOF
}

it "enable sets enabled+priority, writes shell.json and rescans over IPC"
new_home enable
ipc_stub_qs
write_registry '{"version":1,"plugins":{"plug1":{"url":"u","rev":"abc123","enabled":false,"priority":0,"installedAt":"t"}}}'
reset_stub_log
run "$BIN/nixmarchy" enable plug1 --priority 5
assert_status 0
assert_contains "$OUT" "Enabled plug1"
assert_jq '.plugins.plug1.enabled == true' "$(read_state "$(state_dir)/registry.json")"
assert_jq '.plugins.plug1.priority == 5' "$(read_state "$(state_dir)/registry.json")"
assert_jq '.plugins == ["plug1"]' "$(read_state "$(state_dir)/shell.json")"
assert_jq '.idle.screensaver == 150' "$(read_state "$(state_dir)/shell.json")"
assert_stub_only "qs --config nixmarchy-shell ipc call shell rescan"

it "disable clears enabled, empties shell.json and rescans"
new_home disable
ipc_stub_qs
write_registry '{"version":1,"plugins":{"plug1":{"url":"u","rev":"abc123","enabled":true,"priority":0,"installedAt":"t"}}}'
reset_stub_log
run "$BIN/nixmarchy" disable plug1
assert_status 0
assert_contains "$OUT" "Disabled plug1"
assert_jq '.plugins.plug1.enabled == false' "$(read_state "$(state_dir)/registry.json")"
assert_jq '.plugins == []' "$(read_state "$(state_dir)/shell.json")"
assert_stub_only "qs --config nixmarchy-shell ipc call shell rescan"

it "enable of an unknown plugin fails"
new_home enable
write_registry '{"version":1,"plugins":{}}'
run "$BIN/nixmarchy" enable ghost
assert_status 1
assert_contains "$ERR" "unknown plugin 'ghost'"

it "summon forwards to the host as 'summon <id>'"
new_home ipc
ipc_stub_qs
reset_stub_log
run "$BIN/nixmarchy" summon plug1
assert_status 0
assert_stub_only "qs --config nixmarchy-shell ipc call shell summon plug1 {}"

it "hide forwards to the host as 'hide <id>'"
new_home ipc
ipc_stub_qs
reset_stub_log
run "$BIN/nixmarchy" hide plug1
assert_status 0
assert_stub_only "qs --config nixmarchy-shell ipc call shell hide plug1"

it "toggle forwards to the host as 'toggle <id> {}'"
new_home ipc
ipc_stub_qs
reset_stub_log
run "$BIN/nixmarchy" toggle plug1
assert_status 0
assert_stub_only "qs --config nixmarchy-shell ipc call shell toggle plug1 {}"

it "summon with a dead host falls through to the error surface"
new_home ipc
ln -sf "$BIN/nixmarchy-ipc" "$STUB_BIN/nixmarchy-ipc"
stub qs <<'EOF'
exit 1
EOF
write_registry '{"version":1,"plugins":{}}'
run "$BIN/nixmarchy" summon plug1
assert_status 1
assert_contains "$ERR" "no running nixmarchy-shell"

it "hide with a dead host propagates the host error"
new_home ipc
ln -sf "$BIN/nixmarchy-ipc" "$STUB_BIN/nixmarchy-ipc"
stub qs <<'EOF'
exit 1
EOF
run "$BIN/nixmarchy" hide plug1
assert_status 1
assert_contains "$ERR" "no running nixmarchy-shell"

finish
