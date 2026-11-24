//! `shape kind=path d="M 0 0 L 24 0 L 12 20 Z"`: o subconjunto de caminho do SVG
//! (M L H V C S Q T A Z; maiúscula é posição absoluta, minúscula é relativa), lido
//! e achatado em retas uma vez, ao carregar o tema. No quadro o traço só muda de
//! escala e de lugar; o preenchimento (que pode ser côncavo e ter buraco) vira uma
//! máscara feita aqui, na CPU, e guardada por tamanho em `ui/fx.zig`.
//!
//! Nada de SDL nem de ImGui: só contas, testadas em `zig build test`.
const std = @import("std");

pub const FillRule = enum { nonzero, evenodd };

/// Um trecho contínuo do caminho (de um M até o próximo M ou Z).
pub const Sub = struct { start: u32, len: u32, closed: bool };

pub const Path = struct {
    pts: []const [2]f32,
    subs: []const Sub,
    /// Caixa de visão: x, y, largura, altura. É o que vai caber no nó.
    view: [4]f32,
    rule: FillRule = .nonzero,
    /// Conta do conteúdo, para guardar a máscara: depois de recarregar o tema, outro
    /// caminho pode cair no mesmo endereço.
    hash: u64,
};

/// Limites de um caminho num tema: mais que isso é desenho para outro programa.
pub const max_segments = 1024;
pub const max_points = 4096;
/// Tamanho máximo (em pixels) em que o achatamento ainda fica liso: a tolerância é
/// escolhida para a caixa de visão inteira ocupar isto.
pub const max_px: f32 = 2048;
const tol_px: f32 = 0.2;

pub const Problem = struct {
    msg: []const u8,
    /// Onde, em `d` (contando do 1, em bytes).
    at: usize,
};

pub const Error = error{ Invalid, OutOfMemory };

const Seg = union(enum) {
    move: [2]f32,
    line: [2]f32,
    cubic: [3][2]f32,
    quad: [2][2]f32,
    arc: struct { rx: f32, ry: f32, rot: f32, large: bool, sweep: bool, to: [2]f32 },
    close,
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    problem: ?Problem = null,

    fn fail(p: *Parser, msg: []const u8) Error {
        p.problem = .{ .msg = msg, .at = p.i + 1 };
        return error.Invalid;
    }

    fn wsp(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0c;
    }

    /// Espaços e no máximo uma vírgula entre os números (o "comma-wsp" do SVG).
    fn skipSep(p: *Parser) void {
        while (p.i < p.s.len and wsp(p.s[p.i])) p.i += 1;
        if (p.i < p.s.len and p.s[p.i] == ',') {
            p.i += 1;
            while (p.i < p.s.len and wsp(p.s[p.i])) p.i += 1;
        }
    }

    fn skipWsp(p: *Parser) void {
        while (p.i < p.s.len and wsp(p.s[p.i])) p.i += 1;
    }

    fn atNumber(p: *Parser) bool {
        if (p.i >= p.s.len) return false;
        const ch = p.s[p.i];
        return std.ascii.isDigit(ch) or ch == '-' or ch == '+' or ch == '.';
    }

    /// Número do SVG: `-1.5e3`, `.5`, e `1.5.5` são dois (1,5 e 0,5), `1-2` também.
    fn number(p: *Parser, what: []const u8) Error!f32 {
        p.skipSep();
        const start = p.i;
        var j = p.i;
        if (j < p.s.len and (p.s[j] == '-' or p.s[j] == '+')) j += 1;
        var digits: usize = 0;
        while (j < p.s.len and std.ascii.isDigit(p.s[j])) : (j += 1) digits += 1;
        if (j < p.s.len and p.s[j] == '.') {
            j += 1;
            while (j < p.s.len and std.ascii.isDigit(p.s[j])) : (j += 1) digits += 1;
        }
        if (digits == 0) return p.fail(what);
        if (j < p.s.len and (p.s[j] == 'e' or p.s[j] == 'E')) {
            var k = j + 1;
            if (k < p.s.len and (p.s[k] == '-' or p.s[k] == '+')) k += 1;
            if (k < p.s.len and std.ascii.isDigit(p.s[k])) {
                while (k < p.s.len and std.ascii.isDigit(p.s[k])) k += 1;
                j = k;
            }
        }
        const v = std.fmt.parseFloat(f32, p.s[start..j]) catch return p.fail(what);
        if (!std.math.isFinite(v) or @abs(v) > 1e6) {
            return p.fail("d: número grande demais");
        }
        p.i = j;
        return v;
    }

    /// As bandeiras do arco são um caractere só, e podem vir coladas: `a5 5 0 1010 10`.
    fn flag(p: *Parser) Error!bool {
        p.skipSep();
        if (p.i < p.s.len and (p.s[p.i] == '0' or p.s[p.i] == '1')) {
            p.i += 1;
            return p.s[p.i - 1] == '1';
        }
        return p.fail("d: as bandeiras do arco são 0 ou 1");
    }

    fn pair(p: *Parser, what: []const u8) Error![2]f32 {
        const x = try p.number(what);
        const y = try p.number(what);
        return .{ x, y };
    }
};

