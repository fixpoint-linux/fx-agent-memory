// fx-agent-memory — a CLI knowledge-graph memory store for hax agents.
//
// Storage: a single datalog-dafsa database directory, driven directly via the
// C FFI surface in dl.h (libdatalog.so). No sqlite, no shelling out to a dl
// binary.  The engine's built-in relations do the heavy lifting:
//
//   edge(from,to,type)        arity 3  graph edges (dl_traverse)
//   observation(entity,content) arity 2 observations (dl_node_observations,
//                                     dl_index_observations)
//   rev(entity,revision)      arity 2  system-managed CAS revision counter
//
// On top of those we add our own relations:
//
//   entity(name,entity_type)       arity 2
//   entity_ts(entity,created_at,updated_at) arity 3  (ISO-8601 UTC)
//   obs_ts(entity,content,created_at)          arity 3  (ISO-8601 UTC)
//
// All columns are interned text symbols (timestamps too). Every symbol written
// comes from dl_intern_str; every symbol read via dl_prefix/dl_iter resolves
// back to text with dl_intern_str_of.
//
// Concurrency: dl_open takes a single-writer lock (returns NULL when held). We
// retry ~50x at 0.1s, printing "waiting for memory lock" once, then give up.
//
// dl_index_observations / dl_search_top are exported from libdatalog.so but
// declared in index.h (which we deliberately do not @cImport). We forward-
// declare them ourselves below. Term tokenization (split on non-alphanumeric,
// lowercase) is mirrored here from index.c.

const std = @import("std");
const l = @cImport({
    @cInclude("dl.h");
    @cInclude("stdio.h");
    @cInclude("dirent.h");
    @cInclude("dlfcn.h");
});
const dl = l;

// ---------------------------------------------------------------------------
// extern forward declarations for the index.h search entrypoints.
// ---------------------------------------------------------------------------
extern fn dl_index_observations(db: ?*anyopaque) c_long;
extern fn dl_search_top(db: ?*anyopaque, terms: [*c]const u32, n_terms: c_int, obs_ids_out: [*c]u32, scores_out: [*c]c_int, limit: c_int) c_int;
extern fn dl_query_rules_ro(db: ?*anyopaque, source: [*:0]const u8, goal_rel: [*:0]const u8, cb: ?*const fn ([*c]const u32, u8, ?*anyopaque) callconv(.c) c_int, user: ?*anyopaque) c_long;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fgets(buf: [*c]u8, n: c_int, stream: *anyopaque) [*c]u8;
extern fn fclose(stream: *anyopaque) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn time(timer: ?*c_long) c_long;
extern fn usleep(usec: c_uint) c_int;
extern fn opendir(path: [*:0]const u8) ?*l.DIR;
extern fn readdir(dir: ?*l.DIR) ?*l.struct_dirent;
extern fn closedir(dir: ?*l.DIR) c_int;
extern fn unlink(path: [*:0]const u8) c_int;
extern fn dl_txn_begin(db: ?*anyopaque) c_int;
extern fn dl_txn_add_fact(db: ?*anyopaque, rel_name: [*:0]const u8, cols: [*c]const u32, arity: u8) c_int;
extern fn dl_txn_cas(db: ?*anyopaque, entity: [*:0]const u8, expected: u32, new_value: u32) c_int;
extern fn dl_txn_commit(db: ?*anyopaque) c_int;
extern fn dl_txn_rollback(db: ?*anyopaque) c_int;

// ---------------------------------------------------------------------------
// Small typed wrapper over the opaque C handle.
// ---------------------------------------------------------------------------
const Db = *dl.dl_db;
const Alloc = std.mem.Allocator;

const Ctx = struct {
    db: Db,
    alloc: Alloc,
};

fn intern(ctx: *Ctx, s: []const u8) u32 {
    return dl.dl_intern_str(ctx.db, s.ptr);
}

// Intern a slice that is NOT NUL-terminated (e.g. a slice into a file buffer):
// dl_intern_str reads a C string, so a non-terminated slice would pull in
// trailing garbage. Copy to a sentinel buffer, intern, free.
fn internz(ctx: *Ctx, s: []const u8) u32 {
    const z = ctx.alloc.allocSentinel(u8, s.len, 0) catch die("oom", .{});
    defer ctx.alloc.free(z);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return dl.dl_intern_str(ctx.db, z.ptr);
}

// NUL-terminated copy of a slice (for C entrypoints that take `const char*`).
fn zdup(ctx: *Ctx, s: []const u8) [:0]u8 {
    const z = ctx.alloc.allocSentinel(u8, s.len, 0) catch die("oom", .{});
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return z;
}

fn declare(ctx: *Ctx, name: []const u8, arity: u8) void {
    if (dl.dl_declare_relation(ctx.db, name.ptr, arity) != 0) {
        std.debug.print("fatal: cannot declare relation '{s}'\n", .{name});
        std.process.exit(1);
    }
}

fn add_fact(ctx: *Ctx, rel: []const u8, cols: []const u32) void {
    _ = dl.dl_add_fact(ctx.db, rel.ptr, cols.ptr, @intCast(cols.len));
}

fn del_fact(ctx: *Ctx, rel: []const u8, cols: []const u32) void {
    _ = dl.dl_delete_fact(ctx.db, rel.ptr, cols.ptr, @intCast(cols.len));
}

fn rev_get(ctx: *Ctx, name: []const u8) u32 {
    var out: u32 = 0;
    _ = dl.dl_rev_get(ctx.db, name.ptr, &out);
    return out;
}

fn rev_bump(ctx: *Ctx, name: []const u8) void {
    // optimistic concurrency: reread + retry on conflict, so a concurrent
    // writer bumping the rev between our read and CAS is never lost.
    var attempts: usize = 0;
    while (true) {
        const cur = rev_get(ctx, name);
        const rc = dl.dl_cas_revision(ctx.db, name.ptr, cur, cur + 1);
        if (rc == 0) return;
        if (rc < 0) die("error: CAS revision failed for '{s}'", .{name});
        // DL_E_CONFLICT
        attempts += 1;
        if (attempts >= 50) die("error: revision conflict for '{s}'", .{name});
    }
}

fn ensure_relations(ctx: *Ctx) void {
    declare(ctx, "entity", 2);
    declare(ctx, "entity_ts", 3);
    declare(ctx, "obs_ts", 3);
    // engine graph/observation built-ins are not auto-declared in a fresh db;
    // dl_add_fact/dl_traverse error on undeclared relations.
    declare(ctx, "edge", 3);
    declare(ctx, "observation", 2);
}

// ---------------------------------------------------------------------------
// tuple enumeration helpers
// ---------------------------------------------------------------------------
const TupleBuf = std.ArrayListUnmanaged(u32);

const Collect = struct {
    buf: TupleBuf,
    alloc: Alloc,
};

fn tuple_cb(cols: [*c]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
    const c: *Collect = @ptrCast(@alignCast(user.?));
    c.buf.appendSlice(c.alloc, cols[0..arity]) catch return -1;
    return 0;
}

// Enumerate all tuples of `rel` whose first k leading columns equal `leading`
// (k==0 -> all tuples). Returns flat tuple data, count = len/arity.
fn prefix(ctx: *Ctx, rel: []const u8, leading: []const u32, k: u8) TupleBuf {
    var collect = Collect{ .buf = .empty, .alloc = ctx.alloc };
    var lead_ptr: ?[*]const u32 = null;
    if (k > 0) lead_ptr = leading.ptr;
    _ = dl.dl_prefix(ctx.db, rel.ptr, lead_ptr, k, tuple_cb, &collect);
    return collect.buf;
}

const ObsCollect = struct {
    list: std.ArrayListUnmanaged([]const u8),
    alloc: Alloc,
};

fn str_cb(s: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    const c: *ObsCollect = @ptrCast(@alignCast(user.?));
    if (s != null) c.list.append(c.alloc, std.mem.span(s)) catch return -1;
    return 0;
}

fn observations(ctx: *Ctx, node: []const u8, max_obs: i32) std.ArrayListUnmanaged([]const u8) {
    var collect = ObsCollect{ .list = .empty, .alloc = ctx.alloc };
    _ = dl.dl_node_observations(ctx.db, node.ptr, max_obs, str_cb, &collect);
    return collect.list;
}

