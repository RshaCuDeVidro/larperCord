//! Idioma da interface.
//!
//! O português e o inglês ficam no lugar em que o texto é usado:
//!
//!     tr("Entrar", "Sign in")
//!     fmt(&buf, "Respondendo a {s}", "Replying to {s}", .{nome})
//!     plural(&buf, n, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{n})
//!
//! Os outros idiomas vêm de arquivos, com o texto em inglês como chave: os de i18n/*.kdl
//! (embutidos no executável, comprimidos; build.zig acha sozinho cada arquivo da pasta) e
//! os da pasta larpercord/i18n/ nas configurações. Cada arquivo diz quem é, no começo:
//!
//!     language "日本語" code="ja" english="Japanese"
//!
//! e, se precisar, `direction "rtl"`, `font-script "ja"` (a fonte de reserva preferida) e
//! `plurals "ru"` (as regras de plural de outro idioma). Não há lista de idiomas no código:
//! um arquivo novo é um idioma novo. O da pasta de configurações com o código de um embutido
//! vale por cima dele (dá para testar uma tradução sem compilar), e salvar recarrega na
//! hora. O que falta no arquivo aparece em inglês (nunca em português).
//! tools/i18n_strings.py lista os textos, gera o modelo de um idioma e confere os arquivos.
//!
//! O idioma é global e a thread de rede também lê (avisos, dados da demonstração): o idioma
//! em uso é um ponteiro atômico para uma tabela montada antes de ser publicada e nunca mais
//! mexida. Trocar de idioma ou recarregar o arquivo publica outra; a velha fica na memória
//! até o app fechar (um texto dela pode estar guardado em algum lugar, como o título de uma
//! lista), e recarregar só acontece quando o arquivo muda de verdade.
const std = @import("std");
const embutido = @import("../core/embutido.zig");
const cabecalho = @import("../core/i18n_cabecalho.zig");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const embutidos = @import("i18n_embutidos");

// --- O idioma em uso ----------------------------------------------------------------

const Kind = enum(u8) { pt, en, file };

/// O que tr() e companhia precisam, publicado de uma vez (ver o topo).
const Active = struct {
    code: [:0]const u8,
    kind: Kind,
    table: ?*const Table = null,
    rule: Rule = .one,
    rtl: bool = false,
    font_script: []const u8,
};

const active_pt: Active = .{ .code = "pt", .kind = .pt, .font_script = "pt" };
const active_en: Active = .{ .code = "en", .kind = .en, .font_script = "en" };

var active: std.atomic.Value(*const Active) = .init(&active_pt);
/// Muda a cada troca de idioma e a cada arquivo recarregado (ver `stamp`).
var generation: std.atomic.Value(u32) = .init(0);

inline fn now() *const Active {
    return active.load(.acquire);
}

/// O código do idioma em uso: "pt", "en" ou o `code` de um arquivo ("ja", "ru"…).
pub fn current() [:0]const u8 {
    return now().code;
}

pub fn is(code: []const u8) bool {
    return std.mem.eql(u8, now().code, code);
}

/// Inglês, ou outro idioma (que sem tradução mostra o inglês): nunca o português.
pub fn en() bool {
    return now().kind != .pt;
}

/// O arquivo do idioma pede o texto da direita para a esquerda (`direction "rtl"`).
pub fn rtl() bool {
    return now().rtl;
}

/// A escrita cujas fontes de reserva vêm primeiro (ui/fonts.zig): `font-script` do
/// arquivo, ou o próprio código.
pub fn fontScript() []const u8 {
    return now().font_script;
}

/// Muda quando o texto da interface pode ter mudado (outro idioma, arquivo recarregado):
/// quem guarda texto pronto (a janela flutuante, o menu da bandeja) compara com isto.
pub fn stamp() u32 {
    return generation.load(.acquire);
}

/// Troca o idioma: "pt", "en", ou o código de um arquivo (o mais parecido: "ja-JP" acha o
/// "ja"). Desconhecido: inglês. Só na thread da interface.
pub fn set(code: []const u8) void {
    ensureInit();
    publish(match(code) orelse 1);
}

/// Como `set`, mas um código desconhecido não muda nada (falso).
pub fn setExact(code: []const u8) bool {
    ensureInit();
    publish(match(code) orelse return false);
    return true;
}

fn publish(i: usize) void {
    const info = &langs[i];
    const act: *const Active = switch (info.kind) {
        .pt => &active_pt,
        .en => &active_en,
        .file => info.active orelse blk: {
            if (info.table == null) info.table = buildTable(info);
            const a = perm.allocator().create(Active) catch return;
            a.* = .{ .code = info.code, .kind = .file, .table = info.table, .rule = info.rule, .rtl = info.rtl, .font_script = info.font_script };
            info.active = a;
            break :blk a;
        },
    };
    active.store(act, .release);
    _ = generation.fetchAdd(1, .acq_rel);
}

// --- Traduzindo ------------------------------------------------------------------------

pub fn tr(pt: []const u8, english: []const u8) []const u8 {
    const a = now();
    return switch (a.kind) {
        .pt => pt,
        .en => english,
        .file => a.table.?.get(english) orelse english,
    };
}

pub fn trZ(pt: [:0]const u8, english: [:0]const u8) [:0]const u8 {
    const a = now();
    return switch (a.kind) {
        .pt => pt,
        .en => english,
        .file => a.table.?.get(english) orelse english,
    };
}

/// Textos de formato que não couberam no buffer e saíram cortados. Só os builds
/// de debug contam (o QA usa um): cada texto avisa uma vez no registro, e o QA
/// confere que as telas em russo e japonês não cortam nada (qa_paineis.zig). O
/// cirílico ocupa 2 bytes por letra e o japonês 3: um buffer que cabe em pt e en
/// pode não caber na tradução.
pub var cuts: std.atomic.Value(u32) = .init(0);
const count_cuts = @import("builtin").mode == .debug;

inline fn noteCut(comptime english: []const u8, size: usize) void {
    if (comptime count_cuts) cut(english, size);
}

fn cut(comptime english: []const u8, size: usize) void {
    const Once = struct {
        var warned = false;
    };
    _ = cuts.fetchAdd(1, .monotonic);
    if (Once.warned) return;
    Once.warned = true;
    std.log.warn("texto cortado num buffer de {d} bytes ({s}): \"{s}\"", .{ size, current(), english });
}

/// Sem espaço, corta o texto (nunca no meio de um caractere) em vez de sumir.
pub fn fmt(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    const a = now();
    switch (a.kind) {
        .pt => wr.print(pt, args) catch noteCut(english, buf.len),
        .en => wr.print(english, args) catch noteCut(english, buf.len),
        .file => translated(&wr, a.table.?.get(english), english, args) catch noteCut(english, buf.len),
    }
    return whole(buf, wr.buffered());
}

/// O que coube no buffer, sem o último caractere se ele ficou pela metade.
fn whole(buf: []const u8, out: []const u8) []const u8 {
    if (out.len < buf.len) return out;
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
}

/// Sem espaço, devolve "" (como o bufPrintSentinel).
pub fn fmtZ(buf: []u8, comptime pt: []const u8, comptime english: []const u8, args: anytype) [:0]const u8 {
    const a = now();
    switch (a.kind) {
        .pt => return std.fmt.bufPrintSentinel(buf, pt, args, 0) catch cutZ(english, buf.len),
        .en => return std.fmt.bufPrintSentinel(buf, english, args, 0) catch cutZ(english, buf.len),
        .file => {
            if (buf.len == 0) return cutZ(english, 0);
            var wr = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
            translated(&wr, a.table.?.get(english), english, args) catch return cutZ(english, buf.len);
            buf[wr.end] = 0;
            return buf[0..wr.end :0];
        },
    }
}

inline fn cutZ(comptime english: []const u8, size: usize) [:0]const u8 {
    noteCut(english, size);
    return "";
}

pub fn allocPrint(gpa: std.mem.Allocator, comptime pt: []const u8, comptime english: []const u8, args: anytype) ![]u8 {
    const a = now();
    switch (a.kind) {
        .pt => return std.fmt.allocPrint(gpa, pt, args),
        .en => return std.fmt.allocPrint(gpa, english, args),
        .file => {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            // O escritor que aloca só falha sem memória.
            translated(&aw.writer, a.table.?.get(english), english, args) catch return error.OutOfMemory;
            return aw.toOwnedSlice();
        },
    }
}

/// Um texto com contagem: a forma certa para `n` em cada idioma ("1 voto", "2 votos";
/// em russo "1 голос", "3 голоса", "5 голосов"). Em português e inglês, `n == 1` é o
/// singular (o "0 votos" de sempre). Num arquivo de tradução a chave é o plural em inglês
/// (`en_other`), com uma forma por categoria do CLDR:
///
///     "{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"
///
/// Os marcadores seguem as regras do `fmt`, em cada forma. Sem espaço, corta como o `fmt`.
pub fn plural(buf: []u8, n: u64, comptime pt_one: []const u8, comptime pt_other: []const u8, comptime en_one: []const u8, comptime en_other: []const u8, args: anytype) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    writePlural(&wr, now(), n, pt_one, pt_other, en_one, en_other, args) catch noteCut(en_other, buf.len);
    return whole(buf, wr.buffered());
}

