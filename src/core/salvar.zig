//! Salvar mídia no disco (as partes puras, testadas no `zig build test`): qual
//! endereço é o arquivo original de um anexo ou embed, o nome sugerido com a
//! extensão certa, nomes que valem no Windows e no Linux e a pasta Downloads do
//! user-dirs.dirs. (A exportação de conversa não baixa nada: ver net/exportar.zig.)
//!
//! O arquivo original nunca é a prévia reduzida do proxy de mídia: a imagem de um
//! anexo vem do cdn.discordapp.com (o mesmo caminho e a mesma assinatura do
//! media.discordapp.net), o vídeo do link dele e o GIF do Tenor/Giphy do site
//! deles (o .gif de verdade, não a miniatura parada). Tudo isso é CDN: nenhum
//! endereço daqui passa pela API do Discord (ver `safeMediaUrl`).
const std = @import("std");
const types = @import("types.zig");
const media_url = @import("../net/media_url.zig");

/// O que baixar para ter o arquivo original e o nome sugerido para ele.
pub const Pick = struct {
    /// O original. Pode ser `demo:…` (demonstração, gerada aqui) ou `file://…`.
    url: []const u8,
    /// Se o original não pode vir (GIFs do Tenor/Giphy desligados nas
    /// Configurações): a prévia do proxy, que pelo menos é a imagem. Vazio = sem.
    fallback: []const u8 = "",
    /// Nome sugerido, já com a extensão (ainda não passou por `sanitizeName`).
    name: []const u8,
    /// `url` é a página de um GIF antigo do Tenor (tenor.com/view/…): o vídeo
    /// sai do og:video dela.
    page: bool = false,
    /// Só existe no Tenor/Giphy (precisa dos GIFs ligados nas Configurações).
    gif_host: bool = false,
};

/// Espaço para montar os endereços e o nome de um `Pick`.
pub const PickBuf = struct {
    url: [2048]u8 = undefined,
    name: [256]u8 = undefined,
};

const tenor_page = media_url.tenor_page;

/// O original de um anexo (inclusive as imagens e GIFs que vieram de links).
pub fn ofAttachment(b: *PickBuf, a: *const types.Attachment) Pick {
    // Vídeo: `url` é um quadro pelo proxy, `link` o arquivo.
    if (a.video and a.link.len > 0) return .{ .url = a.link, .name = withExt(&b.name, a.filename, a.link, "video") };
    // GIF antigo do Tenor (só MP4): a página diz o vídeo.
    if (std.mem.startsWith(u8, a.url, tenor_page)) {
        return .{ .url = a.url[tenor_page.len..], .fallback = a.still, .page = true, .gif_host = true, .name = forceExt(&b.name, a.filename, ".mp4", "gif") };
    }
    // GIF do Tenor/Giphy: o .gif de verdade no site deles.
    if (media_url.gifOriginal(&b.url, a.url)) |gif| {
        return .{ .url = gif, .fallback = a.still, .gif_host = true, .name = forceExt(&b.name, a.filename, ".gif", "gif") };
    }
    // Imagem de anexo pelo proxy: a mesma no CDN, sem redução nenhuma.
    if (cdnFromProxy(&b.url, a.url)) |cdn| return .{ .url = cdn, .name = withExt(&b.name, a.filename, cdn, "imagem") };
    return .{ .url = a.url, .name = withExt(&b.name, a.filename, a.url, "arquivo") };
}

/// A imagem grande de um cartão de link: o endereço do proxy sem tamanho é o original.
pub fn ofEmbedImage(b: *PickBuf, e: *const types.Embed) Pick {
    return .{ .url = e.image, .name = withExt(&b.name, lastSegment(e.image), e.image, "imagem") };
}

/// O vídeo de um cartão (link direto para um .mp4, pelo proxy do Discord).
pub fn ofEmbedVideo(b: *PickBuf, e: *const types.Embed) Pick {
    return .{ .url = e.video_url, .name = withExt(&b.name, lastSegment(e.video_url), e.video_url, "video") };
}

