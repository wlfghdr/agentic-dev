#!/usr/bin/env bash
# scripts/release.sh REPO
# Create at most one deterministic GitHub release per repo per UTC day, if the
# default branch has commits after the latest semver tag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release_lib.sh
source "${SCRIPT_DIR}/release_lib.sh"

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
    release_enabled="$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "release.enabled" 2>/dev/null || echo "false")"
fi
if [[ "${release_enabled}" != "True" && "${release_enabled}" != "true" ]]; then
    echo "==> releases globally disabled"
    exit 0
fi

repo_release_enabled="false"
if [[ -f "${CONF_FILE}" ]]; then
    repo_release_enabled="$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.release" "${REPO}" 2>/dev/null || echo "false")"
fi
if [[ "${repo_release_enabled}" != "True" && "${repo_release_enabled}" != "true" ]]; then
    echo "==> releases disabled for ${REPO}"
    exit 0
fi

VERSION_SOURCE=""
if [[ -f "${CONF_FILE}" ]]; then
    VERSION_SOURCE="$(python3 "${SCRIPT_DIR}/parse_toml.py" "${CONF_FILE}" "repos.version_source" "${REPO}" 2>/dev/null || true)"
fi

if [[ -f "${STATE_FILE}" ]] && jq -e --arg today "${TODAY_UTC}" '.date == $today' "${STATE_FILE}" >/dev/null 2>&1; then
    echo "==> daily release already evaluated on ${TODAY_UTC}"
    exit 0
fi

DEFAULT_BRANCH="$(gh repo view "${REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name // "main"')"
git -C "${LOCAL_REPO}" fetch --quiet --tags origin "${DEFAULT_BRANCH}"
HEAD_SHA="$(git -C "${LOCAL_REPO}" rev-parse "origin/${DEFAULT_BRANCH}")"
LATEST_RELEASES="$(gh api --paginate --slurp -H "Accept: application/vnd.github+json" \
    "repos/${REPO}/releases?per_page=100")"
LATEST_TAG="$(latest_stable_release_tag <<<"${LATEST_RELEASES}")"

if [[ -n "${LATEST_TAG}" ]] && [[ -z "$(git -C "${LOCAL_REPO}" log --format=%H "${LATEST_TAG}..origin/${DEFAULT_BRANCH}")" ]]; then
    echo "==> no commits since latest release tag ${LATEST_TAG}"
    exit 0
fi

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
    local line
    local breaking_re='^[a-zA-Z]+(\([^)]+\))?!:'
    local feature_re='^feat(\([^)]+\))?:'

    while IFS= read -r line; do
        if [[ "${line}" =~ ${breaking_re} ]] || [[ "${line}" == *"BREAKING CHANGE"* ]]; then
            echo "major"
            return
        fi
        if [[ "${line}" =~ ${feature_re} ]]; then
            bump="minor"
        fi
    done < <(git -C "${LOCAL_REPO}" log --format=%B "${range}")
    echo "${bump}"
}

app_version() {
    local source="${1}"
    local values=""
    local version=""
    local semver_re='^[0-9]+(\.[0-9]+){0,2}$'

    case "${source}" in
        ios)
            values="$(git -C "${LOCAL_REPO}" grep -h 'MARKETING_VERSION' "origin/${DEFAULT_BRANCH}" -- '*.pbxproj' 2>/dev/null \
                | sed -E 's/.*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^;]+);.*/\1/' \
                | tr -d ' \t"' | sort -u)"
            ;;
        android)
            values="$(git -C "${LOCAL_REPO}" grep -h 'versionName' "origin/${DEFAULT_BRANCH}" -- '*.gradle.kts' '*.gradle' 2>/dev/null \
                | sed -E 's/.*versionName[[:space:]]*=?[[:space:]]*"([^"]+)".*/\1/' \
                | tr -d ' \t' | sort -u)"
            ;;
        *)
            echo "FATAL: unknown version_source '${source}'" >&2
            exit 5
            ;;
    esac

    if [[ -z "${values}" ]]; then
        echo "FATAL: version_source '${source}' configured but no version found in ${REPO}" >&2
        exit 5
    fi
    if [[ "$(wc -l <<<"${values}")" -ne 1 ]]; then
        echo "FATAL: conflicting app versions in ${REPO}: $(tr '\n' ' ' <<<"${values}")" >&2
        exit 5
    fi

    version="${values}"
    if [[ ! "${version}" =~ ${semver_re} ]]; then
        echo "FATAL: unparsable app version '${version}' in ${REPO}" >&2
        exit 5
    fi
    case "${version}" in
        *.*.*) ;;
        *.*) version="${version}.0" ;;
        *) version="${version}.0.0" ;;
    esac
    printf '%s\n' "${version}"
}

