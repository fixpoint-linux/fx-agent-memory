// fx-agent-gardener — the deterministic memory-graph gardener, as native
// Datalog rules over the SAME datalog-dafsa store fx-agent-memory uses.
//
// Port of jing-meta/dreamer/souffle/garden.dl. The deterministic tiers are
// computed READ-ONLY in Zig — normalization/tokenization happen here anyway,
// and the plan needs no rule-engine round-trip: it only reads entity/edge
// tuples via dl_prefix (which returns COMPLETE tuples, never suffixes).
// Nothing is written during planning, so a dry-run leaves the store
// byte-for-byte untouched (no __gdn_* helper injection, no interner growth,
// no WAL churn). --apply performs the mutations inside dl_txn_* transactions
// with one CAS per touched entity (retry on DL_E_CONFLICT), mirroring
// cmd_add_obs/cmd_relate in main.zig.
//
// Tiers (order matters on apply):
//   1. type_rename      — canonical_type table (embedded const, ctype.csv)
//   2. duplicate_pair   — normalized-name collision (norm_name)
//   3. candidate_pair   — shared-token overlap (tokenize + count), minus
//                         existing edges, validated by an optional LLM judge
//                         before any edge is written.
//
// LLM relation validation: --validator openapi posts OpenAI-compatible
// chat/completions JSON (default url http://127.0.0.1:8322/v1); --validator
// local posts Ollama /api/generate. Both parse the first integer in the
// reply as the verdict (1 approve / 0 reject); timeouts and any non-2xx or
// unparsable reply REJECT (the deterministic tiers alone are always safe).
//
// Dry-run is the default and never mutates. --apply on a db copy first.

const std = @import("std");
const l = @cImport({
    @cInclude("dl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});
const dl = l;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fgets(buf: [*c]u8, n: c_int, stream: *anyopaque) [*c]u8;
extern fn fclose(stream: *anyopaque) c_int;
extern fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern fn time(timer: ?*c_long) c_long;
extern fn usleep(usec: c_uint) c_int;
// Read-only self-contained rule query (clone-and-evaluate). Mirrors the
// forward declaration in main.zig:44; the clone is shallow (borrows the live
// interner + relation pointers), so helper facts must be present in the live
// store before the call and are read from its CURRENT in-memory contents.
extern fn dl_query_rules_ro(db: ?*anyopaque, source: [*:0]const u8, goal_rel: [*:0]const u8, cb: ?*const fn ([*c]const u32, u8, ?*anyopaque) callconv(.c) c_int, user: ?*anyopaque) c_long;

// ---------------------------------------------------------------------------
// Small typed wrapper over the opaque C handle (mirror of main.zig).
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

fn rev_get(ctx: *Ctx, name: []const u8) u32 {
    var out: u32 = 0;
    _ = dl.dl_rev_get(ctx.db, name.ptr, &out);
    return out;
}

// ---------------------------------------------------------------------------
// tuple enumeration helpers (mirror of main.zig)
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

// ---------------------------------------------------------------------------
// tokenizer / normalization (mirror of index.c tokenization in main.zig)
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

// Normalized name for duplicate detection: lowercase alphanumerics only
// (separators squeezed out, like norm_name in the souffle pipeline). Two-pass
// so the returned slice is the exact allocation (callers free it directly).
fn norm_name(alloc: Alloc, name: []const u8) []u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (is_alnum(ch)) n += 1;
    }
    const d = alloc.alloc(u8, n) catch return &.{};
    var i: usize = 0;
    for (name) |ch| {
        if (is_alnum(ch)) {
            d[i] = std.ascii.toLower(ch);
            i += 1;
        }
    }
    return d;
}

// ---------------------------------------------------------------------------
// output helpers (mirror of main.zig)
// ---------------------------------------------------------------------------
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
// canonical type table (jing-meta/dreamer/souffle/canonical_type.csv)
// ---------------------------------------------------------------------------
const canonical_type_table = [_][2][]const u8{
    .{ "Change", "change" },
    .{ "Task", "task" },
    .{ "Fix", "fix" },
    .{ "File", "file" },
    .{ "Feature", "feature" },
    .{ "DesignDecision", "design-decision" },
    .{ "CodeChange", "code-change" },
    .{ "Implementation", "implementation" },
    .{ "TestSuite", "test" },
    .{ "TestResult", "test-result" },
    .{ "Code", "code" },
    .{ "Project", "project" },
    .{ "Session", "change" },
    .{ "Module", "module" },
    .{ "Fact", "finding" },
    .{ "Lesson", "finding" },
    .{ "Server", "service" },
    .{ "Convention", "config" },
    .{ "Milestone", "plan" },
    .{ "Assessment", "finding" },
    .{ "Recommendation", "finding" },
    .{ "KnownIssue", "bug" },
    .{ "RefactorTask", "task" },
    .{ "Performance_problem", "bug" },
    .{ "NetworkConfig", "config" },
    .{ "NetworkingConfig", "config" },
    .{ "NetworkInterface", "infrastructure" },
    .{ "System_config", "config" },
    .{ "SystemConfig", "config" },
    .{ "Infrastructure", "infrastructure" },
    .{ "Repository", "project" },
    .{ "Artifact", "file" },
    .{ "Configuration", "config" },
    .{ "System", "infrastructure" },
    .{ "Peer", "infrastructure" },
};

// ---------------------------------------------------------------------------
// db open with single-writer lock retry (mirror of main.zig)
// ---------------------------------------------------------------------------
fn home_dir() []const u8 {
    if (getenv("HOME")) |h| return std.mem.span(h);
    return "";
}

var default_db_buf: [4096]u8 = undefined;
fn default_db_dir() []const u8 {
    const home = home_dir();
    const n = std.fmt.bufPrint(&default_db_buf, "{s}/.jing/memory.dl", .{home}) catch return ".jing/memory.dl";
    return n;
}

fn db_path_from_env() []const u8 {
    if (getenv("FX_AGENT_MEMORY_DB")) |v| return std.mem.span(v);
    if (getenv("JING_MEMORY_DB")) |v| return std.mem.span(v);
    if (config_db_path()) |p| return p;
    return default_db_dir();
}

fn expand_cfg_path(alloc: Alloc, raw: []const u8) ?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '~' and i == 0) {
            const home = home_dir();
            out.appendSlice(alloc, home) catch return null;
            i += 1;
        } else if (c == '$') {
            var j = i + 1;
            const braced = (j < raw.len and raw[j] == '{');
            if (braced) j += 1;
            const vstart = j;
            while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) j += 1;
            const vname = raw[vstart..j];
            if (vname.len > 0) {
                var namez: [256]u8 = undefined;
                if (vname.len < namez.len) {
                    @memcpy(namez[0..vname.len], vname);
                    namez[vname.len] = 0;
                    if (getenv(@ptrCast(&namez))) |val| out.appendSlice(alloc, std.mem.span(val)) catch return null;
                }
            }
            i = if (braced and j < raw.len and raw[j] == '}') j + 1 else j;
        } else {
            out.append(alloc, c) catch return null;
            i += 1;
        }
    }
    const owned = alloc.dupe(u8, out.items) catch return null;
    return owned;
}

