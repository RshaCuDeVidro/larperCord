//! Os nomes de uma fonte (a família e o subgrupo) direto da tabela "name" do arquivo
//! TrueType/OpenType, e de cada face de uma coleção .ttc, lendo só o cabeçalho, o
//! diretório de tabelas e a própria tabela: a lista das fontes do Windows passa por
//! centenas de arquivos, alguns de dezenas de MB (ui/fonts.zig windowsFonts).

const std = @import("std");

/// Faces lidas de uma coleção, no máximo (as do Windows têm umas poucas).
pub const max_faces = 64;
/// A maior tabela "name" que lemos (com a licença em vários idiomas passa de 100 KB).
pub const max_table = 512 * 1024;
/// Tabelas no diretório de uma face, no máximo (as fontes de verdade têm umas 20).
const max_tables = 128;

/// Lê `buf.len` bytes a partir de `off` e diz quantos vieram (menos no fim do arquivo).
pub const Reader = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, off: u64, buf: []u8) usize,

    fn exact(r: Reader, off: u64, buf: []u8) bool {
        return r.readFn(r.ctx, off, buf) == buf.len;
    }
};

/// A família (nameID 1) e o subgrupo (nameID 2: "Bold", "Semibold Italic"...). O tamanho
/// é fixo: um nome que não cabe sai cortado, sempre numa letra inteira.
pub const Names = struct {
    family_buf: [64]u8 = undefined,
    family_len: usize = 0,
    sub_buf: [32]u8 = undefined,
    sub_len: usize = 0,
    /// A preferência do registro de onde veio cada campo (ver `parse`).
    family_rank: u8 = 0,
    sub_rank: u8 = 0,

    pub fn family(n: *const Names) []const u8 {
        return n.family_buf[0..n.family_len];
    }

    pub fn sub(n: *const Names) []const u8 {
        return n.sub_buf[0..n.sub_len];
    }

    /// O subgrupo tem a palavra? Sem ligar para maiúsculas ("Bold" tem "bold").
    pub fn has(n: *const Names, word: []const u8) bool {
        return std.ascii.findIgnoreCase(n.sub(), word) != null;
    }
};

fn be16(b: []const u8, at: usize) u16 {
    if (at + 2 > b.len) return 0;
    return (@as(u16, b[at]) << 8) | b[at + 1];
}

fn be32(b: []const u8, at: usize) u32 {
    if (at + 4 > b.len) return 0;
    return (@as(u32, b[at]) << 24) | (@as(u32, b[at + 1]) << 16) | (@as(u32, b[at + 2]) << 8) | b[at + 3];
}

/// Onde começa cada face do arquivo: uma só, salvo nas coleções (.ttc).
pub fn faces(r: Reader, out: *[max_faces]u32) usize {
    var head: [12]u8 = undefined;
    if (!r.exact(0, &head)) return 0;
    if (!std.mem.eql(u8, head[0..4], "ttcf")) {
        out[0] = 0;
        return 1;
    }
    const n: usize = @min(be32(&head, 8), max_faces);
    var offs: [max_faces * 4]u8 = undefined;
    if (!r.exact(12, offs[0 .. n * 4])) return 0;
    for (0..n) |i| out[i] = be32(&offs, i * 4);
    return n;
}

/// Os nomes da face que começa em `face`, com a tabela lida em `scratch`. Falso sem um
/// nome de família que saibamos ler.
pub fn read(r: Reader, face: u32, scratch: []u8, out: *Names) bool {
    out.* = .{};
    var head: [12]u8 = undefined;
    if (!r.exact(face, &head)) return false;
    const n: usize = @min(be16(&head, 4), max_tables);
    var dir: [max_tables * 16]u8 = undefined;
    if (!r.exact(@as(u64, face) + 12, dir[0 .. n * 16])) return false;
    for (0..n) |i| {
        const e = dir[i * 16 ..][0..16];
        if (!std.mem.eql(u8, e[0..4], "name")) continue;
        const len = @min(be32(e, 12), scratch.len);
        const got = r.readFn(r.ctx, be32(e, 8), scratch[0..len]);
        return parse(scratch[0..got], out);
    }
    return false;
}

