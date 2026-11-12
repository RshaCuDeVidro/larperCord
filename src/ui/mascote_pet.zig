//! O mascote que mora num canto do app (Configurações → Aparência → "Mascote no
//! canto"). Mora num lugar dele na barra da caixa de mensagem, segue o mouse com os olhos,
//! digita junto, pula quando você manda mensagem e se assusta com menção. Ri, comemora,
//! fica triste ou acena com o que você escreve (tudo aqui no computador). Dorme depois
//! de uns minutos parado e acorda quando você volta. Dá para pegar e jogar (ele quica
//! nas bordas da janela, fica tonto e volta andando), fazer carinho (corações) e
//! cutucar: cutucado demais, fica bravo e emburra um tempo (cada vez de um jeito:
//! encolhe, afunda na caixa, infla vermelho ou vira de costas). Dois cliques: um truque.
//! Bota fone em call (e fita na boca com o microfone mudo), pega fogo quando você
//! digita rápido, fica tonto se a conversa rola rápido demais, come o arquivo que você
//! arrasta para a janela, fica preocupado quando a mensagem não sai, tem olheiras e
//! boceja de madrugada, se espreguiça de manhã, usa chapéu nas datas e pega a cor de
//! destaque do tema.
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
const types = @import("../core/types.zig");

const Rgba = d.Rgba;

/// Largura do mascote do canto, em pixels (antes da escala da interface).
const base_size: f32 = 50;

const Mode = enum { home, grabbed, flying, dizzy, walking, away };

/// Os jeitos de emburrar: encolher, afundar na caixa (só as orelhas de fora), inflar
/// vermelho soltando fumaça, e virar de costas (espia quando o mouse passa).
pub const Sulk = enum { shrink, sink, inflate, back };

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
    /// As últimas teclas (para o "fogo no teclado") e quando o fogo apaga.
    keys: [12]i64 = @splat(-100_000),
    key_i: u8 = 0,
    fire_until: i64 = -100_000,
    /// Roda do mouse acumulada (rolar muito rápido deixa tonto).
    wheel_acc: f32 = 0,
    /// Arquivo sendo arrastado por cima da janela (boca aberta).
    drag_over_ms: i64 = -100_000,
    /// O segundo clique de um duplo clique (conta como cutucada, sem reação), o clique
    /// que acordou (não conta), e desde quando o truque espera um terceiro clique que
    /// o desfaça (0 = nenhum).
    dbl: bool = false,
    woke: bool = false,
    trick_ms: i64 = 0,
    trick_n: u8 = 0,
    /// Qual jeito de emburrar desta vez (cada vez um).
    sulk: Sulk = .shrink,
    sulk_n: u8 = 0,
    /// De costas: o quanto está espiando (-1..1).
    peek_v: f32 = 0,
    /// "Dormir" pelo menu: dorme até um clique nele ou uma mensagem (mexer o mouse não
    /// acorda), e desde quando.
    nap: bool = false,
    nap_ms: i64 = 0,
    /// "Esconder por 1 hora" pelo menu: some até esta hora.
    hide_until: i64 = 0,
    /// Não perturbe: menção não assusta.
    dnd: bool = false,
    /// Madrugada: o próximo bocejo. Manhã: já se espreguiçou nesta abertura.
    next_yawn_ms: i64 = 0,
    morning_done: bool = false,
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
        .trick => 1.4,
        .dizzy => 1.3,
        .eat => 1.1,
        .stretch => 1.5,
        .yawn => 1.5,
        .worried => 1.7,
        .clone => 0.9,
        .undo => 1.2,
        .search => 1.6,
        .tickle => 1.0,
        .startle => 0.6,
    };
}

/// Você mandou uma mensagem.
pub fn onSend(text: []const u8, now: i64) void {
    start(reactionFor(text), now);
    s.last_input_ms = now;
    s.nap = false;
}

/// Você reagiu a uma mensagem com um emoji (🔥: pega fogo).
pub fn onEmoji(e: []const u8, now: i64) void {
    if (s.mode != .home or s.nap) return;
    s.last_input_ms = now;
    if (std.mem.startsWith(u8, e, "🔥")) {
        s.fire_until = now + 1500;
        return;
    }
    start(contas.reactionForEmoji(e), now);
}

