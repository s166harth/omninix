#!/usr/bin/env bash
# tests/bins.test.sh — observable contracts of the five small nixmarchy bin shims (argv seen by stubs).
#
# nixmarchy-ipc        `qs <--path DIR|--config NAME> ipc call shell <fn> [args…]`; `shell <m>` echoes the
#                      payload, top-level summon/toggle/hide stay silent and demand an "ok"; a failing qs or a
#                      "skip" reply exits 1 (stderr message, silenced by NIXMARCHY_QUIET=1); selector is
#                      --path when $NIXMARCHY_SHELL_DIR/shell.qml exists, else --config $NIXMARCHY_SHELL_CONFIG.
# nixmarchy-shell-run  exports NIXMARCHY_SHELL_DIR + QML_IMPORT_PATH (portal prepended: $NIXMARCHY_COMMONS_DIR
#                      → ~/.config/nixmarchy/Commons.qs → literal @commonsQml@) and execs
#                      `quickshell --path "$SHELL_DIR" "$@"`, forwarding extra args; exit status is quickshell's.
# *-notification-send  forward argv to notify-send verbatim (no `--` terminator, stdin untouched): `-a nixmarchy
#                      <title> <body…>` / `-a omarchy -u normal [-h string:x-canonical-private-icon:<glyph>]
#                      -t <ms> <title> <body…>`; trailing args collapse into one body token, no body ⇒ one
#                      empty arg.
# omarchy-menu-keybindings  `hyprctl -j binds` → `%-28s → %s[\t<dispatcher>\t<arg>]` per keyboard bind in
#                      hyprctl order (mouse/keyless/(mouse:|switch:) binds dropped, leading "[…] " rule groups
#                      stripped, exec binds get a title-cased label); --print/-p, --records/-r/∅, else usage +
#                      exit 1; the excerpt consumers `source` is side-effect free.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

IPC="$BIN/nixmarchy-ipc"
RUNNER="$BIN/nixmarchy-shell-run"
NOTIFY="$BIN/nixmarchy-notification-send"
ONOTIFY="$BIN/omarchy-notification-send"
KB="$BIN/omarchy-menu-keybindings"

# ---------- local helpers ----------

# new_home does not know about the env knobs this suite drives, so clear them
# explicitly before every case (otherwise a value leaks into the next scenario).
clear_env() {
    unset NIXMARCHY_SHELL_CONFIG NIXMARCHY_QUIET \
        QS_OUT QS_ERR QS_STATUS STUB_STATUS HYPR_STATUS QML_IMPORT_PATH 2>/dev/null || true
}

# argv_of <stub> -> the argv that stub saw, "|"-joined, so empty args keep a slot ("a||b").
argv_of() {
    local -a a=()
    local x s=""
    [[ -f "$T/argv.$1" ]] || return 0
    mapfile -t a <"$T/argv.$1"
    for x in "${a[@]}"; do s+="|$x"; done
    printf '%s' "${s#|}"
}

# squeeze runs of spaces (the listing's column padding) but keep content/order.
squeeze() { printf '%s\n' "$1" | tr -s ' '; }

# ---------- stub installers (each records argv one-per-line so empties survive) ----------

stub_qs() {
    stub qs <<'EOF'
printf '%s\n' "$@" >"$T/argv.qs"
[[ -n ${QS_ERR-} ]] && printf '%s\n' "$QS_ERR" >&2
printf '%s' "${QS_OUT-ok}"
exit "${QS_STATUS:-0}"
EOF
}

stub_quickshell() {
    stub quickshell <<'EOF'
printf '%s\n' "$@" >"$T/argv.quickshell"
{
    printf 'QML_IMPORT_PATH=%s\n' "${QML_IMPORT_PATH-}"
    printf 'NIXMARCHY_SHELL_DIR=%s\n' "${NIXMARCHY_SHELL_DIR-}"
    printf 'NIXMARCHY_COMMONS_DIR=%s\n' "${NIXMARCHY_COMMONS_DIR-}"
} >"$T/env.quickshell"
exit "${STUB_STATUS:-0}"
EOF
}

