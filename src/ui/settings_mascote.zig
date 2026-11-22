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
/// Para desfazer: os textos do visual (peças, ajustes e nome) e o arquivo de antes de
/// cada troca.
const Undo = struct { look: S.Text, tweaks: S.Text, name: S.Text, file: S.Text };
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
pub const Anchor = enum { none, stage, more, presets, tabs, files };
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
/// Quantas vezes algo foi guardado para desfazer, desde que o app abriu (a pilha tem
/// tamanho fixo; o QA confere um desfazer por arraste mesmo com ela cheia).
pub fn undoPushes() usize {
    return undo_pushes;
}
var undo_pushes: usize = 0;
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
    undo[undo_n] = .{ .look = s.mascot_look, .tweaks = s.mascot_tweaks, .name = s.mascot_name, .file = s.mascot_file };
    undo_n += 1;
    undo_pushes += 1;
}

/// Passa a usar `l` (o visual montado aqui): deixa de lado um arquivo escolhido (os
/// desenhos dele continuam, pelo `draw=`) e guarda o de antes para desfazer. O nome
/// continua o de agora (um visual pronto ou sorteado não tira o nome dele).
fn apply(ctx: *d.Ctx, l: visual.Look) void {
    var nl = l;
    nl.name = current().name;
    applyEx(ctx, nl, true);
}

