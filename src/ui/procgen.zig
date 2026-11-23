//! Gera as texturas pequenas dos temas: grão, padrões, vinheta, gradiente de 3
//! paradas e os fundos procedurais. Só contas em cima de um vetor RGBA (nada de
//! SDL aqui), rodadas uma vez e guardadas em textura por `ui/fx.zig`.
//!
//! Quase tudo é uma **máscara**: branco com a forma no alfa, tingida ao desenhar
//! (a cor do vértice multiplica). Trocar de tema, de modo ou de cor de destaque
//! não gera nada de novo; só o que depende do tamanho é refeito ao redimensionar.
const std = @import("std");

pub const PatternKind = enum { dots, lines, grid, diagonal };

pub const Orbit = struct {
    w: u16,
    h: u16,
    /// Centro em milésimos da largura/altura.
    cx: i16 = 700,
    cy: i16 = 350,
    rings: u8 = 6,
    seed: u32 = 1,
};

pub const Radar = struct {
    w: u16,
    h: u16,
    cx: i16 = 500,
    cy: i16 = 500,
    rings: u8 = 5,
    seed: u32 = 1,
};

pub const Spec = union(enum) {
    grain: u32,
    pattern: struct { kind: PatternKind, size: u16, width_q: u16 },
    dash: struct { dash: u16, gap: u16 },
    vignette: u16,
    gradient: struct { c: [3]u32, ax: i16, ay: i16 },
    stars: struct { layer: u8, seed: u32, density: u16 },
    aurora: struct { layer: u8, seed: u32 },
    topography: struct { seed: u32, levels: u16 },
    dunes: struct { layer: u8, seed: u32 },
    /// Canto de sombra macia; `round` é o raio em milésimos do lado do bloco.
    shadow: u16,
    orbit: Orbit,
    radar: Radar,
    /// `tilt` em graus (a chuva inclinada pelo vento).
    rain: struct { layer: u8, seed: u32, density: u16, tilt: i8 },
    matrix: struct { layer: u8, seed: u32, density: u16 },
    waves: struct { layer: u8, seed: u32, lines: u8 },
    particles: struct { layer: u8, seed: u32, density: u16 },

    /// Tamanho da textura. Os ladrilhos têm lado potência de 2 quando vão
    /// repetir: é o único caso em que todo renderizador garante a repetição.
    pub fn size(s: Spec) [2]u32 {
        return switch (s) {
            .grain, .vignette => .{ 128, 128 },
            .shadow => .{ 64, 64 },
            .pattern => |p| .{ p.size, p.size },
            .dash => |p| .{ @as(u32, p.dash) + p.gap, 1 },
            .gradient => .{ 64, 64 },
            .stars => .{ 512, 512 },
            .aurora, .dunes => .{ 512, 256 },
            .topography => .{ 1024, 1024 },
            .orbit => |o| .{ o.w, o.h },
            .radar => |o| .{ o.w, o.h },
            .rain, .matrix, .particles => .{ 512, 512 },
            .waves => .{ 1024, 512 },
        };
    }

    pub fn key(s: Spec) u64 {
        var h = std.hash.Wyhash.init(0x7e7a5);
        std.hash.autoHash(&h, s);
        return h.final();
    }
};

const tau = std.math.tau;

/// Preenche `px` (RGBA, largura × altura de `spec.size()`).
pub fn render(spec: Spec, px: []u8, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const sz = spec.size();
    const m: Mask = .{ .px = px, .w = sz[0], .h = sz[1] };
    if (spec != .gradient) m.clear();
    switch (spec) {
        .grain => |seed| grain(m, seed),
        .pattern => |p| pattern(m, p.kind, @as(f32, @floatFromInt(p.width_q)) / 8),
        .dash => |p| for (0..p.dash) |x| m.set(@intCast(x), 0, 255),
        .vignette => |q| vignette(m, @as(f32, @floatFromInt(q)) / 100),
        .gradient => |g| gradient(px, sz[0], sz[1], g.c, @as(f32, @floatFromInt(g.ax)) / 1024, @as(f32, @floatFromInt(g.ay)) / 1024),
        .stars => |st| stars(m, st.layer, st.seed, @as(f32, @floatFromInt(st.density)) / 100),
        .aurora => |a| aurora(m, a.layer, a.seed),
        .dunes => |a| dunes(m, a.layer, a.seed),
        .shadow => |q| shadowCorner(m, @as(f32, @floatFromInt(q)) / 1000),
        .topography => |t| try topography(m, t.seed, t.levels, gpa),
        .orbit => |o| orbit(m, o),
        .radar => |o| radar(m, o),
        .rain => |o| rain(m, o.layer, o.seed, @as(f32, @floatFromInt(o.density)) / 100, o.tilt),
        .matrix => |o| matrix(m, o.layer, o.seed, @as(f32, @floatFromInt(o.density)) / 100),
        .waves => |o| waves(m, o.layer, o.seed, o.lines),
        .particles => |o| particles(m, o.layer, o.seed, @as(f32, @floatFromInt(o.density)) / 100),
    }
}

