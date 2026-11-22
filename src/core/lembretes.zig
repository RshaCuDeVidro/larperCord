//! Lembretes de mensagens ("Me lembrar…" no menu do botão direito). Ficam só neste
//! computador (nada vai para o Discord), num JSON por conta ao lado das mensagens
//! salvas (quem lê e grava o arquivo é ui/lembretes.zig). Guardamos uma cópia do que
//! importa (autor, prévia do texto, canal, servidor): a mensagem pode sumir da
//! memória e o lembrete continua legível.
//!
//! Aqui fica a parte pura: as contas de horário (em 20 min, 1 h, 3 h, amanhã às 9:00,
//! semana que vem e a data e hora escolhidas, no fuso de quem usa, com horário de
//! verão), adiar, concluir, o que venceu, o que venceu com o app fechado e quando o
//! app precisa acordar. Testada em `zig build test`.
const std = @import("std");
const types = @import("types.zig");
const Store = @import("store.zig").Store;
const inbox = @import("inbox.zig");
const j = @import("../net/jsonx.zig");
const Id = types.Id;

pub const max_items = 500;
/// Anotação curta (bytes).
pub const max_note = 200;
/// Prévia do texto da mensagem guardada no lembrete (bytes).
pub const max_preview = 400;
/// "Adiar 10 min".
pub const snooze_ms: i64 = 10 * 60 * 1000;
/// O aviso saiu mais de 1 min depois da hora: "lembrete atrasado" (o app estava
/// fechado, ou o computador dormindo).
pub const late_ms: i64 = 60 * 1000;

// --- Horário --------------------------------------------------------------------

/// O fuso: segundos a somar ao UTC para ter a hora local naquele instante (em s UTC).
/// No app é o do sistema (o SDL responde); nos testes, fusos de mentira.
pub const Zone = *const fn (utc_s: i64) i64;

/// As escolhas prontas do menu.
pub const Preset = enum { min20, h1, h3, tomorrow9, next_week };

/// Quando vence (ms UTC) a escolha pronta, contando de `now_ms`. As de duração são
/// tempo de verdade (atravessam o horário de verão sem mudar); "amanhã às 9:00" e
/// "semana que vem" (a próxima segunda às 9:00) são a hora no relógio da parede.
pub fn presetDue(p: Preset, now_ms: i64, zone: Zone) i64 {
    return switch (p) {
        .min20 => now_ms + 20 * 60 * 1000,
        .h1 => now_ms + 60 * 60 * 1000,
        .h3 => now_ms + 3 * 60 * 60 * 1000,
        .tomorrow9 => atLocal(zone, localDay(zone, now_ms) + 1, 9, 0),
        .next_week => blk: {
            const day = localDay(zone, now_ms);
            // De domingo, a segunda é amanhã; de segunda, a da outra semana.
            const ahead = 7 - @mod(weekday(day) + 6, 7);
            break :blk atLocal(zone, day + ahead, 9, 0);
        },
    };
}

/// O dia local do instante: dias desde 1º/1/1970 no relógio da parede.
pub fn localDay(zone: Zone, ms: i64) i64 {
    const s = @divFloor(ms, 1000);
    return @divFloor(s + zone(s), 86400);
}

/// Minutos desde a meia-noite local do instante.
pub fn localMinute(zone: Zone, ms: i64) i64 {
    const s = @divFloor(ms, 1000);
    return @divFloor(@mod(s + zone(s), 86400), 60);
}

/// 0 = domingo … 6 = sábado (1º/1/1970 foi uma quinta).
pub fn weekday(day: i64) i64 {
    return @mod(day + 4, 7);
}

/// `h:m` do dia local `day`, em ms UTC (ver `localToUtc`).
pub fn atLocal(zone: Zone, day: i64, h: i64, m: i64) i64 {
    return localToUtc(zone, day * 86400 + h * 3600 + m * 60) * 1000;
}