fn add(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn reflect(ctrl: [2]f32, about: [2]f32) [2]f32 {
    return .{ 2 * about[0] - ctrl[0], 2 * about[1] - ctrl[1] };
}

/// Lê `d` em segmentos com posição absoluta.
fn parseSegs(a: std.mem.Allocator, p: *Parser) Error![]Seg {
    var out: std.ArrayList(Seg) = .empty;
    var cur: [2]f32 = .{ 0, 0 };
    var start: [2]f32 = .{ 0, 0 };
    // O último ponto de controle, para S e T (que espelham o anterior).
    var last_cubic: ?[2]f32 = null;
    var last_quad: ?[2]f32 = null;
    var cmd: u8 = 0;
    p.skipWsp();
    if (p.i >= p.s.len) return p.fail("d: caminho vazio");
    while (true) {
        p.skipWsp();
        if (p.i >= p.s.len) break;
        const ch = p.s[p.i];
        if (std.ascii.isAlphabetic(ch)) {
            if (std.mem.indexOfScalar(u8, "MmLlHhVvCcSsQqTtAaZz", ch) == null) return p.fail("d: comando desconhecido (são M L H V C S Q T A Z)");
            if (cmd == 0 and ch != 'M' and ch != 'm') return p.fail("d: o caminho começa com M");
            cmd = ch;
            p.i += 1;
        } else if (cmd == 0) {
            return p.fail("d: o caminho começa com M");
        } else if (cmd == 'Z' or cmd == 'z') {
            return p.fail("d: número depois de Z");
        } else if (!p.atNumber() and p.s[p.i] != ',') {
            return p.fail("d: caractere inesperado");
        }
        // Depois do M, os pares a mais são retas (L), como manda o SVG.
        const rel = std.ascii.isLower(cmd);
        const base = if (rel) cur else [2]f32{ 0, 0 };
        if (out.items.len >= max_segments) return p.fail("d: caminho longo demais (até 1024 comandos)");
        var seg: Seg = undefined;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                cur = add(base, try p.pair("d: M pede x e y"));
                start = cur;
                seg = .{ .move = cur };
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                cur = add(base, try p.pair("d: L pede x e y"));
                seg = .{ .line = cur };
            },
            'H' => {
                const x = try p.number("d: H pede um número");
                cur = .{ if (rel) cur[0] + x else x, cur[1] };
                seg = .{ .line = cur };
            },
            'V' => {
                const y = try p.number("d: V pede um número");
                cur = .{ cur[0], if (rel) cur[1] + y else y };
                seg = .{ .line = cur };
            },
            'C' => {
                const c1 = add(base, try p.pair("d: C pede três pares de números"));
                const c2 = add(base, try p.pair("d: C pede três pares de números"));
                const to = add(base, try p.pair("d: C pede três pares de números"));
                seg = .{ .cubic = .{ c1, c2, to } };
                last_cubic = c2;
                cur = to;
            },
            'S' => {
                const c1 = if (last_cubic) |lc| reflect(lc, cur) else cur;
                const c2 = add(base, try p.pair("d: S pede dois pares de números"));
                const to = add(base, try p.pair("d: S pede dois pares de números"));
                seg = .{ .cubic = .{ c1, c2, to } };
                last_cubic = c2;
                cur = to;
            },
            'Q' => {
                const c1 = add(base, try p.pair("d: Q pede dois pares de números"));
                const to = add(base, try p.pair("d: Q pede dois pares de números"));
                seg = .{ .quad = .{ c1, to } };
                last_quad = c1;
                cur = to;
            },
            'T' => {
                const c1 = if (last_quad) |lq| reflect(lq, cur) else cur;
                const to = add(base, try p.pair("d: T pede x e y"));
                seg = .{ .quad = .{ c1, to } };
                last_quad = c1;
                cur = to;
            },
            'A' => {
                const what = "d: A pede rx ry rotação bandeira bandeira x y";
                const rx = try p.number(what);
                const ry = try p.number(what);
                const rot = try p.number(what);
                const large = try p.flag();
                const sweep = try p.flag();
                const to = add(base, try p.pair(what));
                seg = .{ .arc = .{ .rx = @abs(rx), .ry = @abs(ry), .rot = rot, .large = large, .sweep = sweep, .to = to } };
                cur = to;
            },
            'Z' => {
                seg = .close;
                cur = start;
            },
            else => unreachable,
        }
        // S e T só espelham o controle de uma curva do mesmo tipo logo antes.
        if (seg != .cubic) last_cubic = null;
        if (seg != .quad) last_quad = null;
        try out.append(a, seg);
        p.skipSep();
    }
    return out.toOwnedSlice(a);
}

/// Caixa dos pontos e dos controles (as curvas ficam dentro dela; o arco pode sair
/// um pouco, e a caixa de visão padrão vem dos pontos já achatados).
fn controlBounds(segs: []const Seg) [4]f32 {
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    const S = struct {
        fn grow(l: *[2]f32, h: *[2]f32, q: [2]f32) void {
            l[0] = @min(l[0], q[0]);
            l[1] = @min(l[1], q[1]);
            h[0] = @max(h[0], q[0]);
            h[1] = @max(h[1], q[1]);
        }
    };
    for (segs) |s| switch (s) {
        .move, .line => |q| S.grow(&lo, &hi, q),
        .cubic => |q| for (q) |x| S.grow(&lo, &hi, x),
        .quad => |q| for (q) |x| S.grow(&lo, &hi, x),
        .arc => |q| {
            S.grow(&lo, &hi, q.to);
            S.grow(&lo, &hi, .{ q.to[0] - q.rx, q.to[1] - q.ry });
            S.grow(&lo, &hi, .{ q.to[0] + q.rx, q.to[1] + q.ry });
        },
        .close => {},
    };
    if (!std.math.isFinite(lo[0])) return .{ 0, 0, 1, 1 };
    return .{ lo[0], lo[1], hi[0] - lo[0], hi[1] - lo[1] };
}