const Mask = struct {
    px: []u8,
    w: u32,
    h: u32,

    /// Branco e transparente: o filtro linear não escurece as bordas.
    fn clear(m: Mask) void {
        var i: usize = 0;
        while (i < m.px.len) : (i += 4) {
            m.px[i] = 255;
            m.px[i + 1] = 255;
            m.px[i + 2] = 255;
            m.px[i + 3] = 0;
        }
    }

    fn set(m: Mask, x: u32, y: u32, a: u8) void {
        m.px[(y * m.w + x) * 4 + 3] = a;
    }

    fn get(m: Mask, x: u32, y: u32) u8 {
        return m.px[(y * m.w + x) * 4 + 3];
    }

    /// Fica com o maior alfa (traços que se cruzam não somam brilho).
    fn lift(m: Mask, x: i32, y: i32, a: f32) void {
        if (x < 0 or y < 0 or x >= m.w or y >= m.h) return;
        const v: u8 = @intFromFloat(std.math.clamp(a, 0, 1) * 255 + 0.5);
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (v > m.get(ux, uy)) m.set(ux, uy, v);
    }

    /// Como `lift`, dando a volta nas bordas (ladrilho sem emenda).
    fn liftWrap(m: Mask, x: i32, y: i32, a: f32) void {
        m.lift(@mod(x, @as(i32, @intCast(m.w))), @mod(y, @as(i32, @intCast(m.h))), a);
    }

    /// Como `plot`, dando a volta nas bordas.
    fn plotWrap(m: Mask, x: f32, y: f32, a: f32) void {
        const fx = x - 0.5;
        const fy = y - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        const dx = fx - x0;
        const dy = fy - y0;
        const ix: i32 = @intFromFloat(x0);
        const iy: i32 = @intFromFloat(y0);
        m.liftWrap(ix, iy, a * (1 - dx) * (1 - dy));
        m.liftWrap(ix + 1, iy, a * dx * (1 - dy));
        m.liftWrap(ix, iy + 1, a * (1 - dx) * dy);
        m.liftWrap(ix + 1, iy + 1, a * dx * dy);
    }

    /// Ponto com posição fracionária, dividido entre os 4 pixels em volta.
    /// Andando em passos curtos sobre uma curva, dá uma linha suavizada.
    fn plot(m: Mask, x: f32, y: f32, a: f32) void {
        const fx = x - 0.5;
        const fy = y - 0.5;
        const x0 = @floor(fx);
        const y0 = @floor(fy);
        const dx = fx - x0;
        const dy = fy - y0;
        const ix: i32 = @intFromFloat(x0);
        const iy: i32 = @intFromFloat(y0);
        m.lift(ix, iy, a * (1 - dx) * (1 - dy));
        m.lift(ix + 1, iy, a * dx * (1 - dy));
        m.lift(ix, iy + 1, a * (1 - dx) * dy);
        m.lift(ix + 1, iy + 1, a * dx * dy);
    }
};

/// xorshift: pequeno, sem estado global e igual em todas as execuções.
const Rng = struct {
    s: u32,

    fn init(seed: u32) Rng {
        return .{ .s = (seed *% 2654435761) | 1 };
    }

    fn next(r: *Rng) u32 {
        var x = r.s;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        r.s = x;
        return x;
    }

    fn f(r: *Rng) f32 {
        return @as(f32, @floatFromInt(r.next() >> 8)) / @as(f32, 1 << 24);
    }
};

fn smoothstep(a: f32, b: f32, x: f32) f32 {
    const t = std.math.clamp((x - a) / @max(b - a, 0.0001), 0, 1);
    return t * t * (3 - 2 * t);
}

fn fl(x: anytype) f32 {
    return @floatFromInt(x);
}

fn grain(m: Mask, seed: u32) void {
    var r = Rng.init(seed);
    for (0..m.h) |y| for (0..m.w) |x| {
        // Mais pontos fracos que fortes: textura, não chuvisco.
        const v = r.f();
        m.set(@intCast(x), @intCast(y), @intFromFloat(v * v * 255));
    };
}

fn pattern(m: Mask, kind: PatternKind, width: f32) void {
    const s = fl(m.w);
    const c = s / 2;
    for (0..m.h) |yi| for (0..m.w) |xi| {
        const x = fl(xi) + 0.5;
        const y = fl(yi) + 0.5;
        const a: f32 = switch (kind) {
            .dots => std.math.clamp(width + 0.5 - std.math.hypot(x - c, y - c), 0, 1),
            .lines => std.math.clamp(width / 2 + 0.5 - @abs(y - c), 0, 1),
            .grid => @max(
                std.math.clamp(width / 2 + 0.5 - @abs(y - c), 0, 1),
                std.math.clamp(width / 2 + 0.5 - @abs(x - c), 0, 1),
            ),
            .diagonal => blk: {
                // Distância à diagonal x+y = s, que encaixa nas bordas do ladrilho.
                const d = @abs(@mod(x + y + s / 2, s) - s / 2) / std.math.sqrt2;
                break :blk std.math.clamp(width / 2 + 0.5 - d, 0, 1);
            },
        };
        m.set(@intCast(xi), @intCast(yi), @intFromFloat(a * 255));
    };
}

fn vignette(m: Mask, start: f32) void {
    for (0..m.h) |yi| for (0..m.w) |xi| {
        const u = (fl(xi) + 0.5) / fl(m.w) * 2 - 1;
        const v = (fl(yi) + 0.5) / fl(m.h) * 2 - 1;
        const d = std.math.hypot(u, v) / std.math.sqrt2;
        m.set(@intCast(xi), @intCast(yi), @intFromFloat(smoothstep(start, 1, d) * 255));
    };
}

/// Gradiente de 3 paradas (0, ½ e 1) como cor de verdade. `c` são RGBA8 e a
/// direção vem em coordenadas da textura (`|ax| + |ay| = 1`), então a mesma
/// textura serve para qualquer tamanho com a mesma proporção.
fn gradient(px: []u8, w: u32, h: u32, c: [3]u32, ax: f32, ay: f32) void {
    for (0..h) |yi| for (0..w) |xi| {
        const u = (fl(xi) + 0.5) / fl(w) - 0.5;
        const v = (fl(yi) + 0.5) / fl(h) - 0.5;
        const t = std.math.clamp(0.5 + ax * u + ay * v, 0, 1);
        const k = if (t < 0.5) t * 2 else (t - 0.5) * 2;
        const a = if (t < 0.5) c[0] else c[1];
        const b = if (t < 0.5) c[1] else c[2];
        const o = (yi * w + xi) * 4;
        for (0..4) |ch| {
            const sh: u5 = @intCast(ch * 8);
            const va = fl((a >> sh) & 0xff);
            const vb = fl((b >> sh) & 0xff);
            px[o + ch] = @intFromFloat(va + (vb - va) * k + 0.5);
        }
    };
}

