#!/usr/bin/env bash

# ============================================================
# Hermes Agent Installer
# ============================================================
# Deploys one agent into a running Hermes install, then
# restarts the stack. Run as the `hermes` user after
# bootstrap.sh has brought the Docker stack up.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/install-agent.sh \
#     | bash -s -- --agent _template \
#         --bws-token 0.<token> --bws-project <uuid> \
#         --kb-repo git@github.com:<you>/<kb-repo>.git
#
# Flags:
#   --agent <name>       Agent directory in the repo (default: _template)
#   --agent-dir <path>   Use a local agent directory instead of cloning the repo
#   --bws-token <tok>    Bitwarden Secrets Manager bootstrap token (starts "0.")
#   --bws-project <uuid> Bitwarden project id
#   --kb-repo <git-url>  Knowledge-base git remote
#   --kb-branch <name>   KB branch (default: main)
#   --force              Overwrite ~/.hermes/config.yaml if it exists
#   --help               Show this help
#
# NOTE: secrets are never taken as raw keys. Provider/channel keys live in
# Bitwarden (named after their env vars); only the scoped bootstrap token is
# passed here and it is the sole secret written to disk.
# ============================================================

if [[ "${1:-}" == "--help" ]]; then
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
fi

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "\n${BOLD}$1${NC}"; }
log_ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}!${NC} $1"; }
log_err()  { echo -e "  ${RED}✗${NC} $1"; }

REPO_SLUG="${HERMES_REPO_SLUG:-zenithventure/hermes-agent-teams}"
REPO_BRANCH="${HERMES_REPO_BRANCH:-main}"
REPO_URL="https://github.com/${REPO_SLUG}.git"

# ── Args ───────────────────────────────────────────────────
AGENT="_template"
AGENT_DIR=""
BWS_TOKEN=""
BWS_PROJECT=""
KB_REPO=""
KB_BRANCH="main"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent)       shift; AGENT="${1:-}" ;;
        --agent-dir)   shift; AGENT_DIR="${1:-}" ;;
        --bws-token)   shift; BWS_TOKEN="${1:-}" ;;
        --bws-project) shift; BWS_PROJECT="${1:-}" ;;
        --kb-repo)     shift; KB_REPO="${1:-}" ;;
        --kb-branch)   shift; KB_BRANCH="${1:-}" ;;
        --force)       FORCE=true ;;
        *) log_err "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

# ── Preflight ──────────────────────────────────────────────
HERMES_REPO_DIR="${HERMES_REPO_DIR:-$HOME/hermes-agent}"
if [[ ! -d "$HERMES_REPO_DIR" ]]; then
    log_err "Hermes not installed (no ${HERMES_REPO_DIR})."
    log_err "Run bootstrap.sh first."
    exit 1
fi

# ── Locate the agent dir (local, or clone the repo) ────────
CLONE_DIR=""
cleanup() { [[ -n "$CLONE_DIR" && -d "$CLONE_DIR" ]] && rm -rf "$CLONE_DIR"; }
trap cleanup EXIT

DEPLOYER=""
if [[ -n "$AGENT_DIR" ]]; then
    if [[ ! -d "$AGENT_DIR" ]]; then
        log_err "Agent dir not found: $AGENT_DIR"
        exit 1
    fi
    # Find the repo's deploy-agent.sh relative to the given agent dir, if present.
    if [[ -f "$(dirname "$AGENT_DIR")/lib/deploy-agent.sh" ]]; then
        DEPLOYER="$(dirname "$AGENT_DIR")/lib/deploy-agent.sh"
    fi
