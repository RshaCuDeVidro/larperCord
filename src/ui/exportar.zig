//! "Exportar conversa…" e "Salvar…" / "Salvar em Downloads": a janela de exportar,
//! o cartão de andamento (cancelar enquanto roda; "Abrir" e "Abrir pasta" no fim),
//! o alvo do menu de contexto da mídia e a escolha do arquivo (o seletor do
//! sistema; no QA, um caminho injetado: nenhuma janela de verdade abre).
//!
//! O trabalho pesado fica em net/exportar.zig, que explica as regras da conta: a
//! exportação usa só o que já está no computador (a memória, o cache em disco e os
//! arquivos que o app já baixou) e não pede nada ao Discord, nem a mídia. Esta tela
//! diz quantas mensagens há e desde quando, e que para ter mais é preciso rolar a
//! conversa para cima antes.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const popup = @import("popup.zig");
const forum = @import("forum.zig");
const inbox = @import("inbox.zig");
const invites = @import("invites.zig");
const images = @import("images.zig");
const video = @import("video.zig");
const audio_demo = @import("audio_demo.zig");
const widgets = @import("widgets.zig");
const rich = @import("rich.zig");
const horario = @import("horario.zig");
const types = @import("../core/types.zig");
const store_mod = @import("../core/store.zig");
const exportar = @import("../core/exportar.zig");
const salvar = @import("../core/salvar.zig");
const reply_preview = @import("../core/reply_preview.zig");
const quadros = @import("../core/gif_quadros.zig");
const version = @import("../core/version.zig");
const job_mod = @import("../net/exportar.zig");
const msg_cache = @import("../net/msg_cache.zig");
const pastas = @import("../platform/pastas.zig");
const platform = @import("../platform/window.zig");
const sys = @import("../platform/sys.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

/// No navegador (a demonstração do site) não há threads nem disco de verdade.
pub fn available() bool {
    return !sys.web;
}

var wake_type: u32 = 0;

/// Começo do app: quem acordar e de onde vêm os arquivos que já estão no computador.
pub fn init(wt: u32) void {
    wake_type = wt;
    job_mod.local_hook = &localBytes;
}

fn wakeUi() void {
    platform.Window.wake(wake_type, .media);
}

/// O arquivo de `url` se ele já está no computador (qualquer thread): a imagem que
/// as imagens já baixaram do CDN, as da demonstração, um arquivo nosso.
fn localBytes(url: []const u8, out: *std.ArrayList(u8)) bool {
    if (std.mem.eql(u8, url, video.demo_link) or std.mem.eql(u8, url, "demo:mp4")) {
        out.appendSlice(alloc, video.demo_mp4) catch return false;
        return true;
    }
    if (std.mem.eql(u8, url, "demo:voice") or std.mem.startsWith(u8, url, audio_demo.prefixo)) {
        const ogg = audio_demo.bytes(url) catch return false;
        defer alloc.free(ogg);
        out.appendSlice(alloc, ogg) catch return false;
        return true;
    }
    // Os GIFs da demonstração: um GIF de verdade, feito aqui (decodificar os quadros
    // todos para gravar um PNG seria lento, e o arquivo nem seria GIF).
    if (std.mem.startsWith(u8, url, "demo:")) {
        const spec = std.mem.sliceTo(url[5..], '?');
        if (std.mem.eql(u8, spec, "gif") or std.mem.eql(u8, spec, "longgif")) {
            const gif = quadros.demoGif(alloc, 400, 240, 24, 4) catch return false;
            defer alloc.free(gif);
            out.appendSlice(alloc, gif) catch return false;
            return true;
        }
        return images.demoPng(url, if (std.mem.startsWith(u8, url, "demo:av:")) 128 else 1024, out);
    }
    if (std.mem.startsWith(u8, url, "file://")) {
        var pb: [1100]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "{s}", .{url[7..]}, 0) catch return false;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse return false;
        defer c.SDL_free(data);
        out.appendSlice(alloc, @as([*]const u8, @ptrCast(data))[0..size]) catch return false;
        return true;
    }
    return images.recentOriginal(url, out);
}

/// Hora local de uma mensagem (qualquer thread).
fn localClock(unix: i64) exportar.Parts {
    var dt: c.SDL_DateTime = undefined;
    const ns = horario.sdlTime(unix) orelse return exportar.utcClock(unix);
    if (!c.SDL_TimeToDateTime(ns, &dt, true)) return exportar.utcClock(unix);
    return .{ .year = @intCast(dt.year), .month = @intCast(dt.month), .day = @intCast(dt.day), .hour = @intCast(dt.hour), .minute = @intCast(dt.minute) };
}

fn dayOf(unix: i64) i64 {
    const p = localClock(unix);
    return @as(i64, p.year) * 10000 + @as(i64, p.month) * 100 + p.day;
}

fn dayText(buf: []u8, day: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(@divTrunc(day, 10000))), @as(u64, @intCast(@mod(@divTrunc(day, 100), 100))), @as(u64, @intCast(@mod(day, 100))) }) catch "";
}

// --- O que está no computador ------------------------------------------------------

/// Uma mensagem da conversa que está no computador: na memória ou no cache em disco.
const Local = struct { id: Id, unix: i64, mem: ?*const store_mod.StoredMessage = null, cached: ?*const @import("../core/cache_format.zig").Entry = null };

/// As mensagens da conversa que estão no computador, em ordem (sem repetir: a da
/// memória vale mais que a do disco). Os textos do disco ficam em `arena`.
fn gather(ctx: *d.Ctx, arena: std.mem.Allocator, channel: Id, users_out: ?*[]const @import("../core/cache_format.zig").User) []Local {
    var list: std.ArrayList(Local) = .empty;
    var seen: std.AutoHashMapUnmanaged(Id, void) = .empty;
    defer seen.deinit(alloc);
    if (ctx.store.channel(channel)) |cs| for (cs.messages.items) |*m| {
        // Como o cache em disco: nem as que ainda não foram, nem as apagadas, nem as
        // que só quem usou o comando vê.
        if (m.pending or m.msg.id == 0 or m.deleted or m.msg.flags & (1 << 6) != 0) continue;
        if ((seen.getOrPut(alloc, m.msg.id) catch continue).found_existing) continue;
        list.append(arena, .{ .id = m.msg.id, .unix = m.msg.timestamp, .mem = m }) catch {};
    };
    if (msg_cache.readChannel(arena, channel)) |dec| {
        for (dec.entries) |*e| {
            if (e.msg.id == 0) continue;
            if ((seen.getOrPut(alloc, e.msg.id) catch continue).found_existing) continue;
            list.append(arena, .{ .id = e.msg.id, .unix = e.msg.timestamp, .cached = e }) catch {};
        }
        if (users_out) |u| u.* = dec.users;
    }
    std.mem.sort(Local, list.items, {}, struct {
        fn lt(_: void, a: Local, b: Local) bool {
            return a.id < b.id;
        }
    }.lt);
    return list.items;
}

// --- A janela de exportar ---------------------------------------------------------------

const Dlg = struct {
    channel: Id = 0,
    format: exportar.Format = .html,
    media: bool = false,
    /// Os dias (AAAAMMDD, hora local) que têm mensagens, e quantas em cada.
    days: std.ArrayList(i64) = .empty,
    counts: std.ArrayList(u32) = .empty,
    from_i: usize = 0,
    to_i: usize = 0,
    total: u32 = 0,
};
var dlg: Dlg = .{};

