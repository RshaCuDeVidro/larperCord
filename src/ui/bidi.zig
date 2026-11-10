//! Texto da direita para a esquerda (árabe, hebraico). O ImGui desenha letra por letra, da
//! esquerda para a direita: o árabe sairia com as letras soltas e de trás para frente. Aqui
//! cada linha que tem uma letra RTL passa pelo GNU FriBidi (third_party/fribidi): o árabe vira
//! as formas de apresentação ligadas (inicial, medial, final, lam-alef) e a linha fica na ordem
//! visual do algoritmo bidirecional do Unicode. O texto continua guardado na ordem lógica: só o
//! que vai para a tela muda, e copiar ou selecionar seguem o original. Numa mensagem, o
//! parágrafo inteiro passa pelo algoritmo (`paragraphLevels`, ver ui/rich_plan.zig) e cada
//! trecho de um nível só sai na direção que ele resolveu (`visualRun`).
//!
//! Texto sem letra RTL (quase tudo) passa direto: uma varredura dos bytes, sem alocar nada.
//! Os buffers são fixos e só da thread da interface; nem as listas do FriBidi chamam o malloc
//! (ver `larper_fribidi_malloc`).
const std = @import("std");

// --- FriBidi (lib/fribidi-*.h) ----------------------------------------------------------

pub const Char = u32;
const Index = c_int;
const CharType = u32;
const ParType = u32;
pub const Level = i8;
const ArabicProp = u8;
const BracketType = u32;
const Flags = u32;

extern fn fribidi_get_bidi_type(ch: Char) CharType;
extern fn fribidi_get_bidi_types(str: [*]const Char, len: Index, btypes: [*]CharType) void;
extern fn fribidi_get_bracket_types(str: [*]const Char, len: Index, types: [*]const CharType, btypes: [*]BracketType) void;
extern fn fribidi_get_par_embedding_levels_ex(bidi_types: [*]const CharType, bracket_types: [*]const BracketType, len: Index, pbase_dir: *ParType, embedding_levels: [*]Level) Level;
extern fn fribidi_get_joining_types(str: [*]const Char, len: Index, jtypes: [*]ArabicProp) void;
extern fn fribidi_join_arabic(bidi_types: [*]const CharType, len: Index, embedding_levels: [*]const Level, ar_props: [*]ArabicProp) void;
extern fn fribidi_shape(flags: Flags, embedding_levels: [*]const Level, len: Index, ar_props: [*]ArabicProp, str: [*]Char) void;
extern fn fribidi_get_mirror_char(ch: Char, mirrored_ch: *Char) c_int;
extern fn fribidi_reorder_line(flags: Flags, bidi_types: [*]const CharType, len: Index, off: Index, base_dir: ParType, embedding_levels: [*]Level, visual_str: ?[*]Char, map: ?[*]Index) Level;

// fribidi-bidi-types.h e fribidi-flags.h
const mask_rtl: u32 = 0x1;
const mask_arabic: u32 = 0x2;
const mask_strong: u32 = 0x10;
const mask_letter: u32 = 0x100;
const mask_number: u32 = 0x200;
const mask_nsm: u32 = 0x80000;
const strong_rtl = mask_strong | mask_letter | mask_rtl;
const par_on: ParType = 0x40; // FRIBIDI_PAR_ON: a direção vem da primeira letra forte
const par_rtl: ParType = strong_rtl; // FRIBIDI_PAR_RTL
const par_ltr: ParType = mask_strong | mask_letter; // FRIBIDI_PAR_LTR
const flag_shape_mirroring: Flags = 0x1;
const flag_reorder_nsm: Flags = 0x2;
const flag_shape_arab_pres: Flags = 0x100;
const flag_shape_arab_liga: Flags = 0x200;
/// FRIBIDI_FLAGS_DEFAULT sem REMOVE_SPECIALS (aqui os invisíveis saem em `emit`) + FRIBIDI_FLAGS_ARABIC.
const flags = flag_shape_mirroring | flag_reorder_nsm | flag_shape_arab_pres | flag_shape_arab_liga;
/// O lugar que sobra quando lam + alef viram uma letra só (FRIBIDI_CHAR_FILL).
const fill: u32 = 0xFEFF;

// --- Arena das listas do FriBidi --------------------------------------------------------

