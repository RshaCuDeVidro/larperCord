//! O mascote que mora num canto do app (Configurações → Aparência → "Mascote no
//! canto"). Mora num lugar dele na barra da caixa de mensagem, segue o mouse com os olhos,
//! digita junto, pula quando você manda mensagem e se assusta com menção. Ri, comemora,
//! fica triste ou acena com o que você escreve (tudo aqui no computador). Dorme depois
//! de uns minutos parado e acorda quando você volta. Dá para pegar e jogar (ele quica
//! nas bordas da janela, fica tonto e volta andando), fazer carinho (corações) e
//! cutucar: cutucado demais, fica bravo e emburra um tempo.
//!
//! Leve: parado, ele não acorda o app. Só anima por um instante quando algo acontece
//! (30 quadros por segundo numa reação, 60 só voando ou sendo arrastado), e só com a
//! janela em foco. Seguir o mouse com os olhos não custa nada: mexer o mouse já redesenha.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const anim = @import("anim.zig");
const qa = @import("qa.zig");
const mascote = @import("mascote.zig");
const terminal = @import("mascote_terminal.zig");
const logo = @import("logo.zig");
const contas = @import("mascote_contas.zig");

const Rgba = d.Rgba;

/// Largura do mascote do canto, em pixels (antes da escala da interface).
const base_size: f32 = 50;

const Mode = enum { home, grabbed, flying, dizzy, walking, away };

/// As reações de um instante (ui/mascote_contas.zig).
pub const Reaction = contas.Reaction;
pub const reactionFor = contas.reactionFor;

const State = struct {
    /// Centro do mascote na tela e a velocidade (pixels, pixels por segundo).
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    spin: f32 = 0,
    placed: bool = false,
    mode: Mode = .home,
    mode_ms: i64 = 0,
    /// Arrastando: onde o mouse pegou e quanto já andou.
    grab_dx: f32 = 0,
    grab_dy: f32 = 0,
    press_x: f32 = 0,
    press_y: f32 = 0,
    press_ms: i64 = 0,
    dragging: bool = false,
    react: Reaction = .none,
    react_ms: i64 = 0,
    pokes: u8 = 0,
    poke_ms: i64 = 0,
    pet_dist: f32 = 0,
    last_input_ms: i64 = 0,
    input_sig: u64 = 0,
    type_ms: i64 = -100_000,
};

var s: State = .{};
/// O lugar reservado para ele na barra da caixa de mensagem (ver comp_messages).
var home_slot: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var slot_ms: i64 = -100_000;

/// O lugar dele dentro da barra da caixa, à esquerda dos botões.
pub fn slot(r: d.Rect, now: i64) void {
    home_slot = r;
    slot_ms = now;
}

/// Uma reação começa agora (a de agora vale mais que uma pancada de tecla).
fn start(r: Reaction, now: i64) void {
    s.react = r;
    s.react_ms = now;
}

fn reactionSeconds(r: Reaction) f32 {
    return switch (r) {
        .none => 0,
        .hop, .poke => 0.7,
        .ping => 1.3,
        .laugh => 1.4,
        .gg => 1.8,
        .sad => 2.2,
        .wave => 1.6,
        .love => 1.6,
        .angry => 1.2,
        .wake => 0.9,
    };
}

/// Você mandou uma mensagem.
pub fn onSend(text: []const u8, now: i64) void {
    start(reactionFor(text), now);
    s.last_input_ms = now;
}

/// Chegou uma menção ou DM.
pub fn onPing(now: i64) void {
    if (s.mode != .home) return;
    start(.ping, now);
}

fn dist(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    return std.math.hypot(ax - bx, ay - by);
}

fn kick(since: f32, len: f32) f32 {
    if (since < 0 or since > len) return 0;
    const x = since / len;
    return @sin(std.math.pi * x) * (1 - x);
}

/// Quanto tempo (s) desde `ms`.
fn secs(now: i64, ms: i64) f32 {
    return @as(f32, @floatFromInt(now - ms)) / 1000.0;
}

/// Está escondido neste quadro? (Configurações, paleta, menu ou tela cheia por cima.)
fn hidden(ctx: *d.Ctx) bool {
    const st = ctx.st;
    return !st.settings.mascot_pet or st.settings.open or st.palette.open or st.popup != .none or ctx.now_ms - slot_ms > 250;
}

