#!/usr/bin/env bash
# scripts/engineer.sh [--pr|-c|--rebase] REPO ISSUE_OR_PR_NUMBER
# Spawn an agent CLI on a worktree to implement an issue or fix an assigned PR.
# --rebase first tries the deterministic fast path: rebase the PR branch onto
# its base, push, exit. If the rebase hits conflicts, fall back to the configured
# agent chain in the conflicted worktree to complete the rebase.
# Honors TRIAGE_ENABLE_DISPATCH=1 — otherwise logs the plan and exits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli_dispatch.sh
source "${SCRIPT_DIR}/cli_dispatch.sh"

MODE="issue"
case "${1:-}" in
    --pr|-c) MODE="pr"; shift ;;
    --rebase) MODE="rebase"; shift ;;
esac

REPO="${1:?repo required, e.g. owner/repo}"
NUM="${2:?issue or pr number required}"

REPO_NAME="${REPO##*/}"
REPO_OWNER="${REPO%%/*}"

TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
LOCAL_REPO="${TRIAGE_REPOS_DIR:-/srv/agentic-dev/../repos}/${REPO_NAME}"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
AGENT_LOGIN="${TRIAGE_AGENT_LOGIN:-agent-login}"
HUMAN_LOGIN="${TRIAGE_HUMAN_LOGIN:-human-login}"

if [[ -f "${CONF_FILE}" ]]; then
    CONF_AGENT=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(d.get('agent', {}).get('login', ''))" "${CONF_FILE}" 2>/dev/null || true)
    CONF_HUMAN=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(d.get('agent', {}).get('human_login', ''))" "${CONF_FILE}" 2>/dev/null || true)
    if [[ -n "${CONF_AGENT}" ]]; then AGENT_LOGIN="${CONF_AGENT}"; fi
    if [[ -n "${CONF_HUMAN}" ]]; then HUMAN_LOGIN="${CONF_HUMAN}"; fi
fi
LOGDIR="${TRIAGE_DIR}/logs"
LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-engineer-${REPO_NAME}-${MODE}-${NUM}.log"

case "${MODE}" in
    pr|rebase)
        WORKTREE="${TRIAGE_WORKTREES_DIR:-/srv/agentic-dev/../worktrees}/${REPO_NAME}-pr-${NUM}"
        BRANCH=""
        ;;
    *)
        WORKTREE="${TRIAGE_WORKTREES_DIR:-/srv/agentic-dev/../worktrees}/${REPO_NAME}-${NUM}"
        BRANCH="agentic-dev/issue-${NUM}"
        ;;
esac

mkdir -p "${LOGDIR}" "$(dirname "${WORKTREE}")"

exec >"${LOG}" 2>&1

add_label() {
    # add_label REPO NUM LABEL
    gh api -X POST "repos/${1}/issues/${2}/labels" -f "labels[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to add label '${3}' to ${1}#${2}" >&2
}
remove_label() {
    # remove_label REPO NUM LABEL
    gh api -X DELETE "repos/${1}/issues/${2}/labels/${3}" >/dev/null 2>&1 || true
}
add_assignee() {
    # add_assignee REPO NUM ASSIGNEE
    gh api -X POST "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to add assignee '${3}' to ${1}#${2}" >&2
}
remove_assignee() {
    # remove_assignee REPO NUM ASSIGNEE
    gh api -X DELETE "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || true
}

ensure_workflow_labels() {
    gh label create "approved" -R "${REPO}" \
        --description "PR is ready for human merge" \
        --color "0e8a16" --force >/dev/null 2>&1 || true
    gh label create "changes-requested" -R "${REPO}" \
        --description "PR needs an engineering fix iteration" \
        --color "d93f0b" --force >/dev/null 2>&1 || true
    gh label create "blocked" -R "${REPO}" \
        --description "PR is blocked and needs human attention" \
        --color "b60205" --force >/dev/null 2>&1 || true
    gh label create "needs-review" -R "${REPO}" \
        --description "Deterministic triage review is in progress" \
        --color "fbca04" --force >/dev/null 2>&1 || true
    gh label create "in-progress" -R "${REPO}" \
        --description "Triage agent is actively working on this" \
        --color "1d76db" --force >/dev/null 2>&1 || true
}

