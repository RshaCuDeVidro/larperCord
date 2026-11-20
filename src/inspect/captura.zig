//! O que o Inspetor vê de cada quadro: os pedaços do layout do tema, os itens do ImGui
//! (cada área clicável, caixa de texto, botão, janela; ver ganchos.cpp), os textos, as
//! imagens e os fundos desenhados, cada um com o retângulo, o recorte, a camada e o
//! pedaço do layout que o desenhou. Só grava com o Inspetor aberto ou a pedido do ctl:
//! fechado, cada primitiva de desenho paga a leitura de um booleano.
//!
//! O quadro é gravado em `cur` e, quando termina (depois do ImGui_Render, que diz a ordem
//! das camadas), vira `prev`: quem lê (a janela do Inspetor, o ctl) sempre vê um quadro
//! inteiro, o anterior.
const std = @import("std");
const c = @import("c");
const layout = @import("../theme/layout.zig");
const kdl = @import("../theme/kdl.zig");

pub const Rect = layout.Rect;
const gpa = std.heap.c_allocator;

pub const Kind = enum(u8) { window, item, text, image, fill, border };

/// Um pedaço de texto guardado no quadro (deslocamento e tamanho em `Frame.strs`).
pub const Str = struct {
    at: u32 = 0,
    len: u32 = 0,
};

pub const El = struct {
    kind: Kind,
    rect: Rect,
    /// A parte que aparece de verdade (o recorte da janela ou da lista de desenho).
    clip: Rect,
    /// Índice em `Frame.scopes` (0 = fora de qualquer pedaço do layout).
    scope: u16 = 0,
    /// Posição da lista de desenho na ordem final (0 = a do fundo). Vem do ImGui_Render.
    layer: u16 = 0,
    order: u32 = 0,
    dl: usize = 0,
    // Itens do ImGui.
    id: u32 = 0,
    window: u32 = 0,
    item_flags: u32 = 0,
    status: u32 = 0,
    /// Área clicável do app (draw.hit): o id dela no componente e o que aconteceu.
    hit: ?Hit = null,
    /// Texto (o que se lê), endereço da imagem, rótulo do item ou nome da marca do QA.
    str: Str = .{},
    /// Texto: tamanho da letra. Fundo e borda: o arredondamento.
    size: f32 = 0,
    /// Cor no formato do ImGui (ABGR).
    color: u32 = 0,
    /// Texto: a fonte (para achar a família e o peso). Imagem: largura e altura da textura.
    font: usize = 0,
    tex_w: u16 = 0,
    tex_h: u16 = 0,
};

pub const Hit = struct {
    local: usize,
    hovered: bool,
    held: bool,
    clicked: bool,
};

/// Um pedaço do layout do tema (componente ou contêiner) ou uma sobreposição desenhada
/// por cima (configurações, popups, paleta…).
pub const Scope = struct {
    name: []const u8,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Nó do tema; só vale enquanto `theme_gen` for o mesmo (recarregar o tema solta os nós).
    node: ?*const kdl.Node = null,
    line: u32 = 0,
    col: u32 = 0,
    depth: u8 = 0,
    component: bool = false,
    /// Microssegundos gastos desenhando (só componentes).
    us: u32 = 0,
};

pub const Layer = struct { dl: usize, name: Str = .{} };

