#!/usr/bin/env sh

set -eu

# =============================================================================
# NetConfig Radius Installer
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly TRAEFIK_VERSION="v3.6.1"
readonly RADIUS_DIR="/opt/netconfig-radius"
readonly TRAEFIK_DIR="${RADIUS_DIR}/traefik"
readonly DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
readonly MAX_WAIT=300
readonly WAIT_INTERVAL=5

# =============================================================================
# Global State Variables (intentionally global)
# =============================================================================

UNATTENDED=false
NO_INSTALL_VM_DOCKER=false
NO_UPDATE_VM=false
REINSTALL=false
DOMAIN=""
ACME_EMAIL=""
TRAEFIK_ENABLE_TLS=false
USE_ACME=false
COMPOSE_MODE=""
RADIUS_API_TAG="latest"
RADIUS_SERVER_TAG="latest"

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

die() {
    log_error "$1"
    exit "${2:-1}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This installer must run as root (tip: use sudo)."
    fi
}

generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

# =============================================================================
# Validation Functions
# =============================================================================

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
            --reinstall)
                REINSTALL=true
                shift
                ;;
            --no-install-vm-docker)
                NO_INSTALL_VM_DOCKER=true
                shift
                ;;
            --no-update-vm)
                NO_UPDATE_VM=true
                shift
                ;;
            --api-tag)
                if [ -z "${2:-}" ]; then
                    die "Option --api-tag requires a value (e.g., --api-tag v1.0.0)"
                fi
                RADIUS_API_TAG="$2"
                shift 2
                ;;
            --server-tag)
                if [ -z "${2:-}" ]; then
                    die "Option --server-tag requires a value (e.g., --server-tag v1.0.0)"
                fi
                RADIUS_SERVER_TAG="$2"
                shift 2
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
  --reinstall        Wipe existing NetConfig Radius installation (containers,
                    volume data, and files under /opt/netconfig-radius) and
                    run the installation again (DESTRUCTIVE)
  --no-install-vm-docker
                    Do not install Docker or dependencies (curl, openssl).
                    Check if they are installed, fail if not.
  --no-update-vm    Skip system package update (apt-get update/upgrade)
  --api-tag VERSION Specify radius-api image tag (default: latest)
  --server-tag VERSION
                    Specify radius-server image tag (default: latest)
  --help, -h        Show this help message

Environment variables:
  DOMAIN            Domain name for Let's Encrypt (optional)
  ACME_EMAIL        Email for Let's Encrypt notifications (optional)
  DISABLE_TLS       Set to 'true' to disable HTTPS (optional)
  RADIUS_API_KEY    Pre-defined API key (optional, auto-generated if empty)
EOF
}

# =============================================================================
# Dependency Installation
# =============================================================================

