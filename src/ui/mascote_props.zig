//! Os objetos do mascote do canto (ui/mascote_pet.zig): caneca, livro, videogame,
//! chiclete, notas do assobio, paninho, vara de pesca, plantinha, mosquinha, blocos,
//! rabisco, lixeira, borracha, cartinha, barraca com fogueira e o balão de fala. Tudo
//! desenhado com formas, sem imagem nenhuma: não pesa na memória.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const terminal = @import("mascote_terminal.zig");
const types = @import("../core/types.zig");

const Rgba = d.Rgba;
const tau = std.math.tau;

/// O mascote na tela: os objetos que ele segura são posicionados nas coordenadas do
/// desenho dele (0..127 de largura, 0..99 de altura, olhos em ~(40, 60) e (84, 64)).
pub const Body = struct {
    cx: f32,
    cy: f32,
    size: f32,

    pub fn p(b: Body, x: f32, y: f32) c.ImVec2 {
        return terminal.petPoint(b.cx, b.cy, b.size, x, y);
    }
    pub fn k(b: Body) f32 {
        return b.size * 0.78 / 127.14;
    }
};

fn add(a: c.ImVec2, x: f32, y: f32) c.ImVec2 {
    return d.v(a.x + x, a.y + y);
}

/// Um retângulo girado `ang` em volta do centro.
fn quad(dl: *c.ImDrawList, ctr: c.ImVec2, w: f32, h: f32, ang: f32, col: u32) void {
    const cs = @cos(ang);
    const sn = @sin(ang);
    const hw = w / 2;
    const hh = h / 2;
    const pts = [4][2]f32{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } };
    var o: [4]c.ImVec2 = undefined;
    for (pts, 0..) |q, i| o[i] = d.v(ctr.x + q[0] * cs - q[1] * sn, ctr.y + q[0] * sn + q[1] * cs);
    c.ImDrawList_AddQuadFilled(dl, o[0], o[1], o[2], o[3], col);
}

fn line(dl: *c.ImDrawList, a: c.ImVec2, b: c.ImVec2, col: u32, w: f32) void {
    c.ImDrawList_AddLineEx(dl, a, b, col, w, 0);
}

// --- Coisas de ficar parado ------------------------------------------------------

/// A caneca na mão direita, com o vapor subindo (`t` em segundos).
pub fn mug(dl: *c.ImDrawList, b: Body, lift: f32, t: f32) void {
    const k = b.k();
    const y = -lift * 18;
    const tl = b.p(116, 62 + y);
    const br = b.p(134, 84 + y);
    c.ImDrawList_AddCircleEx(dl, b.p(136, 72 + y), 5 * k, Rgba.hex(0xEDE6DA).u(), 12, 2.6 * k, 0);
    c.ImDrawList_AddRectFilledEx(dl, tl, br, Rgba.hex(0xF4EFE6).u(), 3 * k, 0);
    c.ImDrawList_AddRectFilledEx(dl, b.p(116, 70 + y), b.p(134, 74 + y), Rgba.hex(0x9D40FF).u(), 0, 0);
    c.ImDrawList_AddEllipseFilled(dl, b.p(125, 63 + y), d.v(8 * k, 2.2 * k), Rgba.hex(0x6B3E1E).u());
    for (0..2) |i| {
        const fi: f32 = @floatFromInt(i);
        const f = @mod(t * 0.7 + fi * 0.5, 1);
        var pts: [6]c.ImVec2 = undefined;
        for (0..6) |j| {
            const fj: f32 = @floatFromInt(j);
            pts[j] = b.p(121 + fi * 7 + @sin(fj * 1.3 + t * 4 + fi) * 2.5, 58 + y - f * 22 - fj * 3);
        }
        c.ImDrawList_AddPolyline(dl, &pts, pts.len, Rgba.hex(0xFFFFFF).col(0.45 * (1 - f)), 1.6 * k, 0);
    }
}

