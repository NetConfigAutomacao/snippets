#!/usr/bin/env sh

set -eu

# =============================================================================
# NetConfig SFTP Manager Installer
#
# Installs the file repository devices pull firmware and licences from: an
# OpenSSH SFTP server holding the files, plus a small control API NetConfig
# drives.
#
# It belongs on a machine INSIDE the customer's network, usually the same one
# running the agent. That is not a preference: a device behind the customer's
# NAT can reach a box on its own LAN and cannot reach anything in our cloud,
# so the repository has to be where the devices are.
#
# Traefik terminates TLS in front of the control API so the API key never
# crosses the LAN in clear text; trust comes from the HMAC signature on every
# request, not the certificate. By default that certificate is self-signed
# (no CA issues one for a bare LAN IP); set SFTP_DOMAIN (or --domain) to have
# Traefik obtain a real Let's Encrypt certificate instead, so a browser opening
# a public link sees a valid one. The file transport is SSH, not proxied.
# =============================================================================

readonly SFTP_DIR="/opt/netconfig-sftp"
readonly TRAEFIK_DIR="/opt/netconfig-sftp/traefik"
readonly UPDATE_SCRIPT="${SFTP_DIR}/update.sh"
readonly CRON_FILE="/etc/cron.d/netconfig-sftp"
readonly API_IMAGE_DEFAULT="ghcr.io/netconfigautomacao/netconfig-sftp-api"
readonly MAX_WAIT=180
readonly WAIT_INTERVAL=5

# =============================================================================
# Global State Variables (intentionally global)
# =============================================================================

UNATTENDED=false
UNINSTALL=false
NO_INSTALL_VM_DOCKER=false
NO_AUTO_UPDATE=false
REINSTALL=false
UPDATE_WEEKDAY="-1"
UPDATE_HOUR="-1"
UPDATE_MINUTE="-1"
COMPOSE_MODE=""
SFTP_TAG="latest"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.6.1}"

# Read from the environment so the caller (NetConfig's installer, which
# generates them) never has to put a credential on the command line, where it
# would land in the shell history and in every process listing.
SFTP_API_KEY="${SFTP_API_KEY:-}"
SFTP_PASSWORD="${SFTP_PASSWORD:-}"
SFTP_PORT="${SFTP_PORT:-7777}"
SFTP_API_PORT="${SFTP_API_PORT:-7770}"
SFTP_API_IMAGE="${SFTP_API_IMAGE:-$API_IMAGE_DEFAULT}"

# SFTP_API_IMAGE_URL points at a `docker save` tarball to load instead of
# pulling from a registry. It exists for the machines this product actually
# runs on: an on-premise box with no route to a public registry, or an
# air-gapped one. When set, the tarball is the source of truth and no pull is
# attempted.
SFTP_API_IMAGE_URL="${SFTP_API_IMAGE_URL:-}"

# SFTP_DOMAIN, when set, makes Traefik request a real Let's Encrypt certificate
# for it (HTTP-01 challenge on port 80) instead of the self-signed one, so
# browsers stop warning. It requires the domain to resolve to this machine and
# port 80 reachable from the internet. Empty keeps the self-signed certificate.
SFTP_DOMAIN="${SFTP_DOMAIN:-}"
SFTP_ACME_EMAIL="${SFTP_ACME_EMAIL:-}"

# SFTP_BIND_ADDRESS decides which interface the two published ports listen on.
# Empty means every interface, which is Docker's own default and what every
# installation before this one already does — changing that default would take
# a working repository off the air on upgrade.
#
# It matters because Docker publishes past the host firewall: it writes its own
# iptables rules, so a machine with a public address serves the SFTP port and
# the control API to the internet even with ufw "enabled". Binding to the LAN
# address is how an operator stops that without maintaining firewall rules.
SFTP_BIND_ADDRESS="${SFTP_BIND_ADDRESS:-}"

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
        die "This installer must run as root. Re-run with sudo."
    fi
}

generate_password() {
    if command_exists openssl; then
        openssl rand -hex 32
        return 0
    fi
    # Fall back to the kernel's pool rather than to $RANDOM, which is
    # predictable and would quietly hand out a guessable credential.
    tr -dc 'a-f0-9' < /dev/urandom | head -c 64
    printf '\n'
}

# Checks for what this actually writes — a drop-in in /etc/cron.d — not for
# the crontab binary. BusyBox ships crontab without that directory, and
# answering "yes" there fails at the write instead of at the check.
cron_installed() {
    [ -d /etc/cron.d ]
}

# random_int_in_range spreads a fleet's updates instead of having every
# machine wake at the same minute and pull at once.
random_int_in_range() {
    local min="$1"
    local max="$2"
    local span
    local random_value

    span=$((max - min + 1))
    random_value=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')

    printf '%s\n' $((min + (random_value % span)))
}

is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_integer_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="$4"

    is_integer "$value" || die "$name must be a number, got '$value'."
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        die "$name must be between $min and $max, got '$value'."
    fi
}

validate_port() {
    local value="$1"
    local name="$2"

    is_integer "$value" || die "$name must be a number, got '$value'."
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        die "$name must be between 1 and 65535, got '$value'."
    fi
}

# =============================================================================
# Port Checks
# =============================================================================

# socket_listener_exists answers only "is something listening on this port",
# with no idea of what. The docker functions below are what tell our own
# containers apart from a stranger's.
socket_listener_exists() {
    local port="$1"

    if command_exists ss; then
        ss -ltnH "( sport = :$port )" 2>/dev/null | grep -q .
    elif command_exists netstat; then
        netstat -ltn 2>/dev/null | grep -q "[:.]$port "
    else
        # No tool to ask with: let Docker be the one to refuse, rather than
        # blocking an install on a question we could not ask.
        return 1
    fi
}