pub const Frame = struct {
    els: std.ArrayList(El) = .empty,
    strs: std.ArrayList(u8) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    marks: std.ArrayList(Mark) = .empty,
    /// As partes do tema desenhadas (theme/parts.zig): o nome que um tema usa para cada uma.
    parts: std.ArrayList(Mark) = .empty,
    /// Número do quadro (cresce a cada quadro gravado) e a geração do tema nele.
    number: u64 = 0,
    theme_gen: u32 = 0,
    win: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    mouse: [2]f32 = .{ 0, 0 },
    hovered_window: u32 = 0,
    hovered_id: u32 = 0,
    active_id: u32 = 0,
    build_us: u32 = 0,
    complete: bool = false,

    fn clear(f: *Frame) void {
        f.els.clearRetainingCapacity();
        f.strs.clearRetainingCapacity();
        f.scopes.clearRetainingCapacity();
        f.layers.clearRetainingCapacity();
        f.marks.clearRetainingCapacity();
        f.parts.clearRetainingCapacity();
        f.complete = false;
    }

    pub fn str(f: *const Frame, s: Str) []const u8 {
        if (s.len == 0 or s.at + s.len > f.strs.items.len) return "";
        return f.strs.items[s.at..][0..s.len];
    }

    pub fn scopeOf(f: *const Frame, e: *const El) ?*const Scope {
        if (e.scope == 0 or e.scope >= f.scopes.items.len) return null;
        return &f.scopes.items[e.scope];
    }

    /// O nome da marca do QA no retângulo (só nos builds com o robô).
    pub fn markFor(f: *const Frame, r: Rect) ?[]const u8 {
        return markOf(f, r);
    }

    /// A parte do tema em que o retângulo está ("message.author:hover"), em qualquer build.
    pub fn partFor(f: *const Frame, r: Rect) ?[]const u8 {
        return partOf(f, r);
    }

    pub fn layerName(f: *const Frame, layer: u16) []const u8 {
        if (layer >= f.layers.items.len) return "";
        return f.str(f.layers.items[layer].name);
    }
};

/// Marca do QA (só nos builds com o robô): o nome que o teste usa para cada coisa.
pub const Mark = struct { key: Str, rect: Rect };

const max_els = 40_000;
const max_str_bytes = 4 * 1024 * 1024;
const max_text = 240;

var frames: [2]Frame = .{ .{}, .{} };
var cur_i: usize = 0;
/// Grava o quadro que está sendo montado.
pub var on = false;
/// O próprio Inspetor desenhando: nada dele entra no quadro.
var paused: u32 = 0;
var frame_no: u64 = 0;
var t0_ns: u64 = 0;
/// O pedaço do layout atual (índice em scopes), visto pelo C++ também.
extern var larper_insp_scope: c_int;
extern var larper_insp_order: c_uint;

extern fn larper_insp_enable(on: c_int) void;
extern fn larper_insp_clear() void;
extern fn larper_insp_count() c_int;
extern fn larper_insp_items() [*c]const CItem;
extern fn larper_insp_label(at: c_int) [*c]const u8;
extern fn larper_insp_hovered_window() c_uint;
extern fn larper_insp_hovered_id() c_uint;
extern fn larper_insp_active_id() c_uint;
pub extern fn larper_insp_window_count() c_int;
pub extern fn larper_insp_window(i: c_int, id: *c_uint, name: *[*c]const u8, rect: *[4]f32, active: *c_int, dl: *?*anyopaque) c_int;

const CItem = extern struct {
    id: c_uint,
    window: c_uint,
    draw_list: ?*anyopaque,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    cx0: f32,
    cy0: f32,
    cx1: f32,
    cy1: f32,
    item_flags: c_int,
    status: c_int,
    scope: c_int,
    label: c_int,
    order: c_uint,
    is_window: c_int,
};

/// Hits do quadro (draw.hit), juntados aos itens do ImGui pelo id no fim do quadro.
var hits: std.ArrayList(struct { id: u32, hit: Hit }) = .empty;

pub inline fn recording() bool {
    return on and paused == 0;
}

fn cur() *Frame {
    return &frames[cur_i];
}

/// O último quadro inteiro (o que a janela do Inspetor e o ctl mostram).
pub fn last() ?*const Frame {
    const f = &frames[1 - cur_i];
    return if (f.complete) f else null;
}

/// No começo do quadro (antes do ImGui_NewFrame): o anterior, se terminou, vira `prev`.
pub fn beginFrame(want: bool, theme_gen: u32) void {
    if (!want and !on) return;
    if (cur().complete) cur_i = 1 - cur_i;
    on = want;
    larper_insp_clear();
    hits.clearRetainingCapacity();
    const f = cur();
    f.clear();
    if (!on) return;
    frame_no += 1;
    f.number = frame_no;
    f.theme_gen = theme_gen;
    // O índice 0 é "fora de qualquer pedaço".
    f.scopes.append(gpa, .{ .name = "" }) catch {};
    larper_insp_scope = 0;
    t0_ns = c.SDL_GetTicksNS();
}

