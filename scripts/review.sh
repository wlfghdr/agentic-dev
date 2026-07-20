#!/usr/bin/env bash
# scripts/review.sh REPO PR_NUMBER
# Spawn an agent CLI to review a PR. Honors TRIAGE_ENABLE_DISPATCH=1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli_dispatch.sh
source "${SCRIPT_DIR}/cli_dispatch.sh"

REPO="${1:?repo required}"
NUM="${2:?pr number required}"

REPO_NAME="${REPO##*/}"
TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
LOCAL_REPO="${TRIAGE_REPOS_DIR:-/srv/agentic-dev/../repos}/${REPO_NAME}"
WORKTREE="${TRIAGE_WORKTREES_DIR:-/srv/agentic-dev/../worktrees}/${REPO_NAME}-pr-${NUM}"
LOGDIR="${TRIAGE_DIR}/logs"
LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-review-${REPO_NAME}-${NUM}.log"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
AGENT_LOGIN="${TRIAGE_AGENT_LOGIN:-agent-login}"
HUMAN_LOGIN="${TRIAGE_HUMAN_LOGIN:-human-login}"

if [[ -f "${CONF_FILE}" ]]; then
    CONF_AGENT=$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "agent.login" 2>/dev/null || true)
    CONF_HUMAN=$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "agent.human_login" 2>/dev/null || true)
    if [[ -n "${CONF_AGENT}" ]]; then AGENT_LOGIN="${CONF_AGENT}"; fi
    if [[ -n "${CONF_HUMAN}" ]]; then HUMAN_LOGIN="${CONF_HUMAN}"; fi
fi
NEEDS_REVIEW_LABEL="needs-review"

mkdir -p "${LOGDIR}" "$(dirname "${WORKTREE}")"

exec >"${LOG}" 2>&1

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
    gh label create "${NEEDS_REVIEW_LABEL}" -R "${REPO}" \
        --description "Deterministic triage review is in progress" \
        --color "fbca04" --force >/dev/null 2>&1 || true
}

# Label/assignee mutations via REST API. `gh pr edit` triggers a deprecation
# warning ("Projects (classic) is being deprecated") that exits 1 and aborts
# the whole multi-flag edit, so we go around it. REST endpoints are atomic per
# call and don't query projectCards.
add_label() {
    # add_label LABEL
    gh api -X POST "repos/${REPO}/issues/${NUM}/labels" -f "labels[]=${1}" >/dev/null 2>&1 || \
        echo "WARN: failed to add label '${1}' to ${REPO}#${NUM}" >&2
}
remove_label() {
    # remove_label LABEL — 404 is OK (label wasn't on the issue)
    gh api -X DELETE "repos/${REPO}/issues/${NUM}/labels/${1}" >/dev/null 2>&1 || true
}
add_assignee_to() {
    # add_assignee_to REPO ISSUE_OR_PR ASSIGNEE
    gh api -X POST "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to add assignee '${3}' to ${1}#${2}" >&2
}
remove_assignee_from() {
    # remove_assignee_from REPO ISSUE_OR_PR ASSIGNEE
    gh api -X DELETE "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || true
}

echo "==> triage/review: ${REPO}#${NUM}"

if [[ ! -d "${LOCAL_REPO}/.git" ]]; then
    echo "FATAL: local repo not found at ${LOCAL_REPO}" >&2
    exit 2
fi

git -C "${LOCAL_REPO}" fetch --quiet origin "pull/${NUM}/head:pr-${NUM}-review" || true
if [[ -e "${WORKTREE}" ]]; then
    git -C "${WORKTREE}" reset --hard "pr-${NUM}-review"
else
    git -C "${LOCAL_REPO}" worktree add "${WORKTREE}" "pr-${NUM}-review"
fi

PR_JSON=$(gh pr view "${NUM}" -R "${REPO}" --json title,body,baseRefName,headRefName,files,labels,assignees,isDraft,mergeStateStatus,author,closingIssuesReferences)
PR_AUTHOR=$(echo "${PR_JSON}" | jq -r '.author.login // ""')
DIFF=$(gh pr diff "${NUM}" -R "${REPO}")

