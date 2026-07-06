#!/usr/bin/env bash

# ============================================================
# Hermes Agent Validator
# ============================================================
# Lints an agent directory so broken agents fail before deploy.
#
# Usage:
#   lib/validate-agent.sh --agent-dir <path>
#   lib/validate-agent.sh --all          # validate every agent dir in the repo
#
# Checks:
#   - config.yaml is valid YAML with agent.name + model.provider
#   - SOUL.md exists and isn't a bare placeholder
#   - memories/USER.md exists
#   - each skills/<name>/ has a SKILL.md
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; FAILED=1; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

ALL=false
AGENT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-dir) shift; AGENT_DIR="${1:-}" ;;
        --all)       ALL=true ;;
        --help|-h)   sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# yaml_get <file> <dotted.key> — tiny reader (python3 if available, else grep).
yaml_get() {
    local file="$1" key="$2"
    if command -v python3 &>/dev/null; then
        python3 - "$file" "$key" <<'PY' 2>/dev/null || return 1
import sys, yaml
f, key = sys.argv[1], sys.argv[2]
try:
    data = yaml.safe_load(open(f))
except Exception as e:
    print("__PARSE_ERROR__:%s" % e); sys.exit(0)
cur = data
for part in key.split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(0)
    cur = cur[part]
print(cur if cur is not None else "")
PY
    else
        # Fallback: only handles top-level and one nesting level, good enough here.
        grep -E "^\s*${key##*.}:" "$file" | head -1 | sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//'
    fi
}

validate_one() {
    local dir="$1"
    echo -e "\n${BOLD}Validating $(basename "$dir")${NC}"
    FAILED=0

    # config.yaml
    local cfg="${dir}/config.yaml"
    if [[ ! -f "$cfg" ]]; then
        bad "config.yaml missing"
    else
        local name provider
        name=$(yaml_get "$cfg" "agent.name" || true)
        provider=$(yaml_get "$cfg" "model.provider" || true)
        if [[ "$name" == __PARSE_ERROR__* ]]; then
            bad "config.yaml is not valid YAML (${name#__PARSE_ERROR__:})"
        else
            [[ -n "$name" ]] && ok "config.yaml: agent.name = '$name'" || bad "config.yaml: agent.name is empty"
            case "$provider" in
                anthropic|openai-api|openai-codex|openrouter|auto) ok "config.yaml: model.provider = '$provider'" ;;
                "") bad "config.yaml: model.provider is empty" ;;
                *)  warn "config.yaml: model.provider '$provider' is unusual (expected anthropic|openai-api|openai-codex|openrouter|auto)" ;;
            esac
        fi
    fi

    # SOUL.md
    if [[ ! -f "${dir}/SOUL.md" ]]; then
        bad "SOUL.md missing"
    elif grep -q '\[Agent Name\]' "${dir}/SOUL.md" && [[ "$(basename "$dir")" != "_template" ]]; then
        warn "SOUL.md still has [Agent Name] placeholder — fill it in"
    else
        ok "SOUL.md present"
    fi

    # memories/USER.md
    [[ -f "${dir}/memories/USER.md" ]] && ok "memories/USER.md present" || bad "memories/USER.md missing"

    # skills
    if [[ -d "${dir}/skills" ]]; then
        local s
        for s in "${dir}"/skills/*/; do
            [[ -d "$s" ]] || continue
            [[ -f "${s}SKILL.md" ]] && ok "skill $(basename "$s") has SKILL.md" || bad "skill $(basename "$s") missing SKILL.md"
        done
    fi

    return $FAILED
}

RC=0
if [[ "$ALL" == true ]]; then
    for d in "$REPO_ROOT"/*/; do
        [[ -f "${d}config.yaml" || -f "${d}SOUL.md" ]] || continue
        validate_one "$d" || RC=1
    done
elif [[ -n "$AGENT_DIR" ]]; then
    validate_one "$AGENT_DIR" || RC=1
else
    echo "Provide --agent-dir <path> or --all" >&2
    exit 1
fi

echo ""
[[ $RC -eq 0 ]] && echo -e "${GREEN}All checks passed.${NC}" || echo -e "${RED}Validation failed.${NC}"
exit $RC
