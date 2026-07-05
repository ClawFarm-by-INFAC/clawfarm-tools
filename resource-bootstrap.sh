#!/usr/bin/env bash
# =============================================================================
# resource-bootstrap.sh — ClawFarm Resource-Agent Installer
# =============================================================================
# Installs the ClawFarm resource-agent daemon on a Linux VPS. Designed for
# no-sudo execution: the script installs everything under $HOME (XDG-style
# paths) and supervises the container via Docker's built-in
# --restart=unless-stopped policy. Optional systemd supervision is
# documented separately in docs/ops/resource-agent-systemd.md (operators
# who specifically want it can convert post-install).
#
# The only prerequisite is that the calling user can talk to the Docker
# daemon (i.e., is in the `docker` group). For a fresh VPS, run
# vps-init.sh first as root to install Docker + add the user to the
# group; afterwards this script runs sudo-free.
#
# Curl-pipe-bash compatible:
#
#   curl -fsSL <url>/resource-bootstrap.sh | \
#     RESOURCE_ID=<uuid> RESOURCE_TOKEN=<token> \
#     WEBHOOK_SECRET=<secret> CONTROL_PLANE_URL=<url> bash
#
# Required environment variables:
#   RESOURCE_ID        UUID-format resource identifier
#   RESOURCE_TOKEN     Non-empty bearer token for control-plane auth
#   WEBHOOK_SECRET     Non-empty HMAC shared secret
#   CONTROL_PLANE_URL  http:// or https:// control-plane base URL
#
# Optional overrides (env vars):
#   RESOURCE_AGENT_IMAGE  Docker image name (default: ACR production)
#   STATE_DIR             Host-side XDG state directory bound into
#                         /var/lib/resource-agent inside the container
#                         (default: $HOME/.local/state/clawfarm/resource-agent)
#   GATEWAY_DATA_DIR      Host-side XDG gateway-data directory bound into
#                         /var/lib/clawfarm/gateways inside the container
#                         (default: $HOME/.local/share/clawfarm/gateways)
#   ENV_FILE_DIR          Host-side XDG config directory holding agent.env
#                         (default: $HOME/.config/clawfarm/resource-agent)
#
# Flags:
#   -y, --yes           No-op (script is non-interactive by default)
#   --interactive       Enable future interactive prompts (no-op today)
#   --debug             Verbose logging to stderr
#   --skip-verify       Skip registration verification step
#   -h, --help          Print usage and exit 0
#
# Exit codes:
#   0  Success (or already bootstrapped)
#   2  Unknown flag / usage error
#   3  Docker not installed or daemon not running
#   4  Image pull failed after retries
#   5  Registration verification timed out
#   6  RESOURCE_ID is not a valid UUID
#   7  Required env var is empty (RESOURCE_TOKEN or WEBHOOK_SECRET)
#   8  CONTROL_PLANE_URL is not http(s)://
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants — bumped per release; sync with resource-agent/pyproject.toml
# version field. NOT env-overridable per design Q1.
# ---------------------------------------------------------------------------
RESOURCE_AGENT_TAG="0.2.3"

# Default image registry — overridable via env var of the same name.
RESOURCE_AGENT_IMAGE="${RESOURCE_AGENT_IMAGE:-clawfarmacrproduction.azurecr.io/resource-agent}"

# Host-side XDG layout. These paths are created on the host (no sudo needed)
# and bind-mounted into the container at /var/lib/* (see install_docker_restart
# and write_env_file). The container-internal /var/lib/* values are the
# resource-agent's Pydantic defaults and the gateway-provisioning contract —
# they MUST stay as-is. Only the host-side location is XDG.
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/clawfarm/resource-agent}"
GATEWAY_DATA_DIR="${GATEWAY_DATA_DIR:-${HOME}/.local/share/clawfarm/gateways}"
ENV_FILE_DIR="${ENV_FILE_DIR:-${HOME}/.config/clawfarm/resource-agent}"
ENV_FILE="${ENV_FILE_DIR}/agent.env"

RUNBOOK_URL="https://github.com/ClawFarm-by-INFAC/clawfarm-tools#diagnose"
REGISTRY_INSTALL_HINT="curl -fsSL https://get.docker.com | sh"

# Secrets that must never appear in log output.
REDACT_KEYS=("RESOURCE_TOKEN" "WEBHOOK_SECRET")

# ---------------------------------------------------------------------------
# Flags (set by arg parser)
# ---------------------------------------------------------------------------
ASSUME_YES=false
INTERACTIVE=false
DEBUG=false
SKIP_VERIFY=false