/// Logo depois do ImGui_NewFrame (os ganchos valem por contexto: só o principal).
pub fn afterNewFrame() void {
    larper_insp_enable(@intFromBool(on));
}

pub fn pause() void {
    paused += 1;
    if (paused == 1) larper_insp_enable(0);
}

pub fn unpause() void {
    if (paused == 0) return;
    paused -= 1;
    if (paused == 0) larper_insp_enable(@intFromBool(on));
}

/// Abre um pedaço (componente do layout ou sobreposição). Devolve o anterior para `endScope`.
pub fn scope(name: []const u8, r: Rect, node: ?*const kdl.Node, depth: u8, component: bool) c_int {
    const before = larper_insp_scope;
    if (!recording()) return before;
    const f = cur();
    if (f.scopes.items.len >= std.math.maxInt(u16)) return before;
    f.scopes.append(gpa, .{
        .name = name,
        .rect = r,
        .node = node,
        .line = if (node) |n| n.line else 0,
        .col = if (node) |n| n.col else 0,
        .depth = depth,
        .component = component,
    }) catch return before;
    larper_insp_scope = @intCast(f.scopes.items.len - 1);
    return before;
}

pub fn endScope(before: c_int, us: u64) void {
    if (!on) return;
    const f = cur();
    const i: usize = @intCast(@max(larper_insp_scope, 0));
    if (us > 0 and i < f.scopes.items.len) f.scopes.items[i].us = @intCast(@min(us, std.math.maxInt(u32)));
    larper_insp_scope = before;
}

/// Um contêiner do layout (sem desenho próprio): entra na árvore com o retângulo dele.
pub fn container(name: []const u8, r: Rect, node: *const kdl.Node, depth: u8) void {
    const before = scope(name, r, node, depth, false);
    larper_insp_scope = before;
}

fn keep(s: []const u8) Str {
    const f = cur();
    if (s.len == 0) return .{};
    const n = @min(s.len, max_text);
    if (f.strs.items.len + n > max_str_bytes) return .{};
    const at: u32 = @intCast(f.strs.items.len);
    // Sem partir um caractere no meio.
    var k = n;
    if (k < s.len) while (k > 0 and (s[k] & 0xC0) == 0x80) {
        k -= 1;
    };
    f.strs.appendSlice(gpa, s[0..k]) catch return .{};
    return .{ .at = at, .len = @intCast(k) };
}

fn clipOf(dl: *c.ImDrawList) Rect {
    const lo = c.ImDrawList_GetClipRectMin(dl);
    const hi = c.ImDrawList_GetClipRectMax(dl);
    return .{ .x = lo.x, .y = lo.y, .w = hi.x - lo.x, .h = hi.y - lo.y };
}

fn push(e: El) void {
    const f = cur();
    if (f.els.items.len >= max_els) return;
    var x = e;
    x.scope = @intCast(@max(larper_insp_scope, 0));
    x.order = larper_insp_order;
    larper_insp_order +%= 1;
    f.els.append(gpa, x) catch {};
}

/// Texto desenhado (draw.textDir): `w` é a largura medida por quem desenhou.
pub fn text(dl: *c.ImDrawList, font: *c.ImFont, size: f32, x: f32, y: f32, w: f32, color: u32, s: []const u8) void {
    push(.{
        .kind = .text,
        .rect = .{ .x = x, .y = y, .w = w, .h = size * 1.25 },
        .clip = clipOf(dl),
        .dl = @intFromPtr(dl),
        .str = keep(s),
        .size = size,
        .color = color,
        .font = @intFromPtr(font),
    });
}

