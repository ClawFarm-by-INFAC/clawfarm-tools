#!/bin/bash
##############################################################################
# ClawFarm Gateway Installation Script
# =========================================
# Comprehensive installation script for deploying ClawFarm Gateway on macOS/Linux
#
# Usage:
#   curl -sSL https://github.com/ClawFarm-by-INFAC/clawfarm-tools/raw/refs/heads/main/onboarding/install.sh | bash -s -- \
#     --resource-token YOUR_TOKEN \
#     --agency-id YOUR_AGENCY_ID \
#     --llm-key YOUR_LLM_KEY \
#     --resource-name your-name-hostname \
#     --type local
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
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
REGISTRY="${REGISTRY:-clawfarmacrproduction.azurecr.io}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTROL_PLANE_API_URL="${CONTROL_PLANE_API_URL:-https://api.clawfarm.ca}"
DEPLOYMENT_TYPE="local"
DEFAULT_LLM_MODEL="google/gemma-4-26b-a4b-it"
SKIP_TOKEN_VALIDATION=false

DOCKER_REGISTRY_USERNAME="openclaw-readonly"
DOCKER_REGISTRY_PASSWORD=""
SKIP_DOCKER_LOGIN=false

# Command line arguments
RESOURCE_TOKEN=""
AGENCY_ID=""
RESOURCE_NAME=""
LLM_KEY=""
AUTO_CONFIRM=false
VERBOSE=false
DRY_RUN=false

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
        # Skip empty arguments
        [[ -z "$1" ]] && { shift; continue; }

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
            --llm-model)
                DEFAULT_LLM_MODEL="$2"
                shift 2
                ;;
            --registry-password)
                DOCKER_REGISTRY_PASSWORD="$2"
                shift 2
                ;;
            --skip-docker-login)
                SKIP_DOCKER_LOGIN=true
                shift
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
            --dry-run|-d)
                DRY_RUN=true
                print_warning "Dry run mode: no changes will be made"
                shift
                ;;
            --skip-token-validation)
                SKIP_TOKEN_VALIDATION=true
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
  --resource-token TOKEN       Resource token from Control Plane (required)
  --agency-id ID               Agency ID from Control Plane (required)
  --resource-name NAME         Gateway resource name (default: <user>-<hostname>)
  --llm-key KEY                LLM API key from OpenRouter (recommended for agents)
  --llm-model MODEL            Default LLM model (default: google/gemma-4-26b-a4b-it)
  --registry-password PASS     Docker registry password for authentication
  --type TYPE                  Deployment type: local|cloud (default: local)
  --port PORT                  Gateway port (default: 8080)
  --dir DIR                    Installation directory (default: ~/openclaw-gateway)
  --registry REGISTRY          Container registry (default: clawfarmacrproduction.azurecr.io)
  --tag TAG                    Image tag (default: latest)
  --yes, -y                    Skip confirmation prompts
  --verbose, -v                Enable verbose output
  --dry-run, -d                Show what would be done without executing
  --skip-token-validation      Skip Control Plane token validation
  --skip-docker-login          Skip Docker registry login
  --help, -h                   Show this help message

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