else
    log_step "Cloning ${REPO_SLUG}..."
    CLONE_DIR=$(mktemp -d)
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR" >/dev/null 2>&1 \
        || git clone --depth 1 "$REPO_URL" "$CLONE_DIR" >/dev/null 2>&1
    AGENT_DIR="${CLONE_DIR}/${AGENT}"
    DEPLOYER="${CLONE_DIR}/lib/deploy-agent.sh"
    if [[ ! -d "$AGENT_DIR" ]]; then
        log_err "Agent '${AGENT}' not found in the repo."
        echo "  Available agents:"
        for d in "$CLONE_DIR"/*/; do
            [[ -f "${d}config.yaml" || -f "${d}SOUL.md" ]] && echo "    - $(basename "$d")"
        done
        exit 1
    fi
    log_ok "Cloned"
fi

if [[ -z "$DEPLOYER" || ! -f "$DEPLOYER" ]]; then
    log_err "deploy-agent.sh not found next to the agent dir."
    exit 1
fi

# ── Deploy ─────────────────────────────────────────────────
DEPLOY_ARGS=(--agent-dir "$AGENT_DIR")
[[ -n "$BWS_TOKEN" ]]   && DEPLOY_ARGS+=(--bws-token "$BWS_TOKEN")
[[ -n "$BWS_PROJECT" ]] && DEPLOY_ARGS+=(--bws-project "$BWS_PROJECT")
[[ -n "$KB_REPO" ]]     && DEPLOY_ARGS+=(--kb-repo "$KB_REPO")
[[ -n "$KB_BRANCH" ]]   && DEPLOY_ARGS+=(--kb-branch "$KB_BRANCH")
[[ "$FORCE" == true ]]  && DEPLOY_ARGS+=(--force)

bash "$DEPLOYER" "${DEPLOY_ARGS[@]}"

# ── Remove the bundled "obsidian" skill ────────────────────
# Hermes ships an "obsidian" skill that assumes a DESKTOP Obsidian install
# (~/Documents/Obsidian Vault) — which doesn't exist on a droplet. It hijacks
# "vault"/"notes" requests and beats our knowledge-base skill (the agent goes
# hunting for a local vault instead of using the KB). Drop its profile copy and
# set the no-bundled-skills marker so it isn't re-seeded — other bundled skills
# are left untouched.
rm -rf "${HERMES_DATA_DIR:-$HOME/.hermes}/skills/note-taking/obsidian" 2>/dev/null || true
( cd "$HERMES_REPO_DIR" && docker compose exec -T gateway hermes skills opt-out >/dev/null 2>&1 ) || true
log_ok "Removed the bundled 'obsidian' skill — knowledge-base owns the vault"

# ── Restart the stack ──────────────────────────────────────
log_step "Restarting the Hermes stack..."
( cd "$HERMES_REPO_DIR" && HOME="$HOME" docker compose restart )
log_ok "Stack restarted"

# ── Enable Bitwarden in the LIVE config ────────────────────
# Hermes writes its own config.yaml at first boot, so the template's
# secrets.bitwarden block is seed-once-skipped and the integration stays OFF
# (the classic footgun). Turn it on in the running config so provider / channel
# / KB keys actually resolve from the vault — no manual `secrets bitwarden setup`.
if [[ -n "$BWS_TOKEN" && -n "$BWS_PROJECT" ]]; then
    log_step "Enabling Bitwarden Secrets Manager..."
    cd "$HERMES_REPO_DIR"
    for _ in $(seq 1 20); do
        if docker compose exec -T gateway hermes status >/dev/null 2>&1; then break; fi
        sleep 2
    done
    docker compose exec -T gateway hermes config set secrets.bitwarden.enabled true    >/dev/null 2>&1 || true
    docker compose exec -T gateway hermes config set secrets.bitwarden.project_id "$BWS_PROJECT" >/dev/null 2>&1 || true
    docker compose exec -T gateway hermes secrets bitwarden install >/dev/null 2>&1 || true
    if docker compose exec -T gateway hermes secrets bitwarden sync >/dev/null 2>&1; then
        docker compose restart >/dev/null 2>&1 || true
        log_ok "Bitwarden enabled — provider/channel/KB keys resolve from your vault"
    else
        log_warn "Enabled Bitwarden, but the first sync failed — check on the box:"
        log_warn "  hermes secrets bitwarden status"
    fi
fi

# ── openai-codex OAuth reminder ────────────────────────────
DATA_DIR="${HERMES_DATA_DIR:-$HOME/.hermes}"
if [[ -f "${DATA_DIR}/config.yaml" ]] && grep -q 'openai-codex' "${DATA_DIR}/config.yaml"; then
    echo ""
    log_warn "Provider is openai-codex — one manual OAuth step remains:"
    echo "     cd ~/hermes-agent && docker compose exec gateway \\"
    echo "       hermes auth add openai-codex --type oauth --no-browser --manual-paste"
    echo "     (open the printed URL, approve with ChatGPT Plus, paste the callback URL back)"
    echo "     then: docker compose restart"
fi

echo ""
echo -e "${BOLD}Done.${NC} Last step — pick your model, then say hello:"
echo "  hermes model                              # choose your provider + model"
echo "  hermes -z \"say hello\""
echo "  Logs:      cd ~/hermes-agent && docker compose logs -f"
echo "  Dashboard: ssh -L 9119:127.0.0.1:9119 <admin>@<ip>  # then http://localhost:9119"
