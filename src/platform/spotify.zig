//! Detecção do Spotify local: o que está tocando nele vira a faixa para a
//! presença (net/spotify_presenca.zig). Thread própria (SDL, a interface não
//! bloqueia) que olha o Spotify de 2 s em 2 s e só entrega quando muda:
//! faixa nova, tocar↔pausar ou a detecção sumir. Não é Rich Presence
//! nenhum: a atividade sai daqui mesmo, sem aplicação.
//!
//! Linux: o Spotify fala MPRIS (org.mpris.MediaPlayer2) pelo D-Bus; a
//! libdbus-1 é aberta na hora, como no ícone da bandeja (platform/sni.zig).
//! Windows: a janela do Spotify tem o título "Artista - Título"; parado, ele
//! vira só "Spotify" (e anúncio não entra), o que a própria comparação
//! descarta.
//!
//! A parte pura (título da janela, Metadata do MPRIS, mudança, a atividade)
//! fica fora das chamadas de sistema, testada sem D-Bus nem janela.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");
const proto = @import("../net/rpc_proto.zig");

const windows = sys.windows;
const alloc = std.heap.c_allocator;

/// De quanto em quanto tempo a detecção olha o Spotify.
const poll_ms: i64 = 2000;

/// Uma faixa tocando (ou pausada) no Spotify.
pub const Track = struct {
    title: proto.Text = .{},
    artist: proto.Text = .{},
    playing: bool = true,
    /// Onde a faixa está, no momento da detecção (para o cronômetro).
    position_ms: i64 = 0,
};

/// Mudou a faixa, o tocar↔pausar ou apareceu/someu? A posição sozinha não
/// conta: o cronômetro do Discord anda sozinho depois de mandar.
pub fn changed(a: ?Track, b: ?Track) bool {
    const x = a orelse return b != null;
    const y = b orelse return true;
    return !std.mem.eql(u8, x.title.slice(), y.title.slice()) or
        !std.mem.eql(u8, x.artist.slice(), y.artist.slice()) or
        x.playing != y.playing;
}

/// O título da janela do Windows ("Artista - Título") vira faixa. O que não
/// é faixa (parado é só "Spotify", anúncio é "Advertisement") não vira nada.
pub fn parseTitle(out: *Track, title: []const u8) bool {
    for ([_][]const u8{ "", "Spotify", "Spotify Premium", "Spotify Free", "Advertisement" }) |skip| {
        if (std.mem.eql(u8, title, skip)) return false;
    }
    // O artista vem primeiro; o título é o resto ("Título - Ao Vivo" fica
    // todo no título). O separador vale o primeiro " - ".
    const sep = std.mem.indexOf(u8, title, " - ") orelse return false;
    const artist = std.mem.trim(u8, title[0..sep], " \t");
    const name = std.mem.trim(u8, title[sep + 3 ..], " \t");
    if (artist.len == 0 or name.len == 0) return false;
    out.title.set(name, proto.max_text);
    out.artist.set(artist, proto.max_text);
    out.playing = true;
    out.position_ms = 0;
    return true;
}

/// O Metadata do MPRIS (título, artista, duração e posição, em µs) vira faixa.
pub fn fromMetadata(out: *Track, playing: bool, title: []const u8, artist: []const u8, length_us: i64, position_us: i64) bool {
    if (title.len == 0) return false;
    var pos = @divTrunc(if (position_us > 0) position_us else 0, 1000);
    if (length_us > 0) pos = @min(pos, @divTrunc(length_us, 1000));
    out.title.set(title, proto.max_text);
    out.artist.set(artist, proto.max_text);
    out.playing = playing;
    out.position_ms = pos;
    return true;
}

/// A faixa como atividade nossa (Listening to Spotify): o nome é o que o
/// gateway manda sem application_id (app 0, net/rpc_proto.zig).
pub fn buildActivity(t: *const Track, now_ms: i64, act: *proto.Activity) void {
    act.* = .{ .kind = 2 };
    act.name.set("Spotify", proto.max_text);
    act.details.set(t.title.slice(), proto.max_text);
    act.state.set(t.artist.slice(), proto.max_text);
    // Tocando, o cronômetro vem de trás (o que já andou da faixa); pausada,
    // sem cronômetro (a posição congelada ia parecer errada depois).
    const pos = if (t.position_ms > 0) t.position_ms else 0;
    act.start_ms = if (t.playing) now_ms - pos else 0;
}

