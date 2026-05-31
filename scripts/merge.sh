#!/usr/bin/env bash
# triage/merge.sh REPO PR_NUMBER
# Auto-merge approved PRs if automerge is enabled.
set -euo pipefail

REPO="${1:?repo required}"
NUM="${2:?pr number required}"

CONF_FILE="${TRIAGE_CONFIG:-/srv/wulfai/triage/triage.toml}"
AUTOMERGE="false"
if [[ -f "${CONF_FILE}" ]]; then
    AUTOMERGE=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(any(r.get('name') == sys.argv[2] and r.get('automerge', False) for r in d.get('repos', [])))" "${CONF_FILE}" "${REPO}" 2>/dev/null || echo "false")
fi

if [[ "${AUTOMERGE}" != "True" && "${AUTOMERGE}" != "true" ]]; then
    echo "==> triage/merge disabled for ${REPO}#${NUM}; human owner merges manually"
    exit 0
fi

echo "==> triage/merge auto-merging ${REPO}#${NUM}..."
gh pr merge "${NUM}" -R "${REPO}" --squash --auto