install_dependencies() {
     if [ "$NO_UPDATE_VM" = "true" ]; then
         log_info "Skipping system update (NO_UPDATE_VM=true)."
     else
     log_info "Updating system packages..."
     apt-get update -y && apt-get upgrade -y
     fi

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
# TLS Configuration
# =============================================================================

configure_tls() {
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
    printf "Domain that points to this radius server (optional): "
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
    if [ ! -d "$RADIUS_DIR" ]; then
        log_info "Creating directory $RADIUS_DIR..."
        mkdir -p "$RADIUS_DIR"
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
CN = netconfig-radius

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

detect_compose_mode_optional() {
    COMPOSE_MODE=""

    if command_exists docker-compose; then
        COMPOSE_MODE="docker-compose"
        return 0
    fi

    if command_exists docker && docker compose version >/dev/null 2>&1; then
        COMPOSE_MODE="docker compose"
        return 0
    fi

    return 1
}

# =============================================================================
# Credentials Generation
# =============================================================================

setup_credentials() {
    RADIUS_API_KEY="${RADIUS_API_KEY:-}"
    if [ -z "$RADIUS_API_KEY" ]; then
        RADIUS_API_KEY=$(generate_password)
        log_info "Generated RADIUS API key."
    else
        log_info "Using provided RADIUS_API_KEY."
    fi

    MYSQL_ROOT_PASSWORD=$(generate_password)
    log_info "Generated MySQL root password."
}

# =============================================================================
# Reinstall / Wipe
# =============================================================================

confirm_reinstall() {
    if [ "$UNATTENDED" = "true" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        die "--reinstall needs a TTY for confirmation. Use --unattended to skip prompts."
    fi

    log_warn "--reinstall will REMOVE the existing NetConfig Radius installation."
    log_warn "This includes Docker containers, database volumes, and files in: $RADIUS_DIR"
    printf "Continue with wipe + reinstall? [y/N] "
    read -r answer || true

    if ! printf '%s' "${answer:-}" | grep -iq '^y'; then
        die "Aborted by user."
    fi
}

wipe_previous_installation() {
    confirm_reinstall

    if command_exists docker; then
        log_info "Removing existing NetConfig Radius containers/volumes (if any)..."

        local project
        project="$(basename "$RADIUS_DIR" 2>/dev/null || true)"

        if [ -f "$RADIUS_DIR/docker-compose.yml" ]; then
            if detect_compose_mode_optional; then
                (
                    cd "$RADIUS_DIR" || exit 0
                    $COMPOSE_MODE down -v --remove-orphans || true
                )
            fi
        fi

        docker rm -f netconfig_radius_api netconfig_radius_server netconfig_radius_db netconfig_radius_traefik >/dev/null 2>&1 || true

        if [ -n "${project:-}" ]; then
            for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null || true); do
                docker volume rm "$v" >/dev/null 2>&1 || true
            done
        fi

        log_info "Removing related Docker images (best-effort)..."
        docker image rm -f "netconfigsup/radius-api:${RADIUS_API_TAG}" >/dev/null 2>&1 || true
        docker image rm -f "netconfigsup/radius-server:${RADIUS_SERVER_TAG}" >/dev/null 2>&1 || true
        docker image rm -f "traefik:${TRAEFIK_VERSION}" >/dev/null 2>&1 || true

        for img in $(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^netconfigsup/radius-(api|server):' || true); do
            docker image rm -f "$img" >/dev/null 2>&1 || true
        done
    fi

    if [ -d "$RADIUS_DIR" ]; then
        log_info "Removing files under $RADIUS_DIR..."
        rm -rf "$RADIUS_DIR"
    fi
}

# =============================================================================
# Docker Compose Generation
# =============================================================================

generate_docker_compose() {
    stop_existing_containers

    log_info "Writing docker-compose.yml to $RADIUS_DIR..."

    if [ "$TRAEFIK_ENABLE_TLS" != "true" ]; then
        generate_compose_no_tls
    elif [ "$USE_ACME" = "true" ]; then
        generate_compose_acme
    else
        generate_compose_self_signed
    fi
}

stop_existing_containers() {
    if [ ! -f "$RADIUS_DIR/docker-compose.yml" ]; then
        return 0
    fi

    log_info "Existing docker-compose.yml found. Stopping containers..."
    (
        cd "$RADIUS_DIR" || die "Failed to change to $RADIUS_DIR"
        $COMPOSE_MODE down || true
    )
}

# --- Shared compose fragments ---

compose_header() {
    cat <<'EOF'
services:
EOF
}

compose_db_service() {
    cat <<EOF
  radius-db:
    image: mysql:8.4
    container_name: netconfig_radius_db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    volumes:
      - radius-db-data:/var/lib/mysql
    healthcheck:
      test: mysqladmin ping -h localhost -p${MYSQL_ROOT_PASSWORD}
      interval: 20s
      timeout: 5s
      retries: 3
    networks:
      - radius-internal
EOF
}

compose_api_service() {
    cat <<EOF
  radius-api:
    image: netconfigsup/radius-api:${RADIUS_API_TAG}
    container_name: netconfig_radius_api
    restart: unless-stopped
    depends_on:
      radius-db:
        condition: service_healthy
    environment:
      RADIUS_API_KEY: ${RADIUS_API_KEY}
      RADIUS_DB_DSN: raduser:radpass@tcp(radius-db:3306)/raddb?parseTime=true
      RADIUS_ITEMS_PER_PAGE: 100
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    networks:
      - radius-internal
EOF
}

compose_server_service() {
    cat <<EOF
  radius-server:
    image: netconfigsup/radius-server:${RADIUS_SERVER_TAG}
    container_name: netconfig_radius_server
    restart: unless-stopped
    depends_on:
      radius-db:
        condition: service_healthy
    ports:
      - "1812:1812/udp"
      - "1813:1813/udp"
    networks:
      - radius-internal
EOF
}

compose_volumes_and_networks() {
    cat <<'EOF'
volumes:
  radius-db-data:

networks:
  radius-internal:
EOF
}

# --- No TLS ---

generate_compose_no_tls() {
    {
        compose_header

        cat <<EOF
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_radius_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=radius-internal"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.web.address=:8080"
    ports:
      - "8080:8080"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./traefik/dynamic:/etc/traefik/dynamic:ro"
    networks:
      - radius-internal

EOF
        compose_db_service
        printf '\n'

        compose_api_service
        cat <<'EOF'
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.radius-api.loadbalancer.server.port=8000"
      - "traefik.http.routers.radius-http.rule=PathPrefix(`/`)"
      - "traefik.http.routers.radius-http.entrypoints=web"
      - "traefik.http.routers.radius-http.service=radius-api"

EOF
        compose_server_service
        printf '\n'
        compose_volumes_and_networks
    } > "$RADIUS_DIR/docker-compose.yml"
}

# --- Self-signed TLS ---

generate_compose_self_signed() {
    {
        compose_header

        cat <<EOF
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_radius_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=radius-internal"
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
      - radius-internal

EOF
        compose_db_service
        printf '\n'

        compose_api_service
        cat <<'EOF'
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.radius-api.loadbalancer.server.port=8000"
      - "traefik.http.routers.radius-http.rule=PathPrefix(`/`)"
      - "traefik.http.routers.radius-http.entrypoints=web"
      - "traefik.http.routers.radius-http.service=radius-api"
      - "traefik.http.routers.radius-https.rule=PathPrefix(`/`)"
      - "traefik.http.routers.radius-https.entrypoints=websecure"
      - "traefik.http.routers.radius-https.tls=true"
      - "traefik.http.routers.radius-https.service=radius-api"

EOF
        compose_server_service
        printf '\n'
        compose_volumes_and_networks
    } > "$RADIUS_DIR/docker-compose.yml"
}

# --- ACME (Let's Encrypt) ---

generate_compose_acme() {
    local email_escaped
    local domain_escaped

    {
        compose_header

        cat <<EOF
  traefik:
    image: traefik:${TRAEFIK_VERSION}
    container_name: netconfig_radius_traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=radius-internal"
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
      - radius-internal

EOF
        compose_db_service
        printf '\n'

        compose_api_service
        cat <<EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.radius-api.loadbalancer.server.port=8000"
      - "traefik.http.routers.radius-http.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.radius-http.entrypoints=web"
      - "traefik.http.routers.radius-http.service=radius-api"
      - "traefik.http.routers.radius-https.rule=Host(\`__DOMAIN__\`)"
      - "traefik.http.routers.radius-https.entrypoints=websecure"
      - "traefik.http.routers.radius-https.tls.certresolver=le"
      - "traefik.http.routers.radius-https.service=radius-api"

EOF
        compose_server_service
        printf '\n'
        compose_volumes_and_networks
    } > "$RADIUS_DIR/docker-compose.yml"

    email_escaped=$(printf '%s' "$ACME_EMAIL" | sed 's/[\\/&]/\\&/g')
    domain_escaped=$(printf '%s' "$DOMAIN" | sed 's/[\\/&]/\\&/g')

    sed -i "s/__ACME_EMAIL__/$email_escaped/g" "$RADIUS_DIR/docker-compose.yml"
    sed -i "s/__DOMAIN__/$domain_escaped/g" "$RADIUS_DIR/docker-compose.yml"
}

# =============================================================================
# Deployment
# =============================================================================

deploy_containers() {
    log_info "Starting the NetConfig Radius containers..."

    (
        cd "$RADIUS_DIR" || die "Failed to change to $RADIUS_DIR"
        if ! $COMPOSE_MODE up -d --pull always; then
            die "Failed to start containers with docker compose."
        fi
    )
}

wait_for_health() {
    local wait_time=0

    log_info "Waiting for the radius-api container to report as healthy..."

    while ! docker inspect --format '{{.State.Health.Status}}' netconfig_radius_api 2>/dev/null | grep -q "healthy"; do
        if [ $wait_time -ge $MAX_WAIT ]; then
            die "Container did not become healthy within ${MAX_WAIT} seconds. Check logs with: docker logs netconfig_radius_api"
        fi

        log_info "Container not healthy yet. Retrying in ${WAIT_INTERVAL} seconds... ($wait_time/${MAX_WAIT}s)"
        sleep $WAIT_INTERVAL
        wait_time=$((wait_time + WAIT_INTERVAL))
    done

    log_info "Container is healthy."
}

# =============================================================================
# Display Credentials
# =============================================================================

display_credentials() {
    printf '\n'
    printf '=========================================\n'
    printf ' NetConfig Radius - Installation Complete\n'
    printf '=========================================\n'
    printf '\n'
    printf 'RADIUS API Key:\n'
    printf '%s\n' "$RADIUS_API_KEY"
    printf '\n'
    printf 'Register this key at NetConfig to connect the RADIUS service.\n'
    printf '\n'
    printf 'RADIUS Authentication: UDP port 1812\n'
    printf 'RADIUS Accounting:     UDP port 1813\n'

    if [ "$TRAEFIK_ENABLE_TLS" = "true" ]; then
        printf 'RADIUS API (HTTPS):    port 8443\n'
    fi
    printf 'RADIUS API (HTTP):     port 8080\n'
    printf '\n'
}

# =============================================================================
# Main Function
# =============================================================================

check_distro() {
    if [ ! -f /etc/os-release ]; then
        die "Cannot detect distribution (/etc/os-release not found). This installer only supports Debian and Ubuntu."
    fi

    . /etc/os-release

    case "${ID:-}" in
        debian|ubuntu) ;;
        *) die "Unsupported distribution: ${ID:-unknown}. This installer only supports Debian and Ubuntu." ;;
    esac
}

main() {
    log_info "Starting NetConfig Radius installation..."

    parse_arguments "$@"
    check_root
    check_distro

    if [ "$REINSTALL" = "true" ]; then
        wipe_previous_installation
    fi

    if [ "$NO_INSTALL_VM_DOCKER" = "true" ]; then
        log_info "Skipping Docker/dependency installation (NO_INSTALL_VM_DOCKER=true)."
        command_exists curl || die "curl not found and --no-install-vm-docker was set. Install curl and retry."
        command_exists openssl || die "openssl not found and --no-install-vm-docker was set. Install openssl and retry."
        command_exists docker || die "docker not found and --no-install-vm-docker was set. Install docker and retry."
    else
        install_dependencies
    fi
    configure_tls
    setup_directories
    setup_certificates
    setup_credentials
    detect_compose_mode
    generate_docker_compose
    deploy_containers
    wait_for_health
    display_credentials

    log_info "Installation and configuration completed successfully."
}

# =============================================================================
# Script Entry Point
# =============================================================================

main "$@"
