#!/usr/bin/env bash
# Shared deterministic release helpers. This file is sourced by release.sh and
# directly exercised by the release regression tests.

latest_stable_release_tag() {
    # Input is the paginated/slurped response from GitHub's releases API: one
    # array per page. Policy: drafts, prereleases, and non-strict vX.Y.Z tags
    # are not release baselines. The numerically greatest stable tag wins,
    # independent of API ordering.
    jq -r '
        [.[][]
            | select((.draft // false) | not)
            | select((.prerelease // false) | not)
            | .tag_name
            | select(type == "string" and test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))]
        | sort_by(.[1:] | split(".") | map(tonumber))
        | last // ""
    '
}
