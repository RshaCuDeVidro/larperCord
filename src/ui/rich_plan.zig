//! Texto com árabe ou hebraico em ui/rich.zig. Uma passada que só mede anota onde cada pedaço
//! (palavra, menção, emoji...) caiu: a quebra de linha é feita com as larguras moldadas. Aqui
//! cada parágrafo passa inteiro pelo algoritmo bidirecional do Unicode, caractere por
//! caractere (`bidi.paragraphLevels`): a direção é a da primeira letra forte, e uma palavra é
//! quebrada onde o nível muda ("problem؟" vira "problem" e "؟"; "1.يمنع", "1" e ".يمنع").
//! Cada linha ganha a ordem visual desses trechos (regra L2: do nível mais alto ao mais baixo,
//! cada sequência é invertida), e o trecho de nível ímpar sai de trás para frente e espelhado
//! (`bidi.visualRun`). Parágrafo da direita para a esquerda termina na borda direita da coluna,
//! como num leitor nativo, com o marcador da lista à direita do texto; a barra da citação
//! continua à esquerda. Só o x muda: seleção e cópia seguem os bytes do texto original. Fica
//! fora do rich.zig (que depende do ImGui) para os testes alcançarem as contas.
const std = @import("std");
const bidi = @import("bidi.zig");

/// A largura de um pedaço de texto (`font` e `size` são os do pedaço, como o rich.zig mediu).
pub const Measure = *const fn (font: ?*const anyopaque, size: f32, s: []const u8) f32;

/// Um pedaço como a passada que mede o encontrou.
pub const Piece = struct {
    x: f32,
    y: f32,
    w: f32,
    /// O texto, se ele pode ser quebrado onde o nível muda. Vazio num pedaço inteiro.
    text: []const u8 = "",
    /// Pedaço inteiro (menção, emoji personalizado, código, link solto): entra no parágrafo
    /// como este caractere (ver `bidi.Class.stand`).
    stand: bidi.Char = 0xFFFC,
    font: ?*const anyopaque = null,
    size: f32 = 0,
    /// Começa um parágrafo (\n antes) / começa uma linha.
    para: bool = false,
    line: bool = false,
    /// Não entra na ordem (marcador de lista, linha de bloco de código).
    fixed: bool = false,
    /// Marcador de lista: num parágrafo RTL vai para a direita do texto.
    marker: bool = false,
    /// Tem espaço antes, no texto (o da quebra de linha também conta).
    space: bool = false,
    /// O recuo da citação (a barra fica à esquerda mesmo num parágrafo RTL).
    quote: f32 = 0,
};

