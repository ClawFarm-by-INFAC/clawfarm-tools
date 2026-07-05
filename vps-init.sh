#!/usr/bin/env bash
# =============================================================================
# vps-init.sh — ClawFarm VPS Preparation (Step 1 of two-step onboarding)
# =============================================================================
# Prepares a Linux VPS for ClawFarm resource-agent installation. Runs the
# sudo-required one-time prep: installs Docker if missing, adds the calling
# user to the docker group, and ensures the Docker daemon is enabled and
# running. Idempotent — exits 0 in under 1 second when all three
# preconditions are already satisfied.
#
# Curl-pipe-bash compatible:
#   curl -fsSL <url>/vps-init.sh | sudo -E bash
#
# Step 2 (after this script completes) is resource-bootstrap.sh, which is
# sudo-free once the calling user is in the docker group.
#
# Three preconditions this script verifies:
#   1. Docker CLI is installed (`command -v docker`)
#   2. The calling user is a member of the `docker` group
#   3. The Docker daemon is reachable (`docker info` succeeds)
#
# Required environment variables: none. The script resolves the calling user
# from $SUDO_USER (set by sudo) falling back to $USER.
#
# Flags:
#   -y, --yes           Skip the confirmation prompt that fires before any
#                       system-modifying step. Default path is non-interactive
#                       ONLY when all preconditions are already met; if work
#                       is needed, the script prompts unless --yes is given.
#   --debug             Verbose logging to stderr
#   -h, --help          Print this help and exit 0
#
# Exit codes:
#   0  Success or already-initialized (idempotent no-op)
#   2  Usage error / not invoked as root (when work is needed)
#   3  Docker install failed
#   4  Group-add (usermod -aG docker) failed
#   5  Daemon-enable (systemctl enable --now docker OR service docker start) failed
#   6  Cannot determine the calling user ($SUDO_USER and $USER both empty or invalid)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
RUNBOOK_URL="https://github.com/ClawFarm-by-INFAC/clawfarm-tools#diagnose"
REGISTRY_INSTALL_HINT="curl -fsSL https://get.docker.com | sh"

# ---------------------------------------------------------------------------
# Flags (set by arg parser)
# ---------------------------------------------------------------------------
ASSUME_YES=false
DEBUG=false