fn config_db_path() ?[]const u8 {
    var pathbuf: [4096]u8 = undefined;
    const cfg = if (getenv("FX_AGENT_MEMORY_CONFIG")) |v| std.mem.span(v) else blk: {
        const xdg = if (getenv("XDG_CONFIG_HOME")) |v| std.mem.span(v) else default_config_dir();
        const p = std.fmt.bufPrint(&pathbuf, "{s}/hax/fx-agent-memory", .{xdg}) catch return null;
        break :blk p;
    };

    var cfgz: [4096]u8 = undefined;
    @memcpy(cfgz[0..cfg.len], cfg);
    cfgz[cfg.len] = 0;
    const f = fopen(@ptrCast(&cfgz), "r") orelse return null;
    defer _ = fclose(f);

    var buf: [4096]u8 = undefined;
    while (true) {
        const line = fgets(@ptrCast(&buf), @intCast(buf.len), f);
        if (line == null) break;
        const len = std.mem.len(line);
        const n = std.mem.indexOfScalar(u8, line[0..len], '\n') orelse len;
        const s = std.mem.trim(u8, line[0..n], " \t\r");
        if (s.len == 0 or s[0] == '#') continue;
        if (expand_cfg_path(std.heap.c_allocator, s)) |owned| return owned;
        const owned = std.heap.c_allocator.alloc(u8, s.len) catch return null;
        @memcpy(owned, s);
        return owned;
    }
    return null;
}

fn default_config_dir() []const u8 {
    const home = home_dir();
    if (home.len == 0) return "/.config";
    const n = std.fmt.bufPrint(&config_dir_buf, "{s}/.config", .{home}) catch return "/.config";
    return n;
}
var config_dir_buf: [4096]u8 = undefined;

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
            errOut("waiting for memory lock\n", .{});
            printed = true;
        }
        _ = usleep(100_000);
    }
    return null;
}

// ---------------------------------------------------------------------------
// tier results
// ---------------------------------------------------------------------------
const Rename = struct { name: []const u8, from: []const u8, to: []const u8 };
const PairCount = struct { a: []const u8, b: []const u8, count: u32 };

const Plan = struct {
    renames: std.ArrayListUnmanaged(Rename),
    dups: std.ArrayListUnmanaged(PairCount),
    cands: std.ArrayListUnmanaged(PairCount),
    type_freq: std.ArrayListUnmanaged(PairCount), // (type, count) reuse
    approved: std.ArrayListUnmanaged(bool), // LLM verdict per candidate (apply)

    fn init() Plan {
        return .{ .renames = .empty, .dups = .empty, .cands = .empty, .type_freq = .empty, .approved = .empty };
    }
};

// ---------------------------------------------------------------------------
// LLM validation
// ---------------------------------------------------------------------------
const Validator = enum { none, local, openapi };

const Judge = struct {
    alloc: Alloc,
    validator: Validator,
    api_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

fn firstInt(s: []const u8) ?i32 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '0' or s[i] == '1') {
            return if (s[i] == '1') 1 else 0;
        }
    }
    return null;
}

const JUDGE_TIMEOUT_SECONDS: isize = 30;

