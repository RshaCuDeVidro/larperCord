//! Fundos procedurais: `starfield`, `orbit`, `aurora`, `dunes`, `topography`, `radar`,
//! `rain`, `matrix`, `waves`, `particles`.
//! Parados por padrão: tudo sai de máscaras geradas uma vez (`procgen.zig`),
//! tingidas com os tokens do tema ao desenhar, então claro/escuro e cor de
//! destaque não geram nada de novo e um tema parado nunca acorda o laço.
//! Com `motion=#true` andam devagar (no máximo 15 redesenhos por segundo): só
//! desloca a textura ou desenha uma peça pequena por cima, nunca refaz o ruído.
//! "Reduzir movimento" e janela em segundo plano param o movimento.
const std = @import("std");
const c = @import("c");
const kdl = @import("../theme/kdl.zig");
const d = @import("draw.zig");
const fx = @import("fx.zig");
const anim = @import("anim.zig");
const procgen = @import("procgen.zig");
const qa = @import("qa.zig");

const Rect = d.Rect;

pub fn draw(ctx: *d.Ctx, n: *const kdl.Node, r: Rect) void {
    if (qa.on()) qa.mark(r, "backdrop:{s}", .{n.name});
    const moving = fx.motionAllowed(ctx, n);
    // Segundos desde sempre: só importa em quem se mexe.
    const t: f32 = if (moving) @floatCast(@as(f64, @floatFromInt(@mod(ctx.now_ms, 3_600_000))) / 1000) else 0;
    const seed: u32 = @intFromFloat(@abs(d.pnum(n, "seed", 7)));
    const name = n.name;
    if (std.mem.eql(u8, name, "starfield")) {
        starfield(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "aurora")) {
        aurora(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "dunes")) {
        dunes(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "topography")) {
        // As curvas de nível não têm o que animar: ficam sempre paradas.
        topography(ctx, n, r, seed);
        return;
    } else if (std.mem.eql(u8, name, "orbit")) {
        orbit(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "radar")) {
        radar(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "rain")) {
        rain(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "matrix")) {
        matrix(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "waves")) {
        waves(ctx, n, r, seed, t);
    } else if (std.mem.eql(u8, name, "particles")) {
        particles(ctx, n, r, seed, t);
    }
    if (moving) fx.wake(n);
}