pub const Plan = struct {
    pub const max = 1024;
    pub const max_runs = 2048;
    n: usize = 0,
    /// Passou de `max`: o último parágrafo fica na ordem lógica.
    full: bool = false,
    pc: [max]Piece = undefined,
    /// Os trechos de cada pedaço (um só, se ele não muda de nível): onde começam em `r_*`.
    run_at: [max]u16 = undefined,
    run_n: [max]u16 = undefined,
    /// O nível do espaço antes do pedaço (o que o algoritmo resolveu para ele).
    gap_level: [max]bidi.Level = undefined,
    runs: usize = 0,
    /// Cada trecho: os bytes dentro do texto do pedaço, a largura, o x na tela, o nível e se
    /// sai de trás para frente (nível ímpar).
    r_from: [max_runs]u16 = undefined,
    r_to: [max_runs]u16 = undefined,
    r_w: [max_runs]f32 = undefined,
    r_x: [max_runs]f32 = undefined,
    r_level: [max_runs]bidi.Level = undefined,
    r_rtl: [max_runs]bool = undefined,
    /// A linha do pedaço passou pela ordem visual: onde ela começa e termina na tela, a
    /// direção do parágrafo, se ela foi para a borda direita e se o pedaço é o último dela no
    /// texto (a sonda do mouse usa, ver `select` no rich.zig).
    moved: [max]bool = undefined,
    lo: [max]f32 = undefined,
    hi: [max]f32 = undefined,
    rtl: [max]bool = undefined,
    right: [max]bool = undefined,
    last: [max]bool = undefined,
    /// O vão até o próximo pedaço do texto, na tela (a seleção pinta o espaço ali).
    gap_lo: [max]f32 = undefined,
    gap_hi: [max]f32 = undefined,

    pub const Line = struct { lo: f32, hi: f32, rtl: bool, right: bool, last: bool, gap_lo: f32, gap_hi: f32 };
    pub const Run = struct { from: usize, to: usize, w: f32, x: f32, rtl: bool };

    pub fn reset(p: *Plan) void {
        p.n = 0;
        p.runs = 0;
        p.full = false;
    }

    pub fn add(p: *Plan, pc: Piece) void {
        if (p.n == max) {
            p.full = true;
            return;
        }
        p.pc[p.n] = pc;
        if (p.n == 0) p.pc[0].para = true;
        p.n += 1;
    }

    /// Quantos trechos o pedaço `k` tem (0: não passou pelo plano, fica onde estava).
    pub fn runCount(p: *const Plan, k: usize) usize {
        return if (k < p.n) p.run_n[k] else 0;
    }

    /// O trecho `i` do pedaço `k`, na ordem do texto.
    pub fn run(p: *const Plan, k: usize, i: usize) Run {
        const r = p.run_at[k] + i;
        return .{ .from = p.r_from[r], .to = p.r_to[r], .w = p.r_w[r], .x = p.r_x[r], .rtl = p.r_rtl[r] };
    }

    /// O x do pedaço na tela: o do primeiro trecho dele no texto.
    pub fn xAt(p: *const Plan, k: usize, x: f32) f32 {
        return if (k < p.n and p.run_n[k] > 0) p.r_x[p.run_at[k]] else x;
    }

    pub fn lineOf(p: *const Plan, k: usize) ?Line {
        if (k >= p.n or !p.moved[k]) return null;
        return .{ .lo = p.lo[k], .hi = p.hi[k], .rtl = p.rtl[k], .right = p.right[k], .last = p.last[k], .gap_lo = p.gap_lo[k], .gap_hi = p.gap_hi[k] };
    }

    /// `edge`: a borda direita da coluna, a partir do começo do texto (a largura de quebra,
    /// ou a do balão, que pode ser mais estreita).
    pub fn resolve(p: *Plan, edge: f32, measure: Measure) void {
        p.runs = 0;
        for (0..p.n) |k| {
            p.moved[k] = false;
            p.run_n[k] = 0;
            p.run_at[k] = 0;
        }
        var i: usize = 0;
        while (i < p.n) {
            var j = i + 1;
            while (j < p.n and !p.pc[j].para) j += 1;
            const done = !(j == p.n and p.full) and p.paragraph(i, j, edge, measure);
            if (!done) p.logical(i, j);
            i = j;
        }
    }

    /// Cada pedaço com um trecho só, no x em que estava.
    fn logical(p: *Plan, from: usize, to: usize) void {
        for (from..to) |k| {
            p.moved[k] = false;
            p.run_n[k] = 0;
            _ = p.addRun(k, 0, @intCast(@min(p.pc[k].text.len, std.math.maxInt(u16))), p.pc[k].w, p.pc[k].x, 0);
        }
    }

    /// A ordem visual de um parágrafo, linha por linha. Falso se ele não tem nada RTL ou não
    /// coube: fica na ordem lógica.
    fn paragraph(p: *Plan, from: usize, to: usize, edge: f32, measure: Measure) bool {
        var any_rtl = false;
        for (from..to) |k| {
            const pc = &p.pc[k];
            if (pc.fixed) continue;
            if (if (pc.text.len > 0) bidi.hasRtl(pc.text) else bidi.isRtl(pc.stand)) any_rtl = true;
        }
        if (!any_rtl) return false;
        // Os caracteres do parágrafo na ordem do texto: os pedaços, com um espaço entre os que
        // tinham espaço. `owner` diz de que pedaço é cada um; `boff`, onde ele começa no texto
        // do pedaço (`gap_mark` no espaço).
        var len: usize = 0;
        var first = true;
        for (from..to) |k| {
            const pc = &p.pc[k];
            if (pc.fixed) continue;
            if (pc.text.len > std.math.maxInt(u16)) return false;
            if (!first and pc.space) {
                if (len == bidi.max_line) return false;
                cps[len] = ' ';
                owner[len] = @intCast(k);
                boff[len] = gap_mark;
                len += 1;
            }
            first = false;
            if (pc.text.len == 0) {
                if (len == bidi.max_line) return false;
                cps[len] = pc.stand;
                owner[len] = @intCast(k);
                boff[len] = 0;
                len += 1;
                continue;
            }
            var b: usize = 0;
            while (b < pc.text.len) {
                if (len == bidi.max_line) return false;
                owner[len] = @intCast(k);
                boff[len] = @intCast(b);
                cps[len] = decode(pc.text, &b);
                len += 1;
            }
        }
        if (len == 0) return false;
        const rtl = bidi.paragraphLevels(cps[0..len], levels[0..len]) orelse return false;
        // Os trechos: cada pedaço quebrado onde o nível muda.
        const runs_before = p.runs;
        var c: usize = 0;
        for (from..to) |k| {
            const pc = &p.pc[k];
            p.run_n[k] = 0;
            if (pc.fixed) {
                if (!p.addRun(k, 0, @intCast(pc.text.len), pc.w, pc.x, 0)) return p.undo(runs_before, from, to);
                continue;
            }
            p.gap_level[k] = 0;
            if (c < len and owner[c] == k and boff[c] == gap_mark) {
                p.gap_level[k] = levels[c];
                c += 1;
            }
            if (pc.text.len == 0) {
                if (!p.addRun(k, 0, 0, pc.w, pc.x, levels[c])) return p.undo(runs_before, from, to);
                c += 1;
                continue;
            }
            const first_run = p.runs;
            var sum: f32 = 0;
            while (c < len and owner[c] == k) {
                const lv = levels[c];
                const b0 = boff[c];
                while (c < len and owner[c] == k and levels[c] == lv) c += 1;
                const b1: u16 = if (c < len and owner[c] == k) boff[c] else @intCast(pc.text.len);
                const w = if (b0 == 0 and b1 == pc.text.len) pc.w else measure(pc.font, pc.size, pc.text[b0..b1]);
                if (!p.addRun(k, b0, b1, w, pc.x, lv)) return p.undo(runs_before, from, to);
                sum += w;
            }
            // As larguras medidas aos pedaços somam a da palavra inteira (a quebra de linha foi
            // feita com ela): a diferença, se houver, fica no último.
            if (p.runs > first_run + 1) p.r_w[p.runs - 1] += pc.w - sum;
        }
        var a = from;
        while (a < to) {
            var b = a + 1;
            while (b < to and !p.lineStarts(b)) b += 1;
            p.placeLine(a, b, rtl, edge);
            a = b;
        }
        return true;
    }

    fn undo(p: *Plan, runs_before: usize, from: usize, to: usize) bool {
        p.runs = runs_before;
        for (from..to) |k| p.run_n[k] = 0;
        return false;
    }

    fn addRun(p: *Plan, k: usize, b0: u16, b1: u16, w: f32, x: f32, lv: bidi.Level) bool {
        if (p.runs == max_runs) return false;
        if (p.run_n[k] == 0) p.run_at[k] = @intCast(p.runs);
        p.r_from[p.runs] = b0;
        p.r_to[p.runs] = b1;
        p.r_w[p.runs] = w;
        p.r_x[p.runs] = x;
        p.r_level[p.runs] = lv;
        p.r_rtl[p.runs] = lv & 1 == 1;
        p.runs += 1;
        p.run_n[k] += 1;
        return true;
    }

    /// O pedaço `k` abre uma linha (a quebra já foi feita): marcado assim, ou numa altura
    /// diferente da do anterior.
    fn lineStarts(p: *const Plan, k: usize) bool {
        return p.pc[k].line or p.pc[k].y != p.pc[k - 1].y;
    }

    /// Um item da linha: um trecho, ou o espaço antes de um pedaço (`gap_of`).
    const Item = struct { run: u16 = 0, gap_of: u16 = no_gap, w: f32, level: bidi.Level };
    const no_gap = std.math.maxInt(u16);

    /// A linha `a..b` na ordem visual: os trechos e os espaços entre os pedaços, cada um no
    /// nível dele, invertidos do nível mais alto ao menor ímpar (L2). Parágrafo RTL: a linha
    /// termina na borda direita, menos o recuo da lista, que vai para a direita com o marcador
    /// (o espelho de onde ela começaria num parágrafo da esquerda para a direita).
    fn placeLine(p: *Plan, a: usize, b: usize, rtl: bool, edge: f32) void {
        var items: [max_runs]Item = undefined;
        var n: usize = 0;
        var first: ?usize = null;
        var prev: ?usize = null;
        for (a..b) |k| {
            const pc = &p.pc[k];
            if (pc.fixed) continue;
            if (first == null) first = k;
            if (prev) |q| if (pc.space) {
                items[n] = .{ .gap_of = @intCast(k), .w = @max(0, pc.x - (p.pc[q].x + p.pc[q].w)), .level = p.gap_level[k] };
                n += 1;
            };
            prev = k;
            for (0..p.run_n[k]) |r| {
                const ri = p.run_at[k] + r;
                items[n] = .{ .run = @intCast(ri), .w = p.r_w[ri], .level = p.r_level[ri] };
                n += 1;
            }
        }
        const fk = first orelse return p.placeMarkers(a, b, rtl, edge, 0);
        var hi_lv: bidi.Level = 0;
        var lo_odd: bidi.Level = std.math.maxInt(bidi.Level);
        for (items[0..n]) |it| {
            hi_lv = @max(hi_lv, it.level);
            if (it.level & 1 == 1) lo_odd = @min(lo_odd, it.level);
        }
        var lv = hi_lv;
        while (lv > 0 and lv >= lo_odd) : (lv -= 1) {
            var s: usize = 0;
            while (s < n) {
                if (items[s].level < lv) {
                    s += 1;
                    continue;
                }
                var e = s;
                while (e < n and items[e].level >= lv) e += 1;
                std.mem.reverse(Item, items[s..e]);
                s = e;
            }
        }
        var lw: f32 = 0;
        for (items[0..n]) |it| lw += it.w;
        const start = p.pc[fk].x;
        const quote = p.pc[fk].quote;
        const lo = if (rtl) @max(quote, quote + edge - start - lw) else start;
        for (a..b) |k| {
            p.gap_lo[k] = 0;
            p.gap_hi[k] = 0;
        }
        var cx = lo;
        for (items[0..n]) |it| {
            if (it.gap_of == no_gap) {
                p.r_x[it.run] = cx;
            } else {
                // O vão antes do pedaço `gap_of` é o "depois" do pedaço anterior a ele.
                var pk: usize = it.gap_of - 1;
                while (p.pc[pk].fixed) pk -= 1;
                p.gap_lo[pk] = cx;
                p.gap_hi[pk] = cx + it.w;
            }
            cx += it.w;
        }
        var last_k = fk;
        for (a..b) |k| {
            if (p.pc[k].fixed) continue;
            p.moved[k] = true;
            p.lo[k] = lo;
            p.hi[k] = cx;
            p.rtl[k] = rtl;
            p.right[k] = rtl;
            p.last[k] = false;
            last_k = k;
        }
        p.last[last_k] = true;
        p.placeMarkers(a, b, rtl, edge, quote);
    }

    /// O marcador da lista num parágrafo RTL vai para o lado direito do texto: o mesmo lugar,
    /// espelhado dentro da coluna (o recuo da citação fica fora da conta).
    fn placeMarkers(p: *Plan, a: usize, b: usize, rtl: bool, edge: f32, quote: f32) void {
        if (!rtl) return;
        for (a..b) |k| {
            const pc = &p.pc[k];
            if (!pc.marker or p.run_n[k] == 0) continue;
            const r = p.run_at[k];
            p.r_x[r] = quote + edge - pc.x - pc.w;
            p.r_rtl[r] = true;
        }
    }
};

