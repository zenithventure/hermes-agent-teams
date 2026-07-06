#!/usr/bin/env bash

# ============================================================
# Hermes Agent Deployer (engine)
# ============================================================
# Seeds a single agent's data into ~/.hermes and wires up a
# GitHub-backed knowledge base. Run as the `hermes` user.
# install-agent.sh calls this after cloning the repo; you can
# also run it directly against a local agent directory.
#
# Usage:
#   lib/deploy-agent.sh --agent-dir <path> [options]
#
# Options:
#   --agent-dir <path>   Agent directory (config.yaml, SOUL.md, memories/, skills/)
#   --bws-token <tok>    Bitwarden Secrets Manager bootstrap token (starts "0.")
#   --bws-project <uuid> Bitwarden project id (templated into config.yaml)
#   --kb-repo <git-url>  Knowledge-base git remote (cloned/seeded into ~/.hermes/workspace/kb)
#   --kb-branch <name>   KB branch (default: main)
#   --force              Overwrite ~/.hermes/config.yaml even if it exists
#   --clean              Remove the agent's seeded files before deploying
#   --uninstall          Remove the agent's seeded files and exit
#   --help               Show this help
#
# Seed rules (verified against the live Hermes layout):
#   config.yaml    -> ~/.hermes/config.yaml        seed-once (or --force); runtime-managed
#   BWS token      -> ~/.hermes/.env               0600; ONLY on-disk secret
#   SOUL.md        -> ~/.hermes/SOUL.md            0644; always refreshed (declarative)
#   memories/*     -> ~/.hermes/memories/*         0600; seed-once (never clobber memory)
#   skills/*       -> ~/.hermes/skills/<name>/     0644; merge (never touch bundled skills)
#   kb-seed/*      -> ~/.hermes/workspace/kb/*     pushed to --kb-repo if that repo is empty
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

# ── Args ───────────────────────────────────────────────────
AGENT_DIR=""
BWS_TOKEN=""
BWS_PROJECT=""
KB_REPO=""
KB_BRANCH="main"
FORCE=false
CLEAN=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-dir)   shift; AGENT_DIR="${1:-}" ;;
        --bws-token)   shift; BWS_TOKEN="${1:-}" ;;
        --bws-project) shift; BWS_PROJECT="${1:-}" ;;
        --kb-repo)     shift; KB_REPO="${1:-}" ;;
        --kb-branch)   shift; KB_BRANCH="${1:-}" ;;
        --force)       FORCE=true ;;
        --clean)       CLEAN=true ;;
        --uninstall)   UNINSTALL=true ;;
        *) log_err "Unknown flag: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$AGENT_DIR" ]]; then
    log_err "--agent-dir is required"
    exit 1
fi
if [[ ! -d "$AGENT_DIR" ]]; then
    log_err "Agent dir not found: $AGENT_DIR"
    exit 1
fi

DATA_DIR="${HERMES_DATA_DIR:-$HOME/.hermes}"
WORKSPACE_DIR="${DATA_DIR}/workspace"
KB_DIR="${WORKSPACE_DIR}/kb"

