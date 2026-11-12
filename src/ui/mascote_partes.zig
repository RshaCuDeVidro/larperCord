//! As peças do mascote Terminal (ui/mascote_visual.zig diz quais são): os olhos, as
//! bocas, os chapéus, os acessórios e as formas dos arquivos de mascote, desenhados
//! com o ImDrawList nas medidas do SVG (os olhos do ">_" ficam em (40, 50) e (84, 55),
//! a boca em volta de (63.5, 70)). Cada olho e cada boca desenha a partir dos números
//! da expressão (`visual.Expr`): toda combinação tem todas as caras, a piscada, o olhar
//! e a boca aberta. Tudo vira polígono no espaço do SVG antes de ir para a tela, então
//! gira, achata e espelha junto com o corpo em qualquer tamanho.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const v = @import("mascote_visual.zig");
const terminal = @import("mascote_terminal.zig");
const contas = @import("mascote_contas.zig");

const Rgba = d.Rgba;
const Af = contas.Affine(c.ImVec2);
const tau = std.math.tau;
const pi = std.math.pi;

const cream = Rgba.hex(0xF8F0FF);
const drop_col = Rgba.hex(0xD8B4FE);
const tongue_col = Rgba.hex(0xFF6B9A);
const white = Rgba.hex(0xFFFFFF);
const gold = Rgba.hex(0xF6C344);
const gold_dark = Rgba.hex(0xC98A17);

/// Onde ficam os olhos e a boca do ">_".
pub const eye_l = [2]f32{ 40, 50 };
pub const eye_r = [2]f32{ 84, 55 };
/// A inclinação do rosto (o olho direito fica mais baixo).
const tilt: f32 = 0.1131;

// --- Pincel -------------------------------------------------------------------------

/// O que todo desenho de peça precisa: onde (a transformação do SVG para a tela), as
/// cores do mascote e os efeitos do quadro (transparência, o clarão creme da abertura e
/// a silhueta de uma cor só das franjas do RGB).
pub const Brush = struct {
    dl: *c.ImDrawList,
    m: Af,
    alpha: f32 = 1,
    flash: f32 = 0,
    tint: ?Rgba = null,
    small: bool = false,
    colors: v.Colors = v.brand_colors,
    /// Relógio (a hélice gira, a auréola flutua).
    t: f32 = 0,

    pub fn at(b: Brush, m: Af) Brush {
        var o = b;
        o.m = m;
        return o;
    }
    pub fn k(b: Brush) f32 {
        return b.m.k();
    }
    pub fn pt(b: Brush, x: f32, y: f32) c.ImVec2 {
        return b.m.ap(x, y);
    }
    pub fn role(b: Brush, r: v.Role) Rgba {
        return b.colors[@intFromEnum(r)];
    }
    /// Uma cor de peça, com os efeitos do quadro.
    pub fn paint(b: Brush, col: Rgba) u32 {
        if (b.tint) |tc| return tc.col(col.a * b.alpha);
        var o = col;
        if (b.flash > 0) {
            const m = col.mix(cream, b.flash);
            o = .{ .r = m.r, .g = m.g, .b = m.b, .a = col.a };
        }
        return o.col(b.alpha);
    }
    /// O traço do rosto: some no clarão, como o ">_".
    pub fn ink(b: Brush) u32 {
        return b.inkA(1);
    }
    /// O traço não pega a silhueta das franjas do RGB (como o ">_", que fica escuro nelas).
    pub fn inkA(b: Brush, a: f32) u32 {
        return b.role(.ink).col(a * b.alpha * (1 - b.flash));
    }
    /// Espessura em unidades do SVG, nunca menor que um pixel e pouco.
    fn w(b: Brush, units: f32) f32 {
        return @max(units * b.k(), 0.9);
    }
};

// --- Formas no espaço do SVG ------------------------------------------------------------

const max_pts = 160;

fn screen(b: Brush, src: []const [2]f32, out: []c.ImVec2) usize {
    const n = @min(src.len, out.len);
    for (src[0..n], 0..) |q, i| out[i] = b.m.ap(q[0], q[1]);
    return n;
}

/// No sentido que o triangulador do ImGui acerta (horário na tela).
fn clockwise(pts: []c.ImVec2) void {
    var area: f32 = 0;
    for (0..pts.len) |i| {
        const a = pts[i];
        const q = pts[(i + 1) % pts.len];
        area += a.x * q.y - q.x * a.y;
    }
    if (area < 0) std.mem.reverse(c.ImVec2, pts);
}

/// Polígono (côncavo ou não) pintado.
pub fn fill(b: Brush, src: []const [2]f32, col: u32) void {
    if (src.len < 3 or (col >> 24) == 0) return;
    var buf: [max_pts]c.ImVec2 = undefined;
    const n = screen(b, src, &buf);
    clockwise(buf[0..n]);
    c.ImDrawList_AddConcavePolyFilled(b.dl, &buf, @intCast(n), col);
}

/// Polígono convexo pintado (mais barato e com a borda suave certa).
pub fn fillConvex(b: Brush, src: []const [2]f32, col: u32) void {
    if (src.len < 3 or (col >> 24) == 0) return;
    var buf: [max_pts]c.ImVec2 = undefined;
    const n = screen(b, src, &buf);
    clockwise(buf[0..n]);
    c.ImDrawList_AddConvexPolyFilled(b.dl, &buf, @intCast(n), col, 0);
}

/// Traço de ponta redonda (`width` em unidades do SVG).
pub fn line(b: Brush, src: []const [2]f32, width: f32, col: u32) void {
    if (src.len < 2 or (col >> 24) == 0) return;
    var buf: [max_pts]c.ImVec2 = undefined;
    const n = screen(b, src, &buf);
    const wpx = b.w(width);
    c.ImDrawList_AddPolyline(b.dl, &buf, @intCast(n), col, wpx, 0);
    const r = wpx / 2;
    if (r >= 0.8) for (buf[0..n]) |q| c.ImDrawList_AddCircleFilled(b.dl, q, r, col, 0);
}

/// Contorno fechado.
pub fn outline(b: Brush, src: []const [2]f32, width: f32, col: u32) void {
    if (src.len < 2 or (col >> 24) == 0) return;
    var buf: [max_pts]c.ImVec2 = undefined;
    const n = screen(b, src, &buf);
    c.ImDrawList_AddPolyline(b.dl, &buf, @intCast(n), col, b.w(width), c.ImDrawFlags_Closed);
}

/// Pontos de uma elipse girada `rot` (radianos), com mais pontos quando é grande na tela.
fn ellipsePts(b: Brush, cx: f32, cy: f32, rx: f32, ry: f32, rot: f32, out: [][2]f32) usize {
    const r_px = @max(rx, ry) * b.k();
    const n: usize = @intFromFloat(std.math.clamp(r_px * 0.9, 10, @as(f32, @floatFromInt(@min(out.len, 48)))));
    const cs = @cos(rot);
    const sn = @sin(rot);
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * tau;
        const x = @cos(a) * rx;
        const y = @sin(a) * ry;
        out[i] = .{ cx + x * cs - y * sn, cy + x * sn + y * cs };
    }
    return n;
}

pub fn ellipse(b: Brush, cx: f32, cy: f32, rx: f32, ry: f32, rot: f32, col: u32) void {
    if (rx <= 0.01 or ry <= 0.01) return;
    var pts: [48][2]f32 = undefined;
    const n = ellipsePts(b, cx, cy, rx, ry, rot, &pts);
    fillConvex(b, pts[0..n], col);
}

pub fn circle(b: Brush, cx: f32, cy: f32, r: f32, col: u32) void {
    ellipse(b, cx, cy, r, r, 0, col);
}

pub fn ring(b: Brush, cx: f32, cy: f32, rx: f32, ry: f32, rot: f32, width: f32, col: u32) void {
    if (rx <= 0.01 or ry <= 0.01) return;
    var pts: [48][2]f32 = undefined;
    const n = ellipsePts(b, cx, cy, rx, ry, rot, &pts);
    outline(b, pts[0..n], width, col);
}

/// Curva quadrática em `n` + 1 pontos.
fn quad(a: [2]f32, ctrl: [2]f32, z: [2]f32, n: usize, out: [][2]f32) usize {
    const m = @min(n + 1, out.len);
    for (0..m) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(m - 1));
        const u = 1 - t;
        out[i] = .{ u * u * a[0] + 2 * u * t * ctrl[0] + t * t * z[0], u * u * a[1] + 2 * u * t * ctrl[1] + t * t * z[1] };
    }
    return m;
}

/// Retângulo de cantos redondos (`r` limitado à metade do lado menor), girado `rot`
/// em volta do centro.
fn roundRect(x: f32, y: f32, wd: f32, h: f32, r0: f32, rot: f32, out: [][2]f32) usize {
    const r = @min(r0, @min(wd, h) / 2);
    const cx = x + wd / 2;
    const cy = y + h / 2;
    const cs = @cos(rot);
    const sn = @sin(rot);
    var n: usize = 0;
    const corners = [4][3]f32{ .{ x + wd - r, y + r, -0.25 }, .{ x + wd - r, y + h - r, 0 }, .{ x + r, y + h - r, 0.25 }, .{ x + r, y + r, 0.5 } };
    for (corners) |cn| {
        const steps: usize = if (r > 0.01) 5 else 1;
        for (0..steps) |i| {
            if (n >= out.len) break;
            const a = (cn[2] + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(steps - 1, 1))) * 0.25) * tau;
            const px = cn[0] + @cos(a) * r - cx;
            const py = cn[1] + @sin(a) * r - cy;
            out[n] = .{ cx + px * cs - py * sn, cy + px * sn + py * cs };
            n += 1;
        }
    }
    return n;
}

fn rrect(b: Brush, x: f32, y: f32, wd: f32, h: f32, r: f32, rot: f32, col: u32) void {
    var pts: [24][2]f32 = undefined;
    const n = roundRect(x, y, wd, h, r, rot, &pts);
    fillConvex(b, pts[0..n], col);
}

fn rot2(p: [2]f32, ctr: [2]f32, a: f32) [2]f32 {
    const cs = @cos(a);
    const sn = @sin(a);
    const x = p[0] - ctr[0];
    const y = p[1] - ctr[1];
    return .{ ctr[0] + x * cs - y * sn, ctr[1] + x * sn + y * cs };
}

fn mixRgb(a: Rgba, q: Rgba, t: f32) Rgba {
    const m = a.mix(q, t);
    return .{ .r = m.r, .g = m.g, .b = m.b, .a = a.a };
}

// --- Rosto: o que entra ----------------------------------------------------------------

/// O estado do rosto neste quadro.
pub const FaceIn = struct {
    face: v.Face = .prompt,
    /// Piscada (0..1 fechando) e o olhar (-1..1).
    blink: f32 = 0,
    look: [2]f32 = .{ 0, 0 },
    xeyes: bool = false,
    /// Surgindo na abertura (0..1): os olhos quando o ">" é digitado, a boca com o sorriso.
    reveal_eyes: f32 = 1,
    reveal_mouth: f32 = 1,
    /// O cursor da boca "_": aceso e quanto já foi digitado.
    cursor_on: bool = true,
    cursor_k: f32 = 1,
    /// Conectando: "..." no lugar da boca.
    dots: bool = false,
    dots_t: f32 = 0,
    /// Comendo, bocejando.
    mouth_open: f32 = 0,
};

/// Onde ficam os olhos de cada estilo (o ciclope tem um só; as olheiras e os óculos
/// seguem isto).
pub fn eyeSpots(style: v.Eyes, out: *[2][2]f32) usize {
    if (style == .cyclops) {
        out[0] = .{ 62, 51.5 };
        return 1;
    }
    out[0] = eye_l;
    out[1] = eye_r;
    return 2;
}

/// Meia altura de cada olho aberto (as sobrancelhas e a lágrima ficam acima e abaixo).
fn eyeHalf(style: v.Eyes) f32 {
    return switch (style) {
        .prompt => 9,
        .dots, .wink => 4.6,
        .ovals => 6.6,
        .big => 8,
        .cat => 5.4,
        .sleepy => 3,
        .happy => 4,
        .stars => 6.8,
        .hearts => 6.4,
        .pixel => 4.2,
        .binary => 6,
        .lashes => 7.4,
        .visor => 7.5,
        .cyclops => 12,
        .custom => 7,
    };
}

// --- Olhos -------------------------------------------------------------------------------