// ---------------------------------------------------------------------------
// timestamps (ISO-8601 UTC, NUL-terminated, lexicographically orderable)
// ---------------------------------------------------------------------------
fn ts_iso_alloc(ts: i64) [:0]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrintSentinel(std.heap.c_allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        @as(u8, @intCast(md.month.numeric())),
        @as(u8, @intCast(md.day_index + 1)),
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }, 0) catch unreachable;
}

fn now_iso() [:0]u8 {
    return ts_iso_alloc(time(null));
}

// timestamp `hours` in the past (for window filtering).
fn hours_ago_iso(hours: i64) [:0]u8 {
    return ts_iso_alloc(time(null) - hours * 3600);
}

// ---------------------------------------------------------------------------
// tokenizer / trigrams
// ---------------------------------------------------------------------------
fn is_alnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

// Lowercased copy of `s`.
fn lower(alloc: Alloc, s: []const u8) []u8 {
    const d = alloc.dupe(u8, s) catch return &.{};
    for (d) |*ch| ch.* = std.ascii.toLower(ch.*);
    return d;
}

// Tokenize like index.c: split on non-alphanumeric, lowercase.
fn tokenize(alloc: Alloc, text: []const u8) std.ArrayListUnmanaged([]const u8) {
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !is_alnum(text[i])) i += 1;
        const start = i;
        while (i < text.len and is_alnum(text[i])) i += 1;
        if (i > start) {
            const tok = lower(alloc, text[start..i]);
            out.append(alloc, tok) catch {};
        }
    }
    return out;
}

// Lowercased unique trigram set of a name (for similar).
fn trigrams(alloc: Alloc, name: []const u8) std.ArrayListUnmanaged(u32) {
    const lower_str = lower(alloc, name);
    defer alloc.free(lower_str);
    var out = std.ArrayListUnmanaged(u32).empty;
    const lb = lower_str;
    if (lb.len < 3) {
        out.append(alloc, @intCast(lb.len)) catch {};
        return out;
    }
    var i: usize = 0;
    while (i + 3 <= lb.len) : (i += 1) {
        const g = lb[i .. i + 3];
        const h: u32 = @truncate(std.hash.Wyhash.hash(0, g));
        var dup = false;
        for (out.items) |e| if (e == h) { dup = true; break; };
        if (!dup) out.append(alloc, h) catch {};
    }
    return out;
}

fn trigram_similarity(alloc: Alloc, a: []const u8, b: []const u8) f64 {
    var ta = trigrams(alloc, a);
    defer ta.deinit(alloc);
    var tb = trigrams(alloc, b);
    defer tb.deinit(alloc);
    if (ta.items.len == 0 and tb.items.len == 0) return 1.0;
    var inter: usize = 0;
    for (ta.items) |x| {
        for (tb.items) |y| if (x == y) { inter += 1; break; };
    }
    return @as(f64, @floatFromInt(2 * inter)) / @as(f64, @floatFromInt(ta.items.len + tb.items.len));
}

// ---------------------------------------------------------------------------
// db open with single-writer lock retry
// ---------------------------------------------------------------------------
fn db_path_from_env() []const u8 {
    if (getenv("FX_AGENT_MEMORY_DB")) |v| return std.mem.span(v);
    if (getenv("JING_MEMORY_DB")) |v| return std.mem.span(v);
    if (config_db_path()) |p| return p;
    return "/home/arch/.jing/memory.dl";
}

// Resolve the DB path from a config file: first non-empty, non-comment line
// holds the db dir path. Config file precedence:
//   $FX_AGENT_MEMORY_CONFIG -> $XDG_CONFIG_HOME/hax/fx-agent-memory
//   -> ~/.config/hax/fx-agent-memory.
// The returned slice is allocated on the C allocator (caller keeps it for the
// process lifetime, which is fine for a CLI). Returns null if unset/unreadable.
fn config_db_path() ?[]const u8 {
    var pathbuf: [4096]u8 = undefined;
    const cfg = if (getenv("FX_AGENT_MEMORY_CONFIG")) |v| std.mem.span(v) else blk: {
        const xdg = if (getenv("XDG_CONFIG_HOME")) |v| std.mem.span(v) else "/home/arch/.config";
        const p = std.fmt.bufPrint(&pathbuf, "{s}/hax/fx-agent-memory", .{xdg}) catch return null;
        break :blk p;
    };

    var cfgz: [4096]u8 = undefined;
    @memcpy(cfgz[0..cfg.len], cfg);
    cfgz[cfg.len] = 0;
    const f = fopen(@ptrCast(&cfgz), "r") orelse return null;
    defer _ = fclose(f);

    // Read the first non-empty, non-comment line as the db path.
    var buf: [4096]u8 = undefined;
    while (true) {
        const line = fgets(@ptrCast(&buf), @intCast(buf.len), f);
        if (line == null) break; // EOF or error
        const len = std.mem.len(line);
        const n = std.mem.indexOfScalar(u8, line[0..len], '\n') orelse len;
        const s = std.mem.trim(u8, line[0..n], " \t\r");
        if (s.len == 0 or s[0] == '#') continue;
        // Copy into an owned buffer so the slice outlives the C string.
        const owned = std.heap.c_allocator.alloc(u8, s.len) catch return null;
        @memcpy(owned, s);
        return owned;
    }
    return null;
}

// mkdir -p: create every missing path component of `path`.
fn mkdir_p(path: []const u8) void {
    if (path.len == 0) return;
    const alloc = std.heap.c_allocator;
    var buf = alloc.alloc(u8, path.len + 1) catch return;
    defer alloc.free(buf);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and buf[i] != '/') continue;
        const prev = buf[i];
        buf[i] = 0;
        _ = mkdir(@ptrCast(buf.ptr), 0o755);
        buf[i] = prev;
    }
}

fn open_with_retry(path: []const u8) ?Db {
    // dl_open takes a C string (NUL-terminated).  path may be a non-sentinel
    // slice (e.g. from config_db_path's owned allocation), so copy into a
    // sentinel buffer first — otherwise C reads past the end into garbage.
    const alloc = std.heap.c_allocator;
    const pathz = alloc.alloc(u8, path.len + 1) catch return null;
    defer alloc.free(pathz);
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;

    var printed = false;
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (dl.dl_open(pathz.ptr)) |db| return db;
        if (!printed) {
            std.debug.print("waiting for memory lock\n", .{});
            printed = true;
        }
        _ = usleep(100_000);
    }
    return null;
}

// ---------------------------------------------------------------------------
// output helpers
// ---------------------------------------------------------------------------
// Human-readable output to stdout / stderr. Zig fmt strings, flushed via libc.
// Format on the heap so arbitrarily long lines (e.g. full observations) are
// never dropped — a fixed stack buffer would silently discard output >2KB.
fn emit(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return;
    defer std.heap.c_allocator.free(s);
    _ = l.fwrite(s.ptr, 1, s.len, l.stdout);
}

fn errOut(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return;
    defer std.heap.c_allocator.free(s);
    _ = l.fwrite(s.ptr, 1, s.len, l.stderr);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    errOut(fmt ++ "\n", args);
    std.process.exit(1);
}

// ---------------------------------------------------------------------------
// subcommands
// ---------------------------------------------------------------------------
fn cmd_create(ctx: *Ctx, name: []const u8, etype: []const u8) void {
    if (entity_type(ctx, name) != null) die("error: entity '{s}' already exists", .{name});

    if (dl.dl_txn_begin(ctx.db) != 0)
        die("error: cannot begin transaction", .{});
    const n = intern(ctx, name);
    const ty = intern(ctx, etype);
    const now = now_iso();
    const nowsym = intern(ctx, now[0..]);
    var ecols: [2]u32 = .{ n, ty };
    if (dl.dl_txn_add_fact(ctx.db, "entity", &ecols, 2) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: cannot add entity fact", .{});
    }
    var ts_cols: [3]u32 = .{ n, nowsym, nowsym };
    if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ts_cols, 3) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: cannot add entity_ts fact", .{});
    }
    // starts the entity at revision 1 (implicit rev row starts at 0)
    if (dl.dl_txn_cas(ctx.db, name.ptr, 0, 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{name});
    }
    if (dl.dl_txn_commit(ctx.db) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{name});
    }
    emit("created '{s}' ({s})\n", .{ name, etype });
}

