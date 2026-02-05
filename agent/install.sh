#!/usr/bin/env sh

set -eu

# =============================================================================
# NetConfig Agent Installer
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly TRAEFIK_VERSION="v3.6.1"
readonly AGENT_DIR="/opt/netconfig-agent"
readonly TRAEFIK_DIR="${AGENT_DIR}/traefik"
readonly DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
readonly MAX_WAIT=300
readonly WAIT_INTERVAL=5

# =============================================================================
# Global State Variables (intentionally global)
# =============================================================================

UNATTENDED=false
DOMAIN=""
ACME_EMAIL=""
TRAEFIK_ENABLE_TLS=false
USE_ACME=false
COMPOSE_MODE=""

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

# =============================================================================
# Utility Functions
# =============================================================================

# Exit with error message and optional exit code
die() {
    log_error "$1"
    exit "${2:-1}"
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This installer must run as root (tip: use sudo)."
    fi
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate domain name format
validate_domain() {
    local domain="$1"

    if [ -z "$domain" ]; then
        return 0
    fi

    if ! printf '%s' "$domain" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
        log_warn "'$domain' does not appear to be a valid domain name."
        return 1
    fi

    return 0
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --unattended|--no-prompt|--no-ask|-y)
                UNATTENDED=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
Usage: install.sh [OPTIONS]

Options:
  --unattended, --no-prompt, --no-ask, -y
                    Run installation without interactive prompts
  --help, -h        Show this help message

Environment variables:
  DOMAIN            Domain name for Let's Encrypt (optional)
  ACME_EMAIL        Email for Let's Encrypt notifications (optional)
  DISABLE_TLS       Set to 'true' to disable HTTPS (optional)
EOF
}

# =============================================================================
# Dependency Installation
# =============================================================================

install_dependencies() {
    log_info "Updating system packages..."
    apt-get update -y && apt-get upgrade -y

    install_package "curl"
    install_package "openssl"
    install_docker
}

install_package() {
    local package="$1"

    if ! command_exists "$package"; then
        log_info "$package not found. Installing..."
        apt-get install -y "$package"
    fi
}

install_docker() {
    if command_exists docker; then
        log_info "Docker already installed."
        return 0
    fi

    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh

    local target_user="${SUDO_USER:-$USER}"
    if [ -n "$target_user" ] && id "$target_user" >/dev/null 2>&1; then
        usermod -aG docker "$target_user"
    fi

    systemctl restart docker
}

# =============================================================================
# Docker Configuration
# =============================================================================

configure_docker_ipv6() {
    if [ -f "$DOCKER_CONFIG_FILE" ]; then
        configure_existing_docker_ipv6
    else
        create_docker_ipv6_config
    fi
}

configure_existing_docker_ipv6() {
    if grep -q '"ipv6"[[:space:]]*:[[:space:]]*true' "$DOCKER_CONFIG_FILE" 2>/dev/null; then
        log_info "Docker IPv6 support already enabled."
        return 0
    fi

    log_info "Enabling IPv6 support (backing up existing config)..."

    if command_exists jq; then
        enable_ipv6_with_jq
    else
        enable_ipv6_without_jq
    fi

    systemctl restart docker
    log_info "IPv6 support enabled and Docker restarted."
}

enable_ipv6_with_jq() {
    local temp_config
    temp_config=$(mktemp)
    jq '. + {"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64"}' "$DOCKER_CONFIG_FILE" > "$temp_config"
    mv "$temp_config" "$DOCKER_CONFIG_FILE"
}

enable_ipv6_without_jq() {
    local backup_file="${DOCKER_CONFIG_FILE}.backup.$(date +%s)"
    cp "$DOCKER_CONFIG_FILE" "$backup_file"
    log_info "Original config backed up to: $backup_file"

    cat > "$DOCKER_CONFIG_FILE" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64"
}
EOF
}

create_docker_ipv6_config() {
    log_info "Enabling IPv6 support for Docker..."

    cat > "$DOCKER_CONFIG_FILE" <<'EOF'
{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64"
}
EOF

    systemctl restart docker
}

# =============================================================================
# TLS Configuration
# =============================================================================

