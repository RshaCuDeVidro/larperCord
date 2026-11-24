//! O `<t:…>` do Discord em cada idioma, a partir da data já no fuso de quem lê
//! (o rich.zig converte com o SDL): "9 de novembro de 2026", "November 9, 2026",
//! "2026年11月9日", "9 ноября 2026 г.", e o relativo: "há 3 dias", "3 days ago",
//! "3日前", "3 дня назад". O relativo vem dos arquivos de tradução (com as formas de
//! plural de cada idioma); a data tem o jeito de cada um dos quatro idiomas que o app
//! conhece, e os outros escrevem como o inglês. Testada em `zig build test`.
const std = @import("std");
const i18n = @import("i18n.zig");

/// Como a data é escrita: os quatro jeitos que o app conhece. Outro idioma (um arquivo
/// novo) escreve a data como o inglês.
pub const Lang = enum { pt, en, ja, ru };

/// O jeito de escrever a data de um código de idioma.
pub fn styleOf(code: []const u8) Lang {
    if (std.mem.eql(u8, code, "pt")) return .pt;
    if (std.mem.eql(u8, code, "ja")) return .ja;
    if (std.mem.eql(u8, code, "ru")) return .ru;
    return .en;
}

pub const Parts = struct { year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32, weekday: u32 };

const months_pt = [_][]const u8{ "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro" };
const months_en = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
/// No genitivo, como na data: "9 ноября".
const months_ru = [_][]const u8{ "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря" };
const days_pt = [_][]const u8{ "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado" };
const days_en = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const days_ja = [_][]const u8{ "日曜日", "月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日" };
const days_ru = [_][]const u8{ "воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота" };

/// O `<t:…>` em nanossegundos, como o SDL_Time conta: null depois de 2262, que
/// não cabe num i64 (o Discord aceita até o ano 5138).
pub fn sdlTime(unix: i64) ?i64 {
    return std.math.mul(i64, unix, std.time.ns_per_s) catch null;
}

/// Os estilos de data e hora (t, T, d, D, f, F); `R` é `relative`.
pub fn absolute(buf: []u8, style: u8, p: Parts, lang: Lang) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeAbsolute(&w, style, p, lang) catch return "?";
    return w.buffered();
}

fn writeAbsolute(w: *std.Io.Writer, style: u8, p: Parts, lang: Lang) std.Io.Writer.Error!void {
    switch (style) {
        't' => try w.print("{d:0>2}:{d:0>2}", .{ p.hour, p.minute }),
        'T' => try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ p.hour, p.minute, p.second }),
        'd' => switch (lang) {
            .pt => try w.print("{d:0>2}/{d:0>2}/{d}", .{ p.day, p.month, p.year }),
            .en => try w.print("{d:0>2}/{d:0>2}/{d}", .{ p.month, p.day, p.year }),
            .ja => try w.print("{d}/{d:0>2}/{d:0>2}", .{ p.year, p.month, p.day }),
            .ru => try w.print("{d:0>2}.{d:0>2}.{d}", .{ p.day, p.month, p.year }),
        },
        'D' => try writeDate(w, p, lang),
        'F' => {
            const wd: usize = @min(p.weekday, 6);
            switch (lang) {
                .ja => {
                    try writeDate(w, p, lang);
                    try w.writeAll(days_ja[wd]);
                },
                .pt, .en, .ru => {
                    try w.print("{s}, ", .{(switch (lang) {
                        .pt => days_pt,
                        .en => days_en,
                        else => days_ru,
                    })[wd]});
                    try writeDate(w, p, lang);
                },
            }
            try w.print(" {d:0>2}:{d:0>2}", .{ p.hour, p.minute });
        },
        else => {
            try writeDate(w, p, lang);
            try w.print(" {d:0>2}:{d:0>2}", .{ p.hour, p.minute });
        },
    }
}