fn cmd_add_obs(ctx: *Ctx, name: []const u8, contents: []const []const u8) void {
    var attempts: usize = 0;
    while (true) {
        if (dl.dl_txn_begin(ctx.db) != 0)
            die("error: cannot begin transaction", .{});

        const now = now_iso();
        const nowsym = intern(ctx, now[0..]);
        const namesym = intern(ctx, name);
        for (contents) |c| {
            const csym = intern(ctx, c);
            var ocols: [2]u32 = .{ namesym, csym };
            if (dl.dl_txn_add_fact(ctx.db, "observation", &ocols, 2) != 0) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: cannot add observation fact", .{});
            }
            var tcols: [3]u32 = .{ namesym, csym, nowsym };
            if (dl.dl_txn_add_fact(ctx.db, "obs_ts", &tcols, 3) != 0) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: cannot add obs_ts fact", .{});
            }
        }
        // one CAS bumping the revision by the number of observations (the engine
        // rejects two CAS ops on the same entity in one txn, so we can't bump
        // per-obs; a single cur -> cur+n matches the old per-obs rev_bump net).
        {
            const cur = rev_get(ctx, name);
            if (dl.dl_txn_cas(ctx.db, name.ptr, cur, cur + @as(u32, @intCast(contents.len))) != 0) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: CAS revision failed for '{s}'", .{name});
            }
        }
        // bump updated_at to now
        {
            var cur = prefix(ctx, "entity_ts", &.{namesym}, 1);
            defer cur.deinit(ctx.alloc);
            if (cur.items.len >= 2) {
                _ = dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3);
                var ucols: [3]u32 = .{ cur.items[0], cur.items[1], nowsym };
                if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ucols, 3) != 0) {
                    _ = dl.dl_txn_rollback(ctx.db);
                    die("error: cannot update entity_ts", .{});
                }
            }
        }
        const rc = dl.dl_txn_commit(ctx.db);
        if (rc == 0) return;
        _ = dl.dl_txn_rollback(ctx.db);
        if (rc < 0) die("error: commit failed", .{});
        // DL_E_CONFLICT: CAS validated at commit aborts the whole txn; retry
        // the entire body (re-read rev, re-buffer) at whole-txn granularity.
        attempts += 1;
        if (attempts >= 50) die("error: revision conflict for '{s}'", .{name});
    }
}

fn cmd_relate(ctx: *Ctx, a: []const u8, b: []const u8, rel: []const u8) void {
    var attempts: usize = 0;
    while (true) {
        if (dl.dl_txn_begin(ctx.db) != 0)
            die("error: cannot begin transaction", .{});

        const now = now_iso();
        const nowsym = intern(ctx, now[0..]);
        const asym = intern(ctx, a);
        const bsym = intern(ctx, b);
        const rsym = intern(ctx, rel);
        var ecols: [3]u32 = .{ asym, bsym, rsym };
        if (dl.dl_txn_add_fact(ctx.db, "edge", &ecols, 3) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot add edge fact", .{});
        }
        {
            var cur = prefix(ctx, "entity_ts", &.{asym}, 1);
            defer cur.deinit(ctx.alloc);
            if (cur.items.len >= 2) {
                _ = dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3);
                var ucols: [3]u32 = .{ cur.items[0], cur.items[1], nowsym };
                if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ucols, 3) != 0) {
                    _ = dl.dl_txn_rollback(ctx.db);
                    die("error: cannot update entity_ts", .{});
                }
            }
        }
        {
            var cur = prefix(ctx, "entity_ts", &.{bsym}, 1);
            defer cur.deinit(ctx.alloc);
            if (cur.items.len >= 2) {
                _ = dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3);
                var ucols: [3]u32 = .{ cur.items[0], cur.items[1], nowsym };
                if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ucols, 3) != 0) {
                    _ = dl.dl_txn_rollback(ctx.db);
                    die("error: cannot update entity_ts", .{});
                }
            }
        }
        const ra = rev_get(ctx, a);
        if (dl.dl_txn_cas(ctx.db, a.ptr, ra, ra + 1) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: CAS revision failed for '{s}'", .{a});
        }
        // self-loop (a == b): a single CAS already bumped the shared rev.
        if (!std.mem.eql(u8, a, b)) {
            const rb = rev_get(ctx, b);
            if (dl.dl_txn_cas(ctx.db, b.ptr, rb, rb + 1) != 0) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: CAS revision failed for '{s}'", .{b});
            }
        }
        const rc = dl.dl_txn_commit(ctx.db);
        if (rc == 0) return;
        _ = dl.dl_txn_rollback(ctx.db);
        if (rc < 0) die("error: commit failed", .{});
        // DL_E_CONFLICT: retry the whole transaction at whole-txn granularity.
        attempts += 1;
        if (attempts >= 50) die("error: revision conflict for '{s}'", .{a});
    }
}

fn bump_updated_at(ctx: *Ctx, name: []const u8, ts: []const u8) void {
    var cur = prefix(ctx, "entity_ts", &.{intern(ctx, name)}, 1);
    defer cur.deinit(ctx.alloc);
    if (cur.items.len >= 2) {
        del_fact(ctx, "entity_ts", cur.items[0..3]);
        add_fact(ctx, "entity_ts", &.{ cur.items[0], cur.items[1], intern(ctx, ts) });
    }
}

fn entity_type(ctx: *Ctx, name: []const u8) ?[]const u8 {
    var cur = prefix(ctx, "entity", &.{intern(ctx, name)}, 1);
    defer cur.deinit(ctx.alloc);
    if (cur.items.len >= 2) {
        return std.mem.span(dl.dl_intern_str_of(ctx.db, cur.items[1]) orelse return null);
    }
    return null;
}

fn require_entity(ctx: *Ctx, name: []const u8) void {
    if (entity_type(ctx, name) == null) die("error: entity '{s}' does not exist", .{name});
}

const Rel = struct { from: []const u8, to: []const u8, rel: []const u8 };

fn all_edges(ctx: *Ctx) std.ArrayListUnmanaged(Rel) {
    var buf = prefix(ctx, "edge", &.{}, 0);
    defer buf.deinit(ctx.alloc);
    var out = std.ArrayListUnmanaged(Rel).empty;
    var i: usize = 0;
    while (i + 3 <= buf.items.len) : (i += 3) {
        const f = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i]) orelse continue);
        const t = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i + 1]) orelse continue);
        const r = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i + 2]) orelse continue);
        out.append(ctx.alloc, .{ .from = f, .to = t, .rel = r }) catch {};
    }
    return out;
}

fn cmd_read(ctx: *Ctx, names: []const []const u8) void {
    for (names) |name| {
        const t = entity_type(ctx, name) orelse {
            emit("'{s}': (unknown entity)\n", .{name});
            continue;
        };
        emit("'{s}' ({s}) rev={d}\n", .{ name, t, rev_get(ctx, name) });
        emit("  observations:\n", .{});
        var obs = observations(ctx, name, 1024);
        defer obs.deinit(ctx.alloc);
        if (obs.items.len == 0) {
            emit("    (none)\n", .{});
        } else for (obs.items) |o| {
            emit("    - {s}\n", .{o});
        }
        emit("  relations:\n", .{});
        var found = false;
        var edges = all_edges(ctx);
        defer edges.deinit(ctx.alloc);
        for (edges.items) |e| {
            if (std.mem.eql(u8, e.from, name)) {
                emit("    {s} --{s}--> {s}\n", .{ name, e.rel, e.to });
                found = true;
            }
            if (std.mem.eql(u8, e.to, name)) {
                emit("    {s} <--{s}-- {s}\n", .{ name, e.rel, e.from });
                found = true;
            }
        }
        if (!found) emit("    (none)\n", .{});
    }
}