/// A tabela "name" tem um registro por escrita, idioma e campo. Fica o melhor de cada
/// campo: o do Windows em inglês, o Unicode, o do Windows em outro idioma e, por último,
/// o do Mac em inglês só se for ASCII (os outros encodings do Mac não lemos).
pub fn parse(t: []const u8, out: *Names) bool {
    const count = be16(t, 2);
    const strings: usize = be16(t, 4);
    var at: usize = 6;
    for (0..count) |_| {
        if (at + 12 > t.len) break;
        const platform = be16(t, at);
        const encoding = be16(t, at + 2);
        const lang = be16(t, at + 4);
        const id = be16(t, at + 6);
        const len = be16(t, at + 8);
        const start = strings + be16(t, at + 10);
        at += 12;
        if (id != 1 and id != 2) continue;
        if (start + len > t.len) continue;
        const rank: u8 = switch (platform) {
            3 => if (lang == 0x409) 4 else 2,
            0 => 3,
            1 => if (encoding == 0 and lang == 0) 1 else continue,
            else => continue,
        };
        const best = if (id == 1) &out.family_rank else &out.sub_rank;
        if (rank <= best.*) continue;
        const buf: []u8 = if (id == 1) &out.family_buf else &out.sub_buf;
        const src = t[start .. start + len];
        const got = if (platform == 1) (ascii(src, buf) orelse continue) else utf16Be(src, buf);
        if (got == 0) continue;
        if (id == 1) out.family_len = got else out.sub_len = got;
        best.* = rank;
    }
    return out.family_len > 0;
}

/// Utf-16 big-endian para utf-8 em `out`, parando antes da letra que não cabe.
fn utf16Be(src: []const u8, out: []u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < src.len) {
        var cp: u21 = be16(src, i);
        i += 2;
        if (cp >= 0xD800 and cp < 0xDC00 and i + 1 < src.len) {
            const lo = be16(src, i);
            if (lo >= 0xDC00 and lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            }
        }
        if (cp == 0) break;
        // Metade de um par sozinha: não é letra.
        if (cp >= 0xD800 and cp < 0xE000) continue;
        const need = std.unicode.utf8CodepointSequenceLength(cp) catch break;
        if (n + need > out.len) break;
        n += std.unicode.utf8Encode(cp, out[n..]) catch break;
    }
    return n;
}

/// O registro do Mac em ASCII, sem os caracteres de controle; null se tem outra coisa.
fn ascii(src: []const u8, out: []u8) ?usize {
    var n: usize = 0;
    for (src) |ch| {
        if (ch >= 0x80) return null;
        if (ch < 0x20 or n == out.len) continue;
        out[n] = ch;
        n += 1;
    }
    return n;
}

// --- Testes ---------------------------------------------------------------------------

const Rec = struct { platform: u16, encoding: u16 = 1, lang: u16, id: u16, text: []const u8 };

/// Uma tabela "name" de mentira (o texto em utf-8 vira utf-16, menos o do Mac).
fn buildName(a: std.mem.Allocator, recs: []const Rec) ![]u8 {
    var strs: std.ArrayList(u8) = .empty;
    defer strs.deinit(a);
    var t: std.ArrayList(u8) = .empty;
    errdefer t.deinit(a);
    try put16(a, &t, 0);
    try put16(a, &t, @intCast(recs.len));
    try put16(a, &t, @intCast(6 + recs.len * 12));
    for (recs) |rc| {
        const off = strs.items.len;
        if (rc.platform == 1) {
            try strs.appendSlice(a, rc.text);
        } else {
            var it = (try std.unicode.Utf8View.init(rc.text)).iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp >= 0x10000) {
                    const v = cp - 0x10000;
                    try put16(a, &strs, @intCast(0xD800 + (v >> 10)));
                    try put16(a, &strs, @intCast(0xDC00 + (v & 0x3FF)));
                } else try put16(a, &strs, @intCast(cp));
            }
        }
        for ([_]u16{ rc.platform, rc.encoding, rc.lang, rc.id, @intCast(strs.items.len - off), @intCast(off) }) |v| try put16(a, &t, v);
    }
    try t.appendSlice(a, strs.items);
    return t.toOwnedSlice(a);
}

