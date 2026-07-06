---
name: knowledge-base
description: >-
  Maintain the user's personal knowledge base / Obsidian vault — a markdown wiki
  (the Karpathy LLM Wiki pattern). Use for ANY request about their "vault",
  "notes", "wiki", or "knowledge base": organize/tidy/audit it, add source
  material, answer questions from it, or link notes. The vault IS the repo at
  /opt/data/workspace/kb — there is no separate local Obsidian install to find.
---

# Knowledge Base — an LLM Wiki

You maintain a knowledge base for your human: a plain-markdown **wiki** at
`/opt/data/workspace/kb/`, backed by a GitHub repo (so they can open the same files in
Obsidian). It follows Andrej Karpathy's LLM-wiki pattern: **the user writes
`raw/`, you write `wiki/`.**

> **This repo IS the user's Obsidian vault.** When they say "my vault", "my
> notes", or "my knowledge base", they mean `/opt/data/workspace/kb/` — the exact
> files they open in Obsidian on their laptop. **Do not** look for a local
> Obsidian app or a `~/Documents/Obsidian Vault`; there is none on this box.

> **Always use the absolute path `/opt/data/workspace/kb/`** (and `git -C
> /opt/data/workspace/kb …`). Your shell starts in a different directory, so a
> relative `workspace/kb` resolves to a protected path and fails.

## Layout

```
/opt/data/workspace/kb/
  raw/        → immutable source material the user drops in (notes, clips, docs). NEVER edit.
  wiki/       → the compiled layer YOU write: concept articles, people profiles, project pages.
  INDEX.md    → master catalog, organized by category, one line per page.
  log.md      → append-only change log.
  CLAUDE.md   → the schema (this vault's conventions). Read it first.
```

## Conventions

- **Pure markdown, no YAML frontmatter** in wiki articles.
- Cross-reference with Obsidian `[[wikilinks]]` using vault-relative paths,
  e.g. `[[wiki/projects/Zenith]]`, and alias with `[[wiki/projects/Zenith|Zenith]]`.
- Every wiki article ends with a **## Source Notes** section linking back to the
  `raw/` files it came from, and a **## See Also** section linking related wiki pages.
- Concept article shape: `# Title` → `## Overview` → thematic sections →
  `## Source Notes` → `## See Also`.
- Put articles in the best-fit `wiki/<topic>/` subfolder; propose a new one when
  nothing fits. People go in `wiki/people/`.

## The three operations

### Ingest — when the user adds material to `raw/`

1. Read the new source(s) in `raw/`.
2. Tell the user the key takeaways.
3. Write or update wiki articles — a single source may touch several pages.
4. Update `[[wikilinks]]` across affected pages (this is the step most easily
   missed — cross-references are as valuable as the content).
5. Update `wiki/INDEX.md` (and any per-folder index).
6. Append a line to `wiki/log.md`: `- YYYY-MM-DD: <what changed>`.
7. Commit and push (see Sync).

### Query — when the user asks a question

1. Read `wiki/INDEX.md` to find the relevant pages, then read them.
2. Answer with citations back to wiki pages and `raw/` sources.
3. If the answer is substantive (a comparison, analysis, or new connection),
   offer to **file it back** into the wiki as a new page so exploration compounds.

### Lint — periodic health check (when asked, or offer proactively)

- Raw notes not yet covered by any wiki article.
- Contradictions between pages; stale claims superseded by newer sources.
- Orphan pages (nothing links to them); missing pages (concepts mentioned but
  lacking their own article); broken `[[wikilinks]]`.
- Propose fixes; apply the ones the user approves.

## Sync

After meaningful changes, persist to GitHub:

```bash
cd /opt/data/workspace/kb
git add -A && git commit -m "kb: <short summary>" && git push
```

Auth just works: the remote is HTTPS and a git credential helper reads the
`KB_GITHUB_TOKEN` env var (a GitHub PAT pulled from Bitwarden at startup) — you
never handle the token. Push after every ingest so no knowledge is lost if the
droplet dies. Never commit secrets to the KB.

## Guardrails

- **Raw sources are immutable** — never modify files under `raw/`.
- **The user rarely edits `wiki/` by hand** — that's your job.
- **No secrets in the wiki.** Keys and tokens live in Bitwarden, not here.
