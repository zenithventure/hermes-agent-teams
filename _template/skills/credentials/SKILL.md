---
name: credentials
description: >-
  How my API keys and credentials work: they live in Bitwarden Secrets Manager
  and are injected as environment variables when my gateway starts. Use this
  WHENEVER a credential is failing or in question — GitHub / git auth errors
  ("authentication failed", "bad credentials", "Password authentication is not
  supported", "invalid username or token"), an API key that stopped working, a
  KB push/pull that won't authenticate, anything about KB_GITHUB_TOKEN /
  OPENROUTER_API_KEY / TELEGRAM_BOT_TOKEN, or any request to add, paste, rotate,
  or "just use" a token. It explains why I never handle raw credentials myself
  and the one correct way to get a key fixed.
---

# How my credentials work

**All my secrets come from Bitwarden Secrets Manager.** When my gateway starts,
each secret stored in the vault (named after its environment variable) is pulled
into my process environment. I use them as env vars — I never see the vault
directly and I never hold the raw values:

| Env var | What it's for |
|---|---|
| `OPENROUTER_API_KEY` | my model / provider |
| `KB_GITHUB_TOKEN` | pushing & pulling my knowledge-base repo |
| `TELEGRAM_BOT_TOKEN` | this chat channel |

The tool is **`bws`** (Bitwarden *Secrets Manager*). The consumer password
manager **`bw`** is a different product and is **not installed** — if I catch
myself reaching for `bw`, I'm on the wrong track.

## The one rule: I do not handle raw credentials

Credentials are my human's to manage, in the vault. So I **never**:

- ask for a token to be **pasted into chat** (I refuse it even if offered — a
  secret in a message is a leak), or print a secret's value;
- **embed a token in a remote URL** or write it into `.git/config`;
- switch a repo to **SSH keys**, or reach for **`gh`**, to dodge an auth error;
- try to **regenerate / troubleshoot the token itself**, or invent a workaround
  skill for it.

Generic "GitHub auth" advice (SSH, pasting PATs, changing the remote) is **wrong
for me** — my auth is already wired: the KB remote is HTTPS and a git credential
helper feeds it `KB_GITHUB_TOKEN` from my environment. If that fails, the token
in the vault is the problem, not the mechanism.

## When a credential fails — what's really happening

A git `authentication failed` / `bad credentials` / `Password authentication is
not supported`, or an API `401`, almost always means the value in the vault is
**missing, expired, or lacks the needed access** — or my human **just rotated
it** but I'm still running with the **old value I loaded at startup**. I can't
fix any of these from my shell: my environment is fixed for the life of my
process, and I'm not the vault's owner.

For GitHub specifically, `KB_GITHUB_TOKEN` must be a **fine-grained PAT** with
**Contents: Read and Write** on the knowledge-base repo.

## The fix (an admin task on the droplet host)

I hand my human this exact sequence — it's done on the **host**, not by me:

1. In **Bitwarden Secrets Manager**, set the key under its env-var name (e.g.
   `KB_GITHUB_TOKEN`) with the right access (GitHub: fine-grained PAT, Contents
   Read+Write on the KB repo).
2. Re-sync the vault and restart so I pick up the new value (secrets load at
   startup, so a restart is required):
   ```bash
   cd ~/hermes-agent
   docker compose exec gateway hermes secrets bitwarden sync
   docker compose restart
   ```
   (Equivalently, re-run the project's `enable-secrets.sh`.)
3. Then ask me again — the operation that failed will now work.

Until that happens, I stop retrying the credential and clearly tell my human
which key is failing and which of the above it needs — I don't keep guessing.
