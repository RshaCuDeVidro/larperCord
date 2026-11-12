//! A folha de conferência do mascote (só no QA): todas as peças lado a lado, em cada
//! cara, na piscada, no erro, comendo e conectando, e em tamanhos pequenos, para ver de
//! uma vez se toda combinação ficou bonita. Fora do `--qa` não existe (qa.on() é falso
//! e, nos builds sem o robô, nem compila).
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const mascote = @import("mascote.zig");
const terminal = @import("mascote_terminal.zig");
const visual = @import("mascote_visual.zig");
const arquivos = @import("mascote_arquivos.zig");

pub const Sheet = enum(u8) { none, eyes0, eyes1, eyes2, mouth0, mouth1, mouth2, hats0, hats1, acc, ears, small, palettes, combos, detail, community };

/// A folha que o QA pediu (none: a página de sempre).
pub var sheet: Sheet = .none;

const Col = struct { face: visual.Face = .prompt, blink: ?f32 = null, xeyes: bool = false, eat: f32 = 0, dots: bool = false, name: []const u8 };
const cols = [_]Col{
    .{ .name = "normal" },
    .{ .face = .happy, .name = "happy" },
    .{ .face = .laugh, .name = "laugh" },
    .{ .face = .startled, .name = "startled" },
    .{ .face = .angry, .name = "angry" },
    .{ .face = .sad, .name = "sad" },
    .{ .face = .sleep, .name = "sleep" },
    .{ .face = .dizzy, .name = "dizzy" },
    .{ .face = .worried, .name = "worried" },
    .{ .blink = 0.42, .name = "blink" },
    .{ .xeyes = true, .name = "error" },
    .{ .eat = 0.8, .name = "eat" },
    .{ .dots = true, .name = "dots" },
};

pub fn draw(ctx: *d.Ctx) bool {
    if (!qa.on() or sheet == .none) return false;
    const dl = ctx.fg;
    const win = ctx.win;
    d.rect(dl, win, ctx.col(.bg), 0);
    const font = ctx.ui.get(.semibold);
    switch (sheet) {
        .eyes0, .eyes1, .eyes2 => {
            const page: usize = @intFromEnum(sheet) - @intFromEnum(Sheet.eyes0);
            grid(ctx, dl, font, page, true);
        },
        .mouth0, .mouth1, .mouth2 => {
            const page: usize = @intFromEnum(sheet) - @intFromEnum(Sheet.mouth0);
            grid(ctx, dl, font, page, false);
        },
        .hats0, .hats1 => {
            const from: usize = if (sheet == .hats0) 0 else 12;
            var i: usize = from;
            while (i < @min(from + 12, visual.hat_info.len)) : (i += 1) {
                var l: visual.Look = .{};
                l.hat = @enumFromInt(i);
                cell(ctx, dl, font, i - from, 6, 200, l, .{}, visual.hat_info[i].id, 1.0);
            }
        },
        .acc => {
            for (visual.acc_info, 0..) |a, i| {
                var l: visual.Look = .{ .eyes = .dots, .mouth = .smile };
                l.toggle(@enumFromInt(i));
                cell(ctx, dl, font, i, 6, 200, l, .{}, a.id, 1.15);
            }
        },
        .ears => {
            for (visual.ears_info, 0..) |e, i| {
                var l: visual.Look = .{};
                l.ears = @enumFromInt(i);
                cell(ctx, dl, font, i, 6, 220, l, .{}, e.id, 1.0);
                var l2 = l;
                l2.hat = .crown;
                cell(ctx, dl, font, i + 6, 6, 220, l2, .{ .face = .happy }, e.id, 1.0);
            }
        },
        .small => {
            // Os prontos em 28, 40 e 64 px (o ícone pequeno e o do canto).
            const sizes = [_]f32{ 28, 40, 64 };
            for (visual.presets, 0..) |pr, i| {
                for (sizes, 0..) |sz, j| {
                    const x = win.x + 30 + @as(f32, @floatFromInt(i % 8)) * 155 + @as(f32, @floatFromInt(j)) * 46 + sz * 0.3;
                    const y = win.y + 60 + @as(f32, @floatFromInt(i / 8)) * 300 + @as(f32, @floatFromInt(j)) * 80;
                    const was = mascote.borrow(&pr.look);
                    terminal.showcase(dl, x, y, sz, .{ .t = 0.5 });
                    mascote.restore(was);
                }
                d.text(dl, font, 12, win.x + 30 + @as(f32, @floatFromInt(i % 8)) * 155, win.y + 20 + @as(f32, @floatFromInt(i / 8)) * 300, ctx.col(.muted), pr.id);
            }
        },
        .palettes => {
            for (visual.palettes, 0..) |pal, i| {
                var l: visual.Look = .{ .eyes = .big, .mouth = .cat, .hat = .beanie, .acc = visual.bits(&.{ .blush, .bowtie }) };
                l.usePalette(@intCast(i));
                cell(ctx, dl, font, i, 7, 170, l, .{}, pal.id, 1.0);
            }
        },
        .combos => {
            // O que o mascote do canto faz junto: fone, fita, olheiras de cada estilo.
            for (visual.presets, 0..) |pr, i| {
                const sh: terminal.Show = .{ .headset = i % 2 == 0, .tape = i % 4 == 0, .face = if (i % 3 == 0) .happy else .prompt };
                cell(ctx, dl, font, i, 8, 180, pr.look, sh, pr.id, 1.0);
            }
        },
        .detail => {
            // De perto, as peças com mais detalhe.
            const looks = [_]visual.Look{
                .{ .eyes = .dots, .acc = visual.bits(&.{.scarf}) },
                .{ .eyes = .ovals, .mouth = .grin, .acc = visual.bits(&.{.mustache}) },
                .{ .ears = .floppy, .eyes = .big, .mouth = .tongue },
                .{ .hat = .cap, .eyes = .sleepy, .mouth = .smirk },
                .{ .hat = .horns, .ears = .tiny, .eyes = .wink, .mouth = .fang },
                .{ .eyes = .lashes, .mouth = .pout, .acc = visual.bits(&.{ .earring, .blush, .freckles }) },
                .{ .eyes = .pixel, .mouth = .cursor, .acc = visual.bits(&.{ .bandaid, .bowtie }) },
                .{ .eyes = .binary, .mouth = .whistle, .hat = .propeller },
            };
            for (looks, 0..) |l, i| cell(ctx, dl, font, i, 4, 400, l, .{}, "", 1.05);
        },
        .community => {
            // Os arquivos da pasta, um por linha, em quatro caras (as imagens da galeria
            // do site saem daqui).
            const faces = [_]visual.Face{ .prompt, .happy, .startled, .sleep };
            for (arquivos.list(), 0..) |*e, row| {
                if (row >= 4) break;
                for (faces, 0..) |f, j| cell(ctx, dl, font, row * 4 + j, 4, 200, e.look, .{ .face = f }, "", 1.1);
            }
        },
        .none => {},
    }
    return true;
}

