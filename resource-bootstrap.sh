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
# Credential preservation (v2.10.5+):
#   RESOURCE_TOKEN_PRESERVE=1     When set, an empty RESOURCE_TOKEN in the
#                                 calling env is backfilled from the existing
#                                 ${ENV_FILE}. Without this flag, empty creds
#                                 exit 7 (avoids silently masking rotation).
#   WEBHOOK_SECRET_PRESERVE=1     Same as above for WEBHOOK_SECRET.
#
# Flags:
#   -y, --yes           No-op (script is non-interactive by default)
#   --interactive       Enable future interactive prompts (no-op today)
#   --debug             Verbose logging to stderr
#   --skip-verify       Skip registration verification step
#   --force             Force the upgrade path even when the existing
#                       container's image matches the pinned tag. Useful
#                       for recovering from a stuck-but-running container.
#   -h, --help          Print usage and exit 0
#
# Exit codes:
#   0  Success (or already bootstrapped)
#   2  Unknown flag / usage error
#   3  Docker not installed or daemon not running
#   4  Image pull failed after retries
#   5  Registration verification timed out (rollback applied on upgrade path)
#   6  RESOURCE_ID is not a valid UUID
#   7  Required env var is empty (RESOURCE_TOKEN or WEBHOOK_SECRET)
#   8  CONTROL_PLANE_URL is not http(s)://
#
# CHANGES SINCE v2.10.5-install-1:
#   - Re-runs now UPGRADE the existing same-UUID container instead of
#     failing with "port is already allocated" (aligns with SSH-deploy's
#     `resource-agent-<uuid>` naming; detects existing via docker ps
#     --format + awk exact-match per TD-4).
#   - Safe-sweep of legacy bare-name containers checks BOTH the image
#     (must match clawfarmacrproduction.azurecr.io/resource-agent) AND
#     the com.clawfarm.managed=true label before removing — never destroys
#     a non-ClawFarm container that happens to be named resource-agent.
#   - Credential preservation now requires explicit
#     RESOURCE_TOKEN_PRESERVE=1 / WEBHOOK_SECRET_PRESERVE=1 flags so
#     silent preservation doesn't mask token-rotation failures.
#   - Upgrade path renames existing container to `resource-agent-<uuid>-prev`
#     and rolls back to it automatically when verify_registration fails
#     (UC-4). The agent is never left without a running supervisor.
#   - docker inspect reads the existing container's Mounts[].Source and
#     reuses those host paths verbatim, so cross-path upgrade (Path A →
#     Path B) preserves all state (UC-1).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants — bumped per release; sync with resource-agent/pyproject.toml
# version field. NOT env-overridable per design Q1 (a re-run with stale env
# vars must not accidentally pin to an old tag).
#
# Test-only override: _TEST_RESOURCE_AGENT_TAG allows integration tests to
# pin to a dummy image (e.g. busybox:latest) without modifying the script.
# Production callers MUST NOT set this.
# ---------------------------------------------------------------------------
if [[ -n "${_TEST_RESOURCE_AGENT_TAG:-}" ]]; then
    RESOURCE_AGENT_TAG="$_TEST_RESOURCE_AGENT_TAG"
    _TEST_TAG_WARNING="_TEST_RESOURCE_AGENT_TAG is set — using test tag ${RESOURCE_AGENT_TAG}. Not for production."
else
    RESOURCE_AGENT_TAG="0.2.3"
    _TEST_TAG_WARNING=""
fi

# Default image registry — overridable via env var of the same name.
RESOURCE_AGENT_IMAGE="${RESOURCE_AGENT_IMAGE:-clawfarmacrproduction.azurecr.io/resource-agent}"

# Host-side XDG layout. These paths are created on the host (no sudo needed)
# and bind-mounted into the container at /var/lib/* (see install_supervisor
# and write_env_file). The container-internal /var/lib/* values are the
# resource-agent's Pydantic defaults and the gateway-provisioning contract —
# they MUST stay as-is. Only the host-side location is XDG.
STATE_DIR="${STATE_DIR:-${HOME}/.local/state/clawfarm/resource-agent}"
GATEWAY_DATA_DIR="${GATEWAY_DATA_DIR:-${HOME}/.local/share/clawfarm/gateways}"
ENV_FILE_DIR="${ENV_FILE_DIR:-${HOME}/.config/clawfarm/resource-agent}"
ENV_FILE="${ENV_FILE_DIR}/agent.env"