/// "Exportar conversa…": conta o que está no computador e abre a janela.
pub fn open(ctx: *d.Ctx, channel: Id) void {
    if (!available()) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const list = gather(ctx, arena.allocator(), channel, null);
    if (dlg.channel != channel) {
        dlg.format = .html;
        dlg.media = false;
    }
    dlg.channel = channel;
    dlg.days.clearRetainingCapacity();
    dlg.counts.clearRetainingCapacity();
    dlg.total = @intCast(list.len);
    // Os dias em ordem (a hora de uma mensagem nem sempre segue o ID à risca).
    const days = arena.allocator().alloc(i64, list.len) catch return;
    for (list, days) |l, *day| day.* = dayOf(l.unix);
    std.mem.sort(i64, days, {}, std.sort.asc(i64));
    for (days) |day| {
        if (dlg.days.items.len > 0 and dlg.days.items[dlg.days.items.len - 1] == day) {
            dlg.counts.items[dlg.counts.items.len - 1] += 1;
        } else {
            dlg.days.append(alloc, day) catch break;
            dlg.counts.append(alloc, 1) catch break;
        }
    }
    dlg.from_i = 0;
    dlg.to_i = if (dlg.days.items.len > 0) dlg.days.items.len - 1 else 0;
    ctx.st.popup = .{ .exportar = .{ .channel = channel } };
}

fn inRange() u32 {
    if (dlg.days.items.len == 0) return 0;
    var n: u32 = 0;
    for (dlg.counts.items[dlg.from_i .. dlg.to_i + 1]) |k| n += k;
    return n;
}

fn titleOf(ctx: *d.Ctx, buf: []u8, ch: *const types.Channel) []const u8 {
    if (ch.guild == 0) {
        if (!ch.group) if (ctx.store.user(ch.recipient)) |u| return u.name;
        return ch.name;
    }
    return std.fmt.bufPrint(buf, "#{s}", .{ch.name}) catch ch.name;
}

pub fn drawDialog(ctx: *d.Ctx, channel: Id) void {
    const cs = ctx.store.channel(channel) orelse return popup.close(ctx);
    const r = forum.dialogRect(ctx, 540, 470);
    const dl = popup.beginWindow("##exportar", r);
    defer c.ImGui_End();
    ctx.dl = dl;
    inbox.panelFrame(ctx, dl, r);
    qa.mark(r, "export-dialog", .{});
    const fam = ctx.ui;
    const bold = fam.get(.semibold);
    const x = r.x + 20;
    const wd = r.w - 40;
    _ = d.textClipped(dl, fam.get(.bold), 17, x, r.y + 16, ctx.col(.text), i18n.tr("Exportar conversa", "Export conversation"), wd);
    var tb: [160]u8 = undefined;
    var nb: [140]u8 = undefined;
    const gname = if (ctx.store.guild(cs.info.guild)) |g| g.name else i18n.tr("Mensagens diretas", "Direct Messages");
    _ = d.textClipped(dl, fam.get(.regular), 13, x, r.y + 42, ctx.col(.muted), d.printClip(&tb, "{s}  ·  {s}", .{ titleOf(ctx, &nb, &cs.info), gname }), wd);

    // O que está no computador, e como ter mais.
    var y = r.y + 72;
    const box: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 74 };
    d.rect(dl, box, ctx.col(.rail).mix(ctx.col(.surface), 0.3), @max(ctx.th.radius, 4));
    var ib: [256]u8 = undefined;
    var db: [16]u8 = undefined;
    const info = if (dlg.total == 0)
        i18n.tr("Nenhuma mensagem desta conversa está no computador ainda.", "None of this conversation's messages are on this computer yet.")
    else
        i18n.fmt(&ib, "{d} mensagens deste computador, desde {s}.", "{d} messages on this computer, since {s}.", .{ dlg.total, dayText(&db, dlg.days.items[0]) });
    qa.mark(box, "export-info:{d}", .{dlg.total});
    _ = d.textClipped(dl, bold, 13.5, box.x + 12, box.y + 9, ctx.col(.text), info, box.w - 24);
    _ = inbox.wrapText(dl, fam.get(.regular), 12.5, box.x + 12, box.y + 30, box.w - 24, i18n.tr("Para incluir mensagens mais antigas, role a conversa para cima antes de exportar. Nada é pedido ao Discord para exportar.", "To include older messages, scroll up in the conversation before exporting. Nothing is requested from Discord to export."), 2, ctx.col(.muted));
    y = box.bottom() + 16;

    // Formato.
    d.text(dl, bold, 11.5, x, y, ctx.col(.faint), i18n.tr("FORMATO", "FORMAT"));
    y += 20;
    const formats = [_]struct { f: exportar.Format, label: []const u8, mark: []const u8 }{ .{ .f = .html, .label = "HTML", .mark = "html" }, .{ .f = .markdown, .label = "Markdown", .mark = "markdown" }, .{ .f = .json, .label = "JSON", .mark = "json" } };
    const cw = (wd - 12) / 3;
    for (formats, 0..) |f, i| {
        const fr: d.Rect = .{ .x = x + @as(f32, @floatFromInt(i)) * (cw + 6), .y = y, .w = cw, .h = 28 };
        qa.mark(fr, "export-format:{s}", .{f.mark});
        if (invites.chip(ctx, dl, 0x7E00 + i, fr, f.label, dlg.format == f.f)) dlg.format = f.f;
    }
    y += 34;
    const fdesc = switch (dlg.format) {
        .html => i18n.tr("Uma página só, que abre sem internet, com as cores do tema.", "A single page that opens offline, in the theme's colors."),
        .markdown => i18n.tr("Texto com a formatação do Discord, bom para notas.", "Text with Discord's formatting, good for notes."),
        .json => i18n.tr("Dados estruturados (IDs, horas, anexos, respostas), para programas.", "Structured data (IDs, times, attachments, replies), for programs."),
    };
    _ = d.textClipped(dl, fam.get(.regular), 12.5, x, y, ctx.col(.muted), fdesc, wd);
    y += 26;

    // Período: entre os dias que têm mensagens no computador.
    d.text(dl, bold, 11.5, x, y, ctx.col(.faint), i18n.tr("PERÍODO", "DATE RANGE"));
    y += 20;
    const has_days = dlg.days.items.len > 0;
    const half = (wd - 16) / 2;
    stepper(ctx, dl, .{ .x = x, .y = y, .w = half, .h = 28 }, i18n.tr("De", "From"), "export-from", has_days, &dlg.from_i, 0, dlg.to_i);
    const last = if (has_days) dlg.days.items.len - 1 else 0;
    stepper(ctx, dl, .{ .x = x + half + 16, .y = y, .w = half, .h = 28 }, i18n.tr("Até", "To"), "export-to", has_days, &dlg.to_i, dlg.from_i, last);
    y += 34;
    const n_range = inRange();
    var rb: [96]u8 = undefined;
    const range_r: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 18 };
    qa.mark(range_r, "export-range:{d}", .{n_range});
    _ = d.textClipped(dl, fam.get(.regular), 12.5, x, y, ctx.col(.muted), i18n.fmt(&rb, "{d} mensagens no período", "{d} messages in this range", .{n_range}), wd);
    y += 26;

    // Mídia: desligada por padrão.
    const mr: d.Rect = .{ .x = x, .y = y, .w = wd, .h = 26 };
    const mh = d.hit(ctx, 0x7E10, mr);
    qa.mark(mr, "export-media", .{});
    if (mh.clicked) dlg.media = !dlg.media;
    const cb: d.Rect = .{ .x = mr.x, .y = mr.y + 4, .w = 18, .h = 18 };
    d.rect(dl, cb, if (dlg.media) ctx.col(.accent) else ctx.col(.rail).mix(ctx.col(.surface), 0.25), 4);
    d.border(dl, cb, if (dlg.media) ctx.col(.accent) else ctx.col(.border), 4, 1);
    if (dlg.media) {
        d.line(dl, cb.x + 4, cb.y + 9, cb.x + 8, cb.y + 13, ctx.col(.accent_text), 2);
        d.line(dl, cb.x + 8, cb.y + 13, cb.x + 14, cb.y + 5, ctx.col(.accent_text), 2);
    }
    _ = d.textClipped(dl, fam.get(.medium), 13.5, cb.right() + 8, d.centerY(mr, 13.5), ctx.col(.text), i18n.tr("Incluir imagens e arquivos que já estão no computador", "Include images and files already on this computer"), mr.w - 28);
    y += 28;
    _ = inbox.wrapText(dl, fam.get(.regular), 12, x + 26, y, wd - 26, i18n.tr("Numa pasta ao lado: as fotos de perfil e imagens que o app já baixou. Nada é baixado agora; o resto fica como link.", "In a folder next to it: profile pictures and images the app already downloaded. Nothing is downloaded now; the rest stays as links."), 2, ctx.col(.faint));

    // Botões.
    const running = export_job != null;
    const go_lbl = i18n.tr("Exportar…", "Export…");
    const gw = d.width(bold, 13.5, go_lbl) + 36;
    const br: d.Rect = .{ .x = r.right() - 20 - gw, .y = r.bottom() - 50, .w = gw, .h = 34 };
    qa.mark(br, "export-go", .{});
    const can = n_range > 0 and !running;
    if (forum.primary(ctx, dl, fam, 0x7E11, br, go_lbl, can) and can) {
        pending = .{ .export_ = .{ .channel = channel, .format = dlg.format, .media = dlg.media, .from_day = dlg.days.items[dlg.from_i], .to_day = dlg.days.items[dlg.to_i] } };
        var sb: [200]u8 = undefined;
        var safe: [200]u8 = undefined;
        const base = std.fmt.bufPrint(&sb, "{s}-{s}{s}", .{ cs.info.name, dayText(&db, dlg.days.items[dlg.to_i]), dlg.format.ext() }) catch "conversa.html";
        requestPath(ctx, salvar.sanitizeName(&safe, base, "conversa.html"), dlg.format.ext());
        return popup.close(ctx);
    }
    const close_lbl = i18n.tr("Cancelar", "Cancel");
    const cwb = inbox.buttonWidth(ctx, close_lbl);
    const cr: d.Rect = .{ .x = br.x - cwb - 10, .y = br.y + 3, .w = cwb, .h = 28 };
    qa.mark(cr, "export-cancel", .{});
    if (inbox.button(ctx, dl, 0x7E12, cr, close_lbl, false)) return popup.close(ctx);
    if (running) _ = d.textClipped(dl, fam.get(.regular), 12, x, d.centerY(br, 12), ctx.col(.faint), i18n.tr("Já tem uma exportação andando.", "An export is already running."), cr.x - x - 10);
}

