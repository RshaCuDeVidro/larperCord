//! O tempo da call de um canal de voz, ao lado dele na lista de canais
//! ("16:42:14"): o formato escolhido (um dos prontos ou um escrito pela pessoa,
//! com campos entre chaves) e quando o texto muda de novo. Lógica pura; quem
//! desenha é ui/voice_timer.zig.
//!
//! Campos: {d} dias, {h} horas dentro do dia, {H} horas no total, {m} minutos
//! dentro da hora, {M} minutos no total, {s} segundos dentro do minuto e {S}
//! segundos no total. Com a letra dobrada ({hh}, {mm}, {SS}…), pelo menos dois
//! algarismos. {{ e }} viram { e }. O que não é campo aparece como foi escrito.
const std = @import("std");

pub const Field = enum { d, h, H, m, M, s, S };

/// A menor unidade que o formato mostra: o texto só muda na virada dela.
pub const Unit = enum(u8) {
    second,
    minute,
    hour,
    day,
    /// Nenhum campo: o texto nunca muda.
    none,

    pub fn seconds(u: Unit) i64 {
        return switch (u) {
            .second => 1,
            .minute => 60,
            .hour => 3600,
            .day => 86400,
            .none => 0,
        };
    }
};

fn unitOf(f: Field) Unit {
    return switch (f) {
        .s, .S => .second,
        .m, .M => .minute,
        .h, .H => .hour,
        .d => .day,
    };
}

/// Um pedaço do formato: um campo, ou texto (`start`/`len` em `Compiled.lit`).
const Seg = struct { field: ?Field = null, pad: bool = false, start: u16 = 0, len: u16 = 0 };

pub const max_segs = 40;

/// O formato já interpretado: montado quando a escolha muda, não a cada quadro.
pub const Compiled = struct {
    /// O texto fora dos campos, já sem as chaves dobradas.
    lit: [256]u8 = undefined,
    lit_len: u16 = 0,
    segs: [max_segs]Seg = undefined,
    n: u8 = 0,
    unit: Unit = .none,
    /// Quantos {…} não são campos, e o primeiro deles (em `lit`), para avisar.
    unknown: u8 = 0,
    unknown_at: u16 = 0,
    unknown_len: u16 = 0,

    pub fn firstUnknown(cp: *const Compiled) []const u8 {
        return cp.lit[cp.unknown_at..][0..cp.unknown_len];
    }

    fn addLit(cp: *Compiled, bytes: []const u8) void {
        const room = cp.lit.len - cp.lit_len;
        const b = bytes[0..@min(bytes.len, room)];
        if (b.len == 0) return;
        // Junta com o pedaço de texto anterior: "a" "b" vira "ab".
        if (cp.n > 0 and cp.segs[cp.n - 1].field == null and cp.segs[cp.n - 1].start + cp.segs[cp.n - 1].len == cp.lit_len) {
            cp.segs[cp.n - 1].len += @intCast(b.len);
        } else {
            if (cp.n == max_segs) return;
            cp.segs[cp.n] = .{ .start = cp.lit_len, .len = @intCast(b.len) };
            cp.n += 1;
        }
        @memcpy(cp.lit[cp.lit_len..][0..b.len], b);
        cp.lit_len += @intCast(b.len);
    }

    fn addField(cp: *Compiled, f: Field, pad: bool) void {
        cp.segs[cp.n] = .{ .field = f, .pad = pad };
        cp.n += 1;
        const u = unitOf(f);
        if (@intFromEnum(u) < @intFromEnum(cp.unit)) cp.unit = u;
    }
};

/// "h" -> .h, "hh" -> .h com zeros; o resto não é campo.
fn fieldOf(name: []const u8) ?struct { f: Field, pad: bool } {
    if (name.len == 0 or name.len > 2) return null;
    if (name.len == 2 and name[0] != name[1]) return null;
    const f: Field = switch (name[0]) {
        'd' => .d,
        'h' => .h,
        'H' => .H,
        'm' => .m,
        'M' => .M,
        's' => .s,
        'S' => .S,
        else => return null,
    };
    return .{ .f = f, .pad = name.len == 2 };
}

