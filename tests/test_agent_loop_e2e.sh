#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

RUNTIME="${TEST_ROOT}/runtime"
REPOS="${TEST_ROOT}/repos"
WORKTREES="${TEST_ROOT}/worktrees"
REMOTE="${TEST_ROOT}/app.git"
SEED="${TEST_ROOT}/seed"
MOCK_BIN="${TEST_ROOT}/mock-bin"
STATE="${TEST_ROOT}/github-state.json"

mkdir -p "${REPOS}" "${WORKTREES}" "${MOCK_BIN}"
TRIAGE_DIR="${RUNTIME}" \
TRIAGE_REPOS_DIR="${REPOS}" \
TRIAGE_WORKTREES_DIR="${WORKTREES}" \
TRIAGE_SYSTEMD_DIR="${TEST_ROOT}/systemd" \
TRIAGE_LOGROTATE_DIR="${TEST_ROOT}/logrotate" \
TRIAGE_SKIP_SYSTEMD=1 \
"${ROOT}/install.sh" >/dev/null

[[ -x "${RUNTIME}/bin/tick.sh" ]]
grep -Fq "ExecStart=${RUNTIME}/bin/tick.sh" "${TEST_ROOT}/systemd/triage-tick.service"
grep -Fq "Environment=\"TRIAGE_REPOS_DIR=${REPOS}\"" "${TEST_ROOT}/systemd/triage-tick.service.d/dispatch.conf"
grep -Fq "Environment=\"TRIAGE_WORKTREES_DIR=${WORKTREES}\"" "${TEST_ROOT}/systemd/triage-tick.service.d/dispatch.conf"

git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.email "test@example.invalid"
git -C "${SEED}" config user.name "E2E Seed"
printf 'base\n' > "${SEED}/app.txt"
git -C "${SEED}" add app.txt
git -C "${SEED}" commit -m "chore: initial" >/dev/null
git -C "${SEED}" branch -M main
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push origin main >/dev/null
git --git-dir="${REMOTE}" symbolic-ref HEAD refs/heads/main
git clone "${REMOTE}" "${REPOS}/app" >/dev/null 2>&1
git -C "${REPOS}/app" config user.email "agent@example.invalid"
git -C "${REPOS}/app" config user.name "Agent E2E"

cat > "${STATE}" <<'JSON'
{"phase":"issue","issue_labels":[],"issue_assignees":["agent"],"pr_labels":[],"pr_assignees":[],"review_mode":"needs-fix","review_count":0,"merge_count":0}
JSON

cat > "${MOCK_BIN}/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

args = sys.argv[1:]
state_path = Path(os.environ["E2E_STATE"])
state = json.loads(state_path.read_text())

def save():
    state_path.write_text(json.dumps(state, sort_keys=True))

def labels(names):
    return [{"name": name} for name in names]

def assignees(names):
    return [{"login": name} for name in names]