/// "De ‹ 2026-11-12 ›": anda pelos dias que têm mensagens, entre `lo` e `hi`.
fn stepper(ctx: *d.Ctx, dl: *c.ImDrawList, r: d.Rect, label: []const u8, comptime mark: []const u8, on: bool, idx: *usize, lo: usize, hi: usize) void {
    const fam = ctx.ui;
    const lw = d.width(fam.get(.medium), 13, label) + 10;
    d.text(dl, fam.get(.medium), 13, r.x, d.centerY(r, 13), ctx.col(.muted), label);
    const inner: d.Rect = .{ .x = r.x + lw, .y = r.y, .w = r.w - lw, .h = r.h };
    d.rect(dl, inner, ctx.col(.rail).mix(ctx.col(.surface), 0.25), @max(ctx.th.radius, 4));
    d.border(dl, inner, ctx.col(.border), @max(ctx.th.radius, 4), 1);
    var db: [16]u8 = undefined;
    const txt = if (on) dayText(&db, dlg.days.items[idx.*]) else "—";
    const f = fam.get(.semibold);
    d.text(dl, f, 13, inner.x + (inner.w - d.width(f, 13, txt)) / 2, d.centerY(inner, 13), ctx.col(.text), txt);
    const prev: d.Rect = .{ .x = inner.x, .y = inner.y, .w = 28, .h = inner.h };
    const next: d.Rect = .{ .x = inner.right() - 28, .y = inner.y, .w = 28, .h = inner.h };
    qa.mark(prev, mark ++ "-prev", .{});
    qa.mark(next, mark ++ "-next", .{});
    const ph = d.hit(ctx, @intFromPtr(idx) +% 1, prev);
    const nh = d.hit(ctx, @intFromPtr(idx) +% 2, next);
    const can_prev = on and idx.* > lo;
    const can_next = on and idx.* < hi;
    d.text(dl, f, 15, prev.x + 10, d.centerY(prev, 15), if (can_prev and ph.hovered) ctx.col(.text) else if (can_prev) ctx.col(.muted) else ctx.col(.faint).alpha(0.5), "‹");
    d.text(dl, f, 15, next.x + 10, d.centerY(next, 15), if (can_next and nh.hovered) ctx.col(.text) else if (can_next) ctx.col(.muted) else ctx.col(.faint).alpha(0.5), "›");
    if (ph.clicked and can_prev) idx.* -= 1;
    if (nh.clicked and can_next) idx.* += 1;
}

// --- Escolher o arquivo ------------------------------------------------------------------

const SaveReq = struct {
    pick: salvar.Pick,
    url: [2048]u8 = undefined,
    fallback: [2048]u8 = undefined,
    name: [256]u8 = undefined,

    fn set(r: *SaveReq, p: salvar.Pick) void {
        r.pick = p;
        r.pick.url = copyInto(&r.url, p.url);
        r.pick.fallback = copyInto(&r.fallback, p.fallback);
        r.pick.name = copyInto(&r.name, p.name);
    }
};

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = d.utf8Prefix(s, buf.len).len;
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

const ExportReq = struct { channel: Id, format: exportar.Format, media: bool, from_day: i64, to_day: i64 };

/// Para que é o arquivo que o seletor está escolhendo.
var pending: union(enum) { none, export_: ExportReq, save: void } = .none;
var pending_save: SaveReq = .{ .pick = .{ .url = "", .name = "" } };

/// O nome sugerido e o filtro do próximo seletor (o app abre: ver `showDialog`).
var suggest_buf: [256]u8 = undefined;
var suggest_len: usize = 0;
var ext_buf: [16]u8 = undefined;
var ext_len: usize = 0;

/// QA: o "seletor" responde com este caminho (null = cancelou). Nada abre.
pub var qa_answer: ?[]const u8 = null;
pub var qa_dialogs: u32 = 0;
pub var qa_suggested: [256]u8 = undefined;
pub var qa_suggested_len: usize = 0;

fn requestPath(ctx: *d.Ctx, name: []const u8, ext: []const u8) void {
    suggest_len = copyInto(&suggest_buf, name).len;
    ext_len = copyInto(&ext_buf, ext).len;
    ctx.act(.save_dialog);
}

/// A resposta do seletor (vem de outra thread no Linux com portal).
var answer_mutex: ?*c.SDL_Mutex = null;
var answer_buf: [1100]u8 = undefined;
var answer_len: usize = 0;
var answer_state: enum { none, path, cancelled } = .none;