/// Interpreta o formato. Nunca falha: chave sem par, campo desconhecido ou texto
/// longo demais aparecem como texto (ou são cortados no fim).
pub fn compile(pattern_in: []const u8) Compiled {
    var cp: Compiled = .{};
    // Cabe no texto das configurações (255); sem partir um caractere no meio.
    var end = @min(pattern_in.len, cp.lit.len - 1);
    while (end > 0 and end < pattern_in.len and (pattern_in[end] & 0xC0) == 0x80) end -= 1;
    const p = pattern_in[0..end];
    var i: usize = 0;
    while (i < p.len) {
        const ch = p[i];
        if ((ch == '{' or ch == '}') and i + 1 < p.len and p[i + 1] == ch) {
            cp.addLit(p[i .. i + 1]);
            i += 2;
            continue;
        }
        if (ch != '{') {
            // Até a próxima chave, de uma vez.
            var j = i + 1;
            while (j < p.len and p[j] != '{' and p[j] != '}') j += 1;
            cp.addLit(p[i..j]);
            i = j;
            continue;
        }
        // Um "{": campo se fechar antes de outra chave abrir.
        var j = i + 1;
        while (j < p.len and p[j] != '{' and p[j] != '}') j += 1;
        if (j >= p.len or p[j] != '}') {
            cp.addLit("{");
            i += 1;
            continue;
        }
        const name = p[i + 1 .. j];
        // Sem lugar para mais um pedaço depois deste: o resto vai como texto.
        if (fieldOf(name)) |fp| if (cp.n + 1 < max_segs) {
            cp.addField(fp.f, fp.pad);
            i = j + 1;
            continue;
        };
        if (fieldOf(name) == null) {
            if (cp.unknown == 0) {
                cp.unknown_at = cp.lit_len;
                cp.unknown_len = @intCast(@min(j + 1 - i, cp.lit.len - cp.lit_len));
            }
            cp.unknown +|= 1;
        }
        cp.addLit(p[i .. j + 1]);
        i = j + 1;
    }
    return cp;
}

fn value(f: Field, e: u64) u64 {
    return switch (f) {
        .d => e / 86400,
        .h => (e / 3600) % 24,
        .H => e / 3600,
        .m => (e / 60) % 60,
        .M => e / 60,
        .s => e % 60,
        .S => e,
    };
}

/// O texto para `elapsed_s` segundos. Sem espaço em `buf`, corta (nunca no meio
/// de um caractere).
pub fn format(buf: []u8, cp: *const Compiled, elapsed_s: u64) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    for (cp.segs[0..cp.n]) |sg| {
        if (sg.field) |f| {
            const v = value(f, elapsed_s);
            (if (sg.pad) wr.print("{d:0>2}", .{v}) else wr.print("{d}", .{v})) catch break;
        } else wr.writeAll(cp.lit[sg.start..][0..sg.len]) catch break;
    }
    const out = wr.buffered();
    if (out.len < buf.len) return out;
    var k = out.len;
    while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
    if (k > 0 and out[k - 1] >= 0xC0) {
        const want = std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1;
        if (out.len - (k - 1) < want) return out[0 .. k - 1];
    }
    return out;
}

// --- Os prontos ------------------------------------------------------------------

pub const Preset = struct {
    /// Nome na lista: o formato ("h:mm:ss"), igual em todo idioma, ou, com
    /// `name_en`, uma descrição em português e em inglês.
    name: []const u8,
    name_en: []const u8 = "",
    pattern: []const u8,
    /// Abaixo de uma hora, este no lugar (o "mm:ss" que vira "h:mm:ss").
    short: ?[]const u8 = null,
};