/// Os buffers do parágrafo em análise (só da thread da interface; nenhuma página usada até
/// aparecer texto RTL).
var cps: [bidi.max_line]bidi.Char = undefined;
var levels: [bidi.max_line]bidi.Level = undefined;
var owner: [bidi.max_line]u16 = undefined;
var boff: [bidi.max_line]u16 = undefined;
const gap_mark = std.math.maxInt(u16);

fn decode(s: []const u8, i: *usize) bidi.Char {
    const b = s[i.*];
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

// --- Testes -----------------------------------------------------------------------------

/// 10 de largura por caractere (a palavra inteira e os pedaços dela somam igual).
fn fakeWidth(_: ?*const anyopaque, _: f32, s: []const u8) f32 {
    return @floatFromInt(10 * (std.unicode.utf8CountCodepoints(s) catch s.len));
}

/// Um plano como o rich.zig faria: palavras separadas por espaço (5 de largura), quebrando a
/// linha em `wrap`, um parágrafo por \n. `indent` recua todas as linhas (lista), `quote` diz
/// quanto desse recuo é da citação, e com `marker` cada parágrafo começa com um marcador de
/// lista de 6 de largura, fixo, no recuo.
fn planText(p: *Plan, text: []const u8, wrap: f32, opt: struct { indent: f32 = 0, quote: f32 = 0, marker: bool = false }) void {
    p.reset();
    var y: f32 = 0;
    var paras = std.mem.splitScalar(u8, text, '\n');
    var first_para = true;
    while (paras.next()) |para| {
        if (!first_para) y += 20;
        var x: f32 = opt.indent;
        if (opt.marker) {
            p.add(.{ .x = x, .y = y, .w = 6, .text = "•", .para = true, .line = true, .fixed = true, .marker = true, .quote = opt.quote });
            x += 6;
        }
        var words = std.mem.tokenizeScalar(u8, para, ' ');
        var first_word = true;
        while (words.next()) |w| {
            const ww = fakeWidth(null, 0, w);
            var line = first_word;
            if (!first_word and x + ww > wrap) {
                x = opt.indent;
                y += 20;
                line = true;
            }
            p.add(.{ .x = x, .y = y, .w = ww, .text = w, .para = first_word and !opt.marker, .line = line and !(first_word and opt.marker), .space = !first_word, .quote = opt.quote });
            x += ww + 5;
            first_word = false;
        }
        first_para = false;
    }
}

/// A linha `y` como vai para a tela: os trechos em ordem de x, cada um já invertido e
/// espelhado se for de nível ímpar, com um espaço onde há vão entre eles.
fn screenLine(p: *const Plan, y: f32, buf: []u8) []const u8 {
    const R = struct { x: f32, w: f32, s: []const u8, rtl: bool };
    var list: [64]R = undefined;
    var n: usize = 0;
    for (0..p.n) |k| {
        if (p.pc[k].y != y or p.pc[k].fixed) continue;
        for (0..p.runCount(k)) |i| {
            const r = p.run(k, i);
            list[n] = .{ .x = r.x, .w = r.w, .s = p.pc[k].text[r.from..r.to], .rtl = r.rtl };
            n += 1;
        }
    }
    std.mem.sort(R, list[0..n], {}, struct {
        fn f(_: void, a: R, b: R) bool {
            return a.x < b.x;
        }
    }.f);
    var len: usize = 0;
    for (list[0..n], 0..) |r, i| {
        if (i > 0 and r.x > list[i - 1].x + list[i - 1].w + 0.5) {
            buf[len] = ' ';
            len += 1;
        }
        const v = bidi.visualRun(r.s, r.rtl) orelse r.s;
        @memcpy(buf[len..][0..v.len], v);
        len += v.len;
    }
    return buf[0..len];
}

fn expectNear(want: f32, got: f32) !void {
    try std.testing.expectApproxEqAbs(want, got, 0.01);
}

var test_plan: Plan = .{};

test "a linha montada trecho por trecho é a mesma da linha inteira no FriBidi" {
    const cases = [_][]const u8{
        "مساء الخير what is the problem؟",
        "12- السلام عليكم",
        "1.يمنع تجاهل الإدارة.",
        "السلام عليكم (تجربة)",
        "نرجو أن نعود في غضون 12~24 ساعة إن شاء الله.",
        "الحلم المتجدد للتعريب ✨ (@EternalDreamAR)",
        "يرجى ضغط الزر الأخضر ( ✔️ ) إن قرأت",
        "• 11- لا تكرر نفس الرسائل",
        "abc שלום עולם def",
        "שלום לכולם! השיר הזה מושלם, 10 מתוך 10",
        "ouvindo agora: فيروز - كيفك إنت",
        "سعر 3.5 دولار (تقريبا)!",
        "abc (שלום) def",
    };
    const p = &test_plan;
    for (cases) |t| {
        planText(p, t, 100000, .{});
        p.resolve(100000, fakeWidth);
        var a: [512]u8 = undefined;
        const got = screenLine(p, 0, &a);
        const want = bidi.visual(t).?;
        std.testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("caso: {s}\n", .{t});
            return e;
        };
    }
}