# ---------------------------------------------------------------------------
# Logging helpers — all output to stderr with ISO 8601 timestamp + level.
# vps-init.sh handles no secrets (no tokens, no webhook secrets), so no
# redact helper is needed here.
# ---------------------------------------------------------------------------
log_info() {
    printf '[%s] [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

log_warn() {
    printf '[%s] [WARN] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

log_error() {
    printf '[%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        printf '[%s] [DEBUG] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2
    fi
}

# ---------------------------------------------------------------------------
# ERR trap — log unexpected failures. We deliberately exclude known exit
# codes (0, 2-6) which are used by intentional `exit N` calls throughout
# the script. The trap catches only uncaught errors.
# ---------------------------------------------------------------------------
_err_trap() {
    local code=$?
    case "$code" in
        0|2|3|4|5|6)
            # Intentional exit code — suppress the trap message.
            return "$code"
            ;;
        *)
            log_error "vps-init.sh exited unexpectedly with code ${code}"
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
Usage: sudo -E bash vps-init.sh [flags]

Prepares a Linux VPS for ClawFarm resource-agent installation (Step 1 of
two-step onboarding). Installs Docker if missing, adds the calling user to
the docker group, and ensures the Docker daemon is enabled and running.

Three preconditions verified:
  1. Docker CLI is installed (`command -v docker`)
  2. The calling user is a member of the `docker` group
  3. The Docker daemon is reachable (`docker info` succeeds)

Required environment variables: none. Calling user resolved from $SUDO_USER
(set by sudo) falling back to $USER.

Flags:
  -y, --yes           Skip the confirmation prompt before system-modifying
                      steps. The prompt is ALSO skipped automatically when
                      all three preconditions are already met (idempotent
                      no-op).
  --debug             Verbose logging to stderr
  -h, --help          Print this help and exit 0

Exit codes:
  0  Success or already-initialized
  2  Usage error / not invoked as root (when work is needed)
  3  Docker install failed
  4  Group-add (usermod -aG docker) failed
  5  Daemon-enable failed
  6  Cannot determine the calling user

Step 2 (run AFTER this script completes and you log out + back in, or run
`newgrp docker`): resource-bootstrap.sh.

Runbook: https://github.com/ClawFarm-by-INFAC/clawfarm-tools#diagnose
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
            --debug)
                DEBUG=true
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
# Calling-user detection
#
# Resolves the invoking user. When invoked via `sudo bash`, $SUDO_USER is
# set by sudo to the original invoking user. Fall back to $USER if not set.
# Exit 6 if neither is set or if the resolved name doesn't exist in
# /etc/passwd.
# Sets global variable CALLING_USER on success.
# ---------------------------------------------------------------------------
CALLING_USER=""
detect_calling_user() {
    local candidate=""

    if [[ -n "${SUDO_USER:-}" ]]; then
        candidate="$SUDO_USER"
        log_debug "Resolved calling user from \$SUDO_USER: ${candidate}"
    elif [[ -n "${USER:-}" ]]; then
        candidate="$USER"
        log_debug "Resolved calling user from \$USER: ${candidate}"
    else
        log_error "Cannot determine calling user: both \$SUDO_USER and \$USER are empty."
        log_error "Re-run with: sudo -E bash vps-init.sh"
        exit 6
    fi

    # Validate the resolved username exists in /etc/passwd via getent.
    if ! getent passwd "$candidate" >/dev/null 2>&1; then
        log_error "Resolved calling user '${candidate}' does not exist in /etc/passwd."
        log_error "Check \$SUDO_USER='${SUDO_USER:-}' and \$USER='${USER:-}'."
        exit 6
    fi

    CALLING_USER="$candidate"
    log_info "Calling user: ${CALLING_USER}"
}

# ---------------------------------------------------------------------------
# Docker detection — split into three separate functions per eng review
# (CRITICAL fix). The original spec wired `detect_docker || install_docker`
# where detect_docker was `command -v docker && docker info`. That conflates
# "binary missing" with "daemon stopped" — a stopped daemon would trigger
# Docker reinstall. These three functions keep the states distinct:
#   - docker_cli_present:  binary on PATH?
#   - daemon_running:      daemon reachable + caller has socket permission?
#   - permission_denied_for_docker: caller lacks docker-group membership?
# Main wires: `docker_cli_present || install_docker`. After install (or if
# cli present): `daemon_running || ensure_daemon_running` (NOT reinstall).
# ---------------------------------------------------------------------------

# Returns 0 if `command -v docker` succeeds (binary on PATH).
docker_cli_present() {
    if command -v docker >/dev/null 2>&1; then
        log_debug "Docker CLI found on PATH."
        return 0
    fi
    log_debug "Docker CLI not on PATH."
    return 1
}

# Returns 0 if `docker info` succeeds (daemon reachable AND caller has
# socket permission). Call only after docker_cli_present returns 0.
daemon_running() {
    if docker info >/dev/null 2>&1; then
        log_debug "Docker daemon is reachable."
        return 0
    fi
    log_debug "Docker daemon is not reachable (down or permission denied)."
    return 1
}

# Heuristic: returns 0 if `docker info` stderr contains "permission denied"
# (distinct from "daemon not running"). Useful for clearer error messages
# when the CLI is present but the caller lacks docker-group membership.
# Call only after docker_cli_present returns 0.
permission_denied_for_docker() {
    local stderr
    stderr="$(docker info 2>&1 >/dev/null || true)"
    if echo "$stderr" | grep -qi "permission denied"; then
        return 0
    fi
    return 1
}

