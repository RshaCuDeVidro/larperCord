//! Exportar uma conversa (as partes puras, testadas no `zig build test`): os três
//! formatos (HTML, Markdown e JSON), escritos uma mensagem por vez num `Sink`
//! (quem chama manda para o arquivo aos pedaços: a conversa inteira nunca fica
//! montada na memória), o Markdown do Discord virando HTML e as menções trocadas
//! pelos nomes.
//!
//! O que entra aqui é só o que já estava no computador (net/exportar.zig monta e
//! explica por quê): nada neste arquivo fala com rede nenhuma.
//!
//! O HTML é um arquivo só, que abre sem internet: as cores do tema da hora, as
//! fotos de perfil embutidas (quando estavam no computador) ou a inicial, e os
//! anexos como link ou, com "incluir mídia", o arquivo da pasta ao lado (quando
//! estava no computador). Nenhuma imagem de fora é carregada ao abrir (nada de
//! <img> apontando para o Discord).
//!
//! Campos do JSON (versão 1). IDs vão como texto (passam do que um número do
//! JavaScript guarda) e as horas em ISO 8601, UTC:
//!   format            "larpercord-export"
//!   version           1
//!   app               quem exportou ("larperCord 0.6.7")
//!   exported_at       quando
//!   source            "local": só o que estava neste computador
//!   conversation      { id, name, kind ("text" | "thread" | "dm" | "group"),
//!                       guild: { id, name } ou null }
//!   range             { from, to }: a primeira e a última mensagem exportadas
//!   message_count     quantas mensagens vêm em `messages`
//!   media_included    se a mídia que já estava no computador foi copiada para a
//!                     pasta ao lado (nada é baixado para exportar)
//!   messages[]        em ordem, da mais antiga para a mais nova:
//!     id, timestamp, edited, pinned, system
//!     author          { id, name, bot, avatar (caminho do arquivo, ou null) }
//!     content         o texto (Markdown do Discord) com as menções já com nome
//!     content_raw     o texto como o Discord guarda (<@id>, <#id>, <t:…>)
//!     reply_to        { id, author, excerpt } ou null (author e excerpt vazios
//!                     quando a original não estava no computador)
//!     attachments[]   { name, type ("image" | "gif" | "video" | "audio" | "file" |
//!                     "sticker"), url (o original), size, width, height, spoiler,
//!                     file (caminho na pasta ao lado, ou null) }
//!     embeds[]        { title, url, description, author, provider, footer,
//!                     color ("#rrggbb" ou null), fields[] { name, value },
//!                     image, thumbnail, video, image_file }
//!     reactions[]     { emoji, count }
const std = @import("std");
const markdown = @import("markdown.zig");

pub const Format = enum {
    html,
    markdown,
    json,

    pub fn ext(f: Format) []const u8 {
        return switch (f) {
            .html => ".html",
            .markdown => ".md",
            .json => ".json",
        };
    }
};

/// As cores do tema (0xRRGGBB) que o HTML usa.
pub const Colors = struct {
    bg: u32 = 0x313338,
    surface: u32 = 0x2b2d31,
    elevated: u32 = 0x232428,
    text: u32 = 0xdbdee1,
    muted: u32 = 0xb5bac1,
    faint: u32 = 0x949ba4,
    accent: u32 = 0x5865f2,
    link: u32 = 0x00a8fc,
    border: u32 = 0x3f4147,
    code_bg: u32 = 0x2b2d31,
    danger: u32 = 0xf23f43,
};

/// Os poucos textos que ficam dentro das mensagens (quem chama traduz).
pub const Labels = struct {
    edited: []const u8 = "(edited)",
    pinned: []const u8 = "pinned",
    reply_missing: []const u8 = "earlier message (not in this file)",
    bot: []const u8 = "BOT",
    image: []const u8 = "image",
    video: []const u8 = "video",
    spoiler: []const u8 = "spoiler",
};

/// Data e hora no fuso de quem exporta.
pub const Parts = struct { year: i32, month: u8, day: u8, hour: u8, minute: u8 };
pub const Clock = *const fn (unix: i64) Parts;

pub const Avatar = struct {
    user: u64,
    /// Embutida no HTML (data:): o arquivo e o tipo dele.
    mime: []const u8 = "",
    data: []const u8 = "",
    /// Ou um arquivo da pasta ao lado (caminho relativo).
    path: []const u8 = "",
};

pub const Conversation = struct {
    id: u64,
    name: []const u8,
    kind: []const u8 = "text",
    guild_id: u64 = 0,
    guild_name: []const u8 = "",
};

pub const Header = struct {
    /// "#geral", "Aninha".
    title: []const u8,
    /// O servidor, quantas mensagens, de quando a quando.
    subtitle: []const u8 = "",
    /// "Só as mensagens que estavam neste computador…"
    note: []const u8 = "",
    footer: []const u8 = "",
    /// Idioma do documento (lang do HTML).
    lang: []const u8 = "en",
    conversation: Conversation,
    exported_unix: i64 = 0,
    from_unix: i64 = 0,
    to_unix: i64 = 0,
    count: u32 = 0,
    media: bool = false,
    app: []const u8 = "larperCord",
    colors: Colors = .{},
    avatars: []const Avatar = &.{},
};

pub const AttKind = enum { image, gif, video, audio, file, sticker };

pub const Att = struct {
    name: []const u8,
    /// O original (o que o "salvar" também baixaria).
    url: []const u8,
    size: u32 = 0,
    w: u16 = 0,
    h: u16 = 0,
    kind: AttKind = .file,
    spoiler: bool = false,
    /// Copiado para a pasta ao lado (já estava no computador): o caminho relativo.
    /// Vazio = só o link.
    local: []const u8 = "",
};

pub const Field = struct { name: []const u8, value: []const u8 };

pub const Emb = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    provider: []const u8 = "",
    footer: []const u8 = "",
    color: ?u32 = null,
    fields: []const Field = &.{},
    image: []const u8 = "",
    thumb: []const u8 = "",
    video: []const u8 = "",
    image_local: []const u8 = "",
};

pub const React = struct { emoji: []const u8, count: u16 };

pub const Msg = struct {
    id: u64,
    unix: i64,
    author: u64,
    name: []const u8,
    bot: bool = false,
    edited: bool = false,
    pinned: bool = false,
    system: bool = false,
    /// O texto com as menções já com nome (`resolveTokens`).
    text: []const u8 = "",
    /// Como o Discord guarda.
    raw: []const u8 = "",
    reply_to: u64 = 0,
    reply_name: []const u8 = "",
    reply_text: []const u8 = "",
    atts: []const Att = &.{},
    embeds: []const Emb = &.{},
    reacts: []const React = &.{},
};

/// Para onde vão os bytes (o arquivo, aos pedaços, ou uma lista nos testes).
pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) void,

    pub fn write(s: Sink, b: []const u8) void {
        if (b.len > 0) s.writeFn(s.ctx, b);
    }

    /// Só para pedaços curtos (números, marcação): texto da conversa vai por `write`
    /// ou pelos escapes.
    pub fn print(s: Sink, comptime fmt: []const u8, args: anytype) void {
        var tmp: [1024]u8 = undefined;
        s.write(std.fmt.bufPrint(&tmp, fmt, args) catch return);
    }
};