test "o ؟ grudado no inglês vai para o fim da frase árabe, na esquerda" {
    const p = &test_plan;
    planText(p, "مساء الخير what is the problem؟", 1000, .{});
    p.resolve(1000, fakeWidth);
    // "problem؟" (pedaço 5) virou dois trechos; o "؟" é o primeiro da linha na tela.
    try std.testing.expectEqual(@as(usize, 2), p.runCount(5));
    const q = p.run(5, 1);
    for (0..p.n) |k| for (0..p.runCount(k)) |i| {
        const r = p.run(k, i);
        try std.testing.expect(r.x >= q.x);
    };
    try std.testing.expect(q.rtl and !p.run(5, 0).rtl);
    // A linha termina na borda direita.
    try expectNear(1000, p.lineOf(0).?.hi);
}

test "número com traço ou ponto antes do árabe: parágrafo RTL, o traço à esquerda do número" {
    const p = &test_plan;
    for ([_][]const u8{ "12- السلام عليكم", "1.يمنع تجاهل الإدارة." }) |t| {
        planText(p, t, 1000, .{});
        p.resolve(1000, fakeWidth);
        const l = p.lineOf(0).?;
        try std.testing.expect(l.rtl and l.right);
        try expectNear(1000, l.hi);
        // O número é o trecho mais à direita; o traço (ou o ponto), logo à esquerda dele.
        const num = p.run(0, 0);
        const mark = p.run(0, 1);
        try expectNear(1000, num.x + num.w);
        try std.testing.expect(mark.x + mark.w <= num.x + 0.01);
    }
}

