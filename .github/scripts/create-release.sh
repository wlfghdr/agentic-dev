#!/usr/bin/env bash
set -euo pipefail

tag=${1:?Usage: create-release.sh TAG NOTES_FILE}
notes_file=${2:?Usage: create-release.sh TAG NOTES_FILE}

if gh release view "$tag" >/dev/null 2>&1; then
  echo "GitHub release $tag already exists; skipping creation."
  exit 0
fi

echo "Creating GitHub release $tag."
gh release create "$tag" \
  --title "$tag" \
  --notes-file "$notes_file" \
  --verify-tag
echo "Created GitHub release $tag."