/// Ele precisa do lugar na barra da caixa? (Desligado ou escondido por uma hora, não.)
pub fn wantsSlot(on: bool, now: i64) bool {
    return on and now >= s.hide_until;
}

/// Os itens do menu do botão direito (ui/popup.zig desenha; `menuChoose` faz).
pub const menu_items = [_]struct { pt: []const u8, en: []const u8 }{
    .{ .pt = "Fazer um truque", .en = "Do a Trick" },
    .{ .pt = "Dormir", .en = "Sleep" },
    .{ .pt = "Esconder por 1 hora", .en = "Hide for 1 Hour" },
    .{ .pt = "Trocar de mascote", .en = "Switch Mascot" },
};

/// Escolheram um item do menu do botão direito (1 = o primeiro).
pub fn menuChoose(ctx: *d.Ctx, item: u8) void {
    const now = ctx.now_ms;
    switch (item) {
        1 => {
            s.nap = false;
            s.trick_n +%= 1;
            start(.trick, now);
        },
        2 => {
            s.nap = true;
            s.nap_ms = now;
            s.react = .none;
        },
        3 => s.hide_until = now + 60 * 60 * 1000,
        4 => {
            ctx.st.settings.mascot = if (mascote.Kind.of(ctx.st.settings.mascot) == .terminal) 1 else 0;
            ctx.act(.save_settings);
            start(.wave, now);
        },
        else => {},
    }
}

/// Não deu para mandar (modo lento, rápido demais, sem permissão): fica preocupado.
pub fn onSendBlocked(now: i64) void {
    start(.worried, now);
}

/// Um arquivo está sendo arrastado por cima da janela: ele abre a boca.
pub fn onDragOver(now: i64) void {
    s.drag_over_ms = now;
}

/// Soltou o arquivo: "nhac".
pub fn onDrop(now: i64) void {
    s.drag_over_ms = -100_000;
    start(.eat, now);
}