/// Uma lista que cresce (testes e textos pequenos).
pub const ListSink = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn sink(l: *ListSink) Sink {
        return .{ .ctx = l, .writeFn = write };
    }

    fn write(ctx: *anyopaque, b: []const u8) void {
        const l: *ListSink = @ptrCast(@alignCast(ctx));
        l.list.appendSlice(l.gpa, b) catch {};
    }
};

// --- Escapes -----------------------------------------------------------------------

pub fn htmlEscape(s: Sink, text: []const u8) void {
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        const rep: ?[]const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            0...8, 11, 12, 14...31, 127 => "",
            else => null,
        };
        if (rep) |r| {
            s.write(text[start..i]);
            s.write(r);
            start = i + 1;
        }
    }
    s.write(text[start..]);
}

/// Uma string do JSON, com as aspas.
pub fn jsonString(s: Sink, text: []const u8) void {
    s.write("\"");
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        var hex: [6]u8 = undefined;
        const rep: ?[]const u8 = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31, 127 => std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch}) catch unreachable,
            else => null,
        };
        if (rep) |r| {
            s.write(text[start..i]);
            s.write(r);
            start = i + 1;
        }
    }
    s.write(text[start..]);
    s.write("\"");
}

/// Só http(s) vira link de verdade (nada de javascript: ou file:).
fn safeHref(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

/// Caminho relativo de um arquivo da pasta ao lado, num atributo: as partes com
/// espaço, # ou ? viram %xx (o navegador leria # como âncora).
fn hrefPath(s: Sink, path: []const u8) void {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        const enc = ch == ' ' or ch == '#' or ch == '?' or ch == '%' or ch == '"' or ch == '\'' or ch == '<' or ch == '>' or ch == '&';
        if (enc) {
            s.write(path[start..i]);
            s.print("%{X:0>2}", .{ch});
            start = i + 1;
        }
    }
    s.write(path[start..]);
}

// --- Horas ---------------------------------------------------------------------------

/// Data e hora em UTC (para o JSON e o `datetime` do HTML), sem depender do sistema.
pub fn utcParts(unix: i64) struct { year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8 } {
    const days = @divFloor(unix, 86400);
    const secs: u32 = @intCast(unix - days * 86400);
    // Dias desde 1970 -> data civil (Howard Hinnant).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = y, .month = m, .day = d, .hour = @intCast(secs / 3600), .minute = @intCast(secs / 60 % 60), .second = @intCast(secs % 60) };
}

pub fn isoUtc(buf: []u8, unix: i64) []const u8 {
    const p = utcParts(unix);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u64, @intCast(@max(p.year, 0))), p.month, p.day, p.hour, p.minute, p.second }) catch "";
}

/// O relógio dos testes: UTC.
pub fn utcClock(unix: i64) Parts {
    const p = utcParts(unix);
    return .{ .year = @intCast(p.year), .month = p.month, .day = p.day, .hour = p.hour, .minute = p.minute };
}

fn dayKey(p: Parts) i64 {
    return @as(i64, p.year) * 10000 + @as(i64, p.month) * 100 + p.day;
}

fn dateText(buf: []u8, p: Parts) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(p.year, 0))), p.month, p.day }) catch "";
}

fn timeText(buf: []u8, p: Parts) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ p.hour, p.minute }) catch "";
}

// --- Menções com nome ------------------------------------------------------------------

pub const Token = union(enum) {
    user: u64,
    channel: u64,
    role: u64,
    stamp: struct { unix: i64, style: u8 },
    emoji: []const u8,
};

/// Troca <@id>, <@!id>, <#id>, <@&id>, <t:…> e <:nome:id> pelo que `label` disser
/// (null deixa como está). Dentro de código (`…` e ```…```) nada muda, como na tela.
pub fn resolveTokens(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, ctx: anytype, comptime label: fn (@TypeOf(ctx), Token, []u8) ?[]const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    var lb: [256]u8 = undefined;
    while (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "```")) {
            const close = std.mem.indexOfPos(u8, text, i + 3, "```") orelse text.len - 3;
            i = @min(close + 3, text.len);
            continue;
        }
        if (rest[0] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
                i = close + 1;
                continue;
            }
        }
        if (rest[0] == '<') if (tokenAt(rest)) |t| {
            if (label(ctx, t.tok, &lb)) |rep| {
                try out.appendSlice(gpa, text[start..i]);
                try out.appendSlice(gpa, rep);
                start = i + t.len;
            }
            i += t.len;
            continue;
        };
        i += 1;
    }
    try out.appendSlice(gpa, text[start..]);
}

fn tokenAt(s: []const u8) ?struct { tok: Token, len: usize } {
    const close = std.mem.indexOfScalar(u8, s[0..@min(s.len, 120)], '>') orelse return null;
    const inner = s[1..close];
    const len = close + 1;
    const num = struct {
        fn f(t: []const u8) ?u64 {
            if (t.len == 0 or t.len > 20) return null;
            return std.fmt.parseInt(u64, t, 10) catch null;
        }
    }.f;
    if (std.mem.startsWith(u8, inner, "@&")) return .{ .tok = .{ .role = num(inner[2..]) orelse return null }, .len = len };
    if (std.mem.startsWith(u8, inner, "@!")) return .{ .tok = .{ .user = num(inner[2..]) orelse return null }, .len = len };
    if (std.mem.startsWith(u8, inner, "@")) return .{ .tok = .{ .user = num(inner[1..]) orelse return null }, .len = len };
    if (std.mem.startsWith(u8, inner, "#")) return .{ .tok = .{ .channel = num(inner[1..]) orelse return null }, .len = len };
    if (std.mem.startsWith(u8, inner, "t:")) {
        var digits = inner[2..];
        var style: u8 = 'f';
        if (digits.len >= 2 and digits[digits.len - 2] == ':') {
            style = digits[digits.len - 1];
            if (std.mem.indexOfScalar(u8, "tTdDfFR", style) == null) return null;
            digits = digits[0 .. digits.len - 2];
        }
        const unix = num(digits) orelse return null;
        if (unix > 100_000_000_000) return null;
        return .{ .tok = .{ .stamp = .{ .unix = @intCast(unix), .style = style } }, .len = len };
    }
    if (std.mem.startsWith(u8, inner, ":") or std.mem.startsWith(u8, inner, "a:")) {
        const body = if (inner[0] == 'a') inner[2..] else inner[1..];
        const colon = std.mem.indexOfScalar(u8, body, ':') orelse return null;
        if (colon == 0 or num(body[colon + 1 ..]) == null) return null;
        return .{ .tok = .{ .emoji = body[0..colon] }, .len = len };
    }
    return null;
}

// --- Markdown do Discord -> HTML --------------------------------------------------------

const Seg = struct { text: []const u8, sp: *const markdown.Span };

