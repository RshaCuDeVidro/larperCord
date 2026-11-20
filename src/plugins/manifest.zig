//! O cabeçalho de um plugin: nome, descrição, versão e o que ele pede. Fica nos
//! comentários do começo do arquivo e é lido aqui, sem rodar Lua: a página de
//! configurações mostra tudo isso com o plugin desligado (e com ele desligado
//! não existe nenhum estado de Lua).
//!
//!     -- @name Bookmarks
//!     -- @name:pt Favoritos
//!     -- @description Save messages and find them later.
//!     -- @description:pt Guarde mensagens e ache depois.
//!     -- @name:ja ブックマーク
//!     -- @version 1.0.0
//!     -- @capabilities menu, panel, storage, http
//!     -- @hosts api.exemplo.com, *.cdn.exemplo.com
//!     -- @credentials api.exemplo.com
//!
//! `@name:<código>` e `@description:<código>` valem para qualquer idioma (pt, ja,
//! pt-BR…); o sem código é o de reserva (ver loc.zig). `@credentials` diz para quais
//! dos hosts o plugin pode mandar Authorization ou X-API-Key: o cartão avisa antes de
//! a pessoa aprovar.
//!
//! Arquivo sem nenhuma diretiva é um plugin antigo: continua funcionando com a
//! API de antes (mensagens, comandos, envio, avisos e LSP) e as novas dão um
//! erro que explica o que acrescentar.
const std = @import("std");
const loc = @import("loc.zig");
const http_policy = @import("http_policy.zig");

pub const Cap = enum(u5) {
    messages,
    send,
    notify,
    storage,
    timers,
    panel,
    menu,
    decorate,
    composer,
    http,
    lsp,
    settings,
    completions,
    rewrite,
    links,
    secrets,
    actions,
};

pub const max_hosts = 8;
/// Idiomas de `@name:` e de `@description:`, cada um.
pub const max_locales = 12;
const max_name = 48;
const max_desc = 320;
const max_version = 16;
/// Até onde o cabeçalho pode ir (um comentário gigante não vira trabalho).
const max_lines = 80;

fn bit(cap: Cap) u32 {
    return @as(u32, 1) << @backingInt(cap);
}

/// O que um arquivo sem cabeçalho sempre pôde fazer.
const legacy_caps: u32 = bit(.messages) | bit(.send) | bit(.notify) | bit(.lsp);

pub const Problem = union(enum) {
    none,
    unknown_cap: []const u8,
    bad_host: []const u8,
    discord_host: []const u8,
    /// `*.com`, `*.br`: um domínio inteiro de primeiro nível.
    wildcard_tld: []const u8,
    /// `*.github.io` e afins (http_policy.shared_suffixes).
    wildcard_shared: []const u8,
    too_many_hosts,
    http_without_hosts,
    hosts_without_http,
    /// Um host de `@credentials` que não está em `@hosts`.
    credentials_undeclared: []const u8,
};

/// Um `@name:<código>` ou `@description:<código>` (aponta para o fonte).
pub const Localized = struct { code: []const u8, text: []const u8 };