/// Um item de mídia dos componentes de um bot: `link` é o arquivo no CDN.
pub fn ofBlockMedia(b: *PickBuf, it: *const types.EmbedMedia) Pick {
    const http = std.mem.startsWith(u8, it.link, "https://");
    const src = if (http) it.link else it.url;
    const label = if (it.label.len > 0) it.label else lastSegment(src);
    if (!http) if (cdnFromProxy(&b.url, src)) |cdn| return .{ .url = cdn, .name = withExt(&b.name, label, cdn, "imagem") };
    return .{ .url = src, .name = withExt(&b.name, label, src, "arquivo") };
}

/// media.discordapp.net/attachments/… -> cdn.discordapp.com/attachments/… (o caminho
/// e a assinatura são os mesmos; só o CDN entrega o arquivo como foi enviado).
pub fn cdnFromProxy(buf: []u8, url: []const u8) ?[]const u8 {
    const proxy = "https://media.discordapp.net/attachments/";
    if (!std.mem.startsWith(u8, url, proxy)) return null;
    return std.fmt.bufPrint(buf, "https://cdn.discordapp.com/attachments/{s}", .{url[proxy.len..]}) catch null;
}

/// O último pedaço do caminho, sem a query ("" se não tem).
pub fn lastSegment(url: []const u8) []const u8 {
    const path = url[0 .. std.mem.indexOfAny(u8, url, "?#") orelse url.len];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return if (std.mem.indexOfScalar(u8, path, ':') != null) "" else path;
    return path[slash + 1 ..];
}

/// A extensão de um nome (".png"), ou "" se não tem uma que pareça extensão.
pub fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    const e = name[dot..];
    if (e.len < 2 or e.len > 6) return "";
    for (e[1..]) |ch| if (!std.ascii.isAlphanumeric(ch)) return "";
    return e;
}

/// A extensão do arquivo de um endereço (pelo caminho, sem a query).
pub fn urlExt(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "demo:")) {
        if (std.mem.startsWith(u8, url, "demo:voice")) return ".ogg";
        if (std.mem.startsWith(u8, url, "demo:video")) return ".mp4";
        if (std.mem.indexOf(u8, url, "gif") != null) return ".gif";
        if (std.mem.startsWith(u8, url, "demo:file")) return "";
        return ".png";
    }
    return extOf(lastSegment(url));
}

/// O nome com a extensão do endereço quando não tem nenhuma (o título de um cartão,
/// "imagem"). Vazio vira `fallback`.
fn withExt(buf: []u8, name_in: []const u8, url: []const u8, fallback: []const u8) []const u8 {
    const name = if (std.mem.trim(u8, name_in, " ").len > 0) name_in else fallback;
    if (extOf(name).len > 0) return name;
    const e = urlExt(url);
    if (e.len == 0) return name;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ name[0..@min(name.len, buf.len - e.len)], e }) catch name;
}

/// O nome com a extensão `ext` no lugar da que tiver (o .webp da miniatura do Tenor
/// vira .gif, que é o que foi baixado).
fn forceExt(buf: []u8, name_in: []const u8, ext: []const u8, fallback: []const u8) []const u8 {
    const name = if (std.mem.trim(u8, name_in, " ").len > 0) name_in else fallback;
    const old = extOf(name);
    const stem = name[0 .. name.len - old.len];
    return std.fmt.bufPrint(buf, "{s}{s}", .{ stem[0..@min(stem.len, buf.len - ext.len)], ext }) catch name;
}

/// Nomes que o Windows reserva (com ou sem extensão: "con.txt" também não vale).
const reserved = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };

/// Maior nome que sai daqui (bem abaixo dos 255 bytes do ext4 e do NTFS, que
/// ainda ganham " (12)" e ".part").
pub const max_name = 150;

