#!/usr/bin/env bash
# tests/run-all.sh — run every tests/*.test.sh suite and aggregate.
#
#   tests/run-all.sh            # all suites
#   tests/run-all.sh cli bins   # only suites whose filename contains these words
#
# Exit status: 0 only if every suite passed. Suites print their own summary;
# this only aggregates, so a failing suite's detail is still visible above.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

suites=()
for f in "$here"/*.test.sh; do
    [[ -f $f ]] || continue
    if (($#)); then
        for want in "$@"; do
            [[ $(basename "$f") == *"$want"* ]] && { suites+=("$f"); break; }
        done
    else
        suites+=("$f")
    fi
done

if ((${#suites[@]} == 0)); then
    echo "no suites matched: $*" >&2
    exit 1
fi

failed=()
for s in "${suites[@]}"; do
    if bash "$s"; then
        :
    else
        failed+=("$(basename "$s")")
    fi
done

echo
echo "=============================================="
if ((${#failed[@]})); then
    printf 'SUITES FAILED (%d/%d): %s\n' "${#failed[@]}" "${#suites[@]}" "${failed[*]}"
    exit 1
fi
printf 'ALL %d SUITES PASSED\n' "${#suites[@]}"
