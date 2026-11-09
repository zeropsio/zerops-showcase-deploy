#!/usr/bin/env bash
# zerops-api.sh — Zerops REST API helper functions
# Sourced by all CI/CD pipeline templates.
#
# Required env vars:
#   ZEROPS_TOKEN     — Zerops personal access token (Bearer auth)
#   ZEROPS_CLIENT_ID — Zerops client/organization ID
#
# Dependencies: curl, jq, tar (pre-installed on all major CI runners)
#
# Calling convention:
#   All zerops_api* functions set two globals after each call:
#     ZEROPS_RESPONSE    — response body (JSON string)
#     ZEROPS_HTTP_STATUS — HTTP status code (integer string)
#   Callers read these directly instead of capturing stdout.

set -euo pipefail

ZEROPS_API_BASE="${ZEROPS_API_BASE:-https://api.app-prg1.zerops.io/api/rest/public}"

# Globals set by zerops_api / zerops_api_binary
ZEROPS_RESPONSE=""
ZEROPS_HTTP_STATUS=""

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

slugify() {
    local input="$1" slug digest
    slug=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//' | cut -c1-25)
    digest=$(printf '%s' "$input" | sha256sum)
    printf '%s-%s\n' "${slug:-branch}" "${digest:0:10}"
}

log() { echo "::group::$*" >&2; }
log_end() { echo "::endgroup::" >&2; }
info() { echo "[zerops] $*" >&2; }
err() { echo "[zerops] ERROR: $*" >&2; }


# zerops_render_template TEMPLATE_FILE ENV_FILE PROJECT_NAME
# Renders a .tpl file using envsubst, stripping lines with empty values.
# Sets RENDERED_YAML global.
zerops_render_template() {
    local template_file="$1"
    local env_file="$2"
    local project_name="$3"
    RENDERED_YAML=""

    if [[ ! -f "$template_file" ]]; then
        err "Template file not found: $template_file"
        exit 1
    fi
    if [[ ! -f "$env_file" ]]; then
        err "Env file not found: $env_file"
        exit 1
    fi

    # Load variables from env file (skip comments and blank lines)
    local vars=""
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs)
        export "$key=$value"
        vars="${vars}\${${key}} "
    done < "$env_file"

    # Set project name (always required)
    export PROJECT_NAME="$project_name"

    # Render template, then clean up empty values:
    #   1. envsubst replaces ${VAR} with values (empty string if unset)
    #   2. grep removes lines where the value is empty ("key: " with nothing after)
    #   3. awk removes orphaned section headers (e.g. "verticalAutoscaling:"
    #      with no indented children remaining after the grep)
    #   4. cat -s collapses consecutive blank lines
    RENDERED_YAML=$(envsubst < "$template_file" \
        | grep -v ': $' \
        | awk '
            /^[[:space:]]+[a-zA-Z]+:$/ {
                header = $0
                match($0, /^[[:space:]]+/)
                header_indent = RLENGTH
                getline nextline
                match(nextline, /^[[:space:]]*/)
                next_indent = RLENGTH
                if (next_indent > header_indent && nextline !~ /^[[:space:]]*$/) {
                    print header
                    print nextline
                } else {
                    if (nextline !~ /^[[:space:]]*$/) print nextline
                }
                next
            }
            { print }
        ' \
        | cat -s)

    info "Template rendered for project '${project_name}'"
}
# ---------------------------------------------------------------------------
# Core API wrapper
# ---------------------------------------------------------------------------