pub fn pluralAlloc(gpa: std.mem.Allocator, n: u64, comptime pt_one: []const u8, comptime pt_other: []const u8, comptime en_one: []const u8, comptime en_other: []const u8, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writePlural(&aw.writer, now(), n, pt_one, pt_other, en_one, en_other, args) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writePlural(w: *std.Io.Writer, a: *const Active, n: u64, comptime pt_one: []const u8, comptime pt_other: []const u8, comptime en_one: []const u8, comptime en_other: []const u8, args: anytype) std.Io.Writer.Error!void {
    switch (a.kind) {
        .pt => return if (n == 1) w.print(pt_one, args) else w.print(pt_other, args),
        .en => {},
        .file => if (try writeTemplate(w, a.table.?.form(en_other, n, a.rule), en_other, args)) return,
    }
    return if (n == 1) w.print(en_one, args) else w.print(en_other, args);
}

/// A tradução de um texto de formato, ou o inglês quando não há tradução ou os
/// marcadores dela não batem com os do inglês.
fn translated(w: *std.Io.Writer, tpl: ?[]const u8, comptime english: []const u8, args: anytype) std.Io.Writer.Error!void {
    if (!try writeTemplate(w, tpl, english, args)) try w.print(english, args);
}

/// Escreve a tradução `tpl` do texto de formato `english`. Falso, sem escrever nada,
/// quando não há tradução ou os marcadores dela não batem. Em cada ponto de uso só entra
/// o `emit` (um print por marcador); o resto é uma função só para todos.
fn writeTemplate(w: *std.Io.Writer, tpl: ?[]const u8, comptime english: []const u8, args: anytype) std.Io.Writer.Error!bool {
    const parsed = comptime marksOf(english);
    const Args = @TypeOf(args);
    if (comptime parsed == null) return false;
    const t = tpl orelse return false;
    const P = struct {
        const p = parsed.?;
        fn emit(ctx: *const anyopaque, out: *std.Io.Writer, k: usize) std.Io.Writer.Error!void {
            const a: *const Args = @ptrCast(@alignCast(ctx));
            const names = @typeInfo(Args).@"struct".field_names;
            inline for (0..p.n) |j| if (j == k) {
                const m = p.marks[j];
                return out.print("{" ++ m.spec ++ "}", .{@field(a.*, names[m.arg])});
            };
        }
    };
    walk(t, &P.p, null, undefined, undefined) catch return false;
    const ctx: *const anyopaque = if (@sizeOf(Args) == 0) @ptrCast(&no_args) else @ptrCast(&args);
    walk(t, &P.p, w, ctx, P.emit) catch |e| switch (e) {
        error.WriteFailed => return error.WriteFailed,
        error.Invalid => unreachable, // conferido logo acima
    };
    return true;
}

const no_args: u8 = 0;

// --- Marcadores -----------------------------------------------------------------
//
// Numa tradução de texto de formato (fmt, fmtZ, allocPrint, plural), cada marcador é:
//   - uma cópia de um marcador do inglês ({s}, {d}, {d:.0}...), preenchido na
//     mesma ordem do inglês; ou
//   - {N}: o N-ésimo marcador do texto em inglês (do zero), com a formatação
//     dele, para trocar a ordem. Os dois jeitos não se misturam.
// Todo valor que o inglês mostra precisa aparecer; {{ e }} são as chaves.
// Fora disso a tradução não vale e o app mostra o inglês.

const max_marks = 32;

const Mark = struct {
    /// Que argumento o marcador mostra.
    arg: u8,
    /// O que fica entre as chaves no inglês ("s", "1s", "d:.0").
    inner: []const u8,
    /// `inner` sem o número do argumento: a formatação.
    spec: []const u8,
};

const Parsed = struct {
    marks: [max_marks]Mark = undefined,
    n: usize = 0,
    /// Argumentos que o inglês mostra (bit i = argumento i).
    args: u32 = 0,
};

fn marksOf(comptime english: []const u8) ?Parsed {
    @setEvalBranchQuota(20_000 + 200 * english.len);
    return parseFormat(english);
}

/// Os marcadores de um texto de formato, lidos como o std.fmt lê. null: não é
/// texto de formato (chave sem par), ou tem argumento com nome ou largura vinda
/// de argumento; esses ficam sempre em inglês.
fn parseFormat(text: []const u8) ?Parsed {
    var out: Parsed = .{};
    var next: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch != '{' and ch != '}') {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i + 1] == ch) {
            i += 2;
            continue;
        }
        if (ch == '}') return null;
        const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse return null;
        const inner = text[i + 1 .. close];
        if (std.mem.indexOfAny(u8, inner, "[{") != null) return null;
        var k: usize = 0;
        while (k < inner.len and std.ascii.isDigit(inner[k])) k += 1;
        const arg = if (k > 0) std.fmt.parseInt(usize, inner[0..k], 10) catch return null else blk: {
            next += 1;
            break :blk next - 1;
        };
        if (arg >= 32 or out.n == max_marks) return null;
        out.marks[out.n] = .{ .arg = @intCast(arg), .inner = inner, .spec = inner[k..] };
        out.n += 1;
        out.args |= @as(u32, 1) << @intCast(arg);
        i = close + 1;
    }
    return out;
}

const WalkError = error{ Invalid, WriteFailed };

const Emit = *const fn (ctx: *const anyopaque, w: *std.Io.Writer, k: usize) std.Io.Writer.Error!void;

/// Confere uma tradução (sem `w`) ou escreve: o texto vai direto, e cada marcador
/// (k = marcador do inglês) sai por `emit`.
fn walk(tpl: []const u8, p: *const Parsed, w: ?*std.Io.Writer, ctx: *const anyopaque, emit: Emit) WalkError!void {
    var mode: enum { none, copy, index } = .none;
    var seq: usize = 0;
    var used: u32 = 0;
    var i: usize = 0;
    while (i < tpl.len) {
        const brace = std.mem.indexOfAnyPos(u8, tpl, i, "{}") orelse tpl.len;
        if (brace > i) if (w) |out| try out.writeAll(tpl[i..brace]);
        if (brace == tpl.len) break;
        i = brace;
        const ch = tpl[i];
        if (i + 1 < tpl.len and tpl[i + 1] == ch) {
            if (w) |out| try out.writeByte(ch);
            i += 2;
            continue;
        }
        if (ch == '}') return error.Invalid;
        const close = std.mem.indexOfScalarPos(u8, tpl, i + 1, '}') orelse return error.Invalid;
        const inner = tpl[i + 1 .. close];
        var k: usize = undefined;
        if (inner.len > 0 and allDigits(inner)) {
            if (mode == .copy) return error.Invalid;
            mode = .index;
            k = std.fmt.parseInt(usize, inner, 10) catch return error.Invalid;
            if (k >= p.n) return error.Invalid;
        } else {
            if (mode == .index) return error.Invalid;
            mode = .copy;
            if (seq >= p.n or !std.mem.eql(u8, inner, p.marks[seq].inner)) return error.Invalid;
            k = seq;
            seq += 1;
        }
        used |= @as(u32, 1) << @intCast(p.marks[k].arg);
        if (w) |out| try emit(ctx, out, k);
        i = close + 1;
    }
    if (mode == .copy and seq != p.n) return error.Invalid;
    if (used != p.args) return error.Invalid;
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Não serve para o texto de formato `english`.
fn badTemplate(tpl: []const u8, english: []const u8) bool {
    const p = parseFormat(english) orelse return false;
    walk(tpl, &p, null, undefined, undefined) catch return true;
    return false;
}

// --- Plural (CLDR) ------------------------------------------------------------------
//
// As categorias do CLDR (https://cldr.unicode.org, "Language Plural Rules"), só para
// números inteiros: o app conta coisas. A forma `other` de alguns idiomas (o russo, o
// tcheco) só existe para frações, então nunca aparece aqui.

pub const Plural = enum(u3) { zero, one, two, few, many, other };
const n_forms = @typeInfo(Plural).@"enum".field_names.len;

pub const Rule = enum(u8) { other, one, one01, one_many, one01_many, east_slavic, polish, czech, south_slavic, slovenian, lithuanian, latvian, romanian, arabic, hebrew, irish, welsh, one_mod10, filipino, maltese };

/// `examples`: alguns números de cada forma, para quem traduz (o modelo e o editor do site
/// mostram; um teste confere com `category`).
const RuleInfo = struct { rule: Rule, forms: []const u8, examples: []const u8, langs: []const u8 };

/// Cada regra, as formas que os números inteiros usam nela e os idiomas (o código sem a
/// região, ou com ela quando a região muda a regra). tools/i18n_strings.py e o editor do
/// site leem esta tabela daqui (as formas do modelo de cada idioma).
pub const rules = [_]RuleInfo{
    .{ .rule = .other, .forms = "other", .examples = "other=0,1,2,5", .langs = "bm bo dz id ig ii ja jv kde kea km ko lo ms my nqo sah ses sg su th to vi wo yo yue zh" },
    .{ .rule = .one, .forms = "one other", .examples = "one=1 other=0,2,5,21", .langs = "af an ast az bg ce ckb da de dv ee el en eo et eu fi fo fur fy gl gsw ha haw hu ia io ka kk kl ks ku ky lb lg lij ml mn mr nb nd ne nl nn no om or os pap ps rm sc scn sd so sq ss st sv sw ta te tk tn tr ts ug ur uz ve vo xh yi" },
    .{ .rule = .one01, .forms = "one other", .examples = "one=0,1 other=2,5,21", .langs = "am as bn doi fa ff gu hi hy kab kn pcm zu" },
    .{ .rule = .one_many, .forms = "one many other", .examples = "one=1 many=1000000 other=0,2,5,21", .langs = "ca es it pt-PT vec" },
    .{ .rule = .one01_many, .forms = "one many other", .examples = "one=0,1 many=1000000 other=2,5,21", .langs = "fr pt" },
    .{ .rule = .east_slavic, .forms = "one few many", .examples = "one=1,21,31 few=2,3,4,22 many=0,5,11,12,14", .langs = "be ru uk" },
    .{ .rule = .polish, .forms = "one few many", .examples = "one=1 few=2,3,4,22 many=0,5,12,21", .langs = "pl" },
    .{ .rule = .czech, .forms = "one few other", .examples = "one=1 few=2,3,4 other=0,5,21", .langs = "cs sk" },
    .{ .rule = .south_slavic, .forms = "one few other", .examples = "one=1,21,31 few=2,3,4,22 other=0,5,11,12", .langs = "bs hr sh sr" },
    .{ .rule = .slovenian, .forms = "one two few other", .examples = "one=1,101 two=2,102 few=3,4,103 other=0,5,11", .langs = "sl" },
    .{ .rule = .lithuanian, .forms = "one few other", .examples = "one=1,21,31 few=2,3,9,22 other=0,10,11,19", .langs = "lt" },
    .{ .rule = .latvian, .forms = "zero one other", .examples = "zero=0,10,11,19 one=1,21,31 other=2,5,22", .langs = "lv prg" },
    .{ .rule = .romanian, .forms = "one few other", .examples = "one=1 few=0,2,19,101 other=20,21,100", .langs = "mo ro" },
    .{ .rule = .arabic, .forms = "zero one two few many other", .examples = "zero=0 one=1 two=2 few=3,10,103 many=11,99,111 other=100,101,102", .langs = "ar ars" },
    .{ .rule = .hebrew, .forms = "one two other", .examples = "one=1 two=2 other=0,3,10", .langs = "he iw" },
    .{ .rule = .irish, .forms = "one two few many other", .examples = "one=1 two=2 few=3,6 many=7,10 other=0,11", .langs = "ga" },
    .{ .rule = .welsh, .forms = "zero one two few many other", .examples = "zero=0 one=1 two=2 few=3 many=6 other=4,5,7", .langs = "cy" },
    .{ .rule = .one_mod10, .forms = "one other", .examples = "one=1,21,31 other=0,2,11", .langs = "is mk" },
    .{ .rule = .filipino, .forms = "one other", .examples = "one=0,1,2,3,5 other=4,6,9,14", .langs = "fil tl" },
    .{ .rule = .maltese, .forms = "one two few many other", .examples = "one=1 two=2 few=0,3,10,103 many=11,19,111 other=20,100", .langs = "mt" },
};

/// A categoria de `n` na regra.
pub fn category(rule: Rule, n: u64) Plural {
    const m10 = n % 10;
    const m100 = n % 100;
    const teen = m100 >= 11 and m100 <= 19;
    return switch (rule) {
        .other => .other,
        .one => if (n == 1) .one else .other,
        .one01 => if (n <= 1) .one else .other,
        .one_many => if (n == 1) .one else if (n != 0 and n % 1_000_000 == 0) .many else .other,
        .one01_many => if (n <= 1) .one else if (n % 1_000_000 == 0) .many else .other,
        .east_slavic => if (m10 == 1 and m100 != 11) .one else if (m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14)) .few else .many,
        .polish => if (n == 1) .one else if (m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14)) .few else .many,
        .czech => if (n == 1) .one else if (n >= 2 and n <= 4) .few else .other,
        .south_slavic => if (m10 == 1 and m100 != 11) .one else if (m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14)) .few else .other,
        .slovenian => if (m100 == 1) .one else if (m100 == 2) .two else if (m100 == 3 or m100 == 4) .few else .other,
        .lithuanian => if (teen) .other else if (m10 == 1) .one else if (m10 >= 2) .few else .other,
        .latvian => if (m10 == 0 or teen) .zero else if (m10 == 1) .one else .other,
        .romanian => if (n == 1) .one else if (n == 0 or (m100 >= 1 and m100 <= 19)) .few else .other,
        .arabic => if (n == 0) .zero else if (n == 1) .one else if (n == 2) .two else if (m100 >= 3 and m100 <= 10) .few else if (m100 >= 11) .many else .other,
        .hebrew => if (n == 1) .one else if (n == 2) .two else .other,
        .irish => if (n == 1) .one else if (n == 2) .two else if (n >= 3 and n <= 6) .few else if (n >= 7 and n <= 10) .many else .other,
        .welsh => switch (n) {
            0 => .zero,
            1 => .one,
            2 => .two,
            3 => .few,
            6 => .many,
            else => .other,
        },
        .one_mod10 => if (m10 == 1 and m100 != 11) .one else .other,
        .filipino => if (m10 != 4 and m10 != 6 and m10 != 9) .one else .other,
        .maltese => if (n == 1) .one else if (n == 2) .two else if (n == 0 or (m100 >= 3 and m100 <= 10)) .few else if (teen) .many else .other,
    };
}