/// Camada 0: muitas estrelas fracas. Camada 1: poucas, maiores e com brilho.
fn stars(m: Mask, layer: u8, seed: u32, density: f32) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 7919);
    if (layer == 0) {
        const n: usize = @intFromFloat(380 * density);
        for (0..n) |_| {
            const x: i32 = @intCast(r.next() % m.w);
            const y: i32 = @intCast(r.next() % m.h);
            const b = r.f();
            const a = 0.18 + 0.72 * b * b * b;
            m.liftWrap(x, y, a);
            // Uma em dez ganha um halo de um pixel.
            if (r.f() < 0.1) {
                m.liftWrap(x + 1, y, a * 0.35);
                m.liftWrap(x - 1, y, a * 0.35);
                m.liftWrap(x, y + 1, a * 0.35);
                m.liftWrap(x, y - 1, a * 0.35);
            }
        }
        return;
    }
    const n: usize = @intFromFloat(34 * density);
    for (0..n) |_| {
        const x: i32 = @intCast(r.next() % m.w);
        const y: i32 = @intCast(r.next() % m.h);
        const a = 0.55 + 0.45 * r.f();
        const rad = 1.0 + 1.1 * r.f();
        const ext: i32 = 4;
        var dy: i32 = -ext;
        while (dy <= ext) : (dy += 1) {
            var dx: i32 = -ext;
            while (dx <= ext) : (dx += 1) {
                const d = std.math.hypot(fl(dx), fl(dy));
                m.liftWrap(x + dx, y + dy, a * @exp(-d * d / (rad * rad)));
            }
        }
        // As mais brilhantes têm a cruz de difração.
        if (a > 0.8) {
            const arm: i32 = 3 + @as(i32, @intCast(r.next() % 5));
            var i: i32 = 1;
            while (i <= arm) : (i += 1) {
                const k = a * 0.7 * (1 - fl(i) / fl(arm + 1));
                m.liftWrap(x + i, y, k);
                m.liftWrap(x - i, y, k);
                m.liftWrap(x, y + i, k);
                m.liftWrap(x, y - i, k);
            }
        }
    }
}

/// Soma de senos de frequência inteira: periódica, então não tem emenda em u.
fn wave(u: f32, freqs: []const u8, phases: []const f32) f32 {
    var s: f32 = 0;
    var total: f32 = 0;
    for (freqs, phases) |fq, ph| {
        const amp = 1 / @sqrt(fl(fq));
        s += amp * @sin(tau * (u * fl(fq) + ph));
        total += amp;
    }
    return s / total;
}

/// Cortina de aurora: borda de baixo mais marcada, sobe sumindo aos poucos.
fn aurora(m: Mask, layer: u8, seed: u32) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 104729);
    var ph: [12]f32 = undefined;
    for (&ph) |*p| p.* = r.f();
    const base: f32 = if (layer == 0) 0.40 else 0.58;
    const amp: f32 = if (layer == 0) 0.20 else 0.16;
    const rise: f32 = if (layer == 0) 0.30 else 0.20;
    var dither = Rng.init(seed ^ 0x51ed27);
    for (0..m.h) |yi| {
        const v = (fl(yi) + 0.5) / fl(m.h);
        for (0..m.w) |xi| {
            const u = (fl(xi) + 0.5) / fl(m.w);
            const edge = base + amp * wave(u, &.{ 1, 2, 3, 5 }, ph[0..4]);
            const glow = 0.55 + 0.45 * wave(u, &.{ 1, 2, 4 }, ph[4..7]);
            const rays = 0.72 + 0.28 * wave(u, &.{ 9, 17, 31, 47, 71 }, ph[7..12]);
            const d = v - edge;
            const profile = if (d > 0) @exp(-(d * d) / (0.05 * 0.05)) else @exp(d / rise);
            const top = smoothstep(0, 0.14, v);
            // Um tiquinho de ruído esconde os degraus do alfa baixo.
            const a = glow * rays * profile * top + (dither.f() - 0.5) / 255;
            m.set(@intCast(xi), @intCast(yi), @intFromFloat(std.math.clamp(a, 0, 1) * 255));
        }
    }
}

/// Canto de uma sombra macia: 0 no canto de fora, cheio onde começa a forma.
/// Vale para qualquer tamanho com a mesma proporção de raio e desfoque.
fn shadowCorner(m: Mask, round: f32) void {
    const blur = @max(1 - round, 0.01);
    for (0..m.h) |yi| for (0..m.w) |xi| {
        const dx = 1 - (fl(xi) + 0.5) / fl(m.w);
        const dy = 1 - (fl(yi) + 0.5) / fl(m.h);
        const t = std.math.clamp((std.math.hypot(dx, dy) - round) / blur, 0, 1);
        const k = 1 - t;
        // Cai como uma gaussiana: forte junto da forma, some sem degrau.
        m.set(@intCast(xi), @intCast(yi), @intFromFloat(k * k * (3 - 2 * k) * k * 255));
    };
}

/// Colinas em camadas, como um papel de parede: crista macia, mais forte no topo
/// e esmaecendo para baixo. A camada 0 é a do fundo; a 2, a da frente.
fn dunes(m: Mask, layer: u8, seed: u32) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 15485863);
    var ph: [4]f32 = undefined;
    for (&ph) |*p| p.* = r.f();
    const bases = [3]f32{ 0.46, 0.62, 0.80 };
    const amps = [3]f32{ 0.17, 0.14, 0.10 };
    const i = @min(layer, 2);
    var dither = Rng.init(seed ^ 0x2f1b9d);
    for (0..m.h) |yi| {
        const v = (fl(yi) + 0.5) / fl(m.h);
        for (0..m.w) |xi| {
            const u = (fl(xi) + 0.5) / fl(m.w);
            const edge = bases[i] + amps[i] * wave(u, &.{ 1, 2, 3, 5 }, &ph);
            const d = v - edge;
            const cov = smoothstep(-0.006, 0.010, d);
            const body = 0.58 + 0.42 * @exp(-@max(d, 0) / 0.16);
            const a = cov * body + (dither.f() - 0.5) * 1.5 / 255;
            m.set(@intCast(xi), @intCast(yi), @intFromFloat(std.math.clamp(a, 0, 1) * 255));
        }
    }
}

