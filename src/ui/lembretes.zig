//! Lembretes de mensagens (core/lembretes.zig): a janelinha do "Me lembrar…" (as
//! escolhas prontas, outro horário e a anotação), o aviso que fica na tela quando um
//! vence (Ir para a mensagem, Adiar 10 min, Concluir), a aba Lembretes do painel das
//! salvas (Agora, Próximos e Concluídos, com editar e excluir) e o arquivo
//! (~/.config/larpercord/lembretes-<conta>.json, com permissão 600, como o das salvas).
//! Nada disso vai para o Discord.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const w = @import("widgets.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const inbox = @import("inbox.zig");
const forum = @import("forum.zig");
const anim = @import("anim.zig");
const mascote = @import("mascote.zig");
const horario = @import("horario.zig");
const core = @import("../core/lembretes.zig");
const Id = @import("../core/types.zig").Id;
const fsutil = @import("../platform/fsutil.zig");

// --- Relógio --------------------------------------------------------------------------

/// QA: o relógio dos lembretes adiantado (o robô não espera 20 minutos).
pub var qa_skew_ms: i64 = 0;

/// A hora dos lembretes (ms UTC) a partir da hora do relógio de verdade.
pub fn clock(real_ms: i64) i64 {
    return real_ms + if (qa.on()) qa_skew_ms else 0;
}

/// O fuso do sistema (o SDL responde, no Linux e no Windows).
pub fn zone(utc_s: i64) i64 {
    return w.utcOffset(utc_s);
}

/// O QA confere: quantos avisos saíram e quantas notificações do sistema sairiam
/// (no QA nenhuma sai de verdade).
pub var fired_n: u32 = 0;
pub var desktop_n: u32 = 0;

// --- Arquivo --------------------------------------------------------------------------

fn path(buf: []u8, owner: Id) ?[:0]const u8 {
    // O QA nunca mexe na configuração de verdade.
    if (qa.on()) return std.fmt.bufPrintSentinel(buf, "qa-out/lembretes-{d}.json", .{owner}, 0) catch null;
    var nbuf: [48]u8 = undefined;
    return fsutil.configPath(buf, std.fmt.bufPrint(&nbuf, "lembretes-{d}.json", .{owner}) catch return null);
}

/// Caminho do arquivo da conta (o QA confere o que foi gravado).
pub fn filePath(buf: []u8, owner: Id) ?[:0]const u8 {
    return path(buf, owner);
}

/// Troca para a lista da conta que entrou. `read_file` false: começa vazia (QA e
/// prints, para serem reprodutíveis).
pub fn load(l: *core.List, gpa: std.mem.Allocator, owner: Id, read_file: bool) void {
    if (l.owner == owner) return;
    l.clear(gpa);
    l.owner = owner;
    if (!read_file) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, owner) orelse return;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return;
    defer c.SDL_free(data);
    l.read(gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch |err| {
        std.log.warn("lembretes: não consegui ler {s} ({t})", .{ p, err });
        fsutil.keepBroken(p);
    };
}

/// Grava a lista (num arquivo temporário e depois troca: uma queda no meio não estraga
/// o que já estava salvo).
pub fn persist(l: *const core.List, gpa: std.mem.Allocator) void {
    if (l.owner == 0) return;
    var buf: [512]u8 = undefined;
    const p = path(&buf, l.owner) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    l.write(gpa, &out) catch return;
    if (!fsutil.writePrivate(p, out.items)) std.log.warn("lembretes: não consegui gravar {s}", .{p});
}

// --- Textos de hora ---------------------------------------------------------------------

/// O dia da semana abreviado.
fn wday(day: i64) []const u8 {
    return switch (core.weekday(day)) {
        0 => i18n.tr("dom", "Sun"),
        1 => i18n.tr("seg", "Mon"),
        2 => i18n.tr("ter", "Tue"),
        3 => i18n.tr("qua", "Wed"),
        4 => i18n.tr("qui", "Thu"),
        5 => i18n.tr("sex", "Fri"),
        else => i18n.tr("sáb", "Sat"),
    };
}