/// A regra de um código de idioma: com a região ("pt-PT") se a tabela tem, senão o idioma
/// ("pt"). Desconhecido: null.
pub fn ruleFor(code: []const u8) ?Rule {
    const base = code[0 .. std.mem.indexOfAny(u8, code, "-_") orelse code.len];
    var by_base: ?Rule = null;
    for (rules) |r| {
        var it = std.mem.tokenizeScalar(u8, r.langs, ' ');
        while (it.next()) |l| {
            if (sameCode(l, code)) return r.rule;
            if (by_base == null and sameCode(l, base)) by_base = r.rule;
        }
    }
    return by_base;
}

// --- O arquivo de tradução ---------------------------------------------------------

/// Uma forma por categoria do plural (null: a entrada não tem essa).
pub const Forms = [n_forms]?[]const u8;
const no_forms: Forms = @splat(null);

pub const Entry = struct {
    key: []const u8,
    /// A tradução; com formas de plural, a que vale para as categorias sem forma própria.
    value: []const u8,
    forms: Forms = no_forms,
    line: u32,

    pub fn hasForms(e: *const Entry) bool {
        for (e.forms) |f| if (f != null) return true;
        return false;
    }
};

/// O começo do arquivo: quem é o idioma.
pub const Header = struct {
    /// `language "日本語"`: o nome na própria língua.
    name: ?[]const u8 = null,
    /// `code="ja"`.
    code: ?[]const u8 = null,
    /// `english="Japanese"`.
    english: ?[]const u8 = null,
    /// `direction "rtl"`.
    rtl: bool = false,
    /// `font-script "ja"`.
    font_script: ?[]const u8 = null,
    /// `plurals "ru"`: as regras de outro código.
    plurals: ?[]const u8 = null,
};

pub const File = struct { header: Header, entries: []Entry };

pub const FileError = error{ SyntaxError, OutOfMemory, BadEntry };

/// O arquivo de tradução: o cabeçalho (nós sem aspas: `language`, `direction`,
/// `font-script`, `plurals`) e um nó por entrada, `"inglês" "tradução"`, ou com as formas
/// de plural como propriedades (`one="…" few="…"`, o texto solto valendo para as outras).
/// Texto vazio é tradução que falta (o modelo de um idioma novo vem assim): a entrada, ou a
/// forma, fica de fora. Nó sem aspas desconhecido também (um arquivo de uma versão mais nova
/// abre igual); tools/i18n_strings.py --check aponta.
pub fn parseFile(arena: std.mem.Allocator, src: []const u8, diag: ?*kdl.Diagnostic) FileError!File {
    const nodes = try kdl.parse(arena, src, diag);
    var header: Header = .{};
    const out = try arena.alloc(Entry, nodes.len);
    var n: usize = 0;
    for (nodes) |*node| {
        if (!node.quoted) {
            readHeader(&header, node, diag) catch |e| return e;
            continue;
        }
        out[n] = try readEntry(node, diag) orelse continue;
        n += 1;
    }
    return .{ .header = header, .entries = out[0..n] };
}

fn bad(diag: ?*kdl.Diagnostic, line: u32, msg: []const u8) FileError {
    if (diag) |d| d.* = .{ .line = line, .message = msg };
    return error.BadEntry;
}

fn readHeader(h: *Header, node: *const kdl.Node, diag: ?*kdl.Diagnostic) FileError!void {
    const name = node.name;
    const arg0 = if (node.args.len == 1) node.args[0].asString() else null;
    if (std.mem.eql(u8, name, "language")) {
        const v = arg0 orelse return bad(diag, node.line, "esperava language \"Nome\" code=\"xx\"");
        if (v.len == 0) return bad(diag, node.line, "o nome do idioma está vazio");
        h.name = v;
        if (node.str("code")) |code| {
            if (!validCode(code)) return bad(diag, node.line, "code: letras, números e -, até 15 (\"ja\", \"pt-PT\")");
            h.code = code;
        }
        if (node.str("english")) |e| h.english = e;
    } else if (std.mem.eql(u8, name, "direction")) {
        const v = arg0 orelse return bad(diag, node.line, "esperava direction \"ltr\" ou \"rtl\"");
        if (std.mem.eql(u8, v, "rtl")) h.rtl = true else if (std.mem.eql(u8, v, "ltr")) h.rtl = false else return bad(diag, node.line, "direction: \"ltr\" ou \"rtl\"");
    } else if (std.mem.eql(u8, name, "font-script")) {
        const v = arg0 orelse return bad(diag, node.line, "esperava font-script \"ja\"");
        if (!validCode(v)) return bad(diag, node.line, "font-script: um código como \"ja\", \"zh\" ou \"ko\"");
        h.font_script = v;
    } else if (std.mem.eql(u8, name, "plurals")) {
        const v = arg0 orelse return bad(diag, node.line, "esperava plurals \"ru\"");
        if (ruleFor(v) == null) return bad(diag, node.line, "plurals: um código de idioma que o app conhece");
        h.plurals = v;
    }
}

fn readEntry(node: *const kdl.Node, diag: ?*kdl.Diagnostic) FileError!?Entry {
    if (node.children.len > 0 or node.args.len > 1 or node.name.len == 0)
        return bad(diag, node.line, "esperava \"inglês\" \"tradução\"");
    var e: Entry = .{ .key = node.name, .value = "", .line = node.line };
    if (node.args.len == 1) e.value = node.args[0].asString() orelse return bad(diag, node.line, "esperava \"inglês\" \"tradução\"");
    for (node.props) |p| {
        const cat = std.meta.stringToEnum(Plural, p.key) orelse return bad(diag, node.line, "forma de plural desconhecida (zero, one, two, few, many ou other)");
        const v = p.value.asString() orelse return bad(diag, node.line, "a forma de plural é um texto entre aspas");
        if (v.len > 0) e.forms[@intFromEnum(cat)] = v;
    }
    if (e.value.len == 0) {
        // Só formas: vale a de `other`, ou a última da lista (many, few…), para quem pede
        // o texto sem contagem.
        var k: usize = n_forms;
        while (k > 0) : (k -= 1) {
            if (e.forms[k - 1]) |f| {
                e.value = f;
                break;
            }
        }
        // Nada preenchido: ainda sem tradução.
        if (e.value.len == 0) return null;
    }
    return e;
}

fn validCode(s: []const u8) bool {
    if (s.len == 0 or s.len > 15) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return std.ascii.isAlphabetic(s[0]);
}

/// Mesmo código, sem ligar para maiúsculas nem para "-" ou "_" ("pt-br" = "pt_BR").
fn sameCode(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xx = if (x == '_') '-' else std.ascii.toLower(x);
        const yy = if (y == '_') '-' else std.ascii.toLower(y);
        if (xx != yy) return false;
    }
    return true;
}

// --- A tabela --------------------------------------------------------------------

const Value = struct {
    text: [:0]const u8,
    forms: ?*const [n_forms]?[:0]const u8 = null,
};

