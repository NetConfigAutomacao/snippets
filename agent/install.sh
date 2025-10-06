#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root (tip: use sudo)."
  exit 1
fi

echo "Starting NetConfig Agent installation..."

echo "Updating the system packages..."
apt-get update -y && apt-get upgrade -y

if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found. Installing curl..."
  apt-get install -y curl
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found. Installing openssl..."
  apt-get install -y openssl
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  TARGET_USER="${SUDO_USER:-$USER}"
  if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    usermod -aG docker "$TARGET_USER"
  fi
  systemctl restart docker
else
  echo "Docker already installed."
fi

DOCKER_CONFIG_FILE="/etc/docker/daemon.json"
if [ -f "$DOCKER_CONFIG_FILE" ]; then
  if grep -q '"ip6tables"[[:space:]]*:[[:space:]]*true' "$DOCKER_CONFIG_FILE" 2>/dev/null; then
    echo "Docker IPv6 support already enabled."
  else
    echo "Docker daemon config already exists. Please ensure IPv6 is enabled manually in $DOCKER_CONFIG_FILE."
  fi
else
  echo "Enabling IPv6 support for Docker..."
  cat > "$DOCKER_CONFIG_FILE" <<'EOF'
{
  "experimental": true,
  "ip6tables": true
}
EOF
  systemctl restart docker
fi

DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
TRAEFIK_ENABLE_TLS="false"
USE_ACME="false"

if [ "${DISABLE_TLS:-}" = "true" ]; then
  echo "HTTPS disabled via DISABLE_TLS environment variable."
elif [ -n "$DOMAIN" ] && [ -n "$ACME_EMAIL" ]; then
  TRAEFIK_ENABLE_TLS="true"
  USE_ACME="true"
else
  if [ -t 0 ]; then
    echo "Enable HTTPS via Traefik? [Y/n]"
    echo "Provide DOMAIN and ACME_EMAIL for Let's Encrypt; leave blank to use a self-signed certificate."
    read -r _answer || true
    if ! printf '%s' "${_answer:-}" | grep -iq '^n'; then
      TRAEFIK_ENABLE_TLS="true"
      if [ -z "$DOMAIN" ] || [ -z "$ACME_EMAIL" ]; then
        read -r -p "Domain that points to this agent (optional): " DOMAIN || true
        read -r -p "Email for Let's Encrypt notifications (optional): " ACME_EMAIL || true
      fi
      if [ -n "$DOMAIN" ] && [ -n "$ACME_EMAIL" ]; then
        USE_ACME="true"
      else
        echo "Using a self-signed certificate because DOMAIN or ACME_EMAIL is missing."
      fi
    else
      echo "Skipping HTTPS configuration."
    fi
  else
    TRAEFIK_ENABLE_TLS="true"
    echo "No domain/email provided. HTTPS will use a self-signed certificate. Set DISABLE_TLS=true to skip."
  fi
fi

AGENT_DIR="/opt/netconfig-agent"
if [ ! -d "$AGENT_DIR" ]; then
  echo "Creating directory $AGENT_DIR..."
  mkdir -p "$AGENT_DIR"
fi

TRAEFIK_DIR="$AGENT_DIR/traefik"
if [ ! -d "$TRAEFIK_DIR" ]; then
  echo "Preparing Traefik configuration directories..."
fi
mkdir -p "$TRAEFIK_DIR/dynamic"