/// "14:52", "amanhã 09:00", "ontem 14:52", "seg 09:00" (na semana), "23/11 09:00"
/// ou, em outro ano, "23/11/2027 09:00".
pub fn whenLabel(buf: []u8, at_ms: i64, now_ms: i64) []const u8 {
    var cb: [16]u8 = undefined;
    const hm = w.clock(&cb, @divFloor(at_ms, 1000));
    const day = core.localDay(zone, at_ms);
    const today = core.localDay(zone, now_ms);
    const diff = day - today;
    if (diff == 0) return std.fmt.bufPrint(buf, "{s}", .{hm}) catch "";
    if (diff == 1) return i18n.fmt(buf, "amanhã {s}", "tomorrow {s}", .{hm});
    if (diff == -1) return i18n.fmt(buf, "ontem {s}", "yesterday {s}", .{hm});
    if (diff > 1 and diff < 7) return std.fmt.bufPrint(buf, "{s} {s}", .{ wday(day), hm }) catch "";
    const cv = core.civilFromDays(day);
    if (cv.year != core.civilFromDays(today).year)
        return i18n.fmt(buf, "{d:0>2}/{d:0>2}/{d} {s}", "{1d:0>2}/{0d:0>2}/{2d} {3s}", .{ cv.day, cv.month, cv.year, hm });
    return i18n.fmt(buf, "{d:0>2}/{d:0>2} {s}", "{1d:0>2}/{0d:0>2} {2s}", .{ cv.day, cv.month, hm });
}

/// O dia do "Outro horário": "hoje", "amanhã" ou "qua 19/11".
fn dayLabel(buf: []u8, day: i64, today: i64) []const u8 {
    if (day == today) return i18n.tr("hoje", "today");
    if (day == today + 1) return i18n.tr("amanhã", "tomorrow");
    const cv = core.civilFromDays(day);
    return i18n.fmt(buf, "{s} {d:0>2}/{d:0>2}", "{0s} {2d:0>2}/{1d:0>2}", .{ wday(day), cv.day, cv.month });
}

/// "de onde veio": "#geral · Zig Brasil" ou "@ana".
fn source(buf: []u8, r: *const core.Reminder) []const u8 {
    if (r.guild == 0) return std.fmt.bufPrint(buf, "@{s}", .{r.channel_name}) catch r.channel_name;
    return std.fmt.bufPrint(buf, "#{s}  ·  {s}", .{ r.channel_name, r.guild_name }) catch r.channel_name;
}

fn previewOf(r: *const core.Reminder) []const u8 {
    return if (r.content.len > 0) r.content else i18n.tr("(sem texto)", "(no text)");
}

/// Quantos venceram e não foram concluídos (o número em cima do botão das salvas).
pub fn dueCount(ctx: *const d.Ctx) usize {
    return ctx.st.lembretes.dueCount(clock(ctx.now_ms));
}

// --- "Me lembrar…" ------------------------------------------------------------------------

var note_buf: [core.max_note + 1]u8 = @splat(0);
/// "Outro horário": o dia local e os minutos desde a meia-noite.
var pick_day: i64 = 0;
var pick_min: i64 = 0;

/// Abre a janelinha para a mensagem (com um lembrete pendente, edita ele).
pub fn open(ctx: *d.Ctx, message: Id) void {
    const edit: u32 = if (ctx.st.lembretes.pendingFor(message)) |r| r.id else 0;
    ctx.st.popup = .{ .lembrete = .{ .message = message, .edit = edit } };
}

fn openEdit(ctx: *d.Ctx, r: *const core.Reminder) void {
    ctx.st.popup = .{ .lembrete = .{ .message = r.message, .edit = r.id } };
}

fn fill(buf: []u8, s: []const u8) void {
    @memset(buf, 0);
    const n = d.utf8Prefix(s, buf.len - 1).len;
    @memcpy(buf[0..n], s[0..n]);
}

const presets = [_]struct { p: core.Preset, pt: []const u8, en: []const u8, key: []const u8 }{
    .{ .p = .min20, .pt = "Em 20 minutos", .en = "In 20 minutes", .key = "20min" },
    .{ .p = .h1, .pt = "Em 1 hora", .en = "In 1 hour", .key = "1h" },
    .{ .p = .h3, .pt = "Em 3 horas", .en = "In 3 hours", .key = "3h" },
    .{ .p = .tomorrow9, .pt = "Amanhã às 9:00", .en = "Tomorrow at 9:00", .key = "amanha" },
    .{ .p = .next_week, .pt = "Semana que vem", .en = "Next week", .key = "semana" },
};

/// QA: põe o "Outro horário" num instante (ms) sem depender de que hora o robô roda.
pub fn qaPick(at_ms: i64) void {
    pick_day = core.localDay(zone, at_ms);
    pick_min = core.localMinute(zone, at_ms);
}

/// A hora que o "Outro horário" mostra (ms UTC).
fn pickedDue() i64 {
    return core.atLocal(zone, pick_day, @divFloor(pick_min, 60), @mod(pick_min, 60));
}

fn submit(ctx: *d.Ctx, message: Id, edit: u32, due_ms: i64) void {
    const note = ctx.st.gpa.dupe(u8, std.mem.sliceTo(&note_buf, 0)) catch return;
    if (edit != 0)
        ctx.act(.{ .lembrete = .{ .edit = .{ .id = edit, .due_ms = due_ms, .note = note } } })
    else
        ctx.act(.{ .lembrete = .{ .add = .{ .message = message, .due_ms = due_ms, .note = note } } });
    popup.close(ctx);
}

