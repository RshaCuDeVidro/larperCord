//! Aba Elementos: a árvore do quadro (os pedaços do layout do tema e, dentro de cada um,
//! o que ele desenhou, aninhado pelo que contém o quê) e, do escolhido, o que importa
//! para mexer no app ou num tema: de onde vem no .kdl, as cores com o nome no tema, a
//! letra, o contraste com o fundo, o id do ImGui, a marca do QA e quanto custou.
const std = @import("std");
const c = @import("c");
const d = @import("../ui/draw.zig");
const i18n = @import("../ui/i18n.zig");
const kit = @import("kit.zig");
const qa = @import("../ui/qa.zig");
const cap = @import("captura.zig");
const ui = @import("ui.zig");
const theme_mod = @import("../theme/theme.zig");
const kdl = @import("../theme/kdl.zig");
const App = @import("../app.zig").App;

const gpa = std.heap.c_allocator;

const RowKind = enum { scope, el, outside };
const Row = struct { kind: RowKind, index: usize, depth: u16, key: u64, has_kids: bool, open: bool };

var rows: std.ArrayList(Row) = .empty;
var open_keys: std.AutoHashMapUnmanaged(u64, bool) = .empty;
/// Os elementos de cada pedaço do layout, na ordem em que foram desenhados.
var by_scope: std.ArrayList(std.ArrayList(usize)) = .empty;
var filter: [96]u8 = @splat(0);
var split: f32 = 0.55;
var sec_theme = true;
var sec_visual = true;
var sec_item = true;
var sec_inside = true;
var sec_path = true;
var built_for: u64 = 0;

fn keyOf(a: u64, b: anytype) u64 {
    var h = std.hash.Wyhash.init(a);
    h.update(std.mem.asBytes(&b));
    return h.final();
}

fn scopeKey(f: *const cap.Frame, si: usize) u64 {
    const s = &f.scopes.items[si];
    var h = std.hash.Wyhash.init(0x5c09e);
    h.update(s.name);
    h.update(std.mem.asBytes(&s.line));
    h.update(std.mem.asBytes(&s.col));
    h.update(std.mem.asBytes(&s.depth));
    // Duas sobreposições de mesmo nome não acontecem; dois nós na mesma linha, também não.
    return h.final();
}

fn isOpen(key: u64, default: bool) bool {
    return open_keys.get(key) orelse default;
}

fn container(k: cap.Kind) bool {
    return k == .fill or k == .border or k == .item or k == .window;
}

/// Refaz a lista de linhas visíveis da árvore (com o que está aberto).
fn build(f: *const cap.Frame) void {
    rows.clearRetainingCapacity();
    // Os elementos de cada pedaço.
    while (by_scope.items.len < f.scopes.items.len) by_scope.append(gpa, .empty) catch return;
    for (by_scope.items) |*l| l.clearRetainingCapacity();
    for (f.els.items, 0..) |*e, i| {
        if (e.scope < by_scope.items.len) by_scope.items[e.scope].append(gpa, i) catch {};
    }
    // Os pedaços do layout, na ordem da árvore (o layout grava em pré-ordem com a
    // profundidade); um fechado esconde os mais fundos que vêm depois dele.
    var hide_below: ?u16 = null;
    for (f.scopes.items[1..], 1..) |*s, si| {
        const depth: u16 = s.depth;
        if (hide_below) |hb| {
            if (depth > hb) continue;
            hide_below = null;
        }
        const key = scopeKey(f, si);
        // Contêineres do layout abertos (a estrutura aparece); componentes e sobreposições fechados.
        const default = !s.component and s.node != null;
        const els = by_scope.items[si].items;
        const has_child_scope = si + 1 < f.scopes.items.len and f.scopes.items[si + 1].depth > s.depth and f.scopes.items[si + 1].node != null and s.node != null;
        const has_kids = els.len > 0 or has_child_scope;
        const o = isOpen(key, default);
        rows.append(gpa, .{ .kind = .scope, .index = si, .depth = depth, .key = key, .has_kids = has_kids, .open = o }) catch return;
        if (!o) {
            hide_below = depth;
            continue;
        }
        addElements(f, els, depth + 1, key);
    }
    if (by_scope.items.len > 0 and by_scope.items[0].items.len > 0) {
        const key: u64 = 0x0f0a;
        const o = isOpen(key, false);
        rows.append(gpa, .{ .kind = .outside, .index = 0, .depth = 0, .key = key, .has_kids = true, .open = o }) catch return;
        if (o) addElements(f, by_scope.items[0].items, 1, key);
    }
}

/// Os elementos de um pedaço, aninhados: um fundo ou uma área clicável "contém" o que
/// foi desenhado depois dentro dele.
fn addElements(f: *const cap.Frame, els: []const usize, base: u16, parent_key: u64) void {
    var stack: [64]struct { i: usize, key: u64, open: bool } = undefined;
    var n: usize = 0;
    var closed_depth: ?usize = null;
    for (els, 0..) |i, ord| {
        const e = &f.els.items[i];
        if (!cap.visible(e) and e.kind != .window) continue;
        while (n > 0 and !cap.contains(f.els.items[stack[n - 1].i].rect, e.rect)) n -= 1;
        if (closed_depth) |cd| {
            if (n > cd) continue;
            closed_depth = null;
        }
        const key = keyOf(if (n > 0) stack[n - 1].key else parent_key, ord);
        const kids = container(e.kind) and nextInside(f, els, ord, e.rect);
        const o = isOpen(key, true);
        if (rows.items.len < 60_000) rows.append(gpa, .{ .kind = .el, .index = i, .depth = base + @as(u16, @intCast(n)), .key = key, .has_kids = kids, .open = o }) catch return;
        if (kids and n < stack.len) {
            stack[n] = .{ .i = i, .key = key, .open = o };
            n += 1;
            if (!o) closed_depth = n - 1;
        }
    }
}

