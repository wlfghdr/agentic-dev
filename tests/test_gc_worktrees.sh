#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

RUNTIME="${TEST_ROOT}/runtime"
REPOS="${TEST_ROOT}/repos"
WORKTREES="${TEST_ROOT}/worktrees"
MOCK_BIN="${TEST_ROOT}/mock-bin"
mkdir -p "${RUNTIME}/state/locks" "${REPOS}" "${WORKTREES}" "${MOCK_BIN}"

cat > "${RUNTIME}/triage.toml" <<'TOML'
[[repos]]
name = "acme/App"
TOML

git init -q "${REPOS}/App"
git -C "${REPOS}/App" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
for spec in "App-1:agentic-dev/issue-1" "App-2:agentic-dev/issue-2" "App-pr-3:pr-3-fix" "App-pr-4:pr-4-fix" "App-5:agentic-dev/issue-5" "App-6:agentic-dev/issue-6"; do
    git -C "${REPOS}/App" worktree add -q -b "${spec#*:}" "${WORKTREES}/${spec%%:*}"
done
mkdir -p "${WORKTREES}/unrelated-dir"
touch -t 202001010000 "${WORKTREES}"/*

# 1 closed, 2 open, PR 3 merged, PR 4 closed but locked, 5 closed with open PR,
# 6 closed but touched recently.
touch "${RUNTIME}/state/locks/review-acme_App-4.lock"
touch "${WORKTREES}/App-6"

cat > "${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    "issue view 1 -R acme/App --json state --jq .state // \"\"") echo CLOSED ;;
    "issue view 2 -R acme/App --json state --jq .state // \"\"") echo OPEN ;;
    "pr view 3 -R acme/App --json state --jq .state // \"\"") echo MERGED ;;
    "issue view 5 -R acme/App --json state --jq .state // \"\"") echo CLOSED ;;
    "issue view 6 -R acme/App --json state --jq .state // \"\"") echo CLOSED ;;
    "pr list -R acme/App --head agentic-dev/issue-1 --state open --json number --jq length") echo 0 ;;
    "pr list -R acme/App --head agentic-dev/issue-5 --state open --json number --jq length") echo 1 ;;
    *) echo "unexpected gh args: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "${MOCK_BIN}/gh"

PATH="${MOCK_BIN}:${PATH}" \
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_REPOS_DIR="${REPOS}" \
TRIAGE_WORKTREES_DIR="${WORKTREES}" \
"${ROOT}/scripts/gc_worktrees.sh"

[[ ! -e "${WORKTREES}/App-1" && ! -e "${WORKTREES}/App-pr-3" ]]
[[ -d "${WORKTREES}/App-2" && -d "${WORKTREES}/App-pr-4" && -d "${WORKTREES}/App-5" && -d "${WORKTREES}/App-6" && -d "${WORKTREES}/unrelated-dir" ]]
for ref in agentic-dev/issue-1 pr-3-fix; do
    if git -C "${REPOS}/App" rev-parse -q --verify "refs/heads/${ref}" >/dev/null; then
        echo "branch ${ref} survived worktree gc" >&2
        exit 1
    fi
done
git -C "${REPOS}/App" rev-parse -q --verify refs/heads/agentic-dev/issue-2 >/dev/null
[[ "$(git -C "${REPOS}/App" worktree list | wc -l)" -eq 5 ]]

echo "worktree gc tests passed"