/// Um nome de arquivo que vale nos dois sistemas: sem `<>:"/\|?*` nem caracteres
/// de controle, sem espaço ou ponto no fim, sem os nomes reservados do Windows,
/// cortado em `max_name` bytes (sem partir um caractere e mantendo a extensão).
/// Nada sobrou: `fallback`.
pub fn sanitizeName(buf: []u8, name: []const u8, fallback: []const u8) []const u8 {
    var tmp: [512]u8 = undefined;
    var n: usize = 0;
    for (name) |ch| {
        if (n == tmp.len) break;
        tmp[n] = if (ch < 0x20 or ch == 0x7f or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", ch) != null) '_' else ch;
        n += 1;
    }
    var s: []const u8 = std.mem.trim(u8, tmp[0..n], " ");
    while (s.len > 0 and (s[s.len - 1] == '.' or s[s.len - 1] == ' ')) s = s[0 .. s.len - 1];
    if (s.len == 0 or std.mem.eql(u8, std.mem.trim(u8, s, "_"), "")) s = fallback;
    // Comprido demais: corta o começo do nome e fica com a extensão.
    const limit = @min(max_name, buf.len - 1);
    const e = extOf(s);
    var out_len: usize = 0;
    const base = s[0 .. s.len - e.len];
    const room = if (s.len > limit) limit - e.len else base.len;
    const stem = utf8Prefix(base, room);
    // "CON", "con.txt", "Lpt1.png": com um "_" na frente.
    const word = stem[0 .. std.mem.indexOfScalar(u8, stem, '.') orelse stem.len];
    var prefix = false;
    for (reserved) |r| if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, word, " "), r)) {
        prefix = true;
    };
    if (prefix) {
        buf[0] = '_';
        out_len = 1;
    }
    const stem_fit = utf8Prefix(stem, buf.len - out_len - e.len);
    @memcpy(buf[out_len..][0..stem_fit.len], stem_fit);
    out_len += stem_fit.len;
    @memcpy(buf[out_len..][0..e.len], e);
    out_len += e.len;
    return buf[0..out_len];
}

fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var k = max;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return s[0..k];
}

/// "<pasta>/<nome>", ou "<pasta>/<nome> (1).ext", "(2)"… se já existe um com esse
/// nome. `exists` pergunta ao disco. null = nem com 999 tentativas.
pub fn uniquePath(buf: []u8, dir: []const u8, name: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), [:0]const u8) bool) ?[:0]const u8 {
    const sep: []const u8 = if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) "" else "/";
    const first = std.fmt.bufPrintSentinel(buf, "{s}{s}{s}", .{ dir, sep, name }, 0) catch return null;
    if (!exists(ctx, first)) return first;
    const e = extOf(name);
    const stem = name[0 .. name.len - e.len];
    var i: u32 = 1;
    while (i < 1000) : (i += 1) {
        const p = std.fmt.bufPrintSentinel(buf, "{s}{s}{s} ({d}){s}", .{ dir, sep, stem, i, e }, 0) catch return null;
        if (!exists(ctx, p)) return p;
    }
    return null;
}

/// A pasta Downloads do $XDG_CONFIG_HOME/user-dirs.dirs (`content`): a linha
/// XDG_DOWNLOAD_DIR="$HOME/Downloads" (ou um caminho absoluto). null = não tem a
/// linha ou ela não vale (caminho relativo); quem chama usa ~/Downloads.
pub fn downloadsFromUserDirs(buf: []u8, content: []const u8, home: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const key = "XDG_DOWNLOAD_DIR=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        var v = line[key.len..];
        if (v.len < 2 or v[0] != '"') return null;
        const close = std.mem.indexOfScalarPos(u8, v, 1, '"') orelse return null;
        v = v[1..close];
        if (std.mem.startsWith(u8, v, "$HOME")) {
            const rest = std.mem.trimEnd(u8, v["$HOME".len..], "/");
            if (rest.len > 0 and rest[0] != '/') return null;
            return std.fmt.bufPrint(buf, "{s}{s}", .{ std.mem.trimEnd(u8, home, "/"), rest }) catch null;
        }
        if (v.len > 0 and v[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{std.mem.trimEnd(u8, v, "/")}) catch null;
        return null;
    }
    return null;
}