/// O livrinho aberto na frente do rosto, com uma página virando de vez em quando.
pub fn book(dl: *c.ImDrawList, b: Body, t: f32) void {
    const k = b.k();
    c.ImDrawList_AddQuadFilled(dl, b.p(36, 74), b.p(64, 79), b.p(64, 99), b.p(36, 94), Rgba.hex(0x6A2AC0).u());
    c.ImDrawList_AddQuadFilled(dl, b.p(64, 79), b.p(92, 74), b.p(92, 94), b.p(64, 99), Rgba.hex(0x6A2AC0).u());
    c.ImDrawList_AddQuadFilled(dl, b.p(38, 74), b.p(64, 78), b.p(64, 96), b.p(38, 92), Rgba.hex(0xFAF6EE).u());
    c.ImDrawList_AddQuadFilled(dl, b.p(64, 78), b.p(90, 74), b.p(90, 92), b.p(64, 96), Rgba.hex(0xF1ECE2).u());
    for (0..3) |i| {
        const y: f32 = 80 + @as(f32, @floatFromInt(i)) * 4;
        line(dl, b.p(42, y), b.p(60, y + 2.5), Rgba.hex(0xB8B0A2).u(), 1.1 * k);
        line(dl, b.p(68, y + 2.5), b.p(86, y), Rgba.hex(0xB8B0A2).u(), 1.1 * k);
    }
    // A página virando: a ponta solta vai da direita para a esquerda.
    const f = @mod(t, 1.8) / 0.5;
    if (f < 1) {
        const x = 90 - f * 52;
        const lift = @sin(std.math.pi * f) * 10;
        c.ImDrawList_AddQuadFilled(dl, b.p(64, 78), b.p(x, 74 - lift), b.p(x, 92 - lift), b.p(64, 96), Rgba.hex(0xFFFDF8).u());
    }
}

/// O videogame portátil, com a tela piscando.
pub fn handheld(dl: *c.ImDrawList, b: Body, t: f32) void {
    const k = b.k();
    c.ImDrawList_AddRectFilledEx(dl, b.p(40, 72), b.p(88, 98), Rgba.hex(0x2B2438).u(), 5 * k, 0);
    c.ImDrawList_AddRectFilledEx(dl, b.p(46, 76), b.p(70, 92), Rgba.hex(0x7FE08A).u(), 1.5 * k, 0);
    // Um bonequinho de pixel pulando na tela.
    const jy = -@abs(@sin(t * 6)) * 5;
    const px = 50 + @mod(t * 9, 16);
    c.ImDrawList_AddRectFilled(dl, b.p(px, 85 + jy), b.p(px + 3, 88 + jy), Rgba.hex(0x1D5A2A).u());
    c.ImDrawList_AddRectFilled(dl, b.p(46, 89), b.p(70, 90), Rgba.hex(0x1D5A2A).u());
    c.ImDrawList_AddCircleFilled(dl, b.p(78, 81), 2.6 * k, Rgba.hex(0xFF4A5A).u(), 0);
    c.ImDrawList_AddCircleFilled(dl, b.p(83, 87), 2.6 * k, Rgba.hex(0xF7E04A).u(), 0);
}

/// A bola de chiclete na boca (`r` de 0 a 1; `pop` > 0 = estourou, de 0 a 1).
pub fn gum(dl: *c.ImDrawList, b: Body, r: f32, pop: f32) void {
    const k = b.k();
    const ctr = b.p(64, 74);
    if (pop > 0) {
        for (0..6) |i| {
            const a = @as(f32, @floatFromInt(i)) / 6.0 * tau;
            const rr = (6 + pop * 10) * k;
            c.ImDrawList_AddCircleFilled(dl, d.v(ctr.x + @cos(a) * rr, ctr.y + @sin(a) * rr * 0.7), 2 * k, Rgba.hex(0xFF7AC0).col(1 - pop), 0);
        }
        return;
    }
    const rad = (3 + r * 15) * k;
    c.ImDrawList_AddCircleFilled(dl, d.v(ctr.x, ctr.y + rad * 0.3), rad, Rgba.hex(0xFF7AC0).col(0.92), 0);
    c.ImDrawList_AddCircleFilled(dl, d.v(ctr.x - rad * 0.35, ctr.y - rad * 0.1), rad * 0.25, Rgba.hex(0xFFFFFF).col(0.5), 0);
}