pub const Table = struct {
    map: std.StringHashMapUnmanaged(Value) = .empty,

    fn get(t: *const Table, english: []const u8) ?[:0]const u8 {
        return if (t.map.get(english)) |v| v.text else null;
    }

    /// A forma para `n`; null quando não há tradução ou a que há é o próprio inglês
    /// (espaço reservado esperando alguém): aí o inglês escolhe entre singular e plural.
    fn form(t: *const Table, english: []const u8, n: u64, rule: Rule) ?[]const u8 {
        const v = t.map.get(english) orelse return null;
        const f: []const u8 = if (v.forms) |fs| fs[@intFromEnum(category(rule, n))] orelse v.text else v.text;
        return if (std.mem.eql(u8, f, english)) null else f;
    }

    /// Junta as entradas de um arquivo (a última vale). As cópias ficam em `a`.
    fn add(t: *Table, a: std.mem.Allocator, entries: []const Entry) !void {
        try t.map.ensureUnusedCapacity(a, @intCast(entries.len));
        for (entries) |e| {
            const gop = t.map.getOrPutAssumeCapacity(e.key);
            if (!gop.found_existing) gop.key_ptr.* = try a.dupe(u8, e.key);
            var v: Value = .{ .text = try a.dupeSentinel(u8, e.value, 0) };
            if (e.hasForms()) {
                const fs = try a.create([n_forms]?[:0]const u8);
                for (e.forms, fs) |f, *o| o.* = if (f) |s| try a.dupeSentinel(u8, s, 0) else null;
                v.forms = fs;
            }
            gop.value_ptr.* = v;
        }
    }
};

/// Tudo o que vive até o app fechar: as tabelas publicadas, os nomes e códigos.
var perm: std.heap.ArenaAllocator = .init(std.heap.c_allocator);

fn buildTable(info: *const Info) *const Table {
    const a = perm.allocator();
    const t = a.create(Table) catch return &empty_table;
    t.* = .{};
    var tmp: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer tmp.deinit();
    if (info.packed_data) |p| {
        if (embutido.inflate(tmp.allocator(), (cabecalho.split(p) orelse return t).data)) |src|
            addSource(t, a, tmp.allocator(), src, info.code, "embutida")
        else |e| std.log.warn("tradução {s} embutida ilegível ({t})", .{ info.code, e });
    }
    if (info.user_text) |src| addSource(t, a, tmp.allocator(), src, info.code, "da pasta de configurações");
    return t;
}

const empty_table: Table = .{};

fn addSource(t: *Table, a: std.mem.Allocator, tmp: std.mem.Allocator, src: []const u8, code: []const u8, what: []const u8) void {
    var diag: kdl.Diagnostic = .{};
    const file = parseFile(tmp, src, &diag) catch |e| {
        std.log.warn("tradução {s} ({s}) ilegível na linha {d}: {s} ({t})", .{ code, what, diag.line, diag.message, e });
        return;
    };
    t.add(a, file.entries) catch std.log.warn("tradução {s}: sem memória", .{code});
}

// --- Os idiomas ----------------------------------------------------------------------

pub const max_langs = 64;

pub const Info = struct {
    /// "pt", "ja", "pt-PT" (com o zero no fim: os plugins pedem assim).
    code: [:0]const u8,
    /// O nome na própria língua ("日本語").
    name: []const u8,
    /// O nome em inglês ("Japanese"); vazio quando o arquivo não diz.
    english: []const u8 = "",
    kind: Kind = .file,
    rtl: bool = false,
    font_script: []const u8,
    rule: Rule = .one,
    /// O arquivo embutido (cabeçalho e deflate).
    packed_data: ?[]const u8 = null,
    /// O arquivo da pasta de configurações, inteiro, e o nome dele ("ja.kdl").
    user_text: ?[]const u8 = null,
    user_name: []const u8 = "",
    user_hash: u64 = 0,
    /// O que está errado no arquivo da pasta ("linha 12: …"), para a página Idioma mostrar.
    problem: ?[]const u8 = null,
    table: ?*const Table = null,
    active: ?*const Active = null,
    /// Por mil dos textos do código com tradução; null = ainda não contado.
    coverage: ?u16 = null,
};

var langs: [max_langs]Info = undefined;
var n_langs: usize = 0;
var inited = false;
/// Os textos dos arquivos da pasta de configurações (trocados a cada leitura dela).
var files_arena: ?*std.heap.ArenaAllocator = null;

fn ensureInit() void {
    if (inited) return;
    inited = true;
    langs[0] = .{ .code = "pt", .name = "Português (Brasil)", .english = "Portuguese", .kind = .pt, .font_script = "pt" };
    langs[1] = .{ .code = "en", .name = "English (US)", .english = "English", .kind = .en, .font_script = "en" };
    n_langs = 2;
    var tmp: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer tmp.deinit();
    for (embutidos.files) |f| {
        const p = cabecalho.split(f.data) orelse continue;
        var diag: kdl.Diagnostic = .{};
        const nodes = kdl.parse(tmp.allocator(), p.header, &diag) catch {
            std.log.warn("i18n/{s}.kdl: cabeçalho ilegível na linha {d}: {s}", .{ f.name, diag.line, diag.message });
            continue;
        };
        var h: Header = .{};
        for (nodes) |*node| if (!node.quoted) readHeader(&h, node, &diag) catch {};
        const i = register(h, f.name) orelse continue;
        langs[i].packed_data = f.data;
    }
}

/// Um idioma novo (ou o que já existe com o mesmo código): o índice dele.
fn register(h: Header, file_stem: []const u8) ?usize {
    const a = perm.allocator();
    const code = h.code orelse file_stem;
    if (!validCode(code)) {
        std.log.warn("tradução {s}: código inválido", .{file_stem});
        return null;
    }
    for (langs[0..n_langs], 0..) |*l, i| if (sameCode(l.code, code)) {
        if (l.kind != .file) {
            std.log.warn("tradução {s}: pt e en ficam no código, não num arquivo", .{code});
            return null;
        }
        return i;
    };
    if (n_langs == max_langs) return null;
    if (h.code == null) std.log.warn("tradução {s}: sem `language \"Nome\" code=\"{s}\"` no começo", .{ file_stem, file_stem });
    const code_z = a.dupeSentinel(u8, code, 0) catch return null;
    langs[n_langs] = .{
        .code = code_z,
        .name = a.dupe(u8, h.name orelse code) catch return null,
        .english = a.dupe(u8, h.english orelse "") catch return null,
        .rtl = h.rtl,
        .font_script = a.dupe(u8, h.font_script orelse code) catch return null,
        .rule = ruleOf(h, code),
    };
    n_langs += 1;
    return n_langs - 1;
}

fn ruleOf(h: Header, code: []const u8) Rule {
    if (h.plurals) |p| if (ruleFor(p)) |r| return r;
    return ruleFor(code) orelse .one;
}

/// Todos os idiomas: português e inglês (no código), os embutidos e os da pasta de
/// configurações. Só na thread da interface; vale até a próxima leitura da pasta.
pub fn languages() []Info {
    ensureInit();
    return langs[0..n_langs];
}

/// O idioma de `code`: o mesmo código, ou o idioma dele sem a região ("ja-JP" → "ja",
/// "pt_BR" → "pt"), ou um com a mesma língua e outra região ("pt-PT" pedido, só "pt"
/// existindo). null: nenhum.
pub fn match(code: []const u8) ?usize {
    ensureInit();
    for (langs[0..n_langs], 0..) |l, i| if (sameCode(l.code, code)) return i;
    const base = code[0 .. std.mem.indexOfAny(u8, code, "-_") orelse code.len];
    if (base.len == 0) return null;
    for (langs[0..n_langs], 0..) |l, i| if (sameCode(l.code, base)) return i;
    for (langs[0..n_langs], 0..) |l, i| {
        const lb = l.code[0 .. std.mem.indexOfAny(u8, l.code, "-_") orelse l.code.len];
        if (sameCode(lb, base)) return i;
    }
    return null;
}

/// O código salvo nas configurações, ou o do sistema quando ele está vazio (seguir o
/// sistema) ou não existe mais (o arquivo saiu da pasta).
pub fn fromSetting(code: []const u8) []const u8 {
    ensureInit();
    if (code.len > 0) if (match(code)) |i| return langs[i].code;
    return system();
}

/// `language` das configurações até a 0.6 (0 = sistema, 1 = português, 2 = inglês,
/// 3 = japonês, 4 = russo): o código que ele quer dizer ("" = seguir o sistema).
pub fn legacyCode(v: u8) []const u8 {
    return switch (v) {
        1 => "pt",
        2 => "en",
        3 => "ja",
        4 => "ru",
        else => "",
    };
}

/// O número de `legacyCode` de um código, para uma versão antiga que abra o mesmo arquivo
/// de configurações (0 para os outros: ela segue o sistema).
pub fn legacyNumber(code: []const u8) u8 {
    for (1..5) |v| if (sameCode(legacyCode(@intCast(v)), code)) return @intCast(v);
    return 0;
}

/// O idioma do sistema: a primeira preferência que o app tem (com a região, "pt-PT", ou
/// sem, "pt"), ou inglês. No Windows o SDL lê os idiomas da interface do usuário.
pub fn system() [:0]const u8 {
    ensureInit();
    var count: c_int = 0;
    const list = c.SDL_GetPreferredLocales(&count) orelse return "en";
    defer c.SDL_free(@ptrCast(list));
    for (0..@as(usize, @intCast(@max(count, 0)))) |k| {
        const loc = list[k] orelse continue;
        const l = std.mem.span(loc.*.language orelse continue);
        const country = if (loc.*.country) |cc| std.mem.span(cc) else "";
        if (pickSystem(l, country)) |i| return langs[i].code;
    }
    return "en";
}

/// Uma preferência do sistema: o código com a região, se há um arquivo dele, ou o idioma.
fn pickSystem(lang: []const u8, country: []const u8) ?usize {
    var buf: [40]u8 = undefined;
    if (country.len > 0) if (std.fmt.bufPrint(&buf, "{s}-{s}", .{ lang, country })) |full| {
        for (langs[0..n_langs], 0..) |l, i| if (sameCode(l.code, full)) return i;
    } else |_| {};
    for (langs[0..n_langs], 0..) |l, i| if (sameCode(l.code, lang)) return i;
    return null;
}

// --- A pasta de configurações ---------------------------------------------------------

pub const UserFile = struct { name: []const u8, text: []const u8 };