/// Os olhos de um estilo (menos o ">_", que é o de mascote_terminal).
pub fn eyes(b: Brush, style: v.Eyes, in: FaceIn) void {
    const e = v.exprOf(in.face);
    const open = e.open * (1 - std.math.clamp(in.blink * 1.15, 0, 1));
    const reveal = in.reveal_eyes;
    if (reveal <= 0.01) return;
    switch (style) {
        .visor => return visor(b, e, open, in),
        .cyclops => return cyclops(b, e, open, in),
        else => {},
    }
    const ew: f32 = if (b.small) 7.6 else 5.4;
    for ([_][2]f32{ eye_l, eye_r }, [_]f32{ -1, 1 }) |ctr, side| {
        const s = contas.outBack(std.math.clamp(reveal, 0, 1), 2);
        const eb = if (reveal < 1) b.at(b.m.around(ctr[0], ctr[1], Af.scale(s, s))) else b;
        if (in.xeyes) {
            xEye(eb, ctr, 6.5, ew * 0.85, eb.ink());
            continue;
        }
        if (e.spiral) {
            spiral(eb, ctr, 7, ew * 0.55, eb.ink());
            continue;
        }
        if (e.squeeze) {
            squeezed(eb, ctr, side, ew, eb.ink());
            continue;
        }
        // Os de piscadinha: um aberto e outro fechado, menos quando a cara fecha ou
        // arregala os dois.
        var arc = e.arc;
        var o = open;
        if (style == .happy and e.wide == 0) {
            o = 0;
            if (arc == 0) arc = if (e.brow > 0) -0.7 else if (e.brow < 0) 0.25 else 1;
        }
        if (style == .wink and side > 0 and o > 0.2 and e.wide == 0) {
            o = 0;
            arc = 1;
        }
        const st: v.Eyes = if (style == .happy or style == .wink) .dots else style;
        if (o < 0.2) closed(eb, st, ctr, side, arc, ew) else openEye(eb, st, ctr, side, o, e.wide, in.look);
    }
    if (in.xeyes or e.spiral) return;
    if (e.brow != 0) brows(b, style, e.brow, ew);
    if (e.tear) tear(b, eye_l[0] - 6.5, eye_l[1] + eyeHalf(style) * 0.5 + 3.5);
}

fn xEye(b: Brush, ctr: [2]f32, r: f32, wd: f32, col: u32) void {
    line(b, &.{ .{ ctr[0] - r, ctr[1] - r }, .{ ctr[0] + r, ctr[1] + r } }, wd, col);
    line(b, &.{ .{ ctr[0] - r, ctr[1] + r }, .{ ctr[0] + r, ctr[1] - r } }, wd, col);
}

fn spiral(b: Brush, ctr: [2]f32, r: f32, wd: f32, col: u32) void {
    var pts: [22][2]f32 = undefined;
    for (0..22) |i| {
        const t = @as(f32, @floatFromInt(i)) / 21.0;
        const a = t * tau * 1.8;
        const rr = 1 + (r - 1) * t;
        pts[i] = .{ ctr[0] + @cos(a) * rr, ctr[1] + @sin(a) * rr };
    }
    line(b, &pts, wd, col);
}

fn squeezed(b: Brush, ctr: [2]f32, side: f32, wd: f32, col: u32) void {
    if (side < 0) {
        line(b, &.{ .{ ctr[0] - 9, ctr[1] - 8 }, .{ ctr[0] + 8, ctr[1] }, .{ ctr[0] - 9, ctr[1] + 8 } }, wd, col);
    } else {
        line(b, &.{ .{ ctr[0] + 9, ctr[1] - 7 }, .{ ctr[0] - 7, ctr[1] + 1 }, .{ ctr[0] + 9, ctr[1] + 9 } }, wd, col);
    }
}

/// Olho fechado: arco feliz ("◠"), triste ("◡" para baixo) ou um risco que dorme.
fn closed(b: Brush, style: v.Eyes, ctr: [2]f32, side: f32, arc: f32, ew: f32) void {
    const x = ctr[0];
    const y = ctr[1];
    const col = b.ink();
    var pts: [15][2]f32 = undefined;
    switch (style) {
        .pixel => {
            const u: f32 = 3.7;
            if (arc > 0.2) {
                rrect(b, x - u * 1.5 - u / 2, y, u, u, 0.4, 0, col);
                rrect(b, x - u / 2, y - u, u, u, 0.4, 0, col);
                rrect(b, x + u * 1.5 - u / 2, y, u, u, 0.4, 0, col);
            } else if (arc < -0.2) {
                rrect(b, x - u * 1.5 - u / 2, y - u, u, u, 0.4, 0, col);
                rrect(b, x - u / 2, y, u, u, 0.4, 0, col);
                rrect(b, x + u * 1.5 - u / 2, y - u, u, u, 0.4, 0, col);
            } else rrect(b, x - 6.5, y, 13, u * 0.85, 0.4, 0, col);
            return;
        },
        .binary => {
            if (arc > 0.2) {
                line(b, &.{ .{ x - 6.5, y + 3.5 }, .{ x, y - 3.5 }, .{ x + 6.5, y + 3.5 } }, ew * 0.62, col);
            } else line(b, &.{ .{ x - 5.5, y + 1 }, .{ x + 5.5, y + 1 } }, ew * 0.62, col);
            return;
        },
        else => {},
    }
    const n = if (arc > 0.05)
        quad(.{ x - 7.5, y + 3 }, .{ x, y - 6.5 * arc }, .{ x + 7.5, y + 3 }, 12, &pts)
    else if (arc < -0.05)
        quad(.{ x - 7, y - 1 }, .{ x, y + 5.5 * -arc }, .{ x + 7, y - 1 }, 12, &pts)
    else
        quad(.{ x - 7.2, y + 1.5 }, .{ x, y + 4 }, .{ x + 7.2, y + 1.5 }, 12, &pts);
    line(b, pts[0..n], ew * 0.82, col);
    if (style == .lashes) {
        // Cílios na ponta de fora: para cima no arco feliz, para baixo dormindo.
        const down = arc <= 0.05;
        const tip: [2]f32 = if (side < 0) pts[0] else pts[n - 1];
        for (0..3) |i| {
            const fi: f32 = @floatFromInt(i);
            const ang = (if (down) @as(f32, 0.35) else -0.35) + (if (down) fi * 0.42 else -fi * 0.42);
            const dx = @cos(ang) * 3.4 * side;
            const dy = @sin(ang) * 3.4;
            const base: [2]f32 = .{ tip[0] - side * fi * 1.6, tip[1] + (if (down) fi * 0.5 else -fi * 0.6) };
            line(b, &.{ base, .{ base[0] + dx, base[1] + dy } }, if (b.small) 2.2 else 1.4, col);
        }
    }
}

/// Um olho aberto, `o` (0..1) de abertura, `wide` de susto, `lk` o olhar.
fn openEye(b: Brush, style: v.Eyes, ctr: [2]f32, side: f32, o: f32, wide: f32, lk: [2]f32) void {
    const sz: f32 = (if (b.small) @as(f32, 1.18) else 1) * (1 + 0.22 * wide);
    const lx = lk[0] * 1.3;
    const ly = lk[1] * 1.0;
    const x = ctr[0];
    const y = ctr[1];
    const col = b.ink();
    const glint = b.paint(white.alpha(0.92));
    const ew: f32 = if (b.small) 7.6 else 5.4;
    switch (style) {
        .dots => {
            const r = 4.4 * sz;
            ellipse(b, x + lx, y + ly, r, r * o, 0, col);
            if (!b.small and o > 0.6) circle(b, x + lx + r * 0.36, y + ly - r * 0.4 * o, r * 0.27, glint);
        },
        .ovals => {
            const rx = 3.5 * sz;
            const ry = 6.4 * sz;
            ellipse(b, x + lx, y + ly, rx, ry * o, 0, col);
            if (!b.small and o > 0.6) circle(b, x + lx + rx * 0.3, y + ly - ry * 0.42 * o, 1.3, glint);
        },
        .big => {
            const r = 7.8 * sz;
            ellipse(b, x, y, r, r * o, 0, col);
            const iris = mixRgb(b.role(.accent), b.role(.ink), 0.3);
            const ix = x + lx * 1.4;
            const iy = y + (1 + ly * 1.2) * o;
            ellipse(b, ix, iy, r * 0.62, r * 0.62 * o, 0, b.paint(iris));
            ellipse(b, ix, iy, r * 0.3, r * 0.3 * o, 0, col);
            if (o > 0.45) {
                ellipse(b, x - r * 0.3, y - r * 0.34 * o, r * 0.32, r * 0.3 * o, 0, glint);
                circle(b, x + r * 0.36, y + r * 0.3 * o, r * 0.13, glint);
            }
        },
        .cat => {
            const hw = 7.4 * sz;
            const hh = 5.4 * sz * o;
            const rot = -side * 0.2;
            var lens: [26][2]f32 = undefined;
            for (0..13) |i| {
                const t = @as(f32, @floatFromInt(i)) / 12.0;
                const px = -hw + 2 * hw * t;
                lens[i] = rot2(.{ x + px, y - hh * std.math.pow(f32, @sin(pi * t), 0.8) }, ctr, rot);
                lens[25 - i] = rot2(.{ x + px, y + hh * std.math.pow(f32, @sin(pi * t), 0.8) }, ctr, rot);
            }
            const iris = mixRgb(b.role(.accent), white, 0.18);
            fill(b, &lens, b.paint(iris));
            const pw = 1.45 * sz * (1 + wide * 0.9);
            ellipse(b, x + lx, y + ly * 0.6, pw, hh * 0.86, rot, col);
            outline(b, &lens, if (b.small) 2.2 else 1.5, col);
            if (!b.small and o > 0.6) circle(b, x + lx + 2, y + ly * 0.6 - hh * 0.4, 1.1, glint);
        },
        .sleepy => {
            // A pálpebra pesada em cima e a metade de baixo do olho aparecendo.
            const rx = 6.2 * sz;
            const ry = 5.4 * sz * o;
            const tilt_l: f32 = 0.7 * side;
            var half: [13][2]f32 = undefined;
            for (0..13) |i| {
                const a = pi * @as(f32, @floatFromInt(i)) / 12.0;
                half[i] = .{ x + @cos(a) * rx, y - 1 + @sin(a) * ry + @cos(a) * tilt_l };
            }
            fillConvex(b, half[0..13], col);
            if (!b.small and o > 0.6) circle(b, x + lx * 0.8 + 1.8, y + 1.6, 1.1, glint);
            line(b, &.{ .{ x - rx - 1.6, y - 1 - (tilt_l + 0.4) }, .{ x + rx + 1.6, y - 1 + (tilt_l - 0.4) } }, ew * 0.62, col);
        },
        .stars => {
            const r_out = 7.8 * sz;
            const r_in = r_out * 0.46;
            var st: [10][2]f32 = undefined;
            for (0..10) |i| {
                const a = -pi / 2.0 + @as(f32, @floatFromInt(i)) * pi / 5.0 - side * 0.12;
                const rr = if (i % 2 == 0) r_out else r_in;
                st[i] = .{ x + lx * 0.6 + @cos(a) * rr, y + ly * 0.5 + @sin(a) * rr * o };
            }
            fill(b, &st, b.paint(Rgba.hex(0xFFD84A)));
            outline(b, &st, if (b.small) 1.8 else 1.2, col);
            if (!b.small and o > 0.6) circle(b, x + lx * 0.6 - 1.6, y + ly * 0.5 - 1.8 * o, 1.05, glint);
        },
        .hearts => {
            const s = 0.48 * sz;
            var hp: [28][2]f32 = undefined;
            for (0..28) |i| {
                const t = @as(f32, @floatFromInt(i)) / 28.0 * tau;
                const sn = @sin(t);
                const hx = 16 * sn * sn * sn;
                const hy = -(13 * @cos(t) - 5 * @cos(2 * t) - 2 * @cos(3 * t) - @cos(4 * t));
                hp[i] = .{ x + lx * 0.6 + hx * s, y + 0.6 + ly * 0.5 + hy * s * o };
            }
            fill(b, &hp, b.paint(Rgba.hex(0xFF4D8D)));
            outline(b, &hp, if (b.small) 1.8 else 1.1, col);
            if (!b.small and o > 0.6) circle(b, x + lx * 0.6 - 2.6, y + ly * 0.5 - 2.4 * o, 1.15, glint);
        },
        .pixel => {
            const s = 8.8 * sz;
            const h = s * o;
            rrect(b, x + lx - s / 2, y + ly - h / 2, s, h, 0.7, 0, col);
            if (o > 0.6) rrect(b, x + lx + s * 0.08, y + ly - h / 2 + s * 0.12, s * 0.3, s * 0.3, 0.2, 0, glint);
        },
        .binary => {
            const h = 6.8 * sz * o;
            const wd = ew * 0.7;
            if (side < 0 or wide > 0) {
                ring(b, x + lx, y + ly, 4.2 * sz, h, 0, wd, col);
            } else {
                const bx = x + lx + 0.6;
                const by = y + ly;
                line(b, &.{ .{ bx - 3.6, by - h + 3.4 * o }, .{ bx, by - h }, .{ bx, by + h } }, wd, col);
                line(b, &.{ .{ bx - 3.8, by + h }, .{ bx + 3.8, by + h } }, wd, col);
            }
        },
        .lashes => {
            const r = 5.4 * sz;
            ellipse(b, x + lx, y + ly, r, r * o, 0, col);
            if (!b.small and o > 0.6) circle(b, x + lx + r * 0.36, y + ly - r * 0.4 * o, r * 0.25, glint);
            const dirs = [3][2]f32{ .{ 0.96, -0.28 }, .{ 0.78, -0.62 }, .{ 0.42, -0.9 } };
            for (dirs) |dv| {
                const bx = x + side * dv[0] * r * 0.92;
                const by = y + dv[1] * r * 0.92 * o;
                line(b, &.{ .{ bx, by }, .{ bx + side * dv[0] * 3.3, by + dv[1] * 3.3 * @max(o, 0.4) } }, if (b.small) 2.2 else 1.4, col);
            }
        },
        else => {
            ellipse(b, x + lx, y + ly, 4.4 * sz, 4.4 * sz * o, 0, col);
        },
    }
}

