//! Índice da busca local: as palavras de cada mensagem que o app tem, para achar na hora,
//! a cada tecla, sem rede. Quem mantém (e guarda em disco) é net/busca_local.zig; quem
//! mostra é ui/search.zig. Aqui não há janela, rede nem arquivo: só memória.
//!
//! Cada mensagem vira um documento: ID, canal, autor, o que ela tem (link, imagem,
//! arquivo, vídeo, som) e o texto guardado (até `max_text` bytes, com os nomes dos
//! anexos). Cada palavra, já dobrada (minúsculas, sem acento: "Não" e "nao" são a mesma),
//! aponta para os documentos onde aparece, numa lista compacta: a distância até o
//! anterior em varint, 1 ou 2 bytes por entrada na maioria. Japonês e chinês não separam
//! palavras com espaço: ali cada ideograma ou kana é uma palavra, e a sequência digitada
//! confere no texto. `<@123>` vira uma palavra que não dá para digitar (o filtro
//! "menciona:" usa); o número dos emojis personalizados fica de fora.
//!
//! Editar ou apagar marca o documento como fora; `compact` refaz tudo sem os marcados
//! quando eles passam de um quarto (ou quando passa de `max_docs`: as mais antigas saem).
//!
//! Consulta: cada palavra vira um conjunto de documentos (bits), e os conjuntos se
//! cruzam; a última palavra, ainda sendo digitada, vale como começo de palavra ("hypr"
//! acha "hyprland"). Termos com pontuação ou mais de uma palavra ("http://x.y", "meio
//! termo") ainda conferem no texto dobrado. Filtros: autor, canal, menção, o que tem e
//! datas (o ID do Discord carrega a hora).
const std = @import("std");
const types = @import("types.zig");
const Id = types.Id;
const Allocator = std.mem.Allocator;

/// Texto guardado por mensagem (o Discord deixa 2000 sem Nitro). Só o guardado é
/// indexado: o que volta do disco é igual ao que entrou.
pub const max_text: usize = 2000;
/// Teto de mensagens: passou, as mais antigas saem na próxima compactação.
pub const max_docs: usize = 100_000;
/// Uma palavra mais longa que isso (um pedaço de link) fica com o começo.
const max_token: usize = 32;
/// Nomes dos anexos, depois do texto.
const max_files: usize = 256;
/// Separa o texto dos nomes dos anexos no que fica guardado.
pub const files_sep: u8 = 0x1f;
/// Começo das palavras de menção (`<@123>` vira "\x01123"): ninguém digita isso.
const mention_mark: u8 = 1;

pub const f_link: u8 = 1;
pub const f_image: u8 = 2;
pub const f_file: u8 = 4;
pub const f_video: u8 = 8;
pub const f_sound: u8 = 16;
const f_gone: u8 = 128;

/// Uma mensagem no índice (32 bytes).
pub const Doc = struct {
    id: Id,
    hash: u32,
    /// Índices em `Index.channels` e `Index.authors`.
    chan: u32,
    author: u32,
    text_off: u32,
    text_len: u16,
    flags: u8,

    /// Não foi editada nem apagada depois.
    pub fn alive(d: *const Doc) bool {
        return d.flags & f_gone == 0;
    }
};

const Author = struct { id: Id, name_off: u32, name_len: u8, fold_off: u32, fold_len: u8 };

/// A lista de documentos de uma palavra, num pedaço de `Index.pool`.
const Post = struct { word: u32, off: u32, len: u32, cap: u32, last: u32, count: u32 };

/// O que entra: uma mensagem como o app tem.
pub const Input = struct {
    id: Id,
    channel: Id,
    author: Id,
    /// Vazio: fica o nome que o índice já tinha para essa pessoa.
    author_name: []const u8 = "",
    content: []const u8,
    /// Nomes dos anexos, separados por espaço.
    files: []const u8 = "",
    flags: u8 = 0,
};

/// O que interessa de uma mensagem do app. `files_buf` guarda os nomes dos anexos.
pub fn inputOf(m: *const types.Message, files_buf: []u8) Input {
    var flags: u8 = if (hasLink(m.content)) f_link else 0;
    var n: usize = 0;
    for (m.attachments) |*a| {
        if (a.video) flags |= f_video;
        if (a.voice or (!a.embed and isAudio(a.filename))) flags |= f_sound;
        // Como a busca do Discord: imagem inclui a de um link; arquivo é o anexado que
        // não é imagem.
        if (a.isImage() and !a.video) {
            flags |= f_image;
        } else if (!a.embed) flags |= f_file;
        if (a.embed) continue;
        const room = files_buf.len -| n;
        if (room < 2) continue;
        if (n > 0) {
            files_buf[n] = ' ';
            n += 1;
        }
        const k = utf8Cut(a.filename, files_buf.len - n);
        @memcpy(files_buf[n..][0..k], a.filename[0..k]);
        n += k;
    }
    return .{ .id = m.id, .channel = m.channel, .author = m.author, .content = m.content, .files = files_buf[0..n], .flags = flags };
}

pub fn hasLink(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "https://") != null or std.mem.indexOf(u8, s, "http://") != null;
}

fn isAudio(name: []const u8) bool {
    const exts = [_][]const u8{ ".mp3", ".ogg", ".oga", ".opus", ".wav", ".flac", ".m4a", ".aac" };
    for (exts) |e| if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    return false;
}

/// Quantos bytes de `s` cabem em `max` sem partir um caractere UTF-8.
pub fn utf8Cut(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return k;
}

// --- Dobrar e separar palavras ----------------------------------------------------------

/// Latim estendido A (U+0100 a U+017F) sem acento: Ą é a, Ł é l, Ő é o, ſ é s.
const latin_ext_a = "aaaaaa" ++ "cccccccc" ++ "dddd" ++ "eeeeeeeeee" ++ "gggggggg" ++ "hhhh" ++ "iiiiiiiiii" ++ "jjjj" ++ "kkk" ++
    "llllllllll" ++ "nnnnnnnnn" ++ "oooooooo" ++ "rrrrrr" ++ "ssssssss" ++ "tttttt" ++ "uuuuuuuuuuuu" ++ "wwyyy" ++ "zzzzzzs";
comptime {
    std.debug.assert(latin_ext_a.len == 0x80);
}

/// U+00C0 a U+00FF sem acento (0 = fica como está: æ, ð, þ, ß; × e ÷ separam).
const latin1 = blk: {
    var t: [64]u8 = undefined;
    const s = "aaaaaa\x00ceeeeiiii\x00nooooo\x00ouuuuy\x00\x00aaaaaa\x00ceeeeiiii\x00nooooo\x00ouuuuy\x00y";
    if (s.len != t.len) @compileError("latin1: 64 entradas");
    for (s, 0..) |ch, i| t[i] = ch;
    break :blk t;
};