pub fn fill(dl: *c.ImDrawList, r: Rect, color: u32, rounding: f32) void {
    push(.{ .kind = .fill, .rect = r, .clip = clipOf(dl), .dl = @intFromPtr(dl), .size = rounding, .color = color });
}

pub fn border(dl: *c.ImDrawList, r: Rect, color: u32, rounding: f32) void {
    push(.{ .kind = .border, .rect = r, .clip = clipOf(dl), .dl = @intFromPtr(dl), .size = rounding, .color = color });
}

/// Imagem desenhada: o endereço (ou o nome) e o tamanho da textura, se já carregou.
pub fn image(dl: *c.ImDrawList, r: Rect, url: []const u8, tex_w: u32, tex_h: u32) void {
    push(.{
        .kind = .image,
        .rect = r,
        .clip = clipOf(dl),
        .dl = @intFromPtr(dl),
        .str = keep(url),
        .tex_w = @intCast(@min(tex_w, std.math.maxInt(u16))),
        .tex_h = @intCast(@min(tex_h, std.math.maxInt(u16))),
    });
}

/// Área clicável do app (draw.hit), logo depois do InvisibleButton dela.
pub fn hit(local: usize, hovered: bool, held: bool, clicked: bool) void {
    const id = c.ImGui_GetItemID();
    hits.append(gpa, .{ .id = id, .hit = .{ .local = local, .hovered = hovered, .held = held, .clicked = clicked } }) catch {};
}

/// Marca do QA (só nos builds com o robô): o nome que os testes usam.
pub fn mark(r: Rect, key: []const u8) void {
    const f = cur();
    f.marks.append(gpa, .{ .key = keep(key), .rect = r }) catch {};
}

/// Parte do tema desenhada em `r` (ui/parts.zig, só gravando).
pub fn part(r: Rect, name: []const u8) void {
    const f = cur();
    f.parts.append(gpa, .{ .key = keep(name), .rect = r }) catch {};
}

/// Depois do ImGui_Render: junta os itens do ImGui, descobre a camada de cada lista de
/// desenho pela ordem final e fecha o quadro.
pub fn endFrame(mouse: c.ImVec2, win: Rect) void {
    if (!on) return;
    const f = cur();
    larper_insp_enable(0);
    // Os itens do ImGui, na ordem em que entraram.
    const n: usize = @intCast(@max(larper_insp_count(), 0));
    const items = larper_insp_items();
    const sort_hits = struct {
        fn lt(_: void, a: @TypeOf(hits.items[0]), b: @TypeOf(hits.items[0])) bool {
            return a.id < b.id;
        }
    };
    std.mem.sortUnstable(@TypeOf(hits.items[0]), hits.items, {}, sort_hits.lt);
    for (0..n) |i| {
        if (f.els.items.len >= max_els) break;
        const it = items[i];
        var e: El = .{
            .kind = if (it.is_window != 0) .window else .item,
            .rect = .{ .x = it.x0, .y = it.y0, .w = it.x1 - it.x0, .h = it.y1 - it.y0 },
            .clip = .{ .x = it.cx0, .y = it.cy0, .w = it.cx1 - it.cx0, .h = it.cy1 - it.cy0 },
            .scope = @intCast(std.math.clamp(it.scope, 0, @as(c_int, @intCast(f.scopes.items.len -| 1)))),
            .order = it.order,
            .dl = @intFromPtr(it.draw_list),
            .id = it.id,
            .window = it.window,
            .item_flags = @bitCast(it.item_flags),
            .status = @bitCast(it.status),
        };
        if (it.label >= 0) e.str = keep(std.mem.span(larper_insp_label(it.label)));
        if (findHit(it.id)) |h| e.hit = h;
        f.els.append(gpa, e) catch break;
    }
    // Tudo na ordem em que foi desenhado (itens do ImGui e primitivas do app se intercalam).
    const by_order = struct {
        fn lt(_: void, a: El, b: El) bool {
            return a.order < b.order;
        }
    };
    std.mem.sort(El, f.els.items, {}, by_order.lt);
    mergeTexts(f);
    // As camadas: a ordem das listas de desenho no resultado final (de trás para a frente).
    const dd = c.ImGui_GetDrawData();
    if (dd != null) {
        const lists: usize = @intCast(@max(dd.*.CmdLists.Size, 0));
        for (0..lists) |li| {
            const dl = dd.*.CmdLists.Data[li];
            f.layers.append(gpa, .{ .dl = @intFromPtr(dl), .name = keep(if (dl.*._OwnerName != null) std.mem.span(dl.*._OwnerName) else "") }) catch {};
        }
    }
    for (f.els.items) |*e| e.layer = layerOf(f, e.dl);
    f.win = win;
    f.mouse = .{ mouse.x, mouse.y };
    f.hovered_window = larper_insp_hovered_window();
    f.hovered_id = larper_insp_hovered_id();
    f.active_id = larper_insp_active_id();
    f.build_us = @intCast(@min((c.SDL_GetTicksNS() - t0_ns) / 1000, std.math.maxInt(u32)));
    f.complete = true;
    larper_insp_scope = -1;
}