fn put16(a: std.mem.Allocator, l: *std.ArrayList(u8), v: u16) !void {
    try l.appendSlice(a, &.{ @intCast(v >> 8), @intCast(v & 0xFF) });
}

fn put32(a: std.mem.Allocator, l: *std.ArrayList(u8), v: u32) !void {
    try put16(a, l, @intCast(v >> 16));
    try put16(a, l, @intCast(v & 0xFFFF));
}

/// Uma face com duas tabelas ("head" de enfeite e a "name" em `name_at`).
fn putFace(a: std.mem.Allocator, f: *std.ArrayList(u8), name_at: u32, name_len: u32) !void {
    try put32(a, f, 0x00010000);
    try put16(a, f, 2);
    try put16(a, f, 0);
    try put16(a, f, 0);
    try put16(a, f, 0);
    try f.appendSlice(a, "head");
    try put32(a, f, 0);
    try put32(a, f, 0);
    try put32(a, f, 0);
    try f.appendSlice(a, "name");
    try put32(a, f, 0);
    try put32(a, f, name_at);
    try put32(a, f, name_len);
}

/// Lê de um arquivo na memória.
const Mem = struct {
    data: []const u8,

    fn readFn(ctx: *anyopaque, off: u64, buf: []u8) usize {
        const m: *Mem = @ptrCast(@alignCast(ctx));
        const at: usize = @intCast(off);
        if (at >= m.data.len) return 0;
        const n = @min(buf.len, m.data.len - at);
        @memcpy(buf[0..n], m.data[at..][0..n]);
        return n;
    }

    fn reader(m: *Mem) Reader {
        return .{ .ctx = m, .readFn = readFn };
    }
};

test "a família do Windows em inglês vence a do Mac e a de outro idioma" {
    const a = std.testing.allocator;
    const t = try buildName(a, &.{
        .{ .platform = 1, .encoding = 0, .lang = 0, .id = 1, .text = "Mac Name" },
        .{ .platform = 1, .encoding = 0, .lang = 0, .id = 2, .text = "Regular" },
        .{ .platform = 3, .lang = 0x411, .id = 1, .text = "游ゴシック" },
        .{ .platform = 3, .lang = 0x409, .id = 1, .text = "Test Sans" },
        .{ .platform = 3, .lang = 0x409, .id = 2, .text = "Bold Italic" },
    });
    defer a.free(t);
    var n: Names = .{};
    try std.testing.expect(parse(t, &n));
    try std.testing.expectEqualStrings("Test Sans", n.family());
    try std.testing.expect(n.has("bold") and n.has("ITALIC") and !n.has("semi"));
}

test "só o nome em japonês do Windows: vem em utf-8" {
    const a = std.testing.allocator;
    const t = try buildName(a, &.{.{ .platform = 3, .lang = 0x411, .id = 1, .text = "游ゴシック" }});
    defer a.free(t);
    var n: Names = .{};
    try std.testing.expect(parse(t, &n));
    try std.testing.expectEqualStrings("游ゴシック", n.family());
}

