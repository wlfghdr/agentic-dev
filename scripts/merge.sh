#!/usr/bin/env bash
# scripts/merge.sh REPO PR_NUMBER REVIEWED_HEAD_SHA
# Auto-merge an approved PR only if it is still the reviewed revision.
set -euo pipefail

REPO="${1:?repo required}"
NUM="${2:?pr number required}"
REVIEWED_HEAD_SHA="${3:?reviewed head SHA required}"

if [[ ! "${REVIEWED_HEAD_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "FATAL: reviewed head must be a full commit SHA" >&2
    exit 2
fi

CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR:-/srv/agentic-dev}/triage.toml}"
AUTOMERGE="false"
if [[ -f "${CONF_FILE}" ]]; then
    AUTOMERGE=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "repos.automerge" "${REPO}" 2>/dev/null || echo "false")
fi

if [[ "${AUTOMERGE}" != "True" && "${AUTOMERGE}" != "true" ]]; then
    echo "==> triage/merge disabled for ${REPO}#${NUM}; human owner merges manually"
    exit 0
fi

remove_approved() {
    local output
    if output=$(gh api -X DELETE "repos/${REPO}/issues/${NUM}/labels/approved" 2>&1); then
        return 0
    fi
    if grep -qiE 'HTTP 404|Not Found' <<<"${output}"; then
        return 0
    fi
    echo "WARN: could not ensure approved was absent from ${REPO}#${NUM}" >&2
    return 1
}

if ! PR_JSON=$(gh pr view "${NUM}" -R "${REPO}" --json headRefOid,statusCheckRollup,labels,isDraft,state,mergeStateStatus,mergeable); then
    echo "==> unable to refresh merge eligibility; removing approved state"
    remove_approved
    exit 1
fi

HEAD_SHA="$(echo "${PR_JSON}" | jq -r '.headRefOid // ""')"
if [[ "${HEAD_SHA}" != "${REVIEWED_HEAD_SHA}" ]]; then
    echo "==> PR head changed after review; removing approved state"
    remove_approved
    exit 0
fi
if [[ "$(echo "${PR_JSON}" | jq -r '.state // ""')" != "OPEN" ]] || \
   [[ "$(echo "${PR_JSON}" | jq -r '.isDraft // false')" == "true" ]]; then
    echo "==> PR is not open and ready; removing approved state"
    remove_approved
    exit 0
fi
if echo "${PR_JSON}" | jq -e '.labels[]?.name | select(. == "blocked" or . == "do-not-merge" or . == "do-not-work")' >/dev/null; then
    echo "==> PR has a human stop label; removing approved state"
    remove_approved
    exit 0
fi
if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.status != "COMPLETED" or ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))' >/dev/null; then
    echo "==> PR checks are pending, red, or unknown; removing approved state"
    remove_approved
    exit 0
fi
merge_state="$(echo "${PR_JSON}" | jq -r '.mergeStateStatus // ""' | tr '[:lower:]' '[:upper:]')"
mergeable="$(echo "${PR_JSON}" | jq -r '.mergeable // ""' | tr '[:lower:]' '[:upper:]')"
if [[ "${merge_state}" == "BEHIND" || "${merge_state}" == "DIRTY" || "${mergeable}" == "CONFLICTING" ]]; then
    echo "==> PR is behind or conflicting; removing approved state"
    remove_approved
    exit 0
fi

echo "==> triage/merge auto-merging ${REPO}#${NUM} at ${REVIEWED_HEAD_SHA}..."
if ! gh pr merge "${NUM}" -R "${REPO}" --squash --auto --match-head-commit "${REVIEWED_HEAD_SHA}"; then
    echo "==> merge publication failed; removing approved state"
    remove_approved
    exit 1
fi
