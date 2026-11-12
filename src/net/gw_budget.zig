//! Teto de envio do gateway. O Discord aceita 120 eventos por conexão a cada
//! 60 s e derruba quem passa disso (docs.discord.food, "Rate Limiting"); o
//! op 8 tem limite próprio, um por servidor por sessão a cada 30 s (a fila solta no
//! máximo isso, com folga; o app pede só os membros dos autores de uma página de
//! histórico, net/member_ask.zig, e conta no mesmo teto). A presença ainda fica em 5 a
//! cada 20 s por conta nossa (a doc não dá número; trocar de status mais que
//! isso não tem porquê). Aqui:
//!  - heartbeat (op 1), IDENTIFY (op 2) e RESUME (op 6) saem sempre e na hora:
//!    contam no teto, mas nada os segura (`Budget.note` direto, sem fila);
//!  - o resto para em 110 por janela: a folga até 120 é deles;
//!  - presença (op 3) e lista de membros (op 14) se juntam: só o último pedido
//!    de cada um (op 14: por servidor) sai quando houver vez;
//!  - estado de voz (op 4) entra numa fila e sai na ordem, sem perder nenhum;
//!  - o começo das calls de um servidor (op 43) sai uma vez por servidor: o mesmo
//!    servidor de novo, enquanto espera, não pede outra vez.
//! Lógica pura: quem escreve no WebSocket é net/discord.zig.
const std = @import("std");
const types = @import("../core/types.zig");
const member_ask = @import("member_ask.zig");
const Id = types.Id;

pub const window_ms: i64 = 60_000;
/// O que não é heartbeat/IDENTIFY/RESUME: até aqui por janela.
pub const normal_limit: usize = 110;
pub const presence_limit: usize = 5;
pub const presence_window_ms: i64 = 20_000;

/// As últimas `N` vezes que algo saiu (janela deslizante).
fn Ring(comptime N: usize) type {
    return struct {
        const Self = @This();
        t: [N]i64 = undefined,
        head: usize = 0,
        len: usize = 0,

        fn prune(r: *Self, now_ms: i64, window: i64) void {
            while (r.len > 0 and now_ms - r.t[r.head] >= window) {
                r.head = (r.head + 1) % N;
                r.len -= 1;
            }
        }

        /// Cheio, esquece o mais antigo (a conta só fica mais conservadora).
        fn push(r: *Self, now_ms: i64) void {
            if (r.len == N) {
                r.head = (r.head + 1) % N;
                r.len -= 1;
            }
            r.t[(r.head + r.len) % N] = now_ms;
            r.len += 1;
        }

        fn count(r: *Self, now_ms: i64, window: i64) usize {
            r.prune(now_ms, window);
            return r.len;
        }

        /// Quando o mais antigo sai da janela.
        fn oldestExpires(r: *const Self, window: i64) i64 {
            return if (r.len == 0) 0 else r.t[r.head] + window;
        }
    };
}

pub const Budget = struct {
    /// Cabe tudo o que sai numa janela (110 comuns + os de prioridade).
    sent: Ring(128) = .{},

    /// Algo saiu agora (qualquer op, inclusive heartbeat).
    pub fn note(b: *Budget, now_ms: i64) void {
        b.sent.push(now_ms);
    }

    pub fn used(b: *Budget, now_ms: i64) usize {
        return b.sent.count(now_ms, window_ms);
    }

    /// Um op comum pode sair agora?
    pub fn allows(b: *Budget, now_ms: i64) bool {
        return b.used(now_ms) < normal_limit;
    }

    /// Quando um op comum pode sair (agora, se já pode).
    pub fn freeAt(b: *Budget, now_ms: i64) i64 {
        if (b.allows(now_ms)) return now_ms;
        // Passou de 110 só com heartbeats no meio: espera sair o bastante.
        const extra = b.sent.len - normal_limit;
        return b.sent.t[(b.sent.head + extra) % b.sent.t.len] + window_ms;
    }

    /// Conexão nova: o Discord conta do zero.
    pub fn reset(b: *Budget) void {
        b.sent = .{};
    }
};

/// Op 14: a lista de membros de um servidor vista de um canal (e de uma thread).
pub const Lazy = struct { guild: Id, channel: Id, thread: Id = 0 };
/// Op 4: entrar, sair ou mudar mudo/surdo (`channel` null = sair).
pub const Voice = struct {
    guild: Id,
    channel: ?Id,
    mute: bool = false,
    deaf: bool = false,

    /// O VOICE_STATE_UPDATE da própria conta mostra que este op 4 chegou ao Discord. Saindo,
    /// basta o canal vazio.
    pub fn confirmedBy(v: Voice, channel: ?Id, self_mute: bool, self_deaf: bool) bool {
        const want = v.channel orelse return channel == null;
        const got = channel orelse return false;
        return got == want and v.mute == self_mute and v.deaf == self_deaf;
    }
};
/// Op 8: o Discord aceita um por servidor por sessão a cada 30 s (docs.discord.food,
/// "Gateway", Sub Rate Limits); passando, responde RATE_LIMITED. A fila solta no máximo
/// um por servidor nessa janela, com folga, e junta as páginas que chegam enquanto isso.
pub const members_window_ms: i64 = 32_000;
/// O primeiro pedido de um servidor espera um pouco: abrir um canal e rolar para cima
/// juntam as páginas num pedido só.
pub const members_batch_ms: i64 = 1_000;

