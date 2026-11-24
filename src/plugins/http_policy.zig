//! O que o HTTP dos plugins aceita, num lugar só (o cabeçalho, a thread dos plugins e a
//! thread do pedido usam as mesmas regras):
//! - hosts: o nome exato ou `*.exemplo.com` (os subdomínios de um domínio). Nunca o
//!   Discord, nunca um sufixo público (`*.com`, `*.co.uk`) e nunca um domínio de
//!   hospedagem compartilhada, onde cada subdomínio é de um dono (`*.github.io`
//!   aprovaria o site de qualquer pessoa);
//! - redirecionamentos: só para um host aprovado, só HTTPS e no máximo 5;
//! - cabeçalhos: os que o plugin pode mandar (credenciais só para os hosts de
//!   `@credentials`) e os da resposta que ele pode ler (nunca Set-Cookie).
const std = @import("std");
const manifest = @import("manifest.zig");

/// Domínios em que cada subdomínio é de um dono diferente: um curinga neles, ou acima
/// deles, aprovaria gente que a pessoa nunca viu. `*.fulano.github.io` (o site de uma
/// pessoa só) continua valendo.
pub const shared_suffixes = [_][]const u8{
    // Sufixos públicos de mais de um pedaço (os de um pedaço só, como `*.com`, já são recusados).
    "co.uk",                 "org.uk",             "ac.uk",          "gov.uk",            "me.uk",               "ltd.uk",
    "plc.uk",                "net.uk",             "com.br",         "net.br",            "org.br",              "gov.br",
    "edu.br",                "com.au",             "net.au",         "org.au",            "edu.au",              "gov.au",
    "co.jp",                 "ne.jp",              "or.jp",          "ac.jp",             "go.jp",               "co.nz",
    "co.za",                 "co.in",              "co.kr",          "co.id",             "com.cn",              "com.tw",
    "com.hk",                "com.mx",             "com.ar",         "com.tr",            "com.ru",              "com.ua",
    "com.pl",                "com.sg",             "com.my",         "com.ph",            "com.vn",              "com.pt",
    "com.es",                "com.co",             "com.pe",         "com.eg",            "com.sa",              "com.pk",
    "com.ng",                "eu.org",             "us.com",         "uk.com",            "eu.com",
    // Hospedagem compartilhada e endereços que qualquer um cria.
                 "github.io",
    "githubusercontent.com", "gitlab.io",          "bitbucket.io",   "codeberg.page",     "vercel.app",          "now.sh",
    "netlify.app",           "netlify.com",        "pages.dev",      "workers.dev",       "herokuapp.com",       "herokudns.com",
    "glitch.me",             "repl.co",            "replit.dev",     "replit.app",        "web.app",             "firebaseapp.com",
    "appspot.com",           "cloudfunctions.net", "run.app",        "azurewebsites.net", "azurestaticapps.net", "cloudapp.net",
    "windows.net",           "trafficmanager.net", "cloudfront.net", "s3.amazonaws.com",  "amazonaws.com",       "elasticbeanstalk.com",
    "onrender.com",          "fly.dev",            "railway.app",    "deno.dev",          "surge.sh",            "neocities.org",
    "wordpress.com",         "blogspot.com",       "tumblr.com",     "wixsite.com",       "weebly.com",          "squarespace.com",
    "webflow.io",            "ngrok.io",           "ngrok-free.app", "ngrok.app",         "trycloudflare.com",   "loca.lt",
    "duckdns.org",           "no-ip.org",          "dyndns.org",     "ddns.net",          "itch.io",             "carrd.co",
    "notion.site",           "readthedocs.io",     "gitbook.io",     "sourceforge.net",   "pythonanywhere.com",  "000webhostapp.com",
    "translate.goog",
};

/// Pedidos seguidos de um redirecionamento, no máximo.
pub const max_redirects = 5;

pub fn isWildcard(pattern: []const u8) bool {
    return std.mem.startsWith(u8, pattern, "*.");
}

/// `*.exemplo.com` -> "exemplo.com"; o nome exato fica como está.
pub fn patternBase(pattern: []const u8) []const u8 {
    return if (isWildcard(pattern)) pattern[2..] else pattern;
}

pub const PatternProblem = enum { ok, bad, discord, bare_tld, shared };