fn nextInside(f: *const cap.Frame, els: []const usize, ord: usize, r: cap.Rect) bool {
    if (ord + 1 >= els.len) return false;
    return cap.contains(r, f.els.items[els[ord + 1]].rect);
}

/// Revela o escolhido: abre o caminho até ele e devolve a linha.
fn revealRow(f: *const cap.Frame) ?usize {
    if (!ui.sel.on) return null;
    if (ui.sel.scope_only) {
        const si = ui.sel.scope_index orelse return null;
        for (rows.items, 0..) |r, k| if (r.kind == .scope and r.index == si) return k;
        return null;
    }
    const target = ui.sel.index orelse return null;
    const e = &f.els.items[target];
    // Abre o pedaço dele e os pedaços acima (os de menos profundidade antes dele).
    if (e.scope > 0 and e.scope < f.scopes.items.len) {
        open_keys.put(gpa, scopeKey(f, e.scope), true) catch {};
        var want = f.scopes.items[e.scope].depth;
        var si = e.scope;
        while (si > 1 and want > 0) {
            si -= 1;
            if (f.scopes.items[si].depth < want) {
                open_keys.put(gpa, scopeKey(f, si), true) catch {};
                want = f.scopes.items[si].depth;
            }
        }
    } else open_keys.put(gpa, 0x0f0a, true) catch {};
    build(f);
    for (rows.items, 0..) |r, k| if (r.kind == .el and r.index == target) return k;
    return null;
}

pub fn draw(u: *kit.Ui, app: *App, r: kit.Rect) void {
    _ = app;
    const f = cap.last() orelse {
        empty(u, r, i18n.tr("Gravando o primeiro quadro…", "Capturing the first frame…"));
        @import("../ui/anim.zig").active = true;
        return;
    };
    // Barra: busca.
    const bar_h: f32 = 30;
    kit.rect(u, .{ .x = r.x, .y = r.y, .w = r.w, .h = bar_h }, kit.pal.panel, 0);
    kit.hline(u, r.x, r.right(), r.y + bar_h - 1, kit.pal.line);
    qa.mark(.{ .x = r.x + 6, .y = r.y + 4, .w = @min(320, r.w - 12), .h = bar_h - 8 }, "insp-el-filter", .{});
    _ = kit.search(u, "##el-filter", .{ .x = r.x + 6, .y = r.y + 4, .w = @min(320, r.w - 12), .h = bar_h - 8 }, &filter, i18n.trZ("Buscar por texto, componente, cor ou marca", "Search by text, component, color or mark"));
    const body: kit.Rect = .{ .x = r.x, .y = r.y + bar_h, .w = r.w, .h = r.h - bar_h };
    // Estreito: árvore em cima, detalhes embaixo; largo: lado a lado.
    const side = body.w >= 720;
    const tree_r: kit.Rect = if (side) .{ .x = body.x, .y = body.y, .w = body.w * split, .h = body.h } else .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h * split };
    const det_r: kit.Rect = if (side) .{ .x = body.x + body.w * split + 1, .y = body.y, .w = body.w * (1 - split) - 1, .h = body.h } else .{ .x = body.x, .y = body.y + body.h * split + 1, .w = body.w, .h = body.h * (1 - split) - 1 };
    if (kit.bufStr(&filter).len > 0) searchList(u, f, tree_r) else tree(u, f, tree_r);
    details(u, f, det_r);
    kit.splitter(u, body, side, &split, 160, 160, 0xe1);
}

fn empty(u: *kit.Ui, r: kit.Rect, msg: []const u8) void {
    _ = u.text(r.x + (r.w - u.textW(msg)) / 2, r.y + r.h / 2 - 10, kit.pal.faint, msg);
}