/// As notinhas do assobio subindo.
pub fn notes(dl: *c.ImDrawList, b: Body, t: f32, col: Rgba) void {
    const k = b.k();
    for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const f = @mod(t * 0.6 + fi / 3.0, 1);
        const p = b.p(92 + f * 34 + @sin(f * 9 + fi) * 4, 64 - f * 52);
        const a = 1 - f;
        c.ImDrawList_AddEllipseFilled(dl, p, d.v(3.4 * k, 2.6 * k), col.col(a));
        line(dl, add(p, 3 * k, 0), add(p, 3 * k, -11 * k), col.col(a), 1.5 * k);
        line(dl, add(p, 3 * k, -11 * k), add(p, 7 * k, -8 * k), col.col(a), 1.5 * k);
    }
}

/// O paninho limpando o rosto.
pub fn rag(dl: *c.ImDrawList, b: Body, t: f32) void {
    const k = b.k();
    const p = b.p(64 + @cos(t * 9) * 18, 62 + @sin(t * 9) * 6);
    quad(dl, p, 18 * k, 13 * k, @sin(t * 9) * 0.3, Rgba.hex(0x7ED6FF).u());
    quad(dl, add(p, 0, 2 * k), 18 * k, 2 * k, @sin(t * 9) * 0.3, Rgba.hex(0x4AA8D8).u());
}

/// A vara de pesca jogada para cima, na conversa: `reel` de 0 (linha lá em cima) a 1
/// (o peixe chegou), e o que veio no anzol (`catch_size` > 0 quando já pegou).
pub fn rod(dl: *c.ImDrawList, b: Body, cast: f32, reel: f32, bob: f32) c.ImVec2 {
    const k = b.k();
    const hand = b.p(16, 66);
    const tip = b.p(-24, -40);
    line(dl, hand, tip, Rgba.hex(0x8A5A2B).u(), 2.6 * k);
    c.ImDrawList_AddCircleFilled(dl, b.p(10, 58), 3 * k, Rgba.hex(0x5A3A1B).u(), 0);
    const top = -40 - cast * 120 * (1 - reel);
    const hook = b.p(-36 + bob * 3, top);
    line(dl, tip, hook, Rgba.hex(0xEDE6DA).col(0.8), 1 * k);
    if (reel < 0.05) {
        c.ImDrawList_AddCircleFilled(dl, hook, 2.6 * k, Rgba.hex(0xFF4A5A).u(), 0);
        c.ImDrawList_AddCircleFilled(dl, add(hook, 0, -2.6 * k), 2.6 * k, Rgba.hex(0xFFFFFF).u(), 0);
    }
    return hook;
}

/// Um peixinho (quando a conversa não tem emoji nenhum para pescar).
pub fn fish(dl: *c.ImDrawList, p: c.ImVec2, s: f32, wiggle: f32) void {
    c.ImDrawList_AddEllipseFilled(dl, p, d.v(s * 0.55, s * 0.32), Rgba.hex(0x29E6FF).u());
    const tx = p.x + s * 0.5;
    c.ImDrawList_AddTriangleFilled(dl, d.v(tx, p.y), d.v(tx + s * 0.35, p.y - s * 0.3 + wiggle), d.v(tx + s * 0.35, p.y + s * 0.3 + wiggle), Rgba.hex(0x1AA8C8).u());
    c.ImDrawList_AddCircleFilled(dl, d.v(p.x - s * 0.28, p.y - s * 0.06), s * 0.07, Rgba.hex(0x12061F).u(), 0);
}

/// O emoji pescado da conversa.
pub fn caught(ctx: *d.Ctx, dl: *c.ImDrawList, r: *const types.Reaction, p: c.ImVec2, s: f32) void {
    _ = @import("reactors.zig").drawEmoji(ctx, dl, r, p.x - s / 2, p.y, s, false);
}