worktree_for_branch() {
    # worktree_for_branch BRANCH
    local target="refs/heads/${1}"
    local wt=""
    local line=""
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *) wt="${line#worktree }" ;;
            branch\ *)
                if [[ "${line#branch }" == "${target}" ]]; then
                    printf '%s\n' "${wt}"
                    return 0
                fi
                ;;
        esac
    done < <(git -C "${LOCAL_REPO}" worktree list --porcelain)
    return 1
}

prepare_pr_worktree() {
    local branch="${1}"
    local source_ref="${2}"
    local existing=""

    if existing="$(worktree_for_branch "${branch}")"; then
        WORKTREE="${existing}"
        echo "==> branch already checked out, reusing worktree: ${WORKTREE}"
        return 0
    fi

    if [[ -e "${WORKTREE}" ]]; then
        echo "==> worktree already exists, checking out ${branch}"
        git -C "${WORKTREE}" checkout -B "${branch}" "${source_ref}"
    else
        git -C "${LOCAL_REPO}" worktree add "${WORKTREE}" -B "${branch}" "${source_ref}"
    fi
}

rebase_in_progress() {
    [[ -d "$(git -C "${WORKTREE}" rev-parse --git-path rebase-merge)" || \
       -d "$(git -C "${WORKTREE}" rev-parse --git-path rebase-apply)" ]]
}

worktree_clean() {
    [[ -z "$(git -C "${WORKTREE}" status --porcelain | grep -vE '(__pycache__|\.antigravitycli)')" ]]
}

base_is_ancestor() {
    git -C "${WORKTREE}" merge-base --is-ancestor "origin/${BASE_REF}" HEAD
}

block_rebase_conflict() {
    # block_rebase_conflict COMMENT
    echo "==> rebase still blocked; handing back to ${HUMAN_LOGIN}" >&2
    remove_label "${REPO}" "${NUM}" "in-progress"
    remove_label "${REPO}" "${NUM}" "approved"
    add_label "${REPO}" "${NUM}" "blocked"
    add_assignee "${REPO}" "${NUM}" "${HUMAN_LOGIN}"
    remove_assignee "${REPO}" "${NUM}" "${AGENT_LOGIN}"

    # Request review from human
    echo "==> Requesting review from human ${HUMAN_LOGIN}"
    gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

    # Assign originating issues
    local issue_num
    for issue_num in $(echo "${PR_JSON}" | jq -r '.closingIssuesReferences[].number' 2>/dev/null || true); do
        if [[ -n "${issue_num}" && "${issue_num}" != "null" ]]; then
            echo "==> Handing over originating issue #${issue_num} to ${HUMAN_LOGIN}"
            add_assignee "${REPO}" "${issue_num}" "${HUMAN_LOGIN}"
            remove_assignee "${REPO}" "${issue_num}" "${AGENT_LOGIN}"
        fi
    done

    gh pr comment "${NUM}" -R "${REPO}" --body "${1}" >/dev/null 2>&1 || true
}

