//! O mascote que mora num canto do app (Configurações → Mascote → "Mascote no
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
//! boceja de madrugada, se espreguiça de manhã, usa chapéu nas datas (se não tem um
//! escolhido) e pega a cor de destaque do tema, ou veste o visual personalizado
//! (Configurações → Mascote → Personalizar).
//!
//!
//! Vida própria (Configurações → Mascote): parado, de vez em quando ele faz alguma coisa
//! sozinho (toma café, lê, joga, pesca um emoji das reações da conversa, caça uma
//! mosquinha, empilha blocos, rabisca na caixa, rega a plantinha) ou sai passeando pela
//! janela em pulos (senta na última mensagem, sobe na lista de membros, fica pendurado no
//! cabeçalho, espia por trás da lista de canais). Brinca com a interface (senta no
//! "digitando…", leva mensagem apagada para o lixo, empurra o botão de voltar ao fim, leva
//! a cartinha da DM até o ícone), com a setinha do mouse, pula junto quando você troca de
//! canal, espera com a janela sem foco, acampa quando você some e corre até o mouse na volta.
//!
//! Leve: parado, ele não acorda o app. Só anima por um instante quando algo acontece
//! (30 quadros por segundo numa reação, 15 nas que duram mais, 60 só voando ou sendo
//! arrastado), e só com a janela em foco. A vida própria pede um quadro só na hora da
//! próxima coisa, e para quando ele dorme. Seguir o mouse com os olhos não custa nada:
//! mexer o mouse já redesenha.
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
const props = @import("mascote_props.zig");
const i18n = @import("i18n.zig");

const Rgba = d.Rgba;

/// Largura do mascote do canto, em pixels (antes da escala da interface).
const base_size: f32 = 50;

/// `trip`: pulando de um lugar para outro da janela; `perch`: parado num lugar dela
/// (em cima da última mensagem, pendurado no cabeçalho…), antes de voltar.
const Mode = enum { home, grabbed, flying, dizzy, walking, away, trip, perch };

/// O que ele faz sozinho em casa (Configurações → Mascote → Vida própria) e o que faz
/// quando algo acontece na interface.
pub const Act = enum {
    none,
    // Parado: um destes de vez em quando.
    scratch,
    char_play,
    coffee,
    book,
    game,
    gum,
    whistle,
    clean,
    nap_sit,
    exercise,
    fly,
    fish,
    tower,
    doodle,
    water,
    // Coisas da interface e da volta.
    trash,
    erase,
    pack,
    portal,
    peek,
    grab,
    hold,
    tower_fall,
};

/// Para onde ele vai quando sai de casa.
pub const Goal = enum { none, home, msg, members, header, channels, typing, jump, dm, cursor, mouse };

/// Os lugares da interface aonde ele pode ir (cada componente avisa onde está a cada
/// quadro; o que não apareceu no quadro, como a lista de membros num tema sem ela, fica
/// de fora).
pub const Anchor = enum { members, header, channels, dm_icon, last_msg, typing, jump, input };

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

    // --- Vida própria ---------------------------------------------------------------
    /// O que ele está fazendo em casa, desde quando e qual variação (o tipo de exercício,
    /// o rabisco…); e a próxima vez que ele faz alguma coisa sozinho.
    act: Act = .none,
    act_ms: i64 = 0,
    act_var: u8 = 0,
    next_act_ms: i64 = 0,
    rng: u64 = 0x2545F4914F6CDD1D,
    /// Viagem: o destino (onde os pés pousam), o pulo de agora e o que fazer ao chegar.
    goal: Goal = .none,
    dest: [2]f32 = .{ 0, 0 },
    hop_from: [2]f32 = .{ 0, 0 },
    hop_to: [2]f32 = .{ 0, 0 },
    hop_ms: i64 = 0,
    hop_len: f32 = 0.5,
    hop_h: f32 = 30,
    perch_ms: i64 = 0,
    perch_until: i64 = 0,
    /// Pendurado ou espiando: o retângulo que corta o desenho (largura 0 = nenhum).
    clip: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Onde estava o lugar em que ele pousou (se o lugar some ou muda de posição, ele volta).
    perch_at: ?d.Rect = null,
    /// A torre montada e o rabisco na caixa (ficam até você mexer ou digitar): 0 = nenhum,
    /// 1 = coração, 2 = estrela.
    tower: bool = false,
    doodle: u8 = 0,
    /// O que veio no anzol (um emoji das reações da conversa; sem nenhum, um peixe).
    catch_r: types.Reaction = .{},
    /// Coisas da interface esperando a vez (os ganchos do app chegam fora do quadro).
    pend_delete: bool = false,
    pend_edit: bool = false,
    pend_dm: bool = false,
    pend_resize: bool = false,
    /// Quando ele foi a cada lugar pela última vez (para não ir toda hora).
    trip_ms: i64 = -100_000,
    typing_trip_ms: i64 = -100_000,
    jump_trip_ms: i64 = -100_000,
    dm_trip_ms: i64 = -100_000,
    resize_ms: i64 = -100_000,
    grab_ms: i64 = -100_000,
    jump_seen: bool = false,
    /// A setinha do mouse parada: onde e desde quando.
    still_x: f32 = 0,
    still_y: f32 = 0,
    still_ms: i64 = 0,
    /// Janela sem foco desde quando (0 = com foco), acampado, e o balão de fala.
    away_ms: i64 = 0,
    camped: bool = false,
    camp_ms: i64 = 0,
    balloon_until: i64 = 0,
    /// O canal de antes (para pular junto) e onde era a casa nele.
    last_channel: types.Id = 0,
    last_home: [2]f32 = .{ 0, 0 },
    /// A plantinha: o dia de hoje já foi conferido nesta abertura.
    plant_checked: bool = false,
    /// A pescaria começou e ainda falta escolher o emoji (precisa da conversa).
    need_catch: bool = false,
    /// Uma viagem pedida pelo QA (sai no próximo quadro, que tem os lugares da tela) e
    /// se o lugar não estava na tela.
    qa_goal: Goal = .none,
    qa_go_failed: bool = false,
};

var s: State = .{};
/// O último quadro em que ele apareceu (o QA confere se o tema tem lugar para ele).
var shown_ms: i64 = -100_000;
/// O lugar reservado para ele na barra da caixa de mensagem (ver comp_messages).
var home_slot: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var slot_ms: i64 = -100_000;

/// O lugar dele dentro da barra da caixa, à esquerda dos botões.
pub fn slot(r: d.Rect, now: i64) void {
    home_slot = r;
    slot_ms = now;
}

/// A largura do lugar dele na barra (com a plantinha, um pouco mais).
pub fn slotWidth(plant_on: bool) f32 {
    return if (plant_on) 46 + plant_w else 46;
}
const plant_w: f32 = 18;

var anchors: [@typeInfo(Anchor).@"enum".field_names.len]struct { r: d.Rect, ms: i64 } = @splat(.{ .r = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .ms = -100_000 });

