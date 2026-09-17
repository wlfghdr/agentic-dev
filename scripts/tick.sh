#!/usr/bin/env bash
# scripts/tick.sh — orchestrator. Detects items, dispatches each as a transient
# systemd unit so multiple engineer/reviewer sessions can run in parallel.
# Idempotent via per-item locks; cap concurrency per kind.
set -euo pipefail

TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
BIN="${TRIAGE_DIR}/bin"
STATE="${TRIAGE_DIR}/state"
LOCKS="${STATE}/locks"
LOGDIR="${TRIAGE_DIR}/logs"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
MAX_ENGINEER="${TRIAGE_MAX_ENGINEER:-3}"
MAX_REVIEW="${TRIAGE_MAX_REVIEW:-2}"
MAX_MAINTENANCE="${TRIAGE_MAX_MAINTENANCE:-1}"
LOCK_TTL_HOURS="2"
DISPATCH_ENV_FILE="${TRIAGE_DISPATCH_ENV_FILE:-}"

if [[ -f "${CONF_FILE}" ]]; then
    CONF_MAX_ENG=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "limits.max_engineer" 2>/dev/null || true)
    CONF_MAX_REV=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "limits.max_review" 2>/dev/null || true)
    CONF_MAX_MAINT=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "limits.max_maintenance" 2>/dev/null || true)
    CONF_LOCK_TTL=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "limits.lock_ttl_hours" 2>/dev/null || true)
    CONF_DISPATCH_ENV_FILE=$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "runtime.dispatch_env_file" 2>/dev/null || true)

    if [[ -n "${CONF_MAX_ENG}" ]]; then MAX_ENGINEER="${CONF_MAX_ENG}"; fi
    if [[ -n "${CONF_MAX_REV}" ]]; then MAX_REVIEW="${CONF_MAX_REV}"; fi
    if [[ -n "${CONF_MAX_MAINT}" ]]; then MAX_MAINTENANCE="${CONF_MAX_MAINT}"; fi
    if [[ -n "${CONF_LOCK_TTL}" ]]; then LOCK_TTL_HOURS="${CONF_LOCK_TTL}"; fi
    if [[ -z "${DISPATCH_ENV_FILE}" && -n "${CONF_DISPATCH_ENV_FILE}" ]]; then
        DISPATCH_ENV_FILE="${CONF_DISPATCH_ENV_FILE}"
    fi
fi

