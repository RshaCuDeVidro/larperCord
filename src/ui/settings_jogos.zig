//! Configurações → Privacidade → "Mostrar o jogo aberto": a opção e a lista de
//! jogos (core/jogos.zig), com os dois jeitos de acrescentar um: escolher entre
//! os processos abertos agora (platform/processos.zig) ou o arquivo do
//! executável. Quem olha os processos de tempos em tempos é app_presenca.zig.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const dropdown = @import("dropdown.zig");
const jogos = @import("../core/jogos.zig");
const processos = @import("../platform/processos.zig");
const sys = @import("../platform/sys.zig");

const gpa = std.heap.c_allocator;
const picker_key: usize = 0x9600;

/// Os processos abertos quando a lista abriu, e os que dá para escolher (sem os
/// do sistema, sem repetir). Soltos quando ela fecha.
var scanned: processos.List = .{};
var choices: std.ArrayList(jogos.Proc) = .empty;
var filter_buf: [128]u8 = @splat(0);
var focus_filter = false;
/// Esperando o arquivo do seletor do sistema.
var picking = false;
/// O seletor fechou sem arquivo (o aviso vem da thread do diálogo).
var pick_cancelled = std.atomic.Value(bool).init(false);

pub fn section(p: anytype) void {
    // A demonstração no navegador não tem processos para olhar.
    if (sys.web) return;
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    p.toggle(i18n.tr("Mostrar o jogo aberto", "Show the game you're running"), i18n.tr(
        "Quando um jogo da lista está aberto, o seu status mostra \"Jogando …\" com o tempo de jogo, como no Discord do computador. Serve para jogos sem Rich Presence. Desligado, nada olha os seus processos.",
        "When a game from the list is running, your status shows \"Playing …\" with the time played, like the Discord desktop app. Works for games without Rich Presence. Off: nothing looks at your processes.",
    ), &s.show_game);
    if (!s.show_game) {
        release();
        return;
    }
    p.heading(i18n.tr("Jogos", "Games"));
    p.note(i18n.tr("Só os jogos desta lista aparecem; o resto do que está aberto não sai do computador. Com vários abertos, vale o primeiro da lista.", "Only games on this list show up; nothing else you have open leaves your computer. With several running, the first on the list wins."));
    const list = &ctx.st.jogos;
    var remove: ?usize = null;
    for (list.slice(), 0..) |*e, i| row(p, e, i, &remove);
    if (remove) |i| list.remove(i);

    const add_label = i18n.tr("Adicionar processo aberto", "Add running process");
    const anchor: d.Rect = .{ .x = p.x, .y = p.y, .w = d.width(p.font(.semibold), 14, add_label) + 32, .h = 36 };
    if (p.buttonSoft(add_label)) openPicker();
    p.sameLine();
    if (p.buttonSoft(i18n.tr("Escolher executável", "Choose executable"))) {
        picking = true;
        pick_cancelled.store(false, .release);
        ctx.act(.pick_game_exe);
    }
    // Um respiro antes da próxima opção da página.
    p.y += 10;
    picker(p, anchor);
}