/// Em quantas retas uma curva vira, pela fórmula de Wang: o desvio fica abaixo de
/// `tol` (na unidade do caminho).
pub fn curveSteps(dd: f32, degree: f32, tol: f32) u32 {
    const n = @ceil(@sqrt(degree * (degree - 1) / 8 * dd / @max(tol, 1e-6)));
    return @intFromFloat(std.math.clamp(n, 1, 256));
}

fn len2(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

const Builder = struct {
    a: std.mem.Allocator,
    pts: std.ArrayList([2]f32) = .empty,
    subs: std.ArrayList(Sub) = .empty,
    open: ?usize = null,
    p: *Parser,

    fn point(b: *Builder, q: [2]f32) Error!void {
        if (b.pts.items.len >= max_points) return b.p.fail("d: caminho complexo demais (até 4096 pontos depois de achatar as curvas)");
        if (b.open == null) {
            try b.subs.append(b.a, .{ .start = @intCast(b.pts.items.len), .len = 0, .closed = false });
            b.open = b.subs.items.len - 1;
        }
        try b.pts.append(b.a, q);
        b.subs.items[b.open.?].len += 1;
    }

    fn end(b: *Builder, closed: bool) void {
        const i = b.open orelse return;
        b.subs.items[i].closed = closed;
        // Um trecho de um ponto só não desenha nada.
        if (b.subs.items[i].len < 2) {
            b.pts.shrinkRetainingCapacity(b.subs.items[i].start);
            _ = b.subs.pop();
        }
        b.open = null;
    }

    fn last(b: *const Builder) [2]f32 {
        return b.pts.items[b.pts.items.len - 1];
    }
};

/// Arco do SVG (ponta a ponta) em retas: a conversão para centro e ângulos da seção
/// F.6.5 da especificação, com os raios aumentados quando não alcançam (F.6.6).
fn flattenArc(b: *Builder, from: [2]f32, q: anytype, tol: f32) Error!void {
    var rx = q.rx;
    var ry = q.ry;
    if (rx < 1e-6 or ry < 1e-6 or (from[0] == q.to[0] and from[1] == q.to[1])) return b.point(q.to);
    const phi = std.math.degreesToRadians(q.rot);
    const cs = @cos(phi);
    const sn = @sin(phi);
    const dx = (from[0] - q.to[0]) / 2;
    const dy = (from[1] - q.to[1]) / 2;
    const x1 = cs * dx + sn * dy;
    const y1 = -sn * dx + cs * dy;
    const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if (lam > 1) {
        rx *= @sqrt(lam);
        ry *= @sqrt(lam);
    }
    const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    var k = @sqrt(@max(num / @max(den, 1e-12), 0));
    if (q.large == q.sweep) k = -k;
    const cxp = k * rx * y1 / ry;
    const cyp = -k * ry * x1 / rx;
    const cx = cs * cxp - sn * cyp + (from[0] + q.to[0]) / 2;
    const cy = sn * cxp + cs * cyp + (from[1] + q.to[1]) / 2;
    const ang = struct {
        fn f(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
            const dot = ux * vx + uy * vy;
            const l = len2(ux, uy) * len2(vx, vy);
            var a = std.math.acos(std.math.clamp(dot / @max(l, 1e-12), -1, 1));
            if (ux * vy - uy * vx < 0) a = -a;
            return a;
        }
    }.f;
    const t1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
    var dt = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
    if (!q.sweep and dt > 0) dt -= std.math.tau;
    if (q.sweep and dt < 0) dt += std.math.tau;
    const r = @max(rx, ry);
    const step = 2 * std.math.acos(std.math.clamp(1 - tol / r, -1, 1));
    const n: u32 = @intFromFloat(std.math.clamp(@ceil(@abs(dt) / @max(step, 1e-4)), 1, 256));
    for (1..n + 1) |i| {
        if (i == n) return b.point(q.to);
        const t = t1 + dt * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const ex = rx * @cos(t);
        const ey = ry * @sin(t);
        try b.point(.{ cx + cs * ex - sn * ey, cy + sn * ex + cs * ey });
    }
}

fn flatten(b: *Builder, segs: []const Seg, tol: f32) Error!void {
    var start: [2]f32 = .{ 0, 0 };
    for (segs) |s| switch (s) {
        .move => |q| {
            b.end(false);
            start = q;
            try b.point(q);
        },
        .line => |q| {
            if (b.open == null) try b.point(start);
            try b.point(q);
        },
        .cubic => |q| {
            if (b.open == null) try b.point(start);
            const p0 = b.last();
            const ax = p0[0] - 2 * q[0][0] + q[1][0];
            const ay = p0[1] - 2 * q[0][1] + q[1][1];
            const bx = q[0][0] - 2 * q[1][0] + q[2][0];
            const by = q[0][1] - 2 * q[1][1] + q[2][1];
            const n = curveSteps(@max(len2(ax, ay), len2(bx, by)), 3, tol);
            for (1..n + 1) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                const u = 1 - t;
                const w0 = u * u * u;
                const w1 = 3 * u * u * t;
                const w2 = 3 * u * t * t;
                const w3 = t * t * t;
                try b.point(.{ w0 * p0[0] + w1 * q[0][0] + w2 * q[1][0] + w3 * q[2][0], w0 * p0[1] + w1 * q[0][1] + w2 * q[1][1] + w3 * q[2][1] });
            }
        },
        .quad => |q| {
            if (b.open == null) try b.point(start);
            const p0 = b.last();
            const n = curveSteps(len2(p0[0] - 2 * q[0][0] + q[1][0], p0[1] - 2 * q[0][1] + q[1][1]), 2, tol);
            for (1..n + 1) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                const u = 1 - t;
                try b.point(.{ u * u * p0[0] + 2 * u * t * q[0][0] + t * t * q[1][0], u * u * p0[1] + 2 * u * t * q[0][1] + t * t * q[1][1] });
            }
        },
        .arc => |q| {
            if (b.open == null) try b.point(start);
            try flattenArc(b, b.last(), q, tol);
        },
        .close => b.end(true),
    };
    b.end(false);
}

