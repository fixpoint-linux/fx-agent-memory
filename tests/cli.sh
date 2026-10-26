#!/usr/bin/env bash
# End-to-end CLI gates for the four CLI fixes (E, D, B, C2).
#
# Every "failing-first" case below was run against the pre-fix binary and
# FAILED there; the assertion pins the post-fix behaviour and the pre-fix
# output is quoted in the comment above it.
#
#   E  idempotent entity import (upsert) + honest errors
#   D  custom relations: declare / fact import / facts / count
#   B  WFS fallback in cmd_query when a program is unstratifiable
#   C2 integer columns are rendered, never dropped
#
# Each section gets its OWN scratch store: a query's row set (and the symbol
# ids a raw integer may collide with) must not depend on an earlier section.
# Never touches the real store.
# Usage: tests/cli.sh [path-to-fx-agent-memory]
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-${BIN:-$ROOT/zig-out/bin/fx-agent-memory}}"
if [ ! -x "$BIN" ]; then
    echo "cli.sh: no executable at $BIN (run 'zig build' first)" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fxam-cli.XXXXXX")"
unset FX_AGENT_MEMORY_CONFIG JING_MEMORY_DB
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
OUT=""   # last run's stdout
ERR=""   # last run's stderr
RC=0

# use <db-name>: point the CLI at a fresh scratch store for the next section
use() {
    export FX_AGENT_MEMORY_DB="$WORK/$1"
}

# run <want_rc> <desc> -- <cmd...>: run, capture stdout/stderr separately
run() {
    local want_rc="$1" desc="$2"
    shift 2
    [ "${1:-}" = "--" ] && shift
    OUT="$("$@" 2>"$WORK/.stderr")"
    RC=$?
    ERR="$(cat "$WORK/.stderr")"
    if [ "$RC" -ne "$want_rc" ]; then
        printf 'FAIL %s: rc=%d want %d\n  stdout: %s\n  stderr: %s\n' \
            "$desc" "$RC" "$want_rc" "$(printf '%s' "$OUT" | tr '\n' '|')" "$(printf '%s' "$ERR" | tr '\n' '|')"
        fail=$((fail + 1))
        return 1
    fi
    pass=$((pass + 1))
    return 0
}

# has <desc> <substring>: the last run's stdout must contain it
has() {
    case "$OUT" in
        *"$2"*) pass=$((pass + 1)) ;;
        *)
            printf 'FAIL %s: stdout lacks %s\n  stdout: %s\n' "$1" "$2" "$(printf '%s' "$OUT" | tr '\n' '|')"
            fail=$((fail + 1))
            ;;
    esac
}

# haserr <desc> <substring>: the last run's STDERR must contain it
haserr() {
    case "$ERR" in
        *"$2"*) pass=$((pass + 1)) ;;
        *)
            printf 'FAIL %s: stderr lacks %s\n  stderr: %s\n' "$1" "$2" "$(printf '%s' "$ERR" | tr '\n' '|')"
            fail=$((fail + 1))
            ;;
    esac
}

# hasnt <desc> <substring>: and its combined output must NOT contain it
hasnt() {
    case "$OUT$ERR" in
        *"$2"*)
            printf 'FAIL %s: output must not contain %s\n  stdout: %s\n  stderr: %s\n' \
                "$1" "$2" "$(printf '%s' "$OUT" | tr '\n' '|')" "$(printf '%s' "$ERR" | tr '\n' '|')"
            fail=$((fail + 1))
            ;;
        *) pass=$((pass + 1)) ;;
    esac
}

# eq <desc> <got> <want>
eq() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

# lines <desc> <count>: the last run's stdout must have exactly N lines
lines() {
    local n
    n="$(printf '%s' "$OUT" | grep -c '' || true)"
    eq "$1" "$n" "$2"
}