fn cell(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, i: usize, per_row: usize, h: f32, l: visual.Look, sh: terminal.Show, name: []const u8, zoom: f32) void {
    const win = ctx.win;
    const w = win.w / @as(f32, @floatFromInt(per_row));
    const x = win.x + @as(f32, @floatFromInt(i % per_row)) * w;
    const y = win.y + @as(f32, @floatFromInt(i / per_row)) * h;
    const r: d.Rect = .{ .x = x + 4, .y = y + 4, .w = w - 8, .h = h - 8 };
    d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 10);
    const was = mascote.borrow(&l);
    defer mascote.restore(was);
    var s = sh;
    s.t = 0.5;
    s.light = ctx.col(.bg).luma() > 0.5;
    c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), true);
    terminal.showcase(dl, r.x + r.w / 2, r.y + r.h * 0.6, @min(r.w, r.h) * 0.72 * zoom, s);
    c.ImDrawList_PopClipRect(dl);
    d.text(dl, font, 12, r.x + 8, r.y + 6, ctx.col(.muted), name);
}

/// Linhas: os estilos (5 por página); colunas: as caras e os momentos.
fn grid(ctx: *d.Ctx, dl: *c.ImDrawList, font: *c.ImFont, page: usize, eyes: bool) void {
    const win = ctx.win;
    const n_rows: usize = 5;
    const total: usize = if (eyes) visual.eyes_info.len - 1 else visual.mouth_info.len - 1;
    const cw = win.w / @as(f32, @floatFromInt(cols.len));
    const rh = (win.h - 24) / @as(f32, @floatFromInt(n_rows));
    for (cols, 0..) |col, j| d.text(dl, font, 11, win.x + @as(f32, @floatFromInt(j)) * cw + 6, win.y + 4, ctx.col(.muted), col.name);
    var row: usize = 0;
    while (row < n_rows) : (row += 1) {
        const idx = page * n_rows + row;
        if (idx >= total) break;
        var l: visual.Look = .{};
        if (eyes) l.eyes = @enumFromInt(idx) else l.mouth = @enumFromInt(idx);
        const was = mascote.borrow(&l);
        defer mascote.restore(was);
        for (cols, 0..) |col, j| {
            const r: d.Rect = .{ .x = win.x + @as(f32, @floatFromInt(j)) * cw + 2, .y = win.y + 22 + @as(f32, @floatFromInt(row)) * rh + 2, .w = cw - 4, .h = rh - 4 };
            d.rect(dl, r, ctx.col(.rail).mix(ctx.col(.elevated), 0.4), 8);
            c.ImDrawList_PushClipRect(dl, d.v(r.x, r.y), d.v(r.right(), r.bottom()), true);
            // De perto: o rosto inteiro na célula.
            const size = r.w * 1.9;
            const k = size * 0.78 / terminal.body_w;
            terminal.showcase(dl, r.x + r.w / 2 - (63.5 - terminal.mid_x) * k, r.y + r.h / 2 - (58 - terminal.mid_y) * k, size, .{ .face = col.face, .t = 0.5, .blink = col.blink, .xeyes = col.xeyes, .mouth_open = col.eat, .dots = col.dots, .stage = false });
            c.ImDrawList_PopClipRect(dl);
        }
        const info = if (eyes) visual.eyes_info[idx] else visual.mouth_info[idx];
        d.text(dl, font, 11, win.x + 6, win.y + 22 + @as(f32, @floatFromInt(row)) * rh + 4, ctx.col(.text), info.id);
    }
}