/// Os arquivos de larpercord/i18n/ (todos os .kdl de lá, a cada vez que a pasta muda): um
/// código novo vira um idioma, o de um embutido vale por cima dele. Devolve verdadeiro se
/// o texto do idioma em uso mudou (o arquivo dele mudou e a tabela foi refeita). Só na
/// thread da interface.
pub fn setUserFiles(files: []const UserFile) bool {
    ensureInit();
    const old_arena = files_arena;
    const arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return false;
    arena.* = .init(std.heap.c_allocator);
    files_arena = arena;
    const a = arena.allocator();
    const act = now();
    var changed_active = false;
    var seen: [max_langs]bool = @splat(false);
    var hb: [4096]u8 = undefined;
    for (files) |f| {
        if (!std.mem.endsWith(u8, f.name, ".kdl")) continue;
        const stem = f.name[0 .. f.name.len - 4];
        var tmp: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer tmp.deinit();
        var diag: kdl.Diagnostic = .{};
        var h: Header = .{};
        if (kdl.parse(tmp.allocator(), cabecalho.extract(f.text, &hb), &diag)) |nodes| {
            for (nodes) |*node| if (!node.quoted) readHeader(&h, node, &diag) catch {};
        } else |_| {}
        const i = register(h, stem) orelse continue;
        const l = &langs[i];
        if (seen[i]) {
            std.log.warn("tradução {s}: dois arquivos com o mesmo código na pasta ({s})", .{ l.code, f.name });
            continue;
        }
        seen[i] = true;
        const text = a.dupe(u8, f.text) catch continue;
        const hash = std.hash.Wyhash.hash(0, f.text);
        // O cabeçalho manda no nome (um arquivo só da pasta pode ter mudado de nome).
        if (l.packed_data == null) {
            if (h.name) |name| l.name = perm.allocator().dupe(u8, name) catch l.name;
            if (h.english) |e| l.english = perm.allocator().dupe(u8, e) catch l.english;
            l.rtl = h.rtl;
            if (h.font_script) |fs| l.font_script = perm.allocator().dupe(u8, fs) catch l.font_script;
            l.rule = ruleOf(h, l.code);
        }
        l.problem = checkUser(a, f.name, f.text);
        l.user_name = a.dupe(u8, f.name) catch "";
        // Salvo com um erro no meio (comum enquanto se edita): o idioma fica com o texto que
        // tinha, e a página Idioma mostra o problema até o arquivo abrir de novo.
        if (l.problem != null and l.user_text != null and l.user_hash != hash) {
            l.user_text = a.dupe(u8, l.user_text.?) catch null;
            continue;
        }
        const was = l.user_text != null;
        l.user_text = text;
        if (!was or l.user_hash != hash) {
            l.user_hash = hash;
            changed_active = invalidate(l, act) or changed_active;
        }
    }
    // O arquivo que saiu: o embutido volta sozinho; um idioma só da pasta some da lista
    // (o em uso fica até trocar, com o texto que tinha).
    var i: usize = 2;
    while (i < n_langs) {
        const l = &langs[i];
        if (!seen[i] and l.user_text != null) {
            l.user_text = null;
            l.user_name = "";
            l.problem = null;
            l.user_hash = 0;
            if (l.packed_data != null) changed_active = invalidate(l, act) or changed_active;
        }
        const in_use = l.active != null and l.active == act;
        if (l.packed_data == null and l.user_text == null and !in_use) {
            std.mem.copyForwards(Info, langs[i .. n_langs - 1], langs[i + 1 .. n_langs]);
            std.mem.copyForwards(bool, seen[i .. n_langs - 1], seen[i + 1 .. n_langs]);
            n_langs -= 1;
            continue;
        }
        i += 1;
    }
    if (old_arena) |o| {
        o.deinit();
        std.heap.c_allocator.destroy(o);
    }
    return changed_active;
}

/// O texto do idioma mudou: a tabela e a contagem são refeitas quando alguém pedir, e o
/// em uso é publicado de novo já (verdadeiro).
fn invalidate(l: *Info, act: *const Active) bool {
    const was_active = l.active != null and l.active == act;
    l.table = null;
    l.active = null;
    l.coverage = null;
    if (!was_active) return false;
    for (langs[0..n_langs], 0..) |*x, k| if (x == l) publish(k);
    return true;
}

/// "xx.kdl:12: expected …" (no idioma da interface), ou null quando o arquivo abre.
fn checkUser(a: std.mem.Allocator, name: []const u8, text: []const u8) ?[]const u8 {
    var tmp: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer tmp.deinit();
    var diag: kdl.Diagnostic = .{};
    _ = parseFile(tmp.allocator(), text, &diag) catch {
        std.log.warn("tradução {s}: linha {d}: {s}", .{ name, diag.line, diag.message });
        return std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ name, diag.line, problemText(diag.message) }) catch null;
    };
    return null;
}

/// Os problemas que um arquivo de tradução pode ter (os daqui e os do leitor de KDL, que
/// fala português), para a página Idioma mostrar no idioma de quem está traduzindo.
const problems = [_]struct { pt: []const u8, en: []const u8 }{
    .{ .pt = "esperava language \"Nome\" code=\"xx\"", .en = "expected language \"Name\" code=\"xx\"" },
    .{ .pt = "o nome do idioma está vazio", .en = "the language name is empty" },
    .{ .pt = "code: letras, números e -, até 15 (\"ja\", \"pt-PT\")", .en = "code: letters, digits and -, up to 15 (\"ja\", \"pt-PT\")" },
    .{ .pt = "esperava direction \"ltr\" ou \"rtl\"", .en = "expected direction \"ltr\" or \"rtl\"" },
    .{ .pt = "direction: \"ltr\" ou \"rtl\"", .en = "direction: \"ltr\" or \"rtl\"" },
    .{ .pt = "esperava font-script \"ja\"", .en = "expected font-script \"ja\"" },
    .{ .pt = "font-script: um código como \"ja\", \"zh\" ou \"ko\"", .en = "font-script: a code like \"ja\", \"zh\" or \"ko\"" },
    .{ .pt = "esperava plurals \"ru\"", .en = "expected plurals \"ru\"" },
    .{ .pt = "plurals: um código de idioma que o app conhece", .en = "plurals: a language code the app knows" },
    .{ .pt = "esperava \"inglês\" \"tradução\"", .en = "expected \"English\" \"translation\"" },
    .{ .pt = "forma de plural desconhecida (zero, one, two, few, many ou other)", .en = "unknown plural form (zero, one, two, few, many or other)" },
    .{ .pt = "a forma de plural é um texto entre aspas", .en = "a plural form is a text in quotes" },
    .{ .pt = "blocos aninhados demais", .en = "too many nested blocks" },
    .{ .pt = "comentário /* sem fechar", .en = "a /* comment that isn't closed" },
    .{ .pt = "escape inválido", .en = "invalid escape" },
    .{ .pt = "esperava um nome", .en = "expected a name" },
    .{ .pt = "faltou fechar '}'", .en = "a '}' is missing" },
    .{ .pt = "número inválido", .en = "invalid number" },
    .{ .pt = "número longo demais", .en = "number too long" },
    .{ .pt = "'}' sobrando", .en = "an extra '}'" },
    .{ .pt = "string sem fechar", .en = "a text that isn't closed" },
};

fn problemText(msg: []const u8) []const u8 {
    for (problems) |pr| if (std.mem.eql(u8, pr.pt, msg)) return tr(pr.pt, pr.en);
    return msg;
}

// --- Quanto está traduzido -------------------------------------------------------------

/// Por mil dos textos do código (i18n/keys.txt, gerado por tools/i18n_strings.py --keys)
/// que cada idioma de arquivo traduz. A entrada igual ao inglês não conta: ela está
/// esperando alguém traduzir. Conta uma vez e guarda (até o arquivo mudar); null quando o
/// build não tem a lista. Só na thread da interface.
pub fn coverage(i: usize) ?u16 {
    ensureInit();
    if (i >= n_langs or langs[i].kind != .file or no_keys) return null;
    if (langs[i].coverage == null) countAll();
    return langs[i].coverage;
}

/// O build veio sem a lista de textos (ou ela não abre): sem porcentagem, e sem tentar de
/// novo a cada quadro.
var no_keys = false;

fn countAll() void {
    var tmp: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer tmp.deinit();
    const ta = tmp.allocator();
    const keys = keySet(ta) orelse {
        no_keys = true;
        return;
    };
    if (keys.count() == 0) {
        no_keys = true;
        return;
    }
    for (langs[0..n_langs]) |*l| {
        if (l.kind != .file or l.coverage != null) continue;
        // A tabela pronta (a do idioma em uso) serve; as outras são lidas e jogadas fora.
        if (l.table) |t| {
            l.coverage = countIn(t, &keys);
            continue;
        }
        var scratch: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer scratch.deinit();
        const t = buildInto(scratch.allocator(), l) orelse continue;
        l.coverage = countIn(t, &keys);
    }
}

/// Como `buildTable`, numa arena que quem chama joga fora.
fn buildInto(a: std.mem.Allocator, info: *const Info) ?*const Table {
    const t = a.create(Table) catch return null;
    t.* = .{};
    if (info.packed_data) |p| if (cabecalho.split(p)) |pk| if (embutido.inflate(a, pk.data)) |src| addSource(t, a, a, src, info.code, "embutida") else |_| {};
    if (info.user_text) |src| addSource(t, a, a, src, info.code, "da pasta de configurações");
    return t;
}

const KeySet = std.StringHashMapUnmanaged(void);

fn keySet(a: std.mem.Allocator) ?KeySet {
    const text = embutido.inflate(a, embutidos.keys) catch return null;
    var keys: KeySet = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const key = unescapeKey(a, line) catch return null;
        keys.put(a, key, {}) catch return null;
    }
    return keys;
}

/// Uma linha de i18n/keys.txt: `\n` é a quebra de linha e `\\` a barra.
fn unescapeKey(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '\\') == null) return line;
    var out = try a.alloc(u8, line.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            out[n] = switch (line[i]) {
                'n' => '\n',
                't' => '\t',
                else => line[i],
            };
        } else out[n] = line[i];
        n += 1;
    }
    return out[0..n];
}

fn countIn(t: *const Table, keys: *const KeySet) u16 {
    var done: usize = 0;
    var it = t.map.iterator();
    while (it.next()) |e| {
        if (!keys.contains(e.key_ptr.*)) continue;
        if (translatedValue(e.key_ptr.*, e.value_ptr.*)) done += 1;
    }
    return @intCast(@min(1000, done * 1000 / keys.count()));
}

fn translatedValue(key: []const u8, v: Value) bool {
    if (!std.mem.eql(u8, v.text, key)) return true;
    if (v.forms) |fs| for (fs) |f| if (f) |s| if (!std.mem.eql(u8, s, key)) return true;
    return false;
}