run_rebase_conflict_resolution() {
    local prompt

    prompt="You are working in an existing PR worktree of ${REPO} at ${WORKTREE}.
Branch: ${BRANCH}. Default merge target: ${BASE_REF}.

Task: auto-rebase PR #${NUM} hit merge conflicts. Resolve the conflicts and complete the rebase.

Rules (binding triage policy — do not relax):
- Read the repository's rules/guidelines first.
- Stay scoped to resolving this rebase conflict. No drive-by refactors.
- Inspect \`git status\`, the conflicted files, and the PR payload below before editing.
- Resolve conflicts according to the intent of the PR and the current base branch.
- Run \`git add\` for resolved files and \`git rebase --continue\` until the rebase is complete.
- Run the repo's own tests / linters / checks before declaring done.
- Do not open a new PR. Do not push; the wrapper pushes after verifying the rebase is complete.
- If the conflict cannot be resolved safely, leave the rebase state intact and explain why.

PR payload (JSON):
${PR_JSON}
"

    echo "==> rebase conflict; starting conflict resolution chain"
    load_cli_chain "${CONF_FILE}" "rebase" "claude" "agy" "codex"
    local chain=("${CLI_CHAIN[@]}")

    local out_file
    out_file=$(mktemp)
    local rc=1

    for i in "${!chain[@]}"; do
        local tool="${chain[i]}"
        local step=$((i + 1))
        local total=${#chain[@]}
        
        echo "--> [${step}/${total}] attempting rebase conflict resolution via ${tool}..."
        
        if run_cli_tool "${CONF_FILE}" "${tool}" "${WORKTREE}" "${prompt}" "${out_file}"; then
            rc=0
        else
            rc=$?
        fi
        
        echo "--> ${tool} conflict-resolution exit=${rc}"
        
        if [[ ${rc} -eq 0 ]]; then
            break
        fi
        
        if [[ ${rc} -ne 0 ]]; then
            if (( step < total )) && { [[ ${rc} -eq 127 ]] || grep -Eqi "limit|quota|429|too many requests|cooldown|overloaded|throttl" "${out_file}"; }; then
                echo "--> [${step}/${total}] ${tool} unavailable or rate-limited. falling back..."
                continue
            fi
            break
        fi
    done

    rm -f "${out_file}"
    return "${rc}"
}

echo "==> scripts/engineer: ${REPO}#${NUM} (${MODE})"
echo "==> worktree: ${WORKTREE}"
echo

if [[ ! -d "${LOCAL_REPO}/.git" ]]; then
    echo "FATAL: local repo not found at ${LOCAL_REPO}" >&2
    exit 2
fi

git -C "${LOCAL_REPO}" fetch --quiet
git -C "${LOCAL_REPO}" worktree prune

if [[ "${MODE}" == "pr" || "${MODE}" == "rebase" ]]; then
    PR_JSON=$(gh pr view "${NUM}" -R "${REPO}" --json title,body,baseRefName,headRefName,headRepositoryOwner,url,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviews,comments,files,labels,commits,closingIssuesReferences)
    BASE_REF=$(echo "${PR_JSON}" | jq -r '.baseRefName')
    HEAD_REF=$(echo "${PR_JSON}" | jq -r '.headRefName')
    HEAD_OWNER=$(echo "${PR_JSON}" | jq -r '.headRepositoryOwner.login // ""')
    SAME_ORIGIN_BRANCH=0
    if [[ "${HEAD_OWNER}" == "${REPO_OWNER}" ]] && git -C "${LOCAL_REPO}" ls-remote --exit-code --heads origin "${HEAD_REF}" >/dev/null 2>&1; then
        BRANCH="${HEAD_REF}"
        SAME_ORIGIN_BRANCH=1
        git -C "${LOCAL_REPO}" fetch --quiet origin "${BRANCH}"
    else
        BRANCH="pr-${NUM}-fix"
        git -C "${LOCAL_REPO}" fetch --quiet origin "pull/${NUM}/head:${BRANCH}"
    fi

    echo "==> branch:   ${BRANCH}"
    if [[ "${SAME_ORIGIN_BRANCH}" -eq 1 ]]; then
        prepare_pr_worktree "${BRANCH}" "origin/${BRANCH}"
    elif [[ -e "${WORKTREE}" ]]; then
        echo "==> worktree already exists, reusing"
    else
        git -C "${LOCAL_REPO}" worktree add "${WORKTREE}" "${BRANCH}"
    fi

    if [[ "${MODE}" == "rebase" ]]; then
        if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
            echo "==> DRY RUN — would rebase ${BRANCH} onto origin/${BASE_REF} and push --force-with-lease"
            exit 0
        fi
        ensure_workflow_labels
        if [[ "${SAME_ORIGIN_BRANCH}" -ne 1 ]]; then
            echo "==> cannot rebase — PR head is on a fork (${HEAD_OWNER}); handing back to ${HUMAN_LOGIN}" >&2
            add_label "${REPO}" "${NUM}" "blocked"
            add_assignee "${REPO}" "${NUM}" "${HUMAN_LOGIN}"
            remove_assignee "${REPO}" "${NUM}" "${AGENT_LOGIN}"

            # Request review from human
            echo "==> Requesting review from human ${HUMAN_LOGIN}"
            gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

            # Assign originating issues
            for issue_num in $(echo "${PR_JSON}" | jq -r '.closingIssuesReferences[].number' 2>/dev/null || true); do
                if [[ -n "${issue_num}" && "${issue_num}" != "null" ]]; then
                    echo "==> Handing over originating issue #${issue_num} to ${HUMAN_LOGIN}"
                    add_assignee "${REPO}" "${issue_num}" "${HUMAN_LOGIN}"
                    remove_assignee "${REPO}" "${issue_num}" "${AGENT_LOGIN}"
                fi
            done

            gh pr comment "${NUM}" -R "${REPO}" --body "Auto-rebase skipped: PR head lives on a fork (${HEAD_OWNER}). Needs human rebase." >/dev/null 2>&1 || true
            exit 4
        fi
        echo "==> rebasing ${BRANCH} onto origin/${BASE_REF}"
        git -C "${LOCAL_REPO}" fetch --quiet origin "${BRANCH}" "${BASE_REF}"
        git -C "${WORKTREE}" checkout "${BRANCH}"
        git -C "${WORKTREE}" reset --hard "origin/${BRANCH}"
        git -C "${WORKTREE}" clean -fd
        if git -C "${WORKTREE}" rebase "origin/${BASE_REF}"; then
            if ! base_is_ancestor; then
                block_rebase_conflict "Auto-rebase onto \`${BASE_REF}\` completed with a clean exit, but \`origin/${BASE_REF}\` is not an ancestor of \`${BRANCH}\`. Refusing to force-push; needs human verification."
                exit 5
            fi
            echo "==> rebase clean; pushing --force-with-lease"
            git -C "${WORKTREE}" push --force-with-lease origin "${BRANCH}"
            gh pr comment "${NUM}" -R "${REPO}" --body "Auto-rebased onto \`${BASE_REF}\` (${BRANCH}). Waiting for CI." >/dev/null 2>&1 || true
            exit 0
        else
            if run_rebase_conflict_resolution && ! rebase_in_progress && worktree_clean && base_is_ancestor; then
                echo "==> agent completed conflict rebase; pushing --force-with-lease"
                git -C "${WORKTREE}" push --force-with-lease origin "${BRANCH}"
                remove_label "${REPO}" "${NUM}" "blocked"
                gh pr comment "${NUM}" -R "${REPO}" --body "Auto-rebase onto \`${BASE_REF}\` hit conflicts; the agent chain resolved them and pushed \`${BRANCH}\`. Waiting for CI." >/dev/null 2>&1 || true
                exit 0
            fi

            if rebase_in_progress; then
                git -C "${WORKTREE}" rebase --abort || true
            fi
            block_rebase_conflict "Auto-rebase onto \`${BASE_REF}\` hit conflicts. The agent chain attempted resolution but did not leave a clean worktree with \`origin/${BASE_REF}\` in \`${BRANCH}\` history. Needs human resolution."
            exit 5
        fi
    fi

    PROMPT="You are working in an existing PR worktree of ${REPO} at ${WORKTREE}.
Branch: ${BRANCH}. Default merge target: $(echo "${PR_JSON}" | jq -r '.baseRefName').

Task: address unresolved review comments + failing CI for PR #${NUM} below.

Rules:
- Read the repository's rules/guidelines first.
- Stay scoped to this PR fix iteration. No drive-by refactors.
- Inspect unresolved review comments, review decision, changed files, and failing checks before editing.
- Run the repo's own tests / linters / checks before declaring done.
- When ready, commit fixes on the existing PR branch and push. Do not open a new PR.
- Leave a PR comment summarizing what was fixed.

PR payload (JSON):
${PR_JSON}
"
else
    if [[ -e "${WORKTREE}" ]]; then
        echo "==> worktree already exists, reusing"
    else
        # try to base on existing remote branch, else origin/HEAD
        if git -C "${LOCAL_REPO}" rev-parse --verify --quiet "origin/${BRANCH}" >/dev/null; then
            git -C "${LOCAL_REPO}" worktree add "${WORKTREE}" -B "${BRANCH}" "origin/${BRANCH}"
        else
            DEFAULT=$(git -C "${LOCAL_REPO}" symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@')
            git -C "${LOCAL_REPO}" worktree add "${WORKTREE}" -B "${BRANCH}" "origin/${DEFAULT}"
        fi
    fi

    echo "==> branch:   ${BRANCH}"
    # build prompt
    ISSUE_JSON=$(gh issue view "${NUM}" -R "${REPO}" --json title,body,labels,comments)

    # Mark the issue as in-progress + ensure agent is assigned so status is clear at a glance.
    # Labels must exist before --add-label.
    if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" == "1" ]]; then
        ensure_workflow_labels
        gh issue edit "${NUM}" -R "${REPO}" \
            --add-label "in-progress" \
            --add-assignee "${AGENT_LOGIN}" >/dev/null 2>&1 || \
            echo "WARN: failed to mark issue ${REPO}#${NUM} as in-progress" >&2
    fi

    PROMPT="You are working in a fresh git worktree of ${REPO} at ${WORKTREE}.
Branch: ${BRANCH}. Default merge target: main.

Task: implement the fix or feature requested in issue #${NUM} below.

Rules (binding triage policy — do not relax):
- Read the repository's rules/guidelines first.
- Stay scoped to this issue. No drive-by refactors.
- Run the repo's own tests / linters / checks before declaring done.
- When ready, commit with a clear message and push the branch.
- Open a PR via \`gh pr create\` (NOT as draft — leave off --draft entirely).
- The PR body MUST contain a line \`Closes #${NUM}\` (or \`Fixes #${NUM}\` / \`Resolves #${NUM}\`) so the repo's issue-link check passes and the issue auto-closes on merge.
- Do not open a second PR if one already exists for this branch; push another commit instead.
- PR assignee + labels are handled by the wrapper after you exit — you do not need to touch them.

Issue payload (JSON):
${ISSUE_JSON}
"
fi

if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
    echo "==> DRY RUN (TRIAGE_ENABLE_DISPATCH != 1) — prompt below:"
    echo "----8<----"
    echo "${PROMPT}"
    echo "---->8----"
    echo "==> Would dispatch the configured engineering CLI chain"
    exit 0
fi

echo "==> ensuring workflow labels exist"
ensure_workflow_labels

OUT_FILE=""
OUT_FILE=$(mktemp)

echo "==> dispatching to engineering fallback chain"
cd "${WORKTREE}"

load_cli_chain "${CONF_FILE}" "engineer" "codex" "claude" "agy"
CHAIN=("${CLI_CHAIN[@]}")

rc=1
for i in "${!CHAIN[@]}"; do
    TOOL="${CHAIN[i]}"
    STEP=$((i + 1))
    TOTAL=${#CHAIN[@]}
    
    echo "--> [${STEP}/${TOTAL}] attempting ${TOOL}..."
    
    if run_cli_tool "${CONF_FILE}" "${TOOL}" "${WORKTREE}" "${PROMPT}" "${OUT_FILE}"; then
        rc=0
    else
        rc=$?
    fi
    
    echo "--> ${TOOL} exit=${rc}"
    
    if [[ ${rc} -eq 0 ]]; then
        break
    fi
    
    if [[ ${rc} -ne 0 ]]; then
        if (( STEP < TOTAL )) && { [[ ${rc} -eq 127 ]] || grep -Eqi "limit|quota|429|too many requests|cooldown|overloaded|throttl" "${OUT_FILE}"; }; then
            echo "--> [${STEP}/${TOTAL}] ${TOOL} unavailable or rate-limited. falling back..."
            continue
        fi
        break
    fi
done

rm -f "${OUT_FILE}"

if PR_NUMBER=$(gh pr list -R "${REPO}" --head "${BRANCH}" --state open --json number --jq '.[0].number // ""' 2>/dev/null); then
    if [[ -n "${PR_NUMBER}" ]]; then
        echo "==> normalizing PR #${PR_NUMBER}: assign ${AGENT_LOGIN}, ready-for-review, label in-progress"
        add_assignee "${REPO}" "${PR_NUMBER}" "${AGENT_LOGIN}"
        add_label "${REPO}" "${PR_NUMBER}" "in-progress"
        remove_label "${REPO}" "${PR_NUMBER}" "approved"
        # Codex defaults to draft; flip it. Idempotent: errors if already ready, swallow.
        gh pr ready "${PR_NUMBER}" -R "${REPO}" >/dev/null 2>&1 || true
        if [[ "${MODE}" == "pr" && "${rc}" -eq 0 ]]; then
            echo "==> clearing changes-requested label after fix iteration"
            remove_label "${REPO}" "${PR_NUMBER}" "changes-requested"
        fi
    fi
else
    echo "WARN: failed to inspect open PR for branch ${BRANCH}" >&2
fi

exit "${rc}"
