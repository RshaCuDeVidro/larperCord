//! Conjuntos de abas na tela (core/conjuntos.zig): o menu do botão direito na
//! barra de abas, a janela que pede o nome, a etiqueta do conjunto em uso antes
//! das abas e as entradas da paleta. Também lê e grava o arquivo
//! (~/.config/larpercord/tabsets-<conta>.json, com permissão 600). O que cada
//! escolha faz fica em app_conjuntos.zig.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const forum = @import("forum.zig");
const cj = @import("../core/conjuntos.zig");
const Id = @import("../core/types.zig").Id;
const fsutil = @import("../platform/fsutil.zig");

// --- Arquivo ---------------------------------------------------------------------

/// O QA só lê o arquivo quando a bateria dos conjuntos pede (as outras começam
/// sempre sem nenhum, para serem reprodutíveis).
pub var qa_read = false;

fn path(buf: []u8, owner: Id) ?[:0]const u8 {
    // O QA nunca mexe na configuração de verdade.
    if (qa.on()) return std.fmt.bufPrintSentinel(buf, "qa-out/tabsets-{d}.json", .{owner}, 0) catch null;
    var nbuf: [48]u8 = undefined;
    return fsutil.configPath(buf, std.fmt.bufPrint(&nbuf, "tabsets-{d}.json", .{owner}) catch return null);
}

/// Caminho do arquivo da conta (o QA confere o que foi gravado).
pub fn filePath(buf: []u8, owner: Id) ?[:0]const u8 {
    return path(buf, owner);
}

/// Troca para a lista da conta que entrou. `read_file` false: começa vazia.
pub fn load(list: *cj.List, gpa: std.mem.Allocator, owner: Id, read_file: bool) void {
    list.clear(gpa);
    list.owner = owner;
    if (!read_file or owner == 0) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, owner) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return;
    defer c.SDL_free(data);
    list.read(gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch |err| {
        std.log.warn("conjuntos de abas: não consegui ler {s} ({t})", .{ p, err });
        list.clear(gpa);
        fsutil.keepBroken(p);
    };
}

/// Grava a lista (num temporário e depois troca: uma queda no meio não estraga
/// o que já estava salvo).
pub fn persist(list: *cj.List, gpa: std.mem.Allocator) void {
    list.dirty = false;
    if (list.owner == 0) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, list.owner) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    list.write(gpa, &out) catch return;
    if (!fsutil.writePrivate(p, out.items)) std.log.warn("conjuntos de abas: não consegui gravar {s}", .{p});
}

// --- Menu da barra de abas -----------------------------------------------------

const id_save: u8 = 1;
const id_rename: u8 = 2;
const id_delete: u8 = 3;
const id_leave: u8 = 4;
/// Os conjuntos: 100 + o índice.
const id_set: u8 = 100;

pub fn openMenu(ctx: *d.Ctx, x: f32, y: f32) void {
    ctx.popup(.{ .menu = .{ .kind = .tabs, .id = 0, .x = x, .y = y } });
}

/// As linhas do menu (ui/popup.zig desenha): salvar, os conjuntos (o em uso com o
/// visto) e, com um em uso, renomear, excluir e sair.
pub fn menuItems(ctx: *d.Ctx, items: []popup.Item) usize {
    var n: usize = 0;
    const list = &ctx.st.conjuntos;
    const add = struct {
        fn f(out: []popup.Item, count: *usize, it: popup.Item) void {
            if (count.* < out.len) {
                out[count.*] = it;
                count.* += 1;
            }
        }
    }.f;
    add(items, &n, .{ .label = "Salvar abas como conjunto…", .en = "Save Tabs as Set…", .id = id_save });
    for (list.sets.items, 0..) |s, i| {
        // O nome como a pessoa escreveu: não passa pela tradução.
        add(items, &n, .{ .label = s.name, .en = s.name, .id = id_set + @as(u8, @intCast(i)), .sep = i == 0, .on = list.active == i, .raw = true });
    }
    if (list.active != null) {
        add(items, &n, .{ .label = "Renomear conjunto…", .en = "Rename Tab Set…", .id = id_rename, .sep = true });
        add(items, &n, .{ .label = "Sair do conjunto", .en = "Leave Tab Set", .id = id_leave });
        add(items, &n, .{ .label = "Excluir conjunto", .en = "Delete Tab Set", .id = id_delete, .danger = true });
    }
    return n;
}

