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

# ── Run the whole installer inside a function ──────────────
# This script is delivered via `curl … | bash`, so bash reads it FROM STDIN.
# Downstream subprocesses that touch stdin — git auth on the KB pull, or
# `docker compose exec` — would otherwise swallow the still-unread tail of the
# piped script, and the installer stops SILENTLY mid-run (classically right
# after "Agent deployed", before Bitwarden/Telegram get enabled). Wrapping the
# body in a function forces bash to parse the ENTIRE script into memory before
# executing a single line, so nothing downstream can truncate it.
main() {
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

# ── Enable Bitwarden + Telegram in the LIVE config ─────────
# Hermes rewrites config.yaml at first boot, so the template's
# secrets.bitwarden and platforms.telegram blocks are seed-once-skipped and stay
# OFF (the classic footgun: gateway boots with "No messaging platforms enabled"
# and nothing resolves from the vault). enable-secrets.sh flips both on in the
# running config, pulls the vault, and enables Telegram when its token resolves.
# It's the single source of truth — re-runnable by hand if this ever fails:
#   curl -fsSL https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_BRANCH}/lib/enable-secrets.sh | bash
if [[ -n "$BWS_TOKEN" ]]; then
    ENABLER="$(dirname "$DEPLOYER")/enable-secrets.sh"
    if [[ -f "$ENABLER" ]]; then
        ENABLE_ARGS=()
        [[ -n "$BWS_PROJECT" ]] && ENABLE_ARGS+=(--project "$BWS_PROJECT")
        HERMES_REPO_DIR="$HERMES_REPO_DIR" bash "$ENABLER" "${ENABLE_ARGS[@]}" \
            || log_warn "Auto-enable did not complete — re-run enable-secrets.sh on the box (see README)."
    else
        log_warn "enable-secrets.sh not found next to deploy-agent.sh — skipping auto-enable."
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
}

main "$@"