test "o Mac em outro encoding não dá nome; em ASCII dá" {
    const a = std.testing.allocator;
    const t = try buildName(a, &.{.{ .platform = 1, .encoding = 1, .lang = 11, .id = 1, .text = "\x82\xa0" }});
    defer a.free(t);
    var n: Names = .{};
    try std.testing.expect(!parse(t, &n));
    const t2 = try buildName(a, &.{.{ .platform = 1, .encoding = 0, .lang = 0, .id = 1, .text = "Old\x01 Mac" }});
    defer a.free(t2);
    try std.testing.expect(parse(t2, &n));
    try std.testing.expectEqualStrings("Old Mac", n.family());
}

test "nome comprido sai cortado numa letra inteira, e o par de utf-16 vira uma letra" {
    const a = std.testing.allocator;
    const a62: [62]u8 = @splat('A');
    const long = a62 ++ "日本".*;
    const t = try buildName(a, &.{
        .{ .platform = 3, .lang = 0x409, .id = 1, .text = &long },
        .{ .platform = 0, .lang = 0, .id = 2, .text = "Regular 😀" },
    });
    defer a.free(t);
    var n: Names = .{};
    try std.testing.expect(parse(t, &n));
    try std.testing.expectEqualStrings(&a62, n.family());
    try std.testing.expectEqualStrings("Regular 😀", n.sub());
}

test "arquivo de uma face e coleção .ttc com duas, lendo só a tabela name" {
    const a = std.testing.allocator;
    const n1 = try buildName(a, &.{ .{ .platform = 3, .lang = 0x409, .id = 1, .text = "Uma" }, .{ .platform = 3, .lang = 0x409, .id = 2, .text = "Semibold" } });
    defer a.free(n1);
    const n2 = try buildName(a, &.{.{ .platform = 3, .lang = 0x409, .id = 1, .text = "Outra" }});
    defer a.free(n2);
    var scratch: [4096]u8 = undefined;
    var offs: [max_faces]u32 = undefined;

    // Uma face: a tabela logo depois do diretório (12 + 2 × 16 bytes).
    var one: std.ArrayList(u8) = .empty;
    defer one.deinit(a);
    try putFace(a, &one, 44, @intCast(n1.len));
    try one.appendSlice(a, n1);
    var m1: Mem = .{ .data = one.items };
    try std.testing.expectEqual(@as(usize, 1), faces(m1.reader(), &offs));
    var got: Names = .{};
    try std.testing.expect(read(m1.reader(), offs[0], &scratch, &got));
    try std.testing.expectEqualStrings("Uma", got.family());
    try std.testing.expect(got.has("semibold"));

    // Coleção: cabeçalho "ttcf" com os dois começos, as faces e as tabelas.
    var ttc: std.ArrayList(u8) = .empty;
    defer ttc.deinit(a);
    try ttc.appendSlice(a, "ttcf");
    try put32(a, &ttc, 0x00010000);
    try put32(a, &ttc, 2);
    try put32(a, &ttc, 20);
    try put32(a, &ttc, 64);
    try putFace(a, &ttc, 108, @intCast(n1.len));
    try putFace(a, &ttc, @intCast(108 + n1.len), @intCast(n2.len));
    try ttc.appendSlice(a, n1);
    try ttc.appendSlice(a, n2);
    var m2: Mem = .{ .data = ttc.items };
    try std.testing.expectEqual(@as(usize, 2), faces(m2.reader(), &offs));
    try std.testing.expect(read(m2.reader(), offs[0], &scratch, &got));
    try std.testing.expectEqualStrings("Uma", got.family());
    try std.testing.expect(read(m2.reader(), offs[1], &scratch, &got));
    try std.testing.expectEqualStrings("Outra", got.family());

    // Cortado no meio: falso, sem ler fora.
    var m3: Mem = .{ .data = one.items[0..30] };
    try std.testing.expect(!read(m3.reader(), 0, &scratch, &got));
    var m4: Mem = .{ .data = ttc.items[0..14] };
    try std.testing.expectEqual(@as(usize, 0), faces(m4.reader(), &offs));
}
