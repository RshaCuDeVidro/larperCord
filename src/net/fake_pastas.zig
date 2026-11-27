//! As pastas da barra na demonstração (core/pastas.zig): a gravação de verdade
//! (net/pastas_net.zig `save`, com a cópia das configurações e a versão dela) roda
//! contra um /users/@me/settings-proto/1 de mentira que responde como o Discord: GET,
//! PATCH que troca só os campos de cima que vieram, `out_of_date` quando a versão não
//! bate e a versão que sobe a cada gravação. Guarda o que "foi mandado" para o QA
//! conferir (cada pedido contado). As configurações da conta de mentira têm campos que
//! não são as pastas antes e depois delas, um campo desconhecido dentro de uma pasta e
//! outro na lista. Roda na thread do gateway falso; os contadores são atômicos porque o
//! QA lê da thread da interface.
const std = @import("std");
const sys = @import("../platform/sys.zig");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const i18n = @import("../ui/i18n.zig");
const settings_proto = @import("settings_proto.zig");
const pastas_net = @import("pastas_net.zig");

const alloc = std.heap.c_allocator;

/// Um campo de outra parte das configurações (6, texto e imagens), logo depois das
/// versões, e um campo de número alto (5000) no fim.
pub const other = "\x32\x04\x0a\x02\x08\x01";
pub const tail = "\xc2\xb8\x02\x03xyz";
/// Dentro da pasta "Jogos" (78): o campo 9, fixed64, que o app não conhece.
pub const folder_unknown = "\x49\xef\xbe\xad\xde\x00\x00\x00\x00";
/// No fim do `GuildFolders`: o campo 7, fixed32.
pub const list_unknown = "\x3d\x01\x02\x03\x04";
const path = "/users/@me/settings-proto/1";

pub const sent = struct {
    const A = sys.Atomic(u64);
    /// Pedidos ao endpoint das configurações: todos, os GETs e os PATCHes (aceitos ou não).
    pub var requests: A = .init(0);
    pub var gets: A = .init(0);
    pub var patch_calls: A = .init(0);
    /// PATCHes aceitos e o corpo do último (o QA decodifica).
    pub var patches: A = .init(0);
    pub var body_len: A = .init(0);
    pub var body: [8192]u8 = undefined;
    /// A versão das configurações na conta de mentira (`versions.data_version`).
    pub var version: A = .init(7);
    /// O último PATCH aceito levou só o campo das pastas (1) ou mais coisa (0); e os
    /// dois campos desconhecidos das pastas continuam na conta.
    pub var intact: A = .init(1);
    pub var unknown_kept: A = .init(1);
    /// O QA liga: o próximo PATCH falha como um erro do Discord; outro aparelho grava
    /// algo (a versão sobe) logo antes do próximo PATCH; a próxima gravação começa sem
    /// a cópia das configurações (como uma conta cujo READY veio em JSON).
    pub var fail_next: A = .init(0);
    pub var stale_next: A = .init(0);
    pub var forget_next: A = .init(0);
};

/// O campo 14 inteiro (chave, tamanho e conteúdo) que a conta de mentira guarda.
var folders14: std.ArrayList(u8) = .empty;
/// A cópia das configurações do lado do app (a do gateway de verdade, net/discord.zig).
var client: pastas_net.Cache = .{};

/// O que "outro aparelho" gravou (o QA põe; a thread do gateway aplica antes da
/// próxima gravação, como se o servidor já tivesse e o aviso já tivesse chegado).
var remote_buf: [4096]u8 = undefined;
var remote_len: sys.Atomic(usize) = .init(0);

fn appendVarint(out: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try out.append(alloc, @as(u8, @truncate(x)) | 0x80);
    try out.append(alloc, @truncate(x));
}

fn appendField(out: *std.ArrayList(u8), field: u64, data: []const u8) !void {
    try appendVarint(out, field << 3 | 2);
    try appendVarint(out, data.len);
    try out.appendSlice(alloc, data);
}

