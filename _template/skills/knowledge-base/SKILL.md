---
name: knowledge-base
description: >-
  Maintain a personal knowledge base as a markdown wiki (the Karpathy LLM Wiki
  pattern). Use whenever the user adds source material, asks a question that the
  wiki should answer or that produces a durable insight, or asks to tidy/audit
  the knowledge base. The KB lives at workspace/kb/ and is backed by a GitHub repo.
---

# Knowledge Base — an LLM Wiki

You maintain a knowledge base for your human: a plain-markdown **wiki** at
`workspace/kb/`, backed by a GitHub repo (so they can open the same files in
Obsidian). It follows Andrej Karpathy's LLM-wiki pattern: **the user writes
`raw/`, you write `wiki/`.**

## Layout

```
workspace/kb/
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
cd workspace/kb
git add -A && git commit -m "kb: <short summary>" && git push
```

A cron/heartbeat also pushes periodically, so no knowledge is lost if the
droplet dies. Never commit secrets to the KB.

## Guardrails

- **Raw sources are immutable** — never modify files under `raw/`.
- **The user rarely edits `wiki/` by hand** — that's your job.
- **No secrets in the wiki.** Keys and tokens live in Bitwarden, not here.