# zerops_api METHOD PATH [BODY]
# Sets ZEROPS_RESPONSE and ZEROPS_HTTP_STATUS globals.
# Retries on 5xx up to 3 times with exponential backoff.
# Returns 0 on 2xx/4xx (caller checks ZEROPS_HTTP_STATUS).
# Exits on unrecoverable failure (curl error or 5xx after retries).
zerops_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local url="${ZEROPS_API_BASE}${path}"
    local attempt max_attempts=3
    local backoff_delays=(5 15 30)
    local tmpfile
    tmpfile=$(mktemp)

    ZEROPS_RESPONSE=""
    ZEROPS_HTTP_STATUS=""

    for attempt in $(seq 0 $((max_attempts - 1))); do
        local curl_args=(
            -s
            -w '%{http_code}'
            -o "$tmpfile"
            -X "$method"
            -H "Authorization: Bearer ${ZEROPS_TOKEN}"
            -H "Accept: application/json"
        )

        if [[ -n "$body" ]]; then
            curl_args+=(-H "Content-Type: application/json" -d "$body")
        fi

        local http_code
        http_code=$(curl "${curl_args[@]}" "$url") || {
            err "curl failed for $method $path (attempt $((attempt + 1)))"
            if [[ $attempt -lt $((max_attempts - 1)) ]]; then
                sleep "${backoff_delays[$attempt]}"
                continue
            fi
            rm -f "$tmpfile"
            exit 1
        }

        ZEROPS_HTTP_STATUS="$http_code"
        ZEROPS_RESPONSE=$(cat "$tmpfile")

        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            rm -f "$tmpfile"
            return 0
        elif [[ "$http_code" -ge 500 ]]; then
            err "$method $path returned $http_code (attempt $((attempt + 1))/$max_attempts)"
            if [[ $attempt -lt $((max_attempts - 1)) ]]; then
                sleep "${backoff_delays[$attempt]}"
                continue
            fi
            err "Response body: $ZEROPS_RESPONSE"
            rm -f "$tmpfile"
            exit 1
        else
            # 4xx — caller decides
            rm -f "$tmpfile"
            return 0
        fi
    done

    rm -f "$tmpfile"
}

# zerops_api_binary METHOD PATH FILE
# Sends a binary file upload. Sets ZEROPS_RESPONSE and ZEROPS_HTTP_STATUS.
zerops_api_binary() {
    local method="$1"
    local path="$2"
    local file="$3"
    local url="${ZEROPS_API_BASE}${path}"
    local attempt max_attempts=3
    local backoff_delays=(5 15 30)
    local tmpfile
    tmpfile=$(mktemp)

    ZEROPS_RESPONSE=""
    ZEROPS_HTTP_STATUS=""

    for attempt in $(seq 0 $((max_attempts - 1))); do
        local http_code
        http_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
            -X "$method" \
            -H "Authorization: Bearer ${ZEROPS_TOKEN}" \
            -H "Content-Type: application/x-tar" \
            --data-binary "@${file}" \
            "$url") || {
            err "curl failed for binary upload to $path (attempt $((attempt + 1)))"
            if [[ $attempt -lt $((max_attempts - 1)) ]]; then
                sleep "${backoff_delays[$attempt]}"
                continue
            fi
            rm -f "$tmpfile"
            exit 1
        }

        ZEROPS_HTTP_STATUS="$http_code"
        ZEROPS_RESPONSE=$(cat "$tmpfile")

        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            rm -f "$tmpfile"
            return 0
        elif [[ "$http_code" -ge 500 ]]; then
            err "Binary upload to $path returned $http_code (attempt $((attempt + 1))/$max_attempts)"
            if [[ $attempt -lt $((max_attempts - 1)) ]]; then
                sleep "${backoff_delays[$attempt]}"
                continue
            fi
            err "Response body: $ZEROPS_RESPONSE"
            rm -f "$tmpfile"
            exit 1
        else
            err "Binary upload to $path returned $http_code"
            err "Response body: $ZEROPS_RESPONSE"
            rm -f "$tmpfile"
            exit 1
        fi
    done

    rm -f "$tmpfile"
}

# ---------------------------------------------------------------------------
# Project operations
# ---------------------------------------------------------------------------