version_file_version() {
    local version
    if ! version="$(git -C "${LOCAL_REPO}" show "origin/${DEFAULT_BRANCH}:VERSION" 2>/dev/null | tr -d '[:space:]')"; then
        echo "FATAL: version_source='version' requires VERSION on ${DEFAULT_BRANCH}" >&2
        exit 5
    fi
    printf '%s\n' "${version}"
}

config_yaml_version() {
    local values
    if ! values="$(git -C "${LOCAL_REPO}" show "origin/${DEFAULT_BRANCH}:CONFIG.yaml" 2>/dev/null \
        | sed -nE 's/^[[:space:]]*framework_version:[[:space:]]*([^#]+).*$/\1/p' \
        | tr -d "[:space:]\"'")"; then
        echo "FATAL: version_source='config_yaml' requires CONFIG.yaml on ${DEFAULT_BRANCH}" >&2
        exit 5
    fi
    if [[ -z "${values}" ]] || [[ "$(wc -l <<<"${values}")" -ne 1 ]]; then
        echo "FATAL: CONFIG.yaml must contain exactly one strict framework_version" >&2
        exit 5
    fi
    printf '%s\n' "${values}"
}

validate_strict_version() {
    local version="${1}"
    local source="${2}"
    local semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
    if [[ ! "${version}" =~ ${semver_re} ]]; then
        echo "FATAL: ${source} must be strict numeric SemVer (MAJOR.MINOR.PATCH), got '${version}'" >&2
        exit 4
    fi
}

validate_plugin_manifests() {
    local expected="${1}"
    local path manifest_version
    while IFS= read -r path; do
        [[ "${path##*/}" == "plugin.json" ]] || continue
        if ! manifest_version="$(git -C "${LOCAL_REPO}" show "origin/${DEFAULT_BRANCH}:${path}" | jq -er '.version | strings')"; then
            echo "FATAL: packaged manifest ${path} has no string version" >&2
            exit 6
        fi
        if [[ "${manifest_version}" != "${expected}" ]]; then
            echo "FATAL: packaged manifest ${path} is ${manifest_version}, expected ${expected}" >&2
            echo "       reconcile release metadata in a pull request before publishing" >&2
            exit 6
        fi
    done < <(git -C "${LOCAL_REPO}" ls-tree -r --name-only "origin/${DEFAULT_BRANCH}")
}

changelog_notes() {
    local version="${1}"
    local changelog
    if ! changelog="$(git -C "${LOCAL_REPO}" show "origin/${DEFAULT_BRANCH}:CHANGELOG.md" 2>/dev/null)"; then
        echo "FATAL: authoritative releases require CHANGELOG.md" >&2
        exit 6
    fi
    awk -v version="${version}" '
        BEGIN { target = "## [" version "]" }
        substr($0, 1, length(target)) == target &&
            (length($0) == length(target) || substr($0, length(target) + 1, 1) ~ /[[:space:]]/) { found=1 }
        found && $0 ~ "^## \\[" && substr($0, 1, length(target)) != target { exit }
        found { print }
        END { if (!found) exit 7 }
    ' <<<"${changelog}" || {
        echo "FATAL: CHANGELOG.md has no release section for ${version}" >&2
        echo "       prepare version and release notes together through a pull request" >&2
        exit 6
    }
}