/// A hora do relógio da parede (s, como se fosse UTC) no instante UTC (s). Na hora
/// que não existe (o relógio pulou para a frente) vale a de depois do pulo: 2:30 num
/// pulo das 2:00 para as 3:00 vira 3:30. Na que existe duas vezes (o relógio voltou),
/// a primeira.
pub fn localToUtc(zone: Zone, local_s: i64) i64 {
    // Os dois deslocamentos em volta (um dia antes e um depois; um fuso nunca passa de
    // um dia, e duas mudanças de horário não ficam tão perto).
    const before = zone(local_s - 86400);
    const after = zone(local_s + 86400);
    const a = local_s - before;
    const b = local_s - after;
    const ok_a = zone(a) == before;
    const ok_b = zone(b) == after;
    if (ok_a and ok_b) return @min(a, b);
    if (ok_a) return a;
    if (ok_b) return b;
    // No buraco do pulo: lida com o deslocamento de antes, cai depois do pulo.
    return a;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

/// Dia (desde 1º/1/1970) para a data do calendário (o algoritmo de Howard Hinnant).
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

/// A data do calendário para o dia desde 1º/1/1970.
pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Sai a notificação do sistema? Só com a janela sem foco (ou escondida na bandeja),
/// com as notificações ligadas e fora do "Não perturbe". O aviso dentro do app sai
/// sempre.
pub fn shouldDesktop(focused: bool, dnd: bool, notifs_on: bool) bool {
    return !focused and !dnd and notifs_on;
}

// --- A lista ------------------------------------------------------------------------

pub const Reminder = struct {
    /// Número local, o mesmo no arquivo (0 não existe).
    id: u32,
    message: Id,
    channel: Id,
    /// 0 = mensagem direta.
    guild: Id = 0,
    author: Id = 0,
    /// Quando foi criado (s) e quando vence (ms, UTC).
    created_s: i64 = 0,
    due_ms: i64,
    /// Concluído em (s); 0 = ainda vale.
    done_s: i64 = 0,
    /// Quando o aviso apareceu nesta sessão (ms; 0 = ainda não). Fica fora do arquivo:
    /// aberto de novo, o que venceu e não foi concluído avisa de novo.
    fired_ms: i64 = 0,
    author_name: []const u8,
    channel_name: []const u8,
    guild_name: []const u8,
    /// Prévia do texto (menções resolvidas, spoiler escondido); vazia = sem texto.
    content: []const u8,
    note: []const u8,

    pub fn pending(r: *const Reminder) bool {
        return r.done_s == 0;
    }

    /// Venceu e ainda não foi concluído (o aviso fica na tela).
    pub fn isDue(r: *const Reminder, now_ms: i64) bool {
        return r.done_s == 0 and now_ms >= r.due_ms;
    }

    /// O aviso saiu bem depois da hora: "lembrete atrasado".
    pub fn late(r: *const Reminder) bool {
        return r.fired_ms != 0 and r.fired_ms - r.due_ms > late_ms;
    }

    fn free(r: *const Reminder, gpa: std.mem.Allocator) void {
        for ([_][]const u8{ r.author_name, r.channel_name, r.guild_name, r.content, r.note }) |t| gpa.free(t);
    }
};

pub const AddResult = union(enum) { added: u32, missing, full };

/// O que a interface pede (app_lembretes.zig faz). As anotações vêm alocadas com o
/// gpa da interface.
pub const Action = union(enum) {
    add: struct { message: Id, due_ms: i64, note: []const u8 },
    edit: struct { id: u32, due_ms: i64, note: []const u8 },
    /// "Adiar 10 min", "Concluir", "Excluir" e "Ir para a mensagem".
    snooze: u32,
    done: u32,
    delete: u32,
    open: u32,
    /// Abre (ou fecha) a lista: a aba Lembretes do painel das salvas.
    toggle_list,
};

pub const List = struct {
    /// Os pendentes primeiro (o que vence antes, antes), depois os concluídos (o
    /// concluído por último, antes).
    items: std.ArrayList(Reminder) = .empty,
    /// Conta dona da lista (cada conta tem o seu arquivo); 0 = nenhuma.
    owner: Id = 0,
    next_id: u32 = 1,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.clear(gpa);
        l.items.deinit(gpa);
    }

    pub fn clear(l: *List, gpa: std.mem.Allocator) void {
        for (l.items.items) |*r| r.free(gpa);
        l.items.clearRetainingCapacity();
        l.next_id = 1;
    }

    pub fn find(l: *const List, id: u32) ?*Reminder {
        for (l.items.items) |*r| if (r.id == id) return r;
        return null;
    }

    /// O lembrete ainda pendente da mensagem (o menu oferece editar em vez de criar).
    pub fn pendingFor(l: *const List, message: Id) ?*Reminder {
        for (l.items.items) |*r| if (r.message == message and r.pending()) return r;
        return null;
    }

    /// Copia a mensagem do Store para um lembrete novo.
    pub fn add(l: *List, gpa: std.mem.Allocator, store: *const Store, message: Id, due_ms: i64, note: []const u8, now_ms: i64) !AddResult {
        if (l.items.items.len >= max_items) return .full;
        const f = store.findAny(message) orelse return .missing;
        if (f.m.msg.id == 0) return .missing;
        const ch = &f.cs.info;
        const g = store.guild(ch.guild);
        var pb: [max_preview]u8 = undefined;
        var text = inbox.preview(&pb, store, f.m);
        var ab: [max_preview]u8 = undefined;
        if (text.len == 0 and f.m.msg.attachments.len > 0) text = std.fmt.bufPrint(&ab, "📎 {s}", .{clip(f.m.msg.attachments[0].filename, max_preview - 8)}) catch "";
        const id = try l.insert(gpa, .{
            .id = 0,
            .message = message,
            .channel = ch.id,
            .guild = ch.guild,
            .author = f.m.msg.author,
            .created_s = @divFloor(now_ms, 1000),
            .due_ms = due_ms,
            .author_name = store.nameIn(ch.guild, f.m.msg.author) orelse "?",
            .channel_name = ch.name,
            .guild_name = if (g) |x| x.name else "",
            .content = text,
            .note = note,
        });
        return .{ .added = id };
    }

    /// Insere uma cópia de `src` (os textos são duplicados) e devolve o número dele.
    /// `src.id` 0 (ou repetido) ganha um novo.
    pub fn insert(l: *List, gpa: std.mem.Allocator, src: Reminder) !u32 {
        var r = src;
        if (r.id == 0 or l.find(r.id) != null) r.id = l.next_id;
        r.author_name = try gpa.dupe(u8, clip(src.author_name, 200));
        errdefer gpa.free(r.author_name);
        r.channel_name = try gpa.dupe(u8, clip(src.channel_name, 200));
        errdefer gpa.free(r.channel_name);
        r.guild_name = try gpa.dupe(u8, clip(src.guild_name, 200));
        errdefer gpa.free(r.guild_name);
        r.content = try gpa.dupe(u8, clip(src.content, max_preview));
        errdefer gpa.free(r.content);
        r.note = try gpa.dupe(u8, clip(std.mem.trim(u8, src.note, " \t\r\n"), max_note));
        errdefer gpa.free(r.note);
        try l.items.append(gpa, r);
        l.next_id = @max(l.next_id, r.id +% 1);
        if (l.next_id == 0) l.next_id = 1;
        l.sort();
        return r.id;
    }

    /// Troca a hora: vale de novo (mesmo se estava concluído) e avisa quando vencer.
    pub fn setDue(l: *List, id: u32, due_ms: i64) bool {
        const r = l.find(id) orelse return false;
        r.due_ms = due_ms;
        r.done_s = 0;
        r.fired_ms = 0;
        l.sort();
        return true;
    }

    /// Troca a anotação. false: o lembrete não existe ou não mudou.
    pub fn setNote(l: *List, gpa: std.mem.Allocator, id: u32, note: []const u8) !bool {
        const r = l.find(id) orelse return false;
        const t = clip(std.mem.trim(u8, note, " \t\r\n"), max_note);
        if (std.mem.eql(u8, t, r.note)) return false;
        const owned = try gpa.dupe(u8, t);
        gpa.free(r.note);
        r.note = owned;
        return true;
    }

    /// "Adiar 10 min": sai da tela e volta daqui a 10 minutos.
    pub fn snooze(l: *List, id: u32, now_ms: i64) bool {
        return l.setDue(id, now_ms + snooze_ms);
    }

    /// "Concluir": sai da tela e vai para os concluídos.
    pub fn done(l: *List, id: u32, now_s: i64) bool {
        const r = l.find(id) orelse return false;
        if (!r.pending()) return false;
        r.done_s = @max(now_s, 1);
        r.fired_ms = 0;
        l.sort();
        return true;
    }

    pub fn remove(l: *List, gpa: std.mem.Allocator, id: u32) bool {
        for (l.items.items, 0..) |*r, i| if (r.id == id) {
            r.free(gpa);
            _ = l.items.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// Os que venceram e ainda não avisaram nesta sessão: marca a hora do aviso e põe
    /// os números em `out` (os que não couberem avisam na próxima vez). Quantos.
    pub fn fire(l: *List, now_ms: i64, out: []u32) usize {
        var n: usize = 0;
        for (l.items.items) |*r| {
            if (n == out.len) break;
            if (!r.isDue(now_ms) or r.fired_ms != 0) continue;
            r.fired_ms = now_ms;
            out[n] = r.id;
            n += 1;
        }
        return n;
    }

    /// Quando o app precisa acordar (ms UTC): o próximo vencimento que ainda vai
    /// avisar. null = nenhum (dorme até um evento).
    pub fn nextWake(l: *const List) ?i64 {
        var best: ?i64 = null;
        for (l.items.items) |*r| {
            if (!r.pending() or r.fired_ms != 0) continue;
            if (best == null or r.due_ms < best.?) best = r.due_ms;
        }
        return best;
    }

    /// Quantos venceram e não foram concluídos (o número em cima do botão).
    pub fn dueCount(l: *const List, now_ms: i64) usize {
        var n: usize = 0;
        for (l.items.items) |*r| {
            if (r.isDue(now_ms)) n += 1;
        }
        return n;
    }

    fn sort(l: *List) void {
        std.sort.insertion(Reminder, l.items.items, {}, before);
    }

    fn before(_: void, a: Reminder, b: Reminder) bool {
        if (a.pending() != b.pending()) return a.pending();
        if (a.pending()) return if (a.due_ms != b.due_ms) a.due_ms < b.due_ms else a.id < b.id;
        return if (a.done_s != b.done_s) a.done_s > b.done_s else a.id > b.id;
    }

    /// `{"version":1,"reminders":[{...}]}`, com os IDs do Discord como texto.
    pub fn write(l: *const List, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(gpa, "{\"version\":1,\"reminders\":[");
        for (l.items.items, 0..) |r, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "\n{{\"id\":{d},\"message\":\"{d}\",\"channel\":\"{d}\",\"guild\":\"{d}\",\"author\":\"{d}\",\"created\":{d},\"due_ms\":{d},\"done\":{d}", .{ r.id, r.message, r.channel, r.guild, r.author, r.created_s, r.due_ms, r.done_s });
            const fields = [_]struct { []const u8, []const u8 }{
                .{ "author_name", r.author_name },
                .{ "channel_name", r.channel_name },
                .{ "guild_name", r.guild_name },
                .{ "content", r.content },
                .{ "note", r.note },
            };
            for (fields) |f| {
                try out.print(gpa, ",\"{s}\":", .{f[0]});
                try j.writeString(out, gpa, f[1]);
            }
            try out.append(gpa, '}');
        }
        try out.appendSlice(gpa, "\n]}\n");
    }

    /// Lê o arquivo (substitui a lista). Entradas sem mensagem, canal ou hora são
    /// puladas. Arquivo estragado: erro, e a lista fica como estava.
    pub fn read(l: *List, gpa: std.mem.Allocator, text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
        if (root != .object) return error.InvalidFormat;
        l.clear(gpa);
        for (j.array(j.get(root, "reminders"))) |v| {
            if (l.items.items.len >= max_items) break;
            const msg = j.id(j.get(v, "message")) orelse continue;
            const ch = j.id(j.get(v, "channel")) orelse continue;
            const due = j.int(j.get(v, "due_ms")) orelse continue;
            const raw_id = j.int(j.get(v, "id")) orelse 0;
            _ = try l.insert(gpa, .{
                .id = if (raw_id > 0 and raw_id <= std.math.maxInt(u32)) @intCast(raw_id) else 0,
                .message = msg,
                .channel = ch,
                .guild = j.id(j.get(v, "guild")) orelse 0,
                .author = j.id(j.get(v, "author")) orelse 0,
                .created_s = j.int(j.get(v, "created")) orelse 0,
                .due_ms = due,
                .done_s = @max(j.int(j.get(v, "done")) orelse 0, 0),
                .author_name = j.str(j.get(v, "author_name")) orelse "?",
                .channel_name = j.str(j.get(v, "channel_name")) orelse "?",
                .guild_name = j.str(j.get(v, "guild_name")) orelse "",
                .content = j.str(j.get(v, "content")) orelse "",
                .note = j.str(j.get(v, "note")) orelse "",
            });
        }
    }
};

