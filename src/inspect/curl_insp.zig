//! O pedaço da aba Rede que conversa com o curl: os cabeçalhos que saíram (menos o
//! Authorization), os que voltaram e os tempos de cada fase (nome, conexão, TLS, primeiro
//! byte, total), para quem faz pedidos (net/discord.zig, ui/images.zig, os plugins).
const std = @import("std");
const c = @import("c");
const reg = @import("registros.zig");

const gpa = std.heap.c_allocator;

/// Os cabeçalhos de uma lista do curl, um por linha. O Authorization nunca entra.
pub fn requestHeaders(out: *std.ArrayList(u8), list: ?*c.struct_curl_slist, user_agent: ?[]const u8) void {
    var it = list;
    while (it) |n| : (it = n.*.next) requestLine(out, std.mem.span(n.*.data orelse continue));
    userAgent(out, user_agent);
}

pub fn requestLine(out: *std.ArrayList(u8), line: []const u8) void {
    if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
        out.appendSlice(gpa, "Authorization: (oculto pelo Inspetor)\n") catch return;
        return;
    }
    // A chave de API que um plugin manda (larper.http com @credentials) também não.
    if (std.ascii.startsWithIgnoreCase(line, "x-api-key:")) {
        out.appendSlice(gpa, "X-API-Key: (oculto pelo Inspetor)\n") catch return;
        return;
    }
    // "Content-Type:" vazio é o jeito de pedir ao curl que não invente um.
    if (std.mem.endsWith(u8, line, ":")) return;
    out.appendSlice(gpa, line) catch return;
    out.append(gpa, '\n') catch return;
}

fn userAgent(out: *std.ArrayList(u8), user_agent: ?[]const u8) void {
    if (user_agent) |ua| {
        out.appendSlice(gpa, "User-Agent: ") catch return;
        out.appendSlice(gpa, ua) catch return;
        out.append(gpa, '\n') catch return;
    }
}

/// Uma linha de cabeçalho da resposta (do HEADERFUNCTION de quem pediu).
pub fn responseHeader(out: *std.ArrayList(u8), line: []const u8) void {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    if (l.len == 0) return;
    // Um redirecionamento ou um 100-continue começa outra resposta: só a última fica.
    if (std.mem.startsWith(u8, l, "HTTP/")) out.clearRetainingCapacity();
    if (std.ascii.startsWithIgnoreCase(l, "set-cookie:")) {
        out.appendSlice(gpa, "Set-Cookie: (oculto pelo Inspetor)\n") catch return;
        return;
    }
    out.appendSlice(gpa, l) catch return;
    out.append(gpa, '\n') catch return;
}

fn timeUs(h: *c.CURL, info: c.CURLINFO) u32 {
    var v: c.curl_off_t = 0;
    if (c.curl_easy_getinfo(h, info, &v) != c.CURLE_OK) return 0;
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u32)));
}

/// O que o curl sabe do pedido que terminou (status, tipo, versão do HTTP e os tempos).
pub fn endInfo(h: *c.CURL, e: *reg.NetLog.End) void {
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(h, c.CURLINFO_RESPONSE_CODE, &status);
    if (e.status == 0) e.status = @intCast(std.math.clamp(status, 0, 999));
    var ct: [*c]const u8 = null;
    if (c.curl_easy_getinfo(h, c.CURLINFO_CONTENT_TYPE, &ct) == c.CURLE_OK and ct != null) e.content_type = std.mem.span(ct);
    var ver: c_long = 0;
    if (c.curl_easy_getinfo(h, c.CURLINFO_HTTP_VERSION, &ver) == c.CURLE_OK) e.http = switch (ver) {
        c.CURL_HTTP_VERSION_1_0 => 10,
        c.CURL_HTTP_VERSION_1_1 => 11,
        c.CURL_HTTP_VERSION_2_0 => 20,
        c.CURL_HTTP_VERSION_3 => 30,
        else => 0,
    };
    e.t_dns = timeUs(h, c.CURLINFO_NAMELOOKUP_TIME_T);
    e.t_connect = timeUs(h, c.CURLINFO_CONNECT_TIME_T);
    e.t_tls = timeUs(h, c.CURLINFO_APPCONNECT_TIME_T);
    e.t_first = timeUs(h, c.CURLINFO_STARTTRANSFER_TIME_T);
    e.t_total = timeUs(h, c.CURLINFO_TOTAL_TIME_T);
}

const t = std.testing;

test "cabeçalhos do pedido: o Authorization nunca entra" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for ([_][]const u8{ "Authorization: segredo.de.verdade", "X-API-Key: outro.segredo", "Accept: */*", "Content-Type:" }) |l| requestLine(&out, l);
    userAgent(&out, "UA/1");
    try t.expect(std.mem.indexOf(u8, out.items, "segredo") == null);
    try t.expect(std.mem.indexOf(u8, out.items, "Accept: */*\n") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "Content-Type:") == null);
    try t.expect(std.mem.endsWith(u8, out.items, "User-Agent: UA/1\n"));
}

test "cabeçalhos da resposta: só a última resposta, sem cookie" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    responseHeader(&out, "HTTP/1.1 301 Moved\r\n");
    responseHeader(&out, "Location: x\r\n");
    responseHeader(&out, "HTTP/2 200\r\n");
    responseHeader(&out, "Set-Cookie: __dcfduid=abc\r\n");
    responseHeader(&out, "x-ratelimit-remaining: 4\r\n");
    responseHeader(&out, "\r\n");
    try t.expectEqualStrings("HTTP/2 200\nSet-Cookie: (oculto pelo Inspetor)\nx-ratelimit-remaining: 4\n", out.items);
}