/// versions { client_version: 3, data_version: V }.
fn appendVersions(out: *std.ArrayList(u8)) !void {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, "\x08\x03\x18");
    try appendVarint(&inner, sent.version.load(.acquire));
    try appendField(out, 1, inner.items);
}

/// As configurações inteiras como a conta de mentira tem agora.
fn blob() ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendVersions(&out);
    try out.appendSlice(alloc, other);
    try out.appendSlice(alloc, folders14.items);
    try out.appendSlice(alloc, tail);
    return out.toOwnedSlice(alloc);
}

fn b64Of(bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

/// As pastas que a demonstração mostra no READY, nas configurações da conta.
fn seed(demo: []const types.GuildFolder) !void {
    if (folders14.items.len > 0) return;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    for (demo) |f| {
        const one = try settings_proto.encodeFolder(alloc, f, if (f.id == 78) folder_unknown else "");
        defer alloc.free(one);
        try appendField(&content, 1, one);
    }
    try content.appendSlice(alloc, list_unknown);
    try appendField(&folders14, 14, content.items);
}

/// O READY da demonstração: as configurações vão junto (`user_settings_proto`), e o
/// app guarda a cópia, como com a conta de verdade.
pub fn ready(demo: []const types.GuildFolder) !void {
    try seed(demo);
    const b = try blob();
    defer alloc.free(b);
    client.set(b);
}

/// Aplica o que "outro aparelho" gravou: na conta, o campo das pastas dele, como veio,
/// e a versão sobe; do lado do app, o USER_SETTINGS_PROTO_UPDATE parcial que chega
/// (as versões e as pastas) entra na cópia.
fn takeRemote() !void {
    const n = remote_len.load(.acquire);
    if (n == 0) return;
    defer remote_len.store(0, .release);
    const only = try settings_proto.foldersOnly(alloc, remote_buf[0..n]);
    defer alloc.free(only);
    folders14.clearRetainingCapacity();
    try folders14.appendSlice(alloc, only);
    _ = sent.version.fetchAdd(1, .acq_rel);
    var update: std.ArrayList(u8) = .empty;
    defer update.deinit(alloc);
    try appendVersions(&update);
    try update.appendSlice(alloc, only);
    const b = try b64Of(update.items);
    defer alloc.free(b);
    client.update(b, true);
}

fn hasFolder(bytes: []const u8, id: u64) bool {
    const l = settings_proto.fromProto(alloc, bytes) catch return false;
    defer l.deinit(alloc);
    for (l.folders) |f| if (f.id == id) return true;
    return false;
}

const Response = struct { status: c_long, body: std.ArrayList(u8) };

fn reply(status: c_long, out_of_date: bool) Response {
    var body: std.ArrayList(u8) = .empty;
    const b = blob() catch return .{ .status = 500, .body = body };
    defer alloc.free(b);
    const enc = b64Of(b) catch return .{ .status = 500, .body = body };
    defer alloc.free(enc);
    body.print(alloc, "{{\"settings\":\"{s}\"{s}}}", .{ enc, if (out_of_date) ",\"out_of_date\":true" else "" }) catch {};
    return .{ .status = status, .body = body };
}

fn bad() Response {
    return .{ .status = 400, .body = .empty };
}

/// O PATCH como o Discord: confere a versão, troca os campos de cima que vieram e sobe
/// a versão; responde com as configurações como ficaram.
fn patch(body: []const u8) Response {
    _ = sent.patch_calls.fetchAdd(1, .acq_rel);
    if (sent.fail_next.swap(0, .acq_rel) != 0) return .{ .status = 500, .body = .empty };
    // Outro aparelho gravou outra coisa (o status, por exemplo) e o aviso ainda não chegou.
    if (sent.stale_next.swap(0, .acq_rel) != 0) _ = sent.version.fetchAdd(1, .acq_rel);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return bad();
    if (v != .object) return bad();
    const sv = v.object.get("settings") orelse return bad();
    if (sv != .string) return bad();
    if (v.object.get("required_data_version")) |rv| {
        if (rv != .integer or rv.integer != @as(i64, @intCast(sent.version.load(.acquire)))) return reply(200, true);
    }
    const partial = @import("status_proto.zig").decodeBase64(a, sv.string) catch return bad();
    const only = settings_proto.foldersOnly(a, partial) catch return bad();
    folders14.clearRetainingCapacity();
    folders14.appendSlice(alloc, only) catch return .{ .status = 500, .body = .empty };
    _ = sent.version.fetchAdd(1, .acq_rel);
    const n = @min(body.len, sent.body.len);
    @memcpy(sent.body[0..n], body[0..n]);
    sent.body_len.store(n, .release);
    sent.intact.store(@intFromBool(std.mem.eql(u8, only, partial)), .release);
    const items = folders14.items;
    sent.unknown_kept.store(@intFromBool(std.mem.indexOf(u8, items, list_unknown) != null and
        (std.mem.indexOf(u8, items, folder_unknown) != null or !hasFolder(items, 78))), .release);
    _ = sent.patches.fetchAdd(1, .release);
    return reply(200, false);
}

/// O que net/pastas_net.zig `save` usa do gateway, ligado à conta de mentira.
fn Http(comptime G: type) type {
    return struct {
        g: *G,
        const Self = @This();

        pub fn settingsCache(_: *Self) *pastas_net.Cache {
            return &client;
        }
        pub fn emit(self: *Self, e: ev.Event) void {
            self.g.emit(e);
        }
        pub fn notice(self: *Self, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
            self.g.emit(.{ .notice = i18n.allocPrint(alloc, pt, en, args) catch return });
        }
        /// Como o do gateway de verdade, para um erro sem mensagem do Discord.
        pub fn noticeHttp(self: *Self, what: []const u8, resp: *const Response) void {
            self.notice("{s} (HTTP {d})", "{s} (HTTP {d})", .{ what, resp.status });
        }
        pub fn request(_: *Self, method: [:0]const u8, p: []const u8, body: ?[]const u8) ?Response {
            _ = sent.requests.fetchAdd(1, .acq_rel);
            if (!std.mem.eql(u8, p, path)) return .{ .status = 404, .body = .empty };
            if (std.mem.eql(u8, method, "GET")) {
                _ = sent.gets.fetchAdd(1, .acq_rel);
                return reply(200, false);
            }
            if (std.mem.eql(u8, method, "PATCH")) return patch(body orelse "");
            return .{ .status = 405, .body = .empty };
        }
    };
}

/// Uma gravação das pastas pelo caminho de verdade (net/pastas_net.zig `save`). Gravou:
/// o gateway avisa depois (USER_SETTINGS_PROTO_UPDATE), também como o de verdade.
pub fn execute(g: anytype, f: ev.FolderEdit, demo: []const types.GuildFolder) !void {
    defer pastas_net.free(f);
    if (folders14.items.len == 0) try ready(demo);
    try takeRemote();
    if (sent.forget_next.swap(0, .acq_rel) != 0) client.forget();
    const before = sent.patches.load(.acquire);
    var http: Http(@TypeOf(g.*)) = .{ .g = g };
    pastas_net.save(&http, f);
    if (sent.patches.load(.acquire) == before) return;
    const b = try blob();
    defer alloc.free(b);
    if (pastas_net.foldersOf(b)) |list| g.emit(.{ .guild_folders = list });
}

/// "Outro aparelho" mudou as pastas: o USER_SETTINGS_PROTO_UPDATE (só o campo 14,
/// `partial`), lido pelo mesmo leitor do gateway de verdade. Chamado pelo QA; a
/// conta de mentira passa a ter essas pastas na próxima gravação.
pub fn remote(proto: []const u8) ?ev.Event {
    if (proto.len > remote_buf.len) return null;
    @memcpy(remote_buf[0..proto.len], proto);
    remote_len.store(proto.len, .release);
    var b: [8192]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    if (enc.calcSize(proto.len) > b.len) return null;
    return pastas_net.eventFromBase64(enc.encode(&b, proto));
}

pub fn deinit() void {
    folders14.deinit(alloc);
    folders14 = .empty;
    client.deinit();
}