# ---------------------------------------------------------------------------
# E: idempotent entity import + honest errors
# ---------------------------------------------------------------------------
# PRE-FIX: importing a line for an entity that already exists died with
#   error: import failed: commit failed        (rc=1)
# because cmd_import always issued dl_txn_cas(name, 0, rev), and the engine
# validates the CAS at commit (DL_E_CONFLICT=2).
use db-e
run 0 "E: create the entity under test" -- "$BIN" create ent1 --type svc
printf '%s\n' '{"k":"entity","name":"ent1","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-01-01T00:00:00Z","rev":3}' >"$WORK/ent1.jsonl"
run 0 "E: first import of an existing entity" -- "$BIN" import "$WORK/ent1.jsonl"
hasnt "E: first import must not report a raw commit failure" "commit failed"
run 0 "E: second import of the same line (idempotent)" -- "$BIN" import "$WORK/ent1.jsonl"
hasnt "E: re-import must not report a raw commit failure" "commit failed"
run 0 "E: rev readback" -- "$BIN" rev ent1
eq "E: rev is the imported 3, not double-bumped" "$OUT" "3"

# a LOWER imported rev must not move the revision backwards
printf '%s\n' '{"k":"entity","name":"ent1","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-02-02T00:00:00Z","rev":2}' >"$WORK/ent1-low.jsonl"
run 0 "E: import with a lower rev" -- "$BIN" import "$WORK/ent1-low.jsonl"
run 0 "E: rev after a lower import" -- "$BIN" rev ent1
eq "E: rev unchanged by a lower import" "$OUT" "3"
# ... but the timestamps are the imported record's (upsert refreshes entity_ts)
run 0 "E: entity_ts after refresh" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
has "E: updated_at refreshed from the import" "ent1 2025-01-01T00:00:00Z 2025-02-02T00:00:00Z"

# a DIFFERENT type for an existing entity is a specific error, not a commit code
printf '%s\n' '{"k":"entity","name":"ent1","type":"other","created":"x","updated":"y","rev":9}' >"$WORK/ent1-bad.jsonl"
run 1 "E: type conflict rejected" -- "$BIN" import "$WORK/ent1-bad.jsonl"
haserr "E: type conflict names the entity" "entity 'ent1' exists with type 'svc'"
haserr "E: type conflict names the imported type" "but import declares 'other'"
haserr "E: type conflict names the line" "(line 1)"

# PRE-FIX: two imports of a rev=0 entity line left TWO entity_ts rows (a stale
# second row) — the query below returned two lines for ent2.
use db-e2
printf '%s\n' '{"k":"entity","name":"ent2","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-01-01T00:00:00Z","rev":0}' >"$WORK/ent2-a.jsonl"
printf '%s\n' '{"k":"entity","name":"ent2","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-06-06T06:06:06Z","rev":0}' >"$WORK/ent2-b.jsonl"
run 0 "E: import rev=0 entity" -- "$BIN" import "$WORK/ent2-a.jsonl"
run 0 "E: re-import rev=0 entity with a newer updated_at" -- "$BIN" import "$WORK/ent2-b.jsonl"
run 0 "E: entity_ts for the rev=0 entity" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "E: no stale second entity_ts row" 1
eq "E: entity_ts carries the newer updated_at" "$OUT" "ent2 2025-01-01T00:00:00Z 2025-06-06T06:06:06Z"

# the pre-existing record kinds still import with the SAME summary line
use db-e
printf '%s\n' '{"k":"obs","entity":"ent1","content":"hello","created":"2025-01-01T00:00:00Z"}' '{"k":"rel","from":"ent1","to":"ent1","type":"self"}' >"$WORK/mixed.jsonl"
run 0 "E: obs/rel import" -- "$BIN" import "$WORK/mixed.jsonl"
eq "E: entity/obs/rel summary line unchanged" "$OUT" "imported: 0 entities, 1 observations, 1 relations (2 total)"

