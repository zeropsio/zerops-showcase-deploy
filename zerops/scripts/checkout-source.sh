#!/usr/bin/env bash
# Resolve a service repository ref without silently confusing it with orchestration code.
set -euo pipefail

repo=${1:?repository required}
destination=${2:?destination required}
kind=${3:?branch or tag required}
requested=${4:?ref required}
prefix=${5:?output prefix required}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
[[ "$kind" == branch || "$kind" == tag ]]
[[ "$prefix" =~ ^[a-z_]+$ ]]

namespace=heads
[[ "$kind" != tag ]] || namespace=tags
encoded=$(jq -rn --arg ref "$requested" '$ref | @uri')
# matching-refs returns [] for a missing ref; transport/auth failures must not fall back.
refs=$(gh api "repos/$repo/git/matching-refs/$namespace/$encoded")
selected=$(jq -er --arg ref "refs/$namespace/$requested" '[.[] | select(.ref == $ref)] | length' <<< "$refs")
if [[ "$selected" == 1 ]]; then
    source_ref="refs/$namespace/$requested"
else
    default_branch=$(gh api "repos/$repo" --jq '.default_branch')
    [[ -n "$default_branch" && "$default_branch" != null ]]
    source_ref="refs/heads/$default_branch"
    printf 'No matching %s %s in %s; explicitly falling back to default branch %s.\n' "$kind" "$requested" "$repo" "$default_branch"
fi

git init --quiet "$destination"
git -C "$destination" remote add origin "https://github.com/$repo.git"
git -C "$destination" -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch --no-tags --depth=1 origin "$source_ref"
git -C "$destination" checkout --quiet --detach FETCH_HEAD
sha=$(git -C "$destination" rev-parse HEAD)
printf '%s: %s at %s\n' "$repo" "$source_ref" "$sha"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s_sha=%s\n%s_ref=%s\n' "$prefix" "$sha" "$prefix" "$source_ref" >> "$GITHUB_OUTPUT"
fi