/// Confere um item de `@hosts`.
pub fn checkPattern(pattern: []const u8) PatternProblem {
    const b = patternBase(pattern);
    if (std.mem.indexOfScalar(u8, b, '*') != null) return .bad;
    if (manifest.isDiscord(b)) return .discord;
    if (isWildcard(pattern) and std.mem.indexOfScalar(u8, b, '.') == null) {
        // `*.com`: validHost já recusaria um nome sem ponto.
        return .bare_tld;
    }
    if (!manifest.validHost(b)) return .bad;
    if (isWildcard(pattern) and isShared(b)) return .shared;
    return .ok;
}

/// `base` é um dos domínios compartilhados, ou fica acima de um deles.
pub fn isShared(base: []const u8) bool {
    for (shared_suffixes) |s| {
        if (std.ascii.eqlIgnoreCase(s, base)) return true;
        if (s.len > base.len and s[s.len - base.len - 1] == '.' and std.ascii.endsWithIgnoreCase(s, base)) return true;
    }
    return false;
}

/// O host cabe no item? `*.exemplo.com` vale para os subdomínios, não para o próprio
/// exemplo.com (para ele, declare os dois).
pub fn matches(pattern: []const u8, host: []const u8) bool {
    if (!isWildcard(pattern)) return std.ascii.eqlIgnoreCase(pattern, host);
    const b = pattern[2..];
    return host.len > b.len + 1 and host[host.len - b.len - 1] == '.' and std.ascii.endsWithIgnoreCase(host, b);
}

/// Algum dos itens vale para o host (e o host não é do Discord, nem por curinga).
pub fn anyMatches(patterns: []const []const u8, host: []const u8) bool {
    if (manifest.isDiscord(host)) return false;
    for (patterns) |p| if (matches(p, host)) return true;
    return false;
}

// --- Redirecionamentos --------------------------------------------------------------

/// Para onde um `Location` leva, a partir da URL de agora: absoluto, sem esquema
/// (`//host/x`), a partir da raiz (`/x`) ou relativo ao caminho. Só HTTPS; o
/// fragmento (`#…`) fica de fora. null = não dá para seguir.
pub fn resolveLocation(buf: []u8, current: []const u8, location_raw: []const u8) ?[]const u8 {
    var location = std.mem.trim(u8, location_raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, location, '#')) |cut| location = location[0..cut];
    if (location.len == 0) return null;
    const cur = manifest.parseHttps(current) orelse return null;
    const out = if (std.ascii.startsWithIgnoreCase(location, "https://"))
        std.fmt.bufPrint(buf, "{s}", .{location})
    else if (std.mem.startsWith(u8, location, "//"))
        std.fmt.bufPrint(buf, "https:{s}", .{location})
    else if (location[0] == '/')
        std.fmt.bufPrint(buf, "https://{s}{s}", .{ cur.host, location })
    else if (std.mem.indexOfScalar(u8, location, ':') != null)
        // Outro esquema (http:, ftp:, javascript:…).
        return null
    else blk: {
        // Relativo: troca o último pedaço do caminho de agora.
        const path_end = std.mem.indexOfScalar(u8, cur.rest, '?') orelse cur.rest.len;
        const path = cur.rest[0..path_end];
        const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[0 .. s + 1] else "/";
        break :blk std.fmt.bufPrint(buf, "https://{s}{s}{s}", .{ cur.host, dir, location });
    };
    const url = out catch return null;
    _ = manifest.parseHttps(url) orelse return null;
    return url;
}

pub const Hop = enum { follow, not_https, not_approved, discord };

/// Pode seguir para `url`? Só para um host que a pessoa aprovou para este plugin.
pub fn redirectAllowed(approved: []const []const u8, url: []const u8) Hop {
    const u = manifest.parseHttps(url) orelse return .not_https;
    if (manifest.isDiscord(u.host)) return .discord;
    return if (anyMatches(approved, u.host)) .follow else .not_approved;
}

pub const Method = enum(u8) {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,

    pub fn hasBody(m: Method) bool {
        return m != .GET and m != .HEAD;
    }
};

/// O método depois de um redirecionamento, como os navegadores fazem: 303 vira GET
/// (sem corpo), e 301/302 também, vindo de um POST. 307 e 308 mantêm tudo.
pub fn methodAfter(status: u16, m: Method) Method {
    if (m == .HEAD) return .HEAD;
    if (status == 303) return .GET;
    if ((status == 301 or status == 302) and m == .POST) return .GET;
    return m;
}

pub fn isRedirect(status: u16) bool {
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308;
}

// --- Cabeçalhos ---------------------------------------------------------------------

pub const HeaderKind = enum { plain, credential, refused };