/// `viewbox="0 0 24 24"`: quatro números, largura e altura positivas.
pub fn parseViewbox(s: []const u8) ?[4]f32 {
    var p: Parser = .{ .s = s };
    var out: [4]f32 = undefined;
    for (&out) |*v| v.* = p.number("") catch return null;
    p.skipWsp();
    if (p.i != s.len or out[2] <= 0 or out[3] <= 0) return null;
    return out;
}

/// Lê e achata `d`. `view`: a caixa de visão do tema; sem ela, a dos pontos.
pub fn parse(a: std.mem.Allocator, d: []const u8, view: ?[4]f32, rule: FillRule, problem: *?Problem) Error!*const Path {
    var p: Parser = .{ .s = d };
    errdefer problem.* = p.problem;
    const segs = try parseSegs(a, &p);
    defer a.free(segs);
    // A tolerância vale para o maior tamanho em que o caminho vai aparecer.
    const vb = view orelse controlBounds(segs);
    const tol = tol_px * @max(@max(vb[2], vb[3]), 1e-3) / max_px;
    var b: Builder = .{ .a = a, .p = &p };
    try flatten(&b, segs, tol);
    if (b.subs.items.len == 0) return p.fail("d: o caminho não tem nenhuma linha");
    const out = try a.create(Path);
    var h = std.hash.Wyhash.init(0x9a7e);
    h.update(std.mem.sliceAsBytes(b.pts.items));
    for (b.subs.items) |s| std.hash.autoHash(&h, s);
    std.hash.autoHash(&h, rule);
    out.* = .{
        .pts = try b.pts.toOwnedSlice(a),
        .subs = try b.subs.toOwnedSlice(a),
        .view = undefined,
        .rule = rule,
        .hash = h.final(),
    };
    out.view = view orelse pointBounds(out.pts);
    return out;
}

fn pointBounds(pts: []const [2]f32) [4]f32 {
    var lo = pts[0];
    var hi = pts[0];
    for (pts) |q| {
        lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
        hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
    }
    // Uma reta só (horizontal ou vertical) ainda tem uma caixa.
    const w = @max(hi[0] - lo[0], 1e-3);
    const h = @max(hi[1] - lo[1], 1e-3);
    return .{ lo[0], lo[1], w, h };
}

// --- Encaixe no nó -----------------------------------------------------------

pub const Align = enum { left, center, right };

/// Caixa de visão → retângulo: mesma escala nos dois eixos (sem deformar), centrada
/// na vertical e alinhada na horizontal como os outros `shape`.
pub const Map = struct {
    s: f32,
    /// Onde o canto da caixa de visão cai.
    ox: f32,
    oy: f32,
    /// Tamanho da caixa de visão já na escala.
    w: f32,
    h: f32,

    pub fn apply(m: Map, view: [4]f32, q: [2]f32) [2]f32 {
        return .{ m.ox + (q[0] - view[0]) * m.s, m.oy + (q[1] - view[1]) * m.s };
    }
};

pub fn fit(view: [4]f32, x: f32, y: f32, w: f32, h: f32, al: Align) Map {
    const s = @min(w / view[2], h / view[3]);
    const cw = view[2] * s;
    const ch = view[3] * s;
    const ox = switch (al) {
        .left => x,
        .center => x + (w - cw) / 2,
        .right => x + w - cw,
    };
    return .{ .s = s, .ox = ox, .oy = y + (h - ch) / 2, .w = cw, .h = ch };
}

// --- Máscara do preenchimento --------------------------------------------------

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i8 };
const Cross = struct { x: f32, dir: i8 };