/// Um botão quadrado pequeno com um símbolo ("‹", "›", "−", "+").
fn stepButton(ctx: *d.Ctx, dl: *c.ImDrawList, id: usize, r: d.Rect, glyph: []const u8, on: bool) bool {
    const hb = d.hit(ctx, id, r);
    const radius = @max(ctx.th.radius, 4);
    d.rect(dl, r, if (hb.hovered and on) ctx.col(.accent) else ctx.col(.rail).mix(ctx.col(.surface), 0.35), radius);
    const font = ctx.ui.get(.bold);
    const gw = d.width(font, 15, glyph);
    d.text(dl, font, 15, r.x + (r.w - gw) / 2, d.centerY(r, 15), if (!on) ctx.col(.faint) else if (hb.hovered) ctx.col(.accent_text) else ctx.col(.text), glyph);
    return on and hb.clicked;
}

/// Um valor no meio dos botões de passo.
fn stepValue(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, text: []const u8) void {
    const font = ctx.ui.get(.semibold);
    const tw = d.width(font, 13.5, text);
    d.text(dl, font, 13.5, r.x + (r.w - tw) / 2, d.centerY(r, 13.5), ctx.col(.text), text);
}

pub fn drawEditor(ctx: *d.Ctx, message: Id, edit: u32) void {
    const now = clock(ctx.now_ms);
    const l = &ctx.st.lembretes;
    const editing: ?*core.Reminder = if (edit != 0) l.find(edit) else null;
    if (edit != 0 and editing == null) return popup.close(ctx);
    const live = ctx.store.findAny(message);
    if (editing == null and live == null) return popup.close(ctx);
    const today = core.localDay(zone, now);
    if (popup.appearing) {
        fill(&note_buf, if (editing) |r| r.note else "");
        // Outro horário: a hora do lembrete, se ainda vem; senão daqui a 1 h, nos 15
        // minutos cheios seguintes.
        const keep = if (editing) |r| r.due_ms > now else false;
        const base = if (keep) editing.?.due_ms else now + 60 * 60 * 1000;
        pick_day = core.localDay(zone, base);
        pick_min = core.localMinute(zone, base);
        if (!keep) pick_min = @min(@divFloor(pick_min + 14, 15) * 15, 23 * 60 + 45);
    }

    const r = forum.dialogRect(ctx, 460, 492);
    const dl = popup.beginWindow("##lembrete", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    qa.mark(r, "remind-editor", .{});
    const fam = ctx.ui;
    const x = r.x + 18;
    const iw = r.w - 36;
    icons.alarm(dl, x + 8, r.y + 27, ctx.col(.text).u());
    d.text(dl, fam.get(.bold), 17, x + 26, r.y + 16, ctx.col(.text), if (editing != null) i18n.tr("Editar lembrete", "Edit reminder") else i18n.tr("Me lembrar", "Remind me"));

    // A mensagem: de onde veio, quem escreveu e o começo do texto.
    var sb: [200]u8 = undefined;
    var pb: [600]u8 = undefined;
    var author: []const u8 = "?";
    var where: []const u8 = "";
    var text: []const u8 = "";
    if (editing) |e| {
        where = source(&sb, e);
        author = e.author_name;
        text = previewOf(e);
    } else if (live) |f| {
        where = inbox.channelLabel(&sb, ctx, f.cs.info.id);
        author = ctx.store.nameIn(f.cs.info.guild, f.m.msg.author) orelse "?";
        text = inbox.previewText(ctx, &pb, f.m);
    }
    var lb: [320]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 12.5, x, r.y + 48, ctx.col(.muted), std.fmt.bufPrint(&lb, "{s}  ·  {s}", .{ where, author }) catch where, iw);
    _ = inbox.wrapText(dl, fam.get(.regular), 13.5, x, r.y + 68, iw, text, 2, ctx.col(.text).mix(ctx.col(.muted), 0.15));

    // A anotação (opcional), que vai junto com qualquer escolha.
    d.text(dl, fam.get(.semibold), 12.5, x, r.y + 116, ctx.col(.muted), i18n.tr("Anotação (opcional)", "Note (optional)"));
    const nr: d.Rect = .{ .x = x, .y = r.y + 136, .w = iw, .h = 34 };
    qa.mark(nr, "remind-note", .{});
    _ = forum.textInput(ctx, dl, nr, "##remind-note", i18n.trZ("Por que lembrar?", "Why remember?"), &note_buf, 0);

    // As escolhas prontas: um clique e está feito.
    var y = r.y + 182;
    for (presets, 0..) |p, i| {
        const pr: d.Rect = .{ .x = x - 6, .y = y, .w = iw + 12, .h = 32 };
        const hb = d.hit(ctx, 0x7600 + i, pr);
        qa.mark(pr, "remind-preset:{s}", .{p.key});
        if (hb.hovered) d.rect(dl, pr, ctx.col(.hover), @max(ctx.th.radius - 2, 4));
        d.text(dl, fam.get(.medium), 14, pr.x + 10, d.centerY(pr, 14), ctx.col(.text), i18n.tr(p.pt, p.en));
        const due = core.presetDue(p.p, now, zone);
        var wb: [48]u8 = undefined;
        const wl = whenLabel(&wb, due, now);
        const ww = d.width(fam.get(.regular), 13, wl);
        d.text(dl, fam.get(.regular), 13, pr.right() - 10 - ww, d.centerY(pr, 13), ctx.col(.faint), wl);
        if (hb.clicked) return submit(ctx, message, edit, due);
        y += 32;
    }

    // Outro horário: o dia, a hora e os minutos (de 5 em 5).
    y += 10;
    d.line(dl, r.x + 1, y, r.right() - 1, y, ctx.col(.border), 1);
    y += 10;
    d.text(dl, fam.get(.semibold), 12.5, x, y, ctx.col(.muted), i18n.tr("Outro horário", "Pick a date and time"));
    y += 22;
    const bs: f32 = 28;
    var px = x;
    const day_w: f32 = 118;
    if (stepButton(ctx, dl, 0x7610, .{ .x = px, .y = y, .w = bs, .h = bs }, "‹", pick_day > today)) pick_day -= 1;
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-day-prev", .{});
    px += bs;
    var db: [48]u8 = undefined;
    const day_text = dayLabel(&db, pick_day, today);
    stepValue(ctx, dl, .{ .x = px, .y = y, .w = day_w, .h = bs }, day_text);
    qa.mark(.{ .x = px, .y = y, .w = day_w, .h = bs }, "remind-day:{s}", .{day_text});
    px += day_w;
    if (stepButton(ctx, dl, 0x7611, .{ .x = px, .y = y, .w = bs, .h = bs }, "›", pick_day < today + 366)) pick_day += 1;
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-day-next", .{});
    px += bs + 16;
    const hh = @divFloor(pick_min, 60);
    const mm = @mod(pick_min, 60);
    var hb_buf: [16]u8 = undefined;
    const hour_text = if (w.hour12)
        (std.fmt.bufPrint(&hb_buf, "{d} {s}", .{ if (@mod(hh, 12) == 0) 12 else @mod(hh, 12), if (hh < 12) "AM" else "PM" }) catch "")
    else
        (std.fmt.bufPrint(&hb_buf, "{d:0>2}", .{@as(u32, @intCast(hh))}) catch "");
    const hour_w: f32 = if (w.hour12) 56 else 36;
    if (stepButton(ctx, dl, 0x7612, .{ .x = px, .y = y, .w = bs, .h = bs }, "−", true)) pick_min = @mod(pick_min - 60, 24 * 60);
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-hour-dec", .{});
    px += bs;
    stepValue(ctx, dl, .{ .x = px, .y = y, .w = hour_w, .h = bs }, hour_text);
    px += hour_w;
    if (stepButton(ctx, dl, 0x7613, .{ .x = px, .y = y, .w = bs, .h = bs }, "+", true)) pick_min = @mod(pick_min + 60, 24 * 60);
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-hour-inc", .{});
    px += bs;
    d.text(dl, fam.get(.bold), 15, px + 3, d.centerY(.{ .x = px, .y = y, .w = 10, .h = bs }, 15), ctx.col(.muted), ":");
    px += 12;
    var mb: [8]u8 = undefined;
    const min_text = std.fmt.bufPrint(&mb, "{d:0>2}", .{@as(u32, @intCast(mm))}) catch "";
    if (stepButton(ctx, dl, 0x7614, .{ .x = px, .y = y, .w = bs, .h = bs }, "−", true)) pick_min = hh * 60 + @mod(mm - 5, 60);
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-min-dec", .{});
    px += bs;
    stepValue(ctx, dl, .{ .x = px, .y = y, .w = 34, .h = bs }, min_text);
    px += 34;
    if (stepButton(ctx, dl, 0x7615, .{ .x = px, .y = y, .w = bs, .h = bs }, "+", true)) pick_min = hh * 60 + @mod(mm + 5, 60);
    qa.mark(.{ .x = px, .y = y, .w = bs, .h = bs }, "remind-min-inc", .{});
    y += bs + 8;
    const picked = pickedDue();
    const future = picked > now;
    var tb: [96]u8 = undefined;
    var wb2: [48]u8 = undefined;
    if (future) {
        var rb: [48]u8 = undefined;
        const rel = horario.relative(&rb, @divFloor(picked - now, 1000));
        d.text(dl, fam.get(.regular), 12, x, y, ctx.col(.faint), std.fmt.bufPrint(&tb, "{s}  ·  {s}", .{ whenLabel(&wb2, picked, now), rel }) catch "");
    } else {
        d.text(dl, fam.get(.regular), 12, x, y, ctx.col(.danger), i18n.tr("Esse horário já passou.", "That time has already passed."));
        qa.mark(.{ .x = x, .y = y, .w = iw, .h = 16 }, "remind-past", .{});
    }

    // Criar (ou salvar) com o outro horário; cancelar; excluir quem está editando.
    const lbl = if (editing != null) i18n.tr("Salvar", "Save") else i18n.tr("Criar lembrete", "Set reminder");
    const bw = d.width(fam.get(.semibold), 13.5, lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 18 - bw, .y = r.bottom() - 50, .w = bw, .h = 34 };
    qa.mark(br, "remind-create", .{});
    const create = forum.primary(ctx, dl, fam, 0x7620, br, lbl, future);
    const cancel = i18n.tr("Cancelar", "Cancel");
    const cw = inbox.buttonWidth(ctx, cancel);
    const cr: d.Rect = .{ .x = br.x - cw - 10, .y = br.y + 3, .w = cw, .h = 28 };
    qa.mark(cr, "remind-cancel", .{});
    if (inbox.button(ctx, dl, 0x7621, cr, cancel, false)) return popup.close(ctx);
    if (editing) |e| {
        const del = i18n.tr("Excluir", "Delete");
        const kw = inbox.buttonWidth(ctx, del);
        const kr: d.Rect = .{ .x = x, .y = br.y + 3, .w = kw, .h = 28 };
        qa.mark(kr, "remind-editor-delete", .{});
        if (inbox.button(ctx, dl, 0x7622, kr, del, true)) {
            ctx.act(.{ .lembrete = .{ .delete = e.id } });
            return popup.close(ctx);
        }
    }
    if (create) submit(ctx, message, edit, picked);
}