pub fn menuChoose(ctx: *d.Ctx, item: u8) void {
    const list = &ctx.st.conjuntos;
    switch (item) {
        id_save => openName(ctx, null),
        id_rename => if (list.active) |i| openName(ctx, i),
        id_leave => ctx.act(.{ .conjunto = .leave }),
        id_delete => if (list.active) |i| ctx.act(.{ .conjunto = .{ .delete = i } }),
        else => if (item >= id_set and item - id_set < list.sets.items.len) ctx.act(.{ .conjunto = .{ .open = item - id_set } }),
    }
}

// --- Janela do nome ------------------------------------------------------------

var name_buf: [cj.max_name + 1]u8 = @splat(0);

/// "Salvar abas como conjunto…" (`rename` null) ou "Renomear conjunto…".
pub fn openName(ctx: *d.Ctx, rename: ?usize) void {
    @memset(&name_buf, 0);
    if (rename) |i| if (i < ctx.st.conjuntos.sets.items.len) {
        const name = ctx.st.conjuntos.sets.items[i].name;
        const n = @min(name.len, cj.max_name);
        @memcpy(name_buf[0..n], name[0..n]);
    };
    ctx.popup(.{ .tab_set_name = .{ .rename = rename } });
}

pub fn drawName(ctx: *d.Ctx, rename: ?usize) void {
    const list = &ctx.st.conjuntos;
    if (rename) |i| if (i >= list.sets.items.len) return popup.close(ctx);
    const r = forum.dialogRect(ctx, 460, 214);
    const dl = popup.beginWindow("##tab-set-name", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    const fam = ctx.ui;
    icons.tabSet(dl, r.x + 26, r.y + 27, ctx.col(.text).u());
    const title = if (rename != null) i18n.tr("Renomear conjunto", "Rename tab set") else i18n.tr("Salvar abas como conjunto", "Save tabs as a set");
    _ = d.textClipped(dl, fam.get(.bold), 17, r.x + 44, r.y + 16, ctx.col(.text), title, r.w - 62);
    var sb: [320]u8 = undefined;
    const n_tabs = ctx.st.tabs.items.len;
    const sub = if (rename != null)
        i18n.tr("Só o nome muda: as abas continuam as mesmas.", "Only the name changes: the tabs stay the same.")
    else if (n_tabs == 1)
        i18n.tr("A aba aberta vai para o conjunto. Enquanto ele estiver em uso, o que você abrir ou fechar fica salvo nele.", "The open tab goes into the set. While it's in use, whatever you open or close is saved in it.")
    else
        i18n.fmt(&sb, "As {d} abas abertas vão para o conjunto. Enquanto ele estiver em uso, o que você abrir ou fechar fica salvo nele.", "The {d} open tabs go into the set. While it's in use, whatever you open or close is saved in it.", .{@min(n_tabs, cj.max_tabs)});
    _ = inbox.wrapText(dl, fam.get(.regular), 13, r.x + 18, r.y + 46, r.w - 36, sub, 2, ctx.col(.muted));

    const ir: d.Rect = .{ .x = r.x + 18, .y = r.y + 92, .w = r.w - 36, .h = 36 };
    qa.mark(ir, "tabset-name", .{});
    if (popup.appearing) c.ImGui_SetKeyboardFocusHere();
    const enter = forum.textInput(ctx, dl, ir, "##tab-set-name", i18n.trZ("Nome (ex.: trabalho, jogo)", "Name (e.g. work, games)").ptr, &name_buf, c.ImGuiInputTextFlags_EnterReturnsTrue);
    const name = cj.cleanName(std.mem.sliceTo(&name_buf, 0));
    const ck = list.check(name, rename);
    // Por que não dá (o nome vazio não precisa de aviso: o botão apagado basta).
    var why: []const u8 = "";
    var wb: [200]u8 = undefined;
    if (rename == null and n_tabs == 0) {
        why = i18n.tr("Abra pelo menos um canal antes de salvar.", "Open at least one channel before saving.");
    } else switch (ck) {
        .exists => why = i18n.tr("Já existe um conjunto com esse nome.", "There's already a set with that name."),
        .full => why = i18n.fmt(&wb, "Já são {d} conjuntos: exclua um para salvar outro.", "That's {d} sets already: delete one to save another.", .{cj.max_sets}),
        .ok, .empty => {},
    }
    if (why.len > 0) {
        const wr: d.Rect = .{ .x = r.x + 18, .y = r.y + 136, .w = r.w - 36, .h = 18 };
        qa.mark(wr, "tabset-error", .{});
        _ = d.textClipped(dl, fam.get(.medium), 12.5, wr.x, wr.y, ctx.col(.danger), why, wr.w);
    }
    const can = ck == .ok and (rename != null or n_tabs > 0);
    const lbl = if (rename != null) i18n.tr("Renomear", "Rename") else i18n.tr("Salvar", "Save");
    const bw = d.width(fam.get(.semibold), 13.5, lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - 50, .w = bw, .h = 34 };
    qa.mark(br, "tabset-save", .{});
    const clicked = forum.primary(ctx, dl, fam, 0x7300, br, lbl, can);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "tabset-cancel", .{});
    if (inbox.button(ctx, dl, 0x7301, cr, cancel, false)) return popup.close(ctx);
    if ((clicked or enter) and can) {
        const owned = ctx.st.gpa.dupe(u8, name) catch return;
        if (rename) |i| ctx.act(.{ .conjunto = .{ .rename = .{ .index = i, .name = owned } } }) else ctx.act(.{ .conjunto = .{ .save = owned } });
        popup.close(ctx);
    }
}