fn tree(u: *kit.Ui, f: *const cap.Frame, r: kit.Rect) void {
    build(f);
    var reveal: ?usize = null;
    if (ui.sel.reveal) {
        ui.sel.reveal = false;
        reveal = revealRow(f);
    }
    const parent = u.dl;
    const rh: f32 = 19;
    const l = kit.beginList(u, "##el-tree", r, rows.items.len, rh, false, reveal);
    for (rows.items[l.first..l.last], l.first..) |row, k| {
        const y = l.y0 + @as(f32, @floatFromInt(k - l.first)) * rh;
        const rr: kit.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = rh };
        qa.mark(rr, "insp-tree:{d}", .{k});
        const selected = switch (row.kind) {
            .scope => ui.sel.on and ui.sel.scope_only and ui.sel.scope_index == row.index,
            .el => ui.sel.on and !ui.sel.scope_only and ui.sel.index == row.index,
            .outside => false,
        };
        const over = u.over(rr);
        if (selected) kit.rect(u, rr, kit.pal.sel, 0) else if (over) kit.rect(u, rr, kit.pal.hover, 0);
        if (over) switch (row.kind) {
            .scope => ui.hover_scope = row.index,
            .el => ui.hover_el = row.index,
            .outside => {},
        };
        const x0 = r.x + 6 + @as(f32, @floatFromInt(row.depth)) * 13;
        const chev: kit.Rect = .{ .x = x0, .y = y, .w = 13, .h = rh };
        if (row.has_kids) kit.icon(u.dl, if (row.open) .chevron_d else .chevron_r, x0 + 6, y + rh / 2, kit.pal.dim);
        var run: kit.Run = .{ .u = u, .x = x0 + 15, .y = u.midCode(y, rh), .max_x = r.right() - 4 };
        switch (row.kind) {
            .scope => scopeRow(&run, f, row.index, by_scope.items[row.index].items.len),
            .el => elRow(&run, f, row.index),
            .outside => run.put(kit.pal.faint, i18n.tr("(fora do layout)", "(outside the layout)")),
        }
        if (over and c.ImGui_IsMouseClicked(0)) {
            if (row.has_kids and (chev.contains(u.ctx.mouse.x, u.ctx.mouse.y) or c.ImGui_IsMouseDoubleClicked(0))) {
                open_keys.put(gpa, row.key, !row.open) catch {};
            } else switch (row.kind) {
                .scope => ui.selectScope(f, row.index),
                .el => {
                    ui.select(f, row.index);
                    ui.sel.reveal = false;
                },
                .outside => open_keys.put(gpa, row.key, !row.open) catch {},
            }
        }
    }
    kit.endList(u, l, rows.items.len, rh, parent);
}

/// Busca: lista plana do que bate, com o pedaço do layout de cada um.
fn searchList(u: *kit.Ui, f: *const cap.Frame, r: kit.Rect) void {
    const q = kit.bufStr(&filter);
    var hits: std.ArrayList(usize) = .empty;
    defer hits.deinit(gpa);
    for (f.els.items, 0..) |*e, i| {
        if (!cap.visible(e)) continue;
        var db: [200]u8 = undefined;
        const desc = describe(f, i, &db);
        const s = f.str(e.str);
        var hx: [12]u8 = undefined;
        const hex = if (e.kind == .text or e.kind == .fill or e.kind == .border) kit.hexOf(&hx, e.color) else "";
        const mk = f.markFor(e.rect) orelse "";
        const sc = if (f.scopeOf(e)) |x| x.name else "";
        if (kit.has(s, q) or kit.has(desc, q) or kit.has(hex, q) or kit.has(mk, q) or kit.has(sc, q)) hits.append(gpa, i) catch break;
        if (hits.items.len >= 5000) break;
    }
    const parent = u.dl;
    const rh: f32 = 19;
    const l = kit.beginList(u, "##el-search", r, hits.items.len, rh, false, null);
    for (hits.items[l.first..l.last], l.first..) |i, k| {
        const y = l.y0 + @as(f32, @floatFromInt(k - l.first)) * rh;
        const rr: kit.Rect = .{ .x = r.x, .y = y, .w = r.w, .h = rh };
        const selected = ui.sel.on and !ui.sel.scope_only and ui.sel.index == i;
        const over = u.over(rr);
        if (selected) kit.rect(u, rr, kit.pal.sel, 0) else if (over) kit.rect(u, rr, kit.pal.hover, 0);
        if (over) ui.hover_el = i;
        var run: kit.Run = .{ .u = u, .x = r.x + 8, .y = u.midCode(y, rh), .max_x = r.right() - 4 };
        if (f.scopeOf(&f.els.items[i])) |s| {
            run.put(kit.pal.hl_scope, s.name);
            run.put(kit.pal.faint, " › ");
        }
        elRow(&run, f, i);
        if (over and c.ImGui_IsMouseClicked(0)) ui.select(f, i);
    }
    if (hits.items.len == 0) empty(u, r, i18n.tr("Nada neste quadro com esse texto.", "Nothing in this frame matches."));
    kit.endList(u, l, hits.items.len, rh, parent);
}

fn scopeRow(run: *kit.Run, f: *const cap.Frame, si: usize, n_els: usize) void {
    const s = &f.scopes.items[si];
    run.put(kit.pal.tag, "<");
    run.put(kit.pal.tag, s.name);
    // Até três propriedades do nó (gap=8 padding=12…), se o tema ainda é o mesmo.
    if (nodeOf(f, s)) |n| {
        var shown: usize = 0;
        for (n.props) |p| {
            if (shown == 3) break;
            run.put(kit.pal.attr, " ");
            run.put(kit.pal.attr, p.key);
            run.put(kit.pal.dim, "=");
            var vb: [64]u8 = undefined;
            run.put(kit.pal.value, valueText(&vb, p.value));
            shown += 1;
        }
    }
    run.put(kit.pal.tag, ">");
    if (s.line > 0) run.print(kit.pal.faint, "  :{d}", .{s.line});
    run.print(kit.pal.faint, "  {d:.0}×{d:.0}", .{ s.rect.w, s.rect.h });
    if (n_els > 0) run.print(kit.pal.faint, "  ({d})", .{n_els});
    if (s.us > 0) run.print(kit.pal.faint, "  {d} µs", .{s.us});
}