// --- O aviso -------------------------------------------------------------------------------

/// A aba Lembretes do painel das salvas está aberta: a lista já mostra os vencidos com
/// os mesmos botões, e o aviso sai da frente.
fn listOpen(ctx: *const d.Ctx) bool {
    return ctx.st.popup == .saved and @import("saved.zig").tab == .lembretes;
}

const Buttons = enum { due, upcoming, done };

/// Os botões de cada estado: vencido (ir, adiar, concluir), por vir e concluído (ir,
/// editar, excluir). Devolve a altura usada.
fn buttons(ctx: *d.Ctx, dl: *c.ImDrawList, x: f32, y: f32, max_w: f32, r: *const core.Reminder, kind: Buttons, base_id: usize, comptime prefix: []const u8) f32 {
    const labels: [3][]const u8 = switch (kind) {
        .due => .{ i18n.tr("Ir para a mensagem", "Jump to message"), i18n.tr("Adiar 10 min", "Snooze 10 min"), i18n.tr("Concluir", "Done") },
        .upcoming, .done => .{ i18n.tr("Ir para a mensagem", "Jump to message"), i18n.tr("Editar", "Edit"), i18n.tr("Excluir", "Delete") },
    };
    const keys: [3][]const u8 = switch (kind) {
        .due => .{ "open", "snooze", "done" },
        .upcoming, .done => .{ "open", "edit", "delete" },
    };
    var bx = x;
    var by = y;
    for (labels, 0..) |lbl, k| {
        const bw = inbox.buttonWidth(ctx, lbl);
        // Não coube (um idioma de palavras compridas): desce para a linha de baixo.
        if (bx > x and bx + bw > x + max_w) {
            bx = x;
            by += 34;
        }
        const br: d.Rect = .{ .x = bx, .y = by, .w = bw, .h = 28 };
        if (prefix.len == 0) qa.mark(br, "remind-{s}:{d}", .{ keys[k], r.id }) else qa.mark(br, prefix ++ "-{s}", .{keys[k]});
        if (inbox.button(ctx, dl, base_id + k, br, lbl, kind != .due and k == 2)) {
            const act: core.Action = switch (kind) {
                .due => switch (k) {
                    0 => .{ .open = r.id },
                    1 => .{ .snooze = r.id },
                    else => .{ .done = r.id },
                },
                .upcoming, .done => switch (k) {
                    0 => .{ .open = r.id },
                    1 => {
                        openEdit(ctx, r);
                        return by - y + 28;
                    },
                    else => .{ .delete = r.id },
                },
            };
            ctx.act(.{ .lembrete = act });
        }
        bx = br.right() + 8;
    }
    return by - y + 28;
}

