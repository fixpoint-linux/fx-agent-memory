# fx-agent-memory

A knowledge-graph memory store for agents, exposed as a CLI. Entities, free-form
observations, and typed edges are stored in a **datalog-dafsa** database
directory, driven directly through the C FFI (`dl.h`, `libdatalog.so`) — no
sqlite, no shelling out to a `dl` binary.

It is the **durable** cross-agent context record (the asynchronous graph that
outlives any single run), the complement to the transient real-time channel in
[`fx-agent-bus`](../fx-agent-bus).

## What it stores

On top of the datalog engine's built-ins (`edge`, `observation`, `rev`) it adds:

- `entity(name, entity_type)` — nodes with a kind
- `entity_ts(entity, created_at, updated_at)` — ISO-8601 UTC timestamps
- `obs_ts(entity, content, created_at)` — per-observation timestamps

All columns are interned text symbols. Writes are transactionally wrapped
(create / add-obs / relate / del-rel share one interner save + one `fsync` per
command). Every entity carries a system-managed CAS revision counter.

## Build

Requires Zig 0.16 and a built `libdatalog.so` (and its `dl.h`/`index.h`) from a
sibling `../datalog-dafsa` checkout.

```sh
zig build            # builds fx-agent-memory + fx-agent-gardener
zig build test       # unit tests
```

The default target is the portable baseline CPU so binaries run on hosts without
AVX2/BMI (e.g. the virgin-media VM host). Binaries use an `$ORIGIN` rpath to find
`libdatalog.so` / `libembed.so` next to the installed executable.

## fx-agent-memory

```sh
fx-agent-memory [--db <dir>|-d <dir>] <command> [args]

  create <name> [--type TYPE]
  add-obs <name> <content> [<content>...]
  relate --from A --to B --type REL
  read <name> [<name>...]
  graph
  traverse <start> [depth] [--max-nodes N]
  search "<terms>" [--top N]
  vsearch "<query>" [--k N] [--radius R]   # semantic search over observation content
  recent [--hours N] [--limit N] [--max-obs N]
  similar <name> [--threshold F]
  delete <name> [<name>...]
  del-obs <name> <content> [<content>...]
  del-rel --from A --to B --type REL
  rev <name>                               # show CAS revision
  count [<rel>]
  query <source-or-file> <goal_rel>        # run arbitrary Datalog rules, print goal tuples
  import <file.jsonl>                      # bulk-load NDJSON entities/observations/relations
```

**DB path precedence:** `--db` flag → `$FX_AGENT_MEMORY_DB` →
config file → `$JING_MEMORY_DB` → `~/.jing/memory.dl`. The config file is
`$FX_AGENT_MEMORY_CONFIG` or `$XDG_CONFIG_HOME/hax/fx-agent-memory` (falling back
to `~/.config/hax/fx-agent-memory`); its first non-empty, non-comment line is the
DB directory.

**Concurrency:** writers open with a single-writer lock (`dl_open`, retried ~50×
at 0.1s). Read-only commands (`read`, `graph`, `traverse`, `recent`, `similar`,
`count`, `rev`, `query`, `vsearch`) instead open read-only (`dl_open_ro`, shared
lock) so many readers coexist and never queue behind the writer. `search` is
deliberately *not* read-only — it calls `dl_index_observations`, which writes.

**Search:**
- `search` — lexical full-text over observation content (term tokenization and
  `dl_search_top` scoring).
- `vsearch` — semantic (embedding) search over observation content via
  `libembed.so`, restricted to entities within a graph radius of the match.

## fx-agent-gardener

A deterministic memory-graph gardener implemented as native Datalog rules over
the same store. **Dry-run by default** — it only reads, so a dry run leaves the
store byte-for-byte untouched. `--apply` performs the mutations inside `dl_txn_*`
transactions with one CAS per touched entity (retry on conflict).

Tiers (order matters on apply):
1. `type_rename` — canonicalize entity types from an embedded `ctype.csv` table
2. `duplicate_pair` — normalize-name collisions
3. `candidate_pair` — shared-token overlap (minus existing edges), validated by
   an optional LLM judge before any edge is written

```sh
fx-agent-gardener [--db <dir>|-d <dir>] [--apply]
                  [--validator none|local|openapi] [--api-url <url>]
                  [--api-key <k>] [--model <m>]
                  [--min-shared <n>] [--max-candidates <n>]

  --apply             apply the plan (default: dry-run, prints would-* lines)
  --validator none    no LLM gate; candidate pairs printed only
  --validator local   Ollama /api/generate at --api-url
  --validator openapi OpenAI-compatible /chat/completions at --api-url
  --min-shared <n>    minimum shared tokens for a candidate (default 2)
  --max-candidates <n> cap on applied relations per run (default 80)
  --max-token-holders <n> skip tokens shared by >n entities (near-stopwords; default 64)
```

Dry-run a plan on a copy of the DB first; timeouts and any non-2xx or unparsable
LLM reply **reject** (the deterministic tiers alone are always safe).

## License

Part of the `fixpoint-linux` Linux-distro project. See the org-level license.
