#!/bin/bash
##############################################################################
# ClawFarm Gateway Installation Script
# =========================================
# Quick installation script for deploying ClawFarm Gateway on macOS/Linux
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/ClawFarm-by-INFAC/clawfarm-tools/main/install.sh | bash -s -- \
#     --resource-token YOUR_TOKEN \
#     --agency-id YOUR_AGENCY_ID \
#     --llm-key YOUR_LLM_KEY \
#     --resource-name your-name-hostname \
#     --type local
#
# For non-interactive mode, add --yes flag
##############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration defaults
DEPLOY_DIR="${HOME}/openclaw-gateway"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
REGISTRY="${REGISTRY:-clawfarmacrproduction.azurecr.io}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTROL_PLANE_API_URL="${CONTROL_PLANE_API_URL:-https://api.clawfarm.ca}"
DEPLOYMENT_TYPE="local"

# Command line arguments
RESOURCE_TOKEN=""
AGENCY_ID=""
RESOURCE_NAME=""
LLM_KEY=""
AUTO_CONFIRM=false
VERBOSE=false

##############################################################################
# UTILITY FUNCTIONS
##############################################################################

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}╔═════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  ClawFarm Gateway Installation v1.0.0   ║${NC}"
    echo -e "${BOLD}${BLUE}╚═════════════════════════════════════╝${NC}"
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
    echo -e "${BOLD}[$step_num/10] $step_name${NC}"
}

show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    echo "Progress: $percent%"
}

##############################################################################
# ARGUMENT PARSING
##############################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --resource-token)
                RESOURCE_TOKEN="$2"
                shift 2
                ;;
            --agency-id)
                AGENCY_ID="$2"
                shift 2
                ;;
            --resource-name)
                RESOURCE_NAME="$2"
                shift 2
                ;;
            --llm-key)
                LLM_KEY="$2"
                shift 2
                ;;
            --type)
                DEPLOYMENT_TYPE="$2"
                shift 2
                ;;
            --port)
                GATEWAY_PORT="$2"
                shift 2
                ;;
            --dir)
                DEPLOY_DIR="$2"
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --tag)
                IMAGE_TAG="$2"
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
  --resource-token TOKEN   Resource token from Control Plane (required)
  --agency-id ID           Agency ID from Control Plane (required)
  --resource-name NAME     Gateway resource name (default: <user>-<hostname>)
  --llm-key KEY            LLM API key from OpenRouter (required for agents)
  --type TYPE              Deployment type: local|cloud (default: local)
  --port PORT              Gateway port (default: 8080)
  --dir DIR                Installation directory (default: ~/openclaw-gateway)
  --registry REGISTRY      Container registry (default: clawfarmacrproduction.azurecr.io)
  --tag TAG                Image tag (default: latest)
  --yes, -y                Skip confirmation prompts
  --verbose, -v            Enable verbose output
  --help, -h               Show this help message

Example:
  $0 --resource-token your_token \\
      --agency-id your_agency_id \\
      --llm-key your_llm_key \\
      --resource-name john-macbook \\
      --type local --yes

For more information, visit: https://docs.clawfarm.ca/installation
USAGE
    exit 0
}

##############################################################################
# VALIDATION FUNCTIONS
##############################################################################

validate_prerequisites() {
    print_step 1 "Validating prerequisites"
    show_progress 1 10

    local missing_prereqs=()

    # Check Docker
    if ! command -v docker &> /dev/null; then
        missing_prereqs+=("docker")
    fi

    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        missing_prereqs+=("docker-compose")
    fi

    # Check curl
    if ! command -v curl &> /dev/null; then
        missing_prereqs+=("curl")
    fi

    if [[ ${#missing_prereqs[@]} -gt 0 ]]; then
        print_error "Missing required tools: ${missing_prereqs[*]}"
        echo ""
        echo "Please install the following tools:"
        for tool in "${missing_prereqs[@]}"; do
            case $tool in
                docker)
                    echo "  - Docker: https://www.docker.com/products/docker-desktop"
                    ;;
                docker-compose)
                    echo "  - Docker Compose: Included with Docker Desktop"
                    ;;
                curl)
                    echo "  - curl: Usually pre-installed, or use Homebrew"
                    ;;
            esac
        done
        exit 1
    fi

    # Check Docker is running
    if ! docker ps &> /dev/null; then
        print_error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi

    print_success "Prerequisites validated"
}

validate_arguments() {
    print_step 2 "Validating arguments"
    show_progress 2 10

    if [[ -z "$RESOURCE_TOKEN" ]]; then
        print_error "Resource token is required (use --resource-token)"
        exit 1
    fi

    if [[ -z "$AGENCY_ID" ]]; then
        print_error "Agency ID is required (use --agency-id)"
        exit 1
    fi

    if [[ -z "$RESOURCE_NAME" ]]; then
        # Auto-generate resource name from user and hostname
        local username=$(whoami | sed 's/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]')
        local hostname=$(hostname | sed 's/[^a-zA-Z0-9-]//g' | tr '[:upper:]' '[:lower:]')
        RESOURCE_NAME="${username}-${hostname}"
        print_info "Auto-generated resource name: $RESOURCE_NAME"
    fi

    print_success "Arguments validated"
}