/// Um op 8 esperando: não sai antes de `ready_ms` (o lote ainda junta páginas).
pub const MembersWait = struct { req: member_ask.Request, ready_ms: i64 };
/// O próximo op 8 do servidor não sai antes de `until_ms`.
pub const MembersHold = struct { guild: Id, until_ms: i64 };

/// O que espera vez. A presença sai com o status do momento (só o último vale).
/// `channel_info`: o servidor do op 43.
/// `members`: um op 8 com os autores de uma página de histórico.
pub const Item = union(enum) { presence, lazy: Lazy, voice: Voice, channel_info: Id, members: member_ask.Request };
/// O que entra por `push` (o op 8 entra por `pushMembers`, que sabe a hora e devolve o
/// que não coube).
pub const Op = union(enum) { presence, lazy: Lazy, voice: Voice, channel_info: Id };

pub const Push = enum {
    queued,
    /// Juntou com um pedido do mesmo tipo que ainda não tinha saído.
    coalesced,
    /// A fila de voz encheu: o último estado de voz pendente virou este
    /// (o estado final é o mesmo). Quem chama registra.
    merged,
    /// Muitos servidores com op 14 pendente: o mais antigo deu lugar a este.
    replaced_oldest,
};

pub const Outbox = struct {
    budget: Budget = .{},
    presence_sent: Ring(presence_limit) = .{},
    presence: bool = false,
    /// Na ordem em que chegaram (o mesmo servidor de novo vai para o fim).
    lazy: [8]Lazy = undefined,
    lazy_n: usize = 0,
    voice: [64]Voice = undefined,
    voice_head: usize = 0,
    voice_n: usize = 0,
    /// Op 43 esperando, na ordem em que chegaram (um por servidor).
    info: [8]Id = undefined,
    info_n: usize = 0,
    /// Op 8 esperando, por último (o que é só cosmético espera o resto). No máximo
    /// dois por servidor: o que espera e o que passou dos 100 (sai na janela seguinte).
    members: [16]MembersWait = undefined,
    members_n: usize = 0,
    /// Por servidor: o último envio mais a janela, ou a espera de um RATE_LIMITED. Mais
    /// vagas do que op 8 cabem no teto numa janela: uma espera que não venceu nunca é
    /// despejada (sem vaga, o op 8 de um servidor novo espera uma vencer).
    holds: [128]MembersHold = undefined,
    holds_n: usize = 0,
    /// RATE_LIMITED sem dizer de que servidor: nenhum op 8 até lá.
    members_after: i64 = 0,

    pub fn push(o: *Outbox, it: Op) Push {
        switch (it) {
            .presence => {
                const was = o.presence;
                o.presence = true;
                return if (was) .coalesced else .queued;
            },
            .lazy => |l| {
                for (o.lazy[0..o.lazy_n], 0..) |x, i| if (x.guild == l.guild) {
                    std.mem.copyForwards(Lazy, o.lazy[i .. o.lazy_n - 1], o.lazy[i + 1 .. o.lazy_n]);
                    o.lazy[o.lazy_n - 1] = l;
                    return .coalesced;
                };
                if (o.lazy_n == o.lazy.len) {
                    std.mem.copyForwards(Lazy, o.lazy[0 .. o.lazy.len - 1], o.lazy[1..]);
                    o.lazy[o.lazy.len - 1] = l;
                    return .replaced_oldest;
                }
                o.lazy[o.lazy_n] = l;
                o.lazy_n += 1;
                return .queued;
            },
            .voice => |v| {
                if (o.voice_n == o.voice.len) {
                    o.voice[(o.voice_head + o.voice_n - 1) % o.voice.len] = v;
                    return .merged;
                }
                o.voice[(o.voice_head + o.voice_n) % o.voice.len] = v;
                o.voice_n += 1;
                return .queued;
            },
            .channel_info => |g| {
                if (std.mem.indexOfScalar(Id, o.info[0..o.info_n], g) != null) return .coalesced;
                if (o.info_n == o.info.len) {
                    std.mem.copyForwards(Id, o.info[0 .. o.info.len - 1], o.info[1..]);
                    o.info[o.info.len - 1] = g;
                    return .replaced_oldest;
                }
                o.info[o.info_n] = g;
                o.info_n += 1;
                return .queued;
            },
        }
    }

    /// Um op 8 entra: junta com o que espera do mesmo servidor (sem repetir, até 100), e o
    /// que sobra vai para outro, que só sai numa janela seguinte. false: a fila encheu, e o
    /// que não entrou fica em `r` (quem chama devolve essas pessoas ao Asker).
    pub fn pushMembers(o: *Outbox, r: *member_ask.Request, now_ms: i64) bool {
        var same: usize = 0;
        for (o.members[0..o.members_n]) |*w| {
            if (w.req.guild != r.guild) continue;
            same += 1;
            member_ask.mergeInto(&w.req, r);
            if (r.n == 0) return true;
        }
        // Um servidor não toma a fila dos outros.
        if (same >= 2 or o.members_n == o.members.len) return false;
        o.members[o.members_n] = .{ .req = r.*, .ready_ms = now_ms + members_batch_ms };
        o.members_n += 1;
        r.n = 0;
        return true;
    }

    /// Até quando o op 8 de `guild` espera.
    fn holdOf(o: *const Outbox, guild: Id) i64 {
        var until = o.members_after;
        for (o.holds[0..o.holds_n]) |h| if (h.guild == guild) {
            until = @max(until, h.until_ms);
        };
        return until;
    }

    /// As esperas que já venceram dão lugar.
    fn pruneHolds(o: *Outbox, now_ms: i64) void {
        var k: usize = 0;
        for (o.holds[0..o.holds_n]) |h| if (h.until_ms > now_ms) {
            o.holds[k] = h;
            k += 1;
        };
        o.holds_n = k;
    }

    /// Dá para guardar a espera de `guild` (ela já tem vaga, ou sobra uma)?
    fn canHold(o: *const Outbox, guild: Id, now_ms: i64) bool {
        if (o.holds_n < o.holds.len) return true;
        for (o.holds[0..o.holds_n]) |h| if (h.guild == guild or h.until_ms <= now_ms) return true;
        return false;
    }

    /// O próximo op 8 de `guild` não sai antes de `until_ms` (vale a espera mais longa).
    /// Uma espera que não venceu nunca sai daqui: sem vaga (só com mais op 8 numa janela
    /// do que o teto deixa), a de agora fica sem guardar e `canHold` segura os próximos.
    pub fn hold(o: *Outbox, guild: Id, until_ms: i64, now_ms: i64) void {
        for (o.holds[0..o.holds_n]) |*h| if (h.guild == guild) {
            h.until_ms = @max(h.until_ms, until_ms);
            return;
        };
        if (o.holds_n == o.holds.len) o.pruneHolds(now_ms);
        if (o.holds_n == o.holds.len) return;
        o.holds[o.holds_n] = .{ .guild = guild, .until_ms = until_ms };
        o.holds_n += 1;
    }

    /// O op 8 que pode sair agora: o lote fechou, o servidor não está esperando e a
    /// espera dele tem onde ficar.
    fn nextMembers(o: *const Outbox, now_ms: i64) ?usize {
        for (o.members[0..o.members_n], 0..) |w, i| if (now_ms >= w.ready_ms and now_ms >= o.holdOf(w.req.guild) and o.canHold(w.req.guild, now_ms)) return i;
        return null;
    }

    fn dropMembersAt(o: *Outbox, i: usize) void {
        std.mem.copyForwards(MembersWait, o.members[i .. o.members_n - 1], o.members[i + 1 .. o.members_n]);
        o.members_n -= 1;
    }

    pub fn pending(o: *const Outbox) usize {
        return o.voice_n + o.lazy_n + o.info_n + o.members_n + @intFromBool(o.presence);
    }

    fn presenceOk(o: *Outbox, now_ms: i64) bool {
        return o.presence_sent.count(now_ms, presence_window_ms) < presence_limit;
    }

    /// O próximo que pode sair agora (já contado no teto). Voz primeiro (é a
    /// pessoa esperando a call), depois presença, listas de membros e o op 43.
    pub fn pop(o: *Outbox, now_ms: i64) ?Item {
        if (o.pending() == 0 or !o.budget.allows(now_ms)) return null;
        var it: Item = undefined;
        if (o.voice_n > 0) {
            it = .{ .voice = o.voice[o.voice_head] };
            o.voice_head = (o.voice_head + 1) % o.voice.len;
            o.voice_n -= 1;
        } else if (o.presence and o.presenceOk(now_ms)) {
            o.presence = false;
            o.presence_sent.push(now_ms);
            it = .presence;
        } else if (o.lazy_n > 0) {
            it = .{ .lazy = o.lazy[0] };
            std.mem.copyForwards(Lazy, o.lazy[0 .. o.lazy_n - 1], o.lazy[1..o.lazy_n]);
            o.lazy_n -= 1;
        } else if (o.info_n > 0) {
            it = .{ .channel_info = o.info[0] };
            std.mem.copyForwards(Id, o.info[0 .. o.info_n - 1], o.info[1..o.info_n]);
            o.info_n -= 1;
        } else if (o.nextMembers(now_ms)) |i| {
            const r = o.members[i].req;
            it = .{ .members = r };
            o.dropMembersAt(i);
            // Já conta a janela: o que sobrou do mesmo servidor espera a próxima.
            o.hold(r.guild, now_ms + members_window_ms, now_ms);
        } else return null;
        o.budget.note(now_ms);
        return it;
    }

    /// Devolve à frente da fila um item que `pop` tirou e que não chegou a sair (a escrita
    /// no WebSocket falhou): sai de novo depois do RESUME, na mesma ordem. O teto não é
    /// devolvido: a conexão cai e a próxima começa do zero (`newConnection`).
    pub fn unpop(o: *Outbox, it: Item) void {
        switch (it) {
            .presence => o.presence = true,
            .lazy => |l| {
                // Um pedido mais novo do mesmo servidor já está na fila: vale ele.
                for (o.lazy[0..o.lazy_n]) |x| if (x.guild == l.guild) return;
                // Cheia de pedidos mais novos: este era o mais antigo.
                if (o.lazy_n == o.lazy.len) return;
                std.mem.copyBackwards(Lazy, o.lazy[1 .. o.lazy_n + 1], o.lazy[0..o.lazy_n]);
                o.lazy[0] = l;
                o.lazy_n += 1;
            },
            .voice => |v| {
                // Logo depois de um `pop` sempre cabe; cheia, os estados mais novos valem.
                if (o.voice_n == o.voice.len) return;
                o.voice_head = (o.voice_head + o.voice.len - 1) % o.voice.len;
                o.voice[o.voice_head] = v;
                o.voice_n += 1;
            },
            .channel_info => |g| {
                if (std.mem.indexOfScalar(Id, o.info[0..o.info_n], g) != null or o.info_n == o.info.len) return;
                std.mem.copyBackwards(Id, o.info[1 .. o.info_n + 1], o.info[0..o.info_n]);
                o.info[0] = g;
                o.info_n += 1;
            },
            // A janela que o `pop` marcou fica (no pior caso, espera 30 s à toa).
            .members => |r| {
                if (o.members_n == o.members.len) return;
                std.mem.copyBackwards(MembersWait, o.members[1 .. o.members_n + 1], o.members[0..o.members_n]);
                o.members[0] = .{ .req = r, .ready_ms = 0 };
                o.members_n += 1;
            },
        }
    }

    /// Manda o que tem vez agora por `w.write(item)` (false = não saiu): para na primeira
    /// falha, com o item de volta na frente da fila e o resto esperando atrás dele.
    pub fn drainTo(o: *Outbox, now_ms: i64, w: anytype) void {
        while (o.pop(now_ms)) |it| if (!w.write(it)) {
            o.unpop(it);
            return;
        };
    }

    /// Quando acordar para `pop` (maxInt = nada esperando).
    pub fn due(o: *Outbox, now_ms: i64) i64 {
        if (o.pending() == 0) return std.math.maxInt(i64);
        const free = o.budget.freeAt(now_ms);
        if (o.voice_n > 0 or o.lazy_n > 0 or o.info_n > 0) return free;
        // Só a presença e o op 8: cada um espera também o limite dele.
        var at: i64 = std.math.maxInt(i64);
        if (o.presence) at = if (o.presenceOk(now_ms)) free else @max(free, o.presence_sent.oldestExpires(presence_window_ms));
        for (o.members[0..o.members_n]) |w| at = @min(at, @max(free, @max(w.ready_ms, o.holdOf(w.req.guild))));
        return at;
    }

    /// O Discord recusou um op 8 (RATE_LIMITED): nada daquele servidor (0 = não disse
    /// qual: de nenhum) antes de `wait_ms`, e nunca menos que a janela (o `retry_after`
    /// pode não vir). O pedido recusado, se sabemos qual foi, volta para a fila. false:
    /// não coube (o que não entrou fica em `r`).
    pub fn holdMembers(o: *Outbox, now_ms: i64, guild: Id, wait_ms: i64, r: ?*member_ask.Request) bool {
        const until = now_ms + @max(wait_ms, members_window_ms);
        if (guild == 0) o.members_after = @max(o.members_after, until) else o.hold(guild, until, now_ms);
        const x = r orelse return true;
        return o.pushMembers(x, 0);
    }

    /// Saímos do servidor: o op 8 dele sai da fila (quem chama já esqueceu as pessoas de
    /// lá no Asker). A espera fica: o limite é por servidor e por sessão, e sair não muda
    /// a sessão (voltar em menos de 30 s não pede de novo antes da hora).
    pub fn forgetMembers(o: *Outbox, guild: Id) void {
        var i: usize = o.members_n;
        while (i > 0) {
            i -= 1;
            if (o.members[i].req.guild == guild) o.dropMembersAt(i);
        }
    }

    /// Conexão nova: os limites recomeçam; o que espera continua esperando.
    pub fn newConnection(o: *Outbox) void {
        o.budget.reset();
        o.presence_sent = .{};
    }

    /// Sessão nova (READY): o que esperava era da anterior. Quem chama manda de
    /// novo o que ainda vale (voz, lista de membros; a presença foi no IDENTIFY).
    /// O op 8 também sai (pode ser de um servidor que deixamos enquanto estávamos
    /// fora): quem chama devolve as pessoas dele ao Asker antes, e elas são pedidas
    /// de novo quando a página aparecer. O teto fica (o READY chega na mesma conexão)
    /// e as esperas do op 8 também: não custa nada esperar a janela que já corria.
    pub fn forgetPending(o: *Outbox) void {
        o.presence = false;
        o.lazy_n = 0;
        o.info_n = 0;
        o.members_n = 0;
        o.voice_n = 0;
        o.voice_head = 0;
    }

    pub fn clear(o: *Outbox) void {
        o.* = .{};
    }
};

