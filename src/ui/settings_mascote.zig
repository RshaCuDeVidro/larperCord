//! Configurações → Mascote → Personalizar: a prévia grande (com as caras, o fone e a
//! fita para ver como as peças combinam), sortear, voltar ao padrão e desfazer, os
//! visuais prontos, uma grade de miniaturas por categoria (olhos, boca, chapéu,
//! acessórios, orelhas e cores) e os arquivos de mascote (escolher, abrir a pasta,
//! salvar o visual como arquivo e ver o erro de um arquivo com arquivo:linha:coluna).
//! As miniaturas são desenhos parados; a prévia só anima com o mouse em cima ou por
//! uns segundos depois de uma troca, e só com a janela em foco.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const i18n = @import("i18n.zig");
const inbox = @import("inbox.zig");
const S = @import("settings_state.zig");
const settings = @import("settings.zig");
const mascote = @import("mascote.zig");
const terminal = @import("mascote_terminal.zig");
const visual = @import("mascote_visual.zig");
const arquivos = @import("mascote_arquivos.zig");
const attachments = @import("attachments.zig");

const Rgba = d.Rgba;
const base_id: usize = 0x4D41_5300;

// --- Estado da página (não vai para o settings.kdl) ---------------------------------

/// A cara da prévia e o fone e a fita de quando está em call.
var show_face: visual.Face = .prompt;
var show_call = false;
var show_mute = false;
/// Quando o visual (ou a cara da prévia) mudou: a prévia anima por uns segundos.
var changed_ms: i64 = -100_000;
/// Desde quando a prévia está animando (o relógio dela começa ali).
var anim_from_ms: i64 = 0;
var animating = false;
/// A categoria aberta.
const Tab = enum(u8) { eyes, mouth, hat, acc, ears, colors };
var tab: Tab = .eyes;
/// Para desfazer: o texto do visual e o arquivo de antes de cada troca.
const Undo = struct { look: S.Text, file: S.Text };
var undo: [24]Undo = undefined;
var undo_n: usize = 0;
var seed: u64 = 0x5EED;
/// O texto das caixas de cor (o ImGui escreve aqui) e quem estava sendo editada.
var hex_buf: [5][12]u8 = @splat(@splat(0));
var hex_active: [5]bool = @splat(false);
var hex_bad = false;
/// A página abriu agora (relê a pasta dos arquivos uma vez).
var seen_ms: i64 = -10_000;

/// O QA pede para rolar a página até um pedaço (para fotografar).
pub const Anchor = enum { none, stage, presets, tabs, files };
pub var qa_scroll: Anchor = .none;

fn anchor(p: anytype, a: Anchor) void {
    if (qa_scroll != a) return;
    qa_scroll = .none;
    c.ImGui_SetCursorScreenPos(d.v(p.x, p.y - 24));
    c.ImGui_SetScrollHereY(0);
}

/// Quantas trocas dá para desfazer (o QA confere).
pub fn undoDepth() usize {
    return undo_n;
}
pub fn currentTab() u8 {
    return @intFromEnum(tab);
}
pub fn previewFace() visual.Face {
    return show_face;
}

// --- Trocar o visual -------------------------------------------------------------------

fn pushUndo(s: *const S.Settings) void {
    if (undo_n == undo.len) {
        std.mem.copyForwards(Undo, undo[0 .. undo.len - 1], undo[1..]);
        undo_n -= 1;
    }
    undo[undo_n] = .{ .look = s.mascot_look, .file = s.mascot_file };
    undo_n += 1;
}

/// Passa a usar `l` (o visual montado aqui): deixa de lado um arquivo escolhido (os
/// desenhos dele continuam, pelo `draw=`) e guarda o de antes para desfazer.
fn apply(ctx: *d.Ctx, l: visual.Look) void {
    const s = &ctx.st.settings;
    var buf: [256]u8 = undefined;
    const text = visual.writeCompact(&l, &buf);
    if (std.mem.eql(u8, text, s.mascot_look.slice()) and s.mascot_file.len == 0) return;
    pushUndo(s);
    s.mascot_look.set(text);
    s.mascot_file.set("");
    changed_ms = ctx.now_ms;
}

fn useFile(ctx: *d.Ctx, name: []const u8) void {
    const s = &ctx.st.settings;
    if (std.mem.eql(u8, s.mascot_file.slice(), name)) return;
    pushUndo(s);
    s.mascot_file.set(name);
    changed_ms = ctx.now_ms;
}

fn undoLast(ctx: *d.Ctx) void {
    if (undo_n == 0) return;
    undo_n -= 1;
    const s = &ctx.st.settings;
    s.mascot_look = undo[undo_n].look;
    s.mascot_file = undo[undo_n].file;
    changed_ms = ctx.now_ms;
}

/// O visual de agora, para mexer numa peça.
fn current() visual.Look {
    return mascote.current().*;
}

// --- Pedaços da página ---------------------------------------------------------------

fn tr(info: anytype) []const u8 {
    return i18n.tr(info.pt, info.en);
}

/// O que está na tela da janela de rolagem (o resto não precisa desenhar miniatura).
fn visible(r: d.Rect) bool {
    const wp = c.ImGui_GetWindowPos();
    const ws = c.ImGui_GetWindowSize();
    return r.bottom() >= wp.y - 4 and r.y <= wp.y + ws.y + 4;
}

/// Botão da página (o de destaque ou o discreto), num lugar já escolhido.
fn button(p: anytype, r: d.Rect, id: usize, label: []const u8, primary: bool, enabled: bool) bool {
    const ctx = p.ctx;
    const hb = d.hit(ctx, base_id + id, r);
    if (enabled) qa.mark(r, "button:{s}", .{label}) else qa.mark(r, "button-off:{s}", .{label});
    const fade: f32 = if (enabled) 1 else 0.45;
    const fs = settings.fitSize(p.font(.semibold), 14, 11, label, r.w - 20);
    if (primary) {
        const base = ctx.col(.accent);
        d.rect(p.dl, r, (if (hb.hovered and enabled) base.mix(Rgba.black, 0.12) else base).alpha(fade), ctx.th.radius);
        const tw = d.width(p.font(.semibold), fs, label);
        d.text(p.dl, p.font(.semibold), fs, r.x + (r.w - tw) / 2, d.centerY(r, fs), ctx.col(.accent_text).alpha(fade), label);
    } else {
        d.rect(p.dl, r, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered and enabled) @as(f32, 0.08) else 0).alpha(fade), ctx.th.radius);
        d.border(p.dl, r, ctx.col(.border).mix(ctx.col(.text), 0.08).alpha(fade), ctx.th.radius, 1);
        const tw = d.width(p.font(.semibold), fs, label);
        d.text(p.dl, p.font(.semibold), fs, r.x + (r.w - tw) / 2, d.centerY(r, fs), ctx.col(.text).alpha(fade), label);
    }
    return hb.clicked and enabled;
}