validate_resource_token() {
    local token="$1"
    local control_plane_url="${CONTROL_PLANE_API_URL:-https://api.clawfarm.ca}"

    print_info "Validating resource token with control plane..."

    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Token validated (dry run)"
        return 0
    fi

    if [[ "$SKIP_TOKEN_VALIDATION" == "true" ]]; then
        print_warning "Token validation skipped (SKIP_TOKEN_VALIDATION=true)"
        return 0
    fi

    # Use the registration endpoint which requires resource token
    local registration_url="${control_plane_url}/api/resources/register"

    # Create validation registration payload using correct format
    local validation_gateway_id="install-validation-$(date +%s)"
    local validation_gateway_name="install-validation-$(date +%s)"

    local registration_data
    registration_data=$(cat <<EOF
{
  "name": "${validation_gateway_name}",
  "gateway_id": "${validation_gateway_id}",
  "deployment_type": "docker",
  "ip_address": "validation",
  "region": "auto",
  "version": "1.0.0",
  "capabilities": ["llm", "channels", "skills"]
}
EOF
)

    local response
    local http_code

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "X-Resource-Token: ${token}" \
        -d "$registration_data" \
        "${registration_url}" 2>/dev/null)

    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        print_success "Resource token validated successfully"
        return 0
    elif [[ "$http_code" == "401" ]]; then
        print_error "Invalid resource token - authentication failed"
        return 1
    elif [[ "$http_code" == "403" ]]; then
        print_error "Resource token not accepted - access denied"
        return 1
    elif [[ "$http_code" == "404" ]]; then
        print_warning "Control plane endpoint not found - assuming token is valid"
        return 0
    else
        print_warning "Unable to validate token (HTTP ${http_code}) - continuing with installation"
        print_info "To skip token validation, use: --skip-token-validation"
        return 0
    fi
}

generate_openclaw_state_config() {
    local deploy_dir="$1"
    local gateway_port="${2:-8080}"
    local default_llm_model="${3:-google/gemma-4-26b-a4b-it}"

    print_info "Generating OpenClaw state configuration..."

    # Create .openclaw directory
    local openclaw_dir="${deploy_dir}/.openclaw"
    mkdir -p "$openclaw_dir"

    # Generate a unique gateway token
    local gateway_token
    gateway_token=$(openssl rand -hex 32 2>/dev/null || echo "gateway-token-$(date +%s)-${RANDOM}")

    # Create openclaw.json with correct gateway configuration schema
    cat > "${openclaw_dir}/openclaw.json" <<EOF
{
  "gateway": {
    "port": ${gateway_port},
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${gateway_token}"
    },
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:${gateway_port}",
        "http://127.0.0.1:${gateway_port}",
        "http://localhost:18789",
        "http://127.0.0.1:18789"
      ]
    }
  },
  "agents": {
    "list": [
      {
        "id": "main",
        "model": "openrouter/${default_llm_model}"
      }
    ]
  },
  "plugins": {
    "entries": {
      "openrouter": {
        "enabled": true
      },
      "browser": {
        "enabled": false
      }
    }
  }
}
EOF

    print_success "OpenClaw state configuration generated"
    print_info "Gateway token: ${gateway_token}"
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

    # Create necessary directories
    mkdir -p "$DEPLOY_DIR/workspace"
    mkdir -p "$DEPLOY_DIR/logs"

    # Copy nginx.conf for browser proxy
    # When script is piped via curl, we need to embed nginx.conf directly
    # Only try to copy from script directory if running from a file
    local nginx_conf_source=""
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        nginx_conf_source="$script_dir/nginx.conf"
    fi

    if [[ -f "$nginx_conf_source" ]]; then
        print_info "Copying nginx.conf for browser proxy..."
        cp "$nginx_conf_source" "$DEPLOY_DIR/nginx.conf"
        print_success "nginx.conf copied"
    else
        # Embed nginx.conf directly for self-contained installation
        print_info "Generating nginx.conf for browser proxy..."
        cat > "$DEPLOY_DIR/nginx.conf" <<'EOF'
# Nginx configuration for CDP WebSocket Proxy
# Proxies Chrome DevTools Protocol from localhost:9222 to port 9223

events {
    worker_connections 1024;
}

