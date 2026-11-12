//! Qual mascote o app usa (Configurações → Aparência): o Terminal, o principal,
//! ou o Clássico, o da cara de deboche. Daqui saem o desenho animado da abertura,
//! o parado do "Sobre" e a prévia das Configurações; os ícones da janela, da
//! bandeja e do sistema trocam junto (ver App.applyMascot). Daqui sai também o
//! visual do Terminal de cada quadro (`sync`), o personalizado ou o de um arquivo.
const c = @import("c");
const std = @import("std");
const anim = @import("anim.zig");
const d = @import("draw.zig");
const logo = @import("logo.zig");
const terminal = @import("mascote_terminal.zig");
const visual = @import("mascote_visual.zig");
const arquivos = @import("mascote_arquivos.zig");

pub const Kind = @import("mascote_contas.zig").Kind;

// --- O visual (Configurações → Mascote → Personalizar) ------------------------------

/// O que o último `sync` viu (para não refazer o visual a cada quadro).
var seen_text: [255]u8 = undefined;
var seen_text_len: usize = std.math.maxInt(usize);
var seen_file: [visual.Name.max_name]u8 = undefined;
var seen_file_len: usize = 0;
var seen_gen: u32 = 0;
var seen_accent: u32 = 0;

/// O visual deste quadro, a partir das configurações (`mascot_look`, o texto curto, e
/// `mascot_file`, o arquivo escolhido) e da cor de destaque do tema. Chamado pelo app
/// uma vez por quadro; só refaz quando algo mudou. Um arquivo com erro deixa o visual
/// que estava (como um tema com erro deixa o tema de antes).
pub fn sync(look_text: []const u8, file: []const u8, accent: d.Rgba) void {
    arquivos.frame();
    if (file.len > 0 or std.mem.indexOf(u8, look_text, "draw=") != null) arquivos.ensure();
    const acc = accent.col(1);
    if (seen_text_len == look_text.len and std.mem.eql(u8, seen_text[0..look_text.len], look_text) and
        std.mem.eql(u8, seen_file[0..seen_file_len], file) and seen_gen == arquivos.generation and seen_accent == acc) return;
    const n = @min(look_text.len, seen_text.len);
    @memcpy(seen_text[0..n], look_text[0..n]);
    seen_text_len = n;
    const fl = @min(file.len, seen_file.len);
    @memcpy(seen_file[0..fl], file[0..fl]);
    seen_file_len = fl;
    seen_gen = arquivos.generation;
    seen_accent = acc;
    terminal.accent = accent;
    terminal.look = resolve(look_text, file, terminal.look);
    terminal.colors = terminal.look.colorsFor(accent, false);
}

/// O visual pedido: o do arquivo, se houver um escolhido (e sem erro), ou o do texto
/// curto, com os desenhos do arquivo de onde vierem.
fn resolve(look_text: []const u8, file: []const u8, before: visual.Look) visual.Look {
    if (file.len > 0) {
        if (arquivos.find(file)) |e| {
            if (e.problem == null) return e.look;
            // Com erro: fica o que estava, se era deste arquivo.
            if (std.mem.eql(u8, before.draw_from.slice(), file) or before.drawing == null) return before;
        }
    }
    var l = visual.parseCompact(look_text);
    if (l.draw_from.len > 0) {
        if (arquivos.find(l.draw_from.slice())) |e| l.drawing = e.drawing;
    }
    // Sem os desenhos, as peças "do arquivo" voltam às de sempre.
    const dw = l.drawing;
    if (l.eyes == .custom and (dw == null or !dw.?.hasLayer(.eyes))) l.eyes = .prompt;
    if (l.mouth == .custom and (dw == null or !dw.?.hasLayer(.mouth))) l.mouth = .smile;
    return l;
}

/// O visual de agora.
pub fn current() *const visual.Look {
    return &terminal.look;
}

/// Desenhar com outro visual por um instante (as prévias e as miniaturas): troca e
/// devolve o de antes para `restore`.
pub const Saved = struct { look: visual.Look, colors: visual.Colors };
pub fn borrow(l: *const visual.Look) Saved {
    const was: Saved = .{ .look = terminal.look, .colors = terminal.colors };
    terminal.look = l.*;
    terminal.colors = l.colorsFor(terminal.accent, false);
    return was;
}
pub fn restore(s: Saved) void {
    terminal.look = s.look;
    terminal.colors = s.colors;
}

/// O visual que ficou salvo no settings.kdl mudou por fora (desfazer, QA): o próximo
/// `sync` refaz.
pub fn invalidate() void {
    seen_text_len = std.math.maxInt(usize);
}

/// Parado e pequeno ("Sobre", barra de título).
pub fn still(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32) void {
    switch (kind) {
        .terminal => terminal.still(dl, cx, cy, size),
        .classico => logo.still(dl, cx, cy, size),
    }
}

/// A abertura sozinha, sem a tela de login (a prévia das Configurações): `t` em
/// segundos desde o começo.
pub fn preview(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, t: f32, light: bool, reduce: bool, opening: terminal.Opening) void {
    switch (kind) {
        .terminal => terminal.draw(dl, cx, cy, size, .{ .t = t, .light = light, .reduce = reduce, .opening = opening }),
        .classico => logo.draw(dl, cx, cy, size, if (reduce) .{} else logo.introPose(t)),
    }
}