def pr_detection():
    return {
        "number": 2,
        "title": "fix: implement e2e issue",
        "url": "https://example.invalid/acme/app/pull/2",
        "isDraft": False,
        "statusCheckRollup": [{"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}],
        "labels": labels(state["pr_labels"]),
        "assignees": assignees(state["pr_assignees"]),
        "mergeStateStatus": "CLEAN",
        "mergeable": "MERGEABLE",
        "headRepositoryOwner": {"login": "acme"},
        "isCrossRepository": False,
    }

def pr_metadata():
    data = pr_detection()
    data.update({
        "body": "Closes #1",
        "baseRefName": "main",
        "headRefName": "agentic-dev/issue-1",
        "author": {"login": "agent"},
        "files": [{"path": "app.txt"}],
        "closingIssuesReferences": [{"number": 1}],
        "reviewDecision": "",
        "reviews": [],
        "comments": [],
        "commits": [],
    })
    return data

if args[:2] == ["label", "create"]:
    sys.exit(0)

if args[:2] == ["issue", "list"]:
    if state["phase"] == "issue" and "agent" in state["issue_assignees"]:
        print(json.dumps([{"number": 1, "title": "exercise the full loop", "url": "https://example.invalid/acme/app/issues/1", "labels": labels(state["issue_labels"])}]))
    else:
        print("[]")
    sys.exit(0)

if args[:2] == ["issue", "view"]:
    print(json.dumps({"title": "exercise the full loop", "body": "Change app.txt", "labels": labels(state["issue_labels"]), "comments": []}))
    sys.exit(0)

if args[:2] == ["issue", "edit"]:
    if "--add-label" in args:
        value = args[args.index("--add-label") + 1]
        if value not in state["issue_labels"]:
            state["issue_labels"].append(value)
    if "--add-assignee" in args:
        value = args[args.index("--add-assignee") + 1]
        if value not in state["issue_assignees"]:
            state["issue_assignees"].append(value)
    save()
    sys.exit(0)

if args[:2] == ["pr", "list"]:
    if "--search" in args:
        print("[]" if state["phase"] == "issue" else '[{"number":2}]')
    elif "--head" in args and "--jq" in args:
        print("2" if state["phase"] == "pr" else "")
    elif state["phase"] != "pr":
        print("[]")
    elif "--author" in args and args[args.index("--author") + 1] == "dependabot[bot]":
        print("[]")
    elif "--json" in args and args[args.index("--json") + 1] == "number":
        print('[{"number":2}]')
    elif "--author" in args:
        item = pr_detection()
        item["author"] = {"login": "agent"}
        print(json.dumps([item]))
    else:
        print(json.dumps([pr_detection()]))
    sys.exit(0)

if args[:2] == ["pr", "view"]:
    print(json.dumps(pr_metadata()))
    sys.exit(0)

if args[:2] == ["pr", "create"]:
    state["phase"] = "pr"
    save()
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    subprocess.run(["git", f"--git-dir={os.environ['E2E_REMOTE']}", "update-ref", "refs/pull/2/head", sha], check=True)
    print("https://example.invalid/acme/app/pull/2")
    sys.exit(0)

if args[:2] == ["pr", "ready"]:
    sys.exit(0)

if args[:2] == ["pr", "diff"]:
    print("diff --git a/app.txt b/app.txt\n+implemented")
    sys.exit(0)

if args[:2] == ["pr", "review"]:
    state["review_count"] += 1
    save()
    sys.exit(0)

if args[:2] == ["pr", "merge"]:
    state["phase"] = "merged"
    state["merge_count"] += 1
    state["issue_labels"] = []
    save()
    subprocess.run(["git", f"--git-dir={os.environ['E2E_REMOTE']}", "update-ref", "refs/heads/main", "refs/pull/2/head"], check=True)
    sys.exit(0)

if args and args[0] == "api":
    method = args[args.index("-X") + 1]
    endpoint = next(value for value in args if value.startswith("repos/"))
    parts = endpoint.split("/")
    number = int(parts[4]) if len(parts) > 4 and parts[3] in ("issues", "pulls") and parts[4].isdigit() else None
    target_labels = state["issue_labels"] if number == 1 else state["pr_labels"]
    target_assignees = state["issue_assignees"] if number == 1 else state["pr_assignees"]
    if "/labels" in endpoint:
        if method == "POST":
            value = next((item.split("=", 1)[1] for item in args if item.startswith("labels[]=")), "")
            if value and value not in target_labels:
                target_labels.append(value)
        elif method == "DELETE":
            value = parts[-1]
            if value in target_labels:
                target_labels.remove(value)
    elif "/assignees" in endpoint:
        value = next((item.split("=", 1)[1] for item in args if item.startswith("assignees[]=")), "")
        if method == "POST" and value and value not in target_assignees:
            target_assignees.append(value)
        elif method == "DELETE" and value in target_assignees:
            target_assignees.remove(value)
    save()
    print("[]")
    sys.exit(0)

print("unexpected gh args: " + " ".join(args), file=sys.stderr)
sys.exit(99)
PY

cat > "${MOCK_BIN}/fake-agent" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
worktree="${1}"
prompt="$(cat)"

if [[ "${prompt}" == *"You are reviewing PR"* ]]; then
    mode="$(jq -r .review_mode "${E2E_STATE}")"
    printf '### Review Summary\n\n**Findings**\n1. %s\n\n**Checks Run**\n- e2e fixture: pass\n\n' "${mode}"
    if [[ "${mode}" == "needs-fix" ]]; then
        printf 'VERDICT: needs-fix - exercise the fix iteration\n'
    else
        printf 'VERDICT: merge-ready\n'
    fi
    exit 0
fi

cd "${worktree}"
if [[ "${prompt}" == *"existing PR worktree"* ]]; then
    printf 'fixed after review\n' >> app.txt
    git add app.txt
    git commit -m "fix: address review feedback" >/dev/null
    git push origin HEAD >/dev/null
else
    printf 'implemented by agent\n' >> app.txt
    git add app.txt
    git commit -m "fix: implement e2e issue" >/dev/null
    git push -u origin HEAD >/dev/null
    gh pr create --title "fix: implement e2e issue" --body "Closes #1" --base main --head agentic-dev/issue-1 >/dev/null
fi
sha="$(git rev-parse HEAD)"
git --git-dir="${E2E_REMOTE}" update-ref refs/pull/2/head "${sha}"
MOCK

cat > "${MOCK_BIN}/invalid-review-agent" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
echo "review completed without protocol verdict"
MOCK

cat > "${MOCK_BIN}/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "list-units" ]] && exit 0
exit 0
MOCK

cat > "${MOCK_BIN}/systemd-run" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
env_args=()
args=("$@")
for i in "${!args[@]}"; do
    case "${args[i]}" in
        --setenv=*) env_args+=("${args[i]#--setenv=}") ;;
        /bin/bash) exec env "${env_args[@]}" "${args[@]:i}" ;;
    esac
