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
});
const dl = l;

// ---------------------------------------------------------------------------
// extern forward declarations for the index.h search entrypoints.
// ---------------------------------------------------------------------------
extern fn dl_index_observations(db: ?*anyopaque) c_long;
extern fn dl_search_top(db: ?*anyopaque, terms: [*c]const u32, n_terms: c_int, obs_ids_out: [*c]u32, scores_out: [*c]c_int, limit: c_int) c_int;
extern fn dl_query_rules_ro(db: ?*anyopaque, source: [*:0]const u8, goal_rel: [*:0]const u8, cb: ?*const fn ([*c]const u32, u8, ?*anyopaque) callconv(.c) c_int, user: ?*anyopaque) c_long;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn time(timer: ?*c_long) c_long;
extern fn usleep(usec: c_uint) c_int;
extern fn opendir(path: [*:0]const u8) ?*l.DIR;
extern fn readdir(dir: ?*l.DIR) ?*l.struct_dirent;
extern fn closedir(dir: ?*l.DIR) c_int;
extern fn unlink(path: [*:0]const u8) c_int;

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
    return "/home/arch/.jing/memory.dl";
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
    var printed = false;
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        if (dl.dl_open(path.ptr)) |db| return db;
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
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = l.fwrite(s.ptr, 1, s.len, l.stdout);
}

fn errOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
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

    const now = now_iso();
    add_fact(ctx, "entity", &.{ intern(ctx, name), intern(ctx, etype) });
    add_fact(ctx, "entity_ts", &.{ intern(ctx, name), intern(ctx, now[0..]), intern(ctx, now[0..]) });
    // starts the entity at revision 1 (implicit rev row starts at 0)
    if (dl.dl_cas_revision(ctx.db, name.ptr, 0, 1) != 0)
        die("error: CAS revision failed for '{s}'", .{name});
    emit("created '{s}' ({s})\n", .{ name, etype });
}

fn cmd_add_obs(ctx: *Ctx, name: []const u8, contents: []const []const u8) void {
    const now = now_iso();
    for (contents) |c| {
        add_fact(ctx, "observation", &.{ intern(ctx, name), intern(ctx, c) });
        add_fact(ctx, "obs_ts", &.{ intern(ctx, name), intern(ctx, c), intern(ctx, now[0..]) });
        rev_bump(ctx, name);
    }
    // bump updated_at to now
    var cur = prefix(ctx, "entity_ts", &.{intern(ctx, name)}, 1);
    defer cur.deinit(ctx.alloc);
    if (cur.items.len >= 2) {
        del_fact(ctx, "entity_ts", cur.items[0..3]);
        add_fact(ctx, "entity_ts", &.{ cur.items[0], cur.items[1], intern(ctx, now[0..]) });
    }
}

fn cmd_relate(ctx: *Ctx, a: []const u8, b: []const u8, rel: []const u8) void {
    const now = now_iso();
    add_fact(ctx, "edge", &.{ intern(ctx, a), intern(ctx, b), intern(ctx, rel) });
    bump_updated_at(ctx, a, now[0..]);
    bump_updated_at(ctx, b, now[0..]);
    rev_bump(ctx, a);
    rev_bump(ctx, b);
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
    const now = now_iso();
    del_fact(ctx, "edge", &.{ intern(ctx, a), intern(ctx, b), intern(ctx, rel) });
    bump_updated_at(ctx, a, now[0..]);
    bump_updated_at(ctx, b, now[0..]);
    rev_bump(ctx, a);
    rev_bump(ctx, b);
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
    \\  recent [--hours N] [--limit N] [--max-obs N]
    \\  similar <name> [--threshold F]
    \\  delete <name> [<name>...]
    \\  del-obs <name> <content> [<content>...]
    \\  del-rel --from A --to B --type REL
    \\  rev <name>
    \\  count [<rel>]
    \\  query <source-or-file> <goal_rel>   # run arbitrary Datalog rules, print goal tuples
    \\
    \\db: $FX_AGENT_MEMORY_DB | $JING_MEMORY_DB | /home/arch/.jing/memory.dl
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
    } else {
        errOut("error: unknown command '{s}'\n", .{cmd});
        std.process.exit(1);
    }
}
