#!/usr/bin/env bash
# scripts/release.sh REPO
# Create at most one deterministic GitHub release per repo per UTC day, if the
# default branch has commits after the latest semver tag.
set -euo pipefail

REPO="${1:?repo required}"
REPO_NAME="${REPO##*/}"

TRIAGE_DIR="${TRIAGE_DIR:-/srv/agentic-dev}"
CONF_FILE="${TRIAGE_CONFIG:-${TRIAGE_DIR}/triage.toml}"
LOCAL_REPO="${TRIAGE_REPOS_DIR:-/srv/agentic-dev/../repos}/${REPO_NAME}"
STATE_DIR="${TRIAGE_STATE_DIR:-${TRIAGE_DIR}/state}"
LOGDIR="${TRIAGE_DIR}/logs"
LOG="${LOGDIR}/$(date -u +%Y%m%d-%H%M%S)-release-${REPO_NAME}.log"
TODAY_UTC="$(date -u +%F)"
STATE_FILE="${STATE_DIR}/release/${REPO//\//_}.json"

mkdir -p "${LOGDIR}" "$(dirname "${STATE_FILE}")"
exec >"${LOG}" 2>&1

echo "==> triage/release: ${REPO}"

if [[ "${TRIAGE_ENABLE_DISPATCH:-0}" != "1" ]]; then
    echo "==> DRY RUN — would evaluate daily release"
    exit 0
fi

if [[ ! -d "${LOCAL_REPO}/.git" ]]; then
    echo "FATAL: local repo not found at ${LOCAL_REPO}" >&2
    exit 2
fi

release_enabled="false"
if [[ -f "${CONF_FILE}" ]]; then
    release_enabled="$(python3 "$(dirname "${BASH_SOURCE[0]}")/parse_toml.py" "${CONF_FILE}" "repos.release" "${REPO}" 2>/dev/null || echo "false")"
fi
if [[ "${release_enabled}" != "True" && "${release_enabled}" != "true" ]]; then
    echo "==> releases disabled for ${REPO}"
    exit 0
fi

if [[ -f "${STATE_FILE}" ]] && jq -e --arg today "${TODAY_UTC}" '.date == $today' "${STATE_FILE}" >/dev/null 2>&1; then
    echo "==> daily release already evaluated on ${TODAY_UTC}"
    exit 0
fi

DEFAULT_BRANCH="$(gh repo view "${REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name // "main"')"
git -C "${LOCAL_REPO}" fetch --quiet --tags origin "${DEFAULT_BRANCH}"
HEAD_SHA="$(git -C "${LOCAL_REPO}" rev-parse "origin/${DEFAULT_BRANCH}")"
LATEST_TAG="$(gh release list -R "${REPO}" --limit 100 --json tagName \
    --jq '[.[].tagName | select(test("^v[0-9]+\\\\.[0-9]+\\\\.[0-9]+$"))][0] // ""')"

if [[ -n "${LATEST_TAG}" ]] && [[ -z "$(git -C "${LOCAL_REPO}" log --format=%H "${LATEST_TAG}..origin/${DEFAULT_BRANCH}")" ]]; then
    echo "==> no commits since latest release tag ${LATEST_TAG}"
    exit 0
fi

base_version() {
    if [[ -n "${LATEST_TAG}" ]]; then
        printf '%s\n' "${LATEST_TAG#v}"
        return
    fi
    if [[ -f "${LOCAL_REPO}/VERSION" ]]; then
        tr -d '[:space:]' < "${LOCAL_REPO}/VERSION"
        return
    fi
    printf '0.0.0\n'
}

commit_range() {
    if [[ -n "${LATEST_TAG}" ]]; then
        printf '%s..origin/%s\n' "${LATEST_TAG}" "${DEFAULT_BRANCH}"
    else
        printf 'origin/%s\n' "${DEFAULT_BRANCH}"
    fi
}

determine_bump() {
    local range="${1}"
    local bump="patch"
    local subject body
    local breaking_re='^[a-zA-Z]+(\([^)]+\))?!:'
    local feature_re='^feat(\([^)]+\))?:'

    while IFS= read -r subject; do
        if [[ "${subject}" =~ ${breaking_re} ]] || [[ "${subject}" == *"BREAKING CHANGE"* ]]; then
            echo "major"
            return
        fi
        if [[ "${subject}" =~ ${feature_re} ]]; then
            bump="minor"
        fi
    done < <(git -C "${LOCAL_REPO}" log --format=%s "${range}")

    body="$(git -C "${LOCAL_REPO}" log --format=%B "${range}")"
    if grep -q 'BREAKING CHANGE' <<<"${body}"; then
        echo "major"
        return
    fi
    echo "${bump}"
}

next_version() {
    local version="${1}"
    local bump="${2}"
    local major minor patch
    IFS=. read -r major minor patch <<<"${version}"
    major="${major:-0}"
    minor="${minor:-0}"
    patch="${patch:-0}"
    case "${bump}" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        *)     patch=$((patch + 1)) ;;
    esac
    printf 'v%s.%s.%s\n' "${major}" "${minor}" "${patch}"
}

range="$(commit_range)"
commits="$(git -C "${LOCAL_REPO}" log --format='- %s (%h)' "${range}")"
if [[ -z "${commits}" ]]; then
    echo "==> no commits to release"
    exit 0
fi

bump="$(determine_bump "${range}")"
tag="$(next_version "$(base_version)" "${bump}")"

if git -C "${LOCAL_REPO}" rev-parse --verify --quiet "${tag}" >/dev/null; then
    echo "FATAL: computed tag ${tag} already exists" >&2
    exit 3
fi

notes="$(mktemp)"
{
    printf 'Automated daily release for `%s`.\n\n' "${REPO}"
    printf 'Semver bump: `%s`.\n\n' "${bump}"
    printf 'Changes:\n'
    printf '%s\n' "${commits}"
} > "${notes}"

echo "==> creating release ${tag} from ${HEAD_SHA} (${bump})"
gh release create "${tag}" \
    -R "${REPO}" \
    --target "${HEAD_SHA}" \
    --title "${tag}" \
    --notes-file "${notes}"
rm -f "${notes}"

jq -n \
    --arg date "${TODAY_UTC}" \
    --arg repo "${REPO}" \
    --arg tag "${tag}" \
    --arg sha "${HEAD_SHA}" \
    '{date: $date, repo: $repo, tag: $tag, headSha: $sha}' > "${STATE_FILE}"
echo "==> release ${tag} created"