# ---------------------------------------------------------------------------
# D: custom relations — declare / fact import / facts / count
# ---------------------------------------------------------------------------
use db-d
# PRE-FIX: error: unknown command 'declare' (rc=1)
run 0 "D: declare a 4-column custom relation" -- "$BIN" declare want 4
eq "D: declare reports the arity" "$OUT" "declared 'want' arity 4"
run 0 "D: declare is idempotent on the same arity" -- "$BIN" declare want 4
has "D: idempotent declare says so" "already declared with arity 4"
run 1 "D: arity mismatch is a specific error" -- "$BIN" declare want 5
haserr "D: mismatch names the declared arity" "already declared with arity 4"
haserr "D: mismatch names the requested arity" "cannot redeclare with arity 5"
run 1 "D: built-in relation names are refused" -- "$BIN" declare entity 2
haserr "D: built-in refusal names it" "is a built-in relation"
run 1 "D: the rev relation is refused" -- "$BIN" declare rev 2

# PRE-FIX: a {"k":"fact"} record was rejected as malformed JSON (the parser had
# no array support) — error: import failed: malformed JSON on line: ...
printf '%s\n' '{"k":"fact","rel":"want","cols":["a","b","c","d"]}' '{"k":"fact","rel":"want","cols":["a","b","c",9999]}' >"$WORK/want.jsonl"
run 0 "D: fact import into a declared relation" -- "$BIN" import "$WORK/want.jsonl"
has "D: fact import counts facts" "2 facts (2 total)"
run 0 "D: facts dumps the relation" -- "$BIN" facts want
eq "D: facts prints both tuples (raw int rendered)" "$OUT" "a b c d
a b c 9999"
run 0 "D: count over a custom relation" -- "$BIN" count want
eq "D: count is generic" "$OUT" "want: 2"
run 1 "D: facts on an unknown relation errors" -- "$BIN" facts nosuchrel
haserr "D: unknown relation message" "unknown relation 'nosuchrel'"

# auto-declare on first sight, with a note on stderr (never silently)
printf '%s\n' '{"k":"fact","rel":"tag","cols":["alpha",9999]}' >"$WORK/tag.jsonl"
run 0 "D: fact import auto-declares a new relation" -- "$BIN" import "$WORK/tag.jsonl"
haserr "D: auto-declare is announced" "note: declared relation 'tag' with arity 2"
run 0 "D: facts on the auto-declared relation" -- "$BIN" facts tag
eq "D: auto-declared relation round-trips" "$OUT" "alpha 9999"
run 0 "D: count on the auto-declared relation" -- "$BIN" count tag
eq "D: auto-declared count" "$OUT" "tag: 1"

# a fact whose width disagrees with the declaration is refused
printf '%s\n' '{"k":"fact","rel":"want","cols":["a","b"]}' >"$WORK/want-bad.jsonl"
run 1 "D: fact arity mismatch refused" -- "$BIN" import "$WORK/want-bad.jsonl"
haserr "D: fact arity mismatch is specific" "relation 'want' is declared with arity 4 but the fact on line 1 has 2 columns"

# the declaration is durable: every run above is a separate process, and this
# one re-reads it from the store rather than from memory
run 0 "D: declaration survives reopen" -- "$BIN" declare want 4
has "D: declaration is durable" "already declared with arity 4"

# arity 0 declares a VARIADIC relation (a real, durable engine declaration),
# but the transactional fact import cannot fill one — say so, don't leak -1
run 0 "D: variadic declaration accepted" -- "$BIN" declare log 0
printf '%s\n' '{"k":"fact","rel":"log","cols":["a"]}' >"$WORK/log.jsonl"
run 1 "D: fact import into a variadic relation is refused" -- "$BIN" import "$WORK/log.jsonl"
haserr "D: variadic refusal is specific" "relation 'log' is variadic"
run 1 "D: a relation name with ':' is refused" -- "$BIN" declare "a:b" 2
haserr "D: bad-name refusal is specific" "invalid relation name"