/// A mosquinha de pixel, com as asas batendo.
pub fn fly(dl: *c.ImDrawList, p: c.ImVec2, s: f32, t: f32) void {
    // Verde-limão com asas brancas: aparece em tema escuro e em tema claro.
    const flap = @abs(@sin(t * 40));
    c.ImDrawList_AddEllipseFilled(dl, d.v(p.x - s * 0.55, p.y - s * 0.45), d.v(s * 0.55, s * (0.2 + 0.3 * flap)), Rgba.hex(0xFFFFFF).col(0.85));
    c.ImDrawList_AddEllipseFilled(dl, d.v(p.x + s * 0.55, p.y - s * 0.45), d.v(s * 0.55, s * (0.2 + 0.3 * flap)), Rgba.hex(0xFFFFFF).col(0.85));
    c.ImDrawList_AddCircleFilled(dl, p, s * 0.5, Rgba.hex(0x2B2438).u(), 0);
    c.ImDrawList_AddCircleFilled(dl, p, s * 0.38, Rgba.hex(0xB9F35A).u(), 0);
}

/// A torre de blocos com caracteres, montada até `n` blocos; `fall` de 0 a 1 é ela
/// desabando. `base` é o chão, à esquerda dele.
pub fn blocks(dl: *c.ImDrawList, font: *c.ImFont, base: c.ImVec2, s: f32, n: f32, fall: f32) void {
    const chars = [_][]const u8{ "{", "}", "<", ">", ";", "/" };
    const cols = [_]u32{ 0x9D40FF, 0x29E6FF, 0xFF5FA8, 0xF7E04A, 0x4AD957, 0xFF8A2A };
    const count: usize = @intFromFloat(@min(@ceil(n), chars.len));
    for (0..count) |i| {
        const fi: f32 = @floatFromInt(i);
        // O último bloco ainda descendo até o lugar.
        const settle = std.math.clamp(n - fi, 0, 1);
        var p = d.v(base.x + (if (i % 2 == 0) @as(f32, 0) else s * 0.12), base.y - s * (fi + 0.5) - (1 - settle) * s * 1.5);
        var ang: f32 = 0;
        if (fall > 0) {
            // Cada bloco cai para um lado, girando, até o chão.
            const dir: f32 = if (i % 2 == 0) 1 else -1;
            p.x += dir * fall * s * (1 + fi * 0.6);
            p.y = p.y + (base.y - s * 0.5 - p.y) * @min(1, fall * fall * 1.6);
            ang = dir * fall * (2 + fi);
        }
        quad(dl, p, s * 0.92, s * 0.92, ang, Rgba.hex(cols[i]).u());
        if (ang == 0) {
            const fs = s * 0.8;
            const tw = d.width(font, fs, chars[i]);
            d.text(dl, font, fs, p.x - tw / 2, p.y - d.fontPx(fs) / 2, Rgba.hex(0x12061F), chars[i]);
        }
    }
}

/// O rabisco no fundo da caixa de mensagem: um coração ou uma estrela (`progress` de 0
/// a 1 é o traço sendo desenhado).
pub fn doodle(dl: *c.ImDrawList, ctr: c.ImVec2, s: f32, star: bool, progress: f32, col: Rgba) void {
    var pts: [41]c.ImVec2 = undefined;
    const n: usize = @max(2, @as(usize, @intFromFloat(progress * 40)) + 1);
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / 40.0 * tau;
        if (star) {
            // Estrela de cinco pontas: o raio alterna, interpolado.
            const r = s * (0.55 + 0.45 * @cos(a * 5));
            pts[i] = d.v(ctr.x + @sin(a) * r, ctr.y - @cos(a) * r);
        } else {
            // Coração (curva clássica, de cabeça para baixo na tela).
            const x = 16 * std.math.pow(f32, @sin(a), 3);
            const y = 13 * @cos(a) - 5 * @cos(2 * a) - 2 * @cos(3 * a) - @cos(4 * a);
            pts[i] = d.v(ctr.x + x * s / 17, ctr.y - y * s / 17);
        }
    }
    c.ImDrawList_AddPolyline(dl, &pts, @intCast(n), col.u(), @max(1.4, s * 0.09), 0);
}

// --- Coisas da interface ------------------------------------------------------------