/// O texto de uma mensagem em HTML: uma linha por <div>, citações, títulos, listas e
/// blocos de código como o app desenha (o mesmo leitor de Markdown de ui/rich.zig).
pub fn markdownHtml(s: Sink, gpa: std.mem.Allocator, text: []const u8) void {
    const spans = markdown.parse(gpa, text) catch {
        s.write("<div class=\"ln\">");
        htmlEscape(s, text);
        s.write("</div>");
        return;
    };
    defer gpa.free(spans);
    var line: std.ArrayList(Seg) = .empty;
    defer line.deinit(gpa);
    var st: LineState = .{};
    for (spans) |*sp| {
        if (sp.flags.block) {
            if (line.items.len > 0) st.flush(s, line.items);
            line.clearRetainingCapacity();
            st.code(s, sp);
            continue;
        }
        var it = std.mem.splitScalar(u8, sp.text, '\n');
        var first = true;
        while (it.next()) |piece| {
            if (!first) {
                st.flush(s, line.items);
                line.clearRetainingCapacity();
            }
            first = false;
            if (piece.len > 0) line.append(gpa, .{ .text = piece, .sp = sp }) catch {};
        }
    }
    if (line.items.len > 0) st.flush(s, line.items);
    st.close(s);
}

const LineState = struct {
    quote: bool = false,

    fn setQuote(st: *LineState, s: Sink, on: bool) void {
        if (on == st.quote) return;
        s.write(if (on) "<blockquote>" else "</blockquote>");
        st.quote = on;
    }

    fn close(st: *LineState, s: Sink) void {
        st.setQuote(s, false);
    }

    fn code(st: *LineState, s: Sink, sp: *const markdown.Span) void {
        st.setQuote(s, false);
        s.write("<pre><code>");
        htmlEscape(s, sp.text);
        s.write("</code></pre>");
    }

    fn flush(st: *LineState, s: Sink, segs: []const Seg) void {
        const f: markdown.Flags = if (segs.len > 0) segs[0].sp.flags else .{};
        st.setQuote(s, f.quote);
        const cls: []const u8 = if (f.head == 1) "h1" else if (f.head == 2) "h2" else if (f.head == 3) "h3" else if (f.sub) "sub" else if (f.list and f.nested) "li li2" else if (f.list) "li" else "ln";
        s.print("<div class=\"{s}\">", .{cls});
        for (segs) |seg| inline_(s, seg);
        s.write("</div>");
    }
};

fn inline_(s: Sink, seg: Seg) void {
    const sp = seg.sp;
    const f = sp.flags;
    const href = if (f.link) sp.target() else "";
    const link = f.link and safeHref(href);
    if (link) {
        s.write("<a href=\"");
        htmlEscape(s, href);
        s.write("\">");
    }
    if (f.jumbo) s.write("<span class=\"jumbo\">");
    if (f.code) s.write("<code>");
    if (f.bold) s.write("<strong>");
    if (f.italic) s.write("<em>");
    if (f.strike) s.write("<s>");
    if (f.spoiler) s.write("<span class=\"spoiler\">");
    if (f.bullet) s.write("• ") else if (sp.emoji != 0) {
        s.write(":");
        htmlEscape(s, sp.emojiName());
        s.write(":");
    } else htmlEscape(s, seg.text);
    if (f.number) s.write(" ");
    if (f.spoiler) s.write("</span>");
    if (f.strike) s.write("</s>");
    if (f.italic) s.write("</em>");
    if (f.bold) s.write("</strong>");
    if (f.code) s.write("</code>");
    if (f.jumbo) s.write("</span>");
    if (link) s.write("</a>");
}

// --- Os formatos -------------------------------------------------------------------------

