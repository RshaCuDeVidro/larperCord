//! As contas do papel de parede (`ui/wallpaper.zig`), sem SDL: onde a imagem cai
//! em cada `fit`, até onde reduzir ao carregar, a cópia pequena com desfoque, e o
//! quanto os painéis de um tema sem lugar para a imagem podem ficar translúcidos
//! sem o texto perder contraste.
const std = @import("std");
const color = @import("../theme/color.zig");
const Rgba = color.Rgba;

pub const Fit = enum { cover, contain, tile, center };

/// Um retângulo na tela e o pedaço da textura (0..1; no `tile`, passa de 1 e repete).
pub const Quad = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,
};

/// Onde a imagem cai no retângulo `x, y, w, h`. `nat_w`×`nat_h` é o tamanho próprio
/// dela na tela (usado por `center` e `tile`; `cover` e `contain` só olham a proporção).
/// Nada sai do retângulo: o que sobra é cortado pela coordenada da textura.
pub fn place(fit: Fit, nat_w: f32, nat_h: f32, x: f32, y: f32, w: f32, h: f32) Quad {
    if (nat_w <= 0 or nat_h <= 0 or w <= 0 or h <= 0) return .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y };
    switch (fit) {
        .cover => {
            // Escala que cobre os dois lados; o excesso sai igual dos dois lados.
            const s = @max(w / nat_w, h / nat_h);
            const uw = w / (nat_w * s);
            const vh = h / (nat_h * s);
            return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h, .u0 = (1 - uw) / 2, .v0 = (1 - vh) / 2, .u1 = (1 + uw) / 2, .v1 = (1 + vh) / 2 };
        },
        .contain => {
            const s = @min(w / nat_w, h / nat_h);
            const cw = nat_w * s;
            const ch = nat_h * s;
            const ox = x + (w - cw) / 2;
            const oy = y + (h - ch) / 2;
            return .{ .x0 = ox, .y0 = oy, .x1 = ox + cw, .y1 = oy + ch };
        },
        .center => {
            const ox = x + (w - nat_w) / 2;
            const oy = y + (h - nat_h) / 2;
            const x0 = @max(ox, x);
            const y0 = @max(oy, y);
            const x1 = @min(ox + nat_w, x + w);
            const y1 = @min(oy + nat_h, y + h);
            return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .u0 = (x0 - ox) / nat_w, .v0 = (y0 - oy) / nat_h, .u1 = (x1 - ox) / nat_w, .v1 = (y1 - oy) / nat_h };
        },
        // Repetida a partir do canto do retângulo, no tamanho dela.
        .tile => return .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h, .u1 = w / nat_w, .v1 = h / nat_h },
    }
}

/// Tamanho em que a imagem `src_w`×`src_h` é guardada: o que cobre a janela de
/// `win_w`×`win_h` pixels, nunca maior que a original.
pub fn coverSize(src_w: u32, src_h: u32, win_w: u32, win_h: u32) [2]u32 {
    const fw: f32 = @floatFromInt(@max(src_w, 1));
    const fh: f32 = @floatFromInt(@max(src_h, 1));
    const k = @min(1.0, @max(@as(f32, @floatFromInt(@max(win_w, 1))) / fw, @as(f32, @floatFromInt(@max(win_h, 1))) / fh));
    return .{ @intFromFloat(@max(@ceil(fw * k), 1)), @intFromFloat(@max(@ceil(fh * k), 1)) };
}

/// O limite pedido ao carregar: a janela arredondada para cima em degraus de 256,
/// para um arrasto de alguns pixels não pedir outra carga.
pub fn bound(win_px: u32) u32 {
    return @min((@max(win_px, 1) + 255) / 256 * 256, 8192);
}

