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
    if gh api -X POST "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1; then
        return 0
    fi
    echo "WARN: failed to add assignee '${3}' to ${1}#${2}" >&2
    return 1
}
remove_assignee_from() {
    # remove_assignee_from REPO ISSUE_OR_PR ASSIGNEE
    gh api -X DELETE "repos/${1}/issues/${2}/assignees" -f "assignees[]=${3}" >/dev/null 2>&1 || \
        echo "WARN: failed to remove assignee '${3}' from ${1}#${2}" >&2
}
handoff_closing_issues() {
    local issue_repo issue_num

    while IFS='|' read -r issue_repo issue_num; do
        if [[ ! "${issue_repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
           [[ ! "${issue_num}" =~ ^[1-9][0-9]*$ ]]; then
            echo "WARN: skipping closing issue reference with incomplete or invalid repository identity: ${issue_repo:-<missing>}#${issue_num:-<missing>}" >&2
            continue
        fi

        echo "==> Handing over originating issue ${issue_repo}#${issue_num} to ${HUMAN_LOGIN}"
        if add_assignee_to "${issue_repo}" "${issue_num}" "${HUMAN_LOGIN}"; then
            remove_assignee_from "${issue_repo}" "${issue_num}" "${AGENT_LOGIN}"
        fi
    done < <(jq -r '.closingIssuesReferences[]? | [(if ((.repository.owner.login // "") != "" and (.repository.name // "") != "") then "\(.repository.owner.login)/\(.repository.name)" else "" end), (.number // "")] | join("|")' <<<"${PR_JSON}" 2>/dev/null || true)
}

remove_approved() {
    # A missing label and a successfully removed label are both safe states.
    local output
    if output=$(gh api -X DELETE "repos/${REPO}/issues/${NUM}/labels/approved" 2>&1); then
        return 0
    fi
    if grep -qiE 'HTTP 404|Not Found' <<<"${output}"; then
        return 0
    fi
    echo "WARN: could not ensure approved was absent from ${REPO}#${NUM}" >&2
    return 1
}

add_approved() {
    if ! gh api -X POST "repos/${REPO}/issues/${NUM}/labels" -f "labels[]=approved" >/dev/null 2>&1; then
        echo "WARN: failed to publish approved label to ${REPO}#${NUM}" >&2
        remove_approved || true
        return 1
    fi
}

approval_is_current_and_green() {
    # Refresh every mutable input at the publication boundary. The detector's
    # earlier observation is intentionally not trusted here.
    local live_json live_head live_base
    if ! live_json=$(gh pr view "${NUM}" -R "${REPO}" --json headRefOid,baseRefOid,statusCheckRollup,labels,isDraft,state,mergeStateStatus,mergeable); then
        echo "==> unable to refresh PR approval eligibility; deferring"
        return 1
    fi
    live_head=$(echo "${live_json}" | jq -r '.headRefOid // ""')
    live_base=$(echo "${live_json}" | jq -r '.baseRefOid // ""')
    if [[ "${live_head}" != "${REVIEW_SHA}" || "${live_base}" != "${BASE_SHA}" ]]; then
        echo "==> PR revision changed during review; deferring approval"
        return 1
    fi
    if [[ "$(echo "${live_json}" | jq -r '.state // ""')" != "OPEN" ]] || \
       [[ "$(echo "${live_json}" | jq -r '.isDraft // false')" == "true" ]]; then
        echo "==> PR is no longer open and ready for review; deferring approval"
        return 1
    fi
    if echo "${live_json}" | jq -e '.labels[]?.name | select(. == "blocked" or . == "do-not-merge" or . == "do-not-work")' >/dev/null; then
        echo "==> PR has a human stop label; deferring approval"
        return 1
    fi
    if ! echo "${live_json}" | jq -e '
        (.statusCheckRollup | type == "array" and length > 0) and
        all(.statusCheckRollup[];
            (.status == "COMPLETED" and
             ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED"))) or
            ((.state // "") == "SUCCESS"))
    ' >/dev/null; then
        echo "==> PR checks are missing, pending, red, or unknown; deferring approval"
        return 1
    fi
    local merge_state mergeable
    merge_state=$(echo "${live_json}" | jq -r '.mergeStateStatus // ""' | tr '[:lower:]' '[:upper:]')
    mergeable=$(echo "${live_json}" | jq -r '.mergeable // ""' | tr '[:lower:]' '[:upper:]')
    if [[ "${merge_state}" == "" || "${merge_state}" == "UNKNOWN" || \
          "${merge_state}" == "BEHIND" || "${merge_state}" == "DIRTY" || \
          "${mergeable}" != "MERGEABLE" ]]; then
        echo "==> PR mergeability is unknown, behind, or conflicting; deferring approval"
        return 1
    fi
}

submit_pinned_review() {
    # submit_pinned_review EVENT BODY_FILE
    gh api -X POST "repos/${REPO}/pulls/${NUM}/reviews" \
        -f "commit_id=${REVIEW_SHA}" -f "event=${1}" -F "body=@${2}" >/dev/null 2>&1
}

echo "==> triage/review: ${REPO}#${NUM}"

if [[ ! -d "${LOCAL_REPO}/.git" ]]; then
    echo "FATAL: local repo not found at ${LOCAL_REPO}" >&2
    exit 2
fi

REVIEW_REF="refs/remotes/origin/pr-${NUM}-review"
BASE_REF="refs/remotes/origin/pr-${NUM}-base-review"
PR_JSON=$(gh pr view "${NUM}" -R "${REPO}" --json title,body,baseRefName,baseRefOid,headRefName,headRefOid,files,labels,assignees,isDraft,mergeStateStatus,mergeable,author,closingIssuesReferences,statusCheckRollup,state)
REVIEW_SHA="$(echo "${PR_JSON}" | jq -r '.headRefOid // ""')"
BASE_SHA="$(echo "${PR_JSON}" | jq -r '.baseRefOid // ""')"
BASE_BRANCH="$(echo "${PR_JSON}" | jq -r '.baseRefName // ""')"
if [[ ! "${REVIEW_SHA}" =~ ^[0-9a-fA-F]{40}$ || ! "${BASE_SHA}" =~ ^[0-9a-fA-F]{40}$ ]] || \
   ! git check-ref-format "refs/heads/${BASE_BRANCH}" >/dev/null 2>&1; then
    echo "FATAL: PR metadata did not provide valid immutable head/base revisions" >&2
    exit 2
fi
git -C "${LOCAL_REPO}" fetch --quiet --force origin \
    "+pull/${NUM}/head:${REVIEW_REF}" \
    "+refs/heads/${BASE_BRANCH}:${BASE_REF}"
FETCHED_HEAD_SHA="$(git -C "${LOCAL_REPO}" rev-parse "${REVIEW_REF}")"
FETCHED_BASE_SHA="$(git -C "${LOCAL_REPO}" rev-parse "${BASE_REF}")"
if [[ "${FETCHED_HEAD_SHA}" != "${REVIEW_SHA}" || "${FETCHED_BASE_SHA}" != "${BASE_SHA}" ]]; then
    echo "==> PR head or base changed while capturing review snapshot; deferring review"
    exit 0
fi
if [[ -e "${WORKTREE}" ]]; then
    git -C "${WORKTREE}" checkout --detach "${REVIEW_SHA}"
    git -C "${WORKTREE}" reset --hard "${REVIEW_SHA}"
    git -C "${WORKTREE}" clean -fd
else
    git -C "${LOCAL_REPO}" worktree add --detach "${WORKTREE}" "${REVIEW_SHA}"
fi
CHECKED_OUT_SHA="$(git -C "${WORKTREE}" rev-parse HEAD)"
if [[ "${CHECKED_OUT_SHA}" != "${REVIEW_SHA}" ]]; then
    echo "FATAL: review checkout mismatch: expected ${REVIEW_SHA}, got ${CHECKED_OUT_SHA}" >&2
    exit 2
fi

PR_AUTHOR=$(echo "${PR_JSON}" | jq -r '.author.login // ""')
DIFF=$(git -C "${LOCAL_REPO}" diff --no-ext-diff --binary "${BASE_SHA}...${REVIEW_SHA}")

PROMPT=$(cat <<PROMPT_EOF
You are reviewing PR #${NUM} of ${REPO}, checked out at immutable head ${REVIEW_SHA}
against immutable base ${BASE_SHA} at ${WORKTREE}.

PR metadata (JSON):
${PR_JSON}

Diff:
${DIFF}

Content checks (binding — flag violations as needs-fix unless trivial):
- PR body must contain a closing keyword referencing an issue: \`closes #N\`, \`fixes #N\`, or \`resolves #N\` (cross-repo equivalents also OK). Missing link → needs-fix.
- Agent-authored PR titles must use Conventional Commits format such as \`fix: ...\`, \`feat: ...\`, or \`chore(scope): ...\`. Missing conventional title → needs-fix because releases derive SemVer from merged PR titles/squash commits.
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

LAST_LINE=""
review_verdict_is_valid() {
    case "${1}" in
        "VERDICT: merge-ready") return 0 ;;
        "VERDICT: needs-fix - "?*) return 0 ;;
        "VERDICT: blocked - "?*) return 0 ;;
        *) return 1 ;;
    esac
}

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
        LAST_LINE=$(awk 'NF { line=$0 } END { print line }' "${REVIEW_OUT}" | sed -E 's/[[:space:]]+$//')
        if review_verdict_is_valid "${LAST_LINE}"; then
            break
        fi
        echo "--> ${TOOL} returned success without a valid VERDICT final line: ${LAST_LINE:-<empty>}"
        rc=3
        if (( STEP < TOTAL )); then
            echo "--> [${STEP}/${TOTAL}] ${TOOL} produced invalid review output. falling back..."
            continue
        fi
        break
    fi
    
    if [[ ${rc} -ne 0 ]]; then
        if (( STEP < TOTAL )) && { [[ ${rc} -eq 127 ]] || cli_error_allows_fallback "${REVIEW_OUT}"; }; then
            echo "--> [${STEP}/${TOTAL}] ${TOOL} unavailable or rate-limited. falling back..."
            continue
        fi
        break
    fi
done

if [[ "${rc}" -eq 0 ]]; then
    echo "==> agent final line: ${LAST_LINE:-<empty>}"

    CLEANED_OUT=$(mktemp)
    awk '
        /### Review Summary/ { p=NR }
        { lines[NR]=$0 }
        END {
            if (p) {
                start = p
            } else {
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

    case "${LAST_LINE}" in
        "VERDICT: merge-ready"*)
            echo "==> merge-ready; refreshing head, CI, and stop labels"
            approval_published="false"
            if ! remove_approved; then
                rc=4
            elif ! approval_is_current_and_green; then
                remove_label "${NEEDS_REVIEW_LABEL}"
                # Preserve the evidence as a commit-pinned comment, but do not
                # publish approval state for an ineligible revision.
                submit_pinned_review "COMMENT" "${CLEANED_OUT}" || \
                    echo "WARN: failed to submit deferred review to ${REPO}#${NUM}" >&2
            else
                review_event="APPROVE"
                if [[ "${PR_AUTHOR}" == "${AGENT_LOGIN}" ]]; then
                    echo "==> PR authored by ${AGENT_LOGIN}; GitHub forbids self-approval. Submitting review as comment instead."
                    review_event="COMMENT"
                fi
                echo "==> submitting commit-pinned formal review to PR #${NUM}"
                if ! submit_pinned_review "${review_event}" "${CLEANED_OUT}"; then
                    echo "WARN: failed to publish review for ${REPO}#${NUM}; approval withheld" >&2
                    remove_approved || true
                    rc=4
                elif ! add_approved; then
                    rc=4
                elif ! approval_is_current_and_green; then
                    echo "WARN: approval eligibility changed during publication; removing approved" >&2
                    if ! remove_approved; then
                        rc=4
                    fi
                else
                    approval_published="true"
                fi
            fi

            if [[ "${approval_published}" == "true" ]]; then
                echo "==> approved reviewed commit ${REVIEW_SHA}; assigning ${HUMAN_LOGIN}"
                remove_label "${NEEDS_REVIEW_LABEL}"
                remove_label "in-progress"
                remove_label "changes-requested"
                add_assignee_to "${REPO}" "${NUM}" "${HUMAN_LOGIN}" || true
                remove_assignee_from "${REPO}" "${NUM}" "${AGENT_LOGIN}"

                # Request review from human
                echo "==> Requesting review from human ${HUMAN_LOGIN}"
                gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

                # Assign originating issues using each reference's canonical repository.
                handoff_closing_issues

                # Check for automerge and call merge.sh
                automerge="false"
                if [[ -f "${CONF_FILE}" ]]; then
                    automerge=$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.automerge" "${REPO}" 2>/dev/null || echo "false")
                fi
                if [[ "${automerge}" == "True" || "${automerge}" == "true" ]]; then
                    echo "==> automerge enabled for ${REPO}; executing merge.sh"
                    "$(dirname "$0")/merge.sh" "${REPO}" "${NUM}" "${REVIEW_SHA}" "${BASE_SHA}" || true
                fi
            fi
            ;;
        "VERDICT: needs-fix"*)
            echo "==> needs-fix; labeling changes-requested"
            remove_label "${NEEDS_REVIEW_LABEL}"
            remove_label "approved"
            remove_label "blocked"
            add_label "changes-requested"
            echo "==> submitting commit-pinned formal review to PR #${NUM}"
            submit_pinned_review "REQUEST_CHANGES" "${CLEANED_OUT}" || \
                echo "WARN: failed to submit review to ${REPO}#${NUM}" >&2
            ;;
        "VERDICT: blocked"*)
            echo "==> blocked; labeling blocked and handing back to ${HUMAN_LOGIN}"
            remove_label "${NEEDS_REVIEW_LABEL}"
            remove_label "in-progress"
            remove_label "approved"
            remove_label "changes-requested"
            add_label "blocked"
            add_assignee_to "${REPO}" "${NUM}" "${HUMAN_LOGIN}" || true
            remove_assignee_from "${REPO}" "${NUM}" "${AGENT_LOGIN}"

            # Request review from human
            echo "==> Requesting review from human ${HUMAN_LOGIN}"
            gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

            # Assign originating issues using each reference's canonical repository.
            handoff_closing_issues
            echo "==> submitting commit-pinned formal review to PR #${NUM}"
            submit_pinned_review "COMMENT" "${CLEANED_OUT}" || \
                echo "WARN: failed to submit review to ${REPO}#${NUM}" >&2
            ;;
    esac
    rm -f "${CLEANED_OUT}"
elif [[ "${rc}" -eq 3 ]]; then
    echo "==> invalid review output from all available tools; labeling blocked and handing back to ${HUMAN_LOGIN}"
    remove_label "${NEEDS_REVIEW_LABEL}"
    remove_label "in-progress"
    remove_label "approved"
    remove_label "changes-requested"
    add_label "blocked"
    add_assignee_to "${REPO}" "${NUM}" "${HUMAN_LOGIN}" || true
    remove_assignee_from "${REPO}" "${NUM}" "${AGENT_LOGIN}"
    gh api -X POST "repos/${REPO}/pulls/${NUM}/requested_reviewers" -f "reviewers[]=${HUMAN_LOGIN}" >/dev/null 2>&1 || true

    handoff_closing_issues

    CLEANED_OUT=$(mktemp)
    cat > "${CLEANED_OUT}" <<EOF
### Review Summary

**Findings**
1. Review automation did not return a valid final VERDICT line after trying the configured review chain. Last final line: ${LAST_LINE:-<empty>}

**Checks Run**
- Automated review dispatch: blocked

VERDICT: blocked - invalid review output from configured review chain
EOF
    submit_pinned_review "COMMENT" "${CLEANED_OUT}" || \
        echo "WARN: failed to submit invalid-output review comment to ${REPO}#${NUM}" >&2
    rm -f "${CLEANED_OUT}"
fi
rm -f "${REVIEW_OUT}"
exit "${rc}"