/// O texto rico é desenhado aos pedaços (palavra por palavra, para a seleção e as quebras de
/// linha): pedaços seguidos na mesma linha, com a mesma letra e cor, viram um texto só,
/// como se lê. Um espaço entra quando há um vão entre eles.
fn mergeTexts(f: *Frame) void {
    var out: usize = 0;
    for (f.els.items, 0..) |e, i| {
        if (out > 0 and i > 0) {
            const p = &f.els.items[out - 1];
            if (p.kind == .text and e.kind == .text and p.dl == e.dl and p.scope == e.scope and p.color == e.color and
                p.size == e.size and p.font == e.font and @abs(p.rect.y - e.rect.y) < 0.5)
            {
                const gap = e.rect.x - p.rect.right();
                if (gap > -1 and gap < e.size * 0.75) {
                    var b: [max_text]u8 = undefined;
                    const a = f.str(p.str);
                    const sp: []const u8 = if (gap > e.size * 0.12) " " else "";
                    const joined = std.fmt.bufPrint(&b, "{s}{s}{s}", .{ a, sp, f.str(e.str) }) catch a;
                    p.str = keep(joined);
                    p.rect.w = e.rect.right() - p.rect.x;
                    continue;
                }
            }
        }
        f.els.items[out] = e;
        out += 1;
    }
    f.els.shrinkRetainingCapacity(out);
}