/// Quando vence um lembrete, o aviso fica no canto de baixo, à direita, até alguém
/// mexer: ir para a mensagem, adiar ou concluir. Os outros vencidos esperam a vez (o
/// número deles aparece no canto).
pub fn notice(ctx: *d.Ctx) void {
    if (ctx.st.settings.open or listOpen(ctx)) return;
    const now = clock(ctx.now_ms);
    var first: ?*core.Reminder = null;
    var more: usize = 0;
    for (ctx.st.lembretes.items.items) |*it| {
        if (!it.isDue(now) or it.fired_ms == 0) continue;
        if (first == null) first = it else more += 1;
    }
    const r = first orelse return;
    const fam = ctx.ui;
    const win = ctx.win;

    // Os botões cabem numa linha (o cartão cresce um pouco em idiomas compridos).
    var need: f32 = 0;
    for ([_][]const u8{ i18n.tr("Ir para a mensagem", "Jump to message"), i18n.tr("Adiar 10 min", "Snooze 10 min"), i18n.tr("Concluir", "Done") }) |b| need += inbox.buttonWidth(ctx, b) + 8;
    const card_w: f32 = @min(@max(360, need + 24), win.w - 24);
    const inner = card_w - 28;
    const text_w = inner - 30;
    const ph = inbox.wrapText(null, fam.get(.regular), 13.5, 0, 0, text_w, previewOf(r), 2, ctx.col(.text));
    const nh: f32 = if (r.note.len > 0) inbox.wrapText(null, fam.get(.italic), 13, 0, 0, inner - 12, r.note, 2, ctx.col(.text)) + 10 else 0;
    const bh: f32 = if (need > inner + 8) 62 else 28;
    const ch: f32 = 14 + 24 + 20 + 22 + ph + 8 + nh + bh + 14;
    const k = anim.to(anim.id("lembrete-aviso", r.id), 1, 16);
    const spot: d.Rect = .{ .x = win.right() - card_w - 18, .y = @max(win.y + 60, win.bottom() - ch - 96), .w = card_w, .h = ch };
    // Janela própria, só do tamanho do cartão: recebe o clique mesmo com um popup aberto,
    // na frente a cada quadro sem tirar o foco de quem está digitando.
    c.ImGui_SetNextWindowPos(d.v(spot.x - 20, spot.y - 20), 0);
    c.ImGui_SetNextWindowSize(d.v(spot.w + 40, spot.h + 40), 0);
    _ = c.ImGui_Begin("##lembrete-aviso", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav |
        c.ImGuiWindowFlags_NoFocusOnAppearing);
    defer c.ImGui_End();
    d.windowToFront();
    const dl = c.ImGui_GetWindowDrawList();
    const radius = @max(ctx.th.radius + 4, 6);
    const box: d.Rect = .{ .x = spot.x, .y = spot.y + (1 - k) * 14, .w = spot.w, .h = spot.h };
    d.shadow(dl, box, radius, 22, ctx.col(.shadow).alpha(k));
    d.rect(dl, box, ctx.col(.overlay).mix(ctx.col(.elevated), 0.35).alpha(k), radius);
    const late = r.late();
    const tint = if (late) ctx.col(.idle) else ctx.col(.accent);
    d.border(dl, box, tint.alpha(0.6 * k), radius, 1);
    d.rect(dl, .{ .x = box.x + 1, .y = box.y + 1, .w = box.w - 2, .h = 2.5 }, tint.alpha(0.85 * k), 4);
    qa.mark(box, "remind-notice", .{});
    qa.mark(box, "remind-notice:{d}", .{r.id});
    if (late) qa.mark(box, "remind-notice-late", .{});
    // O mascote do canto leva o bilhete até aqui (ui/mascote_pet.zig): o lugar onde o
    // cartão para, não onde ele está entrando.
    @import("mascote_pet.zig").anchor(.reminder, spot, ctx.now_ms);

    const x = box.x + 14;
    var y = box.y + 14;
    icons.alarm(dl, x + 9, y + 10, tint.alpha(k).u());
    const title = if (late) i18n.tr("Lembrete atrasado", "Overdue reminder") else i18n.tr("Lembrete", "Reminder");
    d.text(dl, fam.get(.bold), 14.5, x + 26, y + 1, ctx.col(.text).alpha(k), title);
    var wb: [48]u8 = undefined;
    const when = whenLabel(&wb, r.due_ms, now);
    const ww = d.width(fam.get(.regular), 12, when);
    var right = box.right() - 14 - ww;
    d.text(dl, fam.get(.regular), 12, right, y + 3, ctx.col(.faint).alpha(k), when);
    if (more > 0) {
        var mb: [16]u8 = undefined;
        const mt = std.fmt.bufPrint(&mb, "+{d}", .{more}) catch "";
        const mw = d.width(fam.get(.bold), 11, mt) + 12;
        right -= mw + 8;
        const mr: d.Rect = .{ .x = right, .y = y + 1, .w = mw, .h = 17 };
        d.rect(dl, mr, ctx.col(.danger).alpha(k), 8.5);
        d.text(dl, fam.get(.bold), 11, mr.x + 6, mr.y + 1.5, d.Rgba.white.alpha(k), mt);
        qa.mark(mr, "remind-notice-more:{d}", .{more});
        var tbuf: [96]u8 = undefined;
        d.tip(ctx, mr, i18n.fmt(&tbuf, "mais {d} esperando a vez", "{d} more waiting", .{more}), d.hit(ctx, 40, mr).hovered);
    }
    y += 24;
    var sb: [200]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 12, x, y, ctx.col(.muted).alpha(k), source(&sb, r), inner);
    y += 20;
    w.avatar(ctx, dl, x + 11, y + 11, 22, r.author, .circle, null, k);
    _ = d.textClipped(dl, fam.get(.semibold), 13.5, x + 30, y + 2, w.nameColor(ctx, r.guild, r.author).alpha(k), r.author_name, text_w);
    y += 22;
    y += inbox.wrapText(dl, fam.get(.regular), 13.5, x + 30, y, text_w, previewOf(r), 2, ctx.col(.text).mix(ctx.col(.muted), 0.15).alpha(k));
    y += 8;
    if (r.note.len > 0) {
        const th = nh - 10;
        d.rect(dl, .{ .x = x, .y = y + 1, .w = 3, .h = th }, ctx.col(.accent).alpha(k), 1.5);
        _ = inbox.wrapText(dl, fam.get(.italic), 13, x + 12, y, inner - 12, r.note, 2, ctx.col(.text).mix(ctx.col(.accent), 0.2).alpha(k));
        y += nh;
    }
    _ = buttons(ctx, dl, x, y, inner, r, .due, 10, "remind-notice");
}

