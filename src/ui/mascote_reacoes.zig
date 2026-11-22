//! As contas das brincadeiras do mascote do canto (ui/mascote_pet.zig), sem nada de
//! janela: o que a caixa de mensagem mostra (tudo em maiúsculas, spoiler, bloco de
//! código, mensagem longa e o quanto falta para o limite, "@", "#" e "/" no começo), os
//! segredos ("miau", "sudo", "rm -rf", ">_"), a sequência de apagar, o d20 do envio, a
//! vez do esconde-esconde e o Esc que não tinha mais nada para fechar. Tudo olha só o
//! texto aqui no computador; nada sai daqui. Separado para os testes rodarem sem o ImGui.
const std = @import("std");
const contas = @import("mascote_contas.zig");

// --- A caixa de mensagem ----------------------------------------------------------

/// A partir de quantos caracteres a mensagem é longa (ele pega o pergaminho).
pub const long_chars: u32 = 300;
/// Daqui para cima do limite ele se afasta preocupado.
pub const full_at: f32 = 0.9;
/// Quantas maiúsculas para ser "tudo em maiúsculas" ("OK", "LOL" e "GG" não bastam).
pub const caps_min: u32 = 5;

/// Para onde ele aponta: a lista de membros (um "@" sendo escrito) ou a de canais ("#").
pub const Point = enum { none, members, channels };

/// O que a caixa mostra agora.
pub const Box = struct {
    caps: bool = false,
    spoiler: bool = false,
    code: bool = false,
    slash: bool = false,
    point: Point = .none,
    /// Caracteres (pontos de código, como o Discord conta).
    chars: u32 = 0,
    /// Quanto do limite já foi (0..1): o do Discord, em caracteres, ou o da caixa, em
    /// bytes, o que estiver mais perto.
    fill: f32 = 0,
    /// O pergaminho desenrolado: 0 = começando a ser longa, 1 = perto do limite.
    unroll: f32 = 0,

    pub fn long(b: Box) bool {
        return b.chars >= long_chars;
    }
    pub fn full(b: Box) bool {
        return b.fill >= full_at;
    }
};

/// O limite do Discord para uma mensagem: 4000 caracteres com o Nitro (e o Nitro Classic
/// de antes), 2000 sem ele ou com o Nitro Basic.
pub fn limitFor(premium: u8) u32 {
    return if (premium == 1 or premium == 2) 4000 else 2000;
}

/// Lê a caixa. `limit`: o do Discord (`limitFor`); `cap`: quantos bytes cabem na caixa.
pub fn readBox(text: []const u8, limit: u32, cap: usize) Box {
    var b: Box = .{};
    if (text.len == 0) return b;
    var buf: [4096]u8 = undefined;
    const pl = plain(text, &buf);
    b.code = pl.code;
    b.chars = countChars(text);
    const by_chars = @as(f32, @floatFromInt(b.chars)) / @as(f32, @floatFromInt(@max(limit, 1)));
    const by_bytes = @as(f32, @floatFromInt(text.len)) / @as(f32, @floatFromInt(@max(cap, 1)));
    b.fill = @max(by_chars, by_bytes);
    const start = @as(f32, @floatFromInt(long_chars)) / @as(f32, @floatFromInt(@max(limit, 1)));
    if (b.long()) b.unroll = std.math.clamp((b.fill - start) / @max(full_at - start, 0.01), 0, 1);
    b.caps = isCaps(pl.text);
    b.spoiler = hasSpoiler(pl.text);
    b.slash = text[0] == '/' and (text.len == 1 or text[1] != '/');
    b.point = pointOf(pl.text);
    return b;
}

/// A pose que a caixa pede (uma de cada vez; a primeira que valer, nesta ordem).
pub const Pose = enum { none, full, spoiler, code, caps, slash, members, channels, long };

pub fn poseFor(b: Box) Pose {
    if (b.full()) return .full;
    if (b.spoiler) return .spoiler;
    if (b.code) return .code;
    if (b.caps) return .caps;
    if (b.slash) return .slash;
    return switch (b.point) {
        .members => .members,
        .channels => .channels,
        .none => if (b.long()) .long else .none,
    };
}