/// O FriBidi monta listas ligadas dos trechos de cada linha, um malloc por nó. Saem daqui,
/// zerado no começo de cada linha; uma linha enorme que passe do tamanho cai no malloc.
/// Fica na seção de zeros do executável: nenhuma página é usada até aparecer texto RTL.
var arena: [96 * 1024]u8 align(16) = undefined;
var arena_used: usize = 0;
/// Quantas vezes a arena não bastou (os testes conferem que uma linha comum cabe).
var arena_misses: u32 = 0;

export fn larper_fribidi_malloc(size: usize) ?*anyopaque {
    const at = std.mem.alignForward(usize, arena_used, 16);
    if (at + size <= arena.len) {
        arena_used = at + size;
        return &arena[at];
    }
    arena_misses += 1;
    return std.c.malloc(size);
}

export fn larper_fribidi_free(ptr: ?*anyopaque) void {
    const p = @intFromPtr(ptr orelse return);
    const lo = @intFromPtr(&arena);
    if (p >= lo and p < lo + arena.len) return;
    std.c.free(ptr);
}

// --- Quem é RTL -------------------------------------------------------------------------

/// Letra de uma escrita da direita para a esquerda, ou marca que pede essa direção.
pub fn isRtl(cp: u32) bool {
    return switch (cp) {
        0x0590...0x08FF => true, // hebraico, árabe, siríaco, thaana, n'ko, samaritano, mandaico, árabe estendido
        0xFB1D...0xFDFF => true, // formas de apresentação do hebraico e do árabe (A)
        0xFE70...0xFEFE => true, // formas de apresentação do árabe (B)
        0x10800...0x10FFF => true, // escritas históricas RTL
        0x1E800...0x1EFFF => true, // mende kikakui, adlam, símbolos matemáticos árabes
        0x200F, 0x202B, 0x202E, 0x2067 => true, // RLM, RLE, RLO, RLI
        else => false,
    };
}

/// Tem alguma letra RTL? Bytes abaixo de 0xD6 nunca começam uma: em texto latino o laço só
/// compara, 16 bytes por vez.
pub fn hasRtl(s: []const u8) bool {
    var i: usize = 0;
    const V = @Vector(16, u8);
    while (i + 16 <= s.len) : (i += 16) {
        const chunk: V = s[i..][0..16].*;
        if (@reduce(.Or, chunk >= @as(V, @splat(0xD6)))) break;
    }
    while (i < s.len) {
        if (s[i] < 0xD6) {
            i += 1;
            continue;
        }
        if (isRtl(decode(s, &i))) return true;
    }
    return false;
}

/// Um caractere de `s[i.*..]`, andando `i`. Byte inválido vira U+FFFD (como no ImGui).
fn decode(s: []const u8, i: *usize) u32 {
    const b = s[i.*];
    if (b < 0x80) {
        i.* += 1;
        return b;
    }
    const n = std.unicode.utf8ByteSequenceLength(b) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + n > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + n]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += n;
    return cp;
}

/// A primeira letra forte de `s` é RTL (a direção do parágrafo, regras P2 e P3).
pub fn baseRtl(s: []const u8) bool {
    if (!hasRtl(s)) return false;
    var i: usize = 0;
    while (i < s.len) {
        const t = fribidi_get_bidi_type(decode(s, &i));
        if (t & mask_strong != 0 and t & mask_letter != 0) return t & mask_rtl != 0;
    }
    return false;
}

// --- Uma linha na ordem de desenho ------------------------------------------------------

/// Letras por linha convertida (uma linha maior fica como veio) e por parágrafo de uma
/// mensagem (ver `paragraphLevels`: um maior fica na ordem lógica).
pub const max_line = 4096;
var cps: [max_line]Char = undefined;
var types: [max_line]CharType = undefined;
var brackets: [max_line]BracketType = undefined;
var levels: [max_line]Level = undefined;
var props: [max_line]ArabicProp = undefined;
var out: [16 * 1024]u8 = undefined;

/// As últimas palavras convertidas: a mesma palavra é medida e desenhada várias vezes por
/// quadro (ui/rich.zig), e achar aqui custa um hash em vez do FriBidi de novo.
const Cached = struct {
    hash: u64 = 0,
    /// Como a direção foi decidida (ver `Dir`): a mesma palavra sai diferente em cada uma.
    dir: Dir = .auto,
    in_len: u8 = 0,
    out_len: u8 = 0,
    in: [cache_in]u8 = undefined,
    out: [cache_out]u8 = undefined,
};
const cache_in = 48;
const cache_out = 64;
var cache: [128]Cached = @splat(.{});

