#!/usr/bin/env bash
# Review ledger: each head SHA is reviewed once, and needs-fix verdicts past
# limits.max_review_rounds hand the PR back to the human instead of looping.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

REMOTE="${TEST_ROOT}/remote.git"
SEED="${TEST_ROOT}/seed"
REPOS="${TEST_ROOT}/repos"
WORKTREES="${TEST_ROOT}/worktrees"
RUNTIME="${TEST_ROOT}/runtime"
MOCK_BIN="${TEST_ROOT}/mock-bin"
GH_LOG="${TEST_ROOT}/gh.log"
REVIEWER_CALLS="${TEST_ROOT}/reviewer-calls"
LEDGER="${RUNTIME}/state/review-rounds/owner_demo-7"
mkdir -p "${REPOS}" "${WORKTREES}" "${RUNTIME}/logs" "${MOCK_BIN}"

git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.email "test@example.invalid"
git -C "${SEED}" config user.name "Review Rounds Test"
printf 'base\n' > "${SEED}/payload.txt"
git -C "${SEED}" add payload.txt
git -C "${SEED}" commit -m "base" >/dev/null
git -C "${SEED}" branch -M main
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push origin main >/dev/null 2>&1
BASE_SHA="$(git -C "${SEED}" rev-parse HEAD)"
git -C "${SEED}" checkout -b feature >/dev/null 2>&1
printf 'change\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "change" >/dev/null
REVIEW_SHA="$(git -C "${SEED}" rev-parse HEAD)"
git -C "${SEED}" push origin feature >/dev/null 2>&1
git --git-dir="${REMOTE}" update-ref refs/pull/7/head "${REVIEW_SHA}"
git clone "${REMOTE}" "${REPOS}/demo" >/dev/null 2>&1

write_config() {
    cat > "${RUNTIME}/triage.toml" <<TOML
[agent]
login = "agent"
human_login = "human"

[limits]
max_review_rounds = ${1}

[cli_chain]
review = ["fake-reviewer"]

[cli_tools.fake-reviewer]
command = "${MOCK_BIN}/fake-reviewer"
args = []
prompt_mode = "stdin"

[[repos]]
name = "owner/demo"
TOML
}

cat > "${MOCK_BIN}/fake-reviewer" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf 'x\n' >> "${REVIEWER_CALLS}"
printf '### Review Summary\n\n**Findings**\n1. Something\n\nVERDICT: needs-fix - something\n'
MOCK

cat > "${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    jq -n --arg head "${REVIEW_SHA}" --arg base "${BASE_SHA}" \
        '{title:"fix",body:"",baseRefName:"main",headRefName:"feature",
          baseRefOid:$base,headRefOid:$head,files:[{path:"payload.txt"}],labels:[],assignees:[],
          isDraft:false,state:"OPEN",mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",
          author:{login:"agent"},closingIssuesReferences:[],
          statusCheckRollup:[{name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}]}'
fi
exit 0
MOCK
chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/fake-reviewer"

export PATH="${MOCK_BIN}:${PATH}"
export GH_LOG REVIEWER_CALLS REVIEW_SHA BASE_SHA
export TRIAGE_DIR="${RUNTIME}"
export TRIAGE_CONFIG="${RUNTIME}/triage.toml"
export TRIAGE_REPOS_DIR="${REPOS}"
export TRIAGE_WORKTREES_DIR="${WORKTREES}"
export TRIAGE_ENABLE_DISPATCH=1

calls() { [[ -f "${REVIEWER_CALLS}" ]] && grep -c . "${REVIEWER_CALLS}" || echo 0; }

# 1. First review of a head: needs-fix requests changes and records the head.
write_config 3
: > "${GH_LOG}"
"${ROOT}/scripts/review.sh" owner/demo 7
[[ "$(calls)" -eq 1 ]]
grep -F "labels[]=changes-requested" "${GH_LOG}" >/dev/null
[[ "$(cat "${LEDGER}")" == "${REVIEW_SHA}" ]]

# 2. Same head again: no reviewer call, no label churn.
: > "${GH_LOG}"
"${ROOT}/scripts/review.sh" owner/demo 7
[[ "$(calls)" -eq 1 ]]
if grep -F "labels[]=" "${GH_LOG}" >/dev/null; then
    echo "re-review of an already reviewed head touched labels" >&2
    exit 1
fi

# 3. Round cap reached: needs-fix hands back to the human as blocked.
write_config 2
printf '%s\n' "0000000000000000000000000000000000000001" > "${LEDGER}"
: > "${GH_LOG}"
"${ROOT}/scripts/review.sh" owner/demo 7
[[ "$(calls)" -eq 2 ]]
grep -F "labels[]=blocked" "${GH_LOG}" >/dev/null
grep -F "assignees[]=human" "${GH_LOG}" >/dev/null
if grep -F "labels[]=changes-requested" "${GH_LOG}" >/dev/null; then
    echo "round cap still requested another fix iteration" >&2
    exit 1
fi
[[ ! -e "${LEDGER}" ]]

echo "review round tests passed"
