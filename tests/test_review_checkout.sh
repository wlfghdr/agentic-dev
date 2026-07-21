#!/usr/bin/env bash
set -euo pipefail

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

REMOTE="${TMPDIR_TEST}/remote.git"
SEED="${TMPDIR_TEST}/seed"
LOCAL="${TMPDIR_TEST}/local"
WORKTREE="${TMPDIR_TEST}/review-worktree"

git init --bare "${REMOTE}" >/dev/null
git init "${SEED}" >/dev/null
git -C "${SEED}" config user.email "test@example.invalid"
git -C "${SEED}" config user.name "Review Checkout Test"

printf 'main\n' > "${SEED}/payload.txt"
git -C "${SEED}" add payload.txt
git -C "${SEED}" commit -m "initial" >/dev/null
git -C "${SEED}" branch -M main
git -C "${SEED}" remote add origin "${REMOTE}"
git -C "${SEED}" push origin main >/dev/null

git -C "${SEED}" checkout -b pr-head >/dev/null
printf 'pr v1\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "pr v1" >/dev/null
git -C "${SEED}" push origin pr-head >/dev/null

git clone "${REMOTE}" "${LOCAL}" >/dev/null 2>&1
git -C "${LOCAL}" fetch --quiet origin "pr-head:pr-20-review"
git -C "${LOCAL}" worktree add "${WORKTREE}" "pr-20-review" >/dev/null

printf 'pr v2\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "pr v2" >/dev/null
git -C "${SEED}" push origin pr-head >/dev/null

set +e
git -C "${LOCAL}" fetch --quiet --force origin "pr-head:pr-20-review" 2>"${TMPDIR_TEST}/branch-fetch.err"
branch_fetch_rc=$?
set -e
if [[ "${branch_fetch_rc}" -eq 0 ]]; then
    echo "legacy branch fetch unexpectedly succeeded while branch was checked out" >&2
    exit 1
fi
grep -F "refusing to fetch into branch" "${TMPDIR_TEST}/branch-fetch.err"

review_ref="refs/remotes/origin/pr-20-review"
git -C "${LOCAL}" fetch --quiet --force origin "pr-head:${review_ref}"
review_sha="$(git -C "${LOCAL}" rev-parse "${review_ref}")"
git -C "${WORKTREE}" checkout --detach "${review_sha}" >/dev/null 2>&1
git -C "${WORKTREE}" reset --hard "${review_sha}" >/dev/null
git -C "${WORKTREE}" clean -fd >/dev/null
[[ "$(git -C "${WORKTREE}" rev-parse HEAD)" == "${review_sha}" ]]
grep -Fx "pr v2" "${WORKTREE}/payload.txt"

printf 'pr v3\n' > "${SEED}/payload.txt"
git -C "${SEED}" commit -am "pr v3" >/dev/null
git -C "${SEED}" push origin pr-head >/dev/null

git -C "${LOCAL}" fetch --quiet --force origin "pr-head:${review_ref}"
review_sha="$(git -C "${LOCAL}" rev-parse "${review_ref}")"
git -C "${WORKTREE}" checkout --detach "${review_sha}" >/dev/null 2>&1
git -C "${WORKTREE}" reset --hard "${review_sha}" >/dev/null
git -C "${WORKTREE}" clean -fd >/dev/null
[[ "$(git -C "${WORKTREE}" rev-parse HEAD)" == "${review_sha}" ]]
grep -Fx "pr v3" "${WORKTREE}/payload.txt"

echo "review checkout tests passed"