/// O que o plugin pode mandar: os comuns, e as credenciais só para os hosts de
/// `@credentials` aprovados. Nada de Cookie, Host, User-Agent ou os do Discord.
pub fn requestHeader(name: []const u8) HeaderKind {
    for ([_][]const u8{ "accept", "accept-language", "content-type", "if-none-match", "if-modified-since" }) |ok| {
        if (std.ascii.eqlIgnoreCase(name, ok)) return .plain;
    }
    for ([_][]const u8{ "authorization", "x-api-key" }) |cred| {
        if (std.ascii.eqlIgnoreCase(name, cred)) return .credential;
    }
    return .refused;
}

/// Os da resposta que chegam ao plugin (em `res.headers`, com o nome em minúsculas).
/// Nunca Set-Cookie nem nada que identifique a sessão.
pub fn responseHeader(name: []const u8) bool {
    for ([_][]const u8{ "content-type", "content-length", "content-language", "etag", "last-modified", "cache-control", "expires", "age", "date", "retry-after", "location", "link", "x-total-count", "x-request-id" }) |ok| {
        if (std.ascii.eqlIgnoreCase(name, ok)) return true;
    }
    for ([_][]const u8{ "x-ratelimit-", "x-rate-limit-", "ratelimit-" }) |prefix| {
        if (name.len > prefix.len and std.ascii.startsWithIgnoreCase(name, prefix)) return true;
    }
    return false;
}

pub const max_response_headers = 24;
pub const max_header_value = 512;

/// Uma linha de cabeçalho da resposta ("Nome: valor\r\n"), se o plugin pode ler.
pub fn parseResponseLine(line: []const u8) ?struct { name: []const u8, value: []const u8 } {
    const l = std.mem.trimEnd(u8, line, "\r\n");
    const colon = std.mem.indexOfScalar(u8, l, ':') orelse return null;
    const name = std.mem.trim(u8, l[0..colon], " \t");
    if (name.len == 0 or name.len > 64 or !responseHeader(name)) return null;
    const value = std.mem.trim(u8, l[colon + 1 ..], " \t");
    if (value.len > max_header_value) return null;
    return .{ .name = name, .value = value };
}

test "hosts: exato, curinga e o que o curinga não pega" {
    try std.testing.expect(matches("api.a.com", "API.a.com"));
    try std.testing.expect(!matches("api.a.com", "x.api.a.com"));
    try std.testing.expect(matches("*.a.com", "x.a.com") and matches("*.a.com", "y.x.A.com"));
    try std.testing.expect(!matches("*.a.com", "a.com"));
    try std.testing.expect(!matches("*.a.com", "xa.com"));
    try std.testing.expect(!matches("*.a.com", "a.com.evil.org"));
    try std.testing.expect(anyMatches(&.{ "a.com", "*.b.org" }, "z.b.org"));
    try std.testing.expect(!anyMatches(&.{"*.b.org"}, "b.org"));
}

test "hosts: curinga em sufixo público, hospedagem compartilhada, TLD e Discord são recusados" {
    for ([_][]const u8{ "*.com", "*.br", "*.gg", "*.media" }) |p| try std.testing.expectEqual(PatternProblem.bare_tld, checkPattern(p));
    for ([_][]const u8{ "*.github.io", "*.vercel.app", "*.netlify.app", "*.pages.dev", "*.herokuapp.com", "*.glitch.me", "*.repl.co", "*.web.app", "*.firebaseapp.com", "*.azurewebsites.net", "*.cloudfront.net", "*.s3.amazonaws.com", "*.amazonaws.com", "*.co.uk", "*.com.br", "*.githubusercontent.com" }) |p| {
        try std.testing.expectEqual(PatternProblem.shared, checkPattern(p));
    }
    for ([_][]const u8{ "*.discord.com", "*.discordapp.net", "discord.gg", "cdn.discordapp.com", "*.discord.media", "*.discordcdn.com", "media.discordapp.net" }) |p| {
        try std.testing.expectEqual(PatternProblem.discord, checkPattern(p));
    }
    for ([_][]const u8{ "*.", "*", "a.*.com", "**.a.com", "*.1.2.3.4", "*.localhost", "*.printer.local" }) |p| {
        try std.testing.expect(checkPattern(p) != .ok);
    }
    // O site de uma pessoa só, e os nomes exatos, continuam valendo.
    for ([_][]const u8{ "*.fulano.github.io", "*.example.com", "*.api.example.co.uk", "fulano.github.io", "api.example.com", "github.io" }) |p| {
        try std.testing.expectEqual(PatternProblem.ok, checkPattern(p));
    }
    // A lista não tem nome inválido nem repetido (um erro aqui deixaria passar um curinga).
    for (shared_suffixes, 0..) |s, i| {
        try std.testing.expect(manifest.validHost(s) or std.mem.indexOfScalar(u8, s, '.') != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, s, '.') != null);
        for (shared_suffixes[i + 1 ..]) |o| try std.testing.expect(!std.ascii.eqlIgnoreCase(s, o));
    }
    // Nem por curinga um pedido chega ao Discord.
    try std.testing.expect(!anyMatches(&.{"*.com"}, "discord.com"));
    try std.testing.expect(!anyMatches(&.{"*.discordapp.net"}, "media.discordapp.net"));
}