# ---------------------------------------------------------------------------
# B: WFS fallback for an unstratifiable program
# ---------------------------------------------------------------------------
use db-b
run 0 "B: seed entity pa" -- "$BIN" create pa --type node
run 0 "B: seed entity pb" -- "$BIN" create pb --type node
run 0 "B: seed the move edge" -- "$BIN" relate --from pa --to pb --type move
# PRE-FIX: compile error: unstratifiable program — negation (or range) through a
# recursion cycle is not supported ... then error: query failed (rc=1)
run 0 "B: cyclic negation answers via the WFS fallback" -- "$BIN" query 'win(X) :- edge(X,Y,"move"), !win(Y).' win
eq "B: the losing side of the cycle is the only answer" "$OUT" "pa"
haserr "B: the stratified diagnostic is still reported" "unstratifiable"

# a stratified program is unaffected (the fallback never runs)
run 0 "B: stratified program unchanged" -- "$BIN" query 'mv(X,Y) :- edge(X,Y,"move").' mv
eq "B: stratified output" "$OUT" "pa pb"
eq "B: no diagnostic on the stratified path" "$ERR" ""

# a genuinely broken program still fails, with today's exit code
run 1 "B: unknown predicate still fails" -- "$BIN" query 'x(R) :- nosuchpred(R,T).' x
haserr "B: failure keeps the CLI message" "error: query failed"

# ---------------------------------------------------------------------------
# C2: integer columns are rendered, never dropped
# ---------------------------------------------------------------------------
use db-c2
run 0 "C2: seed one entity" -- "$BIN" create pa --type node
# PRE-FIX: 'z(X,9999) :- entity(X,T).' printed only "pa" (the int column was
# dropped by `dl_intern_str_of(...) orelse continue`).
run 0 "C2: query with an integer column" -- "$BIN" query 'z(X,9999) :- entity(X,T).' z
eq "C2: the integer column is printed" "$OUT" "pa 9999"
# symbol columns keep rendering as text
run 0 "C2: symbol columns unchanged" -- "$BIN" query 'z(X,T) :- entity(X,T).' z
eq "C2: symbol columns still render" "$OUT" "pa node"
# a small int that collides with a live symbol id renders as that symbol: the
# documented one-space design (the u32 encoding is deliberately NOT changed).
run 0 "C2: one-space int/symbol behaviour is unchanged" -- "$BIN" query 'z(X,1) :- entity(X,T).' z
eq "C2: int 1 resolves as symbol id 1" "$OUT" "pa pa"
# no results still prints the sentinel line
run 0 "C2: empty result set" -- "$BIN" query 'z(X) :- entity(X,"zzz").' z
eq "C2: no-results sentinel" "$OUT" "(no results)"
# facts uses the same rendering policy as query
run 0 "C2: declare a relation for the facts check" -- "$BIN" declare reading 2
printf '%s\n' '{"k":"fact","rel":"reading","cols":["pa",9999]}' >"$WORK/reading.jsonl"
run 0 "C2: import a fact with a large int" -- "$BIN" import "$WORK/reading.jsonl"
run 0 "C2: facts over the int column" -- "$BIN" facts reading
eq "C2: facts prints the integer" "$OUT" "pa 9999"

# ---------------------------------------------------------------------------
# R: review-round regressions — within-file duplicates, field preservation,
#    stacked-row repair, relation-name round-trip safety
# ---------------------------------------------------------------------------
# PRE-FIX (both the original CLI and the first fix round): buffered txn ops are
# invisible to entity_type()/prefix(), so a file naming one entity twice was
# handled line by line and blew up. MEASURED on the pre-fix binary:
#   (i)   same name rev>0 twice -> error: import failed: cannot set revision for
#         'a' (line 2) rc=1 — the engine refuses a second buffered CAS on one
#         entity, so a concatenated bulk export lost EVERY row;
#   (ii)  same name rev=0 twice -> committed TWO entity_ts rows;
#   (iii) same name, two types  -> committed entity(c,t1) AND entity(c,t2).
use db-r1
printf '%s\n' \
    '{"k":"entity","name":"a","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-01-01T00:00:00Z","rev":3}' \
    '{"k":"entity","name":"a","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-02-02T00:00:00Z","rev":5}' \
    '{"k":"obs","entity":"a","content":"hello","created":"2025-01-01T00:00:00Z"}' >"$WORK/dup-rev.jsonl"