# zerops_find_project CLIENT_ID PROJECT_NAME
# Sets PROJECT_FOUND_ID to project ID if found, empty string if not.
# Returns 0 always (caller checks PROJECT_FOUND_ID).
zerops_find_project() {
    local client_id="$1"
    local project_name="$2"
    PROJECT_FOUND_ID=""

    zerops_api GET "/client/${client_id}/projects-by-name/${project_name}"

    if [[ "$ZEROPS_HTTP_STATUS" == "404" ]]; then
        return 0
    fi

    if [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]]; then
        # API returns {"projects":[...]} — extract first match by exact name
        PROJECT_FOUND_ID=$(printf '%s' "$ZEROPS_RESPONSE" | jq -r --arg name "$project_name" '
            [(.projects // [.])[] | select(.name == $name)] |
            if length > 1 then error("Ambiguous project name") else .[0].id // empty end')
        return 0
    fi

    err "Failed to find project '${project_name}': HTTP $ZEROPS_HTTP_STATUS"
    err "Response: $ZEROPS_RESPONSE"
    exit 1
}

# zerops_import_project CLIENT_ID PROJECT_NAME YAML_SOURCE
# Creates a new project from import YAML. Sets IMPORTED_PROJECT_ID.
#
# YAML_SOURCE is either:
#   - Pre-rendered YAML content (if RENDERED_YAML global is set, YAML_SOURCE is ignored)
#   - A file path to a legacy import YAML file (backward compatible)
zerops_import_project() {
    local client_id="$1"
    local project_name="$2"
    local yaml_source="${3:-}"
    zerops_project_marker || return 1

    local yaml_content
    if [[ -n "${RENDERED_YAML:-}" ]]; then
        # Use pre-rendered template (from zerops_render_template)
        yaml_content="$RENDERED_YAML"
    elif [[ -n "$yaml_source" && -f "$yaml_source" ]]; then
        # Legacy: read from file and do simple placeholder substitution
        yaml_content=$(cat "$yaml_source")
        yaml_content="${yaml_content//<FILLED_BY_PIPELINE>/$project_name}"
    else
        err "No YAML content: set RENDERED_YAML or pass a valid file path"
        exit 1
    fi

    local body
    body=$(jq -n --arg yaml "$yaml_content" '{ yaml: $yaml }')

    info "Importing project '${project_name}'..."
    zerops_api POST "/client/${client_id}/project/import" "$body"

    if [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]]; then
        IMPORTED_PROJECT_ID=$(echo "$ZEROPS_RESPONSE" | jq -r '.projectId')
        info "Project created: ${IMPORTED_PROJECT_ID}"
        # Import YAML ignores tagList. Persist ownership via the project API.
        zerops_project_marker || return 1
        local marker_body
        marker_body=$(jq -cn --arg name "$project_name" --argjson tags "$PROJECT_TAG_LIST" \
            '{name:$name,tagList:$tags}')
        zerops_api PUT "/project/${IMPORTED_PROJECT_ID}" "$marker_body"
        if [[ "$ZEROPS_HTTP_STATUS" -lt 200 || "$ZEROPS_HTTP_STATUS" -ge 300 ]]; then
            err "Project created but ownership tagging failed: ${IMPORTED_PROJECT_ID}"
            return 1
        fi
        zerops_assert_owned "$ZEROPS_RESPONSE" false || return 1
        return 0
    fi

    err "Failed to import project '${project_name}': HTTP $ZEROPS_HTTP_STATUS"
    err "Response: $ZEROPS_RESPONSE"
    exit 1
}

# zerops_delete_project PROJECT_ID
# Deletes a project by ID. Ignores 404 (already deleted).
zerops_delete_project() {
    local project_id="$1"
    zerops_get_project "$project_id"
    zerops_assert_owned "$ZEROPS_RESPONSE" true || return 1
    if [[ "${ZEROPS_DELETE_DRY_RUN:-false}" == true ]]; then
        info "Dry run: would delete owned preview ${project_id}"
        return 0
    fi

    info "Deleting project ${project_id}..."
    zerops_api DELETE "/project/${project_id}"

    if [[ "$ZEROPS_HTTP_STATUS" == "404" ]]; then
        info "Project ${project_id} already deleted."
        return 0
    fi

    if [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]]; then
        info "Project ${project_id} deleted."
        return 0
    fi

    err "Failed to delete project ${project_id}: HTTP $ZEROPS_HTTP_STATUS"
    exit 1
}