pub const Writer = struct {
    format: Format,
    out: Sink,
    clock: Clock,
    labels: Labels = .{},
    gpa: std.mem.Allocator,
    n: u32 = 0,
    last_author: u64 = 0,
    last_unix: i64 = 0,
    last_day: i64 = std.math.minInt(i64),
    /// As fotos de perfil (o JSON aponta para as que foram para a pasta ao lado).
    avatars: []const Avatar = &.{},

    pub fn begin(w: *Writer, h: *const Header) void {
        switch (w.format) {
            .html => w.htmlBegin(h),
            .markdown => w.mdBegin(h),
            .json => w.jsonBegin(h),
        }
    }

    pub fn message(w: *Writer, m: *const Msg) void {
        switch (w.format) {
            .html => w.htmlMessage(m),
            .markdown => w.mdMessage(m),
            .json => w.jsonMessage(m),
        }
        w.n += 1;
    }

    pub fn end(w: *Writer, h: *const Header) void {
        switch (w.format) {
            .html => {
                w.out.write("</main>\n<footer>");
                htmlEscape(w.out, h.footer);
                w.out.write("</footer>\n</body>\n</html>\n");
            },
            .markdown => {
                w.out.write("\n---\n\n*");
                mdText(w.out, h.footer);
                w.out.write("*\n");
            },
            .json => w.out.write(if (w.n > 0) "\n  ]\n}\n" else "]\n}\n"),
        }
    }

    // --- HTML ---

    fn htmlBegin(w: *Writer, h: *const Header) void {
        const s = w.out;
        s.write("<!doctype html>\n<html lang=\"");
        htmlEscape(s, h.lang);
        s.write("\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<meta name=\"generator\" content=\"");
        htmlEscape(s, h.app);
        s.write("\">\n<title>");
        htmlEscape(s, h.title);
        s.write("</title>\n<style>\n");
        const k = h.colors;
        s.print(":root{{--bg:#{x:0>6};--surface:#{x:0>6};--elevated:#{x:0>6};--text:#{x:0>6};--muted:#{x:0>6};--faint:#{x:0>6};", .{ k.bg, k.surface, k.elevated, k.text, k.muted, k.faint });
        s.print("--accent:#{x:0>6};--link:#{x:0>6};--border:#{x:0>6};--code:#{x:0>6};--danger:#{x:0>6}}}\n", .{ k.accent, k.link, k.border, k.code_bg, k.danger });
        s.write(html_style);
        // As fotos de perfil, uma vez cada (as mensagens só citam a classe).
        for (h.avatars) |av| {
            if (av.data.len == 0 and av.path.len == 0) continue;
            s.print(".u{d}{{background-image:url(\"", .{av.user});
            if (av.data.len > 0) {
                s.write("data:");
                htmlEscape(s, av.mime);
                s.write(";base64,");
                base64(s, av.data);
            } else hrefPath(s, av.path);
            s.write("\");color:transparent}\n");
        }
        s.write("</style>\n</head>\n<body>\n<header>\n<h1>");
        htmlEscape(s, h.title);
        s.write("</h1>\n");
        if (h.subtitle.len > 0) {
            s.write("<p class=\"subtitle\">");
            htmlEscape(s, h.subtitle);
            s.write("</p>\n");
        }
        if (h.note.len > 0) {
            s.write("<p class=\"note\">");
            htmlEscape(s, h.note);
            s.write("</p>\n");
        }
        s.write("</header>\n<main>\n");
    }

    fn htmlMessage(w: *Writer, m: *const Msg) void {
        const s = w.out;
        const p = w.clock(m.unix);
        const day = dayKey(p);
        var db: [32]u8 = undefined;
        if (day != w.last_day) {
            s.print("<div class=\"day\"><span>{s}</span></div>\n", .{dateText(&db, p)});
            w.last_author = 0;
        }
        // Seguidas da mesma pessoa em poucos minutos: sem foto nem nome, como no app.
        const cont = m.author == w.last_author and m.unix - w.last_unix < 7 * 60 and m.reply_to == 0 and !m.system;
        w.last_day = day;
        w.last_author = if (m.system) 0 else m.author;
        w.last_unix = m.unix;
        var tb: [16]u8 = undefined;
        var ib: [32]u8 = undefined;
        s.print("<article class=\"msg{s}{s}\" id=\"m{d}\">", .{ if (cont) " cont" else "", if (m.system) " system" else "", m.id });
        if (cont or m.system) {
            s.print("<time class=\"side\" datetime=\"{s}\">{s}</time>", .{ isoUtc(&ib, m.unix), timeText(&tb, p) });
        } else {
            // A cor do círculo sem foto sai do ID (espalhado: IDs vizinhos, cores longe).
            s.print("<div class=\"av u{d}\" style=\"background-color:hsl({d},45%,42%)\">", .{ m.author, (m.author *% 0x9E3779B97F4A7C15 >> 40) % 360 });
            htmlEscape(s, initial(m.name));
            s.write("</div>");
        }
        s.write("<div class=\"body\">");
        if (m.reply_to != 0) {
            s.print("<a class=\"reply\" href=\"#m{d}\">↪ ", .{m.reply_to});
            if (m.reply_name.len > 0) {
                s.write("<b>");
                htmlEscape(s, m.reply_name);
                s.write("</b> ");
                htmlEscape(s, m.reply_text);
            } else htmlEscape(s, w.labels.reply_missing);
            s.write("</a>");
        }
        if (!cont and !m.system) {
            s.write("<div class=\"meta\"><span class=\"name\">");
            htmlEscape(s, m.name);
            s.write("</span>");
            if (m.bot) {
                s.write("<span class=\"bot\">");
                htmlEscape(s, w.labels.bot);
                s.write("</span>");
            }
            s.print("<time datetime=\"{s}\">{s} {s}</time>", .{ isoUtc(&ib, m.unix), dateText(&db, p), timeText(&tb, p) });
            if (m.pinned) {
                s.write("<span class=\"tag\">📌 ");
                htmlEscape(s, w.labels.pinned);
                s.write("</span>");
            }
            s.write("</div>");
        }
        if (m.text.len > 0) {
            s.write("<div class=\"text\">");
            markdownHtml(s, w.gpa, m.text);
            if (m.edited) {
                s.write("<span class=\"edited\">");
                htmlEscape(s, w.labels.edited);
                s.write("</span>");
            }
            s.write("</div>");
        }
        if (m.atts.len > 0) {
            s.write("<div class=\"atts\">");
            for (m.atts) |*a| w.htmlAtt(a);
            s.write("</div>");
        }
        for (m.embeds) |*e| w.htmlEmbed(e);
        if (m.reacts.len > 0) {
            s.write("<div class=\"reacts\">");
            for (m.reacts) |r| {
                s.write("<span>");
                htmlEscape(s, r.emoji);
                s.print(" {d}</span>", .{r.count});
            }
            s.write("</div>");
        }
        s.write("</div></article>\n");
    }

    fn htmlAtt(w: *Writer, a: *const Att) void {
        const s = w.out;
        s.write(if (a.spoiler) "<div class=\"att sp\">" else "<div class=\"att\">");
        if (a.local.len > 0) {
            switch (a.kind) {
                .image, .gif, .sticker => {
                    s.write("<a href=\"");
                    hrefPath(s, a.local);
                    s.write("\"><img loading=\"lazy\" src=\"");
                    hrefPath(s, a.local);
                    s.write("\" alt=\"");
                    htmlEscape(s, a.name);
                    s.write("\"");
                    if (a.w > 0 and a.h > 0) s.print(" width=\"{d}\" height=\"{d}\"", .{ a.w, a.h });
                    s.write("></a>");
                },
                .video => {
                    s.write("<video controls preload=\"metadata\" src=\"");
                    hrefPath(s, a.local);
                    s.write("\"></video>");
                },
                .audio => {
                    s.write("<audio controls preload=\"metadata\" src=\"");
                    hrefPath(s, a.local);
                    s.write("\"></audio>");
                },
                .file => {},
            }
        }
        // O nome sempre aparece: com o arquivo ao lado, aponta para ele; sem, para o original.
        s.write("<div class=\"file\">📎 ");
        const href = if (a.local.len > 0) a.local else if (safeHref(a.url)) a.url else "";
        if (href.len > 0) {
            s.write("<a href=\"");
            if (a.local.len > 0) hrefPath(s, a.local) else htmlEscape(s, href);
            s.write("\">");
            htmlEscape(s, a.name);
            s.write("</a>");
        } else htmlEscape(s, a.name);
        if (a.size > 0) {
            var sb: [32]u8 = undefined;
            s.print(" <span class=\"size\">{s}</span>", .{sizeText(&sb, a.size)});
        }
        if (a.spoiler) {
            s.write(" <span class=\"tag\">");
            htmlEscape(s, w.labels.spoiler);
            s.write("</span>");
        }
        s.write("</div></div>");
    }

    fn htmlEmbed(w: *Writer, e: *const Emb) void {
        const s = w.out;
        if (e.color) |col| s.print("<div class=\"embed\" style=\"border-left-color:#{x:0>6}\">", .{col}) else s.write("<div class=\"embed\">");
        if (e.provider.len > 0) {
            s.write("<div class=\"provider\">");
            htmlEscape(s, e.provider);
            s.write("</div>");
        }
        if (e.author.len > 0) {
            s.write("<div class=\"eauthor\">");
            htmlEscape(s, e.author);
            s.write("</div>");
        }
        if (e.title.len > 0) {
            if (safeHref(e.url)) {
                s.write("<a class=\"etitle\" href=\"");
                htmlEscape(s, e.url);
                s.write("\">");
                htmlEscape(s, e.title);
                s.write("</a>");
            } else {
                s.write("<div class=\"etitle\">");
                htmlEscape(s, e.title);
                s.write("</div>");
            }
        }
        if (e.description.len > 0) {
            s.write("<div class=\"edesc\">");
            markdownHtml(s, w.gpa, e.description);
            s.write("</div>");
        }
        if (e.fields.len > 0) {
            s.write("<div class=\"fields\">");
            for (e.fields) |f| {
                s.write("<div class=\"field\"><div class=\"fname\">");
                htmlEscape(s, f.name);
                s.write("</div>");
                markdownHtml(s, w.gpa, f.value);
                s.write("</div>");
            }
            s.write("</div>");
        }
        if (e.image_local.len > 0) {
            s.write("<a href=\"");
            hrefPath(s, e.image_local);
            s.write("\"><img class=\"eimg\" loading=\"lazy\" src=\"");
            hrefPath(s, e.image_local);
            s.write("\" alt=\"\"></a>");
        } else if (safeHref(e.image)) {
            s.write("<div class=\"file\">🖼 <a href=\"");
            htmlEscape(s, e.image);
            s.write("\">");
            htmlEscape(s, w.labels.image);
            s.write("</a></div>");
        }
        if (safeHref(e.video)) {
            s.write("<div class=\"file\">🎬 <a href=\"");
            htmlEscape(s, e.video);
            s.write("\">");
            htmlEscape(s, w.labels.video);
            s.write("</a></div>");
        }
        if (e.footer.len > 0) {
            s.write("<div class=\"efooter\">");
            htmlEscape(s, e.footer);
            s.write("</div>");
        }
        s.write("</div>");
    }

    // --- Markdown ---

    fn mdBegin(w: *Writer, h: *const Header) void {
        const s = w.out;
        s.write("# ");
        mdText(s, h.title);
        s.write("\n\n");
        if (h.subtitle.len > 0) {
            mdText(s, h.subtitle);
            s.write("\n\n");
        }
        if (h.note.len > 0) {
            s.write("> ");
            mdText(s, h.note);
            s.write("\n\n");
        }
        s.write("---\n");
    }

    fn mdMessage(w: *Writer, m: *const Msg) void {
        const s = w.out;
        const p = w.clock(m.unix);
        const day = dayKey(p);
        var db: [32]u8 = undefined;
        var tb: [16]u8 = undefined;
        if (day != w.last_day) s.print("\n## {s}\n", .{dateText(&db, p)});
        w.last_day = day;
        s.write("\n");
        if (m.system) {
            s.print("*{s}* · ", .{timeText(&tb, p)});
            s.write(m.text);
            s.write("\n");
            return;
        }
        s.write("**");
        mdText(s, m.name);
        s.write("**");
        if (m.bot) s.print(" `{s}`", .{w.labels.bot});
        s.print(" · {s}", .{timeText(&tb, p)});
        if (m.edited) {
            s.write(" ");
            mdText(s, w.labels.edited);
        }
        if (m.pinned) {
            s.write(" · 📌 ");
            mdText(s, w.labels.pinned);
        }
        // Dois espaços: quebra de linha de verdade (sem eles o texto emenda no nome).
        s.write("  \n");
        if (m.reply_to != 0) {
            s.write("> ↪ ");
            if (m.reply_name.len > 0) {
                s.write("**");
                mdText(s, m.reply_name);
                s.write("** ");
                mdText(s, oneLine(m.reply_text));
            } else mdText(s, w.labels.reply_missing);
            s.write("\n\n");
        }
        if (m.text.len > 0) {
            // O texto já é Markdown do Discord: vai como está (só sem linha em branco no
            // fim e sem virar HTML num leitor de Markdown).
            mdContent(s, std.mem.trimEnd(u8, m.text, "\n"));
            s.write("\n");
        }
        for (m.atts) |a| {
            s.write("- 📎 [");
            mdText(s, a.name);
            s.write("](");
            if (a.local.len > 0) mdUrl(s, a.local) else mdUrl(s, a.url);
            s.write(")");
            if (a.size > 0) {
                var sb: [32]u8 = undefined;
                s.print(" · {s}", .{sizeText(&sb, a.size)});
            }
            if (a.spoiler) {
                s.write(" · ");
                mdText(s, w.labels.spoiler);
            }
            s.write("\n");
        }
        for (m.embeds) |e| {
            s.write("\n> ");
            if (e.provider.len > 0) {
                mdText(s, e.provider);
                s.write(" · ");
            }
            if (e.author.len > 0) {
                mdText(s, e.author);
                s.write(" · ");
            }
            if (e.title.len > 0) {
                if (safeHref(e.url)) {
                    s.write("[**");
                    mdText(s, e.title);
                    s.write("**](");
                    mdUrl(s, e.url);
                    s.write(")");
                } else {
                    s.write("**");
                    mdText(s, e.title);
                    s.write("**");
                }
            }
            s.write("\n");
            if (e.description.len > 0) quoted(s, e.description);
            for (e.fields) |f| {
                s.write("> **");
                mdText(s, f.name);
                s.write("**\n");
                quoted(s, f.value);
            }
            const img = if (e.image_local.len > 0) e.image_local else e.image;
            if (img.len > 0) {
                s.write("> 🖼 [");
                mdText(s, w.labels.image);
                s.write("](");
                mdUrl(s, img);
                s.write(")\n");
            }
            if (e.footer.len > 0) {
                s.write("> *");
                mdText(s, e.footer);
                s.write("*\n");
            }
        }
        if (m.reacts.len > 0) {
            for (m.reacts, 0..) |r, i| {
                if (i > 0) s.write(" · ");
                s.write(r.emoji);
                s.print(" {d}", .{r.count});
            }
            s.write("\n");
        }
    }

    // --- JSON ---

    fn jsonBegin(w: *Writer, h: *const Header) void {
        const s = w.out;
        var ib: [32]u8 = undefined;
        s.write("{\n  \"format\": \"larpercord-export\",\n  \"version\": 1,\n  \"app\": ");
        jsonString(s, h.app);
        s.print(",\n  \"exported_at\": \"{s}\",\n  \"source\": \"local\",\n  \"conversation\": {{\"id\": \"{d}\", \"name\": ", .{ isoUtc(&ib, h.exported_unix), h.conversation.id });
        jsonString(s, h.conversation.name);
        s.write(", \"kind\": ");
        jsonString(s, h.conversation.kind);
        if (h.conversation.guild_id != 0) {
            s.print(", \"guild\": {{\"id\": \"{d}\", \"name\": ", .{h.conversation.guild_id});
            jsonString(s, h.conversation.guild_name);
            s.write("}},\n");
        } else s.write(", \"guild\": null},\n");
        var fb: [32]u8 = undefined;
        if (h.count > 0) {
            s.print("  \"range\": {{\"from\": \"{s}\", \"to\": \"{s}\"}},\n", .{ isoUtc(&fb, h.from_unix), isoUtc(&ib, h.to_unix) });
        } else s.write("  \"range\": null,\n");
        s.print("  \"message_count\": {d},\n  \"media_included\": {s},\n  \"messages\": [", .{ h.count, if (h.media) "true" else "false" });
    }

    fn jsonMessage(w: *Writer, m: *const Msg) void {
        const s = w.out;
        var ib: [32]u8 = undefined;
        s.write(if (w.n > 0) ",\n    {" else "\n    {");
        s.print("\"id\": \"{d}\", \"timestamp\": \"{s}\", \"edited\": {s}, \"pinned\": {s}, \"system\": {s},\n     \"author\": {{\"id\": \"{d}\", \"name\": ", .{ m.id, isoUtc(&ib, m.unix), boolText(m.edited), boolText(m.pinned), boolText(m.system), m.author });
        jsonString(s, m.name);
        s.print(", \"bot\": {s}, \"avatar\": ", .{boolText(m.bot)});
        jsonOpt(s, w.avatarPath(m.author));
        s.write("},\n     \"content\": ");
        jsonString(s, m.text);
        s.write(", \"content_raw\": ");
        jsonString(s, m.raw);
        if (m.reply_to != 0) {
            s.print(",\n     \"reply_to\": {{\"id\": \"{d}\", \"author\": ", .{m.reply_to});
            jsonString(s, m.reply_name);
            s.write(", \"excerpt\": ");
            jsonString(s, m.reply_text);
            s.write("}");
        } else s.write(",\n     \"reply_to\": null");
        s.write(",\n     \"attachments\": [");
        for (m.atts, 0..) |a, i| {
            if (i > 0) s.write(", ");
            s.write("{\"name\": ");
            jsonString(s, a.name);
            s.print(", \"type\": \"{t}\", \"url\": ", .{a.kind});
            jsonString(s, a.url);
            s.print(", \"size\": {d}, \"width\": {d}, \"height\": {d}, \"spoiler\": {s}, \"file\": ", .{ a.size, a.w, a.h, boolText(a.spoiler) });
            jsonOpt(s, a.local);
            s.write("}");
        }
        s.write("],\n     \"embeds\": [");
        for (m.embeds, 0..) |e, i| {
            if (i > 0) s.write(", ");
            s.write("{\"title\": ");
            jsonString(s, e.title);
            s.write(", \"url\": ");
            jsonString(s, e.url);
            s.write(", \"description\": ");
            jsonString(s, e.description);
            s.write(", \"author\": ");
            jsonString(s, e.author);
            s.write(", \"provider\": ");
            jsonString(s, e.provider);
            s.write(", \"footer\": ");
            jsonString(s, e.footer);
            if (e.color) |col| s.print(", \"color\": \"#{x:0>6}\"", .{col}) else s.write(", \"color\": null");
            s.write(", \"fields\": [");
            for (e.fields, 0..) |f, k| {
                if (k > 0) s.write(", ");
                s.write("{\"name\": ");
                jsonString(s, f.name);
                s.write(", \"value\": ");
                jsonString(s, f.value);
                s.write("}");
            }
            s.write("], \"image\": ");
            jsonString(s, e.image);
            s.write(", \"thumbnail\": ");
            jsonString(s, e.thumb);
            s.write(", \"video\": ");
            jsonString(s, e.video);
            s.write(", \"image_file\": ");
            jsonOpt(s, e.image_local);
            s.write("}");
        }
        s.write("],\n     \"reactions\": [");
        for (m.reacts, 0..) |r, i| {
            if (i > 0) s.write(", ");
            s.write("{\"emoji\": ");
            jsonString(s, r.emoji);
            s.print(", \"count\": {d}}}", .{r.count});
        }
        s.write("]}");
    }

    /// O avatar de alguém, quando foi para a pasta ao lado (o embutido no HTML não conta).
    fn avatarPath(w: *const Writer, user: u64) []const u8 {
        for (w.avatars) |a| if (a.user == user) return a.path;
        return "";
    }
};