// --- Testes ----------------------------------------------------------------------

const testing = std.testing;

/// O idioma de teste (src/ui/i18n_xx.kdl): o "xx" não existe no app, entra como entraria um
/// arquivo da pasta de configurações, sem nada no código saber dele.
const xx_file = @embedFile("i18n_xx.kdl");

test "idioma padrão e troca" {
    const old = current();
    defer set(old);
    set("ja");
    try testing.expect(en());
    try testing.expect(is("ja"));
    try testing.expectEqualStrings("言語", tr("Idioma", "Language"));
    // Sem tradução: o inglês.
    try testing.expectEqualStrings("Sign in to nowhere", tr("Entrar em lugar nenhum", "Sign in to nowhere"));
    try testing.expectEqualStrings("言語", trZ("Idioma", "Language"));
    set("pt");
    try testing.expectEqualStrings("Idioma", tr("Idioma", "Language"));
    set("en");
    try testing.expectEqualStrings("Language", tr("Idioma", "Language"));
    // Desconhecido: inglês; com setExact, nada muda.
    set("ja");
    try testing.expect(!setExact("qq"));
    try testing.expect(is("ja"));
    set("qq");
    try testing.expect(is("en"));
}

// O japonês sem tradução cai no inglês também no fmt (não no português).
test "fallback do japonês no fmt" {
    const old = current();
    defer set(old);
    set("ja");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Message in nowhere #geral", fmt(&buf, "Conversar em lugar nenhum #{s}", "Message in nowhere #{s}", .{"geral"}));
    set("pt");
    try testing.expectEqualStrings("Conversar em #geral", fmt(&buf, "Conversar em #{s}", "Message in #{s}", .{"geral"}));
}

test "marcadores do inglês" {
    const p = parseFormat("Level: {d:.0} dB · {1s} {{x}} {}").?;
    try testing.expectEqual(@as(usize, 3), p.n);
    try testing.expectEqualStrings("d:.0", p.marks[0].inner);
    try testing.expectEqual(@as(u8, 0), p.marks[0].arg);
    try testing.expectEqualStrings("s", p.marks[1].spec);
    try testing.expectEqual(@as(u8, 1), p.marks[1].arg);
    // O implícito continua a contagem dos implícitos, como no std.fmt.
    try testing.expectEqual(@as(u8, 1), p.marks[2].arg);
    try testing.expect(parseFormat("sem par }") == null);
    try testing.expect(parseFormat("com nome {[x]s}") == null);
    try testing.expectEqual(@as(usize, 0), parseFormat("nada {{aqui}}").?.n);
}

test "tradução de texto de formato: cópia, {N}, chaves e recusas" {
    const english = "{s} reacted with {s} to {d} messages";
    try testing.expect(!badTemplate("{s}さんが{s}で{d}件に反応", english));
    try testing.expect(!badTemplate("{2}件に{0}さんが{1}で反応 {{ok}}", english));
    try testing.expect(!badTemplate("{1}{1}{0}{2}", english));
    // Falta um valor, sobra um, tipo trocado, mistura, chave sozinha, índice demais.
    try testing.expect(badTemplate("{s}さんが反応", english));
    try testing.expect(badTemplate("{s}{s}{d}{d}", english));
    try testing.expect(badTemplate("{s}{d}{d}", english));
    try testing.expect(badTemplate("{0}{s}{d}", english));
    try testing.expect(badTemplate("{s}{s}{d} }", english));
    try testing.expect(badTemplate("{0}{1}{3}", english));
    try testing.expect(badTemplate("{0}{1}", english));
    // Sem marcadores no inglês: só as chaves dobradas.
    try testing.expect(!badTemplate("ok {{}}", "fine {{}}"));
    try testing.expect(badTemplate("{0}", "fine"));
}

test "formatar com a tradução, na ordem dela" {
    var buf: [128]u8 = undefined;
    var wr = std.Io.Writer.fixed(&buf);
    try translated(&wr, "{1}: {0}件 ({2})", "{d} messages in {s} ({d:.1}%)", .{ @as(u32, 12), "geral", @as(f32, 3.14159) });
    try testing.expectEqualStrings("geral: 12件 (3.1)", wr.buffered());
    // Marcadores errados: o inglês.
    wr = std.Io.Writer.fixed(&buf);
    try translated(&wr, "{s}件", "{d} messages in {s}", .{ @as(u32, 12), "geral" });
    try testing.expectEqualStrings("12 messages in geral", wr.buffered());
    // O inglês com posições: {N} conta os marcadores do texto, não os argumentos
    // ({0} = {1s}, {1} = {0d}).
    wr = std.Io.Writer.fixed(&buf);
    try translated(&wr, "{2}年{0}{1}日", "{1s} {0d}, {2d}", .{ @as(u32, 8), "11月", @as(u32, 2026) });
    try testing.expectEqualStrings("2026年11月8日", wr.buffered());
    // Sem valores: só o texto, com as chaves dobradas.
    wr = std.Io.Writer.fixed(&buf);
    try translated(&wr, "{{ok}} はい", "fine", .{});
    try testing.expectEqualStrings("{ok} はい", wr.buffered());
    // Cheio: corta sem cair no inglês.
    var small: [6]u8 = undefined;
    wr = std.Io.Writer.fixed(&small);
    try testing.expectError(error.WriteFailed, translated(&wr, "{0}件のメッセージ", "{d} messages", .{@as(u32, 7)}));
    try testing.expectEqualStrings("7件", wr.buffered()[0..4]);
}

test "fmt, fmtZ e allocPrint traduzidos" {
    const old = current();
    defer set(old);
    set("ja");
    const ja_table = @constCast(now().table.?);
    try ja_table.map.put(perm.allocator(), "{d} new messages since {s}", .{ .text = "{1}から{0}件の新着メッセージ" });
    try ja_table.map.put(perm.allocator(), "Broken {s}", .{ .text = "壊れた {d}" });
    var buf: [96]u8 = undefined;
    try testing.expectEqualStrings("12:30から5件の新着メッセージ", fmt(&buf, "{d} novas desde {s}", "{d} new messages since {s}", .{ 5, "12:30" }));
    try testing.expectEqualStrings("12:30から5件の新着メッセージ", fmtZ(&buf, "{d} novas desde {s}", "{d} new messages since {s}", .{ 5, "12:30" }));
    try testing.expectEqualStrings("Broken x", fmt(&buf, "Quebrado {s}", "Broken {s}", .{"x"}));
    // fmt corta sem partir um caractere; fmtZ sem espaço devolve "".
    var tiny: [8]u8 = undefined;
    try testing.expectEqualStrings("12:30か", fmt(&tiny, "{d} novas desde {s}", "{d} new messages since {s}", .{ 5, "12:30" }));
    try testing.expectEqualStrings("", fmtZ(&tiny, "{d} novas desde {s}", "{d} new messages since {s}", .{ 5, "12:30" }));
    const s = try allocPrint(testing.allocator, "{d} novas desde {s}", "{d} new messages since {s}", .{ 5, "12:30" });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("12:30から5件の新着メッセージ", s);
    const e = try allocPrint(testing.allocator, "Quebrado {s}", "Broken {s}", .{"y"});
    defer testing.allocator.free(e);
    try testing.expectEqualStrings("Broken y", e);
}