/// Minúscula e sem acento. 0 = some (acento combinante, seletor de variação).
pub fn foldCp(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    if (cp >= 0xC0 and cp <= 0xFF) {
        const t = latin1[cp - 0xC0];
        if (t != 0) return t;
        return switch (cp) {
            0xC6 => 0xE6,
            0xD0 => 0xF0,
            0xDE => 0xFE,
            else => cp,
        };
    }
    if (cp >= 0x100 and cp <= 0x17F) return latin_ext_a[cp - 0x100];
    if (cp >= 0x300 and cp <= 0x36F) return 0;
    // Grego: maiúsculas e o acento (tonos).
    if (cp >= 0x386 and cp <= 0x3CE) return switch (cp) {
        0x386, 0x3AC => 0x3B1,
        0x388, 0x3AD => 0x3B5,
        0x389, 0x3AE => 0x3B7,
        0x38A, 0x3AF, 0x3AA, 0x3CA => 0x3B9,
        0x38C, 0x3CC => 0x3BF,
        0x38E, 0x3CD, 0x3AB, 0x3CB => 0x3C5,
        0x38F, 0x3CE => 0x3C9,
        0x3C2 => 0x3C3,
        0x391...0x3A1, 0x3A3...0x3A9 => cp + 32,
        else => cp,
    };
    // Cirílico: maiúsculas, e ё como е.
    if (cp >= 0x400 and cp <= 0x45F) {
        const low: u21 = if (cp < 0x410) cp + 80 else if (cp < 0x430) cp + 32 else cp;
        return if (low == 0x451) 0x435 else low;
    }
    // Letras e números de largura cheia (teclados japoneses) viram os comuns.
    if (cp >= 0xFF21 and cp <= 0xFF3A) return cp - 0xFF21 + 'a';
    if (cp >= 0xFF41 and cp <= 0xFF5A) return cp - 0xFF41 + 'a';
    if (cp >= 0xFF10 and cp <= 0xFF19) return cp - 0xFF10 + '0';
    if ((cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x200B or cp == 0x200C or cp == 0xAD) return 0;
    return cp;
}

const Kind = enum { sep, word, ideo };

fn kindOf(cp: u21) Kind {
    if (cp < 0x80) return if (std.ascii.isAlphanumeric(@intCast(cp))) .word else .sep;
    if (cp < 0xC0 or cp == 0xD7 or cp == 0xF7) return .sep;
    return switch (cp) {
        0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFF => .ideo,
        0x2000...0x2BFF, 0x2E00...0x2E7F, 0x3000...0x303F, 0xFE10...0xFE1F, 0xFE30...0xFE4F => .sep,
        0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65, 0xFFF0...0xFFFF => .sep,
        0x1F000...0x1FAFF, 0xE0000...0xE007F => .sep,
        else => .word,
    };
}

/// Próximo caractere: o código e quantos bytes ocupa (UTF-8 quebrado vira separador).
fn decodeAt(s: []const u8, i: usize) struct { u21, usize } {
    const b = s[i];
    if (b < 0x80) return .{ b, 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ 0xFFFD, 1 };
    if (i + n > s.len) return .{ 0xFFFD, 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ 0xFFFD, 1 };
    return .{ cp, n };
}

fn encodeCp(cp: u21, out: []u8) usize {
    return std.unicode.utf8Encode(cp, out) catch 0;
}

/// As palavras de um texto, já dobradas. Cada uma vale até a próxima chamada.
pub const Tokens = struct {
    s: []const u8,
    i: usize = 0,
    buf: [max_token + 8]u8 = undefined,
    /// Emoji personalizado (`<:nome:123>`): o nome entra, o resto pula.
    jump_at: usize = std.math.maxInt(usize),
    jump_to: usize = 0,
    /// A última palavra devolvida é um ideograma ou kana (não vale como começo de palavra).
    ideo: bool = false,

    pub fn next(t: *Tokens) ?[]const u8 {
        var n: usize = 0;
        var full = false;
        t.ideo = false;
        while (t.i < t.s.len) {
            if (t.i == t.jump_at) {
                t.i = t.jump_to;
                t.jump_at = std.math.maxInt(usize);
                if (n > 0) return t.buf[0..n];
                continue;
            }
            const start = t.i;
            if (t.s[start] == '<' and n == 0) {
                if (t.markup()) |tok| return tok;
                if (t.i != start) continue;
            }
            const cp0, const len = decodeAt(t.s, t.i);
            t.i += len;
            const cp = foldCp(cp0);
            if (cp == 0) continue;
            switch (kindOf(cp)) {
                .sep => if (n > 0) return t.buf[0..n],
                .ideo => {
                    if (n > 0) {
                        // A palavra que vinha antes sai primeiro; o ideograma, na próxima.
                        t.i = start;
                        return t.buf[0..n];
                    }
                    t.ideo = true;
                    return t.buf[0..encodeCp(cp, &t.buf)];
                },
                .word => {
                    if (full) continue;
                    var tmp: [4]u8 = undefined;
                    const k = encodeCp(cp, &tmp);
                    if (n + k > max_token) {
                        full = true;
                        continue;
                    }
                    @memcpy(t.buf[n..][0..k], tmp[0..k]);
                    n += k;
                },
            }
        }
        return if (n > 0) t.buf[0..n] else null;
    }

    /// `<@123>` e `<@!123>` viram a palavra da menção; `<#123>`, `<@&123>`, `<t:…>` somem;
    /// `<:nome:123>` deixa só o nome. Fora isso, `<` é um separador comum.
    fn markup(t: *Tokens) ?[]const u8 {
        const s = t.s;
        const i = t.i;
        const end = std.mem.indexOfScalarPos(u8, s[0..@min(s.len, i + 80)], i, '>') orelse return null;
        const body = s[i + 1 .. end];
        if (body.len == 0) return null;
        if (body[0] == '@') {
            var digits = body[1..];
            if (digits.len > 0 and digits[0] == '!') digits = digits[1..];
            if (digits.len > 0 and digits[0] == '&') {
                if (allDigits(digits[1..])) t.i = end + 1;
                return null;
            }
            if (!allDigits(digits) or digits.len + 1 > t.buf.len) return null;
            t.i = end + 1;
            t.buf[0] = mention_mark;
            @memcpy(t.buf[1..][0..digits.len], digits);
            return t.buf[0 .. digits.len + 1];
        }
        if (body[0] == '#' and allDigits(body[1..])) {
            t.i = end + 1;
            return null;
        }
        if (body[0] == 't' and body.len > 2 and body[1] == ':') {
            t.i = end + 1;
            return null;
        }
        const name_at: usize = if (body[0] == ':') 1 else if (body.len > 1 and body[0] == 'a' and body[1] == ':') 2 else return null;
        const colon = std.mem.lastIndexOfScalar(u8, body, ':') orelse return null;
        if (colon <= name_at or !allDigits(body[colon + 1 ..])) return null;
        t.jump_at = i + 1 + colon;
        t.jump_to = end + 1;
        t.i = i + 1 + name_at;
        return null;
    }
};

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// O texto inteiro dobrado, com a pontuação no lugar (para conferir "meio termo").
/// Dobrar nunca aumenta o texto: `buf` do tamanho de `s` basta.
pub fn foldText(buf: []u8, s: []const u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const cp0, const len = decodeAt(s, i);
        i += len;
        const cp = foldCp(cp0);
        if (cp == 0) continue;
        var tmp: [4]u8 = undefined;
        const k = encodeCp(cp, &tmp);
        if (n + k > buf.len) break;
        @memcpy(buf[n..][0..k], tmp[0..k]);
        n += k;
    }
    return buf[0..n];
}

/// Sem os separadores das pontas ("@ana" vira "ana"), já dobrado.
fn trimSeps(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len) {
        const cp, const len = decodeAt(s, a);
        if (kindOf(cp) != .sep) break;
        a += len;
    }
    var b = s.len;
    while (b > a) {
        var k = b - 1;
        while (k > a and (s[k] & 0xC0) == 0x80) k -= 1;
        const cp, _ = decodeAt(s, k);
        if (kindOf(cp) != .sep) break;
        b = k;
    }
    return s[a..b];
}

// --- Varint -----------------------------------------------------------------------------

fn putVarint(out: *[5]u8, v0: u32) usize {
    var v = v0;
    var n: usize = 0;
    while (v >= 0x80) : (v >>= 7) {
        out[n] = @as(u8, @truncate(v)) | 0x80;
        n += 1;
    }
    out[n] = @truncate(v);
    return n + 1;
}

