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
# The runner (tests/js/units.js) strips `.pragma` and evaluates each file in-process — no npm, no QML.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
suite js

# ---- discover a JS runtime (node | bun | deno) ----------------------------------
JS=""
for c in node bun deno; do
    if command -v "$c" >/dev/null 2>&1; then JS="$(command -v "$c")"; break; fi
done
if [[ -z $JS ]]; then
    for c in /nix/store/*-nodejs*/bin/node /nix/store/*-deno*/bin/deno /nix/store/*-bun*/bin/bun; do
        if [[ -x $c ]]; then JS="$c"; break; fi
    done
fi
if [[ -z $JS ]]; then
    it "pure-JS unit suites"
    skip "no JS runtime (node/bun/deno) on PATH or in /nix/store; hint: nix shell nixpkgs#nodejs"
    finish
fi

RUNNER=("$JS")
case "$(basename "$JS")" in
    deno) RUNNER+=("run" "--allow-read") ;;
esac

it "unit sources are present"
assert_file "$SHELLDIR/AppSearch.js" "AppSearch.js"
assert_file "$PORTAL/Commons/BorderGeometry.js" "BorderGeometry.js"

run "${RUNNER[@]}" "$TESTS/js/units.js" "$SHELLDIR/AppSearch.js" "$PORTAL/Commons/BorderGeometry.js"

seen_done=0
while IFS=$'\t' read -r status name detail; do
    case "$status" in
        PASS) it "$name"; ok ;;
        FAIL) it "$name"; bad "${detail:-JS case failed}" ;;
        SKIP) skip "$name: ${detail:-unsupported in this runtime}" ;;
        DONE) seen_done=1 ;;
        *) : ;;
    esac
done < <(printf '%s\n' "$OUT")

if ((seen_done == 0)); then
    it "JS runner completed ($(basename "$JS"))"
    bad "no DONE marker: status=$STATUS stderr=[${ERR:0:300}]"
fi

finish