/// Pinta o alfa de `px` (RGBA, `w`×`h`) com a cobertura do preenchimento: a caixa de
/// visão ocupa a máscara inteira. Cobertura exata na horizontal e 4 sublinhas na
/// vertical: borda lisa sem 16 amostras por pixel. Trecho aberto fecha sozinho, como
/// no SVG. O RGB fica branco (a cor vem ao desenhar).
pub fn rasterize(p: *const Path, w: u32, h: u32, px: []u8, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = 255;
        px[i + 1] = 255;
        px[i + 2] = 255;
        px[i + 3] = 0;
    }
    const sx = @as(f32, @floatFromInt(w)) / p.view[2];
    const sy = @as(f32, @floatFromInt(h)) / p.view[3];
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    for (p.subs) |s| {
        const pts = p.pts[s.start..][0..s.len];
        for (pts, 0..) |q, k| {
            const n = pts[(k + 1) % pts.len];
            const ax = (q[0] - p.view[0]) * sx;
            const ay = (q[1] - p.view[1]) * sy;
            const bx = (n[0] - p.view[0]) * sx;
            const by = (n[1] - p.view[1]) * sy;
            if (ay == by) continue;
            // Sempre de cima para baixo; `dir` guarda o sentido original.
            try edges.append(gpa, if (ay < by) .{ .x0 = ax, .y0 = ay, .x1 = bx, .y1 = by, .dir = 1 } else .{ .x0 = bx, .y0 = by, .x1 = ax, .y1 = ay, .dir = -1 });
        }
    }
    std.mem.sortUnstable(Edge, edges.items, {}, struct {
        fn lt(_: void, a: Edge, b: Edge) bool {
            return a.y0 < b.y0;
        }
    }.lt);
    const cov = try gpa.alloc(f32, w);
    defer gpa.free(cov);
    var cross: std.ArrayList(Cross) = .empty;
    defer cross.deinit(gpa);
    var active: std.ArrayList(usize) = .empty;
    defer active.deinit(gpa);
    var next: usize = 0;
    const wf: f32 = @floatFromInt(w);
    for (0..h) |row| {
        @memset(cov, 0);
        for (0..4) |sub| {
            const yy = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sub)) + 0.5) / 4;
            while (next < edges.items.len and edges.items[next].y0 <= yy) : (next += 1) try active.append(gpa, next);
            cross.clearRetainingCapacity();
            var k: usize = 0;
            while (k < active.items.len) {
                const e = edges.items[active.items[k]];
                if (e.y1 <= yy) {
                    _ = active.swapRemove(k);
                    continue;
                }
                const t = (yy - e.y0) / (e.y1 - e.y0);
                try cross.append(gpa, .{ .x = e.x0 + (e.x1 - e.x0) * t, .dir = e.dir });
                k += 1;
            }
            std.mem.sortUnstable(Cross, cross.items, {}, struct {
                fn lt(_: void, a: Cross, b: Cross) bool {
                    return a.x < b.x;
                }
            }.lt);
            var wind: i32 = 0;
            for (cross.items, 0..) |cr, ci| {
                wind += cr.dir;
                const inside = switch (p.rule) {
                    .nonzero => wind != 0,
                    .evenodd => @mod(wind, 2) != 0,
                };
                if (!inside or ci + 1 >= cross.items.len) continue;
                span(cov, std.math.clamp(cr.x, 0, wf), std.math.clamp(cross.items[ci + 1].x, 0, wf));
            }
        }
        const o = row * w * 4;
        for (cov, 0..) |v, x| px[o + x * 4 + 3] = @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
    }
}

/// Soma ¼ (uma sublinha) de cobertura de `a` a `b`, com a fração certa nas pontas.
fn span(cov: []f32, a: f32, b: f32) void {
    if (b <= a) return;
    const ia: usize = @intFromFloat(@floor(a));
    const ib: usize = @intFromFloat(@floor(b));
    if (ia == ib) {
        if (ia < cov.len) cov[ia] += (b - a) * 0.25;
        return;
    }
    cov[ia] += (@as(f32, @floatFromInt(ia + 1)) - a) * 0.25;
    for (ia + 1..ib) |x| cov[x] += 0.25;
    if (ib < cov.len) cov[ib] += (b - @as(f32, @floatFromInt(ib))) * 0.25;
}

// --- Testes ----------------------------------------------------------------

const testing = std.testing;

fn parseOk(a: std.mem.Allocator, d: []const u8) !*const Path {
    var pr: ?Problem = null;
    return parse(a, d, null, .nonzero, &pr) catch |err| {
        std.debug.print("caminho {s}: {s}\n", .{ d, if (pr) |x| x.msg else "?" });
        return err;
    };
}

fn near(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) < 1e-3 and @abs(a[1] - b[1]) < 1e-3;
}