# ---------------------------------------------------------------------------
# Logging helpers — all output to stderr with ISO 8601 timestamp + level.
# ---------------------------------------------------------------------------

# redact <message> — mask any substring that matches a known secret value.
# We replace each secret's VALUE with ******** in the message. The key
# NAMES are not secret (they appear in docs), so we only redact values.
_redact() {
    local msg="$1"
    local key
    local val
    for key in "${REDACT_KEYS[@]}"; do
        val="${!key:-}"
        if [[ -n "$val" ]]; then
            # Bash ${var//pat/x} performs literal matching when pat is quoted,
            # so no escaping of $val is needed here.
            msg="${msg//"$val"/********}"
        fi
    done
    printf '%s' "$msg"
}

log_info() {
    local msg
    msg="$(_redact "$1")"
    printf '[%s] [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >&2
}

log_warn() {
    local msg
    msg="$(_redact "$1")"
    printf '[%s] [WARN] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >&2
}

log_error() {
    local msg
    msg="$(_redact "$1")"
    printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >&2
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        local msg
        msg="$(_redact "$1")"
        printf '[%s] [DEBUG] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >&2
    fi
}

# ---------------------------------------------------------------------------
# ERR trap — log unexpected failures. We deliberately exclude known exit
# codes (0, 2-8) which are used by intentional `exit N` calls throughout
# the script. The trap catches only uncaught errors (e.g. commands that
# fail under set -e without an explicit handler).
# NEVER log env file content or secret values in this trap.
# ---------------------------------------------------------------------------
_err_trap() {
    local code=$?
    case "$code" in
        0|2|3|4|5|6|7|8)
            # Intentional exit code — suppress the trap message.
            return "$code"
            ;;
        *)
            log_error "resource-bootstrap.sh exited unexpectedly with code ${code}"
            return "$code"
            ;;
    esac
}
trap '_err_trap' ERR

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF' >&2
Usage: RESOURCE_ID=<uuid> RESOURCE_TOKEN=<token> WEBHOOK_SECRET=<secret> \
  CONTROL_PLANE_URL=<url> resource-bootstrap.sh [flags]

Installs the ClawFarm resource-agent daemon on this host.

Required environment variables:
  RESOURCE_ID        UUID-format resource identifier
  RESOURCE_TOKEN     Bearer token for control-plane authentication
  WEBHOOK_SECRET     HMAC shared secret for webhook validation
  CONTROL_PLANE_URL  http:// or https:// control-plane base URL

Optional overrides:
  RESOURCE_AGENT_IMAGE  Docker image (default: clawfarmacrproduction.azurecr.io/resource-agent)
  STATE_DIR             Host state directory bound to /var/lib/resource-agent
                        inside the container (default: $HOME/.local/state/clawfarm/resource-agent)
  GATEWAY_DATA_DIR      Host gateway data directory bound to /var/lib/clawfarm/gateways
                        inside the container (default: $HOME/.local/share/clawfarm/gateways)
  ENV_FILE_DIR          Host config directory holding agent.env
                        (default: $HOME/.config/clawfarm/resource-agent)

Flags:
  -y, --yes           No-op (script is non-interactive by default)
  --interactive       Enable future interactive prompts (no-op today)
  --debug             Verbose logging to stderr
  --skip-verify       Skip registration verification step
  -h, --help          Print this help and exit 0

Exit codes:
  0  Success
  2  Usage error
  3  Docker missing or not running
  4  Image pull failed
  5  Registration verification timed out
  6  RESOURCE_ID not a valid UUID
  7  Required env var is empty
  8  CONTROL_PLANE_URL is not http(s)://
EOF
}

# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            --interactive)
                INTERACTIVE=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown flag: $1"
                usage
                exit 2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Environment variable validation