fn brows(b: Brush, style: v.Eyes, brow: f32, ew: f32) void {
    const col = b.ink();
    const lift = eyeHalf(style) + 4;
    for ([_][2]f32{ eye_l, eye_r }, [_]f32{ -1, 1 }) |ctr, side| {
        const top = ctr[1] - lift;
        // Bravas: a ponta de dentro desce; tristes: a de dentro sobe.
        const inner_dy: f32 = if (brow < 0) 2.6 else -2.6;
        const outer_dy: f32 = if (brow < 0) -2.4 else 1.4;
        const outer_x = ctr[0] + side * 7.2;
        const inner_x = ctr[0] - side * 6;
        line(b, &.{ .{ outer_x, top + outer_dy }, .{ inner_x, top + inner_dy } }, ew * 0.72, col);
    }
}

/// A gota da lágrima com a ponta em (x, y).
fn tear(b: Brush, x: f32, y: f32) void {
    var pts: [18][2]f32 = undefined;
    var n = quad(.{ x, y }, .{ x - 2.5, y + 5 }, .{ x, y + 7.5 }, 8, &pts);
    var p2: [9][2]f32 = undefined;
    const m = quad(.{ x, y + 7.5 }, .{ x + 2.5, y + 5 }, .{ x, y }, 8, &p2);
    for (p2[1 .. m - 1]) |q| {
        pts[n] = q;
        n += 1;
    }
    fillConvex(b, pts[0..n], b.paint(drop_col));
}

/// O visor de robô: uma faixa escura atravessando os dois olhos, com as luzes dentro.
fn visor(b: Brush, e: v.Expr, open: f32, in: FaceIn) void {
    const ctr: [2]f32 = .{ 62, 52.5 };
    const half_len: f32 = 37;
    const half_h: f32 = if (b.small) 8.6 else 7.4;
    var pts: [30][2]f32 = undefined;
    var n: usize = 0;
    for (0..15) |i| {
        const a = -pi / 2.0 + pi * @as(f32, @floatFromInt(i)) / 14.0;
        pts[n] = rot2(.{ ctr[0] + half_len - half_h + @cos(a) * half_h, ctr[1] + @sin(a) * half_h }, ctr, tilt);
        n += 1;
    }
    for (0..15) |i| {
        const a = pi / 2.0 + pi * @as(f32, @floatFromInt(i)) / 14.0;
        pts[n] = rot2(.{ ctr[0] - half_len + half_h + @cos(a) * half_h, ctr[1] + @sin(a) * half_h }, ctr, tilt);
        n += 1;
    }
    const s = contas.outBack(std.math.clamp(in.reveal_eyes, 0, 1), 1.6);
    const vb = if (in.reveal_eyes < 1) b.at(b.m.around(ctr[0], ctr[1], Af.scale(s, 1))) else b;
    fill(vb, &pts, vb.paint(Rgba.hex(0x140F1E).alpha(0.97)));
    outline(vb, &pts, 1.2, vb.inkA(0.55));
    // O brilho do vidro em cima.
    line(vb, &.{ rot2(.{ ctr[0] - half_len + 8, ctr[1] - half_h + 2.2 }, ctr, tilt), rot2(.{ ctr[0] + 4, ctr[1] - half_h + 2.2 }, ctr, tilt) }, 1.2, vb.paint(white.alpha(0.18)));
    const angry = e.brow < 0;
    const glow = if (angry) mixRgb(vb.role(.accent), Rgba.hex(0xFF4A5A), 0.7) else vb.role(.accent);
    const gc = vb.paint(glow);
    const halo_c = vb.paint(glow.alpha(0.28));
    const lx = in.look[0] * 3;
    const ly = in.look[1] * 1.2;
    for ([_][2]f32{ eye_l, eye_r }, [_]f32{ -1, 1 }) |ec, side| {
        const p: [2]f32 = .{ ec[0] + lx, ec[1] - 0.3 + ly };
        if (in.xeyes) {
            xEye(vb, p, 3.6, 1.9, gc);
        } else if (e.spiral) {
            spiral(vb, p, 4.2, 1.5, gc);
        } else if (e.squeeze) {
            const q = if (side < 0) [3][2]f32{ .{ p[0] - 4, p[1] - 3.6 }, .{ p[0] + 3.6, p[1] }, .{ p[0] - 4, p[1] + 3.6 } } else [3][2]f32{ .{ p[0] + 4, p[1] - 3.6 }, .{ p[0] - 3.6, p[1] }, .{ p[0] + 4, p[1] + 3.6 } };
            line(vb, &q, 1.9, gc);
        } else if (open < 0.2 or (e.arc != 0 and open < 0.5)) {
            const arc = e.arc;
            var cp: [11][2]f32 = undefined;
            const m = if (arc > 0.05)
                quad(.{ p[0] - 4.6, p[1] + 1.8 }, .{ p[0], p[1] - 4.6 }, .{ p[0] + 4.6, p[1] + 1.8 }, 10, &cp)
            else if (arc < -0.05)
                quad(.{ p[0] - 4.2, p[1] - 1 }, .{ p[0], p[1] + 3.6 }, .{ p[0] + 4.2, p[1] - 1 }, 10, &cp)
            else
                quad(.{ p[0] - 4.6, p[1] + 0.6 }, .{ p[0], p[1] + 0.6 }, .{ p[0] + 4.6, p[1] + 0.6 }, 10, &cp);
            line(vb, cp[0..m], 1.8, if (arc == 0) vb.paint(glow.alpha(0.55)) else gc);
        } else {
            const rx = 4.8 * (1 + 0.25 * e.wide);
            const ry = (2.3 + 1.6 * e.wide) * open;
            const rot: f32 = tilt + (if (e.brow < 0) side * -0.32 else if (e.brow > 0) side * 0.3 else 0);
            ellipse(vb, p[0], p[1], rx + 2.2, ry + 2, rot, halo_c);
            ellipse(vb, p[0], p[1], rx, ry, rot, gc);
            ellipse(vb, p[0] - rx * 0.3, p[1] - ry * 0.3, rx * 0.35, ry * 0.3, rot, vb.paint(white.alpha(0.55)));
        }
    }
    if (e.tear and !in.xeyes) tear(b, 27, 60);
}

/// Um olho só, grande, no meio do rosto.
fn cyclops(b: Brush, e: v.Expr, open: f32, in: FaceIn) void {
    const ctr: [2]f32 = .{ 62, 51.5 };
    const s = contas.outBack(std.math.clamp(in.reveal_eyes, 0, 1), 2);
    const cb = if (in.reveal_eyes < 1) b.at(b.m.around(ctr[0], ctr[1], Af.scale(s, s))) else b;
    const ew: f32 = if (b.small) 7.6 else 5.4;
    const col = cb.ink();
    const r = 11.4 * (if (b.small) @as(f32, 1.1) else 1) * (1 + 0.12 * e.wide);
    if (in.xeyes) return xEye(cb, ctr, 9, ew * 0.9, col);
    if (e.spiral) return spiral(cb, ctr, 11, ew * 0.6, col);
    if (e.squeeze) {
        line(cb, &.{ .{ ctr[0] - 12, ctr[1] - 7 }, .{ ctr[0] - 2, ctr[1] }, .{ ctr[0] - 12, ctr[1] + 7 } }, ew * 0.9, col);
        line(cb, &.{ .{ ctr[0] + 12, ctr[1] - 7 }, .{ ctr[0] + 2, ctr[1] }, .{ ctr[0] + 12, ctr[1] + 7 } }, ew * 0.9, col);
    } else if (open < 0.2) {
        var pts: [15][2]f32 = undefined;
        const arc = e.arc;
        const n = if (arc > 0.05)
            quad(.{ ctr[0] - 11, ctr[1] + 3 }, .{ ctr[0], ctr[1] - 9 * arc }, .{ ctr[0] + 11, ctr[1] + 3 }, 14, &pts)
        else if (arc < -0.05)
            quad(.{ ctr[0] - 10, ctr[1] - 1 }, .{ ctr[0], ctr[1] + 8 * -arc }, .{ ctr[0] + 10, ctr[1] - 1 }, 14, &pts)
        else
            quad(.{ ctr[0] - 11, ctr[1] + 1.5 }, .{ ctr[0], ctr[1] + 5.5 }, .{ ctr[0] + 11, ctr[1] + 1.5 }, 14, &pts);
        line(cb, pts[0..n], ew * 0.85, col);
    } else {
        ellipse(cb, ctr[0], ctr[1], r, r * open, 0, cb.paint(cream));
        const lx = std.math.clamp(in.look[0], -1, 1) * r * 0.32;
        const ly = std.math.clamp(in.look[1], -1, 1) * r * 0.22;
        const iris = mixRgb(cb.role(.accent), cb.role(.ink), 0.18);
        const ir = r * 0.55 * (1 - 0.15 * e.wide);
        ellipse(cb, ctr[0] + lx, ctr[1] + ly * open, ir, ir * open, 0, cb.paint(iris));
        ellipse(cb, ctr[0] + lx, ctr[1] + ly * open, ir * 0.48, ir * 0.48 * open, 0, col);
        if (open > 0.5) circle(cb, ctr[0] + lx - ir * 0.42, ctr[1] + (ly - ir * 0.45) * open, ir * 0.24, cb.paint(white.alpha(0.95)));
        ring(cb, ctr[0], ctr[1], r, r * open, 0, if (b.small) 2.6 else 1.7, col);
    }
    if (e.brow != 0) {
        const top = ctr[1] - r - 4.5;
        const dy: f32 = if (e.brow < 0) 3 else -3;
        line(cb, &.{ .{ ctr[0] - 12, top - dy * 0.7 }, .{ ctr[0], top + dy }, .{ ctr[0] + 12, top - dy * 0.7 } }, ew * 0.72, col);
    }
    if (e.tear) tear(cb, ctr[0] - r * 0.7, ctr[1] + r * 0.75);
}

// --- Bocas -------------------------------------------------------------------------------

