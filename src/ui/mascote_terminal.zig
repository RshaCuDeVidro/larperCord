//! O mascote "Terminal" (o da piscadinha com ">_" no rosto), desenhado com o
//! ImDrawList nas medidas de assets/mascote-terminal.svg (viewBox -10 -34 147.14 134)
//! para animar cada parte. A abertura é um terminal ligando: o cursor pisca, uma
//! linha de tubo acende e abre o corpo, as orelhas saltam com mola, o rosto é
//! digitado e a gota de suor escorre. Parado ele respira, mexe as orelhas e segue
//! o mouse; conectando, o "_" vira "..."; no erro, glitch e olhos de "x"; ao entrar
//! no app, desliga como uma TV de tubo.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const logo = @import("logo.zig");

const Rgba = d.Rgba;

/// Cores (as mesmas do SVG).
pub const head_top = Rgba.hex(0x9D40FF);
pub const head_bottom = Rgba.hex(0x7A1FE6);
const ink = Rgba.hex(0x12061F);
const tuft_col = Rgba.hex(0xF7A8FF);
const drop_col = Rgba.hex(0xD8B4FE);
const cyan = Rgba.hex(0x29E6FF);
const magenta = Rgba.hex(0xFF2BD6);
const cream = Rgba.hex(0xF8F0FF);
const glow_col = Rgba.hex(0x8B2CF5);

/// O meio do desenho no SVG (das pontas das orelhas ao pé) e a largura do corpo.
const mid_x: f32 = 63.57;
const mid_y: f32 = 42.5;
const body_w: f32 = 127.14;

/// O que a tela de login sabe; o resto sai do relógio.
pub const Input = struct {
    /// Segundos desde que a tela apareceu (a abertura vai até ~2,6 s).
    t: f32,
    /// Para onde o rosto vira (-1..1).
    look: [2]f32 = .{ 0, 0 },
    connecting: bool = false,
    /// Segundos desde o último erro (grande: nenhum).
    err_age: f32 = 100,
    /// Saída para o app (0..1): desliga como uma TV de tubo.
    leave: f32 = 0,
    alpha: f32 = 1,
    light: bool = false,
    /// "Reduzir animações": o desenho parado, sem glitch nem partículas.
    reduce: bool = false,
};

// --- Contas (ui/mascote_contas.zig) ---------------------------------------------

const contas = @import("mascote_contas.zig");
const seg = contas.seg;
const outCubic = contas.outCubic;
const inCubic = contas.inCubic;
const outExpo = contas.outExpo;
const outBack = contas.outBack;
const spring = contas.spring;
const kick = contas.kick;
const hash = contas.hash;
const Af = contas.Affine(c.ImVec2);

// --- Caminhos do SVG -------------------------------------------------------------

/// O corpo, em curvas cúbicas (os arcos do SVG convertidos).
const body_start = [2]f32{ 107.70, 8.07 };
const body_curves = [_][6]f32{
    .{ 99.35, 4.25, 90.53, 1.53, 81.47, 0.00 },
    .{ 80.23, 2.22, 79.11, 4.50, 78.11, 6.83 },
    .{ 68.46, 5.38, 58.65, 5.38, 49.00, 6.83 },
    .{ 48.00, 4.50, 46.88, 2.22, 45.64, 0.00 },
    .{ 36.58, 1.55, 27.75, 4.27, 19.39, 8.09 },
    .{ 2.79, 32.65, -1.71, 56.60, 0.54, 80.21 },
    .{ 10.26, 87.39, 21.14, 92.86, 32.71, 96.36 },
    .{ 35.31, 92.86, 37.62, 89.14, 39.60, 85.25 },
    .{ 35.84, 83.85, 32.21, 82.11, 28.75, 80.07 },
    .{ 29.66, 79.41, 30.55, 78.73, 31.41, 78.07 },
    .{ 51.78, 87.65, 75.36, 87.65, 95.73, 78.07 },
    .{ 96.60, 78.78, 97.49, 79.46, 98.39, 80.07 },
    .{ 94.93, 82.12, 91.29, 83.85, 87.52, 85.26 },
    .{ 89.50, 89.15, 91.80, 92.86, 94.41, 96.36 },
    .{ 105.99, 92.87, 116.88, 87.41, 126.60, 80.22 },
    .{ 129.24, 52.84, 122.09, 29.11, 107.70, 8.07 },
};