/// Chegou uma menção ou DM.
pub fn onPing(now: i64) void {
    if (s.mode != .home or s.dnd or s.nap) return;
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
    // O menu dele mesmo não o esconde.
    const own_menu = st.popup == .menu and st.popup.menu.kind == .pet;
    return !st.settings.mascot_pet or st.settings.open or st.palette.open or (st.popup != .none and !own_menu) or
        ctx.now_ms - slot_ms > 250 or ctx.now_ms < s.hide_until;
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
    if ((moved or typed) and !s.nap) {
        if (asleep_before) start(.wake, now);
        s.last_input_ms = now;
    }
    if (typed) {
        s.type_ms = now;
        s.keys[s.key_i] = now;
        s.key_i = @intCast((s.key_i + 1) % s.keys.len);
        var recent: u8 = 0;
        for (s.keys) |kt| {
            if (now - kt < 1000) recent += 1;
        }
        // Mais de 8 teclas por segundo: fogo no teclado.
        if (recent >= 8) s.fire_until = now + 900;
    }
    // Rolar a conversa muito rápido deixa tonto (a roda em cima dele fica para as cócegas).
    s.wheel_acc = s.wheel_acc * @exp(-dt * 3) + @abs(io.*.MouseWheel);
    if (s.wheel_acc > 16 and s.mode == .home and s.react == .none and !s.nap) {
        s.wheel_acc = 0;
        start(.dizzy, now);
    }
    // A hora (e a data) daqui: madrugada, manhã, Natal, Halloween, Ano-Novo.
    var wall: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&wall);
    const lt = @import("widgets.zig").localTime(@divTrunc(wall, 1_000_000_000));
    const late = lt.hour < 5;
    if (!s.morning_done) {
        s.morning_done = true;
        if (lt.hour >= 6 and lt.hour < 11) start(.stretch, now);
    }
    if (late and s.mode == .home) {
        if (s.next_yawn_ms == 0) s.next_yawn_ms = now + 20_000;
        if (now >= s.next_yawn_ms and s.react == .none) {
            start(.yawn, now);
            s.next_yawn_ms = now + 40_000 + @mod(now, 25_000);
        }
    } else s.next_yawn_ms = 0;

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
    qa.markTop(.{ .x = hit_min.x, .y = hit_min.y, .w = hit_w, .h = hit_h }, "pet", .{});
    if (hovered or active) c.ImGui_SetMouseCursor(if (active and s.dragging) c.ImGuiMouseCursor_ResizeAll else c.ImGuiMouseCursor_Hand);

    // Botão direito: o menu dele (truque, dormir, esconder, trocar de mascote).
    if (hovered and c.ImGui_IsMouseClicked(1) and (s.mode == .home or s.mode == .away))
        ctx.st.popup = .{ .menu = .{ .kind = .pet, .id = 0, .x = mouse.x, .y = mouse.y } };
    // A roda do mouse em cima dele: cócegas.
    if (hovered and io.*.MouseWheel != 0 and s.mode == .home) {
        s.wheel_acc = 0;
        s.nap = false;
        if (s.react != .tickle or secs(now, s.react_ms) > 0.4) start(.tickle, now);
    }
    // O mouse passando muito rápido perto dele: susto.
    if (!hovered and s.mode == .home and s.react == .none and !s.nap and mouse.x > -1000) {
        const md = std.math.hypot(io.*.MouseDelta.x, io.*.MouseDelta.y);
        if (md / dt > 4000 and dist(mouse.x, mouse.y, s.x, s.y) < size * 1.6) start(.startle, now);
    }
    // Atalhos: Ctrl+C faz um clone, Ctrl+Z anda para trás, Ctrl+F pega a lupa.
    if (io.*.KeyCtrl and !io.*.KeyShift and !io.*.KeyAlt and s.mode == .home and !s.nap) {
        if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_C, false)) start(.clone, now);
        if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_Z, false)) start(.undo, now);
        if (c.ImGui_IsKeyPressedEx(c.ImGuiKey_F, false)) start(.search, now);
    }

    // Duplo clique: um truque, se não vier logo um terceiro clique (aí é cutucada
    // atrás de cutucada, e o truque fica para outra vez).
    if (pressed) {
        if (c.ImGui_IsMouseDoubleClicked(0) and s.mode == .home and !s.nap) {
            s.dbl = true;
            s.trick_ms = now;
        } else s.trick_ms = 0;
    }
    // Dormindo pelo menu: o clique só acorda (não é cutucada).
    if (pressed and s.nap) {
        s.nap = false;
        s.woke = true;
        s.last_input_ms = now;
        start(.wake, now);
    }
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
        } else if (s.woke) {
            s.woke = false;
        } else if (s.dbl) {
            s.dbl = false;
            s.pokes = if (now - s.poke_ms < 1500) s.pokes + 1 else 1;
            s.poke_ms = now;
        } else poke(now);
        s.dragging = false;
    }
    if (s.trick_ms != 0 and now - s.trick_ms > trick_wait_ms and !active) {
        s.trick_ms = 0;
        s.pokes = 0;
        s.trick_n +%= 1;
        start(.trick, now);
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
    const asleep = s.mode == .home and (s.nap or now - s.last_input_ms > sleep_ms) and s.react == .none;
    const sleep_from = if (s.nap) s.nap_ms else s.last_input_ms + sleep_ms;
    if (asleep) {
        pl.face = .sleep;
        pl.ears = 0.22;
    }
    // O seu status: ausente (lua), não perturbe (plaquinha), invisível (fantasminha).
    const st = ctx.st;
    const status: types.Status = @fromBackingInt(@intCast(@min(st.settings.my_status, 3)));
    s.dnd = status == .dnd;
    if (status == .offline) pl.alpha = 0.45;
    // Em call: fone de ouvido; com o microfone mudo, fita na boca.
    pl.headset = st.voice != null;
    pl.tape = pl.headset and st.muted;
    // Madrugada: olheiras. Datas especiais: chapéu.
    pl.bags = late;
    pl.hat = contas.hatFor(lt.month, lt.day);
    // O corpo na cor de destaque do tema.
    const acc = ctx.col(.accent);
    pl.colors = .{ acc.mix(Rgba.hex(0xFFFFFF), 0.28), acc.mix(Rgba.hex(0x000000), 0.1) };
    // Digitando: o cursor pisca rápido e o rosto pula a cada tecla.
    const since_type = secs(now, s.type_ms);
    if (since_type < 0.7 and s.mode == .home) {
        pl.cursor = @mod(now, 300) < 170;
        pl.pop = kick(since_type, 0.16) * 1.3;
        pl.look = .{ -0.6, 0.5 };
        anim_until = s.type_ms + 700;
    }
    // Fogo no teclado: chamas nos pés e uma gota de suor.
    if (now < s.fire_until and s.mode == .home) {
        pl.flames = std.math.clamp(@as(f32, @floatFromInt(s.fire_until - now)) / 250.0, 0, 1);
        pl.flames_t = @as(f32, @floatFromInt(@mod(now, 60_000))) / 1000.0;
        pl.drop = 1;
        pl.drop_slide = @mod(pl.flames_t * 0.8, 1);
        anim_until = @max(anim_until, s.fire_until);
    }
    // Um arquivo vindo por cima da janela: boca aberta esperando.
    if (now - s.drag_over_ms < 700 and s.mode == .home and s.react == .none) {
        pl.face = .happy;
        pl.mouth = 0.75 + 0.25 * @sin(@as(f32, @floatFromInt(@mod(now, 60_000))) / 1000.0 * 8);
        pl.look = .{ 0, -0.6 };
        anim_until = @max(anim_until, s.drag_over_ms + 700);
    }
    var sink: f32 = 0;
    var slide: f32 = 0;
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
            // Entra em 0,3 s e desfaz nos últimos 0,3 s.
            const amt = std.math.clamp(at / 0.3, 0, 1) * std.math.clamp((sulk_s - at) / 0.3, 0, 1);
            const whole = s.mode_ms + @as(i64, @intFromFloat(sulk_s * 1000));
            pl.face = if (at < 2.5) .angry else .sad;
            pl.look = .{ -1, 0.3 };
            pl.ears = 0.3;
            anim_until = s.mode_ms + 2600;
            switch (s.sulk) {
                .shrink => shrink = 1 - 0.38 * amt,
                .sink => {
                    // Afunda na caixa: só as orelhas de fora, tremendo.
                    sink = amt;
                    pl.ears = 0.1 + @sin(at * 30) * 0.08;
                    anim_until = whole;
                },
                .inflate => {
                    // Infla vermelho e solta fumaça pelas orelhas.
                    pl.face = .angry;
                    pl.red = amt;
                    pl.smoke_t = at;
                    pl.ears = -0.2;
                    shrink = 1 + (0.22 + @sin(at * 9) * 0.03) * amt;
                    anim_until = whole;
                },
                .back => {
                    // De costas; espia quando o mouse chega perto.
                    pl.back = true;
                    const want: f32 = if (hovered) (if (mouse.x < s.x) -1 else 1) else 0;
                    s.peek_v += (want - s.peek_v) * @min(1, dt * 14);
                    if (@abs(s.peek_v - want) < 0.04) s.peek_v = want;
                    pl.peek = s.peek_v;
                    if (pl.peek != 0) pl.face = .sad;
                    if (s.peek_v != want) anim_until = @max(anim_until, now + 100);
                },
            }
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
            .trick => switch (s.trick_n % 3) {
                // Mortal para trás.
                0 => {
                    const f = std.math.clamp(rt / 0.9, 0, 1);
                    pl.face = if (rt < 0.9) .startled else .happy;
                    bob = -@sin(std.math.pi * f) * size * 0.55;
                    pl.spin = -std.math.tau * f * f * (3 - 2 * f);
                    pl.squash = kick(rt - 0.9, 0.3) * 0.25;
                },
                // Dancinha.
                1 => {
                    const fade = 1 - rt / 1.4;
                    pl.face = .happy;
                    pl.spin = @sin(rt * 13) * 0.2 * fade;
                    pl.wave = @sin(rt * 13) * 0.35 * fade;
                    bob = -@abs(@sin(rt * 13)) * size * 0.1;
                },
                // "Tcharam": pula de orelhas em pé, com brilhinhos.
                else => {
                    pl.face = .happy;
                    pl.ears = -0.3;
                    bob = -kick(rt, 0.5) * size * 0.3;
                    pl.squash = -kick(rt, 0.4) * 0.15;
                },
            },
            .dizzy => {
                pl.face = .dizzy;
                pl.spin = @sin(rt * 9) * 0.1 * (1 - rt / 1.3);
            },
            .eat => {
                // "Nhac": abre e fecha a boca e engole.
                pl.face = .happy;
                pl.mouth = if (rt < 0.75) @abs(@sin(rt * 16)) else 0;
                pl.squash = kick(rt - 0.75, 0.3) * 0.2;
            },
            .stretch => {
                // Espreguiça: estica, orelhas em pé, boca de bocejo.
                const up = @sin(std.math.pi * std.math.clamp(rt / 1.5, 0, 1));
                pl.face = if (rt < 1.1) .sleep else .happy;
                pl.squash = -0.22 * up;
                pl.ears = -0.35 * up;
                pl.mouth = up * 0.8;
            },
            .yawn => {
                const up = @sin(std.math.pi * std.math.clamp(rt / 1.5, 0, 1));
                pl.face = .sleep;
                pl.mouth = up;
                pl.ears = 0.25;
                pl.squash = -0.06 * up;
            },
            .worried => {
                pl.face = .worried;
                pl.drop = 1;
                pl.drop_slide = std.math.clamp(rt / 1.7, 0, 1);
                pl.look = .{ @sin(rt * 7) * 0.7, 0.2 };
                pl.ears = 0.2;
            },
            .clone => {
                // O clone sai de dentro dele (desenhado mais abaixo).
                pl.face = .happy;
                pl.squash = kick(rt, 0.25) * 0.2;
            },
            .undo => {
                // Anda para trás olhando para a frente, e volta.
                const f = std.math.clamp(rt / 1.2, 0, 1);
                slide = -@sin(std.math.pi * f) * size * 0.6;
                bob = -@abs(@sin(rt * 14)) * size * 0.05;
                pl.look = .{ 1, 0 };
                pl.spin = -0.08 * @sin(std.math.pi * f);
            },
            .search => {
                // Pega a lupa e procura de um lado para o outro.
                pl.look = .{ @sin(rt * 4) * 0.8, 0.1 };
                pl.face = .prompt;
            },
            .tickle => {
                pl.face = .laugh;
                pl.squash = @sin(rt * 40) * 0.06 * (1 - rt / 1.0);
                pl.spin = @sin(rt * 33) * 0.07 * (1 - rt / 1.0);
                pl.ears = -0.15;
            },
            .startle => {
                pl.face = .startled;
                bob = -kick(rt, 0.35) * size * 0.3;
                pl.ears = -0.3;
                pl.squash = -kick(rt, 0.25) * 0.12;
            },
        }
    }

    // O truque esperando um terceiro clique: um quadro na hora de decidir.
    if (s.trick_ms != 0) anim_until = @max(anim_until, s.trick_ms + trick_wait_ms + 20);
    // --- Quadros: só enquanto algo anima, e só com a janela em foco ----------------------
    if (focused) {
        if (s.mode == .grabbed or s.mode == .flying or s.mode == .walking or s.mode == .dizzy) {
            anim.active = true;
        } else if (anim_until > now) {
            anim.at(now + 33);
        } else if (asleep) {
            // Os "Z" sobem uns segundos depois de dormir e param.
            const zt = secs(now, sleep_from);
            if (zt < 8) anim.at(now + 66);
        } else if (s.mode == .home) {
            // A hora de dormir: um quadro só.
            anim.at(s.last_input_ms + sleep_ms + 10);
        }
    }

    // --- Desenho (por cima de tudo) ------------------------------------------------------
    const dl = ctx.fg;
    const cx = s.x + slide;
    // Encolhido ou inflado, os pés ficam no mesmo lugar. Afundado, só as orelhas
    // passam da linha dos pés.
    const cy_fx = s.y + bob + (1 - shrink) * (99 - 42.5) * k;
    const cy = cy_fx + sink * (99 - 8) * k;
    const dsize = size * shrink;
    if (sink > 0) c.ImDrawList_PushClipRect(dl, d.v(-100_000, -100_000), d.v(100_000, home_y + (99 - 42.5) * k + 1), true);
    const kind = mascote.Kind.of(ctx.st.settings.mascot);
    // Ctrl+C: um clone sai de lado e some.
    if (s.react == .clone and kind == .terminal) {
        const f = std.math.clamp(rt / reactionSeconds(.clone), 0, 1);
        var cl = pl;
        cl.alpha = pl.alpha * (1 - f) * 0.8;
        cl.flames = 0;
        cl.smoke_t = -1;
        terminal.pet(dl, cx + contas.outCubic(f) * size * 0.95, cy - @sin(std.math.pi * f) * size * 0.15, dsize, cl);
    }
    switch (kind) {
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
    if (sink > 0) c.ImDrawList_PopClipRect(dl);
    effects(dl, now, cx, cy_fx, size, asleep, sleep_from, rt);
    badge(dl, status, cx, cy_fx, size, asleep);
}