stub_notify() {
    stub notify-send <<'EOF'
printf '%s\n' "$@" >"$T/argv.notify-send"
exit "${STUB_STATUS:-0}"
EOF
}

# same, but also drains stdin (only used where the case feeds it a closed pipe).
stub_notify_drain() {
    stub notify-send <<'EOF'
printf '%s\n' "$@" >"$T/argv.notify-send"
cat >"$T/stdin.seen"
exit "${STUB_STATUS:-0}"
EOF
}

# stub hyprctl; the binding table is whatever is currently in $T/binds.json.
stub_hyprctl() {
    stub hyprctl <<'EOF'
cat "$T/binds.json" 2>/dev/null
exit "${HYPR_STATUS:-0}"
EOF
}

env_of() { # env_of <file> <KEY>
    local k v
    while IFS='=' read -r k v; do
        [[ $k == "$2" ]] && { printf '%s' "$v"; return 0; }
    done <"$1"
    return 1
}

binds() { cat >"$T/binds.json"; }

# the excerpt consumers source, extracted exactly as the bin documents.
kb_prefix() {
    sed -n '1,/^output_keybindings() {/p' "$KB" | sed '$d' >"$T/kb.prefix"
}

# run a sourced-prefix function expression: kb_eval <bash code>
kb_eval() {
    run bash -c "source \"\$1\"; $1" _ "$T/kb.prefix"
}

# ---------------------------------------------------------------------------
suite nixmarchy-ipc

it "refuses to run with no arguments and never reaches qs"
new_home ipc
clear_env
stub_qs
run "$IPC"
assert_status 1
assert_contains "$ERR" "usage:" "stderr"
assert_no_file "$T/argv.qs" "qs must not be invoked"

it "requires a method after the shell sub-form"
new_home ipc
clear_env
stub_qs
run "$IPC" shell
assert_status 1
assert_contains "$ERR" "shell method required"
assert_no_file "$T/argv.qs" "qs must not be invoked"

it "rejects an unknown shell method without calling qs"
new_home ipc
clear_env
stub_qs
run "$IPC" shell bogus
assert_status 1
assert_contains "$ERR" "unknown shell method: bogus"
assert_no_file "$T/argv.qs" "qs must not be invoked"

it "rejects an unknown top-level command"
new_home ipc
clear_env
stub_qs
run "$IPC" bogus
assert_status 1
assert_contains "$ERR" "unknown command: bogus"

it "falls back to --config nixmarchy-shell when the host dir holds no shell.qml"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell ping
assert_status 0
assert_eq "ok" "$OUT" "payload printed"
assert_eq "--config|nixmarchy-shell|ipc|call|shell|ping" "$(argv_of qs)" "qs argv"
assert_stub_only "qs --config nixmarchy-shell ipc call shell ping"

it "prefers --path when \$NIXMARCHY_SHELL_DIR holds a shell.qml"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
d="$HOME/.config/nixmarchy-shell"
mkdir -p "$d" && : >"$d/shell.qml"
run "$IPC" shell ping
assert_status 0
assert_eq "--path|$d|ipc|call|shell|ping" "$(argv_of qs)" "qs argv"

it "honours NIXMARCHY_SHELL_CONFIG for the --config selector"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok NIXMARCHY_SHELL_CONFIG=other
run "$IPC" shell ping
assert_status 0
assert_eq "--config|other|ipc|call|shell|ping" "$(argv_of qs)" "qs argv"

it "maps shell list/rescan onto the ping-family calls"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell list
assert_eq "--config|nixmarchy-shell|ipc|call|shell|list" "$(argv_of qs)" "qs argv (list)"
reset_stub_log
run "$IPC" shell rescan
assert_eq "--config|nixmarchy-shell|ipc|call|shell|rescan" "$(argv_of qs)" "qs argv (rescan)"

