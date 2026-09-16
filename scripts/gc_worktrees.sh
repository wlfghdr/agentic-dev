#!/usr/bin/env bash
# scripts/gc_worktrees.sh — remove dispatch worktrees whose issue or PR is closed.
# Worktrees are named <repo>-<issue> or <repo>-pr-<pr> by engineer.sh/review.sh
# and are otherwise never removed, so every finished item leaks a checkout.
set -euo pipefail

TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
WORKTREES_DIR="${TRIAGE_WORKTREES_DIR:-/srv/agentic-dev/../worktrees}"
REPOS_DIR="${TRIAGE_REPOS_DIR:-/srv/agentic-dev/../repos}"
LOCKS="${TRIAGE_DIR}/state/locks"
MIN_AGE_MINUTES="${TRIAGE_WORKTREE_GC_MIN_AGE_MINUTES:-60}"

[[ -d "${WORKTREES_DIR}" && -f "${CONF_FILE}" ]] || exit 0

WATCH_REPOS=()
while IFS= read -r repo; do
    [[ -n "${repo}" ]] && WATCH_REPOS+=("${repo}")
done < <(python3 - "${CONF_FILE}" <<'PY'
import re, sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as f:
        repos = [r.get("name", "") for r in tomllib.load(f).get("repos", [])]
except ImportError:
    text = open(sys.argv[1], encoding="utf-8").read()
    repos = re.findall(r'^\s*name\s*=\s*"([^"]+/[^"]+)"', text, re.M)
print("\n".join(repos))
PY
)

item_state() {
    # item_state KIND REPO NUMBER — prints OPEN/CLOSED/MERGED or nothing.
    gh "${1}" view "${3}" -R "${2}" --json state --jq '.state // ""' 2>/dev/null || true
}

removed=0
shopt -s nullglob
for wt in "${WORKTREES_DIR}"/*/; do
    wt="${wt%/}"
    name="$(basename "${wt}")"
    if [[ "${name}" =~ ^(.+)-pr-([0-9]+)$ ]]; then
        kind="pr"
    elif [[ "${name}" =~ ^(.+)-([0-9]+)$ ]]; then
        kind="issue"
    else
        continue
    fi
    repo_name="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"

    repo=""
    for candidate in "${WATCH_REPOS[@]}"; do
        if [[ "$(tr '[:upper:]' '[:lower:]' <<<"${candidate##*/}")" == "$(tr '[:upper:]' '[:lower:]' <<<"${repo_name}")" ]]; then
            repo="${candidate}"
            break
        fi
    done
    [[ -n "${repo}" ]] || continue

    # In-flight or backed-off items keep their checkout.
    locks=("${LOCKS}"/*-"${repo//\//_}"-"${num}".lock)
    (( ${#locks[@]} == 0 )) || continue
    [[ -z "$(find "${wt}" -maxdepth 0 -mmin -"${MIN_AGE_MINUTES}")" ]] || continue

    state="$(item_state "${kind}" "${repo}" "${num}")"
    [[ "${state}" == "CLOSED" || "${state}" == "MERGED" ]] || continue

    branch="$(git -C "${wt}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [[ "${kind}" == "issue" && -n "${branch}" ]]; then
        # A PR may still be iterating on the issue branch after a manual close.
        open_prs="$(gh pr list -R "${repo}" --head "${branch}" --state open --json number --jq 'length' 2>/dev/null || echo 1)"
        [[ "${open_prs}" == "0" ]] || continue
    fi

    local_repo="${REPOS_DIR}/${repo_name}"
    echo "==> gc ${repo}#${num} (${kind} ${state}): ${wt}"
    if ! git -C "${local_repo}" worktree remove --force "${wt}" 2>/dev/null; then
        echo "WARN: could not remove worktree ${wt}" >&2
        continue
    fi
    if [[ -n "${branch}" ]] && [[ "${branch}" == agentic-dev/* || "${branch}" == wlfg-agent/* || "${branch}" == pr-*-fix ]]; then
        git -C "${local_repo}" branch -D "${branch}" >/dev/null 2>&1 || true
    fi
    removed=$((removed + 1))
done

for repo in "${WATCH_REPOS[@]}"; do
    [[ -d "${REPOS_DIR}/${repo##*/}/.git" ]] && git -C "${REPOS_DIR}/${repo##*/}" worktree prune || true
done

echo "==> worktree gc removed ${removed} worktree(s)"