/// A boca de um estilo (menos o sorriso de sempre, que é o de mascote_terminal).
pub fn mouth(b0: Brush, style: v.Mouth, in: FaceIn) void {
    if (in.reveal_mouth <= 0.01) return;
    const ctr: [2]f32 = .{ 63.5, 70 };
    const s = contas.outBack(std.math.clamp(in.reveal_mouth, 0, 1), 1.8);
    const b = if (in.reveal_mouth < 1) b0.at(b0.m.around(ctr[0], ctr[1], Af.scale(s, s))) else b0;
    if (in.dots) {
        for (0..3) |i| {
            const fi: f32 = @floatFromInt(i);
            const hop = @max(0, @sin((in.dots_t * 1.6 - fi * 0.17) * tau)) * 3.5;
            circle(b, 55 + fi * 8.5, 71 - hop, if (b.small) 3.4 else 2.5, b.ink());
        }
        return;
    }
    var e = v.exprOf(in.face);
    if (in.xeyes) {
        e.curve = -0.3;
        e.wobble = 1;
        e.gape = 0;
    }
    // Comendo ou bocejando: a boca redonda aberta de sempre, em qualquer estilo.
    if (in.mouth_open > 0.01) return openRound(b, in.mouth_open);
    const mw: f32 = if (b.small) 4.2 else 2.6;
    const col = b.ink();
    const g = e.gape;
    const cv = e.curve;
    switch (style) {
        .cursor => {
            if (g > 0.15) return gaped(b, e);
            if (e.wobble > 0) return wavy(b, e.wobble, 0, mw);
            const ew: f32 = if (b.small) 6.4 else 4.6;
            const len = 13 * std.math.clamp(in.cursor_k, 0, 1);
            if (!in.cursor_on or len < 0.5) return;
            const y: f32 = if (cv < -0.3) 72 else 70.5;
            const x0: f32 = if (cv > 1.1) 55.5 else 57;
            line(b, &.{ .{ x0, y }, .{ x0 + (if (cv > 1.1) len * 1.25 else len), y } }, ew, col);
        },
        .cat, .uwu => {
            if (g > 0.15 and e.round) return openRound(b, g);
            if (e.wobble > 0 and g <= 0.15) return wavy(b, e.wobble, 0, mw);
            const flip: f32 = if (cv < -0.2) -1 else 1;
            const depth: f32 = 3.4 * flip * (if (cv > 1.1) @as(f32, 1.2) else 1);
            if (g > 0.15) {
                // Aberta: um triângulo redondo por baixo do "ω".
                var op: [14][2]f32 = undefined;
                const gg = std.math.clamp(g, 0.3, 1);
                for (0..12) |i| {
                    const a = pi * @as(f32, @floatFromInt(i)) / 11.0;
                    op[i + 1] = .{ 63.5 + @cos(a) * 5.4, 70.4 + @sin(a) * 6.5 * gg };
                }
                fillConvex(b, op[1..13], col);
                ellipse(b, 63.5, 70.4 + 4.6 * gg, 3.2, 1.8 * gg, 0, b.paint(tongue_col));
            }
            var pts: [25][2]f32 = undefined;
            if (style == .cat) {
                for (0..25) |i| {
                    const t = @as(f32, @floatFromInt(i)) / 24.0;
                    const xx = 53 + 21 * t;
                    const hump = @abs(@sin(t * tau));
                    pts[i] = .{ xx, 68.8 + depth * 1.18 * hump - (1 - flip) * 1.8 };
                }
                line(b, &pts, mw, col);
            } else {
                const y0: f32 = if (flip > 0) 68.6 else 72.2;
                const y1: f32 = if (flip > 0) 72.4 else 68.6;
                line(b, &.{ .{ 53.5, y0 }, .{ 58.5, y1 + 0.4 * flip }, .{ 63.5, y0 + 0.6 * flip }, .{ 68.5, y1 + 0.4 * flip }, .{ 73.5, y0 } }, mw, col);
            }
        },
        .tongue => {
            if (g > 0.15 and e.round) return openRound(b, g);
            if (g > 0.15) {
                _ = openD(b, g, cv);
                tongueOut(b, 66.5, 72 + 6 * g, 1.2);
                return;
            }
            tongueOut(b, 67.5, 70.1 + smileY(cv, 67.5) - 70, 1.3);
            smileLine(b, cv, e.wobble, mw, col);
        },
        .fang, .vampire => {
            if (g > 0.15 and e.round) return openRound(b, g);
            if (g > 0.15) {
                const top = openD(b, g, cv);
                fangAt(b, 57.5, top, 1.4);
                if (style == .vampire) fangAt(b, 69.5, top - 0.5, 1.4);
                return;
            }
            smileLine(b, cv, e.wobble, mw, col);
            const fy = smileY(cv, 57.5);
            fangAt(b, 57.5, fy + 0.1, 1.35);
            if (style == .vampire) fangAt(b, 69.5, smileY(cv, 69.5) + 0.1, 1.35);
        },
        .open => {
            if (e.round and g > 0.15) return openRound(b, g);
            if (e.wobble > 0) {
                _ = openD(b, 0.42, 0.2);
                return;
            }
            _ = openD(b, @max(g, 0.82), cv);
        },
        .o => {
            const gg = std.math.clamp(g, 0, 1);
            const rx = 2.6 + 3.2 * gg;
            const ry = 3.1 + 4.2 * gg;
            const y: f32 = if (cv < -0.3) 72 else 71;
            if (gg > 0.5) {
                ellipse(b, 63.5, y, rx, ry, 0, col);
                ellipse(b, 63.5, y + ry * 0.45, rx * 0.6, ry * 0.35, 0, b.paint(tongue_col));
            } else ring(b, 63.5, y, rx, ry, 0, mw, col);
        },
        .flat => {
            if (g > 0.15) return gaped(b, e);
            if (e.wobble > 0) return wavy(b, e.wobble, 0, mw);
            const end: f32 = if (cv > 1.1) -1.6 else if (cv < -0.3) 1.8 else 0;
            line(b, &.{ .{ 55, 70.6 + end }, .{ 57.5, 70.6 }, .{ 70, 70.1 }, .{ 72.5, 70.1 + end } }, mw, col);
        },
        .wavy => {
            if (g > 0.15) return gaped(b, e);
            wavy(b, @max(e.wobble, 1), std.math.clamp(cv, -1, 1.3), mw);
        },
        .smirk => {
            if (g > 0.15) return gaped(b, e);
            if (e.wobble > 0) return wavy(b, e.wobble, 0, mw);
            var pts: [13][2]f32 = undefined;
            const n = if (cv >= -0.2)
                quad(.{ 64, 71.2 }, .{ 70.5, 71.4 }, .{ 73.8, 65.6 - (if (cv > 1.1) @as(f32, 1) else 0) }, 10, pts[2..])
            else
                quad(.{ 64, 70 }, .{ 70.5, 69.8 }, .{ 73.5, 74 }, 10, pts[2..]);
            pts[0] = if (cv >= -0.2) .{ 55, 71 } else .{ 55, 69.6 };
            pts[1] = if (cv >= -0.2) .{ 60, 71.2 } else .{ 60, 70 };
            line(b, pts[0 .. n + 2], mw, col);
        },
        .grin => grin(b, e, mw),
        .pout => {
            if (g > 0.15) return openRound(b, @max(g, 0.3) * 0.6);
            const cx: f32 = 63.6;
            var up: [9][2]f32 = undefined;
            var dn: [9][2]f32 = undefined;
            const n1 = quad(.{ cx - 2, 65.6 }, .{ cx + 7, 66 }, .{ cx - 0.6, 70.4 }, 8, &up);
            const n2 = quad(.{ cx - 0.6, 70.4 }, .{ cx + 7, 74.8 }, .{ cx - 2, 75.2 }, 8, &dn);
            line(b, up[0..n1], mw, col);
            line(b, dn[0..n2], mw, col);
        },
        .whistle => {
            if (g > 0.15) return openRound(b, g);
            ring(b, 67, 71.2, 2.5, 2.7, 0, mw, col);
            circle(b, 67, 71.2, 1.1, b.inkA(0.85));
            if (!b.small and in.face == .prompt) note(b, 75.5, 63.5 - 1.2 * @sin(b.t * 2.2));
        },
        .bunny => {
            if (g > 0.15 and e.round) return openRound(b, g);
            if (g > 0.15) {
                const top = openD(b, g, cv);
                teeth(b, top + 0.2);
                return;
            }
            var pts: [13][2]f32 = undefined;
            const cy = 69 + 4 * cv;
            const n = quad(.{ 56.5, 69 }, .{ 63.5, cy }, .{ 70.5, 68.6 }, 12, &pts);
            teeth(b, 69 + (cy - 69) * 0.5 - 0.2);
            line(b, pts[0..n], mw, col);
        },
        .smile, .custom => smileLine(b, cv, e.wobble, mw, col),
    }
}

/// O y da curva do sorriso (`cv`) em `x`.
fn smileY(cv: f32, x: f32) f32 {
    const t = std.math.clamp((x - 53) / 21.5, 0, 1);
    const u = 1 - t;
    const y0: f32 = 69;
    const y1: f32 = 68.5;
    const cy = 68.8 + 6.5 * cv;
    return u * u * y0 + 2 * u * t * cy + t * t * y1;
}

fn smileLine(b: Brush, cv: f32, wobble: f32, mw: f32, col: u32) void {
    if (wobble > 0) return wavy(b, wobble, 0, mw);
    var pts: [15][2]f32 = undefined;
    const n = quad(.{ 53, 69 }, .{ 63.5, 68.8 + 6.5 * cv }, .{ 74.5, 68.5 }, 14, &pts);
    line(b, pts[0..n], mw, col);
}

fn wavy(b: Brush, wob: f32, bias: f32, mw: f32) void {
    var pts: [17][2]f32 = undefined;
    for (0..17) |i| {
        const t = @as(f32, @floatFromInt(i)) / 16.0;
        const ends = (t - 0.5) * (t - 0.5) * 4;
        pts[i] = .{ 53.5 + 21 * t, 71 + @sin(t * tau * 2) * 1.6 * @min(wob, 1.3) - ends * bias * 1.4 };
    }
    line(b, &pts, mw, b.ink());
}

/// Aberta do jeito que a cara pede: redonda (susto, sono) ou em "D" (rindo).
fn gaped(b: Brush, e: v.Expr) void {
    if (e.round) openRound(b, e.gape) else _ = openD(b, e.gape, e.curve);
}

/// A boca redonda aberta (comendo, susto, bocejo).
fn openRound(b: Brush, g: f32) void {
    const gg = std.math.clamp(g, 0, 1.2);
    if (gg < 0.5) {
        // Pouco aberta (sono, susto): o "o" de contorno das caras de sempre.
        const mw: f32 = if (b.small) 4.2 else 2.6;
        ring(b, 63.5, 70.5 + gg * 2, 2.4 + 1.6 * gg, 2.8 + 2.4 * gg, 0, mw, b.ink());
        return;
    }
    ellipse(b, 63.5, 70, 4 + 5 * gg, 2 + 7 * gg, 0, b.ink());
    ellipse(b, 63.5, 72 + 3 * gg, 2.4 + 3 * gg, 1 + 2.6 * gg, 0, b.paint(tongue_col));
}

/// A boca em "D" (rindo); `cv` negativo vira para baixo. Devolve o y de cima (onde
/// ficam os dentinhos).
fn openD(b: Brush, g: f32, cv: f32) f32 {
    const gg = std.math.clamp(g, 0.3, 1.1);
    var pts: [18][2]f32 = undefined;
    if (cv < -0.2) {
        const n = quad(.{ 75, 74 }, .{ 63.5, 74 - 15 * gg }, .{ 52, 74.5 }, 16, &pts);
        fill(b, pts[0..n], b.ink());
        return 74 - 7 * gg;
    }
    const top: f32 = 67;
    const n = quad(.{ 75, top - 0.5 }, .{ 63.5, top + 17 * gg }, .{ 52, top }, 16, &pts);
    fill(b, pts[0..n], b.ink());
    // A língua: a parte de baixo do "D".
    var tg: [24][2]f32 = undefined;
    var m: usize = 0;
    const cut = top + 8.2 * gg;
    for (pts[0..n]) |q| if (q[1] >= cut) {
        tg[m] = q;
        m += 1;
    };
    if (m >= 3) {
        const l = tg[m - 1];
        const r = tg[0];
        tg[m] = .{ (l[0] + r[0]) / 2 - 2, cut - 1.6 };
        tg[m + 1] = .{ (l[0] + r[0]) / 2 + 2, cut - 1.6 };
        fill(b, tg[0 .. m + 2], b.paint(tongue_col));
    }
    return top;
}

fn tongueOut(b: Brush, x: f32, y: f32, s: f32) void {
    var pts: [16][2]f32 = undefined;
    pts[0] = .{ x - 3.6 * s, y };
    for (0..13) |i| {
        const a = pi * @as(f32, @floatFromInt(i)) / 12.0;
        pts[i + 1] = .{ x + @cos(a) * 3.6 * s, y + 3.4 * s + @sin(a) * 3.6 * s };
    }
    pts[14] = .{ x + 3.6 * s, y };
    var poly: [16][2]f32 = undefined;
    poly[0] = .{ x + 3.6 * s, y - 0.6 };
    for (pts[1..14], 0..) |q, i| poly[i + 1] = q;
    poly[14] = .{ x - 3.6 * s, y - 0.6 };
    fill(b, poly[0..15], b.paint(tongue_col));
    line(b, &.{ .{ x, y + 0.6 }, .{ x, y + 4.4 * s } }, if (b.small) 1.6 else 0.9, b.paint(Rgba.hex(0xD94A7A)));
    outline(b, poly[0..15], if (b.small) 1.4 else 0.8, b.inkA(0.7));
}

fn fangAt(b: Brush, x: f32, y: f32, s: f32) void {
    const pts = [3][2]f32{ .{ x - 1.9 * s, y }, .{ x + 1.9 * s, y }, .{ x + 0.2 * s, y + 4.4 * s } };
    fillConvex(b, &pts, b.paint(white));
    outline(b, &pts, if (b.small) 1.2 else 0.75, b.inkA(0.85));
}

fn teeth(b: Brush, y: f32) void {
    for ([_]f32{ 60.4, 63.7 }) |x| {
        var pts: [12][2]f32 = undefined;
        const n = roundRect(x, y, 3.2, 4.6, 1.1, 0, &pts);
        fillConvex(b, pts[0..n], b.paint(white));
        outline(b, pts[0..n], if (b.small) 1.2 else 0.75, b.inkA(0.85));
    }
}