// --- Testes -------------------------------------------------------------------

const t = std.testing;

test "o teto para em 110 e libera quando a janela anda" {
    var b: Budget = .{};
    for (0..normal_limit) |i| {
        try t.expect(b.allows(1000 + @as(i64, @intCast(i))));
        b.note(1000 + @as(i64, @intCast(i)));
    }
    try t.expect(!b.allows(2000));
    try t.expectEqual(@as(i64, 1000 + window_ms), b.freeAt(2000));
    try t.expect(b.allows(1000 + window_ms));
    b.reset();
    try t.expectEqual(@as(usize, 0), b.used(0));
}

test "heartbeat, IDENTIFY e RESUME passam com o teto cheio e cabem nos 120" {
    var o: Outbox = .{};
    var now: i64 = 0;
    // Uma enxurrada de pedidos comuns: só 110 saem na janela.
    var sent: usize = 0;
    for (0..300) |i| {
        _ = o.push(.{ .voice = .{ .guild = 1, .channel = @intCast(i % 3) } });
        while (o.pop(now)) |_| sent += 1;
        now += 10;
    }
    try t.expectEqual(normal_limit, sent);
    // Os de prioridade não perguntam ao teto: saem na hora e são contados.
    for (0..10) |_| o.budget.note(now);
    try t.expect(o.budget.used(now) <= 120);
    // E nada comum sai até a janela andar.
    try t.expectEqual(@as(?Item, null), o.pop(now));
}