/// Pode baixar daqui? Só a CDN e o proxy de mídia do Discord (e o Tenor/Giphy, se
/// ligados): nunca a API (discord.com/api, …/api/v9), que é onde a conta aparece.
/// O `fetch` das imagens já recusa domínio de fora; isto ainda tira qualquer
/// caminho de API mesmo num domínio do Discord.
pub fn safeMediaUrl(url: []const u8) bool {
    if (!media_url.allowedHost(url)) return false;
    const rest = url["https://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const host = rest[0..slash];
    const path = rest[slash..];
    if (std.ascii.startsWithIgnoreCase(path, "/api/") or std.ascii.eqlIgnoreCase(path, "/api")) return false;
    // A API e o site não servem mídia: discord.com, discordapp.com e os canary/ptb.
    for ([_][]const u8{ "discord.com", "discordapp.com", "canary.discordapp.com", "ptb.discordapp.com" }) |h| if (std.ascii.eqlIgnoreCase(host, h)) return false;
    return true;
}

// --- Testes -------------------------------------------------------------------------

const testing = std.testing;

test "nome de arquivo que vale no Windows e no Linux" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("a_b_c_d_e_f_g_h_i.png", sanitizeName(&b, "a<b>c:d\"e/f\\g|h?i.png", "x"));
    try testing.expectEqualStrings("_CON.txt", sanitizeName(&b, "CON.txt", "x"));
    try testing.expectEqualStrings("_con", sanitizeName(&b, "con", "x"));
    try testing.expectEqualStrings("_Lpt1.tar.gz", sanitizeName(&b, "Lpt1.tar.gz", "x"));
    try testing.expectEqualStrings("console.log", sanitizeName(&b, "console.log", "x"));
    try testing.expectEqualStrings("foto", sanitizeName(&b, "foto. . ", "x"));
    try testing.expectEqualStrings("x", sanitizeName(&b, "...", "x"));
    try testing.expectEqualStrings("x", sanitizeName(&b, "  ", "x"));
    try testing.expectEqualStrings("x", sanitizeName(&b, "///", "x"));
    try testing.expectEqualStrings("tab_nl_.txt", sanitizeName(&b, "tab\tnl\n.txt", "x"));
    // Acentos e emoji ficam; comprido demais corta sem partir caractere e guarda a extensão.
    try testing.expectEqualStrings("açaí 🍧.jpg", sanitizeName(&b, "açaí 🍧.jpg", "x"));
    var long: [400]u8 = undefined;
    for (&long, 0..) |*ch, i| ch.* = if (i % 2 == 0) 0xC3 else 0xA9; // "é" repetido
    const name = try std.fmt.allocPrint(testing.allocator, "{s}.webp", .{long[0..398]});
    defer testing.allocator.free(name);
    const out = sanitizeName(&b, name, "x");
    try testing.expect(out.len <= max_name);
    try testing.expect(std.mem.endsWith(u8, out, ".webp"));
    try testing.expect(std.unicode.utf8ValidateSlice(out));
}

test "nome único na pasta" {
    const Fake = struct {
        fn exists(taken: []const []const u8, p: [:0]const u8) bool {
            for (taken) |t| if (std.mem.eql(u8, t, p)) return true;
            return false;
        }
    };
    var b: [256]u8 = undefined;
    const none = [_][]const u8{};
    try testing.expectEqualStrings("/d/foto.png", uniquePath(&b, "/d", "foto.png", @as([]const []const u8, &none), Fake.exists).?);
    const two = [_][]const u8{ "/d/foto.png", "/d/foto (1).png" };
    try testing.expectEqualStrings("/d/foto (2).png", uniquePath(&b, "/d/", "foto.png", @as([]const []const u8, &two), Fake.exists).?);
    const noext = [_][]const u8{"C:\\Users\\a\\Downloads/LEIAME"};
    try testing.expectEqualStrings("C:\\Users\\a\\Downloads/LEIAME (1)", uniquePath(&b, "C:\\Users\\a\\Downloads", "LEIAME", @as([]const []const u8, &noext), Fake.exists).?);
}

