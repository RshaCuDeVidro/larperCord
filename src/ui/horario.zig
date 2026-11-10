//! O `<t:…>` do Discord em cada idioma, a partir da data já no fuso de quem lê
//! (o rich.zig converte com o SDL): "9 de novembro de 2026", "November 9, 2026",
//! "2026年11月9日", "9 ноября 2026 г.", e o relativo: "há 3 dias", "3 days ago",
//! "3日前", "3 дня назад". Lógica pura, testada em `zig build test`.
const std = @import("std");
const Lang = @import("i18n.zig").Lang;

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

/// Russo: "минуту" e "секунду" no acusativo, como vão depois de "через" e antes
/// de "назад" (os masculinos não mudam).
const Unit = struct { size: u64, pt: [2][]const u8, en: [2][]const u8, ja: []const u8, ru: [3][]const u8 };
const units = [_]Unit{
    .{ .size = 365 * 86400, .pt = .{ "ano", "anos" }, .en = .{ "year", "years" }, .ja = "年", .ru = .{ "год", "года", "лет" } },
    .{ .size = 30 * 86400, .pt = .{ "mês", "meses" }, .en = .{ "month", "months" }, .ja = "ヶ月", .ru = .{ "месяц", "месяца", "месяцев" } },
    .{ .size = 86400, .pt = .{ "dia", "dias" }, .en = .{ "day", "days" }, .ja = "日", .ru = .{ "день", "дня", "дней" } },
    .{ .size = 3600, .pt = .{ "hora", "horas" }, .en = .{ "hour", "hours" }, .ja = "時間", .ru = .{ "час", "часа", "часов" } },
    .{ .size = 60, .pt = .{ "minuto", "minutos" }, .en = .{ "minute", "minutes" }, .ja = "分", .ru = .{ "минуту", "минуты", "минут" } },
    .{ .size = 1, .pt = .{ "segundo", "segundos" }, .en = .{ "second", "seconds" }, .ja = "秒", .ru = .{ "секунду", "секунды", "секунд" } },
};

/// A forma do plural russo: 0 para 1, 21, 101…; 1 para 2–4, 22–24…; 2 para o
/// resto (0, 5–20, 25–30, 111–114…).
pub fn ruForm(n: u64) usize {
    const d10 = n % 10;
    const d100 = n % 100;
    if (d10 == 1 and d100 != 11) return 0;
    if (d10 >= 2 and d10 <= 4 and (d100 < 12 or d100 > 14)) return 1;
    return 2;
}

/// "há 2 horas", "em 3 dias"… `delta`: segundos até o momento (negativo: já passou).
pub fn relative(buf: []u8, delta: i64, lang: Lang) []const u8 {
    const secs = @abs(delta);
    const u = for (units) |x| {
        if (secs >= x.size) break x;
    } else units[units.len - 1];
    const n = secs / u.size;
    const past = delta < 0;
    const one: usize = @intFromBool(n != 1);
    const f = std.fmt.bufPrint;
    const out = switch (lang) {
        .pt => if (past) f(buf, "há {d} {s}", .{ n, u.pt[one] }) else f(buf, "em {d} {s}", .{ n, u.pt[one] }),
        .en => if (past) f(buf, "{d} {s} ago", .{ n, u.en[one] }) else f(buf, "in {d} {s}", .{ n, u.en[one] }),
        // Japonês não distingue singular e plural.
        .ja => if (past) f(buf, "{d}{s}前", .{ n, u.ja }) else f(buf, "{d}{s}後", .{ n, u.ja }),
        .ru => if (past) f(buf, "{d} {s} назад", .{ n, u.ru[ruForm(n)] }) else f(buf, "через {d} {s}", .{ n, u.ru[ruForm(n)] }),
    };
    return out catch "?";
}

const t = std.testing;

test "plural russo: 1, 2, 5, 11, 12, 14, 21, 22, 25, 111" {
    const cases = [_][2]u64{
        .{ 1, 0 },   .{ 2, 1 },  .{ 5, 2 },  .{ 11, 2 },  .{ 12, 2 },  .{ 14, 2 }, .{ 21, 0 },
        .{ 22, 1 },  .{ 25, 2 }, .{ 111, 2 }, .{ 0, 2 },  .{ 101, 0 }, .{ 104, 1 }, .{ 112, 2 },
    };
    for (cases) |cs| try t.expectEqual(@as(usize, cs[1]), ruForm(cs[0]));
}

test "relativo em russo, com o plural e o acusativo" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("1 день назад", relative(&buf, -86400, .ru));
    try t.expectEqualStrings("2 дня назад", relative(&buf, -2 * 86400, .ru));
    try t.expectEqualStrings("5 дней назад", relative(&buf, -5 * 86400, .ru));
    try t.expectEqualStrings("11 дней назад", relative(&buf, -11 * 86400, .ru));
    try t.expectEqualStrings("21 день назад", relative(&buf, -21 * 86400, .ru));
    try t.expectEqualStrings("1 минуту назад", relative(&buf, -60, .ru));
    try t.expectEqualStrings("через 2 минуты", relative(&buf, 120, .ru));
    try t.expectEqualStrings("12 часов назад", relative(&buf, -12 * 3600, .ru));
    try t.expectEqualStrings("через 22 секунды", relative(&buf, 22, .ru));
    try t.expectEqualStrings("через 11 месяцев", relative(&buf, 11 * 30 * 86400, .ru));
    try t.expectEqualStrings("2 месяца назад", relative(&buf, -2 * 30 * 86400, .ru));
    try t.expectEqualStrings("111 лет назад", relative(&buf, -111 * 365 * 86400, .ru));
    try t.expectEqualStrings("через 25 лет", relative(&buf, 25 * 365 * 86400, .ru));
}

test "relativo em japonês, inglês e português" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("3日前", relative(&buf, -3 * 86400, .ja));
    try t.expectEqualStrings("2時間後", relative(&buf, 2 * 3600, .ja));
    try t.expectEqualStrings("1 day ago", relative(&buf, -86400, .en));
    try t.expectEqualStrings("in 2 hours", relative(&buf, 2 * 3600, .en));
    try t.expectEqualStrings("há 1 dia", relative(&buf, -86400, .pt));
    try t.expectEqualStrings("em 2 horas", relative(&buf, 2 * 3600, .pt));
    try t.expectEqualStrings("em 0 segundos", relative(&buf, 0, .pt));
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