# zerops_get_project PROJECT_ID
# Sets ZEROPS_RESPONSE to full project JSON.
zerops_get_project() {
    local project_id="$1"

    zerops_api GET "/project/${project_id}"

    if [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]]; then
        return 0
    fi

    err "Failed to get project ${project_id}: HTTP $ZEROPS_HTTP_STATUS"
    exit 1
}

# zerops_wait_ready PROJECT_ID [TIMEOUT_SECONDS]
# Polls until the project is ACTIVE and all infrastructure services are ready.
# Infrastructure services are the ones with priority: 10 in the import YAML.
# Runtime services (app, worker) are expected to be READY_TO_DEPLOY at this point.
zerops_wait_ready() {
    local project_id="$1"
    local timeout="${2:-300}"
    local elapsed=0
    local poll_interval=10
    # Known infrastructure service names from import YAML
    local infra_services=(db redis queue storage)

    info "Waiting for project ${project_id} to be ready (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        # First check project status
        zerops_get_project "$project_id"
        local project_status
        project_status=$(echo "$ZEROPS_RESPONSE" | jq -r '.status')

        if [[ "$project_status" != "ACTIVE" ]]; then
            info "Project status: ${project_status} (${elapsed}s elapsed)"
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))
            continue
        fi

        # Project is ACTIVE — check each infrastructure service
        local all_ready=true
        local not_ready_names=""
        for svc_name in "${infra_services[@]}"; do
            zerops_api GET "/service-stack-by-name/${project_id}/${svc_name}"
            if [[ "$ZEROPS_HTTP_STATUS" == "404" ]]; then
                # Service not created yet
                all_ready=false
                not_ready_names="${not_ready_names} ${svc_name}(missing)"
                continue
            fi
            local svc_status
            svc_status=$(echo "$ZEROPS_RESPONSE" | jq -r '.status')
            case "$svc_status" in
                ACTIVE|SERVICE_ACTIVE)
                    ;; # ready
                *)
                    all_ready=false
                    not_ready_names="${not_ready_names} ${svc_name}(${svc_status})"
                    ;;
            esac
        done

        if [[ "$all_ready" == "true" ]]; then
            info "All infrastructure services are ready."
            return 0
        fi

        info "Waiting...${not_ready_names} (${elapsed}s elapsed)"
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    err "Timeout: project ${project_id} not ready after ${timeout}s"
    exit 1
}

# ---------------------------------------------------------------------------
# Service operations
# ---------------------------------------------------------------------------

# zerops_find_service PROJECT_ID SERVICE_NAME
# Sets SERVICE_FOUND_ID to the service stack ID.
zerops_find_service() {
    local project_id="$1"
    local service_name="$2"
    SERVICE_FOUND_ID=""

    zerops_api GET "/service-stack-by-name/${project_id}/${service_name}"

    if [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]]; then
        # shellcheck disable=SC2034
        SERVICE_FOUND_ID=$(echo "$ZEROPS_RESPONSE" | jq -r '.id')
        return 0
    fi

    err "Failed to find service '${service_name}' in project ${project_id}: HTTP $ZEROPS_HTTP_STATUS"
    err "Response: $ZEROPS_RESPONSE"
    exit 1
}