/// Corta em `max` bytes sem quebrar um caractere UTF-8.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

// --- Testes ---------------------------------------------------------------------------

const tt = std.testing;

fn brasilia(_: i64) i64 {
    return -3 * 3600;
}

fn utc(_: i64) i64 {
    return 0;
}

/// Nova York em 2026: horário de verão de 8/3 às 2:00 (7:00 UTC) a 1º/11 às 2:00
/// (6:00 UTC).
fn newYork(s: i64) i64 {
    const start = (daysFromCivil(2026, 3, 8) * 86400) + 7 * 3600;
    const end = (daysFromCivil(2026, 11, 1) * 86400) + 6 * 3600;
    return if (s >= start and s < end) -4 * 3600 else -5 * 3600;
}

/// Um fuso que muda à meia-noite (como o Chile e o Brasil antigo): em 6/9/2026 a
/// meia-noite pula para a 1:00, e em 5/4/2026 a meia-noite volta para as 23:00 do dia 4.
fn meiaNoite(s: i64) i64 {
    const start = (daysFromCivil(2026, 9, 6) * 86400) + 4 * 3600; // 0:00 a -4 h
    const end = (daysFromCivil(2026, 4, 5) * 86400) + 3 * 3600; // 0:00 a -3 h (= 23:00 a -4 h)
    if (s >= end and s < start) return -4 * 3600;
    return -3 * 3600;
}

