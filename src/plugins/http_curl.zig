//! Os pedidos HTTPS dos plugins, de verdade: uma thread por pedido, só enquanto
//! ele dura (parado, não existe nada). O que já foi conferido antes de chegar aqui
//! (host declarado e aprovado, URL, limites de quantidade) está em runtime.zig.
//!
//! Aqui valem os limites que dependem do curl: só HTTPS, tamanho e tempo (20 s para
//! tudo, com os redirecionamentos). Redirecionamento é seguido aqui mesmo, um de cada
//! vez, e só para um host que a pessoa aprovou para este plugin (http_policy.zig):
//! o curl nunca segue sozinho. As credenciais (Authorization, X-API-Key) não vão
//! para um host que não as leva. O pedido sai sem cookies e só com os cabeçalhos que
//! vieram na lista permitida: nada da conta do Discord passa por este arquivo. Da
//! resposta, só os cabeçalhos da lista chegam ao plugin (nunca Set-Cookie).
const std = @import("std");
const insp = @import("../inspect/registros.zig");
const insp_curl = @import("../inspect/curl_insp.zig");
const c = @import("c");
const wire = @import("wire.zig");
const http_policy = @import("http_policy.zig");
const manifest = @import("manifest.zig");
const proxy = @import("../net/proxy.zig");
const sys = @import("../platform/sys.zig");
const build_options = @import("build_options");
const version: []const u8 = build_options.version;

pub const body_max = 1024 * 1024;
const max_threads = 8;
/// Tempo de um pedido inteiro, com os redirecionamentos.
const total_ms = 20_000;
const url_max = 2100;

var flying = std.atomic.Value(u32).init(0);
var stopping = std.atomic.Value(bool).init(false);

/// Só nos builds com o robô de QA: manda tudo para um servidor local, para testar
/// o caminho inteiro sem falar com a internet. Fora deles nem compila.
pub const qa_builds = @import("../ui/qa.zig").compiled;
pub var qa_base: [if (qa_builds) 128 else 0]u8 = undefined;
pub var qa_base_len: usize = 0;
pub var qa_cainfo: [if (qa_builds) 256 else 0]u8 = undefined;
pub var qa_cainfo_len: usize = 0;

/// Começa um pedido. false = não deu (quem chama ainda é dono de `req`).
pub fn start(req: *wire.HttpReq) bool {
    if (stopping.load(.acquire)) return false;
    if (flying.fetchAdd(1, .acq_rel) >= max_threads) {
        _ = flying.fetchSub(1, .acq_rel);
        return false;
    }
    const t = c.SDL_CreateThread(threadMain, "plugin-http", req) orelse {
        _ = flying.fetchSub(1, .acq_rel);
        return false;
    };
    c.SDL_DetachThread(t);
    return true;
}

/// Cancela o que está no ar e espera acabar (ao fechar o app). Um DNS preso não
/// segura o encerramento: depois do prazo, a resposta é só descartada.
pub fn stop() void {
    stopping.store(true, .release);
    var waited: u32 = 0;
    while (flying.load(.acquire) > 0 and waited < 2000) : (waited += 10) c.SDL_Delay(10);
}

fn threadMain(raw: ?*anyopaque) callconv(.c) c_int {
    const req: *wire.HttpReq = @ptrCast(@alignCast(raw.?));
    defer _ = flying.fetchSub(1, .acq_rel);
    const gpa = req.gpa;
    var body: std.ArrayList(u8) = .empty;
    var heads: std.ArrayList(u8) = .empty;
    var res_err: wire.HttpError = .none;
    var status: u16 = 0;
    const t0 = c.SDL_GetTicks();
    perform(req, &body, &heads, &status) catch |e| {
        res_err = switch (e) {
            error.TooBig => .too_big,
            error.Redirect => .redirect,
            else => .network,
        };
        // Com erro, nem o status de um pulo do meio vale.
        status = 0;
        body.clearRetainingCapacity();
        heads.clearRetainingCapacity();
    };
    defer req.free();
    if (stopping.load(.acquire)) {
        body.deinit(gpa);
        heads.deinit(gpa);
        return 0;
    }
    const res = gpa.create(wire.HttpRes) catch {
        body.deinit(gpa);
        heads.deinit(gpa);
        return 0;
    };
    const ms: u32 = @intCast(@min(c.SDL_GetTicks() - t0, std.math.maxInt(u32)));
    res.* = .{ .run = req.run, .id = req.id, .token = req.token, .status = status, .err = res_err, .body = body.toOwnedSlice(gpa) catch &.{}, .headers = heads.toOwnedSlice(gpa) catch &.{}, .ms = ms, .log = req.log };
    req.done(req.done_ctx, res);
    return 0;
}