/// De onde vem a direção de um texto convertido: da primeira letra forte de cada linha
/// (`auto`), ou de fora, para um pedaço de linha que o algoritmo do parágrafo inteiro já
/// resolveu (ver `visualRun`).
pub const Dir = enum(u8) { auto, ltr, rtl };

/// `s` como deve ir para a tela: cada linha com letra RTL moldada e na ordem visual, as
/// outras iguais. Null quando não há nada a mudar (desenhe `s` mesmo) ou não coube. O
/// resultado vale até a próxima chamada.
pub fn visual(s: []const u8) ?[]const u8 {
    if (!hasRtl(s)) return null;
    return cached(s, .auto);
}

/// Um pedaço de uma linha que está todo num nível só do algoritmo do parágrafo (ui/rich.zig
/// quebra cada palavra onde o nível muda): `rtl`, nível ímpar, sai de trás para frente com os
/// parênteses espelhados e o árabe moldado; nível par, como está (moldado, se tiver árabe).
/// Um emoji com tom de pele, bandeira ou sequência com ZWJ não se desfaz: fica inteiro no
/// lugar dele. Null quando não há nada a mudar: um caractere só, sem espelho (o ponto, o
/// traço, um emoji), nem passa pelo FriBidi.
pub fn visualRun(s: []const u8, rtl: bool) ?[]const u8 {
    if (!rtl) return if (hasRtl(s)) cached(s, .ltr) else null;
    if (!hasRtl(s) and !rtlWork(s)) return null;
    return cached(s, .rtl);
}

/// Texto sem letra RTL num trecho da direita para a esquerda: só muda se tiver mais de um
/// pedaço (caractere com as marcas e os complementos de emoji dele) ou algo com espelho.
fn rtlWork(s: []const u8) bool {
    var i: usize = 0;
    var clusters: usize = 0;
    var cl: Clusters = .{};
    while (i < s.len) {
        const cp = decode(s, &i);
        var m: Char = 0;
        if (fribidi_get_mirror_char(cp, &m) != 0) return true;
        if (cl.starts(cp, fribidi_get_bidi_type(cp))) clusters += 1;
        if (clusters > 1) return true;
    }
    return false;
}

fn cached(s: []const u8, dir: Dir) ?[]const u8 {
    if (s.len > cache_in) return convert(s, dir);
    const h = std.hash.Wyhash.hash(@intFromEnum(dir), s);
    const e = &cache[@intCast(h % cache.len)];
    if (e.in_len == s.len and e.hash == h and e.dir == dir and std.mem.eql(u8, e.in[0..s.len], s)) return e.out[0..e.out_len];
    const v = convert(s, dir) orelse return null;
    if (v.len <= cache_out) {
        e.* = .{ .hash = h, .dir = dir, .in_len = @intCast(s.len), .out_len = @intCast(v.len) };
        @memcpy(e.in[0..s.len], s);
        @memcpy(e.out[0..v.len], v);
    }
    return v;
}

fn convert(s: []const u8, dir: Dir) ?[]const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (it.next()) |ln| {
        if (!first) {
            if (n == out.len) return null;
            out[n] = '\n';
            n += 1;
        }
        first = false;
        n = (if (dir == .rtl) rtlLine(ln, n) else line(ln, n, if (dir == .ltr) par_ltr else par_on)) orelse return null;
    }
    return out[0..n];
}

