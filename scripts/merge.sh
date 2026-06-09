#!/usr/bin/env bash
# scripts/merge.sh REPO PR_NUMBER
# Auto-merge approved PRs if automerge is enabled.
set -euo pipefail

REPO="${1:?repo required}"
NUM="${2:?pr number required}"

CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR:-/srv/agentic-dev}/triage.toml}"
AUTOMERGE="false"
if [[ -f "${CONF_FILE}" ]]; then
    AUTOMERGE=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "repos.automerge" "${REPO}" 2>/dev/null || echo "false")
fi

if [[ "${AUTOMERGE}" != "True" && "${AUTOMERGE}" != "true" ]]; then
    echo "==> triage/merge disabled for ${REPO}#${NUM}; human owner merges manually"
    exit 0
fi

echo "==> triage/merge auto-merging ${REPO}#${NUM}..."
gh pr merge "${NUM}" -R "${REPO}" --squash --auto