fn findHit(id: u32) ?Hit {
    var lo: usize = 0;
    var hi: usize = hits.items.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (hits.items[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < hits.items.len and hits.items[lo].id == id) return hits.items[lo].hit;
    return null;
}

fn layerOf(f: *const Frame, dl: usize) u16 {
    for (f.layers.items, 0..) |l, i| if (l.dl == dl) return @intCast(i);
    // Lista que não foi para a tela (janela escondida, ou recortada inteira).
    return 0;
}

// --- Leitura ------------------------------------------------------------------

pub fn visible(e: *const El) bool {
    return e.rect.w > 0 and e.rect.h > 0 and overlap(e.rect, e.clip).w > 0 and overlap(e.rect, e.clip).h > 0;
}

pub fn overlap(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.right(), b.right());
    const y1 = @min(a.bottom(), b.bottom());
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

pub fn contains(outer: Rect, inner: Rect) bool {
    const eps: f32 = 0.5;
    return inner.x >= outer.x - eps and inner.y >= outer.y - eps and inner.right() <= outer.right() + eps and inner.bottom() <= outer.bottom() + eps;
}

fn area(r: Rect) f32 {
    return r.w * r.h;
}

/// O elemento sob o ponto, como o "selecionar elemento" do navegador: a camada mais de
/// cima ganha; na mesma camada, o menor (o mais específico); empatando, o desenhado depois.
/// Janelas só se não houver mais nada; fundos que cobrem a janela inteira, nunca.
pub fn pick(f: *const Frame, x: f32, y: f32) ?usize {
    const Key = struct { layer: u16, rank: u8, area: f32, order: u32, pref: u8 };
    var best: ?usize = null;
    var best_key: Key = undefined;
    const win_area = area(f.win);
    for (f.els.items, 0..) |*e, i| {
        if (!visible(e)) continue;
        if (!e.rect.contains(x, y) or !e.clip.contains(x, y)) continue;
        const a = area(e.rect);
        if (e.kind == .fill and a >= win_area * 0.9) continue;
        // Janela por último; o resto disputa pelo tamanho.
        const rank: u8 = if (e.kind == .window) 0 else 1;
        const key: Key = .{ .layer = e.layer, .rank = rank, .area = a, .order = e.order, .pref = prefOf(e.kind) };
        if (best == null or better(key, best_key)) {
            best = i;
            best_key = key;
        }
    }
    return best;
}

fn better(a: anytype, b: anytype) bool {
    if (a.layer != b.layer) return a.layer > b.layer;
    if (a.rank != b.rank) return a.rank > b.rank;
    // Quase do mesmo tamanho (o fundo de destaque de uma linha e a área clicável dela):
    // ganha o que diz mais — a área clicável, depois o texto ou a imagem, depois o fundo.
    const close = @min(a.area, b.area) >= @max(a.area, b.area) * 0.9;
    if (close and a.pref != b.pref) return a.pref > b.pref;
    if (@abs(a.area - b.area) > 0.5) return a.area < b.area;
    return a.order > b.order;
}

fn prefOf(k: Kind) u8 {
    return switch (k) {
        .item => 3,
        .text, .image => 2,
        .fill, .border => 1,
        .window => 0,
    };
}

/// Os que contêm `i` (do mais justo ao mais largo), na mesma camada ou abaixo: a "linhagem"
/// que o painel mostra como a árvore de um elemento.
pub fn ancestors(f: *const Frame, i: usize, out: []usize) []usize {
    const e = &f.els.items[i];
    var n: usize = 0;
    for (f.els.items, 0..) |*o, j| {
        if (j == i or n == out.len) continue;
        if (o.kind == .text or o.kind == .image) continue;
        if (o.layer > e.layer) continue;
        if (!contains(o.rect, e.rect)) continue;
        if (area(o.rect) <= area(e.rect) and o.order >= e.order) continue;
        out[n] = j;
        n += 1;
    }
    const S = struct {
        fn lt(ff: *const Frame, a: usize, b: usize) bool {
            return area(ff.els.items[a].rect) < area(ff.els.items[b].rect);
        }
    };
    std.mem.sort(usize, out[0..n], f, S.lt);
    return out[0..n];
}

/// Os textos dentro de um retângulo, na ordem em que foram desenhados (o "rótulo" de um
/// botão que é só uma área clicável).
pub fn textsIn(f: *const Frame, r: Rect, layer: u16, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (f.els.items) |*e| {
        if (e.kind != .text or e.layer != layer) continue;
        if (!contains(r, e.rect)) continue;
        const s = f.str(e.str);
        if (s.len == 0) continue;
        if (w.buffered().len > 0) w.writeAll(" ") catch break;
        w.writeAll(s) catch break;
    }
    return w.buffered();
}

/// O nome da marca do QA que coincide com o retângulo (só nos builds com o robô).
pub fn markOf(f: *const Frame, r: Rect) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: f32 = 3;
    for (f.marks.items) |m| {
        const dd = @abs(m.rect.x - r.x) + @abs(m.rect.y - r.y) + @abs(m.rect.w - r.w) + @abs(m.rect.h - r.h);
        if (dd < best_d) {
            best_d = dd;
            best = f.str(m.key);
        }
    }
    return best;
}

/// A parte do tema mais justa que tem o meio do retângulo: o nome do texto, a linha da
/// mensagem em volta dele, e assim por diante.
pub fn partOf(f: *const Frame, r: Rect) ?[]const u8 {
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;
    var best: ?[]const u8 = null;
    var best_area: f32 = std.math.floatMax(f32);
    for (f.parts.items) |p| {
        if (!p.rect.contains(mx, my)) continue;
        const a = area(p.rect);
        if (a < best_area) {
            best_area = a;
            best = f.str(p.key);
        }
    }
    return best;
}

