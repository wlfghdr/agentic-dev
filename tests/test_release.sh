#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

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
    printf 'payload\n' > "${seed}/payload.txt"
    git -C "${seed}" add VERSION payload.txt
    git -C "${seed}" commit -m "feat: initial versioned release" >/dev/null
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

    git init --bare "${remote}" >/dev/null
    git init "${seed}" >/dev/null
    git -C "${seed}" config user.email "test@example.invalid"
    git -C "${seed}" config user.name "Release Test"
    if [[ "${source}" == "ios" ]]; then
        printf 'MARKETING_VERSION = %s;\n' "${version}" > "${seed}/project.pbxproj"
    else
        printf 'versionName = "%s"\n' "${version}" > "${seed}/build.gradle.kts"
    fi
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
make_mobile_repo iosapp ios 2.4
make_mobile_repo androidapp android 3.7.1
make_mobile_repo unknownapp ios 1.0
git -C "${TMPDIR_TEST}/repos/none" tag -f v1.2.4 origin/main >/dev/null

cat > "${TMPDIR_TEST}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    repo\ view\ acme/*\ --json\ defaultBranchRef\ --jq\ .defaultBranchRef.name\ //\ \"main\")
        printf 'main\n'
        ;;
    release\ list\ -R\ acme/none\ --limit\ 100\ --json\ tagName,isDraft)
        printf '[{"tagName":"v1.2.4","isDraft":false}]\n'
        ;;
    release\ list\ -R\ acme/badversion\ --limit\ 100\ --json\ tagName,isDraft)
        printf '[]\n'
        ;;
    release\ list\ -R\ acme/iosapp\ --limit\ 100\ --json\ tagName,isDraft|\
    release\ list\ -R\ acme/androidapp\ --limit\ 100\ --json\ tagName,isDraft|\
    release\ list\ -R\ acme/unknownapp\ --limit\ 100\ --json\ tagName,isDraft)
        printf '[]\n'
        ;;
    release\ list\ -R\ acme/*\ --limit\ 100\ --json\ tagName,isDraft)
        # Deliberately not ordered by SemVer. Drafts and lower versions must
        # not displace the highest published version.
        printf '[{"tagName":"v0.1.0","isDraft":false},{"tagName":"v9.9.9","isDraft":true},{"tagName":"v1.2.3","isDraft":false}]\n'
        ;;
    release\ create\ *)
        printf '%s\n' "$*" >> "${GH_RELEASE_LOG}"
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

[[repos]]
name = "acme/iosapp"
release = true
version_source = "ios"

[[repos]]
name = "acme/androidapp"
release = true
version_source = "android"

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

"${ROOT}/scripts/release.sh" acme/iosapp
grep -F "release create v2.4.0 -R acme/iosapp" "${GH_RELEASE_LOG}"

"${ROOT}/scripts/release.sh" acme/androidapp
grep -F "release create v3.7.1 -R acme/androidapp" "${GH_RELEASE_LOG}"

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