done
echo "systemd-run mock did not receive a command" >&2
exit 2
MOCK

chmod +x "${MOCK_BIN}/"*

cat > "${RUNTIME}/triage.toml" <<TOML
[agent]
login = "agent"
human_login = "human"

[limits]
max_engineer = 1
max_review = 1
max_maintenance = 1
open_pr_cap_per_repo = 3
lock_ttl_hours = 2

[cli_chain]
engineer = ["missing-agent", "fake-agent"]
review = ["invalid-review-agent", "fake-agent"]
rebase = ["fake-agent"]

[cli_tools.missing-agent]
command = "${MOCK_BIN}/does-not-exist"
args = []
prompt_mode = "stdin"

[cli_tools.fake-agent]
command = "${MOCK_BIN}/fake-agent"
args = ["{worktree}"]
prompt_mode = "stdin"

[cli_tools.invalid-review-agent]
command = "${MOCK_BIN}/invalid-review-agent"
args = []
prompt_mode = "stdin"

[[repos]]
name = "acme/app"
automerge = true
dependabot_automerge = false
release = false
TOML

export PATH="${MOCK_BIN}:${PATH}"
export E2E_STATE="${STATE}"
export E2E_REMOTE="${REMOTE}"
export TRIAGE_DIR="${RUNTIME}"
export TRIAGE_CONFIG="${RUNTIME}/triage.toml"
export TRIAGE_REPOS_DIR="${REPOS}"
export TRIAGE_WORKTREES_DIR="${WORKTREES}"
export TRIAGE_STATE_DIR="${RUNTIME}/state"
export TRIAGE_ENABLE_DISPATCH=1

run_tick() {
    "${RUNTIME}/bin/tick.sh" >/dev/null
}

# A freshly instantiated runtime is inert unless dispatch is explicitly armed.
TRIAGE_ENABLE_DISPATCH=0 run_tick
jq -e '.phase == "issue" and .review_count == 0 and .merge_count == 0' "${STATE}" >/dev/null
[[ ! -e "${RUNTIME}/state/locks/engineer-acme_app-1.lock" ]]

run_tick
[[ "$(jq -r .phase "${STATE}")" == "pr" ]]
[[ "$(git --git-dir="${REMOTE}" show refs/pull/2/head:app.txt)" == *"implemented by agent"* ]]

run_tick
jq -e '.pr_labels | index("changes-requested")' "${STATE}" >/dev/null
[[ "$(jq -r .review_count "${STATE}")" == "1" ]]

run_tick
if jq -e '.pr_labels | index("changes-requested")' "${STATE}" >/dev/null; then
    echo "changes-requested survived successful fix iteration" >&2
    exit 1
fi
[[ "$(git --git-dir="${REMOTE}" show refs/pull/2/head:app.txt)" == *"fixed after review"* ]]

# If every reviewer violates the output protocol, the loop fails closed and
# hands the PR and originating issue to the human owner.
sed 's/review = \["invalid-review-agent", "fake-agent"\]/review = ["invalid-review-agent"]/' \
    "${RUNTIME}/triage.toml" > "${RUNTIME}/triage-invalid-review.toml"
TRIAGE_CONFIG="${RUNTIME}/triage-invalid-review.toml" run_tick || true
jq -e '.pr_labels | index("blocked")' "${STATE}" >/dev/null
jq -e '.pr_assignees | index("human")' "${STATE}" >/dev/null
jq -e '.issue_assignees | index("human")' "${STATE}" >/dev/null

# Simulate the documented human retry action and verify the loop can recover.
jq '.pr_labels = [] | .pr_assignees = ["agent"] | .issue_assignees = ["agent"] | .review_mode = "merge-ready"' \
    "${STATE}" > "${STATE}.next"
mv "${STATE}.next" "${STATE}"

jq '.review_mode = "merge-ready"' "${STATE}" > "${STATE}.next"
mv "${STATE}.next" "${STATE}"
run_tick
jq -e '.phase == "merged" and .merge_count == 1 and .review_count == 3' "${STATE}" >/dev/null
jq -e '.pr_labels | index("approved")' "${STATE}" >/dev/null
jq -e '.pr_assignees | index("human")' "${STATE}" >/dev/null
[[ "$(git --git-dir="${REMOTE}" rev-parse refs/heads/main)" == "$(git --git-dir="${REMOTE}" rev-parse refs/pull/2/head)" ]]

run_tick
jq -e '.itemCount == 0' "${RUNTIME}/state/last-tick.json" >/dev/null

grep -R -F "missing-agent unavailable or rate-limited. falling back" "${RUNTIME}/logs" >/dev/null
grep -R -F "invalid-review-agent produced invalid review output. falling back" "${RUNTIME}/logs" >/dev/null

echo "agent loop e2e tests passed"