/// Uma linha da lista: o nome (dá para mudar), ligado ou não, tirar, e embaixo o
/// arquivo e a opção "só este arquivo".
fn row(p: anytype, e: *jogos.Entry, i: usize, remove: *?usize) void {
    const ctx = p.ctx;
    const list = &ctx.st.jogos;
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 70 };
    d.rect(p.dl, r, ctx.col(.rail).alpha(0.5), ctx.th.radius);
    const right_w: f32 = 92;

    // O nome que vai depois de "Jogando".
    const ir: d.Rect = .{ .x = r.x + 10, .y = r.y + 8, .w = r.w - 20 - right_w, .h = 30 };
    d.rect(p.dl, ir, ctx.col(.rail).mix(ctx.col(.elevated), 0.3), ctx.th.radius);
    d.border(p.dl, ir, ctx.col(.border), ctx.th.radius, 1);
    c.ImGui_PushFontFloat(p.font(.medium), 15);
    c.ImGui_SetCursorScreenPos(d.v(ir.x + 8, ir.y + 5));
    c.ImGui_SetNextItemWidth(ir.w - 16);
    c.ImGui_PushIDInt(@bitCast(e.id));
    if (c.ImGui_InputText("##jogo-nome", &e.name.buf, e.name.buf.len, 0)) list.changed();
    c.ImGui_PopID();
    c.ImGui_PopFont();
    qa.mark(ir, "jogo-nome:{d}", .{i});

    // Ligado ou não (fica na lista, só não vale).
    const sw: d.Rect = .{ .x = r.right() - right_w + 6, .y = r.y + 11, .w = 40, .h = 24 };
    const hs = d.hit(ctx, p.id(), sw);
    qa.mark(sw, "jogo-ligado:{d}", .{i});
    if (hs.clicked) {
        e.on = !e.on;
        list.changed();
    }
    const k = anim.to(anim.id("jogo-sw", e.id), if (e.on) 1 else 0, 22);
    d.rect(p.dl, sw, ctx.col(.faint).mix(ctx.col(.accent), k), 12);
    d.circle(p.dl, sw.x + 12 + k * 16, sw.y + 12, 9, d.Rgba.white);
    d.tip(ctx, sw, if (e.on) i18n.tr("Ligado: aparece quando estiver aberto", "On: shows up while it's running") else i18n.tr("Desligado: fica na lista sem aparecer", "Off: stays on the list without showing up"), hs.hovered);

    // Tirar da lista.
    const xr: d.Rect = .{ .x = r.right() - 36, .y = r.y + 11, .w = 24, .h = 24 };
    const hx = d.hit(ctx, p.id(), xr);
    qa.mark(xr, "jogo-tirar:{d}", .{i});
    const xc = if (hx.hovered) ctx.col(.text) else ctx.col(.muted);
    if (hx.hovered) d.circle(p.dl, xr.x + 12, xr.y + 12, 11, ctx.col(.hover));
    d.line(p.dl, xr.x + 7, xr.y + 7, xr.x + 17, xr.y + 17, xc, 1.6);
    d.line(p.dl, xr.x + 17, xr.y + 7, xr.x + 7, xr.y + 17, xc, 1.6);
    d.tip(ctx, xr, i18n.tr("Tirar da lista", "Remove"), hx.hovered);
    if (hx.clicked) remove.* = i;

    // Embaixo: o arquivo (com o caminho, se sabe) e "só este arquivo".
    const iy = r.y + 46;
    var exact_w: f32 = 0;
    if (e.path.len() > 0) {
        const label = i18n.tr("Só este arquivo", "Only this file");
        exact_w = d.width(p.font(.medium), 12.5, label) + 30;
        const er: d.Rect = .{ .x = r.right() - exact_w - 10, .y = iy - 3, .w = exact_w, .h = 20 };
        const he = d.hit(ctx, p.id(), er);
        qa.mark(er, "jogo-exato:{d}", .{i});
        if (he.clicked) {
            e.exact = !e.exact;
            list.changed();
        }
        const box: d.Rect = .{ .x = er.x, .y = er.y + 3, .w = 14, .h = 14 };
        if (e.exact) d.rect(p.dl, box, ctx.col(.accent), 3) else d.border(p.dl, box, if (he.hovered) ctx.col(.text) else ctx.col(.muted), 3, 1.4);
        if (e.exact) {
            d.line(p.dl, box.x + 3, box.y + 7, box.x + 6, box.y + 10, ctx.col(.accent_text), 1.8);
            d.line(p.dl, box.x + 6, box.y + 10, box.x + 11, box.y + 4, ctx.col(.accent_text), 1.8);
        }
        d.text(p.dl, p.font(.medium), 12.5, box.right() + 8, er.y + 3, if (he.hovered or e.exact) ctx.col(.text) else ctx.col(.muted), label);
        d.tip(ctx, er, i18n.tr("Vale só o executável deste caminho, não outro com o mesmo nome", "Only the executable at this path counts, not another with the same name"), he.hovered);
    }
    const where = if (e.path.len() > 0) e.path.slice() else e.exe.slice();
    const max_w = r.w - 20 - exact_w - (if (exact_w > 0) @as(f32, 12) else 0);
    const tw = d.textClipped(p.dl, p.font(.regular), 12.5, r.x + 12, iy, ctx.col(.faint), where, max_w);
    p.markText(.{ .x = r.x + 12, .y = iy, .w = @max(tw, 1), .h = 16 });
    p.y += r.h + 8;
}

fn openPicker() void {
    if (dropdown.isOpen(picker_key)) return dropdown.close();
    processos.scan(&scanned, gpa, .all);
    jogos.pickable(gpa, scanned.items(), jogos.native, &choices) catch choices.clearRetainingCapacity();
    filter_buf = @splat(0);
    focus_filter = true;
    dropdown.toggle(picker_key);
}

fn release() void {
    if (dropdown.isOpen(picker_key)) dropdown.close();
    if (choices.capacity == 0 and scanned.text.capacity == 0) return;
    choices.deinit(gpa);
    choices = .empty;
    scanned.deinit(gpa);
}