/// Dentes: o sorriso largo, a careta de nervoso e os dentes separados do susto.
fn grin(b: Brush, e: v.Expr, mw: f32) void {
    _ = mw;
    const col = b.ink();
    const lw: f32 = if (b.small) 1.8 else 1.2;
    const teeth_c = b.paint(Rgba.hex(0xFBF8FF));
    if (e.round and e.gape > 0.15 and e.gape < 0.3) {
        // Dormindo: os dentes guardados, só o sorriso.
        smileLine(b, 0.35, 0, if (b.small) 4.2 else 2.6, col);
        return;
    }
    if (e.gape > 0.15 and !e.round) {
        // Rindo: a arcada de cima e a boca escura.
        const gg = std.math.clamp(e.gape, 0.3, 1);
        _ = openD(b, gg, 1);
        rrect(b, 54.5, 67, 19, 3.2, 1.2, 0, teeth_c);
        return;
    }
    if (e.wobble > 0 or e.curve < -0.2 or e.round) {
        // Careta: os dentes num retângulo.
        var pts: [24][2]f32 = undefined;
        const n = roundRect(53.5, 66.8, 20, 7.6, 2.4, 0, &pts);
        fillConvex(b, pts[0..n], teeth_c);
        line(b, &.{ .{ 54.5, 70.6 }, .{ 72.5, 70.6 } }, lw * 0.8, col);
        for ([_]f32{ 58.5, 63.5, 68.5 }) |x| line(b, &.{ .{ x, 67.4 }, .{ x, 73.8 } }, lw * 0.8, col);
        outline(b, pts[0..n], lw, col);
        return;
    }
    var pts: [18][2]f32 = undefined;
    const deep: f32 = if (e.curve > 1.1) 10.5 else 9;
    const n = quad(.{ 74.5, 66.6 }, .{ 63.5, 66.8 + deep * 1.55 }, .{ 52.5, 67 }, 16, &pts);
    fill(b, pts[0..n], teeth_c);
    line(b, &.{ .{ 53.5, 70.6 }, .{ 73.5, 70.4 } }, lw * 0.8, col);
    for ([_]f32{ 58, 63.5, 69 }) |x| {
        const bottom = 67 + (deep * 1.55) * 0.5 * (1 - std.math.pow(f32, (x - 63.5) / 11, 2)) - 0.6;
        line(b, &.{ .{ x, 67.2 }, .{ x, bottom } }, lw * 0.8, col);
    }
    outline(b, pts[0..n], lw, col);
}

/// Uma notinha musical (o assobio).
fn note(b: Brush, x: f32, y: f32) void {
    const col = b.inkA(0.8);
    ellipse(b, x, y + 7, 2.3, 1.7, -0.45, col);
    line(b, &.{ .{ x + 2, y + 6.6 }, .{ x + 2, y - 1 } }, 1.1, col);
    line(b, &.{ .{ x + 2, y - 1 }, .{ x + 5, y + 1.6 } }, 1.1, col);
}

// --- Acessórios -------------------------------------------------------------------------

/// Os acessórios do rosto (bochechas, sardas, bigode, curativo e os óculos) em `face`,
/// e os do corpo (pescoço e brinco) em `body`.
pub fn accessories(body: Brush, face: Brush, l: *const v.Look, show_face: bool) void {
    if (l.acc == 0) return;
    if (show_face) {
        if (l.has(.blush)) {
            const bc = Rgba.hex(0xFF6FAE);
            for ([_][2]f32{ .{ 28.5, 63.5 }, .{ 98, 68 } }) |q| {
                ellipse(face, q[0], q[1], 8.6, 5, 0, face.paint(bc.alpha(0.16)));
                ellipse(face, q[0], q[1], 6.6, 3.6, 0, face.paint(bc.alpha(0.4)));
            }
        }
        if (l.has(.freckles)) {
            const fr: f32 = if (face.small) 1.9 else 1.3;
            for ([_][2]f32{ .{ 25, 61.4 }, .{ 29.4, 64.2 }, .{ 33.4, 61 }, .{ 27.8, 58.6 }, .{ 94, 65.8 }, .{ 98, 68.6 }, .{ 102, 65.4 }, .{ 99.4, 62.6 } }) |q| circle(face, q[0], q[1], fr, face.inkA(0.5));
        }
        if (l.has(.bandaid)) bandaid(face, 101, 37.5);
        if (l.has(.mustache)) mustache(face);
        var spots: [2][2]f32 = undefined;
        const ns = eyeSpots(l.eyes, &spots);
        if (l.has(.glasses)) glasses(face, spots[0..ns]);
        if (l.has(.shades)) shades(face, spots[0..ns]);
        if (l.has(.monocle)) monocle(face, spots[ns - 1]);
        if (l.has(.eyepatch)) eyepatch(face, spots[0]);
    }
    if (l.has(.earring)) earring(body);
    if (l.has(.scarf)) scarf(body);
    if (l.has(.bowtie)) bowtie(body);
    if (l.has(.bandana)) bandana(body);
}

fn bandaid(b: Brush, x: f32, y: f32) void {
    const rot: f32 = -0.6;
    rrect(b, x - 8, y - 3, 16, 6, 3, rot, b.paint(Rgba.hex(0xF0C69C)));
    rrect(b, x - 2.8, y - 3, 5.6, 6, 0.8, rot, b.paint(Rgba.hex(0xDDA878)));
    if (!b.small) for ([_][2]f32{ .{ -1.1, -1.2 }, .{ 1.1, -1.2 }, .{ -1.1, 1.2 }, .{ 1.1, 1.2 } }) |o| {
        const q = rot2(.{ x + o[0], y + o[1] }, .{ x, y }, rot);
        circle(b, q[0], q[1], 0.42, b.paint(Rgba.hex(0xB9855A)));
    };
}

fn mustache(b: Brush) void {
    const col = b.ink();
    // Um bigode de guidão: duas metades cheias que afinam para as pontas, e cada ponta
    // enrola para cima.
    const half = [_][2]f32{ .{ 0.5, 62.2 }, .{ 3.5, 60.8 }, .{ 7.5, 60.4 }, .{ 11.5, 61.2 }, .{ 15, 62.6 }, .{ 17, 63.6 }, .{ 15.6, 65.2 }, .{ 12.4, 66.6 }, .{ 8.4, 67.8 }, .{ 4.2, 68 }, .{ 1, 67.2 } };
    const curl = [_][2]f32{ .{ 16.4, 63.8 }, .{ 19.2, 62.4 }, .{ 19.8, 59.8 }, .{ 18.2, 58.2 }, .{ 16.4, 59 } };
    const wd: f32 = if (b.small) 3 else 2.3;
    for ([_]f32{ -1, 1 }) |side| {
        var pts: [half.len][2]f32 = undefined;
        for (half, 0..) |q, i| pts[i] = .{ 63.5 + side * q[0], q[1] };
        fill(b, &pts, col);
        var cp: [curl.len][2]f32 = undefined;
        for (curl, 0..) |q, i| cp[i] = .{ 63.5 + side * q[0], q[1] };
        line(b, &cp, wd, col);
    }
    circle(b, 63.5, 64.2, 2.6, col);
}

fn glasses(b: Brush, spots: []const [2]f32) void {
    const frame = b.ink();
    const wd: f32 = if (b.small) 3 else 2.1;
    const glare = b.paint(white.alpha(0.42));
    const lens = b.paint(white.alpha(0.1));
    if (spots.len == 1) {
        const p = spots[0];
        circle(b, p[0], p[1], 15, lens);
        ring(b, p[0], p[1], 15, 15, 0, wd, frame);
        line(b, &.{ .{ p[0] - 15, p[1] - 1 }, .{ 12, p[1] - 5 } }, wd, frame);
        line(b, &.{ .{ p[0] + 15, p[1] + 1 }, .{ 114, p[1] - 3 } }, wd, frame);
        line(b, &.{ .{ p[0] - 8, p[1] - 7 }, .{ p[0] - 3, p[1] - 11 } }, 1.4, glare);
        return;
    }
    const l = spots[0];
    const r = spots[1];
    for ([_][2]f32{ .{ l[0], l[1] + 1 }, .{ r[0], r[1] + 1 } }) |p| {
        circle(b, p[0], p[1], 10.6, lens);
        ring(b, p[0], p[1], 10.6, 10.6, 0, wd, frame);
        line(b, &.{ .{ p[0] - 6.2, p[1] - 4.4 }, .{ p[0] - 2.6, p[1] - 7.4 } }, 1.3, glare);
    }
    var br: [9][2]f32 = undefined;
    const n = quad(.{ l[0] + 10.4, l[1] + 0.6 }, .{ 62, l[1] - 3 }, .{ r[0] - 10.4, r[1] - 0.2 }, 8, &br);
    line(b, br[0..n], wd, frame);
    line(b, &.{ .{ l[0] - 10.6, l[1] }, .{ 16, l[1] - 3.4 } }, wd, frame);
    line(b, &.{ .{ r[0] + 10.6, r[1] }, .{ 112, r[1] - 3.4 } }, wd, frame);
}

fn shades(b: Brush, spots: []const [2]f32) void {
    const frame = b.ink();
    const lens_c = b.paint(Rgba.hex(0x140F1E).alpha(0.95));
    const glare = b.paint(white.alpha(0.3));
    const wd: f32 = if (b.small) 2.4 else 1.6;
    if (spots.len == 1) {
        const p = spots[0];
        var pts: [24][2]f32 = undefined;
        const n = roundRect(p[0] - 30, p[1] - 8, 60, 16, 7, tilt * 0.6, &pts);
        fill(b, pts[0..n], lens_c);
        outline(b, pts[0..n], wd, frame);
        line(b, &.{ .{ p[0] - 20, p[1] + 4 }, .{ p[0] - 13, p[1] - 5 } }, 1.6, glare);
        return;
    }
    for (spots, [_]f32{ -1, 1 }) |p, side| {
        // Lente de cima reta e de baixo redonda, inclinada com o rosto.
        var pts: [20][2]f32 = undefined;
        var n: usize = 0;
        pts[n] = rot2(.{ p[0] - 12, p[1] - 6.5 }, p, tilt);
        n += 1;
        pts[n] = rot2(.{ p[0] + 12, p[1] - 6.5 }, p, tilt);
        n += 1;
        for (0..12) |i| {
            const a = @as(f32, @floatFromInt(i)) / 11.0 * pi;
            pts[n] = rot2(.{ p[0] + @cos(a) * 11.5, p[1] - 1 + @sin(a) * 8.6 }, p, tilt);
            n += 1;
        }
        fill(b, pts[0..n], lens_c);
        outline(b, pts[0..n], wd, frame);
        line(b, &.{ rot2(.{ p[0] - 6.5, p[1] + 3.5 }, p, tilt), rot2(.{ p[0] - 1.5, p[1] - 4.5 }, p, tilt) }, 1.5, glare);
        line(b, &.{ rot2(.{ p[0] - 2, p[1] + 4.5 }, p, tilt), rot2(.{ p[0] + 1, p[1] - 0.5 }, p, tilt) }, 1, glare);
        _ = side;
    }
    const l = spots[0];
    const r = spots[1];
    line(b, &.{ rot2(.{ l[0] + 12, l[1] - 5.5 }, l, tilt), rot2(.{ r[0] - 12, r[1] - 5.5 }, r, tilt) }, wd * 1.3, frame);
    line(b, &.{ rot2(.{ l[0] - 12, l[1] - 6 }, l, tilt), .{ 15, l[1] - 8 } }, wd, frame);
    line(b, &.{ rot2(.{ r[0] + 12, r[1] - 6 }, r, tilt), .{ 113, r[1] - 6 } }, wd, frame);
}

fn monocle(b: Brush, p: [2]f32) void {
    const g = b.paint(Rgba.hex(0xE9B949));
    const r: f32 = if (p[0] < 70) 15 else 10.5;
    circle(b, p[0], p[1] + 1, r, b.paint(white.alpha(0.13)));
    ring(b, p[0], p[1] + 1, r, r, 0, if (b.small) 2.8 else 1.9, g);
    line(b, &.{ .{ p[0] - r * 0.55, p[1] - r * 0.35 }, .{ p[0] - r * 0.22, p[1] - r * 0.65 } }, 1.3, b.paint(white.alpha(0.45)));
    var ch: [9][2]f32 = undefined;
    const n = quad(.{ p[0] + r * 0.7, p[1] + r * 0.8 }, .{ p[0] + r + 2, p[1] + r + 14 }, .{ p[0] + r + 9, p[1] + r + 16 }, 8, &ch);
    line(b, ch[0..n], if (b.small) 1.6 else 0.9, g);
}

fn eyepatch(b: Brush, p: [2]f32) void {
    const dark = b.paint(Rgba.hex(0x17121F));
    const strap = b.inkA(0.9);
    const wd: f32 = if (b.small) 3 else 2.2;
    line(b, &.{ .{ p[0] + 4, p[1] - 6 }, .{ 70, 22 }, .{ 106, 11 } }, wd, strap);
    line(b, &.{ .{ p[0] - 8, p[1] - 1 }, .{ 6, p[1] - 6 } }, wd, strap);
    var pts: [24][2]f32 = undefined;
    for (0..24) |i| {
        const a = @as(f32, @floatFromInt(i)) / 24.0 * tau;
        const rx: f32 = if (@cos(a) > 0) 9.6 else 8.8;
        pts[i] = .{ p[0] + @cos(a) * rx, p[1] + 0.8 + @sin(a) * (if (@sin(a) > 0) @as(f32, 8.6) else 7.4) };
    }
    fillConvex(b, &pts, dark);
    outline(b, &pts, 1.1, b.inkA(0.5));
}