pub const presets = [_]Preset{
    .{ .name = "h:mm:ss", .pattern = "{H}:{mm}:{ss}" },
    .{ .name = "mm:ss → h:mm:ss", .pattern = "{H}:{mm}:{ss}", .short = "{mm}:{ss}" },
    .{ .name = "hh:mm:ss", .pattern = "{HH}:{mm}:{ss}" },
    .{ .name = "d:hh:mm:ss", .pattern = "{d}:{hh}:{mm}:{ss}" },
    .{ .name = "h:mm", .pattern = "{H}:{mm}" },
    .{ .name = "Compacto", .name_en = "Compact", .pattern = "{H}h {m}m" },
    .{ .name = "Compacto com segundos", .name_en = "Compact with seconds", .pattern = "{H}h {m}m {s}s" },
    .{ .name = "Só as horas", .name_en = "Hours only", .pattern = "{H}h" },
    .{ .name = "Minutos no total", .name_en = "Total minutes", .pattern = "{M} min" },
    .{ .name = "Segundos no total", .name_en = "Total seconds", .pattern = "{S} s" },
};

/// O índice depois dos prontos: o formato escrito pela pessoa.
pub const custom_index: u8 = presets.len;

/// O formato resolvido das configurações.
pub const Format = struct {
    main: Compiled,
    short: ?Compiled = null,

    /// O que vale para `elapsed_s`: o curto até completar uma hora.
    pub fn pick(f: *const Format, elapsed_s: u64) *const Compiled {
        if (f.short) |*sh| if (elapsed_s < 3600) return sh;
        return &f.main;
    }

    pub fn text(f: *const Format, buf: []u8, elapsed_s: u64) []const u8 {
        return format(buf, f.pick(elapsed_s), elapsed_s);
    }
};

/// `index`: um dos `presets`, ou `custom_index` com o formato da pessoa (vazio
/// = o primeiro pronto). Fora disso (arquivo editado à mão), o primeiro pronto.
pub fn resolve(index: u8, custom: []const u8) Format {
    if (index == custom_index) {
        const pat = if (std.mem.trim(u8, custom, " \t").len == 0) presets[0].pattern else custom;
        return .{ .main = compile(pat) };
    }
    const p = presets[if (index < presets.len) index else 0];
    return .{ .main = compile(p.pattern), .short = if (p.short) |sp| compile(sp) else null };
}

// --- O tempo ---------------------------------------------------------------------

/// O começo de sessão mais tarde que se aceita (s Unix, ano 2286): depois disso
/// é lixo, e as contas em ms estourariam.
pub const max_start_s: i64 = 10_000_000_000;

/// Segundos desde o começo da sessão (`start_s`, Unix). Começo no futuro (o relógio
/// daqui atrasado em relação ao do Discord) conta como agora: 0, nunca negativo.
/// null = sem sessão (ou começo que não faz sentido).
pub fn elapsed(now_ms: i64, start_s: i64) ?u64 {
    if (start_s <= 0 or start_s > max_start_s) return null;
    const now_s = @divFloor(now_ms, 1000);
    return if (now_s <= start_s) 0 else @intCast(now_s - start_s);
}

/// O primeiro minuto cheio do relógio a partir de `ms` (ele mesmo, se já é).
fn ceilMinute(ms: i64) i64 {
    return ms + @mod(-ms, 60_000);
}

/// Quando o texto deste canal muda de novo, visto em `now_ms` (null = nunca):
///  - com segundos, na virada do segundo do relógio: a mesma para todos os canais,
///    que começam em segundos inteiros;
///  - com minutos, horas ou dias, no primeiro minuto cheio do relógio depois da
///    virada deste canal: todos acordam juntos no mesmo minuto (o mesmo em que o
///    tique do minuto do app já redesenha), com no máximo 59 s de atraso.
pub fn nextChange(f: *const Format, now_ms: i64, start_s: i64) ?i64 {
    const e = elapsed(now_ms, start_s) orelse return null;
    const cp = f.pick(e);
    var next: ?i64 = switch (cp.unit) {
        .none => null,
        .second => (@divFloor(now_ms, 1000) + 1) * 1000,
        else => blk: {
            const u = cp.unit.seconds();
            const now_s = @divFloor(now_ms, 1000);
            const k: i64 = if (now_s < start_s) 1 else @divFloor(now_s - start_s, u) + 1;
            break :blk ceilMinute((start_s + k * u) * 1000);
        },
    };
    // O "mm:ss" vira "h:mm:ss" ao completar uma hora.
    if (f.short != null and e < 3600) {
        const sw = (start_s + 3600) * 1000;
        next = if (next) |n| @min(n, sw) else sw;
    }
    return next;
}