fn putAnswer(path: ?[]const u8) void {
    if (answer_mutex == null) answer_mutex = c.SDL_CreateMutex();
    c.SDL_LockMutex(answer_mutex);
    defer c.SDL_UnlockMutex(answer_mutex);
    if (path) |p| {
        answer_len = copyInto(&answer_buf, p).len;
        answer_state = .path;
    } else answer_state = .cancelled;
}

fn dialogCb(_: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    putAnswer(if (list != null and list[0] != null) std.mem.span(list[0]) else null);
    dialog_open.store(false, .release);
    wakeUi();
}

/// O que o seletor do sistema usa até responder (o SDL pede que os filtros
/// continuem valendo até a resposta): por isso fora da pilha, e um seletor por vez.
var dlg_location: [900:0]u8 = undefined;
var dlg_pattern: [16:0]u8 = undefined;
var dlg_filters: [2]c.SDL_DialogFileFilter = undefined;
var dialog_open: std.atomic.Value(bool) = .init(false);

/// O app abre o seletor de "salvar como" (Action.save_dialog). No QA não abre nada:
/// responde com `qa_answer`.
pub fn showDialog(window: ?*c.SDL_Window, qa_mode: bool) void {
    const name = suggest_buf[0..suggest_len];
    if (qa_mode) {
        qa_dialogs += 1;
        qa_suggested_len = copyInto(&qa_suggested, name).len;
        putAnswer(qa_answer);
        return;
    }
    if (dialog_open.load(.acquire)) return;
    // Começa na Downloads, com o nome sugerido.
    var db: [600]u8 = undefined;
    const loc: ?[*:0]const u8 = if (pastas.downloads(&db)) |dir| (if (std.fmt.bufPrintSentinel(&dlg_location, "{s}/{s}", .{ dir, name }, 0)) |z| z.ptr else |_| null) else null;
    const ext = ext_buf[0..ext_len];
    const pattern = std.fmt.bufPrintSentinel(&dlg_pattern, "{s}", .{if (ext.len > 1) ext[1..] else "*"}, 0) catch "*";
    dlg_filters = .{ .{ .name = pattern.ptr, .pattern = pattern.ptr }, .{ .name = i18n.trZ("Todos os arquivos", "All files").ptr, .pattern = "*" } };
    dialog_open.store(true, .release);
    c.SDL_ShowSaveFileDialog(dialogCb, null, window, &dlg_filters, dlg_filters.len, loc);
}

/// Uma vez por quadro: a resposta do seletor, o fim dos trabalhos.
pub fn frame(ctx: *d.Ctx) void {
    if (!available()) return;
    takeAnswer(ctx);
    pollJobs(ctx);
}

fn takeAnswer(ctx: *d.Ctx) void {
    if (answer_mutex == null) return;
    var pb: [1100]u8 = undefined;
    var got: ?[]const u8 = null;
    c.SDL_LockMutex(answer_mutex);
    const st = answer_state;
    if (st == .path) got = copyInto(&pb, answer_buf[0..answer_len]);
    answer_state = .none;
    c.SDL_UnlockMutex(answer_mutex);
    if (st == .none) return;
    const what = pending;
    pending = .none;
    const path_in = got orelse return;
    // Sem extensão (o seletor deixa digitar só o nome): a do formato.
    var eb: [1100]u8 = undefined;
    const ext = switch (what) {
        .export_ => |e| e.format.ext(),
        .save => salvar.extOf(pending_save.pick.name),
        .none => "",
    };
    const base = path_in[if (std.mem.lastIndexOfAny(u8, path_in, "/\\")) |k| k + 1 else 0..];
    const path = if (ext.len > 0 and salvar.extOf(base).len == 0) std.fmt.bufPrint(&eb, "{s}{s}", .{ path_in, ext }) catch path_in else path_in;
    switch (what) {
        .export_ => |e| startExport(ctx, e, path),
        .save => startSave(ctx, &pending_save.pick, path, false),
        .none => {},
    }
}

// --- Exportar ------------------------------------------------------------------------------

var export_job: ?*job_mod.Job = null;
var save_job: ?*job_mod.SaveJob = null;
var save_to_downloads = false;

/// O cartão de cima: andamento e resultado.
const Card = struct {
    text: [320]u8 = undefined,
    len: usize = 0,
    path: [1100]u8 = undefined,
    path_len: usize = 0,
    is_error: bool = false,
    /// Some sozinho nessa hora (0 = enquanto o trabalho roda, ou não há cartão).
    until_ms: i64 = 0,
    shown: bool = false,

    fn set(k: *Card, comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
        k.len = i18n.fmt(&k.text, pt, en, args).len;
    }
};
var export_card: Card = .{};
var save_card: Card = .{};

/// Fechando o app: cancela e espera quem está escrevendo (nada fica pela metade:
/// o arquivo ainda é um .part, que o cancelar apaga).
pub fn shutdown() void {
    if (export_job) |j| {
        j.cancel();
        j.destroy();
        export_job = null;
    }
    if (save_job) |j| {
        j.cancel();
        j.destroy();
        save_job = null;
    }
}

/// Exportação ou gravação andando (o QA espera acabar).
pub fn busy() bool {
    return export_job != null or save_job != null;
}

fn startExport(ctx: *d.Ctx, req: ExportReq, path: []const u8) void {
    if (export_job != null) return;
    const plan = buildPlan(ctx, req, path) orelse {
        export_card = .{ .is_error = true, .until_ms = ctx.now_ms + 8000, .shown = true };
        export_card.set("não deu para preparar a exportação", "couldn't prepare the export", .{});
        return;
    };
    export_job = job_mod.start(plan, &wakeUi) orelse {
        var p = plan;
        p.arena.deinit();
        export_card = .{ .is_error = true, .until_ms = ctx.now_ms + 8000, .shown = true };
        export_card.set("não deu para começar a exportação", "couldn't start the export", .{});
        return;
    };
    export_card = .{ .shown = true };
    export_card.path_len = copyInto(&export_card.path, path).len;
}

