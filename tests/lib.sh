#!/usr/bin/env bash
# tests/lib.sh — zero-dependency test harness shared by every suite.
#
# A suite file sources this, names itself, runs cases, and calls finish:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#     suite cli
#     it "refuses a URL that looks like a git option"
#     run nixmarchy install --upload-pack=/tmp/x
#     assert_status 1
#     assert_contains "$ERR" "looks like a git option"
#     finish
#
# Conventions every suite MUST follow:
#   * hermetic: call `new_home` first; it points HOME/XDG_* at a temp dir and
#     puts a private stub bin dir first on PATH. Never touch the real ~.
#   * no network, no nix store writes, no quickshell: stub whatever the unit
#     under test shells out to (`stub <name> <<'EOF' ... EOF`).
#   * assert behaviour, not text: exit status, state files, argv seen by stubs.
#
# Exit status: 0 when every case passed, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
PORTAL_TREE="$ROOT/Commons.qs"   # portal tree root — put THIS on QML_IMPORT_PATH
                                 # (`import qs.Commons` -> Commons.qs/qs/Commons/qmldir; verified with the real qs 0.3.0)
PORTAL="$PORTAL_TREE/qs"         # the `qs` module parent: $PORTAL/Commons/*, $PORTAL/Ui/*
SHELLDIR="$ROOT/shell"
TESTS="$ROOT/tests"

SUITE="unnamed"
_pass=0
_fail=0
_failures=()
_case=""
_skip=0

# ---------- case machinery ----------

suite() {
    SUITE="$1"
    printf '\n\033[1m== %s ==\033[0m\n' "$SUITE"
}

it() {
    _case="$1"
    printf '  - %s\n' "$_case"
}

ok() {
    _pass=$((_pass + 1))
}

bad() { # bad <why>
    _fail=$((_fail + 1))
    _failures+=("$SUITE: $_case — $1")
    printf '      \033[31mFAIL\033[0m %s\n' "$1"
}

skip() { # skip <why> — counted, never silent
    _skip=$((_skip + 1))
    printf '      \033[33mSKIP\033[0m %s\n' "$1"
}

finish() {
    printf '\n%s: %d passed, %d failed, %d skipped\n' "$SUITE" "$_pass" "$_fail" "$_skip"
    if ((_fail > 0)); then
        printf 'failures:\n'
        printf '  * %s\n' "${_failures[@]}"
        exit 1
    fi
    exit 0
}

# ---------- assertions ----------

assert_eq() { # assert_eq <expected> <actual> [what]
    if [[ "$1" == "$2" ]]; then ok; else bad "${3:-value} expected [$1] got [$2]"; fi
}

assert_ne() {
    if [[ "$1" != "$2" ]]; then ok; else bad "${3:-value} unexpectedly [$1]"; fi
}

assert_contains() { # assert_contains <haystack> <needle> [what]
    if [[ "$1" == *"$2"* ]]; then ok; else bad "${3:-output} missing [$2]; got [${1:0:300}]"; fi
}

assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then ok; else bad "${3:-output} should not contain [$2]"; fi
}

assert_status() { # assert_status <expected> — for the last `run`
    if ((STATUS == $1)); then ok; else bad "exit status expected $1 got $STATUS (stderr: ${ERR:0:300})"; fi
}

assert_file() { # assert_file <path> [what]
    if [[ -f "$1" ]]; then ok; else bad "${2:-file} missing: $1"; fi
}

assert_no_file() {
    if [[ ! -e "$1" ]]; then ok; else bad "${2:-file} should not exist: $1"; fi
}

assert_dir() {
    if [[ -d "$1" ]]; then ok; else bad "${2:-dir} missing: $1"; fi
}

assert_exec() {
    if [[ -x "$1" ]]; then ok; else bad "${2:-file} not executable: $1"; fi
}

assert_symlink_to() { # assert_symlink_to <link> <target-substring>
    if [[ -L "$1" && "$(readlink "$1")" == *"$2"* ]]; then ok; else bad "link $1 -> $(readlink "$1" 2>/dev/null) not to *$2*"; fi
}

assert_jq() { # assert_jq <jq-filter-that-must-be-true> <json-file-or-string>
    local out
    out="$(printf '%s' "$2" | jq -e "$1" 2>&1)" || { bad "jq [$1] false on: ${2:0:200} ($out)"; return; }
    ok
}

# Legacy-style convenience: assert_cmd <expected-status> <cmd...>
assert_cmd() {
    local want="$1"; shift
    run "$@"
    assert_status "$want"
}

# ---------- running things ----------

# run <cmd...> -> fills STATUS, OUT, ERR (stdout/stderr with trailing newlines kept)
run() {
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    "$@" >"$outf" 2>"$errf"
    STATUS=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
    return 0
}

# ---------- isolation ----------

_TMPDIRS=()

new_home() { # new_home [name] -> temp HOME with $STUB_BIN first on PATH
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/nixmarchy-test.${1:-x}.XXXXXX")"
    _TMPDIRS+=("$d")
    T="$d"
    STUB_BIN="$d/stubbin"
    STUB_LOG="$d/stub.log"
    : >"$STUB_LOG"
    mkdir -p "$STUB_BIN" "$d/home/.config" "$d/home/.local/state"
    export HOME="$d/home"
    export XDG_CONFIG_HOME="$d/home/.config"
    export XDG_STATE_HOME="$d/home/.local/state"
    export XDG_DATA_HOME="$d/home/.local/share"
    export XDG_CACHE_HOME="$d/home/.cache"
    export PATH="$STUB_BIN:$PATH"
    export STUB_BIN STUB_LOG T
    unset NIXMARCHY_STATE_DIR NIXMARCHY_CATALOG_URL NIXMARCHY_SHELL_DIR NIXMARCHY_COMMONS_DIR 2>/dev/null || true
}

# stub <name> <<'EOF' ... EOF — installs an executable fake command.
# Every invocation appends "$name argv..." to $STUB_LOG unless the body sets
# STUB_QUIET=1; stdout of the body is returned to the caller.
stub() {
    local name="$1" body
    body="$(cat)"
    {
        printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >>"%s"\n' "$name" "$STUB_LOG"
        printf '%s\n' "$body"
    } >"$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

# $STUB_LOG accumulates every stub invocation for the whole suite (it is NOT
# reset per case). Use reset_stub_log between cases that assert on argv, or
# stub_log_matching to search it.
reset_stub_log() { : >"$STUB_LOG"; }

# stub_log_matching <pattern> -> prints matching lines of the stub log
stub_log_matching() { grep -F -- "$1" "$STUB_LOG" 2>/dev/null || true; }

# stub_log_exactly <line> -> true when that is the only logged line
assert_stub_only() {
    local want="$1" got
    got="$(cat "$STUB_LOG")"
    assert_eq "$want" "$got" "${2:-stub argv}"
}

state_dir() { printf '%s/nixmarchy' "$XDG_STATE_HOME"; }
plugins_dir() { printf '%s/plugins' "$(state_dir)"; }

cleanup_all() {
    local d
    for d in "${_TMPDIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
}
trap cleanup_all EXIT