// Bound a blocking socket with SO_RCVTIMEO/SO_SNDTIMEO so a hung validator
// cannot block --apply forever (std.http fetch has no timeout knob in 0.16).
fn setSocketTimeout(fd: std.posix.socket_t, seconds: isize) void {
    const tv = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

fn postJson(judge: *Judge, url: []const u8, body: []const u8) ?[]u8 {
    var threaded = std.Io.Threaded.init(judge.alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = std.http.Client{ .allocator = judge.alloc, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(judge.alloc);
    defer aw.deinit();
    const w = &aw.writer;
    var authbuf: [512]u8 = undefined;
    const auth: std.http.Client.Request.Headers.Value = if (judge.api_key.len > 0) blk: {
        const s = std.fmt.bufPrint(&authbuf, "Bearer {s}", .{judge.api_key}) catch break :blk .default;
        break :blk .{ .override = s };
    } else .default;

    const uri = std.Uri.parse(url) catch {
        errOut("judge: bad url {s} (rejected)\n", .{url});
        return null;
    };
    var req = client.request(.POST, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = auth,
            .accept_encoding = .omit,
        },
    }) catch {
        errOut("judge: request to {s} failed (rejected)\n", .{url});
        return null;
    };
    defer req.deinit();

    setSocketTimeout(req.connection.?.stream_reader.stream.socket.handle, JUDGE_TIMEOUT_SECONDS);

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = req.sendBodyUnflushed(&.{}) catch {
        errOut("judge: send to {s} failed (rejected)\n", .{url});
        return null;
    };
    bw.writer.writeAll(body) catch {
        errOut("judge: send to {s} failed (rejected)\n", .{url});
        return null;
    };
    bw.end() catch {
        errOut("judge: send to {s} failed (rejected)\n", .{url});
        return null;
    };
    req.connection.?.flush() catch {
        errOut("judge: send to {s} failed (rejected)\n", .{url});
        return null;
    };

    var response = req.receiveHead(&.{}) catch {
        errOut("judge: no response from {s} (rejected)\n", .{url});
        return null;
    };
    if (response.head.status.class() != .success) {
        errOut("judge: HTTP {d} from {s} (rejected)\n", .{ @intFromEnum(response.head.status), url });
        return null;
    }

    var transfer_buffer: [64]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(w) catch {
        errOut("judge: read from {s} failed (rejected)\n", .{url});
        return null;
    };
    return aw.toOwnedSlice() catch null;
}

// Returns true when the LLM approves the pair (errors/none REJECT).
fn judgeApprove(judge: *Judge, a: []const u8, b: []const u8, shared: u32) bool {
    switch (judge.validator) {
        .none => return true,
        .local, .openapi => {},
    }
    var body_aw: std.Io.Writer.Allocating = .init(judge.alloc);
    defer body_aw.deinit();
    const w = &body_aw.writer;

    if (judge.validator == .openapi) {
        w.print("{{\"model\":\"{s}\",\"messages\":[", .{judge.model}) catch return false;
        w.writeAll("{\"role\":\"system\",\"content\":\"You approve or reject proposed relations in a memory graph. Reply with 1 (approve) or 0 (reject) and nothing else.\"},{\"role\":\"user\",\"content\":\"Should entities '") catch return false;
        jsonEscape(w, a) catch return false;
        w.writeAll("' and '") catch return false;
        jsonEscape(w, b) catch return false;
        w.print("' be related? They share {d} name tokens. Reply 1 or 0 only.\"}}]}}", .{shared}) catch return false;
    } else {
        w.print("{{\"model\":\"{s}\",\"prompt\":\"Reply 1 or 0 only: should entities '", .{judge.model}) catch return false;
        jsonEscape(w, a) catch return false;
        w.writeAll("' and '") catch return false;
        jsonEscape(w, b) catch return false;
        w.print("' be related? They share {d} name tokens.\",\"stream\":false}}", .{shared}) catch return false;
    }

    const url = if (judge.validator == .openapi)
        std.fmt.allocPrint(judge.alloc, "{s}/chat/completions", .{judge.api_url}) catch return false
    else
        std.fmt.allocPrint(judge.alloc, "{s}/api/generate", .{judge.api_url}) catch return false;
    defer judge.alloc.free(url);

    const resp = postJson(judge, url, body_aw.written()) orelse return false;
    defer judge.alloc.free(resp);

    // tolerant content extraction: find the "content" or "response" string
    var content: []const u8 = resp;
    if (std.mem.indexOf(u8, resp, "\"content\"")) |pos| {
        content = resp[pos..];
    } else if (std.mem.indexOf(u8, resp, "\"response\"")) |pos| {
        content = resp[pos..];
    }
    return firstInt(content) == 1;
}

// ---------------------------------------------------------------------------
// mutation appliers (one txn per mutation group, one CAS per entity,
// whole-txn retry on DL_E_CONFLICT — mirrors cmd_add_obs in main.zig)
// ---------------------------------------------------------------------------
fn renameOnce(ctx: *Ctx, name: []const u8, from: []const u8, to: []const u8) bool {
    if (dl.dl_txn_begin(ctx.db) != 0) die("error: cannot begin transaction", .{});
    const nsym = intern(ctx, name);
    const fsym = intern(ctx, from);
    const tsym = intern(ctx, to);
    const nowsym = intern(ctx, now_iso());
    if (blk: {
        const cols = [_]u32{ nsym, fsym };
        break :blk dl.dl_txn_delete_fact(ctx.db, "entity", &cols, 2) != 0;
    }) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: cannot delete entity fact", .{});
    }
    if (blk: {
        const cols = [_]u32{ nsym, tsym };
        break :blk dl.dl_txn_add_fact(ctx.db, "entity", &cols, 2) != 0;
    }) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: cannot add entity fact", .{});
    }
    bumpEntityTs(ctx, nsym, nowsym);
    const cur = rev_get(ctx, name);
    if (dl.dl_txn_cas(ctx.db, name.ptr, cur, cur + 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{name});
    }
    const rc = dl.dl_txn_commit(ctx.db);
    if (rc == 0) return true;
    _ = dl.dl_txn_rollback(ctx.db);
    return rc == dl.DL_E_CONFLICT;
}

