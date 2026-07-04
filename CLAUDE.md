# Authoring contract — a reusable Hermes agent

This repo takes a bare Ubuntu droplet to a running [Hermes
Agent](https://github.com/NousResearch/hermes-agent) with one agent installed and
a GitHub-backed knowledge base. Point Claude Code at this repo and describe the
agent you want ("a research assistant that tracks my reading and writes summaries")
— Claude copies `_template/` to a new directory and fills it in.

Hermes runs **one agent per droplet** (a Docker Compose stack: `gateway` +
`dashboard`, sharing `~/.hermes:/opt/data`). There is no multi-agent "team" — the
unit is a single agent, which is *pure data*.

## An agent is a directory

```
my-agent/
  config.yaml                     # name, model/provider, channels, Bitwarden secrets block
  SOUL.md                         # persona (first person)
  memories/
    USER.md                       # who the agent works for
    MEMORY.md                     # optional long-term seed
  skills/
    knowledge-base/SKILL.md       # the LLM-wiki discipline (shipped by default)
    <your-skill>/SKILL.md         # optional; keep free of private data
  kb-seed/                        # starter pushed to an empty knowledge-base repo
```

## Where each file lands on the droplet (and the rules)

| Source | Destination | Perms | Rule |
|--------|-------------|-------|------|
| `config.yaml` | `~/.hermes/config.yaml` | 0644 | **seed-once** — runtime-managed; `--force` only on a fresh box |
| (bootstrap token) | `~/.hermes/.env` | 0600 | the **only** secret on disk |
| `SOUL.md` | `~/.hermes/SOUL.md` | 0644 | always refreshed (declarative persona) |
| `memories/*` | `~/.hermes/memories/*` | 0600 | **seed-once** — never clobber accumulated memory |
| `skills/*` | `~/.hermes/skills/<name>/` | 0644 | **merge** — never touch bundled skills or `memories/` |
| `kb-seed/*` | `~/.hermes/workspace/kb/` | — | pushed to `--kb-repo` if that repo is empty |

## Rules

1. **No secrets in any file.** Provider/channel keys live in Bitwarden Secrets
   Manager, each named after its env var. Only the scoped bootstrap token reaches
   the box (`install-agent.sh --bws-token`). The agent is told to refuse
   credentials sent over chat.
2. **`config.yaml` is credential-free** and becomes runtime-managed after first
   deploy — don't re-seed it against a live agent.
3. **The knowledge base is a GitHub repo.** The agent maintains it as a markdown
   wiki (see `_template/skills/knowledge-base/SKILL.md`) and pushes changes; the
   human opens the same repo in Obsidian.
4. **Keep committed skills generic** — no personal/third-party private data.

## Deploy / iterate

```bash
# On the droplet, as the hermes user:
install-agent.sh --agent my-agent \
  --bws-token 0.<token> --bws-project <uuid> \
  --kb-repo https://github.com/<you>/<kb-repo>.git

# Edit files, then re-run to roll out changes (config.yaml + memories are preserved).
```

Validate before deploying: `lib/validate-agent.sh --agent-dir my-agent`.