test "parágrafo árabe termina na borda direita" {
    const p = &test_plan;
    planText(p, "السلام عليكم ورحمة الله", 400, .{});
    p.resolve(400, fakeWidth);
    // 6 + 5 + 5 + 4 letras = 200 de texto e 15 de espaços: de 185 a 400.
    try expectNear(340, p.xAt(0, 0));
    try expectNear(400, p.xAt(0, 0) + p.pc[0].w);
    try expectNear(185, p.xAt(3, 0));
    for (0..4) |k| {
        const l = p.lineOf(k).?;
        try std.testing.expect(l.rtl and l.right);
        try expectNear(185, l.lo);
        try expectNear(400, l.hi);
        try std.testing.expectEqual(k == 3, l.last);
    }
    // O espaço entre a primeira e a segunda palavra (na tela, à esquerda da primeira).
    const g = p.lineOf(0).?;
    try expectNear(335, g.gap_lo);
    try expectNear(340, g.gap_hi);
}

test "hebraico em duas linhas: cada uma termina na borda" {
    const p = &test_plan;
    planText(p, "שלום שלום שלום שלום שלום", 150, .{});
    p.resolve(150, fakeWidth);
    // 40 por palavra: três na primeira linha (130), duas na segunda (85).
    try expectNear(110, p.xAt(0, 0));
    try expectNear(20, p.xAt(2, 0));
    try expectNear(110, p.xAt(3, 0));
    try expectNear(65, p.xAt(4, 0));
    try expectNear(20, p.lineOf(0).?.lo);
    try expectNear(65, p.lineOf(4).?.lo);
    try expectNear(150, p.lineOf(4).?.hi);
}