is_managed_container_name() {
    case "$1" in
        netconfig-sftp-traefik|netconfig-sftp-server|netconfig-sftp-api|netconfig-sftp-autoheal) return 0 ;;
        *) return 1 ;;
    esac
}

# Matched on the HOST side of the mapping only. The container port is not the
# same number -- the SFTP server publishes 22 as $SFTP_PORT -- so anchoring on
# it, as a symmetric mapping would let you, would never match here.
docker_container_uses_host_port() {
    local container_name="$1"
    local port="$2"

    docker port "$container_name" 2>/dev/null |
        grep -Eq "^[0-9]+/tcp[[:space:]]*->[[:space:]].*:${port}\$"
}

# Prints "managed" when one of this installation's own containers publishes the
# port, "unmanaged" when someone else's container does, nothing when no
# container does.
docker_container_publishing_port() {
    local port="$1"
    local container_name

    command_exists docker || return 0

    for container_name in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        if docker_container_uses_host_port "$container_name" "$port"; then
            if is_managed_container_name "$container_name"; then
                printf '%s\n' "managed"
            else
                printf '%s\n' "unmanaged"
            fi
            return 0
        fi
    done
}

# $2 is the remediation to print, because the answer differs per port: two of
# them are the operator's to choose, and 80 is not.
assert_port_available() {
    local port="$1"
    local hint="$2"
    local owner

    owner=$(docker_container_publishing_port "$port")

    case "$owner" in
        # Ours, and a --reinstall is about to release it. Anything the socket
        # check would say here is this same container.
        managed) return 0 ;;
        unmanaged) die "Port $port is already in use by another Docker container. Stop it, or ${hint}" ;;
    esac

    if socket_listener_exists "$port"; then
        die "Port $port is already in use on this host. Stop the conflicting service, or ${hint}"
    fi
}

validate_required_ports() {
    validate_port "$SFTP_PORT" "SFTP_PORT"
    validate_port "$SFTP_API_PORT" "SFTP_API_PORT"

    if [ "$SFTP_PORT" = "$SFTP_API_PORT" ]; then
        die "SFTP_PORT and SFTP_API_PORT cannot be the same ($SFTP_PORT)."
    fi

    # 2222 is the agent's SSH tunnel, and both land on the same machine often
    # enough that this is the normal collision rather than a rare one.
    if [ "$SFTP_PORT" = "2222" ]; then
        log_warn "SFTP_PORT 2222 collides with the NetConfig Agent's SSH tunnel."
    fi

    assert_port_available "$SFTP_PORT" "set SFTP_PORT to a free port."
    assert_port_available "$SFTP_API_PORT" "set SFTP_API_PORT to a free port."

    # Only with a domain: that is what puts Traefik on :80 for the ACME
    # HTTP-01 challenge. Without one, nothing here wants port 80.
    if [ -n "$SFTP_DOMAIN" ]; then
        assert_port_available 80 "install without --domain (the certificate stays self-signed)."
    fi
}

# =============================================================================
# Arguments
# =============================================================================

show_help() {
    cat <<'EOF'
NetConfig SFTP Manager Installer

Usage: install.sh [options]

Options:
  --unattended             Never prompt; required when run from NetConfig.
  --uninstall              Remove the SFTP Manager from this machine, INCLUDING
                           every file stored in it, and exit.
  --reinstall              Remove a previous installation before installing.
  --no-install-vm-docker   Do not install Docker; fail if it is missing.
  --no-auto-update         Do not schedule the weekly update.
  --update-weekday <0-6>   Update weekday (0 = Sunday). Default: random Sun/Sat.
  --update-hour <0-23>     Update hour. Default: random between 03 and 05.
  --update-minute <0-59>   Update minute. Default: random.
  --tag <tag>              Control API image tag (default: latest).
  --domain <fqdn>          Issue a Let's Encrypt certificate for this domain
                           (needs it to resolve here and port 80 open). Default:
                           self-signed.
  --acme-email <email>     Contact for the Let's Encrypt account (default:
                           admin@<domain>).
  -h, --help               Show this help.

Environment:
  SFTP_API_KEY     Control API key. Generated when unset.
  SFTP_PASSWORD    Password of the shared 'netconfig' SFTP user. Generated when unset.
  SFTP_PORT        Published SFTP port (default: 7777).
  SFTP_API_PORT    Published control API port (default: 7770).
  SFTP_BIND_ADDRESS
                   Address the published ports listen on (default: every
                   interface). Asked interactively when not set.
  SFTP_API_IMAGE   Override the control API image.
  TRAEFIK_VERSION  Tag of the Traefik image (default: v3.6.1).
  SFTP_LOG_MAX_SIZE, SFTP_LOG_MAX_FILE
                   Docker log rotation for every container (default: 10m, 5).
  SFTP_TRAEFIK_CPU_LIMIT, SFTP_TRAEFIK_MEM_LIMIT, SFTP_SERVER_CPU_LIMIT,
  SFTP_SERVER_MEM_LIMIT, SFTP_API_CPU_LIMIT, SFTP_API_MEM_LIMIT
                   Per-container CPU and memory ceilings (default: 1, 512m).
  AUTOHEAL_INTERVAL, AUTOHEAL_START_PERIOD, AUTOHEAL_CPU_LIMIT,
  AUTOHEAL_MEM_LIMIT
                   Tuning for the autoheal container that restarts an unhealthy
                   one (default: 30, 300, 0.5, 128m).
  SFTP_API_IMAGE_URL  Load the control API image from a `docker save` tarball at
                   this URL instead of pulling it. For boxes with no route to a
                   registry.