/// ms UTC de uma hora local no fuso (para conferir).
fn local(zone: Zone, y: i64, mo: i64, d: i64, h: i64, mi: i64) i64 {
    return atLocal(zone, daysFromCivil(y, mo, d), h, mi);
}

fn utcMs(y: i64, mo: i64, d: i64, h: i64, mi: i64) i64 {
    return (daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60) * 1000;
}

test "lembretes: calendário de ida e volta" {
    try tt.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try tt.expectEqual(@as(i64, 4), weekday(0)); // quinta
    const c = civilFromDays(daysFromCivil(2026, 11, 17));
    try tt.expectEqual(Civil{ .year = 2026, .month = 11, .day = 17 }, c);
    try tt.expectEqual(@as(i64, 2), weekday(daysFromCivil(2026, 11, 17))); // terça
    try tt.expectEqual(Civil{ .year = 2028, .month = 2, .day = 29 }, civilFromDays(daysFromCivil(2028, 2, 29)));
    try tt.expectEqual(Civil{ .year = 2027, .month = 1, .day = 1 }, civilFromDays(daysFromCivil(2026, 12, 31) + 1));
    var d: i64 = daysFromCivil(1999, 12, 25);
    while (d < daysFromCivil(2031, 1, 10)) : (d += 37) {
        const cc = civilFromDays(d);
        try tt.expectEqual(d, daysFromCivil(cc.year, cc.month, cc.day));
    }
}