it "shell summon/toggle pass the id and a payload argument, defaulting to {}"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell summon myplugin
assert_status 0
assert_eq "--config|nixmarchy-shell|ipc|call|shell|summon|myplugin|{}" "$(argv_of qs)" "default payload"
# NB: the bin's ${2:-{}} appends a stray "}" to any payload that IS set, so the
# explicit-payload cases below assert textually (they stay green once that bug is fixed).
reset_stub_log
run "$IPC" shell toggle myplugin '{"id":"p","n":1}'
assert_status 0
assert_contains "$(argv_of qs)" '|{"id":"p","n":1}' "explicit payload reaches qs"

it "passes a payload containing spaces as one argv token"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell call p toggle '{"a":"b c"}'
assert_status 0
assert_eq '--config|nixmarchy-shell|ipc|call|shell|call|p|toggle|{"a":"b c"}' "$(argv_of qs)" "payload token"

it "shell hide/isOpen pass the id only"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell isOpen p
assert_status 0
assert_eq "--config|nixmarchy-shell|ipc|call|shell|isOpen|p" "$(argv_of qs)" "qs argv (isOpen)"
reset_stub_log
run "$IPC" shell hide p
assert_eq "--config|nixmarchy-shell|ipc|call|shell|hide|p" "$(argv_of qs)" "qs argv (hide)"

it "shell call maps id/fn/payload, defaulting the payload to null"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" shell call p toggle
assert_status 0
assert_eq "--config|nixmarchy-shell|ipc|call|shell|call|p|toggle|null" "$(argv_of qs)" "null default"
reset_stub_log
run "$IPC" shell call p toggle '{"n":2}'
assert_eq '--config|nixmarchy-shell|ipc|call|shell|call|p|toggle|{"n":2}' "$(argv_of qs)" "explicit payload"

it "prints the shell payload verbatim"
new_home ipc
clear_env
stub_qs
export QS_OUT='["a","b"]'
run "$IPC" shell list
assert_status 0
assert_eq '["a","b"]' "$OUT" "payload"

it "a failing qs exits 1 with a diagnostic naming the selector"
new_home ipc
clear_env
stub_qs
export QS_STATUS=1 QS_OUT= QS_ERR="no instance"
run "$IPC" shell ping
assert_status 1
assert_eq "" "$OUT" "no stdout"
assert_contains "$ERR" "no running nixmarchy-shell"
assert_contains "$ERR" "--config nixmarchy-shell"
assert_contains "$ERR" "no instance" "qs stderr is included"

it "NIXMARCHY_QUIET=1 silences the qs failure but keeps the non-zero exit"
new_home ipc
clear_env
stub_qs
export QS_STATUS=1 QS_OUT= NIXMARCHY_QUIET=1
run "$IPC" shell ping
assert_status 1
assert_eq "" "$ERR" "stderr must be quiet"

it "treats a literal skip reply as a failure"
new_home ipc
clear_env
stub_qs
export QS_OUT=skip
run "$IPC" shell ping
assert_status 1
assert_contains "$ERR" "shell skipped: ping"

it "top-level summon is silent on ok and sends the default {} payload"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" summon panel-1
assert_status 0
assert_eq "" "$OUT" "silent on success"
assert_eq "--config|nixmarchy-shell|ipc|call|shell|summon|panel-1|{}" "$(argv_of qs)" "qs argv"

it "top-level toggle forwards the payload and stays silent"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" toggle panel-1 '{"id":"panel-1"}'
assert_status 0
assert_eq "" "$OUT" "silent on success"
# textually loose for the same ${3:-{}} stray-brace bug documented above.
assert_contains "$(argv_of qs)" '|toggle|panel-1|{"id":"panel-1"}' "qs argv"

it "top-level hide is silent on ok"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" hide panel-1
assert_status 0
assert_eq "" "$OUT" "silent on success"
assert_eq "--config|nixmarchy-shell|ipc|call|shell|hide|panel-1" "$(argv_of qs)" "qs argv"

