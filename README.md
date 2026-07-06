# Hermes Agent Teams

Spin up your own self-hosted AI agent — [Hermes](https://github.com/NousResearch/hermes-agent)
(Nous Research) — on a DigitalOcean droplet, with a **GitHub-backed knowledge
base** and secrets kept in **Bitwarden**, in three commands. Built as a simple
baseline for students: create a droplet → harden it → install Hermes → install
your agent.

> Hermes runs **one agent per droplet**. Your agent is *pure data* — a `SOUL.md`
> persona, a bit of memory, some skills, and a knowledge base. Edit files, re-run
> the installer, done.

## Quick start

```bash
# 1. Create + harden the droplet and install Hermes (on your machine — needs doctl)
./create-droplet.sh --name hermes-1 --bootstrap

# 2. Install your agent (on the droplet, as the hermes user)
ssh root@<ip>           # then: sudo -u hermes -i
curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/install-agent.sh \
  | bash -s -- --agent _template \
      --bws-token 0.<token> --bws-project <uuid> \
      --kb-repo https://github.com/<you>/<kb-repo>.git

# 3. Say hello
hermes -z "say hello"
```

**No `doctl`?** Create the droplet in the DigitalOcean UI instead (Ubuntu 24.04,
2 GB, SSH key) and paste this into **Advanced options → Startup scripts** — it
hardens + installs Hermes on first boot, then you skip straight to step 2:

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/bootstrap.sh | bash
```

Only `bootstrap.sh` (no secrets) goes in that box — never `install-agent.sh`, whose
Bitwarden token would be exposed in the droplet's metadata.

Prefer to do it by hand? See [DO-SETUP.md](DO-SETUP.md). New here? The
[landing page](https://hermes.zenithstudio.app) walks through
the same flow visually.

## The three pieces

| Script | Runs | Does |
|--------|------|------|
| [`create-droplet.sh`](create-droplet.sh) | your machine | `doctl` creates an Ubuntu droplet (2 GB min), optionally chains bootstrap |
| [`bootstrap.sh`](bootstrap.sh) | droplet, as root | hardens the box (UFW, fail2ban, SSH key-only, swap) + installs Docker + brings up the Hermes stack |
| [`install-agent.sh`](install-agent.sh) | droplet, as `hermes` | deploys one agent from a directory + wires the knowledge base + restarts |

All are idempotent. Author agents from [`_template/`](_template/) — see
[CLAUDE.md](CLAUDE.md) for the contract.

## Model provider

`config.yaml` picks how the model authenticates. Three options:

| Choice | `provider` | Auth | Key needed? | Model |
|--------|-----------|------|-------------|-------|
| **Anthropic API** | `anthropic` | `ANTHROPIC_API_KEY` (from Bitwarden) | yes | `claude-opus-4.6` |
| **Codex** (ChatGPT sub) | `openai-codex` | ChatGPT Plus/Pro subscription OAuth | **no** | `gpt-5.5` |
| **OpenRouter** | `auto` + `base_url` | `OPENROUTER_API_KEY` (from Bitwarden) | yes | any OpenRouter slug |

OpenRouter is supported natively — set `provider: auto` with
`base_url: https://openrouter.ai/api/v1` and store your key as `OPENROUTER_API_KEY`
(see the commented block in [`_template/config.yaml`](_template/config.yaml)).

`openai-codex` is the **zero-key start**: no API key at all, just a one-time OAuth
login on the droplet (the installer prints the command). Great for a first run
before you set up Bitwarden.

## Secrets — start on the right foot

**Never paste keys in chat, scripts, or `.env`.** The default backend is Hermes'
native **Bitwarden Secrets Manager**:

- Keys live in a Bitwarden **project**, each secret **named after its env var**
  (`ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, …). They're pulled into the
  gateway's memory at startup.
- The droplet holds **only** a scoped machine-account **bootstrap token**
  (`--bws-token`, written to `~/.hermes/.env` at 0600). Nothing else sensitive on disk.
- Rotate anything with one edit in the Bitwarden web app — no redeploy.

Setup: in Bitwarden Secrets Manager, create a project, add your keys as secrets
named after their env vars, create a machine account with Read access, and
generate an access token. Verify on the box:

```bash
hermes secrets bitwarden status
```

Your agent is also told to **refuse credentials sent over chat** — it points you
to Bitwarden instead.

## Knowledge base — a GitHub-backed wiki

Every agent maintains a personal knowledge base as a plain-markdown **wiki**
(the [Karpathy LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
pattern): you drop sources into `raw/`, the agent compiles them into cross-linked
articles under `wiki/`, and it keeps `INDEX.md` + `log.md` current.

- It lives at `~/.hermes/workspace/kb/` on the droplet and is a **GitHub repo**.
  Create an empty repo, pass it as `--kb-repo`, and the installer seeds it.
- Auth is a fine-grained **GitHub PAT** stored in Bitwarden as `KB_GITHUB_TOKEN`
  (Contents: Read+Write on the KB repo). The agent pushes over HTTPS with it —
  nothing extra on disk, rotate it in the Bitwarden web app.
- Open the **same repo in Obsidian** on your laptop via the `obsidian-git` plugin
  — that's your window into everything the agent has learned. This also serves as
  the off-box backup of the agent's most valuable state.

See [`_template/skills/knowledge-base/SKILL.md`](_template/skills/knowledge-base/SKILL.md)
for the ingest / query / lint discipline the agent follows.

## Operate

`bootstrap.sh` installs a **`hermes` host wrapper**, so you can run the CLI
straight from the shell — `hermes model`, `hermes pairing list`,
`hermes secrets bitwarden status`, etc. — instead of the full
`cd ~/hermes-agent && docker compose exec gateway hermes …`.

```bash
hermes                                     # interactive CLI chat
hermes model                              # change the model/provider
hermes pairing approve telegram <code>    # approve a messaging user
cd ~/hermes-agent && docker compose logs -f    # tail gateway + dashboard
docker restart hermes                     # restart the gateway
# dashboard is localhost-only — tunnel to it:
ssh -L 9119:127.0.0.1:9119 <admin>@<ip>   # then open http://localhost:9119
```

## License

MIT