# zerops_enable_subdomain SERVICE_ID
# Imports without an initial build may leave public access disabled.
zerops_enable_subdomain() {
    local service_id="$1"
    zerops_api GET "/service-stack/$service_id"
    [[ "$ZEROPS_HTTP_STATUS" == 200 ]] || { err "Cannot read app access"; return 1; }
    [[ $(jq -r '.subdomainAccess' <<< "$ZEROPS_RESPONSE") != true ]] || return 0
    zerops_api PUT "/service-stack/$service_id/enable-subdomain-access" '{}'
    [[ "$ZEROPS_HTTP_STATUS" -ge 200 && "$ZEROPS_HTTP_STATUS" -lt 300 ]] ||
        { err "Cannot enable app subdomain: HTTP $ZEROPS_HTTP_STATUS"; return 1; }
    zerops_poll_process "$(jq -er '.id' <<< "$ZEROPS_RESPONSE")" 300
}

# zerops_get_subdomain_url PROJECT_ID SERVICE_NAME [HTTP_PORT]
# Public URLs use zeropsSubdomainHost, not the private publicZone label.
zerops_get_subdomain_url() {
    local project_id="$1" service_name="$2" port="${3:-}"
    local public_zone public_host region
    export SUBDOMAIN_URL=""
    zerops_get_project "$project_id"
    public_zone=$(jq -er '.publicZone' <<< "$ZEROPS_RESPONSE")
    public_host=$(jq -er '.zeropsSubdomainHost' <<< "$ZEROPS_RESPONSE")
    region="${public_zone#*.}"
    region="${region%-zerops.zone}"
    zerops_find_service "$project_id" "$service_name"
    [[ $(jq -r '.subdomainAccess' <<< "$ZEROPS_RESPONSE") == true ]] ||
        { err "Service public subdomain is disabled"; return 1; }
    if [[ -z "$port" ]]; then
        port=$(jq -er '[.ports[] | select(.scheme == "http" or .scheme == "https")][0].port' <<< "$ZEROPS_RESPONSE")
    fi
    jq -e --argjson port "$port" '.ports | any(.port == $port and (.scheme == "http" or .scheme == "https"))' \
        <<< "$ZEROPS_RESPONSE" >/dev/null || { err "No matching HTTP port"; return 1; }
    if [[ "$port" == 80 ]]; then
        SUBDOMAIN_URL="https://${service_name}-${public_host}.${region}.zerops.app"
    else
        SUBDOMAIN_URL="https://${service_name}-${public_host}-${port}.${region}.zerops.app"
    fi
}

# ---------------------------------------------------------------------------
# Deploy operations
# ---------------------------------------------------------------------------