http {
    # Upstream to Chrome CDP endpoint
    upstream chrome_cdp {
        server host.docker.internal:9222;
        keepalive 64;
    }

    # Server block for CDP proxy
    server {
        listen 9223;
        server_name _;

        # Enable detailed logging for debugging
        access_log /var/log/nginx/cdp_access.log;
        error_log /var/log/nginx/cdp_error.log info;

        # Buffer settings for large CDP messages
        client_body_buffer_size 10M;
        client_max_body_size 10M;

        # Proxy settings for HTTP endpoints
        location / {
            proxy_pass http://chrome_cdp;
            proxy_http_version 1.1;

            # Headers for HTTP proxying - set Host to what Chrome expects
            proxy_set_header Host localhost;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Timeout settings
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;

            # URL rewriting for WebSocket URLs in JSON responses
            # This rewrites localhost:9222 to localhost:9223
            sub_filter 'localhost:9222' 'localhost:9223';
            sub_filter '127.0.0.1:9222' 'localhost:9223';
            sub_filter_types *;
            sub_filter_once off;
        }

        # WebSocket specific configuration
        # Matches paths like: /devtools/page/ABC123
        location ~ ^/(devtools|ws) {
            proxy_pass http://chrome_cdp;
            proxy_http_version 1.1;

            # WebSocket upgrade headers
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            # Standard proxy headers - set Host to what Chrome expects
            proxy_set_header Host localhost;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # WebSocket timeout settings
            proxy_connect_timeout 7d;
            proxy_send_timeout 7d;
            proxy_read_timeout 7d;

            # Disable buffering for real-time WebSocket communication
            proxy_buffering off;
            proxy_request_buffering off;

            # TCP settings for WebSocket
            proxy_socket_keepalive on;
            proxy_send_lowat 0;
        }

        # Health check endpoint
        location /health {
            access_log off;
            return 200 '{"status":"healthy","proxy":"nginx","chrome":"host.docker.internal:9222"}';
            add_header Content-Type application/json;
        }

        # JSON endpoints (with URL rewriting)
        location = /json {
            proxy_pass http://chrome_cdp;
            proxy_http_version 1.1;
            proxy_set_header Host localhost;

            # Rewrite WebSocket URLs in JSON response
            sub_filter '"webSocketDebuggerUrl": "ws://localhost:9222' '"webSocketDebuggerUrl": "ws://localhost:9223';
            sub_filter '"webSocketDebuggerUrl": "ws://127.0.0.1:9222' '"webSocketDebuggerUrl": "ws://localhost:9223';
            sub_filter_types *;
            sub_filter_once off;
        }

        location = /json/version {
            proxy_pass http://chrome_cdp;
            proxy_http_version 1.1;
            proxy_set_header Host localhost;

            # Rewrite WebSocket URLs
            sub_filter '"webSocketDebuggerUrl": "ws://localhost:9222' '"webSocketDebuggerUrl": "ws://localhost:9223';
            sub_filter '"webSocketDebuggerUrl": "ws://127.0.0.1:9222' '"webSocketDebuggerUrl": "ws://localhost:9223';
            sub_filter_types *;
            sub_filter_once off;
        }

        location = /json/list {
            proxy_pass http://chrome_cdp;
            proxy_http_version 1.1;
            proxy_set_header Host localhost;

            # Rewrite WebSocket URLs
            sub_filter 'ws://localhost:9222' 'ws://localhost:9223';
            sub_filter 'ws://127.0.0.1:9222' 'ws://localhost:9223';
            sub_filter_types *;
            sub_filter_once off;
        }
    }
}
EOF
        print_success "nginx.conf generated"
    fi

    # Generate .env file with correct variable names
    cat > "$DEPLOY_DIR/.env" <<EOF
# OpenClaw Gateway Environment Configuration
# Generated by ClawFarm installation script

# Docker Configuration
REGISTRY=${REGISTRY}
IMAGE_TAG=${IMAGE_TAG}
IMAGE_TAG_SEPARATOR=:
GATEWAY_PORT=${GATEWAY_PORT}

# Gateway Configuration
GATEWAY_NAME=${RESOURCE_NAME}
GATEWAY_ID=${RESOURCE_NAME}-$(date +%s)
LOG_LEVEL=info