/// A janela cresceu além do que foi carregado e a original tem mais para dar?
/// (Uma carga por degrau; diminuir nunca recarrega.)
pub fn needsReload(loaded: [2]u32, win: [2]u32, src: [2]u32, tex: [2]u32) bool {
    const grew = bound(win[0]) > loaded[0] or bound(win[1]) > loaded[1];
    const reduced = tex[0] < src[0] or tex[1] < src[1];
    return grew and reduced;
}

/// Desfoque de caixa (3 passadas = quase gaussiano) no RGBA `px`, com raio `r`
/// pixels. `tmp` tem o tamanho de `px`. Roda uma vez, na cópia pequena.
pub fn blur(px: []u8, w: u32, h: u32, r: u32, tmp: []u8) void {
    if (r == 0 or w == 0 or h == 0) return;
    for (0..3) |_| {
        boxPass(px, tmp, w, h, r, true);
        boxPass(tmp, px, w, h, r, false);
    }
}

/// Uma passada (na horizontal ou na vertical) com soma corrida: o custo não depende
/// do raio. A borda repete o último pixel.
fn boxPass(src: []const u8, dst: []u8, w: u32, h: u32, r: u32, horiz: bool) void {
    const n = if (horiz) w else h;
    const lines = if (horiz) h else w;
    const ri: i64 = r;
    const div: u32 = 2 * r + 1;
    for (0..lines) |li| {
        const at = struct {
            fn f(hz: bool, ww: u32, line: usize, i: usize) usize {
                return if (hz) (line * ww + i) * 4 else (i * ww + line) * 4;
            }
        }.f;
        var acc: [4]u32 = .{ 0, 0, 0, 0 };
        var k: i64 = -ri;
        while (k <= ri) : (k += 1) {
            const i: usize = @intCast(std.math.clamp(k, 0, @as(i64, n) - 1));
            for (0..4) |ch| acc[ch] += src[at(horiz, w, li, i) + ch];
        }
        for (0..n) |i| {
            for (0..4) |ch| dst[at(horiz, w, li, i) + ch] = @intCast(acc[ch] / div);
            const out: usize = @intCast(std.math.clamp(@as(i64, @intCast(i)) - ri, 0, @as(i64, n) - 1));
            const in: usize = @intCast(std.math.clamp(@as(i64, @intCast(i)) + ri + 1, 0, @as(i64, n) - 1));
            for (0..4) |ch| acc[ch] = acc[ch] + src[at(horiz, w, li, in) + ch] - src[at(horiz, w, li, out) + ch];
        }
    }
}

fn channelLinear(x: f32) f32 {
    return if (x <= 0.03928) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

/// O cinza (sRGB) com essa luminância relativa.
pub fn grayOf(lum: f32) Rgba {
    const l = std.math.clamp(lum, 0, 1);
    const g = if (l <= 0.0031308) l * 12.92 else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
    return .{ .r = g, .g = g, .b = g };
}

/// A faixa de luminância da imagem: o 5º e o 95º percentil (um pontinho branco numa
/// foto escura não manda em tudo). `px` é RGBA.
pub fn lumRange(px: []const u8) [2]f32 {
    var hist: [64]u32 = @splat(0);
    var n: u32 = 0;
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        const rgb: Rgba = .{ .r = @as(f32, @floatFromInt(px[i])) / 255, .g = @as(f32, @floatFromInt(px[i + 1])) / 255, .b = @as(f32, @floatFromInt(px[i + 2])) / 255 };
        const l = 0.2126 * channelLinear(rgb.r) + 0.7152 * channelLinear(rgb.g) + 0.0722 * channelLinear(rgb.b);
        hist[@min(@as(usize, @intFromFloat(l * 64)), 63)] += 1;
        n += 1;
    }
    if (n == 0) return .{ 0, 1 };
    var lo: f32 = 0;
    var hi: f32 = 1;
    var seen: u32 = 0;
    var got_lo = false;
    for (hist, 0..) |count, b| {
        seen += count;
        if (!got_lo and seen * 20 >= n) {
            lo = @as(f32, @floatFromInt(b)) / 64;
            got_lo = true;
        }
        if (seen * 20 >= n * 19) {
            hi = @as(f32, @floatFromInt(b + 1)) / 64;
            break;
        }
    }
    return .{ lo, hi };
}

