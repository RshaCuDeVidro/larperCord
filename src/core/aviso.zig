//! Quem avisa de uma mensagem que chegou, sem nada do app (testado em `zig
//! build test`): a notificação do sistema, o piscar na barra de tarefas e o
//! som de mensagem nova seguem a mesma regra, e ela sai daqui. Quem junta os
//! fatos é app.zig (`incoming`) com app_conta.zig (`arrival`).
const std = @import("std");
const conta = @import("conta.zig");

/// O que se sabe da mensagem na hora em que ela chega.
pub const Chegada = struct {
    /// Nossa (mandada daqui ou de outro aparelho).
    own: bool = false,
    /// Pedido de mensagem ou spam (fora da lista de DMs).
    request: bool = false,
    /// De alguém ignorado, ou pega por um filtro (core/filtros.zig `judge`).
    hidden: bool = false,
    /// DM, menção ou palavra de alerta, como no destaque (core/filtros.zig `judge`).
    important: bool = false,
    /// A conversa, a categoria ou o servidor silenciados na conta.
    muted: bool = false,
    /// O que a mensagem chama: DM, nós, @everyone/@here, um cargo nosso, alerta.
    ping: conta.Ping = .{},
    /// As notificações da conta para o lugar; null = nenhuma configuração, e
    /// vale `important` (DM, menção e alerta, como antes de ler a conta).
    regra: ?Regra = null,
};

/// O nível que vale no canal (core/conta.zig `effectiveLevel`) e as supressões
/// do servidor.
pub const Regra = struct {
    level: ?conta.Level = null,
    suppress_everyone: bool = false,
    suppress_roles: bool = false,
};

/// Avisa? A mesma resposta para a notificação, o piscar e o som. Silenciado
/// nunca avisa, nem com menção.
pub fn notifies(a: Chegada) bool {
    if (a.own or a.request or a.hidden or a.muted) return false;
    const r = a.regra orelse return a.important;
    return conta.shouldNotify(r.level, r.suppress_everyone, r.suppress_roles, a.ping);
}

/// Olhando a conversa com a janela em foco, a mensagem já foi vista: nada
/// avisa. Fora de foco (ou escondida na bandeja), até a conversa aberta avisa,
/// como no Discord.
pub fn seen(focused: bool, active: bool) bool {
    return focused and active;
}

/// O som de mensagem nova: quando toca e o intervalo entre um e outro.
pub const Som = struct {
    /// Quando tocou pela última vez (relógio monotônico, ms); null = ainda não.
    last_ms: ?i64 = null,
    /// Quantas vezes pediu o som (o QA conta por aqui, sem ouvir nada).
    played: u32 = 0,

    /// Uma rajada (várias DMs seguidas, um grupo animado) toca no máximo uma vez
    /// a cada `gap_ms`.
    pub const gap_ms: i64 = 1500;

    pub const Quando = struct {
        /// A chave "Som de mensagem nova" ligada e o som dela não desligado.
        on: bool,
        /// `notifies` da mensagem.
        alert: bool,
        /// Nosso status é "Não perturbe".
        dnd: bool,
        /// A janela à frente, com o foco (escondida na bandeja não conta).
        focused: bool,
        /// A mensagem é da conversa aberta.
        active: bool,
        now_ms: i64,
    };

    /// Toca? Sim: conta e guarda a hora. O que não toca não segura o próximo.
    pub fn want(s: *Som, q: Quando) bool {
        if (!q.on or !q.alert or q.dnd or seen(q.focused, q.active)) return false;
        // Relógio que voltou (outro computador, suspensão) não cala o som.
        if (s.last_ms) |t| if (q.now_ms >= t and q.now_ms - t < gap_ms) return false;
        s.last_ms = q.now_ms;
        s.played +%= 1;
        return true;
    }
};

// --- Testes ----------------------------------------------------------------

const t_expect = std.testing.expect;

/// Uma DM de alguém, numa conversa sem configuração na conta.
const dm: Chegada = .{ .important = true, .ping = .{ .dm = true } };
/// Mensagem comum num servidor sem configuração.
const plain: Chegada = .{};