const sleep_ms: i64 = 3 * 60 * 1000;
/// Quanto o duplo clique espera um terceiro clique antes de virar truque.
const trick_wait_ms: i64 = 350;
/// Quanto tempo ele fica emburrado.
const sulk_s: f32 = 8;

fn poke(now: i64) void {
    s.pokes = if (now - s.poke_ms < 1500) s.pokes + 1 else 1;
    s.poke_ms = now;
    if (s.pokes >= 5 and s.mode == .home) {
        // Cutucado demais: fica bravo e emburra uns segundos, cada vez de um jeito.
        s.pokes = 0;
        s.sulk = @enumFromInt(s.sulk_n % @typeInfo(Sulk).@"enum".field_names.len);
        s.sulk_n +%= 1;
        s.peek_v = 0;
        start(.angry, now);
        s.mode = .away;
        s.mode_ms = now;
        return;
    }
    start(if (s.pokes >= 3) .angry else .poke, now);
}

/// Os enfeites de cada reação: corações, confete, "!", "Z", estrelinhas de tontura.
fn effects(dl: *c.ImDrawList, now: i64, cx: f32, cy: f32, size: f32, asleep: bool, sleep_from: i64, rt: f32) void {
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
        .laugh, .tickle => for (0..3) |i| {
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
        .trick => if (s.trick_n % 3 == 2) for (0..6) |i| {
            // Brilhinhos do "tcharam".
            const fi: f32 = @floatFromInt(i);
            const f = std.math.clamp((rt - 0.15) / 1.0, 0, 1);
            if (f <= 0 or f >= 1) continue;
            const ang = fi / 6.0 * std.math.tau - std.math.pi / 2.0;
            const rr = size * (0.45 + 0.35 * f);
            star(dl, cx + @cos(ang) * rr, top + size * 0.3 + @sin(ang) * rr, size * 0.05 * (1 - f * 0.5), Rgba.hex(0xF7E04A).col(1 - f));
        },
        .eat => for (0..4) |i| {
            // Farelos caindo.
            const fi: f32 = @floatFromInt(i);
            const f = std.math.clamp((rt - 0.1 - fi * 0.12) / 0.6, 0, 1);
            if (f <= 0 or f >= 1) continue;
            const px = cx + (fi - 1.5) * size * 0.12;
            const py = cy + size * 0.12 + f * size * 0.35;
            const q = size * 0.025;
            c.ImDrawList_AddRectFilled(dl, d.v(px - q, py - q), d.v(px + q, py + q), Rgba.hex(0xD9B38C).col(1 - f));
        },
        .search => {
            // A lupa na frente do olho direito.
            const eye = terminal.petPoint(cx, cy, size, 84 + @sin(rt * 4) * 6, 62);
            const lr = size * 0.17;
            const a = std.math.clamp(rt / 0.2, 0, 1) * std.math.clamp((reactionSeconds(.search) - rt) / 0.2, 0, 1);
            c.ImDrawList_AddCircleFilled(dl, eye, lr, Rgba.hex(0xBFEFFF).col(0.25 * a), 0);
            c.ImDrawList_AddCircleEx(dl, eye, lr, Rgba.hex(0x22182E).col(a), 0, @max(size * 0.05, 1.5), 0);
            c.ImDrawList_AddLineEx(dl, d.v(eye.x + lr * 0.7, eye.y + lr * 0.7), d.v(eye.x + lr * 1.6, eye.y + lr * 1.6), Rgba.hex(0x22182E).col(a), @max(size * 0.07, 2), 0);
        },
        else => {},
    }
    if (s.mode == .dizzy or s.react == .dizzy) {
        // Estrelinhas girando em volta da cabeça.
        const t = if (s.mode == .dizzy) secs(now, s.mode_ms) else rt;
        for (0..3) |i| {
            const a = t * 6 + @as(f32, @floatFromInt(i)) * std.math.tau / 3.0;
            const px = cx + @cos(a) * size * 0.42;
            const py = top + @sin(a) * size * 0.1;
            star(dl, px, py, size * 0.06, Rgba.hex(0xF7E04A).col(1));
        }
    }
    if (asleep) {
        const zt = @min(secs(now, sleep_from), 8);
        terminal.zzz(dl, d.v(cx + size * 0.32, top + size * 0.1), size / 150, zt, 1);
    }
}