// --- Etiqueta antes das abas -----------------------------------------------------

pub const Look = enum { pills, underline, tty };

/// A etiqueta do conjunto em uso, antes das abas: o ícone e o nome. Um clique abre
/// o menu dos conjuntos. Sem conjunto em uso não aparece. Devolve onde as abas
/// começam.
pub fn chip(ctx: *d.Ctx, fam: *d.Family, look: Look, x: f32, r: d.Rect) f32 {
    const set = ctx.st.conjuntos.activeSet() orelse return x;
    const dl = ctx.dl;
    var buf: [cj.max_name + 8]u8 = undefined;
    if (look == .tty) {
        const fs = ctx.th.font_size - 1;
        const font = fam.get(.bold);
        const lbl = d.printClip(&buf, "[{s}]", .{d.utf8Prefix(set.name, 24)});
        const cr: d.Rect = .{ .x = x, .y = r.y, .w = d.width(font, fs, lbl) + 8, .h = r.h };
        const hb = d.hit(ctx, 998, cr);
        qa.mark(cr, "tabset-chip", .{});
        if (hb.clicked) openMenu(ctx, cr.x, cr.bottom() + 2);
        if (hb.hovered) d.rect(dl, cr, ctx.col(.hover), 0);
        d.text(dl, font, fs, cr.x + 4, d.centerY(cr, fs), ctx.col(.accent), lbl);
        d.tip(ctx, cr, i18n.tr("Conjunto de abas em uso: clique para trocar ou sair", "Tab set in use: click to switch or leave"), hb.hovered);
        return cr.right() + 4;
    }
    const fs: f32 = 13;
    const font = fam.get(.semibold);
    const name_w = @min(d.width(font, fs, set.name), 140);
    const h: f32 = r.h - 10;
    const cr: d.Rect = .{ .x = x, .y = r.y + (r.h - h) / 2, .w = 30 + name_w + 12, .h = h };
    const hb = d.hit(ctx, 998, cr);
    qa.mark(cr, "tabset-chip", .{});
    if (hb.clicked) openMenu(ctx, cr.x, cr.bottom() + 4);
    const accent = ctx.col(.accent);
    if (look == .pills) {
        d.rect(dl, cr, accent.alpha(if (hb.hovered) 0.26 else 0.14), cr.h / 2);
        d.border(dl, cr, accent.alpha(0.5), cr.h / 2, 1);
    } else if (hb.hovered) d.rect(dl, cr, ctx.col(.hover), ctx.th.radius);
    const ink = accent.mix(ctx.col(.text), 0.35);
    icons.tabSet(dl, cr.x + 17, cr.y + cr.h / 2, ink.u());
    _ = d.textClipped(dl, font, fs, cr.x + 30, d.centerY(cr, fs), ink, set.name, name_w);
    d.tip(ctx, cr, i18n.tr("Conjunto de abas em uso: clique para trocar ou sair", "Tab set in use: click to switch or leave"), hb.hovered);
    // Sublinhado: um fio separa a etiqueta das abas (não tem fundo para isso).
    if (look == .underline) d.line(dl, cr.right() + 6, cr.y + 6, cr.right() + 6, cr.bottom() - 6, ctx.col(.border), 1);
    return cr.right() + (if (look == .underline) @as(f32, 13) else 8);
}