fn buttonWidth(p: anytype, label: []const u8) f32 {
    return d.width(p.font(.semibold), 14, label) + 32;
}

/// Pílula de escolha (as caras) ou de ligar e desligar (em call, mudo).
fn pill(p: anytype, r: d.Rect, id: usize, label: []const u8, on: bool, toggle: bool, mark: []const u8) bool {
    const ctx = p.ctx;
    const hb = d.hit(ctx, base_id + id, r);
    qa.mark(r, "{s}", .{mark});
    const k = anim.to(anim.id("mpill", id), if (on) 1 else if (hb.hovered) 0.35 else 0, 20);
    const rad = r.h / 2;
    d.rect(p.dl, r, ctx.col(.rail).alpha(0.6).mix(ctx.col(.accent).alpha(0.24), k), rad);
    d.border(p.dl, r, if (on) ctx.col(.accent) else ctx.col(.border), rad, if (on) 1.6 else 1);
    var x = r.x + 14;
    if (toggle) {
        const cx = r.x + 16;
        const cy = r.y + r.h / 2;
        c.ImDrawList_AddCircleEx(p.dl, d.v(cx, cy), 6.5, (if (on) ctx.col(.accent) else ctx.col(.muted)).u(), 0, 1.6, 0);
        if (on) {
            d.circle(p.dl, cx, cy, 6.5, ctx.col(.accent));
            d.line(p.dl, cx - 3, cy, cx - 1, cy + 2.4, ctx.col(.accent_text), 1.6);
            d.line(p.dl, cx - 1, cy + 2.4, cx + 3.2, cy - 2.2, ctx.col(.accent_text), 1.6);
        }
        x = r.x + 28;
    }
    const fs = settings.fitSize(p.font(.semibold), 13.5, 10.5, label, r.right() - 12 - x);
    // Sem o círculo de ligar, o nome fica no meio da pílula.
    const tx = if (toggle) x else r.x + (r.w - d.width(p.font(.semibold), fs, label)) / 2;
    d.text(p.dl, p.font(.semibold), fs, tx, d.centerY(r, fs), if (on) ctx.col(.text) else ctx.col(.muted), label);
    return hb.clicked;
}

fn pillWidth(p: anytype, label: []const u8, toggle: bool) f32 {
    return d.width(p.font(.semibold), 13.5, label) + (if (toggle) @as(f32, 42) else 28);
}

/// Lugar de coisas lado a lado que quebram a linha quando não cabem.
const Flow = struct {
    x0: f32,
    w: f32,
    x: f32,
    y: f32,
    h: f32,
    gap: f32,

    fn init(x: f32, y: f32, w: f32, h: f32, gap: f32) Flow {
        return .{ .x0 = x, .w = w, .x = x, .y = y, .h = h, .gap = gap };
    }
    fn next(f: *Flow, width: f32) d.Rect {
        const wd = @min(width, f.w);
        if (f.x > f.x0 and f.x + wd > f.x0 + f.w + 0.5) {
            f.x = f.x0;
            f.y += f.h + f.gap;
        }
        const r: d.Rect = .{ .x = f.x, .y = f.y, .w = wd, .h = f.h };
        f.x += wd + f.gap;
        return r;
    }
    fn bottom(f: *const Flow) f32 {
        return f.y + f.h;
    }
};

// --- Miniaturas --------------------------------------------------------------------------

/// O enquadramento: o mascote inteiro, o rosto de perto, com espaço para o chapéu.
const Frame = enum { full, face, hat };

/// Desenha o visual `l` parado dentro de `r`.
fn thumb(dl: *c.ImDrawList, r: d.Rect, l: *const visual.Look, frame0: Frame, light: bool) void {
    // Chapéu ou orelhas de coelho pedem espaço em cima.
    const frame: Frame = if (frame0 == .full and (l.hat != .none or l.ears == .bunny)) .hat else frame0;
    // A região do SVG que precisa caber (x0, y0, x1, y1) e o ponto que fica no meio.
    const box: [4]f32 = switch (frame) {
        .full => .{ -12, -20, 139, 104 },
        .face => .{ 20, 30, 107, 88 },
        .hat => .{ -14, -50, 141, 104 },
    };
    const k = @min(r.w / (box[2] - box[0]), r.h / (box[3] - box[1]));
    const size = k * terminal.body_w / 0.78;
    const fx = (box[0] + box[2]) / 2;
    const fy = (box[1] + box[3]) / 2;
    const tcx = r.x + r.w / 2;
    const tcy = r.y + r.h / 2;
    const cx = tcx - (fx - terminal.mid_x) * k;
    const cy = tcy - (fy - terminal.mid_y) * k;
    const was = mascote.borrow(l);
    defer mascote.restore(was);
    c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), true);
    defer c.ImDrawList_PopClipRect(dl);
    terminal.lite = true;
    defer terminal.lite = false;
    terminal.showcase(dl, cx, cy, size, .{ .t = 0.5, .stage = frame != .face, .light = light });
}

/// Um cartão da grade: fundo e o lugar da miniatura (quem chama desenha em `inner`);
/// depois `cardFront` põe a borda, o nome e o selo do escolhido.
const Card = struct { clicked: bool, hovered: bool, inner: d.Rect, show: bool, k: f32 };

fn card(p: anytype, r: d.Rect, id: usize, selected: bool, mark: []const u8) Card {
    const ctx = p.ctx;
    const hb = d.hit(ctx, base_id + id, r);
    qa.mark(r, "{s}", .{mark});
    const show = visible(r);
    const k = anim.to(anim.id("mcard", id), if (selected) 1 else if (hb.hovered) 0.5 else 0, 18);
    const inner: d.Rect = .{ .x = r.x + 5, .y = r.y + 5, .w = r.w - 10, .h = r.h - 36 };
    if (show) {
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 12);
        d.rect(p.dl, inner, ctx.col(.bg).mix(ctx.col(.accent), 0.05 + 0.07 * k).alpha(0.75), 9);
    }
    return .{ .clicked = hb.clicked, .hovered = hb.hovered, .inner = inner, .show = show, .k = k };
}