/// `undoable` falso: os passos seguintes de um mesmo arraste (um desfazer só por arraste).
fn applyEx(ctx: *d.Ctx, l: visual.Look, undoable: bool) void {
    const s = &ctx.st.settings;
    var buf: [256]u8 = undefined;
    var tbuf: [256]u8 = undefined;
    const text = visual.writeCompact(&l, &buf);
    const tweaks = visual.writeTweaks(&l, &tbuf);
    if (std.mem.eql(u8, text, s.mascot_look.slice()) and std.mem.eql(u8, tweaks, s.mascot_tweaks.slice()) and
        std.mem.eql(u8, l.name.slice(), s.mascot_name.slice()) and s.mascot_file.len == 0) return;
    if (undoable) pushUndo(s);
    s.mascot_look.set(text);
    s.mascot_tweaks.set(tweaks);
    s.mascot_name.set(l.name.slice());
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
    s.mascot_tweaks = undo[undo_n].tweaks;
    s.mascot_name = undo[undo_n].name;
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
    if (ctx.now_ms - seen_ms > 800) {
        arquivos.requestReload();
        anim.at(ctx.now_ms + 16);
    }
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

/// A prévia grande com as informações, os botões, os ajustes e as caras.
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
    // Embaixo dos botões: o nome, as alturas e "Mais ajustes", que abre o resto.
    var rows_buf: [row_count]Row = undefined;
    const rows = rowsOf(&rows_buf, &l);
    var label_w: f32 = 0;
    for (rows) |r| if (hasLabel(r)) {
        label_w = @max(label_w, d.width(p.font(.medium), 14, rowLabel(r)));
    };
    label_w = @min(label_w, iw * 0.45);
    var rrs: [row_count]d.Rect = undefined;
    var swatch_rs: [eye_swatches.len]d.Rect = undefined;
    var hex_r: d.Rect = undefined;
    var ry = bf.bottom() + 12;
    for (rows, 0..) |r, i| {
        var h: f32 = tweak_h;
        if (r == .right_eye) {
            // As cores prontas e a caixa de hex, quebrando a linha quando não cabem.
            const fx = ix + label_w + 18;
            var sf = Flow.init(fx, ry + 1, ix + iw - fx, 28, 6);
            for (&swatch_rs) |*q| q.* = sf.next(28);
            hex_r = sf.next(hex_w);
            h = sf.bottom() - ry + 1;
        }
        rrs[i] = .{ .x = ix, .y = ry, .w = iw, .h = h };
        ry += h + 4;
    }
    const info_bottom = rrs[rows.len - 1].bottom();
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
    const mcx = prev.x + prev.w / 2;
    const mcy = prev.y + prev.h * 0.56;
    c.ImDrawList_PushClipRect(p.dl, d.v(prev.x, prev.y), d.v(prev.right(), prev.bottom()), true);
    terminal.showcase(p.dl, mcx, mcy, msize, .{ .face = show_face, .t = t, .headset = show_call, .tape = show_mute, .light = light });
    c.ImDrawList_PopClipRect(p.dl);
    nameTag(p, prev, &l);
    previewDrag(p, ph, mcx, mcy, msize, &l);

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
    for (rows, 0..) |r, i| drawRow(p, rrs[i], r, label_w, &l, &swatch_rs, hex_r);

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

// --- Os ajustes da prévia ------------------------------------------------------------

/// As linhas embaixo dos botões da prévia: o nome, as alturas, o botão "Mais ajustes"
/// e, com ele aberto, os outros ajustes (os nomes dos de arrastar são os de
/// `visual.Tweak`).
const Row = enum(u8) { name, eye_height, mouth_height, more, eye_x, eye_spacing, eye_tilt, eye_size, mouth_x, mouth_size, ear_size, ear_tilt, roundness, body_width, blush, two_color, right_eye };
const row_count = @typeInfo(Row).@"enum".field_names.len;
/// A altura de cada linha e a largura da caixa de hex do olho direito.
const tweak_h: f32 = 30;
const hex_w: f32 = 108;
/// "Mais ajustes" aberto (só enquanto o app está aberto; não vai para o settings.kdl).
var more_open = false;
/// O controle sendo arrastado: o primeiro passo de cada arraste guarda o visual de
/// antes para desfazer; os outros, não.
var slider_drag: ?Row = null;
/// O nome sendo escrito (o ImGui escreve aqui) e se a caixa está com o foco.
var name_buf: [visual.PetName.max_chars * 4 + 1]u8 = @splat(0);
var name_active = false;
/// A caixa de hex do olho direito.
var eye_hex_buf: [12]u8 = @splat(0);
var eye_hex_active = false;

/// As cores prontas para o olho direito.
const eye_swatches = [_]u32{ 0xFFC23D, 0x29E6FF, 0x5BE38A, 0xFF5FAE, 0x9D6BFF, 0xE5394E, 0x5B9DFF, 0xF8F0FF };

fn rowsOf(buf: *[row_count]Row, l: *const visual.Look) []const Row {
    var n: usize = 0;
    const base_rows = [_]Row{ .name, .eye_height, .mouth_height, .more };
    const more_rows = [_]Row{ .eye_x, .eye_spacing, .eye_tilt, .eye_size, .mouth_x, .mouth_size, .ear_size, .ear_tilt, .roundness, .body_width, .blush, .two_color };
    for (base_rows) |r| {
        buf[n] = r;
        n += 1;
    }
    if (more_open) {
        for (more_rows) |r| {
            buf[n] = r;
            n += 1;
        }
        if (l.right_eye != null) {
            buf[n] = .right_eye;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Linhas com o rótulo numa coluna (as outras usam a largura toda).
fn hasLabel(r: Row) bool {
    return r != .more and r != .two_color;
}

fn rowLabel(r: Row) []const u8 {
    return switch (r) {
        .name => i18n.tr("Nome", "Name"),
        .eye_height => i18n.tr("Altura dos olhos", "Eye height"),
        .mouth_height => i18n.tr("Altura da boca", "Mouth height"),
        .more => i18n.tr("Mais ajustes", "More tweaks"),
        .eye_x => i18n.tr("Posição dos olhos", "Eye position"),
        .eye_spacing => i18n.tr("Espaço entre os olhos", "Eye spacing"),
        .eye_tilt => i18n.tr("Desalinhar olhos", "Uneven eyes"),
        .eye_size => i18n.tr("Tamanho dos olhos", "Eye size"),
        .mouth_x => i18n.tr("Posição da boca", "Mouth position"),
        .mouth_size => i18n.tr("Tamanho da boca", "Mouth size"),
        .ear_size => i18n.tr("Tamanho das orelhas", "Ear size"),
        .ear_tilt => i18n.tr("Ângulo das orelhas", "Ear angle"),
        .roundness => i18n.tr("Arredondado", "Roundness"),
        .body_width => i18n.tr("Largura do corpo", "Body width"),
        .blush => i18n.tr("Bochechas", "Blush"),
        .two_color => i18n.tr("Olhos de duas cores", "Two-color eyes"),
        .right_eye => i18n.tr("Olho direito", "Right eye"),
    };
}

/// O que cada ponta do controle quer dizer (ao passar o mouse no trilho).
fn rowTip(r: Row) []const u8 {
    return switch (r) {
        .eye_height, .mouth_height => i18n.tr("− mais baixo · + mais alto", "− lower · + higher"),
        .eye_x, .mouth_x => i18n.tr("− para a esquerda · + para a direita", "− to the left · + to the right"),
        .eye_spacing => i18n.tr("− mais perto · + mais longe", "− closer · + farther apart"),
        .eye_tilt => i18n.tr("− o esquerdo mais alto · + o direito mais alto", "− left one higher · + right one higher"),
        .eye_size, .mouth_size, .ear_size => i18n.tr("− menor · + maior", "− smaller · + bigger"),
        .ear_tilt => i18n.tr("− para dentro · + para fora", "− inward · + outward"),
        .roundness => i18n.tr("− mais quadrado · + mais redondo", "− squarer · + rounder"),
        .body_width => i18n.tr("− magrinho · + gordinho", "− slimmer · + chubbier"),
        .blush => i18n.tr("0 sem bochechas · 6 bem coradas", "0 no blush · 6 strongest"),
        else => "",
    };
}

/// O ajuste de uma linha de arrastar (null nas outras).
fn rowTweak(r: Row) ?visual.Tweak {
    return switch (r) {
        inline else => |x| if (@hasField(visual.Tweak, @tagName(x))) @field(visual.Tweak, @tagName(x)) else null,
    };
}

/// Algum dos ajustes de dentro de "Mais ajustes" fora do de sempre?
fn moreChanged(l: *const visual.Look) bool {
    for (std.enums.values(visual.Tweak)) |t| {
        if (t == .eye_height or t == .mouth_height) continue;
        if (l.tweak(t) != 0) return true;
    }
    return l.right_eye != null or (l.has(.blush) and l.blush != visual.blush_usual);
}

fn drawRow(p: anytype, r: d.Rect, row: Row, label_w: f32, l: *const visual.Look, swatch_rs: []const d.Rect, hex_r: d.Rect) void {
    const ctx = p.ctx;
    if (hasLabel(row)) {
        const label = rowLabel(row);
        const fs = settings.fitSize(p.font(.medium), 14, 11, label, label_w);
        const ly = if (row == .right_eye) r.y + (tweak_h - fs * 1.2) / 2 else d.centerY(r, fs);
        const lw = d.textClipped(p.dl, p.font(.medium), fs, r.x, ly, ctx.col(.text), label, label_w);
        p.markText(.{ .x = r.x, .y = ly, .w = lw, .h = fs + 4 });
    }
    switch (row) {
        .name => nameField(p, r, label_w, l),
        .more => moreHeader(p, r, l),
        .two_color => {
            const label = rowLabel(row);
            const pr: d.Rect = .{ .x = r.x, .y = r.y, .w = @min(pillWidth(p, label, true), r.w), .h = r.h };
            if (pill(p, pr, 70, label, l.right_eye != null, true, "mascot-two-color")) {
                var nl = l.*;
                nl.right_eye = if (l.right_eye == null) firstEyeColor(l) else null;
                apply(ctx, nl);
            }
        },
        .right_eye => rightEyeColors(p, swatch_rs, hex_r, l),
        .blush => {
            const cur = l.blushLevel();
            if (slider(p, r, row, "mascot-tweak:blush", label_w, .{ .lo = 0, .hi = visual.blush_range[1], .cur = cur, .signed = false })) |v| {
                var nl = l.*;
                nl.setBlushLevel(v);
                applyEx(ctx, nl, slider_drag != row);
                slider_drag = row;
            }
        },
        else => {
            const t = rowTweak(row) orelse return;
            const range = visual.tweak_range[@intFromEnum(t)];
            var mb: [40]u8 = undefined;
            const mark = switch (t) {
                .eye_height => "mascot-height:eyes",
                .mouth_height => "mascot-height:mouth",
                else => std.fmt.bufPrint(&mb, "mascot-tweak:{s}", .{visual.tweak_ids[@intFromEnum(t)]}) catch "mascot-tweak",
            };
            if (slider(p, r, row, mark, label_w, .{ .lo = range[0], .hi = range[1], .cur = l.tweak(t) })) |v| {
                // Os olhos e a boca se empurram (ver `visual.Look.setTweak`).
                var nl = l.*;
                nl.setTweak(t, v);
                applyEx(ctx, nl, slider_drag != row);
                slider_drag = row;
            }
        },
    }
}

const Slider = struct { lo: i8, hi: i8, cur: i8, signed: bool = true };

/// Um controle de arrastar: o trilho com o zero (o de sempre) marcado, a cor do zero até
/// o valor, o pegador e o número. Devolve o valor novo enquanto é arrastado e muda.
fn slider(p: anytype, r: d.Rect, row: Row, mark: []const u8, label_w: f32, sl: Slider) ?i8 {
    const ctx = p.ctx;
    const lo: f32 = @floatFromInt(sl.lo);
    const hi: f32 = @floatFromInt(sl.hi);
    const num_w: f32 = 30;
    const track: d.Rect = .{ .x = r.x + label_w + 18, .y = r.y + r.h / 2 - 3, .w = @max(r.w - label_w - 18 - num_w - 14, 40), .h = 6 };
    const hr: d.Rect = .{ .x = track.x - 8, .y = r.y, .w = track.w + 16, .h = r.h };
    const hb = d.hit(ctx, base_id + 50 + @intFromEnum(row), hr);
    qa.mark(hr, "{s}", .{mark});
    var out: ?i8 = null;
    if (hb.held) {
        const k = std.math.clamp((ctx.mouse.x - track.x) / track.w, 0, 1);
        const want: i8 = @intFromFloat(@round(lo + k * (hi - lo)));
        if (want != sl.cur) out = want;
    } else if (slider_drag == row) slider_drag = null;
    const tip = rowTip(row);
    if (tip.len > 0) d.tip(ctx, hr, tip, hb.hovered and !hb.held);
    // O trilho, a cor do zero até o valor, a marquinha do zero e o pegador.
    const k = (@as(f32, @floatFromInt(sl.cur)) - lo) / (hi - lo);
    const k0 = -lo / (hi - lo);
    d.rect(p.dl, track, ctx.col(.elevated).mix(ctx.col(.text), 0.08), 3);
    const a = @min(k, k0);
    const b = @max(k, k0);
    if (b > a) d.rect(p.dl, .{ .x = track.x + track.w * a, .y = track.y, .w = track.w * (b - a), .h = track.h }, ctx.col(.accent), 3);
    d.rect(p.dl, .{ .x = track.x + track.w * k0 - 1, .y = track.y - 4, .w = 2, .h = track.h + 8 }, ctx.col(.muted).alpha(0.7), 1);
    const kx = track.x + track.w * k;
    d.shadow(p.dl, .{ .x = kx - 6, .y = r.y + 4, .w = 12, .h = r.h - 8 }, 3, 3, ctx.col(.shadow));
    d.rect(p.dl, .{ .x = kx - 5, .y = r.y + 5, .w = 10, .h = r.h - 10 }, Rgba.white, 3);
    var nb: [8]u8 = undefined;
    const num = (if (sl.signed and sl.cur > 0) std.fmt.bufPrint(&nb, "+{d}", .{sl.cur}) else std.fmt.bufPrint(&nb, "{d}", .{sl.cur})) catch "";
    const nw = d.width(p.font(.semibold), 13, num);
    d.text(p.dl, p.font(.semibold), 13, r.right() - nw, d.centerY(r, 13), ctx.col(.muted), num);
    p.markText(.{ .x = r.right() - nw, .y = d.centerY(r, 13), .w = nw, .h = 17 });
    return out;
}

/// O nome dele: uma caixa de texto (até 24 letras). Vale ao apertar Enter ou sair da
/// caixa, com um desfazer.
fn nameField(p: anytype, r: d.Rect, label_w: f32, l: *const visual.Look) void {
    const ctx = p.ctx;
    const fx = r.x + label_w + 18;
    const field: d.Rect = .{ .x = fx, .y = r.y + 1, .w = @max(r.right() - fx, 60), .h = r.h - 2 };
    // A caixa mostra o nome de agora quando ninguém está escrevendo nela.
    if (!name_active) {
        @memset(&name_buf, 0);
        const cur = l.name.slice();
        @memcpy(name_buf[0..cur.len], cur);
    }
    d.rect(p.dl, field, ctx.col(.bg), ctx.th.radius);
    d.border(p.dl, field, if (name_active) ctx.col(.accent) else ctx.col(.border).mix(ctx.col(.text), 0.1), ctx.th.radius, 1);
    c.ImGui_SetCursorScreenPos(d.v(field.x + 6, field.y + 1));
    c.ImGui_SetNextItemWidth(field.w - 12);
    const hint = i18n.trZ("Sem nome", "No name");
    const enter = c.ImGui_InputTextWithHintEx("##mname", hint.ptr, &name_buf, name_buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackEdit, nameEdit, null);
    const done = enter or c.ImGui_IsItemDeactivatedAfterEdit();
    name_active = c.ImGui_IsItemActive();
    qa.mark(field, "mascot-name", .{});
    if (done) {
        var nl = l.*;
        nl.name.set(std.mem.sliceTo(&name_buf, 0));
        applyEx(ctx, nl, true);
        name_active = false;
    }
}

/// Escrevendo o nome: o que passa de 24 letras sai na hora (colar um texto comprido
/// também), sem cortar uma letra no meio.
fn nameEdit(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const len: usize = @intCast(data.*.BufTextLen);
    const text = data.*.Buf[0..len];
    var chars: usize = 0;
    var i: usize = 0;
    while (i < len) {
        if (chars == visual.PetName.max_chars) {
            c.ImGuiInputTextCallbackData_DeleteChars(data, @intCast(i), @intCast(len - i));
            break;
        }
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        chars += 1;
    }
    return 0;
}

/// O nome dele embaixo do mascote, na prévia.
fn nameTag(p: anytype, prev: d.Rect, l: *const visual.Look) void {
    const ctx = p.ctx;
    const nm = l.name.slice();
    if (nm.len == 0) return;
    const font = p.font(.semibold);
    const fs = settings.fitSize(font, 13, 10.5, nm, prev.w - 44);
    const tw = @min(d.width(font, fs, nm), prev.w - 44);
    const r: d.Rect = .{ .x = prev.x + (prev.w - tw) / 2 - 10, .y = prev.bottom() - 32, .w = tw + 20, .h = 24 };
    d.rect(p.dl, r, ctx.col(.elevated).alpha(0.92), 12);
    d.border(p.dl, r, ctx.col(.accent).alpha(0.5), 12, 1);
    _ = d.textClipped(p.dl, font, fs, r.x + 10, d.centerY(r, fs), ctx.col(.text), nm, tw);
    p.markText(r);
    qa.mark(r, "mascot-name-tag:{s}", .{nm});
}

/// O botão que abre e fecha "Mais ajustes" (com um ponto quando algo de dentro mudou e
/// ele está fechado).
fn moreHeader(p: anytype, r: d.Rect, l: *const visual.Look) void {
    const ctx = p.ctx;
    const label = rowLabel(.more);
    if (qa_scroll == .more) {
        qa_scroll = .none;
        c.ImGui_SetCursorScreenPos(d.v(r.x, r.y - 24));
        c.ImGui_SetScrollHereY(0);
    }
    const hb = d.hit(ctx, base_id + 69, r);
    qa.mark(r, "mascot-more", .{});
    if (hb.hovered) d.rect(p.dl, r, ctx.col(.text).alpha(0.05), ctx.th.radius);
    // A setinha: para a direita fechado, para baixo aberto.
    const cx = r.x + 10;
    const cy = r.y + r.h / 2;
    const col = ctx.col(.muted);
    if (more_open) {
        d.line(p.dl, cx - 4, cy - 2, cx, cy + 2, col, 1.8);
        d.line(p.dl, cx, cy + 2, cx + 4, cy - 2, col, 1.8);
    } else {
        d.line(p.dl, cx - 2, cy - 4, cx + 2, cy, col, 1.8);
        d.line(p.dl, cx + 2, cy, cx - 2, cy + 4, col, 1.8);
    }
    const tx = r.x + 24;
    const fs = settings.fitSize(p.font(.semibold), 14, 11, label, r.w - 44);
    const tw = d.textClipped(p.dl, p.font(.semibold), fs, tx, d.centerY(r, fs), ctx.col(.text), label, r.w - 44);
    p.markText(.{ .x = tx, .y = d.centerY(r, fs), .w = tw, .h = fs + 4 });
    if (!more_open and moreChanged(l)) d.circle(p.dl, tx + tw + 10, cy, 3.5, ctx.col(.accent));
    if (hb.clicked) more_open = !more_open;
}

/// A cor que o olho direito ganha ao ligar: a primeira pronta que não é a do outro olho.
fn firstEyeColor(l: *const visual.Look) visual.Rgba {
    const tones = l.colorsFor(terminal.accent, false);
    const other = switch (l.eyes) {
        .big, .cat, .visor => tones[@intFromEnum(visual.Role.accent)],
        else => tones[@intFromEnum(visual.Role.ink)],
    };
    for (eye_swatches) |hx| {
        const c0 = visual.Rgba.hex(hx);
        if (@abs(c0.r - other.r) + @abs(c0.g - other.g) + @abs(c0.b - other.b) > 0.4) return c0;
    }
    return visual.Rgba.hex(eye_swatches[0]);
}

/// As cores prontas do olho direito e a caixa de hex.
fn rightEyeColors(p: anytype, swatch_rs: []const d.Rect, hex_r: d.Rect, l: *const visual.Look) void {
    const ctx = p.ctx;
    const cur = l.right_eye orelse return;
    for (eye_swatches, swatch_rs, 0..) |hx, sr, i| {
        const col = visual.Rgba.hex(hx);
        const on = col.col(1) == cur.col(1);
        const hb = d.hit(ctx, base_id + 71 + i, sr);
        var mb: [32]u8 = undefined;
        qa.mark(sr, "{s}", .{std.fmt.bufPrint(&mb, "mascot-eye-color:{d}", .{i}) catch "mascot-eye-color"});
        const cx = sr.x + sr.w / 2;
        const cy = sr.y + sr.h / 2;
        if (on or hb.hovered) c.ImDrawList_AddCircleEx(p.dl, d.v(cx, cy), 12.5, (if (on) ctx.col(.accent) else ctx.col(.muted)).u(), 0, 2, 0);
        d.circle(p.dl, cx, cy, 9.5, col);
        c.ImDrawList_AddCircleEx(p.dl, d.v(cx, cy), 9.5, ctx.col(.text).alpha(0.3).u(), 0, 1, 0);
        if (hb.clicked and !on) {
            var nl = l.*;
            nl.right_eye = col;
            apply(ctx, nl);
        }
    }
    // A caixa mostra a cor de agora quando ninguém está escrevendo nela.
    if (!eye_hex_active) {
        @memset(&eye_hex_buf, 0);
        var hb: [12]u8 = undefined;
        const h = visual.hexText(&hb, cur);
        @memcpy(eye_hex_buf[0..h.len], h);
    }
    d.rect(p.dl, hex_r, ctx.col(.bg), ctx.th.radius);
    d.border(p.dl, hex_r, if (eye_hex_active) ctx.col(.accent) else ctx.col(.border).mix(ctx.col(.text), 0.1), ctx.th.radius, 1);
    c.ImGui_SetCursorScreenPos(d.v(hex_r.x + 6, hex_r.y));
    c.ImGui_SetNextItemWidth(hex_r.w - 12);
    const enter = c.ImGui_InputText("##meyehex", &eye_hex_buf, eye_hex_buf.len, c.ImGuiInputTextFlags_CharsNoBlank | c.ImGuiInputTextFlags_EnterReturnsTrue);
    const done = enter or c.ImGui_IsItemDeactivatedAfterEdit();
    eye_hex_active = c.ImGui_IsItemActive();
    qa.mark(hex_r, "mascot-eye-hex", .{});
    if (done) {
        if (visual.parseColor(std.mem.sliceTo(&eye_hex_buf, 0))) |cc| {
            var nl = l.*;
            nl.right_eye = cc;
            if (!nl.eql(l)) apply(ctx, nl);
        }
        eye_hex_active = false;
    }
}

/// Pegar um olho ou a boca na prévia e arrastar: os olhos (juntos) e a boca andam para
/// os lados e para cima e para baixo, com os mesmos limites dos controles e um desfazer
/// por arraste. Pegou fora deles, nada acontece até soltar.
const Grab = enum { none, eyes, mouth, missed };
var grab: Grab = .none;
var grab_from: [2]f32 = .{ 0, 0 };
var grab_start: [2]i8 = .{ 0, 0 };
var grab_moved = false;

fn previewDrag(p: anytype, ph: d.Hit, cx: f32, cy: f32, size: f32, l: *const visual.Look) void {
    const ctx = p.ctx;
    const k = size * 0.78 / terminal.body_w;
    // Onde dá para pegar: em volta de cada olho e da boca.
    const er = 12 * k * l.eyeScale();
    var eyes_r: [2]d.Rect = undefined;
    for ([_]f32{ -1, 1 }, &eyes_r) |side, *q| {
        const e = l.eyeCenter(side);
        const pt = terminal.petPoint(cx, cy, size, e[0], e[1]);
        q.* = .{ .x = pt.x - er, .y = pt.y - er, .w = er * 2, .h = er * 2 };
    }
    const ms = l.mouthShift();
    const sm = l.mouthScale();
    const mp = terminal.petPoint(cx, cy, size, visual.mouth_ctr[0] + ms[0], visual.mouth_ctr[1] + ms[1]);
    const mouth_r: d.Rect = .{ .x = mp.x - 13 * k * sm, .y = mp.y - 7 * k * sm, .w = 26 * k * sm, .h = 14 * k * sm };
    qa.mark(eyes_r[0], "mascot-drag:eyes", .{});
    qa.mark(mouth_r, "mascot-drag:mouth", .{});
    const m = ctx.mouse;
    const over: Grab = if (eyes_r[0].contains(m.x, m.y) or eyes_r[1].contains(m.x, m.y)) .eyes else if (mouth_r.contains(m.x, m.y)) .mouth else .none;
    if ((ph.hovered and over != .none) or grab == .eyes or grab == .mouth) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeAll);
    if (!ph.held) {
        grab = .none;
        return;
    }
    if (grab == .none) {
        grab = if (over == .none) .missed else over;
        grab_from = .{ m.x, m.y };
        grab_start = if (grab == .eyes) .{ l.eye_x, l.eye_height } else .{ l.mouth_x, l.mouth_height };
        grab_moved = false;
    }
    if (grab != .eyes and grab != .mouth) return;
    const dx: i32 = @intFromFloat(@round((m.x - grab_from[0]) / k));
    const dy: i32 = @intFromFloat(@round((m.y - grab_from[1]) / k));
    const nx: i8 = @intCast(std.math.clamp(grab_start[0] + dx, -100, 100));
    const nh: i8 = @intCast(std.math.clamp(grab_start[1] - dy, -100, 100));
    var nl = l.*;
    if (grab == .eyes) {
        nl.setTweak(.eye_x, nx);
        nl.setEyeHeight(nh);
    } else {
        nl.setTweak(.mouth_x, nx);
        nl.setMouthHeight(nh);
    }
    if (nl.eql(l)) return;
    applyEx(ctx, nl, !grab_moved);
    grab_moved = true;
}

fn saveFile(ctx: *d.Ctx, l: *const visual.Look) void {
    const title = if (visual.presetOf(l)) |i| tr(visual.presets[i]) else i18n.tr("Meu mascote", "My mascot");
    var nb: [64]u8 = undefined;
    const name = arquivos.save(l, title, &nb) orelse {
        ctx.st.showToast(ctx.now_ms, true, "não deu para salvar o arquivo", "couldn't save the file", .{});
        return;
    };
    // Passa a usar o arquivo: o que for mudado nele aparece na hora (a lista e o visual
    // releem no começo do próximo quadro).
    useFile(ctx, name);
    anim.at(ctx.now_ms + 16);
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