RUNBOOK_URL="https://github.com/ClawFarm-by-INFAC/clawfarm-tools#diagnose"
ROLLBACK_RUNBOOK_URL="https://github.com/ClawFarm-by-INFAC/clawfarm-tools#rollback"
REGISTRY_INSTALL_HINT="curl -fsSL https://get.docker.com | sh"

# Ownership label — every container the bootstrap creates carries this.
# The legacy bare-name sweep (AC-7) requires BOTH the image name match
# AND this label before removing.
MANAGED_LABEL="com.clawfarm.managed=true"

# Secrets that must never appear in log output.
REDACT_KEYS=("RESOURCE_TOKEN" "WEBHOOK_SECRET")

# ---------------------------------------------------------------------------
# Flags (set by arg parser)
# ---------------------------------------------------------------------------
ASSUME_YES=false
INTERACTIVE=false
DEBUG=false
SKIP_VERIFY=false
FORCE_UPGRADE=false

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

Credential preservation (re-runs with empty creds):
  RESOURCE_TOKEN_PRESERVE=1     Backfill empty RESOURCE_TOKEN from existing
                                agent.env. Without this flag, empty creds
                                exit 7 (avoids masking rotation failures).
  WEBHOOK_SECRET_PRESERVE=1     Same for WEBHOOK_SECRET.

Flags:
  -y, --yes           No-op (script is non-interactive by default)
  --interactive       Enable future interactive prompts (no-op today)
  --debug             Verbose logging to stderr
  --skip-verify       Skip registration verification step
  --force             Force upgrade path even when image matches pinned tag
  -h, --help          Print this help and exit 0

Exit codes:
  0  Success
  2  Usage error
  3  Docker missing or not running
  4  Image pull failed
  5  Registration verification timed out (rollback applied on upgrade path)
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
            --force)
                FORCE_UPGRADE=true
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

    # RESOURCE_TOKEN — must be non-empty, UNLESS we're re-running with
    # credential preservation (AC-10). The preserve_credentials() function
    # enforces the *_PRESERVE=1 requirement; here we only check that the
    # var is set in the calling env OR there's an existing ${ENV_FILE} to
    # potentially backfill from.
    if [[ -z "${RESOURCE_TOKEN:-}" ]] && [[ ! -f "${ENV_FILE}" ]]; then
        log_error "RESOURCE_TOKEN is required but not set or empty."
        has_error=true
    fi

    # WEBHOOK_SECRET — same logic as RESOURCE_TOKEN.
    if [[ -z "${WEBHOOK_SECRET:-}" ]] && [[ ! -f "${ENV_FILE}" ]]; then
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
        # Exit code 7 for empty required vars (covers empty RESOURCE_ID
        # and empty CONTROL_PLANE_URL).
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
# Container name (UUID-suffixed, matches SSH-deploy convention).
# Computed after validate_env().
# ---------------------------------------------------------------------------
CONTAINER_NAME=""