// --- Thread e entrega ------------------------------------------------------------

var thread: ?*c.SDL_Thread = null;
var stopping: std.atomic.Value(bool) = .init(false);

/// A faixa que a detecção viu por último (o que já foi entregue).
var current: ?Track = null;

// Caixa de saída para a interface: só a mais nova importa.
var out_mutex: ?*c.SDL_Mutex = null;
var out_ready: std.atomic.Value(bool) = .init(false);
var out_value: ?Track = null;

pub fn running() bool {
    return thread != null;
}

/// Começa a detecção (já rodando, continua: true).
pub fn start() bool {
    if (running()) return true;
    out_mutex = out_mutex orelse c.SDL_CreateMutex() orelse return false;
    stopping.store(false, .release);
    thread = c.SDL_CreateThread(threadMain, "spotify", null);
    return thread != null;
}

/// Para a detecção (espera a thread, no máximo um ciclo de sono).
pub fn stop() void {
    const t = thread orelse return;
    stopping.store(true, .release);
    c.SDL_WaitThread(t, null);
    thread = null;
    // O que não foi entregue fica para trás: quem desliga já manda limpar.
    var resto: ?Track = null;
    _ = take(&resto);
    current = null;
}

/// Detecção nova desde a última leva (null = o Spotify sumiu). true = mudou.
pub fn take(out: *?Track) bool {
    if (!out_ready.load(.acquire)) return false;
    const m = out_mutex orelse return false;
    c.SDL_LockMutex(m);
    defer c.SDL_UnlockMutex(m);
    out_ready.store(false, .release);
    out.* = out_value;
    out_value = null;
    return true;
}

fn deliver(next: ?Track) void {
    const m = out_mutex orelse return;
    c.SDL_LockMutex(m);
    out_value = next;
    out_ready.store(true, .release);
    c.SDL_UnlockMutex(m);
}

/// Cola de QA: a detecção "viu" esta faixa (ou nenhuma), sem thread. No QA
/// quem manda é a injeção: o Spotify de quem testa não entra no caminho.
/// Pelo mesmo portão da detecção: só o que muda é entregue.
pub fn qaInject(t: ?Track) void {
    out_mutex = out_mutex orelse c.SDL_CreateMutex() orelse return;
    if (changed(current, t)) {
        current = t;
        deliver(t);
    }
}

fn threadMain(_: ?*anyopaque) callconv(.c) c_int {
    while (!stopping.load(.acquire)) {
        pollOnce();
        // Dorme em fatias: parar não fica atrás de um ciclo inteiro.
        var slept: i64 = 0;
        while (slept < poll_ms and !stopping.load(.acquire)) {
            c.SDL_Delay(100);
            slept += 100;
        }
    }
    if (!windows) dropConn();
    return 0;
}

fn pollOnce() void {
    var t: Track = .{};
    const got = if (windows) detectWindows(&t) else detectLinux(&t);
    const next: ?Track = if (got) t else null;
    if (changed(current, next)) {
        current = next;
        deliver(next);
    }
}

// --- Windows: a janela do Spotify ------------------------------------------------

const ProcessWin = struct {
    out: *Track,
    found: bool = false,
};

fn detectWindows(out: *Track) bool {
    var w = ProcessWin{ .out = out };
    _ = c.EnumWindows(windowProc, @intCast(@intFromPtr(&w)));
    return w.found;
}

fn windowProc(hwnd: c.HWND, lparam: c.LPARAM) callconv(.c) c_int {
    const w: *ProcessWin = @ptrFromInt(@as(usize, @intCast(lparam)));
    if (w.found) return 0;
    if (c.IsWindowVisible(hwnd) == 0) return 1;
    var len: c_int = c.GetWindowTextLengthW(hwnd);
    if (len <= 0) return 1;
    var pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &pid);
    if (!spotifyProcess(pid)) return 1;
    var wbuf: [512]u16 = undefined;
    if (len > wbuf.len - 1) len = wbuf.len - 1;
    _ = c.GetWindowTextW(hwnd, &wbuf, len + 1);
    const s = std.mem.sliceTo(wbuf[0..@intCast(len)], 0);
    var ubuf: [1024]u8 = undefined;
    const title = utf16To8(&ubuf, s) orelse return 1;
    // Parado, o título é só "Spotify" (e anúncio é "Advertisement").
    if (parseTitle(w.out, title)) w.found = true;
    return if (w.found) 0 else 1;
}