fn valueText(buf: []u8, v: kdl.Value) []const u8 {
    return switch (v) {
        .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s[0..@min(s.len, 40)]}) catch "",
        .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch "",
        .boolean => |b| if (b) "#true" else "#false",
        .null => "null",
    };
}

/// O nó do tema de um pedaço, só se o tema ainda é o daquele quadro (recarregar solta os nós).
fn nodeOf(f: *const cap.Frame, s: *const cap.Scope) ?*const kdl.Node {
    const app = ui.app_ptr orelse return null;
    if (app.st.theme_gen != f.theme_gen) return null;
    return s.node;
}

fn elRow(run: *kit.Run, f: *const cap.Frame, i: usize) void {
    const e = &f.els.items[i];
    const th = (ui.app_ptr orelse return).themes.theme_();
    switch (e.kind) {
        .text => {
            run.put(kit.pal.tag, "<text");
            attrNum(run, "size", e.size);
            attrColor(run, th, "color", e.color);
            run.put(kit.pal.tag, ">");
            run.put(kit.pal.text, f.str(e.str));
        },
        .image => {
            run.put(kit.pal.tag, "<img");
            run.put(kit.pal.attr, " src");
            run.put(kit.pal.dim, "=");
            run.put(kit.pal.value, shortUrl(f.str(e.str)));
            if (e.tex_w > 0) run.print(kit.pal.faint, " {d}×{d}", .{ e.tex_w, e.tex_h });
            run.put(kit.pal.tag, ">");
        },
        .fill, .border => {
            run.put(kit.pal.tag, if (e.kind == .fill) "<box" else "<border");
            attrColor(run, th, if (e.kind == .fill) "bg" else "color", e.color);
            if (e.size > 0) attrNum(run, "radius", e.size);
            run.put(kit.pal.tag, ">");
        },
        .item => {
            const is_hit = e.hit != null;
            run.put(kit.pal.tag, if (is_hit) "<button" else if (e.status & statusInputable != 0) "<input" else "<item");
            if (f.markFor(e.rect)) |m| {
                run.put(kit.pal.attr, " qa");
                run.put(kit.pal.dim, "=");
                run.put(kit.pal.value, m);
            } else if (!is_hit and f.str(e.str).len > 0) {
                run.put(kit.pal.attr, " label");
                run.put(kit.pal.dim, "=");
                run.put(kit.pal.value, f.str(e.str));
            }
            if (e.hit) |h| if (h.hovered) run.put(kit.pal.ok, " :hover");
            if (f.active_id == e.id and e.id != 0) run.put(kit.pal.warn, " :active");
            run.put(kit.pal.tag, ">");
            var tb: [120]u8 = undefined;
            const inside = cap.textsIn(f, e.rect, e.layer, &tb);
            if (inside.len > 0) run.put(kit.pal.dim, inside);
        },
        .window => {
            run.put(kit.pal.tag, "<window ");
            run.put(kit.pal.value, f.str(e.str));
            run.put(kit.pal.tag, ">");
        },
    }
}

fn attrNum(run: *kit.Run, key: []const u8, v: f32) void {
    run.put(kit.pal.attr, " ");
    run.put(kit.pal.attr, key);
    run.put(kit.pal.dim, "=");
    run.print(kit.pal.num, "{d:.0}", .{v});
}

fn attrColor(run: *kit.Run, th: *const theme_mod.Theme, key: []const u8, color: u32) void {
    run.put(kit.pal.attr, " ");
    run.put(kit.pal.attr, key);
    run.put(kit.pal.dim, "=");
    const tok = tokenName(th, color);
    if (tok.len > 0) {
        run.put(kit.pal.value, tok);
    } else {
        var hx: [12]u8 = undefined;
        run.put(kit.pal.value, kit.hexOf(&hx, color));
    }
}

fn shortUrl(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfScalar(u8, s, '?')) |q| s = s[0..q];
    if (s.len > 48) s = s[s.len - 48 ..];
    return s;
}

// --- O que os outros usam ------------------------------------------------------------

const statusInputable: u32 = 1 << 24;

/// Uma linha curta do elemento (o cartão da tela e o ctl).
pub fn describe(f: *const cap.Frame, i: usize, buf: []u8) []const u8 {
    const e = &f.els.items[i];
    const sc = if (f.scopeOf(e)) |s| s.name else "";
    const s = f.str(e.str);
    return switch (e.kind) {
        .text => std.fmt.bufPrint(buf, "text.{s} \"{s}\"", .{ sc, d.utf8Prefix(s, 60) }) catch "text",
        .image => std.fmt.bufPrint(buf, "img.{s} {s}", .{ sc, shortUrl(s) }) catch "img",
        .fill => std.fmt.bufPrint(buf, "box.{s}", .{sc}) catch "box",
        .border => std.fmt.bufPrint(buf, "border.{s}", .{sc}) catch "border",
        .window => std.fmt.bufPrint(buf, "window {s}", .{s}) catch "window",
        .item => blk: {
            var tb: [80]u8 = undefined;
            const inside = cap.textsIn(f, e.rect, e.layer, &tb);
            if (f.markFor(e.rect)) |m| break :blk std.fmt.bufPrint(buf, "button.{s} \"{s}\" [{s}]", .{ sc, d.utf8Prefix(inside, 50), m }) catch "button";
            if (e.hit != null) break :blk std.fmt.bufPrint(buf, "button.{s} {s}", .{ sc, inside }) catch "button";
            break :blk std.fmt.bufPrint(buf, "item.{s} {s}", .{ sc, if (s.len > 0) s else inside }) catch "item";
        },
    };
}