// --- A aba Lembretes do painel das salvas ------------------------------------------------

var heights: [core.max_items + 12]f32 = @splat(0);
var heights_w: f32 = 0;
var heights_n: usize = 0;

/// Os lembretes: os que venceram (Agora), os que vêm (Próximos) e os concluídos. Devolve
/// onde a lista acaba.
pub fn list(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32) f32 {
    const fam = ctx.ui;
    const items = ctx.st.lembretes.items.items;
    var y = y0;
    if (items.len == 0) {
        mascote.inApp(ctx, dl, body.x + body.w / 2, y + 58, 78, .sleep, .saved, 8);
        const t1 = i18n.tr("Nenhum lembrete.", "No reminders.");
        const t2 = i18n.tr("Botão direito numa mensagem → Me lembrar…", "Right-click a message → Remind Me…");
        const w1 = d.width(fam.get(.bold), 16, t1);
        const w2 = d.width(fam.get(.regular), 13.5, t2);
        d.text(dl, fam.get(.bold), 16, body.x + (body.w - w1) / 2, y + 112, ctx.col(.text), t1);
        d.text(dl, fam.get(.regular), 13.5, body.x + @max(12, (body.w - w2) / 2), y + 138, ctx.col(.muted), t2);
        qa.mark(.{ .x = body.x, .y = y + 112, .w = body.w, .h = 44 }, "remind-empty", .{});
        return y + 180;
    }
    if (heights_w != body.w or heights_n != items.len) {
        heights = @splat(0);
        heights_w = body.w;
        heights_n = items.len;
    }
    const now = clock(ctx.now_ms);
    const Section = struct { kind: Buttons, pt: []const u8, en: []const u8, key: []const u8 };
    const sections = [_]Section{
        .{ .kind = .due, .pt = "AGORA", .en = "NOW", .key = "agora" },
        .{ .kind = .upcoming, .pt = "PRÓXIMOS", .en = "UPCOMING", .key = "proximos" },
        .{ .kind = .done, .pt = "CONCLUÍDOS", .en = "DONE", .key = "concluidos" },
    };
    for (sections) |sec| {
        var count: usize = 0;
        for (items) |*it| {
            if (kindOf(it, now) == sec.kind) count += 1;
        }
        if (count == 0) continue;
        var hb: [48]u8 = undefined;
        const head = std.fmt.bufPrint(&hb, "{s}  ·  {d}", .{ i18n.tr(sec.pt, sec.en), count }) catch "";
        d.text(dl, fam.get(.bold), 11.5, body.x + 16, y + 4, if (sec.kind == .due) ctx.col(.danger) else ctx.col(.faint), head);
        qa.mark(.{ .x = body.x + 16, .y = y + 4, .w = body.w - 32, .h = 16 }, "remind-section:{s}:{d}", .{ sec.key, count });
        y += 24;
        for (items, 0..) |*it, i| {
            if (kindOf(it, now) != sec.kind) continue;
            // Cartões fora da tela só contam a altura.
            const known = if (i < heights.len) heights[i] else 0;
            if (known > 0 and (y + known < body.y - 64 or y > body.bottom() + 64)) {
                y += known;
                continue;
            }
            const y1 = card(ctx, dl, body, y, it, sec.kind, i, now);
            if (i < heights.len) heights[i] = y1 - y;
            y = y1;
        }
        y += 4;
    }
    return y;
}