/// Ruído de valor periódico: a grade se repete a cada `period` células.
fn latticeHash(x: u32, y: u32, seed: u32) f32 {
    var h = x *% 73856093 ^ y *% 19349663 ^ seed *% 83492791;
    h ^= h >> 13;
    h *%= 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h >> 8)) / @as(f32, 1 << 24);
}

fn valueNoise(u: f32, v: f32, period: u32, seed: u32) f32 {
    const x = u * fl(period);
    const y = v * fl(period);
    const x0: u32 = @intFromFloat(@floor(x));
    const y0: u32 = @intFromFloat(@floor(y));
    const sx = smoothstep(0, 1, x - fl(x0));
    const sy = smoothstep(0, 1, y - fl(y0));
    const a = latticeHash(x0 % period, y0 % period, seed);
    const b = latticeHash((x0 + 1) % period, y0 % period, seed);
    const c = latticeHash(x0 % period, (y0 + 1) % period, seed);
    const d = latticeHash((x0 + 1) % period, (y0 + 1) % period, seed);
    const top = a + (b - a) * sx;
    return top + (c + (d - c) * sx - top) * sy;
}

/// Curvas de nível: o campo é calculado numa grade menor e cada pixel só
/// interpola (a conta cara roda 16× menos). A largura da linha é dividida pela
/// inclinação do campo para ficar igual em terreno plano e em terreno íngreme.
fn topography(m: Mask, seed: u32, levels: u16, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const g: u32 = 256;
    const field = try gpa.alloc(f32, g * g);
    defer gpa.free(field);
    for (0..g) |y| for (0..g) |x| {
        const u = fl(x) / fl(g);
        const v = fl(y) / fl(g);
        field[y * g + x] = (valueNoise(u, v, 4, seed) + 0.5 * valueNoise(u, v, 8, seed + 1) + 0.22 * valueNoise(u, v, 16, seed + 2)) / 1.72;
    };
    const scale = fl(g) / fl(m.w);
    const lv = fl(levels);
    for (0..m.h) |yi| for (0..m.w) |xi| {
        const gx = fl(xi) * scale;
        const gy = fl(yi) * scale;
        const x0: u32 = @intFromFloat(gx);
        const y0: u32 = @intFromFloat(gy);
        const x1 = (x0 + 1) % g;
        const y1 = (y0 + 1) % g;
        const dx = gx - fl(x0);
        const dy = gy - fl(y0);
        const a = field[y0 * g + x0];
        const b = field[y0 * g + x1];
        const c = field[y1 * g + x0];
        const d = field[y1 * g + x1];
        const top = a + (b - a) * dx;
        const f = top + (c + (d - c) * dx - top) * dy;
        // Inclinação em unidades do campo por pixel da textura.
        const fxs = ((b - a) * (1 - dy) + (d - c) * dy) * scale;
        const fys = ((c - a) * (1 - dx) + (d - b) * dx) * scale;
        const slope = @max(std.math.hypot(fxs, fys), 0.0004);
        const h = f * lv;
        const nearest = @round(h);
        const dist = @abs(h - nearest) / lv / slope;
        // Uma curva em cada cinco é a "mestra": mais forte, como nos mapas.
        const master = @mod(nearest, 5) == 0;
        const half: f32 = if (master) 0.7 else 0.4;
        const peak: f32 = if (master) 1.0 else 0.55;
        const cov = std.math.clamp(half + 0.5 - dist, 0, 1);
        m.set(@intCast(xi), @intCast(yi), @intFromFloat(cov * peak * 255));
    };
}

/// Elipse de uma órbita, em pixels da textura.
pub const Ellipse = struct {
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    cos: f32,
    sin: f32,

    pub fn at(e: Ellipse, angle: f32) [2]f32 {
        const x = e.rx * @cos(angle);
        const y = e.ry * @sin(angle);
        return .{ e.cx + x * e.cos - y * e.sin, e.cy + x * e.sin + y * e.cos };
    }
};

pub fn orbitEllipse(o: Orbit, i: usize) Ellipse {
    const span = fl(@max(o.w, o.h));
    const rx = span * (0.13 + 0.135 * fl(i));
    const tilt: f32 = -0.42;
    return .{
        .cx = fl(o.w) * fl(o.cx) / 1000,
        .cy = fl(o.h) * fl(o.cy) / 1000,
        .rx = rx,
        .ry = rx * 0.58,
        .cos = @cos(tilt),
        .sin = @sin(tilt),
    };
}

fn orbit(m: Mask, o: Orbit) void {
    for (0..o.rings) |i| {
        const e = orbitEllipse(o, i);
        const steps: usize = @intFromFloat(tau * e.rx * 1.6);
        // Em cada três órbitas, uma tracejada; as de fora vão sumindo.
        const dashed = i % 3 == 1;
        const peak = 0.95 - 0.09 * fl(i);
        for (0..steps) |s| {
            const ang = tau * fl(s) / fl(steps);
            if (dashed and @mod(ang * e.rx / 7, 2) > 1) continue;
            const p = e.at(ang);
            m.plot(p[0], p[1], peak);
        }
    }
    // O corpo central: um disco com halo.
    const c = orbitEllipse(o, 0);
    const span = fl(@max(o.w, o.h));
    const rad = span * 0.022;
    const ext: i32 = @intFromFloat(rad * 3);
    var dy: i32 = -ext;
    while (dy <= ext) : (dy += 1) {
        var dx: i32 = -ext;
        while (dx <= ext) : (dx += 1) {
            const d = std.math.hypot(fl(dx), fl(dy));
            const disc = std.math.clamp(rad + 0.5 - d, 0, 1);
            const halo = 0.28 * @exp(-(d - rad) * (d - rad) / (rad * rad));
            m.lift(@as(i32, @intFromFloat(c.cx)) + dx, @as(i32, @intFromFloat(c.cy)) + dy, @max(disc, if (d > rad) halo else 0));
        }
    }
}