/// Os nomes que este arquivo desenha (o papel de parede de quem usa os tira da frente).
pub fn isBackdrop(name: []const u8) bool {
    const names = [_][]const u8{ "starfield", "orbit", "aurora", "dunes", "topography", "radar", "rain", "matrix", "waves", "particles" };
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// Ladrilho desenhado em `scale`, deslizando `sx`/`sy` pixels. A textura é
/// presa à janela, então não treme quando o painel muda de tamanho.
fn drift(dl: *c.ImDrawList, tex: *c.SDL_Texture, r: Rect, side_w: f32, side_h: f32, sx: f32, sy: f32, col: u32) void {
    const ua = (r.x + sx) / side_w;
    const va = (r.y + sy) / side_h;
    c.ImDrawList_AddImageEx(dl, fx.refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(ua, va), d.v(ua + r.w / side_w, va + r.h / side_h), col);
}

fn starfield(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const density: u16 = @intFromFloat(std.math.clamp(d.pnum(n, "density", 1), 0.1, 6) * 100);
    const far = fx.nodeColor(ctx, n, "color", .faint);
    const near = fx.nodeColor(ctx, n, "color2", .accent);
    if (fx.texture(ctx, .{ .stars = .{ .layer = 0, .seed = seed, .density = density } })) |tex|
        drift(ctx.dl, tex, r, 512, 512, @mod(t * 0.7, 512), @mod(t * 0.2, 512), far.u());
    // A de perto repete em outro período: as duas nunca alinham de um jeito que
    // denuncie o ladrilho.
    if (fx.texture(ctx, .{ .stars = .{ .layer = 1, .seed = seed, .density = density } })) |tex|
        drift(ctx.dl, tex, r, 701, 701, @mod(t * 1.8, 701), @mod(t * 0.5, 701), near.u());
}

fn aurora(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const col1 = fx.nodeColor(ctx, n, "color", .accent);
    const col2 = fx.nodeColor(ctx, n, "color2", .link);
    const speeds = [2]f32{ 0.0035, -0.0022 };
    const cols = [2]d.Rgba{ col1, col2 };
    for (speeds, cols, 0..) |sp, col, li| {
        const tex = fx.texture(ctx, .{ .aurora = .{ .layer = @intCast(li), .seed = seed } }) orelse continue;
        const ua = @mod(t * sp, 1);
        // A cortina estica na janela inteira: é suave, escala sem aparecer.
        c.ImDrawList_AddImageEx(ctx.dl, fx.refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(ua, 0), d.v(ua + 1, 1), col.u());
    }
}

fn dunes(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const cols = [3]d.Rgba{ fx.nodeColor(ctx, n, "color", .elevated), fx.nodeColor(ctx, n, "color2", .accent), fx.nodeColor(ctx, n, "color3", .rail) };
    const speeds = [3]f32{ 0.0012, 0.002, 0.0032 };
    for (cols, speeds, 0..) |col, sp, li| {
        const tex = fx.texture(ctx, .{ .dunes = .{ .layer = @intCast(li), .seed = seed } }) orelse continue;
        const ua = @mod(t * sp, 1);
        c.ImDrawList_AddImageEx(ctx.dl, fx.refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(ua, 0), d.v(ua + 1, 1), col.u());
    }
}

fn densityOf(n: *const kdl.Node) u16 {
    return @intFromFloat(std.math.clamp(d.pnum(n, "density", 1), 0.1, 6) * 100);
}

/// Chuva: as gotas de longe caem devagar, as de perto mais rápido (e as duas seguem a
/// inclinação do vento). Só desliza os dois ladrilhos.
fn rain(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const tilt: i8 = @intFromFloat(std.math.clamp(d.pnum(n, "angle", 10), -45, 45));
    const slope = @tan(std.math.degreesToRadians(@as(f32, @floatFromInt(tilt))));
    const dens = densityOf(n);
    const cols = [2]d.Rgba{ fx.nodeColor(ctx, n, "color", .faint), fx.nodeColor(ctx, n, "color2", .muted) };
    const speeds = [2]f32{ 70, 150 };
    const sides = [2]f32{ 512, 640 };
    for (cols, speeds, sides, 0..) |col, sp, side, li| {
        const tex = fx.texture(ctx, .{ .rain = .{ .layer = @intCast(li), .seed = seed, .density = dens, .tilt = tilt } }) orelse continue;
        const fall = t * sp;
        drift(ctx.dl, tex, r, side, side, @mod(-fall * slope, side), @mod(-fall, side), col.u());
    }
}

/// Chuva de código: o ladrilho em faixas de 8 colunas, cada faixa descendo num
/// ritmo (são 4), para as colunas não andarem todas juntas. Parado, é um quad por camada.
fn matrix(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const dens = densityOf(n);
    const cols = [2]d.Rgba{ fx.nodeColor(ctx, n, "color", .online), fx.nodeColor(ctx, n, "color2", .text) };
    const side: f32 = 512;
    const strip: f32 = side / 4;
    const speeds = [4]f32{ 34, 52, 26, 44 };
    for (cols, 0..) |col, li| {
        const tex = fx.texture(ctx, .{ .matrix = .{ .layer = @intCast(li), .seed = seed, .density = dens } }) orelse continue;
        if (t == 0) {
            drift(ctx.dl, tex, r, side, side, 0, 0, col.u());
            continue;
        }
        // Faixas presas à janela, como o ladrilho: a de x em [k·128, (k+1)·128).
        var x = @floor(r.x / strip) * strip;
        while (x < r.right()) : (x += strip) {
            const x0 = @max(x, r.x);
            const x1 = @min(x + strip, r.right());
            if (x1 <= x0) continue;
            const g: usize = @intFromFloat(@mod(@floor(x / strip), 4));
            const sy = @mod(-t * speeds[g], side);
            const ua = x0 / side;
            const va = (r.y + sy) / side;
            c.ImDrawList_AddImageEx(ctx.dl, fx.refOf(tex), d.v(x0, r.y), d.v(x1, r.bottom()), d.v(ua, va), d.v(ua + (x1 - x0) / side, va + r.h / side), col.u());
        }
    }
}

/// Ondas: esticadas na área inteira, como a aurora; andando, as de trás vão para um
/// lado e as cristas para o outro.
fn waves(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const lines: u8 = @intFromFloat(std.math.clamp(d.pnum(n, "lines", 9), 2, 24));
    const cols = [2]d.Rgba{ fx.nodeColor(ctx, n, "color", .border), fx.nodeColor(ctx, n, "color2", .accent) };
    const speeds = [2]f32{ 0.004, -0.007 };
    for (cols, speeds, 0..) |col, sp, li| {
        const tex = fx.texture(ctx, .{ .waves = .{ .layer = @intCast(li), .seed = seed, .lines = lines } }) orelse continue;
        const ua = @mod(t * sp, 1);
        c.ImDrawList_AddImageEx(ctx.dl, fx.refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(ua, 0), d.v(ua + 1, 1), col.u());
    }
}

/// Partículas: a poeira sobe devagar, os discos de perto um pouco mais rápido e
/// para o outro lado; a de perto repete em outro período, como as estrelas.
fn particles(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const dens = densityOf(n);
    const far = fx.nodeColor(ctx, n, "color", .muted);
    const near = fx.nodeColor(ctx, n, "color2", .accent);
    if (fx.texture(ctx, .{ .particles = .{ .layer = 0, .seed = seed, .density = dens } })) |tex|
        drift(ctx.dl, tex, r, 512, 512, @mod(t * 1.5, 512), @mod(t * 5, 512), far.u());
    if (fx.texture(ctx, .{ .particles = .{ .layer = 1, .seed = seed, .density = dens } })) |tex|
        drift(ctx.dl, tex, r, 640, 640, @mod(-t * 2.5, 640), @mod(t * 11, 640), near.u());
}

fn topography(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32) void {
    const levels: u16 = @intFromFloat(std.math.clamp(d.pnum(n, "levels", 14), 4, 40));
    const tex = fx.texture(ctx, .{ .topography = .{ .seed = seed, .levels = levels } }) orelse return;
    drift(ctx.dl, tex, r, 1024, 1024, 0, 0, fx.nodeColor(ctx, n, "color", .faint).u());
}

// --- O que depende do tamanho ---------------------------------------------

/// Tamanho que um fundo pediu por último. Enquanto a janela está sendo
/// arrastada, estica a textura que já tem: refazer a cada quadro do arrasto
/// custaria caro; ela só é refeita 150 ms depois de o tamanho parar de mudar.
const Sized = struct {
    node: ?*const kdl.Node = null,
    w: u16 = 0,
    h: u16 = 0,
    since_ms: i64 = 0,
    shown: u64 = 0,
    spec: procgen.Spec = .{ .grain = 0 },
};

var sized: [4]Sized = @splat(.{});
var sized_next: usize = 0;

fn slotFor(n: *const kdl.Node) *Sized {
    for (&sized) |*s| if (s.node == n) return s;
    const s = &sized[sized_next];
    sized_next = (sized_next + 1) % sized.len;
    s.* = .{ .node = n };
    return s;
}

/// Tamanho da textura: pixels de verdade da tela, limitado a 2048 de lado.
fn pixelSize(ctx: *const d.Ctx, r: Rect) [2]u16 {
    const sc = ctx.io.*.DisplayFramebufferScale;
    const big = @max(r.w * sc.x, r.h * sc.y);
    const k = if (big > 2048) 2048 / big else 1;
    return .{ @intFromFloat(@max(r.w * sc.x * k, 1)), @intFromFloat(@max(r.h * sc.y * k, 1)) };
}

fn sizedTexture(ctx: *const d.Ctx, n: *const kdl.Node, spec: procgen.Spec, w: u16, h: u16) ?*c.SDL_Texture {
    const slot = slotFor(n);
    if (slot.w != w or slot.h != h) {
        slot.w = w;
        slot.h = h;
        slot.since_ms = ctx.now_ms;
    }
    if (fx.has(spec)) |tex| {
        slot.shown = spec.key();
        slot.spec = spec;
        return tex;
    }
    // Janela mudando: fica com a anterior e volta quando ela parar.
    if (slot.shown != 0 and ctx.now_ms - slot.since_ms < 150) {
        if (fx.has(slot.spec)) |old| {
            anim.at(slot.since_ms + 150);
            return old;
        }
    }
    slot.shown = spec.key();
    slot.spec = spec;
    return fx.texture(ctx, spec);
}

fn permille(n: *const kdl.Node, key: []const u8, default: f32) i16 {
    return @intFromFloat(std.math.clamp(d.pnum(n, key, default), -1, 2) * 1000);
}

fn image(dl: *c.ImDrawList, tex: *c.SDL_Texture, r: Rect, col: u32) void {
    c.ImDrawList_AddImageEx(dl, fx.refOf(tex), d.v(r.x, r.y), d.v(r.right(), r.bottom()), d.v(0, 0), d.v(1, 1), col);
}

fn orbit(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const sz = pixelSize(ctx, r);
    const o: procgen.Orbit = .{
        .w = sz[0],
        .h = sz[1],
        .cx = permille(n, "center-x", 0.7),
        .cy = permille(n, "center-y", 0.35),
        .rings = @intFromFloat(std.math.clamp(d.pnum(n, "rings", 6), 1, 12)),
        .seed = seed,
    };
    const tex = sizedTexture(ctx, n, .{ .orbit = o }, sz[0], sz[1]) orelse return;
    image(ctx.dl, tex, r, fx.nodeColor(ctx, n, "color", .border).u());
    // As luas: poucos círculos por cima da textura, em órbitas diferentes.
    const moon = fx.nodeColor(ctx, n, "color2", .accent);
    const kx = r.w / @as(f32, @floatFromInt(sz[0]));
    const ky = r.h / @as(f32, @floatFromInt(sz[1]));
    var rng: u32 = seed *% 2654435761 | 1;
    for (0..o.rings) |i| {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        if (i % 2 == 0 and i != 0) continue;
        const phase = @as(f32, @floatFromInt(rng >> 16)) / 65536 * std.math.tau;
        // Quanto mais longe, mais devagar (como manda Kepler, a olho).
        const speed = 0.05 / (1 + @as(f32, @floatFromInt(i)));
        const p = procgen.orbitEllipse(o, i).at(phase + t * speed);
        const px = r.x + p[0] * kx;
        const py = r.y + p[1] * ky;
        if (!r.contains(px, py)) continue;
        d.circle(ctx.dl, px, py, 4.5, moon.alpha(0.18));
        d.circle(ctx.dl, px, py, 2.2, moon);
    }
}

fn radar(ctx: *d.Ctx, n: *const kdl.Node, r: Rect, seed: u32, t: f32) void {
    const sz = pixelSize(ctx, r);
    const o: procgen.Radar = .{
        .w = sz[0],
        .h = sz[1],
        .cx = permille(n, "center-x", 0.5),
        .cy = permille(n, "center-y", 0.5),
        .rings = @intFromFloat(std.math.clamp(d.pnum(n, "rings", 5), 1, 12)),
        .seed = seed,
    };
    const tex = sizedTexture(ctx, n, .{ .radar = o }, sz[0], sz[1]) orelse return;
    image(ctx.dl, tex, r, fx.nodeColor(ctx, n, "color", .border).u());
    // A varredura: um leque com o alfa sumindo para trás. Parado, fica num
    // ângulo fixo; andando, dá uma volta a cada 8 s.
    const sweep = fx.nodeColor(ctx, n, "color2", .accent);
    const kx = r.w / @as(f32, @floatFromInt(sz[0]));
    const cx = r.x + r.w * @as(f32, @floatFromInt(o.cx)) / 1000;
    const cy = r.y + r.h * @as(f32, @floatFromInt(o.cy)) / 1000;
    const big = procgen.radarRadius(o) * kx;
    const head = -0.7 + t * (std.math.tau / 8.0);
    const arc: f32 = 0.9;
    const steps = 18;
    const dl = ctx.dl;
    var pts: [steps + 2]c.ImVec2 = undefined;
    pts[0] = d.v(cx, cy);
    for (0..steps + 1) |i| {
        const ang = head - arc * (1 - @as(f32, @floatFromInt(i)) / steps);
        pts[i + 1] = d.v(cx + big * @cos(ang), cy + big * @sin(ang));
    }
    const start = dl.*.VtxBuffer.Size;
    c.ImDrawList_AddConvexPolyFilled(dl, &pts, pts.len, sweep.u(), 0);
    // Alfa pelo ângulo de cada vértice: forte na frente, some para trás.
    for (dl.*.VtxBuffer.Data[@intCast(start)..@intCast(dl.*.VtxBuffer.Size)]) |*p| {
        const dx = p.pos.x - cx;
        const dy = p.pos.y - cy;
        const back = @mod(head - std.math.atan2(dy, dx), std.math.tau);
        const k = 1 - std.math.clamp(back / arc, 0, 1);
        const near_center = dx * dx + dy * dy < 4;
        const a: f32 = @as(f32, @floatFromInt((p.col >> 24) & 0xff)) / 255;
        p.col = sweep.col(a * (if (near_center) 0.1 else 0.18 * k * k));
    }
    d.line(dl, cx, cy, cx + big * @cos(head), cy + big * @sin(head), sweep.alpha(0.4), 1.2);
}
