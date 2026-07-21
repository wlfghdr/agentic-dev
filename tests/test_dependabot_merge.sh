#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    pr\ view\ 1\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"title":"build(deps): bump lib-a","url":"https://example.invalid/pr/1","headRefOid":"abc123"}
JSON
        ;;
    pr\ view\ 2\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":""}],"labels":[],"title":"build(deps): bump lib-b","url":"https://example.invalid/pr/2","headRefOid":"abc123"}
JSON
        ;;
    pr\ view\ 3\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"human"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"title":"fix: human change","url":"https://example.invalid/pr/3","headRefOid":"abc123"}
JSON
        ;;
    pr\ view\ 4\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[],"labels":[],"title":"build(deps): bump lib-c","url":"https://example.invalid/pr/4","headRefOid":"abc123"}
JSON
        ;;
    pr\ view\ 5\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}],"labels":[],"title":"build(deps): bump lib-d","url":"https://example.invalid/pr/5","headRefOid":"abc123"}
JSON
        ;;
    pr\ view\ 6\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"title":"build(deps): bump lib-e","url":"https://example.invalid/pr/6","headRefOid":"abc123"}
JSON
        ;;
    pr\ merge\ 1\ -R\ acme/app\ --squash\ --delete-branch\ --match-head-commit\ abc123)
        printf '%s\n' "$*" >> "${GH_MERGE_LOG}"
        ;;
    pr\ merge\ 6\ -R\ acme/app\ --squash\ --delete-branch\ --match-head-commit\ abc123)
        printf '%s\n' "$*" >> "${GH_MERGE_LOG}"
        exit 1
        ;;
    *)
        echo "unexpected gh args: $*" >&2
        exit 99
        ;;
esac
MOCK
chmod +x "${TMPDIR_TEST}/gh"

cat > "${TMPDIR_TEST}/triage.toml" <<'TOML'
[dependabot]
enabled = true

[[repos]]
name = "acme/app"
dependabot_automerge = true
TOML

export PATH="${TMPDIR_TEST}:${PATH}"
export TRIAGE_ENABLE_DISPATCH=1
export TRIAGE_DIR="${TMPDIR_TEST}/triage"
export TRIAGE_CONFIG="${TMPDIR_TEST}/triage.toml"
export GH_MERGE_LOG="${TMPDIR_TEST}/merges.log"

"${ROOT}/scripts/dependabot_merge.sh" acme/app 1
grep -Fx "pr merge 1 -R acme/app --squash --delete-branch --match-head-commit abc123" "${GH_MERGE_LOG}"

"${ROOT}/scripts/dependabot_merge.sh" acme/app 2
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

if "${ROOT}/scripts/dependabot_merge.sh" acme/app 3; then
    echo "non-Dependabot PR was accepted" >&2
    exit 1
fi
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

"${ROOT}/scripts/dependabot_merge.sh" acme/app 4
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

"${ROOT}/scripts/dependabot_merge.sh" acme/app 5
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

"${ROOT}/scripts/dependabot_merge.sh" acme/app 6
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "2" ]]
if grep -q -- '--auto' "${GH_MERGE_LOG}"; then
    echo "dependabot merge enabled persistent auto-merge" >&2
    exit 1
fi

export TRIAGE_CONFIG="${TMPDIR_TEST}/missing.toml"
"${ROOT}/scripts/dependabot_merge.sh" acme/app 1
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "2" ]]

cat > "${TMPDIR_TEST}/global-disabled.toml" <<'TOML'
[dependabot]
enabled = false

[[repos]]
name = "acme/app"
dependabot_automerge = true
TOML
export TRIAGE_CONFIG="${TMPDIR_TEST}/global-disabled.toml"
"${ROOT}/scripts/dependabot_merge.sh" acme/app 1
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "2" ]]

echo "dependabot merge tests passed"
