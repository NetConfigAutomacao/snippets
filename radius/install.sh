#!/usr/bin/env sh

set -eu

# =============================================================================
# NetConfig Radius Installer
# =============================================================================

readonly TRAEFIK_VERSION="v3.6.1"
readonly RADIUS_DIR="/opt/netconfig-radius"
readonly TRAEFIK_DIR="${RADIUS_DIR}/traefik"
readonly DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
readonly UPDATE_SCRIPT="${RADIUS_DIR}/update.sh"
readonly UPDATE_LOCK_DIR="${RADIUS_DIR}/.update.lock"
readonly CRON_FILE="/etc/cron.d/netconfig-radius"
readonly MAX_WAIT=300
readonly WAIT_INTERVAL=5

# =============================================================================
# Global State Variables (intentionally global)
# =============================================================================

UNATTENDED=false
NO_INSTALL_VM_DOCKER=false
NO_UPDATE_VM=false
NO_AUTO_UPDATE=false
REINSTALL=false
COMPOSE_MODE=""
RADIUS_TAG="latest"
UPDATE_WEEKDAY="-1"
UPDATE_HOUR="-1"
UPDATE_MINUTE="-1"

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

cron_installed() {
    dpkg -s cron >/dev/null 2>&1
}

random_int_in_range() {
    local min="$1"
    local max="$2"
    local span
    local random_value

    span=$((max - min + 1))
    random_value=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')

    printf '%s\n' $((min + (random_value % span)))
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This installer must run as root (tip: use sudo)."
    fi
}

socket_listener_exists() {
    local protocol="$1"
    local port="$2"

    case "$protocol" in
        tcp)
            ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .
            ;;
        udp)
            ss -lunH "( sport = :$port )" 2>/dev/null | grep -q .
            ;;
        *)
            die "Unsupported protocol for port validation: $protocol"
            ;;
    esac
}

is_managed_container_name() {
    case "$1" in
        netconfig_radius_api|netconfig_radius_server|netconfig_radius_db|netconfig_radius_traefik) return 0 ;;
        *) return 1 ;;
    esac
}

docker_container_uses_host_port() {
    local container_name="$1"
    local port="$2"
    local protocol="$3"

    docker port "$container_name" 2>/dev/null | grep -Eq "^${port}/${protocol}[[:space:]]*->[[:space:]].*:${port}$"
}

port_used_by_managed_docker_container() {
    local port="$1"
    local protocol="$2"
    local container_name

    if ! command_exists docker; then
        return 1
    fi

    for container_name in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        if is_managed_container_name "$container_name" && docker_container_uses_host_port "$container_name" "$port" "$protocol"; then
            return 0
        fi
    done

    return 1
}

port_used_by_unmanaged_docker_container() {
    local port="$1"
    local protocol="$2"
    local container_name

    if ! command_exists docker; then
        return 1
    fi

    for container_name in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        if ! is_managed_container_name "$container_name" && docker_container_uses_host_port "$container_name" "$port" "$protocol"; then
            return 0
        fi
    done

    return 1
}

assert_port_available() {
    local port="$1"
    local protocol="$2"

    if port_used_by_unmanaged_docker_container "$port" "$protocol"; then
        die "Port ${port}/${protocol} is already in use by another Docker container. Stop the conflicting service before retrying."
    fi

    if socket_listener_exists "$protocol" "$port" && ! port_used_by_managed_docker_container "$port" "$protocol"; then
        die "Port ${port}/${protocol} is already in use on this host. Stop the conflicting service before retrying."
    fi
}

validate_required_ports() {
    assert_port_available 9443 tcp
    assert_port_available 1812 udp
    assert_port_available 1813 udp

    log_info "Port validation completed."
}

generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

is_integer() {
    case "$1" in
        -|''|*[!0-9-]*|*--*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_integer_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local option_name="$4"

    is_integer "$value" || die "$option_name must be an integer."

    if [ "$value" -ne -1 ] && { [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; }; then
        die "Option $option_name must be between $min and $max."
    fi
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
            --no-auto-update)
                NO_AUTO_UPDATE=true
                shift
                ;;
            --tag)
                if [ -z "${2:-}" ]; then
                    die "Option --tag requires a value (e.g., --tag v1.0.0)"
                fi
                RADIUS_TAG="$2"
                shift 2
                ;;
            --update-weekday)
                validate_integer_range "$2" 0 6 "--update-weekday"
                UPDATE_WEEKDAY="$2"
                shift 2
                ;;
            --update-hour)
                validate_integer_range "$2" 0 23 "--update-hour"
                UPDATE_HOUR="$2"
                shift 2
                ;;
            --update-minute)
                validate_integer_range "$2" 0 59 "--update-minute"
                UPDATE_MINUTE="$2"
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

    if [ "$UPDATE_WEEKDAY" -ne -1 ] || [ "$UPDATE_HOUR" -ne -1 ] || [ "$UPDATE_MINUTE" -ne -1 ]; then
        if [ "$UPDATE_WEEKDAY" -eq -1 ] || [ "$UPDATE_HOUR" -eq -1 ] || [ "$UPDATE_MINUTE" -eq -1 ]; then
            die "If one update schedule option is provided, --update-weekday, --update-hour, and --update-minute must all be provided."
        fi
    fi
}