/// Escreve a linha `ln` em `out[at..]`; devolve onde parou, ou null se `out` encheu.
fn line(ln: []const u8, at: usize, base_in: ParType) ?usize {
    const len = load(ln) orelse return copy(ln, at);
    if (len == 0) return at;
    const l: Index = @intCast(len);
    fribidi_get_bidi_types(&cps, l, &types);
    var base: ParType = base_in;
    if (base_in != par_ltr and allRtl(types[0..len])) {
        // Palavra só de letras RTL (o caso comum, palavra por palavra numa mensagem): todas no
        // nível 1, sem precisar montar as listas do algoritmo.
        @memset(levels[0..len], 1);
        base = par_rtl;
    } else {
        fribidi_get_bracket_types(&cps, l, &types, &brackets);
        arena_used = 0;
        if (fribidi_get_par_embedding_levels_ex(&types, &brackets, l, &base, &levels) == 0) return copy(ln, at);
    }
    fribidi_get_joining_types(&cps, l, &props);
    fribidi_join_arabic(&types, l, &levels, &props);
    fribidi_shape(flags, &levels, l, &props, &cps);
    if (fribidi_reorder_line(flags, &types, l, 0, base, &levels, &cps, null) == 0) return copy(ln, at);
    return emit(cps[0..len], at);
}

/// Um trecho todo no mesmo nível ímpar: o árabe moldado, o que tem espelho espelhado e os
/// pedaços (letra com as marcas dela, emoji com os complementos) do último para o primeiro,
/// cada um com a ordem de dentro (regras L2 e L3 do UAX #9, sem desfazer um emoji).
fn rtlLine(ln: []const u8, at: usize) ?usize {
    const len = load(ln) orelse return copy(ln, at);
    if (len == 0) return at;
    const l: Index = @intCast(len);
    fribidi_get_bidi_types(&cps, l, &types);
    // Número ou letra da esquerda para a direita não fica no nível ímpar: o trecho tem mais de
    // um nível ("12." de um item de lista num parágrafo RTL), e quem resolve é o algoritmo
    // inteiro, com a direção do parágrafo da direita para a esquerda (".12", não ".21").
    for (types[0..len]) |t| {
        if (t & mask_number != 0 or (t & mask_strong != 0 and t & mask_rtl == 0)) return line(ln, at, par_rtl);
    }
    // Onde começa cada pedaço, antes de moldar (a forma moldada não muda a classe).
    var cl: Clusters = .{};
    for (0..len) |i| starts[i] = cl.starts(cps[i], types[i]);
    @memset(levels[0..len], 1);
    fribidi_get_joining_types(&cps, l, &props);
    fribidi_join_arabic(&types, l, &levels, &props);
    fribidi_shape(flags, &levels, l, &props, &cps);
    var n = at;
    var end = len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and !starts[start]) start -= 1;
        n = emit(cps[start..end], n) orelse return null;
        end = start;
    }
    return n;
}
var starts: [max_line]bool = undefined;

/// Os pedaços que não se separam ao inverter um trecho: a letra com as marcas que vão em cima
/// dela, e o emoji com o seletor de variação, o ZWJ e o que vem depois dele, o tom de pele, a
/// tecla (1️⃣) e as letras escondidas; uma bandeira são duas letras regionais.
const Clusters = struct {
    prev: u32 = 0,
    /// A última letra regional abriu um par (a próxima fecha a bandeira).
    ri_open: bool = false,

    fn starts(c: *Clusters, cp: u32, t: CharType) bool {
        const prev = c.prev;
        c.prev = cp;
        const ri = cp >= 0x1F1E6 and cp <= 0x1F1FF;
        if (ri) {
            const closes = c.ri_open and prev >= 0x1F1E6 and prev <= 0x1F1FF;
            c.ri_open = !closes;
            return !closes;
        }
        c.ri_open = false;
        if (prev == 0) return true;
        if (t & mask_nsm != 0 or prev == 0x200D or cp == 0x200D) return false;
        return switch (cp) {
            0xFE00...0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F, 0xE0100...0xE01EF => false,
            else => true,
        };
    }
};

/// Só letras fortes RTL e marcas que vão em cima delas, começando por uma letra.
fn allRtl(list: []const CharType) bool {
    if (list.len == 0 or list[0] & strong_rtl != strong_rtl) return false;
    for (list) |t| if (t & strong_rtl != strong_rtl and t & mask_nsm == 0) return false;
    return true;
}

/// Decodifica `ln` em `cps`. Null se não couber (a linha vai como veio).
fn load(ln: []const u8) ?usize {
    var i: usize = 0;
    var len: usize = 0;
    while (i < ln.len) : (len += 1) {
        if (len == max_line) return null;
        cps[len] = decode(ln, &i);
    }
    return len;
}

fn copy(ln: []const u8, at: usize) ?usize {
    if (at + ln.len > out.len) return null;
    @memcpy(out[at..][0..ln.len], ln);
    return at + ln.len;
}