test "caminho: M L H V Z, absolutos e relativos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parseOk(a, "M 0 0 L 24 0 L 12 20 Z");
    try testing.expectEqual(@as(usize, 3), p.pts.len);
    try testing.expectEqual(@as(usize, 1), p.subs.len);
    try testing.expect(p.subs[0].closed);
    try testing.expect(near(p.pts[2], .{ 12, 20 }));
    // Relativos, pares extras depois do m viram l, números colados.
    const r = try parseOk(a, "m10,10 5,0 0 5h-5v-5z");
    try testing.expect(near(r.pts[0], .{ 10, 10 }));
    try testing.expect(near(r.pts[1], .{ 15, 10 }));
    try testing.expect(near(r.pts[2], .{ 15, 15 }));
    try testing.expect(near(r.pts[3], .{ 10, 15 }));
    try testing.expect(near(r.pts[4], .{ 10, 10 }));
    const hv = try parseOk(a, "M1-2H5V-1.5.5");
    try testing.expect(near(hv.pts[1], .{ 5, -2 }));
    try testing.expect(near(hv.pts[2], .{ 5, -1.5 }));
    try testing.expect(near(hv.pts[3], .{ 5, 0.5 }));
    // Expoente e um trecho novo depois do Z, que começa no início do anterior.
    const e = try parseOk(a, "M0 0L1e1 0 0 1E1zl5 5");
    try testing.expectEqual(@as(usize, 2), e.subs.len);
    try testing.expect(near(e.pts[e.subs[1].start], .{ 0, 0 }));
    try testing.expect(near(e.pts[e.subs[1].start + 1], .{ 5, 5 }));
    try testing.expect(!e.subs[1].closed);
}

test "caminho: curvas C S Q T passam pelas pontas e pelo meio certo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cub = try parseOk(a, "M0 0 C 0 10 10 10 10 0");
    try testing.expect(cub.pts.len > 4);
    try testing.expect(near(cub.pts[cub.pts.len - 1], .{ 10, 0 }));
    // O ponto do meio de uma cúbica simétrica: y = 7,5.
    var top: f32 = 0;
    for (cub.pts) |q| top = @max(top, q[1]);
    try testing.expectApproxEqAbs(@as(f32, 7.5), top, 0.05);
    // S espelha o controle: o segundo arco desce simétrico.
    const s = try parseOk(a, "M0 0 C0 10 10 10 10 0 S20 -10 20 0");
    var low: f32 = 0;
    for (s.pts) |q| low = @min(low, q[1]);
    try testing.expectApproxEqAbs(@as(f32, -7.5), low, 0.05);
    // s relativo dá o mesmo.
    const sr = try parseOk(a, "M0 0 c0 10 10 10 10 0 s10 -10 10 0");
    try testing.expect(near(sr.pts[sr.pts.len - 1], .{ 20, 0 }));
    const q = try parseOk(a, "M0 0 Q5 10 10 0");
    var qt: f32 = 0;
    for (q.pts) |x| qt = @max(qt, x[1]);
    try testing.expectApproxEqAbs(@as(f32, 5), qt, 0.05);
    const t = try parseOk(a, "M0 0 Q5 10 10 0 T20 0");
    var tl: f32 = 0;
    for (t.pts) |x| tl = @min(tl, x[1]);
    try testing.expectApproxEqAbs(@as(f32, -5), tl, 0.05);
    const tr = try parseOk(a, "M0 0 q5 10 10 0 t10 0");
    try testing.expect(near(tr.pts[tr.pts.len - 1], .{ 20, 0 }));
}

test "caminho: arco de meia volta passa pelo topo, nos dois sentidos" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Meia circunferência de raio 5 de (0,0) a (10,0).
    const up = try parseOk(a, "M0 0 A5 5 0 0 1 10 0");
    try testing.expect(near(up.pts[up.pts.len - 1], .{ 10, 0 }));
    var lo: f32 = 0;
    for (up.pts) |q| {
        lo = @min(lo, q[1]);
        try testing.expectApproxEqAbs(@as(f32, 5), std.math.hypot(q[0] - 5, q[1]), 0.01);
    }
    try testing.expectApproxEqAbs(@as(f32, -5), lo, 0.01);
    var hi: f32 = 0;
    const down = try parseOk(a, "M0 0 a5 5 0 0 0 10 0");
    for (down.pts) |q| hi = @max(hi, q[1]);
    try testing.expectApproxEqAbs(@as(f32, 5), hi, 0.01);
    // Raio que não alcança aumenta; bandeiras coladas; raio zero vira reta.
    const small = try parseOk(a, "M0 0 A1 1 0 0110 0");
    try testing.expect(near(small.pts[small.pts.len - 1], .{ 10, 0 }));
    const flat = try parseOk(a, "M0 0 A0 5 0 0 1 10 0");
    try testing.expectEqual(@as(usize, 2), flat.pts.len);
    // Arco grande: mais de meia volta.
    const big = try parseOk(a, "M0 0 A6 6 0 1 1 10 0");
    var bl: f32 = 0;
    for (big.pts) |q| bl = @min(bl, q[1]);
    try testing.expect(bl < -6);
}