fn kindOf(r: *const core.Reminder, now: i64) Buttons {
    if (!r.pending()) return .done;
    return if (r.isDue(now)) .due else .upcoming;
}

/// Um cartão: quando, de onde, autor e texto, a anotação e os botões.
fn card(ctx: *d.Ctx, dl: *c.ImDrawList, body: d.Rect, y0: f32, r: *const core.Reminder, kind: Buttons, index: usize, now: i64) f32 {
    const fam = ctx.ui;
    const x = body.x + 12;
    const wd = body.w - 24;
    const inner = x + 12;
    const iw = wd - 24;
    var y = y0 + 10;
    qa.mark(.{ .x = x, .y = y0, .w = wd, .h = 20 }, "remind-item:{d}", .{r.id});

    // Quando (à esquerda, com a cor do estado) e de onde (à direita).
    var wb: [48]u8 = undefined;
    var tb: [128]u8 = undefined;
    const when = switch (kind) {
        .due => i18n.fmt(&tb, "venceu {s}", "due {s}", .{whenLabel(&wb, r.due_ms, now)}),
        .upcoming => blk: {
            var rb: [48]u8 = undefined;
            break :blk std.fmt.bufPrint(&tb, "{s}  ·  {s}", .{ whenLabel(&wb, r.due_ms, now), horario.relative(&rb, @divFloor(r.due_ms - now, 1000)) }) catch "";
        },
        .done => i18n.fmt(&tb, "concluído {s}", "done {s}", .{whenLabel(&wb, r.done_s * 1000, now)}),
    };
    const when_col = switch (kind) {
        .due => ctx.col(.danger),
        .upcoming => ctx.col(.accent),
        .done => ctx.col(.faint),
    };
    icons.alarm(dl, inner + 7, y + 8, when_col.u());
    const ww = d.textClipped(dl, fam.get(.semibold), 12.5, inner + 20, y, when_col, when, iw * 0.55);
    var sb: [200]u8 = undefined;
    _ = d.textClipped(dl, fam.get(.regular), 12, inner + 20 + ww + 14, y + 0.5, ctx.col(.faint), source(&sb, r), iw - ww - 34);
    y += 22;

    // Autor e texto.
    w.avatar(ctx, dl, inner + 12, y + 12, 24, r.author, .circle, null, 1);
    _ = d.textClipped(dl, fam.get(.semibold), 14, inner + 32, y + 2, w.nameColor(ctx, r.guild, r.author), r.author_name, iw - 32);
    y += 24;
    const text_col = if (kind == .done) ctx.col(.muted) else ctx.col(.text).mix(ctx.col(.muted), 0.15);
    y += inbox.wrapText(dl, fam.get(.regular), 14, inner + 32, y, iw - 32, previewOf(r), 3, text_col);
    y += 6;
    if (r.note.len > 0) {
        const nh = inbox.wrapText(null, fam.get(.italic), 13.5, inner + 12, y, iw - 16, r.note, 3, ctx.col(.text));
        d.rect(dl, .{ .x = inner, .y = y + 2, .w = 3, .h = nh }, ctx.col(.accent), 1.5);
        _ = inbox.wrapText(dl, fam.get(.italic), 13.5, inner + 12, y + 2, iw - 16, r.note, 3, ctx.col(.text).mix(ctx.col(.accent), 0.2));
        y += nh + 8;
    }
    y += buttons(ctx, dl, inner, y, iw, r, kind, 4000 + index * 4, "") + 6;
    const box: d.Rect = .{ .x = x, .y = y0, .w = wd, .h = y - y0 };
    d.border(dl, box, if (kind == .due) ctx.col(.danger).alpha(0.55) else ctx.col(.border), @max(ctx.th.radius, 6), 1);
    return y + 10;
}