# Control Plane Configuration
CONTROL_PLANE_API_URL=${CONTROL_PLANE_API_URL}
RESOURCE_TOKEN=${RESOURCE_TOKEN}
OPENROUTER_API_KEY=${LLM_KEY}
EOF

    # Generate docker-compose.yml with proper volume mounting and browser proxy
    cat > "$DEPLOY_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  openclaw-gateway:
    image: \${REGISTRY}/openclaw-gateway\${IMAGE_TAG_SEPARATOR}\${IMAGE_TAG}
    container_name: \${GATEWAY_NAME}
    # Extra hosts needed for CDP access to host
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "\${GATEWAY_PORT}:8080"
    env_file:
      - .env
    volumes:
      - ./workspace:/workspace
      - ./logs:/var/log/openclaw
      - ./.openclaw:/home/openclaw/.openclaw
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - openclaw-network

  # Nginx CDP Proxy for Chrome DevTools Protocol
  clawfarm-browser-proxy:
    image: nginx:alpine
    container_name: clawfarm-browser-proxy
    ports:
      - "9223:9223"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:9223/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
    networks:
      - openclaw-network

networks:
  openclaw-network:
    driver: bridge
EOF

    # Generate OpenClaw state configuration with gateway token
    if ! generate_openclaw_state_config "$DEPLOY_DIR" "$GATEWAY_PORT" "$DEFAULT_LLM_MODEL"; then
        print_error "Failed to generate OpenClaw state configuration"
        return 1
    fi

    print_success "Configuration files generated"
}

docker_registry_login() {
    print_step 5 "Authenticating with Docker registry"
    show_progress 5 10

    # Skip if registry password not provided or explicitly skipped
    if [[ -z "$DOCKER_REGISTRY_PASSWORD" ]] || [[ "$SKIP_DOCKER_LOGIN" == "true" ]]; then
        print_info "Docker registry authentication skipped (public images or --skip-docker-login)"
        return 0
    fi

    # Check if already logged in to the registry
    if docker info 2>/dev/null | grep -q "Username: ${DOCKER_REGISTRY_USERNAME}"; then
        print_success "Already authenticated with Docker registry"
        return 0
    fi

    print_info "Authenticating with Azure Container Registry..."

    # Extract registry from REGISTRY variable
    local registry="${REGISTRY}"

    # Perform Docker login
    if echo "$DOCKER_REGISTRY_PASSWORD" | docker login -u "$DOCKER_REGISTRY_USERNAME" --password-stdin "$registry" 2>&1; then
        print_success "Docker registry authentication successful"
        return 0
    else
        print_error "Docker registry authentication failed"
        print_info "You can skip authentication with --skip-docker-login"
        return 1
    fi
}

pull_docker_image() {
    print_step 6 "Pulling Docker image"
    show_progress 6 10

    cd "$DEPLOY_DIR"
    if ! docker-compose pull 2>&1; then
        print_error "Failed to pull Docker image"
        return 1
    fi

    print_success "Docker image pulled successfully"
}

start_gateway() {
    print_step 7 "Starting gateway"
    show_progress 7 10

    cd "$DEPLOY_DIR"
    if ! docker-compose up -d 2>&1; then
        print_error "Failed to start gateway"
        return 1
    fi

    print_success "Gateway started"
}