test "op 14 e presença: só o último de cada um sai" {
    var o: Outbox = .{};
    // Teto cheio: tudo espera.
    for (0..normal_limit) |_| o.budget.note(0);
    try t.expectEqual(Push.queued, o.push(.{ .lazy = .{ .guild = 1, .channel = 10 } }));
    try t.expectEqual(Push.coalesced, o.push(.{ .lazy = .{ .guild = 1, .channel = 11 } }));
    try t.expectEqual(Push.queued, o.push(.{ .lazy = .{ .guild = 2, .channel = 20 } }));
    try t.expectEqual(Push.coalesced, o.push(.{ .lazy = .{ .guild = 1, .channel = 12, .thread = 99 } }));
    try t.expectEqual(Push.queued, o.push(.presence));
    try t.expectEqual(Push.coalesced, o.push(.presence));
    try t.expectEqual(Push.coalesced, o.push(.presence));
    try t.expectEqual(@as(usize, 3), o.pending());
    try t.expectEqual(@as(?Item, null), o.pop(10));
    try t.expectEqual(window_ms, o.due(10));
    const later = window_ms;
    try t.expectEqual(Item.presence, o.pop(later).?);
    // O servidor 2 pediu antes do último pedido do 1.
    try t.expectEqual(@as(Id, 20), o.pop(later).?.lazy.channel);
    const l1 = o.pop(later).?.lazy;
    try t.expectEqual(@as(Id, 12), l1.channel);
    try t.expectEqual(@as(Id, 99), l1.thread);
    try t.expectEqual(@as(?Item, null), o.pop(later));
    try t.expectEqual(std.math.maxInt(i64), o.due(later));
}