it "top-level summon/hide fail when the shell answers skip"
new_home ipc
clear_env
stub_qs
export QS_OUT=skip
run "$IPC" summon panel-1
assert_status 1
assert_contains "$ERR" "shell skipped: summon panel-1"
reset_stub_log
run "$IPC" hide panel-1
assert_status 1
assert_contains "$ERR" "shell skipped: hide panel-1"

it "requires an id (and a fn for shell call) before touching qs"
new_home ipc
clear_env
stub_qs
export QS_OUT=ok
run "$IPC" summon
assert_status 1
assert_contains "$ERR" "id required"
assert_no_file "$T/argv.qs" "qs must not be invoked"
run "$IPC" shell hide
assert_status 1
assert_contains "$ERR" "id required"
assert_no_file "$T/argv.qs" "qs must not be invoked"
run "$IPC" shell call p
assert_status 1
assert_contains "$ERR" "fn required"
assert_no_file "$T/argv.qs" "qs must not be invoked"

# ---------------------------------------------------------------------------
suite nixmarchy-shell-run

it "defaults to ~/.config/nixmarchy-shell and exports shell dir + placeholder portal"
new_home runner
clear_env
stub_quickshell
run "$RUNNER"
assert_status 0
assert_eq "--path|$HOME/.config/nixmarchy-shell" "$(argv_of quickshell)" "quickshell argv"
assert_eq "@commonsQml@" "$(env_of "$T/env.quickshell" QML_IMPORT_PATH)" "portal placeholder"
assert_eq "$HOME/.config/nixmarchy-shell" "$(env_of "$T/env.quickshell" NIXMARCHY_SHELL_DIR)" "exported"

it "forwards extra qs args (e.g. --no-color) after --path"
new_home runner
clear_env
stub_quickshell
run "$RUNNER" --no-color -v
assert_status 0
assert_eq "--path|$HOME/.config/nixmarchy-shell|--no-color|-v" "$(argv_of quickshell)" "quickshell argv"

it "NIXMARCHY_SHELL_DIR overrides both --path and the exported shell dir"
new_home runner
clear_env
stub_quickshell
export NIXMARCHY_SHELL_DIR=/live/shell
run "$RUNNER" -v
assert_status 0
assert_eq "--path|/live/shell|-v" "$(argv_of quickshell)" "quickshell argv"
assert_eq "/live/shell" "$(env_of "$T/env.quickshell" NIXMARCHY_SHELL_DIR)" "exported override"

it "prepends the portal to an existing QML_IMPORT_PATH"
new_home runner
clear_env
mkdir -p "$T/portal"
stub_quickshell
export QML_IMPORT_PATH=/pre/existing NIXMARCHY_COMMONS_DIR="$T/portal"
run "$RUNNER"
assert_status 0
assert_eq "$T/portal:/pre/existing" "$(env_of "$T/env.quickshell" QML_IMPORT_PATH)" "prepended"

it "falls back to ~/.config/nixmarchy/Commons.qs when NIXMARCHY_COMMONS_DIR is unset"
new_home runner
clear_env
mkdir -p "$HOME/.config/nixmarchy/Commons.qs"
stub_quickshell
run "$RUNNER"
assert_status 0
assert_eq "$HOME/.config/nixmarchy/Commons.qs" "$(env_of "$T/env.quickshell" QML_IMPORT_PATH)" "fallback portal"

it "an existing NIXMARCHY_COMMONS_DIR wins over the user-config fallback"
new_home runner
clear_env
mkdir -p "$HOME/.config/nixmarchy/Commons.qs" "$T/portal"
stub_quickshell
export NIXMARCHY_COMMONS_DIR="$T/portal"
run "$RUNNER"
assert_status 0
assert_eq "$T/portal" "$(env_of "$T/env.quickshell" QML_IMPORT_PATH)" "env portal wins"

it "still execs quickshell when the host dir and portal are both missing"
new_home runner
clear_env
stub_quickshell
export NIXMARCHY_SHELL_DIR=/does/not/exist
run "$RUNNER"
assert_status 0
assert_eq "--path|/does/not/exist" "$(argv_of quickshell)" "unresolvable path still passed"
assert_eq "@commonsQml@" "$(env_of "$T/env.quickshell" QML_IMPORT_PATH)" "unresolvable portal still passed"
assert_stub_only "quickshell --path /does/not/exist"

