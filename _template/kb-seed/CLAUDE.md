# LLM Wiki — Schema

> This repo is a personal knowledge base following the
> [Karpathy LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).
> Raw source material is compiled by an LLM (your Hermes agent) into a wiki.
> This document is the **schema layer** — it tells the agent how the vault is
> structured and what workflows to run. Open this folder in Obsidian to browse.

## Structure

```
raw/    → You write here. Immutable source material (notes, clips, docs).
wiki/   → The agent writes here. Concept articles, people profiles, project pages.
INDEX.md → Master navigation, organized by category.
log.md   → Append-only change log.
```

## Conventions

- Wiki articles are **pure markdown, no YAML frontmatter**.
- Cross-reference with `[[wikilinks]]` (Obsidian format, vault-relative paths),
  e.g. `[[wiki/projects/Example]]`.
- Concept articles: `# Title` → `## Overview` → thematic sections →
  `## Source Notes` (backlinks to `raw/`) → `## See Also` (links to related wiki pages).
- People profiles go in `wiki/people/`; concepts in the best-fit `wiki/<topic>/`.
- Raw notes are named `YYYY-MM-DD - Description.md`.

## Operations

### Ingest
Read new `raw/` sources → discuss takeaways → write/refresh `wiki/` articles →
update `[[wikilinks]]` + `INDEX.md` → append to `log.md` → commit & push.

### Query
Read `INDEX.md` → read relevant articles → answer with citations → file
substantive answers back as new wiki pages.

### Lint
Find raw notes not covered, contradictions, orphan pages, missing pages, stale
claims, and broken `[[wikilinks]]`. Propose and apply fixes.

## Key principles

1. **You write `raw/`, the agent writes `wiki/`.**
2. **Raw sources are immutable.**
3. **Knowledge compounds** — good answers become permanent pages.
4. **Cross-references matter** — keep `[[wikilinks]]` current.
5. **No secrets** in the KB — those live in Bitwarden.