/// O fundo embaixo de um elemento: o último retângulo opaco desenhado antes dele que o
/// cobre, ou, sem nenhum, o fundo da janela (a cor `bg` do tema, que o renderizador pinta).
pub fn fundo(f: *const cap.Frame, i: usize) u32 {
    if (cap.backgroundOf(f, i)) |bg| return bg;
    const app = ui.app_ptr orelse return 0xFF000000;
    return app.themes.theme_().c(.bg).col(1);
}

/// O nome da cor no tema (`accent`, `muted`…), com a transparência quando difere.
pub fn tokenName(th: *const theme_mod.Theme, color: u32) []const u8 {
    const S = struct {
        var buf: [40]u8 = undefined;
    };
    const rgb = color & 0x00FFFFFF;
    const a = color >> 24;
    var near: []const u8 = "";
    var near_d: u32 = std.math.maxInt(u32);
    inline for (@typeInfo(theme_mod.Token).@"enum".field_names) |name| {
        const tc = th.c(@field(theme_mod.Token, name)).u();
        if (tc & 0x00FFFFFF == rgb) {
            const ta = tc >> 24;
            if (ta == a) return name;
            const pct = a * 100 / @max(ta, 1);
            return std.fmt.bufPrint(&S.buf, "{s} {d}%", .{ name, pct }) catch name;
        }
        const dd = rgbDist(tc, color);
        if (dd < near_d) {
            near_d = dd;
            near = name;
        }
    }
    // Não é cor do tema, mas é quase (uma mistura, um tom acima): o nome da mais perto.
    if (near_d <= 30) return std.fmt.bufPrint(&S.buf, "≈ {s}", .{near}) catch near;
    return "";
}

fn rgbDist(a: u32, b: u32) u32 {
    var s: u32 = 0;
    inline for (.{ 0, 8, 16 }) |sh| {
        const x: i32 = @intCast((a >> sh) & 0xff);
        const y: i32 = @intCast((b >> sh) & 0xff);
        s += @abs(x - y);
    }
    return s;
}

/// A família e o peso de uma fonte do ImGui ("Inter semibold").
pub fn fontName(ctx: *const d.Ctx, font: usize) []const u8 {
    const S = struct {
        var buf: [80]u8 = undefined;
    };
    const weights = [_][]const u8{ "regular", "medium", "semibold", "bold", "italic" };
    const fams = [_]*const d.Family{ ctx.ui, ctx.mono };
    for (fams) |fam| for (fam.faces, 0..) |face, w| if (@intFromPtr(face) == font) {
        return std.fmt.bufPrint(&S.buf, "{s} {s}", .{ fam.name, weights[w] }) catch fam.name;
    };
    for (ctx.fonts.families.items) |fam| for (fam.faces, 0..) |face, w| if (@intFromPtr(face) == font) {
        return std.fmt.bufPrint(&S.buf, "{s} {s}", .{ fam.name, weights[w] }) catch fam.name;
    };
    return "?";
}

/// O arquivo do tema atual: o caminho de um tema do usuário, ou o nome do embutido.
pub fn themeFile() []const u8 {
    const S = struct {
        var buf: [96]u8 = undefined;
    };
    const app = ui.app_ptr orelse return "";
    const m = &app.themes;
    if (m.current >= m.entries.items.len) return "";
    const e = m.entries.items[m.current];
    if (e.path) |p| return std.fs.path.basename(p);
    return std.fmt.bufPrint(&S.buf, "{s}.kdl", .{e.name}) catch e.name;
}

fn themePath() ?[:0]const u8 {
    const app = ui.app_ptr orelse return null;
    const m = &app.themes;
    if (m.current >= m.entries.items.len) return null;
    return m.entries.items[m.current].path;
}

// --- Detalhes ------------------------------------------------------------------------