fn getVarint(s: []const u8, i: *usize) !u32 {
    var v: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (i.* >= s.len) return error.Corrupt;
        const b = s[i.*];
        i.* += 1;
        v |= @as(u32, b & 0x7f) << shift;
        if (b < 0x80) return v;
        if (shift >= 28) return error.Corrupt;
        shift += 7;
    }
}

// --- O índice ---------------------------------------------------------------------------

pub const Hit = struct { id: Id, doc: u32 };

pub const Ask = struct {
    /// Os termos como a consulta tem (core/search_query.zig); aqui são dobrados de novo.
    terms: []const []const u8 = &.{},
    /// A última palavra ainda está sendo digitada: vale o começo dela.
    prefix_last: bool = false,
    /// Pedaço do nome de quem escreveu (vazio = qualquer um).
    from: []const u8 = "",
    /// null = sem o filtro; vazio = ninguém com esse nome (nada casa).
    mentions: ?[]const Id = null,
    /// Tudo isso precisa ter (f_link, f_image...).
    flags: u8 = 0,
    min_id: Id = 0,
    max_id: Id = 0,
    /// Por canal do índice (`channels`): pode aparecer. null = todos.
    channel_ok: ?[]const bool = null,
    oldest: bool = false,
    limit: usize = 200,
};

