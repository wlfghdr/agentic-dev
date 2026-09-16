#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# Exercise the exact jq filter sourced by production with real jq. GitHub's
# REST response is slurped into one array per page.
# shellcheck source=scripts/release_lib.sh
source "${ROOT}/scripts/release_lib.sh"
[[ "$(printf '%s\n' '[[{"tag_name":"v6.4.1","draft":false,"prerelease":false}]]' | latest_stable_release_tag)" == "v6.4.1" ]]
[[ "$(printf '%s\n' '[[{"tag_name":"v11.0.0","draft":true,"prerelease":false},{"tag_name":"v10.0.0","draft":false,"prerelease":false}],[{"tag_name":"v12.0.0","draft":false,"prerelease":true},{"tag_name":"v9.20.0","draft":false,"prerelease":false},{"tag_name":"10.0.0","draft":false,"prerelease":false},{"tag_name":"v9.3.0-rc.1","draft":false,"prerelease":false}]]' | latest_stable_release_tag)" == "v10.0.0" ]]
[[ "$(printf '%s\n' '[[{"tag_name":"v01.2.3","draft":false,"prerelease":false},{"tag_name":"v1.2.2","draft":false,"prerelease":false}]]' | latest_stable_release_tag)" == "v1.2.2" ]]
[[ -z "$(printf '%s\n' '[[]]' | latest_stable_release_tag)" ]]