pub fn radarRadius(o: Radar) f32 {
    return fl(@min(o.w, o.h)) * 0.46;
}

fn radar(m: Mask, o: Radar) void {
    const cx = fl(o.w) * fl(o.cx) / 1000;
    const cy = fl(o.h) * fl(o.cy) / 1000;
    const big = radarRadius(o);
    for (0..o.rings) |i| {
        const rad = big * fl(i + 1) / fl(o.rings);
        const steps: usize = @intFromFloat(tau * rad * 1.6);
        const peak: f32 = if (i + 1 == o.rings) 1 else 0.6;
        for (0..steps) |s| {
            const ang = tau * fl(s) / fl(steps);
            m.plot(cx + rad * @cos(ang), cy + rad * @sin(ang), peak);
        }
    }
    // A cruz do centro.
    const n: usize = @intFromFloat(big * 2 * 1.6);
    for (0..n) |s| {
        const k = (fl(s) / fl(n)) * 2 - 1;
        m.plot(cx + k * big, cy, 0.5);
        m.plot(cx, cy + k * big, 0.5);
    }
    // Graduação em volta: a cada 10°, maior a cada 30°.
    for (0..36) |d| {
        const ang = tau * fl(d) / 36;
        const len: f32 = if (d % 3 == 0) 12 else 6;
        const ca = @cos(ang);
        const sa = @sin(ang);
        var t: f32 = 0;
        while (t < len) : (t += 0.6) m.plot(cx + (big + t) * ca, cy + (big + t) * sa, 0.8);
    }
    // Alguns contatos.
    var r = Rng.init(o.seed);
    for (0..7) |_| {
        const ang = tau * r.f();
        const rad = big * (0.15 + 0.8 * r.f());
        const x = cx + rad * @cos(ang);
        const y = cy + rad * @sin(ang);
        var dy: f32 = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: f32 = -2;
            while (dx <= 2) : (dx += 1) {
                m.lift(@intFromFloat(x + dx), @intFromFloat(y + dy), std.math.clamp(2.4 - std.math.hypot(dx, dy), 0, 1));
            }
        }
    }
}

/// Chuva: riscos finos inclinados pelo vento, mais fortes na ponta de baixo (a gota)
/// e sumindo para cima (o rastro). Camada 0: muitos, curtos e fracos (longe);
/// camada 1: poucos, compridos e mais fortes (perto). Ladrilho sem emenda.
fn rain(m: Mask, layer: u8, seed: u32, density: f32, tilt: i8) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 6007);
    const slope = @tan(std.math.degreesToRadians(@as(f32, @floatFromInt(tilt))));
    const n: usize = @intFromFloat((if (layer == 0) @as(f32, 230) else 46) * density);
    for (0..n) |_| {
        const x = r.f() * fl(m.w);
        const y = r.f() * fl(m.h);
        const len = if (layer == 0) 9 + 18 * r.f() else 26 + 40 * r.f();
        const peak = if (layer == 0) 0.25 + 0.4 * r.f() else 0.55 + 0.4 * r.f();
        var t: f32 = 0;
        while (t <= len) : (t += 0.5) {
            // A ponta (t = len) é a parte de baixo.
            const k = t / len;
            const a = peak * k * k;
            m.plotWrap(x + slope * t, y + t, a);
            if (layer == 1) m.plotWrap(x + slope * t + 0.7, y + t, a * 0.55);
        }
    }
}

/// Os caracteres da chuva de código: 16 desenhos de 5×7 (algarismos e traços de
/// katakana, a olho), feitos à mão em bits. Não dependem de fonte nenhuma.
const glyphs = [16][7]u5{
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }, // 0
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 1
    .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b10000, 0b10000, 0b11111 }, // 2
    .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 }, // 3
    .{ 0b10001, 0b10001, 0b11111, 0b00001, 0b00001, 0b00001, 0b00001 }, // 4
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 7
    .{ 0b11111, 0b00100, 0b00100, 0b11111, 0b00100, 0b01000, 0b10000 }, // ナ
    .{ 0b11110, 0b00010, 0b11110, 0b00010, 0b00010, 0b00100, 0b11000 }, // ヨ-ish
    .{ 0b00100, 0b11111, 0b00100, 0b01110, 0b10101, 0b00100, 0b00100 }, // 木
    .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b00001, 0b00010, 0b01100 }, // レ-ish
    .{ 0b11111, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b11111 }, // 日
    .{ 0b00010, 0b00100, 0b01100, 0b10100, 0b00100, 0b00100, 0b00100 }, // イ
    .{ 0b11111, 0b00001, 0b01010, 0b00100, 0b01010, 0b10000, 0b00000 }, // メ-ish
    .{ 0b01000, 0b11111, 0b01001, 0b01001, 0b01001, 0b10001, 0b10010 }, // カ
    .{ 0b00000, 0b11111, 0b00000, 0b00000, 0b00000, 0b11111, 0b00000 }, // 二
    .{ 0b10101, 0b10101, 0b00001, 0b00010, 0b00010, 0b00100, 0b11000 }, // シ-ish
};

/// Célula de cada caractere no ladrilho (o desenho de 5×7 sai em dobro, 10×14).
pub const matrix_cell = 16;

fn glyph(m: Mask, cx: u32, cy: u32, g: u4, a: f32) void {
    for (glyphs[g], 0..) |bits, row| {
        for (0..5) |col| {
            if ((bits >> @intCast(4 - col)) & 1 == 0) continue;
            const x: i32 = @intCast(cx * matrix_cell + 3 + col * 2);
            const y: i32 = @intCast(cy * matrix_cell + 1 + row * 2);
            for (0..2) |dy| for (0..2) |dx| m.liftWrap(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), a);
        }
    }
}