# ── Uninstall / clean ──────────────────────────────────────
remove_seeded() {
    log_step "Removing seeded agent files..."
    rm -f "${DATA_DIR}/SOUL.md"
    # Leave memories/ and the KB in place — they hold accumulated state.
    if [[ -d "$AGENT_DIR/skills" ]]; then
        local s
        for s in "$AGENT_DIR"/skills/*/; do
            [[ -d "$s" ]] || continue
            rm -rf "${DATA_DIR}/skills/$(basename "$s")"
        done
    fi
    log_ok "Removed SOUL.md and this agent's skills (memories + KB preserved)"
}

if [[ "$UNINSTALL" == true ]]; then
    remove_seeded
    log_ok "Uninstalled. Restart the stack to apply: (cd ~/hermes-agent && docker compose restart)"
    exit 0
fi
if [[ "$CLEAN" == true ]]; then
    remove_seeded
fi

log_step "Deploying agent from ${AGENT_DIR}"
mkdir -p "$DATA_DIR" "$WORKSPACE_DIR"
chmod 700 "$DATA_DIR"

# ── 1. config.yaml (seed-once; runtime-managed) ────────────
seed_config() {
    local src="${AGENT_DIR}/config.yaml"
    local dst="${DATA_DIR}/config.yaml"
    if [[ ! -f "$src" ]]; then
        log_warn "No config.yaml in agent dir — skipping (gateway keeps existing config)"
        return
    fi
    if [[ -f "$dst" && "$FORCE" != true ]]; then
        log_warn "config.yaml exists — leaving it (it is runtime-managed; use --force to overwrite)"
        return
    fi
    # Substitute the Bitwarden project id placeholder if present.
    if [[ -n "$BWS_PROJECT" ]]; then
        sed "s|__BWS_PROJECT_ID__|${BWS_PROJECT}|g" "$src" > "$dst"
    else
        cp "$src" "$dst"
    fi
    chmod 644 "$dst"
    log_ok "Seeded config.yaml"
}

# ── 2. .env — ONLY the Bitwarden bootstrap token ───────────
seed_env() {
    local dst="${DATA_DIR}/.env"
    if [[ -z "$BWS_TOKEN" ]]; then
        log_warn "No --bws-token given — .env not written. Provider keys must resolve"
        log_warn "another way (openai-codex OAuth, or add the token later)."
        return
    fi
    umask 077
    cat > "$dst" <<EOF
# Managed by deploy-agent.sh. The ONLY secret on disk.
# Every provider/channel key lives in Bitwarden, named after its env var,
# and is pulled into gateway memory at startup. Do NOT add raw keys here.
BWS_ACCESS_TOKEN=${BWS_TOKEN}
EOF
    chmod 600 "$dst"
    log_ok "Wrote ~/.hermes/.env (0600) — bootstrap token only, no raw keys"
}

# ── 3. SOUL.md (always refresh) ────────────────────────────
seed_soul() {
    if [[ -f "${AGENT_DIR}/SOUL.md" ]]; then
        cp "${AGENT_DIR}/SOUL.md" "${DATA_DIR}/SOUL.md"
        chmod 644 "${DATA_DIR}/SOUL.md"
        log_ok "Deployed SOUL.md"
    fi
}

# ── 4. memories/* (0600, seed-once) ────────────────────────
seed_memories() {
    [[ -d "${AGENT_DIR}/memories" ]] || return
    mkdir -p "${DATA_DIR}/memories"
    chmod 700 "${DATA_DIR}/memories"
    local f name
    for f in "${AGENT_DIR}"/memories/*; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")
        if [[ -f "${DATA_DIR}/memories/${name}" ]]; then
            log_warn "memories/${name} exists — leaving it (seed-once)"
            continue
        fi
        install -m 600 "$f" "${DATA_DIR}/memories/${name}"
        log_ok "Seeded memories/${name} (0600)"
    done
}

# ── 5. skills/* (0644, merge) ──────────────────────────────
seed_skills() {
    [[ -d "${AGENT_DIR}/skills" ]] || return
    mkdir -p "${DATA_DIR}/skills"
    local s name
    for s in "${AGENT_DIR}"/skills/*/; do
        [[ -d "$s" ]] || continue
        name=$(basename "$s")
        mkdir -p "${DATA_DIR}/skills/${name}"
        cp -R "$s"* "${DATA_DIR}/skills/${name}/"
        chmod -R u+rw,go+r "${DATA_DIR}/skills/${name}"
        log_ok "Deployed skill: ${name}"
    done
}

# ── 6. Knowledge base — GitHub-backed wiki ─────────────────
# Auth = a fine-grained GitHub PAT stored in Bitwarden as KB_GITHUB_TOKEN and
# injected into the gateway's env at startup, so the RUNNING AGENT can push over
# HTTPS with no key on disk. A git credential helper reads $KB_GITHUB_TOKEN at
# push time; the token value is never written to .git/config or the URL.

# The helper git runs on every fetch/push: emits creds from the env for `get`.
# shellcheck disable=SC2016  # ${KB_GITHUB_TOKEN} must stay literal — the shell
# git spawns expands it at push time, using the token from the process env.
KB_CRED_HELPER='!f() { if test "$1" = get; then echo username=x-access-token; echo "password=${KB_GITHUB_TOKEN}"; fi; }; f'

# git@github.com:owner/repo(.git) / ssh://… → https://github.com/owner/repo.git
normalize_kb_url() {
    local url="$1"
    case "$url" in
        git@github.com:*)        url="https://github.com/${url#git@github.com:}" ;;
        ssh://git@github.com/*)  url="https://github.com/${url#ssh://git@github.com/}" ;;
    esac
    [[ "$url" == *.git ]] || url="${url}.git"
    printf '%s' "$url"
}

# Host-side seed push needs the token: prefer the env, else pull it from
# Bitwarden with the bootstrap token (needs the `bws` CLI + jq). Empty = skip.
resolve_kb_token() {
    if [[ -n "${KB_GITHUB_TOKEN:-}" ]]; then printf '%s' "$KB_GITHUB_TOKEN"; return; fi
    if [[ -n "$BWS_TOKEN" ]] && command -v bws &>/dev/null && command -v jq &>/dev/null; then
        BWS_ACCESS_TOKEN="$BWS_TOKEN" bws secret list ${BWS_PROJECT:+"$BWS_PROJECT"} -o json 2>/dev/null \
            | jq -r '.[] | select(.key=="KB_GITHUB_TOKEN") | .value' 2>/dev/null | head -1
    fi
}

