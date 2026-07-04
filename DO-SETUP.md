# DigitalOcean setup — step by step

This is the manual version of the [Quick start](README.md#quick-start), for when
you want to understand or control each step. ~10 minutes.

## Prerequisites

- A DigitalOcean account and [`doctl`](https://docs.digitalocean.com/reference/doctl/how-to/install/)
  installed + authenticated (`doctl auth init`) on your machine.
- An SSH key in your DO account (`doctl compute ssh-key list`).
- A [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/)
  project (free tier is fine) — or skip it and use the `openai-codex` zero-key path first.
- A GitHub repo (empty is fine) for your agent's knowledge base.

## Step 1 — Create the droplet

```bash
./create-droplet.sh --name hermes-1
```

Uses `s-1vcpu-2gb` by default. **2 GB is the floor** — the Hermes image build
runs out of memory on 1 GB. Prints the droplet IP.

## Step 2 — Harden + install Hermes (as root)

```bash
ssh root@<ip> 'curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/bootstrap.sh | bash'
```

This:
- hardens the box — UFW (SSH only; the dashboard is localhost), fail2ban, SSH
  key-only, an admin `zuser-XXXX` account, 2 GB swap;
- installs Docker + the compose plugin;
- clones `hermes-agent`, builds the image, and brings up the stack (`gateway` +
  `dashboard`) as the `hermes` user.

The gateway is up but has no model or agent yet — that's step 4.

> You can combine steps 1–2 with `./create-droplet.sh --name hermes-1 --bootstrap`.

## Step 3 — Set up secrets in Bitwarden

In the Bitwarden web app (Secrets Manager):

1. Create a **project** (note its UUID).
2. Add your keys as **secrets named after their env vars** — e.g.
   `ANTHROPIC_API_KEY`, and later `TELEGRAM_BOT_TOKEN` if you add a channel.
3. Create a **machine account** with **Read** access to the project.
4. Generate an **access token** for it (starts with `0.`).

You'll pass the token + project UUID to the installer. Nothing else touches the box.

> **Zero-key first run:** skip this and set `provider: openai-codex` in your
> agent's `config.yaml`. There's no API key — you do a one-time OAuth login on the
> droplet after install (the installer prints the command). Add Bitwarden when you
> add an API-key provider or a messaging channel.

## Step 4 — Install your agent (as the hermes user)

```bash
ssh root@<ip>
sudo -u hermes -i
curl -fsSL https://raw.githubusercontent.com/zenithventure/hermes-agent-teams/main/install-agent.sh \
  | bash -s -- --agent _template \
      --bws-token 0.<token> --bws-project <uuid> \
      --kb-repo git@github.com:<you>/<kb-repo>.git
```

This seeds the agent (`SOUL.md`, memories, skills), writes only the bootstrap
token to `~/.hermes/.env` (0600), sets up the knowledge base, and restarts the stack.

**Add the printed deploy key** to your knowledge-base repo (GitHub → the repo →
Settings → Deploy keys → Add, and **check "Allow write access"**), then re-run the
installer so it can push the seed.

If you chose `openai-codex`, run the OAuth command the installer prints:

```bash
cd ~/hermes-agent && docker compose exec gateway \
  hermes auth add openai-codex --type oauth --no-browser --manual-paste
# open the URL, approve with ChatGPT Plus, paste the failed callback URL back
docker compose restart
```

## Step 5 — Verify

```bash
cd ~/hermes-agent
docker compose exec gateway hermes secrets bitwarden status   # keys resolve from Bitwarden
docker compose exec -T gateway hermes -z "say hello"          # model replies
ls ~/.hermes/workspace/kb                                     # raw/ wiki/ INDEX.md log.md CLAUDE.md
```

Open the knowledge-base repo in Obsidian on your laptop (via the `obsidian-git`
plugin) to browse what the agent knows.

## Customize

Author your own agent from [`_template/`](_template/) — copy it, edit
`config.yaml` / `SOUL.md` / `memories/USER.md`, add skills, and re-run
`install-agent.sh --agent <name>`. See [CLAUDE.md](CLAUDE.md).

## Teardown

```bash
doctl compute droplet delete hermes-1 --force
```