Both credentials are read from the environment rather than from flags, so they
never reach the shell history or a process listing.
EOF
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --unattended) UNATTENDED=true ;;
            --uninstall) UNINSTALL=true ;;
            --reinstall) REINSTALL=true ;;
            --no-install-vm-docker) NO_INSTALL_VM_DOCKER=true ;;
            --no-auto-update) NO_AUTO_UPDATE=true ;;
            --update-weekday)
                shift
                [ $# -gt 0 ] || die "--update-weekday needs a value."
                UPDATE_WEEKDAY="$1"
                ;;
            --update-hour)
                shift
                [ $# -gt 0 ] || die "--update-hour needs a value."
                UPDATE_HOUR="$1"
                ;;
            --update-minute)
                shift
                [ $# -gt 0 ] || die "--update-minute needs a value."
                UPDATE_MINUTE="$1"
                ;;
            --tag)
                shift
                [ $# -gt 0 ] || die "--tag needs a value."
                SFTP_TAG="$1"
                ;;
            --domain)
                shift
                [ $# -gt 0 ] || die "--domain needs a value."
                SFTP_DOMAIN="$1"
                ;;
            --acme-email)
                shift
                [ $# -gt 0 ] || die "--acme-email needs a value."
                SFTP_ACME_EMAIL="$1"
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *) die "Unknown option: $1. Use --help." ;;
        esac
        shift
    done

    # A partial schedule is a mistake worth refusing: silently filling the
    # missing fields with random values would put the update at an hour the
    # operator did not pick and did not ask for.
    if [ "$UPDATE_WEEKDAY" != "-1" ] || [ "$UPDATE_HOUR" != "-1" ] || [ "$UPDATE_MINUTE" != "-1" ]; then
        if [ "$UPDATE_WEEKDAY" = "-1" ] || [ "$UPDATE_HOUR" = "-1" ] || [ "$UPDATE_MINUTE" = "-1" ]; then
            die "Set --update-weekday, --update-hour and --update-minute together, or none of them."
        fi
        validate_integer_range "$UPDATE_WEEKDAY" 0 6 "--update-weekday"
        validate_integer_range "$UPDATE_HOUR" 0 23 "--update-hour"
        validate_integer_range "$UPDATE_MINUTE" 0 59 "--update-minute"
    fi
}

# =============================================================================
# Dependencies
# =============================================================================

run_apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

install_docker() {
    if command_exists docker; then
        log_info "Docker already installed."
        return 0
    fi

    log_info "Installing Docker..."
    command_exists curl || die "curl is required to install Docker."
    curl -fsSL https://get.docker.com | sh || die "Docker installation failed."
    command_exists docker || die "Docker still not available after installation."
}

install_cron() {
    cron_installed && { log_info "cron already available."; return 0; }

    if command_exists apt-get; then
        log_info "Installing cron..."
        run_apt_get install -y -qq cron || log_warn "Could not install cron; automatic updates will not be scheduled."
    else
        log_warn "apt-get not found; cannot install cron."
    fi
}

install_dependencies() {
    if command_exists apt-get; then
        log_info "Updating package lists..."
        run_apt_get update -qq || log_warn "apt-get update failed; continuing."
        for package in curl openssl; do
            command_exists "$package" && continue
            log_info "Installing $package..."
            run_apt_get install -y -qq "$package" || log_warn "Could not install $package."
        done
    else
        log_warn "apt-get not found; skipping package installation."
    fi

    install_docker
}

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
# Installation
# =============================================================================

confirm_reinstall() {
    [ "$UNATTENDED" = "true" ] && return 0

    if [ ! -t 0 ]; then
        die "--reinstall needs a TTY for confirmation. Use --unattended to skip prompts."
    fi

    printf 'This removes the existing SFTP Manager AND the files stored in it. Continue? [y/N] '
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) die "Aborted." ;;
    esac
}

# uninstall_installation is the whole job when --uninstall is given: stop the
# stack, take its volumes with it, drop the update schedule and remove the
# directory. Separate from --reinstall because it must not go on to install
# anything afterwards.
uninstall_installation() {
    if [ ! -d "$SFTP_DIR" ]; then
        log_info "Nothing installed at $SFTP_DIR."
        return 0
    fi

    if [ -f "$SFTP_DIR/docker-compose.yml" ]; then
        log_info "Stopping the SFTP Manager..."
        # -v takes the stored files with it. That is what "remove completely"
        # means, and it is why the caller has to confirm before getting here.
        (cd "$SFTP_DIR" && $COMPOSE_MODE down -v --remove-orphans) ||
            log_warn "Could not stop the stack cleanly; removing the files anyway."
    fi

    if [ -f "$CRON_FILE" ]; then
        log_info "Removing the automatic update schedule..."
        rm -f "$CRON_FILE"
    fi

    rm -f "$UPDATE_SCRIPT"
    rm -rf "$SFTP_DIR"
    log_info "The SFTP Manager was removed from this machine."
}

wipe_previous_installation() {
    confirm_reinstall

    if [ -f "$SFTP_DIR/docker-compose.yml" ]; then
        log_info "Stopping the previous installation..."
        # -v takes the stored files with it, which is what --reinstall means
        # and why the confirmation above spells it out.
        (cd "$SFTP_DIR" && $COMPOSE_MODE down -v --remove-orphans) || \
            log_warn "Could not stop the previous stack cleanly; continuing."
    fi

    rm -rf "$SFTP_DIR"
}