/// Um lugar da interface neste quadro (ver `Anchor`).
pub fn anchor(a: Anchor, r: d.Rect, now: i64) void {
    anchors[@intFromEnum(a)] = .{ .r = r, .ms = now };
}

/// Um lugar que só vale inteiro dentro de `area` (um ícone rolado para fora da barra
/// não conta).
pub fn anchorIn(a: Anchor, r: d.Rect, area: d.Rect, now: i64) void {
    if (r.x >= area.x - 1 and r.y >= area.y - 1 and r.right() <= area.right() + 1 and r.bottom() <= area.bottom() + 1) anchor(a, r, now);
}

const component_anchors = [_]struct { []const u8, Anchor }{ .{ "member-list", .members }, .{ "header", .header }, .{ "channel-list", .channels }, .{ "guild-bar", .dm_icon } };
var veiled_ms: [@typeInfo(Anchor).@"enum".field_names.len]i64 = @splat(-100_000);

/// Um componente do tema foi desenhado (ui/root.zig): os que servem de lugar para ele.
pub fn component(name: []const u8, r: d.Rect, now: i64) void {
    for (component_anchors) |m| if (std.mem.eql(u8, name, m[0]) and m[1] != .dm_icon) anchor(m[1], r, now);
}

/// Um componente está escondido atrás do véu do `autohide` (ui/root.zig): os lugares
/// dele não valem neste quadro.
pub fn veiled(name: []const u8, now: i64) void {
    for (component_anchors) |m| if (std.mem.eql(u8, name, m[0])) {
        anchors[@intFromEnum(m[1])].ms = -100_000;
        veiled_ms[@intFromEnum(m[1])] = now;
    };
}

fn anchorRect(a: Anchor, now: i64) ?d.Rect {
    const e = anchors[@intFromEnum(a)];
    if (now - e.ms > 250 or e.r.w < 4 or e.r.h < 4) return null;
    return e.r;
}

/// Uma mensagem da conversa aberta foi apagada: ele leva para o lixo.
pub fn onMessageDeleted() void {
    s.pend_delete = true;
}

/// Uma mensagem da conversa aberta foi editada: ele passa a borracha.
pub fn onMessageEdited() void {
    s.pend_edit = true;
}

/// Chegou uma DM: ele leva a cartinha até o ícone das DMs.
pub fn onDm() void {
    s.pend_dm = true;
}

/// A janela mudou de tamanho: ele se segura (ou cai).
pub fn onResize() void {
    s.pend_resize = true;
}

/// Uma reação começa agora (a de agora vale mais que uma pancada de tecla, e mais que o
/// que ele fazia sozinho).
fn start(r: Reaction, now: i64) void {
    s.react = r;
    s.react_ms = now;
    if (isIdleAct(s.act)) s.act = .none;
}

// --- Vida própria: o que ele faz sozinho e aonde vai ----------------------------------

/// Distância dos pés ao centro do desenho (os destinos das viagens são onde os pés pousam).
const foot_off: f32 = (99 - 42.5) * base_size * 0.78 / 127.14;
/// Depois de quanto tempo sem você ele acampa.
const camp_after_ms: i64 = 20 * 60 * 1000;
/// Depois de quanto tempo fora ele diz que sentiu saudade.
const missed_after_ms: i64 = 2 * 60 * 60 * 1000;

fn rand() u32 {
    var x = s.rng;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    s.rng = x;
    return @truncate(x >> 16);
}

fn isIdleAct(a: Act) bool {
    return @intFromEnum(a) >= @intFromEnum(Act.scratch) and @intFromEnum(a) <= @intFromEnum(Act.water);
}

fn actSeconds(a: Act) f32 {
    return switch (a) {
        .none => 0,
        .scratch => 2.2,
        .char_play => 2.6,
        .coffee => 3.2,
        .book => 4.0,
        .game => 4.0,
        .gum => 3.0,
        .whistle => 3.2,
        .clean => 2.4,
        .nap_sit => 4.5,
        .exercise => 4.0,
        .fly => 4.6,
        .fish => 5.6,
        .tower => 4.0,
        .doodle => 2.6,
        .water => 2.6,
        .trash => 2.4,
        .erase => 1.8,
        .pack => 1.4,
        .portal => 0.8,
        .peek => 1.6,
        .grab => 1.1,
        .hold => 1.5,
        .tower_fall => 1.1,
    };
}

fn startAct(a: Act, now: i64) void {
    s.act = a;
    s.act_ms = now;
    s.act_var = @truncate(rand());
    if (a == .fish) s.need_catch = true;
}

/// Uma viagem até `dest` (onde os pés pousam), em pulos de no máximo 280 px.
fn startTrip(goal: Goal, dest: [2]f32, now: i64) void {
    s.goal = goal;
    s.dest = dest;
    s.mode = .trip;
    s.mode_ms = now;
    s.act = .none;
    s.clip.w = 0;
    if (goal != .home) s.trip_ms = now;
    nextHop(now);
}

fn nextHop(now: i64) void {
    const fx = s.x;
    const fy = s.y + foot_off;
    const dx = s.dest[0] - fx;
    const dy = s.dest[1] - fy;
    const len = std.math.hypot(dx, dy);
    const step = @min(len, 280);
    const f = if (len > 0.5) step / len else 1;
    s.hop_from = .{ fx, fy };
    s.hop_to = .{ fx + dx * f, fy + dy * f };
    s.hop_len = 0.3 + step / 1000;
    s.hop_h = 16 + step * 0.2;
    s.hop_ms = now;
}

/// A casa de agora, onde os pés ficam (atualizada a cada quadro).
var home_feet: [2]f32 = .{ 0, 0 };

fn goHome(now: i64) void {
    startTrip(.home, home_feet, now);
}