fn cmd_graph(ctx: *Ctx) void {
    emit("entities:\n", .{});
    var ebuf = prefix(ctx, "entity", &.{}, 0);
    defer ebuf.deinit(ctx.alloc);
    var i: usize = 0;
    while (i + 2 <= ebuf.items.len) : (i += 2) {
        const n = std.mem.span(dl.dl_intern_str_of(ctx.db, ebuf.items[i]) orelse continue);
        const t = std.mem.span(dl.dl_intern_str_of(ctx.db, ebuf.items[i + 1]) orelse continue);
        var obs = observations(ctx, n, 1024);
        defer obs.deinit(ctx.alloc);
        emit("  {s} ({s})", .{ n, t });
        if (obs.items.len > 0) {
            emit(": ", .{});
            for (obs.items, 0..) |o, idx| {
                if (idx > 0) emit(" | ", .{});
                emit("{s}", .{o});
            }
        }
        emit("\n", .{});
    }
    emit("relations:\n", .{});
    var edges = all_edges(ctx);
    defer edges.deinit(ctx.alloc);
    for (edges.items) |e| {
        emit("  {s} --{s}--> {s}\n", .{ e.from, e.rel, e.to });
    }
}

const TraverseCollect = struct {
    lines: std.ArrayListUnmanaged([2]u32),
    alloc: Alloc,
};

fn traverse_cb(node: u32, depth: u8, user: ?*anyopaque) callconv(.c) c_int {
    const c: *TraverseCollect = @ptrCast(@alignCast(user.?));
    c.lines.append(c.alloc, .{ node, depth }) catch return -1;
    return 0;
}

fn cmd_traverse(ctx: *Ctx, start: []const u8, depth: i32, max_nodes: i32) void {
    var collect = TraverseCollect{ .lines = .empty, .alloc = ctx.alloc };
    const n = dl.dl_traverse(ctx.db, start.ptr, depth, max_nodes, traverse_cb, &collect);
    defer collect.lines.deinit(ctx.alloc);
    if (n < 0) die("error: traverse failed", .{});
    for (collect.lines.items) |ln| {
        const name = std.mem.span(dl.dl_intern_str_of(ctx.db, ln[0]) orelse continue);
        emit("{d}: {s}\n", .{ ln[1], name });
    }
}

fn cmd_search(ctx: *Ctx, terms: []const u8, top: i32) void {
    _ = dl_index_observations(@ptrCast(ctx.db));
    var tokens = tokenize(ctx.alloc, terms);
    defer {
        for (tokens.items) |t| ctx.alloc.free(t);
        tokens.deinit(ctx.alloc);
    }
    if (tokens.items.len == 0) {
        die("error: no search terms", .{});
    }
    const alloced = ctx.alloc.alloc(u32, tokens.items.len) catch die("oom", .{});
    defer ctx.alloc.free(alloced);
    for (tokens.items, 0..) |t, idx| alloced[idx] = intern(ctx, t);

    const obs_out = ctx.alloc.alloc(u32, @intCast(top)) catch die("oom", .{});
    defer ctx.alloc.free(obs_out);
    const scores_out = ctx.alloc.alloc(c_int, @intCast(top)) catch die("oom", .{});
    defer ctx.alloc.free(scores_out);

    const rc = dl_search_top(@ptrCast(ctx.db), alloced.ptr, @intCast(tokens.items.len), obs_out.ptr, scores_out.ptr, top);
    if (rc < 0) die("error: search failed", .{});
    var i: c_int = 0;
    while (i < rc) : (i += 1) {
        const content = std.mem.span(dl.dl_intern_str_of(ctx.db, obs_out[@intCast(i)]) orelse continue);
        emit("{s}\n", .{content});
    }
}

// Allocate a null-terminated copy of `s` (Zig 0.16's allocSentinel does NOT
// copy on the c_allocator — it returns the poisoned buffer — so copy manually).
fn sentinel(alloc: Alloc, s: []const u8) [:0]u8 {
    const z = alloc.allocSentinel(u8, s.len, 0) catch die("oom", .{});
    if (s.len > 0) @memcpy(z[0..s.len], s[0..s.len]);
    return z;
}

// ---------------------------------------------------------------------------
// vsearch: semantic search over observation CONTENT via the vector tier.
// ---------------------------------------------------------------------------

// Candidate collector callback for dl_vector_search_corpus.
const CandCollect = struct { syms: std.ArrayListUnmanaged(u32) };

fn vec_cand_cb(sym: u32, score: c_int, user: ?*anyopaque) callconv(.c) c_int {
    _ = score;
    const c: *CandCollect = @ptrCast(@alignCast(user orelse return 1));
    c.syms.append(std.heap.c_allocator, sym) catch return 1;
    return 0;
}

// Result printer callback for dl_vector_rerank_corpus.
const CtxPrint = struct { ctx: *Ctx };

fn vec_res_cb(sym: u32, score: c_int, user: ?*anyopaque) callconv(.c) c_int {
    _ = score;
    const p: *CtxPrint = @ptrCast(@alignCast(user orelse return 1));
    const content = std.mem.span(dl.dl_intern_str_of(p.ctx.db, sym) orelse return 1);
    emit("{s}\n", .{content});
    return 0;
}

// Resolve libembed.so: env override, else next to this executable (via
// /proc/self/exe), else the bare name (rpath/LD_LIBRARY_PATH).  The encoder is
// dlopen'd at runtime — never linked at build time.
fn libembed_path(buf: []u8) []const u8 {
    if (getenv("FX_AGENT_MEMORY_LIBEMBED")) |v| {
        const s = std.mem.span(v);
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    var self: [4096]u8 = undefined;
    const n = std.os.linux.readlink("/proc/self/exe", &self, self.len);
    if (n == 0 or n >= self.len) return "libembed.so";
    var end = n;
    while (end > 0 and self[end - 1] != '/') end -= 1;
    const dir = self[0..end];
    if (dir.len + "libembed.so".len >= buf.len) return "libembed.so";
    @memcpy(buf[0..dir.len], dir[0..dir.len]);
    @memcpy(buf[dir.len..][0.."libembed.so".len], "libembed.so");
    return buf[0 .. dir.len + "libembed.so".len];
}

// dlopen libembed.so lazily on first use; return the encoder symbol.
// dl_embed_encode_query is exported from libembed.so (a C++ shared lib, loaded
// at runtime via dlopen — never linked at build time).
const EncodeQueryFn = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*c]u32, [*c]u32, [*c]u8, usize) callconv(.c) c_int;

fn embed_encode_fn() EncodeQueryFn {
    var pb: [4096]u8 = undefined;
    const path = libembed_path(&pb);
    const pbuf = std.heap.c_allocator.alloc(u8, path.len + 1) catch die("oom", .{});
    defer std.heap.c_allocator.free(pbuf);
    @memcpy(pbuf[0..path.len], path[0..path.len]);
    pbuf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(pbuf.ptr);
    const handle = l.dlopen(path_z, l.RTLD_NOW) orelse {
        const msg = if (l.dlerror()) |e| std.mem.span(@as([*:0]const u8, @ptrCast(e))) else "?";
        die("error: libembed.so dlopen failed (tried '{s}'): {s}", .{ path, msg });
    };
    const sym = l.dlsym(handle, "dl_embed_encode_query") orelse {
        die("error: libembed.so missing dl_embed_encode_query symbol", .{});
    };
    return @ptrCast(@alignCast(sym));
}