/// Chuva de código: colunas de caracteres com a cabeça clara embaixo e o rastro
/// apagando para cima. Camada 0: o rastro; camada 1: só as cabeças (com `color2`).
/// Ladrilho de 32 × 32 células, sem emenda nos dois sentidos.
fn matrix(m: Mask, layer: u8, seed: u32, density: f32) void {
    var r = Rng.init(seed);
    const cols = m.w / matrix_cell;
    const rows = m.h / matrix_cell;
    for (0..cols) |cx| {
        // Uma ou duas cadeias por coluna; as duas camadas sorteiam igual.
        const chains: usize = if (r.f() < 0.35 * density) 2 else if (r.f() < 0.75 * density) 1 else 0;
        for (0..chains) |_| {
            const head = r.next() % rows;
            const len = 5 + r.next() % 18;
            for (0..len) |k| {
                const cy = (head + rows - @as(u32, @intCast(k))) % rows;
                const g: u4 = @intCast(r.next() % glyphs.len);
                const fade = 1 - fl(k) / fl(len);
                if (k == 0) {
                    if (layer == 1) glyph(m, @intCast(cx), cy, g, 1);
                } else if (layer == 0) glyph(m, @intCast(cx), cy, g, 0.12 + 0.78 * std.math.pow(f32, fade, 1.4));
            }
        }
    }
}

/// Ondas: linhas onduladas umas sobre as outras, as de cima mais fracas (longe) e
/// as de baixo mais fortes. Cada linha soma senos de frequência inteira, então o
/// ladrilho não tem emenda em u e pode deslizar de lado. Camada 1: menos linhas,
/// mais claras (as cristas). Calculado por coluna: `lines` contas por coluna, não
/// por pixel.
fn waves(m: Mask, layer: u8, seed: u32, lines: u8) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 7727);
    const total: usize = if (layer == 0) @max(lines, 2) else @max(lines / 3, 1);
    var ph: [24][4]f32 = undefined;
    var amp: [24]f32 = undefined;
    for (0..@min(total, 24)) |i| {
        for (&ph[i]) |*p| p.* = r.f();
        amp[i] = 0.018 + 0.03 * r.f();
    }
    const n = @min(total, 24);
    for (0..m.w) |xi| {
        const u = (fl(xi) + 0.5) / fl(m.w);
        for (0..n) |i| {
            const depth = (fl(i) + (if (layer == 0) @as(f32, 0) else 0.5)) / fl(n);
            const base = 0.22 + 0.72 * depth;
            const y = (base + amp[i] * (0.6 + depth) * wave(u, &.{ 1, 2, 3, 5 }, &ph[i])) * fl(m.h);
            const peak = if (layer == 0) 0.3 + 0.6 * depth else 0.7 + 0.3 * depth;
            // Linha macia: miolo de ~1,5 px e um brilho que some em volta.
            var dy: i32 = -5;
            while (dy <= 5) : (dy += 1) {
                const py = @floor(y) + fl(dy);
                const dist = @abs(py + 0.5 - y);
                const a = peak * @max(std.math.clamp(1.3 - dist, 0, 1), 0.35 * @exp(-dist * dist / 6));
                m.lift(@intCast(xi), @intFromFloat(py), a);
            }
        }
    }
}

/// Partículas no ar: camada 0, poeira fina (pontos macios de 1 a 2 px); camada 1,
/// discos grandes e desfocados com a borda um pouco mais clara (bokeh). Ladrilho
/// sem emenda.
fn particles(m: Mask, layer: u8, seed: u32, density: f32) void {
    var r = Rng.init(seed +% @as(u32, layer) *% 3571);
    const n: usize = @intFromFloat((if (layer == 0) @as(f32, 110) else 16) * density);
    for (0..n) |_| {
        const x = r.f() * fl(m.w);
        const y = r.f() * fl(m.h);
        const rad = if (layer == 0) 0.7 + 1.3 * r.f() else 4 + 8 * r.f();
        const peak = if (layer == 0) 0.3 + 0.6 * r.f() else 0.16 + 0.3 * r.f();
        const ext: i32 = @intFromFloat(@ceil(rad + 2));
        var dy: i32 = -ext;
        while (dy <= ext) : (dy += 1) {
            var dx: i32 = -ext;
            while (dx <= ext) : (dx += 1) {
                const px = @floor(x) + fl(dx) + 0.5;
                const py = @floor(y) + fl(dy) + 0.5;
                const d = std.math.hypot(px - x, py - y);
                const a = if (layer == 0)
                    peak * @exp(-d * d / (rad * rad))
                else
                    peak * std.math.clamp(rad + 0.8 - d, 0, 1) * (0.75 + 0.25 * smoothstep(rad * 0.55, rad, d));
                m.liftWrap(@intFromFloat(@floor(x) + fl(dx)), @intFromFloat(@floor(y) + fl(dy)), a);
            }
        }
    }
}

// --- Testes ---------------------------------------------------------------

const testing = std.testing;

fn gen(spec: Spec) ![]u8 {
    const sz = spec.size();
    const px = try testing.allocator.alloc(u8, sz[0] * sz[1] * 4);
    errdefer testing.allocator.free(px);
    try render(spec, px, testing.allocator);
    return px;
}

fn alphaAt(px: []const u8, w: u32, x: u32, y: u32) u8 {
    return px[(y * w + x) * 4 + 3];
}

test "chaves diferem e são estáveis" {
    const a = Spec{ .pattern = .{ .kind = .dots, .size = 16, .width_q = 8 } };
    const b = Spec{ .pattern = .{ .kind = .grid, .size = 16, .width_q = 8 } };
    try testing.expect(a.key() != b.key());
    try testing.expectEqual(a.key(), (Spec{ .pattern = .{ .kind = .dots, .size = 16, .width_q = 8 } }).key());
    try testing.expect((Spec{ .grain = 1 }).key() != (Spec{ .grain = 2 }).key());
}