// one txn per duplicate pair; `a` is the keeper (lexically smaller name).
// dl_prefix returns COMPLETE tuples (never suffixes): observation is
// [entity, content], obs_ts/entity_ts are [entity, created, updated].
fn mergeOnce(ctx: *Ctx, a: []const u8, b: []const u8) bool {
    if (dl.dl_txn_begin(ctx.db) != 0) die("error: cannot begin transaction", .{});
    const as = intern(ctx, a);
    const bs = intern(ctx, b);
    const now = now_iso();
    const nowsym = intern(ctx, now[0..]);

    // move observations: tuples are [bs, content]
    var obs = prefix(ctx, "observation", &.{bs}, 1);
    defer obs.deinit(ctx.alloc);
    var i: usize = 0;
    while (i + 2 <= obs.items.len) : (i += 2) {
        const c = obs.items[i + 1];
        if (blk: {
        const cols = [_]u32{ bs, c };
        break :blk dl.dl_txn_delete_fact(ctx.db, "observation", &cols, 2) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete observation fact", .{});
        }
        if (blk: {
        const cols = [_]u32{ as, c };
        break :blk dl.dl_txn_add_fact(ctx.db, "observation", &cols, 2) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot add observation fact", .{});
        }
    }

    // move obs_ts rows: tuples are [bs, content, created]
    var ts = prefix(ctx, "obs_ts", &.{bs}, 1);
    defer ts.deinit(ctx.alloc);
    i = 0;
    while (i + 3 <= ts.items.len) : (i += 3) {
        const c = ts.items[i + 1];
        const t = ts.items[i + 2];
        if (blk: {
        const cols = [_]u32{ bs, c, t };
        break :blk dl.dl_txn_delete_fact(ctx.db, "obs_ts", &cols, 3) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete obs_ts fact", .{});
        }
        if (blk: {
        const cols = [_]u32{ as, c, t };
        break :blk dl.dl_txn_add_fact(ctx.db, "obs_ts", &cols, 3) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot add obs_ts fact", .{});
        }
    }

    // b's entity_ts row is deleted (b folds into a); the keeper's updated_at
    // bumps to now. Tuples are [entity, created, updated].
    var ets = prefix(ctx, "entity_ts", &.{bs}, 1);
    defer ets.deinit(ctx.alloc);
    if (ets.items.len >= 3) {
        if (blk: {
        const cols = [_]u32{ bs, ets.items[1], ets.items[2] };
        break :blk dl.dl_txn_delete_fact(ctx.db, "entity_ts", &cols, 3) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete entity_ts fact", .{});
        }
    }
    var aets = prefix(ctx, "entity_ts", &.{as}, 1);
    defer aets.deinit(ctx.alloc);
    if (aets.items.len >= 3) {
        if (blk: {
        const cols = [_]u32{ as, aets.items[1], aets.items[2] };
        break :blk dl.dl_txn_delete_fact(ctx.db, "entity_ts", &cols, 3) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete entity_ts fact", .{});
        }
        if (blk: {
        const cols = [_]u32{ as, aets.items[1], nowsym };
        break :blk dl.dl_txn_add_fact(ctx.db, "entity_ts", &cols, 3) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot add entity_ts fact", .{});
        }
    }

    var edges = prefix(ctx, "edge", &.{}, 0);
    defer edges.deinit(ctx.alloc);
    i = 0;
    while (i + 3 <= edges.items.len) : (i += 3) {
        const f = edges.items[i];
        const t = edges.items[i + 1];
        const r = edges.items[i + 2];
        if (f == bs or t == bs) {
            const nf = if (f == bs) as else f;
            const nt = if (t == bs) as else t;
            if (blk: {
        const cols = [_]u32{ f, t, r };
        break :blk dl.dl_txn_delete_fact(ctx.db, "edge", &cols, 3) != 0;
    }) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: cannot delete edge fact", .{});
            }
            if (blk: {
        const cols = [_]u32{ nf, nt, r };
        break :blk dl.dl_txn_add_fact(ctx.db, "edge", &cols, 3) != 0;
    }) {
                _ = dl.dl_txn_rollback(ctx.db);
                die("error: cannot add edge fact", .{});
            }
        }
    }

    // entity row for b (deleted: b folds into a). Tuples are [bs, type].
    var ent = prefix(ctx, "entity", &.{bs}, 1);
    defer ent.deinit(ctx.alloc);
    if (ent.items.len >= 2) {
        if (blk: {
        const cols = [_]u32{ bs, ent.items[1] };
        break :blk dl.dl_txn_delete_fact(ctx.db, "entity", &cols, 2) != 0;
    }) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot delete entity fact", .{});
        }
    }

    // one CAS per touched entity (the engine rejects two CAS ops on the same
    // entity in one txn; a and b are distinct here)
    const ra = rev_get(ctx, a);
    if (dl.dl_txn_cas(ctx.db, a.ptr, ra, ra + 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{a});
    }
    const rb = rev_get(ctx, b);
    if (dl.dl_txn_cas(ctx.db, b.ptr, rb, rb + 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{b});
    }

    const rc = dl.dl_txn_commit(ctx.db);
    if (rc == 0) return true;
    _ = dl.dl_txn_rollback(ctx.db);
    return rc == dl.DL_E_CONFLICT;
}

// Bump an entity's entity_ts updated_at to `now` inside an open txn.
// entity_ts tuples are [entity, created, updated] (COMPLETE tuples).
fn bumpEntityTs(ctx: *Ctx, sym: u32, nowsym: u32) void {
    var cur = prefix(ctx, "entity_ts", &.{sym}, 1);
    defer cur.deinit(ctx.alloc);
    if (cur.items.len >= 3) {
        if (dl.dl_txn_delete_fact(ctx.db, "entity_ts", cur.items[0..3], 3) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot update entity_ts", .{});
        }
        const cols = [_]u32{ cur.items[0], cur.items[1], nowsym };
        if (dl.dl_txn_add_fact(ctx.db, "entity_ts", &cols, 3) != 0) {
            _ = dl.dl_txn_rollback(ctx.db);
            die("error: cannot update entity_ts", .{});
        }
    }
}

// one txn per candidate relation. Re-checks both endpoints exist and no edge
// already connects them (candidates are computed before merges delete merged
// entities), and bumps both entity_ts updated_at.
fn relateOnce(ctx: *Ctx, a: []const u8, b: []const u8, rel: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true; // self-loop: nothing to relate
    if (dl.dl_txn_begin(ctx.db) != 0) die("error: cannot begin transaction", .{});
    const nowsym = intern(ctx, now_iso());
    const asym = intern(ctx, a);
    const bsym = intern(ctx, b);
    const rsym = intern(ctx, rel);

    // both endpoints must still exist (a merge may have deleted one)
    {
        var ea = prefix(ctx, "entity", &.{asym}, 1);
        defer ea.deinit(ctx.alloc);
        var eb = prefix(ctx, "entity", &.{bsym}, 1);
        defer eb.deinit(ctx.alloc);
        if (ea.items.len < 2 or eb.items.len < 2) {
            _ = dl.dl_txn_rollback(ctx.db);
            return true; // skip silently — endpoint merged away
        }
    }

    if (blk: {
        const cols = [_]u32{ asym, bsym, rsym };
        break :blk dl.dl_txn_add_fact(ctx.db, "edge", &cols, 3) != 0;
    }) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: cannot add edge fact", .{});
    }
    bumpEntityTs(ctx, asym, nowsym);
    bumpEntityTs(ctx, bsym, nowsym);
    const ra = rev_get(ctx, a);
    if (dl.dl_txn_cas(ctx.db, a.ptr, ra, ra + 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{a});
    }
    const rb = rev_get(ctx, b);
    if (dl.dl_txn_cas(ctx.db, b.ptr, rb, rb + 1) != 0) {
        _ = dl.dl_txn_rollback(ctx.db);
        die("error: CAS revision failed for '{s}'", .{b});
    }
    const rc = dl.dl_txn_commit(ctx.db);
    if (rc == 0) return true;
    _ = dl.dl_txn_rollback(ctx.db);
    return rc == dl.DL_E_CONFLICT;
}

const APPLY_ATTEMPTS = 50;

// True when `name` still names an entity. Candidate pairs are computed before
// merges delete merged-away entities, so a stale endpoint must be skipped
// (otherwise relateOnce would add a dangling edge to a ghost entity).
fn entityExists(ctx: *Ctx, name: []const u8) bool {
    const sym = dl.dl_intern_str_find(ctx.db, name.ptr);
    if (sym == 0) return false;
    var buf = prefix(ctx, "entity", &.{sym}, 1);
    defer buf.deinit(ctx.alloc);
    return buf.items.len >= 2;
}

// ---------------------------------------------------------------------------
// deterministic tiers (engine-driven via dl_query_rules_ro over a scratch store)
// ---------------------------------------------------------------------------
const HELPER_CTYPE = "__gdn_ctype"; // canonical type mapping (From -> To)
const HELPER_TOKPAIR = "__gdn_tokpair"; // (A<B sym, shared token sym)

// A read-only in-memory snapshot of the live store's entity/edge relations.
// Every string is NUL-terminated (dupeZ) so the apply path may hand it
// straight to dl_intern_str / dl_rev_get / dl_txn_cas.
const Entity = struct { name: []const u8, ty: []const u8 };
const EdgeRec = struct { from: []const u8, to: []const u8, ty: []const u8 };

const Snap = struct {
    alloc: Alloc,
    entities: std.ArrayListUnmanaged(Entity),
    edges: std.ArrayListUnmanaged(EdgeRec),

    fn deinit(s: *Snap) void {
        for (s.entities.items) |e| {
            s.alloc.free(e.name);
            s.alloc.free(e.ty);
        }
        for (s.edges.items) |e| {
            s.alloc.free(e.from);
            s.alloc.free(e.to);
            s.alloc.free(e.ty);
        }
        s.entities.deinit(s.alloc);
        s.edges.deinit(s.alloc);
    }
};

// Read the planning inputs from the LIVE store. The caller holds the store's
// write lock; this is the only window the lock is held (milliseconds).
fn readSnapshot(db: Db, alloc: Alloc) Snap {
    var snap = Snap{ .alloc = alloc, .entities = .empty, .edges = .empty };
    var ctx = Ctx{ .db = db, .alloc = alloc };

    {
        var ebuf = prefix(&ctx, "entity", &.{}, 0);
        defer ebuf.deinit(alloc);
        var k: usize = 0;
        while (k + 2 <= ebuf.items.len) : (k += 2) {
            const name = std.mem.span(dl.dl_intern_str_of(db, ebuf.items[k]) orelse continue);
            const ty = std.mem.span(dl.dl_intern_str_of(db, ebuf.items[k + 1]) orelse continue);
            const nz = alloc.dupeZ(u8, name) catch continue;
            const tz = alloc.dupeZ(u8, ty) catch {
                alloc.free(nz);
                continue;
            };
            snap.entities.append(alloc, .{ .name = nz, .ty = tz }) catch {
                alloc.free(nz);
                alloc.free(tz);
            };
        }
    }

    {
        var ebuf = prefix(&ctx, "edge", &.{}, 0);
        defer ebuf.deinit(alloc);
        var k: usize = 0;
        while (k + 3 <= ebuf.items.len) : (k += 3) {
            const f = std.mem.span(dl.dl_intern_str_of(db, ebuf.items[k]) orelse continue);
            const t = std.mem.span(dl.dl_intern_str_of(db, ebuf.items[k + 1]) orelse continue);
            const r = std.mem.span(dl.dl_intern_str_of(db, ebuf.items[k + 2]) orelse continue);
            const fz = alloc.dupeZ(u8, f) catch continue;
            const tz = alloc.dupeZ(u8, t) catch {
                alloc.free(fz);
                continue;
            };
            const rz = alloc.dupeZ(u8, r) catch {
                alloc.free(fz);
                alloc.free(tz);
                continue;
            };
            snap.edges.append(alloc, .{ .from = fz, .to = tz, .ty = rz }) catch {
                alloc.free(fz);
                alloc.free(tz);
                alloc.free(rz);
            };
        }
    }
    return snap;
}

// A throwaway store (fresh dir under /tmp) that hosts the Datalog evaluation.
// The live store is never opened here — planning runs lock-free against this.
const Scratch = struct {
    alloc: Alloc,
    db: Db,
    dir: []const u8, // owned, NUL-terminated scratch dir path
    syms: std.StringHashMapUnmanaged(u32),

    fn intern(sc: *Scratch, s: []const u8) u32 {
        if (sc.syms.get(s)) |sym| return sym;
        const z = sc.alloc.dupeZ(u8, s) catch return 0;
        defer sc.alloc.free(z);
        const sym = dl.dl_intern_str(sc.db, z.ptr);
        if (sym == 0) return 0;
        const key = sc.alloc.dupe(u8, s) catch return sym;
        sc.syms.put(sc.alloc, key, sym) catch sc.alloc.free(key);
        return sym;
    }
};

fn openScratch(alloc: Alloc, io: std.Io) ?Scratch {
    const dir = std.fmt.allocPrintSentinel(alloc, "/tmp/fx-gardener-scratch-{d}", .{std.os.linux.getpid()}, 0) catch return null;
    // Clear a stale dir left by a previous crashed run that reused this pid.
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, dir) catch {};
    mkdir_p(dir);
    const db = open_with_retry(dir) orelse {
        alloc.free(dir);
        return null;
    };
    const sc = Scratch{ .alloc = alloc, .db = db, .dir = dir, .syms = .empty };
    // The tier rules reference entity/edge directly, so they must exist even
    // on a fresh store. Declarations are idempotent.
    if (dl.dl_declare_relation(db, "entity", 2) != 0 or
        dl.dl_declare_relation(db, "edge", 3) != 0 or
        dl.dl_declare_relation(db, HELPER_CTYPE, 2) != 0 or
        dl.dl_declare_relation(db, HELPER_TOKPAIR, 3) != 0)
    {
        dl.dl_close(db);
        alloc.free(dir);
        die("error: cannot declare scratch relations", .{});
    }
    return sc;
}

fn closeScratch(sc: *Scratch, io: std.Io) void {
    var it = sc.syms.iterator();
    while (it.next()) |e| sc.alloc.free(e.key_ptr.*);
    sc.syms.deinit(sc.alloc);
    dl.dl_close(sc.db);
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, sc.dir) catch {};
    sc.alloc.free(sc.dir);
}

// Write one CSV row of raw u32 values (already interned sym ids) to `f`.
fn csvInts(f: *l.FILE, cols: []const u32) void {
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    for (cols, 0..) |c, i| {
        if (i > 0) {
            buf[n] = ',';
            n += 1;
        }
        const s = std.fmt.bufPrint(buf[n..], "{d}", .{c}) catch return;
        n += s.len;
    }
    buf[n] = '\n';
    n += 1;
    _ = l.fwrite(buf[0..n].ptr, 1, n, f);
}

// Bulk-load one relation's facts from `path` (raw integers). dl_load_facts
// builds the DAFSA once and saves once — no per-fact WAL/fsync (dl_add_fact's
// per-fact fsync was the 20-minute lock-hold root cause).
fn scratchLoad(sc: *Scratch, rel: []const u8, path: []const u8) void {
    if (dl.dl_load_facts(sc.db, rel.ptr, path.ptr) < 0)
        die("error: cannot load scratch facts for '{s}'", .{rel});
}

// The tier program, in the datalog-dafsa dialect. Negation is grounded (A,B
// bound by gdn_above); the aggregate-result comparison is split into the
// downstream gdn_above rule to avoid the ungrounded-comparison bug; helper
// predicates with a leading '_' are double-quoted (otherwise '_' tokenizes as
// a variable). min_shared is substituted as an integer literal.
fn buildRules(alloc: Alloc, min_shared: u32) [:0]const u8 {
    return std.fmt.allocPrintSentinel(alloc,
        \\gdn_has_edge(A,B) :- edge(A,B,R).
        \\type_freq(T,C) :- entity(E,T), C=count().
        \\type_rename(E,From,To) :- entity(E,From), "__gdn_ctype"(From,To), From!=To.
        \\gdn_candidate_pair(A,B,C) :- "__gdn_tokpair"(A,B,T), C=count().
        \\gdn_above(A,B,C) :- gdn_candidate_pair(A,B,C), C>={d}.
        \\gdn_candidate_final(A,B,C) :- gdn_above(A,B,C), !gdn_has_edge(A,B), !gdn_has_edge(B,A).
    , .{min_shared}, 0) catch return "";
}

// Run the program and stream one goal into a flat tuple buffer (stride =
// goal arity).
fn queryGoal(db: Db, alloc: Alloc, rules: [:0]const u8, goal: [*:0]const u8) TupleBuf {
    var collect = Collect{ .buf = .empty, .alloc = alloc };
    const n = dl_query_rules_ro(db, rules.ptr, goal, tuple_cb, &collect);
    if (n < 0) {
        errOut("error: dl_query_rules_ro goal '{s}' failed\n", .{goal});
        std.process.exit(1);
    }
    return collect.buf;
}

// Compute all deterministic tiers into `plan`. type_rename / type_freq /
// candidate_pair run as native Datalog via dl_query_rules_ro against a
// THROWAWAY scratch store — never the live store, never under its lock;
// duplicate_pair stays Zig-side because the corrected keeper grouping (one
// lexicographically smallest keeper per norm group) is not expressible as the
// naive pairwise join and would reintroduce the multi-way-merge corruption.
// Helper facts (__gdn_ctype, __gdn_tokpair) are bulk-loaded into the scratch
// store, never into the live one, so planning is 100% read-only with respect
// to the live store.
fn computeTiers(alloc: Alloc, io: std.Io, snap: *Snap, plan: *Plan, min_shared: u32, max_token_holders: u32) void {
    // ---- duplicate_pair (Zig-side, corrected keeper grouping)
    {
        var map = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
        defer {
            for (map.values()) |*v| v.deinit(alloc);
            map.deinit(alloc);
        }
        for (snap.entities.items) |e| {
            const nstr = norm_name(alloc, e.name);
            defer alloc.free(nstr);
            if (nstr.len == 0) continue;
            const gop = map.getOrPut(alloc, nstr) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = alloc.dupe(u8, nstr) catch continue;
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.append(alloc, e.name) catch {};
        }
        for (map.values()) |grp| {
            if (grp.items.len < 2) continue;
            var keeper: []const u8 = grp.items[0];
            for (grp.items[1..]) |m| {
                if (std.mem.order(u8, m, keeper) == .lt) keeper = m;
            }
            for (grp.items) |member| {
                if (std.mem.eql(u8, member, keeper)) continue;
                plan.dups.append(alloc, .{ .a = keeper, .b = member, .count = 0 }) catch {};
            }
        }
    }

    // ---- scratch store: intern + bulk-load entity/edge/ctype/tokpair, run engine
    var sc = openScratch(alloc, io) orelse die("error: cannot open scratch store", .{});
    defer closeScratch(&sc, io);

    // entity(name, type)
    {
        const path = std.fmt.allocPrintSentinel(alloc, "{s}/entity.csv", .{sc.dir}, 0) catch die("oom", .{});
        defer alloc.free(path);
        {
            const f = l.fopen(path.ptr, "w") orelse die("error: cannot write scratch entity csv", .{});
            defer _ = l.fclose(f);
            for (snap.entities.items) |e| {
                const ns = sc.intern(e.name);
                const ts = sc.intern(e.ty);
                if (ns == 0 or ts == 0) continue;
                csvInts(f, &.{ ns, ts });
            }
        }
        scratchLoad(&sc, "entity", path);
    }

    // edge(from, to, type)
    {
        const path = std.fmt.allocPrintSentinel(alloc, "{s}/edge.csv", .{sc.dir}, 0) catch die("oom", .{});
        defer alloc.free(path);
        {
            const f = l.fopen(path.ptr, "w") orelse die("error: cannot write scratch edge csv", .{});
            defer _ = l.fclose(f);
            for (snap.edges.items) |e| {
                const fs = sc.intern(e.from);
                const ts = sc.intern(e.to);
                const rs = sc.intern(e.ty);
                if (fs == 0 or ts == 0 or rs == 0) continue;
                csvInts(f, &.{ fs, ts, rs });
            }
        }
        scratchLoad(&sc, "edge", path);
    }

    // __gdn_ctype(From, To) — canonical type table
    {
        const path = std.fmt.allocPrintSentinel(alloc, "{s}/ctype.csv", .{sc.dir}, 0) catch die("oom", .{});
        defer alloc.free(path);
        {
            const f = l.fopen(path.ptr, "w") orelse die("error: cannot write scratch ctype csv", .{});
            defer _ = l.fclose(f);
            for (canonical_type_table) |row| {
                const fs = sc.intern(row[0]);
                const ts = sc.intern(row[1]);
                if (fs == 0 or ts == 0) continue;
                csvInts(f, &.{ fs, ts });
            }
        }
        scratchLoad(&sc, HELPER_CTYPE, path);
    }

    // __gdn_tokpair(A, B, T) — for each token, every (A < B) pair of holders
    {
        var tokmap = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(u32)).empty;
        defer {
            var it = tokmap.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit(alloc);
                alloc.free(e.key_ptr.*);
            }
            tokmap.deinit(alloc);
        }
        for (snap.entities.items) |e| {
            const esym = sc.intern(e.name);
            if (esym == 0) continue;
            var toks = tokenize(alloc, e.name);
            defer toks.deinit(alloc);
            defer for (toks.items) |t| alloc.free(t);
            for (toks.items) |tok| {
                const gop = tokmap.getOrPut(alloc, tok) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                    gop.key_ptr.* = alloc.dupe(u8, tok) catch {
                        _ = tokmap.swapRemove(tok);
                        continue;
                    };
                }
                gop.value_ptr.append(alloc, esym) catch {};
            }
        }
        const path = std.fmt.allocPrintSentinel(alloc, "{s}/tokpair.csv", .{sc.dir}, 0) catch die("oom", .{});
        defer alloc.free(path);
        {
            const f = l.fopen(path.ptr, "w") orelse die("error: cannot write scratch tokpair csv", .{});
            defer _ = l.fclose(f);
            var it = tokmap.iterator();
            while (it.next()) |e| {
                const holders = e.value_ptr.items;
                if (holders.len < 2) continue;
                // Cap the O(n^2) pair blowup: a token shared by more than
                // max_token_holders entities is a near-stopword (on the real
                // store "handoff" alone, on 1887 of ~3543 entities, emits
                // ~1.8M pairs). Such tokens are skipped entirely, so candidate
                // semantics are unchanged for every token at or below the cap
                // and only stopword-dominated pairs are dropped.
                if (holders.len > max_token_holders) continue;
                const tsym = sc.intern(e.key_ptr.*);
                if (tsym == 0) continue;
                var p: usize = 0;
                while (p < holders.len) : (p += 1) {
                    var q: usize = p + 1;
                    while (q < holders.len) : (q += 1) {
                        const a = @min(holders[p], holders[q]);
                        const b = @max(holders[p], holders[q]);
                        if (a == b) continue; // self-pair from a duplicate token
                        csvInts(f, &.{ a, b, tsym });
                    }
                }
            }
        }
        scratchLoad(&sc, HELPER_TOKPAIR, path);
    }

    const rules = buildRules(alloc, min_shared);
    defer alloc.free(rules);

    // type_rename(E,From,To)
    {
        var buf = queryGoal(sc.db, alloc, rules, "type_rename");
        defer buf.deinit(alloc);
        var k: usize = 0;
        while (k + 3 <= buf.items.len) : (k += 3) {
            const nm = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k]) orelse continue);
            const from = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k + 1]) orelse continue);
            const to = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k + 2]) orelse continue);
            plan.renames.append(alloc, .{
                .name = alloc.dupeZ(u8, nm) catch continue,
                .from = alloc.dupeZ(u8, from) catch continue,
                .to = alloc.dupeZ(u8, to) catch continue,
            }) catch {};
        }
    }

    // type_freq(T,C)
    {
        var buf = queryGoal(sc.db, alloc, rules, "type_freq");
        defer buf.deinit(alloc);
        var k: usize = 0;
        while (k + 2 <= buf.items.len) : (k += 2) {
            const ty = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k]) orelse continue);
            plan.type_freq.append(alloc, .{
                .a = alloc.dupeZ(u8, ty) catch continue,
                .b = "",
                .count = buf.items[k + 1],
            }) catch {};
        }
    }

    // candidate pairs (A,B,C) — engine pre-sorts by sym_id; re-sort lexically
    // to preserve the apply-path's a<=b ordering exactly.
    {
        var buf = queryGoal(sc.db, alloc, rules, "gdn_candidate_final");
        defer buf.deinit(alloc);
        var k: usize = 0;
        while (k + 3 <= buf.items.len) : (k += 3) {
            const a = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k]) orelse continue);
            const b = std.mem.span(dl.dl_intern_str_of(sc.db, buf.items[k + 1]) orelse continue);
            const cnt = buf.items[k + 2];
            const first = if (std.mem.order(u8, a, b) == .gt) b else a;
            const second = if (std.mem.order(u8, a, b) == .gt) a else b;
            plan.cands.append(alloc, .{
                .a = alloc.dupeZ(u8, first) catch continue,
                .b = alloc.dupeZ(u8, second) catch continue,
                .count = cnt,
            }) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// tiers