fn cardFront(p: anytype, r: d.Rect, cr: Card, label: []const u8, selected: bool) void {
    const ctx = p.ctx;
    if (!cr.show) return;
    const k = cr.k;
    d.border(p.dl, r, ctx.col(.accent).alpha(0.22 + 0.78 * k), 12, 1 + k * 1.2);
    const font = p.font(.semibold);
    const avail = r.w - 12;
    var fs: f32 = 12.5;
    if (d.width(font, fs, label) > avail) fs = @max(10, @floor(fs * avail / d.width(font, fs, label) * 2) / 2);
    const tw = d.width(font, fs, label);
    const ly = r.bottom() - 16 - d.fontPx(fs) / 2;
    const col = if (selected) ctx.col(.text) else ctx.col(.muted);
    if (tw <= avail + 0.5) {
        d.text(p.dl, font, fs, r.x + (r.w - tw) / 2, ly, col, label);
    } else {
        // Comprido mesmo na letra menor: cortado, com o nome inteiro ao passar o mouse.
        _ = d.textClipped(p.dl, font, fs, r.x + 6, ly, col, label, avail);
        d.tip(ctx, r, label, cr.hovered);
    }
    if (selected) {
        const bx = r.right() - 15;
        const by = r.y + 15;
        d.circle(p.dl, bx, by, 9, ctx.col(.accent));
        d.line(p.dl, bx - 4, by, bx - 1, by + 3, ctx.col(.accent_text), 2);
        d.line(p.dl, bx - 1, by + 3, bx + 4.5, by - 3.5, ctx.col(.accent_text), 2);
    }
}

/// A grade: quantas colunas cabem e o tamanho de cada cartão.
const Grid = struct {
    x: f32,
    y: f32,
    cols: usize,
    cw: f32,
    ch: f32,
    gap: f32,

    fn of(p: anytype, target: f32, aspect: f32) Grid {
        const gap: f32 = 10;
        const cols: usize = @max(3, @as(usize, @intFromFloat(@floor((p.w + gap) / (target + gap)))));
        const cw = (p.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        return .{ .x = p.x, .y = p.y, .cols = cols, .cw = cw, .ch = cw * aspect + 36, .gap = gap };
    }
    fn rect(g: Grid, i: usize) d.Rect {
        const col = i % g.cols;
        const row = i / g.cols;
        return .{ .x = g.x + @as(f32, @floatFromInt(col)) * (g.cw + g.gap), .y = g.y + @as(f32, @floatFromInt(row)) * (g.ch + g.gap), .w = g.cw, .h = g.ch };
    }
    fn height(g: Grid, n: usize) f32 {
        const rows = (n + g.cols - 1) / g.cols;
        return @as(f32, @floatFromInt(rows)) * (g.ch + g.gap);
    }
};

// --- A página ------------------------------------------------------------------------------

pub fn section(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    // Abriu agora: a lista de arquivos é lida de novo (alguém pode ter mexido na pasta).
    if (ctx.now_ms - seen_ms > 800) arquivos.reload();
    seen_ms = ctx.now_ms;

    p.heading(i18n.tr("Personalizar", "Customize"));
    if (mascote.Kind.of(s.mascot) != .terminal) {
        p.note(i18n.tr("O visual personalizado é do Terminal. Escolha o Terminal acima para ver e usar.", "The custom look is for the Terminal mascot. Pick the Terminal above to see and use it."));
        if (p.buttonSoft(i18n.tr("Usar o Terminal", "Use the Terminal"))) s.mascot = 0;
        return;
    }
    _ = @import("mascote_folha.zig").draw(ctx);
    anchor(p, .stage);
    fileBanner(p);
    stage(p);
    p.y += 18;
    anchor(p, .presets);
    p.heading(i18n.tr("Visuais prontos", "Ready-made looks"));
    presetGrid(p);
    p.y += 10;
    anchor(p, .tabs);
    tabs(p);
    switch (tab) {
        .eyes => eyesGrid(p),
        .mouth => mouthGrid(p),
        .hat => hatGrid(p),
        .acc => accGrid(p),
        .ears => earsGrid(p),
        .colors => colorsGrid(p),
    }
    p.divider();
    anchor(p, .files);
    filesSection(p);
}

/// Com um arquivo escolhido: o nome dele e como voltar ao visual de antes.
fn fileBanner(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    const name = s.mascot_file.slice();
    if (name.len == 0) return;
    const e = arquivos.find(name);
    var buf: [160]u8 = undefined;
    const title = if (e) |x| x.title.slice() else name;
    const text = i18n.fmt(&buf, "Usando o arquivo {s}", "Using the file {s}", .{title});
    const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = 48 };
    d.rect(p.dl, r, ctx.col(.accent).alpha(0.12), ctx.th.radius + 4);
    d.border(p.dl, r, ctx.col(.accent).alpha(0.45), ctx.th.radius + 4, 1);
    const stop = i18n.tr("Parar de usar o arquivo", "Stop using the file");
    const bw = buttonWidth(p, stop);
    const fits = bw + 160 < r.w;
    const tw = if (fits) r.w - bw - 36 else r.w - 24;
    _ = d.textClipped(p.dl, p.font(.semibold), 14, r.x + 14, d.centerY(r, 14), ctx.col(.text), text, tw);
    p.markText(.{ .x = r.x + 14, .y = r.y + 14, .w = @min(d.width(p.font(.semibold), 14, text), tw), .h = 20 });
    if (fits) {
        if (button(p, .{ .x = r.right() - bw - 8, .y = r.y + 6, .w = bw, .h = 36 }, 1, stop, false, true)) stopFile(ctx);
        p.y += r.h + 14;
    } else {
        p.y += r.h + 8;
        if (button(p, .{ .x = p.x, .y = p.y, .w = @min(bw, p.w), .h = 36 }, 1, stop, false, true)) stopFile(ctx);
        p.y += 48;
    }
}

fn stopFile(ctx: *d.Ctx) void {
    const s = &ctx.st.settings;
    pushUndo(s);
    s.mascot_file.set("");
    changed_ms = ctx.now_ms;
}