show_help() {
    cat << 'EOF'
Usage: install.sh [OPTIONS]

Options:
  --unattended, --no-prompt, --no-ask, -y
                    Run installation without interactive prompts
  --reinstall       Wipe existing NetConfig Radius installation (containers,
                    volume data, and files under /opt/netconfig-radius) and
                    run the installation again (DESTRUCTIVE)
  --no-install-vm-docker
                    Do not install Docker or dependencies (curl, openssl).
                    Check if they are installed, fail if not.
  --no-update-vm    Skip system package update (apt-get update/upgrade)
  --tag VERSION     Specify image tag for radius-db, radius-api,
                    and radius-server (default: latest)
  --no-auto-update  Do not create the automatic update cron job
  --update-weekday N
                    Weekday for automatic updates (0-6)
  --update-hour N   Hour for automatic updates (0-23)
  --update-minute N Minute for automatic updates (0-59)
  --help, -h        Show this help message

Environment variables:
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
     log_info "Refreshing package index for required dependencies..."
     run_apt_get update -y
     fi

     ensure_package "curl"
     ensure_package "openssl"
     install_docker
}

package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

ensure_package() {
    local package="$1"

    if ! package_installed "$package"; then
        log_info "$package not found. Installing..."
        run_apt_get install -y "$package"
        return 0
    fi

    log_info "Updating required package: $package"
    run_apt_get install -y --only-upgrade "$package"
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

install_cron() {
    if cron_installed; then
        log_info "Updating required package: cron"
        run_apt_get install -y --only-upgrade cron
        return 0
    fi

    log_info "cron not found. Installing..."
    run_apt_get install -y cron
}

run_apt_get() {
    # Ensure apt-get runs non-interactively and doesn't prompt for user input
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$@"
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
    local cert_dir="$TRAEFIK_DIR/certs"
    local self_signed_crt="$cert_dir/selfsigned.crt"
    local self_signed_key="$cert_dir/selfsigned.key"

    mkdir -p "$cert_dir"

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

write_env_file() {
    local env_file="$RADIUS_DIR/.env"

    log_info "Writing environment file to $env_file..."
    umask 077
    cat > "$env_file" <<EOF
RADIUS_TAG=${RADIUS_TAG}
RADIUS_API_KEY=${RADIUS_API_KEY}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
EOF
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
        docker image rm -f "netconfigsup/radius-db:${RADIUS_TAG}" >/dev/null 2>&1 || true
        docker image rm -f "netconfigsup/radius-api:${RADIUS_TAG}" >/dev/null 2>&1 || true
        docker image rm -f "netconfigsup/radius-server:${RADIUS_TAG}" >/dev/null 2>&1 || true
        docker image rm -f "traefik:${TRAEFIK_VERSION}" >/dev/null 2>&1 || true

        for img in $(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^netconfigsup/radius-(db|api|server):' || true); do
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
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=radius-internal"
      - '--providers.docker.constraints=Label("radius.stack","true")'
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.websecure.address=:9443"
    ports:
      - "9443:9443"
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
      - "radius.stack=true"
      - "traefik.docker.network=radius-internal"
      - "traefik.enable=true"
      - "traefik.http.services.radius-api.loadbalancer.server.port=8000"
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
    cat <<'EOF'
  radius-db:
    image: netconfigsup/radius-db:${RADIUS_TAG}
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
    cat <<'EOF'
  radius-api:
    image: netconfigsup/radius-api:${RADIUS_TAG}
    container_name: netconfig_radius_api
    restart: unless-stopped
    depends_on:
      radius-db:
        condition: service_healthy
    environment:
      RADIUS_API_KEY: ${RADIUS_API_KEY}
      RADIUS_DB_DSN: raduser:radpass@tcp(radius-db:3306)/raddb?parseTime=true&tls=false
      RADIUS_ITEMS_PER_PAGE: 100
      RADIUS_SERVER_CONTAINER: netconfig_radius_server
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - radius-internal
EOF
}

compose_server_service() {
    cat <<'EOF'
  radius-server:
    image: netconfigsup/radius-server:${RADIUS_TAG}
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
    name: radius-internal
EOF
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
# Update Script and Cron Job
# =============================================================================

create_update_script() {
    log_info "Creating update script at $UPDATE_SCRIPT..."

    cat > "$UPDATE_SCRIPT" <<EOF
#!/usr/bin/env sh

set -eu

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

detect_update_compose_mode() {
    if command -v docker-compose >/dev/null 2>&1; then
        printf '%s\n' "docker-compose"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        printf '%s\n' "docker compose"
        return 0
    fi

    printf '%s\n' "ERROR_COMPOSE_NOT_FOUND" >&2
    return 1
}

cleanup() {
    rmdir "$UPDATE_LOCK_DIR" >/dev/null 2>&1 || true
}

if ! mkdir "$UPDATE_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "Another NetConfig Radius update is already running." >&2
    exit 0
fi

trap cleanup EXIT INT TERM

if [ ! -d "$RADIUS_DIR" ]; then
    printf '%s\n' "Radius directory not found: $RADIUS_DIR" >&2
    exit 1
fi

cd "$RADIUS_DIR"

if [ ! -f docker-compose.yml ]; then
    printf '%s\n' "docker-compose.yml not found in $RADIUS_DIR" >&2
    exit 1
fi

COMPOSE_MODE="\$(detect_update_compose_mode)"

\$COMPOSE_MODE pull
\$COMPOSE_MODE up -d
EOF

    chmod +x "$UPDATE_SCRIPT"
}

configure_update_cron() {
    local cron_weekday="$UPDATE_WEEKDAY"
    local cron_hour="$UPDATE_HOUR"
    local cron_minute="$UPDATE_MINUTE"

    if [ "$NO_AUTO_UPDATE" = "true" ]; then
        log_info "Automatic updates disabled. Skipping cron update."
        return 0
    fi

    log_info "Configuring weekly update cron job..."

    if [ -f "$CRON_FILE" ] && [ "$UPDATE_WEEKDAY" -eq -1 ]; then
        log_info "Existing cron file found and update schedule was not provided. Skipping cron update."
        return 0
    fi

    if [ "$cron_weekday" -eq -1 ]; then
        cron_weekday=$(random_int_in_range 0 1)
        if [ "$cron_weekday" -eq 1 ]; then
            cron_weekday=6
        fi
    fi

    if [ "$cron_hour" -eq -1 ]; then
        cron_hour=$(random_int_in_range 3 5)
    fi

    if [ "$cron_minute" -eq -1 ]; then
        cron_minute=$(random_int_in_range 0 59)
    fi

    mkdir -p "$RADIUS_DIR/logs"
    systemctl enable cron

    cat > "$CRON_FILE" <<EOF
$cron_minute $cron_hour * * $cron_weekday root $UPDATE_SCRIPT > $RADIUS_DIR/logs/update-\$(date +\%Y\%m\%d-\%H\%M\%S).log 2>&1
EOF

    chmod 644 "$CRON_FILE"
    log_info "Automatic update scheduled for weekday=${cron_weekday} hour=${cron_hour} minute=${cron_minute}."
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
    printf 'RADIUS API (HTTPS):    port 9443\n'
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

    if [ "$NO_INSTALL_VM_DOCKER" = "true" ]; then
        log_info "Skipping Docker/dependency installation (NO_INSTALL_VM_DOCKER=true)."
        command_exists curl || die "curl not found and --no-install-vm-docker was set. Install curl and retry."
        command_exists openssl || die "openssl not found and --no-install-vm-docker was set. Install openssl and retry."
        command_exists docker || die "docker not found and --no-install-vm-docker was set. Install docker and retry."
    else
        install_dependencies
    fi

    if [ "$NO_AUTO_UPDATE" = "true" ]; then
        log_info "Skipping auto-update configuration (NO_AUTO_UPDATE=true)."
        cron_installed || die "cron not found and --no-auto-update was set. Install cron and retry."
    else
        install_cron
    fi

    validate_required_ports

    if [ "$REINSTALL" = "true" ]; then
        wipe_previous_installation
    fi
    setup_directories
    setup_certificates
    setup_credentials
    write_env_file
    detect_compose_mode
    generate_docker_compose
    create_update_script
    configure_update_cron
    deploy_containers
    wait_for_health
    display_credentials

    log_info "Installation and configuration completed successfully."
}

# =============================================================================
# Script Entry Point
# =============================================================================

main "$@"
