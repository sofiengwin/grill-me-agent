# grill-me-agent — Implementation Plan

A langchainrb showcase: a CLI research agent that, given a list of soccer
clubs, produces structured JSON describing every player who played for each
club in the last 20 years.

This document captures the design decisions made during scoping, the project
layout, and a phased build plan. It is the source of truth for `prompt.md`.

## 1. Goal and framing

- **Type**: showcase of `langchainrb`, not a production research tool.
  Architecture optimizes for visible, defensible agent reasoning over
  minimum cost.
- **Deliverable**: a Bundler-managed Ruby CLI (`bin/grill-me`) that reads a
  list of clubs from a file and writes one JSON file per club to a
  configurable output directory.

## 2. Decisions (settled)

| # | Decision | Choice |
|---|---|---|
| 1 | Project shape | Bundler CLI, `bin/grill-me`, `lib/grill_me/` |
| 2 | Input | File path; `.txt` (one name per line) or `.yml`/`.json` rows of `{name, country}`; positional args fallback |
| 3 | Output | One JSON file per club, `out/<slug>.json` |
| 4 | LLM | OpenAI `gpt-4o-mini` default; pluggable factory for Anthropic later |
| 5 | Data sources | Hybrid: Wikipedia + Wikidata SPARQL primary, Brave Search API web search as fallback, Wikipedia/web fetch tool. **No Transfermarkt scraping.** |
| 6 | "Last 20 years" | Player included if tenure overlaps the 20-year window AND senior-team `appearances >= 1`. Dynamic "now" with `--as-of YYYY-MM-DD` override. |
| 7 | Agent shape | Map-reduce: **Roster Agent** (per club) → **Player Agent** (per player, parallel) → plain-Ruby **Assembler**. Max iterations: roster 15, player 8. Roster sanity cap 250 players. Per-club timeout 10 min. |
| 8 | Concurrency | Sequential clubs; parallel players within a club via `Concurrent::FixedThreadPool`. Default `--concurrency 5`. **Brave Search free tier is 1 query/sec** — `web_search` tool is gated by a global token-bucket limiter (1 qps default, configurable via `GRILL_ME_BRAVE_QPS`). |
| 9 | Observability | Tagged stderr stream (`[arsenal/roster] tool_call ...`) + per-agent `.jsonl` transcripts under `out/<slug>/_traces/`. `--quiet` / `--verbose` flags. LangSmith deferred. |
| 10 | Caching | Filesystem cache of tool results and LLM responses under `.cache/`. Keyed by `sha256(canonicalized_inputs)`. `--no-cache`, `--refresh-cache` flags. Default temperature `0`. Trace events tagged `cached: true|false`. |
| 11 | Errors | Retry transient HTTP/LLM (3 attempts, exponential backoff) and JSON-schema validation failures (2 corrective retries). Per-unit isolation: failed player → `failed_players[]`; failed roster → `out/<slug>.error.json`. `--force` overrides skip-if-exists. `--retry-failed` reruns just `failed_players`. |
| 12 | Testing | RSpec. Unit tests for tools/assembler/schema/trace/cache/CLI. VCR cassettes for HTTP. LLM replay reuses the cache. One E2E smoke test. Live tests gated on `LIVE=1`. Evals deferred. |
| 13 | Output schema | Per-stint rows. Variable-precision date strings (`"1999"`, `"1999-08"`, `"1999-08-03"`). `null` for missing fields. Mandatory `confidence` + `sources[]` per player. Hard schema validation via `json_schemer`. |
| 14 | Ruby & gems | Ruby 3.3.x. `langchainrb ~> 0.19`, `ruby-openai ~> 7.4` (verify against langchainrb 0.19), `faraday ~> 2.9`, `faraday-retry ~> 2.2`, `nokogiri ~> 1.16`, `wikipedia-client ~> 1.17`, `sparql-client ~> 3.3`, `concurrent-ruby ~> 1.3`, `thor ~> 1.3`, `json_schemer ~> 2.3`. Dev: `rspec`, `vcr`, `webmock`, `rubocop`, `pry`. |
| 15 | Config | Env vars only. Layered: CLI flag > `GRILL_ME_*` env var > built-in default. Required keys (`OPENAI_API_KEY`, `BRAVE_SEARCH_API_KEY`) validated at startup. **No `.env` file, no YAML config.** |
| 16 | Prompts | ERB-templated Markdown under `lib/grill_me/prompts/`. `version:` field at the top of each file; trace records `prompt_version`. |