/// Monta o retrato da conversa para a thread (cópias: o Store continua mudando).
fn buildPlan(ctx: *d.Ctx, req: ExportReq, path_in: []const u8) ?job_mod.Plan {
    const cs = ctx.store.channel(req.channel) orelse return null;
    var arena = std.heap.ArenaAllocator.init(alloc);
    var built = false;
    defer if (!built) arena.deinit();
    const a = arena.allocator();
    var users: []const @import("../core/cache_format.zig").User = &.{};
    const all = gather(ctx, a, req.channel, &users);
    const guild = cs.info.guild;

    const path = a.dupeSentinel(u8, path_in, 0) catch return null;
    // A pasta da mídia: "<nome>_arquivos" ao lado do documento.
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\");
    const stem_end = if (slash != null and dot < slash.?) path.len else dot;
    const media_dir = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ path[0..stem_end], i18n.tr("_arquivos", "_files") }, 0) catch return null;
    const media_rel = media_dir[if (slash) |k| k + 1 else 0..];

    var msgs: std.ArrayList(exportar.Msg) = .empty;
    var media: std.ArrayList(job_mod.MediaItem) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var authors: std.ArrayList(Id) = .empty;
    var index: std.AutoHashMapUnmanaged(Id, usize) = .empty;
    defer index.deinit(alloc);
    for (all) |l| {
        const day = dayOf(l.unix);
        if (day < req.from_day or day > req.to_day) continue;
        const m: *const types.Message = if (l.mem) |sm| &sm.msg else &l.cached.?.msg;
        const reacts_src: []const types.Reaction = if (l.mem) |sm| sm.reactionSlice() else l.cached.?.reactions[0..l.cached.?.n_reactions];
        const i: u32 = @intCast(msgs.items.len);
        var out: exportar.Msg = .{ .id = m.id, .unix = m.timestamp, .author = m.author, .name = "", .edited = m.edited, .pinned = m.pinned, .system = m.system != .none };
        const u = ctx.store.user(m.author);
        out.name = a.dupe(u8, ctx.store.nameIn(guild, m.author) orelse cachedName(users, m.author) orelse "?") catch return null;
        out.bot = if (u) |x| x.bot or x.webhook else cachedBot(users, m.author);
        out.text = resolved(ctx, a, guild, m.content) catch return null;
        out.raw = a.dupe(u8, m.editable()) catch return null;
        out.reply_to = m.reply_to;
        // Anexos (e as imagens que vieram de links), com o original de cada um.
        var atts: std.ArrayList(exportar.Att) = .empty;
        for (m.attachments) |*at| {
            var pb: salvar.PickBuf = .{};
            const p = salvar.ofAttachment(&pb, at);
            const kind: exportar.AttKind = if (at.voice) .audio else if (at.video) .video else if (reply_preview.isSticker(at)) .sticker else if (at.isImage()) (if (at.animated) .gif else .image) else .file;
            atts.append(a, .{ .name = a.dupe(u8, at.filename) catch return null, .url = a.dupe(u8, if (std.mem.startsWith(u8, p.url, "https://")) p.url else "") catch return null, .size = at.size, .w = at.width, .h = at.height, .kind = kind, .spoiler = at.spoiler }) catch return null;
            if (req.media) addMedia(a, &media, &used, media_rel, p, .{ .att = .{ .msg = i, .i = @intCast(atts.items.len - 1) } }) catch return null;
        }
        var embeds: std.ArrayList(exportar.Emb) = .empty;
        for (m.embeds) |*e| {
            var fields: std.ArrayList(exportar.Field) = .empty;
            for (e.fields) |f| fields.append(a, .{ .name = a.dupe(u8, f.name) catch return null, .value = resolved(ctx, a, guild, f.value) catch return null }) catch return null;
            // Os componentes de um bot: o texto dos blocos, a mídia como anexo, os links.
            var desc: std.ArrayList(u8) = .empty;
            desc.appendSlice(a, resolved(ctx, a, guild, e.description) catch return null) catch return null;
            for (e.blocks) |*b| {
                switch (b.kind) {
                    .text => {
                        if (desc.items.len > 0) desc.appendSlice(a, "\n") catch {};
                        desc.appendSlice(a, resolved(ctx, a, guild, b.text) catch return null) catch {};
                    },
                    .buttons => for (b.media) |it| if (it.link.len > 0) {
                        if (desc.items.len > 0) desc.appendSlice(a, "\n") catch {};
                        desc.print(a, "[{s}]({s})", .{ it.label, it.link }) catch {};
                    },
                    else => {},
                }
                if (b.kind == .gallery or b.kind == .file or b.kind == .text) for (b.media) |*it| {
                    if (it.url.len == 0 and it.link.len == 0) continue;
                    var pb: salvar.PickBuf = .{};
                    const p = salvar.ofBlockMedia(&pb, it);
                    const kind: exportar.AttKind = if (it.video) .video else if (it.w > 0) .image else .file;
                    atts.append(a, .{ .name = a.dupe(u8, p.name) catch return null, .url = a.dupe(u8, if (std.mem.startsWith(u8, p.url, "https://")) p.url else "") catch return null, .size = it.size, .w = it.w, .h = it.h, .kind = kind, .spoiler = it.spoiler }) catch return null;
                    if (req.media) addMedia(a, &media, &used, media_rel, p, .{ .att = .{ .msg = i, .i = @intCast(atts.items.len - 1) } }) catch return null;
                };
            }
            embeds.append(a, .{
                .title = a.dupe(u8, e.title) catch return null,
                .url = a.dupe(u8, e.url) catch return null,
                .description = desc.items,
                .author = a.dupe(u8, e.author) catch return null,
                .provider = a.dupe(u8, e.provider) catch return null,
                .footer = a.dupe(u8, e.footer) catch return null,
                .color = if (e.has_color) e.color else null,
                .fields = fields.items,
                .image = a.dupe(u8, if (std.mem.startsWith(u8, e.image, "https://")) e.image else "") catch return null,
                .thumb = a.dupe(u8, if (std.mem.startsWith(u8, e.thumb, "https://")) e.thumb else "") catch return null,
                .video = a.dupe(u8, if (std.mem.startsWith(u8, e.video_url, "https://")) e.video_url else "") catch return null,
            }) catch return null;
            if (req.media and e.image.len > 0) {
                var pb: salvar.PickBuf = .{};
                addMedia(a, &media, &used, media_rel, salvar.ofEmbedImage(&pb, e), .{ .emb = .{ .msg = i, .i = @intCast(embeds.items.len - 1) } }) catch return null;
            }
        }
        out.atts = atts.items;
        out.embeds = embeds.items;
        var reacts: std.ArrayList(exportar.React) = .empty;
        for (reacts_src) |*r| {
            const emoji = if (r.custom != 0) std.fmt.allocPrint(a, ":{s}:", .{r.text()}) catch return null else a.dupe(u8, r.text()) catch return null;
            reacts.append(a, .{ .emoji = emoji, .count = r.count }) catch return null;
        }
        out.reacts = reacts.items;
        index.put(alloc, m.id, msgs.items.len) catch {};
        msgs.append(a, out) catch return null;
        if (!out.system and std.mem.indexOfScalar(Id, authors.items, m.author) == null) authors.append(a, m.author) catch {};
    }
    // Respostas: o autor e o começo da original, quando ela também foi exportada
    // (ou ainda está na memória).
    for (msgs.items) |*m| if (m.reply_to != 0) {
        if (index.get(m.reply_to)) |k| {
            m.reply_name = msgs.items[k].name;
            m.reply_text = excerpt(msgs.items[k].text);
        } else if (ctx.store.findAny(m.reply_to)) |f| {
            m.reply_name = a.dupe(u8, ctx.store.nameIn(guild, f.m.msg.author) orelse "?") catch "";
            m.reply_text = excerpt(resolved(ctx, a, guild, f.m.msg.content) catch "");
        }
    };
    // Fotos de perfil: embutidas quando já estão no computador; com a mídia ligada,
    // vão para a pasta (as que não estiverem ficam com a inicial, como os anexos
    // que ficam como link: nada é baixado).
    var avatars: std.ArrayList(exportar.Avatar) = .empty;
    var local: std.ArrayList(u8) = .empty;
    defer local.deinit(alloc);
    for (authors.items) |uid| {
        var ub: [256]u8 = undefined;
        const url = avatarUrl(ctx, &ub, guild, uid, users);
        if (url.len == 0) continue;
        const k: u32 = @intCast(avatars.items.len);
        avatars.append(a, .{ .user = uid }) catch return null;
        if (req.media) {
            var nb: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&nb, "avatar-{d}{s}", .{ uid, if (salvar.urlExt(url).len > 0) salvar.urlExt(url) else ".png" }) catch continue;
            addMedia(a, &media, &used, media_rel, .{ .url = url, .name = name }, .{ .avatar = k }) catch return null;
            continue;
        }
        local.clearRetainingCapacity();
        if (!localBytes(url, &local)) continue;
        avatars.items[k].data = a.dupe(u8, local.items) catch continue;
        avatars.items[k].mime = mimeOf(local.items);
    }

    var tb: [160]u8 = undefined;
    const title = a.dupe(u8, titleOf(ctx, &tb, &cs.info)) catch return null;
    const gname: []const u8 = if (ctx.store.guild(guild)) |g| g.name else "";
    const n: u32 = @intCast(msgs.items.len);
    const first: i64 = if (n > 0) msgs.items[0].unix else 0;
    const last: i64 = if (n > 0) msgs.items[n - 1].unix else 0;
    var fb: [16]u8 = undefined;
    var lb: [16]u8 = undefined;
    const place = if (gname.len > 0) gname else if (cs.info.group) i18n.tr("Grupo", "Group") else i18n.tr("Mensagem direta", "Direct message");
    const subtitle = i18n.allocPrint(a, "{s} · {d} mensagens deste computador, de {s} a {s}", "{s} · {d} messages from this computer, {s} to {s}", .{ place, n, dayText(&fb, dayOf(first)), dayText(&lb, dayOf(last)) }) catch return null;
    var now_ns: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&now_ns);
    const now_s: i64 = @divTrunc(now_ns, std.time.ns_per_s);
    var nowb: [16]u8 = undefined;
    const p_now = localClock(now_s);
    const footer = i18n.allocPrint(a, "Exportado pelo larperCord {s} em {s} {d:0>2}:{d:0>2}.", "Exported by larperCord {s} on {s} {d:0>2}:{d:0>2}.", .{ version.number, dayText(&nowb, dayOf(now_s)), p_now.hour, p_now.minute }) catch return null;
    const t = ctx.th;
    const hex = struct {
        fn f(col: d.Rgba) u32 {
            const r: u32 = @intFromFloat(std.math.clamp(col.r, 0, 1) * 255 + 0.5);
            const g: u32 = @intFromFloat(std.math.clamp(col.g, 0, 1) * 255 + 0.5);
            const b: u32 = @intFromFloat(std.math.clamp(col.b, 0, 1) * 255 + 0.5);
            return r << 16 | g << 8 | b;
        }
    }.f;
    built = true;
    return .{
        .arena = arena,
        .format = req.format,
        .header = .{
            .title = title,
            .subtitle = subtitle,
            .note = i18n.tr("Só as mensagens que estavam neste computador: nada foi pedido ao Discord para exportar.", "Only the messages that were on this computer: nothing was requested from Discord to export."),
            .footer = footer,
            .lang = switch (i18n.current()) {
                .pt => "pt-BR",
                .en => "en",
                .ja => "ja",
                .ru => "ru",
            },
            .conversation = .{
                .id = req.channel,
                .name = a.dupe(u8, cs.info.name) catch return null,
                .kind = if (cs.info.thread != null) "thread" else if (guild == 0) (if (cs.info.group) "group" else "dm") else "text",
                .guild_id = guild,
                .guild_name = a.dupe(u8, gname) catch return null,
            },
            .exported_unix = now_s,
            .from_unix = first,
            .to_unix = last,
            .count = n,
            .media = req.media,
            .app = "larperCord " ++ version.number,
            .colors = .{ .bg = hex(t.c(.bg)), .surface = hex(t.c(.surface)), .elevated = hex(t.c(.elevated)), .text = hex(t.c(.text)), .muted = hex(t.c(.muted)), .faint = hex(t.c(.faint)), .accent = hex(t.c(.accent)), .link = hex(t.c(.link)), .border = hex(t.c(.border)), .code_bg = hex(t.c(.code_bg)), .danger = hex(t.c(.danger)) },
        },
        .labels = .{
            .edited = i18n.tr("(editada)", "(edited)"),
            .pinned = i18n.tr("fixada", "pinned"),
            .reply_missing = i18n.tr("mensagem anterior (não está neste arquivo)", "earlier message (not in this file)"),
            .bot = i18n.tr("BOT", "BOT"),
            .image = i18n.tr("imagem", "image"),
            .video = i18n.tr("vídeo", "video"),
            .spoiler = i18n.tr("spoiler", "spoiler"),
        },
        .msgs = msgs.items,
        .avatars = avatars.items,
        .media = media.items,
        .path = path,
        .media_dir = if (media.items.len > 0) media_dir else "",
        .clock = &localClock,
    };
}

