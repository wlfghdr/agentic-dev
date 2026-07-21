#!/usr/bin/env bash
# scripts/dependabot_merge.sh [--rebase] REPO PR_NUMBER
# Deterministically merge green Dependabot PRs. If a PR is behind/conflicting,
# reuse the existing rebase path first; that path only calls an agent on real
# conflicts.
set -euo pipefail

MODE="merge"
case "${1:-}" in
    --rebase) MODE="rebase"; shift ;;
esac

REPO="${1:?repo required}"
NUM="${2:?pr number required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
LOGDIR="${TRIAGE_DIR}/logs"
REPO_NAME="${REPO##*/}"
LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-dependabot-${REPO_NAME}-${NUM}.log"
DEPENDABOT_LOGIN="${TRIAGE_DEPENDABOT_LOGIN:-dependabot[bot]}"
DEPENDABOT_APP_LOGIN="${TRIAGE_DEPENDABOT_APP_LOGIN:-app/dependabot}"
HUMAN_LOGIN="${TRIAGE_HUMAN_LOGIN:-human-login}"

mkdir -p "${LOGDIR}"
exec >"${LOG}" 2>&1

echo "==> triage/dependabot: ${REPO}#${NUM} (${MODE})"

if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
    echo "==> DRY RUN — would validate and merge Dependabot PR"
    exit 0
fi

repo_automerge() {
    python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.dependabot_automerge" "${REPO}" 2>/dev/null || echo "false"
}

add_label() {
    gh api -X POST "repos/${1}/issues/${2}/labels" -f "labels[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to add label '${3}' to ${1}#${2}" >&2
}

add_assignee() {
    gh api -X POST "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to add assignee '${3}' to ${1}#${2}" >&2
}

block_for_workflow_scope() {
    local body
    body="Dependabot auto-merge blocked: GitHub refused the merge because this token does not have the \`workflow\` scope required to update workflow files. Re-authenticate the automation token with workflow permission, then remove \`blocked\` to let the loop retry."
    echo "==> Dependabot merge requires GitHub token workflow scope; handing back to ${HUMAN_LOGIN}"
    add_label "${REPO}" "${NUM}" "blocked"
    add_assignee "${REPO}" "${NUM}" "${HUMAN_LOGIN}"
    gh pr comment "${NUM}" -R "${REPO}" --body "${body}" >/dev/null 2>&1 || true
}

if [[ -f "${CONF_FILE}" ]]; then
    CONF_HUMAN=$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "agent.human_login" 2>/dev/null || true)
    if [[ -n "${CONF_HUMAN}" ]]; then HUMAN_LOGIN="${CONF_HUMAN}"; fi
fi

global_enabled="$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "dependabot.enabled" 2>/dev/null || echo "false")"
if [[ "${global_enabled}" != "True" && "${global_enabled}" != "true" ]]; then
    echo "==> Dependabot automerge globally disabled"
    exit 0
fi

enabled="$(repo_automerge)"
if [[ "${enabled}" == "False" || "${enabled}" == "false" ]]; then
    echo "==> Dependabot automerge disabled for ${REPO}"
    exit 0
fi

PR_JSON="$(gh pr view "${NUM}" -R "${REPO}" --json author,isDraft,mergeStateStatus,mergeable,statusCheckRollup,labels,title,url,headRefOid)"
AUTHOR="$(echo "${PR_JSON}" | jq -r '.author.login // ""')"
if [[ "${AUTHOR}" != "${DEPENDABOT_LOGIN}" && "${AUTHOR}" != "${DEPENDABOT_APP_LOGIN}" ]]; then
    echo "FATAL: refusing to merge non-Dependabot PR authored by ${AUTHOR}" >&2
    exit 3
fi

if [[ "$(echo "${PR_JSON}" | jq -r '.isDraft')" == "true" ]]; then
    echo "==> Dependabot PR is draft; nothing to merge"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '.labels[].name | select(. == "blocked" or . == "do-not-merge")' >/dev/null; then
    echo "==> Dependabot PR has blocked/do-not-merge label; skipping"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '(.statusCheckRollup // []) | length == 0' >/dev/null; then
    echo "==> Dependabot PR has no checks; skipping"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")' >/dev/null; then
    echo "==> Dependabot PR has red checks; skipping"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING" or .status == "WAITING")' >/dev/null; then
    echo "==> Dependabot PR has pending checks; skipping"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.status != "COMPLETED" or ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))' >/dev/null; then
    echo "==> Dependabot PR has non-successful checks; skipping"
    exit 0
fi

merge_state="$(echo "${PR_JSON}" | jq -r '.mergeStateStatus // ""' | tr '[:lower:]' '[:upper:]')"
mergeable="$(echo "${PR_JSON}" | jq -r '.mergeable // ""' | tr '[:lower:]' '[:upper:]')"
if [[ "${MODE}" == "rebase" || "${merge_state}" == "BEHIND" || "${merge_state}" == "DIRTY" || "${mergeable}" == "CONFLICTING" ]]; then
    echo "==> Dependabot PR needs rebase before merge"
    "${SCRIPT_DIR}/engineer.sh" --rebase "${REPO}" "${NUM}"
    echo "==> rebase pushed; waiting for the next tick to observe fresh CI"
    exit 0
fi

HEAD_SHA="$(echo "${PR_JSON}" | jq -r '.headRefOid // ""')"
echo "==> merging Dependabot PR with squash at ${HEAD_SHA}"
MERGE_OUTPUT="$(mktemp)"
if gh pr merge "${NUM}" -R "${REPO}" --squash --delete-branch --match-head-commit "${HEAD_SHA}" >"${MERGE_OUTPUT}" 2>&1; then
    cat "${MERGE_OUTPUT}"
    rm -f "${MERGE_OUTPUT}"
    echo "==> merged Dependabot PR ${REPO}#${NUM}"
else
    cat "${MERGE_OUTPUT}"
    if grep -qiE 'workflow.*scope|without `?workflow`? scope|without workflow scope' "${MERGE_OUTPUT}"; then
        rm -f "${MERGE_OUTPUT}"
        block_for_workflow_scope
        exit 0
    fi
    rm -f "${MERGE_OUTPUT}"
    echo "==> direct Dependabot merge failed; not enabling persistent auto-merge"
fi