fn writeDate(w: *std.Io.Writer, p: Parts, lang: Lang) std.Io.Writer.Error!void {
    const m: usize = std.math.clamp(p.month, 1, 12) - 1;
    switch (lang) {
        .pt => try w.print("{d} de {s} de {d}", .{ p.day, months_pt[m], p.year }),
        .en => try w.print("{s} {d}, {d}", .{ months_en[m], p.day, p.year }),
        .ja => try w.print("{d}年{d}月{d}日", .{ p.year, p.month, p.day }),
        .ru => try w.print("{d} {s} {d} г.", .{ p.day, months_ru[m], p.year }),
    }
}

const unit_sizes = [_]u64{ 365 * 86400, 30 * 86400, 86400, 3600, 60, 1 };

/// "há 2 horas", "em 3 dias"… no idioma da interface, com o plural dele (o russo tem três
/// formas: "1 день", "2 дня", "5 дней"). `delta`: segundos até o momento (negativo: já
/// passou). Sem espaço, corta como o i18n.fmt.
pub fn relative(buf: []u8, delta: i64) []const u8 {
    const secs = @abs(delta);
    const unit = for (unit_sizes, 0..) |size, k| {
        if (secs >= size) break k;
    } else unit_sizes.len - 1;
    const n = secs / unit_sizes[unit];
    if (delta < 0) return switch (unit) {
        0 => i18n.plural(buf, n, "há {d} ano", "há {d} anos", "{d} year ago", "{d} years ago", .{n}),
        1 => i18n.plural(buf, n, "há {d} mês", "há {d} meses", "{d} month ago", "{d} months ago", .{n}),
        2 => i18n.plural(buf, n, "há {d} dia", "há {d} dias", "{d} day ago", "{d} days ago", .{n}),
        3 => i18n.plural(buf, n, "há {d} hora", "há {d} horas", "{d} hour ago", "{d} hours ago", .{n}),
        4 => i18n.plural(buf, n, "há {d} minuto", "há {d} minutos", "{d} minute ago", "{d} minutes ago", .{n}),
        else => i18n.plural(buf, n, "há {d} segundo", "há {d} segundos", "{d} second ago", "{d} seconds ago", .{n}),
    };
    return switch (unit) {
        0 => i18n.plural(buf, n, "em {d} ano", "em {d} anos", "in {d} year", "in {d} years", .{n}),
        1 => i18n.plural(buf, n, "em {d} mês", "em {d} meses", "in {d} month", "in {d} months", .{n}),
        2 => i18n.plural(buf, n, "em {d} dia", "em {d} dias", "in {d} day", "in {d} days", .{n}),
        3 => i18n.plural(buf, n, "em {d} hora", "em {d} horas", "in {d} hour", "in {d} hours", .{n}),
        4 => i18n.plural(buf, n, "em {d} minuto", "em {d} minutos", "in {d} minute", "in {d} minutes", .{n}),
        else => i18n.plural(buf, n, "em {d} segundo", "em {d} segundos", "in {d} second", "in {d} seconds", .{n}),
    };
}

const t = std.testing;

// O russo vem de i18n/ru.kdl, com as três formas do plural (o mesmo texto que o código
// tinha até a 0.6).
test "relativo em russo, com o plural e o acusativo" {
    const old = i18n.current();
    defer i18n.set(old);
    i18n.set("ru");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("1 день назад", relative(&buf, -86400));
    try t.expectEqualStrings("2 дня назад", relative(&buf, -2 * 86400));
    try t.expectEqualStrings("5 дней назад", relative(&buf, -5 * 86400));
    try t.expectEqualStrings("11 дней назад", relative(&buf, -11 * 86400));
    try t.expectEqualStrings("21 день назад", relative(&buf, -21 * 86400));
    try t.expectEqualStrings("1 минуту назад", relative(&buf, -60));
    try t.expectEqualStrings("через 2 минуты", relative(&buf, 120));
    try t.expectEqualStrings("12 часов назад", relative(&buf, -12 * 3600));
    try t.expectEqualStrings("через 22 секунды", relative(&buf, 22));
    try t.expectEqualStrings("через 11 месяцев", relative(&buf, 11 * 30 * 86400));
    try t.expectEqualStrings("2 месяца назад", relative(&buf, -2 * 30 * 86400));
    try t.expectEqualStrings("111 лет назад", relative(&buf, -111 * 365 * 86400));
    try t.expectEqualStrings("через 25 лет", relative(&buf, 25 * 365 * 86400));
}

