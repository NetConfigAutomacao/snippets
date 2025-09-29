#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root (tip: use sudo)."
  exit 1
fi

echo "Starting NetConfig Agent installation..."

echo "Updating the system packages..."
apt-get update -y && apt-get upgrade -y

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

AGENT_DIR="/opt/netconfig-agent"
if [ ! -d "$AGENT_DIR" ]; then
  echo "Creating directory $AGENT_DIR..."
  mkdir -p "$AGENT_DIR"
fi

echo "Writing docker-compose.yml to $AGENT_DIR..."
cat > "$AGENT_DIR/docker-compose.yml" <<'EOF'
version: "3"
services:
  agent:
    image: netconfigsup/agent:latest
    container_name: netconfig_agent
    environment:
      HOST: "0.0.0.0" # Listen on IPv4; use "::" for IPv6
    ports:
      - "8000:8000"
      - "2222:2222"
    volumes:
      - agent_data:/data
    networks:
      - local
    restart: unless-stopped

volumes:
  agent_data:

networks:
  local:
    name: netconfig
    driver: bridge
    enable_ipv6: true
EOF

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

echo "API Key: $API_KEY"
echo "SSH Key: $SSH_KEY"

echo "Register this Agent at https://app.netconfig.com.br/tunnels using the keys above."
echo "After registration, visit https://app.netconfig.com.br/enterprise/settings and select the newly created Agent."

echo "Installation and configuration completed successfully."

exit 0
