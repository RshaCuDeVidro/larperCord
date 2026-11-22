//! QA da gravação de áudio na caixa (QA_SUITE=gravar-audio): o botão do
//! microfone (e a chave dele em Configurações → Chat), Cancelar e Esc jogando
//! fora, Ctrl+Shift+R, enviar ~2 s como um anexo comum (.ogg, audio/ogg, sem
//! nada de mensagem de voz), o arquivo lido de volta pelo leitor do app e
//! decodificado pela libopus, a cópia pendente na conversa, um tom de 440 Hz
//! codificado e decodificado de novo, o canal sem permissão de arquivos, a call
//! e trocar de conversa no meio. Nenhum microfone abre: no QA, um sinal
//! sintético faz o papel dele (ui/gravar_audio.zig).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const i18n = @import("ui/i18n.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const ogg = @import("core/ogg_opus.zig");
const gravar = @import("ui/gravar_audio.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 5000 } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

/// O #geral do nosso servidor (somos donos: tudo liberado), o #geral do "Rice do
/// Hyprland" (o @everyone de lá não anexa arquivos) e o #anúncios de lá (só lê).
const ours = gw.channelId(0, 4);
const ours_other = gw.channelId(0, 5);
const no_files = gw.channelId(1, 4);
const read_only = gw.channelId(1, 2);
const draft = "rascunho que fica na caixa";

fn activeId(app: *App) Id {
    return app.st.activeChannel() orelse 0;
}
fn open(app: *App, ch: Id) void {
    app.actions.append(app.gpa, .{ .select_channel = ch }) catch {};
}
fn loaded(app: *App, ch: Id) bool {
    const cs = app.store.channel(ch) orelse return false;
    return activeId(app) == ch and cs.history == .loaded;
}
fn toastIs(app: *App, text: []const u8) bool {
    return app.st.toast.until_ms > gw.nowMs() and std.mem.eql(u8, app.st.toast.text(), text);
}
fn input(app: *App) []const u8 {
    return std.mem.sliceTo(&app.st.input, 0);
}
fn body() []const u8 {
    return gw.sent.view(&gw.sent.send_body, &gw.sent.send_body_len);
}
fn has(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

// --- Contadores antes de cada parte -----------------------------------------------

var sends0: u64 = 0;
var starts0: u32 = 0;
var discards0: u32 = 0;
var reply_id: Id = 0;

fn mark(_: *App) void {
    sends0 = gw.sent.sends.load(.monotonic);
    starts0 = gravar.qa_stats.starts.load(.monotonic);
    discards0 = gravar.qa_stats.discards.load(.monotonic);
}

// --- O botão --------------------------------------------------------------------

fn openOurs(app: *App) void {
    open(app, ours);
}
fn oursLoaded(app: *App) bool {
    return loaded(app, ours);
}
fn buttonShown(app: *App) bool {
    return app.st.settings.record_audio and R.hasInk(app, "composer-record") and qa.find("composer") != null;
}
fn chatPage(app: *App) bool {
    return app.st.settings.open and app.st.settings.page == .chat and qa.find("toggle:Botão de gravar áudio") != null;
}
fn settingOff(app: *App) bool {
    return !app.st.settings.record_audio;
}
fn buttonHidden(app: *App) bool {
    return !app.st.settings.open and !app.st.settings.record_audio and qa.find("composer-record") == null and qa.find("composer") != null;
}
fn settingOn(app: *App) bool {
    return app.st.settings.record_audio;
}

// --- Cancelar e Esc ---------------------------------------------------------------

fn recording(_: *App) bool {
    const i = gravar.info();
    return i.recording and i.ms >= 400 and qa.find("record-bar") != null and qa.find("record-timer") != null and
        qa.find("composer") == null and qa.find("composer-record") == null;
}
fn discarded(_: *App) bool {
    return !gravar.info().active and gravar.qa_stats.discards.load(.monotonic) > discards0 and
        gw.sent.sends.load(.monotonic) == sends0 and qa.find("record-bar") == null and qa.find("composer") != null;
}
fn startedByKey(app: *App) bool {
    return gravar.qa_stats.starts.load(.monotonic) > starts0 and recording(app);
}

// --- Enviar ---------------------------------------------------------------------

/// Um rascunho na caixa e uma resposta a alguém: o áudio vai respondendo e o texto fica.
fn draftAndReply(app: *App) void {
    @memset(&app.st.input, 0);
    @memcpy(app.st.input[0..draft.len], draft);
    app.st.input_sync = true;
    const cs = app.store.channel(ours) orelse return;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.id != 0 and m.msg.author != app.store.me) {
            reply_id = m.msg.id;
            app.actions.append(app.gpa, .{ .reply = m.msg.id }) catch {};
            return;
        }
    }
}
fn replying(app: *App) bool {
    return reply_id != 0 and app.st.reply_to == reply_id and std.mem.eql(u8, input(app), draft);
}
fn twoSeconds(_: *App) bool {
    const i = gravar.info();
    return i.recording and i.ms >= 2000 and i.bars >= 20;
}