# Persist the helper + HTTPS remote into the repo so the in-container agent
# (which doesn't go through kb_git) pushes with the same env token.
configure_kb_auth() {
    git -C "$1" config credential.helper "$KB_CRED_HELPER"
    git -C "$1" remote set-url origin "$KB_REPO" 2>/dev/null \
        || git -C "$1" remote add origin "$KB_REPO"
    # Persistent identity so the agent's own commits succeed (git errors with
    # "unable to auto-detect email address" otherwise).
    git -C "$1" config user.email "hermes-agent@localhost"
    git -C "$1" config user.name "Hermes Agent"
}

# Every git call injects the helper inline (so clone works before .git exists)
# and exports the resolved token into the env the helper reads.
kb_git() { KB_GITHUB_TOKEN="${KB_TOKEN:-${KB_GITHUB_TOKEN:-}}" git -c credential.helper="$KB_CRED_HELPER" "$@"; }

seed_kb() {
    [[ -n "$KB_REPO" ]] || { log_warn "No --kb-repo — skipping knowledge base"; return; }
    KB_REPO="$(normalize_kb_url "$KB_REPO")"
    KB_TOKEN="$(resolve_kb_token || true)"
    mkdir -p "$WORKSPACE_DIR"

    if [[ -d "${KB_DIR}/.git" ]]; then
        configure_kb_auth "$KB_DIR"
        log_step "  Updating existing knowledge base..."
        kb_git -C "$KB_DIR" pull --ff-only origin "$KB_BRANCH" \
            || log_warn "KB pull failed — is KB_GITHUB_TOKEN in Bitwarden with repo access?"
        log_ok "KB ready at ${KB_DIR}"
        return
    fi

    log_step "  Setting up knowledge base at ${KB_DIR}..."
    if ! kb_git clone --branch "$KB_BRANCH" "$KB_REPO" "$KB_DIR" 2>/dev/null \
        && ! kb_git clone "$KB_REPO" "$KB_DIR" 2>/dev/null; then
        # Fresh/empty/private-without-token repo: init locally, seed below.
        log_step "  Clone skipped — initializing a fresh KB locally..."
        mkdir -p "$KB_DIR"
        git -C "$KB_DIR" init -q -b "$KB_BRANCH"
    fi
    configure_kb_auth "$KB_DIR"

    # Empty repo? Seed it from the agent's kb-seed/ and (with a token) push.
    if [[ -z "$(ls -A "$KB_DIR" 2>/dev/null | grep -v '^\.git$' || true)" ]]; then
        if [[ -d "${AGENT_DIR}/kb-seed" ]]; then
            cp -R "${AGENT_DIR}/kb-seed/." "$KB_DIR/"
            find "$KB_DIR" -name .gitkeep -type f -delete 2>/dev/null || true
            # Preserve empty raw/ wiki/ so the structure exists on clone.
            mkdir -p "${KB_DIR}/raw" "${KB_DIR}/wiki"
            touch "${KB_DIR}/raw/.gitkeep" "${KB_DIR}/wiki/.gitkeep"
            kb_git -C "$KB_DIR" add -A
            kb_git -C "$KB_DIR" -c user.email="hermes@localhost" -c user.name="Hermes" \
                commit -q -m "kb: seed knowledge base (Karpathy LLM Wiki)"
            kb_git -C "$KB_DIR" branch -M "$KB_BRANCH"
            if [[ -n "$KB_TOKEN" ]] && kb_git -C "$KB_DIR" push -u origin "$KB_BRANCH" 2>/dev/null; then
                log_ok "Seeded + pushed the knowledge base to origin"
            else
                log_warn "Seeded locally. Add a fine-grained GitHub PAT (Contents: Read+Write on the"
                log_warn "KB repo) to Bitwarden as KB_GITHUB_TOKEN — the agent pushes on its next run,"
                log_warn "or push now:  (cd ${KB_DIR} && KB_GITHUB_TOKEN=<pat> git push -u origin ${KB_BRANCH})"
            fi
        else
            log_warn "Repo is empty and the agent ships no kb-seed/ — nothing to seed"
        fi
    else
        log_ok "Cloned existing knowledge base ($(ls "$KB_DIR" | tr '\n' ' '))"
    fi
}

seed_config
seed_env
seed_soul
seed_memories
seed_skills
seed_kb

log_step "Agent deployed."
echo -e "  Restart the stack to apply:  ${BOLD}(cd ~/hermes-agent && HOME=\$HOME docker compose restart)${NC}"