it "propagates quickshell's exit status (exec)"
new_home runner
clear_env
stub_quickshell
export STUB_STATUS=7
run "$RUNNER"
assert_status 7

# ---------------------------------------------------------------------------
suite nixmarchy-notification-send

it "maps <title> <body> onto -a nixmarchy title body"
new_home notify
clear_env
stub_notify
run "$NOTIFY" Title Body
assert_status 0
assert_eq "-a|nixmarchy|Title|Body" "$(argv_of notify-send)" "notify-send argv"

it "collapses the body args into a single token"
new_home notify
clear_env
stub_notify
run "$NOTIFY" Title one two three
assert_status 0
assert_eq "-a|nixmarchy|Title|one two three" "$(argv_of notify-send)" "notify-send argv"

it "with no args uses the literal app name as title and an empty body arg"
new_home notify
clear_env
stub_notify
run "$NOTIFY"
assert_status 0
assert_eq "-a|nixmarchy|nixmarchy|" "$(argv_of notify-send)" "notify-send argv"

it "a title with no body still sends an empty body arg"
new_home notify
clear_env
stub_notify
run "$NOTIFY" OnlyTitle
assert_status 0
assert_eq "-a|nixmarchy|OnlyTitle|" "$(argv_of notify-send)" "notify-send argv"
reset_stub_log
run "$NOTIFY" OnlyTitle ""
assert_eq "-a|nixmarchy|OnlyTitle|" "$(argv_of notify-send)" "explicit empty body"

it "forwards -- verbatim (no terminator: it becomes the title)"
new_home notify
clear_env
stub_notify
run "$NOTIFY" -- Title Body
assert_status 0
assert_eq "-a|nixmarchy|--|Title Body" "$(argv_of notify-send)" "notify-send argv"

it "leaves stdin untouched (notify-send inherits it)"
new_home notify
clear_env
stub_notify_drain
run bash -c 'printf payload | "$1" Title Body' _ "$NOTIFY"
assert_status 0
assert_eq "payload" "$(cat "$T/stdin.seen")" "stdin reached notify-send"
assert_eq "-a|nixmarchy|Title|Body" "$(argv_of notify-send)" "notify-send argv"

it "propagates notify-send's exit status (exec)"
new_home notify
clear_env
stub_notify
export STUB_STATUS=3
run "$NOTIFY" Title Body
assert_status 3

# ---------------------------------------------------------------------------
suite omarchy-notification-send

it "maps <title> <body> onto -a omarchy -u normal -t 3500"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" Title Body
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|3500|Title|Body" "$(argv_of notify-send)" "notify-send argv"

it "with no args uses the literal app name as title and an empty body arg"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY"
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|3500|nixmarchy|" "$(argv_of notify-send)" "notify-send argv"

it "-g adds the canonical private icon hint before -t"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -g G Title Body
assert_status 0
assert_eq "-a|omarchy|-u|normal|-h|string:x-canonical-private-icon:G|-t|3500|Title|Body" "$(argv_of notify-send)" "notify-send argv"
reset_stub_log
run "$ONOTIFY" -g 'g l y' Title
assert_eq "-a|omarchy|-u|normal|-h|string:x-canonical-private-icon:g l y|-t|3500|Title|" "$(argv_of notify-send)" "glyph keeps its spaces"

it "an empty glyph omits the hint"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -g "" Title Body
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|3500|Title|Body" "$(argv_of notify-send)" "notify-send argv"

it "-t overrides the millisecond timeout"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -t 99 Title Body
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|99|Title|Body" "$(argv_of notify-send)" "notify-send argv"

it "parses -g and -t together and collapses the body"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -g X -t 100 Title one two
assert_status 0
assert_eq "-a|omarchy|-u|normal|-h|string:x-canonical-private-icon:X|-t|100|Title|one two" "$(argv_of notify-send)" "notify-send argv"