pub const Manifest = struct {
    /// Sem nenhuma diretiva: plugin de antes do cabeçalho.
    legacy: bool = true,
    /// O `@name` e a `@description` sem código: os de reserva.
    name: []const u8 = "",
    description: []const u8 = "",
    names: [max_locales]Localized = undefined,
    n_names: u8 = 0,
    descs: [max_locales]Localized = undefined,
    n_descs: u8 = 0,
    version: []const u8 = "",
    caps: u32 = legacy_caps,
    /// Nomes exatos ou `*.exemplo.com` (http_policy.zig).
    hosts: [max_hosts][]const u8 = undefined,
    n_hosts: u8 = 0,
    /// Os de `@hosts` que podem receber Authorization e X-API-Key.
    creds: [max_hosts][]const u8 = undefined,
    n_creds: u8 = 0,
    problem: Problem = .none,

    pub fn has(m: *const Manifest, cap: Cap) bool {
        return m.caps & bit(cap) != 0;
    }

    pub fn hostList(m: *const Manifest) []const []const u8 {
        return m.hosts[0..m.n_hosts];
    }

    pub fn credList(m: *const Manifest) []const []const u8 {
        return m.creds[0..m.n_creds];
    }

    /// Algum item de `@hosts` vale para este host (nome exato ou curinga).
    pub fn declares(m: *const Manifest, host: []const u8) bool {
        return http_policy.anyMatches(m.hostList(), host);
    }

    /// O item exato de `@hosts` (a aprovação é por item: `*.exemplo.com` inteiro).
    pub fn declaresPattern(m: *const Manifest, pattern: []const u8) bool {
        for (m.hostList()) |h| if (std.ascii.eqlIgnoreCase(h, pattern)) return true;
        return false;
    }

    /// O plugin pode mandar credenciais para este host (se a pessoa aprovar).
    pub fn sendsCredentials(m: *const Manifest, host: []const u8) bool {
        return http_policy.anyMatches(m.credList(), host);
    }

    /// O item de `@hosts` leva credenciais.
    pub fn credentialPattern(m: *const Manifest, pattern: []const u8) bool {
        for (m.credList()) |h| if (std.ascii.eqlIgnoreCase(h, pattern)) return true;
        return false;
    }

    /// Nome no idioma da interface (`ui` como "pt", "ja", "pt-BR"); sem nenhum, o
    /// nome do arquivo.
    pub fn title(m: *const Manifest, ui: []const u8, fallback: []const u8) []const u8 {
        const t = pickText(m.name, m.names[0..m.n_names], ui);
        return if (t.len > 0) t else fallback;
    }

    pub fn about(m: *const Manifest, ui: []const u8) []const u8 {
        return pickText(m.description, m.descs[0..m.n_descs], ui);
    }

    /// O texto de um idioma que veio escrito com o código dele (null = não tem).
    pub fn nameIn(m: *const Manifest, code: []const u8) ?[]const u8 {
        for (m.names[0..m.n_names]) |l| if (std.ascii.eqlIgnoreCase(l.code, code)) return l.text;
        return null;
    }

    pub fn descriptionIn(m: *const Manifest, code: []const u8) ?[]const u8 {
        for (m.descs[0..m.n_descs]) |l| if (std.ascii.eqlIgnoreCase(l.code, code)) return l.text;
        return null;
    }

    /// O problema do cabeçalho, já em texto (null = nenhum).
    pub fn problemText(m: *const Manifest, buf: []u8, en: bool) ?[]const u8 {
        return switch (m.problem) {
            .none => null,
            .unknown_cap => |s| (if (en) std.fmt.bufPrint(buf, "manifest: unknown capability \"{s}\"", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: capacidade desconhecida \"{s}\"", .{s})) catch "manifest",
            .bad_host => |s| (if (en) std.fmt.bufPrint(buf, "manifest: invalid host \"{s}\" (just the name, like api.example.com: no IP address, no https:// and no port)", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: host inválido \"{s}\" (só o nome, como api.exemplo.com: sem endereço IP, https:// nem porta)", .{s})) catch "manifest",
            .discord_host => |s| (if (en) std.fmt.bufPrint(buf, "manifest: \"{s}\" is Discord; plugins can't talk to Discord directly", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: \"{s}\" é o Discord; plugins não falam direto com o Discord", .{s})) catch "manifest",
            .wildcard_tld => |s| (if (en) std.fmt.bufPrint(buf, "manifest: \"{s}\" would approve a whole top-level domain; use *.example.com", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: \"{s}\" aprovaria um domínio de primeiro nível inteiro; use *.exemplo.com", .{s})) catch "manifest",
            .wildcard_shared => |s| (if (en) std.fmt.bufPrint(buf, "manifest: \"{s}\" is shared hosting (each subdomain belongs to someone else); list the exact host", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: \"{s}\" é hospedagem compartilhada (cada subdomínio é de alguém); declare o host exato", .{s})) catch "manifest",
            .credentials_undeclared => |s| (if (en) std.fmt.bufPrint(buf, "manifest: \"{s}\" is in @credentials but not in @hosts", .{s}) else std.fmt.bufPrint(buf, "cabeçalho: \"{s}\" está em @credentials mas não em @hosts", .{s})) catch "manifest",
            .too_many_hosts => if (en) "manifest: at most 8 hosts" else "cabeçalho: no máximo 8 hosts",
            .http_without_hosts => if (en) "manifest: the http capability needs @hosts" else "cabeçalho: a capacidade http pede @hosts",
            .hosts_without_http => if (en) "manifest: @hosts needs the http capability" else "cabeçalho: @hosts pede a capacidade http",
        };
    }
};

fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn firstProblem(m: *Manifest, p: Problem) void {
    if (m.problem == .none) m.problem = p;
}

/// Lê o cabeçalho (as fatias apontam para `src`). Nunca falha: o que estiver
/// errado fica em `problem`, e o plugin não liga até a pessoa corrigir.
pub fn parse(src: []const u8) Manifest {
    var m: Manifest = .{};
    var body = src;
    // Marca de ordem de bytes que alguns editores põem no Windows.
    if (std.mem.startsWith(u8, body, "\xEF\xBB\xBF")) body = body[3..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        seen += 1;
        if (seen > max_lines) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "--")) break;
        const text = std.mem.trimStart(u8, line[2..], " \t");
        if (text.len == 0 or text[0] != '@') continue;
        const sp = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const key = text[1..sp];
        const value = std.mem.trim(u8, text[sp..], " \t");
        directive(&m, key, value);
    }
    if (m.legacy) return m;
    if (m.has(.http) and m.n_hosts == 0) firstProblem(&m, .http_without_hosts);
    if (!m.has(.http) and m.n_hosts > 0) firstProblem(&m, .hosts_without_http);
    for (m.credList()) |cr| {
        if (!m.declaresPattern(cr)) firstProblem(&m, .{ .credentials_undeclared = cr });
    }
    return m;
}

/// O texto para a interface em `ui`: o código exato, o idioma base, o inglês, o sem
/// código e, sem nada disso, o primeiro que veio (loc.pick).
fn pickText(default: []const u8, list: []const Localized, ui: []const u8) []const u8 {
    var codes: [max_locales + 1][]const u8 = undefined;
    var texts: [max_locales + 1][]const u8 = undefined;
    var n: usize = 0;
    if (default.len > 0) {
        codes[0] = "";
        texts[0] = default;
        n = 1;
    }
    for (list) |l| {
        codes[n] = l.code;
        texts[n] = l.text;
        n += 1;
    }
    const i = loc.pick(ui, codes[0..n]) orelse return "";
    return texts[i];
}

/// `@name:ja` -> .{ "name", "ja" }; sem ":" o código é "".
fn splitKey(key: []const u8) struct { []const u8, []const u8 } {
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return .{ key, "" };
    return .{ key[0..colon], key[colon + 1 ..] };
}

fn addLocalized(list: []Localized, n: *u8, code: []const u8, text: []const u8) void {
    for (list[0..n.*]) |*l| if (std.ascii.eqlIgnoreCase(l.code, code)) {
        l.text = text;
        return;
    };
    if (n.* == list.len) return;
    list[n.*] = .{ .code = code, .text = text };
    n.* += 1;
}

/// Um item de `@hosts` (ou de `@credentials`): a lista e o problema, se tiver.
fn hostItem(m: *Manifest, h: []const u8) bool {
    switch (http_policy.checkPattern(h)) {
        .ok => return true,
        .discord => firstProblem(m, .{ .discord_host = h }),
        .bare_tld => firstProblem(m, .{ .wildcard_tld = h }),
        .shared => firstProblem(m, .{ .wildcard_shared = h }),
        .bad => firstProblem(m, .{ .bad_host = h }),
    }
    return false;
}

