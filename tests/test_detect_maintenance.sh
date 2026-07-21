#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

cat > "${TMPDIR_TEST}/triage.toml" <<'TOML'
[agent]
login = "WulfAI"
human_login = "wlfghdr"

[dependabot]
enabled = true

[release]
enabled = true

[[repos]]
name = "acme/app"
dependabot_automerge = true
release = true
TOML

cat > "${TMPDIR_TEST}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == "pr list -R acme/app --state open --limit 50 --json number,labels,assignees,mergeStateStatus,mergeable,author,statusCheckRollup" ]]; then
    printf '[]\n'
elif [[ "$*" == "pr list -R acme/app --author WulfAI --state open --limit 50 --json number" ]]; then
    printf '[]\n'
elif [[ "$*" == "issue list -R acme/app --assignee WulfAI --state open --limit 50 --json number,title,url,labels" ]]; then
    printf '[]\n'
elif [[ "$*" == "pr list -R acme/app --assignee WulfAI --state open --limit 50 --json number" ]]; then
    printf '[]\n'
elif [[ "$*" == "pr list -R acme/app --assignee WulfAI --state open --limit 50 --json number,title,url,isDraft,statusCheckRollup,labels,assignees,mergeStateStatus,mergeable" ]]; then
    printf '[]\n'
elif [[ "$*" == "pr list -R acme/app --author dependabot[bot] --state open --limit 50 --json number,title,url,isDraft,statusCheckRollup,labels,mergeStateStatus,mergeable,isCrossRepository" ]]; then
    cat <<'JSON'
[
  {"number":1,"title":"build(deps): bump lib-a","url":"https://example.invalid/pr/1","isDraft":false,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isCrossRepository":false},
  {"number":2,"title":"build(deps): bump lib-b","url":"https://example.invalid/pr/2","isDraft":false,"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":""}],"labels":[],"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isCrossRepository":false},
  {"number":3,"title":"build(deps): bump lib-c","url":"https://example.invalid/pr/3","isDraft":false,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"labels":[],"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isCrossRepository":false},
  {"number":4,"title":"build(deps): bump lib-d","url":"https://example.invalid/pr/4","isDraft":false,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","isCrossRepository":false}
]
JSON
elif [[ "$*" == "repo view acme/app --json defaultBranchRef" ]]; then
    printf '{"defaultBranchRef":{"name":"main"}}\n'
elif [[ "$*" == "release list -R acme/app --limit 1 --json tagName" ]]; then
    printf '[{"tagName":"v1.0.0"}]\n'
elif [[ "$*" == "api -X GET repos/acme/app/compare/v1.0.0...main" ]]; then
    printf '{"ahead_by":2}\n'
else
    echo "unexpected gh args: $*" >&2
    exit 99
fi
MOCK
chmod +x "${TMPDIR_TEST}/gh"

PATH="${TMPDIR_TEST}:${PATH}" \
TRIAGE_CONFIG="${TMPDIR_TEST}/triage.toml" \
TRIAGE_STATE_DIR="${TMPDIR_TEST}/state" \
"${ROOT}/scripts/detect.py" > "${TMPDIR_TEST}/report.json" 2>"${TMPDIR_TEST}/stderr.log"

jq -e '.itemCount == 3' "${TMPDIR_TEST}/report.json"
jq -e '.items[] | select(.kind == "dependabot" and .number == 1 and .mode == "merge")' "${TMPDIR_TEST}/report.json"
jq -e '.items[] | select(.kind == "dependabot" and .number == 4 and .mode == "rebase")' "${TMPDIR_TEST}/report.json"
jq -e '.items[] | select(.kind == "release" and .repo == "acme/app" and .mode == "daily")' "${TMPDIR_TEST}/report.json"
grep -F "Dependabot PR has pending CI" "${TMPDIR_TEST}/stderr.log"
grep -F "Dependabot PR has red CI" "${TMPDIR_TEST}/stderr.log"

mkdir -p "${TMPDIR_TEST}/state/release"
jq -n --arg date "$(date -u +%F)" '{date: $date}' > "${TMPDIR_TEST}/state/release/acme_app.json"
PATH="${TMPDIR_TEST}:${PATH}" \
TRIAGE_CONFIG="${TMPDIR_TEST}/triage.toml" \
TRIAGE_STATE_DIR="${TMPDIR_TEST}/state" \
"${ROOT}/scripts/detect.py" > "${TMPDIR_TEST}/report-second.json" 2>/dev/null

jq -e '.itemCount == 2' "${TMPDIR_TEST}/report-second.json"
if jq -e '.items[] | select(.kind == "release")' "${TMPDIR_TEST}/report-second.json" >/dev/null; then
    echo "release item emitted despite same-day state" >&2
    exit 1
fi

echo "maintenance detection tests passed"
