#!/usr/bin/env bash
# host/scripts/install-triage.sh — install Sagi triage pipeline on a host.
#
# Idempotent. Run as root on the VPS (or any host that should run the triage).
# - Copies scripts into /srv/wulfai/triage/bin/ from this repo
# - Installs systemd units from host/systemd/
# - Creates state dirs
# - Enables (but does not necessarily start) the timer
#
# After install:
#   systemctl status triage-tick.timer
#   /srv/wulfai/triage/bin/triage-tick.sh   # manual dry-run
#
# Real Codex/Claude dispatch is controlled by versioned drop-ins under
# host/systemd/triage-tick.service.d/. The production override (dispatch.conf)
# sets TRIAGE_ENABLE_DISPATCH=1 and is installed automatically by this script.
# To temporarily disable on a host, either remove the drop-in by hand
# (will be reinstalled on next run) or remove it from the repo.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE_DIR=/srv/wulfai/triage

echo "==> install from ${REPO_DIR}"

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

# scripts (already named correctly in the repo)
install -m 0755 "${REPO_DIR}/scripts/detect.py"   "${TRIAGE_DIR}/bin/detect.py"
install -m 0755 "${REPO_DIR}/scripts/tick.sh"     "${TRIAGE_DIR}/bin/tick.sh"
install -m 0755 "${REPO_DIR}/scripts/engineer.sh" "${TRIAGE_DIR}/bin/engineer.sh"
install -m 0755 "${REPO_DIR}/scripts/review.sh"   "${TRIAGE_DIR}/bin/review.sh"
install -m 0755 "${REPO_DIR}/scripts/merge.sh"    "${TRIAGE_DIR}/bin/merge.sh"
install -m 0644 "${REPO_DIR}/README.md"           "${TRIAGE_DIR}/README.md"

# systemd units
install -m 0644 "${REPO_DIR}/systemd/triage-tick.service" /etc/systemd/system/triage-tick.service
install -m 0644 "${REPO_DIR}/systemd/triage-tick.timer"   /etc/systemd/system/triage-tick.timer

# Versioned drop-ins (production overrides that belong in Git, not local edits).
# Sync the on-disk drop-in dirs to exactly what the repo ships:
#   - install every *.conf the repo carries for the unit
#   - delete any *.conf the host has that the repo does not, so historical
#     leftovers (like the old 5min OnUnitActiveSec override) can't silently
#     re-pin behavior on every restart
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
            install -m 0644 "${f}" "${dropin_dir}/$(basename "${f}")"
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
install -m 0644 "${REPO_DIR}/logrotate/wulfai-triage" /etc/logrotate.d/wulfai-triage

systemctl daemon-reload
systemctl enable triage-tick.timer

echo "==> installed. status:"
systemctl list-timers triage-tick.timer --no-pager || true

echo
echo "Next steps:"
echo "  systemctl start triage-tick.timer    # if not auto-started"
echo "  systemctl start triage-tick.service  # manual one-shot tick"
echo
echo "Dispatch is controlled by versioned drop-ins under host/systemd/triage-tick.service.d/."
echo "Production override (dispatch.conf) flips TRIAGE_ENABLE_DISPATCH=1 and HOME=/root."
echo "To dry-run, remove that drop-in from the repo and reinstall."