/// A orelha esquerda; a direita é o espelho. Gira em volta da base.
const ear_pivot = [2]f32{ 35, 19 };
const tuft = [_][2]f32{ .{ 24, 15 }, .{ 26.6, 8 }, .{ 28.2, 13 }, .{ 31, 5 }, .{ 32.8, 11 }, .{ 35.8, 4 }, .{ 37.6, 9 }, .{ 40.6, 3.5 }, .{ 41.6, 7.5 } };

fn earPath(dl: *c.ImDrawList, m: Af) void {
    c.ImDrawList_PathLineTo(dl, m.ap(11, 26));
    c.ImDrawList_PathBezierCubicCurveTo(dl, m.ap(13, 12), m.ap(16, -3), m.ap(20, -14), 16);
    c.ImDrawList_PathBezierQuadraticCurveTo(dl, m.ap(21, -16.5), m.ap(23.5, -15.5), 6);
    c.ImDrawList_PathBezierCubicCurveTo(dl, m.ap(35, -9), m.ap(47, 0), m.ap(59, 9), 16);
    c.ImDrawList_PathLineTo(dl, m.ap(34, 24));
}

/// Pontos por curva: fixo, para o contorno caber no buffer em qualquer tamanho.
const curve_steps: c_int = 14;

fn bodyPath(dl: *c.ImDrawList, m: Af) void {
    c.ImDrawList_PathLineTo(dl, m.ap(body_start[0], body_start[1]));
    for (body_curves) |q| c.ImDrawList_PathBezierCubicCurveTo(dl, m.ap(q[0], q[1]), m.ap(q[2], q[3]), m.ap(q[4], q[5]), curve_steps);
}

/// Copia o caminho que está sendo montado e o limpa, sem pontos repetidos (o
/// preenchimento côncavo do ImGui se perde com eles e cobre o vão entre os pés).
fn takePath(dl: *c.ImDrawList, out: []c.ImVec2) usize {
    const path = &dl.*._Path;
    const total: usize = @intCast(path.*.Size);
    var n: usize = 0;
    for (path.*.Data[0..total]) |q| {
        if (n > 0 and @abs(q.x - out[n - 1].x) < 0.05 and @abs(q.y - out[n - 1].y) < 0.05) continue;
        if (n == out.len) break;
        out[n] = q;
        n += 1;
    }
    while (n > 2 and @abs(out[n - 1].x - out[0].x) < 0.05 and @abs(out[n - 1].y - out[0].y) < 0.05) n -= 1;
    c.ImDrawList_PathClear(dl);
    // O triangulador do ImGui só acerta no sentido horário da tela; no outro ele
    // preenche os vãos (o do queixo, o da orelha espelhada).
    var area: f32 = 0;
    for (0..n) |i| {
        const a = out[i];
        const b = out[(i + 1) % n];
        area += a.x * b.y - b.x * a.y;
    }
    if (area < 0) std.mem.reverse(c.ImVec2, out[0..n]);
    return n;
}

/// Preenche o caminho que está sendo montado (côncavo, em qualquer sentido).
fn fillPath(dl: *c.ImDrawList, col: u32) void {
    var poly: [96]c.ImVec2 = undefined;
    const n = takePath(dl, &poly);
    if (n >= 3) c.ImDrawList_AddConcavePolyFilled(dl, &poly, @intCast(n), col);
}

/// Pinta os vértices criados desde `start` com o degradê de `ca` (em `a`) a
/// `cb` (em `b`), mantendo o alpha de cada vértice (a borda suavizada).
fn paint(dl: *c.ImDrawList, start: c_int, a: c.ImVec2, b: c.ImVec2, ca: Rgba, cb: Rgba, alpha: f32) void {
    const vb = &dl.*.VtxBuffer;
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = @max(dx * dx + dy * dy, 1);
    var i: usize = @intCast(start);
    while (i < @as(usize, @intCast(vb.*.Size))) : (i += 1) {
        const vtx = &vb.*.Data[i];
        const t = std.math.clamp(((vtx.pos.x - a.x) * dx + (vtx.pos.y - a.y) * dy) / len2, 0, 1);
        const va: f32 = @floatFromInt(vtx.col >> 24);
        vtx.col = ca.mix(cb, t).col(va / 255.0 * alpha);
    }
}