pub const Index = struct {
    gpa: Allocator,
    docs: std.ArrayList(Doc) = .empty,
    text: std.ArrayList(u8) = .empty,
    by_id: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    channels: std.ArrayList(Id) = .empty,
    chan_ix: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    authors: std.ArrayList(Author) = .empty,
    author_ix: std.AutoHashMapUnmanaged(Id, u32) = .empty,
    names: std.ArrayList(u8) = .empty,
    /// As palavras, cada uma terminada em 0; o dicionário guarda onde cada uma começa.
    words: std.ArrayList(u8) = .empty,
    dict: std.HashMapUnmanaged(u32, u32, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,
    posts: std.ArrayList(Post) = .empty,
    pool: std.ArrayList(u8) = .empty,
    pool_waste: usize = 0,
    /// Documentos marcados como fora (editados ou apagados).
    gone: usize = 0,
    /// Muda a cada mudança: quem mostra resultados sabe quando refazer.
    gen: u32 = 0,

    pub fn init(gpa: Allocator) Index {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ix: *Index) void {
        const g = ix.gpa;
        ix.docs.deinit(g);
        ix.text.deinit(g);
        ix.by_id.deinit(g);
        ix.channels.deinit(g);
        ix.chan_ix.deinit(g);
        ix.authors.deinit(g);
        ix.author_ix.deinit(g);
        ix.names.deinit(g);
        ix.words.deinit(g);
        ix.dict.deinit(g);
        ix.posts.deinit(g);
        ix.pool.deinit(g);
        ix.* = .init(g);
    }

    /// Mensagens no índice (sem as marcadas como fora).
    pub fn count(ix: *const Index) usize {
        return ix.docs.items.len - ix.gone;
    }

    pub fn wordCount(ix: *const Index) usize {
        return ix.posts.items.len;
    }

    pub fn contains(ix: *const Index, id: Id) bool {
        return ix.by_id.contains(id);
    }

    pub fn docOf(ix: *const Index, id: Id) ?*const Doc {
        const i = ix.by_id.get(id) orelse return null;
        return &ix.docs.items[i];
    }

    /// O texto guardado: a mensagem e, depois de `files_sep`, os nomes dos anexos.
    pub fn stored(ix: *const Index, d: *const Doc) []const u8 {
        return ix.text.items[d.text_off..][0..d.text_len];
    }

    pub fn content(ix: *const Index, d: *const Doc) []const u8 {
        const s = ix.stored(d);
        return s[0 .. std.mem.indexOfScalar(u8, s, files_sep) orelse s.len];
    }

    pub fn files(ix: *const Index, d: *const Doc) []const u8 {
        const s = ix.stored(d);
        const at = std.mem.indexOfScalar(u8, s, files_sep) orelse return "";
        return s[at + 1 ..];
    }

    pub fn channelOf(ix: *const Index, d: *const Doc) Id {
        return ix.channels.items[d.chan];
    }

    pub fn authorOf(ix: *const Index, d: *const Doc) Id {
        return ix.authors.items[d.author].id;
    }

    pub fn authorName(ix: *const Index, d: *const Doc) []const u8 {
        const a = &ix.authors.items[d.author];
        return ix.names.items[a.name_off..][0..a.name_len];
    }

    /// De volta ao que entrou (para compactar e gravar).
    pub fn inputOfDoc(ix: *const Index, d: *const Doc) Input {
        return .{
            .id = d.id,
            .channel = ix.channelOf(d),
            .author = ix.authorOf(d),
            .author_name = ix.authorName(d),
            .content = ix.content(d),
            .files = ix.files(d),
            .flags = d.flags & ~f_gone,
        };
    }

    fn hashOf(in: Input) u32 {
        var h = std.hash.Wyhash.init(in.flags);
        h.update(in.content);
        h.update(&.{files_sep});
        h.update(in.files);
        return @truncate(h.final());
    }

    fn channelIndex(ix: *Index, ch: Id) !u32 {
        const gop = try ix.chan_ix.getOrPut(ix.gpa, ch);
        if (!gop.found_existing) {
            ix.channels.append(ix.gpa, ch) catch |e| {
                _ = ix.chan_ix.remove(ch);
                return e;
            };
            gop.value_ptr.* = @intCast(ix.channels.items.len - 1);
        }
        return gop.value_ptr.*;
    }

    fn authorIndex(ix: *Index, id: Id, name_in: []const u8) !u32 {
        const g = ix.gpa;
        const gop = try ix.author_ix.getOrPut(g, id);
        if (gop.found_existing) {
            const a = &ix.authors.items[gop.value_ptr.*];
            if (name_in.len > 0 and !std.mem.eql(u8, ix.names.items[a.name_off..][0..a.name_len], name_in[0..utf8Cut(name_in, 64)])) try ix.setName(a, name_in);
            return gop.value_ptr.*;
        }
        ix.authors.append(g, .{ .id = id, .name_off = 0, .name_len = 0, .fold_off = 0, .fold_len = 0 }) catch |e| {
            _ = ix.author_ix.remove(id);
            return e;
        };
        gop.value_ptr.* = @intCast(ix.authors.items.len - 1);
        try ix.setName(&ix.authors.items[ix.authors.items.len - 1], name_in);
        return gop.value_ptr.*;
    }

    fn setName(ix: *Index, a: *Author, name_in: []const u8) !void {
        const name = name_in[0..utf8Cut(name_in, 64)];
        var fb: [64]u8 = undefined;
        const folded = foldText(&fb, name);
        try ix.names.ensureUnusedCapacity(ix.gpa, name.len + folded.len);
        a.name_off = @intCast(ix.names.items.len);
        a.name_len = @intCast(name.len);
        ix.names.appendSliceAssumeCapacity(name);
        a.fold_off = @intCast(ix.names.items.len);
        a.fold_len = @intCast(folded.len);
        ix.names.appendSliceAssumeCapacity(folded);
    }

    fn wordIndex(ix: *Index, tok: []const u8) !u32 {
        const g = ix.gpa;
        try ix.words.ensureUnusedCapacity(g, tok.len + 1);
        try ix.posts.ensureUnusedCapacity(g, 1);
        const gop = try ix.dict.getOrPutContextAdapted(g, tok, std.hash_map.StringIndexAdapter{ .bytes = &ix.words }, .{ .bytes = &ix.words });
        if (gop.found_existing) return gop.value_ptr.*;
        const off: u32 = @intCast(ix.words.items.len);
        ix.words.appendSliceAssumeCapacity(tok);
        ix.words.appendAssumeCapacity(0);
        gop.key_ptr.* = off;
        gop.value_ptr.* = @intCast(ix.posts.items.len);
        ix.posts.appendAssumeCapacity(.{ .word = off, .off = 0, .len = 0, .cap = 0, .last = 0, .count = 0 });
        return gop.value_ptr.*;
    }

    fn findWord(ix: *const Index, tok: []const u8) ?*const Post {
        const i = ix.dict.getAdapted(tok, std.hash_map.StringIndexAdapter{ .bytes = &ix.words }) orelse return null;
        return &ix.posts.items[i];
    }

    fn addPosting(ix: *Index, w: u32, doc: u32) !void {
        const p = &ix.posts.items[w];
        // A mesma palavra duas vezes na mensagem: uma entrada só.
        if (p.count > 0 and p.last == doc) return;
        var tmp: [5]u8 = undefined;
        const n = putVarint(&tmp, if (p.count == 0) doc else doc - p.last);
        if (p.len + n > p.cap) {
            const cap: u32 = @max(4, p.cap * 2);
            try ix.pool.ensureUnusedCapacity(ix.gpa, cap);
            const at = ix.pool.items.len;
            _ = ix.pool.addManyAsSliceAssumeCapacity(cap);
            @memcpy(ix.pool.items[at..][0..p.len], ix.pool.items[p.off..][0..p.len]);
            ix.pool_waste += p.cap;
            p.off = @intCast(at);
            p.cap = cap;
        }
        @memcpy(ix.pool.items[p.off + p.len ..][0..n], tmp[0..n]);
        p.len += @intCast(n);
        p.last = doc;
        p.count += 1;
    }

    /// Põe (ou atualiza) uma mensagem. A mesma, sem mudança, não custa nada além da conta.
    pub fn put(ix: *Index, in_raw: Input) !void {
        var in = in_raw;
        in.flags &= ~f_gone;
        const g = ix.gpa;
        const files_n = utf8Cut(in.files, max_files);
        const room = max_text - @as(usize, if (files_n > 0) files_n + 1 else 0);
        in.content = in.content[0..utf8Cut(in.content, room)];
        in.files = in.files[0..files_n];
        const hash = hashOf(in);
        if (ix.by_id.get(in.id)) |old| {
            const d = &ix.docs.items[old];
            if (d.hash == hash and ix.channels.items[d.chan] == in.channel) {
                if (in.author_name.len > 0) _ = try ix.authorIndex(in.author, in.author_name);
                return;
            }
            d.flags |= f_gone;
            ix.gone += 1;
            _ = ix.by_id.remove(in.id);
        }
        const chan = try ix.channelIndex(in.channel);
        const author = try ix.authorIndex(in.author, in.author_name);
        const off = ix.text.items.len;
        const len = in.content.len + @as(usize, if (in.files.len > 0) in.files.len + 1 else 0);
        try ix.text.ensureUnusedCapacity(g, len);
        try ix.docs.ensureUnusedCapacity(g, 1);
        try ix.by_id.ensureUnusedCapacity(g, 1);
        ix.text.appendSliceAssumeCapacity(in.content);
        if (in.files.len > 0) {
            ix.text.appendAssumeCapacity(files_sep);
            ix.text.appendSliceAssumeCapacity(in.files);
        }
        const doc: u32 = @intCast(ix.docs.items.len);
        ix.docs.appendAssumeCapacity(.{ .id = in.id, .hash = hash, .chan = chan, .author = author, .text_off = @intCast(off), .text_len = @intCast(len), .flags = in.flags });
        ix.by_id.putAssumeCapacity(in.id, doc);
        ix.gen +%= 1;
        var it: Tokens = .{ .s = ix.text.items[off..][0..len] };
        while (it.next()) |tok| {
            const w = try ix.wordIndex(tok);
            try ix.addPosting(w, doc);
        }
    }

    /// Tira uma mensagem (apagada). false: não estava.
    pub fn remove(ix: *Index, id: Id) bool {
        const kv = ix.by_id.fetchRemove(id) orelse return false;
        ix.docs.items[kv.value].flags |= f_gone;
        ix.gone += 1;
        ix.gen +%= 1;
        return true;
    }

    /// Uma página do histórico é a conversa inteira entre a primeira e a última dela: o
    /// que o índice tem desse canal nessa faixa e não veio na página foi apagado.
    pub fn pruneRange(ix: *Index, channel: Id, min: Id, max: Id, keep: []const Id) usize {
        const chan = ix.chan_ix.get(channel) orelse return 0;
        var n: usize = 0;
        for (ix.docs.items) |*d| {
            if (d.flags & f_gone != 0 or d.chan != chan or d.id < min or d.id > max) continue;
            if (std.mem.indexOfScalar(Id, keep, d.id) != null) continue;
            _ = ix.by_id.remove(d.id);
            d.flags |= f_gone;
            ix.gone += 1;
            n += 1;
        }
        if (n > 0) ix.gen +%= 1;
        return n;
    }

    /// Vale refazer tudo: muitas marcadas como fora, listas espalhadas ou acima do teto.
    pub fn wantsCompact(ix: *const Index) bool {
        if (ix.gone > 2048 and ix.gone * 4 > ix.docs.items.len) return true;
        if (ix.count() > max_docs + max_docs / 10) return true;
        return ix.pool_waste > (4 << 20) and ix.pool_waste * 2 > ix.pool.items.len;
    }

    /// Refaz sem as marcadas como fora; acima de `max_docs`, as mais antigas saem.
    pub fn compact(ix: *Index) !void {
        var floor: Id = 0;
        const live = ix.count();
        if (live > max_docs) {
            const ids = try ix.gpa.alloc(Id, live);
            defer ix.gpa.free(ids);
            var k: usize = 0;
            for (ix.docs.items) |d| if (d.flags & f_gone == 0) {
                ids[k] = d.id;
                k += 1;
            };
            std.mem.sortUnstable(Id, ids, {}, std.sort.asc(Id));
            floor = ids[live - max_docs];
        }
        var fresh = Index.init(ix.gpa);
        errdefer fresh.deinit();
        for (ix.docs.items) |*d| {
            if (d.flags & f_gone != 0 or d.id < floor) continue;
            try fresh.put(ix.inputOfDoc(d));
        }
        fresh.gen = ix.gen +% 1;
        fresh.tighten();
        ix.deinit();
        ix.* = fresh;
    }

    /// Depois de ler muita coisa de uma vez (o disco, uma compactação): devolve a folga
    /// das listas e junta as listas de documentos, sem os buracos de quando cresceram.
    pub fn tighten(ix: *Index) void {
        const g = ix.gpa;
        ix.docs.shrinkAndFree(g, ix.docs.items.len);
        ix.text.shrinkAndFree(g, ix.text.items.len);
        ix.words.shrinkAndFree(g, ix.words.items.len);
        ix.posts.shrinkAndFree(g, ix.posts.items.len);
        ix.names.shrinkAndFree(g, ix.names.items.len);
        ix.channels.shrinkAndFree(g, ix.channels.items.len);
        ix.authors.shrinkAndFree(g, ix.authors.items.len);
        var used: usize = 0;
        for (ix.posts.items) |p| used += p.len;
        var pool: std.ArrayList(u8) = .empty;
        pool.ensureTotalCapacityPrecise(g, used) catch return;
        for (ix.posts.items) |*p| {
            const at = pool.items.len;
            pool.appendSliceAssumeCapacity(ix.pool.items[p.off..][0..p.len]);
            p.off = @intCast(at);
            p.cap = p.len;
        }
        ix.pool.deinit(g);
        ix.pool = pool;
        ix.pool_waste = 0;
    }

    /// Quanto o índice ocupa na memória (o que foi pedido ao alocador).
    pub fn memBytes(ix: *const Index) usize {
        const map = struct {
            fn bytes(cap: usize, kv: usize) usize {
                return cap * (kv + 1);
            }
        };
        return ix.docs.capacity * @sizeOf(Doc) + ix.text.capacity + ix.channels.capacity * @sizeOf(Id) +
            ix.authors.capacity * @sizeOf(Author) + ix.names.capacity + ix.words.capacity +
            ix.posts.capacity * @sizeOf(Post) + ix.pool.capacity +
            map.bytes(ix.by_id.capacity(), @sizeOf(Id) + @sizeOf(u32)) + map.bytes(ix.chan_ix.capacity(), @sizeOf(Id) + @sizeOf(u32)) +
            map.bytes(ix.author_ix.capacity(), @sizeOf(Id) + @sizeOf(u32)) + map.bytes(ix.dict.capacity(), 2 * @sizeOf(u32));
    }

    // --- Consulta ---------------------------------------------------------------------

    fn orPostings(ix: *const Index, p: *const Post, bits: []u64) void {
        const s = ix.pool.items[p.off..][0..p.len];
        var i: usize = 0;
        var doc: u32 = 0;
        var k: u32 = 0;
        while (k < p.count) : (k += 1) {
            const v = getVarint(s, &i) catch return;
            doc = if (k == 0) v else doc + v;
            bits[doc >> 6] |= @as(u64, 1) << @intCast(doc & 63);
        }
    }

    /// Os documentos de uma palavra (ou de todas que começam com ela). false: nenhum.
    fn fill(ix: *const Index, tok: []const u8, prefix: bool, bits: []u64) bool {
        @memset(bits, 0);
        if (!prefix) {
            const p = ix.findWord(tok) orelse return false;
            ix.orPostings(p, bits);
            return true;
        }
        var any = false;
        const w = ix.words.items;
        for (ix.posts.items) |*p| {
            if (w.len - p.word < tok.len or w[p.word] != tok[0]) continue;
            if (!std.mem.eql(u8, w[p.word..][0..tok.len], tok)) continue;
            ix.orPostings(p, bits);
            any = true;
        }
        return any;
    }

    fn andInto(cand: *?[]u64, bits: []const u64, spare: []u64) void {
        if (cand.*) |cb| {
            for (cb, bits) |*a, b| a.* &= b;
        } else {
            @memcpy(spare, bits);
            cand.* = spare;
        }
    }

    /// Quantas casaram; as `limit` mais novas (ou mais antigas) vão para `out`.
    pub fn search(ix: *const Index, gpa: Allocator, ask: Ask, out: *std.ArrayList(Hit)) !usize {
        out.clearRetainingCapacity();
        const n = ix.docs.items.len;
        if (n == ix.gone) return 0;
        const n_words = (n + 63) / 64;
        const bits = try gpa.alloc(u64, n_words * 2);
        defer gpa.free(bits);
        const tmp = bits[0..n_words];
        var cand: ?[]u64 = null;

        // Termos que precisam conferir no texto: "meio termo", "http://x.y", 日本語.
        var verify_buf: [8][256]u8 = undefined;
        var verify: [8][]const u8 = undefined;
        var n_verify: usize = 0;
        for (ask.terms, 0..) |raw, ti| {
            const last_term = ti + 1 == ask.terms.len;
            var it: Tokens = .{ .s = raw };
            var toks: [16][max_token + 8]u8 = undefined;
            var tok_len: [16]usize = undefined;
            var tok_ideo: [16]bool = undefined;
            var n_tok: usize = 0;
            while (it.next()) |tok| {
                if (n_tok == toks.len) break;
                @memcpy(toks[n_tok][0..tok.len], tok);
                tok_len[n_tok] = tok.len;
                tok_ideo[n_tok] = it.ideo;
                n_tok += 1;
            }
            for (0..n_tok) |k| {
                const tok = toks[k][0..tok_len[k]];
                const prefix = ask.prefix_last and last_term and k + 1 == n_tok and !tok_ideo[k];
                if (!ix.fill(tok, prefix, tmp)) return 0;
                andInto(&cand, tmp, bits[n_words..]);
            }
            var fb: [256]u8 = undefined;
            const folded = trimSeps(foldText(&fb, raw));
            const single = n_tok == 1 and std.mem.eql(u8, folded, toks[0][0..tok_len[0]]);
            if (!single and folded.len > 0 and n_verify < verify.len) {
                @memcpy(verify_buf[n_verify][0..folded.len], folded);
                verify[n_verify] = verify_buf[n_verify][0..folded.len];
                n_verify += 1;
            }
        }

        if (ask.mentions) |ids| {
            if (ids.len == 0) return 0;
            @memset(tmp, 0);
            var any = false;
            for (ids) |uid| {
                var mb: [24]u8 = undefined;
                mb[0] = mention_mark;
                const digits = std.fmt.bufPrint(mb[1..], "{d}", .{uid}) catch continue;
                const p = ix.findWord(mb[0 .. digits.len + 1]) orelse continue;
                ix.orPostings(p, tmp);
                any = true;
            }
            if (!any) return 0;
            andInto(&cand, tmp, bits[n_words..]);
        }

        var author_ok: ?[]bool = null;
        defer if (author_ok) |a| gpa.free(a);
        if (ask.from.len > 0) {
            var fb: [64]u8 = undefined;
            const needle = foldText(&fb, ask.from);
            const ok = try gpa.alloc(bool, ix.authors.items.len);
            author_ok = ok;
            var any = false;
            for (ix.authors.items, ok) |*a, *o| {
                o.* = std.mem.indexOf(u8, ix.names.items[a.fold_off..][0..a.fold_len], needle) != null;
                any = any or o.*;
            }
            if (!any) return 0;
        }

        var total: usize = 0;
        var fold_buf: [max_text]u8 = undefined;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (cand) |cb| {
                // Pula de 64 em 64 o que não casou.
                const word = cb[i >> 6] >> @intCast(i & 63);
                if (word == 0) {
                    i = (i | 63);
                    continue;
                }
                i += @ctz(word);
                if (i >= n) break;
            }
            const d = &ix.docs.items[i];
            if (d.flags & f_gone != 0 or d.flags & ask.flags != ask.flags) continue;
            if (ask.min_id != 0 and d.id <= ask.min_id) continue;
            if (ask.max_id != 0 and d.id >= ask.max_id) continue;
            if (ask.channel_ok) |ok| if (d.chan >= ok.len or !ok[d.chan]) continue;
            if (author_ok) |ok| if (!ok[d.author]) continue;
            if (n_verify > 0) {
                const hay = foldText(&fold_buf, ix.stored(d));
                const all = for (verify[0..n_verify]) |v| {
                    if (std.mem.indexOf(u8, hay, v) == null) break false;
                } else true;
                if (!all) continue;
            }
            total += 1;
            try out.append(gpa, .{ .id = d.id, .doc = @intCast(i) });
        }
        const S = struct {
            fn newer(_: void, a: Hit, b: Hit) bool {
                return a.id > b.id;
            }
            fn older(_: void, a: Hit, b: Hit) bool {
                return a.id < b.id;
            }
        };
        if (ask.oldest) std.mem.sortUnstable(Hit, out.items, {}, S.older) else std.mem.sortUnstable(Hit, out.items, {}, S.newer);
        if (out.items.len > ask.limit) out.shrinkRetainingCapacity(ask.limit);
        return total;
    }

    // --- Em disco ---------------------------------------------------------------------
    //
    //   "LCI1"
    //   u32 canais, cada um u64
    //   u32 autores, cada um u64 + u8 tamanho + nome
    //   u32 mensagens, cada uma u64 ID, varint canal, varint autor, u8 flags,
    //       varint tamanho + texto guardado
    //   u64 Wyhash de tudo o que vem antes
    //
    // Só os documentos: as palavras são refeitas ao ler (numa thread, ver net/busca_local.zig).

    pub const magic = "LCI1";

    pub fn encode(ix: *const Index, gpa: Allocator, out: *std.ArrayList(u8)) !void {
        const live = ix.count();
        try out.ensureTotalCapacity(gpa, 16 + ix.channels.items.len * 8 + ix.authors.items.len * 24 + live * 16 + ix.text.items.len);
        try out.appendSlice(gpa, magic);
        try putU32(gpa, out, @intCast(ix.channels.items.len));
        for (ix.channels.items) |ch| try putU64(gpa, out, ch);
        try putU32(gpa, out, @intCast(ix.authors.items.len));
        for (ix.authors.items) |*a| {
            try putU64(gpa, out, a.id);
            try out.append(gpa, a.name_len);
            try out.appendSlice(gpa, ix.names.items[a.name_off..][0..a.name_len]);
        }
        try putU32(gpa, out, @intCast(live));
        var vb: [5]u8 = undefined;
        for (ix.docs.items) |*d| {
            if (d.flags & f_gone != 0) continue;
            try putU64(gpa, out, d.id);
            try out.appendSlice(gpa, vb[0..putVarint(&vb, d.chan)]);
            try out.appendSlice(gpa, vb[0..putVarint(&vb, d.author)]);
            try out.append(gpa, d.flags);
            try out.appendSlice(gpa, vb[0..putVarint(&vb, d.text_len)]);
            try out.appendSlice(gpa, ix.stored(d));
        }
        try putU64(gpa, out, std.hash.Wyhash.hash(0, out.items));
    }

    /// Lê o que `encode` gravou para dentro de `ix` (vazio). Estragado: error.Corrupt.
    pub fn decodeInto(ix: *Index, bytes: []const u8) !void {
        if (bytes.len < magic.len + 20 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Corrupt;
        const body = bytes[0 .. bytes.len - 8];
        if (std.mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .little) != std.hash.Wyhash.hash(0, body)) return error.Corrupt;
        const g = ix.gpa;
        var i: usize = magic.len;
        const n_ch = try getU32(body, &i);
        if (n_ch > body.len / 8) return error.Corrupt;
        const chans = try g.alloc(Id, n_ch);
        defer g.free(chans);
        for (chans) |*ch| ch.* = try getU64(body, &i);
        const n_auth = try getU32(body, &i);
        if (n_auth > body.len / 9) return error.Corrupt;
        const auths = try g.alloc(struct { id: Id, name: []const u8 }, n_auth);
        defer g.free(auths);
        for (auths) |*a| {
            a.id = try getU64(body, &i);
            if (i >= body.len) return error.Corrupt;
            const len = body[i];
            i += 1;
            if (i + len > body.len) return error.Corrupt;
            a.name = body[i..][0..len];
            i += len;
        }
        const n_docs = try getU32(body, &i);
        if (n_docs > body.len / 12) return error.Corrupt;
        var k: u32 = 0;
        while (k < n_docs) : (k += 1) {
            const id = try getU64(body, &i);
            const ch = try getVarint(body, &i);
            const au = try getVarint(body, &i);
            if (ch >= n_ch or au >= n_auth or i >= body.len) return error.Corrupt;
            const flags = body[i];
            i += 1;
            const len = try getVarint(body, &i);
            if (len > max_text or i + len > body.len) return error.Corrupt;
            const t = body[i..][0..len];
            i += len;
            const sep = std.mem.indexOfScalar(u8, t, files_sep);
            try ix.put(.{
                .id = id,
                .channel = chans[ch],
                .author = auths[au].id,
                .author_name = auths[au].name,
                .content = t[0 .. sep orelse t.len],
                .files = if (sep) |s| t[s + 1 ..] else "",
                .flags = flags,
            });
        }
        if (i != body.len) return error.Corrupt;
    }
};