fn sentOgg(app: *App) bool {
    if (gw.sent.sends.load(.monotonic) != sends0 + 1) return false;
    const b = body();
    var rb: [64]u8 = undefined;
    const ref = std.fmt.bufPrint(&rb, "\"message_reference\":{{\"message_id\":\"{d}\"}}", .{reply_id}) catch return false;
    const types_ = gw.sent.view(&gw.sent.send_types, &gw.sent.send_types_len);
    const file = gw.sent.view(&gw.sent.send_file, &gw.sent.send_file_len);
    const name = std.fs.path.basename(file);
    return has(b, "\"content\":\"\"") and has(b, "\"attachments\":[{\"id\":0,\"filename\":\"audio-") and has(b, ".ogg\"}]") and has(b, ref) and
        // Um anexo comum: nada da mensagem de voz do Discord.
        !has(b, "\"flags\"") and !has(b, "duration_secs") and !has(b, "waveform") and !has(b, "uploaded_filename") and
        std.mem.eql(u8, types_, "audio/ogg") and std.mem.startsWith(u8, name, "audio-") and std.mem.endsWith(u8, name, ".ogg") and
        types.isPastedFile(file) and app.st.reply_to == 0;
}

const Decoded = struct { dur_ms: u32, samples: u64, rms_db: f32, peak: i32, hz: f32, size: usize };

/// Lê com o leitor do app (core/ogg_opus.zig) e decodifica com a libopus, como o
/// player faz: só as amostras entre o pre-skip e o fim do áudio.
fn decode(bytes: []const u8) ?Decoded {
    const gpa = std.heap.c_allocator;
    var st = ogg.index(gpa, bytes) catch return null;
    defer st.deinit(gpa);
    var err: c_int = 0;
    const dec = c.opus_decoder_create(48000, st.channels, &err) orelse return null;
    defer c.opus_decoder_destroy(dec);
    var pcm: [5760 * 2]i16 = undefined;
    var sum: f64 = 0;
    var n: u64 = 0;
    var peak: i32 = 0;
    var crossings: u64 = 0;
    var prev: i16 = 0;
    for (st.packets, 0..) |pk, idx| {
        const got = c.opus_decode(dec, st.data(bytes, pk).ptr, @intCast(pk.len), &pcm, 5760, 0);
        if (got <= 0) return null;
        const next = if (idx + 1 < st.packets.len) st.packets[idx + 1].start else st.end;
        var k: usize = 0;
        while (k < @as(usize, @intCast(got))) : (k += 1) {
            const at = pk.start + k;
            if (at < st.pre_skip or at >= @min(st.end, @max(next, pk.start + 1))) continue;
            const v = pcm[k * st.channels];
            sum += @as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(v));
            peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, v)))));
            if ((prev < 0) != (v < 0)) crossings += 1;
            prev = v;
            n += 1;
        }
    }
    if (n == 0) return null;
    const rms = std.math.sqrt(sum / @as(f64, @floatFromInt(n)));
    const secs = @as(f64, @floatFromInt(n)) / 48000;
    return .{
        .dur_ms = st.durationMs(),
        .samples = n,
        .rms_db = @floatCast(20 * std.math.log10(@max(rms, 0.5) / 32768)),
        .peak = peak,
        .hz = @floatCast(@as(f64, @floatFromInt(crossings)) / 2 / secs),
        .size = bytes.len,
    };
}

var sent_decoded: ?Decoded = null;