test "presença: no máximo 5 a cada 20 s, sem segurar o resto" {
    var o: Outbox = .{};
    var now: i64 = 0;
    for (0..presence_limit) |_| {
        _ = o.push(.presence);
        try t.expectEqual(Item.presence, o.pop(now).?);
        now += 100;
    }
    _ = o.push(.presence);
    _ = o.push(.{ .lazy = .{ .guild = 3, .channel = 30 } });
    // A sexta presença espera; a lista de membros não.
    try t.expectEqual(@as(Id, 30), o.pop(now).?.lazy.channel);
    try t.expectEqual(@as(?Item, null), o.pop(now));
    try t.expectEqual(presence_window_ms, o.due(now));
    try t.expectEqual(Item.presence, o.pop(presence_window_ms).?);
}

test "op 4 nunca se perde: sai tudo, na ordem" {
    var o: Outbox = .{};
    for (0..normal_limit) |_| o.budget.note(0);
    for (0..40) |i| try t.expectEqual(Push.queued, o.push(.{ .voice = .{ .guild = 5, .channel = @intCast(i), .mute = i % 2 == 0 } }));
    try t.expectEqual(@as(?Item, null), o.pop(1));
    var got: usize = 0;
    while (o.pop(window_ms)) |it| : (got += 1) {
        try t.expectEqual(@as(?Id, got), it.voice.channel);
        try t.expectEqual(got % 2 == 0, it.voice.mute);
    }
    try t.expectEqual(@as(usize, 40), got);
}

test "op 4: fila cheia guarda o último estado no lugar do penúltimo" {
    var o: Outbox = .{};
    for (0..normal_limit) |_| o.budget.note(0);
    for (0..o.voice.len) |i| _ = o.push(.{ .voice = .{ .guild = 5, .channel = @intCast(i) } });
    try t.expectEqual(Push.merged, o.push(.{ .voice = .{ .guild = 5, .channel = null } }));
    try t.expectEqual(o.voice.len, o.pending());
    var last: ?Voice = null;
    while (o.pop(window_ms)) |it| last = it.voice;
    try t.expectEqual(@as(?Id, null), last.?.channel);
}

test "op 14 de muitos servidores: o mais antigo dá lugar" {
    var o: Outbox = .{};
    for (0..normal_limit) |_| o.budget.note(0);
    for (0..8) |i| _ = o.push(.{ .lazy = .{ .guild = @intCast(i + 1), .channel = 1 } });
    try t.expectEqual(Push.replaced_oldest, o.push(.{ .lazy = .{ .guild = 100, .channel = 1 } }));
    try t.expectEqual(@as(Id, 2), o.pop(window_ms).?.lazy.guild);
}