/// O fundo visível embaixo de um elemento: o último preenchimento desenhado antes dele,
/// na mesma camada ou abaixo, que o cobre (para o contraste de um texto).
pub fn backgroundOf(f: *const Frame, i: usize) ?u32 {
    const e = &f.els.items[i];
    var best: ?u32 = null;
    var best_layer: u16 = 0;
    var best_order: u32 = 0;
    for (f.els.items) |*o| {
        if (o.kind != .fill) continue;
        if ((o.color >> 24) < 0xF0) continue;
        if (o.layer > e.layer or (o.layer == e.layer and o.order >= e.order)) continue;
        if (!contains(o.rect, e.rect)) continue;
        if (best == null or o.layer > best_layer or (o.layer == best_layer and o.order > best_order)) {
            best = o.color;
            best_layer = o.layer;
            best_order = o.order;
        }
    }
    return best;
}

const t = std.testing;

test "escolher elemento: camada de cima, depois o menor, depois o mais novo" {
    var f: Frame = .{};
    defer {
        f.els.deinit(gpa);
        f.strs.deinit(gpa);
    }
    f.win = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const big: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const small: Rect = .{ .x = 10, .y = 10, .w = 50, .h = 20 };
    try f.els.append(gpa, .{ .kind = .fill, .rect = f.win, .clip = f.win, .order = 0 });
    try f.els.append(gpa, .{ .kind = .item, .rect = big, .clip = f.win, .order = 1 });
    try f.els.append(gpa, .{ .kind = .text, .rect = small, .clip = f.win, .order = 2 });
    try f.els.append(gpa, .{ .kind = .window, .rect = f.win, .clip = f.win, .order = 3 });
    // O texto é o menor sob o ponto.
    try t.expectEqual(@as(?usize, 2), pick(&f, 20, 15));
    // Fora do texto, o item; o fundo da janela inteira nunca.
    try t.expectEqual(@as(?usize, 1), pick(&f, 200, 200));
    // Fora de tudo, só a janela.
    try t.expectEqual(@as(?usize, 3), pick(&f, 900, 700));
    // Uma camada de cima ganha mesmo sendo maior.
    try f.els.append(gpa, .{ .kind = .item, .rect = big, .clip = f.win, .order = 4, .layer = 3 });
    try t.expectEqual(@as(?usize, 4), pick(&f, 20, 15));
    // Do mesmo tamanho que um fundo, a área clicável ganha (mesmo desenhada antes).
    const row: Rect = .{ .x = 500, .y = 500, .w = 200, .h = 30 };
    try f.els.append(gpa, .{ .kind = .item, .rect = row, .clip = f.win, .order = 5 });
    try f.els.append(gpa, .{ .kind = .fill, .rect = row, .clip = f.win, .order = 6 });
    try t.expectEqual(@as(?usize, 5), pick(&f, 510, 510));
    // Recortado: a parte fora do recorte não conta.
    f.els.items[4].clip = .{ .x = 300, .y = 0, .w = 100, .h = 300 };
    try t.expectEqual(@as(?usize, 2), pick(&f, 20, 15));
}

test "pedaços de texto na mesma linha viram um texto só" {
    const f = cur();
    f.clear();
    const w: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 10, .y = 5, .w = 30, .h = 18 }, .clip = w, .size = 14, .color = 1, .str = keep("imagi") });
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 40, .y = 5, .w = 12, .h = 18 }, .clip = w, .size = 14, .color = 1, .str = keep("na") });
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 56, .y = 5, .w = 20, .h = 18 }, .clip = w, .size = 14, .color = 1, .str = keep("um") });
    // Outra cor: fica separado.
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 78, .y = 5, .w = 20, .h = 18 }, .clip = w, .size = 14, .color = 2, .str = keep("link") });
    // Outra linha: também.
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 10, .y = 25, .w = 20, .h = 18 }, .clip = w, .size = 14, .color = 2, .str = keep("dois") });
    mergeTexts(f);
    try t.expectEqual(@as(usize, 3), f.els.items.len);
    try t.expectEqualStrings("imagina um", f.str(f.els.items[0].str));
    try t.expectEqual(@as(f32, 66), f.els.items[0].rect.w);
    try t.expectEqualStrings("link", f.str(f.els.items[1].str));
    f.clear();
}