test "lembretes: as escolhas prontas" {
    // Terça, 17/11/2026, 14:32:10 em Brasília (17:32:10 UTC).
    const now = utcMs(2026, 11, 17, 17, 32) + 10_000;
    try tt.expectEqual(now + 20 * 60_000, presetDue(.min20, now, brasilia));
    try tt.expectEqual(now + 3_600_000, presetDue(.h1, now, brasilia));
    try tt.expectEqual(now + 3 * 3_600_000, presetDue(.h3, now, brasilia));
    // Amanhã às 9:00 = 12:00 UTC de quarta.
    try tt.expectEqual(utcMs(2026, 11, 18, 12, 0), presetDue(.tomorrow9, now, brasilia));
    // Semana que vem: a segunda, 23/11, às 9:00.
    try tt.expectEqual(utcMs(2026, 11, 23, 12, 0), presetDue(.next_week, now, brasilia));
    // De domingo, a segunda é amanhã; de segunda, a da outra semana; de sábado, depois de amanhã.
    try tt.expectEqual(local(brasilia, 2026, 11, 23, 9, 0), presetDue(.next_week, local(brasilia, 2026, 11, 22, 20, 0), brasilia));
    try tt.expectEqual(local(brasilia, 2026, 11, 30, 9, 0), presetDue(.next_week, local(brasilia, 2026, 11, 23, 8, 0), brasilia));
    try tt.expectEqual(local(brasilia, 2026, 11, 23, 9, 0), presetDue(.next_week, local(brasilia, 2026, 11, 21, 23, 59), brasilia));
}

test "lembretes: amanhã às 9:00 perto da meia-noite" {
    // 23:59 de terça: amanhã é quarta.
    try tt.expectEqual(local(brasilia, 2026, 11, 18, 9, 0), presetDue(.tomorrow9, local(brasilia, 2026, 11, 17, 23, 59), brasilia));
    // 0:01 de quarta: amanhã é quinta (o dia do calendário, não "daqui a umas horas").
    try tt.expectEqual(local(brasilia, 2026, 11, 19, 9, 0), presetDue(.tomorrow9, local(brasilia, 2026, 11, 18, 0, 1), brasilia));
    // 22:00 de terça em Brasília já é quarta em UTC: o dia que vale é o local.
    try tt.expectEqual(local(brasilia, 2026, 11, 18, 9, 0), presetDue(.tomorrow9, local(brasilia, 2026, 11, 17, 22, 0), brasilia));
    // Virada do ano e do mês.
    try tt.expectEqual(utcMs(2027, 1, 1, 9, 0), presetDue(.tomorrow9, utcMs(2026, 12, 31, 23, 30), utc));
    try tt.expectEqual(utcMs(2028, 2, 29, 9, 0), presetDue(.tomorrow9, utcMs(2028, 2, 28, 10, 0), utc));
}