test "quem avisa: DM, menção, @everyone e cargo; nossa, pedido, ignorada e silenciada não" {
    try t_expect(notifies(dm));
    try t_expect(notifies(.{ .important = true, .ping = .{ .me = true } }));
    try t_expect(!notifies(plain));
    // Palavra de alerta conta como menção.
    try t_expect(notifies(.{ .important = true, .ping = .{ .alert = true } }));
    // Nossa mensagem (de outro aparelho) nunca avisa, nem com menção a nós mesmos.
    var own = dm;
    own.own = true;
    try t_expect(!notifies(own));
    var req = dm;
    req.request = true;
    try t_expect(!notifies(req));
    var hid = dm;
    hid.hidden = true;
    try t_expect(!notifies(hid));
    // Silenciado vence tudo: DM, menção e "todas as mensagens".
    var muted = dm;
    muted.muted = true;
    try t_expect(!notifies(muted));
    try t_expect(!notifies(.{ .muted = true, .important = true, .ping = .{ .me = true }, .regra = .{ .level = .all } }));

    // Com a configuração da conta: @everyone e cargo seguem as supressões.
    const everyone: Chegada = .{ .important = true, .ping = .{ .everyone = true }, .regra = .{} };
    try t_expect(notifies(everyone));
    var sup = everyone;
    sup.regra = .{ .suppress_everyone = true };
    try t_expect(!notifies(sup));
    const role: Chegada = .{ .important = true, .ping = .{ .role = true }, .regra = .{ .level = .mentions } };
    try t_expect(notifies(role));
    var role_sup = role;
    role_sup.regra.?.suppress_roles = true;
    try t_expect(!notifies(role_sup));
    // "Todas as mensagens" avisa a comum; "Nada" cala até a menção.
    try t_expect(notifies(.{ .regra = .{ .level = .all } }));
    try t_expect(!notifies(.{ .important = true, .ping = .{ .me = true }, .regra = .{ .level = .nothing } }));
}

test "olhando a conversa com a janela em foco: visto; fora de foco, não" {
    try t_expect(seen(true, true));
    try t_expect(!seen(false, true));
    try t_expect(!seen(true, false));
    try t_expect(!seen(false, false));
}

fn ask(s: *Som, alert: bool, focused: bool, active: bool, now_ms: i64) bool {
    return s.want(.{ .on = true, .alert = alert, .dnd = false, .focused = focused, .active = active, .now_ms = now_ms });
}

test "som de mensagem: quando toca" {
    var s: Som = .{};
    // DM com a janela fora de foco, na conversa aberta: toca.
    try t_expect(ask(&s, notifies(dm), false, true, 10_000));
    try t_expect(s.played == 1);
    // Olhando a conversa com a janela em foco: não toca.
    s = .{};
    try t_expect(!ask(&s, notifies(dm), true, true, 10_000));
    // Em foco, mas em outra conversa: toca.
    try t_expect(ask(&s, notifies(dm), true, false, 10_000));
    // Mensagem comum, a nossa e a silenciada não tocam.
    s = .{};
    try t_expect(!ask(&s, notifies(plain), false, false, 10_000));
    var own = dm;
    own.own = true;
    try t_expect(!ask(&s, notifies(own), false, false, 10_000));
    var muted = dm;
    muted.muted = true;
    try t_expect(!ask(&s, notifies(muted), false, false, 10_000));
    try t_expect(s.played == 0 and s.last_ms == null);
    // Não perturbe e a chave desligada: nada.
    try t_expect(!s.want(.{ .on = true, .alert = true, .dnd = true, .focused = false, .active = false, .now_ms = 10_000 }));
    try t_expect(!s.want(.{ .on = false, .alert = true, .dnd = false, .focused = false, .active = false, .now_ms = 10_000 }));
    try t_expect(s.played == 0);
}

test "som de mensagem: uma rajada toca uma vez a cada intervalo" {
    var s: Som = .{};
    try t_expect(ask(&s, true, false, false, 50_000));
    // Mais três logo atrás: caladas.
    try t_expect(!ask(&s, true, false, false, 50_200));
    try t_expect(!ask(&s, true, false, false, 50_900));
    try t_expect(!ask(&s, true, false, false, 50_000 + Som.gap_ms - 1));
    // Passado o intervalo (contado do último que tocou), toca de novo.
    try t_expect(ask(&s, true, false, false, 50_000 + Som.gap_ms));
    try t_expect(s.played == 2);
    // O que não toca (visto) não segura o próximo nem conta.
    var q: Som = .{};
    try t_expect(!ask(&q, true, true, true, 60_000));
    try t_expect(ask(&q, true, false, false, 60_100));
    // Relógio que voltou não cala.
    try t_expect(ask(&q, true, false, false, 1_000));
}