/// Linha grossa de ponta redonda (o ImGui não arredonda as pontas).
fn stroke(dl: *c.ImDrawList, pts: []const c.ImVec2, w: f32, col: Rgba) void {
    if (pts.len < 2 or col.a <= 0.002) return;
    c.ImDrawList_AddPolyline(dl, pts.ptr, @intCast(pts.len), col.u(), w, 0);
    const r = w / 2;
    if (r >= 0.8) {
        c.ImDrawList_AddCircleFilled(dl, pts[0], r, col.u(), 0);
        c.ImDrawList_AddCircleFilled(dl, pts[pts.len - 1], r, col.u(), 0);
        for (pts[1 .. pts.len - 1]) |p| c.ImDrawList_AddCircleFilled(dl, p, r, col.u(), 0);
    }
}

/// Polilinha do SVG até a fração `k` do comprimento (desenhar "aos poucos").
fn partial(m: Af, src: []const [2]f32, k: f32, out: []c.ImVec2) usize {
    if (k <= 0 or src.len < 2) return 0;
    var total: f32 = 0;
    for (src[1..], 0..) |p, i| total += std.math.hypot(p[0] - src[i][0], p[1] - src[i][1]);
    var left = total * @min(k, 1);
    out[0] = m.ap(src[0][0], src[0][1]);
    var n: usize = 1;
    for (src[1..], 0..) |p, i| {
        const q = src[i];
        const l = std.math.hypot(p[0] - q[0], p[1] - q[1]);
        if (l >= left) {
            const f = if (l > 0) left / l else 0;
            out[n] = m.ap(q[0] + (p[0] - q[0]) * f, q[1] + (p[1] - q[1]) * f);
            return n + 1;
        }
        out[n] = m.ap(p[0], p[1]);
        n += 1;
        left -= l;
    }
    return n;
}

// --- O desenho -------------------------------------------------------------------

/// Tudo o que muda de um quadro para outro, já calculado.
const Pose = struct {
    /// Abertura do corpo (escala em volta do meio) e respiração (em volta do pé).
    open_x: f32 = 1,
    open_y: f32 = 1,
    breath: f32 = 0,
    /// Mistura com o creme (o flash da abertura e do desligar).
    flash: f32 = 0,
    ear_l: f32 = 1,
    ear_r: f32 = 1,
    turn_l: f32 = 0,
    turn_r: f32 = 0,
    tufts: f32 = 1,
    /// O ">" (0..1, dois traços) e o quanto ele está apertado (piscada).
    prompt: f32 = 1,
    squint: f32 = 0,
    /// O "_": desenhado até `under`, aceso ou não (cursor piscando).
    under: f32 = 1,
    under_on: bool = true,
    dots: bool = false,
    /// Relógio dos pulinhos do "...".
    dots_t: f32 = 0,
    xeyes: bool = false,
    smile: f32 = 1,
    /// Pulinho do rosto a cada tecla.
    pop: f32 = 0,
    look: [2]f32 = .{ 0, 0 },
    /// Gota: 0 = some; posição ao longo da descida e queda.
    drop: f32 = 0,
    drop_slide: f32 = 0,
    drop_fall: f32 = 0,
    /// Separação das cores e cortes horizontais (glitch).
    rgb: f32 = 0,
    slices: f32 = 0,
    slice_seed: u32 = 0,
};