test "lembretes: horário de verão (Nova York)" {
    // Sábado 7/3 às 20:00 (EST): amanhã às 9:00 já é EDT = 13:00 UTC, não 14:00.
    try tt.expectEqual(utcMs(2026, 3, 8, 13, 0), presetDue(.tomorrow9, local(newYork, 2026, 3, 7, 20, 0), newYork));
    // Sábado 31/10 às 22:00 (EDT): amanhã às 9:00 já é EST = 14:00 UTC.
    try tt.expectEqual(utcMs(2026, 11, 1, 14, 0), presetDue(.tomorrow9, local(newYork, 2026, 10, 31, 22, 0), newYork));
    // Semana que vem atravessando o fim do horário de verão: segunda 2/11 às 9:00 EST.
    try tt.expectEqual(utcMs(2026, 11, 2, 14, 0), presetDue(.next_week, local(newYork, 2026, 10, 28, 12, 0), newYork));
    // Duração é tempo de verdade: 1:30 EST + 1 h = 3:30 EDT (o relógio pulou as 2:00).
    const t0 = local(newYork, 2026, 3, 8, 1, 30);
    try tt.expectEqual(utcMs(2026, 3, 8, 6, 30), t0);
    try tt.expectEqual(utcMs(2026, 3, 8, 7, 30), presetDue(.h1, t0, newYork));
    try tt.expectEqual(@as(i64, 3 * 60 + 30), localMinute(newYork, presetDue(.h1, t0, newYork)));
    // Hora que não existe (2:30 no dia do pulo): vira 3:30 EDT.
    try tt.expectEqual(utcMs(2026, 3, 8, 7, 30), local(newYork, 2026, 3, 8, 2, 30));
    // Hora que existe duas vezes (1:30 no dia da volta): a primeira (EDT, 5:30 UTC).
    try tt.expectEqual(utcMs(2026, 11, 1, 5, 30), local(newYork, 2026, 11, 1, 1, 30));
    // Longe das mudanças, o de sempre.
    try tt.expectEqual(utcMs(2026, 7, 4, 16, 0), local(newYork, 2026, 7, 4, 12, 0));
    try tt.expectEqual(utcMs(2026, 12, 25, 17, 0), local(newYork, 2026, 12, 25, 12, 0));
}

test "lembretes: fuso que muda à meia-noite" {
    // O dia 6/9 começa à 1:00: amanhã às 9:00 (do dia 5) não muda por isso.
    try tt.expectEqual(utcMs(2026, 9, 6, 12, 0), presetDue(.tomorrow9, local(meiaNoite, 2026, 9, 5, 23, 30), meiaNoite));
    // 0:30 do dia 6 não existe: vira 1:30 (4:30 UTC).
    try tt.expectEqual(utcMs(2026, 9, 6, 4, 30), local(meiaNoite, 2026, 9, 6, 0, 30));
    try tt.expectEqual(@as(i64, 90), localMinute(meiaNoite, local(meiaNoite, 2026, 9, 6, 0, 30)));
    // 23:30 do dia 4/4 existe duas vezes (a meia-noite volta para as 23:00): a primeira.
    try tt.expectEqual(utcMs(2026, 4, 5, 2, 30), local(meiaNoite, 2026, 4, 4, 23, 30));
    // Amanhã às 9:00 de quem está às 23:30 da primeira vez e da segunda: o mesmo dia 5,
    // já no horário de depois da volta (-4 h, 13:00 UTC).
    try tt.expectEqual(utcMs(2026, 4, 5, 13, 0), presetDue(.tomorrow9, utcMs(2026, 4, 5, 2, 30), meiaNoite));
    try tt.expectEqual(utcMs(2026, 4, 5, 13, 0), presetDue(.tomorrow9, utcMs(2026, 4, 5, 3, 30), meiaNoite));
}

test "lembretes: notificação do sistema só sem foco, fora do não perturbe" {
    try tt.expect(shouldDesktop(false, false, true));
    try tt.expect(!shouldDesktop(true, false, true));
    try tt.expect(!shouldDesktop(false, true, true));
    try tt.expect(!shouldDesktop(false, false, false));
}

fn sample(due: i64, note: []const u8) Reminder {
    return .{ .id = 0, .message = 77, .channel = 10, .guild = 5, .author = 2, .created_s = 1, .due_ms = due, .author_name = "ana", .channel_name = "geral", .guild_name = "Zig Brasil", .content = "olha \"isso\"\nlinha 2 ✨", .note = note };
}