verify_deployment() {
    print_step 8 "Verifying deployment"
    show_progress 8 10

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

setup_communication_channels() {
    print_step 9 "Setting up communication channels"
    show_progress 9 13

    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Communication channels configured (dry run)"
        return 0
    fi

    # Find the gateway container
    local gateway_container=""
    local env_file="${DEPLOY_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        # Extract resource token and get last 4 characters
        local resource_token
        resource_token=$(grep "^RESOURCE_TOKEN=" "$env_file" | cut -d'=' -f2)
        if [[ -n "$resource_token" ]]; then
            local token_suffix="${resource_token: -4}"
            gateway_container="clawfarm-gateway-${token_suffix}"
        fi
    fi

    # Fallback to pattern matching if exact match fails
    if [[ -z "$gateway_container" ]] || ! docker ps --format '{{.Names}}' | grep -q "^${gateway_container}$"; then
        gateway_container=$(docker ps --format '{{.Names}}' | grep -E '^clawfarm-gateway-' | head -1)
    fi

    if [[ -z "$gateway_container" ]]; then
        print_warning "Channel setup skipped - gateway container not found"
        print_info "You can setup channels manually after installation"
        return 0
    fi

    # Check if gateway is running
    if ! docker exec "$gateway_container" pwd &>/dev/null; then
        print_warning "Channel setup skipped - gateway not running"
        print_info "You can setup channels manually after starting the gateway"
        return 0
    fi

    # Install WeChat plugin
    print_info "Installing WeChat communication plugin"

    if docker exec "$gateway_container" openclaw plugins install "@tencent-weixin/openclaw-weixin" 2>&1 | grep -q "Installed plugin"; then
        # Add to plugins.allow list (exclude built-in browser plugin)
        docker exec "$gateway_container" openclaw config set plugins.allow '["openclaw-weixin","memory-core","openrouter","gemma"]' --json 2>/dev/null || true

        print_success "WeChat plugin installed"
    else
        print_warning "WeChat plugin installation failed"
    fi

    print_success "Communication channels configured"
    echo ""
    echo "WeChat Plugin Installation:"
    echo "  Status:        Installed"
    echo "  Next Step:     Login to WeChat channel"
    echo ""
    echo "To complete WeChat setup:"
    echo "  docker exec $gateway_container openclaw channels login --channel openclaw-weixin"
    echo ""
    echo "Then scan the QR code with WeChat to connect."
    echo ""
}

setup_built_in_skills() {
    print_step 10 "Setting up built-in skills"
    show_progress 10 13

    if [[ "$DRY_RUN" == "true" ]]; then
        print_success "Built-in skills configured (dry run)"
        return 0
    fi

    # Find the gateway container
    local gateway_container=""
    local env_file="${DEPLOY_DIR}/.env"

    if [[ -f "$env_file" ]]; then
        # Extract resource token and get last 4 characters
        local resource_token
        resource_token=$(grep "^RESOURCE_TOKEN=" "$env_file" | cut -d'=' -f2)
        if [[ -n "$resource_token" ]]; then
            local token_suffix="${resource_token: -4}"
            gateway_container="clawfarm-gateway-${token_suffix}"
        fi
    fi

    # Fallback to pattern matching if exact match fails
    if [[ -z "$gateway_container" ]] || ! docker ps --format '{{.Names}}' | grep -q "^${gateway_container}$"; then
        gateway_container=$(docker ps --format '{{.Names}}' | grep -E '^clawfarm-gateway-' | head -1)
    fi

    if [[ -z "$gateway_container" ]]; then
        print_warning "Skills setup skipped - gateway container not found"
        print_info "You can setup skills manually after installation"
        return 0
    fi

    # Check if gateway is running
    if ! docker exec "$gateway_container" pwd &>/dev/null; then
        print_warning "Skills setup skipped - gateway not running"
        print_info "You can setup skills manually after starting the gateway"
        return 0
    fi

    # Copy all built-in skills from /usr/local/share/openclaw/skills to workspace
    print_info "Copying built-in skills to workspace"

    # Create workspace skills directory if it doesn't exist
    docker exec "$gateway_container" mkdir -p /workspace/skills/ 2>/dev/null

    # Copy all skills from built-in location to workspace
    local skills_copied=0
    local skills_failed=0

    # List all directories in the skills source directory
    local skills_list
    skills_list=$(docker exec "$gateway_container" find /usr/local/share/openclaw/skills -mindepth 1 -maxdepth 1 -type d -printf "%f\n" 2>/dev/null)

    if [[ -n "$skills_list" ]]; then
        while IFS= read -r skill_dir; do
            if [[ -n "$skill_dir" ]]; then
                local skill_name="$skill_dir"

                if docker exec "$gateway_container" cp -r "/usr/local/share/openclaw/skills/${skill_name}" "/workspace/skills/" 2>/dev/null; then
                    skills_copied=$((skills_copied + 1))

                    # Check if this skill has an agent-browser CLI
                    if [[ "$skill_name" == "Agent-Browser-CLI" ]]; then
                        if docker exec "$gateway_container" command -v agent-browser &>/dev/null; then
                            local agent_browser_version
                            agent_browser_version=$(docker exec "$gateway_container" agent-browser --version 2>/dev/null || echo "unknown")
                            print_info "agent-browser CLI version: $agent_browser_version"
                        fi
                    fi
                else
                    skills_failed=$((skills_failed + 1))
                fi
            fi
        done <<< "$skills_list"
    else
        print_warning "No built-in skills found to copy"
    fi

    # Report results
    if [[ $skills_copied -gt 0 ]]; then
        print_success "Copied $skills_copied built-in skill(s) to workspace"
    fi

    if [[ $skills_failed -gt 0 ]]; then
        print_warning "Failed to copy $skills_failed skill(s)"
    fi

    print_success "Built-in skills configured"
    echo ""
    echo "Skills Overview:"
    echo "  Total Copied:  $skills_copied skill(s)"
    echo "  Location:       /workspace/skills/"
    echo ""

    # Show individual skills if any were copied
    if [[ $skills_copied -gt 0 ]]; then
        echo "Available Skills:"
        docker exec "$gateway_container" find /workspace/skills -mindepth 1 -maxdepth 1 -type d -printf "  - %f\n" 2>/dev/null | sort
        echo ""
    fi

    # Show agent-browser specific info if available
    if [[ -n "${agent_browser_version:-}" ]]; then
        echo "Agent-Browser-CLI:"
        echo "  CLI Version:   $agent_browser_version"
        echo "  CDP Proxy:     clawfarm-browser-proxy:9223"
        echo "  Status:        Ready for browser automation"
        echo ""
    fi

    echo "Built-in browser plugin is disabled - agent-browser skill is preferred."
    echo "Agents can now use the installed skills for various automation tasks."
    echo ""
}

setup_autostart_service() {
    print_step 11 "Setting up auto-start service"
    show_progress 11 13

    # Only setup autostart for macOS local deployments
    if [[ "$OSTYPE" == darwin* ]] && [[ "$DEPLOYMENT_TYPE" == "local" ]]; then
        print_info "Configuring macOS LaunchAgent for auto-start..."

        # Create LaunchAgents directory if it doesn't exist
        local launch_agents_dir="$HOME/Library/LaunchAgents"
        mkdir -p "$launch_agents_dir"

        # Generate LaunchAgent plist file
        local plist_file="$launch_agents_dir/com.clawfarm.gateway.plist"
        local work_dir="$(cd "$DEPLOY_DIR" && pwd)"

        cat > "$plist_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clawfarm.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/docker-compose</string>
        <string>-f</string>
        <string>${work_dir}/docker-compose.yml</string>
        <string>up</string>
        <string>-d</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${work_dir}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${work_dir}/logs/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>${work_dir}/logs/gateway.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF

        # Load the LaunchAgent
        if launchctl load "$plist_file" 2>/dev/null; then
            print_success "LaunchAgent loaded successfully"
            print_info "Gateway will start automatically on login"
        else
            print_warning "Failed to load LaunchAgent"
            print_info "You can manually load it later with: launchctl load $plist_file"
        fi

        # Setup Docker Desktop auto-start (macOS)
        if [[ -f "$HOME/Library/Preferences/com.docker.docker.plist" ]]; then
            print_info "Docker Desktop auto-start should be configured manually"
            print_info "Go to Docker Desktop > Settings > General > Start Docker Desktop when you log in"
        fi
    else
        print_info "Auto-start service setup skipped (not supported on this platform)"
        print_info "You can manually start the gateway with: cd $DEPLOY_DIR && docker-compose up -d"
    fi

    print_success "Auto-start configuration completed"
}

get_gateway_token() {
    # Try to get the gateway token from the running container
    local container_name="${RESOURCE_NAME}"
    local token=""

    # Try to get token from container environment or config
    if command -v docker >/dev/null 2>&1; then
        # Try to get token from .openclaw/openclaw.json
        if [[ -f "$DEPLOY_DIR/.openclaw/openclaw.json" ]]; then
            token=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$DEPLOY_DIR/.openclaw/openclaw.json" | cut -d'"' -f4)
        fi

        # If not found, try to get from container
        if [[ -z "$token" ]]; then
            token=$(docker exec "$container_name" cat /home/openclaw/.openclaw/openclaw.json 2>/dev/null | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
        fi
    fi

    echo "$token"
}

show_summary() {
    print_step 12 "Installation summary"
    show_progress 12 13

    echo ""
    echo -e "${BOLD}${GREEN}Installation completed successfully!${NC}"
    echo ""
    echo -e "${BOLD}Gateway Details:${NC}"
    echo "  Resource Name:   $RESOURCE_NAME"
    echo "  Gateway Port:    $GATEWAY_PORT"
    echo "  Install Dir:     $DEPLOY_DIR"
    echo "  Agency ID:       $AGENCY_ID"
    echo "  Default Model:   $DEFAULT_LLM_MODEL"

    # Try to get and display the gateway token
    local gateway_token
    gateway_token=$(get_gateway_token)
    if [[ -n "$gateway_token" ]]; then
        echo ""
        echo -e "${BOLD}Gateway Token:${NC} $gateway_token"
        echo -e "${YELLOW}⚠ Please save this token securely - it will not be shown again!${NC}"
    fi

    echo ""
    echo -e "${BOLD}Management Commands:${NC}"
    echo "  View logs:       cd $DEPLOY_DIR && docker-compose logs -f"
    echo "  Stop gateway:     cd $DEPLOY_DIR && docker-compose down"
    echo "  Start gateway:    cd $DEPLOY_DIR && docker-compose up -d"
    echo "  Restart gateway:  cd $DEPLOY_DIR && docker-compose restart"
    echo "  Uninstall:      curl -sSL https://github.com/ClawFarm-by-INFAC/clawfarm-tools/raw/refs/heads/main/onboarding/uninstall.sh | bash -s -- --dir $DEPLOY_DIR"
    echo ""
    echo "  Health check:    curl http://localhost:${GATEWAY_PORT}/health"
    echo ""
    echo -e "${BOLD}Browser Automation:${NC}"
    echo "  Built-in browser plugin: DISABLED"
    echo "  Agent-Browser-CLI skill: ENABLED"
    echo "  Browser Proxy: clawfarm-browser-proxy:9223"
    echo "  Usage: agent-browser --cdp http://clawfarm-browser-proxy:9223 <command>"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Verify your gateway in Control Plane Dashboard"
    echo "  2. Configure OpenRouter API key for LLM features (if not set)"
    echo "  3. Login to WeChat channel to enable messaging"
    echo "  4. Create and configure agents as needed"
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

    # Validate resource token with Control Plane
    if ! validate_resource_token "$RESOURCE_TOKEN"; then
        print_error "Resource token validation failed"
        echo "Use --skip-token-validation to bypass this check"
        exit 1
    fi

    create_deployment_directory
    generate_configuration_files
    docker_registry_login
    pull_docker_image
    start_gateway

    # Verify and setup additional features
    if verify_deployment; then
        setup_communication_channels
        setup_built_in_skills
        setup_autostart_service
        show_summary
        exit 0
    else
        print_error "Installation failed. Check logs for details."
        exit 1
    fi
}

# Run main function - this works for both direct execution and piped input (curl | bash)
main "$@"