/// A lixeirinha (com a tampa aberta de 0 a 1).
pub fn trash(dl: *c.ImDrawList, base: c.ImVec2, s: f32, lid: f32) void {
    const w = s * 0.7;
    const h = s * 0.85;
    c.ImDrawList_AddQuadFilled(dl, d.v(base.x - w / 2, base.y - h), d.v(base.x + w / 2, base.y - h), d.v(base.x + w * 0.4, base.y), d.v(base.x - w * 0.4, base.y), Rgba.hex(0x8A8496).u());
    for (0..3) |i| {
        const x = base.x + (@as(f32, @floatFromInt(i)) - 1) * w * 0.25;
        line(dl, d.v(x, base.y - h * 0.8), d.v(x * 0.98 + base.x * 0.02, base.y - h * 0.15), Rgba.hex(0x6A6476).u(), @max(1, s * 0.05));
    }
    const hinge = d.v(base.x + w * 0.55, base.y - h);
    const ang = -lid * 1.6;
    quad(dl, d.v(hinge.x - @cos(ang) * w * 0.55, hinge.y - @sin(ang) * -w * 0.55 - s * 0.05), w * 1.15, s * 0.12, ang, Rgba.hex(0xA8A2B4).u());
}

/// A bolinha de papel (a mensagem apagada amassada).
pub fn paperBall(dl: *c.ImDrawList, p: c.ImVec2, r: f32) void {
    c.ImDrawList_AddCircleFilled(dl, p, r, Rgba.hex(0xF4EFE6).u(), 0);
    line(dl, d.v(p.x - r * 0.5, p.y - r * 0.2), d.v(p.x + r * 0.3, p.y + r * 0.4), Rgba.hex(0xC8C0B2).u(), @max(1, r * 0.18));
    line(dl, d.v(p.x - r * 0.1, p.y - r * 0.6), d.v(p.x + r * 0.5, p.y - r * 0.1), Rgba.hex(0xC8C0B2).u(), @max(1, r * 0.18));
}

/// A borracha, girada, com farelos.
pub fn eraser(dl: *c.ImDrawList, p: c.ImVec2, s: f32, ang: f32, t: f32) void {
    quad(dl, p, s * 0.5, s * 0.26, ang, Rgba.hex(0xFF8FB0).u());
    quad(dl, d.v(p.x + @cos(ang) * s * 0.12, p.y + @sin(ang) * s * 0.12), s * 0.12, s * 0.27, ang, Rgba.hex(0x4A7BFF).u());
    for (0..4) |i| {
        const fi: f32 = @floatFromInt(i);
        const f = @mod(t * 2 + fi * 0.25, 1);
        c.ImDrawList_AddCircleFilled(dl, d.v(p.x + (fi - 1.5) * s * 0.12, p.y + s * 0.2 + f * s * 0.4), @max(0.8, s * 0.03), Rgba.hex(0xFF8FB0).col(1 - f), 0);
    }
}

/// A cartinha da DM.
pub fn letter(dl: *c.ImDrawList, p: c.ImVec2, s: f32, ang: f32) void {
    const w = s * 0.62;
    const h = s * 0.42;
    quad(dl, p, w, h, ang, Rgba.hex(0xF8F4EC).u());
    const cs = @cos(ang);
    const sn = @sin(ang);
    const P = struct {
        fn at(ctr: c.ImVec2, x: f32, y: f32, ccs: f32, ssn: f32) c.ImVec2 {
            return d.v(ctr.x + x * ccs - y * ssn, ctr.y + x * ssn + y * ccs);
        }
    };
    const lw = @max(1, s * 0.035);
    line(dl, P.at(p, -w / 2, -h / 2, cs, sn), P.at(p, 0, h * 0.1, cs, sn), Rgba.hex(0xB8B0A2).u(), lw);
    line(dl, P.at(p, w / 2, -h / 2, cs, sn), P.at(p, 0, h * 0.1, cs, sn), Rgba.hex(0xB8B0A2).u(), lw);
    c.ImDrawList_AddCircleFilled(dl, P.at(p, 0, h * 0.12, cs, sn), s * 0.06, Rgba.hex(0xFF4A5A).u(), 0);
}

