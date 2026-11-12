//! Qual mascote o app usa (Configurações → Aparência): o Terminal, o principal,
//! ou o Clássico, o da cara de deboche. Daqui saem o desenho animado da abertura,
//! o parado do "Sobre" e a prévia das Configurações; os ícones da janela, da
//! bandeja e do sistema trocam junto (ver App.applyMascot).
const c = @import("c");
const std = @import("std");
const anim = @import("anim.zig");
const d = @import("draw.zig");
const logo = @import("logo.zig");
const terminal = @import("mascote_terminal.zig");

pub const Kind = @import("mascote_contas.zig").Kind;

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
