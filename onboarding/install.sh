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

    # Create necessary directories
    mkdir -p "$DEPLOY_DIR/workspace"
    mkdir -p "$DEPLOY_DIR/logs"

    # Generate nginx.conf for browser proxy
    print_info "Generating nginx.conf for browser proxy..."
    cat > "$DEPLOY_DIR/nginx.conf" <<'NGINX_EOF'
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
NGINX_EOF

    print_success "nginx.conf generated"

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

setup_autostart_service() {
    print_step 8 "Setting up auto-start service"
    show_progress 8 10

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
    print_step 9 "Installation summary"
    show_progress 9 10

    echo ""
    echo -e "${BOLD}${GREEN}Installation completed successfully!${NC}"
    echo ""
    echo -e "${BOLD}Gateway Details:${NC}"
    echo "  Resource Name:   $RESOURCE_NAME"
    echo "  Gateway Port:    $GATEWAY_PORT"
    echo "  Install Dir:     $DEPLOY_DIR"
    echo "  Agency ID:       $AGENCY_ID"

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

    # Verify and setup autostart
    if verify_deployment; then
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
