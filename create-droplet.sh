#!/usr/bin/env bash

# ============================================================
# Hermes Droplet Creator — DigitalOcean
# ============================================================
# Runs on YOUR machine (the control machine). Creates a fresh
# Ubuntu droplet with doctl, then — with --bootstrap — hardens
# it and installs the Hermes Agent stack in one shot.
#
# Flow:
#   create-droplet.sh  →  bootstrap.sh (on box)  →  install-agent.sh (on box)
#
# Usage:
#   ./create-droplet.sh --name hermes-1
#   ./create-droplet.sh --name hermes-1 --bootstrap
#
# Flags:
#   --name,   -n   Droplet hostname (required)
#   --size,   -s   Droplet size slug (default: s-1vcpu-2gb — 2 GB is the
#                  floor; the Hermes image build OOMs on 1 GB)
#   --region, -r   Datacenter region (default: nyc1)
#   --image,  -i   OS image (default: latest Ubuntu LTS)
#   --ssh-key      SSH key name/fingerprint (auto-detected from doctl)
#   --bootstrap    After the droplet boots, SSH in as root and run
#                  bootstrap.sh (harden + install Hermes)
#   --help,   -h   Show this help
# ============================================================

set -euo pipefail

# Where bootstrap.sh is fetched from when --bootstrap is used.
REPO_SLUG="${HERMES_REPO_SLUG:-zenithventure/hermes-agent-teams}"
REPO_BRANCH="${HERMES_REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}"

# --- Defaults ---
NAME=""
SIZE="s-1vcpu-2gb"
REGION="nyc1"
IMAGE=""
SSH_KEY=""
BOOTSTRAP=false

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name|-n)   NAME="${2:-}";   shift 2 ;;
        --size|-s)   SIZE="${2:-}";   shift 2 ;;
        --region|-r) REGION="${2:-}"; shift 2 ;;
        --image|-i)  IMAGE="${2:-}";  shift 2 ;;
        --ssh-key)   SSH_KEY="${2:-}"; shift 2 ;;
        --bootstrap) BOOTSTRAP=true;  shift ;;
        --help|-h)   usage ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Error: --name is required." >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 1
fi

# --- Preflight: doctl installed + authenticated ---
if ! command -v doctl &>/dev/null; then
    echo "Error: doctl is not installed." >&2
    echo "Install it: https://docs.digitalocean.com/reference/doctl/how-to/install/" >&2
    exit 1
fi
if ! doctl account get &>/dev/null; then
    echo "Error: doctl is not authenticated. Run: doctl auth init" >&2
    exit 1
fi

# --- Auto-detect SSH key ---
if [[ -z "$SSH_KEY" ]]; then
    echo "Detecting SSH keys from doctl..."
    SSH_KEY=$(doctl compute ssh-key list --format FingerPrint --no-header | head -n 1)
    if [[ -z "$SSH_KEY" ]]; then
        echo "Error: No SSH keys found in your DigitalOcean account." >&2
        echo "Add one: doctl compute ssh-key create <name> --public-key-file ~/.ssh/id_ed25519.pub" >&2
        exit 1
    fi
    echo "Using SSH key: $SSH_KEY"
fi

# --- Auto-detect latest Ubuntu image ---
if [[ -z "$IMAGE" ]]; then
    echo "Detecting latest Ubuntu image..."
    IMAGE=$(doctl compute image list-distribution --format Slug --no-header | grep '^ubuntu-' | sort -V | tail -n 1)
    if [[ -z "$IMAGE" ]]; then
        echo "Error: Could not detect latest Ubuntu image." >&2
        echo "Specify one manually with --image, e.g. --image ubuntu-24-04-x64" >&2
        exit 1
    fi
    echo "Using image: $IMAGE"
fi

# --- Create droplet ---
echo ""
echo "Creating droplet..."
echo "  Name:   $NAME"
echo "  Size:   $SIZE"
echo "  Region: $REGION"
echo "  Image:  $IMAGE"
echo ""

CREATE_OUTPUT=$(doctl compute droplet create "$NAME" \
    --size "$SIZE" \
    --region "$REGION" \
    --image "$IMAGE" \
    --ssh-keys "$SSH_KEY" \
    --enable-monitoring \
    --wait \
    --format ID,Name,PublicIPv4 \
    --no-header)

DROPLET_ID=$(echo "$CREATE_OUTPUT" | awk '{print $1}')
DROPLET_IP=$(echo "$CREATE_OUTPUT" | awk '{print $3}')

if [[ -z "$DROPLET_IP" || "$DROPLET_IP" == "0.0.0.0" ]]; then
    echo "Waiting for IP assignment..."
    sleep 5
    DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
fi

if [[ -z "$DROPLET_IP" ]]; then
    echo "Error: Could not retrieve droplet IP." >&2
    exit 1
fi

echo "Droplet created — IP: $DROPLET_IP"

# --- Wait for SSH ---
echo ""
echo "Waiting for SSH..."
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$DROPLET_IP" true 2>/dev/null; then
        echo "SSH is ready."
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "Warning: SSH not available after 30 attempts." >&2
    fi
    sleep 5
done

# --- Optional: bootstrap the box ---
if [[ "$BOOTSTRAP" == true ]]; then
    echo ""
    echo "Running bootstrap.sh on the droplet (harden + install Hermes)..."
    ssh -o StrictHostKeyChecking=no root@"$DROPLET_IP" \
        "curl -fsSL ${RAW_BASE}/bootstrap.sh | bash"
fi

# --- Summary ---
echo ""
echo "========================================"
echo "  Droplet Ready"
echo "========================================"
echo "  ID:     $DROPLET_ID"
echo "  Name:   $NAME"
echo "  IP:     $DROPLET_IP"
echo "========================================"
echo ""
echo "Next steps:"
if [[ "$BOOTSTRAP" == false ]]; then
    echo "  1. Harden + install Hermes (as root):"
    echo "       ssh root@$DROPLET_IP 'curl -fsSL ${RAW_BASE}/bootstrap.sh | bash'"
fi
echo "  2. Install your agent (as the hermes user):"
echo "       ssh root@$DROPLET_IP   # then: sudo -u hermes -i"
echo "       curl -fsSL ${RAW_BASE}/install-agent.sh | bash -s -- \\"
echo "         --agent _template --bws-token 0.<token> --bws-project <uuid> \\"
echo "         --kb-repo git@github.com:<you>/<kb-repo>.git"
echo ""
echo "  Delete: doctl compute droplet delete $NAME --force"