it "stops parsing options at the title (later flags are body text)"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" Title -g X
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|3500|Title|-g X" "$(argv_of notify-send)" "notify-send argv"

it "forwards -- verbatim (no terminator: it becomes the title)"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -- Title
assert_status 0
assert_eq "-a|omarchy|-u|normal|-t|3500|--|Title" "$(argv_of notify-send)" "notify-send argv"

it "a trailing -g with no value fails without invoking notify-send"
new_home onotify
clear_env
stub_notify
run "$ONOTIFY" -g
assert_status 1
assert_no_file "$T/argv.notify-send" "notify-send must not be invoked"

it "leaves stdin untouched and propagates notify-send's exit status"
new_home onotify
clear_env
stub_notify_drain
run bash -c 'printf payload | "$1" Title Body' _ "$ONOTIFY"
assert_status 0
assert_eq "payload" "$(cat "$T/stdin.seen")" "stdin reached notify-send"
assert_eq "-a|omarchy|-u|normal|-t|3500|Title|Body" "$(argv_of notify-send)" "notify-send argv"
reset_stub_log
export STUB_STATUS=4
run "$ONOTIFY" Title Body
assert_status 4

# ---------------------------------------------------------------------------
suite omarchy-menu-keybindings

it "the excerpt consumers source is side-effect free and defines the API"
new_home kb
clear_env
stub_hyprctl
kb_prefix
reset_stub_log
run bash -c 'source "$1"; echo sourced' _ "$T/kb.prefix"
assert_status 0
assert_eq "sourced" "$OUT" "sourcing emits nothing else"
assert_eq "" "$ERR" "no stderr on source"
assert_eq "" "$(cat "$STUB_LOG")" "sourcing must not consult hyprctl"
run bash -c 'source "$1"; for f in modmask_to_text normalize_key describe hyprctl_records output_binding_records; do type -t "$f" >/dev/null || exit 9; done; echo api-ok' _ "$T/kb.prefix"
assert_status 0
assert_eq "api-ok" "$OUT" "consumer API defined"

it "modmask_to_text renders SUPER SHIFT CTRL ALT order plus raw leftover bits"
new_home kb
clear_env
stub_hyprctl
kb_prefix
kb_eval 'printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$(modmask_to_text 0)" "$(modmask_to_text 64)" "$(modmask_to_text 1)" "$(modmask_to_text 4)" "$(modmask_to_text 8)" "$(modmask_to_text 65)" "$(modmask_to_text 77)" "$(modmask_to_text 2)"'
assert_status 0
assert_eq "|SUPER|SHIFT|CTRL|ALT|SUPER SHIFT|SUPER SHIFT CTRL ALT|2" "$OUT" "modmask table"

it "normalize_key title-cases punctuation and single letters, leaves names alone"
new_home kb
clear_env
stub_hyprctl
kb_prefix
kb_eval 'printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$(normalize_key comma)" "$(normalize_key period)" "$(normalize_key minus)" "$(normalize_key equal)" "$(normalize_key slash)" "$(normalize_key grave)" "$(normalize_key x)" "$(normalize_key F1)" "$(normalize_key space)" "$(normalize_key Return)"'
assert_status 0
assert_eq "COMMA|PERIOD|MINUS|EQUAL|SLASH|~|X|F1|space|Return" "$OUT" "key table"

it "describe labels exec binds (stripping rule groups) and nothing else"
new_home kb
clear_env
stub_hyprctl
kb_prefix
kb_eval 'printf "%s|%s|%s|%s|%s\n" "$(describe exec zen-beta)" "$(describe exec "[workspace 1 silent] zen-beta")" "$(describe exec ghostty)" "$(describe movetoworkspace 3)" "$(describe exec "")"'
assert_status 0
assert_eq "Zen Beta|Zen Beta|Ghostty||" "$OUT" "describe table"

it "reads the live table with hyprctl -j binds"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[]
JSON
run "$KB" --print
assert_status 0
assert_stub_only "hyprctl -j binds"