/// O processo da janela é o Spotify? (Vale o exe dele mesmo, não um navegador.)
fn spotifyProcess(pid: c.DWORD) bool {
    // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION.
    const h = c.OpenProcess(0x1000, 0, pid) orelse return false;
    defer _ = c.CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var size: c.DWORD = buf.len;
    if (c.QueryFullProcessImageNameW(h, 0, &buf, &size) == 0) return false;
    const path = std.mem.sliceTo(buf[0..size], 0);
    const base = std.mem.lastIndexOfScalar(u16, path, '\\') orelse return false;
    const name = path[base + 1 ..];
    if (name.len != "spotify.exe".len) return false;
    for (name, "spotify.exe") |ch, want| {
        const lower = std.ascii.toLower(std.math.cast(u8, ch) orelse return false);
        if (lower != want) return false;
    }
    return true;
}

/// UTF-16 do Windows vira UTF-8 (o que a faixa tem de texto).
fn utf16To8(buf: []u8, s: []const u16) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and s[i] != 0) {
        var ch: u32 = s[i];
        i += 1;
        if (ch >= 0xD800 and ch < 0xDC00) {
            if (i >= s.len or s[i] < 0xDC00 or s[i] >= 0xE000) return null;
            ch = 0x10000 + ((ch - 0xD800) << 10) + (s[i] - 0xDC00);
            i += 1;
        } else if (ch >= 0xDC00 and ch < 0xE000) return null;
        const m = std.unicode.utf8Encode(@intCast(ch), buf[n..]) catch return null;
        n += m;
    }
    return buf[0..n];
}

// --- Linux: o Spotify falando MPRIS no D-Bus ---------------------------------------

const Conn = opaque {};
const Msg = opaque {};
/// DBusMessageIter tem 72 bytes e DBusError, 32: os dois com folga.
const Iter = [16]u64;
const Err = extern struct { name: ?[*:0]const u8, message: ?[*:0]const u8, rest: [6]usize };

/// Os nomes dos campos são os das funções da libdbus.
const Fns = struct {
    dbus_error_init: *const fn (*Err) callconv(.c) void,
    dbus_error_free: *const fn (*Err) callconv(.c) void,
    dbus_bus_get_private: *const fn (c_int, *Err) callconv(.c) ?*Conn,
    dbus_connection_set_exit_on_disconnect: *const fn (*Conn, u32) callconv(.c) void,
    dbus_connection_get_is_connected: *const fn (*Conn) callconv(.c) u32,
    dbus_connection_close: *const fn (*Conn) callconv(.c) void,
    dbus_connection_unref: *const fn (*Conn) callconv(.c) void,
    dbus_message_new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    dbus_message_unref: *const fn (*Msg) callconv(.c) void,
    dbus_message_iter_init_append: *const fn (*Msg, *Iter) callconv(.c) u32,
    dbus_message_iter_append_basic: *const fn (*Iter, c_int, *const anyopaque) callconv(.c) u32,
    dbus_message_iter_init: *const fn (*Msg, *Iter) callconv(.c) u32,
    dbus_message_iter_get_arg_type: *const fn (*Iter) callconv(.c) c_int,
    dbus_message_iter_next: *const fn (*Iter) callconv(.c) u32,
    dbus_message_iter_recurse: *const fn (*Iter, *Iter) callconv(.c) void,
    dbus_message_iter_get_basic: *const fn (*Iter, *anyopaque) callconv(.c) void,
    dbus_connection_send_with_reply_and_block: *const fn (*Conn, *Msg, c_int, *Err) callconv(.c) ?*Msg,
};

var d: Fns = undefined;
var lib: ?*c.SDL_SharedObject = null;
/// Sem libdbus (uma vez que não abriu, não tenta de novo a cada 2 s).
var lib_failed = false;
/// Conexão do D-Bus, mantida entre os ciclos (cai: refaz no próximo).
var conn: ?*Conn = null;