test "texto latino fica onde estava" {
    const p = &test_plan;
    planText(p, "bom dia 123 pessoal", 400, .{});
    p.resolve(400, fakeWidth);
    for (0..p.n) |k| {
        try expectNear(p.pc[k].x, p.xAt(k, -1));
        try std.testing.expect(p.lineOf(k) == null);
        try std.testing.expectEqual(@as(usize, 1), p.runCount(k));
    }
}

test "parágrafo da esquerda para a direita com hebraico no meio não vai para a direita" {
    const p = &test_plan;
    planText(p, "abc שלום עולם def", 400, .{});
    p.resolve(400, fakeWidth);
    // abc (30) e def (30) no lugar; as duas palavras hebraicas (40 cada) trocam.
    try expectNear(0, p.xAt(0, -1));
    try expectNear(80, p.xAt(1, -1));
    try expectNear(35, p.xAt(2, -1));
    try expectNear(125, p.xAt(3, -1));
    const l = p.lineOf(0).?;
    try std.testing.expect(!l.rtl and !l.right);
    try expectNear(0, l.lo);
    try expectNear(155, l.hi);
}

test "mensagem mista: cada parágrafo com o seu alinhamento" {
    const p = &test_plan;
    planText(p, "lyrics and translation:\nكلمات الأغنية على https://x.y/z مع الترجمة", 600, .{});
    p.resolve(600, fakeWidth);
    for (0..3) |k| {
        try expectNear(p.pc[k].x, p.xAt(k, -1));
        try std.testing.expect(p.lineOf(k) == null);
    }
    // Segundo parágrafo: o link (pedaço 6) fica entre "على" (5) e "مع" (7), da direita para
    // a esquerda, e a linha termina em 600.
    try std.testing.expect(p.xAt(5, 0) > p.xAt(6, 0) and p.xAt(6, 0) > p.xAt(7, 0));
    try expectNear(600, p.xAt(3, 0) + p.pc[3].w);
    const l = p.lineOf(6).?;
    try std.testing.expect(l.rtl and l.right);
    try expectNear(600, l.hi);
}