if [[ -n "${DISPATCH_ENV_FILE}" && "${DISPATCH_ENV_FILE}" != /* ]]; then
    echo "FATAL: runtime.dispatch_env_file must be an absolute path" >&2
    exit 2
fi

if [[ -f "${BIN}/cli_dispatch.sh" ]]; then
    # shellcheck source=scripts/cli_dispatch.sh
    source "${BIN}/cli_dispatch.sh"
fi

LOCK_TTL=$((LOCK_TTL_HOURS * 3600))  # failsafe; cleanly-exited dispatchers drop their lock immediately
DISPATCH_ENABLED="${TRIAGE_ENABLE_DISPATCH:-0}"

TICK_LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-tick.log"
mkdir -p "${LOCKS}" "${LOGDIR}"

# Detection lock: serialize detection + lock-acquisition only.
# Dispatchers run as independent transient units, so the lock is released
# as soon as this tick exits — the next 60s tick can start immediately.
exec 9>"${STATE}/tick.lock"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        echo "tick already running, exit" >&2
        exit 0
    fi
else
    echo "WARN: flock not found, skipping concurrency lock" >&2
fi

count_running() {
    systemctl list-units --no-legend --state=running "agentic-dispatch-${1}-*.service" 2>/dev/null \
        | wc -l | tr -d ' '
}

cleanup_stale_locks() {
    local report="${1}"
    local lock slug

    shopt -s nullglob
    for lock in "${LOCKS}"/*.lock; do
        slug="$(basename "${lock}" .lock)"
        if ! echo "${report}" | jq -e --arg slug "${slug}" '.liveLockSlugs // [] | index($slug)' >/dev/null; then
            echo "WARN: removing stale lock ${slug} (not in liveLockSlugs)"
            rm -f "${lock}"
        fi
    done
    shopt -u nullglob
}

llm_chain_available() {
    # llm_chain_available CHAIN DEFAULT_TOOL... — false only when every CLI in
    # the chain is parked, so the dispatch would fail without doing any work.
    declare -F cli_chain_available >/dev/null || return 0
    load_cli_chain "${CONF_FILE}" "$@"
    cli_chain_available "${CLI_CHAIN[@]}"
}

run_housekeeping() {
    # Hourly: prune old logs. Every TRIAGE_WORKTREE_GC_HOURS: drop worktrees
    # of closed issues/PRs. Both are cheap to skip and unbounded if never run.
    local stamp="${STATE}/housekeeping.stamp"
    local now last gc_stamp gc_hours retention_days
    retention_days="${TRIAGE_LOG_RETENTION_DAYS:-14}"
    if [[ ! "${retention_days}" =~ ^[0-9]+$ ]]; then
        echo "WARN: ignoring invalid TRIAGE_LOG_RETENTION_DAYS='${retention_days}'" >&2
        retention_days=14
    fi
    now="$(date +%s)"
    last=0
    [[ -f "${stamp}" ]] && last="$(get_lock_mtime "${stamp}")"
    if (( now - last >= 3600 )); then
        touch "${stamp}"
        find "${LOGDIR}" -type f -mtime +"${retention_days}" -delete 2>/dev/null || true
    fi

    # Never evaluate unvalidated configuration inside (( )) — it would run
    # embedded command substitutions as root.
    gc_hours="${TRIAGE_WORKTREE_GC_HOURS:-6}"
    if [[ ! "${gc_hours}" =~ ^[0-9]+$ ]]; then
        echo "WARN: ignoring invalid TRIAGE_WORKTREE_GC_HOURS='${gc_hours}'" >&2
        gc_hours=6
    fi
    [[ "${DISPATCH_ENABLED}" == "1" && "${gc_hours}" != "0" && -x "${BIN}/gc_worktrees.sh" ]] || return 0
    gc_stamp="${STATE}/worktree-gc.stamp"
    last=0
    [[ -f "${gc_stamp}" ]] && last="$(get_lock_mtime "${gc_stamp}")"
    if (( now - last >= gc_hours * 3600 )); then
        touch "${gc_stamp}"
        "${BIN}/gc_worktrees.sh" || echo "WARN: worktree GC failed" >&2
    fi
}

get_lock_mtime() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %m "${1}"
    else
        stat -c %Y "${1}"
    fi
}

set +e  # the group below re-enables errexit; the pipeline status is handled after it
{
    set -e
    echo "==> tick start $(date -u +%FT%TZ)"
    echo "==> dispatch enabled: ${DISPATCH_ENABLED}"
    echo "==> caps: engineer=${MAX_ENGINEER} review=${MAX_REVIEW} maintenance=${MAX_MAINTENANCE}"
    echo

    run_housekeeping

    DETECT_STDOUT="$(mktemp)"
    DETECT_STDERR="$(mktemp)"
    if ! "${BIN}/detect.py" >"${DETECT_STDOUT}" 2>"${DETECT_STDERR}"; then
        cat "${DETECT_STDERR}" >&2 || true
        cat "${DETECT_STDOUT}" >&2 || true
        rm -f "${DETECT_STDOUT}" "${DETECT_STDERR}"
        exit 1
    fi
    cat "${DETECT_STDERR}" || true
    REPORT="$(cat "${DETECT_STDOUT}")"
    rm -f "${DETECT_STDOUT}" "${DETECT_STDERR}"

    COUNT=$(echo "${REPORT}" | jq '.itemCount')
    echo "==> detected ${COUNT} items"
    cleanup_stale_locks "${REPORT}"

    if [[ "${COUNT}" -eq 0 ]]; then
        echo "==> nothing to do"
        exit 0
    fi

    ENG_RUNNING=$(count_running engineer)
    REV_RUNNING=$(count_running review)
    MAINT_RUNNING=$(count_running dependabot)
    MAINT_RUNNING=$((MAINT_RUNNING + $(count_running release)))
    echo "==> in-flight: engineer=${ENG_RUNNING} review=${REV_RUNNING} maintenance=${MAINT_RUNNING}"

    # Use process substitution so ENG_RUNNING/REV_RUNNING survive the loop.
    while read -r ITEM; do
        KIND=$(echo "${ITEM}" | jq -r .kind)
        REPO=$(echo "${ITEM}" | jq -r .repo)
        NUM=$(echo "${ITEM}" | jq -r .number)
        URL=$(echo "${ITEM}" | jq -r .url)
        MODE=$(echo "${ITEM}" | jq -r '.mode // "issue"')
        SLUG="${KIND}-${REPO//\//_}-${NUM}"
        LOCK="${LOCKS}/${SLUG}.lock"

        if [[ -e "${LOCK}" ]]; then
            AGE=$(( $(date +%s) - $(get_lock_mtime "${LOCK}") ))
            if [[ "${AGE}" -lt "${LOCK_TTL}" ]]; then
                echo "skip ${KIND} ${REPO}#${NUM} — locked (age ${AGE}s)"
                continue
            fi
            echo "WARN: removing expired lock ${SLUG} (age ${AGE}s >= TTL ${LOCK_TTL}s)"
            rm -f "${LOCK}"
        fi

        case "${KIND}" in
            engineer)
                if (( ENG_RUNNING >= MAX_ENGINEER )); then
                    echo "skip ${KIND} ${REPO}#${NUM} — engineer cap reached (${ENG_RUNNING}/${MAX_ENGINEER})"
                    continue
                fi
                # Rebase first tries a deterministic git rebase, so it is never gated.
                if [[ "${MODE}" != "rebase" ]] && ! llm_chain_available engineer codex claude agy; then
                    echo "skip ${KIND} ${REPO}#${NUM} — every engineer CLI is parked (cooldown)"
                    continue
                fi
                SCRIPT="${BIN}/engineer.sh"
                case "${MODE}" in
                    pr)     CMD_ARGS=(--pr "${REPO}" "${NUM}") ;;
                    rebase) CMD_ARGS=(--rebase "${REPO}" "${NUM}") ;;
                    *)      CMD_ARGS=("${REPO}" "${NUM}") ;;
                esac
                ENG_RUNNING=$((ENG_RUNNING + 1))
                ;;
            review)
                if (( REV_RUNNING >= MAX_REVIEW )); then
                    echo "skip ${KIND} ${REPO}#${NUM} — review cap reached (${REV_RUNNING}/${MAX_REVIEW})"
                    continue
                fi
                if ! llm_chain_available review claude codex agy; then
                    echo "skip ${KIND} ${REPO}#${NUM} — every review CLI is parked (cooldown)"
                    continue
                fi
                SCRIPT="${BIN}/review.sh"
                CMD_ARGS=("${REPO}" "${NUM}")
                REV_RUNNING=$((REV_RUNNING + 1))
                ;;
            dependabot)
                if (( MAINT_RUNNING >= MAX_MAINTENANCE )); then
                    echo "skip ${KIND} ${REPO}#${NUM} — maintenance cap reached (${MAINT_RUNNING}/${MAX_MAINTENANCE})"
                    continue
                fi
                SCRIPT="${BIN}/dependabot_merge.sh"
                case "${MODE}" in
                    rebase) CMD_ARGS=(--rebase "${REPO}" "${NUM}") ;;
                    block)  CMD_ARGS=(--block "${REPO}" "${NUM}") ;;
                    *)      CMD_ARGS=("${REPO}" "${NUM}") ;;
                esac
                MAINT_RUNNING=$((MAINT_RUNNING + 1))
                ;;
            release)
                if (( MAINT_RUNNING >= MAX_MAINTENANCE )); then
                    echo "skip ${KIND} ${REPO}#${NUM} — maintenance cap reached (${MAINT_RUNNING}/${MAX_MAINTENANCE})"
                    continue
                fi
                SCRIPT="${BIN}/release.sh"
                CMD_ARGS=("${REPO}")
                MAINT_RUNNING=$((MAINT_RUNNING + 1))
                ;;
            *)
                echo "unknown kind: ${KIND}"
                continue
                ;;
        esac

        echo "==> dispatch ${KIND}/${MODE} ${REPO}#${NUM} — ${URL}"
        touch "${LOCK}"

        if [[ "${DISPATCH_ENABLED}" != "1" ]]; then
            echo "    DRY RUN (TRIAGE_ENABLE_DISPATCH != 1) — releasing lock"
            rm -f "${LOCK}"
            continue
        fi

        UNIT="agentic-dispatch-${SLUG}.service"

        SYSTEMD_PROPERTIES=(
            --property=TimeoutStartSec=6h
            --property=KillMode=mixed
        )
        if [[ -n "${DISPATCH_ENV_FILE}" ]]; then
            # A missing optional credentials file must not prevent dispatch.
            SYSTEMD_PROPERTIES+=(--property="EnvironmentFile=-${DISPATCH_ENV_FILE}")
        fi

        # Build a one-line bash command that runs the script and drops the lock on success.
        # %q-quote each arg so spaces / shell metachars in titles never bite.
        printf -v QUOTED_ARGS '%q ' "${CMD_ARGS[@]}"
        WRAPPED="${SCRIPT} ${QUOTED_ARGS}; rc=\$?; if [ \$rc -eq 0 ]; then rm -f $(printf '%q' "${LOCK}"); else touch -d \"@\$(( \$(date +%s) - ${LOCK_TTL} + 1200 ))\" $(printf '%q' "${LOCK}"); fi; exit \$rc"

        # Forward HOME and triage configuration variables so the dispatched unit 
        # can read configuration, resolve correct paths, and use git credentials.
        if ! systemd-run \
            --no-block \
            --collect \
            --unit="${UNIT}" \
            --description="triage dispatch ${KIND}/${MODE} ${REPO}#${NUM}" \
            --setenv=TRIAGE_ENABLE_DISPATCH=1 \
            --setenv="HOME=${HOME:-/root}" \
            --setenv="TRIAGE_DIR=${TRIAGE_DIR}" \
            --setenv="TRIAGE_REPOS_DIR=${TRIAGE_REPOS_DIR:-/srv/agentic-dev/../repos}" \
            --setenv="TRIAGE_WORKTREES_DIR=${TRIAGE_WORKTREES_DIR:-/srv/agentic-dev/../worktrees}" \
            --setenv="TRIAGE_CONFIG=${CONF_FILE}" \
            "${SYSTEMD_PROPERTIES[@]}" \
            /bin/bash -c "${WRAPPED}"; then
            echo "WARN: systemd-run failed for ${UNIT}; releasing lock" >&2
            rm -f "${LOCK}"
        fi
    done < <(echo "${REPORT}" | jq -c '.items[]')

    echo "==> tick done $(date -u +%FT%TZ)"
} 2>&1 | tee "${TICK_LOG}"
rc=${PIPESTATUS[0]}
set -e

# Output is in the journal either way; keep a file only for ticks that acted,
# warned, or failed instead of one file per idle minute.
if [[ "${rc}" -eq 0 ]] && ! grep -Eq '^==> dispatch [a-z]+/|WARN|FATAL|\[fatal\]|\[demote\]' "${TICK_LOG}"; then
    rm -f "${TICK_LOG}"
fi
exit "${rc}"