pub const Glass = struct {
    /// Quanto do alfa dos painéis fica (1 = como o tema desenha).
    alpha: f32,
    /// Quanto a imagem escurece em direção ao `bg` (o da pessoa, ou mais, se o
    /// contraste pedir).
    dim: f32,
};

/// Painel translúcido sobre a imagem já escurecida: a cor que o texto vê.
pub fn composite(panel: Rgba, bg: Rgba, wall: Rgba, dim: f32, k: f32) Rgba {
    const under = wall.mix(solid(bg), dim);
    return under.mix(solid(panel), std.math.clamp(panel.a * k, 0, 1));
}

fn solid(x: Rgba) Rgba {
    return .{ .r = x.r, .g = x.g, .b = x.b };
}

/// Para um tema sem lugar para a imagem: o menor alfa dos painéis (de 0,55 a 1) que
/// mantém `text` com 7:1 e `muted` com 4,5:1 (ou o que eles já tinham, se era menos)
/// sobre cada cor de `panels`, com a imagem mais clara e a mais escura da faixa
/// `lum`. Nem com painel cheio dá? Escurece mais a imagem.
pub fn glass(panels: []const Rgba, bg: Rgba, text: Rgba, muted: Rgba, user_dim: f32, lum: [2]f32) Glass {
    const walls = [2]Rgba{ grayOf(lum[0]), grayOf(lum[1]) };
    var dim = std.math.clamp(user_dim, 0, 0.95);
    while (true) : (dim += 0.05) {
        var k: f32 = 0.55;
        while (k <= 1.0001) : (k += 0.02) {
            if (passes(panels, bg, text, muted, walls, dim, k)) return .{ .alpha = @min(k, 1), .dim = dim };
        }
        if (dim >= 0.95) return .{ .alpha = 1, .dim = 0.95 };
    }
}

fn passes(panels: []const Rgba, bg: Rgba, text: Rgba, muted: Rgba, walls: [2]Rgba, dim: f32, k: f32) bool {
    for (panels) |p| {
        // A referência é o painel sem imagem nenhuma atrás (sobre o próprio fundo).
        const ref = solid(bg).mix(solid(p), p.a);
        const want_text = @min(7, solid(text).contrast(ref)) - 0.01;
        const want_muted = @min(4.5, solid(muted).contrast(ref)) - 0.01;
        for (walls) |w| {
            const cpx = composite(p, bg, w, dim, k);
            if (solid(text).contrast(cpx) < want_text) return false;
            if (solid(muted).contrast(cpx) < want_muted) return false;
        }
    }
    return true;
}

// --- Testes ----------------------------------------------------------------

const testing = std.testing;