test "relativo em japonês, inglês e português" {
    const old = i18n.current();
    defer i18n.set(old);
    var buf: [64]u8 = undefined;
    i18n.set("ja");
    try t.expectEqualStrings("3日前", relative(&buf, -3 * 86400));
    try t.expectEqualStrings("2時間後", relative(&buf, 2 * 3600));
    i18n.set("en");
    try t.expectEqualStrings("1 day ago", relative(&buf, -86400));
    try t.expectEqualStrings("in 2 hours", relative(&buf, 2 * 3600));
    i18n.set("pt");
    try t.expectEqualStrings("há 1 dia", relative(&buf, -86400));
    try t.expectEqualStrings("em 2 horas", relative(&buf, 2 * 3600));
    try t.expectEqualStrings("em 0 segundos", relative(&buf, 0));
}

test "jeito da data de cada código" {
    try t.expectEqual(Lang.ja, styleOf("ja"));
    try t.expectEqual(Lang.ru, styleOf("ru"));
    try t.expectEqual(Lang.en, styleOf("xx"));
    try t.expectEqual(Lang.pt, styleOf("pt"));
}

test "<t:…> em nanossegundos: até 2262, depois null" {
    try t.expectEqual(@as(?i64, 1_800_000_000 * std.time.ns_per_s), sdlTime(1_800_000_000));
    try t.expectEqual(@as(?i64, null), sdlTime(9_999_999_999));
    try t.expectEqual(@as(?i64, null), sdlTime(100_000_000_000));
    try t.expect(sdlTime(@divTrunc(std.math.maxInt(i64), std.time.ns_per_s)) != null);
}

test "data e hora do <t:…> em cada idioma" {
    var buf: [96]u8 = undefined;
    // Segunda-feira, 9 de novembro de 2026, 03:39:07.
    const p: Parts = .{ .year = 2026, .month = 11, .day = 9, .hour = 3, .minute = 39, .second = 7, .weekday = 1 };
    try t.expectEqualStrings("03:39", absolute(&buf, 't', p, .ru));
    try t.expectEqualStrings("03:39:07", absolute(&buf, 'T', p, .ja));
    try t.expectEqualStrings("09/11/2026", absolute(&buf, 'd', p, .pt));
    try t.expectEqualStrings("11/09/2026", absolute(&buf, 'd', p, .en));
    try t.expectEqualStrings("2026/11/09", absolute(&buf, 'd', p, .ja));
    try t.expectEqualStrings("09.11.2026", absolute(&buf, 'd', p, .ru));
    try t.expectEqualStrings("9 de novembro de 2026", absolute(&buf, 'D', p, .pt));
    try t.expectEqualStrings("November 9, 2026", absolute(&buf, 'D', p, .en));
    try t.expectEqualStrings("2026年11月9日", absolute(&buf, 'D', p, .ja));
    try t.expectEqualStrings("9 ноября 2026 г.", absolute(&buf, 'D', p, .ru));
    try t.expectEqualStrings("9 ноября 2026 г. 03:39", absolute(&buf, 'f', p, .ru));
    try t.expectEqualStrings("November 9, 2026 03:39", absolute(&buf, 'f', p, .en));
    try t.expectEqualStrings("segunda-feira, 9 de novembro de 2026 03:39", absolute(&buf, 'F', p, .pt));
    try t.expectEqualStrings("Monday, November 9, 2026 03:39", absolute(&buf, 'F', p, .en));
    try t.expectEqualStrings("2026年11月9日月曜日 03:39", absolute(&buf, 'F', p, .ja));
    try t.expectEqualStrings("понедельник, 9 ноября 2026 г. 03:39", absolute(&buf, 'F', p, .ru));
    // Sem espaço: "?", como antes.
    var tiny: [4]u8 = undefined;
    try t.expectEqualStrings("?", absolute(&tiny, 'D', p, .pt));
}
