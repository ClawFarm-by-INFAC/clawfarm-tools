#!/bin/bash
##############################################################################
# ClawFarm Gateway Uninstallation Script
# ======================================
# Comprehensive removal of ClawFarm Gateway deployment
#
# Usage:
#   curl -sSL https://github.com/ClawFarm-by-INFAC/clawfarm-tools/raw/refs/heads/main/onboarding/uninstall.sh | bash -s -- \
#     --dir ~/openclaw-gateway
#
# For non-interactive mode, add --yes flag
##############################################################################

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration defaults
DEPLOY_DIR="${HOME}/openclaw-gateway"
AUTO_CONFIRM=false
VERBOSE=false
DRY_RUN=false
KEEP_DATA=false
REMOVE_DOCKER_IMAGES=false

# Command line arguments
RESOURCE_NAME=""
GATEWAY_NAME=""

##############################################################################
# UTILITY FUNCTIONS
##############################################################################

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  ClawFarm Gateway Uninstallation v1.0.0  ║${NC}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════╝${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo "ℹ $1"
}

print_step() {
    local step_num="$1"
    local step_name="$2"
    echo -e "${BOLD}[$step_num/8] $step_name${NC}"
}

##############################################################################
# ARGUMENT PARSING
##############################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir)
                DEPLOY_DIR="$2"
                shift 2
                ;;
            --resource-name)
                RESOURCE_NAME="$2"
                shift 2
                ;;
            --gateway-name)
                GATEWAY_NAME="$2"
                shift 2
                ;;
            --yes|-y)
                AUTO_CONFIRM=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --dry-run|-d)
                DRY_RUN=true
                print_warning "Dry run mode: no changes will be made"
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                print_info "Will keep data volumes and workspace"
                shift
                ;;
            --remove-images)
                REMOVE_DOCKER_IMAGES=true
                print_info "Will remove Docker images"
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                echo ""
                usage
                exit 1
                ;;
        esac
    done
}

usage() {
    cat <<USAGE
Usage: $0 [OPTIONS]

Options:
  --dir DIR                  Installation directory (default: ~/openclaw-gateway)
  --resource-name NAME       Gateway resource name (auto-detected if not specified)
  --gateway-name NAME        Container name (auto-detected if not specified)
  --yes, -y                  Skip confirmation prompts
  --verbose, -v              Enable verbose output
  --dry-run, -d              Show what would be done without executing
  --keep-data                Keep data volumes and workspace directory
  --remove-images            Remove Docker images (not recommended, saves space)
  --help, -h                 Show this help message

Example:
  $0 --dir ~/openclaw-gateway --yes

For more information, visit: https://docs.clawfarm.ca/installation
USAGE
    exit 0
}

##############################################################################
# DETECTION FUNCTIONS
##############################################################################

detect_deployment_info() {
    print_info "Detecting deployment configuration..."

    # Check if deploy directory exists
    if [[ ! -d "$DEPLOY_DIR" ]]; then
        print_warning "Deployment directory not found: $DEPLOY_DIR"
        print_info "The gateway may have already been uninstalled or installed elsewhere"
        return 1
    fi

    # Try to read .env file for configuration
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        print_info "Found configuration file"

        # Extract GATEWAY_NAME from .env
        if [[ -z "$GATEWAY_NAME" ]]; then
            GATEWAY_NAME=$(grep "^GATEWAY_NAME=" "$DEPLOY_DIR/.env" | cut -d'=' -f2)
        fi

        # Extract RESOURCE_NAME from .env
        if [[ -z "$RESOURCE_NAME" ]]; then
            RESOURCE_NAME=$(grep "^GATEWAY_NAME=" "$DEPLOY_DIR/.env" | cut -d'=' -f2)
        fi
    fi

    # Auto-detect container name if not set
    if [[ -z "$GATEWAY_NAME" ]]; then
        # Try to find running clawfarm-gateway containers
        GATEWAY_NAME=$(docker ps --format '{{.Names}}' | grep -E '^clawfarm-gateway-' | head -1)

        # Fallback to pattern matching
        if [[ -z "$GATEWAY_NAME" ]]; then
            GATEWAY_NAME=$(docker ps --format '{{.Names}}' | grep -E 'gateway|openclaw' | head -1)
        fi
    fi

    if [[ -n "$GATEWAY_NAME" ]]; then
        print_success "Detected gateway container: $GATEWAY_NAME"
    else
        print_warning "No running gateway container detected"
    fi

    return 0
}

