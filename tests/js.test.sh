#!/usr/bin/env bash
# tests/js.test.sh — the pure-JS units: shell/AppSearch.js + Commons.qs/qs/Commons/BorderGeometry.js.
#
# AppSearch.js (no host globals): entry{Name,Subtext,SortKey}/keywordText/entrySearchText; wordText/
#   words/entryAcronym; termMatches/allTermsMatch (lowercased query, ≤5-char acronym fallback);
#   fuzzyScore (0 on empty query, -1 no match, else 10000/9500/8000/7600/6000/5000/4600/4000 tiers);
#   sortedEntries(values,query,hiddenCallback) → [{entry,score,key,name}] by score desc then key/name,
#   dropping falsy/noDisplay/hidden/nameless and non-matching rows.
# BorderGeometry.js (.pragma library, works with Qt undefined): clamp/padHex/qmlHexColor/canonicalColor
#   (#rgb|#rrggbb|#rrggbbaa|RGB()|RGBA()|rgb()|rgba()|0xAARRGGBB), parseWidthSpec/withSideOverrides
#   (CSS 1–4 side widths), parseGradientSpec, isUniform/maxWidth/needsOverlay/canUseNative, normalizeRadii
#   (clamp + scale to fit), roundedRectPath/borderBoundary/borderPaths/ringPath, gradientEndpoints, stop*.
#
# The runner (tests/js/units.js) strips `.pragma` and evaluates each file in-process (no npm, no QML
# host, so `Qt` stays undefined and the helpers take their JS-string code paths). This suite runs that
# runner under EVERY engine it can find — node, bun, deno (PATH first, then a /nix/store glob, one lane
# per engine name) — and skips only when none exists, so an engine-specific regression is visible.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
suite js

# ---- discover every JS engine (node | bun | deno) ------------------------------
ENGINES=()
_eng_names=""
add_engine() { # add_engine <path> — one lane per engine name; a PATH entry wins
    local p="$1" name
    [[ -f $p && -x $p ]] || return 0
    name="$(basename "$p")"
    case " $_eng_names " in *" $name "*) return 0 ;; esac
    _eng_names="$_eng_names $name"
    ENGINES+=("$name:$p")
}
for c in node bun deno; do
    command -v "$c" >/dev/null 2>&1 && add_engine "$(command -v "$c")"
done
for pat in /nix/store/*-nodejs*/bin/node /nix/store/*-bun*/bin/bun /nix/store/*-deno*/bin/deno; do
    for p in $pat; do add_engine "$p"; done
done

if ((${#ENGINES[@]} == 0)); then
    it "pure-JS units"
    skip "no JS engine (node/bun/deno) on PATH or in /nix/store; hint: nix shell nixpkgs#nodejs"
    finish
fi

it "unit sources are present"
assert_file "$SHELLDIR/AppSearch.js" "AppSearch.js"
assert_file "$PORTAL/Commons/BorderGeometry.js" "BorderGeometry.js"

for spec in "${ENGINES[@]}"; do
    eng="${spec%%:*}"; bin="${spec#*:}"
    cmd=("$bin")
    [[ $eng == deno ]] && cmd+=(run --allow-read)
    run "${cmd[@]}" "$TESTS/js/units.js" "$SHELLDIR/AppSearch.js" "$PORTAL/Commons/BorderGeometry.js"

    seen_done=0
    while IFS=$'\t' read -r status name detail; do
        case "$status" in
            PASS) it "$eng: $name"; ok ;;
            FAIL) it "$eng: $name"; bad "${detail:-JS case failed}" ;;
            SKIP) skip "$eng: $name: ${detail:-unsupported in this engine}" ;;
            DONE) seen_done=1 ;;
            *) : ;;
        esac
    done < <(printf '%s\n' "$OUT")

    if ((seen_done == 0)); then
        it "$eng: runner reached DONE"
        bad "no DONE marker: status=$STATUS stderr=[${ERR:0:300}]"
    fi
done

finish