/// Desenha e anima o mascote do canto (por cima de tudo, depois da interface).
pub fn draw(ctx: *d.Ctx) void {
    const now = ctx.now_ms;
    if (hidden(ctx)) {
        // Voltando, ele já está em casa.
        if (s.mode == .home or ctx.now_ms - slot_ms > 250) s.placed = false;
        s.mode = .home;
        s.dragging = false;
        return;
    }
    // A escala da interface já vale para tudo (ver App.uiScale).
    const size = base_size;
    const k = size * 0.78 / 127.14;
    // Em casa: no lugar dele na barra da caixa, com a cabeça espiando por cima.
    const home_x = home_slot.x + home_slot.w / 2;
    const home_y = home_slot.bottom() - 4 - (99 - 42.5) * k;
    if (!s.placed) {
        s.x = home_x;
        s.y = home_y;
        s.mode = .home;
        s.placed = true;
        s.last_input_ms = now;
    }
    const dt = std.math.clamp(anim.dt, 0.001, 1.0 / 30.0);
    const mouse = ctx.mouse;
    const io = ctx.io;
    const focused = ctx.st.window_focused;

    // Mexeu em alguma coisa: acordado. Digitando: ele digita junto.
    const moved = io.*.MouseDelta.x != 0 or io.*.MouseDelta.y != 0 or c.ImGui_IsMouseDown(0);
    const sig = std.hash.Wyhash.hash(0, std.mem.sliceTo(&ctx.st.input, 0));
    const typed = sig != s.input_sig;
    s.input_sig = sig;
    const asleep_before = now - s.last_input_ms > sleep_ms and s.mode == .home;
    if (moved or typed) {
        if (asleep_before) start(.wake, now);
        s.last_input_ms = now;
    }
    if (typed) s.type_ms = now;

    // --- Clique, arrasto, carinho e cutucada ----------------------------------
    // A área do clique é a janela inteira, e só ela: em casa, o lugar dele na barra
    // (nada mais mora ali); fora de casa (voando, tonto, voltando), o próprio corpo.
    const at_home = s.mode == .home or s.mode == .away;
    const hit_w = if (at_home) home_slot.w else size * 0.86;
    const hit_h = if (at_home) home_slot.h else size * 0.8;
    const hit_min = if (at_home) d.v(home_slot.x, home_slot.y) else d.v(s.x - hit_w / 2, s.y - hit_h / 2);
    c.ImGui_SetNextWindowPos(hit_min, 0);
    c.ImGui_SetNextWindowSize(d.v(hit_w, hit_h), 0);
    _ = c.ImGui_Begin("##pet", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav |
        c.ImGuiWindowFlags_NoFocusOnAppearing);
    d.windowToFront();
    c.ImGui_SetCursorScreenPos(hit_min);
    _ = c.ImGui_InvisibleButton("##pet-hit", d.v(hit_w, hit_h), c.ImGuiButtonFlags_MouseButtonLeft);
    const hovered = c.ImGui_IsItemHovered(0);
    const active = c.ImGui_IsItemActive();
    const pressed = c.ImGui_IsItemActivated();
    const released = c.ImGui_IsItemDeactivated();
    c.ImGui_End();
    qa.mark(.{ .x = hit_min.x, .y = hit_min.y, .w = hit_w, .h = hit_h }, "pet", .{});
    if (hovered or active) c.ImGui_SetMouseCursor(if (active and s.dragging) c.ImGuiMouseCursor_ResizeAll else c.ImGuiMouseCursor_Hand);

    if (pressed) {
        s.press_x = mouse.x;
        s.press_y = mouse.y;
        s.press_ms = now;
        s.grab_dx = s.x - mouse.x;
        s.grab_dy = s.y - mouse.y;
        s.dragging = false;
    }
    if (active and !s.dragging and dist(mouse.x, mouse.y, s.press_x, s.press_y) > 6) {
        s.dragging = true;
        s.mode = .grabbed;
        s.mode_ms = now;
        s.react = .none;
    }
    if (active and s.dragging) {
        const nx = mouse.x + s.grab_dx;
        const ny = mouse.y + s.grab_dy;
        // Velocidade suavizada, para o arremesso sair do jeito que a mão mexeu.
        s.vx = s.vx * 0.6 + (nx - s.x) / dt * 0.4;
        s.vy = s.vy * 0.6 + (ny - s.y) / dt * 0.4;
        s.x = nx;
        s.y = ny;
        s.spin = std.math.clamp(s.vx * 0.0006, -0.6, 0.6);
    }
    if (released) {
        if (s.dragging) {
            s.mode = .flying;
            s.mode_ms = now;
            s.vx = std.math.clamp(s.vx, -2600, 2600);
            s.vy = std.math.clamp(s.vy, -2600, 2600);
        } else poke(now);
        s.dragging = false;
    }
    // Carinho: o mouse passando devagar por cima, sem clicar.
    if (hovered and !active and s.mode == .home) {
        const md = std.math.hypot(io.*.MouseDelta.x, io.*.MouseDelta.y);
        if (md > 0 and md < 30) s.pet_dist += md;
        if (s.pet_dist > 70) {
            s.pet_dist = 0;
            if (s.react != .love or secs(now, s.react_ms) > 0.8) start(.love, now);
        }
    } else s.pet_dist = 0;

    // --- Física e caminhada ----------------------------------------------------------
    const win = ctx.win;
    const r = size * 0.42;
    switch (s.mode) {
        .home => {
            s.x = home_x;
            s.y = home_y;
            s.spin = 0;
        },
        .grabbed => {},
        .flying => {
            s.vy += 2600 * dt;
            s.x += s.vx * dt;
            s.y += s.vy * dt;
            s.spin += s.vx * dt * 0.012;
            if (s.x < win.x + r) {
                s.x = win.x + r;
                s.vx = -s.vx * 0.62;
            } else if (s.x > win.right() - r) {
                s.x = win.right() - r;
                s.vx = -s.vx * 0.62;
            }
            if (s.y < win.y + r) {
                s.y = win.y + r;
                s.vy = -s.vy * 0.5;
            }
            const floor = win.bottom() - r;
            if (s.y > floor) {
                s.y = floor;
                s.vy = -s.vy * 0.55;
                s.vx *= 0.82;
                if (@abs(s.vy) < 140) {
                    s.vy = 0;
                    if (@abs(s.vx) < 70) {
                        s.vx = 0;
                        s.mode = .dizzy;
                        s.mode_ms = now;
                    }
                }
            }
            // Perdido por muito tempo (um arremesso de lado infinito): volta.
            if (secs(now, s.mode_ms) > 6) {
                s.mode = .dizzy;
                s.mode_ms = now;
            }
        },
        .dizzy => {
            s.spin *= 0.85;
            if (secs(now, s.mode_ms) > 1.6) {
                s.mode = .walking;
                s.mode_ms = now;
            }
        },
        .walking => {
            const dd = dist(s.x, s.y, home_x, home_y);
            s.spin *= 0.8;
            if (dd < 4) {
                s.x = home_x;
                s.y = home_y;
                s.mode = .home;
                s.mode_ms = now;
                start(.wave, now);
            } else {
                const step = @min(300 * dt, dd);
                s.x += (home_x - s.x) / dd * step;
                s.y += (home_y - s.y) / dd * step;
            }
        },
        .away => {
            // Emburrado: encolhe no lugar dele um tempo e depois volta ao normal.
            s.x = home_x;
            s.y = home_y;
            if (secs(now, s.mode_ms) > sulk_s) {
                s.mode = .home;
                s.mode_ms = now;
                start(.wave, now);
            }
        },
    }

    // --- Pose -------------------------------------------------------------------------
    var pl: terminal.PetLook = .{};
    // Os olhos seguem o mouse.
    const lx = std.math.clamp((mouse.x - s.x) / 220, -1, 1);
    const ly = std.math.clamp((mouse.y - s.y) / 160, -1, 1);
    pl.look = .{ lx, ly };
    if (mouse.x < -1000) pl.look = .{ 0, 0 };
    pl.spin = s.spin;
    var bob: f32 = 0;
    var shrink: f32 = 1;
    var anim_until: i64 = 0;
    const asleep = s.mode == .home and now - s.last_input_ms > sleep_ms and s.react == .none;
    if (asleep) {
        pl.face = .sleep;
        pl.ears = 0.22;
    }
    // Digitando: o cursor pisca rápido e o rosto pula a cada tecla.
    const since_type = secs(now, s.type_ms);
    if (since_type < 0.7 and s.mode == .home) {
        pl.cursor = @mod(now, 300) < 170;
        pl.pop = kick(since_type, 0.16) * 1.3;
        pl.look = .{ -0.6, 0.5 };
        anim_until = s.type_ms + 700;
    }
    switch (s.mode) {
        .grabbed => {
            pl.face = .startled;
            pl.squash = -0.1;
            pl.ears = -0.15;
        },
        .flying => {
            pl.face = .startled;
            pl.squash = std.math.clamp(-s.vy * 0.00006, -0.12, 0.12);
        },
        .dizzy => {
            pl.face = .dizzy;
            pl.squash = kick(secs(now, s.mode_ms), 0.25) * 0.25;
        },
        .walking => {
            const wt = secs(now, s.mode_ms);
            bob = -@abs(@sin(wt * 11)) * size * 0.12;
            pl.look = .{ if (home_x < s.x) -1 else 1, 0 };
        },
        .away => {
            const at = secs(now, s.mode_ms);
            pl.face = if (at < 2.5) .angry else .sad;
            pl.look = .{ -1, 0.3 };
            pl.ears = 0.3;
            // Encolhe ao emburrar e cresce de volta no fim.
            shrink = 1 - 0.38 * std.math.clamp(at / 0.3, 0, 1) * std.math.clamp((sulk_s - at) / 0.3, 0, 1);
            anim_until = s.mode_ms + 2600;
            if (at > sulk_s - 0.35) anim_until = now + 50;
        },
        .home => {},
    }
    // Reações de um instante.
    const rt = secs(now, s.react_ms);
    if (s.react != .none and rt > reactionSeconds(s.react)) s.react = .none;
    if (s.react != .none and (s.mode == .home or s.mode == .away)) {
        anim_until = s.react_ms + @as(i64, @intFromFloat(reactionSeconds(s.react) * 1000));
        switch (s.react) {
            .none => {},
            .hop => {
                bob = -kick(rt, 0.5) * size * 0.35;
                pl.squash = kick(rt - 0.45, 0.2) * 0.2;
                pl.face = .happy;
            },
            .poke => {
                pl.face = if (rt < 0.25) .startled else .happy;
                pl.squash = kick(rt, 0.18) * 0.25;
                bob = -kick(rt - 0.1, 0.35) * size * 0.15;
            },
            .ping => {
                pl.face = .startled;
                bob = -kick(rt, 0.3) * size * 0.3;
                pl.ears = -0.25;
            },
            .laugh => {
                pl.face = .laugh;
                pl.spin = @sin(rt * 30) * 0.08 * (1 - rt / 1.4);
                bob = -@abs(@sin(rt * 14)) * size * 0.06;
            },
            .gg => {
                pl.face = .happy;
                bob = -kick(rt, 0.6) * size * 0.45;
                pl.spin = std.math.tau * std.math.clamp(rt / 0.6, 0, 1) * @as(f32, if (rt < 0.6) 1 else 0);
            },
            .sad => {
                pl.face = .sad;
                pl.ears = 0.35;
                pl.look = .{ 0, 0.8 };
            },
            .wave => {
                pl.face = .happy;
                pl.wave = @sin(rt * 14) * 0.3 * (1 - rt / 1.6);
            },
            .love => {
                pl.face = .happy;
                pl.ears = 0.12;
                pl.squash = @sin(rt * 9) * 0.05;
            },
            .angry => {
                pl.face = .angry;
                pl.spin = @sin(rt * 40) * 0.06;
            },
            .wake => {
                pl.face = if (rt < 0.35) .startled else .prompt;
                bob = -kick(rt, 0.3) * size * 0.2;
            },
        }
    }

    // --- Quadros: só enquanto algo anima, e só com a janela em foco ----------------------
    if (focused) {
        if (s.mode == .grabbed or s.mode == .flying or s.mode == .walking or s.mode == .dizzy) {
            anim.active = true;
        } else if (anim_until > now) {
            anim.at(now + 33);
        } else if (asleep) {
            // Os "Z" sobem uns segundos depois de dormir e param.
            const zt = secs(now, s.last_input_ms + sleep_ms);
            if (zt < 8) anim.at(now + 66);
        } else if (s.mode == .home) {
            // A hora de dormir: um quadro só.
            anim.at(s.last_input_ms + sleep_ms + 10);
        }
    }

    // --- Desenho (por cima de tudo) ------------------------------------------------------
    const dl = ctx.fg;
    const cx = s.x;
    // Encolhido, os pés ficam no mesmo lugar.
    const cy = s.y + bob + (1 - shrink) * (99 - 42.5) * k;
    const dsize = size * shrink;
    switch (mascote.Kind.of(ctx.st.settings.mascot)) {
        .terminal => terminal.pet(dl, cx, cy, dsize, pl),
        .classico => {
            var pose: logo.Pose = .{ .glow = 0.3, .look = pl.look };
            pose.eyes = switch (pl.face) {
                .sleep, .laugh => 0,
                .happy => 1.15,
                .startled => 1.2,
                .angry, .sad => 0.55,
                else => 1,
            };
            pose.spin = s.spin * 3 + pl.wave * 4;
            logo.draw(dl, cx, cy, dsize * 1.12, pose);
        },
    }
    effects(dl, now, cx, cy, size, asleep, rt);
}