fn fileDecodes(_: *App) bool {
    const file = gw.sent.view(&gw.sent.send_file, &gw.sent.send_file_len);
    var pb: [600]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pb, "{s}", .{file}, 0) catch return false;
    var size: usize = 0;
    const data = c.SDL_LoadFile(z.ptr, &size) orelse return false;
    defer c.SDL_free(data);
    // Uma cópia para conferir de fora (ffprobe, ffmpeg).
    _ = c.SDL_SaveFile("qa-out/gravacao-qa.ogg", data, size);
    const dd = decode(@as([*]const u8, @ptrCast(data))[0..size]) orelse return false;
    sent_decoded = dd;
    std.debug.print("  gravação: {d} ms, {d} amostras, {d} bytes, RMS {d:.1} dB, pico {d}\n", .{ dd.dur_ms, dd.samples, dd.size, dd.rms_db, dd.peak });
    // ~2 s de som de verdade: a contagem bate com a granule do fim (até um quadro).
    const want = @as(u64, dd.dur_ms) * 48;
    return dd.dur_ms >= 2000 and dd.dur_ms < 4000 and dd.samples + 960 >= want and dd.samples <= want + 960 and
        dd.rms_db > -45 and dd.peak < 32767;
}

fn echoShown(app: *App) bool {
    const cs = app.store.channel(ours) orelse return false;
    const m = &cs.messages.items[cs.messages.items.len - 1];
    if (m.msg.author != app.store.me or m.msg.id == 0 or m.msg.attachments.len != 1) return false;
    const a = m.msg.attachments[0];
    var mb: [64]u8 = undefined;
    const att = std.fmt.bufPrint(&mb, "att:{d}:0", .{m.msg.id}) catch return false;
    var vb: [64]u8 = undefined;
    const voice = std.fmt.bufPrint(&vb, "voice-play:{d}", .{m.msg.id}) catch return false;
    // Um arquivo comum na conversa (o cartão de arquivo, não o player de voz), a
    // resposta marcada e o rascunho de volta na caixa.
    return std.mem.startsWith(u8, a.filename, "audio-") and std.mem.endsWith(u8, a.filename, ".ogg") and !a.voice and a.size > 1000 and
        m.msg.content.len == 0 and m.msg.reply_to == reply_id and qa.find(att) != null and qa.find(voice) == null and
        std.mem.eql(u8, input(app), draft) and qa.find("composer") != null;
}

fn clearDraft(app: *App) void {
    @memset(&app.st.input, 0);
    app.st.input_sync = true;
}

// --- O codificador sozinho --------------------------------------------------------

fn toneRoundTrip(_: *App) bool {
    const gpa = std.heap.c_allocator;
    // 1,5 s de 440 Hz a meia escala (RMS -9 dB).
    const n = 72_000;
    const pcm = gpa.alloc(i16, n) catch return false;
    defer gpa.free(pcm);
    for (pcm, 0..) |*x, i| x.* = @intFromFloat(@sin(2 * std.math.pi * 440 * @as(f64, @floatFromInt(i)) / 48000) * 16383);
    const bytes = gravar.encodeAll(pcm) catch return false;
    defer gpa.free(bytes);
    _ = c.SDL_SaveFile("qa-out/gravacao-tom.ogg", bytes.ptr, bytes.len);
    const dd = decode(bytes) orelse return false;
    std.debug.print("  tom: {d} ms, {d} amostras, {d} bytes, RMS {d:.2} dB, {d:.1} Hz\n", .{ dd.dur_ms, dd.samples, dd.size, dd.rms_db, dd.hz });
    const dur_ok = @abs(@as(i64, dd.dur_ms) - 1500) <= 20 and dd.samples == n;
    return dur_ok and @abs(dd.rms_db - (-9.03)) < 1.5 and @abs(dd.hz - 440) < 8;
}

// --- Sem permissão, numa call e trocando de conversa ------------------------------

fn openNoFiles(app: *App) void {
    open(app, no_files);
}
fn noFilesLoaded(app: *App) bool {
    return loaded(app, no_files) and qa.find("composer") != null;
}
fn deniedReason(app: *App) bool {
    return toastIs(app, i18n.tr("Você não tem permissão para enviar arquivos neste canal.", "You don't have permission to attach files in this channel.")) and
        gravar.qa_stats.starts.load(.monotonic) == starts0 and !gravar.info().active;
}
fn openReadOnly(app: *App) void {
    open(app, read_only);
}
fn readOnlyNoButton(app: *App) bool {
    return loaded(app, read_only) and qa.find("composer-reason:no_permission") != null and qa.find("composer-record") == null;
}
fn fakeCall(app: *App) void {
    app.st.voice = gw.channelId(0, 13);
}
fn endFakeCall(app: *App) void {
    app.st.voice = null;
}
fn callReason(app: *App) bool {
    return toastIs(app, i18n.tr("Numa call o microfone é dela: saia da call para gravar áudio.", "In a call the microphone is in use: leave the call to record audio.")) and
        gravar.qa_stats.starts.load(.monotonic) == starts0 and !gravar.info().active;
}
fn switchAway(app: *App) void {
    open(app, ours_other);
}
fn leftDiscarded(app: *App) bool {
    return !gravar.info().active and gravar.qa_stats.discards.load(.monotonic) > discards0 and gw.sent.sends.load(.monotonic) == sends0 and
        toastIs(app, i18n.tr("gravação descartada: você saiu da conversa", "recording discarded: you left the conversation"));
}