test "pasta Downloads do user-dirs.dirs" {
    var b: [256]u8 = undefined;
    const pt = "# comentário\nXDG_DESKTOP_DIR=\"$HOME/Área de trabalho\"\nXDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\n";
    try testing.expectEqualStrings("/home/ana/Downloads", downloadsFromUserDirs(&b, pt, "/home/ana").?);
    try testing.expectEqualStrings("/home/ana/Baixados", downloadsFromUserDirs(&b, "XDG_DOWNLOAD_DIR=\"$HOME/Baixados/\"", "/home/ana/").?);
    try testing.expectEqualStrings("/mnt/dados/dl", downloadsFromUserDirs(&b, "  XDG_DOWNLOAD_DIR=\"/mnt/dados/dl\"\r\n", "/home/ana").?);
    // $HOME sozinho: a pasta foi desligada e vale a própria pasta pessoal.
    try testing.expectEqualStrings("/home/ana", downloadsFromUserDirs(&b, "XDG_DOWNLOAD_DIR=\"$HOME/\"", "/home/ana").?);
    try testing.expect(downloadsFromUserDirs(&b, "XDG_DOWNLOAD_DIR=\"Downloads\"", "/home/ana") == null);
    try testing.expect(downloadsFromUserDirs(&b, "XDG_DOWNLOAD_DIR=\"$HOMEX/a\"", "/home/ana") == null);
    try testing.expect(downloadsFromUserDirs(&b, "XDG_MUSIC_DIR=\"$HOME/Música\"", "/home/ana") == null);
    try testing.expect(downloadsFromUserDirs(&b, "#XDG_DOWNLOAD_DIR=\"$HOME/x\"", "/home/ana") == null);
}

test "original de um anexo: o arquivo, nunca a prévia reduzida" {
    var b: PickBuf = .{};
    // Imagem pelo proxy -> a mesma no CDN, com a assinatura.
    const img: types.Attachment = .{ .url = "https://media.discordapp.net/attachments/1/2/foto.png?ex=a&is=b&hm=c", .filename = "foto.png", .width = 800, .height = 600 };
    var p = ofAttachment(&b, &img);
    try testing.expectEqualStrings("https://cdn.discordapp.com/attachments/1/2/foto.png?ex=a&is=b&hm=c", p.url);
    try testing.expectEqualStrings("foto.png", p.name);
    // Vídeo: o link, não o quadro.
    const vid: types.Attachment = .{ .url = "https://media.discordapp.net/attachments/1/3/v.mp4", .filename = "v.mp4", .width = 320, .height = 180, .video = true, .link = "https://cdn.discordapp.com/attachments/1/3/v.mp4?ex=1" };
    p = ofAttachment(&b, &vid);
    try testing.expectEqualStrings("https://cdn.discordapp.com/attachments/1/3/v.mp4?ex=1", p.url);
    // GIF do Tenor: o .gif de verdade, com a miniatura do proxy de reserva e o nome em .gif.
    const tenor: types.Attachment = .{ .url = "https://media.tenor.com/H5y5Fk9VdKcAAAAx/cat-dance.webp", .filename = "Cat Dance GIF", .width = 498, .height = 280, .animated = true, .embed = true, .still = "https://images-ext-1.discordapp.net/external/x/https/media.tenor.com/a.png" };
    p = ofAttachment(&b, &tenor);
    try testing.expectEqualStrings("https://media.tenor.com/H5y5Fk9VdKcAAAAC/cat-dance.gif", p.url);
    try testing.expectEqualStrings("Cat Dance GIF.gif", p.name);
    try testing.expect(p.gif_host);
    try testing.expectEqualStrings(tenor.still, p.fallback);
    // Giphy.
    var b2: PickBuf = .{};
    const giphy: types.Attachment = .{ .url = "https://media.giphy.com/media/abc/giphy.webp", .filename = "x.webp", .width = 1, .height = 1, .embed = true, .animated = true };
    try testing.expectEqualStrings("https://media.giphy.com/media/abc/giphy.gif", ofAttachment(&b2, &giphy).url);
    try testing.expectEqualStrings("x.gif", ofAttachment(&b2, &giphy).name);
    // Tenor antigo: a página.
    const old: types.Attachment = .{ .url = "tenor-page:https://tenor.com/view/x-123", .filename = "GIF", .width = 1, .height = 1, .embed = true, .animated = true, .still = "https://images-ext-1.discordapp.net/a.png" };
    p = ofAttachment(&b, &old);
    try testing.expect(p.page);
    try testing.expectEqualStrings("https://tenor.com/view/x-123", p.url);
    try testing.expectEqualStrings("GIF.mp4", p.name);
    // Imagem de link pelo proxy: o endereço sem tamanho já é o original; o nome ganha a extensão.
    const ext: types.Attachment = .{ .url = "https://images-ext-1.discordapp.net/external/h/https/i.imgur.com/abc.jpeg", .filename = "imagem", .width = 1, .height = 1, .embed = true };
    p = ofAttachment(&b, &ext);
    try testing.expectEqualStrings(ext.url, p.url);
    try testing.expectEqualStrings("imagem.jpeg", p.name);
    // Arquivo comum e GIF anexado: já estão no CDN.
    const file: types.Attachment = .{ .url = "https://cdn.discordapp.com/attachments/1/4/notas.txt", .filename = "notas.txt" };
    try testing.expectEqualStrings(file.url, ofAttachment(&b, &file).url);
    // Demonstração: gerada aqui, com a extensão do que sai.
    const demo: types.Attachment = .{ .url = "demo:3", .filename = "foto", .width = 960, .height = 540 };
    try testing.expectEqualStrings("foto.png", ofAttachment(&b, &demo).name);
}

