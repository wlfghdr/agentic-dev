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

mkdir -p "${LOGDIR}"
exec >"${LOG}" 2>&1

echo "==> triage/dependabot: ${REPO}#${NUM} (${MODE})"

if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
    echo "==> DRY RUN — would validate and merge Dependabot PR"
    exit 0
fi

repo_automerge() {
    python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.dependabot_automerge" "${REPO}" 2>/dev/null || echo "true"
}

enabled="$(repo_automerge)"
if [[ "${enabled}" == "False" || "${enabled}" == "false" ]]; then
    echo "==> Dependabot automerge disabled for ${REPO}"
    exit 0
fi

PR_JSON="$(gh pr view "${NUM}" -R "${REPO}" --json author,isDraft,mergeStateStatus,mergeable,statusCheckRollup,labels,title,url)"
AUTHOR="$(echo "${PR_JSON}" | jq -r '.author.login // ""')"
if [[ "${AUTHOR}" != "${DEPENDABOT_LOGIN}" ]]; then
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

if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT")' >/dev/null; then
    echo "==> Dependabot PR has red checks; skipping"
    exit 0
fi

if echo "${PR_JSON}" | jq -e '.statusCheckRollup[]? | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING" or .status == "WAITING")' >/dev/null; then
    echo "==> Dependabot PR has pending checks; skipping"
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

echo "==> merging Dependabot PR with squash"
if gh pr merge "${NUM}" -R "${REPO}" --squash --delete-branch; then
    echo "==> merged Dependabot PR ${REPO}#${NUM}"
else
    echo "==> direct merge failed; enabling auto-merge if branch protection is waiting"
    gh pr merge "${NUM}" -R "${REPO}" --squash --auto --delete-branch
fi