fn earring(b: Brush) void {
    const g = b.paint(Rgba.hex(0xF2C04A));
    circle(b, 120.6, 33, 2.1, g);
    ring(b, 120.6, 40, 4.6, 5.4, 0, if (b.small) 2.8 else 1.9, g);
    circle(b, 120.6, 45.4, 1.8, b.paint(b.role(.accent)));
    if (!b.small) circle(b, 119.2, 36.4, 0.8, b.paint(white.alpha(0.85)));
}

fn bowtie(b: Brush) void {
    const base = b.role(.accent);
    const main = b.paint(base);
    const dark = b.paint(mixRgb(base, Rgba.black, 0.3));
    const left = [_][2]f32{ .{ 61.5, 86.4 }, .{ 50.4, 79.4 }, .{ 48.4, 86.6 }, .{ 50.4, 93.6 } };
    const right = [_][2]f32{ .{ 65.5, 86.4 }, .{ 76.6, 79.4 }, .{ 78.6, 86.6 }, .{ 76.6, 93.6 } };
    fill(b, &left, main);
    fill(b, &right, main);
    line(b, &.{ .{ 54, 83.4 }, .{ 58.6, 86.4 }, .{ 54, 89.6 } }, 0.9, dark);
    line(b, &.{ .{ 73, 83.4 }, .{ 68.4, 86.4 }, .{ 73, 89.6 } }, 0.9, dark);
    rrect(b, 59.8, 82.6, 7.4, 7.6, 2, 0, dark);
    outline(b, &left, 0.8, dark);
    outline(b, &right, 0.8, dark);
}

fn scarf(b: Brush) void {
    const base = mixRgb(b.role(.accent), b.role(.ink), 0.12);
    const main = b.paint(base);
    const stripe_c = b.paint(mixRgb(b.role(.tufts), white, 0.35));
    const shade = b.paint(mixRgb(base, Rgba.black, 0.22));
    const deep = b.paint(mixRgb(base, Rgba.black, 0.42));
    // As duas pontas penduradas do nó, por baixo da volta.
    const tails = [2][4][2]f32{
        .{ .{ 19, 86 }, .{ 32, 87.5 }, .{ 30, 106 }, .{ 16, 104.5 } },
        .{ .{ 29, 86 }, .{ 41, 85 }, .{ 44, 102.5 }, .{ 32.5, 104 } },
    };
    for (tails, 0..) |tl, ti| {
        fill(b, &tl, if (ti == 0) shade else main);
        for ([_]f32{ 0.45, 0.72 }) |f| {
            const l0: [2]f32 = .{ tl[0][0] + (tl[3][0] - tl[0][0]) * f, tl[0][1] + (tl[3][1] - tl[0][1]) * f };
            const r0: [2]f32 = .{ tl[1][0] + (tl[2][0] - tl[1][0]) * f, tl[1][1] + (tl[2][1] - tl[1][1]) * f };
            line(b, &.{ l0, r0 }, 2.2, stripe_c);
        }
        for (0..4) |i| {
            const f = (@as(f32, @floatFromInt(i)) + 0.5) / 4.0;
            const x = tl[3][0] + (tl[2][0] - tl[3][0]) * f;
            const y = tl[3][1] + (tl[2][1] - tl[3][1]) * f;
            line(b, &.{ .{ x, y }, .{ x, y + 2.6 } }, if (b.small) 1.4 else 0.9, deep);
        }
    }
    // A volta em torno do queixo, com listras de lado a lado.
    var top: [17][2]f32 = undefined;
    var bot: [17][2]f32 = undefined;
    const n1 = quad(.{ -1.5, 68.5 }, .{ 63.5, 86 }, .{ 128.5, 68.5 }, 16, &top);
    const n2 = quad(.{ 0.5, 85 }, .{ 63.5, 103 }, .{ 126.5, 85 }, 16, &bot);
    var band: [34][2]f32 = undefined;
    for (top[0..n1], 0..) |q, i| band[i] = q;
    for (0..n2) |i| band[n1 + i] = bot[n2 - 1 - i];
    fill(b, band[0 .. n1 + n2], main);
    // O tricô: duas linhas finas ao longo e as listras largas de través.
    var knit: [17][2]f32 = undefined;
    for ([_]f32{ 0.36, 0.68 }) |f| {
        for (0..n1) |i| knit[i] = .{ top[i][0] + (bot[i][0] - top[i][0]) * f, top[i][1] + (bot[i][1] - top[i][1]) * f };
        line(b, knit[0..n1], if (b.small) 1.2 else 0.8, shade);
    }
    for ([_]usize{ 2, 4, 12, 14 }) |i| line(b, &.{ .{ top[i][0], top[i][1] + 0.8 }, .{ bot[i][0], bot[i][1] - 0.8 } }, 3.2, stripe_c);
    // O nó.
    ellipse(b, 30, 87, 8.4, 6.8, 0.25, shade);
    ellipse(b, 28.6, 85.6, 4.4, 2.8, 0.25, b.paint(mixRgb(base, white, 0.2)));
}

fn bandana(b: Brush) void {
    const red = Rgba.hex(0xE04848);
    const main = b.paint(red);
    const dark = b.paint(Rgba.hex(0xB12F35));
    var top: [13][2]f32 = undefined;
    const n = quad(.{ 30, 77 }, .{ 63.5, 88 }, .{ 97, 77 }, 12, &top);
    var poly: [16][2]f32 = undefined;
    for (top[0..n], 0..) |q, i| poly[i] = q;
    poly[n] = .{ 63.5, 100 };
    fill(b, poly[0 .. n + 1], main);
    line(b, top[0..n], 2.2, dark);
    for ([_][2]f32{ .{ 50, 86 }, .{ 58, 90.5 }, .{ 66, 87.4 }, .{ 74, 85.2 }, .{ 62.5, 95 }, .{ 70.5, 91 }, .{ 54.5, 92 } }) |q| circle(b, q[0], q[1], if (b.small) 1.2 else 0.85, b.paint(white.alpha(0.85)));
    outline(b, poly[0 .. n + 1], 0.8, dark);
}

// --- Chapéus -------------------------------------------------------------------------------

/// O chapéu na cabeça (`b` com a transformação do corpo).
pub fn hat(b: Brush, h: v.Hat) void {
    switch (h) {
        .none => {},
        .santa => santa(b),
        .witch => witch(b),
        .party => party(b),
        .crown => crown(b),
        .tophat => tophat(b),
        .beanie => beanie(b),
        .cap => cap(b),
        .cowboy => cowboy(b),
        .chef => chef(b),
        .halo => halo(b),
        .horns => horns(b),
        .flowers => flowers(b),
        .viking => viking(b),
        .wizard => wizard(b),
        .bow => bow(b),
        .propeller => propeller(b),
        .beret => beret(b),
        .tiara => tiara(b),
        .pirate => pirate(b),
        .helmet => helmet(b),
        .sprout => sprout(b),
        .antenna => antenna(b),
    }
}

// Os chapéus das datas, quando escolhidos (o do canto, nas datas, usa os de
// mascote_terminal, que são estes mesmos).
fn santa(b: Brush) void {
    var pts: [14][2]f32 = undefined;
    var n = quad(.{ 38, 2 }, .{ 70, -44 }, .{ 104, -26 }, 10, &pts);
    pts[n] = .{ 90, 2 };
    n += 1;
    fill(b, pts[0..n], b.paint(Rgba.hex(0xE0303A)));
    rrect(b, 33, -4, 62, 11, 5, 0, b.paint(Rgba.hex(0xF6F2EE)));
    circle(b, 104, -26, 6, b.paint(Rgba.hex(0xF6F2EE)));
}

fn witch(b: Brush) void {
    ellipse(b, 63.57, 2, 44, 7, 0, b.paint(Rgba.hex(0x1B1030)));
    var l: [11][2]f32 = undefined;
    var r: [11][2]f32 = undefined;
    _ = quad(.{ 44, 1 }, .{ 64, -30 }, .{ 84, -46 }, 10, &l);
    _ = quad(.{ 84, -46 }, .{ 78, -22 }, .{ 84, 1 }, 10, &r);
    var pts: [21][2]f32 = undefined;
    for (l, 0..) |q, i| pts[i] = q;
    for (r[1..], 0..) |q, i| pts[11 + i] = q;
    fill(b, &pts, b.paint(Rgba.hex(0x241540)));
    const band = [_][2]f32{ .{ 46, -4 }, .{ 82, -4 }, .{ 83, 1 }, .{ 45, 1 } };
    fill(b, &band, b.paint(b.role(.top)));
}

fn party(b: Brush) void {
    fillConvex(b, &.{ .{ 50, 3 }, .{ 78, 3 }, .{ 64, -38 } }, b.paint(Rgba.hex(0x29E6FF)));
    for ([_]f32{ -8, -20 }) |y| {
        const wd = (y + 38) / 41 * 14;
        line(b, &.{ .{ 64 - wd, y }, .{ 64 + wd, y } }, 3, b.paint(Rgba.hex(0xFF5FA8)));
    }
    circle(b, 64, -39, 4.5, b.paint(Rgba.hex(0xF7E04A)));
}

fn crown(b: Brush) void {
    const main = b.paint(gold);
    const dark = b.paint(gold_dark);
    const pts = [_][2]f32{ .{ 42, 7 }, .{ 40, -12 }, .{ 50, -3 }, .{ 56.5, -17 }, .{ 63.5, -5 }, .{ 70.5, -17 }, .{ 77, -3 }, .{ 87, -12 }, .{ 85, 7 } };
    fill(b, &pts, main);
    rrect(b, 41.5, 1.5, 44, 6.5, 2, 0, dark);
    outline(b, &pts, if (b.small) 1.6 else 1, dark);
    for ([_][2]f32{ .{ 40, -12.5 }, .{ 56.5, -17.5 }, .{ 70.5, -17.5 }, .{ 87, -12.5 } }) |q| circle(b, q[0], q[1], 2, main);
    circle(b, 63.5, 4.6, 2.3, b.paint(Rgba.hex(0xE5394E)));
    circle(b, 52, 4.8, 1.6, b.paint(b.role(.accent)));
    circle(b, 75, 4.8, 1.6, b.paint(b.role(.accent)));
    if (!b.small) line(b, &.{ .{ 45, -4 }, .{ 46, 0 } }, 1.2, b.paint(white.alpha(0.5)));
}

fn tophat(b: Brush) void {
    const black = b.paint(Rgba.hex(0x1D1630));
    const hi = b.paint(Rgba.hex(0x3A2E55));
    const band = b.paint(b.role(.accent));
    ellipse(b, 63.5, 5, 31, 5, 0, black);
    const crown_pts = [_][2]f32{ .{ 46, 5 }, .{ 45, -30 }, .{ 82, -30 }, .{ 81, 5 } };
    fill(b, &crown_pts, black);
    ellipse(b, 63.5, -30, 18.5, 3.4, 0, hi);
    const band_pts = [_][2]f32{ .{ 45.8, -2 }, .{ 81.2, -2 }, .{ 81.1, 2.6 }, .{ 45.9, 2.6 } };
    fill(b, &band_pts, band);
    if (!b.small) line(b, &.{ .{ 50, -26 }, .{ 50.6, -6 } }, 1.6, b.paint(white.alpha(0.16)));
}

fn beanie(b: Brush) void {
    const base = b.role(.accent);
    const main = b.paint(mixRgb(base, Rgba.black, 0.12));
    const cuff = b.paint(base);
    const rib = b.paint(mixRgb(base, Rgba.black, 0.3));
    var dome: [20][2]f32 = undefined;
    for (0..19) |i| {
        const a = pi + pi * @as(f32, @floatFromInt(i)) / 18.0;
        dome[i] = .{ 63.5 + @cos(a) * 34, 4 + @sin(a) * 22 };
    }
    fillConvex(b, dome[0..19], main);
    rrect(b, 28.5, -2, 70, 11, 4.5, 0, cuff);
    if (!b.small) for (0..9) |i| {
        const x = 33.5 + @as(f32, @floatFromInt(i)) * 7.6;
        line(b, &.{ .{ x, 0 }, .{ x, 7 } }, 1, rib);
    };
    circle(b, 63.5, -18.5, 6.4, b.paint(b.role(.tufts)));
    if (!b.small) circle(b, 61.5, -20.5, 2, b.paint(white.alpha(0.35)));
}