/// Um arquivo para a pasta ao lado (se estiver no computador), com um nome que não
/// repete (o Windows não separa maiúscula de minúscula: "Foto.png" e "foto.png"
/// seriam o mesmo).
fn addMedia(a: std.mem.Allocator, media: *std.ArrayList(job_mod.MediaItem), used: *std.StringHashMapUnmanaged(void), rel_dir: []const u8, p: salvar.Pick, where: @FieldType(job_mod.MediaItem, "target")) !void {
    if (p.url.len == 0) return;
    var sb: [256]u8 = undefined;
    const base = salvar.sanitizeName(&sb, p.name, i18n.tr("arquivo", "file"));
    const ext = salvar.extOf(base);
    var nb: [300]u8 = undefined;
    var name: []const u8 = base;
    var k: u32 = 1;
    while (true) : (k += 1) {
        var low: [300]u8 = undefined;
        const key = std.ascii.lowerString(&low, name);
        if (!used.contains(key)) {
            try used.put(a, try a.dupe(u8, key), {});
            break;
        }
        name = std.fmt.bufPrint(&nb, "{s} ({d}){s}", .{ base[0 .. base.len - ext.len], k, ext }) catch return;
    }
    try media.append(a, .{ .url = try a.dupe(u8, p.url), .rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, name }), .target = where });
}

fn cachedName(users: []const @import("../core/cache_format.zig").User, id: Id) ?[]const u8 {
    for (users) |u| if (u.id == id) return u.name;
    return null;
}

fn cachedBot(users: []const @import("../core/cache_format.zig").User, id: Id) bool {
    for (users) |u| if (u.id == id) return u.bot or u.webhook;
    return false;
}

fn avatarUrl(ctx: *d.Ctx, buf: []u8, guild: Id, uid: Id, users: []const @import("../core/cache_format.zig").User) []const u8 {
    if (ctx.store.user(uid) != null) return widgets.avatarUrl(ctx, buf, guild, uid);
    for (users) |u| if (u.id == uid and u.avatar.len > 0) return widgets.cdnUrl(buf, .avatar, uid, u.avatar);
    return "";
}

fn mimeOf(data: []const u8) []const u8 {
    if (std.mem.startsWith(u8, data, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, data, "\xff\xd8")) return "image/jpeg";
    if (std.mem.startsWith(u8, data, "GIF8")) return "image/gif";
    if (data.len > 12 and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    return "image/png";
}

/// O começo de um texto, numa linha, para a prévia da resposta.
fn excerpt(text: []const u8) []const u8 {
    const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return d.utf8Prefix(line, 120);
}

/// O texto com as menções trocadas pelos nomes de agora (como a tela mostra).
fn resolved(ctx: *d.Ctx, a: std.mem.Allocator, guild: Id, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '<') == null) return a.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    const Ctx = struct { ctx: *d.Ctx, guild: Id };
    try exportar.resolveTokens(&out, a, text, Ctx{ .ctx = ctx, .guild = guild }, struct {
        fn label(k: Ctx, t: exportar.Token, buf: []u8) ?[]const u8 {
            const store = k.ctx.store;
            return switch (t) {
                .user => |id| std.fmt.bufPrint(buf, "@{s}", .{store.nameIn(k.guild, id) orelse i18n.tr("desconhecido", "unknown-user")}) catch null,
                .channel => |id| std.fmt.bufPrint(buf, "#{s}", .{if (store.channel(id)) |ch| ch.info.name else i18n.tr("canal", "unknown")}) catch null,
                .role => |id| std.fmt.bufPrint(buf, "@{s}", .{if (store.roles.get(id)) |r| r.name else i18n.tr("cargo", "unknown-role")}) catch null,
                .stamp => |s| rich.stampText(buf, @as(u64, @intCast(s.unix)) << 8 | s.style),
                .emoji => |name| std.fmt.bufPrint(buf, ":{s}:", .{name}) catch null,
            };
        }
    }.label);
    return out.items;
}