fn ensureLib() bool {
    if (lib != null) return true;
    if (lib_failed) return false;
    const l = c.SDL_LoadObject("libdbus-1.so.3") orelse {
        lib_failed = true;
        return false;
    };
    inline for (@typeInfo(Fns).@"struct".field_names) |fname| {
        const sym = c.SDL_LoadFunction(l, fname.ptr) orelse {
            c.SDL_UnloadObject(l);
            lib_failed = true;
            return false;
        };
        @field(d, fname) = @ptrCast(sym);
    }
    lib = l;
    return true;
}

fn ensureConn() bool {
    if (conn) |cn| return d.dbus_connection_get_is_connected(cn) != 0;
    var err: Err = undefined;
    d.dbus_error_init(&err);
    defer d.dbus_error_free(&err);
    // 0 = DBUS_BUS_SESSION.
    const cn = d.dbus_bus_get_private(0, &err) orelse return false;
    // Por padrão a libdbus derruba o processo quando a conexão cai; aqui quem
    // sai é o laço, que refaz a conexão no próximo ciclo.
    d.dbus_connection_set_exit_on_disconnect(cn, 0);
    conn = cn;
    return true;
}

fn dropConn() void {
    if (conn) |cn| {
        d.dbus_connection_close(cn);
        d.dbus_connection_unref(cn);
        conn = null;
    }
}

/// Uma chamada de método com resposta (bloqueia até ela ou o prazo).
fn call(dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8) ?*Msg {
    const cn = conn orelse return null;
    const msg = d.dbus_message_new_method_call(dest, path, iface, method) orelse return null;
    defer d.dbus_message_unref(msg);
    var err: Err = undefined;
    d.dbus_error_init(&err);
    defer d.dbus_error_free(&err);
    const reply = d.dbus_connection_send_with_reply_and_block(cn, msg, 500, &err) orelse {
        // Sessão caiu: fecha, e o próximo ciclo refaz.
        if (d.dbus_connection_get_is_connected(cn) == 0) dropConn();
        return null;
    };
    return reply;
}

/// O que a detecção vê no Linux: o Spotify (ou, sem ele, algum player MPRIS).
fn detectLinux(out: *Track) bool {
    if (!ensureLib() or !ensureConn()) return false;
    var name_buf: [128]u8 = undefined;
    const name = mprisName(&name_buf) orelse return false;

    // Estado de reprodução: "Playing" toca, o resto (Paused, Stopped) não.
    var playing = true;
    if (getVariant(name, "PlaybackStatus")) |m| {
        defer d.dbus_message_unref(m);
        var v: Iter = undefined;
        if (variantIter(m, &v)) |vi| if (basicString(vi)) |s| {
            playing = std.mem.eql(u8, std.mem.span(s), "Playing");
        };
    }

    // Metadata: xesam:title, xesam:artist (o primeiro do time) e mpris:length.
    var title: []const u8 = "";
    var artist: []const u8 = "";
    var length_us: i64 = 0;
    const meta = getVariant(name, "Metadata") orelse return false;
    defer d.dbus_message_unref(meta);
    var mv: Iter = undefined;
    const mi = variantIter(meta, &mv) orelse return false;
    if (d.dbus_message_iter_get_arg_type(mi) != 'a') return false;
    var arr: Iter = undefined;
    d.dbus_message_iter_recurse(mi, &arr);
    while (d.dbus_message_iter_get_arg_type(&arr) == 'e') {
        var entry: Iter = undefined;
        d.dbus_message_iter_recurse(&arr, &entry);
        if (basicString(&entry)) |kp| {
            _ = d.dbus_message_iter_next(&entry);
            var val: Iter = undefined;
            d.dbus_message_iter_recurse(&entry, &val);
            const key = std.mem.span(kp);
            if (std.mem.eql(u8, key, "xesam:title")) {
                if (basicString(&val)) |s| title = std.mem.span(s);
            } else if (std.mem.eql(u8, key, "xesam:artist")) {
                // Array de artistas: o primeiro já basta.
                if (d.dbus_message_iter_get_arg_type(&val) == 'a') {
                    var li: Iter = undefined;
                    d.dbus_message_iter_recurse(&val, &li);
                    if (basicString(&li)) |s| artist = std.mem.span(s);
                }
            } else if (std.mem.eql(u8, key, "mpris:length")) {
                if (basicI64(&val)) |x| length_us = x;
            }
        }
        _ = d.dbus_message_iter_next(&arr);
    }
    if (title.len == 0) return false;

    // Posição (µs): falta (player sem a propriedade), fica em 0.
    var pos_us: i64 = 0;
    if (getVariant(name, "Position")) |m| {
        defer d.dbus_message_unref(m);
        var v: Iter = undefined;
        if (variantIter(m, &v)) |vi| if (basicI64(vi)) |x| {
            pos_us = x;
        };
    }

    return fromMetadata(out, playing, title, artist, length_us, pos_us);
}