/// O nome do visual de agora: o do arquivo, o do pronto, "Padrão" ou "Do seu jeito".
fn lookName(ctx: *d.Ctx, l: *const visual.Look) []const u8 {
    const file = ctx.st.settings.mascot_file.slice();
    if (file.len > 0) if (arquivos.find(file)) |e| return e.title.slice();
    if (visual.presetOf(l)) |i| return tr(visual.presets[i]);
    if (l.isDefault()) return i18n.tr("Padrão", "Default");
    return i18n.tr("Do seu jeito", "Your own");
}

/// As peças do visual numa linha: "Estrelas · Gatinho :3 · Mago · Cachecol · Meia-noite".
fn summary(buf: []u8, l: *const visual.Look) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const parts = [_][]const u8{
        tr(visual.eyes_info[@intFromEnum(l.eyes)]),
        tr(visual.mouth_info[@intFromEnum(l.mouth)]),
    };
    for (parts, 0..) |x, i| {
        if (i > 0) w.writeAll(" · ") catch {};
        w.writeAll(x) catch {};
    }
    if (l.hat != .none) w.print(" · {s}", .{tr(visual.hat_info[@intFromEnum(l.hat)])}) catch {};
    if (l.ears != .pointy) w.print(" · {s}", .{tr(visual.ears_info[@intFromEnum(l.ears)])}) catch {};
    for (visual.acc_info, 0..) |a, i| if (l.acc & (@as(u16, 1) << @intCast(i)) != 0) w.print(" · {s}", .{tr(a)}) catch {};
    switch (l.paint) {
        .brand => {},
        .theme => w.print(" · {s}", .{i18n.tr("Cor do tema", "Theme color")}) catch {},
        .custom => if (l.palette < visual.palettes.len) w.print(" · {s}", .{tr(visual.palettes[l.palette])}) catch {} else w.print(" · {s}", .{i18n.tr("Cores próprias", "Your own colors")}) catch {},
    }
    return w.buffered();
}

/// A prévia grande com as informações, os botões e as caras.
fn stage(p: anytype) void {
    const ctx = p.ctx;
    const now = ctx.now_ms;
    const wide = p.w >= 600;
    const l = current();
    const card_r_x = p.x;
    const card_y = p.y;
    const prev: d.Rect = if (wide)
        .{ .x = card_r_x + 12, .y = card_y + 12, .w = 250, .h = 250 }
    else
        .{ .x = card_r_x + 12, .y = card_y + 12, .w = p.w - 24, .h = 230 };
    // As informações: ao lado (larga) ou embaixo (estreita).
    const ix = if (wide) prev.right() + 22 else card_r_x + 16;
    const iw = if (wide) card_r_x + p.w - 16 - ix else p.w - 32;
    var iy = if (wide) card_y + 22 else prev.bottom() + 16;
    const name = lookName(ctx, &l);
    var sb: [400]u8 = undefined;
    const sum = summary(&sb, &l);
    const sum_h = inbox.wrapText(null, p.font(.regular), 13, 0, 0, iw, sum, 3, ctx.col(.muted));
    // Os botões quebram a linha quando não cabem.
    const b_random = i18n.tr("Sortear visual", "Random look");
    const b_undo = i18n.tr("Desfazer", "Undo");
    const b_reset = i18n.tr("Padrão", "Default");
    const b_save = i18n.tr("Salvar como arquivo", "Save as file");
    const labels = [_][]const u8{ b_random, b_undo, b_reset, b_save };
    var bf = Flow.init(ix, iy + 18 + 30 + sum_h + 14, iw, 36, 8);
    var brs: [4]d.Rect = undefined;
    for (labels, 0..) |lb, i| brs[i] = bf.next(buttonWidth(p, lb));
    const info_bottom = bf.bottom();
    // As caras e o fone, embaixo de tudo, de ponta a ponta.
    const faces = [_]struct { f: visual.Face, pt: []const u8, en: []const u8 }{
        .{ .f = .prompt, .pt = "Normal", .en = "Normal" },
        .{ .f = .happy, .pt = "Feliz", .en = "Happy" },
        .{ .f = .laugh, .pt = "Rindo", .en = "Laughing" },
        .{ .f = .startled, .pt = "Susto", .en = "Startled" },
        .{ .f = .angry, .pt = "Bravo", .en = "Angry" },
        .{ .f = .sad, .pt = "Triste", .en = "Sad" },
        .{ .f = .sleep, .pt = "Dormindo", .en = "Asleep" },
        .{ .f = .dizzy, .pt = "Tonto", .en = "Dizzy" },
    };
    const call_label = i18n.tr("Em call", "In a call");
    const mute_label = i18n.tr("Mudo", "Muted");
    // Larga: as caras ficam na coluna da direita, embaixo dos botões; estreita, embaixo
    // de tudo, de ponta a ponta.
    const prev_label = i18n.tr("Na prévia", "In the preview");
    const chips_y = if (wide) info_bottom + 22 + 20 else @max(prev.bottom(), info_bottom) + 18 + 20;
    var cf = if (wide) Flow.init(ix, chips_y, iw, 32, 7) else Flow.init(card_r_x + 16, chips_y, p.w - 32, 32, 7);
    var frs: [faces.len]d.Rect = undefined;
    for (faces, 0..) |f, i| frs[i] = cf.next(pillWidth(p, i18n.tr(f.pt, f.en), false));
    const call_r = cf.next(pillWidth(p, call_label, true));
    const mute_r = cf.next(pillWidth(p, mute_label, true));
    const bottom = if (wide) @max(prev.bottom() + 12, cf.bottom() + 16) else cf.bottom() + 16;
    const card_r: d.Rect = .{ .x = card_r_x, .y = card_y, .w = p.w, .h = bottom - card_y };

    // --- Desenho ---------------------------------------------------------------------
    d.rect(p.dl, card_r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 14);
    d.border(p.dl, card_r, ctx.col(.border), 14, 1);
    const light = ctx.col(.bg).luma() > 0.5;
    const stage_bg = ctx.col(.bg).mix(ctx.col(.accent), 0.06);
    d.rect(p.dl, prev, stage_bg, 12);
    const ph = d.hit(ctx, base_id + 2, prev);
    qa.mark(prev, "mascot-preview", .{});
    // Anima com o mouse em cima ou logo depois de uma troca; parado, um desenho só.
    const want = !ctx.st.settings.reduce_motion and (ph.hovered or now - changed_ms < 4000);
    if (want and !animating) anim_from_ms = now;
    animating = want;
    var t: f32 = 0.5;
    if (animating) {
        t = 0.5 + @as(f32, @floatFromInt(now - anim_from_ms)) / 1000.0;
        if (ctx.st.window_focused) anim.at(now + 33);
    }
    const msize = @min(prev.w * 0.74, prev.h * 0.74);
    c.ImDrawList_PushClipRect(p.dl, d.v(prev.x, prev.y), d.v(prev.right(), prev.bottom()), true);
    terminal.showcase(p.dl, prev.x + prev.w / 2, prev.y + prev.h * 0.56, msize, .{ .face = show_face, .t = t, .headset = show_call, .tape = show_mute, .light = light });
    c.ImDrawList_PopClipRect(p.dl);

    // Informações e botões.
    const lb = i18n.tr("Visual", "Look");
    var ub: [32]u8 = undefined;
    const up = d.upper(&ub, lb);
    d.text(p.dl, p.font(.bold), 11.5, ix, iy, ctx.col(.muted), up);
    p.markText(.{ .x = ix, .y = iy, .w = d.width(p.font(.bold), 11.5, up), .h = 14 });
    iy += 18;
    const nfs = settings.fitSize(p.font(.bold), 20, 14, name, iw);
    _ = d.textClipped(p.dl, p.font(.bold), nfs, ix, iy, ctx.col(.text), name, iw);
    p.markText(.{ .x = ix, .y = iy, .w = @min(d.width(p.font(.bold), nfs, name), iw), .h = 26 });
    iy += 30;
    _ = inbox.wrapText(p.dl, p.font(.regular), 13, ix, iy, iw, sum, 3, ctx.col(.muted));
    if (button(p, brs[0], 3, b_random, true, true)) {
        seed +%= @as(u64, @intCast(@mod(now, 1 << 30))) | 1;
        var r = visual.random(seed);
        // Nunca o mesmo de agora.
        if (r.eql(&l)) r = visual.random(seed +% 7);
        apply(ctx, r);
    }
    if (button(p, brs[1], 4, b_undo, false, undo_n > 0)) undoLast(ctx);
    if (undo_n == 0) {
        const hb = d.hitRaw(ctx, brs[1]);
        d.tip(ctx, brs[1], i18n.tr("Nada para desfazer", "Nothing to undo"), hb.hovered);
    }
    if (button(p, brs[2], 5, b_reset, false, !l.isDefault() or ctx.st.settings.mascot_file.len > 0)) apply(ctx, .{});
    if (button(p, brs[3], 6, b_save, false, true)) saveFile(ctx, &l);

    // As caras da prévia.
    var pb: [48]u8 = undefined;
    const pl_up = d.upper(&pb, prev_label);
    d.text(p.dl, p.font(.bold), 11.5, cf.x0, chips_y - 20, ctx.col(.muted), pl_up);
    p.markText(.{ .x = cf.x0, .y = chips_y - 20, .w = d.width(p.font(.bold), 11.5, pl_up), .h = 14 });
    for (faces, 0..) |f, i| {
        var mb: [24]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "mascot-face:{d}", .{i}) catch "mascot-face";
        if (pill(p, frs[i], 10 + i, i18n.tr(f.pt, f.en), show_face == f.f, false, mark)) {
            show_face = f.f;
            changed_ms = now;
        }
    }
    if (pill(p, call_r, 30, call_label, show_call, true, "mascot-call")) {
        show_call = !show_call;
        if (!show_call) show_mute = false;
        changed_ms = now;
    }
    if (pill(p, mute_r, 31, mute_label, show_mute, true, "mascot-mute")) {
        show_mute = !show_mute;
        if (show_mute) show_call = true;
        changed_ms = now;
    }
    p.y = card_r.bottom();
}