fn cmd_vsearch(ctx: *Ctx, query: []const u8, k: c_int, radius: c_int, dbdir: []const u8) void {
    // guard: content vector index must exist.
    const n_vec = dl.dl_count(ctx.db, "__vec_obs__");
    if (n_vec == 0 or n_vec == std.math.maxInt(u64))
        die("error: no observation vector index — run the content pipeline first", .{});

    // encode the query in-process via the dlopen'd encoder.
    const encode = embed_encode_fn();
    var sig: [8]u32 = undefined;
    var ivec: [96]u32 = undefined;
    const dbdir_z = sentinel(ctx.alloc, dbdir);
    defer ctx.alloc.free(dbdir_z);
    const query_z = sentinel(ctx.alloc, query);
    defer ctx.alloc.free(query_z);
    var errbuf: [512:0]u8 = undefined;
    const rc = encode(dbdir_z.ptr, "_obs", query_z.ptr, &sig, &ivec, &errbuf, errbuf.len);
    if (rc != 0) die("error: {s}", .{std.mem.sliceTo(@as([*:0]const u8, &errbuf), 0)});

    // content corpus descriptor (built in Zig — the C macros don't translate).
    const corpus = dl.struct_dl_vec_corpus{
        .filter_rel = "observation",
        .filter_col = 1,
        .sig_rel_fmt = "__obssig%d__",
        .vec_rel = "__vec_obs__",
        .basis_suffix = "_obs",
    };

    // (1) candidate retrieval.
    var collect = CandCollect{ .syms = .empty };
    defer collect.syms.deinit(ctx.alloc);
    const n_cand = dl.dl_vector_search_corpus(ctx.db, &corpus, &sig, k * 10, radius, vec_cand_cb, &collect);
    if (n_cand < 0) die("error: vector search failed", .{});
    if (n_cand == 0) return;

    // (2) int8 cosine re-rank.
    const cands = collect.syms.items;
    var pr = CtxPrint{ .ctx = ctx };
    _ = dl.dl_vector_rerank_corpus(ctx.db, &corpus, &ivec, cands.ptr, @intCast(cands.len), k, vec_res_cb, &pr);
}

const SimResult = struct { name: []const u8, sim: f64 };
const RecentRow = struct { entity: []const u8, updated: []const u8, created: []const u8 };

fn cmd_similar(ctx: *Ctx, name: []const u8, threshold: f64) void {
    var ebuf = prefix(ctx, "entity", &.{}, 0);
    defer ebuf.deinit(ctx.alloc);
    var results = std.ArrayListUnmanaged(SimResult).empty;
    var i: usize = 0;
    while (i + 2 <= ebuf.items.len) : (i += 2) {
        const n = std.mem.span(dl.dl_intern_str_of(ctx.db, ebuf.items[i]) orelse continue);
        if (std.mem.eql(u8, n, name)) continue;
        const sim = trigram_similarity(ctx.alloc, name, n);
        if (sim >= threshold) results.append(ctx.alloc, .{ .name = n, .sim = sim }) catch {};
    }
    std.mem.sort(SimResult, results.items, {}, struct {
        fn lt(_: void, a: @TypeOf(results.items[0]), b: @TypeOf(results.items[0])) bool {
            if (a.sim == b.sim) return a.name.len < b.name.len;
            return a.sim > b.sim;
        }
    }.lt);
    var count: usize = 0;
    for (results.items) |r| {
        if (count >= 20) break;
        emit("{d:.3} {s}\n", .{ r.sim, r.name });
        count += 1;
    }
    results.deinit(ctx.alloc);
}

fn cmd_recent(ctx: *Ctx, hours: i64, limit: usize, max_obs: usize) void {
    const cutoff = hours_ago_iso(hours);
    var buf = prefix(ctx, "entity_ts", &.{}, 0);
    defer buf.deinit(ctx.alloc);
    var rows = std.ArrayListUnmanaged(RecentRow).empty;
    var i: usize = 0;
    while (i + 3 <= buf.items.len) : (i += 3) {
        const e = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i]) orelse continue);
        const created = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i + 1]) orelse continue);
        const updated = std.mem.span(dl.dl_intern_str_of(ctx.db, buf.items[i + 2]) orelse continue);
        if (std.mem.order(u8, updated, cutoff) == .gt) {
            rows.append(ctx.alloc, .{ .entity = e, .updated = updated, .created = created }) catch {};
        }
    }
    std.mem.sort(RecentRow, rows.items, {}, struct {
        fn lt(_: void, a: @TypeOf(rows.items[0]), b: @TypeOf(rows.items[0])) bool {
            return std.mem.order(u8, a.updated, b.updated) == .gt;
        }
    }.lt);
    var count: usize = 0;
    for (rows.items) |r| {
        if (count >= limit) break;
        const t = entity_type(ctx, r.entity) orelse "entity";
        emit("{s} ({s}) updated {s}\n", .{ r.entity, t, r.updated });
        var obuf = prefix(ctx, "obs_ts", &.{intern(ctx, r.entity)}, 1);
        var shown: usize = 0;
        var oi: usize = 0;
        while (oi + 3 <= obuf.items.len) : (oi += 3) {
            if (shown >= max_obs) break;
            const content = std.mem.span(dl.dl_intern_str_of(ctx.db, obuf.items[oi + 1]) orelse continue);
            const created = std.mem.span(dl.dl_intern_str_of(ctx.db, obuf.items[oi + 2]) orelse continue);
            if (std.mem.order(u8, created, cutoff) == .gt) {
                emit("    - {s}\n", .{content});
                shown += 1;
            }
        }
        obuf.deinit(ctx.alloc);
        count += 1;
    }
    rows.deinit(ctx.alloc);
}

fn cmd_delete(ctx: *Ctx, names: []const []const u8) void {
    for (names) |name| {
        const t = entity_type(ctx, name) orelse {
            emit("'{s}': nothing to delete\n", .{name});
            continue;
        };
        emit("deleting '{s}' ({s}):\n", .{ name, t });
        // observations + obs_ts
        var obs = observations(ctx, name, 1024);
        for (obs.items) |o| {
            del_fact(ctx, "observation", &.{ intern(ctx, name), intern(ctx, o) });
            emit("  removed observation: {s}\n", .{o});
        }
        obs.deinit(ctx.alloc);
        // obs_ts rows (any leftover) — rows are arity 3
        var obuf = prefix(ctx, "obs_ts", &.{intern(ctx, name)}, 1);
        var oi: usize = 0;
        while (oi + 3 <= obuf.items.len) : (oi += 3) {
            del_fact(ctx, "obs_ts", obuf.items[oi .. oi + 3]);
        }
        obuf.deinit(ctx.alloc);
        // edges touching it (both directions)
        var edges = all_edges(ctx);
        for (edges.items) |e| {
            if (std.mem.eql(u8, e.from, name)) {
                del_fact(ctx, "edge", &.{ intern(ctx, e.from), intern(ctx, e.to), intern(ctx, e.rel) });
                emit("  removed edge: {s} --{s}--> {s}\n", .{ e.from, e.rel, e.to });
            } else if (std.mem.eql(u8, e.to, name)) {
                del_fact(ctx, "edge", &.{ intern(ctx, e.from), intern(ctx, e.to), intern(ctx, e.rel) });
                emit("  removed edge: {s} --{s}--> {s}\n", .{ e.from, e.rel, e.to });
            }
        }
        edges.deinit(ctx.alloc);
        // entity + entity_ts (delete exact entity_ts row)
        del_fact(ctx, "entity", &.{ intern(ctx, name), intern(ctx, t) });
        var tsbuf = prefix(ctx, "entity_ts", &.{intern(ctx, name)}, 1);
        if (tsbuf.items.len >= 3) del_fact(ctx, "entity_ts", tsbuf.items[0..3]);
        tsbuf.deinit(ctx.alloc);
        // CAS guard (system-managed rev row can't be deleted directly)
        rev_bump(ctx, name);
        emit("  removed entity\n", .{});
    }
}

fn cmd_del_obs(ctx: *Ctx, name: []const u8, contents: []const []const u8) void {
    const now = now_iso();
    for (contents) |c| {
        del_fact(ctx, "observation", &.{ intern(ctx, name), intern(ctx, c) });
        // delete the exact obs_ts row for (name, content)
        var obuf = prefix(ctx, "obs_ts", &.{intern(ctx, name)}, 1);
        var oi: usize = 0;
        while (oi + 3 <= obuf.items.len) : (oi += 3) {
            const cs = dl.dl_intern_str_of(ctx.db, obuf.items[oi + 1]);
            const content = if (cs == null) "" else std.mem.span(cs);
            if (std.mem.eql(u8, c, content)) {
                del_fact(ctx, "obs_ts", obuf.items[oi .. oi + 3]);
                break;
            }
        }
        obuf.deinit(ctx.alloc);
        rev_bump(ctx, name);
    }
    bump_updated_at(ctx, name, now[0..]);
}