/// A cabeça inteira (orelhas, corpo, pelos e rosto) com a transformação `base`.
fn figure(dl: *c.ImDrawList, base: Af, p: Pose, alpha: f32, tint: ?Rgba, small: bool) void {
    const body = base
        .around(mid_x, 48, Af.scale(p.open_x, p.open_y))
        .around(mid_x, 96, Af.scale(1 - p.breath * 0.6, 1 + p.breath))
        .mul(Af.move(p.look[0] * 0.9, 0));
    const k = body.k();
    // Degradê único para orelhas e corpo (sem emenda entre as peças).
    const ga = base.ap(14, -16);
    const gb = base.ap(113, 96);
    var top = tint orelse head_top;
    var bottom = tint orelse head_bottom;
    if (p.flash > 0) {
        top = top.mix(cream, p.flash);
        bottom = bottom.mix(cream, p.flash);
    }

    // Orelhas, atrás do corpo (com um pouco de profundidade ao virar).
    const ears_m = body.mul(Af.move(-p.look[0] * 1.6, -p.look[1] * 0.6));
    const ear_l = ears_m.around(ear_pivot[0], ear_pivot[1], Af.turn(p.turn_l).mul(Af.scale(p.ear_l, p.ear_l)));
    const mirror = ears_m.mul(Af.move(body_w, 0)).mul(Af.scale(-1, 1));
    const ear_r = mirror.around(ear_pivot[0], ear_pivot[1], Af.turn(p.turn_r).mul(Af.scale(p.ear_r, p.ear_r)));
    for ([_]Af{ ear_l, ear_r }, [_]f32{ p.ear_l, p.ear_r }) |m, s| {
        if (s <= 0.01) continue;
        const start = dl.*.VtxBuffer.Size;
        earPath(dl, m);
        fillPath(dl, Rgba.white.u());
        paint(dl, start, ga, gb, top, bottom, alpha);
    }

    // Corpo.
    var poly: [body_curves.len * curve_steps + 8]c.ImVec2 = undefined;
    bodyPath(dl, body);
    const n = takePath(dl, &poly);
    const start = dl.*.VtxBuffer.Size;
    c.ImDrawList_AddConcavePolyFilled(dl, &poly, @intCast(n), Rgba.white.u());
    paint(dl, start, ga, gb, top, bottom, alpha);

    // Pelinhos dentro das orelhas (acompanham a orelha).
    if (!small and p.tufts > 0) {
        var pts: [tuft.len]c.ImVec2 = undefined;
        for ([_]Af{ ear_l, ear_r }) |m| {
            const cnt = partial(m, &tuft, p.tufts, &pts);
            if (cnt >= 2) c.ImDrawList_AddPolyline(dl, &pts, @intCast(cnt), tuft_col.mix(cream, p.flash).col(alpha), @max(1.5 * k, 0.8), 0);
        }
    }

    // Rosto: vira para onde o mouse está e dá um pulinho a cada tecla.
    const face = body.mul(Af.move(p.look[0] * 4, p.look[1] * 2.6)).around(mid_x, 58, Af.scale(1 + p.pop * 0.07, 1 + p.pop * 0.07));
    const fk = face.k();
    const eye_w = (if (small) @as(f32, 7.6) else 5.4) * fk;
    const ink_c = ink.alpha(alpha * (1 - p.flash));
    if (p.xeyes) {
        // Olhos de "x" (o erro).
        for ([_][2]f32{ .{ 40, 50 }, .{ 84, 55 } }) |e| {
            const r: f32 = 6.5;
            stroke(dl, &.{ face.ap(e[0] - r, e[1] - r), face.ap(e[0] + r, e[1] + r) }, eye_w * 0.85, ink_c);
            stroke(dl, &.{ face.ap(e[0] - r, e[1] + r), face.ap(e[0] + r, e[1] - r) }, eye_w * 0.85, ink_c);
        }
    } else {
        // ">", apertando na piscada.
        const sq = 1 - p.squint * 0.75;
        const gt = [_][2]f32{ .{ 31, 50 - 9 * sq }, .{ 49, 50 }, .{ 31, 50 + 9 * sq } };
        var pts: [3]c.ImVec2 = undefined;
        const cnt = partial(face, &gt, p.prompt, &pts);
        if (cnt >= 2) stroke(dl, pts[0..cnt], eye_w, ink_c);
        if (p.dots) {
            // Conectando: "..." pulando no lugar do "_".
            for (0..3) |i| {
                const fi: f32 = @floatFromInt(i);
                const hop = @max(0, @sin((p.dots_t * 1.6 - fi * 0.17) * std.math.tau)) * 4.5;
                c.ImDrawList_AddCircleFilled(dl, face.ap(76 + fi * 8.5, 58 - hop), 2.9 * fk, ink_c.u(), 0);
            }
        } else if (p.under > 0 and p.under_on) {
            stroke(dl, &.{ face.ap(73, 58), face.ap(73 + 22 * p.under, 58) }, eye_w, ink_c);
        }
    }
    // Boca.
    if (p.smile > 0) {
        var pts: [17]c.ImVec2 = undefined;
        const steps: usize = 16;
        const upto: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(steps)) * std.math.clamp(p.smile, 0, 1)))));
        for (0..upto + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            // Erro: boca torta e trêmula no lugar do sorriso.
            const wob: f32 = if (p.xeyes) @sin(t * 18) * 1.6 else 0;
            const ctrl_y: f32 = if (p.xeyes) 66 else 75;
            pts[i] = face.ap(u * u * 52 + 2 * u * t * mid_x + t * t * 76, u * u * 69 + 2 * u * t * ctrl_y + t * t * 68 + wob);
        }
        stroke(dl, pts[0 .. upto + 1], (if (small) @as(f32, 4.2) else 2.6) * fk, ink_c);
    }
    // Gota de suor: aparece, escorre pela testa e cai.
    if (!small and p.drop > 0) {
        const sx = 103 + p.drop_slide * 5;
        const sy = 28 + p.drop_slide * 12 + p.drop_fall * p.drop_fall * 60;
        const stretch = 1 + p.drop_slide * 0.25 + p.drop_fall * 0.5;
        const dm = body.around(103, 32, Af.scale(p.drop, p.drop * stretch)).mul(Af.move(sx - 103, sy - 28));
        c.ImDrawList_PathLineTo(dl, dm.ap(103, 28));
        c.ImDrawList_PathBezierQuadraticCurveTo(dl, dm.ap(99.6, 34), dm.ap(103, 36.6), 10);
        c.ImDrawList_PathBezierQuadraticCurveTo(dl, dm.ap(106.4, 34), dm.ap(103, 28), 10);
        fillPath(dl, drop_col.col(alpha * (1 - p.drop_fall)));
    }
}