/// Invisíveis que não vão para a tela: o ImGui não os conhece e desenharia o "?".
fn invisible(cp: u32) bool {
    return cp == fill or cp == 0x061C or (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x206F);
}

fn emit(list: []const Char, at: usize) ?usize {
    var n = at;
    for (list) |cp| {
        if (invisible(cp)) continue;
        if (n + 4 > out.len) return null;
        const c21 = std.math.cast(u21, cp) orelse 0xFFFD;
        n += std.unicode.utf8Encode(c21, out[n..]) catch std.unicode.utf8Encode(0xFFFD, out[n..]) catch unreachable;
    }
    return n;
}

// --- Palavras de uma mensagem -----------------------------------------------------------

/// A direção de um pedaço que entra no parágrafo como um caractere só (menção, emoji, código,
/// link solto: ui/rich_plan.zig), pela primeira letra forte dele.
pub const Class = enum(u8) {
    /// Pontuação, emoji, menção: segue as vizinhas.
    neutral,
    ltr,
    /// Hebraico (e as outras RTL que não são árabe).
    rtl,
    arabic,
    number,
    arabic_number,

    /// Um caractere que o FriBidi classifica igual à palavra toda.
    pub fn stand(c: Class) Char {
        return switch (c) {
            .neutral => 0xFFFC,
            .ltr => 'a',
            .rtl => 0x05D0,
            .arabic => 0x0627,
            .number => '1',
            .arabic_number => 0x0661,
        };
    }
};

/// A classe da palavra: a da primeira letra forte; sem letra, número ou neutra.
pub fn classOf(s: []const u8) Class {
    var i: usize = 0;
    var num: Class = .neutral;
    while (i < s.len) {
        const cp = decode(s, &i);
        if (cp < 0x80) {
            if (std.ascii.isAlphabetic(@intCast(cp))) return .ltr;
            if (std.ascii.isDigit(@intCast(cp)) and num == .neutral) num = .number;
            continue;
        }
        const t = fribidi_get_bidi_type(cp);
        if (t & mask_strong != 0 and t & mask_letter != 0) {
            if (t & mask_rtl == 0) return .ltr;
            return if (t & mask_arabic != 0) .arabic else .rtl;
        }
        if (t & mask_number != 0 and num == .neutral) num = if (t & mask_arabic != 0) .arabic_number else .number;
    }
    return num;
}

/// Os níveis do algoritmo bidirecional (UAX #9) de um parágrafo inteiro, na ordem lógica:
/// `list` são os caracteres (um pedaço que não se divide, como uma menção, entra como um
/// caractere só, da classe dele: ver `Class.stand`) e `lv` recebe o nível de cada um, com o
/// par de parênteses resolvido junto (N0). A direção do parágrafo vem da primeira letra forte
/// (P2 e P3): número, pontuação, espaço, emoji e marcador de lista não decidem. Devolve se ele
/// é da direita para a esquerda, ou null se não deu.
pub fn paragraphLevels(list: []const Char, lv: []Level) ?bool {
    const len = list.len;
    if (len == 0 or len > max_line or lv.len < len) return null;
    const l: Index = @intCast(len);
    fribidi_get_bidi_types(list.ptr, l, &types);
    fribidi_get_bracket_types(list.ptr, l, &types, &brackets);
    var base: ParType = par_on;
    arena_used = 0;
    if (fribidi_get_par_embedding_levels_ex(&types, &brackets, l, &base, lv.ptr) == 0) return null;
    return base & mask_rtl != 0;
}

// --- Testes -----------------------------------------------------------------------------

fn expectCodepoints(want: []const u32, got: []const u8) !void {
    var buf: [256]u32 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < got.len) : (n += 1) buf[n] = decode(got, &i);
    try std.testing.expectEqualSlices(u32, want, buf[0..n]);
}