fn cmd_del_rel(ctx: *Ctx, a: []const u8, b: []const u8, rel: []const u8) void {
    var attempts: usize = 0;
    while (true) {
        if (dl.dl_txn_begin(ctx.db) != 0)
            die("error: cannot begin transaction", .{});

        const now = now_iso();
        const nowsym = intern(ctx, now[0..]);
        const asym = intern(ctx, a);
        const bsym = intern(ctx, b);
        const rsym = intern(ctx, rel);
        var ecols: [3]u32 = .{ asym, bsym, rsym };
        if (dl.dl_txn_delete_fact(ctx.db, "edge", &ecols, 3) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete edge fact", .{});
        }
        {
            var cur = prefix(ctx, "entity_ts", &.{asym}, 1);
            defer cur.deinit(ctx.alloc);
            if (cur.items.len >= 2) {
                _ = dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3);
                var ucols: [3]u32 = .{ cur.items[0], cur.items[1], nowsym };
                if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ucols, 3) != 0) {
                    _ = dl.dl_txn_rollback(ctx.db);
                    die("error: cannot update entity_ts", .{});
                }
            }
        }
        {
            var cur = prefix(ctx, "entity_ts", &.{bsym}, 1);
            defer cur.deinit(ctx.alloc);
            if (cur.items.len >= 2) {
                _ = dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3);
                var ucols: [3]u32 = .{ cur.items[0], cur.items[1], nowsym };
                if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ucols, 3) != 0) {
                    _ = dl.dl_txn_rollback(ctx.db);
                    die("error: cannot update entity_ts", .{});
                }
            }
        }
        const ra = rev_get(ctx, a);
        if (dl.dl_txn_cas(ctx.db, a.ptr, ra, ra + 1) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: CAS revision failed for '{s}'", .{a});
        }
        // self-loop (a == b): a single CAS already bumped the shared rev.
        if (!std.mem.eql(u8, a, b)) {
            const rb = rev_get(ctx, b);
            if (dl.dl_txn_cas(ctx.db, b.ptr, rb, rb + 1) != 0) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: CAS revision failed for '{s}'", .{b});
            }
        }
        const rc = dl.dl_txn_commit(ctx.db);
        if (rc == 0) return;
        _ = dl.dl_txn_rollback(ctx.db);
        if (rc < 0) die("error: commit failed", .{});
        // DL_E_CONFLICT: retry the whole transaction at whole-txn granularity.
        attempts += 1;
        if (attempts >= 50) die("error: revision conflict for '{s}'", .{a});
    }
}

fn cmd_rev(ctx: *Ctx, name: []const u8) void {
    emit("{d}\n", .{rev_get(ctx, name)});
}

fn cmd_count(ctx: *Ctx, rel: []const u8) void {
    const n = dl.dl_count(ctx.db, rel.ptr);
    if (n == std.math.maxInt(u64)) die("error: cannot count '{s}'", .{rel});
    emit("{s}: {d}\n", .{ rel, n });
}

const QueryPrinter = struct {
    ctx: *Ctx,
    count: usize = 0,
};

fn query_cb(cols: [*c]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
    const q: *QueryPrinter = @ptrCast(@alignCast(user.?));
    var i: usize = 0;
    while (i < arity) : (i += 1) {
        const s = std.mem.span(dl.dl_intern_str_of(q.ctx.db, cols[i]) orelse continue);
        if (i > 0) emit(" ", .{});
        emit("{s}", .{s});
    }
    emit("\n", .{});
    q.count += 1;
    return 0;
}

fn cmd_query(ctx: *Ctx, source: []const u8, goal_rel: []const u8) void {
    // source may be a file path (read it) or a literal rule string.
    const zpath = ctx.alloc.allocSentinel(u8, source.len, 0) catch die("oom", .{});
    defer ctx.alloc.free(zpath);
    @memcpy(zpath[0..source.len], source);
    zpath[source.len] = 0;

    var buf: []u8 = undefined;
    if (l.fopen(@ptrCast(zpath.ptr), "r")) |f| {
        // read the whole file via libc
        if (l.fseek(f, 0, 2) != 0) die("error: cannot seek '{s}'", .{source});
        const sz = l.ftell(f);
        if (sz < 0) die("error: cannot tell '{s}'", .{source});
        _ = l.rewind(f);
        buf = ctx.alloc.alloc(u8, @intCast(sz)) catch die("oom", .{});
        const nr = l.fread(buf.ptr, 1, @intCast(sz), f);
        _ = l.fclose(f);
        buf = buf[0..nr];
    } else {
        buf = ctx.alloc.dupe(u8, source) catch die("oom", .{});
    }
    defer ctx.alloc.free(buf);
    const zsrc = ctx.alloc.allocSentinel(u8, buf.len, 0) catch die("oom", .{});
    defer ctx.alloc.free(zsrc);
    @memcpy(zsrc[0..buf.len], buf);
    zsrc[buf.len] = 0;

    // Read-only evaluation: the engine runs the rules against an internal
    // clone of the store, so nothing is persisted and no relation is added.
    var q = QueryPrinter{ .ctx = ctx };
    const n = dl_query_rules_ro(@ptrCast(ctx.db), @ptrCast(zsrc.ptr), @ptrCast(goal_rel.ptr), query_cb, &q);
    if (n < 0) die("error: query failed", .{});
    if (q.count == 0) emit("(no results)\n", .{});
}

// ---------------------------------------------------------------------------
// bulk import (NDJSON) — hand-rolled JSON object parser
// ---------------------------------------------------------------------------
// Each record is one JSON object. We parse it into a small field map:
// string values are stored unescaped (owned), numbers as raw slices (owned by
// the input buffer) flagged via `nums`. Enough JSON for NDJSON: objects,
// escaped strings, numbers, and the literals true/false/null (ignored).
const JsonObj = struct {
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    vals: std.ArrayListUnmanaged([]const u8) = .empty,
    nums: std.ArrayListUnmanaged(bool) = .empty,
    alloc: Alloc,

    fn deinit(self: *JsonObj) void {
        for (self.nums.items, 0..) |is_num, i| {
            // string values are owned copies; number values point into input
            if (!is_num) self.alloc.free(self.vals.items[i]);
            self.alloc.free(self.names.items[i]);
        }
        self.names.deinit(self.alloc);
        self.vals.deinit(self.alloc);
        self.nums.deinit(self.alloc);
    }

    // string value for a field, or `def` when absent.
    fn str(self: *const JsonObj, name: []const u8, def: []const u8) []const u8 {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name) and !self.nums.items[i]) return self.vals.items[i];
        }
        return def;
    }

    // numeric value for a field, or `def` when absent / not a number.
    fn num(self: *const JsonObj, name: []const u8, def: u32) u32 {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name) and self.nums.items[i]) {
                return std.fmt.parseInt(u32, self.vals.items[i], 10) catch def;
            }
        }
        return def;
    }
};

fn skip_ws(s: []const u8, i: *usize) void {
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
}

// Parse a JSON string starting at s[i] (must be '"'). Returns an owned,
// unescaped copy, advancing i past the closing quote. Null on malformed input.
fn json_parse_string(alloc: Alloc, s: []const u8, i: *usize) ?[]u8 {
    if (i.* >= s.len or s[i.*] != '"') return null;
    i.* += 1;
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(alloc);
    while (i.* < s.len) {
        const c = s[i.*];
        if (c == '"') {
            i.* += 1;
            return out.toOwnedSlice(alloc) catch null;
        }
        if (c != '\\') {
            out.append(alloc, c) catch return null;
            i.* += 1;
            continue;
        }
        i.* += 1;
        if (i.* >= s.len) return null;
        const e = s[i.*];
        i.* += 1;
        switch (e) {
            '"' => out.append(alloc, '"') catch return null,
            '\\' => out.append(alloc, '\\') catch return null,
            '/' => out.append(alloc, '/') catch return null,
            'b' => out.append(alloc, 0x08) catch return null,
            'f' => out.append(alloc, 0x0c) catch return null,
            'n' => out.append(alloc, '\n') catch return null,
            'r' => out.append(alloc, '\r') catch return null,
            't' => out.append(alloc, '\t') catch return null,
            'u' => {
                if (i.* + 4 > s.len) return null;
                const cp = std.fmt.parseInt(u32, s[i.* .. i.* + 4], 16) catch return null;
                i.* += 4;
                // encode a BMP code point as UTF-8 (no surrogate-pair handling)
                if (cp < 0x80) {
                    out.append(alloc, @intCast(cp)) catch return null;
                } else if (cp < 0x800) {
                    out.append(alloc, @intCast(0xC0 | (cp >> 6))) catch return null;
                    out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch return null;
                } else {
                    out.append(alloc, @intCast(0xE0 | (cp >> 12))) catch return null;
                    out.append(alloc, @intCast(0x80 | ((cp >> 6) & 0x3F))) catch return null;
                    out.append(alloc, @intCast(0x80 | (cp & 0x3F))) catch return null;
                }
            },
            else => return null,
        }
    }
    return null;
}