const sleep_ms: i64 = 3 * 60 * 1000;
/// Quanto tempo ele fica emburrado.
const sulk_s: f32 = 8;

fn poke(now: i64) void {
    s.pokes = if (now - s.poke_ms < 1500) s.pokes + 1 else 1;
    s.poke_ms = now;
    if (s.pokes >= 5 and s.mode == .home) {
        // Cutucado demais: fica bravo e emburra (encolhe no canto uns segundos).
        s.pokes = 0;
        start(.angry, now);
        s.mode = .away;
        s.mode_ms = now;
        return;
    }
    start(if (s.pokes >= 3) .angry else .poke, now);
}

/// Os enfeites de cada reação: corações, confete, "!", "Z", estrelinhas de tontura.
fn effects(dl: *c.ImDrawList, now: i64, cx: f32, cy: f32, size: f32, asleep: bool, rt: f32) void {
    const top = cy - size * 0.55;
    switch (s.react) {
        .love => for (0..4) |i| {
            const fi: f32 = @floatFromInt(i);
            const f = std.math.clamp((rt - fi * 0.18) / 1.0, 0, 1);
            if (f <= 0 or f >= 1) continue;
            const hx = cx + (fi - 1.5) * size * 0.22 + @sin(f * 6 + fi) * size * 0.06;
            const hy = top - f * size * 0.7;
            heart(dl, hx, hy, size * 0.085 * (0.7 + 0.5 * f), Rgba.hex(0xFF5FA8).col(1 - f));
        },
        .gg => for (0..18) |i| {
            const fi: f32 = @floatFromInt(i);
            const f = std.math.clamp(rt / 1.6, 0, 1);
            const ang = fi / 18.0 * std.math.tau + fi * 0.37;
            const sp = size * (0.9 + @mod(fi * 0.37, 0.6));
            const px = cx + @cos(ang) * sp * f;
            const py = top + @sin(ang) * sp * f * 0.6 + f * f * size * 1.1;
            const cols = [_]u32{ 0xFF5FA8, 0x29E6FF, 0xF7E04A, 0x9D40FF, 0x4AD957 };
            const q = size * 0.045;
            const rot = fi + rt * 8;
            const ax = @cos(rot) * q;
            const ay = @sin(rot) * q;
            c.ImDrawList_AddQuadFilled(dl, d.v(px - ax, py - ay), d.v(px - ay, py + ax), d.v(px + ax, py + ay), d.v(px + ay, py - ax), Rgba.hex(cols[i % cols.len]).col(1 - f));
        },
        .ping, .angry => {
            // "!" em cima da cabeça.
            const a = std.math.clamp(1 - (rt - 0.9) / 0.4, 0, 1);
            const pop = 1 + kick(rt, 0.25) * 0.6;
            const h = size * 0.24 * pop;
            const w = size * 0.07 * pop;
            const col = (if (s.react == .angry) Rgba.hex(0xFF4A5A) else Rgba.hex(0xF7E04A)).col(a);
            const ex = cx + size * 0.42;
            c.ImDrawList_AddRectFilledEx(dl, d.v(ex - w / 2, top - h), d.v(ex + w / 2, top - h * 0.25), col, w / 2, 0);
            c.ImDrawList_AddCircleFilled(dl, d.v(ex, top), w * 0.62, col, 0);
        },
        .laugh => for (0..3) |i| {
            const fi: f32 = @floatFromInt(i);
            const f = std.math.clamp((rt - fi * 0.25) / 0.8, 0, 1);
            if (f <= 0 or f >= 1) continue;
            const side: f32 = if (i % 2 == 0) 1 else -1;
            const hx = cx + side * size * (0.5 + f * 0.25);
            const hy = top + size * 0.15 - f * size * 0.35;
            const col = Rgba.hex(0xB98CFF).col(1 - f);
            const l = size * 0.08;
            c.ImDrawList_AddLineEx(dl, d.v(hx - l, hy - l), d.v(hx - l, hy + l), col, @max(size * 0.03, 1), 0);
            c.ImDrawList_AddLineEx(dl, d.v(hx + l, hy - l), d.v(hx + l, hy + l), col, @max(size * 0.03, 1), 0);
            c.ImDrawList_AddLineEx(dl, d.v(hx - l, hy), d.v(hx + l, hy), col, @max(size * 0.03, 1), 0);
        },
        else => {},
    }
    if (s.mode == .dizzy) {
        // Estrelinhas girando em volta da cabeça.
        const t = secs(now, s.mode_ms);
        for (0..3) |i| {
            const a = t * 6 + @as(f32, @floatFromInt(i)) * std.math.tau / 3.0;
            const px = cx + @cos(a) * size * 0.42;
            const py = top + @sin(a) * size * 0.1;
            star(dl, px, py, size * 0.06, Rgba.hex(0xF7E04A).col(1));
        }
    }
    if (asleep) {
        const zt = @min(secs(now, s.last_input_ms + sleep_ms), 8);
        terminal.zzz(dl, d.v(cx + size * 0.32, top + size * 0.1), size / 150, zt, 1);
    }
}