fn details(u: *kit.Ui, f: *const cap.Frame, r: kit.Rect) void {
    kit.rect(u, r, kit.pal.panel, 0);
    if (!ui.sel.on) {
        empty(u, r, i18n.tr("Escolha um elemento na árvore ou na tela (Ctrl+Shift+E).", "Pick an element in the tree or on screen (Ctrl+Shift+E)."));
        return;
    }
    const parent = u.dl;
    var y = kit.beginPane(u, "##el-det", r);
    const x = r.x;
    const w = r.w - 10;
    if (ui.sel.scope_only) {
        if (ui.sel.scope_index) |si| scopeDetails(u, f, si, x, &y, w) else gone(u, x, &y, w);
        kit.endPane(u, r, y, parent);
        return;
    }
    const i = ui.sel.index orelse {
        gone(u, x, &y, w);
        kit.endPane(u, r, y, parent);
        return;
    };
    const e = &f.els.items[i];
    const app = ui.app_ptr.?;
    const th = app.themes.theme_();
    // Cabeça: o que é e o tamanho.
    {
        var run: kit.Run = .{ .u = u, .x = x + 10, .y = y + 6, .max_x = x + w };
        elRow(&run, f, i);
        y += 26;
        var pb: [96]u8 = undefined;
        const vis = cap.overlap(e.rect, e.clip);
        const pos = std.fmt.bufPrint(&pb, "x {d:.0}  y {d:.0}  ·  {d:.0} × {d:.0}{s}", .{ e.rect.x, e.rect.y, e.rect.w, e.rect.h, if (vis.w * vis.h < e.rect.w * e.rect.h - 1) i18n.tr("  ·  parte recortada", "  ·  partly clipped") else "" }) catch "";
        _ = u.clipCode(x + 10, y, kit.pal.dim, pos, w - 10);
        y += 22;
        // Ações.
        var bx = x + 10;
        const by = y;
        const sel_parent = kit.button(u, bx, by, 22, i18n.tr("Pai", "Parent"), .up);
        bx += sel_parent.w + 6;
        if (sel_parent.clicked) {
            var anc: [32]usize = undefined;
            const a = cap.ancestors(f, i, &anc);
            if (a.len > 0) ui.select(f, a[0]) else if (e.scope > 0) ui.selectScope(f, e.scope);
        }
        if (e.kind == .item) {
            const click = kit.button(u, bx, by, 22, i18n.tr("Clicar", "Click"), .pick);
            bx += click.w + 6;
            if (click.clicked) @import("comandos.zig").clickAt(e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2, .left);
        }
        const copy = kit.button(u, bx, by, 22, i18n.tr("Copiar JSON", "Copy JSON"), .copy);
        if (copy.clicked) {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            @import("comandos.zig").elementJson(&out.writer, f, i);
            kit.copyLong(out.written());
        }
        y += 30;
    }
    // Tema: o pedaço do layout e de onde vem.
    if (f.scopeOf(e)) |s| {
        if (kit.section(u, x, &y, w + 10, i18n.tr("Tema", "Theme"), &sec_theme)) {
            const si = e.scope;
            themeRows(u, f, si, s, x, &y, w);
            // O nome para o bloco `parts` do tema (themes/README.md, "Parts and states").
            if (f.partFor(e.rect)) |pn| kit.kv(u, x, &y, w, i18n.tr("Parte do tema", "Theme part"), pn, kit.pal.value);
        }
    }
    // Visual: cores, letra, contraste.
    if (kit.section(u, x, &y, w + 10, i18n.tr("Visual", "Visual"), &sec_visual)) {
        switch (e.kind) {
            .text, .fill, .border => {
                colorRow(u, th, x, &y, w, if (e.kind == .fill) i18n.tr("Fundo", "Background") else i18n.tr("Cor", "Color"), e.color);
                if (e.kind == .text) {
                    kit.kv(u, x, &y, w, i18n.tr("Fonte", "Font"), fontName(u.ctx, e.font), kit.pal.text);
                    var sb: [24]u8 = undefined;
                    kit.kv(u, x, &y, w, i18n.tr("Tamanho", "Size"), std.fmt.bufPrint(&sb, "{d:.0} px", .{e.size}) catch "", kit.pal.num);
                    const bg = fundo(f, i);
                    colorRow(u, th, x, &y, w, i18n.tr("Fundo embaixo", "Background below"), bg);
                    contrastRow(u, x, &y, w, kit.fromU32(e.color).contrast(kit.fromU32(bg)), e.size);
                    kit.kv(u, x, &y, w, i18n.tr("Texto", "Text"), f.str(e.str), kit.pal.str);
                } else if (e.size > 0) {
                    var rb: [24]u8 = undefined;
                    kit.kv(u, x, &y, w, i18n.tr("Cantos", "Corners"), std.fmt.bufPrint(&rb, "{d:.1} px", .{e.size}) catch "", kit.pal.num);
                }
            },
            .image => {
                kit.kv(u, x, &y, w, "URL", f.str(e.str), kit.pal.str);
                var tb: [32]u8 = undefined;
                kit.kv(u, x, &y, w, i18n.tr("Textura", "Texture"), if (e.tex_w > 0) std.fmt.bufPrint(&tb, "{d} × {d}", .{ e.tex_w, e.tex_h }) catch "" else i18n.tr("carregando", "loading"), kit.pal.num);
            },
            .item, .window => {
                colorRow(u, th, x, &y, w, i18n.tr("Fundo embaixo", "Background below"), fundo(f, i));
            },
        }
        kit.kv(u, x, &y, w, i18n.tr("Camada", "Layer"), layerText(f, e.layer), kit.pal.dim);
        y += 6;
    }
    // Interação: o item do ImGui.
    if (e.kind == .item or e.kind == .window) {
        if (kit.section(u, x, &y, w + 10, i18n.tr("Interação", "Interaction"), &sec_item)) {
            var ib: [24]u8 = undefined;
            kit.kv(u, x, &y, w, "ID", std.fmt.bufPrint(&ib, "0x{X:0>8}", .{e.id}) catch "", kit.pal.num);
            if (f.str(e.str).len > 0) kit.kv(u, x, &y, w, i18n.tr("Rótulo", "Label"), f.str(e.str), kit.pal.str);
            if (f.markFor(e.rect)) |m| kit.kv(u, x, &y, w, i18n.tr("Marca do QA", "QA mark"), m, kit.pal.value);
            if (e.hit) |h| {
                var hb: [64]u8 = undefined;
                kit.kv(u, x, &y, w, i18n.tr("Área clicável", "Hit area"), std.fmt.bufPrint(&hb, "id {d}{s}{s}{s}", .{ h.local, if (h.hovered) " · hover" else "", if (h.held) " · held" else "", if (h.clicked) " · clicked" else "" }) catch "", kit.pal.text);
            }
            var fb: [160]u8 = undefined;
            kit.kv(u, x, &y, w, i18n.tr("Estado", "Status"), statusText(&fb, e.status, e.id == f.active_id, e.id == f.hovered_id), kit.pal.text);
            y += 6;
        }
        var tb: [400]u8 = undefined;
        const inside = cap.textsIn(f, e.rect, e.layer, &tb);
        if (inside.len > 0) if (kit.section(u, x, &y, w + 10, i18n.tr("Texto dentro", "Text inside"), &sec_inside)) {
            y = wrapped(u, x + 12, y, w - 12, inside, kit.pal.text) + 8;
        };
    }
    // Linhagem: os que contêm este, do mais justo ao mais largo.
    if (kit.section(u, x, &y, w + 10, i18n.tr("Dentro de", "Inside"), &sec_path)) {
        var anc: [24]usize = undefined;
        for (cap.ancestors(f, i, &anc)) |a| {
            const rr: kit.Rect = .{ .x = x, .y = y, .w = w + 10, .h = 19 };
            const over = u.over(rr);
            if (over) {
                kit.rect(u, rr, kit.pal.hover, 0);
                ui.hover_el = a;
                if (c.ImGui_IsMouseClicked(0)) ui.select(f, a);
            }
            var run: kit.Run = .{ .u = u, .x = x + 12, .y = u.midCode(y, 19), .max_x = x + w };
            elRow(&run, f, a);
            y += 19;
        }
        if (f.scopeOf(e)) |s| {
            const rr: kit.Rect = .{ .x = x, .y = y, .w = w + 10, .h = 19 };
            const over = u.over(rr);
            if (over) {
                kit.rect(u, rr, kit.pal.hover, 0);
                ui.hover_scope = e.scope;
                if (c.ImGui_IsMouseClicked(0)) ui.selectScope(f, e.scope);
            }
            var run: kit.Run = .{ .u = u, .x = x + 12, .y = u.midCode(y, 19), .max_x = x + w };
            scopeRow(&run, f, e.scope, 0);
            _ = s;
            y += 19;
        }
    }
    kit.endPane(u, r, y, parent);
}