pub const ops = [_]Op{
    s("gravar áudio: o botão"),
    run(openOurs),
    expect("o #geral do nosso servidor abre", oursLoaded),
    expect("o microfone aparece ao lado das opções, ligado de começo", buttonShown),
    .{ .hover = .{ .mark = "composer-record" } },
    .{ .wait = 700 },
    .{ .shot = "gravar-botao" },
    click("user-btn:2"),
    click("settings:Chat"),
    expect("Configurações → Chat tem a chave do botão", chatPage),
    .{ .shot = "gravar-configuracao" },
    click("toggle:Botão de gravar áudio"),
    expect("desligar a chave", settingOff),
    key(c.ImGuiKey_Escape),
    expect("desligado, o botão some da caixa", buttonHidden),
    run(struct {
        fn f(app: *App) void {
            app.st.settings.record_audio = true;
        }
    }.f),
    expect("ligado de novo, ele volta", buttonShown),

    s("gravar áudio: Cancelar e Esc jogam fora"),
    run(mark),
    click("composer-record"),
    expect("clicar começa: a barra no lugar da caixa, com o tempo e o nível", recording),
    .{ .shot = "gravar-barra" },
    click("record-cancel"),
    expect("Cancelar joga fora: nada vai para o Discord e a caixa volta", discarded),
    run(mark),
    // O atalho de verdade passa pelo ImGui (ui/root.zig → gravar_audio.shortcut).
    .{ .key = .{ .key = c.ImGuiKey_R, .ctrl = true, .shift = true } },
    expect("Ctrl+Shift+R também começa", startedByKey),
    key(c.ImGuiKey_Escape),
    expect("Esc joga fora", discarded),

    s("gravar áudio: enviar"),
    run(draftAndReply),
    expect("com um rascunho na caixa, respondendo a alguém", replying),
    run(mark),
    click("composer-record"),
    .{ .expect = .{ .name = "grava uns 2 s (o sinal do QA no lugar do microfone)", .check = twoSeconds, .timeout_ms = 6000 } },
    .{ .shot = "gravar-2s" },
    click("record-send"),
    expect("Enviar manda um anexo comum: audio-….ogg como audio/ogg, respondendo, sem nada de mensagem de voz", sentOgg),
    expect("o .ogg abre no leitor do app e a libopus decodifica uns 2 s de som", fileDecodes),
    expect("na conversa: o .ogg como arquivo (sem o player de voz), e o rascunho volta para a caixa", echoShown),
    .{ .wait = 200 },
    .{ .shot = "gravar-enviado" },
    run(clearDraft),

    s("gravar áudio: o codificador"),
    expect("um tom de 440 Hz de 1,5 s volta pelo Ogg com a mesma duração (até 20 ms), o mesmo volume e a mesma altura", toneRoundTrip),

    s("gravar áudio: onde não dá"),
    run(mark),
    run(openNoFiles),
    expect("abre o #geral do servidor em que o @everyone não anexa arquivos", noFilesLoaded),
    click("composer-record"),
    expect("o botão diz o motivo e não grava", deniedReason),
    .{ .shot = "gravar-sem-permissao" },
    run(openReadOnly),
    expect("sem permissão de enviar: o motivo no lugar da caixa e nenhum botão", readOnlyNoButton),
    run(openOurs),
    expect("de volta ao nosso servidor", oursLoaded),
    run(fakeCall),
    .{ .wait = 100 },
    click("composer-record"),
    expect("numa call o microfone é dela: o motivo, sem gravar", callReason),
    run(endFakeCall),

    s("gravar áudio: trocar de conversa no meio"),
    run(mark),
    click("composer-record"),
    expect("gravando de novo", recording),
    run(switchAway),
    expect("trocar de conversa joga a gravação fora, com o aviso", leftDiscarded),
};