test "grão: determinístico, com média baixa e branco no RGB" {
    const a = try gen(.{ .grain = 3 });
    defer testing.allocator.free(a);
    const b = try gen(.{ .grain = 3 });
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        try testing.expectEqual(@as(u8, 255), a[i]);
        sum += a[i + 3];
    }
    const mean = sum / (a.len / 4);
    try testing.expect(mean > 60 and mean < 110);
}

test "padrões: ponto no centro, linha, grade" {
    const dots = try gen(.{ .pattern = .{ .kind = .dots, .size = 16, .width_q = 16 } });
    defer testing.allocator.free(dots);
    try testing.expect(alphaAt(dots, 16, 8, 8) > 200);
    try testing.expectEqual(@as(u8, 0), alphaAt(dots, 16, 0, 0));
    const lines = try gen(.{ .pattern = .{ .kind = .lines, .size = 8, .width_q = 8 } });
    defer testing.allocator.free(lines);
    try testing.expect(alphaAt(lines, 8, 0, 4) > 100);
    try testing.expect(alphaAt(lines, 8, 7, 4) > 100);
    try testing.expectEqual(@as(u8, 0), alphaAt(lines, 8, 0, 0));
    const grid = try gen(.{ .pattern = .{ .kind = .grid, .size = 8, .width_q = 8 } });
    defer testing.allocator.free(grid);
    try testing.expect(alphaAt(grid, 8, 4, 0) > 100);
    try testing.expect(alphaAt(grid, 8, 0, 4) > 100);
    // A diagonal encaixa: o que sai por um lado entra pelo outro.
    const diag = try gen(.{ .pattern = .{ .kind = .diagonal, .size = 8, .width_q = 8 } });
    defer testing.allocator.free(diag);
    try testing.expectEqual(alphaAt(diag, 8, 0, 3), alphaAt(diag, 8, 7, 4));
}

test "tracejado: traço e vão" {
    const px = try gen(.{ .dash = .{ .dash = 3, .gap = 2 } });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 255), alphaAt(px, 5, 2, 0));
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 5, 3, 0));
}

test "vinheta: limpa no centro, forte nos cantos" {
    const px = try gen(.{ .vignette = 40 });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 128, 64, 64));
    try testing.expect(alphaAt(px, 128, 0, 0) > 240);
}

test "gradiente de 3 paradas passa pelas cores" {
    // Vertical: preto → vermelho (0xff no R) → preto; alfa cheio.
    const k: u32 = 0xff000000;
    const px = try gen(.{ .gradient = .{ .c = .{ k, k | 0xff, k }, .ax = 0, .ay = 1024 } });
    defer testing.allocator.free(px);
    const o = (32 * 64 + 10) * 4;
    try testing.expect(px[o] > 240);
    try testing.expect(px[(0 * 64 + 10) * 4] < 16);
    try testing.expect(px[(63 * 64 + 10) * 4] < 16);
    try testing.expectEqual(@as(u8, 255), px[o + 3]);
}

test "estrelas: a densidade conta, e tem estrela" {
    var totals: [2]usize = undefined;
    for ([_]u16{ 50, 200 }, 0..) |dens, i| {
        const px = try gen(.{ .stars = .{ .layer = 0, .seed = 5, .density = dens } });
        defer testing.allocator.free(px);
        var n: usize = 0;
        var o: usize = 3;
        while (o < px.len) : (o += 4) {
            if (px[o] > 0) n += 1;
        }
        totals[i] = n;
    }
    try testing.expect(totals[0] > 100);
    try testing.expect(totals[1] > totals[0] * 2);
}

test "aurora não tem emenda em u" {
    const px = try gen(.{ .aurora = .{ .layer = 0, .seed = 9 } });
    defer testing.allocator.free(px);
    var peak: u8 = 0;
    for (0..256) |y| {
        const a = alphaAt(px, 512, 0, @intCast(y));
        const b = alphaAt(px, 512, 511, @intCast(y));
        try testing.expect(@abs(@as(i32, a) - @as(i32, b)) < 48);
        peak = @max(peak, a);
    }
    try testing.expect(peak > 40);
}

test "canto de sombra: some por fora, cheio por dentro" {
    const px = try gen(.{ .shadow = 250 });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 64, 0, 0));
    try testing.expect(alphaAt(px, 64, 63, 63) > 240);
    // Na borda de baixo da textura (o meio do lado) a queda só depende de y.
    try testing.expect(alphaAt(px, 64, 63, 40) > alphaAt(px, 64, 63, 20));
}

test "colinas: céu limpo em cima, cheio embaixo, sem emenda" {
    const px = try gen(.{ .dunes = .{ .layer = 1, .seed = 4 } });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 512, 100, 3) & 0xf0);
    try testing.expect(alphaAt(px, 512, 100, 250) > 120);
    for (0..256) |y| {
        const a = alphaAt(px, 512, 0, @intCast(y));
        const b = alphaAt(px, 512, 511, @intCast(y));
        try testing.expect(@abs(@as(i32, a) - @as(i32, b)) < 64);
    }
}

test "curvas de nível têm traço e fundo, e ladrilham" {
    const px = try gen(.{ .topography = .{ .seed = 2, .levels = 14 } });
    defer testing.allocator.free(px);
    var on: usize = 0;
    var o: usize = 3;
    while (o < px.len) : (o += 4) {
        if (px[o] > 60) on += 1;
    }
    const total = px.len / 4;
    try testing.expect(on > total / 100 and on < total / 2);
    // A coluna 0 e a última são vizinhas na repetição: contagem parecida.
    var left: i32 = 0;
    var right: i32 = 0;
    for (0..1024) |y| {
        if (alphaAt(px, 1024, 0, @intCast(y)) > 60) left += 1;
        if (alphaAt(px, 1024, 1023, @intCast(y)) > 60) right += 1;
    }
    try testing.expect(@abs(left - right) < 40);
}