fn boolText(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// String, ou null quando vazia.
fn jsonOpt(s: Sink, text: []const u8) void {
    if (text.len == 0) s.write("null") else jsonString(s, text);
}

/// Texto solto no Markdown: os caracteres de marcação ganham uma barra.
fn mdText(s: Sink, text: []const u8) void {
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (std.mem.indexOfScalar(u8, "\\*_`~|[]<>", ch) != null) {
            s.write(text[start..i]);
            s.write("\\");
            s.write(text[i .. i + 1]);
            start = i + 1;
        } else if (ch == '\n') {
            s.write(text[start..i]);
            s.write(" ");
            start = i + 1;
        }
    }
    s.write(text[start..]);
}

/// O texto de uma mensagem no Markdown: como está, só com "<" escapado fora do código
/// (o Discord não tem HTML; um leitor de Markdown que aceita HTML mostraria uma tag
/// escrita na conversa como tag) e cada quebra de linha valendo (no Discord ela vale; no
/// Markdown, sem os dois espaços, as linhas emendam). Dentro de `…` e ```…``` nada muda.
fn mdContent(s: Sink, text: []const u8) void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "```")) {
            i = if (std.mem.indexOfPos(u8, text, i + 3, "```")) |close| close + 3 else text.len;
            continue;
        }
        if (text[i] == '`') if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |close| {
            i = close + 1;
            continue;
        };
        if (text[i] == '<') {
            s.write(text[start..i]);
            s.write("\\<");
            start = i + 1;
        } else if (text[i] == '\n') {
            s.write(text[start..i]);
            s.write("  \n");
            start = i + 1;
        }
        i += 1;
    }
    s.write(text[start..]);
}

