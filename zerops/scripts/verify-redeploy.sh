#!/usr/bin/env bash
# Exercise a synthetic upload across an app + worker redeploy.
# Usage: bash zerops/scripts/verify-redeploy.sh PROJECT_ID APP_DIR WORKER_DIR
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/zerops-api.sh"
project_id="${1:?Project ID required}"
app_dir="${2:?App checkout required}"
worker_dir="${3:?Worker checkout required}"
zerops_get_project "$project_id"
zerops_assert_owned "$ZEROPS_RESPONSE" false
snapshot() {
    local service
    for service in db redis queue storage; do
        zerops_find_service "$project_id" "$service"
        printf '%s:%s\n' "$service" "$SERVICE_FOUND_ID"
    done
}
before=$(snapshot)
zerops_get_subdomain_url "$project_id" app
url="${SUBDOMAIN_URL:?App subdomain required}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A synthetic 1x1 PNG. No production data or database credentials needed.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7XkAAAAASUVORK5CYII=' | base64 -d > "$tmp/probe.png"
row=$(curl --fail --silent --show-error -F "image=@$tmp/probe.png;type=image/png" "$url/api/upload" | jq -er '.id')
read_row() {
    curl --fail --silent --show-error "$url/api/gallery/$row" | jq -ec --arg id "$row" \
        'select(.id == $id and .filename == "probe.png") | {id,filename,originalUrl}'
}
original=$(read_row)
object_url=$(printf '%s' "$original" | jq -er '.originalUrl')
curl --fail --silent --show-error "$object_url" -o "$tmp/before.png"
cmp "$tmp/probe.png" "$tmp/before.png"
zerops_find_service "$project_id" app
zerops_deploy_service "$SERVICE_FOUND_ID" "$app_dir" "$app_dir/zerops.yaml" prod
zerops_find_service "$project_id" worker
zerops_deploy_service "$SERVICE_FOUND_ID" "$worker_dir" "$worker_dir/zerops.yml" prod
[[ "$before" == "$(snapshot)" ]] || { err 'Infrastructure IDs changed'; exit 1; }
[[ "$original" == "$(read_row)" ]] || { err 'Synthetic row changed or disappeared'; exit 1; }
curl --fail --silent --show-error "$object_url" -o "$tmp/after.png"
cmp "$tmp/probe.png" "$tmp/after.png"
printf 'PASS: four infrastructure IDs unchanged; synthetic PostgreSQL upload row and original object bytes survived app and worker redeployment.\n'