fn putU32(gpa: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn putU64(gpa: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn getU32(s: []const u8, i: *usize) !u32 {
    if (i.* + 4 > s.len) return error.Corrupt;
    defer i.* += 4;
    return std.mem.readInt(u32, s[i.*..][0..4], .little);
}

fn getU64(s: []const u8, i: *usize) !u64 {
    if (i.* + 8 > s.len) return error.Corrupt;
    defer i.* += 8;
    return std.mem.readInt(u64, s[i.*..][0..8], .little);
}

// --- Junto com a busca do Discord -------------------------------------------------------

pub const Order = enum { newest, oldest, relevance };
pub const Origin = enum { local, server, both };
/// Uma linha da lista: de onde veio e a posição na lista de cada lado.
pub const Item = struct { id: Id, origin: Origin, local_i: u32 = 0, server_i: u32 = 0 };

/// A página do Discord junto com o que achou aqui, cada mensagem uma vez: o Discord só
/// acrescenta o que não está neste computador. Por data, tudo junto na ordem pedida; por
/// relevância, a ordem do Discord primeiro e depois as daqui que ele não trouxe.
pub fn merge(gpa: Allocator, local: []const Id, server: []const Id, order: Order, out: *std.ArrayList(Item)) !void {
    out.clearRetainingCapacity();
    var seen: std.AutoHashMapUnmanaged(Id, u32) = .empty;
    defer seen.deinit(gpa);
    try out.ensureTotalCapacity(gpa, local.len + server.len);
    if (order == .relevance) {
        for (server, 0..) |id, i| {
            const gop = try seen.getOrPut(gpa, id);
            if (gop.found_existing) continue;
            gop.value_ptr.* = @intCast(out.items.len);
            out.appendAssumeCapacity(.{ .id = id, .origin = .server, .server_i = @intCast(i) });
        }
        for (local, 0..) |id, i| {
            if (seen.get(id)) |at| {
                out.items[at].origin = .both;
                out.items[at].local_i = @intCast(i);
                continue;
            }
            try seen.put(gpa, id, @intCast(out.items.len));
            out.appendAssumeCapacity(.{ .id = id, .origin = .local, .local_i = @intCast(i) });
        }
        return;
    }
    for (local, 0..) |id, i| {
        const gop = try seen.getOrPut(gpa, id);
        if (gop.found_existing) continue;
        gop.value_ptr.* = @intCast(out.items.len);
        out.appendAssumeCapacity(.{ .id = id, .origin = .local, .local_i = @intCast(i) });
    }
    for (server, 0..) |id, i| {
        if (seen.get(id)) |at| {
            out.items[at].origin = .both;
            out.items[at].server_i = @intCast(i);
            continue;
        }
        try seen.put(gpa, id, @intCast(out.items.len));
        out.appendAssumeCapacity(.{ .id = id, .origin = .server, .server_i = @intCast(i) });
    }
    const S = struct {
        fn newer(_: void, a: Item, b: Item) bool {
            return a.id > b.id;
        }
        fn older(_: void, a: Item, b: Item) bool {
            return a.id < b.id;
        }
    };
    if (order == .oldest) std.mem.sortUnstable(Item, out.items, {}, S.older) else std.mem.sortUnstable(Item, out.items, {}, S.newer);
}

// --- Testes -----------------------------------------------------------------------------

const testing = std.testing;

fn msg(ix: *Index, id: Id, ch: Id, author: Id, text: []const u8) !void {
    try ix.put(.{ .id = id, .channel = ch, .author = author, .author_name = if (author == 1) "Ana Clara" else "Bruno", .content = text, .flags = if (hasLink(text)) f_link else 0 });
}

fn hitIds(ix: *const Index, ask: Ask) ![]Id {
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    _ = try ix.search(testing.allocator, ask, &out);
    const r = try testing.allocator.alloc(Id, out.items.len);
    for (out.items, r) |h, *x| x.* = h.id;
    return r;
}

fn expectIds(ix: *const Index, ask: Ask, want: []const Id) !void {
    const got = try hitIds(ix, ask);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Id, want, got);
}

test "palavras dobradas: acento, maiúscula, cirílico, largura cheia, menção e emoji" {
    var it: Tokens = .{ .s = "Não SEI, <@123> olá <:pepe_ok:999> ЁЛКА ｚｉｇ <#55> fim" };
    const want = [_][]const u8{ "nao", "sei", "\x01123", "ola", "pepe", "ok", "елка", "zig", "fim" };
    for (want) |w| try testing.expectEqualStrings(w, it.next().?);
    try testing.expect(it.next() == null);
    // Japonês: cada ideograma ou kana é uma palavra, mesmo colado num latino.
    var ja: Tokens = .{ .s = "zig日本語!" };
    for ([_][]const u8{ "zig", "日", "本", "語" }) |w| try testing.expectEqualStrings(w, ja.next().?);
    try testing.expect(ja.next() == null);
    // Uma palavra comprida fica com o começo, sem partir um caractere (ж tem 2 bytes).
    var long: Tokens = .{ .s = "aжжжжжжжжжжжжжжжжжжжж x" };
    try testing.expectEqual(@as(usize, 31), long.next().?.len);
    try testing.expectEqualStrings("x", long.next().?);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("acao, lodz: ola!", foldText(&buf, "AÇÃO, Łódź: Olá!"));
}

test "busca por palavras, acentos e o começo da última palavra" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try msg(&ix, 10, 1, 1, "Não sei, mas confia");
    try msg(&ix, 20, 1, 2, "o hyprland novo tá muito liso");
    try msg(&ix, 30, 2, 1, "alguém usa HYPRLAND? não aguento mais o gnome");
    try msg(&ix, 40, 2, 2, "naofaz sentido");
    try expectIds(&ix, .{ .terms = &.{"nao"} }, &.{ 30, 10 });
    try expectIds(&ix, .{ .terms = &.{"NÃO"} }, &.{ 30, 10 });
    // Digitando: "hypr" já acha; palavras anteriores valem inteiras.
    try expectIds(&ix, .{ .terms = &.{"hypr"}, .prefix_last = true }, &.{ 30, 20 });
    try expectIds(&ix, .{ .terms = &.{"hypr"} }, &.{});
    try expectIds(&ix, .{ .terms = &.{ "nao", "ag" }, .prefix_last = true }, &.{30});
    try expectIds(&ix, .{ .terms = &.{ "na", "aguento" }, .prefix_last = true }, &.{});
    try expectIds(&ix, .{ .terms = &.{"nao"}, .prefix_last = true }, &.{ 40, 30, 10 });
    // Mais de uma palavra num termo confere no texto ("meio termo", links).
    try expectIds(&ix, .{ .terms = &.{"sei, mas"} }, &.{10});
    try expectIds(&ix, .{ .terms = &.{"mas sei"} }, &.{});
    // Mais antigas primeiro e o corte.
    try expectIds(&ix, .{ .terms = &.{"nao"}, .prefix_last = true, .oldest = true, .limit = 2 }, &.{ 10, 30 });
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), try ix.search(testing.allocator, .{ .terms = &.{"nao"}, .prefix_last = true, .limit = 1 }, &out));
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "filtros: de, menciona, em, tem e datas" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try msg(&ix, 100, 1, 1, "veja https://ziglang.org");
    try msg(&ix, 200, 1, 2, "<@1> olha isso");
    try msg(&ix, 300, 2, 1, "foto da praia");
    try ix.put(.{ .id = 400, .channel = 2, .author = 2, .content = "", .files = "relatorio.pdf", .flags = f_file });
    try ix.put(.{ .id = 500, .channel = 3, .author = 1, .content = "voz", .flags = f_sound | f_file });
    try expectIds(&ix, .{ .from = "ana" }, &.{ 500, 300, 100 });
    try expectIds(&ix, .{ .from = "BRU" }, &.{ 400, 200 });
    try expectIds(&ix, .{ .from = "ninguem" }, &.{});
    try expectIds(&ix, .{ .mentions = &.{1} }, &.{200});
    try expectIds(&ix, .{ .mentions = &.{} }, &.{});
    try expectIds(&ix, .{ .flags = f_link }, &.{100});
    try expectIds(&ix, .{ .flags = f_file }, &.{ 500, 400 });
    try expectIds(&ix, .{ .flags = f_sound }, &.{500});
    // Os nomes dos anexos também são texto.
    try expectIds(&ix, .{ .terms = &.{"relat"}, .prefix_last = true }, &.{400});
    // Um link inteiro confere no texto.
    try expectIds(&ix, .{ .terms = &.{"https://ziglang.org"} }, &.{100});
    try expectIds(&ix, .{ .min_id = 200, .max_id = 500 }, &.{ 400, 300 });
    const ok = [_]bool{ false, true, false };
    try expectIds(&ix, .{ .channel_ok = &ok }, &.{ 400, 300 });
}