##############################################################################
# UNINSTALLATION FUNCTIONS
##############################################################################

stop_and_remove_containers() {
    print_step 1 "Stopping and removing containers"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would stop and remove containers"
        return 0
    fi

    cd "$DEPLOY_DIR" 2>/dev/null || return 0

    # Stop containers using docker-compose if available
    if [[ -f "docker-compose.yml" ]]; then
        print_info "Stopping containers with docker-compose..."

        if docker-compose down -v 2>&1; then
            print_success "Containers stopped via docker-compose"
        else
            print_warning "docker-compose down failed, trying manual removal"
        fi
    fi

    # Manual container removal as fallback
    local -a containers_to_remove=()

    # Add gateway container if detected
    if [[ -n "$GATEWAY_NAME" ]] && docker ps -a --format '{{.Names}}' | grep -q "^${GATEWAY_NAME}$"; then
        containers_to_remove+=("$GATEWAY_NAME")
    fi

    # Add browser proxy container
    if docker ps -a --format '{{.Names}}' | grep -q "^clawfarm-browser-proxy$"; then
        containers_to_remove+=("clawfarm-browser-proxy")
    fi

    # Remove any detected containers
    for container in "${containers_to_remove[@]:-}"; do
        print_info "Removing container: $container"

        if docker stop "$container" 2>/dev/null; then
            print_success "Stopped: $container"
        fi

        if docker rm "$container" 2>/dev/null; then
            print_success "Removed: $container"
        fi
    done

    print_success "Containers removed"
}

remove_docker_volumes() {
    print_step 2 "Removing Docker volumes"

    if [[ "$KEEP_DATA" == "true" ]]; then
        print_warning "Keeping data volumes (--keep-data specified)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove Docker volumes"
        return 0
    fi

    cd "$DEPLOY_DIR" 2>/dev/null || return 0

    # Remove volumes defined in docker-compose.yml
    if [[ -f "docker-compose.yml" ]]; then
        print_info "Removing volumes from docker-compose..."

        # Extract volume names and remove them
        local volumes
        volumes=$(docker-compose down -v 2>/dev/null | grep -o 'volume.*' || echo "")

        if [[ -n "$volumes" ]]; then
            print_success "Volumes removed"
        else
            print_info "No volumes to remove"
        fi
    fi

    # Manual volume removal for named volumes
    local -a volumes_to_remove=(
        "openclaw-workspace"
        "openclaw-logs"
    )

    for volume in "${volumes_to_remove[@]:-}"; do
        if docker volume ls -q | grep -q "^${volume}$"; then
            print_info "Removing volume: $volume"

            if docker volume rm "$volume" 2>/dev/null; then
                print_success "Removed volume: $volume"
            else
                print_warning "Failed to remove volume: $volume"
            fi
        fi
    done

    print_success "Docker volumes removed"
}

remove_docker_images() {
    print_step 3 "Removing Docker images"

    if [[ "$REMOVE_DOCKER_IMAGES" != "true" ]]; then
        print_info "Keeping Docker images (use --remove-images to delete)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove Docker images"
        return 0
    fi

    # Remove gateway image
    local gateway_image
    gateway_image=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'openclaw-gateway|clawfarm.*gateway' || echo "")

    if [[ -n "$gateway_image" ]]; then
        print_info "Removing image: $gateway_image"

        if docker rmi "$gateway_image" 2>/dev/null; then
            print_success "Removed image: $gateway_image"
        else
            print_warning "Failed to remove image: $gateway_image"
        fi
    fi

    # Remove nginx proxy image
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^nginx:alpine$'; then
        print_info "Removing image: nginx:alpine"

        if docker rmi "nginx:alpine" 2>/dev/null; then
            print_success "Removed image: nginx:alpine"
        fi
    fi

    print_success "Docker images removed"
}

remove_docker_networks() {
    print_step 4 "Removing Docker networks"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove Docker networks"
        return 0
    fi

    # Remove openclaw-network
    if docker network ls --format '{{.Name}}' | grep -q '^openclaw-network$'; then
        print_info "Removing network: openclaw-network"

        if docker network rm "openclaw-network" 2>/dev/null; then
            print_success "Removed network: openclaw-network"
        else
            print_warning "Failed to remove network: openclaw-network"
        fi
    else
        print_info "No openclaw-network found"
    fi

    print_success "Docker networks removed"
}