fn gone(u: *kit.Ui, x: f32, y: *f32, w: f32) void {
    _ = w;
    _ = u.text(x + 12, y.* + 10, kit.pal.faint, i18n.tr("Não está na tela neste quadro.", "Not on screen in this frame."));
    y.* += 34;
}

fn layerText(f: *const cap.Frame, layer: u16) []const u8 {
    const S = struct {
        var buf: [96]u8 = undefined;
    };
    const name = f.layerName(layer);
    return std.fmt.bufPrint(&S.buf, "{d} {s}", .{ layer, if (name.len > 0) name else "-" }) catch "";
}

fn scopeDetails(u: *kit.Ui, f: *const cap.Frame, si: usize, x: f32, y: *f32, w: f32) void {
    const s = &f.scopes.items[si];
    var run: kit.Run = .{ .u = u, .x = x + 10, .y = y.* + 6, .max_x = x + w };
    scopeRow(&run, f, si, by_scope.items[si].items.len);
    y.* += 30;
    if (kit.section(u, x, y, w + 10, i18n.tr("Tema", "Theme"), &sec_theme)) themeRows(u, f, si, s, x, y, w);
}

fn themeRows(u: *kit.Ui, f: *const cap.Frame, si: usize, s: *const cap.Scope, x: f32, y: *f32, w: f32) void {
    _ = si;
    kit.kv(u, x, y, w, i18n.tr("Pedaço", "Piece"), s.name, kit.pal.tag);
    if (s.line > 0) {
        var lb: [160]u8 = undefined;
        kit.kv(u, x, y, w, i18n.tr("Arquivo", "File"), std.fmt.bufPrint(&lb, "{s}:{d}:{d}", .{ themeFile(), s.line, s.col }) catch "", kit.pal.hl_scope);
    } else kit.kv(u, x, y, w, i18n.tr("Origem", "Origin"), i18n.tr("sobreposição do app (não vem do tema)", "app overlay (not from the theme)"), kit.pal.dim);
    var sb: [64]u8 = undefined;
    kit.kv(u, x, y, w, i18n.tr("Retângulo", "Rect"), std.fmt.bufPrint(&sb, "{d:.0}, {d:.0}  {d:.0} × {d:.0}", .{ s.rect.x, s.rect.y, s.rect.w, s.rect.h }) catch "", kit.pal.num);
    if (s.us > 0) {
        var ub: [32]u8 = undefined;
        kit.kv(u, x, y, w, i18n.tr("Custo neste quadro", "Cost this frame"), std.fmt.bufPrint(&ub, "{d} µs", .{s.us}) catch "", kit.pal.num);
    }
    if (nodeOf(f, s)) |n| {
        for (n.props) |p| {
            var vb: [96]u8 = undefined;
            const v = valueText(&vb, p.value);
            // Uma propriedade que é cor do tema mostra a cor ao lado.
            const tok = if (p.value.asString()) |str| theme_mod.tokenFromName(str) else null;
            if (tok) |tk| {
                const th = ui.app_ptr.?.themes.theme_();
                kit.swatch(u, .{ .x = x + w - 16, .y = y.* + 4, .w = 11, .h = 11 }, th.c(tk));
            }
            kit.kv(u, x, y, w - 18, p.key, v, kit.pal.value);
        }
    }
    if (themePath()) |p| {
        y.* += 4;
        const b = kit.button(u, x + 12, y.*, 22, i18n.tr("Abrir o arquivo do tema", "Open the theme file"), .download);
        if (b.clicked) {
            var ub: [700]u8 = undefined;
            const url = std.fmt.bufPrintSentinel(&ub, "file://{s}{s}", .{ if (p.len > 0 and p[0] != '/') "/" else "", p }, 0) catch return;
            _ = c.SDL_OpenURL(url.ptr);
        }
        y.* += 28;
    } else if (s.line > 0) {
        _ = u.clip(x + 12, y.* + 2, kit.pal.faint, i18n.tr("Tema embutido: copie para a pasta de temas para editar.", "Built-in theme: copy it to the themes folder to edit it."), w - 12);
        y.* += 20;
    }
    y.* += 4;
}