if [ "$TRAEFIK_ENABLE_TLS" = "true" ]; then
  if [ "$USE_ACME" = "true" ]; then
    mkdir -p "$TRAEFIK_DIR/acme"
    touch "$TRAEFIK_DIR/acme/acme.json"
    chmod 600 "$TRAEFIK_DIR/acme/acme.json"
    rm -f "$TRAEFIK_DIR/dynamic/selfsigned.yml"
  else
    CERT_DIR="$TRAEFIK_DIR/certs"
    mkdir -p "$CERT_DIR"
    SELF_SIGNED_CRT="$CERT_DIR/selfsigned.crt"
    SELF_SIGNED_KEY="$CERT_DIR/selfsigned.key"
    if [ ! -f "$SELF_SIGNED_CRT" ] || [ ! -f "$SELF_SIGNED_KEY" ]; then
      echo "Generating self-signed certificate for Traefik..."
      OPENSSL_CFG="$CERT_DIR/openssl.cnf"
      cat > "$OPENSSL_CFG" <<'EOF'
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
      host_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || host_ip=""
      if [ -n "$host_ip" ]; then
        printf 'IP.2 = %s\n' "$host_ip" >> "$OPENSSL_CFG"
      fi
      openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$SELF_SIGNED_KEY.tmp" \
        -out "$SELF_SIGNED_CRT.tmp" \
        -days 1095 \
        -config "$OPENSSL_CFG" >/dev/null 2>&1
      mv "$SELF_SIGNED_KEY.tmp" "$SELF_SIGNED_KEY"
      mv "$SELF_SIGNED_CRT.tmp" "$SELF_SIGNED_CRT"
      rm -f "$OPENSSL_CFG"
    fi
    chmod 600 "$SELF_SIGNED_KEY"
    cat > "$TRAEFIK_DIR/dynamic/selfsigned.yml" <<'EOF'
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/selfsigned.crt
        keyFile: /etc/traefik/certs/selfsigned.key
EOF
    echo "Self-signed certificate ready at $SELF_SIGNED_CRT"
  fi
else
  rm -f "$TRAEFIK_DIR/dynamic/selfsigned.yml"
fi

echo "Writing docker-compose.yml to $AGENT_DIR..."
if [ "$TRAEFIK_ENABLE_TLS" = "true" ]; then
  if [ "$USE_ACME" = "true" ]; then
    cat > "$AGENT_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.1
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
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(`/`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
      - "traefik.http.routers.netconfig-https.rule=Host(\"__DOMAIN__\")"
      - "traefik.http.routers.netconfig-https.entrypoints=websecure"
      - "traefik.http.routers.netconfig-https.tls.certresolver=le"
      - "traefik.http.routers.netconfig-https.service=netconfig"
    restart: unless-stopped

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF
    email_escaped=$(printf '%s' "$ACME_EMAIL" | sed 's/[\\/&]/\\&/g')
    domain_escaped=$(printf '%s' "$DOMAIN" | sed 's/[\\/&]/\\&/g')
    sed -i "s/__ACME_EMAIL__/$email_escaped/g" "$AGENT_DIR/docker-compose.yml"
    sed -i "s/__DOMAIN__/$domain_escaped/g" "$AGENT_DIR/docker-compose.yml"
  else
    cat > "$AGENT_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.1
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
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(`/`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
      - "traefik.http.routers.netconfig-https.rule=PathPrefix(`/`)"
      - "traefik.http.routers.netconfig-https.entrypoints=websecure"
      - "traefik.http.routers.netconfig-https.tls=true"
      - "traefik.http.routers.netconfig-https.service=netconfig"
    restart: unless-stopped

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF
  fi
else
  cat > "$AGENT_DIR/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.1
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
      - "traefik.http.routers.netconfig-http.rule=PathPrefix(`/`)"
      - "traefik.http.routers.netconfig-http.entrypoints=web"
      - "traefik.http.routers.netconfig-http.service=netconfig"
    restart: unless-stopped

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF
fi

COMPOSE_MODE=""
if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_MODE="docker-compose"
  echo "Using docker-compose..."
elif docker compose version >/dev/null 2>&1; then
  COMPOSE_MODE="docker compose"
  echo "Using docker compose plugin..."
else
  echo "Error: docker-compose or docker compose not found."
  exit 1
fi

echo "Starting the NetConfig Agent containers..."
cd "$AGENT_DIR"
sh -c "$COMPOSE_MODE up -d"

echo "Waiting for the container to report as healthy..."
until docker inspect --format '{{.State.Health.Status}}' netconfig_agent | grep -q "healthy"; do
  echo "Container not healthy yet. Retrying in 5 seconds..."
  sleep 5
done

echo "Container is healthy. Fetching authentication keys..."

API_KEY=$(docker exec netconfig_agent cat /data/api_key)
SSH_KEY=$(docker exec netconfig_agent cat /data/tunnel_ssh_key)

echo
echo "API Key:"
echo "$API_KEY"
echo
echo "SSH Key:"
echo "$SSH_KEY"
echo

echo "Register this Agent at https://app.netconfig.com.br/tunnels using the keys above."
echo "After registration, visit https://app.netconfig.com.br/enterprise/settings and select the newly created Agent."

echo "Installation and configuration completed successfully."

exit 0
