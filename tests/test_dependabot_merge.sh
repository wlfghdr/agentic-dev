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
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"title":"build(deps): bump lib-a","url":"https://example.invalid/pr/1"}
JSON
        ;;
    pr\ view\ 2\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"dependabot[bot]"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS","conclusion":""}],"labels":[],"title":"build(deps): bump lib-b","url":"https://example.invalid/pr/2"}
JSON
        ;;
    pr\ view\ 3\ -R\ acme/app\ --json*)
        cat <<'JSON'
{"author":{"login":"human"},"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"labels":[],"title":"fix: human change","url":"https://example.invalid/pr/3"}
JSON
        ;;
    pr\ merge\ 1\ -R\ acme/app\ --squash\ --delete-branch)
        printf '%s\n' "$*" >> "${GH_MERGE_LOG}"
        ;;
    *)
        echo "unexpected gh args: $*" >&2
        exit 99
        ;;
esac
MOCK
chmod +x "${TMPDIR_TEST}/gh"

cat > "${TMPDIR_TEST}/triage.toml" <<'TOML'
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
grep -Fx "pr merge 1 -R acme/app --squash --delete-branch" "${GH_MERGE_LOG}"

"${ROOT}/scripts/dependabot_merge.sh" acme/app 2
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

if "${ROOT}/scripts/dependabot_merge.sh" acme/app 3; then
    echo "non-Dependabot PR was accepted" >&2
    exit 1
fi
[[ "$(wc -l < "${GH_MERGE_LOG}")" == "1" ]]

echo "dependabot merge tests passed"