/// O texto sem o que é código (``` bloco ``` e `linha`), que vira um espaço: as
/// maiúsculas, o spoiler e o "@"/"#" não olham dentro de código. `code`: tem um
/// bloco ``` (aberto já conta: ele está escrevendo um).
fn plain(text: []const u8, out: []u8) struct { text: []const u8, code: bool } {
    var n: usize = 0;
    var i: usize = 0;
    var code = false;
    while (i < text.len and n < out.len) {
        if (std.mem.startsWith(u8, text[i..], "```")) {
            code = true;
            i = if (std.mem.indexOfPos(u8, text, i + 3, "```")) |cl| cl + 3 else text.len;
            out[n] = ' ';
            n += 1;
            continue;
        }
        if (text[i] == '`') if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |cl| {
            i = cl + 1;
            out[n] = ' ';
            n += 1;
            continue;
        };
        // Um "`" sozinho é texto mesmo.
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return .{ .text = out[0..n], .code = code };
}

/// Pontos de código, tolerando um pedaço quebrado no fim (a caixa cheia corta no byte).
fn countChars(text: []const u8) u32 {
    var n: u32 = 0;
    for (text) |ch| {
        if (ch & 0xC0 != 0x80) n += 1;
    }
    return n;
}

const Case = enum { none, upper, lower };

/// Maiúscula, minúscula ou nada: o ASCII, o latim com acento (português, espanhol…), o
/// cirílico e o grego. Japonês, chinês e coreano não têm caixa: nunca contam.
fn caseOf(cp: u21) Case {
    return switch (cp) {
        'A'...'Z' => .upper,
        'a'...'z' => .lower,
        0xC0...0xD6, 0xD8...0xDE => .upper,
        0xDF...0xF6, 0xF8...0xFF => .lower,
        // Latim estendido A: pares maiúscula/minúscula.
        0x100...0x137, 0x14A...0x177 => if (cp % 2 == 0) .upper else .lower,
        0x391...0x3A9 => .upper,
        0x3B1...0x3C9 => .lower,
        0x400...0x42F => .upper,
        0x430...0x45F => .lower,
        else => .none,
    };
}

/// Tudo em maiúsculas: pelo menos `caps_min` maiúsculas e quase nenhuma minúscula. Links,
/// menções, canais e os ":nomes:" de emoji ficam de fora (":KEKW:" não é gritar).
fn isCaps(t: []const u8) bool {
    var upper: u32 = 0;
    var lower: u32 = 0;
    var it = std.mem.tokenizeAny(u8, t, " \t\r\n");
    while (it.next()) |w| {
        if (std.mem.indexOf(u8, w, "://") != null) continue;
        if (w[0] == '<' or w[0] == '@' or w[0] == '#') continue;
        if (w.len > 2 and w[0] == ':' and w[w.len - 1] == ':') continue;
        var i: usize = 0;
        while (i < w.len) {
            const len = std.unicode.utf8ByteSequenceLength(w[i]) catch 1;
            const cp: u21 = if (i + len <= w.len) std.unicode.utf8Decode(w[i .. i + len]) catch 0 else 0;
            i += if (i + len <= w.len) len else 1;
            switch (caseOf(cp)) {
                .upper => upper += 1,
                .lower => lower += 1,
                .none => {},
            }
        }
    }
    return upper >= caps_min and upper >= lower * 3;
}

/// Um "||" com alguma coisa dentro: fechado, ou ainda sendo escrito (aí colado no "||",
/// porque "a || b" numa frase é "ou", não spoiler).
fn hasSpoiler(t: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t, i, "||")) |open| {
        const from = open + 2;
        const close = std.mem.indexOfPos(u8, t, from, "||") orelse
            return from < t.len and !std.ascii.isWhitespace(t[from]);
        if (std.mem.trim(u8, t[from..close], " \t\r\n").len > 0) return true;
        i = close + 2;
    }
    return false;
}

/// A palavra sendo escrita (a última, sem espaço depois) começa com "@" ou "#".
fn pointOf(t: []const u8) Point {
    if (t.len == 0 or std.ascii.isWhitespace(t[t.len - 1])) return .none;
    var i = t.len;
    while (i > 0 and !std.ascii.isWhitespace(t[i - 1])) i -= 1;
    return switch (t[i]) {
        '@' => .members,
        '#' => .channels,
        else => .none,
    };
}

// --- Os segredos -------------------------------------------------------------------