test "fit: cover corta igual dos dois lados, contain cabe inteiro, center e tile no tamanho dela" {
    // Imagem 2:1 num retângulo quadrado: cover mostra a metade do meio.
    const cv = place(.cover, 200, 100, 10, 20, 100, 100);
    try testing.expectEqual(@as(f32, 10), cv.x0);
    try testing.expectEqual(@as(f32, 120), cv.y1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cv.u0, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.75), cv.u1, 1e-5);
    try testing.expectEqual(@as(f32, 0), cv.v0);
    try testing.expectEqual(@as(f32, 1), cv.v1);
    // Imagem alta num retângulo largo: corta em cima e embaixo.
    const tall = place(.cover, 100, 400, 0, 0, 200, 100);
    try testing.expectApproxEqAbs(@as(f32, 0.4375), tall.v0, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5625), tall.v1, 1e-5);
    // contain: faixas dos lados, a imagem inteira.
    const ct = place(.contain, 200, 100, 0, 0, 100, 100);
    try testing.expectEqual(@as(f32, 0), ct.x0);
    try testing.expectEqual(@as(f32, 25), ct.y0);
    try testing.expectEqual(@as(f32, 75), ct.y1);
    try testing.expectEqual(@as(f32, 1), ct.u1);
    // center menor que o retângulo: no meio, inteira.
    const cs = place(.center, 40, 20, 0, 0, 100, 100);
    try testing.expectEqual(@as(f32, 30), cs.x0);
    try testing.expectEqual(@as(f32, 40), cs.y0);
    try testing.expectEqual(@as(f32, 0), cs.u0);
    try testing.expectEqual(@as(f32, 1), cs.v1);
    // center maior: cortada, o pedaço do meio.
    const cb = place(.center, 400, 100, 0, 0, 100, 100);
    try testing.expectEqual(@as(f32, 0), cb.x0);
    try testing.expectEqual(@as(f32, 100), cb.x1);
    try testing.expectApproxEqAbs(@as(f32, 0.375), cb.u0, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.625), cb.u1, 1e-5);
    try testing.expectEqual(@as(f32, 0), cb.y0 - 0);
    // tile: 2,5 repetições na largura.
    const tl = place(.tile, 40, 50, 5, 5, 100, 100);
    try testing.expectApproxEqAbs(@as(f32, 2.5), tl.u1, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2), tl.v1, 1e-5);
    // Sem tamanho: nada.
    const none = place(.cover, 0, 10, 0, 0, 100, 100);
    try testing.expectEqual(none.x0, none.x1);
}

test "redução: cobre a janela, nunca aumenta; recarrega só quando cresce de degrau" {
    try testing.expectEqual([2]u32{ 2160, 1080 }, coverSize(4000, 2000, 1920, 1080));
    try testing.expectEqual([2]u32{ 1920, 1080 }, coverSize(3840, 2160, 1920, 1080));
    // Foto em pé numa janela deitada: a largura cobre, a altura passa.
    try testing.expectEqual([2]u32{ 1920, 2560 }, coverSize(3000, 4000, 1920, 1080));
    // Menor que a janela: fica como é.
    try testing.expectEqual([2]u32{ 800, 600 }, coverSize(800, 600, 1920, 1080));
    try testing.expectEqual(@as(u32, 1280), bound(1280));
    try testing.expectEqual(@as(u32, 1536), bound(1281));
    try testing.expectEqual(@as(u32, 8192), bound(20000));
    // Carregada para 1280×768 e reduzida: cresceu de degrau, recarrega; poucos pixels, não.
    try testing.expect(needsReload(.{ 1280, 768 }, .{ 1600, 900 }, .{ 4000, 3000 }, .{ 1280, 960 }));
    try testing.expect(!needsReload(.{ 1280, 768 }, .{ 1270, 760 }, .{ 4000, 3000 }, .{ 1280, 960 }));
    // A original já cabia inteira: não tem o que ganhar.
    try testing.expect(!needsReload(.{ 1280, 768 }, .{ 2560, 1440 }, .{ 800, 600 }, .{ 800, 600 }));
}

test "desfoque: espalha um ponto e guarda a soma" {
    const w = 16;
    const h = 16;
    var px: [w * h * 4]u8 = @splat(0);
    var tmp: [w * h * 4]u8 = undefined;
    px[(8 * w + 8) * 4] = 255;
    blur(&px, w, h, 1, &tmp);
    var total: u32 = 0;
    for (0..w * h) |i| total += px[i * 4];
    try testing.expect(px[(8 * w + 8) * 4] < 255);
    try testing.expect(px[(8 * w + 10) * 4] > 0);
    try testing.expectEqual(@as(u8, 0), px[(0 * w + 0) * 4]);
    // O arredondamento para baixo perde um pouco a cada passada.
    try testing.expect(total > 150 and total <= 255);
    // Imagem lisa continua lisa.
    var flat: [w * h * 4]u8 = @splat(90);
    blur(&flat, w, h, 3, &tmp);
    for (flat) |v| try testing.expectEqual(@as(u8, 90), v);
}