test "citação em árabe: termina na borda direita e não passa da barra" {
    const p = &test_plan;
    planText(p, "يمنع النقاش في الدين", 300, .{ .indent = 14, .quote = 14 });
    p.resolve(300, fakeWidth);
    const l = p.lineOf(0).?;
    try std.testing.expect(l.rtl and l.right);
    try expectNear(300, l.hi);
    try expectNear(300, p.xAt(0, 0) + p.pc[0].w);
    // Mais larga que a coluna: começa na barra, não antes.
    planText(p, "يمنع النقاش في الدين السياسة المذاهب", 100000, .{ .indent = 14, .quote = 14 });
    p.resolve(100, fakeWidth);
    try expectNear(14, p.lineOf(0).?.lo);
}

test "item de lista em árabe: o marcador à direita do texto, o recuo do lado dele" {
    const p = &test_plan;
    // Recuo 20 (só da lista) e o marcador de 6: o texto começaria em 26.
    planText(p, "مرحبا", 300, .{ .indent = 20, .marker = true });
    p.resolve(300, fakeWidth);
    const l = p.lineOf(1).?;
    try std.testing.expect(l.rtl and l.right);
    // Espelho: o texto termina em 300 - 26 e o marcador fica de 274 a 280.
    try expectNear(274, l.hi);
    try expectNear(274, p.xAt(0, 0));
    try std.testing.expect(p.run(0, 0).rtl);
    // Em português, tudo onde estava.
    planText(p, "olá", 300, .{ .indent = 20, .marker = true });
    p.resolve(300, fakeWidth);
    try expectNear(20, p.xAt(0, -1));
    try expectNear(26, p.xAt(1, -1));
}

test "linha mais larga que a coluna não passa da borda esquerda" {
    const p = &test_plan;
    planText(p, "السلام عليكم ورحمة", 100000, .{});
    p.resolve(100, fakeWidth);
    try expectNear(0, p.lineOf(0).?.lo);
    try expectNear(0, p.xAt(2, 0));
}

test "bloco de código não sai do lugar no meio do árabe" {
    const p = &test_plan;
    p.reset();
    p.add(.{ .x = 0, .y = 0, .w = 50, .text = "السلام", .para = true, .line = true });
    p.add(.{ .x = 55, .y = 0, .w = 50, .text = "عليكم", .space = true });
    // A linha do bloco: largura toda, fixa.
    p.add(.{ .x = 0, .y = 20, .w = 400, .text = "const x = 1;", .para = true, .line = true, .fixed = true });
    p.add(.{ .x = 0, .y = 40, .w = 50, .text = "مرحبا", .para = true, .line = true });
    p.resolve(400, fakeWidth);
    try expectNear(0, p.xAt(2, -1));
    try std.testing.expect(p.lineOf(2) == null);
    try expectNear(350, p.xAt(0, 0));
    try expectNear(295, p.xAt(1, 0));
    try expectNear(350, p.xAt(3, 0));
}

test "menção e emoji inteiros entram no parágrafo como um caractere da classe deles" {
    const p = &test_plan;
    p.reset();
    p.add(.{ .x = 0, .y = 0, .w = 40, .text = "شكرا", .para = true, .line = true });
    p.add(.{ .x = 45, .y = 0, .w = 30, .stand = 'a', .space = true });
    p.add(.{ .x = 80, .y = 0, .w = 20, .stand = 0xFFFC, .space = true });
    p.resolve(300, fakeWidth);
    // RTL: a palavra na direita, a menção no meio, o emoji na esquerda.
    try expectNear(260, p.xAt(0, 0));
    try std.testing.expect(p.xAt(1, 0) < 260 and p.xAt(2, 0) < p.xAt(1, 0));
    try std.testing.expectEqual(@as(usize, 1), p.runCount(1));
}