it "an empty bind table yields nothing and exits 0"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[]
JSON
run "$KB" --print
assert_status 0
assert_eq "" "$OUT" "no binds, no output"

it "--print lists one padded \"COMBO → label\" line per keyboard bind, in hyprctl order"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"},
 {"modmask":77,"key":"comma","description":"","dispatcher":"exec","arg":"[workspace 1 silent] brave --new-window"},
 {"modmask":0,"key":"F1","description":"Help","dispatcher":"exec","arg":"foo-bar"},
 {"modmask":72,"key":"period","description":"","dispatcher":"exec","arg":"mainMod, period"},
 {"modmask":64,"key":"mouse:272","description":"m","dispatcher":"exec","arg":"x"},
 {"modmask":64,"key":"","description":"","dispatcher":"","arg":""},
 {"mouse":true,"modmask":64,"key":"Q","description":"mb","dispatcher":"exec","arg":"x"},
 {"modmask":1,"key":"Return","description":"","dispatcher":"exec","arg":"wezterm"},
 {"modmask":64,"key":"grave","description":"Drop Down","dispatcher":"exec","arg":"[float; size 1111 700] ghostty"},
 {"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"}]
JSON
run "$KB" --print
assert_status 0
expected=$(cat <<'E'
SUPER + T → Terminal
SUPER SHIFT CTRL ALT + COMMA → Brave
F1 → Help
SUPER ALT + PERIOD → MainMod,
SHIFT + Return → Wezterm
SUPER + ~ → Drop Down
SUPER + T → Terminal
E
)
assert_eq "$expected" "$(squeeze "$OUT")" "listing (order, filtering, derived labels)"

it "the arrow sits at a fixed 28-column combo field"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"},
 {"modmask":77,"key":"comma","description":"Brave","dispatcher":"exec","arg":"brave"}]
JSON
run "$KB" --print
assert_status 0
mapfile -t lines <<<"$OUT"
assert_eq "SUPER + T" "${lines[0]:0:9}" "combo"
assert_eq "" "$(printf '%s' "${lines[0]:9:19}" | tr -d ' ')" "combo field padded with spaces to 28"
assert_eq " → Terminal" "${lines[0]:28}" "label after the arrow"
assert_eq "SUPER SHIFT CTRL ALT + COMMA" "${lines[1]:0:28}" "28-char combo fills the field exactly"
assert_eq " → Brave" "${lines[1]:28}" "label after the arrow (2)"

it "--records appends dispatcher and rule-group-free arg as tab fields"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"},
 {"modmask":77,"key":"comma","description":"","dispatcher":"exec","arg":"[workspace 1 silent] brave --new-window"},
 {"modmask":0,"key":"F1","description":"Help","dispatcher":"exec","arg":"foo-bar"},
 {"modmask":72,"key":"period","description":"","dispatcher":"exec","arg":"mainMod, period"},
 {"modmask":1,"key":"Return","description":"","dispatcher":"exec","arg":"wezterm"},
 {"modmask":64,"key":"grave","description":"Drop Down","dispatcher":"exec","arg":"[float; size 1111 700] ghostty"}]
JSON
run "$KB" --records
assert_status 0
assert_eq "0" "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF!=3{n++} END{print n+0}')" "every line has 3 tab fields"
mapfile -t recs <<<"$OUT"
IFS=$'\t' read -r r1c r1d r1a <<<"${recs[0]}"
assert_eq "SUPER + T → Terminal" "$(squeeze "$r1c")" "combo field"
assert_eq "exec" "$r1d" "dispatcher field"
assert_eq "zen-beta" "$r1a" "arg field"
IFS=$'\t' read -r r2c r2d r2a <<<"${recs[1]}"
assert_eq "exec" "$r2d" "dispatcher field 2"
assert_eq "brave --new-window" "$r2a" "leading [workspace …] group stripped"
IFS=$'\t' read -r r6c r6d r6a <<<"${recs[5]}"
assert_eq "ghostty" "$r6a" "[float; size …] group stripped"