/// A barraca do acampamento (o chão em `base`, centro embaixo).
pub fn tent(dl: *c.ImDrawList, base: c.ImVec2, s: f32, fold: f32) void {
    const w = s * 1.1 * (1 - fold * 0.8);
    const h = s * 0.8 * (1 - fold * 0.7);
    c.ImDrawList_AddTriangleFilled(dl, d.v(base.x - w / 2, base.y), d.v(base.x + w / 2, base.y), d.v(base.x, base.y - h), Rgba.hex(0xE8873A).u());
    c.ImDrawList_AddTriangleFilled(dl, d.v(base.x - w * 0.16, base.y), d.v(base.x + w * 0.16, base.y), d.v(base.x, base.y - h * 0.55), Rgba.hex(0x3A1F12).u());
    line(dl, d.v(base.x, base.y - h), d.v(base.x, base.y - h - s * 0.12), Rgba.hex(0x8A5A2B).u(), @max(1, s * 0.04));
}

/// A fogueira (lenha cruzada e chama; `t` mexe a chama de leve).
pub fn campfire(dl: *c.ImDrawList, base: c.ImVec2, s: f32, t: f32, alpha: f32) void {
    const lw = @max(1.5, s * 0.08);
    line(dl, d.v(base.x - s * 0.3, base.y), d.v(base.x + s * 0.3, base.y - s * 0.12), Rgba.hex(0x6B3E1E).col(alpha), lw);
    line(dl, d.v(base.x + s * 0.3, base.y), d.v(base.x - s * 0.3, base.y - s * 0.12), Rgba.hex(0x8A5A2B).col(alpha), lw);
    const fl = 1 + 0.12 * @sin(t * 3);
    c.ImDrawList_AddTriangleFilled(dl, d.v(base.x - s * 0.22, base.y - s * 0.06), d.v(base.x + s * 0.22, base.y - s * 0.06), d.v(base.x + s * 0.03, base.y - s * 0.62 * fl), Rgba.hex(0xFF6A1A).col(0.9 * alpha));
    c.ImDrawList_AddTriangleFilled(dl, d.v(base.x - s * 0.11, base.y - s * 0.06), d.v(base.x + s * 0.11, base.y - s * 0.06), d.v(base.x - s * 0.02, base.y - s * 0.38 * fl), Rgba.hex(0xFFE04A).col(alpha));
}

/// A plantinha no vaso (o fundo do vaso em `base`). `level` de 0 a 30 dias; murcha, o
/// caule tomba e as folhas ficam marrons.
pub fn plant(dl: *c.ImDrawList, base: c.ImVec2, s: f32, level: u8, wilted: bool) void {
    const lv: f32 = @floatFromInt(@min(level, 30));
    const pw = s * 0.5;
    const ph = s * 0.42;
    // O vaso.
    c.ImDrawList_AddQuadFilled(dl, d.v(base.x - pw / 2, base.y - ph), d.v(base.x + pw / 2, base.y - ph), d.v(base.x + pw * 0.36, base.y), d.v(base.x - pw * 0.36, base.y), Rgba.hex(0xC4683A).u());
    c.ImDrawList_AddRectFilledEx(dl, d.v(base.x - pw * 0.56, base.y - ph - s * 0.08), d.v(base.x + pw * 0.56, base.y - ph + s * 0.02), Rgba.hex(0xD9824F).u(), s * 0.03, 0);
    const soil = d.v(base.x, base.y - ph - s * 0.06);
    const green = if (wilted) Rgba.hex(0x8A7A4A) else Rgba.hex(0x4AD957);
    const dark = if (wilted) Rgba.hex(0x6A5A32) else Rgba.hex(0x2EA84A);
    // O caule cresce com os dias; murcho, entorta para o lado.
    const stem_h = s * (0.15 + lv * 0.035);
    const bend: f32 = if (wilted) 0.9 else 0.08;
    var pts: [8]c.ImVec2 = undefined;
    for (0..8) |i| {
        const f = @as(f32, @floatFromInt(i)) / 7.0;
        pts[i] = d.v(soil.x + @sin(f * bend * 1.6) * stem_h * bend * f, soil.y - stem_h * f * (1 - bend * f * 0.45));
    }
    c.ImDrawList_AddPolyline(dl, &pts, pts.len, dark.u(), @max(1.2, s * (0.04 + lv * 0.002)), 0);
    // Folhas ao longo do caule, alternando os lados.
    const n_leaves: usize = @min(7, 1 + @as(usize, @intFromFloat(lv / 4)));
    for (0..n_leaves) |i| {
        const f = (@as(f32, @floatFromInt(i)) + 1) / @as(f32, @floatFromInt(n_leaves + 1));
        const at = pts[@min(7, @as(usize, @intFromFloat(f * 7)))];
        const side: f32 = if (i % 2 == 0) -1 else 1;
        const droop: f32 = if (wilted) 0.9 else -0.35;
        quad(dl, d.v(at.x + side * s * 0.09, at.y + droop * s * 0.05), s * 0.16, s * 0.07, side * (0.5 + droop * 0.6), green.u());
    }
    const top = pts[7];
    if (lv >= 30 and !wilted) {
        // Uma arvorezinha: a copa redonda.
        for ([_][3]f32{ .{ 0, -0.12, 0.2 }, .{ -0.14, -0.02, 0.15 }, .{ 0.14, -0.02, 0.15 }, .{ 0, 0.06, 0.13 } }) |q|
            c.ImDrawList_AddCircleFilled(dl, d.v(top.x + q[0] * s, top.y + q[1] * s), q[2] * s, (if (q[1] < 0) green else dark).u(), 0);
        c.ImDrawList_AddCircleFilled(dl, d.v(top.x + s * 0.08, top.y - s * 0.16), s * 0.035, Rgba.hex(0xFF4A5A).u(), 0);
    } else if (lv >= 12 and !wilted) {
        // A florzinha.
        for (0..5) |i| {
            const a = @as(f32, @floatFromInt(i)) / 5.0 * tau;
            c.ImDrawList_AddCircleFilled(dl, d.v(top.x + @cos(a) * s * 0.06, top.y + @sin(a) * s * 0.06), s * 0.05, Rgba.hex(0xFF7AC0).u(), 0);
        }
        c.ImDrawList_AddCircleFilled(dl, top, s * 0.04, Rgba.hex(0xF7E04A).u(), 0);
    }
}