PROMPT=$(cat <<PROMPT_EOF
You are reviewing PR #${NUM} of ${REPO}, checked out at ${WORKTREE}.

PR metadata (JSON):
${PR_JSON}

Diff:
${DIFF}

Content checks (binding — flag violations as needs-fix unless trivial):
- PR body must contain a closing keyword referencing an issue: \`closes #N\`, \`fixes #N\`, or \`resolves #N\` (cross-repo equivalents also OK). Missing link → needs-fix.
- Stay scoped to the originating issue. Drive-by refactors are needs-fix.

Out of scope for you (the wrapper enforces these — do NOT flag them as needs-fix):
- Assignment (wrapper sets agent login on dispatch).
- Draft state (wrapper flips ready-for-review after codex).
- Label hygiene (wrapper applies based on your VERDICT).

Review rules:
- Honor the repo's rules/guidelines.
- Look for correctness bugs, missing tests, security issues, vendor lock-in, doc drift.
- Run the repo's own checks where helpful.
- Do not run gh commands or make workflow decisions. The wrapper handles labels and assignment based on your verdict.
- Structure your output response exactly as follows (do not output any other content):

  ### Review Summary

  **Findings**
  1. [Finding description with file path and line context if applicable, or "None"]

  **Checks Run**
  - [List any checks run and their status, e.g., 'pytest: pass']

  VERDICT: [verdict]

- Your final stdout line must be exactly one of:
  VERDICT: merge-ready
  VERDICT: needs-fix - reason
  VERDICT: blocked - reason
PROMPT_EOF
)

if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
    echo "==> DRY RUN — would dispatch configured review CLI chain with prompt of $(echo "${PROMPT}" | wc -c) bytes"
    exit 0
fi

echo "==> marking review in progress"
ensure_workflow_labels
add_label "${NEEDS_REVIEW_LABEL}"

echo "==> dispatching to review fallback chain"
cd "${WORKTREE}"
REVIEW_OUT=$(mktemp)

load_cli_chain "${CONF_FILE}" "review" "claude" "codex" "agy"
CHAIN=("${CLI_CHAIN[@]}")

rc=1
for i in "${!CHAIN[@]}"; do
    TOOL="${CHAIN[i]}"
    STEP=$((i + 1))
    TOTAL=${#CHAIN[@]}
    
    echo "--> [${STEP}/${TOTAL}] attempting ${TOOL}..."
    
    if run_cli_tool "${CONF_FILE}" "${TOOL}" "${WORKTREE}" "${PROMPT}" "${REVIEW_OUT}"; then
        rc=0
    else
        rc=$?
    fi
    
    echo "--> ${TOOL} exit=${rc}"
    
    if [[ ${rc} -eq 0 ]]; then
        break
    fi
    
    if [[ ${rc} -ne 0 ]]; then
        if (( STEP < TOTAL )) && { [[ ${rc} -eq 127 ]] || grep -Eqi "auth|authenticate|oauth|permission|expired|limit|quota|429|too many requests|cooldown|overloaded|throttl" "${REVIEW_OUT}"; }; then
            echo "--> [${STEP}/${TOTAL}] ${TOOL} unavailable or rate-limited. falling back..."
            continue
        fi
        break
    fi
done

if [[ "${rc}" -eq 0 ]]; then
    LAST_LINE=$(awk 'NF { line=$0 } END { print line }' "${REVIEW_OUT}" | sed -E 's/[[:space:]]+$//')
    echo "==> agent final line: ${LAST_LINE:-<empty>}"
    
    review_flag="--comment"
    case "${LAST_LINE}" in
        "VERDICT: merge-ready"*)
            echo "==> merge-ready; labeling approved and assigning ${HUMAN_LOGIN}"
            remove_label "${NEEDS_REVIEW_LABEL}"
            remove_label "in-progress"
            remove_label "changes-requested"
            remove_label "blocked"
            add_label "approved"
            add_assignee_to "${REPO}" "${NUM}" "${HUMAN_LOGIN}"
            remove_assignee_from "${REPO}" "${NUM}" "${AGENT_LOGIN}"
            review_flag="--approve"

            # Request review from human
            echo "==> Requesting review from human ${HUMAN_LOGIN}"
            gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

            # Assign originating issues
            for issue_num in $(echo "${PR_JSON}" | jq -r '.closingIssuesReferences[].number' 2>/dev/null || true); do
                if [[ -n "${issue_num}" && "${issue_num}" != "null" ]]; then
                    echo "==> Handing over originating issue #${issue_num} to ${HUMAN_LOGIN}"
                    add_assignee_to "${REPO}" "${issue_num}" "${HUMAN_LOGIN}"
                    remove_assignee_from "${REPO}" "${issue_num}" "${AGENT_LOGIN}"
                fi
            done
            
            # Check for automerge and call merge.sh
            automerge="false"
            if [[ -f "${CONF_FILE}" ]]; then
                automerge=$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.automerge" "${REPO}" 2>/dev/null || echo "false")
            fi
            if [[ "${automerge}" == "True" || "${automerge}" == "true" ]]; then
                echo "==> automerge enabled for ${REPO}; executing merge.sh"
                "$(dirname "$0")/merge.sh" "${REPO}" "${NUM}" || true
            fi
            ;;
        "VERDICT: needs-fix"*)
            echo "==> needs-fix; labeling changes-requested"
            remove_label "${NEEDS_REVIEW_LABEL}"
            remove_label "approved"
            remove_label "blocked"
            add_label "changes-requested"
            review_flag="--request-changes"
            ;;
        "VERDICT: blocked"*)
            echo "==> blocked; labeling blocked and handing back to ${HUMAN_LOGIN}"
            remove_label "${NEEDS_REVIEW_LABEL}"
            remove_label "in-progress"
            remove_label "approved"
            remove_label "changes-requested"
            add_label "blocked"
            add_assignee_to "${REPO}" "${NUM}" "${HUMAN_LOGIN}"
            remove_assignee_from "${REPO}" "${NUM}" "${AGENT_LOGIN}"
            review_flag="--comment"

            # Request review from human
            echo "==> Requesting review from human ${HUMAN_LOGIN}"
            gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

            # Assign originating issues
            for issue_num in $(echo "${PR_JSON}" | jq -r '.closingIssuesReferences[].number' 2>/dev/null || true); do
                if [[ -n "${issue_num}" && "${issue_num}" != "null" ]]; then
                    echo "==> Handing over originating issue #${issue_num} to ${HUMAN_LOGIN}"
                    add_assignee_to "${REPO}" "${issue_num}" "${HUMAN_LOGIN}"
                    remove_assignee_from "${REPO}" "${issue_num}" "${AGENT_LOGIN}"
                fi
            done
            ;;
        *)
            echo "FATAL: missing or invalid VERDICT final line" >&2
            rm -f "${REVIEW_OUT}"
            exit 3
            ;;
    esac

    if [[ "${review_flag}" == "--approve" && "${PR_AUTHOR}" == "${AGENT_LOGIN}" ]]; then
        echo "==> PR authored by ${AGENT_LOGIN}; GitHub forbids self-approval. Submitting review as comment instead."
        review_flag="--comment"
    fi
    
    echo "==> submitting formal review to PR #${NUM}"
    CLEANED_OUT=$(mktemp)
    awk '
        /### Review Summary/ { p=NR }
        { lines[NR]=$0 }
        END {
            if (p) {
                start = p
            } else {
                # Fallback to checking tokens used or codex
                start = 1
                for (i=1; i<=NR; i++) {
                    if (lines[i] == "tokens used") {
                        start = i + 2
                        break
                    }
                    if (lines[i] == "codex") {
                        start = i + 1
                        break
                    }
                }
            }
            for (i=start; i<=NR; i++) {
                print lines[i]
            }
        }
    ' "${REVIEW_OUT}" > "${CLEANED_OUT}"

    gh pr review "${NUM}" -R "${REPO}" "${review_flag}" -F "${CLEANED_OUT}" >/dev/null 2>&1 || \
        echo "WARN: failed to submit review to ${REPO}#${NUM}" >&2
    rm -f "${CLEANED_OUT}"
fi
rm -f "${REVIEW_OUT}"
exit "${rc}"