## 3. Project layout

```
.
├── bin/
│   └── grill-me                    # Thor entrypoint
├── lib/
│   └── grill_me/
│       ├── version.rb
│       ├── cli.rb                  # Thor commands: research, retry-failed, clear-cache
│       ├── config.rb               # CLI > env > defaults
│       ├── runner.rb               # orchestrates clubs and concurrency
│       ├── llm.rb                  # provider/model factory
│       ├── cache.rb                # filesystem KV for tools + LLM
│       ├── trace.rb                # stderr formatter + .jsonl writer
│       ├── schema.rb               # JSON Schema loader + validator
│       ├── assembler.rb            # merges roster + player results into the per-club artifact
│       ├── window.rb               # 20-year overlap filter, as-of handling
│       ├── input.rb                # club list parser (txt/yml/json/positional)
│       ├── output.rb               # per-club file writer, skip-if-exists, retry-failed
│       ├── agents/
│       │   ├── roster_agent.rb     # Langchain::Assistant wrapper
│       │   └── player_agent.rb     # Langchain::Assistant wrapper
│       ├── tools/
│       │   ├── wikipedia_search.rb
│       │   ├── wikipedia_page.rb
│       │   ├── wikidata_sparql.rb
│       │   ├── web_search.rb       # Brave Search API REST
│       │   └── web_fetch.rb        # Faraday + Nokogiri readability
│       ├── prompts/
│       │   ├── roster_agent.md.erb
│       │   └── player_agent.md.erb
│       └── schemas/
│           └── club.schema.json
├── spec/
│   ├── spec_helper.rb              # VCR + WebMock + cache fixture wiring
│   ├── fixtures/
│   │   ├── cassettes/              # VCR HTTP cassettes
│   │   └── llm_cache/              # committed LLM replay records
│   ├── unit/                       # tools, assembler, schema, trace, cache, cli, window
│   ├── integration/                # agents driven against cassettes + llm_cache
│   ├── live/                       # gated on LIVE=1, regenerates cassettes
│   └── e2e/                        # one smoke test running the binary
├── Gemfile
├── Gemfile.lock
├── .ruby-version                   # 3.3.x
├── .rubocop.yml
├── .gitignore                      # .cache/, out/, *.local
├── PLAN.md                         # this file
└── prompt.md                       # original task brief
```

## 4. Output schema (canonical)

`lib/grill_me/schemas/club.schema.json` validates this shape. See PLAN
section 2 row 13 for design notes.

```json
{
  "schema_version": "1.0",
  "club": { "name": "Arsenal", "country": "England", "league": "Premier League",
            "wikidata_id": "Q9617", "wikipedia_url": "https://..." },
  "as_of": "2026-05-07",
  "window_years": 20,
  "researched_at": "2026-05-07T12:34:56Z",
  "status": "complete",
  "counts": { "success": 167, "failed": 3 },
  "players": [
    { "name": "Thierry Henry", "wikidata_id": "Q5582",
      "wikipedia_url": "https://...", "club_name": "Arsenal",
      "club_league": "Premier League", "club_country": "England",
      "start": "1999-08-03", "end": "2007-06-22", "appearances": 254,
      "confidence": "high", "sources": ["https://..."] }
  ],
  "failed_players": [ { "name": "...", "reason": "max_iterations_reached" } ]
}
```



## 5. End-to-end flow

```
bin/grill-me research clubs.yml --out out/ --concurrency 5
        │
        ▼
   CLI (Thor) ── Config ── validate env keys ── parse input ── build Runner
        │
        ▼
   Runner (sequential over clubs)
        │
        ├── skip if out/<slug>.json exists (unless --force)
        │
        ├── ROSTER AGENT (Langchain::Assistant)
        │     tools: wikipedia_search, wikipedia_page, wikidata_sparql,
        │            web_search
        │     output: [{ name, wikidata_id?, wikipedia_url? }, ...]
        │     traces: out/<slug>/_traces/roster.jsonl
        │
        ├── Window filter (last 20y overlap, drops obvious non-matches)
        │
        ├── Thread pool (concurrency=5)
        │     for each candidate player:
        │         PLAYER AGENT (Langchain::Assistant)
        │           tools: wikipedia_page, wikidata_sparql, web_search,
        │                  web_fetch
        │           output: one player record matching schema (or failure)
        │           traces: out/<slug>/_traces/player-<slug>.jsonl
        │
        ├── Assembler: drop window-misses, validate schema, build artifact
        │
        └── write out/<slug>.json (or out/<slug>.error.json on roster failure)
```