/// Sai para um lugar da interface. false: o lugar não está na tela (ou já está lá).
fn goTo(ctx: *d.Ctx, goal: Goal, now: i64) bool {
    const kk = base_size * 0.78 / 127.14;
    const win = ctx.win;
    const dest: [2]f32 = switch (goal) {
        .msg => blk: {
            const r = anchorRect(.last_msg, now) orelse return false;
            break :blk .{ r.right() - 70, r.y + 3 };
        },
        .members => blk: {
            // Na ponta direita da borda de cima (o título dos cargos fica à esquerda).
            const r = anchorRect(.members, now) orelse return false;
            break :blk .{ r.right() - 30, r.y + 3 };
        },
        .header => blk: {
            // Pendurado: as pontas das orelhas na borda de baixo do cabeçalho.
            const r = anchorRect(.header, now) orelse return false;
            break :blk .{ r.x + r.w * 0.55, r.bottom() + (99 + 14) * kk };
        },
        .channels => blk: {
            // Quase todo atrás da lista de canais, só o rosto de fora, do lado da
            // conversa (a lista fica à direita em alguns temas).
            const r = anchorRect(.channels, now) orelse return false;
            const right_side = r.x + r.w / 2 > win.x + win.w / 2;
            break :blk .{ if (right_side) r.x + base_size * 0.1 else r.right() - base_size * 0.1, r.y + r.h * 0.42 };
        },
        .typing => blk: {
            const r = anchorRect(.typing, now) orelse return false;
            break :blk .{ r.x + r.w * 0.5, r.y + 3 };
        },
        .jump => blk: {
            const r = anchorRect(.jump, now) orelse return false;
            break :blk .{ r.x - base_size * 0.36, r.bottom() };
        },
        .dm => blk: {
            // Logo embaixo do ícone das DMs (ui/comp_rail.zig avisa onde ele está, em
            // qualquer formato da barra).
            // Ícone em cima (barra de servidores, lista): ele fica logo embaixo; ícone
            // embaixo (o dock do Cupertino): senta em cima dele.
            const r = anchorRect(.dm_icon, now) orelse return false;
            const low = r.y + r.h / 2 > win.y + win.h / 2;
            break :blk .{ r.x + r.w / 2, if (low) r.y + 2 else r.bottom() + 4 };
        },
        .cursor => .{ ctx.mouse.x + 3, ctx.mouse.y - 1 },
        .mouse => .{ ctx.mouse.x, home_feet[1] },
        .none, .home => return false,
    };
    const dx = std.math.clamp(dest[0], win.x + 24, win.right() - 24);
    const dy = std.math.clamp(dest[1], win.y + 30, win.bottom() - 2);
    if (std.math.hypot(dx - s.x, dy - (s.y + foot_off)) < 8) return false;
    startTrip(goal, .{ dx, dy }, now);
    // O lugar como estava na saída: mudou ou sumiu até ele chegar (ou depois), ele volta.
    s.perch_at = anchorFor(goal, now);
    return true;
}

/// O lugar da tela de cada destino (o mouse não é um lugar).
fn anchorFor(goal: Goal, now: i64) ?d.Rect {
    return switch (goal) {
        .msg => anchorRect(.last_msg, now),
        .members => anchorRect(.members, now),
        .header => anchorRect(.header, now),
        .channels => anchorRect(.channels, now),
        .typing => anchorRect(.typing, now),
        .jump => anchorRect(.jump, now),
        .dm => anchorRect(.dm_icon, now),
        .none, .home, .cursor, .mouse => null,
    };
}

/// Quanto ele fica em cada lugar.
fn perchMs(goal: Goal) i64 {
    return switch (goal) {
        .msg, .members => 6000 + @as(i64, rand() % 3000),
        .header, .channels => 5000,
        .typing => 8000,
        .jump => 3500,
        .dm => 900,
        .cursor => 30_000,
        .mouse => 1400,
        .none, .home => 0,
    };
}

fn arrive(now: i64) void {
    if (s.goal == .home or s.goal == .none) {
        s.mode = .home;
        s.goal = .none;
        s.mode_ms = now;
        s.clip.w = 0;
        return;
    }
    s.mode = .perch;
    s.perch_ms = now;
    s.perch_until = now + perchMs(s.goal);
    // Atrás da lista de canais: o que passa da borda dela para dentro some.
    if (s.goal == .channels) if (anchorRect(.channels, now)) |r| {
        s.clip = if (s.x > r.x + r.w / 2)
            .{ .x = r.right(), .y = -100_000, .w = 200_000, .h = 200_000 }
        else
            .{ .x = -100_000, .y = -100_000, .w = r.x + 100_000, .h = 200_000 };
    };

}

/// O emoji para pescar: uma das reações das últimas mensagens da conversa aberta.
fn pickCatch(ctx: *d.Ctx) void {
    s.catch_r = .{};
    const ch = ctx.st.activeChannel() orelse return;
    const cs = ctx.store.channel(ch) orelse return;
    const items = cs.messages.items;
    var found: [16]*const types.Reaction = undefined;
    var n: usize = 0;
    var i = items.len;
    while (i > 0 and items.len - i < 40 and n < found.len) {
        i -= 1;
        for (items[i].reactionSlice()) |*r| if (n < found.len) {
            found[n] = r;
            n += 1;
        };
    }
    if (n > 0) s.catch_r = found[rand() % n].*;
}

/// Hora de fazer alguma coisa sozinho: passear (se der) ou uma das coisas de ficar parado.
fn pickLife(ctx: *d.Ctx, now: i64) void {
    const set = &ctx.st.settings;
    if (set.mascot_roam and rand() % 100 < 30 and now - s.trip_ms > 30_000) {
        const goals = [_]Goal{ .msg, .members, .header, .channels };
        const first = rand() % goals.len;
        for (0..goals.len) |j| if (goTo(ctx, goals[(first + j) % goals.len], now)) return;
    }
    if (set.mascot_plant and set.mascot_plant_wilted) return startAct(.water, now);
    var pool: [16]Act = undefined;
    var n: usize = 0;
    for ([_]Act{ .scratch, .char_play, .coffee, .book, .game, .gum, .whistle, .clean, .nap_sit, .exercise, .fly, .fish }) |a| {
        pool[n] = a;
        n += 1;
    }
    // A torre fica do lado da caixa: só com ela vazia (não cobre o texto).
    if (!s.tower and ctx.st.input[0] == 0) {
        pool[n] = .tower;
        n += 1;
    }
    if (s.doodle == 0 and ctx.st.input[0] == 0 and anchorRect(.input, now) != null) {
        pool[n] = .doodle;
        n += 1;
    }
    if (set.mascot_plant and rand() % 3 == 0) {
        pool[n] = .water;
        n += 1;
    }
    const a = pool[rand() % n];
    startAct(a, now);
    if (a == .doodle) s.doodle = 1 + @as(u8, @intCast(rand() % 2));
}

/// Acabou o que ele fazia: o que fica (a torre, a planta regada) e o que vem depois.
fn endAct(ctx: *d.Ctx, now: i64) void {
    const a = s.act;
    s.act = .none;
    switch (a) {
        .tower => s.tower = true,
        .water => if (ctx.st.settings.mascot_plant_wilted) {
            ctx.st.settings.mascot_plant_wilted = false;
            ctx.act(.save_settings);
        },
        .pack => if (ctx.mouse.x > -1000) {
            _ = goTo(ctx, .mouse, now);
        },
        .tower_fall => start(.dizzy, now),
        else => {},
    }
}