test "lembretes: vencer, avisar, adiar, concluir e quando acordar" {
    const gpa = tt.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const base: i64 = 1_800_000_000_000;
    const a = try l.insert(gpa, sample(base + 60_000, "  responder ✓ "));
    var s2 = sample(base + 3_600_000, "");
    s2.message = 78;
    const b = try l.insert(gpa, s2);
    try tt.expect(a != b);
    try tt.expectEqualStrings("responder ✓", l.find(a).?.note);
    try tt.expectEqual(@as(?i64, base + 60_000), l.nextWake());
    try tt.expectEqual(@as(usize, 0), l.dueCount(base));
    var out: [4]u32 = undefined;
    // Antes da hora, nada.
    try tt.expectEqual(@as(usize, 0), l.fire(base + 59_999, &out));
    // Na hora: avisa uma vez só, sem atraso.
    try tt.expectEqual(@as(usize, 1), l.fire(base + 60_500, &out));
    try tt.expectEqual(a, out[0]);
    try tt.expect(!l.find(a).?.late());
    try tt.expectEqual(@as(usize, 0), l.fire(base + 61_000, &out));
    try tt.expectEqual(@as(usize, 1), l.dueCount(base + 61_000));
    // O que já avisou não acorda o app: o próximo é o de 1 h.
    try tt.expectEqual(@as(?i64, base + 3_600_000), l.nextWake());
    try tt.expect(l.pendingFor(77) != null);
    // Adiar 10 min: sai da tela e volta daqui a 10 min.
    try tt.expect(l.snooze(a, base + 120_000));
    try tt.expectEqual(base + 120_000 + snooze_ms, l.find(a).?.due_ms);
    try tt.expectEqual(@as(usize, 0), l.dueCount(base + 120_000));
    try tt.expectEqual(@as(?i64, base + 120_000 + snooze_ms), l.nextWake());
    try tt.expectEqual(@as(usize, 1), l.fire(base + 120_000 + snooze_ms, &out));
    // Concluir: vai para o fim da lista e não acorda mais nada.
    try tt.expect(l.done(a, @divFloor(base, 1000) + 800));
    try tt.expect(!l.done(a, @divFloor(base, 1000) + 900));
    try tt.expectEqual(b, l.items.items[0].id);
    try tt.expectEqual(a, l.items.items[1].id);
    try tt.expect(l.pendingFor(77) == null);
    try tt.expectEqual(@as(?i64, base + 3_600_000), l.nextWake());
    try tt.expectEqual(@as(usize, 0), l.dueCount(base + 1_000_000));
    // Nova hora num concluído: vale de novo.
    try tt.expect(l.setDue(a, base + 7_200_000));
    try tt.expect(l.find(a).?.pending());
    try tt.expectEqual(b, l.items.items[0].id);
    try tt.expect(try l.setNote(gpa, a, "outra"));
    try tt.expect(!try l.setNote(gpa, a, " outra "));
    try tt.expect(l.remove(gpa, b));
    try tt.expect(!l.remove(gpa, b));
    try tt.expectEqual(@as(?i64, base + 7_200_000), l.nextWake());
    try tt.expect(l.remove(gpa, a));
    try tt.expectEqual(@as(?i64, null), l.nextWake());
}

test "lembretes: o que venceu com o app fechado avisa ao abrir, atrasado" {
    const gpa = tt.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const base: i64 = 1_800_000_000_000;
    _ = try l.insert(gpa, sample(base - 3 * 3_600_000, "venceu de madrugada"));
    var fut = sample(base + 30_000, "");
    fut.message = 90;
    _ = try l.insert(gpa, fut);
    var old = sample(base - 86_400_000, "já feito");
    old.message = 91;
    old.done_s = @divFloor(base, 1000) - 3600;
    _ = try l.insert(gpa, old);
    var out: [8]u32 = undefined;
    // Abriu agora: o vencido acorda o app na hora (o prazo já passou) e avisa atrasado.
    try tt.expect(l.nextWake().? <= base);
    try tt.expectEqual(@as(usize, 1), l.fire(base, &out));
    const r = l.find(out[0]).?;
    try tt.expect(r.late());
    try tt.expectEqualStrings("venceu de madrugada", r.note);
    try tt.expectEqual(@as(usize, 1), l.dueCount(base));
    try tt.expectEqual(@as(?i64, base + 30_000), l.nextWake());
    // O de daqui a 30 s, na hora, não é atrasado.
    try tt.expectEqual(@as(usize, 1), l.fire(base + 30_000, &out));
    try tt.expect(!l.find(out[0]).?.late());
}