test "órbita passa onde a elipse diz; radar tem anel e centro" {
    const o: Orbit = .{ .w = 400, .h = 300, .cx = 500, .cy = 500, .rings = 3 };
    const px = try gen(.{ .orbit = o });
    defer testing.allocator.free(px);
    const p = orbitEllipse(o, 0).at(1.0);
    try testing.expect(alphaAt(px, 400, @intFromFloat(p[0]), @intFromFloat(p[1])) > 60);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 400, 1, 1));

    const ro: Radar = .{ .w = 300, .h = 300 };
    const rp = try gen(.{ .radar = ro });
    defer testing.allocator.free(rp);
    const big = radarRadius(ro);
    try testing.expect(alphaAt(rp, 300, @intFromFloat(150 + big), 150) > 60);
    try testing.expect(alphaAt(rp, 300, 150, 150) > 30);
}

fn countOn(px: []const u8, min: u8) usize {
    var n: usize = 0;
    var o: usize = 3;
    while (o < px.len) : (o += 4) {
        if (px[o] > min) n += 1;
    }
    return n;
}

test "fundos novos: a mesma semente dá o mesmo desenho, outra semente outro" {
    const specs = [_][2]Spec{
        .{ .{ .rain = .{ .layer = 1, .seed = 3, .density = 100, .tilt = 12 } }, .{ .rain = .{ .layer = 1, .seed = 4, .density = 100, .tilt = 12 } } },
        .{ .{ .matrix = .{ .layer = 0, .seed = 3, .density = 100 } }, .{ .matrix = .{ .layer = 0, .seed = 4, .density = 100 } } },
        .{ .{ .waves = .{ .layer = 0, .seed = 3, .lines = 9 } }, .{ .waves = .{ .layer = 0, .seed = 4, .lines = 9 } } },
        .{ .{ .particles = .{ .layer = 1, .seed = 3, .density = 100 } }, .{ .particles = .{ .layer = 1, .seed = 4, .density = 100 } } },
    };
    for (specs) |pair| {
        const a = try gen(pair[0]);
        defer testing.allocator.free(a);
        const b = try gen(pair[0]);
        defer testing.allocator.free(b);
        const o = try gen(pair[1]);
        defer testing.allocator.free(o);
        try testing.expectEqualSlices(u8, a, b);
        try testing.expect(!std.mem.eql(u8, a, o));
        try testing.expect(countOn(a, 40) > 50);
        try testing.expect(pair[0].key() != pair[1].key());
    }
}

test "chuva e partículas: a densidade conta" {
    for ([_]bool{ true, false }) |is_rain| {
        var totals: [2]usize = undefined;
        for ([_]u16{ 50, 200 }, 0..) |dens, i| {
            const spec: Spec = if (is_rain) .{ .rain = .{ .layer = 0, .seed = 5, .density = dens, .tilt = 0 } } else .{ .particles = .{ .layer = 0, .seed = 5, .density = dens } };
            const px = try gen(spec);
            defer testing.allocator.free(px);
            totals[i] = countOn(px, 20);
        }
        try testing.expect(totals[1] > totals[0] * 2);
    }
}

test "chuva: risco inclinado com a ponta embaixo mais forte" {
    // Um ladrilho com poucos riscos e sem vento: cada coluna acesa fica mais forte para baixo.
    const px = try gen(.{ .rain = .{ .layer = 1, .seed = 9, .density = 10, .tilt = 0 } });
    defer testing.allocator.free(px);
    var down: usize = 0;
    var up: usize = 0;
    for (0..512) |x| for (0..500) |y| {
        const a = alphaAt(px, 512, @intCast(x), @intCast(y));
        const b = alphaAt(px, 512, @intCast(x), @intCast(y + 8));
        if (a > 30 and b > 30) {
            if (b > a) down += 1 else if (a > b) up += 1;
        }
    };
    try testing.expect(down > up * 3);
}

test "chuva de código: as cabeças ficam embaixo do rastro e no desenho da célula" {
    const trail = try gen(.{ .matrix = .{ .layer = 0, .seed = 2, .density = 100 } });
    defer testing.allocator.free(trail);
    const heads = try gen(.{ .matrix = .{ .layer = 1, .seed = 2, .density = 100 } });
    defer testing.allocator.free(heads);
    var found: usize = 0;
    const cells = 512 / matrix_cell;
    for (0..cells) |cx| for (0..cells) |cy| {
        // Célula com cabeça: a de cima é rastro forte, a de baixo não é desta cadeia.
        var lit = false;
        for (0..matrix_cell) |dy| for (0..matrix_cell) |dx| {
            if (alphaAt(heads, 512, @intCast(cx * matrix_cell + dx), @intCast(cy * matrix_cell + dy)) > 200) lit = true;
        };
        if (!lit) continue;
        const above = (cy + cells - 1) % cells;
        var ink: usize = 0;
        for (0..matrix_cell) |dy| for (0..matrix_cell) |dx| {
            if (alphaAt(trail, 512, @intCast(cx * matrix_cell + dx), @intCast(above * matrix_cell + dy)) > 120) ink += 1;
        };
        if (ink > 4) found += 1;
    };
    try testing.expect(found > 8);
    // Nada fora do desenho de 10×14 dentro da célula: as bordas ficam vazias.
    for (0..512) |y| try testing.expectEqual(@as(u8, 0), alphaAt(trail, 512, 0, @intCast(y)));
}

test "ondas: sem emenda em u, linhas de baixo mais fortes" {
    const px = try gen(.{ .waves = .{ .layer = 0, .seed = 6, .lines = 9 } });
    defer testing.allocator.free(px);
    var left: usize = 0;
    var right: usize = 0;
    var top: u32 = 0;
    var bottom: u32 = 0;
    for (0..512) |y| {
        const a = alphaAt(px, 1024, 0, @intCast(y));
        const b = alphaAt(px, 1024, 1023, @intCast(y));
        if (a > 100) left += 1;
        if (b > 100) right += 1;
        if (y < 256) top = @max(top, a) else bottom = @max(bottom, a);
    }
    try testing.expect(left > 5);
    try testing.expect(@abs(@as(i64, @intCast(left)) - @as(i64, @intCast(right))) <= 3);
    try testing.expect(bottom > top);
}

