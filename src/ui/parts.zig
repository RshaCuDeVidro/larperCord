//! Desenho das partes do tema (theme/parts.zig): cada componente pede o `Look` do
//! pedaço que está desenhando, na combinação de estados dele, e usa o que vier no lugar
//! do desenho de sempre. Tema sem `parts` dá sempre `none` (tudo null) e o componente
//! segue pelo caminho de sempre, pixel por pixel.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const tp = @import("../theme/parts.zig");
const insp = @import("../inspect/captura.zig");

pub const Part = tp.Part;
pub const States = tp.States;
pub const Look = tp.Look;

/// O tema tem alguma parte: só então vale calcular um estado que custa (quem fala).
pub fn on(ctx: *const d.Ctx) bool {
    return ctx.th.parts != null;
}

pub fn look(ctx: *const d.Ctx, p: Part, s: States) *const Look {
    const t = ctx.th.parts orelse return &tp.none;
    return t.get(p, s);
}

/// A cor da parte, com os tokens de agora (destaque escolhido, `c-…` do nó), ou a de sempre.
pub fn colorOr(ctx: *const d.Ctx, e: ?*const tp.Expr, default: d.Rgba) d.Rgba {
    const x = e orelse return default;
    return x.eval(ctx.th.tokenValues());
}

pub fn weightOr(l: *const Look, default: d.Weight) d.Weight {
    const w = l.weight orelse return default;
    return @enumFromInt(@intFromEnum(w));
}

/// O fundo da parte, se ela tiver um. Devolve se desenhou.
pub fn fill(ctx: *const d.Ctx, dl: *c.ImDrawList, l: *const Look, r: d.Rect, default_radius: f32) bool {
    const e = l.bg orelse return false;
    d.rect(dl, shown(dl, r), e.eval(ctx.th.tokenValues()), l.radius orelse default_radius);
    return true;
}

/// O pedaço de `r` que aparece na horizontal: a linha de uma mensagem vai até a beirada da
/// lista, por baixo do lugar da barra de rolagem, que o recorte esconde. O fundo, a borda e
/// a faixa ficam no que aparece (com os cantos arredondados à vista).
fn shown(dl: *c.ImDrawList, r: d.Rect) d.Rect {
    const lo = c.ImDrawList_GetClipRectMin(dl);
    const hi = c.ImDrawList_GetClipRectMax(dl);
    const x0 = @max(r.x, lo.x);
    const x1 = @min(r.right(), hi.x);
    if (x1 - x0 < 1) return r;
    return .{ .x = x0, .y = r.y, .w = x1 - x0, .h = r.h };
}

pub fn border(ctx: *const d.Ctx, dl: *c.ImDrawList, l: *const Look, r: d.Rect, default_radius: f32) void {
    const e = l.border orelse return;
    d.border(dl, shown(dl, r), e.eval(ctx.th.tokenValues()), l.radius orelse default_radius, l.border_width);
}

/// A borda só com alguns cantos arredondados (a caixa de mensagem com a barra de
/// "Respondendo a…" presa em cima). `radius` já é o final.
pub fn borderFlags(ctx: *const d.Ctx, dl: *c.ImDrawList, l: *const Look, r: d.Rect, radius: f32, flags: c_int) void {
    const e = l.border orelse return;
    const col = e.eval(ctx.th.tokenValues());
    const sr = shown(dl, r);
    if (flags == 0) return d.border(dl, sr, col, radius, l.border_width);
    if (insp.recording()) insp.border(dl, sr, col.u(), radius);
    const h = l.border_width / 2;
    c.ImDrawList_AddRectEx(dl, d.v(sr.x + h, sr.y + h), d.v(sr.right() - h, sr.bottom() - h), col.u(), radius, l.border_width, flags);
}

/// A faixa no lado em que o texto começa: à esquerda, ou à direita (`right`) numa linha
/// da direita para a esquerda. Os cantos de fora acompanham os da parte.
pub fn bar(ctx: *const d.Ctx, dl: *c.ImDrawList, l: *const Look, r_in: d.Rect, right: bool, default_radius: f32) void {
    const e = l.bar orelse return;
    const r = shown(dl, r_in);
    const w = @min(l.bar_width, r.w);
    const br: d.Rect = .{ .x = if (right) r.right() - w else r.x, .y = r.y, .w = w, .h = r.h };
    d.rectFlags(dl, br, e.eval(ctx.th.tokenValues()), l.radius orelse default_radius, if (right) c.ImDrawFlags_RoundCornersRight else c.ImDrawFlags_RoundCornersLeft);
}

/// `opacity`: guarda onde o desenho da parte começa e, no fim, multiplica a opacidade
/// do que foi desenhado desde ali (o mesmo jeito das animações, `draw.transformVerts`).
pub const Fade = struct {
    dl: *c.ImDrawList,
    start: c_int,
    k: f32,

    pub fn begin(dl: *c.ImDrawList, l: *const Look) Fade {
        return .{ .dl = dl, .start = dl.*.VtxBuffer.Size, .k = l.opacity };
    }

    pub fn end(f: Fade) void {
        if (f.k < 1) d.transformVerts(f.dl, f.start, d.v(0, 0), 1, 0, f.k);
    }
};

/// Para o Inspetor: o nome da parte, com os estados de agora, no retângulo dela
/// ("channel.item:hover:selected"). O que um tema escreveria para mexer nela.
pub fn mark(r: d.Rect, p: Part, s: States) void {
    if (!insp.recording()) return;
    var buf: [96]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll(tp.partes[@intFromEnum(p)].name) catch return;
    const bits: u8 = @bitCast(s);
    for (tp.estados, 0..) |e, i| if (bits & (@as(u8, 1) << @intCast(i)) != 0 and tp.hasState(p, @enumFromInt(i))) {
        w.print(":{s}", .{e.name}) catch return;
    };
    insp.part(r, w.buffered());
}