/// Endereço num link do Markdown: espaço e parênteses ficam %xx.
fn mdUrl(s: Sink, url: []const u8) void {
    var start: usize = 0;
    for (url, 0..) |ch, i| {
        if (ch == ' ' or ch == '(' or ch == ')' or ch == '<' or ch == '>' or ch == '\n') {
            s.write(url[start..i]);
            s.print("%{X:0>2}", .{ch});
            start = i + 1;
        }
    }
    s.write(url[start..]);
}

/// Cada linha com "> " na frente (o texto de um cartão, dentro da citação dele).
fn quoted(s: Sink, text: []const u8) void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| {
        s.write("> ");
        s.write(l);
        s.write("\n");
    }
}

fn oneLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

/// A primeira letra do nome, para o círculo sem foto (maiúscula, se for ASCII).
fn initial(name: []const u8) []const u8 {
    if (name.len == 0) return "?";
    const n = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
    if (n == 1) {
        const up = std.ascii.toUpper(name[0]);
        return upper_ascii[up .. up + 1];
    }
    return name[0..@min(n, name.len)];
}

const upper_ascii: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*ch, i| ch.* = @intCast(i);
    break :blk t;
};

pub fn sizeText(buf: []u8, bytes: u64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{b / (1024 * 1024)}) catch "";
    if (bytes >= 1024) return std.fmt.bufPrint(buf, "{d:.0} KB", .{b / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
}

fn base64(s: Sink, data: []const u8) void {
    const enc = std.base64.standard.Encoder;
    var i: usize = 0;
    var out: [4096]u8 = undefined;
    // 3 bytes viram 4: pedaços de 3072 cabem em 4096.
    while (i < data.len) : (i += 3072) {
        const chunk = data[i..@min(i + 3072, data.len)];
        s.write(enc.encode(&out, chunk));
    }
}

const html_style =
    \\*{box-sizing:border-box}
    \\body{margin:0;background:var(--bg);color:var(--text);font:15px/1.375 "Inter","Segoe UI","Noto Sans",Helvetica,Arial,sans-serif}
    \\header{padding:24px 32px 16px;border-bottom:1px solid var(--border);background:var(--surface)}
    \\header h1{margin:0 0 6px;font-size:22px}
    \\.subtitle{margin:0;color:var(--muted)}
    \\.note{margin:8px 0 0;color:var(--faint);font-size:13px}
    \\main{padding:8px 0 24px;max-width:1100px}
    \\footer{padding:16px 32px 32px;color:var(--faint);font-size:12px;border-top:1px solid var(--border)}
    \\a{color:var(--link);text-decoration:none}
    \\a:hover{text-decoration:underline}
    \\.day{display:flex;align-items:center;margin:20px 16px 8px;color:var(--faint);font-size:12px;font-weight:600}
    \\.day:before,.day:after{content:"";flex:1;border-top:1px solid var(--border)}
    \\.day span{padding:0 10px}
    \\.msg{display:flex;gap:14px;padding:4px 32px 4px 16px;margin-top:14px}
    \\.msg.cont,.msg.system{margin-top:0;padding-top:1px;padding-bottom:1px}
    \\.msg:hover{background:var(--surface)}
    \\.av{flex:none;width:40px;height:40px;border-radius:50%;background-size:cover;background-position:center;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:600;font-size:17px}
    \\.side{flex:none;width:40px;text-align:right;font-size:11px;color:var(--faint);visibility:hidden;padding-top:3px}
    \\.msg:hover .side,.system .side{visibility:visible}
    \\.system .body{color:var(--muted);font-style:italic}
    \\.body{min-width:0;flex:1}
    \\.meta{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
    \\.name{font-weight:600;color:var(--text)}
    \\.meta time{font-size:12px;color:var(--faint)}
    \\.bot{background:var(--accent);color:#fff;font-size:10px;font-weight:700;padding:1px 5px;border-radius:4px}
    \\.tag{font-size:12px;color:var(--faint)}
    \\.reply{display:block;font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-bottom:2px}
    \\.text{overflow-wrap:anywhere}
    \\.ln,.li,.sub,.h1,.h2,.h3{white-space:pre-wrap;min-height:1.375em}
    \\.li{padding-left:16px}.li2{padding-left:36px}
    \\.sub{font-size:12px;color:var(--faint)}
    \\.h1{font-size:24px;font-weight:700}.h2{font-size:20px;font-weight:700}.h3{font-size:17px;font-weight:700}
    \\.jumbo{font-size:44px;line-height:1.2}
    \\.edited{font-size:11px;color:var(--faint);margin-left:4px}
    \\blockquote{margin:2px 0;padding-left:12px;border-left:4px solid var(--border)}
    \\code{background:var(--code);border-radius:4px;padding:1px 4px;font:13px/1.4 "JetBrains Mono",Consolas,monospace}
    \\pre{background:var(--code);border:1px solid var(--border);border-radius:6px;padding:8px 10px;overflow:auto;margin:4px 0}
    \\pre code{background:none;padding:0;white-space:pre}
    \\.spoiler{background:var(--elevated);color:transparent;border-radius:3px}
    \\.spoiler:hover{color:inherit}
    \\.atts{display:flex;flex-direction:column;gap:6px;margin-top:4px}
    \\.att img,.att video{display:block;max-width:min(520px,100%);max-height:360px;width:auto;height:auto;border-radius:8px}
    \\.att.sp img,.att.sp video{filter:blur(28px)}
    \\.att.sp:hover img,.att.sp:hover video{filter:none}
    \\.file{font-size:14px;margin-top:2px}
    \\.size{color:var(--faint);font-size:12px}
    \\.embed{margin-top:6px;max-width:520px;background:var(--surface);border:1px solid var(--border);border-left:4px solid var(--border);border-radius:6px;padding:8px 12px}
    \\.provider,.efooter{font-size:12px;color:var(--faint)}
    \\.eauthor{font-size:13px;font-weight:600}
    \\.etitle{display:block;font-weight:600;margin:2px 0}
    \\.edesc{font-size:14px}
    \\.fields{display:flex;flex-wrap:wrap;gap:6px 16px;margin-top:6px}
    \\.field{min-width:140px;font-size:14px}
    \\.fname{font-weight:600;font-size:13px}
    \\.eimg{display:block;max-width:100%;border-radius:4px;margin-top:8px}
    \\.reacts{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px}
    \\.reacts span{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1px 8px;font-size:13px}
    \\
;

// --- Testes -----------------------------------------------------------------------------

const testing = std.testing;

fn render(f: Format, h: *const Header, msgs: []const Msg) ![]u8 {
    var ls: ListSink = .{ .gpa = testing.allocator };
    errdefer ls.list.deinit(testing.allocator);
    var w: Writer = .{ .format = f, .out = ls.sink(), .clock = utcClock, .gpa = testing.allocator, .labels = .{ .edited = "(editada)" } };
    w.begin(h);
    for (msgs) |*m| w.message(m);
    w.end(h);
    return ls.list.toOwnedSlice(testing.allocator);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const sample_header: Header = .{ .title = "#geral <b>", .subtitle = "Servidor & cia", .note = "só local", .footer = "fim", .lang = "pt-BR", .conversation = .{ .id = 42, .name = "geral", .guild_id = 7, .guild_name = "Servidor \"x\"" }, .exported_unix = 1_763_380_800, .from_unix = 1_763_377_200, .to_unix = 1_763_377_500, .count = 3, .colors = .{ .bg = 0x101010, .accent = 0xff0066 } };

const sample = [_]Msg{
    .{ .id = 100, .unix = 1_763_377_200, .author = 1, .name = "Ana", .text = "oi **todos** <script>alert(1)</script> [site](https://a.b/c?d=1&e=2) [mau](javascript:alert(1))", .raw = "oi" },
    .{ .id = 101, .unix = 1_763_377_260, .author = 1, .name = "Ana", .text = "```\nlet x = \"<y>\";\n```", .edited = true, .atts = &.{
        .{ .name = "foto (1).png", .url = "https://cdn.discordapp.com/attachments/1/2/foto.png?ex=1&hm=2", .size = 2048, .w = 640, .h = 480, .kind = .image, .local = "geral_arquivos/foto (1).png" },
        .{ .name = "notas.txt", .url = "https://cdn.discordapp.com/attachments/1/3/notas.txt", .size = 10, .kind = .file },
    } },
    .{ .id = 102, .unix = 1_763_377_500, .author = 2, .name = "Bruno", .bot = true, .text = "> citado\nnormal", .raw = "> citado\nnormal", .reply_to = 100, .reply_name = "Ana", .reply_text = "oi todos", .embeds = &.{.{ .title = "Título", .url = "https://ex.com", .description = "desc *it*", .color = 0x00ff00, .fields = &.{.{ .name = "campo", .value = "valor" }}, .image = "https://images-ext-1.discordapp.net/x.png" }}, .reacts = &.{.{ .emoji = "👍", .count = 3 }} },
};

test "html: escapa tudo, Markdown vira HTML, resposta, anexos e cores do tema" {
    const out = try render(.html, &sample_header, &sample);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "<!doctype html>"));
    try testing.expect(has(out, "<html lang=\"pt-BR\">"));
    try testing.expect(has(out, "<title>#geral &lt;b&gt;</title>"));
    try testing.expect(has(out, "--bg:#101010"));
    try testing.expect(has(out, "--accent:#ff0066"));
    try testing.expect(has(out, "Servidor &amp; cia"));
    // Nada de script vivo nem link javascript:.
    try testing.expect(!has(out, "<script"));
    try testing.expect(has(out, "&lt;script&gt;alert(1)&lt;/script&gt;"));
    try testing.expect(!has(out, "href=\"javascript"));
    try testing.expect(has(out, "<strong>todos</strong>"));
    try testing.expect(has(out, "<a href=\"https://a.b/c?d=1&amp;e=2\">site</a>"));
    // Bloco de código escapado, e a marca de editada.
    try testing.expect(has(out, "<pre><code>let x = &quot;&lt;y&gt;&quot;;</code></pre>"));
    try testing.expect(has(out, "(editada)"));
    // A segunda mensagem da Ana, logo depois: sem foto nem nome.
    try testing.expect(has(out, "<article class=\"msg cont\" id=\"m101\">"));
    // Anexo copiado: a imagem da pasta ao lado (espaço e parênteses no caminho).
    try testing.expect(has(out, "src=\"geral_arquivos/foto%20(1).png\""));
    try testing.expect(has(out, "width=\"640\" height=\"480\""));
    // Anexo sem arquivo: o link do original, nenhum <img> remoto.
    try testing.expect(has(out, "<a href=\"https://cdn.discordapp.com/attachments/1/3/notas.txt\">notas.txt</a>"));
    try testing.expect(!has(out, "<img loading=\"lazy\" src=\"https://"));
    // Resposta aponta para a original.
    try testing.expect(has(out, "<a class=\"reply\" href=\"#m100\">↪ <b>Ana</b> oi todos</a>"));
    try testing.expect(has(out, "<blockquote><div class=\"ln\">citado</div></blockquote><div class=\"ln\">normal</div>"));
    try testing.expect(has(out, "border-left-color:#00ff00"));
    try testing.expect(has(out, "<span class=\"bot\">BOT</span>"));
    try testing.expect(has(out, "<span>👍 3</span>"));
    try testing.expect(has(out, "<div class=\"day\"><span>2025-11-17</span></div>"));
    try testing.expect(std.mem.endsWith(u8, out, "</html>\n"));
}

test "markdown do discord em html: títulos, listas, spoiler, código inline" {
    var ls: ListSink = .{ .gpa = testing.allocator };
    defer ls.list.deinit(testing.allocator);
    markdownHtml(ls.sink(), testing.allocator, "# T\n- um\n  - dois\n||seg|| `a<b` ~~x~~ *i*\n-# nota");
    const out = ls.list.items;
    try testing.expect(has(out, "<div class=\"h1\">T</div>"));
    try testing.expect(has(out, "<div class=\"li\">• um</div>"));
    try testing.expect(has(out, "<div class=\"li li2\">• dois</div>"));
    try testing.expect(has(out, "<span class=\"spoiler\">seg</span>"));
    try testing.expect(has(out, "<code>a&lt;b</code>"));
    try testing.expect(has(out, "<s>x</s>"));
    try testing.expect(has(out, "<em>i</em>"));
    try testing.expect(has(out, "<div class=\"sub\">nota</div>"));
}

test "markdown: cabeçalho, resposta, anexos e escape" {
    const out = try render(.markdown, &sample_header, &sample);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "# #geral \\<b\\>\n"));
    try testing.expect(has(out, "oi **todos** \\<script>alert(1)\\</script>"));
    try testing.expect(has(out, "\n## 2025-11-17\n"));
    try testing.expect(has(out, "**Ana** · 11:00  \n"));
    try testing.expect(has(out, "**Ana** · 11:01 (editada)  \n```\nlet x = \"<y>\";\n```\n"));
    try testing.expect(has(out, "- 📎 [foto (1).png](geral_arquivos/foto%20%281%29.png) · 2 KB\n"));
    try testing.expect(has(out, "- 📎 [notas.txt](https://cdn.discordapp.com/attachments/1/3/notas.txt) · 10 B\n"));
    try testing.expect(has(out, "**Bruno** `BOT` · 11:05  \n> ↪ **Ana** oi todos\n"));
    try testing.expect(has(out, "> citado  \nnormal\n"));
    try testing.expect(has(out, "normal\n\n> [**Título**](https://ex.com)\n> desc *it*\n> **campo**\n> valor\n"));
    try testing.expect(has(out, "👍 3\n"));
}

