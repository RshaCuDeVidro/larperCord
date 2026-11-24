//! Textos de plugin em vários idiomas: `larper.tr{pt=…, en=…, ja=…}`, os rótulos de
//! menus, escolhas e painéis e o `@name:<código>` do cabeçalho. A escolha é sempre a
//! mesma cadeia: o código exato da interface, o idioma base (pt-BR → pt), outra
//! variante do mesmo idioma, o inglês, o texto sem idioma e, sem nada disso, o
//! primeiro que houver.
const std = @import("std");

/// Idiomas por texto, no máximo (um rótulo com mais que isso perde os últimos).
pub const max_langs = 16;

/// "pt-BR" -> "pt", "zh_Hant" -> "zh".
pub fn base(code: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, code, "-_") orelse code.len;
    return code[0..cut];
}

/// Um código de idioma: 2 ou 3 letras e, se tiver, uma variante de 2 a 8 letras ou
/// números depois de "-" ou "_" (pt, ja, pt-BR, zh_Hant). Assim `value`, `label` e os
/// outros campos de uma tabela nunca passam por idioma.
pub fn validCode(code: []const u8) bool {
    const b = base(code);
    if (b.len < 2 or b.len > 3) return false;
    for (b) |ch| if (!std.ascii.isAlphabetic(ch)) return false;
    if (b.len == code.len) return true;
    const rest = code[b.len + 1 ..];
    if (rest.len < 2 or rest.len > 8) return false;
    for (rest) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

/// O mesmo código, sem ligar para maiúsculas nem para "-" ou "_" (pt-BR = pt_br).
pub fn sameCode(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const sep_x = x == '-' or x == '_';
        const sep_y = y == '-' or y == '_';
        if (sep_x or sep_y) {
            if (sep_x != sep_y) return false;
        } else if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Qual dos `codes` mostrar para a interface em `ui`. "" é o texto sem idioma (o
/// `@name` sem código, um rótulo que veio como texto só). null = lista vazia.
pub fn pick(ui: []const u8, codes: []const []const u8) ?usize {
    if (codes.len == 0) return null;
    const ui_base = base(ui);
    for (codes, 0..) |cd, i| if (cd.len > 0 and sameCode(cd, ui)) return i;
    for (codes, 0..) |cd, i| if (cd.len > 0 and std.ascii.eqlIgnoreCase(cd, ui_base)) return i;
    for (codes, 0..) |cd, i| if (cd.len > 0 and std.ascii.eqlIgnoreCase(base(cd), ui_base)) return i;
    for (codes, 0..) |cd, i| if (std.ascii.eqlIgnoreCase(cd, "en")) return i;
    for (codes, 0..) |cd, i| if (cd.len > 0 and std.ascii.eqlIgnoreCase(base(cd), "en")) return i;
    for (codes, 0..) |cd, i| if (cd.len == 0) return i;
    return 0;
}

/// Um par lido de uma tabela (os textos são emprestados).
pub const Pair = struct { code: []const u8, text: []const u8 };

/// Em ordem de código: o "primeiro que houver" é sempre o mesmo, qualquer que seja a
/// ordem em que o Lua devolveu a tabela.
pub fn sortPairs(pairs: []Pair) void {
    std.sort.insertion(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.code, b.code);
        }
    }.lt);
}

/// O texto dos `pairs` para a interface em `ui` ("" sem nenhum).
pub fn pickPair(ui: []const u8, pairs: []const Pair) []const u8 {
    var codes: [max_langs][]const u8 = undefined;
    const n = @min(pairs.len, max_langs);
    for (pairs[0..n], codes[0..n]) |p, *cd| cd.* = p.code;
    const i = pick(ui, codes[0..n]) orelse return "";
    return pairs[i].text;
}