// --- Testes -----------------------------------------------------------------------

const t = std.testing;

fn fmtPreset(buf: []u8, i: u8, e: u64) []const u8 {
    const S = struct {
        var f: Format = undefined;
    };
    S.f = resolve(i, "");
    return S.f.text(buf, e);
}

fn fmtPattern(buf: []u8, pattern: []const u8, e: u64) []const u8 {
    const S = struct {
        var cp: Compiled = undefined;
    };
    S.cp = compile(pattern);
    return format(buf, &S.cp, e);
}

test "todos os prontos com 16:42:14" {
    var b: [64]u8 = undefined;
    const e: u64 = 16 * 3600 + 42 * 60 + 14;
    const want = [_][]const u8{ "16:42:14", "16:42:14", "16:42:14", "0:16:42:14", "16:42", "16h 42m", "16h 42m 14s", "16h", "1002 min", "60134 s" };
    try t.expectEqual(want.len, presets.len);
    for (want, 0..) |w, i| try t.expectEqualStrings(w, fmtPreset(&b, @intCast(i), e));
}

test "prontos com zero, menos de uma hora, mais de um dia e mais de 99 h" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("0:00:00", fmtPreset(&b, 0, 0));
    try t.expectEqualStrings("00:00", fmtPreset(&b, 1, 0));
    try t.expectEqualStrings("00:00:00", fmtPreset(&b, 2, 0));
    try t.expectEqualStrings("0:00:00:00", fmtPreset(&b, 3, 0));
    try t.expectEqualStrings("0h", fmtPreset(&b, 7, 0));
    try t.expectEqualStrings("0 s", fmtPreset(&b, 9, 0));
    // mm:ss até uma hora, depois h:mm:ss.
    try t.expectEqualStrings("05:07", fmtPreset(&b, 1, 5 * 60 + 7));
    try t.expectEqualStrings("59:59", fmtPreset(&b, 1, 3599));
    try t.expectEqualStrings("1:00:00", fmtPreset(&b, 1, 3600));
    try t.expectEqualStrings("01:02:03", fmtPreset(&b, 2, 3723));
    // 26 h 3 min 9 s: as horas no total passam de 24; com dias, o resto do dia.
    const day_plus: u64 = 26 * 3600 + 3 * 60 + 9;
    try t.expectEqualStrings("26:03:09", fmtPreset(&b, 0, day_plus));
    try t.expectEqualStrings("1:02:03:09", fmtPreset(&b, 3, day_plus));
    // 123 h 4 min 5 s: três algarismos de hora, sem cortar.
    const big: u64 = 123 * 3600 + 4 * 60 + 5;
    try t.expectEqualStrings("123:04:05", fmtPreset(&b, 0, big));
    try t.expectEqualStrings("123:04:05", fmtPreset(&b, 2, big));
    try t.expectEqualStrings("5:03:04:05", fmtPreset(&b, 3, big));
    try t.expectEqualStrings("123h 4m", fmtPreset(&b, 5, big));
    try t.expectEqualStrings("7384 min", fmtPreset(&b, 8, big));
}

test "formato da pessoa: todos os campos, com e sem zeros" {
    var b: [128]u8 = undefined;
    // 2 dias, 3 h, 4 min e 5 s.
    const e: u64 = 2 * 86400 + 3 * 3600 + 4 * 60 + 5;
    try t.expectEqualStrings("2 3 51 4 3064 5 183845", fmtPattern(&b, "{d} {h} {H} {m} {M} {s} {S}", e));
    try t.expectEqualStrings("02 03 51 04 3064 05 183845", fmtPattern(&b, "{dd} {hh} {HH} {mm} {MM} {ss} {SS}", e));
    // Na ordem que a pessoa quiser: s:m:h e d:h:s.
    try t.expectEqualStrings("05:04:03", fmtPattern(&b, "{ss}:{mm}:{hh}", e));
    try t.expectEqualStrings("2:3:5", fmtPattern(&b, "{d}:{h}:{s}", e));
    try t.expectEqualStrings("call há 51h04", fmtPattern(&b, "call há {H}h{mm}", e));
    // Zeros só completam: número grande passa de dois algarismos.
    try t.expectEqualStrings("183845", fmtPattern(&b, "{SS}", e));
}