fn directive(m: *Manifest, key: []const u8, value: []const u8) void {
    const eql = std.mem.eql;
    const field, const code = splitKey(key);
    if (code.len > 0 and (eql(u8, field, "name") or eql(u8, field, "description"))) {
        // Código que não é de idioma: fica de fora, como uma diretiva desconhecida.
        if (!loc.validCode(code)) return;
        if (eql(u8, field, "name")) addLocalized(&m.names, &m.n_names, code, clip(value, max_name)) else addLocalized(&m.descs, &m.n_descs, code, clip(value, max_desc));
    } else if (eql(u8, key, "name")) {
        m.name = clip(value, max_name);
    } else if (eql(u8, key, "description")) {
        m.description = clip(value, max_desc);
    } else if (eql(u8, key, "version")) {
        m.version = clip(value, max_version);
    } else if (eql(u8, key, "capabilities")) {
        m.caps = 0;
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |word| {
            if (std.meta.stringToEnum(Cap, word)) |cap| {
                m.caps |= bit(cap);
            } else firstProblem(m, .{ .unknown_cap = word });
        }
    } else if (eql(u8, key, "hosts")) {
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |h| {
            if (m.n_hosts == max_hosts) {
                firstProblem(m, .too_many_hosts);
                break;
            }
            if (hostItem(m, h)) {
                m.hosts[m.n_hosts] = h;
                m.n_hosts += 1;
            }
        }
    } else if (eql(u8, key, "credentials")) {
        var it = std.mem.tokenizeAny(u8, value, ", \t");
        while (it.next()) |h| {
            if (m.n_creds == max_hosts) {
                firstProblem(m, .too_many_hosts);
                break;
            }
            if (hostItem(m, h)) {
                m.creds[m.n_creds] = h;
                m.n_creds += 1;
            }
        }
    } else return;
    // Primeira diretiva conhecida: a partir daqui as capacidades são só as pedidas.
    if (m.legacy) {
        m.legacy = false;
        if (!eql(u8, key, "capabilities")) m.caps = 0;
    }
}

/// Um nome de verdade: nada de IP (a rede local fica de fora), porta ou caminho.
pub fn validHost(h: []const u8) bool {
    if (h.len < 4 or h.len > 96 or h[0] == '.' or h[0] == '-' or h[h.len - 1] == '.') return false;
    var dot = false;
    var letter = false;
    for (h) |ch| {
        if (ch == '.') {
            dot = true;
        } else if (std.ascii.isAlphabetic(ch)) {
            letter = true;
        } else if (!std.ascii.isDigit(ch) and ch != '-') return false;
    }
    if (!dot or !letter) return false;
    if (std.ascii.endsWithIgnoreCase(h, ".local") or std.ascii.endsWithIgnoreCase(h, ".localhost")) return false;
    return !allDigitsLast(h);
}