/// Quanto dura a abertura de cada um (depois disso, a prévia pode parar).
pub fn introSeconds(kind: Kind, opening: terminal.Opening) f32 {
    return switch (kind) {
        .terminal => terminal.openingSeconds(opening),
        .classico => 1.5,
    };
}

/// A abertura desta vez: a escolhida, ou uma sorteada (`mascot_opening` = 5).
pub const pickOpening = @import("mascote_contas.zig").pickOpening;

// --- Momentos dentro do app ----------------------------------------------------

pub const Mood = terminal.Mood;
pub const reaction_seconds = terminal.reaction_seconds;

/// Um momento do app com o mascote escolhido (ver mascote_terminal.moment). O
/// Clássico usa as poses que já tem: olhos fechados, olhando de lado, a estrela.
pub fn moment(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, mood: Mood, t: f32, light: bool, react_t: f32, variant: u8) void {
    switch (kind) {
        .terminal => terminal.moment(dl, cx, cy, size, mood, t, light, react_t, variant),
        .classico => {
            var pose: logo.Pose = .{ .glow = 0.4 };
            var y = cy;
            switch (mood) {
                .sleep => {
                    pose.eyes = 0;
                    pose.star = 0.7;
                },
                .offline => {
                    pose.eyes = 0.35;
                    pose.look = .{ 0, 1 };
                    pose.spin = @sin(t * 7) * 0.15;
                },
                .loading => {
                    pose.look = .{ @sin(t * 2.4), -0.3 };
                    pose.spin = t * 2;
                },
            }
            if (react_t >= 0 and react_t < reaction_seconds) {
                const x = react_t / 0.55;
                const up = if (x < 1) @sin(std.math.pi * x) * (1 - x) else 0;
                y -= size * 0.14 * up;
                pose.spin = react_t * 12;
                pose.star = 1 + up * 0.6;
                pose.eyes = 1.15;
            }
            logo.draw(dl, cx, y, size, pose);
            if (mood == .sleep and (react_t < 0 or react_t >= reaction_seconds)) terminal.zzz(dl, .{ .x = cx + size * 0.36, .y = cy - size * 0.24 }, size / 150, t, 1);
        },
    }
}

/// Onde cada momento aparece (cada lugar conta o próprio tempo).
pub const Spot = enum(u8) { inbox, pins, saved, friends, history, offline, about, login };

var spot_from: [@typeInfo(Spot).@"enum".field_names.len]i64 = @splat(0);
var spot_seen: [@typeInfo(Spot).@"enum".field_names.len]i64 = @splat(-100_000);

/// Segundos desde que o lugar apareceu: sumiu por mais de meio segundo, começa de novo.
pub fn age(spot: Spot, now: i64) f32 {
    const i = @backingInt(spot);
    if (now - spot_seen[i] > 500) spot_from[i] = now;
    spot_seen[i] = now;
    return @as(f32, @floatFromInt(now - spot_from[i])) / 1000.0;
}

/// Pede o próximo quadro a 15 por segundo enquanto o momento anima, só com a
/// janela em foco; depois de `until` segundos ele para. Devolve o `t` para desenhar
/// (parado no fim).
pub fn pace(now: i64, t: f32, until: f32, focused: bool) f32 {
    if (t >= until) return until;
    if (focused) anim.at(now + 66);
    return t;
}

/// O mascote escolhido num momento do app, no lugar `spot`: anima por `until`
/// segundos (a 15 quadros por segundo, só com a janela em foco) e para.
pub fn inApp(ctx: *d.Ctx, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, mood: Mood, spot: Spot, until: f32) void {
    const t = pace(ctx.now_ms, age(spot, ctx.now_ms), until, ctx.st.window_focused);
    moment(.of(ctx.st.settings.mascot), dl, cx, cy, size, mood, t, ctx.col(.bg).luma() > 0.5, -1, 0);
}

/// Parado (respirando, piscando) e reagindo a cliques: o "Sobre". `t` em segundos;
/// `react_t`: segundos desde o clique (negativo: nenhum).
pub fn idle(kind: Kind, dl: *c.ImDrawList, cx: f32, cy: f32, size: f32, t: f32, light: bool, react_t: f32, variant: u8) void {
    switch (kind) {
        .terminal => terminal.draw(dl, cx, cy, size, .{ .t = 2.6 + t, .light = light, .react = react_t, .react_variant = variant }),
        .classico => {
            var pose = logo.introPose(3 + t);
            var y = cy;
            if (react_t >= 0 and react_t < reaction_seconds) {
                const x = react_t / 0.55;
                const up = if (x < 1) @sin(std.math.pi * x) * (1 - x) else 0;
                y -= size * 0.14 * up;
                pose.spin = react_t * 12;
                pose.star = 1 + up * 0.6;
                pose.eyes = 1.15;
            }
            logo.draw(dl, cx, y, size, pose);
        },
    }
}