const dbus_name = "org.freedesktop.DBus";
const player_path = "/org/mpris/MediaPlayer2";
const player_iface = "org.mpris.MediaPlayer2.Player";
const props_iface = "org.freedesktop.DBus.Properties";
const mpris_prefix = "org.mpris.MediaPlayer2.";

/// O nome do player de música no barramento (o Spotify ganha). Copiado para
/// `buf` (o nome do D-Bus vive até a resposta ir embora).
fn mprisName(buf: []u8) ?[:0]const u8 {
    const reply = call(dbus_name, "/", dbus_name, "ListNames") orelse return null;
    defer d.dbus_message_unref(reply);
    var it: Iter = undefined;
    if (d.dbus_message_iter_init(reply, &it) == 0) return null;
    if (d.dbus_message_iter_get_arg_type(&it) != 'a') return null;
    var sub: Iter = undefined;
    d.dbus_message_iter_recurse(&it, &sub);
    var any: ?[:0]const u8 = null;
    while (d.dbus_message_iter_get_arg_type(&sub) == 's') {
        var p: [*:0]const u8 = undefined;
        d.dbus_message_iter_get_basic(&sub, @ptrCast(&p));
        const s = std.mem.span(p);
        if (std.mem.startsWith(u8, s, mpris_prefix)) {
            if (any == null or std.ascii.findIgnoreCase(s, "spotify") != null) {
                const copy = std.fmt.bufPrintSentinel(buf, "{s}", .{s}, 0) catch return any;
                if (std.ascii.findIgnoreCase(s, "spotify") != null) return copy;
                any = copy;
            }
        }
        _ = d.dbus_message_iter_next(&sub);
    }
    return any;
}

/// Propriedade do player como resposta (o corpo é a variante pedida).
fn getVariant(dest: [:0]const u8, prop: [*:0]const u8) ?*Msg {
    const cn = conn orelse return null;
    const msg = d.dbus_message_new_method_call(dest.ptr, player_path, props_iface, "Get") orelse return null;
    defer d.dbus_message_unref(msg);
    var it: Iter = undefined;
    _ = d.dbus_message_iter_init_append(msg, &it);
    var iface: [*:0]const u8 = player_iface;
    if (d.dbus_message_iter_append_basic(&it, 's', @ptrCast(&iface)) == 0) return null;
    var p: [*:0]const u8 = prop;
    if (d.dbus_message_iter_append_basic(&it, 's', @ptrCast(&p)) == 0) return null;
    var err: Err = undefined;
    d.dbus_error_init(&err);
    defer d.dbus_error_free(&err);
    const reply = d.dbus_connection_send_with_reply_and_block(cn, msg, 500, &err) orelse {
        if (d.dbus_connection_get_is_connected(cn) == 0) dropConn();
        return null;
    };
    return reply;
}

/// O iterador dentro da variante da resposta (o primeiro tipo real).
fn variantIter(reply: *Msg, v: *Iter) ?*Iter {
    var it: Iter = undefined;
    if (d.dbus_message_iter_init(reply, &it) == 0) return null;
    if (d.dbus_message_iter_get_arg_type(&it) != 'v') return null;
    d.dbus_message_iter_recurse(&it, v);
    return v;
}

fn basicString(it: *Iter) ?[*:0]const u8 {
    if (d.dbus_message_iter_get_arg_type(it) != 's') return null;
    var p: [*:0]const u8 = undefined;
    d.dbus_message_iter_get_basic(it, @ptrCast(&p));
    return p;
}

fn basicI64(it: *Iter) ?i64 {
    if (d.dbus_message_iter_get_arg_type(it) != 'x') return null;
    var x: i64 = undefined;
    d.dbus_message_iter_get_basic(it, @ptrCast(&x));
    return x;
}

// --- Testes -----------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