/// A plantinha cresce um dia por dia de uso: o primeiro toque seu em cada dia conta
/// (com o app aberto por dias, cada dia em que você mexe). Mais de uma semana sem
/// você, ela murcha, e fica murcha (guardado nas configurações) até ele regar.
fn plantDay(ctx: *d.Ctx, today: i64) void {
    const set = &ctx.st.settings;
    const t: i16 = @intCast(std.math.clamp(today, 1, 32767));
    const last = set.mascot_plant_day;
    if (last == t) return;
    if (last != 0 and t - last > 7) set.mascot_plant_wilted = true;
    if (set.mascot_plant_days < 255) set.mascot_plant_days += 1;
    set.mascot_plant_day = t;
    ctx.act(.save_settings);
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

/// Está escondido neste quadro? (Desligado, Configurações ou imagem em tela cheia por
/// cima, a caixa de mensagem fora da tela, ou "Esconder por 1 hora".)
fn hidden(ctx: *d.Ctx) bool {
    const st = ctx.st;
    return !st.settings.mascot_pet or st.settings.open or st.viewer != null or
        ctx.now_ms - slot_ms > 250 or ctx.now_ms < s.hide_until;
}

/// Um popup ou a paleta aberta: ele continua na tela, mas por baixo deles e sem pegar
/// o mouse.
fn underPopup(ctx: *d.Ctx) bool {
    return ctx.st.popup != .none or ctx.st.palette.open;
}

/// Desenha e anima o mascote do canto (por cima de tudo, depois da interface).
pub fn draw(ctx: *d.Ctx) void {
    const now = ctx.now_ms;
    if (hidden(ctx)) {
        // Voltando, ele já está em casa.
        if (s.mode == .home or ctx.now_ms - slot_ms > 250) s.placed = false;
        s.mode = .home;
        s.dragging = false;
        s.goal = .none;
        s.act = .none;
        s.clip.w = 0;
        // O que aconteceu com ele escondido (a janela mudando de tamanho ao abrir, uma
        // mensagem apagada) não vale para depois.
        s.pend_delete = false;
        s.pend_edit = false;
        s.pend_dm = false;
        s.pend_resize = false;
        return;
    }
    shown_ms = now;
    // A escala da interface já vale para tudo (ver App.uiScale).
    const size = base_size;
    const k = size * 0.78 / 127.14;
    // Em casa: no lugar dele na barra da caixa, com a cabeça espiando por cima (com a
    // plantinha, ela fica à esquerda dele, no mesmo lugar).
    const set = &ctx.st.settings;
    const pw: f32 = if (set.mascot_plant and home_slot.w > 46) plant_w else 0;
    const home_x = home_slot.x + pw + (home_slot.w - pw) / 2;
    const home_y = home_slot.bottom() - 4 - (99 - 42.5) * k;
    home_feet = .{ home_x, home_slot.bottom() - 4 };
    if (!s.placed) {
        s.x = home_x;
        s.y = home_y;
        s.mode = .home;
        s.placed = true;
        s.last_input_ms = now;
        // Logo que aparece, a janela ainda pode estar se ajeitando (o compositor muda o
        // tamanho dela ao abrir): nada de se segurar por isso.
        s.resize_ms = now;
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
    const idle_before = now - s.last_input_ms;
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

    // --- Vida própria: a plantinha, a volta, o canal novo --------------------------------
    if (moved or typed or !s.plant_checked) {
        s.plant_checked = true;
        plantDay(ctx, lt.day_index);
    }
    const away_on = set.mascot_away;
    if (!focused) {
        if (s.away_ms == 0) s.away_ms = now;
        if (away_on and !s.camped and now - s.away_ms > camp_after_ms) {
            s.camped = true;
            s.tower = false;
        }
    } else {
        const gap: i64 = if (s.away_ms != 0) now - s.away_ms else 0;
        s.away_ms = 0;
        // Ninguém mexendo há muito tempo, mesmo com a janela em foco: acampa também.
        if (away_on and !s.camped and s.mode == .home and idle_before > camp_after_ms) {
            s.camped = true;
            s.tower = false;
        }
        if (!away_on) s.camped = false;
        if (away_on and (gap > 0 or (s.camped and (moved or typed)))) {
            // Voltou: desmonta o acampamento e corre até o mouse.
            const absent = @max(gap, idle_before);
            if (s.camped) {
                s.camped = false;
                startAct(.pack, now);
            } else if (absent > 60_000 and s.mode == .home and mouse.x > -1000) _ = goTo(ctx, .mouse, now);
            if (absent > missed_after_ms) s.balloon_until = now + 3500;
        }
    }
    // Trocou de canal: ele pula junto (a caixa mudou de lugar) ou passa por um portal; numa
    // thread, ele espia.
    {
        const ch = ctx.st.activeChannel() orelse 0;
        // (Trocar de canal é você mexendo: vale mais que o que ele fazia, menos desmontar
        // o acampamento.)
        if (ch != s.last_channel and s.last_channel != 0 and ch != 0 and set.mascot_roam and set.mascot_life > 0 and s.mode == .home and s.act != .pack) {
            const old = s.last_home;
            const thread = if (ctx.store.channel(ch)) |cs| cs.info.thread != null else false;
            if (thread) {
                startAct(.peek, now);
            } else if (std.math.hypot(old[0] - home_feet[0], old[1] - home_feet[1]) > 40) {
                s.x = old[0];
                s.y = old[1] - foot_off;
                startTrip(.home, home_feet, now);
            } else startAct(.portal, now);
        }
        s.last_channel = ch;
        s.last_home = home_feet;
    }
    // Digitou: o rabisco some e o que ele fazia sozinho para. Mexeu: a torre cai nele.
    if (typed) {
        s.doodle = 0;
        if (isIdleAct(s.act)) s.act = .none;
    }
    if ((moved or typed) and s.tower and s.act != .tower) {
        s.tower = false;
        startAct(.tower_fall, now);
    }

    // --- Clique, arrasto, carinho e cutucada ----------------------------------
    // A área do clique é a janela inteira, e só ela: em casa, o lugar dele na barra
    // (nada mais mora ali); fora de casa (voando, tonto, voltando), o próprio corpo.
    const at_home = s.mode == .home or s.mode == .away;
    const hit_w = if (at_home) home_slot.w else size * 0.86;
    const hit_h = if (at_home) home_slot.h else size * 0.8;
    var hit_box: d.Rect = if (at_home) home_slot else .{ .x = s.x - hit_w / 2, .y = s.y - hit_h / 2, .w = hit_w, .h = hit_h };
    // Espiando atrás da lista de canais: só a parte de fora pega o clique.
    if (!at_home and s.clip.w > 0) {
        const l = @max(hit_box.x, s.clip.x);
        const rr = @min(hit_box.right(), s.clip.right());
        hit_box.x = l;
        hit_box.w = @max(1, rr - l);
    }
    const hit_min = d.v(hit_box.x, hit_box.y);
    const under = underPopup(ctx);
    // Um popup abriu no meio do arrasto: ele cai de onde estava.
    if (under and s.dragging) {
        s.dragging = false;
        if (s.mode == .grabbed) {
            s.mode = .flying;
            s.mode_ms = now;
        }
    }
    c.ImGui_SetNextWindowPos(hit_min, 0);
    c.ImGui_SetNextWindowSize(d.v(hit_box.w, hit_box.h), 0);
    _ = c.ImGui_Begin("##pet", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoBackground |
        c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoNav |
        c.ImGuiWindowFlags_NoFocusOnAppearing | (if (under) c.ImGuiWindowFlags_NoInputs else 0));
    // Ele se desenha na lista da própria janela: fica por cima da interface e, com um
    // popup aberto (que vem para a frente ao aparecer), por baixo dele.
    const dl = c.ImGui_GetWindowDrawList();
    if (!under) d.windowToFront();
    c.ImGui_SetCursorScreenPos(hit_min);
    _ = c.ImGui_InvisibleButton("##pet-hit", d.v(hit_box.w, hit_box.h), c.ImGuiButtonFlags_MouseButtonLeft);
    const hovered = c.ImGui_IsItemHovered(0);
    const active = c.ImGui_IsItemActive();
    const pressed = c.ImGui_IsItemActivated();
    const released = c.ImGui_IsItemDeactivated();
    c.ImGui_End();
    qa.markTop(hit_box, "pet", .{});
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
        s.act = .none;
        s.goal = .none;
        s.clip.w = 0;
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
        } else if (s.mode == .trip or s.mode == .perch) {
            // Clicou nele fora de casa: volta.
            goHome(now);
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

    // --- Vida própria: a interface, o mouse e o que fazer à toa --------------------------
    const idle_ms = now - s.last_input_ms;
    const awake = s.mode == .home and !s.nap and idle_ms < sleep_ms and !s.camped;
    const ui_ok = set.mascot_ui and awake and focused and s.react == .none;
    if (s.pend_delete) {
        s.pend_delete = false;
        if (ui_ok and s.act == .none) startAct(.trash, now);
    }
    if (s.pend_edit) {
        s.pend_edit = false;
        if (ui_ok and s.act == .none) startAct(.erase, now);
    }
    if (s.pend_resize) {
        s.pend_resize = false;
        if (ui_ok and s.act == .none and now - s.resize_ms > 2000) {
            s.resize_ms = now;
            if (rand() % 3 == 0) {
                // Caiu: quica, fica tonto e volta andando.
                s.mode = .flying;
                s.mode_ms = now;
                s.vx = if (rand() % 2 == 0) -170 else 170;
                s.vy = -320;
            } else startAct(.hold, now);
        }
    }
    if (s.pend_dm) {
        // A DM chega junto com o susto da menção (onPing): a cartinha vale mais.
        s.pend_dm = false;
        if (set.mascot_ui and awake and focused and now - s.dm_trip_ms > 90_000 and goTo(ctx, .dm, now)) {
            s.dm_trip_ms = now;
            s.react = .none;
        }
    }
    // Alguém digitando: senta em cima do "digitando…" (não enquanto você mesmo digita).
    if (ui_ok and s.mode == .home and s.act == .none and now - s.typing_trip_ms > 45_000 and now - s.type_ms > 2000 and anchorRect(.typing, now) != null) {
        if (goTo(ctx, .typing, now)) s.typing_trip_ms = now;
    }
    // O botão de voltar ao fim apareceu: vai lá empurrar (assim que estiver livre,
    // enquanto o botão estiver lá).
    if (anchorRect(.jump, now) == null) {
        s.jump_seen = false;
    } else if (!s.jump_seen and ui_ok and s.mode == .home and s.act == .none and now - s.jump_trip_ms > 60_000) {
        s.jump_seen = true;
        if (goTo(ctx, .jump, now)) s.jump_trip_ms = now;
    }
    // A setinha parada: perto, ele tenta pegar; em cima dele, senta nela.
    if (@abs(mouse.x - s.still_x) > 2 or @abs(mouse.y - s.still_y) > 2) {
        s.still_x = mouse.x;
        s.still_y = mouse.y;
        s.still_ms = now;
    }
    const cursor_on = set.mascot_cursor and awake and focused and s.act == .none and s.react == .none and mouse.x > -1000 and !active;
    if (cursor_on) {
        const still_for = now - s.still_ms;
        const near = dist(mouse.x, mouse.y, s.x, s.y);
        if (hovered and still_for > 2500 and now - s.trip_ms > 60_000) {
            _ = goTo(ctx, .cursor, now);
        } else if (!hovered and near > 30 and near < 130 and still_for > 1500 and now - s.grab_ms > 20_000) {
            s.grab_ms = now;
            startAct(.grab, now);
        }
    }
    if (s.need_catch) {
        s.need_catch = false;
        pickCatch(ctx);
    }
    if (s.qa_goal != .none) {
        s.qa_go_failed = !goTo(ctx, s.qa_goal, now);
        s.qa_goal = .none;
    }
    // À toa: de vez em quando ele faz alguma coisa sozinho (até dormir).
    const life = set.mascot_life;
    const interval: i64 = switch (life) {
        0 => 1,
        1 => 90_000,
        2 => 45_000,
        else => 22_000,
    };
    const life_ready = life > 0 and awake and s.mode == .home and focused and s.react == .none and s.act == .none and s.trick_ms == 0;
    // A plantinha murcha é regada mesmo com a vida própria desligada (a chave dela promete).
    if (life == 0 and set.mascot_plant and set.mascot_plant_wilted and awake and s.mode == .home and focused and s.react == .none and s.act == .none and idle_ms >= 8000) startAct(.water, now);
    if (life_ready) {
        if (s.next_act_ms <= s.last_input_ms) s.next_act_ms = s.last_input_ms + 8000 + @mod(@as(i64, rand()), interval);
        if (now >= s.next_act_ms) {
            s.next_act_ms = now + @divTrunc(interval * (70 + @as(i64, rand() % 60)), 100);
            pickLife(ctx, now);
        }
    }

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
        .trip => {
            // Um pulo em arco do ponto de partida até o próximo ponto do caminho.
            const f = std.math.clamp(secs(now, s.hop_ms) / s.hop_len, 0, 1);
            const y0 = s.hop_from[1];
            const y1 = s.hop_to[1];
            const lift = 4 * f * (1 - f) * (s.hop_h + @abs(y1 - y0) * 0.5);
            s.x = s.hop_from[0] + (s.hop_to[0] - s.hop_from[0]) * f;
            s.y = y0 + (y1 - y0) * f - lift - foot_off;
            s.spin = 0;
            if (f >= 1) {
                // A casa pode ter mudado de lugar no caminho (a janela mudou de tamanho).
                if (s.goal == .home) s.dest = home_feet;
                if (std.math.hypot(s.hop_to[0] - s.dest[0], s.hop_to[1] - s.dest[1]) < 1.5) arrive(now) else nextHop(now);
            }
        },
        .perch => {
            var done = now >= s.perch_until;
            switch (s.goal) {
                .typing => if (anchorRect(.typing, now) == null) {
                    done = true;
                },
                .jump => if (anchorRect(.jump, now) == null) {
                    done = true;
                },
                .cursor => if (dist(mouse.x, mouse.y, s.dest[0] - 3, s.dest[1] + 1) > 4) {
                    // A setinha saiu de baixo dele: cai.
                    s.mode = .flying;
                    s.mode_ms = now;
                    s.vx = 0;
                    s.vy = 0;
                    s.goal = .none;
                    done = false;
                },
                else => {},
            }
            // O lugar em que ele pousou sumiu ou mudou de posição (mensagem nova,
            // rolagem, a lista de membros que some): volta em vez de ficar no ar.
            switch (s.goal) {
                .msg, .members, .header, .channels => {
                    const was = s.perch_at;
                    const cur = anchorFor(s.goal, now);
                    if (was == null or cur == null) {
                        done = true;
                    } else if (@abs(cur.?.x - was.?.x) > 3 or @abs(cur.?.y - was.?.y) > 3 or @abs(cur.?.w - was.?.w) > 3 or @abs(cur.?.h - was.?.h) > 3) done = true;
                },
                else => {},
            }
            if (done and s.mode == .perch) goHome(now);
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
    pl.hat = if (st.settings.mascot_date_hats) contas.hatFor(lt.month, lt.day) else .none;
    pl.clock = @as(f32, @floatFromInt(@mod(now, 60_000))) / 1000.0;
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
        .home, .trip, .perch => {},
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

    // --- Vida própria: as poses ------------------------------------------------------------
    var fly_pt: ?c.ImVec2 = null;
    var slow_anim = false;
    if (s.act != .none and secs(now, s.act_ms) > actSeconds(s.act)) endAct(ctx, now);
    const at = secs(now, s.act_ms);
    if (s.act != .none and s.react == .none and s.mode == .home) {
        anim_until = @max(anim_until, s.act_ms + @as(i64, @intFromFloat(actSeconds(s.act) * 1000)));
        const f = at / actSeconds(s.act);
        switch (s.act) {
            .none => {},
            .scratch => {
                pl.wave = if (at < 1.7) @sin(at * 24) * 0.22 else 0;
                pl.face = .happy;
                pl.look = .{ 0.6, -0.6 };
                pl.spin = 0.05;
            },
            .char_play => {
                pl.cursor = @mod(now, 240) < 120;
                pl.pop = @abs(@sin(at * 7)) * 1.5;
                pl.look = .{ 0.3, 0.7 };
                pl.face = .happy;
            },
            .coffee => {
                const lift = sip(at);
                pl.look = .{ 0.8, 0.1 };
                if (lift > 0.5) {
                    pl.face = .happy;
                    pl.spin = -0.05 * lift;
                }
            },
            .book => pl.look = .{ 0, 0.9 },
            .game => {
                pl.look = .{ 0, 0.9 };
                pl.pop = @abs(@sin(at * 9)) * 0.6;
                pl.face = if (@mod(at, 1.4) < 0.7) .happy else .startled;
            },
            .gum => pl.face = if (at > 2.2 and at < 2.6) .startled else .prompt,
            .whistle => {
                pl.mouth = 0.25;
                pl.look = .{ 0.7, -0.6 };
                pl.spin = @sin(at * 3) * 0.05;
            },
            .clean => {
                pl.face = .sleep;
                pl.spin = @sin(at * 9) * 0.03;
            },
            .nap_sit => {
                pl.face = .sleep;
                pl.ears = 0.25;
                pl.squash = 0.06;
                slow_anim = true;
            },
            .exercise => switch (s.act_var % 3) {
                // Flexão.
                0 => {
                    pl.squash = 0.22 * @abs(@sin(at * 5));
                    pl.face = .worried;
                    pl.drop = 1;
                    pl.drop_slide = @mod(at * 0.5, 1);
                },
                // Alongamento.
                1 => {
                    const up = @sin(std.math.pi * f);
                    pl.squash = -0.25 * up;
                    pl.ears = -0.3 * up;
                    pl.face = .sleep;
                },
                // Polichinelo.
                else => {
                    bob = -@abs(@sin(at * 7)) * size * 0.18;
                    pl.wave = @sin(at * 14) * 0.35;
                    pl.face = .happy;
                },
            },
            .fly => {
                const caught = at > 3.6;
                if (!caught) fly_pt = d.v(s.x + @sin(at * 2.3) * size * 0.9 + @sin(at * 5.1) * size * 0.2, s.y - size * 0.35 + @cos(at * 3.1) * size * 0.25);
                if (fly_pt) |fp| pl.look = .{ std.math.clamp((fp.x - s.x) / 60, -1, 1), std.math.clamp((fp.y - s.y) / 50, -1, 1) };
                // Dois pulos errando e o terceiro pega.
                for ([_]f32{ 1.2, 2.4, 3.3 }) |j| bob = @min(bob, -kick(at - j, 0.45) * size * 0.5);
                pl.face = if (caught) .happy else if (at > 1.2) .startled else .prompt;
                if (at > 3.3 and at < 3.7) pl.mouth = 1;
            },
            .fish => {
                pl.look = .{ -0.5, -0.8 };
                pl.face = if (at > 3.9) .happy else .prompt;
            },
            .tower => {
                bob = -kick(@mod(at, 0.6), 0.25) * size * 0.08;
                pl.look = .{ -0.8, 0.3 };
                pl.face = if (at > 3.6) .happy else .prompt;
            },
            .doodle => {
                pl.look = .{ -0.9, 0.2 };
                pl.spin = -0.08;
            },
            .water => {
                pl.look = .{ -1, 0.4 };
                pl.spin = -0.12;
                pl.face = .happy;
            },
            .trash => {
                slide = -16 * std.math.clamp((at - 0.5) / 0.6, 0, 1) * std.math.clamp((2.4 - at) / 0.5, 0, 1);
                pl.look = .{ -1, 0 };
            },
            .erase => pl.look = .{ 1, 0.4 },
            .pack => {
                bob = -@abs(@sin(at * 10)) * size * 0.12;
                pl.face = if (at < 0.4) .startled else .happy;
            },
            .portal => shrink = @max(0.02, @abs(@cos(std.math.pi * f))),
            .peek => {
                pl.look = .{ 1, -0.3 };
                pl.face = if (at < 0.3) .startled else .happy;
                pl.spin = 0.1 * @sin(std.math.pi * f);
            },
            .grab => {
                const dir: f32 = if (mouse.x < s.x) -1 else 1;
                slide = dir * std.math.clamp(@abs(mouse.x - s.x) - 20, 0, 50) * @sin(std.math.pi * f);
                bob = -@sin(std.math.pi * f) * size * 0.45;
                pl.face = .startled;
                pl.ears = -0.3;
                pl.look = .{ dir, -0.6 };
            },
            .hold => {
                pl.ears = -0.35;
                pl.face = .worried;
                pl.spin = @sin(at * 14) * 0.1 * (1 - f);
                pl.squash = -0.12;
            },
            .tower_fall => {
                pl.face = if (at > 0.4) .dizzy else .startled;
                pl.squash = kick(at - 0.4, 0.3) * 0.3;
            },
        }
    }
    if (s.mode == .trip) {
        anim_until = @max(anim_until, now + 40);
        const hf = std.math.clamp(secs(now, s.hop_ms) / s.hop_len, 0, 1);
        pl.face = .happy;
        pl.look = .{ if (s.hop_to[0] < s.hop_from[0]) -1 else 1, if (s.hop_to[1] < s.hop_from[1]) -0.5 else 0.2 };
        pl.ears = -0.15;
        pl.squash = -0.1 * @sin(std.math.pi * hf) + kick(hf - 0.85, 0.15) * 0.2;
    }
    if (s.mode == .perch) {
        const pt = secs(now, s.perch_ms);
        switch (s.goal) {
            .msg, .members => {
                pl.squash = 0.06;
                if (pt < 0.6) pl.face = .happy;
            },
            .header => {
                // Pendurado pelas orelhas, balançando até parar.
                pl.ears = -0.4;
                pl.face = .happy;
                pl.spin = @sin(pt * 2.6) * 0.15 * @max(0, 1 - pt / 3);
                if (pt < 3) anim_until = @max(anim_until, now + 40);
            },
            .channels => {
                // Olhando para a conversa, do lado de onde ele espia.
                pl.look = .{ if (s.clip.x < 0) -1 else 1, 0 };
                pl.face = .happy;
            },
            .typing => {
                // Balançando as perninhas (devagar: 15 quadros por segundo).
                pl.wave = @sin(pt * 6) * 0.18;
                pl.look = .{ 0, 0.6 };
                pl.face = .happy;
                slow_anim = true;
            },
            .jump => {
                // Empurrando o botão: "volta lá".
                pl.spin = 0.16;
                pl.squash = @sin(pt * 9) * 0.07;
                pl.face = .worried;
                pl.look = .{ 1, 0.2 };
                slow_anim = true;
            },
            .dm => {
                pl.face = .happy;
                if (pt < 0.9) anim_until = @max(anim_until, now + 40);
            },
            .cursor => {
                pl.face = .happy;
                pl.squash = 0.05;
                pl.look = .{ 0, 0.8 };
            },
            .mouse => {
                if (pt < 1.2) {
                    bob = -@abs(@sin(pt * 9)) * size * 0.2;
                    anim_until = @max(anim_until, now + 40);
                }
                pl.face = .happy;
                pl.ears = -0.2;
            },
            .none, .home => {},
        }
    }
    // Acampado: dormindo do lado da fogueira. Sem foco: esperando você, de olho na porta.
    if (s.camped and s.mode == .home) {
        pl.face = .sleep;
        pl.squash = 0.05;
        pl.look = .{ -0.3, 0.3 };
    } else if (!focused and away_on and s.mode == .home and s.react == .none) {
        pl.face = .prompt;
        pl.look = .{ -1, -0.6 };
        pl.ears = -0.1;
    }

    // O truque esperando um terceiro clique: um quadro na hora de decidir.
    if (s.trick_ms != 0) anim_until = @max(anim_until, s.trick_ms + trick_wait_ms + 20);
    // --- Quadros: só enquanto algo anima, e só com a janela em foco ----------------------
    if (focused) {
        if (s.mode == .grabbed or s.mode == .flying or s.mode == .walking or s.mode == .dizzy) {
            anim.active = true;
        } else if (anim_until > now) {
            anim.at(now + 33);
        } else if (slow_anim) {
            anim.at(now + 66);
        } else if (asleep) {
            // Os "Z" sobem uns segundos depois de dormir e param; mais tarde, um quadro na
            // hora de acampar.
            const zt = secs(now, sleep_from);
            if (zt < 8) anim.at(now + 66) else if (away_on and !s.camped and !s.nap) anim.at(s.last_input_ms + camp_after_ms + 10);
        } else if (s.mode == .home) {
            // A hora de dormir, a próxima coisa que ele faz sozinho e a setinha parada: um
            // quadro em cada uma, e nada no meio.
            var wake = s.last_input_ms + sleep_ms + 10;
            if (life_ready) wake = @min(wake, @max(s.next_act_ms, now + 50));
            // A planta murcha com a vida própria desligada: um quadro na hora de regar.
            if (life == 0 and set.mascot_plant and set.mascot_plant_wilted) wake = @min(wake, @max(s.last_input_ms + 8010, now + 50));
            if (cursor_on and now - s.still_ms < 2600) wake = @min(wake, s.still_ms + (if (now - s.still_ms < 1500) @as(i64, 1510) else 2510));
            anim.at(wake);
        }
        if (s.mode == .perch) anim.at(s.perch_until);
        if (s.balloon_until > now) anim.at(s.balloon_until);
    }

    // --- Desenho (por cima de tudo) ------------------------------------------------------
    c.ImDrawList_PushClipRectFullScreen(dl);
    defer c.ImDrawList_PopClipRect(dl);
    const cx = s.x + slide;
    // Encolhido ou inflado, os pés ficam no mesmo lugar. Afundado, só as orelhas
    // passam da linha dos pés.
    const cy_fx = s.y + bob + (1 - shrink) * (99 - 42.5) * k;
    const cy = cy_fx + sink * (99 - 8) * k;
    const dsize = size * shrink;
    const feet_y = home_slot.bottom() - 4;
    const tsec = @as(f32, @floatFromInt(@mod(now, 60_000))) / 1000.0;
    // A plantinha, à esquerda dele no lugar da barra.
    if (pw > 0) props.plant(dl, d.v(home_slot.x + pw / 2 + 1, home_slot.bottom() - 5), 22, set.mascot_plant_days, set.mascot_plant_wilted);
    // Acampado: a barraca e a fogueira do lado (desmontando na volta).
    if (s.camped or s.act == .pack) {
        const fold: f32 = if (s.act == .pack) std.math.clamp(at / 1.0, 0, 1) else 0;
        props.tent(dl, d.v(home_slot.x - 26, feet_y), 30, fold);
        props.campfire(dl, d.v(home_slot.x - 4, feet_y), 18, tsec, 1 - fold);
    }
    // A torre de blocos e o rabisco na caixa.
    if (s.tower or s.act == .tower or s.act == .tower_fall) {
        const n: f32 = if (s.act == .tower) at / 0.6 else 6;
        const fall: f32 = if (s.act == .tower_fall) std.math.clamp(at / 0.9, 0, 1) else 0;
        props.blocks(dl, ctx.ui.get(.bold), d.v(home_slot.x - 12, feet_y), 10, n, fall);
    }
    if (s.doodle != 0) if (anchorRect(.input, now)) |ir| {
        const prog: f32 = if (s.act == .doodle) std.math.clamp(at / 2.2, 0, 1) else 1;
        props.doodle(dl, d.v(ir.right() - 40, ir.y + ir.h / 2), 9, s.doodle == 2, prog, ctx.col(.accent).alpha(0.55));
    };
    // Atrás da lista de canais: o que passa da borda some.
    if (s.clip.w > 0) c.ImDrawList_PushClipRect(dl, d.v(s.clip.x, s.clip.y), d.v(s.clip.right(), s.clip.bottom()), true);
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
    if (s.clip.w > 0) c.ImDrawList_PopClipRect(dl);
    // O que ele segura, na frente dele.
    const body: props.Body = .{ .cx = cx, .cy = cy, .size = dsize };
    if (s.mode == .home and s.react == .none) switch (s.act) {
        .coffee => props.mug(dl, body, sip(at), tsec),
        .book => props.book(dl, body, at),
        .game => props.handheld(dl, body, at),
        .gum => props.gum(dl, body, std.math.clamp(at / 2.2, 0, 1), if (at > 2.2) std.math.clamp((at - 2.2) / 0.4, 0, 1) else 0),
        // As notas na cor do texto: a de destaque é a do corpo dele.
        .whistle => props.notes(dl, body, at, ctx.col(.text)),
        .clean => props.rag(dl, body, at),
        .fly => if (fly_pt) |fp| props.fly(dl, fp, 7, tsec),
        .fish => {
            const cast = std.math.clamp(at / 0.5, 0, 1);
            const reel = std.math.clamp((at - 3.0) / 0.9, 0, 1);
            const hook = props.rod(dl, body, cast, reel, @sin(at * 5));
            const rise = std.math.clamp((at - 4.8) / 0.8, 0, 1);
            if (reel > 0 and rise < 1) {
                // Puxou: o emoji vem no anzol e depois ele mostra em cima da cabeça.
                const p0 = if (at > 3.9) body.p(64, -26 - rise * 40) else hook;
                const sz = 18 * (1 - rise * 0.3);
                if (s.catch_r.len > 0) props.caught(ctx, dl, &s.catch_r, p0, sz) else props.fish(dl, p0, sz, @sin(at * 20) * 2);
            }
        },
        .water => props.wateringCan(dl, body.p(-14, 66), 20, std.math.clamp(at / 0.4, 0, 1) * 0.9, at),
        .trash => {
            const can = d.v(home_slot.x - 10, feet_y);
            const lid = std.math.clamp((at - 0.9) / 0.3, 0, 1) * std.math.clamp((2.1 - at) / 0.3, 0, 1);
            props.trash(dl, can, 16, lid);
            if (at < 0.5) {
                props.paperBall(dl, body.p(64, 84), 3 + at * 8);
            } else if (at < 1.5) {
                props.paperBall(dl, body.p(64, -12), 6);
            } else if (at < 1.9) {
                const g = (at - 1.5) / 0.4;
                const from = body.p(64, -12);
                props.paperBall(dl, d.v(from.x + (can.x - from.x) * g, from.y + (can.y - 14 - from.y) * g), 6 * (1 - g * 0.4));
            }
        },
        .erase => props.eraser(dl, body.p(124 + @sin(at * 18) * 8, 82), 18, @sin(at * 18) * 0.4, at),
        .portal => {
            const ring = @sin(std.math.pi * std.math.clamp(at / 0.8, 0, 1));
            c.ImDrawList_AddEllipseFilled(dl, d.v(cx, feet_y), d.v(size * 0.5 * ring, size * 0.12 * ring), ctx.col(.accent).col(0.55 * ring));
        },
        .nap_sit => terminal.zzz(dl, d.v(cx + size * 0.3, cy - size * 0.45), size / 150, at, 1),
        else => {},
    };
    // A cartinha da DM: levando na ida e entregando no ícone.
    if (s.goal == .dm) {
        if (s.mode == .trip) {
            props.letter(dl, body.p(64, -16), 18, 0.1 * @sin(tsec * 6));
        } else if (s.mode == .perch) if (anchorRect(.dm_icon, now)) |gr| {
            const g = std.math.clamp(secs(now, s.perch_ms) / 0.7, 0, 1);
            const from = body.p(64, -16);
            const to = d.v(gr.x + gr.w / 2, gr.y + gr.h / 2);
            if (g < 1) props.letter(dl, d.v(from.x + (to.x - from.x) * g, from.y + (to.y - from.y) * g - @sin(std.math.pi * g) * 20), 18 * (1 - g * 0.5), g * 6);
        };
    }
    effects(dl, now, cx, cy_fx, size, asleep, sleep_from, rt);
    badge(dl, status, cx, cy_fx, size, asleep);
    // O balão de fala.
    if (now < s.balloon_until) props.balloon(dl, ctx.ui.get(.medium), d.v(cx, cy_fx - size * 0.62), i18n.tr("Senti saudade!", "Missed you!"), ctx.col(.elevated), ctx.col(.text), 1, ctx.win);
}

/// A caneca subindo até a boca nos dois goles.
fn sip(t: f32) f32 {
    const one = std.math.clamp((t - 0.6) / 0.15, 0, 1) * std.math.clamp((1.3 - t) / 0.15, 0, 1);
    const two = std.math.clamp((t - 1.9) / 0.15, 0, 1) * std.math.clamp((2.6 - t) / 0.15, 0, 1);
    return @max(one, two);
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
pub fn activity() Act {
    return s.act;
}
pub fn goalNow() Goal {
    return s.goal;
}
pub fn isCamped() bool {
    return s.camped;
}
pub fn hasTower() bool {
    return s.tower;
}
pub fn doodleKind() u8 {
    return s.doodle;
}
pub fn balloonOn(now: i64) bool {
    return now < s.balloon_until;
}
pub fn qaShown(now: i64) bool {
    return now - shown_ms < 300;
}
pub fn qaVeiled(a: Anchor, now: i64) bool {
    return now - veiled_ms[@intFromEnum(a)] < 300;
}
pub fn qaGoFailed() bool {
    return s.qa_go_failed;
}
/// Quanto do corpo dele está de fora do corte (espiando atrás da lista de canais).
pub fn qaVisibleWidth() f32 {
    const half = base_size * 0.39;
    var l = s.x - half;
    var r = s.x + half;
    if (s.clip.w > 0) {
        l = @max(l, s.clip.x);
        r = @min(r, s.clip.right());
    }
    return @max(0, r - l);
}
/// Faz agora uma das coisas da vida própria (o QA não espera a vez dele). `variant`
/// escolhe o tipo de exercício.
pub fn qaAct(a: Act, variant: u8, now: i64) void {
    s.mode = .home;
    s.react = .none;
    s.goal = .none;
    startAct(a, now);
    s.act_var = variant;
    if (a == .doodle) s.doodle = 1;
}
/// Sai para um lugar da tela no próximo quadro.
pub fn qaGo(g: Goal) void {
    s.qa_goal = g;
}
/// A próxima coisa que ele faz sozinho é agora.
pub fn qaLifeNow() void {
    s.next_act_ms = s.last_input_ms + 1;
}
/// A janela está sem foco há tanto tempo.
pub fn qaAwayFor(ms: i64, now: i64) void {
    s.away_ms = now - ms;
}
/// Tudo da vida própria do começo: em casa, sem nada montado e sem esperar a vez.
pub fn qaLifeReset(now: i64) void {
    s.mode = .home;
    s.react = .none;
    s.act = .none;
    s.goal = .none;
    s.clip.w = 0;
    s.tower = false;
    s.doodle = 0;
    s.camped = false;
    s.away_ms = 0;
    s.balloon_until = 0;
    s.next_act_ms = now + 3_600_000;
    s.qa_goal = .none;
    s.qa_go_failed = false;
    s.perch_at = null;
    s.trip_ms = -100_000;
    s.typing_trip_ms = -100_000;
    s.jump_trip_ms = -100_000;
    s.dm_trip_ms = -100_000;
    s.resize_ms = -100_000;
    s.grab_ms = -100_000;
    s.pend_delete = false;
    s.pend_edit = false;
    s.pend_dm = false;
    s.pend_resize = false;
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