# machine_addresses prints one address per line, IPv4 first. `ip -o addr` is
# present on every distribution this installer targets; hostname -I is not, and
# ifconfig is gone from modern minimal images.
# Docker's own bridges are skipped: on a machine that already runs containers
# they are most of the list, and binding the repository to one would publish it
# to other containers and nothing else.
machine_addresses() {
    command_exists ip || return 0
    for family in inet inet6; do
        ip -o addr show scope global 2>/dev/null |
            awk -v family="$family" '
                $2 ~ /^(docker|br-|veth|virbr)/ { next }
                $3 == family { split($4, a, "/"); print a[1] }
            '
    done
}

# address_is_public answers whether an address is routable from the internet.
# Deliberately coarse: RFC1918, CGNAT, loopback, link-local and IPv6 ULA are
# private, everything else counts as public. Erring towards "public" is the
# safe direction — a warning shown for an address that turns out to sit behind
# a NAT costs nothing, and a missing warning costs an exposed repository.
address_is_public() {
    case "$1" in
        10.*|127.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        fc*:*|fd*:*|fe8*:*|fe9*:*|fea*:*|feb*:*|::1) return 1 ;;
        *) return 0 ;;
    esac
}

# address_belongs_to_machine keeps a typo from producing a stack that cannot
# start: Docker refuses to bind an address the host does not have, and the
# failure arrives as a compose error after everything else is already done.
address_belongs_to_machine() {
    machine_addresses | grep -qxF "$1"
}

choose_bind_address() {
    [ -n "$SFTP_BIND_ADDRESS" ] && {
        address_belongs_to_machine "$SFTP_BIND_ADDRESS" ||
            die "SFTP_BIND_ADDRESS ($SFTP_BIND_ADDRESS) is not an address of this machine."
        log_info "Publishing on $SFTP_BIND_ADDRESS only."
        return 0
    }

    # Unattended runs take the default rather than guessing: picking an
    # interface for someone is how a repository ends up unreachable by the
    # very devices it was installed to serve.
    if [ "$UNATTENDED" = "true" ] || [ ! -t 0 ]; then
        log_info "Publishing on every interface (0.0.0.0)."
        for address in $(machine_addresses); do
            address_is_public "$address" || continue
            log_warn "This machine is reachable at $address from the internet, and both ports are published there."
            log_warn "Set SFTP_BIND_ADDRESS to a LAN address to restrict it."
            break
        done
        return 0
    fi

    addresses=$(machine_addresses)
    if [ -z "$addresses" ]; then
        log_warn "Could not read this machine's addresses; publishing on every interface."
        return 0
    fi

    printf '\n'
    printf 'Which address should the SFTP port and the control API listen on?\n'
    printf '\n'
    printf '  0) every interface (0.0.0.0) [default]\n'
    index=0
    has_public=false
    for address in $addresses; do
        index=$((index + 1))
        if address_is_public "$address"; then
            has_public=true
            printf '  %d) %s  <-- reachable from the internet\n' "$index" "$address"
        else
            printf '  %d) %s\n' "$index" "$address"
        fi
    done
    printf '\n'
    printf 'Docker publishes past the host firewall: it writes its own iptables rules,\n'
    printf 'so a port published on every interface is served even with ufw enabled.\n'
    if [ "$has_public" = "true" ]; then
        printf '\n'
        log_warn "This machine has an address reachable from the internet."
        printf '  Choosing "every interface" leaves the SFTP port and the control API\n'
        printf '  open to it. What guards them then is only the SFTP password and the\n'
        printf '  API key -- and public links stay downloadable by anyone holding one,\n'
        printf '  by design. Pick the LAN address unless devices outside this network\n'
        printf '  have to reach the repository.\n'
    fi
    printf '\n'
    printf 'Choice [0]: '
    read -r choice

    [ -z "$choice" ] && choice=0
    if [ "$choice" = "0" ]; then
        log_info "Publishing on every interface (0.0.0.0)."
        return 0
    fi

    is_integer "$choice" || die "Invalid choice: $choice"
    [ "$choice" -ge 1 ] && [ "$choice" -le "$index" ] || die "Invalid choice: $choice"

    SFTP_BIND_ADDRESS=$(printf '%s\n' "$addresses" | sed -n "${choice}p")
    log_info "Publishing on $SFTP_BIND_ADDRESS only."
}

# compose_bind_prefix renders the address half of a published port. Docker's
# form is IP:HOSTPORT:CONTAINERPORT, and an IPv6 address has to be bracketed
# there or the colons make it unparseable.
compose_bind_prefix() {
    [ -z "$SFTP_BIND_ADDRESS" ] && return 0
    case "$SFTP_BIND_ADDRESS" in
        *:*) printf '[%s]:' "$SFTP_BIND_ADDRESS" ;;
        *) printf '%s:' "$SFTP_BIND_ADDRESS" ;;
    esac
}

setup_directories() {
    log_info "Creating $SFTP_DIR..."
    mkdir -p "$SFTP_DIR" "$TRAEFIK_DIR/dynamic" "$TRAEFIK_DIR/certs"
    chmod 750 "$SFTP_DIR"
}

# =============================================================================
# TLS
# =============================================================================