test "editar, apagar e a faixa de uma página do histórico ficam em dia" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try msg(&ix, 1, 7, 1, "primeira versão");
    try msg(&ix, 2, 7, 1, "outra mensagem");
    try msg(&ix, 3, 7, 2, "mais uma");
    try msg(&ix, 4, 8, 2, "noutro canal");
    const g0 = ix.gen;
    // A mesma mensagem de novo não muda nada.
    try msg(&ix, 1, 7, 1, "primeira versão");
    try testing.expectEqual(g0, ix.gen);
    try msg(&ix, 1, 7, 1, "segunda versão");
    try expectIds(&ix, .{ .terms = &.{"primeira"} }, &.{});
    try expectIds(&ix, .{ .terms = &.{"segunda"} }, &.{1});
    try testing.expect(ix.remove(2));
    try testing.expect(!ix.remove(2));
    try expectIds(&ix, .{ .terms = &.{"outra"} }, &.{});
    try testing.expectEqual(@as(usize, 3), ix.count());
    // Uma página de 1 a 3 sem a 3: ela foi apagada; o outro canal fica.
    try testing.expectEqual(@as(usize, 1), ix.pruneRange(7, 1, 3, &.{1}));
    try expectIds(&ix, .{}, &.{ 4, 1 });
    // Compactar tira as marcadas e mantém o resto achável.
    try ix.compact();
    try testing.expectEqual(@as(usize, 0), ix.gone);
    try testing.expectEqual(@as(usize, 2), ix.docs.items.len);
    try expectIds(&ix, .{ .terms = &.{"seg"}, .prefix_last = true }, &.{1});
    try expectIds(&ix, .{ .from = "ana" }, &.{1});
}

