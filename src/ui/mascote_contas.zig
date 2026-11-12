//! As contas do mascote (ui/mascote_terminal.zig), sem nada de janela: as curvas
//! de tempo, a mola, o sorteio estável e a transformação afim. Separado para os
//! testes rodarem sem o ImGui.
const std = @import("std");

/// Qual mascote o app usa (o byte das Configurações).
pub const Kind = enum(u8) {
    terminal = 0,
    classico = 1,

    /// O byte das configurações (um número de fora vira o principal).
    pub fn of(v: u8) Kind {
        return if (v == 1) .classico else .terminal;
    }
};

/// As aberturas do Terminal: o boot de terminal (a primeira) e as outras quatro.
pub const Opening = enum(u8) {
    boot = 0,
    codigo = 1,
    tv = 2,
    pixels = 3,
    portal = 4,

    pub const count = 5;

    /// O byte das configurações; o que passar do fim vira o boot.
    pub fn of(v: u8) Opening {
        return if (v < count) @fromBackingInt(@intCast(v)) else .boot;
    }
};

/// Quando cada abertura termina e o mascote fica inteiro (depois disso, o parado).
pub fn openingEnd(o: Opening) f32 {
    return switch (o) {
        .boot => 2.6,
        .codigo => 2.0,
        .tv => 1.9,
        .pixels => 2.05,
        .portal => 1.95,
    };
}

/// Quanto o demo e a prévia esperam por abertura (até a gota do boot cair).
pub fn openingSeconds(o: Opening) f32 {
    return if (o == .boot) 3.4 else openingEnd(o) + 0.4;
}

/// A abertura desta vez: a escolhida, ou uma sorteada (o byte = `Opening.count`).
pub fn pickOpening(setting: u8, seed: u64) Opening {
    if (setting < Opening.count) return .of(setting);
    return .of(@intCast(seed % Opening.count));
}

/// As reações do mascote do canto (ui/mascote_pet.zig).
pub const Reaction = enum { none, hop, ping, laugh, gg, sad, wave, love, angry, wake, poke };

/// Algo em minúsculas (só ASCII) contém `needle`?
pub fn has(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(text[i + j]) != ch) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// "gg" como palavra (não o "gg" de "bigger").
pub fn hasWord(text: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t\n.,!?;:()[]\"'");
    while (it.next()) |w| if (w.len == word.len and has(w, word)) return true;
    return false;
}

/// A reação a uma mensagem que você mandou (só olha o texto aqui; nada sai daqui).
pub fn reactionFor(text: []const u8) Reaction {
    const t = text[0..@min(text.len, 400)];
    if (has(t, "kkk") or has(t, "haha") or has(t, "hehe") or has(t, "rsrs") or hasWord(t, "lol") or hasWord(t, "lmao") or hasWord(t, "kek")) return .laugh;
    if (hasWord(t, "gg") or hasWord(t, "ggwp") or hasWord(t, "ez") or has(t, "parabéns") or has(t, "parabens") or has(t, "congrats")) return .gg;
    if (has(t, ":(") or has(t, ":'(") or has(t, "t-t") or has(t, "triste") or hasWord(t, "sad") or has(t, "😢") or has(t, "😭")) return .sad;
    if (has(t, "<3") or has(t, "❤") or has(t, "te amo") or has(t, "love you") or has(t, "🥰")) return .love;
    if (has(t, "bom dia") or has(t, "boa tarde") or has(t, "boa noite") or hasWord(t, "oi") or hasWord(t, "olá") or hasWord(t, "ola") or hasWord(t, "salve") or hasWord(t, "eae") or hasWord(t, "hello") or hasWord(t, "hi") or hasWord(t, "hey") or hasWord(t, "tchau") or hasWord(t, "bye")) return .wave;
    return .hop;
}

pub fn seg(t: f32, a: f32, b: f32) f32 {
    return std.math.clamp((t - a) / (b - a), 0, 1);
}
pub fn outCubic(x: f32) f32 {
    const y = 1 - x;
    return 1 - y * y * y;
}
pub fn inCubic(x: f32) f32 {
    return x * x * x;
}
pub fn outExpo(x: f32) f32 {
    return if (x >= 1) 1 else 1 - std.math.pow(f32, 2, -10 * x);
}
pub fn outBack(x: f32, s: f32) f32 {
    const y = x - 1;
    return 1 + (s + 1) * y * y * y + s * y * y;
}
/// Mola: sobe de 0 a 1 passando um pouco e volta (`since` em segundos).
pub fn spring(since: f32, w: f32, z: f32) f32 {
    if (since <= 0) return 0;
    return 1 - @exp(-z * since) * @cos(w * since);
}
/// Pancada que some: 0 → pico → 0 em `len` segundos.
pub fn kick(since: f32, len: f32) f32 {
    if (since < 0 or since > len) return 0;
    const x = since / len;
    return @sin(std.math.pi * x) * (1 - x);
}
/// Número pseudoaleatório estável por índice (0..1).
pub fn hash(i: u32, salt: u32) f32 {
    var h: u32 = i *% 0x9E3779B1 +% salt *% 0x85EBCA77;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 65535.0;
}

