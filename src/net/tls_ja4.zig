//! JA4 de um ClientHello (a impressão TLS que a Cloudflare usa; especificação da FoxIO):
//! "t13d1516h2_<cifras>_<extensões e assinaturas>". Ignora os valores GREASE e a ordem
//! das extensões, que o Chrome sorteia. O teste monta o ClientHello do perfil do Chrome
//! (src/platform/tls_chrome.c) na memória e confere que dá o JA4 de um Chrome de
//! verdade, o mesmo que tools/tls_check.sh mede pela rede.
const std = @import("std");

/// O do Chromium 156, medido em tls.peet.ws (tools/tls_check.sh).
pub const chrome = "t13d1516h2_8daaf6152771_806a8c22fdea";

fn grease(v: u16) bool {
    return v & 0x0f0f == 0x0a0a and v >> 8 == v & 0xff;
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) ?[]const u8 {
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    fn int(r: *Reader, comptime T: type) ?T {
        const s = r.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .big);
    }
    fn vec(r: *Reader, comptime Len: type) ?[]const u8 {
        return r.take(r.int(Len) orelse return null);
    }
};

/// Os 12 primeiros dígitos do SHA-256 da lista de códigos de 4 dígitos separados por vírgula.
fn hash12(out: *[12]u8, text: []const u8) void {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    out.* = hex[0..12].*;
}

fn codes(w: *std.ArrayList(u8), gpa: std.mem.Allocator, list: []const u16) !void {
    for (list, 0..) |v, i| {
        if (i > 0) try w.append(gpa, ',');
        try w.print(gpa, "{x:0>4}", .{v});
    }
}

/// `hello`: a mensagem ClientHello (tipo 1), sem o cabeçalho do registro.
pub fn ja4(gpa: std.mem.Allocator, hello: []const u8) ![]u8 {
    var r: Reader = .{ .b = hello };
    if ((r.int(u8) orelse return error.Truncado) != 1) return error.NaoEClientHello;
    _ = r.take(3 + 2 + 32) orelse return error.Truncado;
    _ = r.vec(u8) orelse return error.Truncado;
    var ciphers: std.ArrayList(u16) = .empty;
    defer ciphers.deinit(gpa);
    var cr: Reader = .{ .b = r.vec(u16) orelse return error.Truncado };
    while (cr.int(u16)) |v| if (!grease(v)) try ciphers.append(gpa, v);
    _ = r.vec(u8) orelse return error.Truncado;
    var exts: std.ArrayList(u16) = .empty;
    defer exts.deinit(gpa);
    var sigalgs: std.ArrayList(u16) = .empty;
    defer sigalgs.deinit(gpa);
    var n_ext: usize = 0;
    var version: u16 = 0;
    var sni = false;
    var alpn: [2]u8 = "00".*;
    var er: Reader = .{ .b = r.vec(u16) orelse return error.Truncado };
    while (er.int(u16)) |kind| {
        var data: Reader = .{ .b = er.vec(u16) orelse return error.Truncado };
        if (grease(kind)) continue;
        n_ext += 1;
        switch (kind) {
            0x0000 => sni = true,
            0x0010 => {
                var list: Reader = .{ .b = data.vec(u16) orelse return error.Truncado };
                const first = list.vec(u8) orelse return error.Truncado;
                if (first.len > 0) alpn = .{ first[0], first[first.len - 1] };
            },
            0x000d => {
                var list: Reader = .{ .b = data.vec(u16) orelse return error.Truncado };
                while (list.int(u16)) |v| if (!grease(v)) try sigalgs.append(gpa, v);
            },
            0x002b => {
                var list: Reader = .{ .b = data.vec(u8) orelse return error.Truncado };
                while (list.int(u16)) |v| if (!grease(v)) {
                    version = @max(version, v);
                };
            },
            else => {},
        }
        if (kind != 0x0000 and kind != 0x0010) try exts.append(gpa, kind);
    }
    std.mem.sort(u16, ciphers.items, {}, std.sort.asc(u16));
    std.mem.sort(u16, exts.items, {}, std.sort.asc(u16));
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try codes(&text, gpa, ciphers.items);
    var b: [12]u8 = undefined;
    hash12(&b, text.items);
    text.clearRetainingCapacity();
    try codes(&text, gpa, exts.items);
    if (sigalgs.items.len > 0) {
        try text.append(gpa, '_');
        try codes(&text, gpa, sigalgs.items);
    }
    var cpart: [12]u8 = undefined;
    hash12(&cpart, text.items);
    const ver = switch (version) {
        0x0304 => "13",
        0x0303 => "12",
        else => "00",
    };
    return std.fmt.allocPrint(gpa, "t{s}{c}{d:0>2}{d:0>2}{s}_{s}_{s}", .{ ver, @as(u8, if (sni) 'd' else 'i'), @min(ciphers.items.len, 99), @min(n_ext, 99), &alpn, &b, &cpart });
}

const t = std.testing;

test "JA4: as listas do Chrome dão o JA4 do Chrome" {
    // O ja4_r do Chromium 156 (tls.peet.ws), refeito aqui: cifras, extensões (sem o
    // nome do servidor e o ALPN, que só contam) e as assinaturas na ordem.
    var b: [12]u8 = undefined;
    hash12(&b, "002f,0035,009c,009d,1301,1302,1303,c013,c014,c02b,c02c,c02f,c030,cca8,cca9");
    try t.expectEqualStrings("8daaf6152771", &b);
    hash12(&b, "0005,000a,000b,000d,0012,0017,001b,0023,002b,002d,0033,44cd,fe0d,ff01_0904,0905,0906,0403,0804,0401,0503,0805,0501,0806,0601");
    try t.expectEqualStrings("806a8c22fdea", &b);
}

extern fn larper_tls_client_hello(out: [*]u8, cap: c_int) c_int;
extern fn larper_tls_openssl_version() c_ulong;

test "o perfil do Chrome no OpenSSL dá o JA4 de um Chrome de verdade" {
    // Só onde o teste liga o OpenSSL (build.zig, `tls_test`).
    if (@import("tls_test").on) {
        // ML-KEM e ML-DSA chegaram no OpenSSL 3.5; antes, o perfil fica com o que der.
        if (larper_tls_openssl_version() < 0x30500000) return error.SkipZigTest;
        var buf: [8192]u8 = undefined;
        const n = larper_tls_client_hello(&buf, buf.len);
        try t.expect(n > 0);
        const got = try ja4(t.allocator, buf[0..@intCast(n)]);
        defer t.allocator.free(got);
        try t.expectEqualStrings(chrome, got);
    } else return error.SkipZigTest;
}