# Self-signed, like the Agent and Radius installers: the control API is reached
# by IP on the customer's LAN, and no CA issues a certificate for an address
# that only exists inside someone's network. NetConfig therefore does not
# verify the chain (it authenticates the instance with the API key instead) --
# the certificate is here so the key does not cross the LAN in clear text.
setup_certificates() {
    cert_dir="$TRAEFIK_DIR/certs"

    if [ -f "$cert_dir/selfsigned.crt" ] && [ -f "$cert_dir/selfsigned.key" ]; then
        log_info "Self-signed certificate already exists."
    else
        generate_self_signed_cert "$cert_dir"
    fi

    {
        cat <<'YML'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/selfsigned.crt
        keyFile: /etc/traefik/certs/selfsigned.key
YML
        # With a domain, Traefik generates a real certificate for it (via the
        # ACME resolver wired in the compose command) and uses it as the default
        # for every TLS router -- including the public /l and /f paths reached
        # over HTTPS -- so a browser opening a link sees a valid certificate. The
        # self-signed one above stays as the fallback until ACME succeeds.
        if [ -n "$SFTP_DOMAIN" ]; then
            cat <<YML
      defaultGeneratedCert:
        resolver: le
        domain:
          main: ${SFTP_DOMAIN}
YML
        fi
        cat <<'YML'

# Two routers, one port. A Traefik entrypoint is a TCP listener and is not
# bound to one protocol: TLS is decided per router, so a TLS router only ever
# matches a TLS connection and a plain one only ever matches cleartext.
#
# That split is the whole point here. The control API carries the key that owns
# the repository, so it exists only on the TLS router -- over plain HTTP it is
# not 401, it is not routed at all. The public download paths are reachable
# either way, because that is what a device does with `copy <url>`: most network
# gear will not accept a self-signed certificate and plenty cannot speak HTTPS
# at all. Nothing is weakened by serving them in the clear -- a public link is
# unauthenticated by design, which is exactly what lets a device fetch it.
http:
  routers:
    sftp-api:
      rule: "PathPrefix(`/`)"
      entryPoints:
        - websecure
      service: sftp-api
      tls: {}
    sftp-public:
      rule: "PathPrefix(`/l`) || PathPrefix(`/f`)"
      entryPoints:
        - websecure
      service: sftp-api
  services:
    sftp-api:
      loadBalancer:
        servers:
          - url: "http://sftp-api:8000"
YML
    } > "$TRAEFIK_DIR/dynamic/dynamic.yml"

    # ACME persists the issued certificate here; Traefik refuses an acme.json
    # that is group/world readable.
    if [ -n "$SFTP_DOMAIN" ]; then
        mkdir -p "$TRAEFIK_DIR/acme"
        [ -f "$TRAEFIK_DIR/acme/acme.json" ] || : > "$TRAEFIK_DIR/acme/acme.json"
        chmod 600 "$TRAEFIK_DIR/acme/acme.json"
    fi
}

generate_self_signed_cert() {
    cert_dir="$1"
    openssl_cfg="$cert_dir/openssl.cnf"

    command_exists openssl || die "openssl is required to generate the TLS certificate."
    log_info "Generating the self-signed certificate for Traefik..."

    cat > "$openssl_cfg" <<'CFG'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = netconfig-sftp

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
CFG

    host_ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    if [ -n "${host_ip:-}" ]; then
        printf 'IP.2 = %s\n' "$host_ip" >> "$openssl_cfg"
    fi

    # Written to .tmp first so an interrupted run cannot leave a half-written
    # pair that the "already exists" check above would then accept forever.
    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$cert_dir/selfsigned.key.tmp" \
        -out "$cert_dir/selfsigned.crt.tmp" \
        -days 1095 \
        -config "$openssl_cfg" >/dev/null 2>&1 || die "Could not generate the TLS certificate."

    mv "$cert_dir/selfsigned.key.tmp" "$cert_dir/selfsigned.key"
    mv "$cert_dir/selfsigned.crt.tmp" "$cert_dir/selfsigned.crt"
    rm -f "$openssl_cfg"
    chmod 600 "$cert_dir/selfsigned.key"
}

setup_credentials() {
    if [ -z "$SFTP_API_KEY" ]; then
        SFTP_API_KEY=$(generate_password)
        log_info "Generated control API key."
    else
        log_info "Using the provided SFTP_API_KEY."
    fi

    if [ -z "$SFTP_PASSWORD" ]; then
        SFTP_PASSWORD=$(generate_password)
        log_info "Generated SFTP password."
    else
        log_info "Using the provided SFTP_PASSWORD."
    fi
}

write_env_file() {
    log_info "Writing $SFTP_DIR/.env..."
    # umask before the file exists, not a chmod after: a chmod that follows the
    # write leaves a window where the credentials are world-readable. Scoped to
    # a subshell so it does not silently tighten every file written later.
    (
        umask 077
        cat > "$SFTP_DIR/.env" <<EOF
SFTP_TAG=${SFTP_TAG}
TRAEFIK_VERSION=${TRAEFIK_VERSION}
SFTP_API_IMAGE=${SFTP_API_IMAGE}
SFTP_API_KEY=${SFTP_API_KEY}
SFTP_PASSWORD=${SFTP_PASSWORD}
SFTP_PORT=${SFTP_PORT}
SFTP_API_PORT=${SFTP_API_PORT}
SFTP_BIND_ADDRESS=${SFTP_BIND_ADDRESS}
EOF
    )
}