test "lembretes: gravar e ler de volta" {
    const gpa = tt.allocator;
    var l: List = .{};
    defer l.deinit(gpa);
    const base: i64 = 1_800_000_000_000;
    const a = try l.insert(gpa, sample(base, "lembrar de \"responder\" ✓\n"));
    var s2 = sample(base + 10, "");
    s2.message = 88;
    s2.guild = 0;
    s2.guild_name = "";
    const b = try l.insert(gpa, s2);
    try tt.expect(l.done(b, 1_700_000_123));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try l.write(gpa, &out);

    var back: List = .{};
    defer back.deinit(gpa);
    try back.read(gpa, out.items);
    try tt.expectEqual(@as(usize, 2), back.items.items.len);
    const r = back.find(a).?;
    try tt.expectEqual(@as(Id, 77), r.message);
    try tt.expectEqual(@as(Id, 10), r.channel);
    try tt.expectEqual(@as(Id, 5), r.guild);
    try tt.expectEqual(base, r.due_ms);
    try tt.expectEqualStrings("lembrar de \"responder\" ✓", r.note);
    try tt.expectEqualStrings("olha \"isso\"\nlinha 2 ✨", r.content);
    try tt.expectEqualStrings("Zig Brasil", r.guild_name);
    try tt.expectEqual(@as(i64, 0), r.fired_ms);
    const rb = back.find(b).?;
    try tt.expectEqual(@as(i64, 1_700_000_123), rb.done_s);
    try tt.expectEqual(@as(Id, 0), rb.guild);
    // O próximo número continua depois dos que vieram do arquivo.
    const c = try back.insert(gpa, sample(base, ""));
    try tt.expect(c != a and c != b);
    // Arquivo estragado não derruba nada (e não apaga a lista).
    if (back.read(gpa, "{ isso não é json")) |_| return error.TestUnexpectedResult else |_| {}
    if (back.read(gpa, "[1,2]")) |_| return error.TestUnexpectedResult else |_| {}
    try tt.expectEqual(@as(usize, 3), back.items.items.len);
    // Entradas sem mensagem, canal ou hora são puladas; número repetido ganha outro.
    try back.read(gpa, "{\"version\":1,\"reminders\":[{\"id\":3,\"channel\":\"1\",\"due_ms\":5},{\"id\":3,\"message\":\"9\",\"channel\":\"1\",\"due_ms\":5},{\"id\":3,\"message\":\"8\",\"channel\":\"1\",\"due_ms\":6},{\"message\":\"7\",\"channel\":\"1\"}]}");
    try tt.expectEqual(@as(usize, 2), back.items.items.len);
    try tt.expect(back.items.items[0].id != back.items.items[1].id);
}

test "lembretes: criar a partir da mensagem do Store" {
    const ca = std.heap.c_allocator;
    const gpa = tt.allocator;
    var s = Store.init(gpa);
    defer s.deinit();
    const chans = try ca.alloc(types.Channel, 1);
    chans[0] = .{ .id = 10, .guild = 5, .name = try ca.dupe(u8, "geral"), .topic = try ca.dupe(u8, "") };
    const guilds = try ca.alloc(types.Guild, 1);
    guilds[0] = .{ .id = 5, .name = try ca.dupe(u8, "Zig Brasil"), .acronym = try ca.dupe(u8, "Z") };
    const users = try ca.alloc(types.User, 1);
    users[0] = .{ .id = 2, .name = try ca.dupe(u8, "ana") };
    try s.apply(.{ .ready = .{ .me = 1, .users = users, .guilds = guilds, .channels = chans, .voice = try ca.alloc([2]Id, 0) } }, 0);
    try s.apply(.{ .message_create = .{ .id = 7, .channel = 10, .author = 2, .timestamp = 1700000000, .content = try ca.dupe(u8, "segredo ||spoiler|| aqui") } }, 0);

    var l: List = .{};
    defer l.deinit(gpa);
    const res = try l.add(gpa, &s, 7, 2_000_000, "ver depois", 1_000_000);
    try tt.expect(res == .added);
    try tt.expect(try l.add(gpa, &s, 99, 2_000_000, "", 1_000_000) == .missing);
    const r = l.find(res.added).?;
    try tt.expectEqualStrings("ana", r.author_name);
    try tt.expectEqualStrings("geral", r.channel_name);
    try tt.expectEqualStrings("Zig Brasil", r.guild_name);
    try tt.expectEqual(@as(i64, 1000), r.created_s);
    // O spoiler não vai para a prévia guardada.
    try tt.expect(std.mem.indexOf(u8, r.content, "spoiler") == null);
    try tt.expect(std.mem.startsWith(u8, r.content, "segredo "));
}