/// O status ao lado dele: a lua do ausente e a plaquinha do não perturbe.
fn badge(dl: *c.ImDrawList, status: types.Status, cx: f32, cy: f32, size: f32, asleep: bool) void {
    const top = cy - size * 0.55;
    switch (status) {
        .idle => if (!asleep) {
            const m = d.v(cx - size * 0.46, top + size * 0.12);
            const r = size * 0.085;
            c.ImDrawList_PathArcTo(dl, m, r, std.math.pi * 0.55, std.math.pi * 1.75, 14);
            c.ImDrawList_PathStroke(dl, Rgba.hex(0xF0B232).u(), r * 0.7, 0);
        },
        .dnd => {
            // A plaquinha num cabinho, do lado.
            const px = cx + size * 0.5;
            const py = top + size * 0.25;
            const r = size * 0.1;
            c.ImDrawList_AddLineEx(dl, d.v(px, py + r), d.v(px - size * 0.08, cy + size * 0.1), Rgba.hex(0x8A6A4A).u(), @max(size * 0.035, 1.2), 0);
            c.ImDrawList_AddCircleFilled(dl, d.v(px, py), r, Rgba.hex(0xF23F43).u(), 0);
            c.ImDrawList_AddRectFilledEx(dl, d.v(px - r * 0.62, py - r * 0.18), d.v(px + r * 0.62, py + r * 0.18), Rgba.hex(0xFFFFFF).u(), r * 0.15, 0);
        },
        else => {},
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
pub fn sulkKind() Sulk {
    return s.sulk;
}
pub fn onFire(now: i64) bool {
    return now < s.fire_until;
}
pub fn isAsleep(now: i64) bool {
    return s.mode == .home and (s.nap or now - s.last_input_ms > sleep_ms) and s.react == .none;
}
pub fn isHidden(now: i64) bool {
    return now < s.hide_until;
}
/// Desfaz o "Esconder por 1 hora" e o "Dormir" (o QA não espera uma hora).
pub fn qaUnhide() void {
    s.hide_until = 0;
    s.nap = false;
}
/// Volta para casa na hora (o QA não espera ele voltar andando).
pub fn qaHome() void {
    s.mode = .home;
    s.react = .none;
    s.pokes = 0;
    s.fire_until = -100_000;
}
/// Faz de conta que ninguém mexe há tanto tempo (o QA não espera três minutos).
pub fn qaIdleFor(ms: i64, now: i64) void {
    s.last_input_ms = now - ms;
}