# Installs Docker via get.docker.com (Docker's official convenience installer).
# Returns 0 on success. Exit 3 on any failure with the manual-install hint.
# Idempotent: caller (compute_pending_actions) only invokes this when
# docker_cli_present() returned non-zero, so we never reinstall an existing
# Docker.
install_docker() {
    log_info "Installing Docker via get.docker.com ..."

    # curl-pipe into sh. Pipefail is set, so a non-zero exit from either
    # curl or sh propagates. We capture the exit code explicitly so the
    # error message names the failing step.
    local install_rc=0
    curl -fsSL https://get.docker.com | sh -s -- >/dev/null 2>&1 || install_rc=$?

    if [[ "$install_rc" -ne 0 ]]; then
        log_error "Docker install via get.docker.com failed (exit ${install_rc})."
        log_error "Manual install hint: ${REGISTRY_INSTALL_HINT}"
        log_error "See runbook: ${RUNBOOK_URL}"
        exit 3
    fi

    # Re-verify the install: docker --version must be non-empty.
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker install reported success but 'docker' is not on PATH."
        log_error "Manual install hint: ${REGISTRY_INSTALL_HINT}"
        log_error "See runbook: ${RUNBOOK_URL}"
        exit 3
    fi

    local version
    version="$(docker --version 2>/dev/null || true)"
    if [[ -z "$version" ]]; then
        log_error "Docker install reported success but 'docker --version' is empty."
        exit 3
    fi

    log_info "Docker installed successfully: ${version}"
}

# Ensures the calling user is in the docker group. Returns 0 on success or
# if membership already present. Exit 4 on usermod failure.
#
# Order constraint: MUST run after install_docker — the docker group is
# created by Docker's installer. On systems without Docker yet, getent group
# docker would fail spuriously.
#
# Sets USER_ADDED_TO_GROUP=1 when membership was actually added (vs. already
# present) so main can print the "log out + back in" reminder only on the
# runs that need it.
USER_ADDED_TO_GROUP=0
ensure_docker_group() {
    # Verify the docker group exists (created by Docker's installer).
    if ! getent group docker >/dev/null 2>&1; then
        log_error "The 'docker' group does not exist on this system."
        log_error "This usually means Docker is not installed correctly."
        log_error "See runbook: ${RUNBOOK_URL}"
        exit 4
    fi

    # Check membership: id -nG lists the user's group names.
    if id -nG "$CALLING_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        log_debug "User '${CALLING_USER}' is already in the docker group."
        return 0
    fi

    log_info "Adding user '${CALLING_USER}' to the 'docker' group (usermod -aG docker) ..."
    local usermod_rc=0
    usermod -aG docker "$CALLING_USER" || usermod_rc=$?

    if [[ "$usermod_rc" -ne 0 ]]; then
        log_error "Failed to add user '${CALLING_USER}' to the 'docker' group (usermod exit ${usermod_rc})."
        log_error "See runbook: ${RUNBOOK_URL}"
        exit 4
    fi

    USER_ADDED_TO_GROUP=1
    log_info "User '${CALLING_USER}' added to the 'docker' group."
}

# Ensures the Docker daemon is running. Returns 0 if already running or
# successfully started. Exit 5 on failure.
# Body filled in by Task A4.
ensure_daemon_running() {
    return 0
}

# ---------------------------------------------------------------------------
# Compute the set of pending actions (for the confirmation prompt).
# Sets three global flags: NEED_INSTALL, NEED_GROUP, NEED_DAEMON.
# ---------------------------------------------------------------------------
NEED_INSTALL=false
NEED_GROUP=false
NEED_DAEMON=false

compute_pending_actions() {
    if ! docker_cli_present; then
        NEED_INSTALL=true
        return
    fi

    # CLI present. Check daemon state (do NOT trigger reinstall when only
    # the daemon is down — that's the CRITICAL eng-review fix).
    if ! daemon_running; then
        NEED_DAEMON=true
    fi

    # Check group membership only if CLI is present (the docker group is
    # created by the install step; checking it pre-install would fail
    # spuriously).
    if ! _user_in_docker_group; then
        NEED_GROUP=true
    fi
}

_user_in_docker_group() {
    # Uses id -nG to list the calling user's groups, then checks for docker.
    id -nG "$CALLING_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker
}