/// O regador na mão, com as gotas caindo no vaso.
pub fn wateringCan(dl: *c.ImDrawList, spout: c.ImVec2, s: f32, tilt: f32, t: f32) void {
    const body = d.v(spout.x + s * 0.3, spout.y + s * 0.05);
    quad(dl, body, s * 0.34, s * 0.26, -tilt, Rgba.hex(0x29B6E6).u());
    line(dl, d.v(body.x - s * 0.15, body.y), spout, Rgba.hex(0x1A8AB8).u(), @max(1.2, s * 0.06));
    if (tilt > 0.3) for (0..3) |i| {
        const fi: f32 = @floatFromInt(i);
        const f = @mod(t * 2.5 + fi / 3.0, 1);
        c.ImDrawList_AddCircleFilled(dl, d.v(spout.x - s * 0.02 + fi * s * 0.02, spout.y + f * s * 0.45), @max(0.8, s * 0.03), Rgba.hex(0x7ED6FF).col(1 - f * 0.5), 0);
    };
}

/// O balão de fala com a ponta em `tip` (embaixo dele).
pub fn balloon(dl: *c.ImDrawList, font: *c.ImFont, tip: c.ImVec2, text: []const u8, bg: Rgba, fg: Rgba, alpha: f32, win: d.Rect) void {
    const fs: f32 = 13;
    const tw = d.width(font, fs, text);
    const w = tw + 18;
    const h = d.fontPx(fs) + 12;
    const x = std.math.clamp(tip.x - w / 2, win.x + 6, win.right() - w - 6);
    const y = tip.y - 8 - h;
    c.ImDrawList_AddRectFilledEx(dl, d.v(x + 2, y + 3), d.v(x + w + 2, y + h + 3), Rgba.hex(0x000000).col(0.2 * alpha), h / 2, 0);
    c.ImDrawList_AddRectFilledEx(dl, d.v(x, y), d.v(x + w, y + h), bg.col(alpha), h / 2, 0);
    c.ImDrawList_AddTriangleFilled(dl, d.v(tip.x - 6, y + h - 1), d.v(tip.x + 6, y + h - 1), tip, bg.col(alpha));
    d.text(dl, font, fs, x + 9, y + 6, fg.alpha(alpha), text);
}