// Cada arquivo embutido precisa abrir, dizer quem é (com o código igual ao nome do
// arquivo), sem chave repetida, e cada tradução de texto de formato com os marcadores
// certos, em cada forma de plural (faltar tradução não é erro).
test "i18n/*.kdl embutidos: cabeçalho, arquivo válido e marcadores certos" {
    var bad_n: usize = 0;
    try testing.expect(embutidos.files.len >= 2);
    for (embutidos.files) |f| {
        var a: std.heap.ArenaAllocator = .init(testing.allocator);
        defer a.deinit();
        var diag: kdl.Diagnostic = .{};
        const p = cabecalho.split(f.data).?;
        // O comprimido abre igual ao arquivo (o que o app lê é o comprimido).
        const source = try embutido.inflate(a.allocator(), p.data);
        const file = parseFile(a.allocator(), source, &diag) catch |e| {
            std.debug.print("i18n/{s}.kdl:{d}: {s}\n", .{ f.name, diag.line, diag.message });
            return e;
        };
        try testing.expect(file.entries.len > 0);
        if (file.header.name == null or file.header.code == null or !std.mem.eql(u8, file.header.code.?, f.name)) {
            std.debug.print("i18n/{s}.kdl: falta `language \"Nome\" code=\"{s}\"` no começo\n", .{ f.name, f.name });
            bad_n += 1;
        }
        // O cabeçalho separado pelo build é o mesmo do arquivo.
        const nodes = try kdl.parse(a.allocator(), p.header, null);
        var h: Header = .{};
        for (nodes) |*node| if (!node.quoted) try readHeader(&h, node, null);
        try testing.expectEqualStrings(file.header.name orelse "", h.name orelse "");
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        for (file.entries) |e| {
            const gop = try seen.getOrPut(a.allocator(), e.key);
            if (gop.found_existing) {
                std.debug.print("i18n/{s}.kdl:{d}: chave repetida (a primeira na linha {d}): {s}\n", .{ f.name, e.line, gop.value_ptr.*, e.key });
                bad_n += 1;
            } else gop.value_ptr.* = e.line;
            // Os textos com marcadores {…} só podem ser de formato: no inglês de um
            // tr() não há chaves (tools/i18n_strings.py --check confere de novo).
            const fp = parseFormat(e.key) orelse continue;
            var texts: [n_forms + 1]?[]const u8 = undefined;
            texts[0] = e.value;
            for (e.forms, 1..) |fm, k| texts[k] = fm;
            for (texts) |maybe| {
                const v = maybe orelse continue;
                if (fp.n == 0 and std.mem.indexOfAny(u8, v, "{}") == null) continue;
                if (badTemplate(v, e.key)) {
                    std.debug.print("i18n/{s}.kdl:{d}: marcadores não batem com o inglês: {s} -> {s}\n", .{ f.name, e.line, e.key, v });
                    bad_n += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), bad_n);
}

test "os idiomas embutidos aparecem sozinhos, com o nome do arquivo" {
    const ls = languages();
    try testing.expectEqualStrings("pt", ls[0].code);
    try testing.expectEqualStrings("en", ls[1].code);
    const ja_i = match("ja").?;
    try testing.expectEqualStrings("日本語", ls[ja_i].name);
    try testing.expectEqualStrings("Japanese", ls[ja_i].english);
    try testing.expectEqual(Rule.other, ls[ja_i].rule);
    const ru_i = match("ru").?;
    try testing.expectEqualStrings("Русский", ls[ru_i].name);
    try testing.expectEqual(Rule.east_slavic, ls[ru_i].rule);
    // A região acha o idioma; outra língua, não.
    try testing.expectEqual(ja_i, match("ja-JP").?);
    try testing.expectEqual(@as(usize, 0), match("pt_BR").?);
    try testing.expectEqual(@as(?usize, null), match("de"));
    try testing.expectEqual(@as(?usize, null), match(""));
}

test "russo: tabela do arquivo e fallback em inglês" {
    const old = current();
    defer set(old);
    set("ru");
    try testing.expect(en());
    try testing.expect(!is("ja"));
    try testing.expectEqualStrings("Язык", tr("Idioma", "Language"));
    try testing.expectEqualStrings("Sign in to nowhere", tr("Entrar em lugar nenhum", "Sign in to nowhere"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Сегодня в 03:39", fmt(&buf, "Hoje às {s}", "Today at {s}", .{"03:39"}));
}

test "idioma do sistema: o código com a região, depois o idioma" {
    ensureInit();
    try testing.expectEqual(match("ru").?, pickSystem("ru", "RU").?);
    try testing.expectEqual(@as(usize, 0), pickSystem("pt", "BR").?);
    try testing.expectEqual(@as(?usize, null), pickSystem("rue", ""));
    try testing.expectEqual(@as(?usize, null), pickSystem("jam", ""));
    try testing.expect(sameCode("pt_BR", "pt-br"));
    try testing.expect(!sameCode("ru", "rue"));
}

test "configuração antiga (número) e nova (código)" {
    try testing.expectEqualStrings("ja", legacyCode(3));
    try testing.expectEqualStrings("ru", legacyCode(4));
    try testing.expectEqualStrings("", legacyCode(0));
    try testing.expectEqual(@as(u8, 4), legacyNumber("ru"));
    try testing.expectEqual(@as(u8, 1), legacyNumber("pt"));
    try testing.expectEqual(@as(u8, 0), legacyNumber("xx"));
    // (fromSetting com o código salvo é o `match`; vazio, pergunta ao sistema pelo SDL,
    // que os testes não têm.)
    try testing.expectEqualStrings("ru", languages()[match("ru-RU").?].code);
}

// As datas dos arquivos embutidos, com os valores na ordem em que o código passa
// (status_menu.zig, widgets.zig, profile.zig): o {N} conta os marcadores do texto
// em inglês, não os argumentos, e é fácil trocar dia e mês.
test "datas dos arquivos embutidos na ordem de cada idioma" {
    const old = current();
    defer set(old);
    var buf: [64]u8 = undefined;
    const day: u32 = 9;
    const month: u32 = 11;
    const year: u32 = 2026;
    set("ja");
    try testing.expectEqualStrings("11/09 03:39まで", fmt(&buf, "até {d:0>2}/{d:0>2} {s}", "until {1d:0>2}/{0d:0>2} {2s}", .{ day, month, "03:39" }));
    try testing.expectEqualStrings("2026/11/09 03:39", fmt(&buf, "{d:0>2}/{d:0>2}/{d} {s}", "{1d:0>2}/{0d:0>2}/{2d} {3s}", .{ day, month, year, "03:39" }));
    try testing.expectEqualStrings("2026年11月9日", fmt(&buf, "{d} de {s} de {d}", "{1s} {0d}, {2d}", .{ day, "11月", year }));
    set("ru");
    try testing.expectEqualStrings("до 09.11 03:39", fmt(&buf, "até {d:0>2}/{d:0>2} {s}", "until {1d:0>2}/{0d:0>2} {2s}", .{ day, month, "03:39" }));
    try testing.expectEqualStrings("09.11.2026 03:39", fmt(&buf, "{d:0>2}/{d:0>2}/{d} {s}", "{1d:0>2}/{0d:0>2}/{2d} {3s}", .{ day, month, year, "03:39" }));
    try testing.expectEqualStrings("9 ноября 2026 г.", fmt(&buf, "{d} de {s} de {d}", "{1s} {0d}, {2d}", .{ day, "ноября", year }));
}

test "texto que não cabe no buffer conta como cortado (debug)" {
    const old = current();
    defer set(old);
    set("ru");
    const before = cuts.load(.monotonic);
    var big: [256]u8 = undefined;
    _ = fmt(&big, "Hoje às {s}", "Today at {s}", .{"03:39"});
    try testing.expectEqual(before, cuts.load(.monotonic));
    var small: [8]u8 = undefined;
    _ = fmt(&small, "Hoje às {s}", "Today at {s}", .{"03:39"});
    _ = fmtZ(&small, "Hoje às {s}", "Today at {s}", .{"03:39"});
    if (count_cuts) try testing.expectEqual(before + 2, cuts.load(.monotonic));
}

test "arquivo de tradução: erros" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const A = a.allocator();
    var diag: kdl.Diagnostic = .{};
    try testing.expectError(error.BadEntry, parseFile(A, "\"ok\" \"はい\"\n\"a\" \"b\" \"c\"\n", &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    // Só a chave, sem tradução: ainda falta (como a vazia), não é erro.
    try testing.expectEqual(@as(usize, 1), (try parseFile(A, "\"ok\" \"はい\"\n\"só a chave\"\n", null)).entries.len);
    try testing.expectError(error.BadEntry, parseFile(A, "\"a\" \"b\" extra=\"1\"\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "\"a\" \"b\" one=1\n", null));
    // Vazio é o que ainda falta traduzir (o modelo vem assim): fica de fora, sem erro.
    const empty = try parseFile(A, "\"a\" \"\"\n\"b\" one=\"\" few=\"\"\n\"c\" one=\"x\" few=\"\"\n", null);
    try testing.expectEqual(@as(usize, 1), empty.entries.len);
    try testing.expectEqualStrings("c", empty.entries[0].key);
    try testing.expect(empty.entries[0].forms[@intFromEnum(Plural.few)] == null);
    try testing.expectError(error.BadEntry, parseFile(A, "\"a\" \"b\" \"c\"\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "\"a\" \"b\" { x }\n", null));
    try testing.expectError(error.SyntaxError, parseFile(A, "\"a\" \"sem fim\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "language code=\"ja\"\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "language \"日本語\" code=\"j a\"\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "direction \"up\"\n", null));
    try testing.expectError(error.BadEntry, parseFile(A, "plurals \"klingon\"\n", null));
    const ok = try parseFile(A, "// comentário\n\"Line\\none\" \\\n    \"一行\\n目\"\n", null);
    try testing.expectEqual(@as(usize, 1), ok.entries.len);
    try testing.expectEqualStrings("Line\none", ok.entries[0].key);
    try testing.expectEqualStrings("一行\n目", ok.entries[0].value);
    // O nome entre aspas é sempre entrada, mesmo "language".
    const q = try parseFile(A, "language \"Teste\" code=\"tt\" english=\"Test\"\ndirection \"rtl\"\nfont-script \"ja\"\nplurals \"ru\"\nnovidade \"ignorada\"\n\"language\" \"língua\"\n", null);
    try testing.expectEqualStrings("Teste", q.header.name.?);
    try testing.expectEqualStrings("tt", q.header.code.?);
    try testing.expectEqualStrings("Test", q.header.english.?);
    try testing.expect(q.header.rtl);
    try testing.expectEqualStrings("ja", q.header.font_script.?);
    try testing.expectEqualStrings("ru", q.header.plurals.?);
    try testing.expectEqual(@as(usize, 1), q.entries.len);
    try testing.expectEqualStrings("language", q.entries[0].key);
}

test "arquivo de tradução: formas de plural" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const f = try parseFile(a.allocator(), "\"{d} votes\" one=\"{d} голос\" few=\"{d} голоса\" many=\"{d} голосов\"\n\"{d} files\" \"{d} x\" one=\"{d} y\"\n", null);
    const e = f.entries[0];
    try testing.expectEqualStrings("{d} голос", e.forms[@intFromEnum(Plural.one)].?);
    try testing.expectEqualStrings("{d} голосов", e.forms[@intFromEnum(Plural.many)].?);
    try testing.expect(e.forms[@intFromEnum(Plural.other)] == null);
    // Sem o texto solto: vale a última forma (para quem pede o texto sem contagem).
    try testing.expectEqualStrings("{d} голосов", e.value);
    try testing.expectEqualStrings("{d} x", f.entries[1].value);
    try testing.expect(f.entries[1].hasForms());
}

test "plural: categorias do CLDR para números inteiros" {
    const Case = struct { Rule, u64, Plural };
    const cases = [_]Case{
        .{ .east_slavic, 1, .one },   .{ .east_slavic, 21, .one },    .{ .east_slavic, 101, .one },  .{ .east_slavic, 11, .many },
        .{ .east_slavic, 2, .few },   .{ .east_slavic, 24, .few },    .{ .east_slavic, 12, .many },  .{ .east_slavic, 14, .many },
        .{ .east_slavic, 0, .many },  .{ .east_slavic, 5, .many },    .{ .east_slavic, 111, .many }, .{ .east_slavic, 112, .many },
        .{ .polish, 1, .one },        .{ .polish, 21, .many },        .{ .polish, 22, .few },        .{ .polish, 12, .many },
        .{ .czech, 1, .one },         .{ .czech, 3, .few },           .{ .czech, 5, .other },        .{ .czech, 22, .other },
        .{ .one, 1, .one },           .{ .one, 0, .other },           .{ .one, 21, .other },         .{ .one01, 0, .one },
        .{ .one01, 1, .one },         .{ .one01, 2, .other },         .{ .one_many, 1_000_000, .many }, .{ .one_many, 0, .other },
        .{ .one01_many, 0, .one },    .{ .one01_many, 2_000_000, .many }, .{ .other, 1, .other },    .{ .arabic, 0, .zero },
        .{ .arabic, 2, .two },        .{ .arabic, 103, .few },        .{ .arabic, 111, .many },      .{ .arabic, 100, .other },
        .{ .arabic, 102, .other },    .{ .welsh, 6, .many },          .{ .welsh, 4, .other },        .{ .latvian, 0, .zero },
        .{ .latvian, 11, .zero },     .{ .latvian, 21, .one },        .{ .lithuanian, 11, .other },  .{ .lithuanian, 22, .few },
        .{ .lithuanian, 31, .one },   .{ .romanian, 0, .few },        .{ .romanian, 119, .few },     .{ .romanian, 120, .other },
        .{ .slovenian, 102, .two },   .{ .slovenian, 104, .few },     .{ .south_slavic, 21, .one },  .{ .south_slavic, 13, .other },
        .{ .hebrew, 2, .two },        .{ .hebrew, 3, .other },        .{ .irish, 7, .many },         .{ .one_mod10, 21, .one },
        .{ .one_mod10, 11, .other },  .{ .filipino, 4, .other },      .{ .filipino, 0, .one },       .{ .maltese, 0, .few },
        .{ .maltese, 15, .many },     .{ .maltese, 20, .other },
    };
    for (cases) |cs| {
        if (category(cs[0], cs[1]) != cs[2]) {
            std.debug.print("{t} {d}: {t}, esperava {t}\n", .{ cs[0], cs[1], category(cs[0], cs[1]), cs[2] });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(Rule.east_slavic, ruleFor("ru").?);
    try testing.expectEqual(Rule.one_many, ruleFor("pt-PT").?);
    try testing.expectEqual(Rule.one01_many, ruleFor("pt_BR").?);
    try testing.expectEqual(Rule.one, ruleFor("de-AT").?);
    try testing.expectEqual(@as(?Rule, null), ruleFor("klingon"));
    // Os exemplos que o modelo e o editor do site mostram caem mesmo na forma dita.
    for (rules) |r| {
        var it = std.mem.tokenizeScalar(u8, r.examples, ' ');
        while (it.next()) |part| {
            const eq = std.mem.indexOfScalar(u8, part, '=').?;
            const cat = std.meta.stringToEnum(Plural, part[0..eq]).?;
            var nums = std.mem.tokenizeScalar(u8, part[eq + 1 ..], ',');
            while (nums.next()) |num| {
                const n = try std.fmt.parseInt(u64, num, 10);
                if (category(r.rule, n) != cat) {
                    std.debug.print("{t}: {d} é {t}, o exemplo diz {t}\n", .{ r.rule, n, category(r.rule, n), cat });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    // Cada forma que a tabela lista existe, e a categoria de qualquer número está entre
    // as formas da regra (o modelo pede todas que podem aparecer).
    for (rules) |r| {
        var it = std.mem.tokenizeScalar(u8, r.forms, ' ');
        var listed: [n_forms]bool = @splat(false);
        while (it.next()) |name| listed[@intFromEnum(std.meta.stringToEnum(Plural, name).?)] = true;
        for (0..2000) |n| try testing.expect(listed[@intFromEnum(category(r.rule, n))]);
    }
}

test "plural em português, inglês e nos arquivos" {
    const old = current();
    defer set(old);
    var buf: [64]u8 = undefined;
    set("pt");
    try testing.expectEqualStrings("1 voto", plural(&buf, 1, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{1}));
    try testing.expectEqualStrings("0 votos", plural(&buf, 0, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{0}));
    set("en");
    try testing.expectEqualStrings("1 vote", plural(&buf, 1, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{1}));
    try testing.expectEqualStrings("7 votes", plural(&buf, 7, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{7}));
    set("ru");
    try testing.expectEqualStrings("1 голос", plural(&buf, 1, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{1}));
    try testing.expectEqualStrings("21 голос", plural(&buf, 21, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{21}));
    try testing.expectEqualStrings("Голосов: 3", plural(&buf, 3, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{3}));
    // Sem tradução: o inglês, com o singular e o plural do inglês.
    try testing.expectEqualStrings("1 widget", plural(&buf, 1, "{d} coisa", "{d} coisas", "{d} widget", "{d} widgets", .{1}));
    try testing.expectEqualStrings("2 widgets", plural(&buf, 2, "{d} coisa", "{d} coisas", "{d} widget", "{d} widgets", .{2}));
    set("ja");
    try testing.expectEqualStrings("1票", plural(&buf, 1, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{1}));
    try testing.expectEqualStrings("5票", plural(&buf, 5, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{5}));
    const s = try pluralAlloc(testing.allocator, 3, "{d} aba", "{d} abas", "{d} tab", "{d} tabs", .{3});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("タブ3個", s);
}

// Um idioma que o app não conhece, só um arquivo: aparece na lista, traduz, cai no inglês
// (nunca no português) no que falta, usa as regras de plural que o arquivo pede, e o
// arquivo recarregado troca o texto na hora. Nenhuma linha de código sabe do "xx".
test "idioma novo só com um arquivo (xx), recarregado na hora" {
    const old = current();
    defer set(old);
    defer _ = setUserFiles(&.{});
    try testing.expectEqual(@as(?usize, null), match("xx"));
    try testing.expect(!setUserFiles(&.{.{ .name = "xx.kdl", .text = xx_file }}));
    const i = match("xx").?;
    const info = languages()[i];
    try testing.expectEqualStrings("Xx (teste)", info.name);
    try testing.expectEqualStrings("Test language", info.english);
    try testing.expect(info.rtl);
    try testing.expectEqualStrings("ja", info.font_script);
    try testing.expectEqual(Rule.east_slavic, info.rule);
    try testing.expect(info.problem == null);
    const before = stamp();
    set("xx");
    try testing.expect(stamp() != before);
    try testing.expect(is("xx") and en() and rtl());
    try testing.expectEqualStrings("ja", fontScript());
    try testing.expectEqualStrings("Xxlang", tr("Idioma", "Language"));
    try testing.expectEqualStrings("Sign in to nowhere", tr("Entrar em lugar nenhum", "Sign in to nowhere"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("xx-today 03:39", fmt(&buf, "Hoje às {s}", "Today at {s}", .{"03:39"}));
    // Marcadores errados no arquivo: o inglês.
    try testing.expectEqualStrings("Yesterday at 03:39", fmt(&buf, "Ontem às {s}", "Yesterday at {s}", .{"03:39"}));
    try testing.expectEqualStrings("1 xvote", plural(&buf, 1, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{1}));
    try testing.expectEqualStrings("3 xvotes-few", plural(&buf, 3, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{3}));
    try testing.expectEqualStrings("11 xvotes-many", plural(&buf, 11, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{11}));
    // Espaço reservado (o próprio inglês): o inglês escolhe a forma.
    try testing.expectEqualStrings("1 tab", plural(&buf, 1, "{d} aba", "{d} abas", "{d} tab", "{d} tabs", .{1}));
    // A porcentagem: traduz alguma coisa, longe de tudo.
    const cov = coverage(i).?;
    try testing.expect(cov > 0 and cov < 100);
    try testing.expect(coverage(match("ja").?).? > 900);
    try testing.expectEqual(@as(?u16, null), coverage(0));
    // Salvar o arquivo de novo, igual: nada muda. Mudado: a tabela é refeita e publicada.
    const s1 = stamp();
    try testing.expect(!setUserFiles(&.{.{ .name = "xx.kdl", .text = xx_file }}));
    try testing.expectEqual(s1, stamp());
    const edited = try std.mem.replaceOwned(u8, testing.allocator, xx_file, "\"Xxlang\"", "\"Xxlang 2\"");
    defer testing.allocator.free(edited);
    try testing.expect(setUserFiles(&.{.{ .name = "xx.kdl", .text = edited }}));
    try testing.expect(stamp() != s1);
    try testing.expectEqualStrings("Xxlang 2", tr("Idioma", "Language"));
    // Um arquivo quebrado não derruba nada: a página mostra o problema.
    _ = setUserFiles(&.{ .{ .name = "xx.kdl", .text = edited }, .{ .name = "yy.kdl", .text = "language \"Yy\" code=\"yy\"\n\"a\" \"b\" \"c\"\n" } });
    const yy = languages()[match("yy").?];
    try testing.expect(std.mem.indexOf(u8, yy.problem.?, "yy.kdl:2") != null);
    // No idioma da interface (o xx não traduz este, então o inglês).
    try testing.expectEqualStrings("yy.kdl:2: expected \"English\" \"translation\"", yy.problem.?);
    // O em uso salvo com um erro no meio fica com o texto de antes (e o problema aparece).
    const s2 = stamp();
    const broken = try std.mem.concat(testing.allocator, u8, &.{ edited, "\"sem fim\n" });
    defer testing.allocator.free(broken);
    try testing.expect(!setUserFiles(&.{.{ .name = "xx.kdl", .text = broken }}));
    try testing.expectEqual(s2, stamp());
    try testing.expectEqualStrings("Xxlang 2", tr("Idioma", "Language"));
    try testing.expect(languages()[match("xx").?].problem != null);
    // Consertado: vale de novo, sem o problema.
    try testing.expect(!setUserFiles(&.{.{ .name = "xx.kdl", .text = edited }}));
    try testing.expect(languages()[match("xx").?].problem == null);
    // Sem os arquivos: o yy some, o xx (em uso) fica até trocar.
    _ = setUserFiles(&.{});
    try testing.expectEqual(@as(?usize, null), match("yy"));
    try testing.expect(match("xx") != null);
    set("pt");
    _ = setUserFiles(&.{});
    try testing.expectEqual(@as(?usize, null), match("xx"));
}

test "arquivo da pasta por cima do embutido" {
    const old = current();
    defer set(old);
    defer _ = setUserFiles(&.{});
    set("ja");
    try testing.expectEqualStrings("言語", tr("Idioma", "Language"));
    // Sem cabeçalho (a cópia de um ja.kdl antigo): o nome do arquivo diz o idioma.
    try testing.expect(setUserFiles(&.{.{ .name = "ja.kdl", .text = "\"Language\" \"げんご\"\n" }}));
    try testing.expectEqualStrings("げんご", tr("Idioma", "Language"));
    // O resto continua do embutido.
    try testing.expectEqualStrings("ログイン", tr("Entrar", "Sign in"));
    try testing.expectEqualStrings("日本語", languages()[match("ja").?].name);
    // O arquivo saiu: volta o embutido.
    try testing.expect(setUserFiles(&.{}));
    try testing.expectEqualStrings("言語", tr("Idioma", "Language"));
    // pt e en não vêm de arquivo.
    _ = setUserFiles(&.{.{ .name = "pt.kdl", .text = "language \"P\" code=\"pt\"\n\"Language\" \"x\"\n" }});
    set("pt");
    try testing.expectEqualStrings("Idioma", tr("Idioma", "Language"));
}