configure_tls() {
    # Load from environment variables
    DOMAIN="${DOMAIN:-}"
    ACME_EMAIL="${ACME_EMAIL:-}"

    if [ "${DISABLE_TLS:-}" = "true" ]; then
        log_info "HTTPS disabled via DISABLE_TLS environment variable."
        TRAEFIK_ENABLE_TLS=false
        USE_ACME=false
        return 0
    fi

    if [ -n "$DOMAIN" ] && [ -n "$ACME_EMAIL" ]; then
        configure_tls_from_env
    elif [ "$UNATTENDED" = "true" ]; then
        configure_tls_unattended
    elif [ -t 0 ]; then
        configure_tls_interactive
    else
        configure_tls_default
    fi
}

configure_tls_from_env() {
    if validate_domain "$DOMAIN"; then
        TRAEFIK_ENABLE_TLS=true
        USE_ACME=true
        log_info "Using Let's Encrypt with domain: $DOMAIN"
    else
        die "Invalid domain provided. Please provide a valid domain or leave it empty for self-signed certificate."
    fi
}

configure_tls_unattended() {
    TRAEFIK_ENABLE_TLS=true
    USE_ACME=false
    log_info "Running in unattended mode. HTTPS will use a self-signed certificate."
    log_info "To use Let's Encrypt, set DOMAIN and ACME_EMAIL environment variables."
}

configure_tls_interactive() {
    printf "Enable HTTPS via Traefik? [Y/n] "
    read -r answer || true

    if printf '%s' "${answer:-}" | grep -iq '^n'; then
        log_info "Skipping HTTPS configuration."
        TRAEFIK_ENABLE_TLS=false
        USE_ACME=false
        return 0
    fi

    TRAEFIK_ENABLE_TLS=true
    printf "\nTo use Let's Encrypt, provide DOMAIN and ACME_EMAIL.\n"
    printf "Leave both blank to use a self-signed certificate.\n\n"

    read_domain_and_email
    determine_acme_usage
}

read_domain_and_email() {
    printf "Domain that points to this agent (optional): "
    read -r DOMAIN || true

    printf "Email for Let's Encrypt notifications (optional): "
    read -r ACME_EMAIL || true
}

determine_acme_usage() {
    if [ -n "$DOMAIN" ] && [ -n "$ACME_EMAIL" ]; then
        if validate_domain "$DOMAIN"; then
            USE_ACME=true
            log_info "Using Let's Encrypt for SSL certificates."
        else
            log_warn "Invalid domain format. Using self-signed certificate instead."
            DOMAIN=""
            USE_ACME=false
        fi
    else
        USE_ACME=false
        log_info "Using a self-signed certificate because DOMAIN or ACME_EMAIL is missing."
    fi
}

configure_tls_default() {
    TRAEFIK_ENABLE_TLS=true
    USE_ACME=false
    log_info "No domain/email provided. HTTPS will use a self-signed certificate. Set DISABLE_TLS=true to skip."
}

# =============================================================================
# Directory Setup
# =============================================================================

setup_directories() {
    if [ ! -d "$AGENT_DIR" ]; then
        log_info "Creating directory $AGENT_DIR..."
        mkdir -p "$AGENT_DIR"
    fi

    mkdir -p "$TRAEFIK_DIR/dynamic"
}

# =============================================================================
# Certificate Generation
# =============================================================================

setup_certificates() {
    if [ "$TRAEFIK_ENABLE_TLS" != "true" ]; then
        cleanup_cert_directories
        return 0
    fi

    if [ "$USE_ACME" = "true" ]; then
        setup_acme_certificates
    else
        setup_self_signed_certificates
    fi
}

cleanup_cert_directories() {
    rm -f "$TRAEFIK_DIR/dynamic/selfsigned.yml"
    rm -rf "$TRAEFIK_DIR/certs"
    rm -rf "$TRAEFIK_DIR/acme"
}

setup_acme_certificates() {
    mkdir -p "$TRAEFIK_DIR/acme"
    touch "$TRAEFIK_DIR/acme/acme.json"
    chmod 600 "$TRAEFIK_DIR/acme/acme.json"

    rm -f "$TRAEFIK_DIR/dynamic/selfsigned.yml"
    rm -rf "$TRAEFIK_DIR/certs"
}