test "caminho: erros dizem o que e onde" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const casos = [_]struct { d: []const u8, at: usize }{
        .{ .d = "", .at = 1 },
        .{ .d = "L 1 1", .at = 1 },
        .{ .d = "M 0 0 L 5", .at = 10 },
        .{ .d = "M 0 0 X 5 5", .at = 7 },
        .{ .d = "M 0 0 A 5 5 0 2 0 10 0", .at = 15 },
        .{ .d = "M 0 0 Z 4", .at = 9 },
        .{ .d = "M 0 0 L 1e9 0", .at = 9 },
        .{ .d = "M 0 0 L # 0", .at = 9 },
        .{ .d = "M 1 1", .at = 6 },
        // Texto que acaba no meio de um comando: antes das bandeiras do arco, entre elas,
        // antes do ponto final, no meio de uma curva.
        .{ .d = "M0 0 A5 5 0", .at = 12 },
        .{ .d = "M0 0 A5 5 0 1", .at = 14 },
        .{ .d = "M0 0 A5 5 0 1 1", .at = 16 },
        .{ .d = "M0 0 C1 1 2", .at = 12 },
        .{ .d = "M0 0 Q1", .at = 8 },
        .{ .d = "M0 0 L1e", .at = 8 },
    };
    for (casos) |cs| {
        var pr: ?Problem = null;
        try testing.expectError(error.Invalid, parse(a, cs.d, null, .nonzero, &pr));
        const got = pr orelse return error.SemProblema;
        if (got.at != cs.at) {
            std.debug.print("{s}: esperava {d}, veio {d} ({s})\n", .{ cs.d, cs.at, got.at, got.msg });
            return error.LugarErrado;
        }
    }
    // Comprido demais: 2000 comandos.
    var long: std.ArrayList(u8) = .empty;
    try long.appendSlice(a, "M0 0");
    for (0..2000) |i| try long.print(a, " L{d} {d}", .{ i % 50, i / 50 });
    var pr: ?Problem = null;
    try testing.expectError(error.Invalid, parse(a, long.items, null, .nonzero, &pr));
    try testing.expect(std.mem.indexOf(u8, pr.?.msg, "1024") != null);
    // Curvas demais depois de achatar.
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(a, "M0 0");
    for (0..900) |_| try many.appendSlice(a, " a500 500 0 1 1 0 1");
    pr = null;
    try testing.expectError(error.Invalid, parse(a, many.items, null, .nonzero, &pr));
    try testing.expect(std.mem.indexOf(u8, pr.?.msg, "4096") != null);
}

test "caminho: lixo de todo tipo vira erro com lugar, nunca pânico" {
    // Comandos seguidos de 0 a 8 números (quase certos, então o texto acaba em qualquer
    // ponto de um comando), com pedaços quebrados no meio: ou lê, ou recusa dizendo onde.
    // Em Debug, um índice fora do texto ou uma conta que estoura param o teste aqui.
    const cmds = [_][]const u8{ "M", "m", "L", "l", "H", "v", "C", "s", "Q", "t", "A", "a", "Z", "z" };
    const nums = [_][]const u8{ " 0", " 1", "1", ",1", "-2", " .5", "5.5.5", "-.5", " 120", "-3e2", " 0 1", "10", " 1e-3", "+7" };
    // Raros, senão quase todo texto para no primeiro erro e nunca chega ao fim de um comando.
    const junk = [_][]const u8{ " 1e", "1e+", " 99999999", " 1e38", " nan", " inf", "#", "\x00", "\xff", "é", ",", ",,", "" };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var buf: [96]u8 = undefined;
    for (0..20000) |_| {
        var n: usize = 0;
        const count = rnd.uintLessThan(usize, 40);
        for (0..count) |_| {
            const roll = rnd.uintLessThan(u8, 40);
            const pc = if (roll < 8) cmds[rnd.uintLessThan(usize, cmds.len)] else if (roll == 8) junk[rnd.uintLessThan(usize, junk.len)] else nums[rnd.uintLessThan(usize, nums.len)];
            if (n + pc.len > buf.len) break;
            @memcpy(buf[n..][0..pc.len], pc);
            n += pc.len;
        }
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var pr: ?Problem = null;
        if (parse(arena.allocator(), buf[0..n], null, .nonzero, &pr)) |p| {
            for (p.pts) |q| try testing.expect(std.math.isFinite(q[0]) and std.math.isFinite(q[1]));
            try testing.expect(p.view[2] > 0 and p.view[3] > 0);
        } else |err| {
            try testing.expectEqual(error.Invalid, err);
            const got = pr orelse return error.SemProblema;
            try testing.expect(got.at >= 1 and got.at <= n + 1);
            try testing.expect(got.msg.len > 0);
        }
    }
}

test "achatamento: a tolerância segue a caixa de visão" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A mesma curva numa caixa de visão 10× maior tem menos pontos.
    var pr: ?Problem = null;
    const fine = try parse(a, "M0 0 C0 10 10 10 10 0", .{ 0, 0, 10, 10 }, .nonzero, &pr);
    const coarse = try parse(a, "M0 0 C0 10 10 10 10 0", .{ 0, 0, 1000, 1000 }, .nonzero, &pr);
    try testing.expect(fine.pts.len > coarse.pts.len);
    // Em 2048 px, o desvio de cada reta fica abaixo de meio pixel: o meio de cada reta
    // contra a curva de verdade no meio do mesmo trecho (os pontos vêm em passos iguais de t).
    const tol = 0.5 * 10 / max_px;
    const n: f32 = @floatFromInt(fine.pts.len - 1);
    for (fine.pts[0 .. fine.pts.len - 1], fine.pts[1..], 0..) |p0, p1, i| {
        const t = (@as(f32, @floatFromInt(i)) + 0.5) / n;
        const u = 1 - t;
        const x = 3 * u * t * t * 10 + t * t * t * 10;
        const y = 3 * u * u * t * 10 + 3 * u * t * t * 10;
        try testing.expect(std.math.hypot(x - (p0[0] + p1[0]) / 2, y - (p0[1] + p1[1]) / 2) < tol);
    }
    try testing.expectEqual(@as(u32, 1), curveSteps(0, 3, 0.1));
    try testing.expect(curveSteps(100, 3, 0.001) > curveSteps(100, 3, 0.1));
}