fn saveFile(ctx: *d.Ctx, l: *const visual.Look) void {
    const title = if (visual.presetOf(l)) |i| tr(visual.presets[i]) else i18n.tr("Meu mascote", "My mascot");
    var nb: [64]u8 = undefined;
    const name = arquivos.save(l, title, &nb) orelse {
        ctx.st.showToast(ctx.now_ms, true, "não deu para salvar o arquivo", "couldn't save the file", .{});
        return;
    };
    // Passa a usar o arquivo: o que for mudado nele aparece na hora.
    useFile(ctx, name);
    ctx.st.showToast(ctx.now_ms, false, "salvo em mascots/{s}.kdl", "saved to mascots/{s}.kdl", .{name});
}

fn presetGrid(p: anytype) void {
    const ctx = p.ctx;
    const l = current();
    const light = ctx.col(.bg).luma() > 0.5;
    const g = Grid.of(p, 104, 0.9);
    const chosen = if (ctx.st.settings.mascot_file.len == 0) visual.presetOf(&l) else null;
    for (visual.presets, 0..) |pr, i| {
        const r = g.rect(i);
        var mb: [40]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "mascot-preset:{s}", .{pr.id}) catch "mascot-preset";
        const sel = chosen != null and chosen.? == i;
        const cr = card(p, r, 100 + i, sel, mark);
        if (cr.show) thumb(p.dl, cr.inner, &pr.look, .hat, light);
        cardFront(p, r, cr, tr(pr), sel);
        if (cr.clicked) apply(ctx, pr.look);
    }
    p.y += g.height(visual.presets.len) + 4;
}

fn tabs(p: anytype) void {
    const names = [_]struct { t: Tab, pt: []const u8, en: []const u8 }{
        .{ .t = .eyes, .pt = "Olhos", .en = "Eyes" },
        .{ .t = .mouth, .pt = "Boca", .en = "Mouth" },
        .{ .t = .hat, .pt = "Chapéu", .en = "Hat" },
        .{ .t = .acc, .pt = "Acessórios", .en = "Accessories" },
        .{ .t = .ears, .pt = "Orelhas", .en = "Ears" },
        .{ .t = .colors, .pt = "Cores", .en = "Colors" },
    };
    var f = Flow.init(p.x, p.y, p.w, 38, 8);
    for (names, 0..) |n, i| {
        const label = i18n.tr(n.pt, n.en);
        var mb: [32]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "mascot-tab:{s}", .{@tagName(n.t)}) catch "mascot-tab";
        const r = f.next(@max(pillWidth(p, label, false) + 12, 84));
        if (pill(p, r, 40 + i, label, tab == n.t, false, mark)) tab = n.t;
    }
    p.y = f.bottom() + 16;
}