test "grava e lê de volta; estragado não passa" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try msg(&ix, 11, 1, 1, "olá <@2> mundo");
    try msg(&ix, 12, 2, 2, "日本語のテキスト");
    try ix.put(.{ .id = 13, .channel = 2, .author = 1, .content = "", .files = "foto.png notas.txt", .flags = f_image | f_file });
    _ = ix.remove(11);
    try msg(&ix, 14, 1, 1, "depois");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try ix.encode(testing.allocator, &bytes);
    var back = Index.init(testing.allocator);
    defer back.deinit();
    try back.decodeInto(bytes.items);
    try testing.expectEqual(@as(usize, 3), back.count());
    try expectIds(&back, .{ .terms = &.{"日本語"} }, &.{12});
    try expectIds(&back, .{ .terms = &.{"notas"}, .flags = f_image }, &.{13});
    try expectIds(&back, .{ .terms = &.{"ola"} }, &.{});
    try expectIds(&back, .{ .from = "clara" }, &.{ 14, 13 });
    const d = back.docOf(13).?;
    try testing.expectEqualStrings("foto.png notas.txt", back.files(d));
    try testing.expectEqualStrings("", back.content(d));
    // Um byte trocado ou o arquivo cortado: estragado.
    bytes.items[10] ^= 0x40;
    var bad = Index.init(testing.allocator);
    defer bad.deinit();
    try testing.expectError(error.Corrupt, bad.decodeInto(bytes.items));
    try testing.expectError(error.Corrupt, bad.decodeInto(bytes.items[0 .. bytes.items.len / 2]));
    try testing.expectError(error.Corrupt, bad.decodeInto("LCI0"));
}