## 6. Tool contracts (Langchain tool I/O)

| Tool | Input | Output | Notes |
|---|---|---|---|
| `wikipedia_search` | `query: String` | `[{ title, snippet, url }]` (top 5) | MediaWiki opensearch API |
| `wikipedia_page` | `title: String` | `{ title, url, summary, sections: [{heading, text}], infobox: {...} }` | Truncated to ~12k chars |
| `wikidata_sparql` | `sparql: String` | `[{ var: value, ... }]` rows | Hard-cap 500 rows; 30s timeout |
| `web_search` | `query: String, max_results: Int = 5` | `[{ title, url, snippet }]` | Brave Search API REST; throttled to `GRILL_ME_BRAVE_QPS` (default 1) |
| `web_fetch` | `url: String` | `{ url, title, text }` | Nokogiri readability extract; ~12k chars |

All tool calls flow through `Cache` (read-through) and `Trace`
(emit `tool_call` + `tool_result` events with `cached:` flag and latency).

## 7. Build phases (implementation order)

Each phase ends with green tests for what it added. Earlier phases are
runnable end-to-end as soon as the placeholder agents are in place.

1. **Skeleton** — Gemfile, `.ruby-version`, `bin/grill-me`, `lib/grill_me/version.rb`, Thor CLI with `research` subcommand stub, RSpec set up, RuboCop config, `.gitignore`.
2. **Config + input + output plumbing** — `Config`, `Input` (parses txt/yml/json/positional), `Output` (per-club file writer, skip-if-exists, slug rules), schema + `json_schemer` validator. Unit tests.
3. **Trace + Cache** — `Trace` (stderr formatter + jsonl writer, agent-tagged), `Cache` (filesystem KV with TTL, canonicalized keys). Unit tests including a fake clock.
4. **Tools** — implement all five tools as plain Ruby classes wrapping the relevant clients/HTTP. Each tool has its own unit test with WebMock stubs and a VCR cassette. Tools auto-register with `Trace` and `Cache`.
5. **LLM factory** — `Llm.build(provider:, model:, temperature:)`. OpenAI implementation. Uniform `chat(messages:, tools:)` interface that goes through the LLM cache.
6. **Roster Agent** — `Langchain::Assistant` wired to the four discovery tools. ERB prompt. Returns parsed JSON list. Schema validation + corrective retry on bad JSON. Integration test against committed cassettes + LLM replay for one club (Arsenal).
7. **Player Agent** — same structure, four enrichment tools. Returns one player record. Integration test for a known player (Henry).
8. **Runner + Assembler** — sequential clubs, parallel players via `Concurrent::FixedThreadPool`. Window filter, failure isolation, retry-failed mode, `--force`. Integration test that runs the full per-club pipeline against fixtures.
9. **CLI polish** — `--quiet`/`--verbose`, `--no-cache`/`--refresh-cache`, `--as-of`, `--concurrency`, `--out`, `--model`, `--retry-failed`, `--force`. `clear-cache` subcommand. Friendly startup error for missing env keys.
10. **E2E smoke + live regeneration script** — `spec/e2e/` runs the binary against a 1-club, 3-player slice using cassettes + LLM cache. `bin/regenerate-cassettes` for refreshing recordings under `LIVE=1`.

## 8. Open questions / deferred

- Anthropic provider in `Llm.build`. Gated until first concrete need.
- LangSmith / Langfuse trace export. Optional sink behind env vars.
- Eval suite (`bin/grill-me-eval`) comparing output to ground-truth fixtures.
- `--strict` flag for CI.
- Transfermarkt / SofaScore integrations (deliberately excluded).

## 9. Definition of done

- `bundle exec rspec` green (unit + integration + e2e).
- `bin/grill-me research spec/fixtures/clubs.yml --out tmp/out/` produces a
  schema-valid JSON file per club, with traces under `_traces/`.
- A representative trace file is human-readable and demonstrably shows the
  agent's tool-use reasoning.
