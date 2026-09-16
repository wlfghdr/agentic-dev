#!/usr/bin/env bash
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
VIEW_COUNT="${TEST_ROOT}/view-count"
mkdir -p "${REPOS}" "${WORKTREES}" "${RUNTIME}/logs" "${MOCK_BIN}"

git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.email "test@example.invalid"
git -C "${SEED}" config user.name "Review Freshness Test"
printf 'base\n' > "${SEED}/payload.txt"
git -C "${SEED}" add payload.txt
git -C "${SEED}" commit -m "base" >/dev/null
git -C "${SEED}" branch -M main
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push origin main >/dev/null
BASE_SHA="$(git -C "${SEED}" rev-parse HEAD)"

git -C "${SEED}" checkout -b feature >/dev/null
printf 'reviewed\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "reviewed head" >/dev/null
REVIEW_SHA="$(git -C "${SEED}" rev-parse HEAD)"
git -C "${SEED}" push origin feature >/dev/null
git --git-dir="${REMOTE}" update-ref refs/pull/7/head "${REVIEW_SHA}"

printf 'changed\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "changed head" >/dev/null
CHANGED_SHA="$(git -C "${SEED}" rev-parse HEAD)"
git clone "${REMOTE}" "${REPOS}/demo" >/dev/null 2>&1

cat > "${RUNTIME}/triage.toml" <<TOML
[agent]
login = "agent"
human_login = "human"

[cli_chain]
review = ["fake-reviewer"]

[cli_tools.fake-reviewer]
command = "${MOCK_BIN}/fake-reviewer"
args = []
prompt_mode = "stdin"

[[repos]]
name = "owner/demo"
automerge = true
TOML

cat > "${MOCK_BIN}/fake-reviewer" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '### Review Summary\n\n**Findings**\n1. None\n\n**Checks Run**\n- fixture: pass\n\nVERDICT: merge-ready\n'
MOCK

cat > "${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"

if [[ "${1:-}" == "label" && "${2:-}" == "create" ]]; then
    exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    count=0
    [[ -f "${VIEW_COUNT}" ]] && count="$(<"${VIEW_COUNT}")"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${VIEW_COUNT}"
    head="${REVIEW_SHA}"
    status="COMPLETED"
    conclusion="SUCCESS"
    if (( count > 1 )); then
        case "${TEST_MODE}" in
            head-change) head="${CHANGED_SHA}" ;;
            red) conclusion="FAILURE" ;;
            pending) status="IN_PROGRESS"; conclusion="" ;;
        esac
    fi
    jq -n \
        --arg head "${head}" --arg base "${BASE_SHA}" \
        --arg status "${status}" --arg conclusion "${conclusion}" \
        '{title:"fix: safe review",body:"Closes #27",baseRefName:"main",headRefName:"feature",
          baseRefOid:$base,headRefOid:$head,files:[{path:"payload.txt"}],labels:[],assignees:[],
          isDraft:false,state:"OPEN",mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",
          author:{login:"contributor"},closingIssuesReferences:[{number:27}],
          statusCheckRollup:[{name:"ci",status:$status,conclusion:$conclusion}]}'
    exit 0
fi

if [[ "${1:-}" == "api" ]]; then
    if [[ "$*" == *"/reviews"* && "${TEST_MODE}" == "api-failure" ]]; then
        exit 1
    fi
    exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
    if [[ "${TEST_MODE}" == "merge-failure" ]]; then
        exit 1
    fi
    exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 99
MOCK
chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/fake-reviewer"

export PATH="${MOCK_BIN}:${PATH}"
export GH_LOG VIEW_COUNT REVIEW_SHA BASE_SHA CHANGED_SHA
export TRIAGE_DIR="${RUNTIME}"
export TRIAGE_CONFIG="${RUNTIME}/triage.toml"
export TRIAGE_REPOS_DIR="${REPOS}"
export TRIAGE_WORKTREES_DIR="${WORKTREES}"
export TRIAGE_ENABLE_DISPATCH=1

run_case() {
    TEST_MODE="${1}"
    export TEST_MODE
    : > "${GH_LOG}"
    printf '0\n' > "${VIEW_COUNT}"
    "${ROOT}/scripts/review.sh" owner/demo 7 || true

    if [[ "${TEST_MODE}" == "stable" ]]; then
        grep -F "commit_id=${REVIEW_SHA}" "${GH_LOG}" >/dev/null
        grep -F "event=APPROVE" "${GH_LOG}" >/dev/null
        grep -F "labels[]=approved" "${GH_LOG}" >/dev/null
        grep -F "pr merge 7 -R owner/demo --squash --auto --match-head-commit ${REVIEW_SHA}" "${GH_LOG}" >/dev/null
    elif [[ "${TEST_MODE}" == "merge-failure" ]]; then
        grep -F "labels[]=approved" "${GH_LOG}" >/dev/null
        grep -F "pr merge 7 -R owner/demo --squash --auto --match-head-commit ${REVIEW_SHA}" "${GH_LOG}" >/dev/null
        [[ "$(grep -E 'labels\[\]=approved|labels/approved' "${GH_LOG}" | tail -n 1)" == \
            "api -X DELETE repos/owner/demo/issues/7/labels/approved" ]]
    else
        if grep -F "labels[]=approved" "${GH_LOG}" >/dev/null; then
            echo "${TEST_MODE}: published approved state" >&2
            exit 1
        fi
        if grep -F "pr merge" "${GH_LOG}" >/dev/null; then
            echo "${TEST_MODE}: attempted merge" >&2
            exit 1
        fi
    fi
}

run_case head-change
run_case red
run_case pending
run_case api-failure
run_case merge-failure
run_case stable

echo "review freshness tests passed"