fn colorRow(u: *kit.Ui, th: *const theme_mod.Theme, x: f32, y: *f32, w: f32, label: []const u8, color: u32) void {
    var hx: [12]u8 = undefined;
    var vb: [64]u8 = undefined;
    const tok = tokenName(th, color);
    const v = if (tok.len > 0) std.fmt.bufPrint(&vb, "{s}  {s}", .{ kit.hexOf(&hx, color), tok }) catch "" else kit.hexOf(&hx, color);
    const kw: f32 = @min(150, w * 0.38);
    kit.swatch(u, .{ .x = x + kw - 16, .y = y.* + 4, .w = 11, .h = 11 }, kit.fromU32(color));
    kit.kv(u, x, y, w, label, v, kit.pal.value);
}

fn contrastRow(u: *kit.Ui, x: f32, y: *f32, w: f32, ratio: f32, size: f32) void {
    // Texto grande (18 px ou mais) passa com 3:1 na WCAG.
    const need: f32 = if (size >= 18) 3 else 4.5;
    var b: [64]u8 = undefined;
    const verdict = if (ratio >= need + 2.5) "AAA" else if (ratio >= need) "AA" else i18n.tr("abaixo do AA", "below AA");
    const s = std.fmt.bufPrint(&b, "{d:.2} : 1   {s}", .{ ratio, verdict }) catch "";
    kit.kv(u, x, y, w, i18n.tr("Contraste", "Contrast"), s, if (ratio >= need) kit.pal.ok else kit.pal.err);
}

fn statusText(buf: []u8, status: u32, active: bool, hovered: bool) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    const names = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = 1 << 0, .name = "hovered-rect" },
        .{ .bit = 1 << 2, .name = "edited" },
        .{ .bit = 1 << 3, .name = "toggled-selection" },
        .{ .bit = 1 << 4, .name = "toggled-open" },
        .{ .bit = 1 << 8, .name = "visible" },
        .{ .bit = 1 << 20, .name = "openable" },
        .{ .bit = 1 << 21, .name = "opened" },
        .{ .bit = 1 << 22, .name = "checkable" },
        .{ .bit = 1 << 23, .name = "checked" },
        .{ .bit = 1 << 24, .name = "inputable" },
    };
    if (active) w.writeAll("active ") catch {};
    if (hovered) w.writeAll("hovered ") catch {};
    for (names) |n| if (status & n.bit != 0) {
        w.writeAll(n.name) catch break;
        w.writeByte(' ') catch break;
    };
    const out = w.buffered();
    return if (out.len == 0) "-" else out;
}

/// Texto quebrado em linhas na largura; devolve o y depois dele.
fn wrapped(u: *kit.Ui, x: f32, y0: f32, w: f32, s: []const u8, col: kit.Rgba) f32 {
    var y = y0;
    var rest = s;
    var n: usize = 0;
    while (rest.len > 0 and n < 40) : (n += 1) {
        const k = @max(1, d.fitBytes(u.font, u.fs, rest, w));
        _ = u.text(x, y, col, rest[0..k]);
        rest = rest[k..];
        y += u.fs * 1.4;
    }
    return y;
}

const t = std.testing;

test "texto do estado do item" {
    var b: [160]u8 = undefined;
    try t.expectEqualStrings("active visible checkable checked ", statusText(&b, (1 << 8) | (1 << 22) | (1 << 23), true, false));
    try t.expectEqualStrings("-", statusText(&b, 0, false, false));
}

test "endereço curto de imagem" {
    try t.expectEqualStrings("cdn.discordapp.com/avatars/1/a.png", shortUrl("https://cdn.discordapp.com/avatars/1/a.png?size=64"));
}