const Sink = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    too_big: bool = false,

    fn write(ptr: [*c]u8, size: usize, n: usize, ud: ?*anyopaque) callconv(.c) usize {
        const s: *Sink = @ptrCast(@alignCast(ud.?));
        const total = size * n;
        if (s.out.items.len + total > body_max) {
            s.too_big = true;
            return 0;
        }
        s.out.appendSlice(s.gpa, ptr[0..total]) catch return 0;
        return total;
    }
};

/// Os cabeçalhos da resposta: os da lista para o plugin, o Location para o próximo
/// pulo e, gravando, tudo para a aba Rede do Inspetor.
const HeaderSink = struct {
    gpa: std.mem.Allocator,
    heads: *std.ArrayList(u8),
    n: usize = 0,
    location: [url_max]u8 = undefined,
    location_len: usize = 0,
    insp: ?*std.ArrayList(u8) = null,

    fn line(ptr: [*c]u8, size: usize, n: usize, ud: ?*anyopaque) callconv(.c) usize {
        const s: *HeaderSink = @ptrCast(@alignCast(ud.?));
        const raw = ptr[0 .. size * n];
        if (s.insp) |out| insp_curl.responseHeader(out, raw);
        // Uma resposta nova (100-continue): só a última conta.
        if (std.mem.startsWith(u8, raw, "HTTP/")) {
            s.heads.clearRetainingCapacity();
            s.n = 0;
            s.location_len = 0;
            return raw.len;
        }
        const h = http_policy.parseResponseLine(raw) orelse return raw.len;
        if (std.ascii.eqlIgnoreCase(h.name, "location") and h.value.len <= s.location.len) {
            @memcpy(s.location[0..h.value.len], h.value);
            s.location_len = h.value.len;
        }
        if (s.n >= http_policy.max_response_headers) return raw.len;
        s.heads.ensureUnusedCapacity(s.gpa, h.name.len + h.value.len + 2) catch return raw.len;
        for (h.name) |ch| s.heads.appendAssumeCapacity(std.ascii.toLower(ch));
        s.heads.appendAssumeCapacity(0);
        s.heads.appendSliceAssumeCapacity(h.value);
        s.heads.appendAssumeCapacity(0);
        s.n += 1;
        return raw.len;
    }
};

fn progress(_: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    return if (stopping.load(.acquire)) 1 else 0;
}

fn isCredential(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    return http_policy.requestHeader(line[0..colon]) == .credential;
}

/// O pedido inteiro: segue os redirecionamentos que a política deixa, um por vez.
fn perform(req: *wire.HttpReq, out: *std.ArrayList(u8), heads: *std.ArrayList(u8), status: *u16) !void {
    var url_buf: [url_max]u8 = undefined;
    var cur: []const u8 = req.url;
    var method = req.method;
    var with_body = method.hasBody();
    var with_creds = true;
    const deadline = c.SDL_GetTicks() + total_ms;
    var hop: u8 = 0;
    while (true) : (hop += 1) {
        out.clearRetainingCapacity();
        heads.clearRetainingCapacity();
        const now = c.SDL_GetTicks();
        if (now >= deadline) return error.Network;
        var hs: HeaderSink = .{ .gpa = req.gpa, .heads = heads };
        const code = try once(req, cur, method, with_body, with_creds, deadline - now, out, &hs);
        status.* = code;
        if (!http_policy.isRedirect(code) or hs.location_len == 0) return;
        if (hop >= http_policy.max_redirects) return error.Redirect;
        var next_buf: [url_max]u8 = undefined;
        const next = http_policy.resolveLocation(&next_buf, cur, hs.location[0..hs.location_len]) orelse return error.Redirect;
        if (http_policy.redirectAllowed(req.allow, next) != .follow) return error.Redirect;
        const next_host = (manifest.parseHttps(next) orelse return error.Redirect).host;
        // Credenciais só seguem para outro host que também as leva (e foi aprovado).
        if (with_creds and !http_policy.anyMatches(req.creds, next_host)) with_creds = false;
        method = http_policy.methodAfter(code, method);
        with_body = with_body and method.hasBody();
        @memcpy(url_buf[0..next.len], next);
        cur = url_buf[0..next.len];
    }
}