/// Os segredos da caixa, cada um com a sua reação (uma vez, até sair da caixa e voltar).
/// A ordem é a de quem ganha quando aparecem dois juntos.
pub const Egg = enum(u3) { rm, sudo, meow, prompt, name };

fn eggBit(e: Egg) u8 {
    return @as(u8, 1) << @backingInt(e);
}

/// Quais segredos estão na caixa agora (um bit por `Egg`).
pub fn eggsIn(text: []const u8) u8 {
    const t = text[0..@min(text.len, 4000)];
    var m: u8 = 0;
    if (contas.has(t, "rm -rf")) m |= eggBit(.rm);
    if (contas.hasWord(t, "sudo")) m |= eggBit(.sudo);
    if (contas.has(t, "miau") or contas.has(t, "meow") or std.mem.indexOf(u8, t, "мяу") != null or
        std.mem.indexOf(u8, t, "Мяу") != null or std.mem.indexOf(u8, t, "МЯУ") != null or std.mem.indexOf(u8, t, "にゃ") != null) m |= eggBit(.meow);
    if (std.mem.indexOf(u8, t, ">_") != null) m |= eggBit(.prompt);
    return m;
}

/// Os segredos e mais o nome do mascote (Personalizar → Nome), como palavra inteira e
/// sem diferença de maiúsculas: "Bob" chama, "Bobagem" não.
pub fn eggsWithName(text: []const u8, name: []const u8) u8 {
    return eggsIn(text) | (if (nameIn(text[0..@min(text.len, 4000)], name)) eggBit(.name) else 0);
}