fn cap(b: Brush) void {
    const base = b.role(.accent);
    const main = b.paint(base);
    const dark = b.paint(mixRgb(base, Rgba.black, 0.28));
    // De trás para a frente: a aba virada para trás aparece do lado.
    ellipse(b, 99, 2, 20, 4.6, -0.1, dark);
    var dome: [20][2]f32 = undefined;
    for (0..19) |i| {
        const a = pi + pi * @as(f32, @floatFromInt(i)) / 18.0;
        dome[i] = .{ 63.5 + @cos(a) * 31, 5 + @sin(a) * 18 };
    }
    fillConvex(b, dome[0..19], main);
    // A abertura de ajuste na frente (o boné está virado).
    var hole: [12][2]f32 = undefined;
    for (0..12) |i| {
        const a = pi + pi * @as(f32, @floatFromInt(i)) / 11.0;
        hole[i] = .{ 63.5 + @cos(a) * 7.5, 5.2 + @sin(a) * 6 };
    }
    fillConvex(b, &hole, b.paint(mixRgb(base, Rgba.black, 0.5)));
    line(b, &.{ .{ 56.5, 3.4 }, .{ 70.5, 3.4 } }, 1.6, dark);
    for ([_]f32{ 48, 79 }) |x| line(b, &.{ .{ x, -9 }, .{ x + (63.5 - x) * 0.3, 4.5 } }, 0.9, dark);
    circle(b, 63.5, -13.2, 2.4, dark);
}

fn cowboy(b: Brush) void {
    const main = b.paint(Rgba.hex(0xA8703A));
    const dark = b.paint(Rgba.hex(0x7B4C22));
    const band = b.paint(Rgba.hex(0x3E2512));
    // Aba larga, com as pontas viradas para cima.
    var brim: [26][2]f32 = undefined;
    for (0..13) |i| {
        const t = @as(f32, @floatFromInt(i)) / 12.0;
        const x = 8 + 111 * t;
        const lift = std.math.pow(f32, @abs(t - 0.5) * 2, 2.2) * 9;
        brim[i] = .{ x, 2.5 - lift };
        brim[25 - i] = .{ x, 7.5 - lift * 0.65 + @sin(t * pi) * 2.5 };
    }
    fill(b, &brim, dark);
    const crown_pts = [_][2]f32{ .{ 42, 4 }, .{ 44, -18 }, .{ 51, -25 }, .{ 58, -21 }, .{ 63.5, -24 }, .{ 69, -21 }, .{ 76, -25 }, .{ 83, -18 }, .{ 85, 4 } };
    fill(b, &crown_pts, main);
    const band_pts = [_][2]f32{ .{ 42.6, -2.8 }, .{ 84.4, -2.8 }, .{ 84.8, 2 }, .{ 42.2, 2 } };
    fill(b, &band_pts, band);
    line(b, &.{ .{ 63.5, -21 }, .{ 63.5, -9 } }, 1, dark);
    circle(b, 74, -0.4, 1.6, b.paint(Rgba.hex(0xE9C46A)));
}

fn chef(b: Brush) void {
    const white_c = b.paint(Rgba.hex(0xFBFAF7));
    const shade = b.paint(Rgba.hex(0xDCD5CB));
    for ([_][3]f32{ .{ 48, -14, 11 }, .{ 79, -14, 11 }, .{ 63.5, -22, 13.5 }, .{ 56, -9, 9 }, .{ 71, -9, 9 } }) |q| circle(b, q[0], q[1], q[2], white_c);
    rrect(b, 43, -9, 41, 16, 3, 0, white_c);
    line(b, &.{ .{ 44, -1 }, .{ 83, -1 } }, 1, shade);
    for ([_]f32{ 52, 63.5, 75 }) |x| line(b, &.{ .{ x, -6 }, .{ x, 5 } }, 0.9, shade);
    if (!b.small) {
        var a: [9][2]f32 = undefined;
        const n = quad(.{ 55, -27 }, .{ 59, -32 }, .{ 66, -32 }, 8, &a);
        line(b, a[0..n], 1, shade);
    }
}

fn halo(b: Brush) void {
    const bob = @sin(b.t * 2.4) * 1.2;
    const g = Rgba.hex(0xFFD95A);
    ellipse(b, 63.5, -24 + bob, 27, 8, 0, b.paint(g.alpha(0.18)));
    ring(b, 63.5, -24 + bob, 22, 5.6, 0, if (b.small) 4.4 else 3.4, b.paint(g));
    if (!b.small) ring(b, 63.5, -24.8 + bob, 20, 4.6, 0, 1, b.paint(white.alpha(0.55)));
}

fn horns(b: Brush) void {
    const red = Rgba.hex(0xE23D4F);
    const main = b.paint(red);
    const dark = b.paint(Rgba.hex(0x9E1F33));
    for ([_]f32{ -1, 1 }) |side| {
        const x0: f32 = 63.5 + side * 15;
        var pts: [14][2]f32 = undefined;
        var n: usize = 0;
        var outer: [7][2]f32 = undefined;
        var inner: [7][2]f32 = undefined;
        _ = quad(.{ x0 - side * 7, 7 }, .{ x0 - side * 3, -12 }, .{ x0 + side * 9, -20 }, 6, &outer);
        _ = quad(.{ x0 + side * 9, -20 }, .{ x0 + side * 7, -6 }, .{ x0 + side * 7, 7 }, 6, &inner);
        for (outer) |q| {
            pts[n] = q;
            n += 1;
        }
        for (inner[1..]) |q| {
            pts[n] = q;
            n += 1;
        }
        fill(b, pts[0..n], main);
        outline(b, pts[0..n], if (b.small) 1.4 else 0.9, dark);
    }
}

fn flowers(b: Brush) void {
    var vine: [15][2]f32 = undefined;
    const n = quad(.{ 22, 11 }, .{ 63.5, -4 }, .{ 105, 11 }, 14, &vine);
    line(b, vine[0..n], if (b.small) 2.6 else 2, b.paint(Rgba.hex(0x3E9C4B)));
    const petals = [_]u32{ 0xFF8FB8, 0xFFE066, 0xFFFFFF, 0xC9A0FF, 0xFF8FB8, 0xFFE066 };
    for ([_]f32{ 0.08, 0.27, 0.5, 0.73, 0.92 }, 0..) |t, i| {
        const u = 1 - t;
        const x = u * u * 22 + 2 * u * t * 63.5 + t * t * 105;
        const y = u * u * 11 + 2 * u * t * -4 + t * t * 11;
        const r: f32 = if (i == 2) 5.6 else 4.6;
        if (i % 2 == 1) ellipse(b, x + 5.5, y + 1.5, 3.2, 1.6, 0.5, b.paint(Rgba.hex(0x5BBF5A)));
        for (0..5) |pi_| {
            const a = @as(f32, @floatFromInt(pi_)) / 5.0 * tau + @as(f32, @floatFromInt(i));
            circle(b, x + @cos(a) * r * 0.62, y + @sin(a) * r * 0.62, r * 0.5, b.paint(Rgba.hex(petals[i])));
        }
        circle(b, x, y, r * 0.34, b.paint(Rgba.hex(0xF5A300)));
    }
}

fn viking(b: Brush) void {
    const metal = b.paint(Rgba.hex(0xA3ACBD));
    const dark = b.paint(Rgba.hex(0x6E788C));
    const horn = Rgba.hex(0xF3E7CC);
    for ([_]f32{ -1, 1 }) |side| {
        const x0 = 63.5 + side * 27;
        var pts: [14][2]f32 = undefined;
        var outer: [7][2]f32 = undefined;
        var inner: [7][2]f32 = undefined;
        _ = quad(.{ x0, -6 }, .{ x0 + side * 14, -6 }, .{ x0 + side * 17, -29 }, 6, &outer);
        _ = quad(.{ x0 + side * 17, -29 }, .{ x0 + side * 9, -12 }, .{ x0 - side * 2, 2 }, 6, &inner);
        var n: usize = 0;
        for (outer) |q| {
            pts[n] = q;
            n += 1;
        }
        for (inner[1..]) |q| {
            pts[n] = q;
            n += 1;
        }
        fill(b, pts[0..n], b.paint(horn));
        outline(b, pts[0..n], 0.9, b.paint(Rgba.hex(0xB7A379)));
    }
    var dome: [20][2]f32 = undefined;
    for (0..19) |i| {
        const a = pi + pi * @as(f32, @floatFromInt(i)) / 18.0;
        dome[i] = .{ 63.5 + @cos(a) * 31, 4 + @sin(a) * 22 };
    }
    fillConvex(b, dome[0..19], metal);
    rrect(b, 31.5, -1.5, 64, 8, 3, 0, dark);
    line(b, &.{ .{ 63.5, -17 }, .{ 63.5, -1.5 } }, 3, dark);
    if (!b.small) {
        for ([_]f32{ 38, 50, 77, 89 }) |x| circle(b, x, 2.5, 1, metal);
        line(b, &.{ .{ 44, -11 }, .{ 51, -15 } }, 1.6, b.paint(white.alpha(0.4)));
    }
}

fn wizard(b: Brush) void {
    const blue = b.paint(Rgba.hex(0x2E3192));
    const deep = b.paint(Rgba.hex(0x1F2170));
    const star = b.paint(Rgba.hex(0xFFD95A));
    ellipse(b, 63.5, 3.5, 40, 6.5, 0, deep);
    var cone: [16][2]f32 = undefined;
    var l: [8][2]f32 = undefined;
    var r: [8][2]f32 = undefined;
    _ = quad(.{ 44, 3 }, .{ 50, -26 }, .{ 36, -44 }, 7, &l);
    _ = quad(.{ 36, -44 }, .{ 70, -30 }, .{ 83, 3 }, 7, &r);
    var n: usize = 0;
    for (l) |q| {
        cone[n] = q;
        n += 1;
    }
    for (r[1..]) |q| {
        cone[n] = q;
        n += 1;
    }
    fill(b, cone[0..n], blue);
    starShape(b, 60, -14, 4.6, star);
    starShape(b, 72, -4, 2.8, star);
    starShape(b, 49, -30, 2.4, star);
    if (!b.small) {
        var moon: [16][2]f32 = undefined;
        for (0..8) |i| {
            const a = -pi / 2.0 + pi * @as(f32, @floatFromInt(i)) / 7.0;
            moon[i] = .{ 70 + @cos(a) * 3.4, -19 + @sin(a) * 3.4 };
            moon[15 - i] = .{ 70 + @cos(a) * 1.6 + 0.6, -19 + @sin(a) * 3 };
        }
        fill(b, &moon, star);
    }
}

fn starShape(b: Brush, x: f32, y: f32, r: f32, col: u32) void {
    var st: [10][2]f32 = undefined;
    for (0..10) |i| {
        const a = -pi / 2.0 + @as(f32, @floatFromInt(i)) * pi / 5.0;
        const rr = if (i % 2 == 0) r else r * 0.45;
        st[i] = .{ x + @cos(a) * rr, y + @sin(a) * rr };
    }
    fill(b, &st, col);
}

fn bow(b: Brush) void {
    const pink = Rgba.hex(0xFF5FA8);
    const main = b.paint(pink);
    const dark = b.paint(Rgba.hex(0xC93A7E));
    const ctr: [2]f32 = .{ 92, 3 };
    for ([_]f32{ -1, 1 }) |side| {
        var pts: [14][2]f32 = undefined;
        var n: usize = 0;
        pts[n] = ctr;
        n += 1;
        for (0..11) |i| {
            const a = (-0.62 + 1.24 * @as(f32, @floatFromInt(i)) / 10.0) * pi * 0.5;
            const rr = 12.5 + @cos(a * 2) * 1.5;
            pts[n] = rot2(.{ ctr[0] + side * @cos(a) * rr, ctr[1] + @sin(a) * rr * 0.8 }, ctr, -0.25);
            n += 1;
        }
        fill(b, pts[0..n], main);
        line(b, &.{ rot2(.{ ctr[0] + side * 3, ctr[1] }, ctr, -0.25), rot2(.{ ctr[0] + side * 8.5, ctr[1] - 3 }, ctr, -0.25) }, 1.1, dark);
        line(b, &.{ rot2(.{ ctr[0] + side * 3, ctr[1] }, ctr, -0.25), rot2(.{ ctr[0] + side * 8.5, ctr[1] + 3 }, ctr, -0.25) }, 1.1, dark);
    }
    // As fitas soltas.
    const t1 = [_][2]f32{ .{ 90, 4 }, .{ 84, 14 }, .{ 88, 13.5 }, .{ 92.5, 5 } };
    const t2 = [_][2]f32{ .{ 93.5, 4 }, .{ 100.5, 13 }, .{ 96.5, 13.8 }, .{ 91.5, 5 } };
    fill(b, &t1, dark);
    fill(b, &t2, dark);
    ellipse(b, ctr[0], ctr[1], 3.4, 3.8, -0.25, dark);
}