test "redirecionamento: para onde vai, e se pode seguir" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://b.com/x", resolveLocation(&buf, "https://a.com/p/q?z=1", "https://b.com/x").?);
    try std.testing.expectEqualStrings("https://b.com/x", resolveLocation(&buf, "https://a.com/p", "//b.com/x").?);
    try std.testing.expectEqualStrings("https://a.com/raiz?k=v", resolveLocation(&buf, "https://a.com/p/q", "/raiz?k=v#frag").?);
    try std.testing.expectEqualStrings("https://a.com/p/r", resolveLocation(&buf, "https://a.com/p/q?x=1", "r").?);
    try std.testing.expectEqualStrings("https://a.com/r", resolveLocation(&buf, "https://a.com", "r").?);
    for ([_][]const u8{ "http://a.com/", "ftp://a.com/", "javascript:alert(1)", "", "https://u:p@a.com/", "https://a.com:8443/", "https://127.0.0.1/" }) |bad| {
        try std.testing.expect(resolveLocation(&buf, "https://a.com/", bad) == null);
    }
    const ok = [_][]const u8{ "a.com", "*.cdn.b.org" };
    try std.testing.expectEqual(Hop.follow, redirectAllowed(&ok, "https://a.com/x"));
    try std.testing.expectEqual(Hop.follow, redirectAllowed(&ok, "https://x.cdn.b.org/y"));
    try std.testing.expectEqual(Hop.not_approved, redirectAllowed(&ok, "https://evil.org/"));
    try std.testing.expectEqual(Hop.not_approved, redirectAllowed(&ok, "https://cdn.b.org/"));
    try std.testing.expectEqual(Hop.discord, redirectAllowed(&ok, "https://discord.com/api"));
    try std.testing.expectEqual(Hop.not_https, redirectAllowed(&ok, "http://a.com/"));
    try std.testing.expectEqual(Method.GET, methodAfter(303, .PUT));
    try std.testing.expectEqual(Method.GET, methodAfter(302, .POST));
    try std.testing.expectEqual(Method.POST, methodAfter(307, .POST));
    try std.testing.expectEqual(Method.PATCH, methodAfter(301, .PATCH));
    try std.testing.expectEqual(Method.HEAD, methodAfter(303, .HEAD));
}

test "cabeçalhos: o que o plugin manda e o que ele lê" {
    try std.testing.expectEqual(HeaderKind.plain, requestHeader("Content-Type"));
    try std.testing.expectEqual(HeaderKind.credential, requestHeader("AUTHORIZATION"));
    try std.testing.expectEqual(HeaderKind.credential, requestHeader("x-api-key"));
    for ([_][]const u8{ "Cookie", "Host", "User-Agent", "X-Super-Properties", "X-Discord-Locale", "X-Fingerprint", "Proxy-Authorization", "Referer", "Origin" }) |h| {
        try std.testing.expectEqual(HeaderKind.refused, requestHeader(h));
    }
    for ([_][]const u8{ "content-type", "ETag", "Retry-After", "Location", "Link", "x-ratelimit-remaining", "X-RateLimit-Reset", "ratelimit-limit", "x-rate-limit-reset" }) |h| {
        try std.testing.expect(responseHeader(h));
    }
    for ([_][]const u8{ "set-cookie", "Set-Cookie2", "www-authenticate", "x-ratelimit-", "server", "x-powered-by", "strict-transport-security" }) |h| {
        try std.testing.expect(!responseHeader(h));
    }
    const l = parseResponseLine("ETag: \"abc\"\r\n").?;
    try std.testing.expectEqualStrings("ETag", l.name);
    try std.testing.expectEqualStrings("\"abc\"", l.value);
    try std.testing.expect(parseResponseLine("Set-Cookie: s=1\r\n") == null);
    try std.testing.expect(parseResponseLine("HTTP/1.1 200 OK\r\n") == null);
}