// ---------------------------------------------------------------------------
const USAGE =
    \\fx-agent-gardener — deterministic memory-graph gardener (dry-run by default)
    \\
    \\usage: fx-agent-gardener [--db <dir>|-d <dir>] [--apply]
    \\                         [--validator none|local|openapi] [--api-url <url>]
    \\                         [--api-key <k>] [--model <m>]
    \\                         [--min-shared <n>] [--max-candidates <n>]
    \\
    \\  --apply            apply the plan (default: dry-run, prints would-* lines)
    \\  --validator none   no LLM gate; candidate pairs printed only
    \\  --validator local  Ollama /api/generate at --api-url
    \\  --validator openapi OpenAI-compatible /chat/completions at --api-url
    \\  --min-shared <n>   minimum shared tokens for a candidate (default 2)
    \\  --max-candidates <n> cap on applied relations per run (default 80)
    \\  --max-token-holders <n> skip tokens shared by >n entities (near-stopwords; default 64)
    \\
;

pub fn main(init: std.process.Init) void {
    const alloc = std.heap.c_allocator;
    var arglist = std.ArrayListUnmanaged([]const u8).empty;
    for (init.minimal.args.vector) |a| arglist.append(alloc, std.mem.span(a)) catch {
        std.debug.print("oom\n", .{});
        std.process.exit(1);
    };
    defer arglist.deinit(alloc);
    const args = arglist.items;

    var dbdir: []const u8 = db_path_from_env();
    var apply = false;
    var validator: Validator = .none;
    var api_url: []const u8 = "http://127.0.0.1:8322/v1";
    var api_key: []const u8 = "";
    var model: []const u8 = "qwen3:0.6b";
    var min_shared: u32 = 2;
    var max_candidates: u32 = 80;
    var max_token_holders: u32 = 64;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            emit("{s}", .{USAGE});
            return;
        } else if ((std.mem.eql(u8, a, "--db") or std.mem.eql(u8, a, "-d")) and i + 1 < args.len) {
            i += 1;
            dbdir = args[i];
        } else if (std.mem.eql(u8, a, "--apply")) {
            apply = true;
        } else if (std.mem.eql(u8, a, "--validator") and i + 1 < args.len) {
            i += 1;
            const v = args[i];
            validator = if (std.mem.eql(u8, v, "local"))
                .local
            else if (std.mem.eql(u8, v, "openapi"))
                .openapi
            else if (std.mem.eql(u8, v, "none"))
                .none
            else
                die("error: --validator must be none|local|openapi", .{});
        } else if (std.mem.eql(u8, a, "--api-url") and i + 1 < args.len) {
            i += 1;
            api_url = args[i];
        } else if (std.mem.eql(u8, a, "--api-key") and i + 1 < args.len) {
            i += 1;
            api_key = args[i];
        } else if (std.mem.eql(u8, a, "--model") and i + 1 < args.len) {
            i += 1;
            model = args[i];
        } else if (std.mem.eql(u8, a, "--min-shared") and i + 1 < args.len) {
            i += 1;
            min_shared = std.fmt.parseInt(u32, args[i], 10) catch die("error: --min-shared needs a number", .{});
        } else if (std.mem.eql(u8, a, "--max-candidates") and i + 1 < args.len) {
            i += 1;
            max_candidates = std.fmt.parseInt(u32, args[i], 10) catch die("error: --max-candidates needs a number", .{});
        } else if (std.mem.eql(u8, a, "--max-token-holders") and i + 1 < args.len) {
            i += 1;
            max_token_holders = std.fmt.parseInt(u32, args[i], 10) catch die("error: --max-token-holders needs a number", .{});
        } else {
            errOut("error: unknown flag '{s}'\n{s}", .{ a, USAGE });
            std.process.exit(1);
        }
    }

    mkdir_p(dbdir);

    // ---- Phase 1: open -> read snapshot -> close. The lock is held only for
    // this read window (milliseconds); everything after runs lock-free.
    const db = open_with_retry(dbdir) orelse {
        errOut("error: could not acquire memory lock on {s}\n", .{dbdir});
        std.process.exit(1);
    };
    var snap = readSnapshot(db, alloc);
    dl.dl_close(db);
    defer snap.deinit();

    var plan = Plan.init();

    // ---- Phase 2: planning + LLM validation with NO store open.
    computeTiers(alloc, init.io, &snap, &plan, min_shared, max_token_holders);

    if (apply) {
        // LLM validation (the slow part) runs here, lock-free, BEFORE any
        // reopen. Reproduce the apply loop's validation order exactly: skip
        // candidates below the shared-token floor and those whose endpoint a
        // merge will delete (the apply loop still re-checks endpoint liveness
        // against the live store).
        var judge = Judge{
            .alloc = alloc,
            .validator = validator,
            .api_url = api_url,
            .api_key = api_key,
            .model = model,
        };
        var merged_away = std.StringHashMapUnmanaged(void).empty;
        defer merged_away.deinit(alloc);
        for (plan.dups.items) |d| merged_away.put(alloc, d.b, {}) catch {};

        var n_approved: usize = 0;
        for (plan.cands.items) |c| {
            if (n_approved >= max_candidates) break;
            if (c.count < min_shared) {
                plan.approved.append(alloc, false) catch {};
                continue;
            }
            const skip = merged_away.contains(c.a) or merged_away.contains(c.b);
            const ok = !skip and judgeApprove(&judge, c.a, c.b, c.count);
            plan.approved.append(alloc, ok) catch {};
            if (ok) n_approved += 1;
        }
    }

    // ---- dry-run output (no reopen needed)
    if (!apply) {
        for (plan.type_freq.items) |f| {
            emit("type-freq {s} = {d}\n", .{ f.a, f.count });
        }
        for (plan.renames.items) |r| {
            emit("would-rename type of '{s}': {s} -> {s}\n", .{ r.name, r.from, r.to });
        }
        for (plan.dups.items) |d| {
            emit("would-merge '{s}' <- '{s}' (same normalized name)\n", .{ d.a, d.b });
        }
        for (plan.cands.items, 0..) |c, idx| {
            if (idx >= max_candidates) break;
            emit("would-relate '{s}' -> '{s}' (shared={d})\n", .{ c.a, c.b, c.count });
        }
        if (plan.renames.items.len + plan.dups.items.len + plan.cands.items.len == 0) {
            emit("garden: nothing to do\n", .{});
        } else {
            emit("plan: {d} renames, {d} merges, {d} candidate relations (dry-run; --apply to execute)\n", .{
                plan.renames.items.len,
                plan.dups.items.len,
                plan.cands.items.len,
            });
        }
        return;
    }

    // ---- Phase 3: reopen -> apply -> close.
    const db2 = open_with_retry(dbdir) orelse {
        errOut("error: could not reacquire memory lock on {s}\n", .{dbdir});
        std.process.exit(1);
    };
    defer dl.dl_close(db2);

    var ctx = Ctx{ .db = db2, .alloc = alloc };

    var n_renames: usize = 0;
    for (plan.renames.items) |r| {
        var attempts: usize = 0;
        while (!renameOnce(&ctx, r.name, r.from, r.to)) {
            attempts += 1;
            if (attempts >= APPLY_ATTEMPTS) die("error: revision conflict, giving up", .{});
        }
        n_renames += 1;
        emit("renamed type of '{s}': {s} -> {s}\n", .{ r.name, r.from, r.to });
    }

    var n_merges: usize = 0;
    for (plan.dups.items) |d| {
        var attempts: usize = 0;
        while (!mergeOnce(&ctx, d.a, d.b)) {
            attempts += 1;
            if (attempts >= APPLY_ATTEMPTS) die("error: revision conflict, giving up", .{});
        }
        n_merges += 1;
        emit("merged '{s}' <- '{s}'\n", .{ d.a, d.b });
    }

    var n_rels: usize = 0;
    for (plan.cands.items, 0..) |c, idx| {
        if (n_rels >= max_candidates) break;
        if (c.count < min_shared) continue;
        if (idx >= plan.approved.items.len or !plan.approved.items[idx]) continue;
        // a/b may have been merged away by the duplicate tier above; only
        // relate still-existing endpoints (avoids dangling edges).
        if (!entityExists(&ctx, c.a) or !entityExists(&ctx, c.b)) continue;
        var attempts: usize = 0;
        while (!relateOnce(&ctx, c.a, c.b, "related_to")) {
            attempts += 1;
            if (attempts >= APPLY_ATTEMPTS) die("error: revision conflict, giving up", .{});
        }
        n_rels += 1;
        emit("related '{s}' -> '{s}' (shared={d})\n", .{ c.a, c.b, c.count });
    }

    emit("applied: {d} renames, {d} merges, {d} relations\n", .{ n_renames, n_merges, n_rels });
}

// ---------------------------------------------------------------------------
// unit tests (tokenize/norm + the rule-source smoke path)
// ---------------------------------------------------------------------------
test "norm_name strips separators and lowercases" {
    const a = std.testing.allocator;
    const n1 = norm_name(a, "Mistral-Vibe_2");
    defer a.free(n1);
    try std.testing.expectEqualStrings("mistralvibe2", n1);
    const n2 = norm_name(a, "Palimpsest toolkit");
    defer a.free(n2);
    try std.testing.expectEqualStrings("palimpsesttoolkit", n2);
}

test "tokenize splits on non-alnum and lowercases" {
    var toks = tokenize(std.testing.allocator, "fx-Agent-Memory v2");
    defer toks.deinit(std.testing.allocator);
    defer for (toks.items) |t| std.testing.allocator.free(t);
    try std.testing.expectEqual(@as(usize, 4), toks.items.len);
    try std.testing.expectEqualStrings("agent", toks.items[1]);
}

test "firstInt finds verdict" {
    try std.testing.expectEqual(@as(?i32, 1), firstInt("abc 1"));
    try std.testing.expectEqual(@as(?i32, 0), firstInt("xyz0def"));
    try std.testing.expectEqual(@as(?i32, null), firstInt("no digits"));
}