fn propeller(b: Brush) void {
    const cols = [_]u32{ 0xE5394E, 0xFFD23F, 0x3B82F6, 0x22C55E };
    for (0..4) |q| {
        var pts: [8][2]f32 = undefined;
        pts[0] = .{ 63.5, 4.5 };
        for (0..7) |i| {
            const a = pi + pi * (@as(f32, @floatFromInt(q)) + @as(f32, @floatFromInt(i)) / 6.0) / 4.0;
            pts[i + 1] = .{ 63.5 + @cos(a) * 27, 4.5 + @sin(a) * 16 };
        }
        fill(b, &pts, b.paint(Rgba.hex(cols[q])));
    }
    rrect(b, 36, 1.5, 55, 5, 2.5, 0, b.paint(Rgba.hex(0x2B2D42)));
    line(b, &.{ .{ 63.5, -11 }, .{ 63.5, -17 } }, 1.8, b.paint(Rgba.hex(0x4B4E63)));
    // As pás giram com o relógio (achatadas: vistas de lado).
    const ang = b.t * 9;
    const sw = @cos(ang);
    for ([_]f32{ -1, 1 }) |side| {
        const len = 13 * sw * side;
        ellipse(b, 63.5 + len / 2, -18, @max(@abs(len) / 2, 1.2), 2.1, 0, b.paint(Rgba.hex(if (side > 0) 0xE5394E else 0x3B82F6)));
    }
    circle(b, 63.5, -18, 2, b.paint(Rgba.hex(0xFFD23F)));
}

fn beret(b: Brush) void {
    const red = Rgba.hex(0xC8323C);
    ellipse(b, 59, 0.5, 34, 10.5, -0.16, b.paint(red));
    ellipse(b, 57, -2, 27, 6.5, -0.16, b.paint(mixRgb(red, white, 0.12)));
    line(b, &.{ .{ 55, -9 }, .{ 54, -14 } }, 2, b.paint(mixRgb(red, Rgba.black, 0.3)));
    var rim: [13][2]f32 = undefined;
    const n = quad(.{ 30, 7 }, .{ 60, 13 }, .{ 90, 2 }, 12, &rim);
    line(b, rim[0..n], 1.4, b.paint(mixRgb(red, Rgba.black, 0.3)));
}

fn tiara(b: Brush) void {
    const silver = b.paint(Rgba.hex(0xE3E8F2));
    const shade = b.paint(Rgba.hex(0xA6B0C3));
    var band: [13][2]f32 = undefined;
    const n = quad(.{ 36, 8 }, .{ 63.5, -2 }, .{ 91, 8 }, 12, &band);
    line(b, band[0..n], if (b.small) 3.2 else 2.4, silver);
    const peaks = [_][3]f32{ .{ 47, 3.6, 5.5 }, .{ 55, 1.6, 8 }, .{ 63.5, 0.8, 12 }, .{ 72, 1.6, 8 }, .{ 80, 3.6, 5.5 } };
    for (peaks) |q| {
        const tri = [_][2]f32{ .{ q[0] - 3, q[1] + 1 }, .{ q[0], q[1] - q[2] }, .{ q[0] + 3, q[1] + 1 } };
        fill(b, &tri, silver);
        outline(b, &tri, 0.7, shade);
    }
    ellipse(b, 63.5, -5, 2.6, 3.4, 0, b.paint(Rgba.hex(0xFF5FA8)));
    circle(b, 55, -2, 1.4, b.paint(b.role(.accent)));
    circle(b, 72, -2, 1.4, b.paint(b.role(.accent)));
    if (!b.small) circle(b, 62.8, -6.2, 0.8, b.paint(white.alpha(0.8)));
}

fn pirate(b: Brush) void {
    const black = b.paint(Rgba.hex(0x1B1622));
    const trim = b.paint(Rgba.hex(0xE2B33C));
    var shape: [26][2]f32 = undefined;
    var n: usize = 0;
    var top: [13][2]f32 = undefined;
    _ = quad(.{ 20, -6 }, .{ 63.5, -36 }, .{ 107, -6 }, 12, &top);
    for (top) |q| {
        shape[n] = q;
        n += 1;
    }
    var bot: [13][2]f32 = undefined;
    _ = quad(.{ 107, -6 }, .{ 63.5, 18 }, .{ 20, -6 }, 12, &bot);
    for (bot[1..12]) |q| {
        shape[n] = q;
        n += 1;
    }
    fill(b, shape[0..n], black);
    var tb: [13][2]f32 = undefined;
    const m = quad(.{ 22, -5 }, .{ 63.5, 15 }, .{ 105, -5 }, 12, &tb);
    line(b, tb[0..m], 1.6, trim);
    // Caveira e ossos.
    const bone = b.paint(Rgba.hex(0xF2EEE6));
    line(b, &.{ .{ 57, -8 }, .{ 70, -1 } }, 1.8, bone);
    line(b, &.{ .{ 57, -1 }, .{ 70, -8 } }, 1.8, bone);
    circle(b, 63.5, -10.5, 4.2, bone);
    rrect(b, 61, -8.4, 5, 3.4, 1, 0, bone);
    if (!b.small) {
        circle(b, 62, -11, 1, black);
        circle(b, 65, -11, 1, black);
    }
}

fn helmet(b: Brush) void {
    const glass = b.paint(Rgba.hex(0xDDEBFF).alpha(0.16));
    const rim = b.paint(Rgba.hex(0xDDEBFF).alpha(0.7));
    ellipse(b, 63.5, 44, 75, 66, 0, glass);
    // Um fio escuro por fora: o vidro aparece também em fundo claro.
    ring(b, 63.5, 44, 76.2, 67.2, 0, 1, b.inkA(0.22));
    ring(b, 63.5, 44, 75, 66, 0, if (b.small) 2.4 else 1.6, rim);
    var refl: [13][2]f32 = undefined;
    for (0..13) |i| {
        const a = pi * (1.12 + 0.3 * @as(f32, @floatFromInt(i)) / 12.0);
        refl[i] = .{ 63.5 + @cos(a) * 64, 44 + @sin(a) * 56 };
    }
    line(b, &refl, if (b.small) 3 else 2.4, b.paint(white.alpha(0.55)));
    line(b, &.{ .{ 63.5, -22 }, .{ 63.5, -30 } }, 1.4, rim);
    circle(b, 63.5, -31.5, 2.4, b.paint(Rgba.hex(0xFF4A5A)));
}

fn sprout(b: Brush) void {
    const stem = b.paint(Rgba.hex(0x3FA34D));
    var s: [9][2]f32 = undefined;
    const n = quad(.{ 63.5, 7 }, .{ 62, -2 }, .{ 64.5, -10 }, 8, &s);
    line(b, s[0..n], if (b.small) 2.6 else 1.8, stem);
    ellipse(b, 57, -13, 7.2, 3.6, 0.45, b.paint(Rgba.hex(0x5BD06A)));
    ellipse(b, 71.5, -15, 7.8, 3.8, -0.5, b.paint(Rgba.hex(0x49BA59)));
    if (!b.small) {
        line(b, &.{ .{ 52.5, -15 }, .{ 61, -11.2 } }, 0.8, b.paint(Rgba.hex(0x2F8A3C)));
        line(b, &.{ .{ 76.5, -17.6 }, .{ 66.5, -12.6 } }, 0.8, b.paint(Rgba.hex(0x2F8A3C)));
    }
}

fn antenna(b: Brush) void {
    const stalk = b.ink();
    const glow = b.role(.accent);
    for ([_]f32{ -1, 1 }) |side| {
        var s: [9][2]f32 = undefined;
        const n = quad(.{ 63.5 + side * 11, 4 }, .{ 63.5 + side * 13, -10 }, .{ 63.5 + side * 21, -20 }, 8, &s);
        line(b, s[0..n], if (b.small) 2.6 else 1.6, stalk);
        circle(b, 63.5 + side * 21, -21, 6.5, b.paint(glow.alpha(0.25)));
        circle(b, 63.5 + side * 21, -21, 4, b.paint(glow));
        if (!b.small) circle(b, 63.5 + side * 21 - 1.3, -22.4, 1.2, b.paint(white.alpha(0.7)));
    }
}

// --- Formas dos arquivos -------------------------------------------------------------------

/// As formas de uma camada de um arquivo de mascote, na expressão `w`.
pub fn drawing(b: Brush, dw: *const v.Drawing, layer: v.Layer, w: v.When) void {
    for (dw.shapesSlice()) |*s| {
        if (s.layer != layer or !dw.shows(s, w)) continue;
        drawingShape(b, dw, s);
    }
}

/// O meio de cada lado do rosto de uma camada (a piscada aperta cada olho no lugar).
pub fn layerCenters(dw: *const v.Drawing, layer: v.Layer, w: v.When) [2][2]f32 {
    var lo: [2][2]f32 = .{ .{ 1e9, 1e9 }, .{ 1e9, 1e9 } };
    var hi: [2][2]f32 = .{ .{ -1e9, -1e9 }, .{ -1e9, -1e9 } };
    for (dw.shapesSlice()) |*s| {
        if (s.layer != layer or !dw.shows(s, w)) continue;
        var box: [4]f32 = undefined;
        bounds(dw, s, &box);
        const side: usize = if ((box[0] + box[2]) / 2 < 62) 0 else 1;
        lo[side] = .{ @min(lo[side][0], box[0]), @min(lo[side][1], box[1]) };
        hi[side] = .{ @max(hi[side][0], box[2]), @max(hi[side][1], box[3]) };
    }
    var out: [2][2]f32 = .{ eye_l, eye_r };
    for (0..2) |i| if (lo[i][0] < 1e8) {
        out[i] = .{ (lo[i][0] + hi[i][0]) / 2, (lo[i][1] + hi[i][1]) / 2 };
    };
    return out;
}

fn bounds(dw: *const v.Drawing, s: *const v.Shape, box: *[4]f32) void {
    switch (s.kind) {
        .circle => box.* = .{ s.v[0] - s.v[2], s.v[1] - s.v[2], s.v[0] + s.v[2], s.v[1] + s.v[2] },
        .ellipse => {
            const r = @max(s.v[2], s.v[3]);
            box.* = .{ s.v[0] - r, s.v[1] - r, s.v[0] + r, s.v[1] + r };
        },
        .rect => box.* = .{ s.v[0], s.v[1], s.v[0] + s.v[2], s.v[1] + s.v[3] },
        .line => box.* = .{ @min(s.v[0], s.v[2]), @min(s.v[1], s.v[3]), @max(s.v[0], s.v[2]), @max(s.v[1], s.v[3]) },
        .polyline, .polygon => {
            box.* = .{ 1e9, 1e9, -1e9, -1e9 };
            for (dw.pointsOf(s)) |q| box.* = .{ @min(box[0], q[0]), @min(box[1], q[1]), @max(box[2], q[0]), @max(box[3], q[1]) };
        },
    }
}

fn inkColor(b: Brush, k: v.Ink, opacity: f32) ?u32 {
    return switch (k) {
        .none => null,
        .role => |r| if (r == .ink) b.inkA(opacity) else b.paint(b.role(r).alpha(opacity)),
        .rgba => |col| b.paint(col.alpha(opacity)),
    };
}

pub fn drawingShape(b: Brush, dw: *const v.Drawing, s: *const v.Shape) void {
    const fc = inkColor(b, s.fill, s.opacity);
    const sc = inkColor(b, s.stroke, s.opacity);
    var pts: [v.max_shape_points][2]f32 = undefined;
    switch (s.kind) {
        .circle, .ellipse => {
            const rx = s.v[2];
            const ry = if (s.kind == .circle) s.v[2] else s.v[3];
            const rot = if (s.kind == .ellipse) s.v[4] * pi / 180.0 else 0;
            if (fc) |col| ellipse(b, s.v[0], s.v[1], rx, ry, rot, col);
            if (sc) |col| ring(b, s.v[0], s.v[1], rx, ry, rot, s.width, col);
        },
        .rect => {
            const n = roundRect(s.v[0], s.v[1], s.v[2], s.v[3], s.v[4], 0, pts[0..24]);
            if (fc) |col| fillConvex(b, pts[0..n], col);
            if (sc) |col| outline(b, pts[0..n], s.width, col);
        },
        .line => if (sc) |col| line(b, &.{ .{ s.v[0], s.v[1] }, .{ s.v[2], s.v[3] } }, s.width, col),
        .polyline, .polygon => {
            const src = dw.pointsOf(s);
            // Um caminho comprido é desenhado em pedaços (o ImGui recebe até `max_pts`).
            if (s.kind == .polygon) {
                if (fc) |col| if (src.len <= max_pts) fill(b, src, col);
                if (sc) |col| if (src.len <= max_pts) outline(b, src, s.width, col) else strokeLong(b, src, s.width, col, true);
            } else if (sc) |col| strokeLong(b, src, s.width, col, false);
        },
    }
}

fn strokeLong(b: Brush, src: []const [2]f32, width: f32, col: u32, closed_: bool) void {
    var i: usize = 0;
    while (i + 1 < src.len) {
        const end = @min(src.len, i + max_pts);
        line(b, src[i..end], width, col);
        if (end == src.len) break;
        i = end - 1;
    }
    if (closed_ and src.len > 2) line(b, &.{ src[src.len - 1], src[0] }, width, col);
}