fn heart(dl: *c.ImDrawList, x: f32, y: f32, r: f32, col: u32) void {
    c.ImDrawList_AddCircleFilled(dl, d.v(x - r * 0.55, y), r * 0.62, col, 0);
    c.ImDrawList_AddCircleFilled(dl, d.v(x + r * 0.55, y), r * 0.62, col, 0);
    c.ImDrawList_AddTriangleFilled(dl, d.v(x - r * 1.12, y + r * 0.2), d.v(x + r * 1.12, y + r * 0.2), d.v(x, y + r * 1.35), col);
}

fn star(dl: *c.ImDrawList, x: f32, y: f32, r: f32, col: u32) void {
    c.ImDrawList_AddQuadFilled(dl, d.v(x, y - r * 1.6), d.v(x + r * 0.45, y), d.v(x, y + r * 1.6), d.v(x - r * 0.45, y), col);
    c.ImDrawList_AddQuadFilled(dl, d.v(x - r * 1.6, y), d.v(x, y - r * 0.45), d.v(x + r * 1.6, y), d.v(x, y + r * 0.45), col);
}

// --- Para o QA ---------------------------------------------------------------------

pub fn mode() Mode {
    return s.mode;
}
pub fn reaction() Reaction {
    return s.react;
}
pub fn position() [2]f32 {
    return .{ s.x, s.y };
}
pub fn isAsleep(now: i64) bool {
    return s.mode == .home and now - s.last_input_ms > sleep_ms and s.react == .none;
}
/// Volta para casa na hora (o QA não espera ele voltar andando).
pub fn qaHome() void {
    s.mode = .home;
    s.react = .none;
    s.pokes = 0;
}
/// Faz de conta que ninguém mexe há tanto tempo (o QA não espera três minutos).
pub fn qaIdleFor(ms: i64, now: i64) void {
    s.last_input_ms = now - ms;
}