/// `1.2.3.4` e afins: o último pedaço de um nome de verdade nunca é só número.
fn allDigitsLast(h: []const u8) bool {
    const at = std.mem.lastIndexOfScalar(u8, h, '.') orelse return false;
    for (h[at + 1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// O Discord e os domínios dele: nem com a aprovação da pessoa.
pub fn isDiscord(h: []const u8) bool {
    const family = [_][]const u8{ "discord.com", "discordapp.com", "discord.gg", "discordapp.net", "discord.media", "discordcdn.com", "discordstatus.com", "discord.gift", "discord.new", "discord.co", "discord.dev", "dis.gd" };
    for (family) |f| {
        if (std.ascii.eqlIgnoreCase(h, f)) return true;
        if (h.len > f.len and h[h.len - f.len - 1] == '.' and std.ascii.endsWithIgnoreCase(h, f)) return true;
    }
    return false;
}

pub const Url = struct { host: []const u8, rest: []const u8 };

/// `https://nome/caminho?busca`, sem usuário, sem porta e sem espaços nem
/// caracteres de controle (quem chama codifica o texto: larper.urlencode).
pub fn parseHttps(url: []const u8) ?Url {
    const scheme = "https://";
    if (url.len > 2048 or url.len <= scheme.len) return null;
    if (!std.ascii.startsWithIgnoreCase(url, scheme)) return null;
    for (url) |ch| if (ch <= 0x20 or ch >= 0x7F) return null;
    const after = url[scheme.len..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    const host = after[0..end];
    if (!validHost(host)) return null;
    if (end < after.len and after[end] == '#') return null;
    return .{ .host = host, .rest = after[end..] };
}

test "cabeçalho completo nos dois idiomas" {
    const m = parse(
        \\-- bookmarks: comentário solto vale
        \\-- @name Bookmarks
        \\-- @name:pt Favoritos
        \\-- @description Save messages.
        \\-- @description:pt Guarde mensagens.
        \\-- @version 1.2.0
        \\-- @capabilities menu, panel storage
        \\
        \\-- @hosts ignorado.com
        \\larper.notify("oi")
        \\-- @name Depois do código não vale
    );
    try std.testing.expect(!m.legacy);
    try std.testing.expectEqualStrings("Favoritos", m.title("pt", "x.lua"));
    try std.testing.expectEqualStrings("Bookmarks", m.title("en", "x.lua"));
    try std.testing.expectEqualStrings("Guarde mensagens.", m.about("pt"));
    try std.testing.expectEqualStrings("Save messages.", m.about("en"));
    // Japonês e russo não vieram: o inglês, nunca o português.
    try std.testing.expectEqualStrings("Bookmarks", m.title("ja", "x.lua"));
    try std.testing.expectEqualStrings("Save messages.", m.about("ru"));
    try std.testing.expectEqualStrings("1.2.0", m.version);
    try std.testing.expect(m.has(.menu) and m.has(.panel) and m.has(.storage));
    try std.testing.expect(!m.has(.send) and !m.has(.messages));
    // "@hosts" ainda está no bloco de comentários, mas pede http.
    try std.testing.expectEqual(Problem.hosts_without_http, m.problem);
}

test "sem cabeçalho é plugin antigo, com a API de antes" {
    const m = parse("-- só um comentário\nlarper.notify('oi')\n-- @name tarde demais");
    try std.testing.expect(m.legacy);
    try std.testing.expect(m.has(.messages) and m.has(.send) and m.has(.notify) and m.has(.lsp));
    try std.testing.expect(!m.has(.storage) and !m.has(.http) and !m.has(.panel));
    try std.testing.expectEqualStrings("shrug.lua", m.title("en", "shrug.lua"));
}

test "cabeçalho sem capacidades não herda a API antiga" {
    const m = parse("-- @name Só comandos\n");
    try std.testing.expect(!m.legacy);
    try std.testing.expectEqual(@as(u32, 0), m.caps);
    try std.testing.expectEqual(Problem.none, m.problem);
}

test "problemas do cabeçalho viram explicação" {
    var buf: [200]u8 = undefined;
    const a = parse("-- @name x\n-- @capabilities voar\n");
    try std.testing.expectEqualStrings("voar", a.problem.unknown_cap);
    try std.testing.expect(std.mem.indexOf(u8, a.problemText(&buf, false).?, "voar") != null);
    try std.testing.expect(parse("-- @capabilities http\n").problem == .http_without_hosts);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts discord.com\n").problem == .discord_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts cdn.discordapp.com\n").problem == .discord_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts 127.0.0.1\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts localhost\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts https://a.com\n").problem == .bad_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts a.com:8443\n").problem == .bad_host);
    const ok = parse("-- @capabilities http\n-- @hosts a.com, api.b-c.org\n");
    try std.testing.expectEqual(Problem.none, ok.problem);
    try std.testing.expect(ok.declares("API.B-C.org"));
    try std.testing.expect(!ok.declares("c.org"));
}

test "URL: só https, sem usuário, porta ou caracteres soltos" {
    const u = parseHttps("https://api.a.com/get?q=oi%20gente").?;
    try std.testing.expectEqualStrings("api.a.com", u.host);
    try std.testing.expectEqualStrings("/get?q=oi%20gente", u.rest);
    try std.testing.expectEqualStrings("", parseHttps("https://a.com").?.rest);
    for ([_][]const u8{
        "http://a.com/",
        "ftp://a.com/",
        "https://",
        "https://user:pw@a.com/",
        "https://a.com:8443/",
        "https://1.2.3.4/",
        "https://a.com/com espaço",
        "https://a.com/\r\nCookie: x",
        "https://a.com/ç",
    }) |bad| try std.testing.expect(parseHttps(bad) == null);
    try std.testing.expect(isDiscord("discord.com") and isDiscord("gateway.discord.gg") and !isDiscord("notdiscord.com"));
}

test "cabeçalho: nome e descrição em qualquer idioma, com o inglês de reserva" {
    const m = parse(
        \\-- @name Bookmarks
        \\-- @name:pt-BR Favoritos
        \\-- @name:ja ブックマーク
        \\-- @name:ru Закладки
        \\-- @name:valor Não é idioma
        \\-- @description:ja メッセージを保存。
        \\-- @description:en Save messages.
        \\-- @capabilities secrets, actions
    );
    try std.testing.expectEqual(Problem.none, m.problem);
    try std.testing.expect(m.has(.secrets) and m.has(.actions));
    try std.testing.expectEqualStrings("ブックマーク", m.title("ja", "x.lua"));
    try std.testing.expectEqualStrings("Закладки", m.title("ru", "x.lua"));
    // pt-BR serve para o português da interface.
    try std.testing.expectEqualStrings("Favoritos", m.title("pt", "x.lua"));
    try std.testing.expectEqualStrings("Bookmarks", m.title("en", "x.lua"));
    try std.testing.expectEqualStrings("Bookmarks", m.title("de", "x.lua"));
    try std.testing.expectEqual(@as(u8, 3), m.n_names);
    try std.testing.expectEqualStrings("メッセージを保存。", m.about("ja"));
    try std.testing.expectEqualStrings("Save messages.", m.about("pt"));
    try std.testing.expectEqualStrings("Favoritos", m.nameIn("pt-br").?);
    try std.testing.expect(m.nameIn("pt") == null);
    // Só nomes com código, sem o de reserva: o inglês, e sem ele o primeiro.
    const only = parse("-- @name:pt Só português\n-- @name:es Solo español\n");
    try std.testing.expectEqualStrings("Só português", only.title("ja", "x.lua"));
    try std.testing.expectEqualStrings("Solo español", only.title("es", "x.lua"));
}

test "cabeçalho: curingas, hospedagem compartilhada e credenciais" {
    const ok = parse("-- @capabilities http\n-- @hosts api.a.com, *.cdn.b.org\n-- @credentials api.a.com\n");
    try std.testing.expectEqual(Problem.none, ok.problem);
    try std.testing.expect(ok.declares("x.cdn.b.org") and ok.declares("api.a.com"));
    try std.testing.expect(!ok.declares("cdn.b.org") and !ok.declares("b.org"));
    try std.testing.expect(ok.declaresPattern("*.cdn.b.org") and !ok.declaresPattern("x.cdn.b.org"));
    try std.testing.expect(ok.sendsCredentials("api.a.com") and !ok.sendsCredentials("x.cdn.b.org"));
    try std.testing.expect(ok.credentialPattern("api.a.com"));
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts *.com\n").problem == .wildcard_tld);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts *.github.io\n").problem == .wildcard_shared);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts *.discord.com\n").problem == .discord_host);
    try std.testing.expect(parse("-- @capabilities http\n-- @hosts a.com\n-- @credentials b.com\n").problem == .credentials_undeclared);
    // Credencial com curinga vale se o mesmo curinga está em @hosts.
    try std.testing.expectEqual(Problem.none, parse("-- @capabilities http\n-- @hosts *.a.com\n-- @credentials *.a.com\n").problem);
    var buf: [200]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, parse("-- @capabilities http\n-- @hosts *.vercel.app\n").problemText(&buf, true).?, "shared") != null);
}