/// Um rótulo em vários idiomas num pedaço só de memória ("código\x00texto\x00…", em
/// ordem de código). Fica com a interface: o idioma pode mudar com o menu aberto, e o
/// plugin não precisa registrar de novo.
pub const Text = struct {
    buf: []u8 = &.{},

    pub fn make(gpa: std.mem.Allocator, list: []const Pair) !Text {
        var total: usize = 0;
        for (list) |p| total += p.code.len + p.text.len + 2;
        const buf = try gpa.alloc(u8, total);
        var at: usize = 0;
        for (list) |p| {
            for ([_][]const u8{ p.code, p.text }) |s| {
                @memcpy(buf[at..][0..s.len], s);
                at += s.len;
                buf[at] = 0;
                at += 1;
            }
        }
        return .{ .buf = buf };
    }

    /// Um texto só, sem idioma.
    pub fn one(gpa: std.mem.Allocator, text: []const u8) !Text {
        return make(gpa, &.{.{ .code = "", .text = text }});
    }

    pub fn free(t: *const Text, gpa: std.mem.Allocator) void {
        gpa.free(t.buf);
    }

    pub fn dup(t: *const Text, gpa: std.mem.Allocator) !Text {
        return .{ .buf = try gpa.dupe(u8, t.buf) };
    }

    /// Os pares, para quem quer ler todos (até `max_langs`).
    pub fn pairs(t: *const Text, out: *[max_langs]Pair) []Pair {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, t.buf, 0);
        while (n < out.len) {
            const code = it.next() orelse break;
            const text = it.next() orelse break;
            out[n] = .{ .code = code, .text = text };
            n += 1;
        }
        return out[0..n];
    }

    /// O texto para a interface em `ui`.
    pub fn get(t: *const Text, ui: []const u8) []const u8 {
        var ps: [max_langs]Pair = undefined;
        return pickPair(ui, t.pairs(&ps));
    }

    pub fn isEmpty(t: *const Text) bool {
        return t.get("en").len == 0;
    }
};

test "idioma: exato, base, variante, inglês, sem idioma e o primeiro" {
    const t = std.testing;
    const all = [_][]const u8{ "en", "ja", "pt", "pt-BR" };
    try t.expectEqual(@as(?usize, 1), pick("ja", &all));
    try t.expectEqual(@as(?usize, 3), pick("pt-BR", &all));
    try t.expectEqual(@as(?usize, 3), pick("pt_br", &all));
    try t.expectEqual(@as(?usize, 2), pick("pt-PT", &all));
    try t.expectEqual(@as(?usize, 2), pick("pt", &all));
    // Russo não tem: cai no inglês, nunca no português.
    try t.expectEqual(@as(?usize, 0), pick("ru", &all));
    // Só a variante: serve para o idioma base também.
    try t.expectEqual(@as(?usize, 0), pick("pt", &.{"pt-BR"}));
    try t.expectEqual(@as(?usize, 1), pick("ru", &.{ "de", "en-GB" }));
    // Sem inglês, o texto sem idioma; sem ele, o primeiro.
    try t.expectEqual(@as(?usize, 1), pick("ru", &.{ "de", "" }));
    try t.expectEqual(@as(?usize, 0), pick("ru", &.{ "de", "fr" }));
    try t.expectEqual(@as(?usize, null), pick("ru", &.{}));
    // O sem idioma nunca ganha do idioma certo.
    try t.expectEqual(@as(?usize, 1), pick("pt", &.{ "", "pt" }));
}

test "idioma: códigos válidos e inválidos" {
    for ([_][]const u8{ "pt", "en", "ja", "ast", "pt-BR", "zh_Hant", "es-419" }) |ok| try std.testing.expect(validCode(ok));
    for ([_][]const u8{ "", "p", "value", "label", "pt-", "pt-B", "pt BR", "1a", "pt-BR-x", "ptbr" }) |bad| try std.testing.expect(!validCode(bad));
    try std.testing.expectEqualStrings("pt", base("pt-BR"));
    try std.testing.expectEqualStrings("en", base("en"));
}

test "idioma: rótulo guardado responde a cada idioma da interface" {
    const gpa = std.testing.allocator;
    var ps = [_]Pair{ .{ .code = "pt", .text = "Traduzir" }, .{ .code = "ja", .text = "翻訳" }, .{ .code = "en", .text = "Translate" } };
    sortPairs(&ps);
    const txt = try Text.make(gpa, &ps);
    defer txt.free(gpa);
    try std.testing.expectEqualStrings("Traduzir", txt.get("pt"));
    try std.testing.expectEqualStrings("翻訳", txt.get("ja"));
    try std.testing.expectEqualStrings("Translate", txt.get("ru"));
    const copy = try txt.dup(gpa);
    defer copy.free(gpa);
    try std.testing.expectEqualStrings("Traduzir", copy.get("pt-BR"));
    const single = try Text.one(gpa, "Só um");
    defer single.free(gpa);
    try std.testing.expectEqualStrings("Só um", single.get("ja"));
    try std.testing.expect(!single.isEmpty());
}