run 0 "R: duplicate name with rev>0 in one file imports" -- "$BIN" import "$WORK/dup-rev.jsonl"
hasnt "R: duplicate name does not abort the import" "cannot set revision"
eq "R: the row after the duplicate entity is committed too" "$OUT" "imported: 1 entities, 1 observations, 0 relations (2 total)"
run 0 "R: rev after the duplicate" -- "$BIN" rev a
eq "R: rev is the highest imported rev" "$OUT" "5"
run 0 "R: entity_ts after the duplicate" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "R: exactly one entity_ts row after a duplicate" 1
eq "R: the later record's updated_at wins" "$OUT" "a 2025-01-01T00:00:00Z 2025-02-02T00:00:00Z"
run 0 "R: re-importing the duplicate file is idempotent" -- "$BIN" import "$WORK/dup-rev.jsonl"
run 0 "R: entity_ts after the idempotent re-import" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "R: still one entity_ts row" 1

use db-r2
printf '%s\n' \
    '{"k":"entity","name":"b","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-01-01T00:00:00Z","rev":0}' \
    '{"k":"entity","name":"b","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2025-03-03T00:00:00Z","rev":0}' >"$WORK/dup-rev0.jsonl"
run 0 "R: duplicate name with rev=0 imports" -- "$BIN" import "$WORK/dup-rev0.jsonl"
run 0 "R: entity_ts after the rev=0 duplicate" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "R: one entity_ts row after a rev=0 duplicate" 1
eq "R: the later updated_at wins" "$OUT" "b 2025-01-01T00:00:00Z 2025-03-03T00:00:00Z"
run 0 "R: entity rows after the rev=0 duplicate" -- "$BIN" query 'e(X,T) :- entity(X,T).' e
lines "R: one entity row after a rev=0 duplicate" 1

use db-r3
printf '%s\n' \
    '{"k":"entity","name":"c","type":"t1","created":"x","updated":"y","rev":1}' \
    '{"k":"entity","name":"c","type":"t2","created":"x","updated":"y","rev":1}' >"$WORK/dup-type.jsonl"
run 1 "R: a duplicate name with two types is refused" -- "$BIN" import "$WORK/dup-type.jsonl"
haserr "R: the refusal names the first line" "entity 'c' has type 't1' on line 1"
haserr "R: the refusal names the second line" "but type 't2' on line 2"
run 0 "R: nothing from the refused import is committed" -- "$BIN" query 'e(X,T) :- entity(X,T).' e
eq "R: no rows after the abort" "$OUT" "(no results)"

# PRE-FIX: the upsert replaced BOTH entity_ts columns from the record, so a
# re-import omitting created/updated wiped them to empty symbols
# ('x 2026-01-01T00:00:00Z' -> 'x  ').
use db-r4
run 0 "R: create the entity" -- "$BIN" create x --type svc
run 0 "R: baseline entity_ts" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
base_ts="$OUT"
printf '%s\n' '{"k":"entity","name":"x","type":"svc","rev":2}' >"$WORK/bare.jsonl"
run 0 "R: re-import omitting created and updated" -- "$BIN" import "$WORK/bare.jsonl"
run 0 "R: entity_ts after the bare re-import" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
eq "R: an omitted field never wipes the recorded one" "$OUT" "$base_ts"
run 0 "R: rev after the bare re-import" -- "$BIN" rev x
eq "R: rev still moves forward" "$OUT" "2"
printf '%s\n' '{"k":"entity","name":"x","type":"svc","updated":"2030-01-01T00:00:00Z","rev":3}' >"$WORK/upd.jsonl"
run 0 "R: re-import with only updated" -- "$BIN" import "$WORK/upd.jsonl"
run 0 "R: entity_ts after the updated-only re-import" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
has "R: created_at is preserved" "$(printf '%s' "$base_ts" | cut -d' ' -f1-2)"
has "R: updated_at is the imported value" "2030-01-01T00:00:00Z"