// Parse one JSON object from `s` into `obj`. Advances nothing (object must be
// the whole record). Returns false on malformed JSON.
fn json_parse_object(alloc: Alloc, s: []const u8, obj: *JsonObj) bool {
    var i: usize = 0;
    skip_ws(s, &i);
    if (i >= s.len or s[i] != '{') return false;
    i += 1;
    while (true) {
        skip_ws(s, &i);
        if (i >= s.len) return false;
        if (s[i] == '}') return true; // empty object
        const key = json_parse_string(alloc, s, &i) orelse return false;
        skip_ws(s, &i);
        if (i >= s.len or s[i] != ':') {
            alloc.free(key);
            return false;
        }
        i += 1;
        skip_ws(s, &i);
        if (i >= s.len) return false;
        const c = s[i];
        var value: []const u8 = "";
        var is_num = false;
        if (c == '"') {
            value = json_parse_string(alloc, s, &i) orelse {
                alloc.free(key);
                return false;
            };
        } else if (c == '-' or (c >= '0' and c <= '9')) {
            const start = i;
            while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '-' or s[i] == '+' or s[i] == '.' or s[i] == 'e' or s[i] == 'E')) i += 1;
            value = s[start..i];
            is_num = true;
        } else if (std.mem.startsWith(u8, s[i..], "true") or std.mem.startsWith(u8, s[i..], "false") or std.mem.startsWith(u8, s[i..], "null")) {
            // literal: consume it, store an empty string value
            i += if (s[i] == 't') 4 else if (s[i] == 'f') 5 else 4;
            value = "";
        } else {
            alloc.free(key);
            return false;
        }
        obj.names.append(alloc, key) catch return false;
        obj.vals.append(alloc, value) catch return false;
        obj.nums.append(alloc, is_num) catch return false;
        skip_ws(s, &i);
        if (i >= s.len) return false;
        if (s[i] == ',') {
            i += 1;
            continue;
        }
        if (s[i] == '}') return true;
        return false;
    }
}

fn import_fail(ctx: *Ctx, comptime fmt: []const u8, args: anytype) noreturn {
    _ = dl.dl_txn_rollback(ctx.db);
    die("error: import failed: " ++ fmt, args);
}

fn cmd_import(ctx: *Ctx, file: []const u8) void {
    // read the whole file via libc (mirror cmd_query)
    const zpath = ctx.alloc.allocSentinel(u8, file.len, 0) catch die("oom", .{});
    defer ctx.alloc.free(zpath);
    @memcpy(zpath[0..file.len], file);
    zpath[file.len] = 0;

    const f = l.fopen(@ptrCast(zpath.ptr), "r") orelse
        die("error: import failed: cannot open '{s}'", .{file});
    if (l.fseek(f, 0, 2) != 0) {
        _ = l.fclose(f);
        die("error: import failed: cannot seek '{s}'", .{file});
    }
    const sz = l.ftell(f);
    if (sz < 0) {
        _ = l.fclose(f);
        die("error: import failed: cannot tell '{s}'", .{file});
    }
    _ = l.rewind(f);
    const buf = ctx.alloc.alloc(u8, @intCast(sz)) catch die("oom", .{});
    defer ctx.alloc.free(buf);
    const nr = l.fread(buf.ptr, 1, @intCast(sz), f);
    _ = l.fclose(f);
    const data = buf[0..nr];

    if (dl.dl_txn_begin(ctx.db) != 0)
        die("error: import failed: cannot begin transaction", .{});

    var n_entity: u64 = 0;
    var n_obs: u64 = 0;
    var n_rel: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        // tolerate blank lines (trailing newline, stray whitespace)
        var s = raw;
        while (s.len > 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\r')) s = s[1..];
        while (s.len > 0 and (s[s.len - 1] == ' ' or s[s.len - 1] == '\t' or s[s.len - 1] == '\r')) s = s[0 .. s.len - 1];
        if (s.len == 0) continue;

        var obj = JsonObj{ .alloc = ctx.alloc };
        defer obj.deinit();
        if (!json_parse_object(ctx.alloc, s, &obj))
            import_fail(ctx, "malformed JSON on line: {s}", .{s});

        const kind = obj.str("k", "");
        if (std.mem.eql(u8, kind, "entity")) {
            const name = obj.str("name", "");
            const etype = obj.str("type", "");
            const created = obj.str("created", "");
            const updated = obj.str("updated", "");
            const rev = obj.num("rev", 0);
            var ecols: [2]u32 = .{ internz(ctx, name), internz(ctx, etype) };
            if (dl.dl_txn_add_fact(ctx.db, "entity", &ecols, 2) != 0)
                import_fail(ctx, "cannot add entity fact", .{});
            var ts_cols: [3]u32 = .{ internz(ctx, name), internz(ctx, created), internz(ctx, updated) };
            if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &ts_cols, 3) != 0)
                import_fail(ctx, "cannot add entity_ts fact", .{});
            if (rev > 0) {
                // 0 -> R: fresh db starts the implicit rev row at 0.
                const zname = zdup(ctx, name);
                defer ctx.alloc.free(zname);
                if (dl.dl_txn_cas(ctx.db, zname.ptr, 0, rev) != 0)
                    import_fail(ctx, "cannot set revision for '{s}'", .{name});
            }
            n_entity += 1;
        } else if (std.mem.eql(u8, kind, "obs")) {
            const ent = obj.str("entity", "");
            const content = obj.str("content", "");
            const created = obj.str("created", "");
            var ocols: [2]u32 = .{ internz(ctx, ent), internz(ctx, content) };
            if (dl.dl_txn_add_fact(ctx.db, "observation", &ocols, 2) != 0)
                import_fail(ctx, "cannot add observation fact", .{});
            var tcols: [3]u32 = .{ internz(ctx, ent), internz(ctx, content), internz(ctx, created) };
            if (dl.dl_txn_add_fact(ctx.db, "obs_ts", &tcols, 3) != 0)
                import_fail(ctx, "cannot add obs_ts fact", .{});
            n_obs += 1;
        } else if (std.mem.eql(u8, kind, "rel")) {
            const a = obj.str("from", "");
            const b = obj.str("to", "");
            const rtype = obj.str("type", "");
            var rcols: [3]u32 = .{ internz(ctx, a), internz(ctx, b), internz(ctx, rtype) };
            if (dl.dl_txn_add_fact(ctx.db, "edge", &rcols, 3) != 0)
                import_fail(ctx, "cannot add edge fact", .{});
            n_rel += 1;
        } else {
            import_fail(ctx, "unknown record kind '{s}'", .{kind});
        }
    }

    if (dl.dl_txn_commit(ctx.db) != 0)
        import_fail(ctx, "commit failed", .{});
    emit("imported: {d} entities, {d} observations, {d} relations ({d} total)\n", .{
        n_entity, n_obs, n_rel, n_entity + n_obs + n_rel,
    });
}

