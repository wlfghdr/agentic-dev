#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/.github/scripts/create-release.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

cat >"$test_dir/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
if [[ $1 == release && $2 == view ]]; then
  exit "${GH_VIEW_STATUS:-0}"
fi
EOF
chmod +x "$test_dir/gh"

export PATH="$test_dir:$PATH"
export GH_CALLS="$test_dir/calls"
notes_file="$test_dir/release notes.md"
printf 'Release notes\n' >"$notes_file"

output=$(GH_VIEW_STATUS=0 "$helper" v1.2.3 "$notes_file")
grep -Fq 'already exists; skipping creation.' <<<"$output"
[[ $(wc -l <"$GH_CALLS") -eq 1 ]]
grep -Fxq 'release view v1.2.3' "$GH_CALLS"

: >"$GH_CALLS"
output=$(GH_VIEW_STATUS=1 "$helper" v1.2.3 "$notes_file")
grep -Fq 'Creating GitHub release v1.2.3.' <<<"$output"
grep -Fq 'Created GitHub release v1.2.3.' <<<"$output"
[[ $(wc -l <"$GH_CALLS") -eq 2 ]]
grep -Fxq "release create v1.2.3 --title v1.2.3 --notes-file $notes_file --verify-tag" "$GH_CALLS"

echo "release workflow tests passed"