test "original de um cartão e dos componentes" {
    var b: PickBuf = .{};
    const e: types.Embed = .{ .image = "https://images-ext-2.discordapp.net/external/q/https/site.com/capa.webp", .video_url = "https://images-ext-2.discordapp.net/external/r/https/site.com/v.mp4" };
    try testing.expectEqualStrings("capa.webp", ofEmbedImage(&b, &e).name);
    try testing.expectEqualStrings(e.image, ofEmbedImage(&b, &e).url);
    try testing.expectEqualStrings("v.mp4", ofEmbedVideo(&b, &e).name);
    const it: types.EmbedMedia = .{ .url = "https://media.discordapp.net/attachments/9/8/g.png?ex=1", .link = "https://cdn.discordapp.com/attachments/9/8/g.png?ex=1", .w = 10, .h = 10 };
    try testing.expectEqualStrings(it.link, ofBlockMedia(&b, &it).url);
    try testing.expectEqualStrings("g.png", ofBlockMedia(&b, &it).name);
    const proxied: types.EmbedMedia = .{ .url = "https://media.discordapp.net/attachments/9/8/h.png?ex=1" };
    try testing.expectEqualStrings("https://cdn.discordapp.com/attachments/9/8/h.png?ex=1", ofBlockMedia(&b, &proxied).url);
}

test "nunca a API do Discord" {
    try testing.expect(safeMediaUrl("https://cdn.discordapp.com/attachments/1/2/a.png"));
    try testing.expect(safeMediaUrl("https://media.discordapp.net/attachments/1/2/a.png"));
    try testing.expect(safeMediaUrl("https://images-ext-1.discordapp.net/external/x/https/a.com/b.png"));
    try testing.expect(!safeMediaUrl("https://discord.com/api/v9/channels/1/messages"));
    try testing.expect(!safeMediaUrl("https://canary.discordapp.com/api/v9/users/@me"));
    try testing.expect(!safeMediaUrl("https://cdn.discordapp.com/api/v9/x"));
    try testing.expect(!safeMediaUrl("https://discordapp.com/api/users/@me"));
    try testing.expect(!safeMediaUrl("http://cdn.discordapp.com/a.png"));
    try testing.expect(!safeMediaUrl("https://evil.com/cdn.discordapp.com/a.png"));
    try testing.expect(!safeMediaUrl("https://cdn.discordapp.com"));
}