# PRE-FIX: only the FIRST stacked entity_ts row was deleted, so a store damaged
# by the old import bug stayed half-repaired on re-import (2 rows remained).
# The damage is reproduced through the raw fact surface, which is exactly the
# end state the pre-fix CLI produced.
use db-r5
run 0 "R: create the entity to damage" -- "$BIN" create b --type svc
printf '%s\n' '{"k":"fact","rel":"entity_ts","cols":["b","2025-01-01T00:00:00Z","2025-01-02T00:00:00Z"]}' >"$WORK/stack.jsonl"
run 0 "R: stack a second entity_ts row (damaged store)" -- "$BIN" import "$WORK/stack.jsonl"
run 0 "R: the damage is present" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "R: two stacked rows before the repair" 2
printf '%s\n' '{"k":"entity","name":"b","type":"svc","created":"2025-01-01T00:00:00Z","updated":"2030-01-01T00:00:00Z","rev":9}' >"$WORK/repair.jsonl"
run 0 "R: re-import repairs the stacked store" -- "$BIN" import "$WORK/repair.jsonl"
run 0 "R: entity_ts after the repair" -- "$BIN" query 'ts(X,C,U) :- entity_ts(X,C,U).' ts
lines "R: the repair leaves exactly one row" 1
eq "R: the surviving row is the merged one" "$OUT" "b 2025-01-01T00:00:00Z 2030-01-01T00:00:00Z"

# PRE-FIX: declare validated only empty/':' , so a name with a newline was
# accepted (rc=0), rels.txt then split into a phantom relation, and the
# declared relation VANISHED on reopen.
use db-r6
run 1 "R: a newline in a relation name is refused" -- "$BIN" declare "$(printf 'we\nird')" 2
haserr "R: the name refusal is specific" "invalid relation name"
run 1 "R: a space in a relation name is refused" -- "$BIN" declare "sp ace" 2
run 1 "R: a tab in a relation name is refused" -- "$BIN" declare "$(printf 'ta\tb')" 2
run 1 "R: a ':' in a relation name is refused" -- "$BIN" declare "a:b" 2
long252="$(head -c 252 /dev/zero | tr '\0' 'r')"
run 1 "R: a 252-byte relation name is refused" -- "$BIN" declare "$long252" 2
haserr "R: the length refusal names the limit" "must be 1-251 bytes"
long251="$(head -c 251 /dev/zero | tr '\0' 'r')"
run 0 "R: a 251-byte relation name is accepted" -- "$BIN" declare "$long251" 2
run 0 "R: the 251-byte relation round-trips through rels.txt" -- "$BIN" declare "$long251" 2
has "R: it is still declared after reopen" "already declared with arity 2"

# bulk fact import exercises the per-import arity cache (finding 5): one
# rels.txt read for the relation, not one per line
use db-r7
run 0 "R: declare a relation for the bulk import" -- "$BIN" declare bulk 2
: >"$WORK/bulk.jsonl"
i=1
while [ "$i" -le 200 ]; do
    printf '{"k":"fact","rel":"bulk","cols":["k%s",%s]}\n' "$i" "$i" >>"$WORK/bulk.jsonl"
    i=$((i + 1))
done
run 0 "R: 200 facts into one relation in one import" -- "$BIN" import "$WORK/bulk.jsonl"
has "R: all 200 facts are counted" "200 facts (200 total)"
run 0 "R: count after the bulk import" -- "$BIN" count bulk
eq "R: the bulk relation holds 200 tuples" "$OUT" "bulk: 200"

# ---------------------------------------------------------------------------
printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