test "formato da pessoa: o que não é campo aparece como texto" {
    var b: [128]u8 = undefined;
    const e: u64 = 3723;
    try t.expectEqualStrings("{x} 1 {hm} {hhh} {} {mM}", fmtPattern(&b, "{x} {H} {hm} {hhh} {} {mM}", e));
    var cp = compile("{x} {H} {q}");
    try t.expectEqual(@as(u8, 2), cp.unknown);
    try t.expectEqualStrings("{x}", cp.firstUnknown());
    try t.expectEqual(Unit.hour, cp.unit);
    // Chave sem par, chave dentro de chave e as dobradas.
    try t.expectEqualStrings("{H}:02", fmtPattern(&b, "{{H}:{mm}", e));
    try t.expectEqualStrings("{1}", fmtPattern(&b, "{{{H}}}", e));
    try t.expectEqualStrings("a{b 1", fmtPattern(&b, "a{b {H}", e));
    try t.expectEqualStrings("{ 1 }", fmtPattern(&b, "{ {H} }", e));
    try t.expectEqualStrings("x}y{", fmtPattern(&b, "x}y{", e));
    try t.expectEqualStrings("", fmtPattern(&b, "", e));
    cp = compile("sem campo");
    try t.expectEqual(Unit.none, cp.unit);
    try t.expectEqual(@as(u8, 0), cp.unknown);
    // Acentos e emoji passam inteiros.
    try t.expectEqualStrings("🎙 1h — 02 min", fmtPattern(&b, "🎙 {H}h — {mm} min", e));
}

test "formato enorme ou com campos demais não estoura" {
    var b: [512]u8 = undefined;
    var long: [600]u8 = undefined;
    @memset(&long, 'a');
    try t.expectEqual(@as(usize, 255), fmtPattern(&b, &long, 5).len);
    // Mais campos do que cabem: o resto vira texto, sem perder nada do começo.
    var many: [255]u8 = undefined;
    var n: usize = 0;
    while (n + 3 <= many.len) : (n += 3) @memcpy(many[n..][0..3], "{s}");
    const out = fmtPattern(&b, many[0..n], 7);
    try t.expect(std.mem.startsWith(u8, out, "7777"));
    try t.expect(std.mem.endsWith(u8, out, "{s}"));
    // Buffer pequeno corta sem partir um caractere.
    var small: [5]u8 = undefined;
    try t.expectEqualStrings("ab", fmtPattern(&small, "ab🎙cd", 0));
    try t.expectEqualStrings("1:00:", fmtPattern(&small, "{H}:{mm}:{ss}", 3600));
}

test "unidade de cada formato" {
    try t.expectEqual(Unit.second, compile("{H}:{mm}:{ss}").unit);
    try t.expectEqual(Unit.second, compile("{S} s").unit);
    try t.expectEqual(Unit.minute, compile("{H}:{mm}").unit);
    try t.expectEqual(Unit.minute, compile("{M} min").unit);
    try t.expectEqual(Unit.hour, compile("{H}h").unit);
    try t.expectEqual(Unit.hour, compile("{h}").unit);
    try t.expectEqual(Unit.day, compile("{d} dias").unit);
}

test "sem começo, começo no futuro e começo absurdo" {
    try t.expectEqual(@as(?u64, null), elapsed(1_700_000_000_000, 0));
    try t.expectEqual(@as(?u64, null), elapsed(1_700_000_000_000, -5));
    try t.expectEqual(@as(?u64, null), elapsed(1_700_000_000_000, max_start_s + 1));
    // Relógio daqui atrasado: zero, não negativo.
    try t.expectEqual(@as(?u64, 0), elapsed(1_700_000_000_000, 1_700_000_090));
    try t.expectEqual(@as(?u64, 0), elapsed(1_700_000_000_999, 1_700_000_000));
    try t.expectEqual(@as(?u64, 60134), elapsed(1_700_060_134_500, 1_700_000_000));
}

