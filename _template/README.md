# _template — a reusable Hermes agent

Copy this directory to make your own agent:

```bash
cp -r _template my-agent
```

Then fill in the files and deploy with `install-agent.sh --agent my-agent`
(or `lib/deploy-agent.sh --agent-dir my-agent` locally).

## What's here

| File | Deploys to | Purpose |
|------|-----------|---------|
| `config.yaml` | `~/.hermes/config.yaml` (seed-once) | Name, model/provider, channels, Bitwarden secrets block. Keep credential-free. |
| `SOUL.md` | `~/.hermes/SOUL.md` (0644, refreshed) | The agent's persona / system prompt. |
| `memories/USER.md` | `~/.hermes/memories/USER.md` (0600, seed-once) | Who the agent works for. |
| `memories/MEMORY.md` | `~/.hermes/memories/MEMORY.md` (0600, seed-once) | Optional long-term memory seed. |
| `skills/knowledge-base/SKILL.md` | `~/.hermes/skills/knowledge-base/` (merge) | The LLM-wiki discipline (ingest/query/lint). |
| `kb-seed/` | pushed to `--kb-repo` if it's empty | Starter for the GitHub-backed knowledge base. |

## Editing checklist

- [ ] `config.yaml`: set `agent.name` and pick `model.provider` + `default`.
- [ ] `SOUL.md`: write the persona in first person; delete the template comments.
- [ ] `memories/USER.md`: fill in the human's details.
- [ ] Add any `skills/<name>/SKILL.md` your agent needs (keep them free of private data).
- [ ] Create a GitHub repo for the knowledge base and pass it as `--kb-repo`.

## Secrets

Never put API keys in these files. Provider/channel keys live in **Bitwarden
Secrets Manager**, each named after its env var (`ANTHROPIC_API_KEY`,
`TELEGRAM_BOT_TOKEN`, …). Only the scoped Bitwarden bootstrap token is passed to
`install-agent.sh` (`--bws-token`) and it's the sole secret written to the box.