remove_launch_agents() {
    print_step 5 "Removing macOS LaunchAgents"

    if [[ "$OSTYPE" != darwin* ]]; then
        print_info "Skipping (not on macOS)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove macOS LaunchAgents"
        return 0
    fi

    local launch_agents_dir="$HOME/Library/LaunchAgents"

    # Array of all possible clawfarm LaunchAgent identifiers
    local -a launch_agent_ids=(
        "com.clawfarm.gateway"
        "ca.clawfarm.browser"
        "ca.clawfarm.daemon"
    )

    local removed_count=0

    # Try to unload and remove each known LaunchAgent
    for agent_id in "${launch_agent_ids[@]:-}"; do
        local plist_file="$launch_agents_dir/${agent_id}.plist"

        if [[ -f "$plist_file" ]]; then
            print_info "Found LaunchAgent: $agent_id"

            # Try to unload the LaunchAgent using both methods
            if launchctl unload "$plist_file" 2>/dev/null; then
                print_success "Unloaded: $agent_id"
            elif launchctl bootout "gui/$(id -u)/${agent_id}" 2>/dev/null; then
                print_success "Booted out: $agent_id"
            else
                print_warning "$agent_id was not loaded"
            fi

            # Remove the plist file
            if rm -f "$plist_file"; then
                print_success "Removed plist: $plist_file"
                removed_count=$((removed_count + 1))
            else
                print_warning "Failed to remove plist: $plist_file"
            fi
        fi
    done

    # Also scan for any other clawfarm plist files that might exist
    if [[ -d "$launch_agents_dir" ]]; then
        local -a additional_plists
        additional_plists=($(find "$launch_agents_dir" -name "*clawfarm*.plist" -o -name "*ca.clawfarm*.plist" 2>/dev/null))

        for plist_file in "${additional_plists[@]:-}"; do
            if [[ -f "$plist_file" ]]; then
                print_info "Found additional clawfarm plist: $(basename "$plist_file")"

                # Extract the agent ID (filename without .plist extension)
                local agent_id=$(basename "$plist_file" .plist)

                # Try to unload
                launchctl unload "$plist_file" 2>/dev/null || launchctl bootout "gui/$(id -u)/${agent_id}" 2>/dev/null || true

                # Remove the file
                if rm -f "$plist_file"; then
                    print_success "Removed additional plist: $plist_file"
                    removed_count=$((removed_count + 1))
                fi
            fi
        done
    fi

    if [[ $removed_count -eq 0 ]]; then
        print_info "No clawfarm LaunchAgents found to remove"
    else
        print_success "Removed $removed_count LaunchAgent(s)"
    fi

    print_success "LaunchAgents cleanup completed"
}

remove_systemd_services() {
    print_step 6 "Removing systemd services (Linux)"

    if [[ "$OSTYPE" == darwin* ]]; then
        print_info "Skipping (on macOS)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove systemd services"
        return 0
    fi

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]] && ! command -v sudo &> /dev/null; then
        print_warning "Skipping (requires root privileges)"
        return 0
    fi

    local service_file="/etc/systemd/system/clawfarm-gateway.service"

    if [[ -f "$service_file" ]]; then
        print_info "Stopping and disabling service: clawfarm-gateway"

        local sudo_cmd=""
        if [[ $EUID -ne 0 ]]; then
            sudo_cmd="sudo"
        fi

        # Stop and disable the service
        if $sudo_cmd systemctl stop clawfarm-gateway 2>/dev/null; then
            print_success "Service stopped"
        fi

        if $sudo_cmd systemctl disable clawfarm-gateway 2>/dev/null; then
            print_success "Service disabled"
        fi

        # Remove the service file
        print_info "Removing service file: $service_file"

        if $sudo_cmd rm -f "$service_file"; then
            print_success "Service file removed"
        fi

        # Reload systemd
        $sudo_cmd systemctl daemon-reload 2>/dev/null || true
    else
        print_info "No systemd service found"
    fi

    print_success "systemd services removed"
}