test "escrita que falha devolve o item: nada se perde e a ordem fica" {
    const Fake = struct {
        fail_at: usize,
        n: usize = 0,
        got: [16]Item = undefined,

        pub fn write(f: *@This(), it: Item) bool {
            if (f.n == f.fail_at) {
                f.fail_at = std.math.maxInt(usize);
                return false;
            }
            f.got[f.n] = it;
            f.n += 1;
            return true;
        }
    };
    var o: Outbox = .{};
    _ = o.push(.{ .voice = .{ .guild = 1, .channel = 10, .mute = true } });
    _ = o.push(.{ .voice = .{ .guild = 1, .channel = null } });
    _ = o.push(.presence);
    _ = o.push(.{ .lazy = .{ .guild = 7, .channel = 70 } });
    _ = o.push(.{ .lazy = .{ .guild = 8, .channel = 80 } });
    // A segunda escrita (sair da call) falha: o flush para e nada depois dela sai.
    var w: Fake = .{ .fail_at = 1 };
    o.drainTo(0, &w);
    try t.expectEqual(@as(usize, 1), w.n);
    try t.expectEqual(@as(?Id, 10), w.got[0].voice.channel);
    try t.expectEqual(@as(usize, 4), o.pending());
    // Depois do RESUME o resto sai na ordem de antes, começando pelo que falhou.
    o.newConnection();
    o.drainTo(1, &w);
    try t.expectEqual(@as(usize, 5), w.n);
    try t.expectEqual(@as(?Id, null), w.got[1].voice.channel);
    try t.expectEqual(Item.presence, w.got[2]);
    try t.expectEqual(@as(Id, 7), w.got[3].lazy.guild);
    try t.expectEqual(@as(Id, 8), w.got[4].lazy.guild);
    try t.expectEqual(@as(usize, 0), o.pending());
}

test "item devolvido: um pedido mais novo do mesmo servidor vence; voz volta para a frente" {
    var o: Outbox = .{};
    _ = o.push(.{ .lazy = .{ .guild = 1, .channel = 10 } });
    const old = o.pop(0).?;
    _ = o.push(.{ .lazy = .{ .guild = 1, .channel = 11 } });
    o.unpop(old);
    try t.expectEqual(@as(usize, 1), o.pending());
    try t.expectEqual(@as(Id, 11), o.pop(0).?.lazy.channel);
    // Voz com a fila dando a volta no anel: o devolvido sai antes dos que esperam.
    for (0..o.voice.len - 1) |_| {
        _ = o.push(.{ .voice = .{ .guild = 2, .channel = 1 } });
        _ = o.pop(0);
    }
    _ = o.push(.{ .voice = .{ .guild = 2, .channel = 20 } });
    _ = o.push(.{ .voice = .{ .guild = 2, .channel = 21 } });
    const v = o.pop(window_ms).?;
    o.unpop(v);
    try t.expectEqual(@as(?Id, 20), o.pop(window_ms).?.voice.channel);
    try t.expectEqual(@as(?Id, 21), o.pop(window_ms).?.voice.channel);
}

fn page(guild: Id, from: Id, n: u8) member_ask.Request {
    var r: member_ask.Request = .{ .guild = guild, .n = n };
    for (r.ids[0..n], 0..) |*u, i| u.* = from + i;
    return r;
}

const Sent = struct { at: i64, guild: Id, n: u8, first: Id };

test "op 8: no máximo um por servidor a cada 30 s, com páginas a cada 2 s se juntando" {
    var o: Outbox = .{};
    var sent: std.ArrayList(Sent) = .empty;
    defer sent.deinit(t.allocator);
    var total: usize = 0;
    var now: i64 = 0;
    // 40 páginas (80 s), cada uma com 3 autores novos no servidor 5.
    var k: usize = 0;
    while (k < 40) : (k += 1) {
        var r = page(5, 1000 + k * 3, 3);
        try t.expect(o.pushMembers(&r, now));
        total += 3;
        // Até a próxima página: o gateway acorda de 100 em 100 ms.
        var step: i64 = 0;
        while (step < 2000) : (step += 100) while (o.pop(now + step)) |it| {
            if (it == .members) try sent.append(t.allocator, .{ .at = now + step, .guild = it.members.guild, .n = it.members.n, .first = it.members.ids[0] });
        };
        now += 2000;
    }
    // O resto sai depois, cada um na sua janela.
    while (o.members_n > 0) : (now += 100) while (o.pop(now)) |it| {
        if (it == .members) try sent.append(t.allocator, .{ .at = now, .guild = it.members.guild, .n = it.members.n, .first = it.members.ids[0] });
    };
    // O primeiro espera o lote fechar; os outros, a janela inteira depois do anterior.
    try t.expectEqual(members_batch_ms, sent.items[0].at);
    var ids: usize = 0;
    for (sent.items, 0..) |x, i| {
        ids += x.n;
        if (i > 0) try t.expect(x.at - sent.items[i - 1].at >= members_window_ms);
    }
    // Ninguém se perdeu, e as páginas se juntaram (80 s pedem 3 ou 4 envios, não 40).
    try t.expectEqual(total, ids);
    try t.expect(sent.items.len <= 4);
}