# zerops_deploy_service SERVICE_ID SOURCE_DIR ZEROPS_YAML_PATH SETUP_NAME
# Full deploy cycle: create version → package → upload → build & deploy → poll
zerops_deploy_service() {
    local service_id="$1"
    local source_dir="$2"
    local zerops_yaml_path="$3"
    local setup_name="$4"

    log "Deploying service ${service_id} from ${source_dir}"

    # Step 1: Create app version
    info "Creating app version..."
    local version_body
    version_body=$(jq -n --arg name "ci-$(date -u +%Y%m%d-%H%M%S)" '{ name: $name }')

    zerops_api POST "/service-stack/${service_id}/app-version" "$version_body"

    if [[ "$ZEROPS_HTTP_STATUS" -lt 200 || "$ZEROPS_HTTP_STATUS" -ge 300 ]]; then
        err "Failed to create app version: HTTP $ZEROPS_HTTP_STATUS"
        err "Response: $ZEROPS_RESPONSE"
        exit 1
    fi

    local version_id
    version_id=$(echo "$ZEROPS_RESPONSE" | jq -r '.id')
    info "App version created: ${version_id}"

    # Step 2: Package source into tarball
    info "Packaging source from ${source_dir}..."
    local tarball="/tmp/artifact-${service_id}.tar.gz"

    if [[ -d "${source_dir}/.git" ]]; then
        # Use git archive for clean builds that respect .gitignore
        git -C "$source_dir" archive --format=tar.gz -o "$tarball" HEAD
    else
        tar czf "$tarball" -C "$source_dir" .
    fi

    local tarball_size
    tarball_size=$(stat -c%s "$tarball" 2>/dev/null || stat -f%z "$tarball" 2>/dev/null || echo "unknown")
    info "Tarball size: ${tarball_size} bytes"

    # Step 3: Upload artifact
    info "Uploading artifact..."
    zerops_api_binary PUT "/app-version/${version_id}/upload" "$tarball"
    info "Upload complete."

    # Clean up tarball
    rm -f "$tarball"

    # Step 4: Build & deploy
    info "Triggering build & deploy..."
    local zerops_yaml_content
    zerops_yaml_content=$(cat "$zerops_yaml_path")

    local deploy_body
    deploy_body=$(jq -n \
        --arg yaml "$zerops_yaml_content" \
        --arg setup "$setup_name" \
        '{ zeropsYaml: $yaml, zeropsYamlSetup: $setup }')

    zerops_api PUT "/app-version/${version_id}/build-and-deploy" "$deploy_body"

    if [[ "$ZEROPS_HTTP_STATUS" -lt 200 || "$ZEROPS_HTTP_STATUS" -ge 300 ]]; then
        err "Failed to trigger build & deploy: HTTP $ZEROPS_HTTP_STATUS"
        err "Response: $ZEROPS_RESPONSE"
        exit 1
    fi

    local process_id
    process_id=$(echo "$ZEROPS_RESPONSE" | jq -r '.id')
    info "Build & deploy process started: ${process_id}"

    # Step 5: Poll process until completion
    zerops_poll_process "$process_id" 600

    log_end
}

# zerops_poll_process PROCESS_ID [TIMEOUT_SECONDS]
# Polls a process until it reaches a terminal state.
zerops_poll_process() {
    local process_id="$1"
    local timeout="${2:-600}"
    local elapsed=0
    local poll_interval=5

    info "Polling process ${process_id} (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        zerops_api GET "/process/${process_id}"

        if [[ "$ZEROPS_HTTP_STATUS" -lt 200 || "$ZEROPS_HTTP_STATUS" -ge 300 ]]; then
            err "Failed to poll process ${process_id}: HTTP $ZEROPS_HTTP_STATUS"
            exit 1
        fi

        local status
        status=$(echo "$ZEROPS_RESPONSE" | jq -r '.status')

        case "$status" in
            FINISHED)
                info "Process ${process_id} finished successfully."
                return 0
                ;;
            FAILED|CANCELLED|BUILD_FAILED)
                err "Process ${process_id} ended with status: ${status}"
                echo "$ZEROPS_RESPONSE" | jq '.' >&2
                exit 1
                ;;
            *)
                # PENDING, RUNNING, or other intermediate states
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    info "Process status: ${status} (${elapsed}s elapsed)"
                fi
                ;;
        esac

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    err "Timeout: process ${process_id} did not finish after ${timeout}s"
    exit 1
}

# ---------------------------------------------------------------------------
# High-level helpers
# ---------------------------------------------------------------------------

# zerops_ensure_project CLIENT_ID PROJECT_NAME IMPORT_YAML_FILE [WAIT_TIMEOUT]
# Creates or finds a project. Sets PROJECT_ID global variable.
#
# If RENDERED_YAML is set (from zerops_render_template), it is used instead
# of IMPORT_YAML_FILE. This allows both template-based and legacy workflows.
zerops_ensure_project() {
    local client_id="$1"
    local project_name="$2"
    local import_yaml_file="${3:-}"
    local wait_timeout="${4:-300}"

    info "Ensuring project '${project_name}' exists..."

    zerops_find_project "$client_id" "$project_name"

    if [[ -n "$PROJECT_FOUND_ID" ]]; then
        PROJECT_ID="$PROJECT_FOUND_ID"
        zerops_get_project "$PROJECT_ID"
        zerops_assert_owned "$ZEROPS_RESPONSE" false || return 1
        info "Project '${project_name}' already exists: ${PROJECT_ID}"
        return 0
    fi

    info "Project '${project_name}' not found, creating..."
    zerops_import_project "$client_id" "$project_name" "$import_yaml_file" || return 1
    PROJECT_ID="$IMPORTED_PROJECT_ID"

    zerops_wait_ready "$PROJECT_ID" "$wait_timeout"
}