remove_deployment_directory() {
    print_step 7 "Removing deployment directory"

    if [[ "$KEEP_DATA" == "true" ]]; then
        print_warning "Keeping deployment directory (--keep-data specified)"
        print_info "Directory: $DEPLOY_DIR"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would remove deployment directory: $DEPLOY_DIR"
        return 0
    fi

    if [[ -d "$DEPLOY_DIR" ]]; then
        print_info "Removing deployment directory: $DEPLOY_DIR"

        # Remove the deployment directory
        if rm -rf "$DEPLOY_DIR"; then
            print_success "Deployment directory removed"
        else
            print_error "Failed to remove deployment directory"
            print_info "You may need to remove it manually:"
            print_info "  sudo rm -rf $DEPLOY_DIR"
            return 1
        fi
    else
        print_info "Deployment directory not found: $DEPLOY_DIR"
    fi

    print_success "Deployment directory removed"
}

show_summary() {
    print_step 8 "Uninstallation summary"

    echo ""
    echo -e "${BOLD}${GREEN}Uninstallation completed successfully!${NC}"
    echo ""
    echo -e "${BOLD}Removed Components:${NC}"

    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  ✓ Docker containers (gateway, browser-proxy)"
        echo "  ✓ Docker volumes (workspace, logs)"
    else
        echo "  ✓ Docker containers (gateway, browser-proxy)"
        echo "  ○ Data volumes preserved (--keep-data)"
    fi

    if [[ "$REMOVE_DOCKER_IMAGES" == "true" ]]; then
        echo "  ✓ Docker images"
    fi

    echo "  ✓ Docker networks"
    echo "  ✓ Auto-start services (LaunchAgent/systemd)"
    if [[ "$OSTYPE" == darwin* ]]; then
        echo "  ✓ Browser service (Chrome CDP)"
    fi
    echo "  ✓ Deployment directory"

    if [[ "$KEEP_DATA" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}Note: Data preserved in:${NC} $DEPLOY_DIR"
        echo "  To remove manually: rm -rf $DEPLOY_DIR"
    fi

    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Verify containers are gone: docker ps -a"
    echo "  2. Check for remaining volumes: docker volume ls"
    echo "  3. Remove any remaining networks: docker network ls"
    echo ""
    echo "To reinstall ClawFarm Gateway:"
    echo "  curl -sSL https://github.com/ClawFarm-by-INFAC/clawfarm-tools/raw/refs/heads/main/onboarding/install.sh | bash"
    echo ""
}

##############################################################################
# MAIN UNINSTALLATION FLOW
##############################################################################

confirm_uninstall() {
    if [[ "$AUTO_CONFIRM" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}⚠ WARNING: This will completely remove ClawFarm Gateway${NC}"
    echo ""
    echo "This action will:"
    echo "  • Stop and remove all gateway containers"
    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  • Remove all data volumes and workspace"
    else
        echo "  • Keep data volumes (--keep-data specified)"
    fi
    if [[ "$REMOVE_DOCKER_IMAGES" == "true" ]]; then
        echo "  • Remove Docker images"
    fi
    echo "  • Remove Docker networks"
    echo "  • Remove auto-start services"
    if [[ "$KEEP_DATA" != "true" ]]; then
        echo "  • Delete deployment directory: $DEPLOY_DIR"
    else
        echo "  • Keep deployment directory with configuration"
    fi
    echo ""
    echo -e "${RED}This action cannot be undone!${NC}"
    echo ""

    read -rp "Are you sure you want to uninstall? [y/N]: " response
    case "$response" in
        [Yy]|[Yy][Ee][Ss])
            return 0
            ;;
        *)
            echo ""
            print_info "Uninstallation cancelled by user"
            exit 0
            ;;
    esac
}

main() {
    print_header

    # Parse arguments
    parse_arguments "$@"

    # Detect deployment configuration
    if ! detect_deployment_info; then
        if [[ "$AUTO_CONFIRM" != "true" ]]; then
            echo ""
            read -rp "Continue anyway? [y/N]: " response
            case "$response" in
                [Yy]|[Yy][Ee][Ss])
                    :
                    ;;
                *)
                    print_info "Uninstallation cancelled"
                    exit 0
                    ;;
            esac
        fi
    fi

    # Confirm uninstallation
    confirm_uninstall

    # Uninstallation steps
    stop_and_remove_containers
    remove_docker_volumes
    remove_docker_images
    remove_docker_networks
    remove_launch_agents
    remove_systemd_services
    remove_deployment_directory

    # Show summary
    show_summary

    exit 0
}

# Run main function - this works for both direct execution and piped input (curl | bash)
main "$@"