test "texto sem RTL passa direto" {
    try std.testing.expect(!hasRtl(""));
    try std.testing.expect(!hasRtl("bom dia rapaziada, tudo certo por aí? 0123456789 kkkkkkkkkkkkkkkkk"));
    try std.testing.expect(!hasRtl("Polski: zażółć gęślą jaźń. Русский: привет. 日本語: こんにちは 😂"));
    try std.testing.expect(!hasRtl("Հայերեն")); // armênio: 0x0580 começa com o mesmo byte do hebraico
    try std.testing.expect(!hasRtl("\xEF\xBB\xBFbom")); // BOM
    try std.testing.expect(visual("nada para mudar aqui, nem em 32 bytes ou mais de texto") == null);
    try std.testing.expect(hasRtl("um pouco de texto latino antes, e só no fim: שלום"));
    try std.testing.expect(hasRtl("ﻻ"));
    try std.testing.expect(!hasRtl("\xff\xfe quebrado \xd7"));
}

test "lam + alef viram uma letra só" {
    try expectCodepoints(&.{0xFEFB}, visual("لا").?);
}

test "hebraico de trás para frente" {
    try std.testing.expectEqualStrings("םולש", visual("שלום").?);
}

test "parágrafo da esquerda para a direita com hebraico e número" {
    // O número logo depois do hebraico fica com ele (regras W e N do UAX #9).
    try std.testing.expectEqualStrings("abc 123 םולש", visual("abc שלום 123").?);
    try std.testing.expectEqualStrings("abc םולש def", visual("abc שלום def").?);
}

test "frase árabe com as letras ligadas, na ordem de desenho" {
    try expectCodepoints(&.{
        0xFEEA, 0xFEE0, 0xFEDF, 0xFE8D, ' ', // الله
        0xFE94, 0xFEE4, 0xFEA3, 0xFEAD, 0xFEED, ' ', // ورحمة
        0xFEE2, 0xFEDC, 0xFEF4, 0xFEE0, 0xFECB, ' ', // عليكم
        0xFEE1, 0xFEFC, 0xFEB4, 0xFEDF, 0xFE8D, // السلام (com lam-alef)
    }, visual("السلام عليكم ورحمة الله").?);
    try std.testing.expectEqual(@as(u32, 0), arena_misses);
}

test "cada linha por si, e o espelho dos parênteses" {
    try std.testing.expectEqualStrings("ok\nםולש\nfim", visual("ok\nשלום\nfim").?);
    // Dentro do RTL o parêntese é espelhado: continua abrindo do lado certo.
    try std.testing.expectEqualStrings("(םולש)", visual("(שלום)").?);
}

test "atalho da palavra toda RTL dá o mesmo que o algoritmo inteiro" {
    // Com um espaço no fim a linha não é mais só RTL e passa pelo caminho completo.
    for ([_][]const u8{ "مَرْحَبًا", "שָׁלוֹם", "السلام", "لا" }) |w| {
        var a: [64]u8 = undefined;
        const fast = visual(w).?;
        @memcpy(a[0..fast.len], fast);
        var with_space: [64]u8 = undefined;
        @memcpy(with_space[0..w.len], w);
        with_space[w.len] = ' ';
        const full = convert(with_space[0 .. w.len + 1], .auto).?;
        try std.testing.expectEqualStrings(full[1..], a[0..fast.len]);
    }
}

test "invisíveis de direção não vão para a tela" {
    try std.testing.expectEqualStrings("םולש", visual("\u{200F}שלום\u{200E}").?);
}

test "linha longa cabe na arena" {
    // Perto do limite de letras por linha, com trechos trocando de direção o tempo todo.
    const w = "السلام عليكم abc 12 ";
    var buf: [90 * w.len]u8 = undefined;
    for (0..90) |i| @memcpy(buf[i * w.len ..][0..w.len], w);
    const got = visual(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, got, "\u{FEFC}") != null);
    try std.testing.expectEqual(@as(u32, 0), arena_misses);
}

test "classe das palavras" {
    try std.testing.expectEqual(Class.ltr, classOf("hello"));
    try std.testing.expectEqual(Class.rtl, classOf("שלום"));
    try std.testing.expectEqual(Class.arabic, classOf("مرحبا!"));
    try std.testing.expectEqual(Class.number, classOf("123"));
    try std.testing.expectEqual(Class.arabic_number, classOf("١٢٣"));
    try std.testing.expectEqual(Class.neutral, classOf("!?"));
    try std.testing.expectEqual(Class.ltr, classOf("abc-שלום"));
    try std.testing.expect(baseRtl("(שלום) abc"));
    try std.testing.expect(!baseRtl("abc שלום"));
}