/// Uma grade de peças: `count` cartões, cada um com o visual de agora trocado pela
/// peça `i` (`with`), o nome e se é a escolhida.
fn partGrid(p: anytype, comptime E: type, info: []const visual.Info, count: usize, frame: Frame, comptime kind: []const u8, is: *const fn (*const visual.Look, usize) bool, with: *const fn (*visual.Look, usize) void) void {
    const ctx = p.ctx;
    const l = current();
    const light = ctx.col(.bg).luma() > 0.5;
    const g = Grid.of(p, 104, if (frame == .face) 0.62 else 0.9);
    var n: usize = 0;
    for (0..count) |i| {
        const e: E = @enumFromInt(i);
        // "Do arquivo" só com um arquivo que desenha a peça.
        if (@hasField(E, "custom") and e == @field(E, "custom") and !hasCustom(&l, kind)) continue;
        const r = g.rect(n);
        n += 1;
        var mb: [48]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "mascot-opt:{s}:{s}", .{ kind, info[i].id }) catch "mascot-opt";
        const sel = is(&l, i);
        const id = 200 + n + @as(usize, @intFromEnum(tab)) * 64;
        const cr = card(p, r, id, sel, mark);
        if (cr.show) {
            var alt = l;
            with(&alt, i);
            thumb(p.dl, cr.inner, &alt, frame, light);
        }
        cardFront(p, r, cr, tr(info[i]), sel);
        if (cr.clicked) {
            var nl = l;
            with(&nl, i);
            if (!nl.eql(&l)) apply(ctx, nl);
        }
    }
    p.y += g.height(n) + 4;
}

fn hasCustom(l: *const visual.Look, comptime kind: []const u8) bool {
    const dw = l.drawing orelse return false;
    return dw.hasLayer(if (std.mem.eql(u8, kind, "eyes")) .eyes else .mouth);
}

fn eyesGrid(p: anytype) void {
    const F = struct {
        fn is(l: *const visual.Look, i: usize) bool {
            return @intFromEnum(l.eyes) == i;
        }
        fn with(l: *visual.Look, i: usize) void {
            l.eyes = @enumFromInt(i);
            // Os óculos escuros e o tapa-olho esconderiam os olhos na miniatura.
            l.acc &= ~visual.bits(&.{ .shades, .eyepatch });
        }
    };
    partGrid(p, visual.Eyes, &visual.eyes_info, visual.eyes_info.len, .face, "eyes", F.is, F.with);
}

fn mouthGrid(p: anytype) void {
    const F = struct {
        fn is(l: *const visual.Look, i: usize) bool {
            return @intFromEnum(l.mouth) == i;
        }
        fn with(l: *visual.Look, i: usize) void {
            l.mouth = @enumFromInt(i);
        }
    };
    partGrid(p, visual.Mouth, &visual.mouth_info, visual.mouth_info.len, .face, "mouth", F.is, F.with);
}

fn hatGrid(p: anytype) void {
    const F = struct {
        fn is(l: *const visual.Look, i: usize) bool {
            return @intFromEnum(l.hat) == i;
        }
        fn with(l: *visual.Look, i: usize) void {
            l.hat = @enumFromInt(i);
        }
    };
    p.note(i18n.tr("Com um chapéu escolhido, o mascote do canto não troca pelo das datas.", "With a hat picked, the corner mascot doesn't switch to the holiday one."));
    partGrid(p, visual.Hat, &visual.hat_info, visual.hat_info.len, .hat, "hat", F.is, F.with);
}

fn accGrid(p: anytype) void {
    const F = struct {
        fn is(l: *const visual.Look, i: usize) bool {
            return l.acc & (@as(u16, 1) << @intCast(i)) != 0;
        }
        fn with(l: *visual.Look, i: usize) void {
            l.toggle(@enumFromInt(i));
        }
    };
    const G = struct {
        // A miniatura mostra o acessório ligado, mesmo que ainda não esteja.
        fn preview(l: *visual.Look, i: usize) void {
            const a: visual.Acc = @enumFromInt(i);
            if (!l.has(a)) l.toggle(a);
        }
    };
    p.note(i18n.tr("Dá para usar vários. Óculos e o que vai no pescoço: um de cada vez.", "You can wear several. Glasses and neckwear: one at a time."));
    accPartGrid(p, F.is, F.with, G.preview);
}

/// A grade dos acessórios: a miniatura mostra cada um ligado, e o clique liga ou desliga.
fn accPartGrid(p: anytype, is: *const fn (*const visual.Look, usize) bool, with: *const fn (*visual.Look, usize) void, preview: *const fn (*visual.Look, usize) void) void {
    const ctx = p.ctx;
    const l = current();
    const light = ctx.col(.bg).luma() > 0.5;
    const g = Grid.of(p, 104, 0.9);
    for (visual.acc_info, 0..) |a, i| {
        const r = g.rect(i);
        var mb: [48]u8 = undefined;
        const mark = std.fmt.bufPrint(&mb, "mascot-opt:acc:{s}", .{a.id}) catch "mascot-opt";
        const sel = is(&l, i);
        const id = 600 + i;
        const cr = card(p, r, id, sel, mark);
        if (cr.show) {
            var alt = l;
            preview(&alt, i);
            thumb(p.dl, cr.inner, &alt, .full, light);
        }
        cardFront(p, r, cr, tr(a), sel);
        if (cr.clicked) {
            var nl = l;
            with(&nl, i);
            apply(ctx, nl);
        }
    }
    p.y += g.height(visual.acc_info.len) + 4;
}

fn earsGrid(p: anytype) void {
    const F = struct {
        fn is(l: *const visual.Look, i: usize) bool {
            return @intFromEnum(l.ears) == i;
        }
        fn with(l: *visual.Look, i: usize) void {
            l.ears = @enumFromInt(i);
        }
    };
    partGrid(p, visual.Ears, &visual.ears_info, visual.ears_info.len, .hat, "ears", F.is, F.with);
}

