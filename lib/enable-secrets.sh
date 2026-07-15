#!/usr/bin/env bash

# ============================================================
# enable-secrets.sh — turn Bitwarden + Telegram ON in a LIVE agent
# ============================================================
# Hermes rewrites config.yaml at first boot, so the template's
# secrets.bitwarden and platforms.telegram blocks are seed-once-skipped and
# stay OFF: the gateway boots with "No messaging platforms enabled" and nothing
# resolves from the vault. This flips both on in the RUNNING config, pulls the
# vault secrets, and enables Telegram only when its bot token actually resolves.
# Idempotent — safe to re-run any time.
#
# Run on the droplet, as the hermes user:
#   curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/lib/enable-secrets.sh | bash
# or, from a checkout / the installer:
#   bash lib/enable-secrets.sh [--project <uuid>] [--no-restart]
#
# Flags:
#   --project <uuid>   Bitwarden project id (default: auto-discover from token)
#   --no-restart       Apply config but don't restart the stack
#   --help             Show this help
# ============================================================

if [[ "${1:-}" == "--help" ]]; then
    sed -n '/^# Run on/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
fi

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "\n${BOLD}$1${NC}"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

# Run inside a function so bash reads the WHOLE script before executing — see
# the same guard in install-agent.sh. This entrypoint is a `curl … | bash`
# target and calls `docker compose exec`, which reads stdin; without this the
# piped script tail would be swallowed and the run would stop mid-way.
main() {
PROJECT=""
RESTART=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) shift; PROJECT="${1:-}" ;;
        --no-restart) RESTART=0 ;;
        *) log_err "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

HERMES_REPO_DIR="${HERMES_REPO_DIR:-$HOME/hermes-agent}"
if [[ ! -d "$HERMES_REPO_DIR" ]]; then
    log_err "Hermes stack not found at ${HERMES_REPO_DIR} (set HERMES_REPO_DIR)."
    exit 1
fi
cd "$HERMES_REPO_DIR"

# Run a command in the gateway container.
gexec() { docker compose exec -T gateway "$@"; }
# Run bws inside the gateway with the on-disk access token loaded + exported.
bws()   { docker compose exec -T gateway sh -c 'set -a; . /opt/data/.env 2>/dev/null; set +a; exec /opt/data/bin/bws "$@"' _ "$@"; }

UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

log_step "Waiting for the gateway..."
for _ in $(seq 1 30); do
    gexec hermes status >/dev/null 2>&1 && break
    sleep 2
done
gexec hermes status >/dev/null 2>&1 || { log_err "Gateway not responding at ${HERMES_REPO_DIR}."; exit 1; }
log_ok "Gateway is up"

log_step "Installing the Bitwarden CLI (bws)..."
gexec hermes secrets bitwarden install >/dev/null 2>&1 || true
gexec test -x /opt/data/bin/bws || { log_err "bws unavailable — cannot resolve the vault."; exit 1; }
log_ok "bws ready"

if [[ -z "$PROJECT" ]]; then
    log_step "Discovering the Bitwarden project..."
    PROJECT="$(bws project list -o json 2>/dev/null | grep -oiE "$UUID_RE" | head -1 || true)"
fi
if [[ -z "$PROJECT" ]]; then
    log_err "No Bitwarden project found for this access token. Re-run with --project <uuid>."
    exit 1
fi
log_ok "Project: ${PROJECT}"

log_step "Enabling Bitwarden Secrets Manager..."
# Set project_id + access_token_env BEFORE enabled, so no "project_id is empty"
# warning fires between writes and the first sync has everything it needs.
gexec hermes config set secrets.bitwarden.project_id "$PROJECT"          >/dev/null
gexec hermes config set secrets.bitwarden.access_token_env BWS_ACCESS_TOKEN >/dev/null
gexec hermes config set secrets.bitwarden.enabled true                   >/dev/null
if gexec hermes secrets bitwarden sync >/dev/null 2>&1; then
    log_ok "Bitwarden enabled — provider/channel/KB keys resolve from the vault"
else
    log_err "Bitwarden sync failed. Check: docker compose exec gateway hermes secrets bitwarden status"
    exit 1
fi

log_step "Enabling messaging platforms whose tokens are in the vault..."
TELEGRAM=0
if bws secret list "$PROJECT" -o json 2>/dev/null | grep -q '"TELEGRAM_BOT_TOKEN"'; then
    gexec hermes config set platforms.telegram.reply_to_mode first >/dev/null
    log_ok "Telegram enabled (TELEGRAM_BOT_TOKEN found in the vault)"
    TELEGRAM=1
else
    log_warn "No TELEGRAM_BOT_TOKEN in the vault — Telegram left off"
fi

if [[ "$RESTART" == "1" ]]; then
    log_step "Restarting the stack..."
    docker compose restart >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        gexec hermes status >/dev/null 2>&1 && break
        sleep 2
    done
    gexec hermes status 2>/dev/null | grep -iE 'Telegram|Status:' || true
fi

echo
if [[ "$TELEGRAM" == "1" ]]; then
    log_ok "Done. Message your Telegram bot — it replies with a pairing code. Approve it:"
    echo "     cd ${HERMES_REPO_DIR} && docker compose exec gateway hermes pairing approve telegram <CODE>"
else
    log_ok "Done — Bitwarden is on. Add TELEGRAM_BOT_TOKEN to the vault and re-run to enable Telegram."
fi
}

main "$@"