// ---------------------------------------------------------------------------
// arg parsing
// ---------------------------------------------------------------------------
fn parseI64(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}
fn parseF64(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

const usage =
    \\fx-agent-memory — datalog-dafsa knowledge-graph memory for hax agents
    \\
    \\usage: fx-agent-memory [--db <dir>|-d <dir>] <command> [args]
    \\
    \\  create <name> [--type TYPE]
    \\  add-obs <name> <content> [<content>...]
    \\  relate --from A --to B --type REL
    \\  read <name> [<name>...]
    \\  graph
    \\  traverse <start> [depth] [--max-nodes N]
    \\  search "<terms>" [--top N]
    \\  vsearch "<query>" [--k N] [--radius R]   # semantic search over observation content
    \\  recent [--hours N] [--limit N] [--max-obs N]
    \\  similar <name> [--threshold F]
    \\  delete <name> [<name>...]
    \\  del-obs <name> <content> [<content>...]
    \\  del-rel --from A --to B --type REL
    \\  rev <name>
    \\  count [<rel>]
    \\  query <source-or-file> <goal_rel>   # run arbitrary Datalog rules, print goal tuples
    \\  import <file.jsonl>   # bulk-load NDJSON entities/observations/relations
    \\
    \\db: $FX_AGENT_MEMORY_DB | $JING_MEMORY_DB | config file ($FX_AGENT_MEMORY_CONFIG | $XDG_CONFIG_HOME/hax/fx-agent-memory | ~/.config/hax/fx-agent-memory) | /home/arch/.jing/memory.dl
    \\
;

fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn flagI64(args: []const []const u8, flag: []const u8, def: i64) i64 {
    if (flagValue(args, flag)) |v| {
        if (parseI64(v)) |n| return n;
    }
    return def;
}

fn flagF64(args: []const []const u8, flag: []const u8, def: f64) f64 {
    if (flagValue(args, flag)) |v| {
        if (parseF64(v)) |n| return n;
    }
    return def;
}

// filter out flag/value pairs, leaving positional args
fn positional(args: []const []const u8) std.ArrayListUnmanaged([]const u8) {
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var i: usize = 0;
    const flags = [_][]const u8{ "--type", "--from", "--to", "--max-nodes", "--top", "--hours", "--limit", "--max-obs", "--threshold" };
    while (i < args.len) : (i += 1) {
        var skip = false;
        for (flags) |f| {
            if (std.mem.eql(u8, args[i], f)) { skip = true; break; }
        }
        if (skip) { i += 1; continue; }
        out.append(std.heap.c_allocator, args[i]) catch {};
    }
    return out;
}

pub fn main(init: std.process.Init) void {
    const alloc = std.heap.c_allocator;
    // Convert the runtime argv (sentinel C strings) into []const []const u8.
    var arglist = std.ArrayListUnmanaged([]const u8).empty;
    for (init.minimal.args.vector) |a| arglist.append(alloc, std.mem.span(a)) catch {
        std.debug.print("oom\n", .{});
        std.process.exit(1);
    };
    defer arglist.deinit(alloc);
    const args = arglist.items;

    // drop program name
    var rest = args[1..];
    if (rest.len == 0) {
        errOut("{s}", .{usage});
        std.process.exit(1);
    }

    // global db override
    var dbdir: []const u8 = db_path_from_env();
    if (rest.len >= 2 and (std.mem.eql(u8, rest[0], "--db") or std.mem.eql(u8, rest[0], "-d"))) {
        dbdir = rest[1];
        rest = rest[2..];
    }

    if (rest.len == 0) {
        errOut("{s}", .{usage});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h")) {
        emit("{s}", .{usage});
        return;
    }

    // mkdir -p parent dirs
    mkdir_p(dbdir);

    const db = open_with_retry(dbdir) orelse {
        std.debug.print("error: could not acquire memory lock on {s}\n", .{dbdir});
        std.process.exit(1);
    };
    defer dl.dl_close(db);

    var ctx = Ctx{ .db = db, .alloc = alloc };
    ensure_relations(&ctx);

    const cmd = rest[0];
    const cmd_args = rest[1..];

    if (std.mem.eql(u8, cmd, "create")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: create needs <name>", .{});
        const etype = flagValue(cmd_args, "--type") orelse "entity";
        cmd_create(&ctx, pos.items[0], etype);
    } else if (std.mem.eql(u8, cmd, "add-obs")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 2) die("error: add-obs needs <name> and content", .{});
        require_entity(&ctx, pos.items[0]);
        cmd_add_obs(&ctx, pos.items[0], pos.items[1..]);
    } else if (std.mem.eql(u8, cmd, "relate")) {
        const f = flagValue(cmd_args, "--from") orelse die("error: relate needs --from", .{});
        const t = flagValue(cmd_args, "--to") orelse die("error: relate needs --to", .{});
        const r = flagValue(cmd_args, "--type") orelse die("error: relate needs --type", .{});
        require_entity(&ctx, f);
        require_entity(&ctx, t);
        cmd_relate(&ctx, f, t, r);
    } else if (std.mem.eql(u8, cmd, "read")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: read needs <name>", .{});
        cmd_read(&ctx, pos.items);
    } else if (std.mem.eql(u8, cmd, "graph")) {
        cmd_graph(&ctx);
    } else if (std.mem.eql(u8, cmd, "traverse")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: traverse needs <start>", .{});
        const depth: i32 = @intCast(if (pos.items.len >= 2) parseI64(pos.items[1]) orelse 2 else 2);
        const mn: i32 = @intCast(flagI64(cmd_args, "--max-nodes", 1000));
        cmd_traverse(&ctx, pos.items[0], depth, mn);
    } else if (std.mem.eql(u8, cmd, "search")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: search needs \"<terms>\"", .{});
        const top: i32 = @intCast(flagI64(cmd_args, "--top", 20));
        cmd_search(&ctx, pos.items[0], top);
    } else if (std.mem.eql(u8, cmd, "vsearch")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: vsearch needs \"<query>\"", .{});
        const k: c_int = @intCast(flagI64(cmd_args, "--k", 10));
        const radius: c_int = @intCast(flagI64(cmd_args, "--radius", 2));
        cmd_vsearch(&ctx, pos.items[0], k, radius, dbdir);
    } else if (std.mem.eql(u8, cmd, "recent")) {
        const hours = flagI64(cmd_args, "--hours", 24);
        const limit: usize = @intCast(flagI64(cmd_args, "--limit", 20));
        const max_obs: usize = @intCast(flagI64(cmd_args, "--max-obs", 5));
        cmd_recent(&ctx, hours, limit, max_obs);
    } else if (std.mem.eql(u8, cmd, "similar")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: similar needs <name>", .{});
        const th = flagF64(cmd_args, "--threshold", 0.5);
        cmd_similar(&ctx, pos.items[0], th);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: delete needs <name>", .{});
        cmd_delete(&ctx, pos.items);
    } else if (std.mem.eql(u8, cmd, "del-obs")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 2) die("error: del-obs needs <name> and content", .{});
        require_entity(&ctx, pos.items[0]);
        cmd_del_obs(&ctx, pos.items[0], pos.items[1..]);
    } else if (std.mem.eql(u8, cmd, "del-rel")) {
        const f = flagValue(cmd_args, "--from") orelse die("error: del-rel needs --from", .{});
        const t = flagValue(cmd_args, "--to") orelse die("error: del-rel needs --to", .{});
        const r = flagValue(cmd_args, "--type") orelse die("error: del-rel needs --type", .{});
        require_entity(&ctx, f);
        require_entity(&ctx, t);
        cmd_del_rel(&ctx, f, t, r);
    } else if (std.mem.eql(u8, cmd, "rev")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: rev needs <name>", .{});
        cmd_rev(&ctx, pos.items[0]);
    } else if (std.mem.eql(u8, cmd, "count")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        const rel = if (pos.items.len >= 1) pos.items[0] else "entity";
        cmd_count(&ctx, rel);
    } else if (std.mem.eql(u8, cmd, "query")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 2) die("error: query needs <source-or-file> <goal_rel>", .{});
        cmd_query(&ctx, pos.items[0], pos.items[1]);
    } else if (std.mem.eql(u8, cmd, "import")) {
        var pos = positional(cmd_args);
        defer pos.deinit(alloc);
        if (pos.items.len < 1) die("error: import needs <file.jsonl>", .{});
        cmd_import(&ctx, pos.items[0]);
    } else {
        errOut("error: unknown command '{s}'\n", .{cmd});
        std.process.exit(1);
    }
}