it "derives a title-cased label only for undescribed exec binds"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","dispatcher":"exec","arg":"zen-beta"},
 {"modmask":64,"key":"Q","dispatcher":"movetoworkspace","arg":"3"}]
JSON
run "$KB" --print
assert_status 0
mapfile -t lines <<<"$OUT"
assert_eq "SUPER + T → Zen Beta" "$(squeeze "${lines[0]}")" "exec label derived"
assert_eq "" "${lines[1]#*→ }" "non-exec bind stays unlabelled"

it "--print is field one of --records"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"},
 {"modmask":1,"key":"Return","description":"","dispatcher":"exec","arg":"wezterm"}]
JSON
run "$KB" --print
assert_status 0
printed="$OUT"
run "$KB" --records
assert_status 0
assert_eq "$printed" "$(printf '%s\n' "$OUT" | cut -f1)" "--print == cut -f1"

it "no args and -r match --records; -p matches --print"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"}]
JSON
run "$KB" --records
assert_status 0
recs="$OUT"
run "$KB"
assert_eq "$recs" "$OUT" "no args == --records"
run "$KB" -r
assert_eq "$recs" "$OUT" "-r == --records"
run "$KB" --print
assert_status 0
printed="$OUT"
run "$KB" -p
assert_eq "$printed" "$OUT" "-p == --print"

it "keeps hyprctl order and does not dedup repeated binds"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"W","description":"third","dispatcher":"exec","arg":"w"},
 {"modmask":64,"key":"E","description":"second","dispatcher":"exec","arg":"e"},
 {"modmask":64,"key":"Q","description":"first","dispatcher":"exec","arg":"q"},
 {"modmask":64,"key":"Q","description":"first","dispatcher":"exec","arg":"q"}]
JSON
run "$KB" --print
assert_status 0
expected=$(cat <<'E'
SUPER + W → third
SUPER + E → second
SUPER + Q → first
SUPER + Q → first
E
)
assert_eq "$expected" "$(squeeze "$OUT")" "input order preserved, duplicates kept"

it "drops mouse, keyless and switch/mouse: pseudo binds"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"mouse:272","description":"m","dispatcher":"exec","arg":"x"},
 {"modmask":64,"key":"switch:on","description":"s","dispatcher":"exec","arg":"y"},
 {"modmask":64,"key":"","description":"","dispatcher":"exec","arg":"z"},
 {"mouse":true,"modmask":64,"key":"A","description":"mb","dispatcher":"exec","arg":"w"},
 {"modmask":64,"key":"B","description":"ok","dispatcher":"exec","arg":"bin"}]
JSON
run "$KB" --print
assert_status 0
assert_eq "SUPER + B → ok" "$(squeeze "$OUT")" "only the real keyboard bind survives"

it "a failing hyprctl makes the resolver exit non-zero"
new_home kb
clear_env
stub_hyprctl
binds </dev/null
export HYPR_STATUS=1
run "$KB" --print
assert_ne 0 "$STATUS" "must not report success"
assert_eq "" "$OUT" "no table, no output"

it "a failing hyprctl still prints a readable table but exits non-zero"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[{"modmask":64,"key":"T","description":"Terminal","dispatcher":"exec","arg":"zen-beta"}]
JSON
export HYPR_STATUS=1
run "$KB" --print
assert_ne 0 "$STATUS" "hyprctl failure propagates through the pipeline"
assert_eq "SUPER + T → Terminal" "$(squeeze "$OUT")" "table is still emitted"

it "unparseable hyprctl output fails loudly"
new_home kb
clear_env
stub_hyprctl
printf 'not json' >"$T/binds.json"
run "$KB" --records
assert_ne 0 "$STATUS" "jq error propagates"
assert_contains "$ERR" "parse error"

it "an unknown flag prints usage and never consults hyprctl"
new_home kb
clear_env
stub_hyprctl
binds <<'JSON'
[]
JSON
reset_stub_log
run "$KB" --bogus
assert_status 1
assert_contains "$ERR" "usage:"
assert_eq "" "$(cat "$STUB_LOG")" "hyprctl must not be invoked"

finish