setup_self_signed_certificates() {
    local cert_dir="$TRAEFIK_DIR/certs"
    local self_signed_crt="$cert_dir/selfsigned.crt"
    local self_signed_key="$cert_dir/selfsigned.key"

    mkdir -p "$cert_dir"
    rm -rf "$TRAEFIK_DIR/acme"

    if [ -f "$self_signed_crt" ] && [ -f "$self_signed_key" ]; then
        log_info "Self-signed certificate already exists."
    else
        generate_self_signed_cert "$cert_dir" "$self_signed_crt" "$self_signed_key"
    fi

    create_self_signed_config
}

generate_self_signed_cert() {
    local cert_dir="$1"
    local crt_file="$2"
    local key_file="$3"
    local openssl_cfg="$cert_dir/openssl.cnf"

    log_info "Generating self-signed certificate for Traefik..."

    create_openssl_config "$openssl_cfg"

    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$key_file.tmp" \
        -out "$crt_file.tmp" \
        -days 1095 \
        -config "$openssl_cfg" >/dev/null 2>&1

    mv "$key_file.tmp" "$key_file"
    mv "$crt_file.tmp" "$crt_file"
    rm -f "$openssl_cfg"

    chmod 600 "$key_file"
    log_info "Self-signed certificate ready at $crt_file"
}

create_openssl_config() {
    local config_file="$1"
    local host_ip

    cat > "$config_file" <<'EOF'
[req]
distinguished_name=req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = netconfig-agent

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

    host_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}') || host_ip=""
    if [ -n "$host_ip" ]; then
        printf 'IP.2 = %s\n' "$host_ip" >> "$config_file"
    fi
}

create_self_signed_config() {
    cat > "$TRAEFIK_DIR/dynamic/selfsigned.yml" <<'EOF'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/selfsigned.crt
        keyFile: /etc/traefik/certs/selfsigned.key
EOF
}

# =============================================================================
# Docker Compose Detection
# =============================================================================

detect_compose_mode() {
    if command_exists docker-compose; then
        COMPOSE_MODE="docker-compose"
        log_info "Detected docker-compose..."
    elif docker compose version >/dev/null 2>&1; then
        COMPOSE_MODE="docker compose"
        log_info "Detected docker compose plugin..."
    else
        die "Error: docker-compose or docker compose not found."
    fi
}

# =============================================================================
# Docker Compose Generation
# =============================================================================

generate_docker_compose() {
    stop_existing_containers

    log_info "Writing docker-compose.yml to $AGENT_DIR..."

    if [ "$TRAEFIK_ENABLE_TLS" != "true" ]; then
        generate_compose_no_tls
    elif [ "$USE_ACME" = "true" ]; then
        generate_compose_acme
    else
        generate_compose_self_signed
    fi
}

stop_existing_containers() {
    if [ ! -f "$AGENT_DIR/docker-compose.yml" ]; then
        return 0
    fi

    log_info "Existing docker-compose.yml found. Stopping containers..."
    (
        cd "$AGENT_DIR" || die "Failed to change to $AGENT_DIR"
        $COMPOSE_MODE down || true
    )
}

generate_compose_no_tls() {
    cat > "$AGENT_DIR/docker-compose.yml" <<EOF
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=netconfig"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.web.address=:8080"
    ports:
      - "8080:8080"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/dynamic:/etc/traefik/dynamic:ro"
    networks:
      - local

  agent:
    image: netconfigsup/agent:latest
    container_name: netconfig_agent
    ports:
      - "2222:2222"
    volumes:
      - agent_data:/data
    networks:
      - local
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.netconfig.loadbalancer.server.port=8000"
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF
}

generate_compose_self_signed() {
    cat > "$AGENT_DIR/docker-compose.yml" <<EOF
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=netconfig"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.web.address=:8080"
      - "--entryPoints.websecure.address=:8443"
    ports:
      - "8080:8080"
      - "8443:8443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/dynamic:/etc/traefik/dynamic:ro"
      - "./traefik/certs:/etc/traefik/certs:ro"
    networks:
      - local

  agent:
    image: netconfigsup/agent:latest
    container_name: netconfig_agent
    ports:
      - "2222:2222"
    volumes:
      - agent_data:/data
    networks:
      - local
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.netconfig.loadbalancer.server.port=8000"
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
      - "traefik.http.routers.netconfig-https.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.netconfig-https.entrypoints=websecure"
      - "traefik.http.routers.netconfig-https.tls=true"
      - "traefik.http.routers.netconfig-https.service=netconfig"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF
}