/// Transformação afim: x' = a·x + c·y + e, y' = b·x + d·y + f. `V` é o tipo do
/// ponto na tela (o ImVec2 no app, um struct qualquer com x e y nos testes).
pub fn Affine(comptime V: type) type {
    return struct {
        const Af = @This();
        a: f32 = 1,
        b: f32 = 0,
        c: f32 = 0,
        d: f32 = 1,
        e: f32 = 0,
        f: f32 = 0,

        pub fn ap(m: Af, x: f32, y: f32) V {
            return .{ .x = m.a * x + m.c * y + m.e, .y = m.b * x + m.d * y + m.f };
        }
        /// `m` depois de `n` (n é aplicada primeiro).
        pub fn mul(m: Af, n: Af) Af {
            return .{
                .a = m.a * n.a + m.c * n.b,
                .b = m.b * n.a + m.d * n.b,
                .c = m.a * n.c + m.c * n.d,
                .d = m.b * n.c + m.d * n.d,
                .e = m.a * n.e + m.c * n.f + m.e,
                .f = m.b * n.e + m.d * n.f + m.f,
            };
        }
        pub fn move(x: f32, y: f32) Af {
            return .{ .e = x, .f = y };
        }
        pub fn scale(sx: f32, sy: f32) Af {
            return .{ .a = sx, .d = sy };
        }
        pub fn turn(r: f32) Af {
            return .{ .a = @cos(r), .b = @sin(r), .c = -@sin(r), .d = @cos(r) };
        }
        /// `inner` em volta do ponto (px, py) do SVG.
        pub fn around(m: Af, px: f32, py: f32, inner: Af) Af {
            return m.mul(move(px, py)).mul(inner).mul(move(-px, -py));
        }
        /// Escala média (para espessuras).
        pub fn k(m: Af) f32 {
            return @sqrt(@abs(m.a * m.d - m.b * m.c));
        }
    };
}

const P = struct { x: f32, y: f32 };
const Xf = Affine(P);

test "transformação: escala em volta de um ponto deixa o ponto parado, e a ordem conta" {
    const m = (Xf{}).around(10, 20, Xf.scale(3, 0.5));
    const fixed = m.ap(10, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 10), fixed.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 20), fixed.y, 1e-4);
    const q = m.ap(11, 22);
    try std.testing.expectApproxEqAbs(@as(f32, 13), q.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 21), q.y, 1e-4);
    // Mover e depois girar não é o mesmo que girar e depois mover.
    const a = Xf.move(5, 0).mul(Xf.turn(std.math.pi / 2.0)).ap(1, 0);
    const b = Xf.turn(std.math.pi / 2.0).mul(Xf.move(5, 0)).ap(1, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), a.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6), b.y, 1e-4);
}

test "a mola passa de 1 e assenta, e a pancada volta a zero" {
    try std.testing.expectEqual(@as(f32, 0), spring(0, 13, 6));
    var peak: f32 = 0;
    var t: f32 = 0;
    while (t < 0.6) : (t += 0.01) peak = @max(peak, spring(t, 13, 6));
    try std.testing.expect(peak > 1.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1), spring(2, 13, 6), 0.01);
    try std.testing.expectEqual(@as(f32, 0), kick(0.5, 0.3));
    try std.testing.expect(kick(0.1, 0.3) > 0);
}

test "o byte da configuração vira o mascote; o que não for 1 é o principal" {
    try std.testing.expectEqual(Kind.terminal, Kind.of(0));
    try std.testing.expectEqual(Kind.classico, Kind.of(1));
    try std.testing.expectEqual(Kind.terminal, Kind.of(7));
}

test "abertura: a escolhida vale; \"sortear\" passa pelas cinco; byte de fora vira o boot" {
    try std.testing.expectEqual(Opening.portal, pickOpening(4, 123));
    try std.testing.expectEqual(Opening.boot, Opening.of(200));
    var seen: [Opening.count]bool = @splat(false);
    var seed: u64 = 0;
    while (seed < 20) : (seed += 1) seen[@backingInt(pickOpening(Opening.count, seed))] = true;
    for (seen) |v| try std.testing.expect(v);
    // A espera do demo cobre a abertura inteira de cada uma.
    for (0..Opening.count) |i| {
        const o: Opening = @fromBackingInt(@intCast(i));
        try std.testing.expect(openingSeconds(o) >= openingEnd(o));
    }
}

test "a reação ao que você escreve" {
    try std.testing.expectEqual(Reaction.laugh, reactionFor("KKKKKKK que isso"));
    try std.testing.expectEqual(Reaction.laugh, reactionFor("lol"));
    try std.testing.expectEqual(Reaction.gg, reactionFor("gg wp"));
    try std.testing.expectEqual(Reaction.hop, reactionFor("bigger egg"));
    try std.testing.expectEqual(Reaction.sad, reactionFor("ficou triste :("));
    try std.testing.expectEqual(Reaction.wave, reactionFor("Bom dia galera"));
    try std.testing.expectEqual(Reaction.wave, reactionFor("oi"));
    try std.testing.expectEqual(Reaction.hop, reactionFor("oito horas"));
    try std.testing.expectEqual(Reaction.love, reactionFor("vcs <3"));
    try std.testing.expectEqual(Reaction.hop, reactionFor("bora jogar"));
}
