#!/usr/bin/env bash

# ============================================================
# Hermes Bootstrap — DigitalOcean Droplet Provisioner
# ============================================================
# Prepares a fresh Ubuntu 24.04 droplet: hardens the server,
# creates users, installs Docker, and brings up the Hermes
# Agent (Nous Research) stack via docker compose.
#
# Run as ROOT on the droplet.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/bootstrap.sh \
#     | bash
#
# Full:
#   curl -fsSL ... | bash -s -- \
#     --user szewong \
#     --key "ssh-ed25519 AAAA..."
#
# Flags:
#   --user <name>     Admin SSH username (default: zuser-XXXX random)
#   --key "<pubkey>"  SSH public key (default: copy from root authorized_keys)
#   --ref <git-ref>   hermes-agent ref to build (default: main)
#   --help            Show this help
# ============================================================

if [[ "${1:-}" == "--help" ]]; then
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
fi

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log_step() { echo -e "\n${BOLD}$1${NC}"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

banner() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ${RED}●${NC} ${YELLOW}●${NC} ${GREEN}●${NC} ${BLUE}●${NC}  ${BOLD}Hermes Bootstrap                     ║${NC}"
    echo -e "${BOLD}║        DigitalOcean Droplet Provisioner               ║${NC}"
    echo -e "${BOLD}║  ${DIM}Harden · Docker · Hermes Agent${NC}${BOLD}                       ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Parse Arguments ────────────────────────────────────────
ADMIN_USER=""
SSH_KEY=""
HERMES_REF="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) shift; ADMIN_USER="${1:-}" ;;
        --key)  shift; SSH_KEY="${1:-}" ;;
        --ref)  shift; HERMES_REF="${1:-}" ;;
        *) log_err "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# ── Validate ───────────────────────────────────────────────
if [[ -z "$ADMIN_USER" ]]; then
    ADMIN_USER="zuser-$(printf '%04d' $((RANDOM % 10000)))"
fi

if [[ "$(id -u)" -ne 0 ]]; then
    log_err "This script must be run as root"
    exit 1
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    # shellcheck source=/dev/null
    log_err "This script requires Ubuntu (detected: $(. /etc/os-release && echo "$NAME"))"
    exit 1
fi

# ── Hermes constants ───────────────────────────────────────
HERMES_USER="hermes"
HERMES_HOME="/home/hermes"
HERMES_REPO_URL="https://github.com/NousResearch/hermes-agent.git"
HERMES_REPO_DIR="${HERMES_HOME}/hermes-agent"
HERMES_DATA_DIR="${HERMES_HOME}/.hermes"

# ── Preflight ──────────────────────────────────────────────
banner
echo -e "${BOLD}Configuration:${NC}"
echo -e "  Admin user:  ${GREEN}${ADMIN_USER}${NC}"
echo -e "  Hermes ref:  ${GREEN}${HERMES_REF}${NC}"
echo ""

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
if [[ $TOTAL_RAM_MB -lt 2048 ]]; then
    log_warn "Low memory: ${TOTAL_RAM_MB}MB (Hermes image build wants ≥2048MB) — swap will be added"
fi

# ============================================================
# Phase 1/2 — Server Hardening
# ============================================================
log_step "[1/2] Server hardening..."

install_packages() {
    log_step "  Installing system packages..."
    export DEBIAN_FRONTEND=noninteractive
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        log_step "  Waiting for dpkg lock (unattended-upgrades?)..."
        sleep 5
    done
    apt-get update -qq
    apt-get install -y -qq curl vim git ufw build-essential python3 jq fail2ban ca-certificates gnupg > /dev/null
    log_ok "System packages installed"
}