test "json: estrutura válida, ids como texto, escapes" {
    const out = try render(.json, &sample_header, &sample);
    defer testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("larpercord-export", root.get("format").?.string);
    try testing.expectEqual(@as(i64, 1), root.get("version").?.integer);
    try testing.expectEqualStrings("local", root.get("source").?.string);
    try testing.expectEqualStrings("Servidor \"x\"", root.get("conversation").?.object.get("guild").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 3), root.get("message_count").?.integer);
    const msgs = root.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("100", msgs[0].object.get("id").?.string);
    try testing.expectEqualStrings("2025-11-17T11:00:00Z", msgs[0].object.get("timestamp").?.string);
    try testing.expect(std.mem.startsWith(u8, msgs[0].object.get("content").?.string, "oi **todos** <script>"));
    const atts = msgs[1].object.get("attachments").?.array.items;
    try testing.expectEqualStrings("image", atts[0].object.get("type").?.string);
    try testing.expectEqualStrings("geral_arquivos/foto (1).png", atts[0].object.get("file").?.string);
    try testing.expect(atts[1].object.get("file").? == .null);
    try testing.expectEqualStrings("100", msgs[2].object.get("reply_to").?.object.get("id").?.string);
    try testing.expectEqualStrings("#00ff00", msgs[2].object.get("embeds").?.array.items[0].object.get("color").?.string);
    try testing.expectEqual(@as(i64, 3), msgs[2].object.get("reactions").?.array.items[0].object.get("count").?.integer);
    // Sem mensagens também é JSON.
    var empty = sample_header;
    empty.count = 0;
    const out0 = try render(.json, &empty, &.{});
    defer testing.allocator.free(out0);
    const p0 = try std.json.parseFromSlice(std.json.Value, testing.allocator, out0, .{});
    defer p0.deinit();
    try testing.expectEqual(@as(usize, 0), p0.value.object.get("messages").?.array.items.len);
}