fn levelsOf(text: []const u8, lv: []Level) ?bool {
    var list: [256]Char = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) list[n] = decode(text, &i);
    return paragraphLevels(list[0..n], lv[0..n]);
}

test "níveis do parágrafo: a direção é a da primeira letra forte" {
    var lv: [128]Level = undefined;
    // O "؟" no fim de uma frase árabe com inglês no meio fica com o árabe (nível 1), não com
    // o inglês (2), mesmo grudado nele.
    const q = "مساء الخير what is the problem؟";
    try std.testing.expectEqual(@as(?bool, true), levelsOf(q, &lv));
    try std.testing.expectEqual(@as(Level, 1), lv[0]);
    try std.testing.expectEqual(@as(Level, 2), lv[11]); // w
    try std.testing.expectEqual(@as(Level, 2), lv[29]); // m
    try std.testing.expectEqual(@as(Level, 1), lv[30]); // ؟
    // Número, ponto, traço e marcador antes do texto não decidem a direção.
    for ([_][]const u8{ "1.يمنع تجاهل الإدارة.", "12- السلام عليكم", "• 11- لا تكرر", "(12) שלום" }) |t| {
        try std.testing.expectEqual(@as(?bool, true), levelsOf(t, &lv));
    }
    // "12- السلام": o 12 fica no nível 2 e o traço no 1 (vai para a esquerda do número).
    _ = levelsOf("12- السلام", &lv);
    try std.testing.expectEqualSlices(Level, &.{ 2, 2, 1, 1 }, lv[0..4]);
    try std.testing.expectEqual(@as(?bool, false), levelsOf("abc שלום", &lv));
    try std.testing.expectEqual(@as(?bool, false), levelsOf("123 !?", &lv));
}

test "pedaço num nível só: espelho, ordem e emoji inteiro" {
    // Todo RTL: igual à linha inteira.
    var a: [64]u8 = undefined;
    const whole = visual("(تجربة)").?;
    @memcpy(a[0..whole.len], whole);
    try std.testing.expectEqualStrings(a[0..whole.len], visualRun("(تجربة)", true).?);
    // Parêntese sozinho num trecho RTL sai espelhado; ponto, traço e um emoji, como estão.
    try std.testing.expectEqualStrings(")", visualRun("(", true).?);
    try std.testing.expectEqualStrings("]!", visualRun("![", true).?);
    try std.testing.expect(visualRun(".", true) == null);
    try std.testing.expect(visualRun("-", true) == null);
    try std.testing.expect(visualRun("✔️", true) == null);
    try std.testing.expect(visualRun("👍🏽", true) == null);
    try std.testing.expect(visualRun("👩‍💻", true) == null);
    // Dois emojis num trecho RTL trocam de lugar, mas cada um fica inteiro. (As letras das
    // bandeiras são da esquerda para a direita no Unicode: duas bandeiras ficam na ordem.)
    try std.testing.expectEqualStrings("🇧🇷🇵🇹", visualRun("🇧🇷🇵🇹", true) orelse "🇧🇷🇵🇹");
    // (O ZWJ não vai para a tela: o ImGui desenha um emoji de cada vez.)
    try std.testing.expectEqualStrings("👩💻👍🏽", visualRun("👍🏽👩‍💻", true).?);
    // As marcas do árabe continuam depois da letra delas.
    try std.testing.expectEqualStrings(visual("مَرْحَبًا").?, visualRun("مَرْحَبًا", true).?);
    // O número de um item de lista numerada num parágrafo RTL: o ponto à esquerda, os
    // algarismos na ordem deles (não ".21").
    try std.testing.expectEqualStrings(".1", visualRun("1.", true).?);
    try std.testing.expectEqualStrings(".10", visualRun("10.", true).?);
    try std.testing.expectEqualStrings(".12", visualRun("12.", true).?);
    try std.testing.expectEqualStrings(".123", visualRun("123.", true).?);
    try std.testing.expectEqualStrings(".١٢", visualRun("١٢.", true).?);
    try std.testing.expectEqualStrings("abc )", visualRun("( abc", true).?);
    try std.testing.expect(visualRun("12.", false) == null);
    try std.testing.expect(visualRun("1000.", false) == null);
    // Nível par: o número e o latino como estão.
    try std.testing.expect(visualRun("12", false) == null);
    try std.testing.expect(visualRun("problem", false) == null);
}