test "caixa de visão: lida, recusada e encaixada no nó sem deformar" {
    try testing.expectEqual([4]f32{ 0, 0, 24, 24 }, parseViewbox("0 0 24 24").?);
    try testing.expectEqual([4]f32{ -2, 1, 10, 5 }, parseViewbox("-2,1,10,5").?);
    try testing.expect(parseViewbox("0 0 0 24") == null);
    try testing.expect(parseViewbox("0 0 24") == null);
    try testing.expect(parseViewbox("0 0 24 24 1") == null);
    // Caixa quadrada num nó largo: escala pela altura e alinha.
    const view = [4]f32{ 0, 0, 24, 24 };
    const c = fit(view, 100, 50, 200, 48, .center);
    try testing.expectEqual(@as(f32, 2), c.s);
    try testing.expectEqual(@as(f32, 176), c.ox);
    try testing.expectEqual(@as(f32, 50), c.oy);
    try testing.expectEqual(@as(f32, 100), fit(view, 100, 50, 200, 48, .left).ox);
    try testing.expectEqual(@as(f32, 252), fit(view, 100, 50, 200, 48, .right).ox);
    // Nó alto: escala pela largura e centra na vertical.
    const tall = fit(.{ 10, 10, 20, 10 }, 0, 0, 40, 100, .center);
    try testing.expectEqual(@as(f32, 2), tall.s);
    try testing.expectEqual(@as(f32, 40), tall.oy);
    try testing.expectEqual([2]f32{ 0, 40 }, tall.apply(.{ 10, 10, 20, 10 }, .{ 10, 10 }));
    try testing.expectEqual([2]f32{ 40, 60 }, tall.apply(.{ 10, 10, 20, 10 }, .{ 30, 20 }));
}

fn alphaAt(px: []const u8, w: u32, x: u32, y: u32) u8 {
    return px[(y * w + x) * 4 + 3];
}

test "máscara: triângulo cheio, buraco com evenodd e nonzero, borda suave" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr: ?Problem = null;
    const tri = try parse(a, "M0 0 L32 0 L16 32 Z", .{ 0, 0, 32, 32 }, .nonzero, &pr);
    const px = try testing.allocator.alloc(u8, 32 * 32 * 4);
    defer testing.allocator.free(px);
    try rasterize(tri, 32, 32, px, testing.allocator);
    try testing.expectEqual(@as(u8, 255), alphaAt(px, 32, 16, 4));
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 32, 2, 28));
    try testing.expectEqual(@as(u8, 255), px[(28 * 32 + 2) * 4]);
    // Na diagonal, meio coberto.
    const edge = alphaAt(px, 32, 8, 16);
    try testing.expect(edge > 60 and edge < 200);
    // Um quadrado dentro do outro, no mesmo sentido: evenodd fura, nonzero não.
    const rings = "M0 0 H32 V32 H0 Z M8 8 H24 V24 H8 Z";
    const eo = try parse(a, rings, .{ 0, 0, 32, 32 }, .evenodd, &pr);
    try rasterize(eo, 32, 32, px, testing.allocator);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 32, 16, 16));
    try testing.expectEqual(@as(u8, 255), alphaAt(px, 32, 3, 16));
    const nz = try parse(a, rings, .{ 0, 0, 32, 32 }, .nonzero, &pr);
    try rasterize(nz, 32, 32, px, testing.allocator);
    try testing.expectEqual(@as(u8, 255), alphaAt(px, 32, 16, 16));
    // No sentido contrário, o nonzero também fura.
    const ccw = try parse(a, "M0 0 H32 V32 H0 Z M8 8 V24 H24 V8 Z", .{ 0, 0, 32, 32 }, .nonzero, &pr);
    try rasterize(ccw, 32, 32, px, testing.allocator);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 32, 16, 16));
    // O mesmo caminho dá o mesmo hash; a regra muda o hash.
    try testing.expectEqual(nz.hash, (try parse(a, rings, .{ 0, 0, 32, 32 }, .nonzero, &pr)).hash);
    try testing.expect(nz.hash != eo.hash);
}

test "os exemplos do themes/README.md" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pr: ?Problem = null;
    const ring = try parse(a, "M12 1 A11 11 0 1 1 12 23 A11 11 0 1 1 12 1 Z M12 6 A6 6 0 1 0 12 18 A6 6 0 1 0 12 6 Z", .{ 0, 0, 24, 24 }, .evenodd, &pr);
    try testing.expectEqual(@as(usize, 2), ring.subs.len);
    const px = try testing.allocator.alloc(u8, 24 * 24 * 4);
    defer testing.allocator.free(px);
    try rasterize(ring, 24, 24, px, testing.allocator);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 24, 12, 12));
    try testing.expectEqual(@as(u8, 255), alphaAt(px, 24, 12, 3));
    _ = try parse(a, "M3 12 C 8 4, 16 20, 21 12", .{ 0, 0, 24, 24 }, .nonzero, &pr);
    _ = try parse(a, "M12 2 L22 20 H2 Z", .{ 0, 0, 24, 24 }, .nonzero, &pr);
    _ = try parse(a, "M10,10 l5-5", null, .nonzero, &pr);
}