##############################################################################
# INSTALLATION FUNCTIONS
##############################################################################

create_deployment_directory() {
    print_step 3 "Creating deployment directory"
    show_progress 3 10

    if [[ -d "$DEPLOY_DIR" ]]; then
        if [[ "$AUTO_CONFIRM" != "true" ]]; then
            echo -n "Deployment directory already exists. Continue? [y/N] "
            read -r response
            if [[ "$response" != "y" && "$response" != "Y" ]]; then
                print_info "Installation cancelled by user"
                exit 0
            fi
        fi
    fi

    mkdir -p "$DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR/logs"

    print_success "Deployment directory created: $DEPLOY_DIR"
}

generate_configuration_files() {
    print_step 4 "Generating configuration files"
    show_progress 4 10

    # Generate .env file
    cat > "$DEPLOY_DIR/.env" <<EOF
# Control Plane Configuration
CONTROL_PLANE_API_URL=${CONTROL_PLANE_API_URL}
RESOURCE_TOKEN=${RESOURCE_TOKEN}
AGENCY_ID=${AGENCY_ID}
GATEWAY_NAME=${RESOURCE_NAME}
GATEWAY_ID=${RESOURCE_NAME}-$(date +%s)
GATEWAY_PORT=${GATEWAY_PORT}
DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE}

# LLM Configuration
LLM_KEY=${LLM_KEY}
DEFAULT_LLM_MODEL=moonshotai/kimi-k2.5

# Logging
LOG_LEVEL=info
EOF

    # Generate docker-compose.yml
    cat > "$DEPLOY_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  openclaw-gateway:
    image: ${REGISTRY}/openclaw-gateway:${IMAGE_TAG}
    container_name: ${RESOURCE_NAME}
    ports:
      - "${GATEWAY_PORT}:8080"
    environment:
      - CONTROL_PLANE_API_URL=${CONTROL_PLANE_API_URL}
      - RESOURCE_TOKEN=${RESOURCE_TOKEN}
      - AGENCY_ID=${AGENCY_ID}
      - GATEWAY_NAME=${RESOURCE_NAME}
    volumes:
      - openclaw-workspace:/workspace
      - openclaw-logs:/logs
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  openclaw-workspace:
    driver: local
  openclaw-logs:
    driver: local
EOF

    print_success "Configuration files generated"
}

pull_docker_image() {
    print_step 5 "Pulling Docker image"
    show_progress 5 10

    cd "$DEPLOY_DIR"
    if ! docker-compose pull 2>&1; then
        print_error "Failed to pull Docker image"
        return 1
    fi

    print_success "Docker image pulled successfully"
}

start_gateway() {
    print_step 6 "Starting gateway"
    show_progress 6 10

    cd "$DEPLOY_DIR"
    if ! docker-compose up -d 2>&1; then
        print_error "Failed to start gateway"
        return 1
    fi

    print_success "Gateway started"
}

verify_deployment() {
    print_step 7 "Verifying deployment"
    show_progress 7 10

    # Wait for health check
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf http://localhost:${GATEWAY_PORT}/health &>/dev/null; then
            print_success "Gateway is healthy and responding"
            return 0
        fi

        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done

    echo ""
    print_error "Gateway health check failed"
    echo "Check logs with: cd $DEPLOY_DIR && docker-compose logs"
    return 1
}

show_summary() {
    print_step 8 "Installation summary"
    show_progress 8 10

    echo ""
    echo -e "${BOLD}${GREEN}Installation completed successfully!${NC}"
    echo ""
    echo -e "${BOLD}Gateway Details:${NC}"
    echo "  Resource Name:   $RESOURCE_NAME"
    echo "  Gateway Port:    $GATEWAY_PORT"
    echo "  Install Dir:     $DEPLOY_DIR"
    echo "  Agency ID:       $AGENCY_ID"
    echo ""
    echo -e "${BOLD}Management Commands:${NC}"
    echo "  View logs:       cd $DEPLOY_DIR && docker-compose logs -f"
    echo "  Stop gateway:     cd $DEPLOY_DIR && docker-compose down"
    echo "  Start gateway:    cd $DEPLOY_DIR && docker-compose up -d"
    echo "  Restart gateway:  cd $DEPLOY_DIR && docker-compose restart"
    echo ""
    echo "  Health check:    curl http://localhost:${GATEWAY_PORT}/health"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Verify your gateway in Control Plane Dashboard"
    echo "  2. Set up communication channels (WeChat, Telegram, etc.)"
    echo "  3. Configure skills and agents as needed"
    echo ""
    echo "For more information, visit: https://docs.clawfarm.ca"
    echo ""
}

##############################################################################
# MAIN INSTALLATION FLOW
##############################################################################

main() {
    print_header

    # Parse arguments
    parse_arguments "$@"

    # Installation steps
    validate_prerequisites
    validate_arguments
    create_deployment_directory
    generate_configuration_files
    pull_docker_image
    start_gateway

    # Verify and show summary
    if verify_deployment; then
        show_summary
        exit 0
    else
        print_error "Installation failed. Check logs for details."
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