/// A lista dos processos abertos, com a caixa de filtro em cima: clicar num
/// acrescenta o jogo e fecha.
fn picker(p: anytype, anchor: d.Rect) void {
    const ctx = p.ctx;
    if (!dropdown.isOpen(picker_key)) {
        release();
        return;
    }
    const filter = std.mem.sliceTo(&filter_buf, 0);
    var shown: usize = 0;
    for (choices.items) |pr| {
        if (jogos.filterMatch(pr, filter)) shown += 1;
    }
    const row_h: f32 = 46;
    const head_h: f32 = 46;
    const content_h = head_h + @as(f32, @floatFromInt(@max(shown, 1))) * row_h;
    var dd = dropdown.begin(ctx, picker_key, anchor, @min(p.w, 560), content_h) orelse return;
    defer dd.end();

    const fr: d.Rect = .{ .x = dd.x + 4, .y = dd.y + 4, .w = dd.w - 8, .h = 34 };
    d.rect(dd.dl, fr, ctx.col(.rail).mix(ctx.col(.elevated), 0.3), ctx.th.radius);
    d.border(dd.dl, fr, ctx.col(.border), ctx.th.radius, 1);
    c.ImGui_PushFontFloat(p.font(.regular), 14);
    c.ImGui_SetCursorScreenPos(d.v(fr.x + 8, fr.y + 8));
    c.ImGui_SetNextItemWidth(fr.w - 16);
    if (focus_filter) {
        focus_filter = false;
        c.ImGui_SetKeyboardFocusHere();
    }
    var hz: [96]u8 = undefined;
    const hint = std.fmt.bufPrintSentinel(&hz, "{s}", .{i18n.tr("Filtrar pelo nome ou pelo caminho", "Filter by name or path")}, 0) catch "";
    _ = c.ImGui_InputTextWithHint("##jogo-filtro", hint.ptr, &filter_buf, filter_buf.len, 0);
    c.ImGui_PopFont();
    qa.mark(fr, "jogo-filtro", .{});
    dd.y += head_h;

    if (shown == 0) {
        const msg = if (choices.items.len == 0) i18n.tr("Nenhum programa aberto além dos do sistema.", "No programs running besides the system's.") else i18n.tr("Nenhum processo aberto com esse nome.", "No running process matches that.");
        _ = d.textClipped(dd.dl, p.font(.regular), 13.5, dd.x + 8, dd.y + 14, ctx.col(.muted), msg, dd.w - 16);
        dd.y += row_h;
        return;
    }
    for (choices.items) |pr| {
        if (!jogos.filterMatch(pr, filter)) continue;
        const ro = dd.row(row_h, false);
        qa.mark(ro.rect, "jogo-proc:{s}", .{pr.name});
        _ = d.textClipped(dd.dl, p.font(.semibold), 14, ro.rect.x + 8, ro.rect.y + 6, ctx.col(.text), pr.name, ro.rect.w - 16);
        if (pr.path.len > 0) _ = d.textClipped(dd.dl, p.font(.regular), 12, ro.rect.x + 8, ro.rect.y + 25, ctx.col(.faint), pr.path, ro.rect.w - 16);
        if (ro.hit.clicked) {
            add(ctx.st, ctx.now_ms, pr.name, pr.path);
            dropdown.close();
        }
    }
}

fn add(st: anytype, now_ms: i64, exe: []const u8, path: []const u8) void {
    const list = &st.jogos;
    switch (list.add(exe, path, jogos.native)) {
        .added => st.showToast(now_ms, false, "{s} entrou na lista", "{s} added to the list", .{list.items[list.len - 1].name.slice()}),
        .exists => st.showToast(now_ms, false, "esse já está na lista", "that one is already on the list", .{}),
        .full => st.showToast(now_ms, true, "lista cheia ({d} no máximo)", "list is full ({d} at most)", .{jogos.max_games}),
        .empty => st.showToast(now_ms, true, "não deu para ler o nome desse arquivo", "couldn't read that file's name", .{}),
    }
}

/// O seletor do sistema devolveu um arquivo: é o executável esperado? true = era daqui.
pub fn takePicked(st: anytype, now_ms: i64, path: [:0]const u8) bool {
    if (!picking) return false;
    picking = false;
    add(st, now_ms, jogos.baseName(path), path);
    return true;
}

/// O seletor fechou sem arquivo (chamado da thread do diálogo).
pub fn cancelPick() void {
    pick_cancelled.store(true, .release);
}

/// A cada volta do laço: o seletor cancelado não deixa o próximo arquivo (um
/// anexo) virar jogo.
pub fn pollCancel() void {
    if (pick_cancelled.swap(false, .acq_rel)) picking = false;
}