test "op 8: dois servidores não esperam um pelo outro; mais de 100 fica para a janela seguinte" {
    var o: Outbox = .{};
    var a = page(5, 100, 70);
    var b = page(5, 200, 60);
    var c = page(6, 300, 2);
    try t.expect(o.pushMembers(&a, 0) and o.pushMembers(&b, 0) and o.pushMembers(&c, 0));
    try t.expect(o.pop(999) == null);
    // O lote fecha: um do 5 (com 100) e um do 6, nunca dois do 5 juntos.
    const one = o.pop(1000).?.members;
    const two = o.pop(1000).?.members;
    try t.expect(o.pop(1000) == null);
    try t.expectEqual(@as(Id, 5), one.guild);
    try t.expectEqual(@as(u8, 100), one.n);
    try t.expectEqual(@as(Id, 6), two.guild);
    // Os 30 que sobraram do 5 esperam a janela dele.
    try t.expectEqual(1000 + members_window_ms, o.due(1000));
    try t.expect(o.pop(1000 + members_window_ms - 1) == null);
    const rest = o.pop(1000 + members_window_ms).?.members;
    try t.expectEqual(@as(u8, 30), rest.n);
    try t.expectEqual(@as(Id, 230), rest.ids[0]);
}

test "op 8: RATE_LIMITED segura o servidor mesmo sem nonce e sem retry_after; sem servidor, segura todos" {
    var o: Outbox = .{};
    var a = page(5, 100, 2);
    var b = page(6, 200, 2);
    // Recusado sem dizer qual pedido nem quanto esperar: o 5 espera a janela inteira.
    try t.expect(o.holdMembers(0, 5, 0, null));
    try t.expect(o.pushMembers(&a, 0) and o.pushMembers(&b, 0));
    try t.expectEqual(@as(Id, 6), o.pop(1000).?.members.guild);
    try t.expect(o.pop(members_window_ms - 1) == null);
    try t.expectEqual(@as(Id, 5), o.pop(members_window_ms).?.members.guild);
    // O pedido recusado volta para a fila e espera o retry_after maior que a janela.
    var back = page(7, 300, 1);
    try t.expect(o.holdMembers(40_000, 7, 50_000, &back));
    try t.expect(o.pop(89_999) == null);
    try t.expectEqual(@as(Id, 7), o.pop(90_000).?.members.guild);
    // Sem o servidor (meta.guild_id não veio): nenhum op 8 até lá.
    var d = page(8, 400, 1);
    try t.expect(o.holdMembers(100_000, 0, 0, null));
    try t.expect(o.pushMembers(&d, 100_000));
    try t.expect(o.pop(100_000 + members_window_ms - 1) == null);
    try t.expectEqual(@as(Id, 8), o.pop(100_000 + members_window_ms).?.members.guild);
}

test "op 8: sair e voltar ao servidor não encurta a espera; fila cheia devolve o que não entrou" {
    var o: Outbox = .{};
    var a = page(5, 100, 2);
    try t.expect(o.pushMembers(&a, 0));
    try t.expectEqual(@as(Id, 5), o.pop(members_batch_ms).?.members.guild);
    // Saímos com um pedido esperando: ele sai da fila, a espera do servidor fica.
    var b = page(5, 200, 2);
    try t.expect(o.pushMembers(&b, 2000));
    o.forgetMembers(5);
    try t.expectEqual(@as(usize, 0), o.members_n);
    // Voltamos logo: o pedido novo espera a janela do que já saiu.
    var again = page(5, 300, 2);
    try t.expect(o.pushMembers(&again, 4000));
    try t.expect(o.pop(members_batch_ms + members_window_ms - 1) == null);
    try t.expectEqual(@as(Id, 5), o.pop(members_batch_ms + members_window_ms).?.members.guild);
    // No máximo dois por servidor na fila (o que espera e o que passou dos 100).
    var x = page(6, 1000, 100);
    var y = page(6, 2000, 100);
    var z = page(6, 3000, 5);
    try t.expect(o.pushMembers(&x, 0) and o.pushMembers(&y, 0));
    try t.expect(!o.pushMembers(&z, 0));
    try t.expectEqual(@as(u8, 5), z.n);
    // 16 esperando: o próximo não entra e fica inteiro em `r`.
    var g: Id = 10;
    while (o.members_n < o.members.len) : (g += 1) {
        var r = page(g, 1, 1);
        try t.expect(o.pushMembers(&r, 0));
    }
    var late = page(99, 7, 3);
    try t.expect(!o.pushMembers(&late, 0));
    try t.expectEqual(@as(u8, 3), late.n);
    // Sessão nova: o op 8 sai da fila (quem chama devolve as pessoas ao Asker).
    o.forgetPending();
    try t.expectEqual(@as(usize, 0), o.members_n);
}