generate_docker_compose() {
    log_info "Writing $SFTP_DIR/docker-compose.yml..."
    cat > "$SFTP_DIR/docker-compose.yml" <<'EOF'
services:
  # The control API is not published directly: Traefik terminates TLS in front
  # of it, so the API key never crosses the LAN in clear text. The SFTP service
  # below is NOT proxied -- Traefik speaks HTTP, and SSH brings its own
  # encryption and host key.
  traefik:
    image: "traefik:${TRAEFIK_VERSION}"
    container_name: netconfig-sftp-traefik
    cpus: ${SFTP_TRAEFIK_CPU_LIMIT:-1}
    mem_limit: ${SFTP_TRAEFIK_MEM_LIMIT:-512m}
    logging:
      driver: "json-file"
      options:
        max-size: "${SFTP_LOG_MAX_SIZE:-10m}"
        max-file: "${SFTP_LOG_MAX_FILE:-5}"
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    # The file provider, not the docker one: there is exactly one backend and
    # its name is fixed, so label discovery would buy nothing -- and it would
    # cost a docker.sock mount in the one container reachable from outside,
    # plus a Docker API version negotiation that breaks on newer daemons
    # (traefik asks for 1.24; Engine now refuses anything below 1.40).
    command:
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--entryPoints.websecure.address=:${SFTP_API_PORT}"
      - "--entryPoints.ping.address=:8082"
      - "--ping=true"
      - "--ping.entryPoint=ping"
    ports:
      - "__BIND__${SFTP_API_PORT}:${SFTP_API_PORT}"
    volumes:
      - "./traefik/dynamic:/etc/traefik/dynamic:ro"
      - "./traefik/certs:/etc/traefik/certs:ro"
    networks:
      - sftp-internal
    labels:
      - "autoheal=true"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8082/ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

  sftp-server:
    image: atmoz/sftp:alpine
    container_name: netconfig-sftp-server
    cpus: ${SFTP_SERVER_CPU_LIMIT:-1}
    mem_limit: ${SFTP_SERVER_MEM_LIMIT:-512m}
    logging:
      driver: "json-file"
      options:
        max-size: "${SFTP_LOG_MAX_SIZE:-10m}"
        max-file: "${SFTP_LOG_MAX_FILE:-5}"
    restart: unless-stopped
    environment:
      # One shared user by design: this instance serves a single enterprise,
      # so files live directly under data/ and access is controlled by the
      # SFTP password and public links, not extra accounts. uid/gid must match
      # what the API chowns new directories to.
      SFTP_USERS: "netconfig:${SFTP_PASSWORD}:1001:100:data"
    volumes:
      - sftp-data:/home/netconfig/data
    ports:
      - "__BIND__${SFTP_PORT}:22"
    # Labelled for autoheal, but inert until it has a healthcheck: sshd exposes
    # no probe this installer can trust, and a wrong one would have autoheal
    # restarting a healthy server -- dropping the transfers in flight -- in a
    # loop. A real check means an SFTP login with the user's own password,
    # which belongs to the image, not here.
    labels:
      - "autoheal=true"
    networks:
      - sftp-internal

  sftp-api:
    image: "${SFTP_API_IMAGE}:${SFTP_TAG}"
    container_name: netconfig-sftp-api
    cpus: ${SFTP_API_CPU_LIMIT:-1}
    mem_limit: ${SFTP_API_MEM_LIMIT:-512m}
    logging:
      driver: "json-file"
      options:
        max-size: "${SFTP_LOG_MAX_SIZE:-10m}"
        max-file: "${SFTP_LOG_MAX_FILE:-5}"
    restart: unless-stopped
    depends_on:
      - sftp-server
    environment:
      SFTP_API_KEY: "${SFTP_API_KEY}"
      SFTP_SERVER_CONTAINER: netconfig-sftp-server
      SFTP_DATA_DIR: /data
      SFTP_DB_PATH: /state/sftp-api.db
      DOCKER_SOCKET_PATH: /var/run/docker.sock
      SFTP_UID: "1001"
      SFTP_GID: "100"
    volumes:
      # The same volume the server exposes: the API does file operations
      # directly against it, with no SSH in between.
      - sftp-data:/data
      # Its own state lives OUTSIDE that volume on purpose — anything under
      # /data is downloadable by anyone holding the SFTP password.
      - sftp-api-state:/state
      # Needed only to rotate the SFTP user's password in the server container.
      - /var/run/docker.sock:/var/run/docker.sock
    # Labelled for autoheal, without a healthcheck for now: the API answers
    # /api/healthy, but the check runs INSIDE this image and there is no
    # guarantee it ships wget or curl -- a check that cannot run reports
    # unhealthy, and autoheal would restart a working API forever. Add it here
    # once the image is known to carry one of them.
    labels:
      - "autoheal=true"
    networks:
      - sftp-internal

  # Restarts any container above whose healthcheck reports unhealthy -- the
  # failure restart: unless-stopped cannot see, because that one only reacts to
  # a process that exits, not to one that stays up and stops answering. Same
  # service the agent and RADIUS stacks run.
  autoheal:
    image: ${AUTOHEAL_IMAGE:-willfarrell/autoheal}:${AUTOHEAL_VERSION:-latest}
    container_name: netconfig-sftp-autoheal
    cpus: ${AUTOHEAL_CPU_LIMIT:-0.5}
    mem_limit: ${AUTOHEAL_MEM_LIMIT:-128m}
    logging:
      driver: "json-file"
      options:
        max-size: "${SFTP_LOG_MAX_SIZE:-10m}"
        max-file: "${SFTP_LOG_MAX_FILE:-5}"
    environment:
      - AUTOHEAL_CONTAINER_LABEL=autoheal
      - AUTOHEAL_INTERVAL=${AUTOHEAL_INTERVAL:-30}
      - AUTOHEAL_START_PERIOD=${AUTOHEAL_START_PERIOD:-300}
      - AUTOHEAL_DEFAULT_STOP_TIMEOUT=10
    volumes:
      # Read-write on purpose: restarting a container is a write. It is also
      # root-equivalent on this host.
      - "/var/run/docker.sock:/var/run/docker.sock"
      - "/etc/localtime:/etc/localtime:ro"
    restart: unless-stopped
    networks:
      - sftp-internal

volumes:
  sftp-data:
  sftp-api-state:

networks:
  sftp-internal:
EOF
    # __BIND__ is substituted after the fact because the heredoc above is
    # quoted: everything else in it must reach compose verbatim to be resolved
    # from .env, and only this one piece is decided here.
    # A domain turns on ACME: a :80 entrypoint for the HTTP-01 challenge, the
    # resolver the dynamic config references, and a writable volume for the
    # issued certificate. Injected here so the port 80 line still picks up the
    # __BIND__ prefix below.
    if [ -n "$SFTP_DOMAIN" ]; then
        acme_email="${SFTP_ACME_EMAIL:-admin@${SFTP_DOMAIN}}"
        awk -v email="$acme_email" '
            { print }
            /--entryPoints.websecure.address=/ {
                print "      - \"--entryPoints.web.address=:80\""
                print "      - \"--certificatesresolvers.le.acme.httpchallenge=true\""
                print "      - \"--certificatesresolvers.le.acme.httpchallenge.entrypoint=web\""
                print "      - \"--certificatesresolvers.le.acme.email=" email "\""
                print "      - \"--certificatesresolvers.le.acme.storage=/etc/traefik/acme/acme.json\""
            }
            /__BIND__/ && /SFTP_API_PORT/ {
                print "      - \"__BIND__80:80\""
            }
            /certs:\/etc\/traefik\/certs:ro/ {
                print "      - \"./traefik/acme:/etc/traefik/acme\""
            }
        ' "$SFTP_DIR/docker-compose.yml" > "$SFTP_DIR/docker-compose.yml.tmp" &&
            mv "$SFTP_DIR/docker-compose.yml.tmp" "$SFTP_DIR/docker-compose.yml"
    fi

    bind_prefix=$(compose_bind_prefix)
    sed -i "s|__BIND__|${bind_prefix}|g" "$SFTP_DIR/docker-compose.yml"
}