/// Um pedido só, sem seguir nada. Devolve o status.
fn once(req: *wire.HttpReq, logical: []const u8, method: wire.Method, with_body: bool, with_creds: bool, left_ms: u64, out: *std.ArrayList(u8), hs: *HeaderSink) !u16 {
    const h = c.curl_easy_init() orelse return error.Network;
    defer c.curl_easy_cleanup(h);
    var sink: Sink = .{ .gpa = req.gpa, .out = out };
    var ua_buf: [64]u8 = undefined;
    const ua = std.fmt.bufPrintSentinel(&ua_buf, "larperCord/{s} (plugin)", .{version}, 0) catch "larperCord";
    var url_buf: [2400]u8 = undefined;
    var url: [:0]const u8 = std.fmt.bufPrintSentinel(&url_buf, "{s}", .{logical}, 0) catch return error.Network;
    var qa_buf: [2400]u8 = undefined;
    var plain_qa = false;
    if (qa_builds and qa_base_len > 0) {
        // https://host/resto -> base/resto
        const after = logical["https://".len..];
        const cut = std.mem.indexOfAny(u8, after, "/?") orelse after.len;
        url = std.fmt.bufPrintSentinel(&qa_buf, "{s}{s}", .{ qa_base[0..qa_base_len], after[cut..] }, 0) catch return error.Network;
        plain_qa = std.mem.startsWith(u8, qa_base[0..qa_base_len], "http://");
    }
    _ = c.curl_easy_setopt(h, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(h, c.CURLOPT_USERAGENT, ua.ptr);
    // Só HTTPS, e sem o curl seguir redirecionamento sozinho: quem segue é `perform`.
    _ = c.curl_easy_setopt(h, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, if (plain_qa) "http" else "https"));
    _ = c.curl_easy_setopt(h, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    _ = c.curl_easy_setopt(h, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(@min(left_ms, 10_000))));
    _ = c.curl_easy_setopt(h, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(@max(left_ms, 1))));
    _ = c.curl_easy_setopt(h, c.CURLOPT_MAXFILESIZE_LARGE, @as(c.curl_off_t, body_max));
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEFUNCTION, Sink.write);
    _ = c.curl_easy_setopt(h, c.CURLOPT_WRITEDATA, &sink);
    _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERFUNCTION, HeaderSink.line);
    _ = c.curl_easy_setopt(h, c.CURLOPT_HEADERDATA, hs);
    _ = c.curl_easy_setopt(h, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(h, c.CURLOPT_XFERINFOFUNCTION, progress);
    // Sem cookies: o motor de cookies do curl só liga se alguém pedir, e aqui ninguém pede.
    var list: ?*c.curl_slist = null;
    defer if (list) |l| c.curl_slist_free_all(l);
    for (req.headers) |line| {
        if (!with_creds and isCredential(line)) continue;
        list = c.curl_slist_append(list, line.ptr);
    }
    if (list) |l| _ = c.curl_easy_setopt(h, c.CURLOPT_HTTPHEADER, l);
    switch (method) {
        .GET => {},
        .HEAD => _ = c.curl_easy_setopt(h, c.CURLOPT_NOBODY, @as(c_long, 1)),
        .POST => _ = c.curl_easy_setopt(h, c.CURLOPT_POST, @as(c_long, 1)),
        .PUT, .PATCH, .DELETE => _ = c.curl_easy_setopt(h, c.CURLOPT_CUSTOMREQUEST, @as([*:0]const u8, @tagName(method))),
    }
    if (with_body and (method == .POST or req.body.len > 0)) {
        _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDS, req.body.ptr);
        _ = c.curl_easy_setopt(h, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(req.body.len)));
    }
    sys.curlTls(h);
    if (qa_builds and qa_cainfo_len > 0) _ = c.curl_easy_setopt(h, c.CURLOPT_CAINFO, @as([*]const u8, &qa_cainfo));
    var pb: proxy.Buf = undefined;
    if (proxy.forUrl(&pb, url)) |p| _ = c.curl_easy_setopt(h, c.CURLOPT_PROXY, p.ptr);
    // A aba Rede do Inspetor (só gravando), com os cabeçalhos que o plugin mandou
    // (as credenciais ficam escondidas: inspect/curl_insp.zig).
    var insp_h: std.ArrayList(u8) = .empty;
    defer insp_h.deinit(std.heap.c_allocator);
    const insp_id = if (insp.gravando()) blk: {
        var req_h: std.ArrayList(u8) = .empty;
        defer req_h.deinit(std.heap.c_allocator);
        insp_curl.requestHeaders(&req_h, list, ua);
        hs.insp = &insp_h;
        break :blk insp.net.begin(.plugin, @tagName(method), url, req_h.items, if (with_body) req.body else null, "plugins");
    } else 0;
    const rc = c.curl_easy_perform(h);
    if (insp_id != 0) {
        var e: insp.NetLog.End = .{ .resp_headers = insp_h.items, .resp_body = out.items };
        insp_curl.endInfo(h, &e);
        if (rc != c.CURLE_OK) {
            e.failed = true;
            e.note = if (sink.too_big or rc == c.CURLE_FILESIZE_EXCEEDED) "grande demais para um plugin" else std.mem.span(c.curl_easy_strerror(rc));
        }
        insp.net.end(insp_id, e);
    }
    hs.insp = null;
    if (sink.too_big or rc == c.CURLE_FILESIZE_EXCEEDED) return error.TooBig;
    if (rc != c.CURLE_OK) return error.Network;
    var code: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &code);
    return @intCast(std.math.clamp(code, 0, 65535));
}