# zerops_delete_project_by_name CLIENT_ID PROJECT_NAME
# Find and delete a project by name. No-op if not found.
zerops_delete_project_by_name() {
    local client_id="$1"
    local project_name="$2"

    info "Looking up project '${project_name}' for deletion..."

    zerops_find_project "$client_id" "$project_name"

    if [[ -z "$PROJECT_FOUND_ID" ]]; then
        info "Project '${project_name}' not found. Nothing to delete."
        return 0
    fi

    ZEROPS_DELETE_DRY_RUN="${3:-${ZEROPS_DELETE_DRY_RUN:-false}}" zerops_delete_project "$PROJECT_FOUND_ID"
}

# Ownership is stored in project tags, including persistent environments.
# The ref is base64url so branch names remain a single unambiguous tag.
zerops_project_marker() {
    : "${ZEROPS_OWNER_REPOSITORY:?Set the owning GitHub repository}"
    : "${ZEROPS_ENV_KIND:?Set branch, pr, stage or prod}"
    : "${ZEROPS_ENV_REF:?Set the branch, PR number or release ref}"
    case "$ZEROPS_ENV_KIND" in branch|pr|stage|prod) ;; *) err "Invalid environment kind"; return 1 ;; esac
    local encoded
    encoded=$(printf '%s' "$ZEROPS_ENV_REF" | base64 | tr -d '\n=' | tr '+/' '-_')
    PROJECT_TAG_LIST=$(jq -cn --arg owner "showcase-owner:$ZEROPS_OWNER_REPOSITORY" \
        --arg kind "showcase-kind:$ZEROPS_ENV_KIND" --arg ref "showcase-ref:$encoded" \
        --arg created "showcase-created:$(date +%s)" '[$owner,$kind,$ref,$created]')
}

zerops_assert_owned() {
    local project="$1" deleting="${2:-false}" name kind ref
    zerops_project_marker || return 1
    name=$(printf '%s' "$project" | jq -r '.name')
    if [[ "$deleting" == true ]]; then
        case "$name" in stage|prod|*-stage|*-prod) err "Protected project: $name"; return 1 ;; esac
        case ",${ZEROPS_PROTECTED_NAMES:-}," in *",$name,"*) err "Protected project: $name"; return 1 ;; esac
        case "$ZEROPS_ENV_KIND" in branch|pr) ;; *) err "Only previews may be deleted"; return 1 ;; esac
    fi
    kind="showcase-kind:$ZEROPS_ENV_KIND"
    ref=$(printf '%s' "$PROJECT_TAG_LIST" | jq -r '.[2]')
    if ! printf '%s' "$project" | jq -e --arg owner "showcase-owner:$ZEROPS_OWNER_REPOSITORY" \
        --arg kind "$kind" --arg ref "$ref" '
        (.tagList // []) as $tags |
        [$tags[] | select(startswith("showcase-owner:"))] == [$owner] and
        [$tags[] | select(startswith("showcase-kind:"))] == [$kind] and
        [$tags[] | select(startswith("showcase-ref:"))] == [$ref] and
        ([$tags[] | select(startswith("showcase-created:"))] |
          length == 1 and (.[0] | test("^showcase-created:[0-9]{1,12}$")))
        ' >/dev/null; then
        err "Refusing project without matching repository/environment ownership: $name"
        return 1
    fi
}