has_established_version_contract() {
    git -C "${LOCAL_REPO}" cat-file -e "origin/${DEFAULT_BRANCH}:VERSION" 2>/dev/null ||
        git -C "${LOCAL_REPO}" cat-file -e "origin/${DEFAULT_BRANCH}:CONFIG.yaml" 2>/dev/null ||
        git -C "${LOCAL_REPO}" ls-tree -r --name-only "origin/${DEFAULT_BRANCH}" | grep -E '(^|/)plugin\.json$' >/dev/null ||
        git -C "${LOCAL_REPO}" grep -q 'MARKETING_VERSION' "origin/${DEFAULT_BRANCH}" -- '*.pbxproj' 2>/dev/null ||
        git -C "${LOCAL_REPO}" grep -q 'versionName' "origin/${DEFAULT_BRANCH}" -- '*.gradle' '*.gradle.kts' 2>/dev/null
}

version_is_newer() {
    local candidate="v${1}"
    local latest="${2}"
    [[ -z "${latest}" ]] && return 0
    [[ "${candidate}" != "${latest}" ]] &&
        [[ "$(printf '%s\n%s\n' "${candidate}" "${latest}" | jq -Rrsc '
            split("\n")[:-1]
            | sort_by(.[1:] | split(".") | map(tonumber))
            | last
        ')" == "${candidate}" ]]
}

next_version() {
    local version="${1}"
    local bump="${2}"
    local major minor patch
    local semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
    if [[ ! "${version}" =~ ${semver_re} ]]; then
        echo "FATAL: invalid base version '${version}'" >&2
        exit 4
    fi
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

if [[ -z "${VERSION_SOURCE}" ]]; then
    if has_established_version_contract; then
        echo "FATAL: ${REPO} has release metadata but no version_source adapter" >&2
        echo "       configure version, config_yaml, ios, android, or conventional explicitly" >&2
        exit 5
    fi
    VERSION_SOURCE="conventional"
fi

if [[ "${VERSION_SOURCE}" == "conventional" ]]; then
    bump="$(determine_bump "${range}")"
    base_version="${LATEST_TAG#v}"
    base_version="${base_version:-0.0.0}"
    tag="$(next_version "${base_version}" "${bump}")"
    bump_note="Semver bump: \`${bump}\`."
    release_notes=""
else
    case "${VERSION_SOURCE}" in
        version) authoritative_version="$(version_file_version)" ;;
        config_yaml) authoritative_version="$(config_yaml_version)" ;;
        ios|android) authoritative_version="$(app_version "${VERSION_SOURCE}")" ;;
        *)
            echo "FATAL: unknown version_source '${VERSION_SOURCE}'" >&2
            exit 5
            ;;
    esac
    validate_strict_version "${authoritative_version}" "version_source '${VERSION_SOURCE}'"
    validate_plugin_manifests "${authoritative_version}"
    release_notes="$(changelog_notes "${authoritative_version}")"
    tag="v${authoritative_version}"
    bump="${VERSION_SOURCE} adapter"
    bump_note="Version taken from the ${VERSION_SOURCE} repository contract."
    echo "==> version_source=${VERSION_SOURCE} -> ${tag}"
    if ! version_is_newer "${authoritative_version}" "${LATEST_TAG}"; then
        echo "FATAL: authoritative version ${tag} must be newer than latest stable release ${LATEST_TAG}" >&2
        echo "       reconcile metadata forward in a pull request; public tags are never rewritten" >&2
        exit 6
    fi
fi

if git -C "${LOCAL_REPO}" rev-parse --verify --quiet "${tag}" >/dev/null; then
    echo "FATAL: release tag ${tag} already exists" >&2
    exit 3
fi

notes="$(mktemp)"
{
    printf 'Automated daily release for `%s` as `%s`.\n\n' "${REPO}" "${tag}"
    printf '%s\n\n' "${bump_note}"
    if [[ -n "${release_notes}" ]]; then
        printf '%s\n' "${release_notes}"
    else
        printf 'Changes:\n'
        printf '%s\n' "${commits}"
    fi
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