fn colorsGrid(p: anytype) void {
    const ctx = p.ctx;
    const l = current();
    const light = ctx.col(.bg).luma() > 0.5;
    const g = Grid.of(p, 104, 0.9);
    const n = visual.palettes.len + 2;
    for (0..n) |i| {
        const r = g.rect(i);
        var alt = l;
        var label: []const u8 = undefined;
        var mb: [48]u8 = undefined;
        var mark: []const u8 = undefined;
        var sel = false;
        if (i == 0) {
            alt.paint = .brand;
            label = i18n.tr("Padrão", "Default");
            mark = "mascot-opt:colors:brand";
            sel = l.paint == .brand;
        } else if (i == 1) {
            alt.paint = .theme;
            label = i18n.tr("Cor do tema", "Theme color");
            mark = "mascot-opt:colors:theme";
            sel = l.paint == .theme;
        } else {
            const pi: u8 = @intCast(i - 2);
            alt.usePalette(pi);
            label = tr(visual.palettes[pi]);
            mark = std.fmt.bufPrint(&mb, "mascot-opt:colors:{s}", .{visual.palettes[pi].id}) catch "mascot-opt";
            sel = l.paint == .custom and l.palette == pi;
        }
        const id = 700 + i;
        const cr = card(p, r, id, sel, mark);
        if (cr.show) thumb(p.dl, cr.inner, &alt, .full, light);
        cardFront(p, r, cr, label, sel);
        if (cr.clicked and !alt.eql(&l)) apply(ctx, alt);
    }
    p.y += g.height(n) + 8;
    p.heading(i18n.tr("Cores próprias", "Your own colors"));
    p.note(i18n.tr("Uma cor por parte, em hex (#RRGGBB). Mudar uma cor solta a paleta.", "One color per part, in hex (#RRGGBB). Changing a color leaves the palette."));
    hexEditor(p, &l);
}

/// As cinco caixas de cor (corpo em cima e embaixo, rosto, pelinhos e detalhes).
fn hexEditor(p: anytype, l: *const visual.Look) void {
    const ctx = p.ctx;
    const cols: usize = if (p.w >= 560) 2 else 1;
    const gap: f32 = 14;
    const cw = (p.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const row_h: f32 = 44;
    const tones = terminal.colors;
    for (0..5) |i| {
        const col = i % cols;
        const row = i / cols;
        const r: d.Rect = .{ .x = p.x + @as(f32, @floatFromInt(col)) * (cw + gap), .y = p.y + @as(f32, @floatFromInt(row)) * (row_h + 6), .w = cw, .h = row_h };
        // A caixa mostra a cor de agora quando ninguém está escrevendo nela.
        if (!hex_active[i]) {
            @memset(&hex_buf[i], 0);
            var hb: [12]u8 = undefined;
            const h = visual.hexText(&hb, tones[i]);
            @memcpy(hex_buf[i][0..h.len], h);
        }
        d.rect(p.dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.35), ctx.th.radius + 2);
        d.circle(p.dl, r.x + 22, r.y + r.h / 2, 11, tones[i]);
        c.ImDrawList_AddCircleEx(p.dl, d.v(r.x + 22, r.y + r.h / 2), 11, ctx.col(.text).alpha(0.3).u(), 0, 1, 0);
        const label = tr(visual.role_info[i]);
        const box_w: f32 = 112;
        const lw = r.w - 44 - box_w - 16;
        const fs = settings.fitSize(p.font(.medium), 14, 11, label, lw);
        _ = d.textClipped(p.dl, p.font(.medium), fs, r.x + 42, d.centerY(r, fs), ctx.col(.text), label, lw);
        p.markText(.{ .x = r.x + 42, .y = r.y + 12, .w = @min(d.width(p.font(.medium), fs, label), lw), .h = 20 });
        const bx = r.right() - box_w - 8;
        const field: d.Rect = .{ .x = bx - 2, .y = r.y + 7, .w = box_w + 4, .h = 30 };
        d.rect(p.dl, field, ctx.col(.bg), ctx.th.radius);
        d.border(p.dl, field, if (hex_active[i]) ctx.col(.accent) else ctx.col(.border).mix(ctx.col(.text), 0.1), ctx.th.radius, 1);
        c.ImGui_SetCursorScreenPos(d.v(bx + 6, r.y + 8));
        c.ImGui_SetNextItemWidth(box_w - 8);
        var idb: [16]u8 = undefined;
        const id = std.fmt.bufPrintSentinel(&idb, "##mhex{d}", .{i}, 0) catch "##mhex";
        const enter = c.ImGui_InputText(id.ptr, &hex_buf[i], hex_buf[i].len, c.ImGuiInputTextFlags_CharsNoBlank | c.ImGuiInputTextFlags_EnterReturnsTrue);
        const done = enter or c.ImGui_IsItemDeactivatedAfterEdit();
        hex_active[i] = c.ImGui_IsItemActive();
        var mb: [24]u8 = undefined;
        qa.mark(.{ .x = bx, .y = r.y + 8, .w = box_w, .h = 28 }, "{s}", .{std.fmt.bufPrint(&mb, "mascot-hex:{s}", .{visual.role_info[i].id}) catch "mascot-hex"});
        if (done) {
            const text = std.mem.sliceTo(&hex_buf[i], 0);
            if (visual.parseColor(text)) |cc| {
                hex_bad = false;
                var nl = l.*;
                if (nl.paint != .custom) nl.colors = tones;
                nl.paint = .custom;
                nl.palette = visual.no_palette;
                nl.colors[i] = cc;
                if (!nl.eql(l)) apply(ctx, nl);
            } else hex_bad = true;
            hex_active[i] = false;
        }
    }
    const rows = (5 + cols - 1) / cols;
    p.y += @as(f32, @floatFromInt(rows)) * (row_h + 6) + 4;
    if (hex_bad) p.note(i18n.tr("hex inválido — use #RRGGBB ou #RRGGBBAA", "invalid hex — use #RRGGBB or #RRGGBBAA"));
}