// --- Salvar mídia ----------------------------------------------------------------------------

/// O que o botão direito na mídia escolheu: vale só para o menu aberto daquele
/// clique (a mesma mensagem e o mesmo ponto).
const Target = struct { msg: Id = 0, x: f32 = 0, y: f32 = 0, req: SaveReq = .{ .pick = .{ .url = "", .name = "" } } };
var target: Target = .{};

/// Botão direito numa imagem, vídeo ou arquivo: o menu da mensagem com "Salvar…".
pub fn mediaMenu(ctx: *d.Ctx, msg: Id, p: salvar.Pick) void {
    if (available() and p.url.len > 0) {
        target.msg = msg;
        target.x = ctx.mouse.x;
        target.y = ctx.mouse.y;
        target.req.set(p);
    } else target.msg = 0;
    ctx.popup(.{ .menu = .{ .kind = .message, .id = msg, .x = ctx.mouse.x, .y = ctx.mouse.y } });
}

/// O menu da mensagem `msg` aberto em (x, y) veio de um clique na mídia?
pub fn menuTarget(msg: Id, x: f32, y: f32) bool {
    return target.msg != 0 and target.msg == msg and target.x == x and target.y == y;
}

/// "Salvar…": o seletor do sistema com o nome sugerido.
pub fn saveAsTarget(ctx: *d.Ctx) void {
    saveAs(ctx, target.req.pick);
}

/// "Salvar em Downloads".
pub fn saveTargetToDownloads(ctx: *d.Ctx) void {
    saveToDownloads(ctx, &target.req.pick);
}

pub fn saveAs(ctx: *d.Ctx, p: salvar.Pick) void {
    if (!available()) return;
    pending_save.set(p);
    pending = .{ .save = {} };
    var sb: [256]u8 = undefined;
    const name = salvar.sanitizeName(&sb, p.name, i18n.tr("arquivo", "file"));
    requestPath(ctx, name, salvar.extOf(name));
}

pub fn saveToDownloads(ctx: *d.Ctx, p: *const salvar.Pick) void {
    if (!available()) return;
    var db: [600]u8 = undefined;
    const dir = pastas.downloads(&db) orelse {
        save_card = .{ .is_error = true, .until_ms = ctx.now_ms + 8000, .shown = true };
        save_card.set("não achei a pasta Downloads", "couldn't find the Downloads folder", .{});
        return;
    };
    var sb: [256]u8 = undefined;
    const name = salvar.sanitizeName(&sb, p.name, i18n.tr("arquivo", "file"));
    var pb: [1100]u8 = undefined;
    const path = salvar.uniquePath(&pb, dir, name, {}, struct {
        fn f(_: void, z: [:0]const u8) bool {
            return sys.exists(z.ptr);
        }
    }.f) orelse return;
    startSave(ctx, p, path, true);
}

fn startSave(ctx: *d.Ctx, p: *const salvar.Pick, path: []const u8, downloads: bool) void {
    if (save_job != null) {
        save_card.until_ms = 0;
        return ctx.st.showToast(ctx.now_ms, false, "espere o arquivo anterior terminar de salvar", "wait for the previous file to finish saving", .{});
    }
    // Já está no computador (a imagem que a conversa baixou do CDN, o vídeo aberto):
    // é só gravar.
    var local: std.ArrayList(u8) = .empty;
    const have = video.originalBytes(p.url, &local) or localBytes(p.url, &local);
    const bytes: []u8 = if (have) (local.toOwnedSlice(alloc) catch &.{}) else &.{};
    if (!have) local.deinit(alloc);
    save_job = job_mod.startSave(p.*, path, bytes, &wakeUi) orelse {
        if (bytes.len > 0) alloc.free(bytes);
        save_card = .{ .is_error = true, .until_ms = ctx.now_ms + 8000, .shown = true };
        save_card.set("não deu para salvar", "couldn't save", .{});
        return;
    };
    save_to_downloads = downloads;
    save_card = .{ .shown = true };
    save_card.path_len = copyInto(&save_card.path, path).len;
}

fn baseName(path: []const u8) []const u8 {
    return path[if (std.mem.lastIndexOfAny(u8, path, "/\\")) |k| k + 1 else 0..];
}

fn pollJobs(ctx: *d.Ctx) void {
    if (export_job) |j| if (j.finished()) {
        const phase = j.phase.load(.acquire);
        const ok_files = j.media_ok.load(.acquire);
        const failed = j.media_failed.load(.acquire);
        j.destroy();
        export_job = null;
        const k = &export_card;
        k.until_ms = ctx.now_ms + 12_000;
        k.is_error = phase != .done;
        const name = baseName(k.path[0..k.path_len]);
        switch (phase) {
            // Os que ficaram como link não estavam no computador (nada é baixado).
            .done => if (failed > 0 and ok_files > 0)
                k.set("Conversa exportada: {s} · {d} arquivos na pasta ao lado, {d} ficaram como link", "Conversation exported: {s} · {d} files in the folder next to it, {d} stayed as links", .{ name, ok_files, failed })
            else if (failed > 0)
                k.set("Conversa exportada: {s} · {d} arquivos ficaram como link", "Conversation exported: {s} · {d} files stayed as links", .{ name, failed })
            else if (ok_files > 0)
                k.set("Conversa exportada: {s} · {d} arquivos na pasta ao lado", "Conversation exported: {s} · {d} files in the folder next to it", .{ name, ok_files })
            else
                k.set("Conversa exportada: {s}", "Conversation exported: {s}", .{name}),
            .cancelled => {
                k.is_error = false;
                k.until_ms = ctx.now_ms + 4000;
                k.set("Exportação cancelada", "Export cancelled", .{});
            },
            else => k.set("Não deu para exportar (sem espaço ou sem permissão na pasta?)", "Couldn't export (no space or no permission in that folder?)", .{}),
        }
        if (phase != .done) k.path_len = 0;
    };
    if (save_job) |j| if (j.finished()) {
        const phase = j.phase.load(.acquire);
        const fallback = j.used_fallback;
        const too_big = j.too_big;
        j.destroy();
        save_job = null;
        const k = &save_card;
        k.until_ms = ctx.now_ms + 10_000;
        k.is_error = phase != .done;
        const name = baseName(k.path[0..k.path_len]);
        switch (phase) {
            .done => if (fallback)
                k.set("Salvo: {s} (a prévia; para o GIF original, ligue Configurações → Privacidade → Animar GIFs do Tenor e do Giphy)", "Saved: {s} (the preview; for the original GIF, turn on Settings → Privacy → Animate Tenor and Giphy GIFs)", .{name})
            else if (save_to_downloads)
                k.set("Salvo em Downloads: {s}", "Saved to Downloads: {s}", .{name})
            else
                k.set("Salvo: {s}", "Saved: {s}", .{name}),
            .cancelled => {
                k.is_error = false;
                k.until_ms = ctx.now_ms + 4000;
                k.set("Cancelado", "Cancelled", .{});
            },
            else => if (too_big)
                k.set("Arquivo grande demais para salvar daqui (mais de 500 MB)", "File too big to save from here (over 500 MB)", .{})
            else
                k.set("Não deu para salvar {s}", "Couldn't save {s}", .{name}),
        }
        if (phase != .done) k.path_len = 0;
    };
}

