#!/usr/bin/env bash
# Enumerate candidates, then re-read ownership and lifecycle under the deployment lock.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/zerops-api.sh"

: "${ZEROPS_OWNER_REPOSITORY:?owner repository required}"
: "${ZEROPS_CLIENT_ID:?client ID required}"
project_prefix=${ZEROPS_PROJECT_PREFIX:-showcase}
ttl_hours=${PREVIEW_TTL_HOURS:-168}
[[ "$ttl_hours" =~ ^[0-9]+$ && ${#ttl_hours} -le 6 ]] || { echo 'Invalid PREVIEW_TTL_HOURS' >&2; exit 1; }
ttl_seconds=$((10#$ttl_hours * 3600))
(( ttl_seconds > 0 )) || { echo 'PREVIEW_TTL_HOURS must be positive' >&2; exit 1; }
now=$(date +%s)

list_owned_previews() {
    local offset=0 page_count total projects='[]'
    while :; do
        zerops_api GET "/client/$ZEROPS_CLIENT_ID/project?limit=100&offset=$offset" || return 1
        [[ "$ZEROPS_HTTP_STATUS" == 200 ]] || { echo 'Cannot list projects safely' >&2; return 1; }
        jq -e '.list | type == "array"' <<< "$ZEROPS_RESPONSE" >/dev/null || return 1
        page_count=$(jq '.list | length' <<< "$ZEROPS_RESPONSE") || return 1
        total=$(jq -er '.total | select(type == "number" and . >= 0 and floor == .)' <<< "$ZEROPS_RESPONSE") || return 1
        projects=$(jq -cn --argjson previous "$projects" --argjson page "$ZEROPS_RESPONSE" '$previous + $page.list') || return 1
        offset=$((offset + page_count))
        (( offset < total )) || break
        (( page_count > 0 )) || { echo 'Project pagination stopped before total' >&2; return 1; }
    done
    # All four markers must be unique. Missing/ambiguous/foreign markers are never candidates.
    jq -c --arg owner "showcase-owner:$ZEROPS_OWNER_REPOSITORY" '
      .[] | select(.tagList | type == "array") |
      . as $project | .tagList as $tags |
      select([$tags[] | select(startswith("showcase-owner:"))] == [$owner]) |
      ([$tags[] | select(startswith("showcase-kind:")) | ltrimstr("showcase-kind:")]) as $kind |
      ([$tags[] | select(startswith("showcase-ref:")) | ltrimstr("showcase-ref:")]) as $ref |
      ([$tags[] | select(startswith("showcase-created:")) | ltrimstr("showcase-created:")]) as $created |
      select(($kind | length) == 1 and ($ref | length) == 1 and ($created | length) == 1) |
      select($kind[0] == "pr" or $kind[0] == "branch") |
      select($ref[0] | test("^[A-Za-z0-9_-]+$")) |
      select($created[0] | test("^[0-9]{1,12}$")) |
      ($ref[0] | gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | try @base64d catch null) as $decoded |
      select($decoded != null and ($decoded | length) > 0) |
      select(($decoded | @base64 | gsub("="; "") | gsub("\\+"; "-") | gsub("/"; "_")) == $ref[0]) |
      {name: $project.name, kind: $kind[0], ref: $decoded, created: ($created[0] | tonumber)}
    ' <<< "$projects"
}

eligible() {
    local candidate=$1 kind ref name created expected refs state encoded
    kind=$(jq -r '.kind' <<< "$candidate")
    ref=$(jq -r '.ref' <<< "$candidate")
    name=$(jq -r '.name' <<< "$candidate")
    created=$(jq -r '.created' <<< "$candidate")
    (( created > 0 && created <= now )) || return 1
    case "$kind" in
        pr)
            [[ "$ref" =~ ^[1-9][0-9]*$ ]] || return 1
            expected="$project_prefix-mr-$ref"
            ;;
        branch)
            [[ "$ref" != main && "$ref" != stage ]] || return 1
            expected="$project_prefix-dev-$(slugify "$ref")"
            ;;
        *) return 1 ;;
    esac
    [[ "$name" == "$expected" ]] || return 1
    # Always consult GitHub, even for TTL expiry: any API error aborts without deletion.
    if [[ "$kind" == pr ]]; then
        state=$(gh api "repos/$ZEROPS_OWNER_REPOSITORY/pulls/$ref" --jq '.state') || exit 1
        [[ "$state" == open || "$state" == closed ]] || exit 1
        [[ "$state" != closed ]] || return 0
    else
        encoded=$(jq -rn --arg ref "$ref" '$ref | @uri')
        refs=$(gh api "repos/$ZEROPS_OWNER_REPOSITORY/git/matching-refs/heads/$encoded") || exit 1
        jq -e 'type == "array"' <<< "$refs" >/dev/null || exit 1
        if [[ $(jq --arg ref "refs/heads/$ref" '[.[] | select(.ref == $ref)] | length' <<< "$refs") == 0 ]]; then
            return 0
        fi
    fi
    (( now - created >= ttl_seconds ))
}

case "${1:-}" in
    enumerate)
        candidates=$(list_owned_previews)
        matrix='[]'
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if eligible "$candidate"; then
                kind=$(jq -r '.kind' <<< "$candidate")
                ref=$(jq -r '.ref' <<< "$candidate")
                key=$ref
                [[ "$kind" != branch ]] || key=$(slugify "$ref")
                matrix=$(jq -cn --argjson matrix "$matrix" --argjson candidate "$candidate" --arg key "$key" '$matrix + [$candidate | {name,kind,ref} + {key:$key}]')
            fi
        done <<< "$candidates"
        printf 'matrix=%s\nhas_candidates=%s\n' "$matrix" "$(jq 'length > 0' <<< "$matrix")" >> "${GITHUB_OUTPUT:?GitHub output required}"
        ;;
    delete)
        : "${PREVIEW_NAME:?preview name required}"
        : "${ZEROPS_ENV_KIND:?environment kind required}"
        : "${ZEROPS_ENV_REF:?environment ref required}"
        candidates=$(list_owned_previews)
        matches=$(jq -sc --arg name "$PREVIEW_NAME" --arg kind "$ZEROPS_ENV_KIND" --arg ref "$ZEROPS_ENV_REF" '[.[] | select(.name == $name and .kind == $kind and .ref == $ref)]' <<< "$candidates")
        [[ $(jq length <<< "$matches") == 1 ]] || { echo 'No unique owned preview remains; skipping' >&2; exit 0; }
        candidate=$(jq -c '.[0]' <<< "$matches")
        if eligible "$candidate"; then
            zerops_delete_project_by_name "$ZEROPS_CLIENT_ID" "$PREVIEW_NAME" "${CLEANUP_DRY_RUN:-false}"
        fi
        ;;
    *) echo 'Usage: cleanup-previews.sh enumerate|delete' >&2; exit 2 ;;
esac
