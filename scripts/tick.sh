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
LOCK_TTL_HOURS="2"

if [[ -f "${CONF_FILE}" ]]; then
    CONF_MAX_ENG=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(d.get('limits', {}).get('max_engineer', ''))" "${CONF_FILE}" 2>/dev/null || true)
    CONF_MAX_REV=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(d.get('limits', {}).get('max_review', ''))" "${CONF_FILE}" 2>/dev/null || true)
    CONF_LOCK_TTL=$(python3 -c "import tomllib, sys; d=tomllib.load(open(sys.argv[1], 'rb')); print(d.get('limits', {}).get('lock_ttl_hours', ''))" "${CONF_FILE}" 2>/dev/null || true)

    if [[ -n "${CONF_MAX_ENG}" ]]; then MAX_ENGINEER="${CONF_MAX_ENG}"; fi
    if [[ -n "${CONF_MAX_REV}" ]]; then MAX_REVIEW="${CONF_MAX_REV}"; fi
    if [[ -n "${CONF_LOCK_TTL}" ]]; then LOCK_TTL_HOURS="${CONF_LOCK_TTL}"; fi
fi

LOCK_TTL=$((LOCK_TTL_HOURS * 3600))  # failsafe; cleanly-exited dispatchers drop their lock immediately
DISPATCH_ENABLED="${TRIAGE_ENABLE_DISPATCH:-0}"

TICK_LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-tick.log"
mkdir -p "${LOCKS}" "${LOGDIR}"

# Detection lock: serialize detection + lock-acquisition only.
# Dispatchers run as independent transient units, so the lock is released
# as soon as this tick exits — the next 60s tick can start immediately.
exec 9>"${STATE}/tick.lock"
if ! flock -n 9; then
    echo "tick already running, exit" >&2
    exit 0
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

{
    echo "==> tick start $(date -u +%FT%TZ)"
    echo "==> dispatch enabled: ${DISPATCH_ENABLED}"
    echo "==> caps: engineer=${MAX_ENGINEER} review=${MAX_REVIEW}"
    echo

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
    echo "==> in-flight: engineer=${ENG_RUNNING} review=${REV_RUNNING}"

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
            AGE=$(( $(date +%s) - $(stat -c %Y "${LOCK}") ))
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
                SCRIPT="${BIN}/review.sh"
                CMD_ARGS=("${REPO}" "${NUM}")
                REV_RUNNING=$((REV_RUNNING + 1))
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
            --setenv="TRIAGE_AGENT_LOGIN=${AGENT_LOGIN}" \
            --setenv="TRIAGE_HUMAN_LOGIN=${HUMAN_LOGIN}" \
            --property=TimeoutStartSec=6h \
            --property=KillMode=mixed \
            /bin/bash -c "${WRAPPED}"; then
            echo "WARN: systemd-run failed for ${UNIT}; releasing lock" >&2
            rm -f "${LOCK}"
        fi
    done < <(echo "${REPORT}" | jq -c '.items[]')

    echo "==> tick done $(date -u +%FT%TZ)"
} 2>&1 | tee "${TICK_LOG}"