/// Os arquivos da pasta: escolher um, abrir a pasta e o guia, e o erro de cada um.
fn filesSection(p: anytype) void {
    const ctx = p.ctx;
    const s = &ctx.st.settings;
    p.heading(i18n.tr("Arquivos de mascote", "Mascot files"));
    p.note(i18n.tr("Cada arquivo .kdl da pasta vira um visual: escolhe peças e cores ou desenha as próprias, por expressão. Salvar o arquivo atualiza na hora.", "Each .kdl file in the folder becomes a look: it picks parts and colors or draws its own, per expression. Saving the file updates it right away."));
    var db: [512]u8 = undefined;
    if (arquivos.dir(&db)) |dir| {
        const tw = d.textClipped(p.dl, p.ctx.mono.get(.regular), 12.5, p.x, p.y, ctx.col(.muted), dir, p.w);
        p.markText(.{ .x = p.x, .y = p.y, .w = tw, .h = 18 });
        p.y += 26;
    }
    const files = arquivos.list();
    const light = ctx.col(.bg).luma() > 0.5;
    for (files, 0..) |*e, i| {
        const name = e.name.slice();
        const active = std.mem.eql(u8, s.mascot_file.slice(), name);
        // O erro ocupa mais linhas.
        var eb: [260]u8 = undefined;
        const err_text: ?[]const u8 = if (e.problem) |pr| blk: {
            const info = visual.issue_info[@intFromEnum(pr.issue)];
            break :blk i18n.fmt(&eb, "{s}.kdl:{d}:{d}: {s}", "{s}.kdl:{d}:{d}: {s}", .{ name, pr.line, pr.col, i18n.tr(info.pt, info.en) });
        } else null;
        const use_label = if (active) i18n.tr("Em uso", "In use") else i18n.tr("Usar", "Use");
        const bw = buttonWidth(p, use_label);
        const text_w = p.w - 74 - bw - 20;
        const err_h = if (err_text) |et| inbox.wrapText(null, p.font(.regular), 12.5, 0, 0, text_w, et, 4, ctx.col(.danger)) else 0;
        const r: d.Rect = .{ .x = p.x, .y = p.y, .w = p.w, .h = @max(68, 30 + err_h + 12) };
        var mb: [64]u8 = undefined;
        qa.mark(r, "{s}", .{std.fmt.bufPrint(&mb, "mascot-file:{s}", .{name}) catch "mascot-file"});
        d.rect(p.dl, r, if (active) ctx.col(.accent).alpha(0.1) else ctx.col(.rail).mix(ctx.col(.elevated), 0.35), ctx.th.radius + 4);
        d.border(p.dl, r, if (active) ctx.col(.accent).alpha(0.7) else if (err_text != null) ctx.col(.danger).alpha(0.55) else ctx.col(.border), ctx.th.radius + 4, if (active) 1.6 else 1);
        const th: d.Rect = .{ .x = r.x + 8, .y = r.y + (r.h - 54) / 2, .w = 54, .h = 54 };
        if (visible(r)) {
            d.rect(p.dl, th, ctx.col(.bg).mix(ctx.col(.accent), 0.05).alpha(0.8), 8);
            if (e.problem == null) thumb(p.dl, th, &e.look, .full, light) else {
                // Um sinal de atenção no lugar do mascote.
                const cx = th.x + th.w / 2;
                const cy = th.y + th.h / 2;
                c.ImDrawList_AddTriangleFilled(p.dl, d.v(cx, cy - 14), d.v(cx + 15, cy + 12), d.v(cx - 15, cy + 12), ctx.col(.danger).u());
                d.line(p.dl, cx, cy - 5, cx, cy + 4, Rgba.white, 2.4);
                d.circle(p.dl, cx, cy + 8, 1.5, Rgba.white);
            }
        }
        const tx = th.right() + 12;
        const title = e.title.slice();
        _ = d.textClipped(p.dl, p.font(.semibold), 15, tx, r.y + 12, ctx.col(.text), title, text_w);
        p.markText(.{ .x = tx, .y = r.y + 12, .w = @min(d.width(p.font(.semibold), 15, title), text_w), .h = 18 });
        if (err_text) |et| {
            _ = inbox.wrapText(p.dl, p.font(.regular), 12.5, tx, r.y + 34, text_w, et, 4, ctx.col(.danger));
            p.markText(.{ .x = tx, .y = r.y + 34, .w = @min(d.width(p.font(.regular), 12.5, et), text_w), .h = err_h });
        } else {
            var meta_b: [160]u8 = undefined;
            const meta = if (e.author.len > 0) i18n.fmt(&meta_b, "por {s} · {s}.kdl", "by {s} · {s}.kdl", .{ e.author.slice(), name }) else std.fmt.bufPrint(&meta_b, "{s}.kdl", .{name}) catch name;
            _ = d.textClipped(p.dl, p.font(.regular), 12.5, tx, r.y + 36, ctx.col(.muted), meta, text_w);
            p.markText(.{ .x = tx, .y = r.y + 36, .w = @min(d.width(p.font(.regular), 12.5, meta), text_w), .h = 16 });
        }
        const br: d.Rect = .{ .x = r.right() - bw - 12, .y = r.y + (r.h - 36) / 2, .w = bw, .h = 36 };
        if (e.problem == null) {
            var bb: [64]u8 = undefined;
            const bmark = std.fmt.bufPrint(&bb, "mascot-file-use:{s}", .{name}) catch "mascot-file-use";
            const hb = d.hit(ctx, base_id + 900 + i, br);
            qa.mark(br, "{s}", .{bmark});
            if (active) {
                d.rect(p.dl, br, ctx.col(.accent), ctx.th.radius);
                const tw = d.width(p.font(.semibold), 14, use_label);
                d.text(p.dl, p.font(.semibold), 14, br.x + (br.w - tw) / 2, d.centerY(br, 14), ctx.col(.accent_text), use_label);
            } else {
                d.rect(p.dl, br, ctx.col(.elevated).mix(ctx.col(.text), if (hb.hovered) @as(f32, 0.08) else 0), ctx.th.radius);
                d.border(p.dl, br, ctx.col(.border).mix(ctx.col(.text), 0.08), ctx.th.radius, 1);
                const tw = d.width(p.font(.semibold), 14, use_label);
                d.text(p.dl, p.font(.semibold), 14, br.x + (br.w - tw) / 2, d.centerY(br, 14), ctx.col(.text), use_label);
                if (hb.clicked) useFile(ctx, name);
            }
        }
        p.y += r.h + 8;
    }
    if (files.len == 0) p.note(i18n.tr("Nenhum arquivo ainda. \"Salvar como arquivo\" cria o primeiro.", "No files yet. \"Save as file\" makes the first one."));
    p.y += 4;
    const b_open = i18n.tr("Abrir pasta", "Open folder");
    const b_guide = i18n.tr("Como escrever um mascote", "How to write a mascot");
    var f = Flow.init(p.x, p.y, p.w, 36, 8);
    const r1 = f.next(buttonWidth(p, b_open));
    const r2 = f.next(buttonWidth(p, b_guide));
    if (button(p, r1, 7, b_open, false, true) and !qa.on()) arquivos.openFolder();
    if (button(p, r2, 8, b_guide, false, true)) {
        attachments.openUrl(if (i18n.current() == .pt) "https://rshacudevidro.github.io/larperCord/pt/guide/mascots.html" else "https://rshacudevidro.github.io/larperCord/guide/mascots.html");
    }
    p.y = f.bottom() + 12;
}
