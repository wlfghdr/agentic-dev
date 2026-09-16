#!/usr/bin/env bash
# scripts/merge.sh REPO PR_NUMBER REVIEWED_HEAD_SHA REVIEWED_BASE_SHA
# Auto-merge an approved PR only if its reviewed head and base are unchanged.
set -euo pipefail

REPO="${1:?repo required}"
NUM="${2:?pr number required}"
REVIEWED_HEAD_SHA="${3:?reviewed head SHA required}"
REVIEWED_BASE_SHA="${4:?reviewed base SHA required}"

if [[ ! "${REVIEWED_HEAD_SHA}" =~ ^[0-9a-fA-F]{40}$ || \
      ! "${REVIEWED_BASE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "FATAL: reviewed head and base must be full commit SHAs" >&2
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

if ! PR_JSON=$(gh pr view "${NUM}" -R "${REPO}" --json headRefOid,baseRefOid,statusCheckRollup,labels,isDraft,state,mergeStateStatus,mergeable); then
    echo "==> unable to refresh merge eligibility; removing approved state"
    remove_approved
    exit 1
fi

HEAD_SHA="$(echo "${PR_JSON}" | jq -r '.headRefOid // ""')"
BASE_SHA="$(echo "${PR_JSON}" | jq -r '.baseRefOid // ""')"
if [[ "${HEAD_SHA}" != "${REVIEWED_HEAD_SHA}" || "${BASE_SHA}" != "${REVIEWED_BASE_SHA}" ]]; then
    echo "==> PR head or base changed after review; removing approved state"
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
if ! echo "${PR_JSON}" | jq -e '
    (.statusCheckRollup | type == "array" and length > 0) and
    all(.statusCheckRollup[];
        (.status == "COMPLETED" and
         ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED"))) or
        ((.state // "") == "SUCCESS"))
' >/dev/null; then
    echo "==> PR checks are missing, pending, red, or unknown; removing approved state"
    remove_approved
    exit 0
fi
merge_state="$(echo "${PR_JSON}" | jq -r '.mergeStateStatus // ""' | tr '[:lower:]' '[:upper:]')"
mergeable="$(echo "${PR_JSON}" | jq -r '.mergeable // ""' | tr '[:lower:]' '[:upper:]')"
if [[ "${merge_state}" == "" || "${merge_state}" == "UNKNOWN" || \
      "${merge_state}" == "BEHIND" || "${merge_state}" == "DIRTY" || \
      "${mergeable}" != "MERGEABLE" ]]; then
    echo "==> PR mergeability is unknown, behind, or conflicting; removing approved state"
    remove_approved
    exit 0
fi

echo "==> triage/merge auto-merging ${REPO}#${NUM} at ${REVIEWED_HEAD_SHA}..."
if ! gh pr merge "${NUM}" -R "${REPO}" --squash --auto --match-head-commit "${REVIEWED_HEAD_SHA}"; then
    echo "==> merge publication failed; removing approved state"
    remove_approved
    exit 1
fi