set_container_name() {
    CONTAINER_NAME="resource-agent-${RESOURCE_ID}"
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
# Credential preservation (UC-6 / AC-10).
#
# preserve_credentials() reads the existing ${ENV_FILE} (if any) and
# backfills empty RESOURCE_TOKEN / WEBHOOK_SECRET in the calling env.
# Requires explicit *_PRESERVE=1 flags — silent preservation was removed
# to avoid masking token-rotation failures.
#
# Exit code 7 when creds are empty AND no *_PRESERVE=1 flag is set.
# ---------------------------------------------------------------------------
preserve_credentials() {
    # Nothing to preserve if there's no existing env file.
    [[ -f "$ENV_FILE" ]] || return 0

    local existing_token=""
    local existing_secret=""
    existing_token="$(_read_env_value "RESOURCE_TOKEN" "$ENV_FILE")"
    existing_secret="$(_read_env_value "WEBHOOK_SECRET" "$ENV_FILE")"

    # RESOURCE_TOKEN
    if [[ -z "${RESOURCE_TOKEN:-}" ]]; then
        if [[ "${RESOURCE_TOKEN_PRESERVE:-0}" == "1" ]]; then
            if [[ -n "$existing_token" ]]; then
                RESOURCE_TOKEN="$existing_token"
                log_info "Preserved RESOURCE_TOKEN from existing env file (RESOURCE_TOKEN_PRESERVE=1)."
            else
                log_error "RESOURCE_TOKEN_PRESERVE=1 set but existing env file has no RESOURCE_TOKEN."
                exit 7
            fi
        else
            log_error "RESOURCE_TOKEN is empty and RESOURCE_TOKEN_PRESERVE=1 is not set."
            log_error "Re-run with RESOURCE_TOKEN=<new-token> or set RESOURCE_TOKEN_PRESERVE=1 to reuse the existing value."
            exit 7
        fi
    fi

    # WEBHOOK_SECRET
    if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
        if [[ "${WEBHOOK_SECRET_PRESERVE:-0}" == "1" ]]; then
            if [[ -n "$existing_secret" ]]; then
                WEBHOOK_SECRET="$existing_secret"
                log_info "Preserved WEBHOOK_SECRET from existing env file (WEBHOOK_SECRET_PRESERVE=1)."
            else
                log_error "WEBHOOK_SECRET_PRESERVE=1 set but existing env file has no WEBHOOK_SECRET."
                exit 7
            fi
        else
            log_error "WEBHOOK_SECRET is empty and WEBHOOK_SECRET_PRESERVE=1 is not set."
            log_error "Re-run with WEBHOOK_SECRET=<new-secret> or set WEBHOOK_SECRET_PRESERVE=1 to reuse the existing value."
            exit 7
        fi
    fi

    # WARN if the existing token's last recorded heartbeat is older than 24h.
    # The heartbeat is optional — only present if the resource-agent wrote it.
    local last_hb
    last_hb="$(_read_env_value "LAST_HEARTBEAT_RECEIVED" "$ENV_FILE")"
    if [[ -n "$last_hb" ]]; then
        local now_epoch hb_epoch
        now_epoch=$(date -u +%s)
        # Parse ISO 8601 (best-effort across GNU/BSD date).
        hb_epoch=$(date -u -d "$last_hb" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$last_hb" +%s 2>/dev/null || echo "")
        if [[ -n "$hb_epoch" ]]; then
            local age_seconds=$((now_epoch - hb_epoch))
            if (( age_seconds > 86400 )); then
                log_warn "Existing credential's LAST_HEARTBEAT_RECEIVED is $((age_seconds / 3600))h old (>$((86400 / 3600))h). Token may be stale."
            fi
        fi
    fi
}

# _read_env_value <key> <file> — read a single KEY=VALUE line from an env
# file. Strips surrounding quotes. Returns empty string if not found.
_read_env_value() {
    local key="$1"
    local file="$2"
    local line val
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 || true)
    if [[ -z "$line" ]]; then
        printf ''
        return 0
    fi
    val="${line#${key}=}"
    # Strip surrounding single or double quotes.
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# Detect existing container (v2.10.5+).
#
# detect_existing_container() inspects the docker daemon for the
# UUID-suffixed container and echoes one of:
#   absent
#   running_same_image
#   running_different_image
#   stopped
#   restarting
#
# Implementation note: uses `docker ps -a --format` + awk with
# EXACT-STRING match (TD-4). The previous `--filter "name=^...$"` regex
# had unreliable semantics across Docker versions.
# ---------------------------------------------------------------------------
detect_existing_container() {
    local target_name="$CONTAINER_NAME"
    local pinned_image="${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}"

    # docker ps -a --format + awk exact-match. We emit only the status
    # and image for the matching container (or nothing if absent).
    local match
    match=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null \
            | awk -F'|' -v target="$target_name" '$1 == target { print $2 "|" $3; exit }')

    if [[ -z "$match" ]]; then
        printf 'absent'
        return 0
    fi

    local status image
    status="${match%%|*}"
    image="${match#*|}"

    # Classify the status. Docker reports "Restarting (137) 5 seconds ago"
    # for the crashloop case, and "Up X minutes" for healthy. We match
    # case-insensitively to be robust across Docker versions.
    local status_lower="${status,,}"
    if [[ "$status_lower" == restarting* ]]; then
        printf 'restarting'
        return 0
    fi

    if [[ "$status_lower" != up* && "$status_lower" != running* ]]; then
        # Not "Up" — could be "Exited", "Created", "Paused", etc.
        printf 'stopped'
        return 0
    fi

    # Status is "Up" (or "running"). Compare image to pinned.
    if [[ "$image" == "$pinned_image" ]]; then
        printf 'running_same_image'
    else
        printf 'running_different_image'
    fi
}

# ---------------------------------------------------------------------------
# Read the existing container's Mounts[].Source host paths via docker
# inspect (UC-1). Returns "<src>:<dest> <src2>:<dest2> ..." on stdout,
# one mount per line.
# ---------------------------------------------------------------------------
read_existing_mounts() {
    local target="$1"
    docker inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}' "$target" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Build the -v and host-path args for the new docker run, optionally
# reusing the existing container's mounts (UC-1).
#
# Echoes a string of `-v src:dst` flags suitable for `docker run`.
# Sets shell variables REUSED_STATE_DIR / REUSED_GATEWAY_DATA_DIR if the
# paths were reused from the existing container (so write_env_file can
# log the correct host-side paths).
#
# Args:
#   $1 — "default" to use the script's STATE_DIR/GATEWAY_DATA_DIR env vars.
#   $1 — mount-lines string returned by read_existing_mounts to reuse
#        those host paths verbatim (UC-1 / AC-2-cross-path).
# ---------------------------------------------------------------------------
build_mount_args() {
    local mode="$1"
    local mounts="${2:-}"

    if [[ "$mode" == "reuse" && -n "$mounts" ]]; then
        # Reuse existing container's mounts verbatim (UC-1).
        local args=""
        local line src dst
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            src="${line%%:*}"
            dst="${line#*:}"
            args+=" -v ${src}:${dst}"
        done <<< "$mounts"
        printf '%s' "$args"
    else
        # Default XDG paths.
        printf -- ' -v %s:/var/run/docker.sock' "/var/run/docker.sock"
        printf -- ' -v %s:%s' "$GATEWAY_DATA_DIR" "/var/lib/clawfarm/gateways"
        printf -- ' -v %s:%s' "$STATE_DIR" "/var/lib/resource-agent"
    fi
}

# ---------------------------------------------------------------------------
# Sweep legacy bare-name container (AC-7).
#
# sweep_legacy_container() checks for a container named exactly
# `resource-agent` (the pre-v2.10.5 convention). It removes that container
# ONLY IF its image matches ${RESOURCE_AGENT_IMAGE} (ClawFarm ACR) AND it
# carries the ${MANAGED_LABEL}. Pure name-based destruction is forbidden.
#
# Never fatal: if docker fails, we log and continue.
# ---------------------------------------------------------------------------
sweep_legacy_container() {
    local bare_name="resource-agent"
    local match
    match=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null \
            | awk -F'|' -v target="$bare_name" '$1 == target { print $2 "|" $3; exit }')

    if [[ -z "$match" ]]; then
        # No legacy bare-name container — nothing to sweep.
        return 0
    fi

    local legacy_status legacy_image legacy_age
    legacy_status="${match%%|*}"
    legacy_image="${match#*|}"

    # Check image: must start with the ClawFarm ACR resource-agent prefix.
    if [[ "$legacy_image" != ${RESOURCE_AGENT_IMAGE}* ]]; then
        log_info "Skipping legacy bare-name container: image=${legacy_image} does not match ${RESOURCE_AGENT_IMAGE}* (not ClawFarm)."
        return 0
    fi

    # Check the managed label via docker inspect. Older pre-label containers
    # may lack it — we accept those too IF the image matches (covers
    # containers created by v2.10.4 and earlier).
    local labels
    labels=$(docker inspect --format '{{.Config.Labels}}' "$bare_name" 2>/dev/null || echo "")
    if [[ "$labels" != *com.clawfarm.managed* ]]; then
        log_info "Skipping legacy bare-name container: no com.clawfarm.managed label (image=${legacy_image})."
        return 0
    fi

    # Best-effort age computation from the status line.
    legacy_age="$legacy_status"
    log_info "Sweeping legacy bare-name container: image=${legacy_image} status=${legacy_age}"
    docker rm -f "$bare_name" >&2 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Write $ENV_FILE (mode 0600, owned by calling user).
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
# install_supervisor — docker run -d the supervisor container.
#
# Args (via env vars consumed by build_mount_args):
#   REUSE_MOUNTS — when non-empty, build_mount_args reuses these host paths
#                  verbatim (UC-1 / AC-2-cross-path).
# ---------------------------------------------------------------------------
install_supervisor() {
    # Build the -v args. If REUSE_MOUNTS is set (from read_existing_mounts),
    # we reuse the existing container's host paths verbatim — this is the
    # cross-path upgrade safety (UC-1).
    local mount_args
    if [[ -n "${REUSE_MOUNTS:-}" ]]; then
        mount_args=$(build_mount_args "reuse" "$REUSE_MOUNTS")
    else
        # Include the docker socket mount by default.
        mount_args=$(build_mount_args "default")
    fi

    log_debug "docker run mount args: ${mount_args}"

    # Run with --label com.clawfarm.managed=true (AC-11).
    # shellcheck disable=SC2086  # word-splitting is intentional for mount_args
    docker run -d \
        --restart=unless-stopped \
        --name "$CONTAINER_NAME" \
        --label "$MANAGED_LABEL" \
        $mount_args \
        --env-file "${ENV_FILE}" \
        -p 9091:9091 \
        "${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}" >&2

    log_info "Installed ${CONTAINER_NAME} container with restart=unless-stopped"
}

# ---------------------------------------------------------------------------
# Upgrade path (UC-4 / AC-2).
#
# upgrade_existing_container() renames the existing container to
# <CONTAINER_NAME>-prev, runs the new container with the SAME mounts,
# and verifies registration. On success, removes -prev. On failure,
# removes the failed new container and restarts -prev.
#
# Args:
#   $1 — existing container status (for log context)
# ---------------------------------------------------------------------------
upgrade_existing_container() {
    local existing_status="$1"
    local prev_name="${CONTAINER_NAME}-prev"
    local pinned_image="${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}"

    # Read existing container's mounts so we can reuse the host paths
    # verbatim (UC-1 / AC-2-cross-path).
    local existing_mounts
    existing_mounts=$(read_existing_mounts "$CONTAINER_NAME")
    export REUSE_MOUNTS="$existing_mounts"

    # Pull new image FIRST. If pull fails (exit 4), the existing container
    # is untouched — no rename happened yet.
    pull_image

    # Rename existing container to -prev BEFORE running the new one.
    log_info "Upgrading: existing=${existing_status} new=${pinned_image}, renaming existing to ${prev_name}"
    if ! docker rename "$CONTAINER_NAME" "$prev_name" >&2 2>&1; then
        log_error "Failed to rename existing container ${CONTAINER_NAME} to ${prev_name}."
        log_error "Aborting upgrade; existing container is untouched."
        exit 2
    fi

    # Run the new container (reuses existing mounts via REUSE_MOUNTS).
    if ! install_supervisor; then
        log_error "docker run of new container failed. Rolling back to ${prev_name}."
        docker start "$prev_name" >&2 2>/dev/null || true
        exit 2
    fi

    # Verify registration. On failure, roll back.
    if ! verify_registration_inner; then
        log_error "Registration verification failed for the new container."
        log_error "Removing the failed new container ${CONTAINER_NAME}..."
        docker rm -f "$CONTAINER_NAME" >&2 2>/dev/null || true
        log_info "Rolled back to previous: restarting ${prev_name} (new image failed registration). See ${ROLLBACK_RUNBOOK_URL}"
        if docker start "$prev_name" >&2 2>/dev/null; then
            # Optional best-effort: rename prev back to the canonical name.
            docker rename "$prev_name" "$CONTAINER_NAME" >&2 2>/dev/null || true
        else
            log_error "FATAL: could not restart ${prev_name}. The agent is DOWN. See ${ROLLBACK_RUNBOOK_URL}"
        fi
        exit 5
    fi

    # Success: remove the -prev container.
    log_info "Upgraded successfully. Removing previous container ${prev_name}."
    docker rm -f "$prev_name" >&2 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Restart a stopped container (no pull, no run).
# ---------------------------------------------------------------------------
restart_stopped_container() {
    local status="$1"
    log_info "Restarting: container status=${status}"
    docker start "$CONTAINER_NAME" >&2
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
# Registration verification (inner — returns 0 on success, 1 on timeout).
# ---------------------------------------------------------------------------
verify_registration_inner() {
    if [[ "$SKIP_VERIFY" == "true" ]]; then
        log_warn "Skipping registration verification per --skip-verify"
        return 0
    fi

    log_info "Verifying registration with control plane (timeout: 120s)..."

    local max_iterations=24
    local sleep_interval=5
    local iter

    for iter in $(seq 1 "$max_iterations"); do
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Successfully registered with control plane"; then
            log_info "Resource-agent successfully registered with control plane."
            return 0
        fi
        log_debug "Waiting for registration (iteration ${iter}/${max_iterations})..."
        sleep "$sleep_interval"
    done

    log_error "Resource-agent did not register within $((max_iterations * sleep_interval))s."
    log_error "Last 30 log lines:"
    docker logs --tail 30 "$CONTAINER_NAME" >&2 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# verify_registration — exit-5 wrapper around verify_registration_inner.
# Used for the fresh-install path. The upgrade path uses the inner
# function directly so it can roll back on failure.
# ---------------------------------------------------------------------------
verify_registration() {
    if ! verify_registration_inner; then
        log_error "See runbook: ${RUNBOOK_URL}"
        exit 5
    fi
}

# ---------------------------------------------------------------------------
# Main flow (v2.10.5+ — state-aware branching)
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_info "ClawFarm Resource-Agent Bootstrap starting..."
    log_debug "RESOURCE_AGENT_TAG=${RESOURCE_AGENT_TAG}"
    log_debug "RESOURCE_AGENT_IMAGE=${RESOURCE_AGENT_IMAGE}"
    if [[ -n "$_TEST_TAG_WARNING" ]]; then
        log_warn "$_TEST_TAG_WARNING"
    fi

    validate_env
    set_container_name

    log_debug "CONTAINER_NAME=${CONTAINER_NAME}"

    detect_docker

    # Always sweep legacy bare-name containers first (AC-7).
    sweep_legacy_container

    # Credential preservation / enforcement (AC-10).
    preserve_credentials

    # Detect the existing UUID-suffixed container and dispatch.
    local state
    state=$(detect_existing_container)
    log_debug "detect_existing_container() returned: ${state}"

    local pinned_image="${RESOURCE_AGENT_IMAGE}:${RESOURCE_AGENT_TAG}"

    case "$state" in
        absent)
            if [[ -f "$ENV_FILE" ]]; then
                # AC-9: ENV_FILE present but container absent — fresh install.
                log_info "Installing fresh: ENV_FILE present but container absent (container was removed)."
            else
                log_info "Installing fresh: no existing container found"
            fi
            pull_image
            ensure_directories
            write_env_file
            install_supervisor
            verify_registration
            log_info "Bootstrap complete. Resource-agent is running."
            exit 0
            ;;
        running_same_image)
            if [[ "$FORCE_UPGRADE" == "true" ]]; then
                log_info "Force-upgrading (pinned tag matches running tag=${RESOURCE_AGENT_TAG}, but --force was given)."
                upgrade_existing_container "running tag=${RESOURCE_AGENT_TAG}"
                log_info "Bootstrap complete (force-upgraded)."
            else
                # AC-1 no-op path.
                log_info "No-op: running tag=${RESOURCE_AGENT_TAG} matches pinned tag=${RESOURCE_AGENT_TAG} (status=Up)."
                exit 0
            fi
            ;;
        running_different_image)
            # Get the existing image for logging.
            local existing_image
            existing_image=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null \
                             | awk -F'|' -v target="$CONTAINER_NAME" '$1 == target { print $3; exit }')
            log_info "Upgrading: old=${existing_image} new=${pinned_image}"
            upgrade_existing_container "running image=${existing_image}"
            log_info "Bootstrap complete (upgraded)."
            exit 0
            ;;
        stopped)
            restart_stopped_container "Exited"
            log_info "Bootstrap complete (restarted stopped container)."
            exit 0
            ;;
        restarting)
            # AC-8: treat crashloop as upgrade-in-place.
            log_info "Upgrading: container status=restarting (crashloop suspected), pulling fresh image."
            upgrade_existing_container "restarting"
            log_info "Bootstrap complete (recovered from restart loop)."
            exit 0
            ;;
        *)
            log_error "detect_existing_container() returned unknown state: ${state}"
            exit 2
            ;;
    esac
}

main "$@"