create_admin_user() {
    log_step "  Creating admin user: ${ADMIN_USER}..."
    if id "$ADMIN_USER" &>/dev/null; then
        log_ok "User $ADMIN_USER already exists"
    else
        useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
        log_ok "Created user $ADMIN_USER"
    fi

    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/sudo-nopasswd"
    chmod 440 "/etc/sudoers.d/sudo-nopasswd"
    log_ok "Passwordless sudo configured"

    local ssh_dir="/home/${ADMIN_USER}/.ssh"
    mkdir -p "$ssh_dir"
    if [[ -n "$SSH_KEY" ]]; then
        echo "$SSH_KEY" > "${ssh_dir}/authorized_keys"
        log_ok "SSH key set from --key flag"
    elif [[ -f /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys "${ssh_dir}/authorized_keys"
        log_ok "SSH key copied from root (DO-injected)"
    else
        log_warn "No SSH key found — set one manually in ${ssh_dir}/authorized_keys"
    fi
    chmod 700 "$ssh_dir"
    chmod 600 "${ssh_dir}/authorized_keys" 2>/dev/null || true
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "$ssh_dir"
}

configure_ssh() {
    log_step "  Configuring SSH..."
    local sshd_config="/etc/ssh/sshd_config"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_config"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
    log_ok "SSH hardened (root key-only, password auth disabled)"
}

configure_firewall() {
    log_step "  Configuring firewall..."
    # Hermes uses host networking; the gateway + dashboard bind to 127.0.0.1
    # only (reach the dashboard via `ssh -L`). So only SSH needs to be open.
    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null
    ufw allow 22/tcp > /dev/null
    ufw --force enable > /dev/null
    log_ok "UFW enabled (22 only — dashboard is localhost, reach via ssh -L)"
}

configure_fail2ban() {
    log_step "  Configuring fail2ban..."
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl start fail2ban > /dev/null 2>&1
    log_ok "fail2ban enabled"
}

install_packages
create_admin_user
configure_ssh
configure_firewall
configure_fail2ban

# ── Swap file (image build is memory-hungry) ────────────────
if ! swapon --show | grep -q /swapfile; then
    log_step "  Creating 2 GB swap file..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_ok "2 GB swap enabled"
else
    log_ok "Swap already active — skipping"
fi

log_ok "Phase 1 complete — server hardened"

# ============================================================
# Phase 2/2 — Install Hermes (Docker + compose stack)
# ============================================================
log_step "[2/2] Installing Hermes Agent..."

create_hermes_user() {
    log_step "  Creating ${HERMES_USER} user..."
    if id "$HERMES_USER" &>/dev/null; then
        log_ok "User ${HERMES_USER} already exists"
    else
        useradd --create-home --home-dir "$HERMES_HOME" --shell /bin/bash "$HERMES_USER"
        log_ok "Created user: ${HERMES_USER}"
    fi
}

install_docker() {
    log_step "  Installing Docker Engine + compose plugin..."
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_ok "Docker + compose already installed"
    else
        install -m 0755 -d /etc/apt/keyrings
        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
        fi
        local arch codename
        arch=$(dpkg --print-architecture)
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME}")
        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
        log_ok "Docker installed"
    fi
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1
    usermod -aG docker "$HERMES_USER"
    usermod -aG docker "$ADMIN_USER" 2>/dev/null || true
    log_ok "dockerd enabled; ${HERMES_USER} + ${ADMIN_USER} in docker group"
}

clone_and_build_hermes() {
    log_step "  Cloning hermes-agent (${HERMES_REF})..."
    if [[ -d "$HERMES_REPO_DIR/.git" ]]; then
        git -C "$HERMES_REPO_DIR" fetch --depth 1 origin "$HERMES_REF" >/dev/null 2>&1
        git -C "$HERMES_REPO_DIR" checkout -q FETCH_HEAD
    else
        git clone --depth 1 --branch "$HERMES_REF" "$HERMES_REPO_URL" "$HERMES_REPO_DIR" >/dev/null 2>&1 \
            || git clone --depth 1 "$HERMES_REPO_URL" "$HERMES_REPO_DIR" >/dev/null 2>&1
    fi
    chown -R "${HERMES_USER}:${HERMES_USER}" "$HERMES_REPO_DIR"
    log_ok "hermes-agent at ${HERMES_REPO_DIR}"

    # State dir the container mounts as /opt/data.
    mkdir -p "$HERMES_DATA_DIR"
    chown "${HERMES_USER}:${HERMES_USER}" "$HERMES_DATA_DIR"
    chmod 700 "$HERMES_DATA_DIR"

    # compose-level .env: substitutes HERMES_UID/GID so the container writes to
    # the mounted ~/.hermes volume as the hermes user (not root).
    local uid gid
    uid=$(id -u "$HERMES_USER")
    gid=$(id -g "$HERMES_USER")
    cat > "${HERMES_REPO_DIR}/.env" <<EOF
# Managed by bootstrap.sh. Do not edit by hand.
HERMES_UID=${uid}
HERMES_GID=${gid}
EOF
    chown "${HERMES_USER}:${HERMES_USER}" "${HERMES_REPO_DIR}/.env"

    log_step "  Building the Hermes image (this takes a few minutes)..."
    # Daemon runs as root; HOME is pinned to the hermes home so the compose
    # file's ~/.hermes bind-mount resolves there, not /root/.hermes.
    ( cd "$HERMES_REPO_DIR" && HOME="$HERMES_HOME" docker compose build )
    log_ok "Image built"

    log_step "  Bringing up the Hermes stack (gateway + dashboard)..."
    ( cd "$HERMES_REPO_DIR" && HOME="$HERMES_HOME" docker compose up -d )
    log_ok "Stack up"

    # The docker CLI ran as root (with HOME pinned) above, so it created
    # ~/.docker owned by root — which makes `docker compose` fail for the hermes
    # user later ("permission denied" on ~/.docker/config.json). Hand it back.
    if [[ -d "${HERMES_HOME}/.docker" ]]; then
        chown -R "${HERMES_USER}:${HERMES_USER}" "${HERMES_HOME}/.docker"
        log_ok "Fixed ~/.docker ownership for the ${HERMES_USER} user"
    fi

    # Host wrapper so `hermes …` works straight from the shell — the CLI really
    # runs inside the gateway container, and typing the docker-compose prefix
    # every time is the #1 student stumble. Allocates a TTY for interactive
    # commands (hermes model, secrets bitwarden setup) and disables it when piped.
    cat > /usr/local/bin/hermes <<'WRAP'
#!/usr/bin/env bash
# Run the Hermes CLI inside the running gateway container.
cd /home/hermes/hermes-agent 2>/dev/null || { echo "Hermes stack not found at /home/hermes/hermes-agent" >&2; exit 1; }
[ -t 0 ] && TTY= || TTY=-T
exec env HOME=/home/hermes docker compose exec $TTY gateway hermes "$@"
WRAP
    chmod 0755 /usr/local/bin/hermes
    log_ok "Installed 'hermes' host wrapper (run 'hermes …' directly)"
}

create_hermes_user
install_docker
clone_and_build_hermes

log_ok "Phase 2 complete — Hermes stack running"

# ============================================================
# Summary
# ============================================================
PUBLIC_IP=$(curl -s --connect-timeout 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Bootstrap Complete!                                  ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}What was done:${NC}"
echo -e "  ${GREEN}✓${NC} Server hardened (UFW 22, fail2ban, SSH key-only, swap)"
echo -e "  ${GREEN}✓${NC} Admin user created: ${BOLD}${ADMIN_USER}${NC}"
echo -e "  ${GREEN}✓${NC} Docker + Hermes stack running (as ${BOLD}${HERMES_USER}${NC})"
echo ""
echo -e "  ${DIM}The gateway is up but has NO model/agent yet — install one next.${NC}"
echo ""
echo -e "${BOLD}SSH:${NC}  ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo ""
echo -e "${BOLD}Next — install your agent (as the hermes user):${NC}"
echo -e "  ${YELLOW}sudo -u hermes -i${NC}"
echo -e "  curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/install-agent.sh \\"
echo -e "    | bash -s -- --agent _template --bws-token 0.<token> --bws-project <uuid> \\"
echo -e "        --kb-repo git@github.com:<you>/<kb-repo>.git"
echo ""