# ---------------------------------------------------------------------------
validate_env() {
    local has_error=false

    # RESOURCE_ID — must look like a UUID (hex with dashes, 36 chars).
    if [[ -z "${RESOURCE_ID:-}" ]]; then
        log_error "RESOURCE_ID is required but not set."
        has_error=true
    elif [[ ! "${RESOURCE_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        log_error "RESOURCE_ID does not match UUID format."
        exit 6
    fi

    # RESOURCE_TOKEN — must be non-empty.
    if [[ -z "${RESOURCE_TOKEN:-}" ]]; then
        log_error "RESOURCE_TOKEN is required but not set or empty."
        has_error=true
    fi

    # WEBHOOK_SECRET — must be non-empty.
    if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
        log_error "WEBHOOK_SECRET is required but not set or empty."
        has_error=true
    fi

    # CONTROL_PLANE_URL — must start with http:// or https://.
    if [[ -z "${CONTROL_PLANE_URL:-}" ]]; then
        log_error "CONTROL_PLANE_URL is required but not set."
        has_error=true
    elif [[ ! "${CONTROL_PLANE_URL}" =~ ^https?:// ]]; then
        log_error "CONTROL_PLANE_URL must start with http:// or https://"
        exit 8
    fi

    if [[ "$has_error" == "true" ]]; then
        # Exit code 7 for empty required vars (RESOURCE_TOKEN, WEBHOOK_SECRET,
        # and also for empty RESOURCE_ID/CONTROL_PLANE_URL which failed the
        # non-empty check before the format check).
        exit 7
    fi

    log_debug "All required environment variables are present and valid."
}

# ---------------------------------------------------------------------------
# Docker detection
# ---------------------------------------------------------------------------
detect_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is required but not installed."
        log_error "Install Docker with: ${REGISTRY_INSTALL_HINT}"
        exit 3
    fi
    log_debug "Docker CLI found on PATH."

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running."
        log_error "Run vps-init.sh first to install Docker and start the daemon."
        exit 3
    fi
    log_debug "Docker daemon is running."
    log_info "Docker detected and daemon is running."
}

# ---------------------------------------------------------------------------
# Image pull with retries
# ---------------------------------------------------------------------------
pull_image() {
    local image="${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}"
    local max_attempts=3
    local attempt
    local delay=1

    log_info "Pulling image: ${image}"

    for attempt in $(seq 1 "$max_attempts"); do
        log_debug "Pull attempt ${attempt}/${max_attempts}..."
        if docker pull "$image" >&2; then
            log_info "Image pulled successfully: ${image}"
            return 0
        fi
        log_warn "Pull attempt ${attempt}/${max_attempts} failed."
        if [[ $attempt -lt $max_attempts ]]; then
            log_debug "Backing off ${delay}s before retry..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done

    log_error "Failed to pull ${image} from registry after ${max_attempts} attempts."
    log_error "Check ACR authentication, network connectivity, or the image tag."
    exit 4
}

# ---------------------------------------------------------------------------
# Check if already bootstrapped (idempotency)
# ---------------------------------------------------------------------------
is_already_running() {
    if [[ -f "$ENV_FILE" ]]; then
        if docker ps --filter "name=^resource-agent$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "resource-agent"; then
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Write $ENV_FILE (mode 0600, owned by calling user).
#
# The container-internal paths /var/lib/resource-agent and
# /var/lib/clawfarm/gateways are HARD-CODED into the heredoc body below.
# They are NOT ${STATE_DIR}/${GATEWAY_DATA_DIR} (which are the host-side XDG
# bind-mount sources — see install_docker_restart). The agent's Pydantic
# defaults and the entrypoint chown contract both expect /var/lib/* paths
# inside the container; the host-side XDG location is purely a
# bootstrap-script concern and the container never sees it.
# ---------------------------------------------------------------------------
write_env_file() {
    # Create directory with mode 0700 (private to the calling user).
    mkdir -p "$ENV_FILE_DIR"
    chmod 0700 "$ENV_FILE_DIR" 2>/dev/null || true

    # Write to a temp file, then atomically move into place.
    local tmp_file="${ENV_FILE_DIR}/.agent.env.tmp.$$"

    cat > "$tmp_file" <<EOF
# ClawFarm Resource-Agent Configuration
# Generated by resource-bootstrap.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ)
# This file contains secrets — mode must remain 0600.

# Required fields
RESOURCE_ID=${RESOURCE_ID}
RESOURCE_TOKEN=${RESOURCE_TOKEN}
WEBHOOK_SECRET=${WEBHOOK_SECRET}
CONTROL_PLANE_URL=${CONTROL_PLANE_URL}

# Optional defaults
WEBHOOK_PORT=${WEBHOOK_PORT:-9091}
HEALTH_ENDPOINT_PORT=${HEALTH_ENDPOINT_PORT:-9090}
DOCKER_SOCKET=${DOCKER_SOCKET:-/var/run/docker.sock}
GATEWAY_NETWORK_NAME=${GATEWAY_NETWORK_NAME:-}
STATE_DIR=/var/lib/resource-agent
GATEWAY_DATA_DIR=/var/lib/clawfarm/gateways
LOG_LEVEL=${LOG_LEVEL:-INFO}
EOF

    # Set permissions before moving into place.
    chmod 0600 "$tmp_file"

    mv "$tmp_file" "$ENV_FILE"
    chmod 0600 "$ENV_FILE" 2>/dev/null || true

    log_info "Wrote ${ENV_FILE} (mode 0600, $(id -un))"
}

# ---------------------------------------------------------------------------
# Install via docker run --restart=unless-stopped (approach B, no --user flag).
#
# Bind-mount path mapping: host XDG paths (${STATE_DIR},
# ${GATEWAY_DATA_DIR}) are bind-mounted to the agent's container-internal
# paths (/var/lib/resource-agent, /var/lib/clawfarm/gateways). The
# container-internal paths are the resource-agent's Pydantic defaults and
# the gateway-provisioning contract — the entrypoint and Dockerfile both
# expect /var/lib/* inside the container, so we MUST preserve them on the
# right-hand side of the bind mount. Only the host-side location is XDG.
#
# NO --user flag is passed: the image runs as root, the entrypoint chowns
# the bind-mounted dirs to UID 1001, then gosu-drops to UID 1001 before
# exec'ing the agent. Passing `--user $(id -u):$(id -g)` would break both
# the entrypoint's docker-socket GID fix AND the gateway container's
# openclaw UID alignment (see entrypoint.sh:57-77, Dockerfile:36-47).
#
# NO -e HOME flag: the container's $HOME is irrelevant — the agent reads
# STATE_DIR/GATEWAY_DATA_DIR from agent.env (hard-coded to /var/lib/*
# in write_env_file above).
# ---------------------------------------------------------------------------
install_supervisor() {
    # Remove any existing container first.
    docker rm -f resource-agent 2>/dev/null || true

    docker run -d \
        --restart=unless-stopped \
        --name resource-agent \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${GATEWAY_DATA_DIR}:/var/lib/clawfarm/gateways" \
        -v "${STATE_DIR}:/var/lib/resource-agent" \
        --env-file "${ENV_FILE}" \
        -p 9091:9091 \
        "${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}" >&2

    log_info "Installed resource-agent container with restart=unless-stopped"
}

# ---------------------------------------------------------------------------
# Restart the service (for idempotency path)
# ---------------------------------------------------------------------------
restart_service() {
    if docker ps --filter "name=^resource-agent$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "resource-agent"; then
        docker restart resource-agent >&2
        log_info "Restarted resource-agent container"
    else
        # Container not running — install fresh.
        install_supervisor
    fi
}

# ---------------------------------------------------------------------------
# Registration verification
# ---------------------------------------------------------------------------
verify_registration() {
    if [[ "$SKIP_VERIFY" == "true" ]]; then
        log_warn "Skipping registration verification per --skip-verify"
        return 0
    fi

    log_info "Verifying registration with control plane (timeout: 120s)..."

    local max_iterations=24
    local sleep_interval=5
    local iter

    for iter in $(seq 1 "$max_iterations"); do
        if docker logs resource-agent 2>&1 | grep -q "Successfully registered with control plane"; then
            log_info "Resource-agent successfully registered with control plane."
            return 0
        fi
        log_debug "Waiting for registration (iteration ${iter}/${max_iterations})..."
        sleep "$sleep_interval"
    done

    log_error "Resource-agent did not register within $((max_iterations * sleep_interval))s."
    log_error "Last 30 log lines:"
    docker logs --tail 30 resource-agent >&2 2>/dev/null || true
    log_error "See runbook: ${RUNBOOK_URL}"
    exit 5
}

# ---------------------------------------------------------------------------
# Ensure host directories exist
# ---------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$GATEWAY_DATA_DIR"
    mkdir -p "$STATE_DIR"
    log_debug "Ensured directories: ${GATEWAY_DATA_DIR}, ${STATE_DIR}"
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_info "ClawFarm Resource-Agent Bootstrap starting..."
    log_debug "RESOURCE_AGENT_TAG=${RESOURCE_AGENT_TAG}"
    log_debug "RESOURCE_AGENT_IMAGE=${RESOURCE_AGENT_IMAGE}"

    validate_env

    detect_docker

    # Idempotency check: if env file exists AND container is running, just restart.
    if is_already_running; then
        log_info "Already bootstrapped — restarting service"
        restart_service
        log_info "Bootstrap complete (restarted existing service)."
        exit 0
    fi

    pull_image

    ensure_directories

    write_env_file

    install_supervisor

    verify_registration

    log_info "Bootstrap complete. Resource-agent is running."
}

main "$@"