generate_compose_acme() {
    local email_escaped
    local domain_escaped

    cat > "$AGENT_DIR/docker-compose.yml" <<EOF
services:
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=netconfig"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.web.address=:8080"
      - "--entryPoints.websecure.address=:8443"
      - "--entryPoints.acme.address=:80"
      - "--certificatesresolvers.le.acme.email=__ACME_EMAIL__"
      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=acme"
    ports:
      - "80:80"
      - "8080:8080"
      - "8443:8443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/dynamic:/etc/traefik/dynamic:ro"
      - "./traefik/acme:/letsencrypt"
    networks:
      - local

  agent:
    image: netconfigsup/agent:latest
    container_name: netconfig_agent
    ports:
      - "2222:2222"
    volumes:
      - agent_data:/data
    networks:
      - local
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.netconfig.loadbalancer.server.port=8000"
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
      - "traefik.http.routers.netconfig-https.rule=Host(\`__DOMAIN__\`)"
      - "traefik.http.routers.netconfig-https.entrypoints=websecure"
      - "traefik.http.routers.netconfig-https.tls.certresolver=le"
      - "traefik.http.routers.netconfig-https.service=netconfig"
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF

    # Escape special characters for sed
    email_escaped=$(printf '%s' "$ACME_EMAIL" | sed 's/[\\/&]/\\&/g')
    domain_escaped=$(printf '%s' "$DOMAIN" | sed 's/[\\/&]/\\&/g')

    sed -i "s/__ACME_EMAIL__/$email_escaped/g" "$AGENT_DIR/docker-compose.yml"
    sed -i "s/__DOMAIN__/$domain_escaped/g" "$AGENT_DIR/docker-compose.yml"
}

# =============================================================================
# Deployment
# =============================================================================

deploy_containers() {
    log_info "Starting the NetConfig Agent containers..."

    (
        cd "$AGENT_DIR" || die "Failed to change to $AGENT_DIR"
        if ! $COMPOSE_MODE up -d --pull always; then
            die "Failed to start containers with docker compose."
        fi
    )
}

wait_for_health() {
    local wait_time=0

    log_info "Waiting for the container to report as healthy..."

    while ! docker inspect --format '{{.State.Health.Status}}' netconfig_agent 2>/dev/null | grep -q "healthy"; do
        if [ $wait_time -ge $MAX_WAIT ]; then
            die "Container did not become healthy within ${MAX_WAIT} seconds. Check logs with: docker logs netconfig_agent"
        fi

        log_info "Container not healthy yet. Retrying in ${WAIT_INTERVAL} seconds... ($wait_time/${MAX_WAIT}s)"
        sleep $WAIT_INTERVAL
        wait_time=$((wait_time + WAIT_INTERVAL))
    done

    log_info "Container is healthy."
}

# =============================================================================
# Key Retrieval
# =============================================================================

retrieve_keys() {
    local api_key
    local ssh_key

    log_info "Fetching authentication keys..."

    api_key=$(docker exec netconfig_agent cat /data/api_key 2>/dev/null) || die "Failed to retrieve API key from container."
    ssh_key=$(docker exec netconfig_agent cat /data/tunnel_ssh_key 2>/dev/null) || die "Failed to retrieve SSH key from container."

    display_keys "$api_key" "$ssh_key"
}

display_keys() {
    local api_key="$1"
    local ssh_key="$2"

    printf '\n'
    printf 'API Key:\n'
    printf '%s\n' "$api_key"
    printf '\n'
    printf 'SSH Key:\n'
    printf '%s\n' "$ssh_key"
    printf '\n'

    printf 'Register this Agent at https://app.netconfig.com.br/agents using the keys above.\n'
    printf 'After registration, visit https://app.netconfig.com.br/enterprise/settings and select the newly created Agent.\n'
}

# =============================================================================
# Main Function
# =============================================================================

main() {
    log_info "Starting NetConfig Agent installation..."

    parse_arguments "$@"
    check_root
    install_dependencies
    configure_docker_ipv6
    configure_tls
    setup_directories
    setup_certificates
    detect_compose_mode
    generate_docker_compose
    deploy_containers
    wait_for_health
    retrieve_keys

    log_info "Installation and configuration completed successfully."
}

# =============================================================================
# Script Entry Point
# =============================================================================

main "$@"