fn nameIn(text: []const u8, name: []const u8) bool {
    const n = std.mem.trim(u8, name, " ");
    if (n.len < 2 or n.len > text.len) return false;
    var i: usize = 0;
    while (i + n.len <= text.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(text[i .. i + n.len], n)) continue;
        const before_ok = i == 0 or !wordByte(text[i - 1]);
        const after_ok = i + n.len == text.len or !wordByte(text[i + n.len]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

/// Letra, número, "_" ou parte de um caractere não ASCII: continua a palavra.
fn wordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

/// O segredo que acabou de aparecer (estava fora em `before` e está em `now`).
pub fn newEgg(before: u8, now: u8) ?Egg {
    const fresh = now & ~before;
    inline for (@typeInfo(Egg).@"enum".field_names) |name| {
        const e = @field(Egg, name);
        if (fresh & eggBit(e) != 0) return e;
    }
    return null;
}

// --- Apagar muito ------------------------------------------------------------------

/// Quantas apagadas seguidas até ele oferecer um chá (ou dar tapinhas no braço).
pub const erase_streak: u16 = 12;
/// Mais que isto entre duas apagadas e a sequência recomeça.
pub const erase_gap_ms: i64 = 900;
/// Depois do chá, um tempo sem oferecer de novo.
pub const erase_cool_ms: i64 = 45_000;

/// A sequência de apagar: cada quadro em que o texto encolheu é uma apagada (uma tecla
/// ou uma palavra inteira com Ctrl); escrever qualquer coisa recomeça.
pub const Erase = struct {
    n: u16 = 0,
    last_ms: i64 = -100_000,
    cool_until: i64 = -100_000,
    prev_len: usize = 0,

    /// O texto tem `len` bytes agora: true quando a sequência chega a `erase_streak`.
    pub fn feed(e: *Erase, len: usize, now: i64) bool {
        defer e.prev_len = len;
        if (len > e.prev_len) {
            e.n = 0;
            return false;
        }
        if (len == e.prev_len) return false;
        if (now - e.last_ms > erase_gap_ms) e.n = 0;
        e.n += 1;
        e.last_ms = now;
        if (e.n < erase_streak or now < e.cool_until) return false;
        e.n = 0;
        e.cool_until = now + erase_cool_ms;
        return true;
    }

    /// A caixa esvaziou por outro motivo (a mensagem foi enviada): não é apagar.
    pub fn reset(e: *Erase, len: usize) void {
        e.n = 0;
        e.prev_len = len;
    }
};

// --- O d20 do envio ------------------------------------------------------------------

/// Uma vez em quantas mensagens enviadas ele rola o dado.
pub const d20_odds: u32 = 50;

/// O dado deste envio, a partir de um número sorteado: 0 = não rolou; 1..20 = a face.
pub fn d20(roll: u32) u8 {
    if (roll % d20_odds != 0) return 0;
    return @intCast(1 + (roll / d20_odds) % 20);
}

// --- Esconde-esconde ---------------------------------------------------------------

/// Parado há pelo menos isto antes de se esconder.
pub const seek_idle_ms: i64 = 20_000;
/// Ninguém achou: ele volta sozinho depois disto.
pub const seek_hide_ms: i64 = 30_000;

/// O intervalo mínimo entre duas brincadeiras de esconde-esconde (agitada: mais vezes).
pub fn seekGap(life: u8) i64 {
    return if (life >= 3) 4 * 60_000 else 8 * 60_000;
}

/// Na hora de fazer alguma coisa sozinho, ele se esconde? Só com a vida própria normal ou
/// agitada, parado há um tempo, longe da última vez e nem sempre (`roll` sorteado).
pub fn seekReady(life: u8, idle_ms: i64, since_ms: i64, roll: u32) bool {
    if (life < 2) return false;
    if (idle_ms < seek_idle_ms or since_ms < seekGap(life)) return false;
    return roll % 4 == 0;
}

/// Escondido há tanto tempo: volta sozinho.
pub fn seekOver(hidden_ms: i64) bool {
    return hidden_ms >= seek_hide_ms;
}

// --- Esc ---------------------------------------------------------------------------

/// Um Esc sem nada para fechar só faz ele se esconder de novo depois disto.
pub const esc_gap_ms: i64 = 20_000;

/// O Esc faz ele se esconder? Só quando não tinha nada para fechar (menu, paleta,
/// resposta, edição, imagem aberta, a lista do autocompletar…: `free`, do quadro de
/// antes) e longe do último esconderijo; o Esc é apertado toda hora.
pub fn escHides(free: bool, since_ms: i64) bool {
    return free and since_ms >= esc_gap_ms;
}

// --- Testes ------------------------------------------------------------------------

const tt = std.testing;

fn box(text: []const u8) Box {
    return readBox(text, 2000, 1999);
}

test "tudo em maiúsculas: algumas letras, não só \"OK\"" {
    try tt.expect(box("PARA DE GRITAR").caps);
    try tt.expect(box("HELLO").caps);
    try tt.expect(!box("OK").caps);
    try tt.expect(!box("LOL").caps);
    try tt.expect(!box("oi tudo bem").caps);
    try tt.expect(!box("I use JSON").caps);
    try tt.expect(box("WHAT THE HELL man").caps);
    // Com acento e em russo também; japonês não tem maiúscula.
    try tt.expect(box("NÃO ACREDITO").caps);
    try tt.expect(box("ПРИВЕТ ВСЕМ").caps);
    try tt.expect(!box("привет всем").caps);
    try tt.expect(!box("こんにちは").caps);
    // Link, menção, canal, emoji e código não contam.
    try tt.expect(!box("https://EXAMPLE.COM/ABCDEF").caps);
    try tt.expect(!box(":KEKW: :POGGERS:").caps);
    try tt.expect(!box("olha `SELECT FROM TABLE` aqui").caps);
    try tt.expect(!box("@EVERYONE #GERAL").caps);
}

test "spoiler: fechado, ainda sendo escrito, e não dentro de código" {
    try tt.expect(box("o ||assassino|| é o mordomo").spoiler);
    try tt.expect(box("||ainda escrevendo").spoiler);
    try tt.expect(!box("|| ||").spoiler);
    try tt.expect(!box("a || b").spoiler);
    try tt.expect(!box("`a || b`").spoiler);
    try tt.expect(!box("```zig\nif (a || b) {}\n```").spoiler);
    try tt.expect(box("|| || depois ||isto||").spoiler);
}

test "bloco de código: aberto já conta; código de uma linha não" {
    try tt.expect(box("```").code);
    try tt.expect(box("```zig\nconst x = 1;\n```").code);
    try tt.expect(!box("um `trecho` só").code);
    try tt.expect(poseFor(box("```\nSELECT * FROM X\n```")) == .code);
}

test "mensagem longa: o pergaminho desenrola até o limite, que depende do Nitro" {
    var big: [1999]u8 = @splat('a');
    try tt.expect(!box(big[0..299]).long());
    const at300 = box(big[0..300]);
    try tt.expect(at300.long() and at300.unroll < 0.01 and poseFor(at300) == .long);
    const mid = box(big[0..1000]);
    try tt.expect(mid.unroll > 0.3 and mid.unroll < 0.7 and !mid.full());
    // Sem Nitro: 2000 caracteres. Perto dele, preocupado.
    try tt.expect(box(big[0..1850]).full());
    try tt.expect(poseFor(box(big[0..1850])) == .full);
    // Com Nitro o Discord deixa 4000, mas a caixa só tem 1999 bytes: vale o que vier antes.
    try tt.expectEqual(@as(u32, 4000), limitFor(2));
    try tt.expectEqual(@as(u32, 2000), limitFor(0));
    try tt.expectEqual(@as(u32, 2000), limitFor(3));
    try tt.expect(readBox(big[0..1850], 4000, 1999).full());
    try tt.expect(!readBox(big[0..1700], 4000, 8000).full());
    // Bytes de emoji (4 cada) enchem a caixa antes dos caracteres.
    var emoji: [1800]u8 = undefined;
    for (0..450) |i| @memcpy(emoji[i * 4 ..][0..4], "😀");
    const e = box(&emoji);
    try tt.expectEqual(@as(u32, 450), e.chars);
    try tt.expect(e.full());
}

test "\"@\" e \"#\" sendo escritos apontam; \"/\" no começo abre o terminal" {
    try tt.expectEqual(Point.members, box("fala @").point);
    try tt.expectEqual(Point.members, box("fala @jo").point);
    try tt.expectEqual(Point.none, box("fala @joão ").point);
    try tt.expectEqual(Point.channels, box("vai no #ger").point);
    try tt.expectEqual(Point.none, box("me@exemplo.com").point);
    try tt.expectEqual(Pose.members, poseFor(box("@")));
    try tt.expectEqual(Pose.channels, poseFor(box("#")));
    try tt.expect(box("/giphy gatos").slash);
    try tt.expect(!box("//comentário").slash);
    try tt.expect(!box("a/b").slash);
    try tt.expectEqual(Pose.slash, poseFor(box("/shrug")));
    try tt.expectEqual(Pose.none, poseFor(box("")));
    try tt.expectEqual(Pose.none, poseFor(box("tudo certo por aí?")));
}

test "a ordem das poses: o limite, o spoiler, o código, as maiúsculas" {
    try tt.expectEqual(Pose.spoiler, poseFor(box("||NÃO CONTA PARA NINGUÉM||")));
    try tt.expectEqual(Pose.caps, poseFor(box("/GRITANDO MUITO")));
    try tt.expectEqual(Pose.spoiler, poseFor(box("```\nfoo\n``` ||x||")));
    try tt.expectEqual(Pose.code, poseFor(box("```\nPARA DE GRITAR\n```")));
    try tt.expectEqual(Pose.code, poseFor(box("```py\nCONST = 1\n``` E AGORA")));
}

test "o nome do mascote chama ele, como palavra inteira" {
    try tt.expectEqual(@as(?Egg, .name), newEgg(0, eggsWithName("oi bob, tudo bem?", "Bob")));
    try tt.expectEqual(@as(?Egg, .name), newEgg(0, eggsWithName("BOB", "Bob")));
    try tt.expectEqual(@as(?Egg, null), newEgg(0, eggsWithName("que bobagem", "Bob")));
    try tt.expectEqual(@as(?Egg, null), newEgg(0, eggsWithName("bob", "")));
    try tt.expectEqual(@as(?Egg, null), newEgg(0, eggsWithName("x", "x")));
    try tt.expectEqual(@as(?Egg, .name), newEgg(0, eggsWithName("olá Pixel Gato!", "Pixel Gato")));
    // Junto com outro segredo, o outro ganha (o nome é o último).
    try tt.expectEqual(@as(?Egg, .meow), newEgg(0, eggsWithName("miau bob", "bob")));
}

test "os segredos: cada um uma vez, até sair da caixa" {
    try tt.expectEqual(@as(?Egg, null), newEgg(0, eggsIn("mia")));
    const m1 = eggsIn("miau");
    try tt.expectEqual(@as(?Egg, .meow), newEgg(0, m1));
    try tt.expectEqual(@as(?Egg, null), newEgg(m1, eggsIn("miau miau")));
    try tt.expectEqual(@as(?Egg, .meow), newEgg(eggsIn(""), eggsIn("MEOW")));
    try tt.expectEqual(@as(?Egg, .meow), newEgg(0, eggsIn("мяу")));
    try tt.expectEqual(@as(?Egg, .meow), newEgg(0, eggsIn("にゃーん")));
    try tt.expectEqual(@as(?Egg, .sudo), newEgg(0, eggsIn("sudo apt install")));
    try tt.expectEqual(@as(?Egg, null), newEgg(0, eggsIn("pseudocódigo")));
    try tt.expectEqual(@as(?Egg, .prompt), newEgg(0, eggsIn("olha ele >_")));
    // "sudo rm -rf /": o rm ganha, e o sudo que já estava não repete.
    try tt.expectEqual(@as(?Egg, .rm), newEgg(0, eggsIn("sudo rm -rf /")));
    try tt.expectEqual(@as(?Egg, .rm), newEgg(eggsIn("sudo "), eggsIn("sudo rm -rf /")));
}

test "apagar muito: doze seguidas oferecem o chá, e escrever recomeça" {
    var e: Erase = .{ .prev_len = 40 };
    var len: usize = 40;
    var now: i64 = 1000;
    for (0..11) |_| {
        len -= 1;
        now += 80;
        try tt.expect(!e.feed(len, now));
    }
    // Escreveu uma letra: recomeça.
    len += 1;
    try tt.expect(!e.feed(len, now + 10));
    for (0..11) |_| {
        len -= 1;
        now += 80;
        try tt.expect(!e.feed(len, now));
    }
    len -= 1;
    try tt.expect(e.feed(len, now + 80));
    // Logo depois, outra sequência não oferece de novo.
    var e2 = e;
    var l2: usize = 200;
    e2.reset(l2);
    var n2 = now + 1000;
    var got = false;
    for (0..30) |_| {
        l2 -= 1;
        n2 += 50;
        got = got or e2.feed(l2, n2);
    }
    try tt.expect(!got);
    // Devagar demais (mais de `erase_gap_ms` entre uma e outra) não é sequência.
    var slow: Erase = .{ .prev_len = 100 };
    var sl: usize = 100;
    var sn: i64 = 0;
    for (0..20) |_| {
        sl -= 1;
        sn += erase_gap_ms + 1;
        try tt.expect(!slow.feed(sl, sn));
    }
}

test "d20: uma vez em 50 envios, as vinte faces por igual" {
    var rolls: u32 = 0;
    var faces: [21]u32 = @splat(0);
    var r: u32 = 0;
    while (r < 100_000) : (r += 1) {
        const f = d20(r);
        if (f == 0) continue;
        rolls += 1;
        try tt.expect(f >= 1 and f <= 20);
        faces[f] += 1;
    }
    try tt.expectEqual(@as(u32, 2000), rolls);
    for (faces[1..]) |n| try tt.expectEqual(@as(u32, 100), n);
    try tt.expectEqual(@as(u8, 0), d20(1));
}

test "esconde-esconde: raro, só parado e com a vida própria animada, e volta sozinho" {
    const long_ago: i64 = 60 * 60_000;
    try tt.expect(seekReady(2, 30_000, long_ago, 0));
    try tt.expect(seekReady(3, 30_000, long_ago, 4));
    try tt.expect(!seekReady(2, 30_000, long_ago, 1));
    try tt.expect(!seekReady(1, 30_000, long_ago, 0));
    try tt.expect(!seekReady(0, 30_000, long_ago, 0));
    try tt.expect(!seekReady(2, 5_000, long_ago, 0));
    try tt.expect(!seekReady(2, 30_000, 5 * 60_000, 0));
    try tt.expect(seekReady(3, 30_000, 5 * 60_000, 0));
    try tt.expect(!seekOver(seek_hide_ms - 1));
    try tt.expect(seekOver(seek_hide_ms));
}

test "Esc: só sem nada para fechar, e não toda hora" {
    try tt.expect(escHides(true, esc_gap_ms));
    try tt.expect(!escHides(false, esc_gap_ms * 10));
    try tt.expect(!escHides(true, esc_gap_ms - 1));
}