test "faixa de luminância: preto, branco e meio a meio" {
    var px: [400 * 4]u8 = @splat(0);
    for (0..400) |i| px[i * 4 + 3] = 255;
    const black = lumRange(&px);
    try testing.expect(black[1] <= 1.0 / 64.0 + 1e-6);
    for (200..400) |i| @memset(px[i * 4 ..][0..3], 255);
    const half = lumRange(&px);
    try testing.expect(half[0] < 0.02 and half[1] > 0.98);
    try testing.expectApproxEqAbs(@as(f32, 0.5), grayOf(0.214).r, 0.01);
}

test "vidro: painel escuro sobre foto escura fica bem translúcido; sobre branco, menos" {
    const bg = Rgba.hex(0x1e1f22);
    const panels = [_]Rgba{ bg, Rgba.hex(0x2b2d31) };
    const text = Rgba.hex(0xf2f3f5);
    const muted = Rgba.hex(0xa0a4ab);
    const dark = glass(&panels, bg, text, muted, 0.4, .{ 0, 0.05 });
    const bright = glass(&panels, bg, text, muted, 0.4, .{ 0.6, 1 });
    try testing.expect(dark.alpha < 0.7);
    try testing.expect(bright.alpha > dark.alpha);
    try testing.expectEqual(@as(f32, 0.4), dark.dim);
}

test "vidro em todos os temas embutidos, no escuro e no claro: o texto continua legível" {
    const builtin_themes = @import("builtin_themes");
    const theme = @import("../theme/theme.zig");
    for (builtin_themes.list) |b| for ([_]theme.Mode{ .dark, .light }) |mode| {
        var t = try theme.loadWith(testing.allocator, b.source, .{ .mode = mode }, null);
        defer t.deinit();
        const panels = [_]Rgba{ t.c(.bg), t.c(.sidebar), t.c(.surface) };
        // Fotos de todo tipo: escura, clara, de contraste alto.
        for ([_][2]f32{ .{ 0, 0.04 }, .{ 0.7, 1 }, .{ 0, 1 } }) |lum| for ([_]f32{ 0, 0.45, 0.9 }) |dim| {
            const g = glass(&panels, t.c(.bg), t.c(.text), t.c(.muted), dim, lum);
            try testing.expect(g.alpha >= 0.55 and g.alpha <= 1);
            try testing.expect(g.dim >= dim - 1e-4);
            for (panels) |p| {
                const ref = solid(t.c(.bg)).mix(solid(p), p.a);
                for ([_]f32{ lum[0], lum[1] }) |l| {
                    const cpx = composite(p, t.c(.bg), grayOf(l), g.dim, g.alpha);
                    const ct = solid(t.c(.text)).contrast(cpx);
                    const cm = solid(t.c(.muted)).contrast(cpx);
                    if (ct < @min(7, solid(t.c(.text)).contrast(ref)) - 0.02 or cm < @min(4.5, solid(t.c(.muted)).contrast(ref)) - 0.02) {
                        std.debug.print("tema {s} ({t}) lum {any} dim {d}: texto {d:.2}, muted {d:.2}\n", .{ b.name, mode, lum, dim, ct, cm });
                        return error.PoucoContraste;
                    }
                }
            }
        };
        // Foto escura no tema escuro (e clara no claro): a imagem aparece de verdade.
        const calm: [2]f32 = if (mode == .dark) .{ 0, 0.03 } else .{ 0.85, 1 };
        const g = glass(&panels, t.c(.bg), t.c(.text), t.c(.muted), 0.45, calm);
        if (g.alpha > 0.9) {
            std.debug.print("tema {s} ({t}): painel {d:.2} com foto calma\n", .{ b.name, mode, g.alpha });
            return error.ImagemNaoAparece;
        }
    };
}
