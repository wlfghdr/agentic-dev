#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

RUNTIME="${TEST_ROOT}/runtime"
REPOS="${TEST_ROOT}/repos"
WORKTREES="${TEST_ROOT}/worktrees"
MOCK_BIN="${TEST_ROOT}/mock-bin"
REMOTE="${TEST_ROOT}/app.git"
LOCAL="${REPOS}/app"
GH_API_LOG="${TEST_ROOT}/gh-api.log"

mkdir -p "${RUNTIME}/logs" "${REPOS}" "${WORKTREES}" "${MOCK_BIN}"
git init --bare "${REMOTE}" >/dev/null
git clone "${REMOTE}" "${LOCAL}" >/dev/null 2>&1
git -C "${LOCAL}" config user.email "test@example.invalid"
git -C "${LOCAL}" config user.name "Review Test"
printf 'fixture\n' > "${LOCAL}/fixture.txt"
git -C "${LOCAL}" add fixture.txt
git -C "${LOCAL}" commit -m "test: add fixture" >/dev/null
git -C "${LOCAL}" push origin HEAD:main >/dev/null
git --git-dir="${REMOTE}" update-ref refs/pull/7/head "$(git -C "${LOCAL}" rev-parse HEAD)"
HEAD_OID="$(git -C "${LOCAL}" rev-parse HEAD)"

# review.sh pins every review to immutable head/base revisions and refreshes
# eligibility before publishing, so each fixture carries a green, mergeable
# snapshot of the reviewed PR.
pr_json() {
    # pr_json CLOSING_ISSUES_JSON
    printf '{"author":{"login":"contributor"},"baseRefName":"main","headRefName":"feature","headRefOid":"%s","baseRefOid":"%s","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","labels":[],"assignees":[],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"closingIssuesReferences":%s}' \
        "${HEAD_OID}" "${HEAD_OID}" "${1}"
}

cat > "${MOCK_BIN}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "label" ]]; then
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    printf '%s\n' "${REVIEW_PR_JSON}"
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
    printf 'diff --git a/fixture.txt b/fixture.txt\n'
    exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "review" ]]; then
    exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    printf '%s\n' "$*" >> "${GH_API_LOG}"
    if [[ -n "${FAIL_API_TARGET:-}" && "$*" == *"${FAIL_API_TARGET}"* ]] &&
       [[ -z "${FAIL_API_OPERATION:-}" || "$*" == *"${FAIL_API_OPERATION}"* ]]; then
        exit 1
    fi
    exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 99
MOCK

cat > "${MOCK_BIN}/reviewer" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf '### Review Summary\n\n**Findings**\n1. None\n\n**Checks Run**\n- fixture: pass\n\n%s\n' "${REVIEW_VERDICT}"
MOCK
chmod +x "${MOCK_BIN}/gh" "${MOCK_BIN}/reviewer"

cat > "${RUNTIME}/triage.toml" <<TOML
[agent]
login = "bot"
human_login = "human"

[cli_chain]
review = ["reviewer"]

[cli_tools.reviewer]
command = "${MOCK_BIN}/reviewer"
args = []
prompt_mode = "stdin"
TOML

export PATH="${MOCK_BIN}:${PATH}"
export GH_API_LOG REVIEW_PR_JSON REVIEW_VERDICT FAIL_API_TARGET FAIL_API_OPERATION
export TRIAGE_DIR="${RUNTIME}"
export TRIAGE_CONFIG="${RUNTIME}/triage.toml"
export TRIAGE_REPOS_DIR="${REPOS}"
export TRIAGE_WORKTREES_DIR="${WORKTREES}"
export TRIAGE_ENABLE_DISPATCH=1

run_review() {
    local log_file
    : > "${GH_API_LOG}"
    rm -rf "${RUNTIME}/state/review-rounds"
    "${ROOT}/scripts/review.sh" acme/app 7 || [[ "${1:-}" == "expect-failure" ]]
    log_file="$(find "${RUNTIME}/logs" -type f -name '*review-app-7.log' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
    cat "${log_file}"
}

# Same-repo and cross-repo references retain their own canonical repository,
# including distinct repositories whose issue numbers happen to match.
REVIEW_PR_JSON="$(pr_json '[{"number":42,"repository":{"name":"app","owner":{"login":"acme"}}},{"number":42,"repository":{"name":"project","owner":{"login":"other"}}},{"number":9,"repository":{"name":"repo","owner":{"login":"third"}}}]')"
REVIEW_VERDICT='VERDICT: merge-ready'
FAIL_API_TARGET=''
FAIL_API_OPERATION=''
run_review >/dev/null
grep -Fq 'repos/acme/app/issues/42/assignees' "${GH_API_LOG}"
grep -Fq 'repos/other/project/issues/42/assignees' "${GH_API_LOG}"
grep -Fq 'repos/third/repo/issues/9/assignees' "${GH_API_LOG}"
[[ "$(grep -c 'repos/.*/issues/42/assignees' "${GH_API_LOG}")" -eq 4 ]]

# Blocked handoffs use the referenced repository. If assigning the human fails,
# the agent remains assigned so the issue is never left without an owner.
REVIEW_PR_JSON="$(pr_json '[{"number":55,"repository":{"name":"failing","owner":{"login":"other"}}}]')"
REVIEW_VERDICT='VERDICT: blocked - external dependency'
FAIL_API_TARGET='repos/other/failing/issues/55/assignees'
FAIL_API_OPERATION='-X POST'
blocked_log="$(run_review)"
[[ "$(grep -c 'repos/other/failing/issues/55/assignees' "${GH_API_LOG}")" -eq 1 ]]
! grep -Fq -- '-X DELETE repos/other/failing/issues/55/assignees' "${GH_API_LOG}"
grep -Fq "WARN: failed to add assignee 'human' to other/failing#55" <<<"${blocked_log}"

# Missing repository identity is explicit and fails closed. In particular, it
# is never substituted with the PR repository for a possibly cross-repo issue.
REVIEW_PR_JSON="$(pr_json '[{"number":77,"repository":null},{"number":78,"repository":{"name":"repo","owner":null}}]')"
REVIEW_VERDICT='VERDICT: blocked - inaccessible issue'
FAIL_API_TARGET=''
FAIL_API_OPERATION=''
incomplete_log="$(run_review)"
! grep -Fq 'repos/acme/app/issues/77/assignees' "${GH_API_LOG}"
! grep -Fq 'repos/acme/app/issues/78/assignees' "${GH_API_LOG}"
grep -Fq 'WARN: skipping closing issue reference with incomplete or invalid repository identity: <missing>#77' <<<"${incomplete_log}"
grep -Fq 'WARN: skipping closing issue reference with incomplete or invalid repository identity: <missing>#78' <<<"${incomplete_log}"

# Invalid reviewer output follows the same repository-aware blocked handoff.
REVIEW_PR_JSON="$(pr_json '[{"number":88,"repository":{"name":"output","owner":{"login":"invalid"}}}]')"
REVIEW_VERDICT='review completed without protocol verdict'
FAIL_API_TARGET=''
run_review expect-failure >/dev/null
grep -Fq 'repos/invalid/output/issues/88/assignees' "${GH_API_LOG}"

echo "review handoff tests passed"