test "json escapa controle e aspas" {
    var ls: ListSink = .{ .gpa = testing.allocator };
    defer ls.list.deinit(testing.allocator);
    jsonString(ls.sink(), "a\"b\\c\nd\x01e");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001e\"", ls.list.items);
}

test "menções viram nomes, menos dentro de código" {
    const L = struct {
        fn f(_: void, t: Token, buf: []u8) ?[]const u8 {
            return switch (t) {
                .user => |id| std.fmt.bufPrint(buf, "@u{d}", .{id}) catch null,
                .channel => |id| std.fmt.bufPrint(buf, "#c{d}", .{id}) catch null,
                .role => |id| std.fmt.bufPrint(buf, "@r{d}", .{id}) catch null,
                .stamp => |s| std.fmt.bufPrint(buf, "[{d}:{c}]", .{ s.unix, s.style }) catch null,
                .emoji => |name| std.fmt.bufPrint(buf, ":{s}:", .{name}) catch null,
            };
        }
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try resolveTokens(&out, testing.allocator, "oi <@1> <@!2> <#3> <@&4> <t:5:R> <:pepe:6> <a:dance:7> `<@8>` <@x> <t:9:q>\n```\n<@10>\n```", {}, L.f);
    try testing.expectEqualStrings("oi @u1 @u2 #c3 @r4 [5:R] :pepe: :dance: `<@8>` <@x> <t:9:q>\n```\n<@10>\n```", out.items);
}

test "hora em utc sem o sistema" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", isoUtc(&b, 0));
    try testing.expectEqualStrings("2024-02-29T23:59:59Z", isoUtc(&b, 1_709_251_199));
    try testing.expectEqualStrings("2026-11-17T12:00:00Z", isoUtc(&b, 1_794_916_800));
}
