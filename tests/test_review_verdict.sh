#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

verdict_helper="${TMPDIR_TEST}/review_verdict.sh"
sed -n '/^review_verdict_is_valid()/,/^}/p' "${ROOT}/scripts/review.sh" > "${verdict_helper}"
# shellcheck source=/dev/null
source "${verdict_helper}"

for verdict in \
    'VERDICT: merge-ready' \
    'VERDICT: needs-fix - reason' \
    'VERDICT: blocked - reason'; do
    review_verdict_is_valid "${verdict}"
done

for line in \
    '' \
    'Please let me know if there is anything else you need!' \
    'VERDICT merge-ready' \
    'VERDICT: approved' \
    'VERDICT: merge-ready-ish' \
    'VERDICT: needs-fix' \
    'VERDICT: needs-fix reason' \
    'VERDICT: needs-fix - ' \
    'VERDICT: blocked unexpectedly' \
    'VERDICT: blocked - '; do
    if review_verdict_is_valid "${line}"; then
        echo "invalid review verdict accepted: ${line}" >&2
        exit 1
    fi
done

echo "review verdict tests passed"
