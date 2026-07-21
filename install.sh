#!/usr/bin/env bash
# scripts/install.sh — install agentic-dev triage pipeline on a host.
#
# Idempotent. Run as root on the VPS (or any host that should run the triage).
# - Copies scripts into /srv/agentic-dev/bin/ from this repo
# - Installs systemd units from systemd/
# - Creates state dirs
# - Enables (but does not necessarily start) the timer
#
# After install:
#   systemctl status triage-tick.timer
#   /srv/agentic-dev/bin/tick.sh   # manual dry-run
#
# Real agent CLI dispatch is controlled by versioned drop-ins under
# systemd/triage-tick.service.d/. The production override (dispatch.conf)
# sets TRIAGE_ENABLE_DISPATCH=1 and is installed automatically by this script.
# To temporarily disable on a host, either remove the drop-in by hand
# (will be reinstalled on next run) or remove it from the repo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
TRIAGE_REPOS_DIR="${TRIAGE_REPOS_DIR:-/srv/wulfai/repos}"
TRIAGE_WORKTREES_DIR="${TRIAGE_WORKTREES_DIR:-/srv/wulfai/worktrees}"

escape_sed_replacement() {
    printf '%s' "${1}" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g'
}

escape_systemd_value() {
    printf '%s' "${1}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

escape_systemd_replacement() {
    local value
    value="$(escape_systemd_value "${1}")"
    escape_sed_replacement "${value}"
}

echo "==> install from ${REPO_DIR} to ${TRIAGE_DIR}"

mkdir -p "${TRIAGE_DIR}/bin" \
         "${TRIAGE_DIR}/state/queue" \
         "${TRIAGE_DIR}/state/in-progress" \
         "${TRIAGE_DIR}/state/done" \
         "${TRIAGE_DIR}/state/locks" \
         "${TRIAGE_DIR}/state/history" \
         "${TRIAGE_DIR}/logs"

# install triage.toml template if it doesn't exist
if [[ ! -f "${TRIAGE_DIR}/triage.toml" ]]; then
    echo "==> installing default triage.toml"
    install -m 0644 "${REPO_DIR}/triage.toml" "${TRIAGE_DIR}/triage.toml"
else
    echo "==> triage.toml already exists, skipping template overwrite"
fi

# scripts (compiled with dynamic path substitutions)
triage_dir_escaped="$(escape_sed_replacement "${TRIAGE_DIR}")"
for script in detect.py tick.sh engineer.sh review.sh merge.sh cli_dispatch.sh parse_toml.py; do
    sed "s|/srv/agentic-dev|${triage_dir_escaped}|g" "${REPO_DIR}/scripts/${script}" > "/tmp/${script}"
    install -m 0755 "/tmp/${script}" "${TRIAGE_DIR}/bin/${script}"
    rm -f "/tmp/${script}"
done
install -m 0644 "${REPO_DIR}/README.md"           "${TRIAGE_DIR}/README.md"

render_template() {
    # render_template SOURCE DEST
    local triage_dir_escaped
    local repos_dir_escaped
    local worktrees_dir_escaped
    triage_dir_escaped="$(escape_systemd_replacement "${TRIAGE_DIR}")"
    repos_dir_escaped="$(escape_systemd_replacement "${TRIAGE_REPOS_DIR}")"
    worktrees_dir_escaped="$(escape_systemd_replacement "${TRIAGE_WORKTREES_DIR}")"
    sed \
        -e "s|/srv/agentic-dev|${triage_dir_escaped}|g" \
        -e "s|@TRIAGE_REPOS_DIR@|${repos_dir_escaped}|g" \
        -e "s|@TRIAGE_WORKTREES_DIR@|${worktrees_dir_escaped}|g" \
        "${1}" > "${2}"
}

# systemd units
render_template "${REPO_DIR}/systemd/triage-tick.service" /tmp/triage-tick.service
install -m 0644 /tmp/triage-tick.service /etc/systemd/system/triage-tick.service
rm -f /tmp/triage-tick.service
install -m 0644 "${REPO_DIR}/systemd/triage-tick.timer"   /etc/systemd/system/triage-tick.timer

# Versioned drop-ins (production overrides that belong in Git, not local edits).
# Sync the on-disk drop-in dirs to exactly what the repo ships:
#   - install every *.conf the repo carries for the unit
#   - delete any *.conf the host has that the repo does not, so historical
#     leftovers can't silently re-pin behavior on every restart
#   - remove the drop-in dir if the repo has nothing for the unit
for unit in triage-tick.timer triage-tick.service; do
    src_dir="${REPO_DIR}/systemd/${unit}.d"
    dropin_dir="/etc/systemd/system/${unit}.d"

    if [[ -d "${src_dir}" ]]; then
        mkdir -p "${dropin_dir}"
        # install repo-shipped drop-ins
        repo_files=()
        for f in "${src_dir}"/*.conf; do
            [[ -e "${f}" ]] || continue
            render_template "${f}" "/tmp/$(basename "${f}")"
            install -m 0644 "/tmp/$(basename "${f}")" "${dropin_dir}/$(basename "${f}")"
            rm -f "/tmp/$(basename "${f}")"
            repo_files+=("$(basename "${f}")")
        done
        # drop stray on-host drop-ins not present in repo
        for f in "${dropin_dir}"/*.conf; do
            [[ -e "${f}" ]] || continue
            base="$(basename "${f}")"
            skip=0
            for known in "${repo_files[@]:-}"; do
                [[ "${base}" == "${known}" ]] && { skip=1; break; }
            done
            (( skip )) || rm -f "${f}"
        done
    elif [[ -d "${dropin_dir}" ]]; then
        # repo carries no drop-ins for this unit -> clear the dir
        rm -f "${dropin_dir}"/*.conf
        rmdir "${dropin_dir}" 2>/dev/null || true
    fi
done

# local log retention
sed "s|/srv/agentic-dev|${triage_dir_escaped}|g" "${REPO_DIR}/logrotate/agentic-triage" > /tmp/agentic-triage
install -m 0644 /tmp/agentic-triage /etc/logrotate.d/agentic-triage
rm -f /tmp/agentic-triage

systemctl daemon-reload
systemctl enable triage-tick.timer

echo "==> installed. status:"
systemctl list-timers triage-tick.timer --no-pager || true

echo
echo "Next steps:"
echo "  systemctl start triage-tick.timer    # if not auto-started"
echo "  systemctl start triage-tick.service  # manual one-shot tick"
echo
echo "Dispatch is controlled by versioned drop-ins under systemd/triage-tick.service.d/."
echo "Production override (dispatch.conf) flips TRIAGE_ENABLE_DISPATCH=1 and HOME=/root."
echo "To dry-run, remove that drop-in from the repo and reinstall."