/// Linhas de varredura só dentro do contorno do corpo.
fn scanlines(dl: *c.ImDrawList, base: Af, p: Pose, alpha: f32, offset: f32) void {
    if (alpha <= 0.004) return;
    const body = base.around(mid_x, 48, Af.scale(p.open_x, p.open_y));
    var poly: [body_curves.len * curve_steps + 8]c.ImVec2 = undefined;
    bodyPath(dl, body);
    const n = takePath(dl, &poly);
    if (n < 3) return;
    var y0: f32 = poly[0].y;
    var y1: f32 = poly[0].y;
    for (poly[0..n]) |q| {
        y0 = @min(y0, q.y);
        y1 = @max(y1, q.y);
    }
    const gap = @max(2.4 * body.k(), 2);
    var y = y0 + @mod(offset, gap);
    const col = ink.col(alpha);
    while (y < y1) : (y += gap) {
        // Interseções da linha com o contorno, em pares.
        var xs: [32]f32 = undefined;
        var m: usize = 0;
        for (0..n) |i| {
            const a = poly[i];
            const b = poly[(i + 1) % n];
            if ((a.y <= y) != (b.y <= y) and m < xs.len) {
                xs[m] = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x);
                m += 1;
            }
        }
        std.mem.sort(f32, xs[0..m], {}, std.sort.asc(f32));
        var i: usize = 0;
        while (i + 1 < m) : (i += 2) c.ImDrawList_AddLineEx(dl, d.v(xs[i], y), d.v(xs[i + 1], y), col, @max(gap * 0.38, 0.8), 0);
    }
}

/// "0" e "1" subindo atrás do mascote.
fn particles(dl: *c.ImDrawList, base: Af, t: f32, from: f32, until: f32, loop: bool, alpha: f32) void {
    const k = base.k();
    for (0..16) |idx| {
        const i: u32 = @intCast(idx);
        const life: f32 = 1.3 + hash(i, 3) * 0.6;
        const spawn = from + hash(i, 1) * 1.1;
        var age = t - spawn;
        if (loop and age > 0) age = @mod(age, life + 0.4);
        if (age < 0 or age > life) continue;
        if (!loop and spawn + life > until + 0.6 and t > until) continue;
        const x = -8 + hash(i, 2) * 143;
        const y = 70 + hash(i, 4) * 30 - age / life * 46;
        const fade = @sin(std.math.pi * age / life);
        const col = (if (i % 3 == 0) magenta else if (i % 3 == 1) Rgba.hex(0xB98CFF) else tuft_col).alpha(0.75 * fade * alpha);
        const s = (4.2 + hash(i, 5) * 2.4) * k;
        const pt = base.ap(x, y);
        if (i % 2 == 0) {
            c.ImDrawList_AddEllipseEx(dl, pt, d.v(s * 0.42, s * 0.62), col.u(), 0, 12, @max(s * 0.2, 0.9), 0);
        } else {
            c.ImDrawList_AddLineEx(dl, d.v(pt.x, pt.y - s * 0.62), d.v(pt.x, pt.y + s * 0.62), col.u(), @max(s * 0.22, 0.9), 0);
            c.ImDrawList_AddLineEx(dl, d.v(pt.x, pt.y - s * 0.62), d.v(pt.x - s * 0.3, pt.y - s * 0.32), col.u(), @max(s * 0.22, 0.9), 0);
        }
    }
}