test "op 8: muitas esperas ao mesmo tempo: nenhuma é despejada antes de vencer" {
    var o: Outbox = .{};
    // O servidor 1 manda o dele e ainda tem 50 esperando a janela.
    var first = page(1, 1000, 100);
    var rest = page(1, 2000, 50);
    try t.expect(o.pushMembers(&first, 0) and o.pushMembers(&rest, 0));
    try t.expectEqual(@as(Id, 1), o.pop(members_batch_ms).?.members.guild);
    // Mais 40 servidores, um op 8 cada, dentro da mesma janela.
    var g: Id = 100;
    var now: i64 = members_batch_ms;
    while (g < 140) : (g += 1) {
        var r = page(g, 1, 1);
        try t.expect(o.pushMembers(&r, now));
        now += 100;
        while (o.pop(now + members_batch_ms)) |it| try t.expect(it.members.guild != 1);
    }
    // Os 50 do servidor 1 continuam esperando a janela dele, nem um ms antes.
    try t.expect(o.pop(members_batch_ms + members_window_ms - 1) == null);
    try t.expectEqual(@as(Id, 1), o.pop(members_batch_ms + members_window_ms).?.members.guild);
    // Todas as vagas de espera ocupadas por esperas que não venceram: um servidor novo
    // espera uma vencer em vez de tomar o lugar dela.
    var full: Outbox = .{};
    for (0..full.holds.len) |i| full.hold(@as(Id, 500 + i), 50_000, 0);
    var newcomer = page(7, 1, 1);
    try t.expect(full.pushMembers(&newcomer, 0));
    try t.expect(full.pop(49_999) == null);
    try t.expectEqual(@as(Id, 7), full.pop(50_000).?.members.guild);
}

test "op 8: depois de tudo e no teto; o op 43 sai antes" {
    var o: Outbox = .{};
    var a = page(5, 11, 1);
    var b = page(5, 12, 1);
    try t.expect(o.pushMembers(&a, 0) and o.pushMembers(&b, 0));
    _ = o.push(.{ .channel_info = 9 });
    try t.expect(o.pop(members_batch_ms).? == .channel_info);
    try t.expectEqualSlices(Id, &.{ 11, 12 }, o.pop(members_batch_ms).?.members.slice());
    try t.expectEqual(@as(usize, 2), o.budget.used(members_batch_ms));
}

test "op 43: um por servidor, depois do resto, e volta para a frente se não saiu" {
    var o: Outbox = .{};
    for (0..normal_limit) |_| o.budget.note(0);
    try t.expectEqual(Push.queued, o.push(.{ .channel_info = 1 }));
    try t.expectEqual(Push.coalesced, o.push(.{ .channel_info = 1 }));
    try t.expectEqual(Push.queued, o.push(.{ .channel_info = 2 }));
    _ = o.push(.{ .lazy = .{ .guild = 1, .channel = 10 } });
    try t.expectEqual(@as(usize, 3), o.pending());
    // Teto cheio: espera a janela, como os outros.
    try t.expectEqual(@as(?Item, null), o.pop(1));
    try t.expectEqual(window_ms, o.due(1));
    try t.expectEqual(@as(Id, 1), o.pop(window_ms).?.lazy.guild);
    const first = o.pop(window_ms).?;
    try t.expectEqual(@as(Id, 1), first.channel_info);
    // A escrita falhou: volta para a frente, sem duplicar.
    o.unpop(first);
    o.unpop(first);
    try t.expectEqual(@as(usize, 2), o.pending());
    try t.expectEqual(@as(Id, 1), o.pop(window_ms).?.channel_info);
    try t.expectEqual(@as(Id, 2), o.pop(window_ms).?.channel_info);
    try t.expectEqual(@as(?Item, null), o.pop(window_ms));
    // Muitos servidores: o mais antigo dá lugar; sessão nova esquece.
    for (0..9) |i| _ = o.push(.{ .channel_info = @intCast(100 + i) });
    try t.expectEqual(o.info.len, o.info_n);
    try t.expectEqual(@as(Id, 101), o.info[0]);
    o.forgetPending();
    try t.expectEqual(@as(usize, 0), o.pending());
}

test "o VOICE_STATE_UPDATE da conta confirma o op 4" {
    const join: Voice = .{ .guild = 1, .channel = 5, .mute = true };
    try t.expect(join.confirmedBy(5, true, false));
    try t.expect(!join.confirmedBy(5, false, false));
    try t.expect(!join.confirmedBy(6, true, false));
    try t.expect(!join.confirmedBy(null, true, false));
    const leave: Voice = .{ .guild = 1, .channel = null };
    try t.expect(leave.confirmedBy(null, true, true));
    try t.expect(!leave.confirmedBy(5, false, false));
}

test "conexão nova zera os limites e mantém a fila" {
    var o: Outbox = .{};
    for (0..normal_limit) |_| o.budget.note(0);
    _ = o.push(.{ .voice = .{ .guild = 1, .channel = 2 } });
    try t.expectEqual(@as(?Item, null), o.pop(5));
    o.newConnection();
    try t.expectEqual(@as(?Id, 2), o.pop(5).?.voice.channel);
    _ = o.push(.presence);
    _ = o.push(.{ .lazy = .{ .guild = 1, .channel = 2 } });
    o.forgetPending();
    try t.expectEqual(@as(usize, 0), o.pending());
    try t.expectEqual(@as(usize, 1), o.budget.used(5));
    o.clear();
    try t.expectEqual(@as(usize, 0), o.pending());
}