make_repo() {
    local name="${1}"
    local tag="${2}"
    local subject="${3}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    printf 'base\n' > "${seed}/payload.txt"
    git -C "${seed}" add payload.txt
    git -C "${seed}" commit -m "chore: initial" >/dev/null
    git -C "${seed}" tag "${tag}"
    git -C "${seed}" tag v9.9.9
    printf '%s\n' "${subject}" > "${seed}/payload.txt"
    git -C "${seed}" commit -am "${subject}" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main --tags >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_repo_with_body() {
    local name="${1}"
    local tag="${2}"
    local subject="${3}"
    local body="${4}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    printf 'base\n' > "${seed}/payload.txt"
    git -C "${seed}" add payload.txt
    git -C "${seed}" commit -m "chore: initial" >/dev/null
    git -C "${seed}" tag "${tag}"
    printf '%s\n' "${body}" > "${seed}/payload.txt"
    git -C "${seed}" commit -am "${subject}" -m "${body}" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main --tags >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_version_repo() {
    local name="${1}"
    local version="${2}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    printf '%s\n' "${version}" > "${seed}/VERSION"
    printf '## [%s] - 2026-09-16\n\n- Test release.\n' "${version}" > "${seed}/CHANGELOG.md"
    printf 'payload\n' > "${seed}/payload.txt"
    git -C "${seed}" add VERSION CHANGELOG.md payload.txt
    git -C "${seed}" commit -m "feat: initial versioned release" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_version_plugin_repo() {
    local name="${1}"
    local previous="${2}"
    local version="${3}"
    local manifest_version="${4:-${version}}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    mkdir -p "${seed}/plugin"
    printf '%s\n' "${previous}" > "${seed}/VERSION"
    printf '{"version":"%s"}\n' "${previous}" > "${seed}/plugin/plugin.json"
    printf '## [%s] - 2026-09-01\n\n- Previous release.\n' "${previous}" > "${seed}/CHANGELOG.md"
    printf 'base\n' > "${seed}/payload.txt"
    git -C "${seed}" add .
    git -C "${seed}" commit -m "chore: previous release" >/dev/null
    git -C "${seed}" tag "v${previous}"
    printf '%s\n' "${version}" > "${seed}/VERSION"
    printf '{"version":"%s"}\n' "${manifest_version}" > "${seed}/plugin/plugin.json"
    printf '## [%s] - 2026-09-16\n\n- Coordinated plugin release.\n\n## [%s] - 2026-09-01\n\n- Previous release.\n' "${version}" "${previous}" > "${seed}/CHANGELOG.md"
    printf 'next\n' > "${seed}/payload.txt"
    git -C "${seed}" add .
    git -C "${seed}" commit -m "feat: prepare plugin release" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main --tags >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_config_repo() {
    local name="${1}"
    local previous="${2}"
    local version="${3}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    printf 'framework_version: "%s"\n' "${previous}" > "${seed}/CONFIG.yaml"
    printf '## [%s] - 2026-09-01\n\n- Previous release.\n' "${previous}" > "${seed}/CHANGELOG.md"
    git -C "${seed}" add .
    git -C "${seed}" commit -m "chore: previous release" >/dev/null
    git -C "${seed}" tag "v${previous}"
    printf 'framework_version: "%s" # authoritative\n' "${version}" > "${seed}/CONFIG.yaml"
    printf '## [%s] - 2026-09-16\n\n- Framework release.\n\n## [%s] - 2026-09-01\n\n- Previous release.\n' "${version}" "${previous}" > "${seed}/CHANGELOG.md"
    git -C "${seed}" add .
    git -C "${seed}" commit -m "feat: prepare framework release" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main --tags >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_large_manifest_only_repo() {
    local name="${1}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"
    local index

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    mkdir -p "${seed}/000-plugin" "${seed}/zzz-files"
    printf '{"version":"1.0.0"}\n' > "${seed}/000-plugin/plugin.json"
    for index in $(seq -w 1 5000); do
        printf 'fixture\n' > "${seed}/zzz-files/file-${index}.txt"
    done
    git -C "${seed}" add .
    git -C "${seed}" commit -m "feat: manifest-only repository" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_mobile_repo() {
    local name="${1}"
    local source="${2}"
    local version="${3}"
    local remote="${TMPDIR_TEST}/${name}.git"
    local seed="${TMPDIR_TEST}/${name}-seed"
    local local_repo="${TMPDIR_TEST}/repos/${name}"
    local normalized_version

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    if [[ "${source}" == "ios" ]]; then
        printf 'MARKETING_VERSION = %s;\n' "${version}" > "${seed}/project.pbxproj"
    else
        printf 'versionName = "%s"\n' "${version}" > "${seed}/build.gradle.kts"
    fi
    case "${version}" in
        *.*.*) normalized_version="${version}" ;;
        *.*) normalized_version="${version}.0" ;;
        *) normalized_version="${version}.0.0" ;;
    esac
    printf '## [%s] - 2026-09-16\n\n- Mobile release.\n' "${normalized_version}" > "${seed}/CHANGELOG.md"
    git -C "${seed}" add .
    git -C "${seed}" commit -m "feat: mobile release" >/dev/null
    git -C "${seed}" branch -M main
    git -C "${seed}" remote add origin "${remote}"
    git -C "${seed}" push origin main >/dev/null

    mkdir -p "${TMPDIR_TEST}/repos"
    git clone "${remote}" "${local_repo}" >/dev/null 2>&1
}

make_repo minor v1.2.3 "feat: add useful thing"
make_repo_with_body mergeminor v1.2.3 "Merge pull request #7 from acme/feature" "feat: add merged feature"
make_repo major v1.2.3 "feat!: change public contract"
make_repo patch v1.2.3 "docs: update readme"
make_repo none v1.2.3 "fix: already tagged"
make_version_repo badversion '1.$(touch /tmp/agentic-dev-version-pwned).0'
make_version_repo leadingzero 01.2.3
make_version_plugin_repo versionplugin 1.2.3 1.3.0
make_version_plugin_repo mismatchedplugin 1.2.3 1.3.0 1.2.3
make_config_repo framework 4.4.1 4.5.0
make_large_manifest_only_repo manifestonly
make_mobile_repo iosapp ios 2.4
make_mobile_repo androidapp android 3.7.1
make_mobile_repo mobilewithoutadapter ios 5.0
make_mobile_repo unknownapp ios 1.0
git -C "${TMPDIR_TEST}/repos/none" tag -f v1.2.4 origin/main >/dev/null

cat > "${TMPDIR_TEST}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    repo\ view\ acme/*\ --json\ defaultBranchRef\ --jq\ .defaultBranchRef.name\ //\ \"main\")
        printf 'main\n'
        ;;
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/none/releases\?per_page=100)
        printf '[[{"tag_name":"v1.2.4","draft":false,"prerelease":false}]]\n'
        ;;
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/versionplugin/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/mismatchedplugin/releases\?per_page=100)
        printf '[[{"tag_name":"v1.2.3","draft":false,"prerelease":false}]]\n'
        ;;
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/framework/releases\?per_page=100)
        printf '[[{"tag_name":"v4.4.1","draft":false,"prerelease":false}]]\n'
        ;;
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/badversion/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/leadingzero/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/manifestonly/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/iosapp/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/androidapp/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/mobilewithoutadapter/releases\?per_page=100|\
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/unknownapp/releases\?per_page=100)
        printf '[[]]\n'
        ;;
    api\ --paginate\ --slurp\ -H\ Accept:\ application/vnd.github+json\ repos/acme/*/releases\?per_page=100)
        # Deliberately split and unordered. Drafts, prereleases and lower
        # versions must not displace the highest stable published version.
        printf '[[{"tag_name":"v0.1.0","draft":false,"prerelease":false},{"tag_name":"v9.9.9","draft":true,"prerelease":false}],[{"tag_name":"v8.0.0","draft":false,"prerelease":true},{"tag_name":"v1.2.3","draft":false,"prerelease":false}]]\n'
        ;;
    release\ create\ *)
        printf '%s\n' "$*" >> "${GH_RELEASE_LOG}"
        while (( $# )); do
            if [[ "$1" == "--notes-file" ]]; then
                printf '%s\n' "--- $2" >> "${GH_NOTES_LOG}"
                sed -n '/^## \[/,$p' "$2" >> "${GH_NOTES_LOG}"
                break
            fi
            shift
        done
        ;;
    *)
        echo "unexpected gh args: $*" >&2
        exit 99
        ;;
esac
MOCK
chmod +x "${TMPDIR_TEST}/gh"

export PATH="${TMPDIR_TEST}:${PATH}"
export TRIAGE_ENABLE_DISPATCH=1
export TRIAGE_DIR="${TMPDIR_TEST}/triage"
export TRIAGE_REPOS_DIR="${TMPDIR_TEST}/repos"
export TRIAGE_STATE_DIR="${TMPDIR_TEST}/state"
export TRIAGE_CONFIG="${TMPDIR_TEST}/triage.toml"
export GH_RELEASE_LOG="${TMPDIR_TEST}/releases.log"
export GH_NOTES_LOG="${TMPDIR_TEST}/notes.log"

cat > "${TRIAGE_CONFIG}" <<'TOML'
[release]
enabled = true

[[repos]]
name = "acme/minor"
release = true

[[repos]]
name = "acme/mergeminor"
release = true

[[repos]]
name = "acme/major"
release = true

[[repos]]
name = "acme/patch"
release = true

[[repos]]
name = "acme/none"
release = true

[[repos]]
name = "acme/badversion"
release = true
version_source = "version"

[[repos]]
name = "acme/leadingzero"
release = true
version_source = "version"

[[repos]]
name = "acme/manifestonly"
release = true

[[repos]]
name = "acme/versionplugin"
release = true
version_source = "version"

[[repos]]
name = "acme/mismatchedplugin"
release = true
version_source = "version"

[[repos]]
name = "acme/framework"
release = true
version_source = "config_yaml"

[[repos]]
name = "acme/iosapp"
release = true
version_source = "ios"

[[repos]]
name = "acme/androidapp"
release = true
version_source = "android"

[[repos]]
name = "acme/mobilewithoutadapter"
release = true

[[repos]]
name = "acme/unknownapp"
release = true
version_source = "windows-phone"
TOML

"${ROOT}/scripts/release.sh" acme/minor
grep -F "release create v1.3.0" "${GH_RELEASE_LOG}"

"${ROOT}/scripts/release.sh" acme/mergeminor
grep -F "release create v1.3.0 -R acme/mergeminor" "${GH_RELEASE_LOG}"

"${ROOT}/scripts/release.sh" acme/major
grep -F "release create v2.0.0" "${GH_RELEASE_LOG}"

"${ROOT}/scripts/release.sh" acme/patch
grep -F "release create v1.2.4" "${GH_RELEASE_LOG}"

before_count="$(wc -l < "${GH_RELEASE_LOG}")"
"${ROOT}/scripts/release.sh" acme/minor
after_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${before_count}" == "${after_count}" ]]

"${ROOT}/scripts/release.sh" acme/none
after_none_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${after_count}" == "${after_none_count}" ]]

if "${ROOT}/scripts/release.sh" acme/badversion; then
    echo "malformed VERSION unexpectedly released" >&2
    exit 1
fi
[[ ! -e /tmp/agentic-dev-version-pwned ]]
after_badversion_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${after_count}" == "${after_badversion_count}" ]]

if "${ROOT}/scripts/release.sh" acme/leadingzero; then
    echo "leading-zero VERSION unexpectedly released" >&2
    exit 1
fi
[[ "${after_badversion_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

if "${ROOT}/scripts/release.sh" acme/manifestonly; then
    echo "large manifest-only repository unexpectedly released" >&2
    exit 1
fi
[[ "${after_badversion_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

"${ROOT}/scripts/release.sh" acme/versionplugin
grep -F "release create v1.3.0 -R acme/versionplugin" "${GH_RELEASE_LOG}"
grep -F "## [1.3.0] - 2026-09-16" "${GH_NOTES_LOG}"
after_version_count="$(wc -l < "${GH_RELEASE_LOG}")"
"${ROOT}/scripts/release.sh" acme/versionplugin
[[ "${after_version_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

if "${ROOT}/scripts/release.sh" acme/mismatchedplugin; then
    echo "mismatched plugin manifest unexpectedly released" >&2
    exit 1
fi
[[ "${after_version_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

"${ROOT}/scripts/release.sh" acme/framework
grep -F "release create v4.5.0 -R acme/framework" "${GH_RELEASE_LOG}"
grep -F "## [4.5.0] - 2026-09-16" "${GH_NOTES_LOG}"
after_framework_count="$(wc -l < "${GH_RELEASE_LOG}")"
"${ROOT}/scripts/release.sh" acme/framework
[[ "${after_framework_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

"${ROOT}/scripts/release.sh" acme/iosapp
grep -F "release create v2.4.0 -R acme/iosapp" "${GH_RELEASE_LOG}"

"${ROOT}/scripts/release.sh" acme/androidapp
grep -F "release create v3.7.1 -R acme/androidapp" "${GH_RELEASE_LOG}"

before_missing_adapter_count="$(wc -l < "${GH_RELEASE_LOG}")"
if "${ROOT}/scripts/release.sh" acme/mobilewithoutadapter; then
    echo "mobile version contract without an adapter unexpectedly released" >&2
    exit 1
fi
[[ "${before_missing_adapter_count}" == "$(wc -l < "${GH_RELEASE_LOG}")" ]]

before_unknown_count="$(wc -l < "${GH_RELEASE_LOG}")"
if "${ROOT}/scripts/release.sh" acme/unknownapp; then
    echo "unknown version_source unexpectedly released" >&2
    exit 1
fi
after_unknown_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${before_unknown_count}" == "${after_unknown_count}" ]]

after_count="$(wc -l < "${GH_RELEASE_LOG}")"

cat > "${TRIAGE_CONFIG}" <<'TOML'
[release]
enabled = false

[[repos]]
name = "acme/patch"
release = true
TOML
"${ROOT}/scripts/release.sh" acme/patch
after_global_disabled_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${after_count}" == "${after_global_disabled_count}" ]]

cat > "${TRIAGE_CONFIG}" <<'TOML'
[release]
enabled = "true"

[[repos]]
name = "acme/patch"
release = "true"
TOML
"${ROOT}/scripts/release.sh" acme/patch
after_string_flags_count="$(wc -l < "${GH_RELEASE_LOG}")"
[[ "${after_count}" == "${after_string_flags_count}" ]]

echo "release tests passed"
