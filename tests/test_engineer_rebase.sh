#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

REMOTE="${TEST_ROOT}/app.git"
SEED="${TEST_ROOT}/seed"
REPOS="${TEST_ROOT}/repos"
WORKTREES="${TEST_ROOT}/worktrees"
RUNTIME="${TEST_ROOT}/runtime"
MOCK_BIN="${TEST_ROOT}/mock-bin"

mkdir -p "${REPOS}" "${WORKTREES}" "${RUNTIME}/logs" "${MOCK_BIN}"
git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.email "test@example.invalid"
git -C "${SEED}" config user.name "Rebase Test"
printf 'base\n' > "${SEED}/base.txt"
git -C "${SEED}" add base.txt
git -C "${SEED}" commit -m "chore: base" >/dev/null
git -C "${SEED}" branch -M main
git -C "${SEED}" checkout -b pr-head >/dev/null
printf 'pr change\n' > "${SEED}/pr.txt"
git -C "${SEED}" add pr.txt
git -C "${SEED}" commit -m "fix: dependency update" >/dev/null
git -C "${SEED}" checkout main >/dev/null
printf 'main advanced\n' > "${SEED}/main.txt"
git -C "${SEED}" add main.txt
git -C "${SEED}" commit -m "feat: advance main" >/dev/null
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push origin main pr-head >/dev/null
git --git-dir="${REMOTE}" symbolic-ref HEAD refs/heads/main
git clone "${REMOTE}" "${REPOS}/app" >/dev/null 2>&1
git -C "${REPOS}/app" config user.email "agent@example.invalid"
git -C "${REPOS}/app" config user.name "Rebase Agent"

cat > "${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    pr\ view\ 10\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"title":"fix: dependency update","body":"Closes #1","baseRefName":"main","headRefName":"pr-head","headRepositoryOwner":{"login":"acme"},"url":"https://example.invalid/pr/10","reviewDecision":"","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","statusCheckRollup":[],"reviews":[],"comments":[],"files":[],"labels":[],"commits":[],"closingIssuesReferences":[{"number":1}]}
JSON
        ;;
    label\ create*) ;;
    pr\ comment\ 10\ -R\ acme/app\ --body*) printf '%s\n' "$*" >> "${GH_CALLS}" ;;
    *) echo "unexpected gh args: $*" >&2; exit 99 ;;
esac
MOCK

cat > "${MOCK_BIN}/must-not-run-agent" <<'MOCK'
#!/usr/bin/env bash
touch "${AGENT_RAN_MARKER}"
exit 99
MOCK
chmod +x "${MOCK_BIN}/"*

cat > "${RUNTIME}/triage.toml" <<TOML
[agent]
login = "agent"
human_login = "human"

[cli_chain]
rebase = ["must-not-run"]

[cli_tools.must-not-run]
command = "${MOCK_BIN}/must-not-run-agent"
args = []
prompt_mode = "stdin"
TOML

export PATH="${MOCK_BIN}:${PATH}"
export TRIAGE_ENABLE_DISPATCH=1
export TRIAGE_DIR="${RUNTIME}"
export TRIAGE_CONFIG="${RUNTIME}/triage.toml"
export TRIAGE_REPOS_DIR="${REPOS}"
export TRIAGE_WORKTREES_DIR="${WORKTREES}"
export GH_CALLS="${TEST_ROOT}/gh-calls.log"
export AGENT_RAN_MARKER="${TEST_ROOT}/agent-ran"

old_head="$(git --git-dir="${REMOTE}" rev-parse refs/heads/pr-head)"
main_head="$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)"
"${ROOT}/scripts/engineer.sh" --rebase acme/app 10
new_head="$(git --git-dir="${REMOTE}" rev-parse refs/heads/pr-head)"

[[ "${new_head}" != "${old_head}" ]]
git --git-dir="${REMOTE}" merge-base --is-ancestor "${main_head}" "${new_head}"
grep -Fx 'pr change' <(git --git-dir="${REMOTE}" show "${new_head}:pr.txt")
grep -Fx 'main advanced' <(git --git-dir="${REMOTE}" show "${new_head}:main.txt")
[[ ! -e "${AGENT_RAN_MARKER}" ]]
grep -Fq 'Auto-rebased onto `main` (pr-head).' "${GH_CALLS}"

echo "engineer rebase tests passed"