/// O quadro `in.t` da animação, centrado em (cx, cy) com `size` pixels de largura.
pub fn draw(dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, in: Input) void {
    const A = in.alpha;
    if (A <= 0.002 or size < 4) return;
    const k = size * 0.78 / body_w;
    const base = Af.move(cx, cy).mul(Af.scale(k, k)).mul(Af.move(-mid_x, -mid_y));
    const small = size < 40;
    if (in.reduce) {
        logo.glow(dl, cx, cy, size * 0.5, size * 0.42, glow_col.alpha(0.3 * A));
        figure(dl, base, .{ .look = in.look }, A, null, small);
        return;
    }
    const t = in.t;
    var p: Pose = .{ .look = in.look };

    // --- Abertura -----------------------------------------------------------
    const cursor_on = (t < 0.14) or (t >= 0.24 and t < 0.42);
    const line_k = outExpo(seg(t, 0.36, 0.62));
    const open = seg(t, 0.55, 1.05);
    if (t < 0.55) {
        p.open_y = 0;
    } else {
        p.open_y = @max(0.02, outBack(open, 1.7));
        p.open_x = 1 + 0.12 * (1 - outCubic(open));
    }
    p.flash = 1 - outCubic(seg(t, 0.55, 0.95));
    p.rgb = 1 - outCubic(seg(t, 0.55, 1.3));
    p.ear_l = std.math.clamp(spring(t - 0.85, 13, 6), 0, 1.3);
    p.ear_r = std.math.clamp(spring(t - 0.93, 13, 6), 0, 1.3);
    p.turn_l = -0.55 * @exp(-5 * @max(t - 0.85, 0)) * @cos(11 * @max(t - 0.85, 0)) * @as(f32, if (t > 0.85) 1 else 0);
    p.turn_r = -0.55 * @exp(-5 * @max(t - 0.93, 0)) * @cos(11 * @max(t - 0.93, 0)) * @as(f32, if (t > 0.93) 1 else 0);
    p.tufts = outCubic(seg(t, 1.15, 1.45));
    p.prompt = seg(t, 1.2, 1.4);
    p.under = outCubic(seg(t, 1.5, 1.58));
    p.smile = outCubic(seg(t, 1.6, 1.85));
    p.pop = kick(t - 1.2, 0.14) + kick(t - 1.3, 0.14) + kick(t - 1.5, 0.16);
    // O "_" pisca como cursor depois de digitado.
    if (t > 1.9 and t < 2.6) p.under_on = @mod(t - 1.9, 0.36) < 0.2;
    // Gota: aparece, escorre e cai.
    if (t > 2.0 and t < 3.3) {
        p.drop = outBack(seg(t, 2.0, 2.2), 2);
        p.drop_slide = outCubic(seg(t, 2.25, 2.75));
        p.drop_fall = seg(t, 2.8, 3.3);
    }

    // --- Parado (depois da abertura) -------------------------------------------
    if (t > 2.6) {
        const it = t - 2.6;
        p.breath = 0.012 * @sin(it * 1.7);
        // Orelhas tremem, uma de cada vez.
        const ear_period: f32 = 5.3;
        const ec = @floor(it / ear_period);
        const eph = it - ec * ear_period;
        const tw = kick(eph - 1.0, 0.32) * 0.35;
        if (@mod(ec, 2) == 0) p.turn_l += tw else p.turn_r += tw;
        // O cursor pisca duas vezes de vez em quando.
        const cph = @mod(it, 4.2);
        p.under_on = !((cph > 2.9 and cph < 3.05) or (cph > 3.2 and cph < 3.35));
        // O ">" aperta (a "piscada" do outro olho).
        p.squint = kick(@mod(it, 6.7) - 4.6, 0.22) * 2.2;
        // A gota volta de vez em quando: ele é um larper nervoso.
        const dph = @mod(it, 11.0) - 8.0;
        if (dph > 0 and dph < 1.3) {
            p.drop = outBack(seg(dph, 0, 0.2), 2);
            p.drop_slide = outCubic(seg(dph, 0.25, 0.75));
            p.drop_fall = seg(dph, 0.8, 1.3);
        }
        // Glitch rápido e raro.
        const gph = @mod(it, 12.5) - 9.0;
        if (gph > 0 and gph < 0.16) {
            p.slices = 1 - gph / 0.16;
            p.rgb = @max(p.rgb, 0.6 * p.slices);
            p.slice_seed = @intFromFloat(@floor(t * 30));
        }
    }

    // --- Conectando, erro e saída -------------------------------------------------
    if (in.connecting and t > 1.5) {
        p.dots = true;
        p.dots_t = t;
        p.turn_l -= 0.08;
        p.turn_r -= 0.08;
    }
    if (in.err_age < 1.4) {
        p.xeyes = true;
        p.dots = false;
        const g = 1 - seg(in.err_age, 0, 0.45);
        p.slices = @max(p.slices, g);
        p.rgb = @max(p.rgb, g);
        p.slice_seed = @intFromFloat(@floor(t * 24));
        if (in.err_age < 1.3) {
            p.drop = outBack(seg(in.err_age, 0.1, 0.3), 2);
            p.drop_slide = outCubic(seg(in.err_age, 0.35, 0.8));
            p.drop_fall = seg(in.err_age, 0.85, 1.3);
        }
    }
    var dot_glow: f32 = 0;
    var line_glow: f32 = 0;
    if (in.leave > 0) {
        // Conectou: a piscadinha ">_" aparece de relance e ele desliga como uma
        // TV de tubo: achata até virar linha, a linha encolhe até um ponto, e o
        // ponto apaga.
        const lk = in.leave;
        p.dots = false;
        p.under_on = true;
        p.under = @max(p.under * @as(f32, if (t > 1.58) 1 else 0), outCubic(seg(lk, 0, 0.12)));
        p.pop = @max(p.pop, kick(lk, 0.2) * 1.4);
        const squash = inCubic(seg(lk, 0.2, 0.5));
        p.open_y *= 1 - squash * 0.985;
        p.open_x *= 1 + 0.15 * squash;
        p.flash = @max(p.flash, squash);
        const shrink = seg(lk, 0.5, 0.8);
        p.open_x *= 1 - inCubic(shrink);
        line_glow = squash * (1 - shrink);
        dot_glow = kick(lk - 0.72, 0.28) * 1.6;
        p.drop = 0;
    }

    // --- Desenho ----------------------------------------------------------------
    const center = base.ap(mid_x, 48);
    const shown = @min(seg(t, 0.55, 0.9) + @as(f32, if (t >= 0.9) 1 else 0), 1) * (1 - seg(in.leave, 0.5, 0.75));
    // Halo e sombra no chão.
    logo.glow(dl, cx, cy + 4 * k, size * 0.55 * shown, size * 0.46 * shown, glow_col.alpha((0.34 + 0.06 * @sin(t * 2)) * A));
    if (shown > 0.01) {
        const foot = base.ap(mid_x, 99);
        c.ImDrawList_AddEllipseFilled(dl, foot, d.v(46 * k * p.open_x * shown, 4.5 * k * shown), (if (in.light) ink.alpha(0.12) else Rgba.black.alpha(0.32)).col(A));
    }
    // Partículas (na abertura; conectando, ficam subindo).
    particles(dl, base, t, 0.55, 2.4, in.connecting, A * (1 - in.leave));
    // Onda de choque no chão quando o corpo aterrissa.
    const ring = seg(t, 0.82, 1.35);
    if (ring > 0 and ring < 1) {
        const foot = base.ap(mid_x, 98);
        const rr = outCubic(ring);
        c.ImDrawList_AddEllipseEx(dl, foot, d.v((40 + 46 * rr) * k, (4 + 6 * rr) * k), magenta.col(0.55 * (1 - ring) * A), 0, 48, @max(2.2 * k * (1 - ring), 0.8), 0);
    }

    if (t < 0.55) {
        // O cursor e a linha que acende.
        if (cursor_on and t < 0.42) {
            const cw = 8 * k;
            const ch = 13 * k;
            c.ImDrawList_AddRectFilledEx(dl, d.v(center.x - cw / 2, center.y - ch / 2), d.v(center.x + cw / 2, center.y + ch / 2), cream.col(A), 1.5 * k, 0);
        }
        if (line_k > 0) {
            const lw = 8 * k + (body_w * 1.12 - 8) * k * line_k;
            logo.glow(dl, center.x, center.y, lw * 0.6, 7 * k, magenta.alpha(0.55 * A));
            c.ImDrawList_AddRectFilledEx(dl, d.v(center.x - lw / 2, center.y - 1.3 * k), d.v(center.x + lw / 2, center.y + 1.3 * k), cream.col(A), 1.3 * k, 0);
        }
        return;
    }

    // Separação de cores atrás (as franjas ciano e magenta nas bordas).
    if (p.rgb > 0.01) {
        const off = 5.5 * k * p.rgb;
        figure(dl, base.mul(Af.move(-off / k, 0)), p, A * 0.55 * p.rgb, cyan, small);
        figure(dl, base.mul(Af.move(off / k, 0)), p, A * 0.55 * p.rgb, magenta, small);
    }
    if (p.slices > 0.01) {
        // Glitch: faixas horizontais deslocadas.
        const top_y = base.ap(0, -18).y;
        const bot_y = base.ap(0, 100).y;
        const bands: u32 = 6;
        for (0..bands) |bi| {
            const b: u32 = @intCast(bi);
            const y0 = top_y + (bot_y - top_y) * @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(bands));
            const y1 = top_y + (bot_y - top_y) * @as(f32, @floatFromInt(b + 1)) / @as(f32, @floatFromInt(bands));
            const shift = (hash(b, p.slice_seed) - 0.5) * 22 * p.slices;
            c.ImDrawList_PushClipRect(dl, d.v(cx - size, y0), d.v(cx + size, y1), true);
            figure(dl, base.mul(Af.move(shift, 0)), p, A, null, small);
            c.ImDrawList_PopClipRect(dl);
        }
    } else {
        figure(dl, base, p, A, null, small);
    }
    // Faíscas saindo da ponta de cada orelha quando ela salta.
    for ([_]f32{ 0.95, 1.03 }, [_]f32{ 1, -1 }) |at, side| {
        const sp = seg(t, at, at + 0.42);
        if (sp <= 0 or sp >= 1) continue;
        const tip_x: f32 = if (side > 0) 21.5 else body_w - 21.5;
        const tip = base.ap(tip_x, -15);
        for (0..5) |si| {
            const fi: f32 = @floatFromInt(si);
            const ang = (-0.5 - 0.55 * side) * std.math.pi + (fi - 2) * 0.32 * side;
            const r0 = (3 + 14 * outCubic(sp)) * k;
            const r1 = r0 + 6 * k * (1 - sp);
            const col = (if (si % 2 == 0) cream else tuft_col).col((1 - sp) * A);
            c.ImDrawList_AddLineEx(dl, d.v(tip.x + @cos(ang) * r0, tip.y + @sin(ang) * r0), d.v(tip.x + @cos(ang) * r1, tip.y + @sin(ang) * r1), col, @max(1.8 * k * (1 - sp * 0.5), 0.8), 0);
        }
    }
    // Varredura da tela de tubo por cima, sumindo depois da abertura.
    const scan_a = (1 - seg(t, 1.0, 1.8)) * 0.16 + p.slices * 0.12 + line_glow * 0.2;
    scanlines(dl, base, p, scan_a * A, t * 18 * k);
    // A faixa clara que desce uma vez pela tela.
    const sweep = seg(t, 0.62, 1.25);
    if (sweep > 0 and sweep < 1) {
        const top_y = base.ap(0, -16).y;
        const bot_y = base.ap(0, 98).y;
        const yy = top_y + (bot_y - top_y) * outCubic(sweep);
        logo.glow(dl, cx, yy, size * 0.45 * p.open_x, 5 * k, cream.alpha(0.35 * (1 - sweep) * A));
    }
    if (line_glow > 0.01) logo.glow(dl, center.x, center.y, body_w * k * 0.62 * p.open_x, 8 * k, magenta.alpha(0.6 * line_glow * A));
    if (dot_glow > 0.01) {
        logo.glow(dl, center.x, center.y, 16 * k * dot_glow, 16 * k * dot_glow, cream.alpha(0.9 * @min(dot_glow, 1) * A));
        c.ImDrawList_AddCircleFilled(dl, center, 2.4 * k * @min(dot_glow, 1), cream.col(A), 0);
    }
}

/// Mascote pequeno e parado ("Sobre", barra de título).
pub fn still(dl: *c.ImDrawList, cx: f32, cy: f32, size: f32) void {
    draw(dl, cx, cy, size, .{ .t = 100, .reduce = true });
}