# ---------------------------------------------------------------------------
# Confirmation prompt — fires only when work is needed and --yes was not
# passed. Already-prepared hosts skip the prompt entirely (no-op exit 0
# in <1s). Per CLAUDE.md QA philosophy: this prompt is acceptable because
# the script genuinely modifies system state (Docker install, group
# membership) — it's not a speed bump.
# ---------------------------------------------------------------------------
prompt_to_proceed() {
    if [[ "$ASSUME_YES" == "true" ]]; then
        log_debug "--yes given; skipping confirmation prompt."
        return 0
    fi

    # If there's nothing to do, don't prompt at all.
    if [[ "$NEED_INSTALL" == "false" && "$NEED_GROUP" == "false" && "$NEED_DAEMON" == "false" ]]; then
        return 0
    fi

    # Build the 3-line summary of what will change.
    cat >&2 <<EOF
$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] The following actions will be performed on this host:
EOF
    if [[ "$NEED_INSTALL" == "true" ]]; then
        log_info "  - Install Docker via get.docker.com (apt/yum package management)"
    fi
    if [[ "$NEED_GROUP" == "true" ]]; then
        log_info "  - Add user '${CALLING_USER}' to the 'docker' group (usermod -aG)"
    fi
    if [[ "$NEED_DAEMON" == "true" ]]; then
        log_info "  - Enable + start the Docker daemon (systemctl enable --now docker)"
    fi

    printf 'Proceed? [y/N] ' >&2
    local reply=""
    if ! read -r reply; then
        # read failed (EOF / closed stdin) — treat as "no".
        log_info "Aborted (no reply on stdin)."
        exit 0
    fi
    if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
        log_info "Aborted by user."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
    # Early EUID check (Eng Amendment 10). Must be the first thing main
    # does so non-sudo invocations fail fast with a clear message instead
    # of reaching curl|sh or usermod and failing confusingly. Skipped only
    # when --help is the sole argument (parse_args handles --help and
    # exits before this check runs).
    parse_args "$@"

    if [ "$(id -u)" -ne 0 ]; then
        log_error "vps-init.sh requires root. Re-run with: sudo -E bash vps-init.sh"
        exit 2
    fi

    log_info "ClawFarm VPS init starting..."
    log_debug "RUNBOOK_URL=${RUNBOOK_URL}"
    log_debug "ASSUME_YES=${ASSUME_YES}"

    detect_calling_user

    compute_pending_actions

    # Idempotent short-circuit: if all three preconditions are met, exit 0
    # in <1s without prompting.
    if [[ "$NEED_INSTALL" == "false" && "$NEED_GROUP" == "false" && "$NEED_DAEMON" == "false" ]]; then
        log_info "Already initialized — Docker installed, '${CALLING_USER}' in docker group, daemon running."
        log_info "Nothing to do. Run resource-bootstrap.sh next."
        exit 0
    fi

    prompt_to_proceed

    # Install Docker if CLI is missing. Do NOT chain `detect_docker ||
    # install_docker` — that conflates "daemon stopped" with "binary
    # missing" (CRITICAL eng-review fix). Stopped daemon goes to
    # ensure_daemon_running, not to install.
    if [[ "$NEED_INSTALL" == "true" ]]; then
        install_docker
    fi

    # Add the calling user to the docker group if not already a member.
    # Order matters: install creates the docker group, so this MUST run
    # after install_docker.
    ensure_docker_group

    # Start/enable the daemon if it's down. Runs last so install + group
    # membership are already in place.
    if [[ "$NEED_DAEMON" == "true" ]]; then
        ensure_daemon_running
    fi

    log_info "VPS init complete."

    # Print the "log out + back in" reminder only when membership was
    # actually added during this run (not on no-op runs that only touched
    # the daemon or install). The user needs to re-login or newgrp for the
    # group change to take effect in their shell sessions.
    if [[ "${USER_ADDED_TO_GROUP:-0}" == "1" ]]; then
        log_warn "User '${CALLING_USER}' was added to the docker group."
        log_warn "To activate the group in your current shell without logging out:"
        log_warn "  newgrp docker"
        log_warn "Or log out completely and back in, then run resource-bootstrap.sh."
    else
        log_info "Next: run resource-bootstrap.sh"
    fi
}

main "$@"