test "segundos: acorda na virada do segundo, igual para todos" {
    const f = resolve(0, "");
    const now: i64 = 1_700_000_123_456;
    try t.expectEqual(@as(?i64, 1_700_000_124_000), nextChange(&f, now, 1_700_000_000));
    try t.expectEqual(@as(?i64, 1_700_000_124_000), nextChange(&f, now, 1_699_990_017));
    // Começo no futuro: o texto fica em 0 e confere de novo no próximo segundo.
    try t.expectEqual(@as(?i64, 1_700_000_124_000), nextChange(&f, now, 1_700_000_500));
    try t.expectEqual(@as(?i64, null), nextChange(&f, now, 0));
}

test "minutos: acorda no minuto cheio do relógio depois da virada do canal" {
    const f = resolve(4, "");
    // Agora: 12:00:10 de algum dia (múltiplo de 60 s + 10 s).
    const base: i64 = 1_699_999_980; // múltiplo de 60
    const now: i64 = (base + 10) * 1000 + 250;
    // O canal começou num minuto cheio: vira em base+60, que já é minuto cheio.
    try t.expectEqual(@as(?i64, (base + 60) * 1000), nextChange(&f, now, base - 600));
    // Começou no segundo 30: vira em base+30 e aparece no minuto cheio seguinte.
    try t.expectEqual(@as(?i64, (base + 60) * 1000), nextChange(&f, now, base - 570));
    // Já virou neste minuto (segundo 5): a próxima é em base+65, mostrada em base+120.
    try t.expectEqual(@as(?i64, (base + 120) * 1000), nextChange(&f, now, base - 595));
    // Sempre minuto cheio, sempre no futuro, nunca mais que 2 min adiante.
    var st: i64 = base - 7200;
    while (st < base) : (st += 7) {
        const n = nextChange(&f, now, st).?;
        try t.expectEqual(@as(i64, 0), @mod(n, 60_000));
        try t.expect(n > now and n <= now + 120_000);
    }
}

test "horas e dias: uma vez por hora (ou por dia), no minuto cheio seguinte" {
    const base: i64 = 1_699_999_200; // múltiplo de 3600
    const now: i64 = (base + 600) * 1000;
    const hours = resolve(7, "");
    // Começou às :30:15 de uma hora: vira às :30:15 da seguinte, mostrada às :31:00.
    try t.expectEqual(@as(?i64, (base + 1800 + 60) * 1000), nextChange(&hours, now, base - 3600 + 1815));
    const days = resolve(custom_index, "{d}d");
    try t.expectEqual(@as(?i64, (base + 86400 - 3600 + 60) * 1000), nextChange(&days, now, base - 3600 + 15));
    // Sem campo nenhum: nunca muda.
    const fixed = resolve(custom_index, "em call");
    try t.expectEqual(@as(?i64, null), nextChange(&fixed, now, base));
}

test "mm:ss acorda também na hora de virar h:mm:ss" {
    const f = resolve(1, "");
    const st: i64 = 1_700_000_000;
    try t.expectEqual(@as(?i64, (st + 3600) * 1000), nextChange(&f, (st + 3599) * 1000 + 10, st));
    // Um formato da pessoa não tem a troca: {M} muda no minuto cheio depois da virada.
    const mins = resolve(custom_index, "{M}");
    try t.expectEqual(@as(?i64, (st + 3640) * 1000), nextChange(&mins, (st + 3599) * 1000 + 10, st));
}

test "escolha fora da lista e formato vazio usam o primeiro pronto" {
    var b: [64]u8 = undefined;
    var f = resolve(200, "{S}");
    try t.expectEqualStrings("1:00:00", f.text(&b, 3600));
    f = resolve(custom_index, "   ");
    try t.expectEqualStrings("1:00:00", f.text(&b, 3600));
    f = resolve(custom_index, "{S} s");
    try t.expectEqualStrings("3600 s", f.text(&b, 3600));
}