fn track(title: []const u8, artist: []const u8, playing: bool, position_ms: i64) Track {
    var t: Track = .{};
    t.title.set(title, proto.max_text);
    t.artist.set(artist, proto.max_text);
    t.playing = playing;
    t.position_ms = position_ms;
    return t;
}

test "título da janela do Windows: artista e faixa" {
    var t: Track = .{};
    try testing.expect(parseTitle(&t, "Artista de Teste - Musica de Teste"));
    try testing.expectEqualStrings("Musica de Teste", t.title.slice());
    try testing.expectEqualStrings("Artista de Teste", t.artist.slice());
    try testing.expect(t.playing);
    try testing.expectEqual(@as(i64, 0), t.position_ms);
    // Vários artistas ficam inteiros no artista; o título pode ter " - ".
    try testing.expect(parseTitle(&t, "Um, Dois e Três - Nome da Música - Ao Vivo"));
    try testing.expectEqualStrings("Nome da Música - Ao Vivo", t.title.slice());
    try testing.expectEqualStrings("Um, Dois e Três", t.artist.slice());
}

test "títulos que não são faixa ficam de fora" {
    var t: Track = .{};
    for ([_][]const u8{ "", "Spotify", "Spotify Premium", "Spotify Free", "Advertisement", "sem separador" }) |title| {
        try testing.expect(!parseTitle(&t, title));
    }
}

test "Metadata do MPRIS vira faixa, com pausa e posição no lugar" {
    var t: Track = .{};
    // 30 s tocando numa faixa de 3 min.
    try testing.expect(fromMetadata(&t, true, "Fase 3", "Artista", 180_000_000, 30_000_000));
    try testing.expectEqualStrings("Fase 3", t.title.slice());
    try testing.expectEqualStrings("Artista", t.artist.slice());
    try testing.expect(t.playing);
    try testing.expectEqual(@as(i64, 30_000), t.position_ms);
    // Pausada depois do fim da faixa: a posição fica na duração.
    try testing.expect(fromMetadata(&t, false, "Fase 3", "Artista", 180_000_000, 999_000_000));
    try testing.expect(!t.playing);
    try testing.expectEqual(@as(i64, 180_000), t.position_ms);
    // Artista vazio vale; sem título, não é faixa.
    try testing.expect(fromMetadata(&t, true, "Solo", "", 0, 0));
    try testing.expectEqualStrings("", t.artist.slice());
    try testing.expect(!fromMetadata(&t, true, "", "Artista", 0, 0));
}

test "mudança: faixa e tocar↔pausar contam, a posição sozinha não" {
    const a = track("Fase 3", "Artista", true, 30_000);
    try testing.expect(!changed(a, a));
    try testing.expect(changed(a, track("Fase 4", "Artista", true, 30_000)));
    try testing.expect(changed(a, track("Fase 3", "Outro", true, 30_000)));
    try testing.expect(changed(a, track("Fase 3", "Artista", false, 30_000)));
    // A posição andou sozinha (o Spotify continua tocando): nada muda.
    try testing.expect(!changed(a, track("Fase 3", "Artista", true, 45_000)));
    // Aparecer e sumir contam.
    try testing.expect(changed(null, a));
    try testing.expect(changed(a, null));
    try testing.expect(!changed(null, null));
}

test "a faixa vira atividade Listening to Spotify (pausada, sem cronômetro)" {
    var act: proto.Activity = .{};
    const t = track("Fase 3", "Artista de Teste", true, 30_000);
    buildActivity(&t, 1_000_000, &act);
    try testing.expectEqual(@as(u8, 2), act.kind);
    try testing.expectEqualStrings("Spotify", act.name.slice());
    try testing.expectEqualStrings("Fase 3", act.details.slice());
    try testing.expectEqualStrings("Artista de Teste", act.state.slice());
    try testing.expectEqual(@as(i64, 970_000), act.start_ms);
    try testing.expectEqual(@as(i64, 0), act.end_ms);
    // Pausada: sem cronômetro nenhum.
    var p: Track = t;
    p.playing = false;
    buildActivity(&p, 1_000_000, &act);
    try testing.expectEqual(@as(i64, 0), act.start_ms);
}
// A entrega (take/qaInject) toca o mutex da SDL: fica para a QA, que injeta
// pelo mesmo caminho (suíte "spotify").