// --- O cartão de andamento -----------------------------------------------------------------

/// Por cima de tudo, no topo: o andamento (com cancelar) e, no fim, abrir o arquivo
/// ou a pasta.
pub fn cards(ctx: *d.Ctx) void {
    if (!available()) return;
    card_on = .{ false, false };
    var y = ctx.win.y + 56;
    y = card(ctx, &export_card, export_job != null, y, 0);
    _ = card(ctx, &save_card, save_job != null, y, 1);
}

/// Onde os cartões estão (o visualizador não fecha com um clique neles).
var card_rect: [2]d.Rect = undefined;
var card_on: [2]bool = .{ false, false };

pub fn overCard(x: f32, y: f32) bool {
    for (card_rect, card_on) |r, on| if (on and r.contains(x, y)) return true;
    return false;
}

fn card(ctx: *d.Ctx, k: *Card, running: bool, y: f32, which: u8) f32 {
    if (!k.shown) return y;
    if (!running and k.until_ms != 0 and ctx.now_ms >= k.until_ms) {
        k.shown = false;
        return y;
    }
    if (!running and k.until_ms != 0) anim.at(k.until_ms);
    // O texto do andamento muda a cada arquivo e a cada mensagem.
    var tb: [320]u8 = undefined;
    const text: []const u8 = if (running) progressText(&tb, which) else k.text[0..k.len];
    const fam = ctx.ui;
    const font = fam.get(.semibold);
    const fs: f32 = 13.5;
    const labels: [3][]const u8 = if (running)
        .{ i18n.tr("Cancelar", "Cancel"), "", "" }
    else if (k.path_len > 0)
        .{ i18n.tr("Abrir", "Open"), i18n.tr("Abrir pasta", "Open folder"), "×" }
    else
        .{ "×", "", "" };
    var bw_total: f32 = 0;
    for (labels) |l| if (l.len > 0) {
        bw_total += inbox.buttonWidth(ctx, l) + 6;
    };
    const max_w = @min(ctx.win.w - 32, 760);
    const tw = @min(d.width(font, fs, text), max_w - bw_total - 40);
    const w = tw + bw_total + 36;
    const r: d.Rect = .{ .x = ctx.win.x + (ctx.win.w - w) / 2, .y = y, .w = w, .h = 40 };
    card_rect[which] = r;
    card_on[which] = true;
    c.ImGui_SetNextWindowPos(d.v(r.x, r.y), 0);
    c.ImGui_SetNextWindowSize(d.v(r.w, r.h), 0);
    // Com o visualizador aberto (salvar de lá), o cartão desenha por cima de tudo e só
    // pega o foco com o mouse em cima dele: pegar a cada quadro cancelaria o clique nos
    // botões do visualizador (o ImGui solta o botão apertado quando o foco muda).
    const over_viewer = ctx.st.viewer != null;
    if (over_viewer and r.contains(ctx.mouse.x, ctx.mouse.y)) c.ImGui_SetNextWindowFocus();
    _ = c.ImGui_Begin(if (which == 0) "##exportar-card" else "##salvar-card", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoFocusOnAppearing);
    defer c.ImGui_End();
    const dl = if (over_viewer) ctx.fg else c.ImGui_GetWindowDrawList();
    qa.markTop(r, "{s}", .{if (which == 0) "export-card" else "save-card"});
    d.shadow(dl, r, 20, 12, ctx.col(.shadow));
    d.rect(dl, r, if (k.is_error) ctx.col(.danger) else ctx.col(.overlay), 20);
    if (!k.is_error) d.border(dl, r, ctx.col(.accent).alpha(0.6), 20, 1);
    const tc = if (k.is_error) d.Rgba.white else ctx.col(.text);
    _ = d.textClipped(dl, font, fs, r.x + 18, d.centerY(r, fs), tc, text, tw);
    var bx = r.x + 18 + tw + 12;
    for (labels, 0..) |l, i| {
        if (l.len == 0) continue;
        const bwd = inbox.buttonWidth(ctx, l);
        const br: d.Rect = .{ .x = bx, .y = r.y + 6, .w = bwd, .h = 28 };
        bx += bwd + 6;
        const tag: []const u8 = if (running) "cancel" else if (k.path_len == 0) "close" else switch (i) {
            0 => "open",
            1 => "folder",
            else => "close",
        };
        qa.markTop(br, "{s}:{s}", .{ if (which == 0) "export-card" else "save-card", tag });
        if (inbox.button(ctx, dl, 0x7E40 + @as(usize, which) * 8 + i, br, l, false)) {
            if (std.mem.eql(u8, tag, "cancel")) {
                if (which == 0) {
                    if (export_job) |j| j.cancel();
                } else if (save_job) |j| j.cancel();
            } else if (std.mem.eql(u8, tag, "open")) {
                pastas.open(k.path[0..k.path_len], qa.on());
            } else if (std.mem.eql(u8, tag, "folder")) {
                pastas.open(pastas.dirOf(k.path[0..k.path_len]), qa.on());
            } else k.shown = false;
        }
    }
    return r.bottom() + 8;
}

/// O texto do cartão (0 = exportar, 1 = salvar), para o QA conferir.
pub fn qaCardText(which: u8) []const u8 {
    const k = if (which == 0) &export_card else &save_card;
    return k.text[0..k.len];
}

fn progressText(buf: []u8, which: u8) []const u8 {
    if (which == 1) {
        const j = save_job orelse return "";
        return i18n.fmt(buf, "Salvando {s}…", "Saving {s}…", .{baseName(j.pathSlice())});
    }
    const j = export_job orelse return "";
    return switch (j.phase.load(.acquire)) {
        .media => i18n.fmt(buf, "Exportando: arquivos {d} de {d}", "Exporting: files {d} of {d}", .{ j.media_done.load(.acquire), j.plan.media.len }),
        else => i18n.fmt(buf, "Exportando: mensagens {d} de {d}", "Exporting: messages {d} of {d}", .{ j.msgs_done.load(.acquire), j.plan.msgs.len }),
    };
}

// --- O visualizador -------------------------------------------------------------------------

/// O original da imagem aberta no visualizador, quando quem abriu sabia (um anexo,
/// um cartão); vale enquanto ele mostrar o mesmo endereço.
var viewer_key: u64 = 0;
var viewer_req: SaveReq = .{ .pick = .{ .url = "", .name = "" } };

pub fn setViewerPick(shown_url: []const u8, p: salvar.Pick) void {
    viewer_key = std.hash.Wyhash.hash(0, shown_url);
    viewer_req.set(p);
}

/// O que "Salvar…" do visualizador salva: o original guardado, ou o próprio endereço
/// (foto de perfil, banner: já é o arquivo inteiro), com o nome da imagem.
pub fn viewerPick(shown_url: []const u8, name: []const u8, out: *salvar.PickBuf) salvar.Pick {
    if (viewer_key == std.hash.Wyhash.hash(0, shown_url) and viewer_req.pick.url.len > 0) return viewer_req.pick;
    const url = salvar.cdnFromProxy(&out.url, shown_url) orelse shown_url;
    const e = salvar.urlExt(url);
    const n = if (salvar.extOf(name).len == 0 and e.len > 0) (std.fmt.bufPrint(&out.name, "{s}{s}", .{ d.utf8Prefix(name, 200), e }) catch name) else name;
    return .{ .url = url, .name = n };
}