test "apagar tudo (o cache) deixa o índice vazio e utilizável" {
    var ix = Index.init(testing.allocator);
    defer ix.deinit();
    try msg(&ix, 1, 1, 1, "algo para esquecer");
    ix.deinit();
    try testing.expectEqual(@as(usize, 0), ix.count());
    try expectIds(&ix, .{ .terms = &.{"algo"} }, &.{});
    try msg(&ix, 2, 1, 1, "algo novo");
    try expectIds(&ix, .{ .terms = &.{"algo"} }, &.{2});
}

test "a página do Discord junto com o que está aqui, cada uma uma vez" {
    var out: std.ArrayList(Item) = .empty;
    defer out.deinit(testing.allocator);
    const local = [_]Id{ 90, 70, 50 };
    const server = [_]Id{ 80, 70, 10 };
    try merge(testing.allocator, &local, &server, .newest, &out);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    const want = [_]Id{ 90, 80, 70, 50, 10 };
    for (out.items, want) |it, w| try testing.expectEqual(w, it.id);
    try testing.expectEqual(Origin.both, out.items[2].origin);
    try testing.expectEqual(Origin.server, out.items[1].origin);
    try testing.expectEqual(@as(u32, 1), out.items[2].server_i);
    try merge(testing.allocator, &local, &server, .oldest, &out);
    try testing.expectEqual(@as(Id, 10), out.items[0].id);
    // Relevância: a ordem do Discord, e depois as daqui que ele não trouxe.
    try merge(testing.allocator, &local, &server, .relevance, &out);
    const want_rel = [_]Id{ 80, 70, 10, 90, 50 };
    for (out.items, want_rel) |it, w| try testing.expectEqual(w, it.id);
    try testing.expectEqual(Origin.both, out.items[1].origin);
}

test "medida: dezenas de milhares de mensagens, memória e tempo de consulta" {
    const gpa = std.heap.c_allocator;
    var ix = Index.init(gpa);
    defer ix.deinit();
    const vocab = [_][]const u8{
        "zig",        "allocator", "hyprland",   "wallpaper", "compilar", "não",      "sei",     "bom",
        "dia",        "rapaziada", "jogar",      "hoje",      "noite",    "cache",    "ram",     "tema",
        "kitty",      "dormir",    "prova",      "cliente",   "discord",  "mensagem", "print",   "lindo",
        "segredo",    "cpu",       "parado",     "bordas",    "moderno",  "lo-fi",    "café",    "energético",
        "geladeira",  "call",      "script",     "cores",     "repo",     "sentido",  "testar",  "funcionou",
        "série",      "cachorro",  "vilão",      "docs",      "kdl",      "layout",   "nível",   "vesktop",
        "electron",   "memória",   "thread",     "gateway",   "servidor", "canal",    "emoji",   "reação",
        "atualização", "versão",    "português", "japonês",   "russo",    "teclado",  "atalho",  "mascote",
    };
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const n: usize = 50_000;
    var text_bytes: usize = 0;
    const t0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    var buf: [400]u8 = undefined;
    for (0..n) |i| {
        var len: usize = 0;
        const words = 3 + r.uintLessThan(usize, 12);
        for (0..words) |_| {
            // Palavras comuns e algumas raras (números, nomes): o vocabulário cresce.
            const w = vocab[r.uintLessThan(usize, vocab.len)];
            const piece = if (r.uintLessThan(u8, 5) == 0)
                std.fmt.bufPrint(buf[len..], "{s}{d} ", .{ w, r.uintLessThan(u32, 5000) }) catch break
            else
                std.fmt.bufPrint(buf[len..], "{s} ", .{w}) catch break;
            len += piece.len;
        }
        text_bytes += len;
        const flags: u8 = if (i % 17 == 0) f_link else if (i % 23 == 0) f_image else 0;
        try ix.put(.{ .id = 1_000_000 + i * 7, .channel = 100 + r.uintLessThan(u64, 300), .author = 1 + r.uintLessThan(u64, 400), .author_name = "pessoa", .content = buf[0..len], .flags = flags });
    }
    const t1 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    const grown = ix.memBytes();
    // Como fica depois de ler do disco.
    ix.tighten();
    const per_msg_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0 / @as(f64, @floatFromInt(n));
    const asks = [_]Ask{
        .{ .terms = &.{"z"}, .prefix_last = true },
        .{ .terms = &.{"allocator"} },
        .{ .terms = &.{ "zig", "hypr" }, .prefix_last = true },
        .{ .terms = &.{"nao"}, .from = "pes", .flags = f_link },
        .{ .terms = &.{"bom dia"} },
        .{ .flags = f_image },
        .{ .terms = &.{"ca"}, .prefix_last = true, .oldest = true },
    };
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(gpa);
    var worst_ns: i96 = 0;
    for (asks) |a| {
        const q0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
        const found = try ix.search(gpa, a, &out);
        const q1 = std.Io.Clock.awake.now(testing.io).nanoseconds;
        worst_ns = @max(worst_ns, q1 - q0);
        try testing.expect(found > 0);
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try ix.encode(gpa, &bytes);
    const worst_ms = @as(f64, @floatFromInt(worst_ns)) / 1e6;
    // LARPER_MEDIR=1 zig build test: mostra os números (sem ele, o teste fica quieto).
    if (std.c.getenv("LARPER_MEDIR") != null) std.debug.print("busca local: {d} mensagens ({d} KB de texto), {d} palavras, {d} KB na memória ({d} KB antes de apertar), {d} KB em disco, {d:.2} µs por mensagem, pior consulta {d:.2} ms\n", .{
        n, text_bytes / 1024, ix.wordCount(), ix.memBytes() / 1024, grown / 1024, bytes.items.len / 1024, per_msg_us, worst_ms,
    });
    // O orçamento: consulta em menos de ~10 ms (no modo do app; o Debug é bem mais lento).
    if (@import("builtin").mode != .debug) try testing.expect(worst_ms < 10);
    try testing.expect(ix.memBytes() < 16 * 1024 * 1024);
    // Apertado, continua aceitando mensagens novas.
    try ix.put(.{ .id = 1, .channel = 100, .author = 1, .content = "palavranova depois de apertar" });
    try testing.expectEqual(@as(usize, 1), try ix.search(gpa, .{ .terms = &.{"palavranova"} }, &out));
}