test "linhagem: do mais justo ao mais largo, sem textos" {
    var f: Frame = .{};
    defer f.els.deinit(gpa);
    const w: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try f.els.append(gpa, .{ .kind = .fill, .rect = w, .clip = w, .order = 0 });
    try f.els.append(gpa, .{ .kind = .item, .rect = .{ .x = 0, .y = 0, .w = 300, .h = 300 }, .clip = w, .order = 1 });
    try f.els.append(gpa, .{ .kind = .fill, .rect = .{ .x = 5, .y = 5, .w = 100, .h = 40 }, .clip = w, .order = 2 });
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 10, .y = 10, .w = 30, .h = 15 }, .clip = w, .order = 3 });
    var buf: [8]usize = undefined;
    const a = ancestors(&f, 3, &buf);
    try t.expectEqual(@as(usize, 3), a.len);
    try t.expectEqual(@as(usize, 2), a[0]);
    try t.expectEqual(@as(usize, 1), a[1]);
    try t.expectEqual(@as(usize, 0), a[2]);
}

test "fundo de um texto: o último preenchimento opaco antes dele que o cobre" {
    var f: Frame = .{};
    defer f.els.deinit(gpa);
    const w: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    try f.els.append(gpa, .{ .kind = .fill, .rect = w, .clip = w, .order = 0, .color = 0xFF111111 });
    try f.els.append(gpa, .{ .kind = .fill, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 50 }, .clip = w, .order = 1, .color = 0xFF222222 });
    // Translúcido: não conta como fundo.
    try f.els.append(gpa, .{ .kind = .fill, .rect = .{ .x = 0, .y = 0, .w = 200, .h = 50 }, .clip = w, .order = 2, .color = 0x40FFFFFF });
    try f.els.append(gpa, .{ .kind = .text, .rect = .{ .x = 10, .y = 10, .w = 30, .h = 15 }, .clip = w, .order = 3 });
    // Desenhado depois do texto: está por cima, não embaixo.
    try f.els.append(gpa, .{ .kind = .fill, .rect = w, .clip = w, .order = 4, .color = 0xFF333333 });
    try t.expectEqual(@as(?u32, 0xFF222222), backgroundOf(&f, 3));
}

test "parte do tema: a mais justa que tem o meio do elemento" {
    var f: Frame = .{};
    defer {
        f.parts.deinit(gpa);
        f.strs.deinit(gpa);
    }
    const add = struct {
        fn put(fr: *Frame, r: Rect, name: []const u8) !void {
            const at: u32 = @intCast(fr.strs.items.len);
            try fr.strs.appendSlice(gpa, name);
            try fr.parts.append(gpa, .{ .key = .{ .at = at, .len = @intCast(name.len) }, .rect = r });
        }
    }.put;
    try add(&f, .{ .x = 0, .y = 0, .w = 700, .h = 60 }, "message:hover");
    try add(&f, .{ .x = 60, .y = 4, .w = 80, .h = 20 }, "message.author:hover");
    // O nome dentro da linha é do nome; o texto embaixo dele, da linha.
    try t.expectEqualStrings("message.author:hover", f.partFor(.{ .x = 62, .y = 6, .w = 70, .h = 16 }).?);
    try t.expectEqualStrings("message:hover", f.partFor(.{ .x = 60, .y = 30, .w = 300, .h = 18 }).?);
    try t.expect(f.partFor(.{ .x = 800, .y = 30, .w = 10, .h = 10 }) == null);
}