create_update_script() {
    log_info "Creating the update script at $UPDATE_SCRIPT..."

    # Written with a literal heredoc: the script must resolve compose and the
    # directory when it RUNS, months from now, not bake in what was true at
    # install time.
    cat > "$UPDATE_SCRIPT" <<'EOF'
#!/usr/bin/env sh

set -eu

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SFTP_DIR="/opt/netconfig-sftp"

detect_compose_mode() {
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

# A lock directory, because mkdir is the one atomic create-if-absent every
# shell has: cron and an operator running this by hand must not pull and
# recreate the containers at the same time. The trap releases it on every exit
# short of a kill -9; after one of those, remove it by hand.
UPDATE_LOCK_DIR="$SFTP_DIR/.update.lock"

cleanup() {
    rmdir "$UPDATE_LOCK_DIR" >/dev/null 2>&1 || true
}

if ! mkdir "$UPDATE_LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "Another NetConfig SFTP update is already running." >&2
    exit 0
fi

trap cleanup EXIT INT TERM

COMPOSE=$(detect_compose_mode)
cd "$SFTP_DIR"

printf '[%s] pulling images\n' "$(date -Iseconds)"
$COMPOSE pull

# Recreating the containers drops any SFTP session in flight. That is the
# trade this schedule accepts by running in the small hours; a transfer
# started then is rare, and a repository left months behind is not.
printf '[%s] restarting\n' "$(date -Iseconds)"
$COMPOSE up -d

printf '[%s] pruning old images\n' "$(date -Iseconds)"
docker image prune -f >/dev/null 2>&1 || true

printf '[%s] done\n' "$(date -Iseconds)"
EOF

    chmod 750 "$UPDATE_SCRIPT"
}

configure_update_cron() {
    local cron_weekday="$UPDATE_WEEKDAY"
    local cron_hour="$UPDATE_HOUR"
    local cron_minute="$UPDATE_MINUTE"

    if [ "$NO_AUTO_UPDATE" = "true" ]; then
        log_info "Automatic updates disabled. Skipping cron."
        return 0
    fi

    if ! cron_installed; then
        log_warn "cron is not available; skipping the automatic update schedule."
        return 0
    fi

    # An existing schedule the operator did not ask to change is left alone:
    # a reinstall should not silently move an update window they chose.
    if [ -f "$CRON_FILE" ] && [ "$UPDATE_WEEKDAY" = "-1" ]; then
        log_info "Keeping the existing update schedule."
        return 0
    fi

    if [ "$cron_weekday" = "-1" ]; then
        # Sunday or Saturday: the quietest days on a service network.
        cron_weekday=$(random_int_in_range 0 1)
        [ "$cron_weekday" -eq 1 ] && cron_weekday=6
    fi
    [ "$cron_hour" = "-1" ] && cron_hour=$(random_int_in_range 3 5)
    [ "$cron_minute" = "-1" ] && cron_minute=$(random_int_in_range 0 59)

    mkdir -p "$SFTP_DIR/logs"

    # Never fatal: a repository that works but does not update itself is a
    # far better outcome than an install aborted halfway over its schedule.
    if ! cat > "$CRON_FILE" 2>/dev/null <<EOF
$cron_minute $cron_hour * * $cron_weekday root $UPDATE_SCRIPT > $SFTP_DIR/logs/update-\$(date +\%Y\%m\%d-\%H\%M\%S).log 2>&1
EOF
    then
        log_warn "Could not write $CRON_FILE; automatic updates are not scheduled."
        return 0
    fi
    chmod 644 "$CRON_FILE"

    log_info "Automatic update scheduled for weekday=${cron_weekday} hour=${cron_hour} minute=${cron_minute}."
}

load_api_image_from_url() {
    [ -n "$SFTP_API_IMAGE_URL" ] || return 0

    log_info "Loading the control API image from $SFTP_API_IMAGE_URL..."
    tarball="$SFTP_DIR/sftp-api-image.tar.gz"

    if command_exists curl; then
        curl -fsSL "$SFTP_API_IMAGE_URL" -o "$tarball" || die "Could not download the image tarball."
    else
        wget -qO "$tarball" "$SFTP_API_IMAGE_URL" || die "Could not download the image tarball."
    fi

    loaded=$(docker load -i "$tarball") || die "Could not load the image tarball."
    # It is tens of megabytes and only needed once; leaving it behind would
    # quietly grow /opt on every reinstall.
    rm -f "$tarball"

    # The tarball names its own image, and it is almost never the registry one
    # -- a `docker save` of a locally built image carries whatever tag it was
    # built with. Without adopting it, compose would go back to the registry
    # for an image that was just loaded and, on an air-gapped machine, fail
    # there. "Loaded image:" is docker load's own wording; "Loaded image ID:"
    # (an untagged save) gives nothing to run and is refused rather than
    # silently falling back to the registry.
    reference=$(printf '%s\n' "$loaded" | sed -n 's/^Loaded image: //p' | tail -n 1)
    [ -n "$reference" ] || die "The tarball carries no tagged image; save it with a tag (docker save repo:tag)."

    SFTP_API_IMAGE=${reference%:*}
    SFTP_TAG=${reference##*:}
    log_info "Using the image from the tarball: ${SFTP_API_IMAGE}:${SFTP_TAG}"
}

deploy_containers() {
    if [ -n "$SFTP_API_IMAGE_URL" ]; then
        log_info "Skipping the registry pull; the image came from the tarball."
        (cd "$SFTP_DIR" && $COMPOSE_MODE pull sftp-server traefik) || log_warn "Could not pull the SFTP server image; continuing with what is local."
    else
        log_info "Pulling images..."
        (cd "$SFTP_DIR" && $COMPOSE_MODE pull) || log_warn "Could not pull every image; continuing with what is local."
    fi

    log_info "Starting the SFTP Manager..."
    (cd "$SFTP_DIR" && $COMPOSE_MODE up -d) || die "Could not start the containers."
}

wait_for_health() {
    log_info "Waiting for the control API to answer..."
    elapsed=0

    while [ "$elapsed" -lt "$MAX_WAIT" ]; do
        if curl -fsSk "https://127.0.0.1:${SFTP_API_PORT}/api/healthy" >/dev/null 2>&1; then
            log_info "Control API is up."
            return 0
        fi
        sleep "$WAIT_INTERVAL"
        elapsed=$((elapsed + WAIT_INTERVAL))
    done

    log_error "The control API did not answer within ${MAX_WAIT}s."
    (cd "$SFTP_DIR" && $COMPOSE_MODE logs --tail 40 sftp-api) || true
    die "Installation failed."
}

# primary_address is only for the message below. hostname -I is absent on
# Alpine and on a few minimal images, and printing "http://:7770" is worse than
# saying plainly that the address could not be read.
primary_address() {
    addr=""
    if command_exists hostname; then
        addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$addr" ] && command_exists ip; then
        addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    fi
    if [ -z "$addr" ]; then
        addr="<endereco-desta-maquina>"
    fi
    printf '%s' "$addr"
}

display_credentials() {
    cat <<EOF

=============================================================================
 NetConfig SFTP Manager installed
=============================================================================
 Control API : https://$(primary_address):${SFTP_API_PORT}
 API key     : ${SFTP_API_KEY}
 SFTP port   : ${SFTP_PORT}
 SFTP user   : netconfig
 SFTP pass   : ${SFTP_PASSWORD}

 Register these in NetConfig under Integrations > SFTP Manager, unless it
 installed this for you — in that case it already holds them.

 They are also in ${SFTP_DIR}/.env, readable only by root.
=============================================================================

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_arguments "$@"
    check_root

    if [ "$UNINSTALL" = "true" ]; then
        detect_compose_mode
        uninstall_installation
        return 0
    fi

    # Before the dependency install, not after: installing Docker changes the
    # machine, and a port typo should not cost the operator that.
    validate_required_ports

    if [ "$NO_INSTALL_VM_DOCKER" = "true" ]; then
        log_info "Skipping dependency installation (--no-install-vm-docker)."
        command_exists curl || die "curl not found and --no-install-vm-docker was set."
        command_exists docker || die "docker not found and --no-install-vm-docker was set."
    else
        install_dependencies
    fi

    detect_compose_mode

    if [ "$REINSTALL" = "true" ]; then
        wipe_previous_installation
    elif [ -f "$SFTP_DIR/docker-compose.yml" ]; then
        die "An installation already exists at $SFTP_DIR. Use --reinstall to replace it."
    fi

    if [ "$NO_AUTO_UPDATE" = "true" ]; then
        log_info "Skipping cron installation (--no-auto-update)."
    else
        install_cron
    fi

    setup_directories
    choose_bind_address
    setup_credentials
    # Before the .env, because the tarball decides which image name goes in it.
    load_api_image_from_url
    write_env_file
    setup_certificates
    generate_docker_compose
    create_update_script
    configure_update_cron
    deploy_containers
    wait_for_health
    display_credentials

    log_info "Installation completed successfully."
}

main "$@"
