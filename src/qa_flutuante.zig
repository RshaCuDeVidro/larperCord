//! QA da janela flutuante (app_flutuante.zig): abre pelo menu da aba com a conversa, a
//! mensagem nova aparece nela, a caixa dela manda (o gateway de mentira recebe), o botão
//! de voltar abre a conversa na principal, a call vai para a mesma janela pelo botão da
//! tela da call e muta por ela, a principal vai para a bandeja e ela continua, parada não
//! faz quadro, e fechar solta tudo e a principal volta a pular os quadros iguais. Tudo no
//! driver offscreen do SDL: a janela flutuante também é de mentira aqui, e os prints dela
//! saem da superfície dela.
//!
//! `QA_SUITE=flutuante` roda isto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const platform = @import("platform/window.zig");
const tray = @import("platform/tray.zig");
const popup = @import("ui/popup.zig");
const ui = @import("ui/flutuante.zig");
const pip = @import("app_flutuante.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

const g0: Id = gw.guildId(0);
const call0: Id = gw.channelId(0, 13);
const me: Id = 1000;
const ana: Id = 1001;
const kaique: Id = 1003;
const duda: Id = 1005;

/// A conversa que vai para a janela flutuante (a aba aberta no começo).
var conversa: Id = 0;
var main_ctx: ?*c.ImGuiContext = null;
var main_input: [64]u8 = @splat(0);
var novo: Id = 0;
/// O atlas das fontes (compartilhado com a principal) e o que o malloc tem em uso: para
/// separar o custo da janela do das letras novas que ela desenhou.
fn atlasKb(app: *App) u32 {
    const t = app.io.*.Fonts.*.TexData;
    if (t == null) return 0;
    return @intCast(@divTrunc(@as(i64, t.*.Width) * t.*.Height * t.*.BytesPerPixel, 1024));
}
fn heapKb() u32 {
    return if (@import("platform/mem_tune.zig").heap()) |h| h.used_kb else 0;
}
var atlas_antes: u32 = 0;
var heap_antes: u32 = 0;

/// Memória (PSS) antes de abrir, aberta, e antes e depois de fechar.
var pss_antes: u32 = 0;
var pss_aberta: u32 = 0;
var pss_antes_fechar: u32 = 0;
var pip_quadros: u64 = 0;
var pip_desenhados: u64 = 0;
var main_feitos: u64 = 0;
var main_pulados: u64 = 0;
var gate_feitos: u64 = 0;
var gate_pulados: u64 = 0;

fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn windowCount() usize {
    var n: c_int = 0;
    const list = c.SDL_GetWindows(&n);
    if (list != null) c.SDL_free(@ptrCast(list));
    return @intCast(@max(n, 0));
}

fn pipOn(_: *App) void {
    R.pip_mode = true;
}
fn pipOff(_: *App) void {
    R.pip_mode = false;
}

fn markFmt(comptime fmt: []const u8, args: anytype) ?@import("theme/layout.zig").Rect {
    var buf: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&buf, fmt, args) catch return null);
}

fn lastOf(app: *App, ch: Id) ?*@import("core/store.zig").StoredMessage {
    const cs = app.store.channel(ch) orelse return null;
    if (cs.messages.items.len == 0) return null;
    return &cs.messages.items[cs.messages.items.len - 1];
}

// --- Abrir pela aba -----------------------------------------------------------

fn openGuild0(app: *App) void {
    app.handle(.{ .select_guild = g0 });
}
fn onText(app: *App) bool {
    const ch = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(ch) orelse return false;
    return app.st.guild == g0 and cs.history == .loaded and cs.info.kind == .text and qa.find("composer") != null;
}
fn rememberBase(app: *App) void {
    main_ctx = c.ImGui_GetCurrentContext();
    const t = std.mem.sliceTo(&app.st.input, 0);
    @memset(&main_input, 0);
    @memcpy(main_input[0..@min(t.len, main_input.len - 1)], t[0..@min(t.len, main_input.len - 1)]);
}
/// A aba da conversa da janela flutuante.
fn tTextTab(app: *App, b: []u8) []const u8 {
    for (app.st.tabs.items, 0..) |id, i| if (id == conversa) return std.fmt.bufPrint(b, "tab:{d}", .{i}) catch "";
    return "";
}
fn menuHasPip(app: *App) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .tabs and m.id == conversa and qa.find("menu:Abrir em janela flutuante") != null,
        else => false,
    };
}
fn pipOpenConversa(app: *App) bool {
    const win = app.pip.win orelse return false;
    const flags = c.SDL_GetWindowFlags(win);
    const title = std.mem.span(@as([*:0]const u8, @ptrCast(c.SDL_GetWindowTitle(win))));
    const cs = app.store.channel(conversa) orelse return false;
    return std.meta.eql(app.pip.alvo, .{ .conversa = conversa }) and flags & c.SDL_WINDOW_ALWAYS_ON_TOP != 0 and
        flags & c.SDL_WINDOW_RESIZABLE != 0 and windowCount() == 2 and ui.aberta and app.st.popup == .none and
        std.mem.indexOf(u8, title, cs.info.name) != null;
}
fn pipMarks(app: *App) bool {
    const last = lastOf(app, conversa) orelse return false;
    const win = qa.find("pip/window:conversa") orelse return false;
    const m = markFmt("pip/msg:{d}", .{last.msg.id}) orelse return false;
    const box = qa.find("pip/composer") orelse return false;
    // A última mensagem acima da caixa, dentro da janela dela (coordenadas da flutuante).
    return qa.find("pip/title") != null and qa.find("pip/back") != null and qa.find("pip/close") != null and
        m.bottom() <= box.y + 1 and box.bottom() <= win.bottom() + 1 and win.w < 800;
}
var main_active: Id = 0;
fn rememberActive(app: *App) void {
    main_active = app.st.activeChannel() orelse 0;
    conversa = main_active;
    pss_antes = platform.selfMemKb().pss;
    atlas_antes = atlasKb(app);
    heap_antes = heapKb();
}
fn menuOfChannel(app: *App) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .channel and m.id == conversa and qa.find("menu:Abrir em janela flutuante") != null,
        else => false,
    };
}
fn setTabs(app: *App, on: bool) void {
    const th = app.themes.theme_();
    for (th.options, 0..) |o, i| if (std.mem.eql(u8, o.name, "abas")) app.handle(.{ .set_theme_option = .{ .index = i, .value = on } });
}
fn tabsOn(app: *App) void {
    setTabs(app, true);
}
fn tabsOff(app: *App) void {
    setTabs(app, false);
}
fn tabsShown(_: *App) bool {
    return qa.find("tabs-bar") != null;
}
fn menuClosed(app: *App) bool {
    return app.st.popup == .none;
}
fn memOpen(app: *App) void {
    pss_aberta = platform.selfMemKb().pss;
    std.debug.print("    abrir: PSS {d} -> {d} KB; malloc em uso {d} -> {d} KB; atlas das fontes {d} -> {d} KB\n", .{ pss_antes, pss_aberta, heap_antes, heapKb(), atlas_antes, atlasKb(app) });
    // Quem mostra a imagem dela: nenhum renderizador próprio fora do Wayland.
    const main_r = if (c.SDL_GetRendererName(app.win.renderer)) |n| std.mem.span(n) else "?";
    const own = if (app.pip.win) |w| c.SDL_GetRenderer(w) else null;
    std.debug.print("    renderizador da principal: {s}; da flutuante: {s}\n", .{ main_r, if (own) |r| std.mem.span(c.SDL_GetRendererName(r)) else "nenhum (superfície da janela)" });
}
fn noOwnRenderer(app: *App) bool {
    const w = app.pip.win orelse return false;
    return c.SDL_GetRenderer(w) == null;
}
fn mainUntouched(app: *App) bool {
    return app.st.activeChannel() == main_active and std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), std.mem.sliceTo(&main_input, 0)) and
        c.ImGui_GetCurrentContext() == main_ctx and qa.find("composer") != null;
}
fn shotConversa(app: *App) void {
    _ = pip.shot(app, "qa-out/flutuante-conversa.png");
}

// --- Mensagem nova ao vivo ------------------------------------------------------

fn injectNew(app: *App) void {
    const ca = std.heap.c_allocator;
    novo = types.makeSnowflake(gw.nowMs(), 0x7f1a7);
    const content = ca.dupe(u8, "chegou na janela flutuante") catch return;
    push(app, .{ .message_create = .{ .id = novo, .channel = conversa, .author = kaique, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
}
fn newInPip(_: *App) bool {
    // Na parte de baixo da lista, à vista (o demo ao vivo pode mandar outra logo depois).
    var buf: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&buf, "pip/msg:{d}", .{novo}) catch return false;
    const m = qa.visiblePart(k) orelse return false;
    const box = qa.find("pip/composer") orelse return false;
    return m.bottom() <= box.y + 1 and m.h > 4;
}

// --- Responder pela caixa dela --------------------------------------------------

const enviado = "mandei da janela flutuante";
var sends0: u64 = 0;
var pip_sends0: u32 = 0;
fn rememberSends(_: *App) void {
    sends0 = gw.sent.sends.load(.monotonic);
    pip_sends0 = pip.medidas.enviadas;
}
fn pipSent(app: *App) bool {
    const cs = app.store.channel(conversa) orelse return false;
    const body = gw.sent.view(&gw.sent.send_body, &gw.sent.send_body_len);
    // Confirmada pelo gateway (não mais pendente), na conversa da janela flutuante.
    const found = for (cs.messages.items) |*m| {
        if (m.msg.author == app.store.me and !m.pending and std.mem.eql(u8, m.msg.content, enviado)) break true;
    } else false;
    // Pela caixa da janela flutuante (`send_to`), não pela da principal.
    return found and pip.medidas.enviadas == pip_sends0 + 1 and gw.sent.sends.load(.monotonic) == sends0 + 1 and
        std.mem.indexOf(u8, body, enviado) != null;
}
fn boxesClean(app: *App) bool {
    return app.pip.estado.input[0] == 0 and std.mem.eql(u8, std.mem.sliceTo(&app.st.input, 0), std.mem.sliceTo(&main_input, 0)) and
        qa.find("pip/composer") != null;
}

// --- Voltar para a principal ----------------------------------------------------

fn otherChannel(app: *App) void {
    app.handle(.{ .select_channel = gw.channelId(0, 1) });
}
fn onOther(app: *App) bool {
    return app.st.activeChannel() == gw.channelId(0, 1) and app.st.activeChannel() != conversa;
}
fn backOpened(app: *App) bool {
    return app.st.activeChannel() == conversa and app.pip.win != null;
}

// --- Call -----------------------------------------------------------------------

fn joinCall(app: *App) void {
    app.handle(.{ .select_guild = g0 });
    if (app.st.voice != call0) app.handle(.{ .toggle_voice = call0 });
    const cs = app.store.channel(call0) orelse return;
    for ([_]Id{ ana, duda, kaique }) |uid| if (std.mem.indexOfScalar(Id, cs.voice_members.items, uid) == null)
        push(app, .{ .voice_state = .{ .channel = call0, .user = uid } });
}
fn showCall(app: *App) void {
    app.handle(.{ .show_call = call0 });
}
fn callView(app: *App) bool {
    return app.st.voice == call0 and app.st.call_view and qa.find("grid-view") != null and qa.find("pip-call") != null;
}
fn pipCall(app: *App) bool {
    return std.meta.eql(app.pip.alvo, .{ .call = call0 }) and windowCount() == 2 and qa.find("pip/window:call") != null and
        qa.find("pip/grid-mic") != null and qa.find("pip/grid-deaf") != null and qa.find("pip/grid-leave") != null and
        markFmt("pip/grid-tile:{d}", .{me}) != null and markFmt("pip/grid-tile:{d}", .{ana}) != null and qa.find("pip/composer") == null;
}
fn muted(app: *App) bool {
    return app.st.muted and !app.st.deafened;
}
fn unmuted(app: *App) bool {
    return !app.st.muted and !app.st.deafened;
}
fn deafened(app: *App) bool {
    return app.st.deafened;
}
fn undeafened(app: *App) bool {
    return !app.st.deafened;
}
fn shotCall(app: *App) void {
    _ = pip.shot(app, "qa-out/flutuante-call.png");
}

// --- Com a principal na bandeja -------------------------------------------------

fn toTray(app: *App) void {
    tray.fake = true;
    app.st.settings.close_to_tray = true;
    var e = std.mem.zeroes(c.SDL_Event);
    e.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    e.window.windowID = c.SDL_GetWindowID(app.win.window);
    _ = c.SDL_PushEvent(&e);
}
fn hiddenPipOpen(app: *App) bool {
    const win = app.pip.win orelse return false;
    return c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_HIDDEN != 0 and app.in_tray and
        c.SDL_GetWindowFlags(win) & c.SDL_WINDOW_HIDDEN == 0;
}
fn speakDuda(app: *App) void {
    push(app, .{ .voice_speaking = .{ .user = duda, .speaking = true } });
}
fn speakingInPip(app: *App) bool {
    return markFmt("pip/grid-speaking:{d}", .{duda}) != null and app.pip.win != null;
}
fn wakeShow(app: *App) void {
    platform.Window.wake(app.win.wake_type, .show);
}
fn shownAgain(app: *App) bool {
    return c.SDL_GetWindowFlags(app.win.window) & c.SDL_WINDOW_HIDDEN == 0 and !app.in_tray and app.pip.win != null;
}

// --- De volta à conversa, e a call que acaba --------------------------------------

fn backToConversa(app: *App) void {
    app.handle(.{ .flutuante = .{ .abrir = .{ .conversa = conversa } } });
}
fn pipOnConversa(app: *App) bool {
    return std.meta.eql(app.pip.alvo, .{ .conversa = conversa }) and windowCount() == 2 and
        qa.find("pip/composer") != null and qa.find("pip/grid-view") == null;
}
fn leaveCall(app: *App) void {
    app.handle(.leave_voice);
}
fn stillConversa(app: *App) bool {
    return app.st.voice == null and pipOnConversa(app);
}
fn openPipCall(app: *App) void {
    app.handle(.{ .flutuante = .{ .abrir = .{ .call = call0 } } });
}
fn pipOnCall(app: *App) bool {
    return std.meta.eql(app.pip.alvo, .{ .call = call0 }) and qa.find("pip/grid-view") != null;
}

// --- Parada não desenha ---------------------------------------------------------

fn idleStart(app: *App) void {
    app.qa_real_gate = true;
    pip_quadros = pip.medidas.quadros;
    pip_desenhados = pip.medidas.desenhados;
    main_feitos = app.gate.built;
}
fn idleStop(app: *App) void {
    app.qa_real_gate = false;
    pip_quadros = pip.medidas.quadros - pip_quadros;
    pip_desenhados = pip.medidas.desenhados - pip_desenhados;
    main_feitos = app.gate.built - main_feitos;
    std.debug.print("    parada por 1,5 s: a principal fez {d} quadros, a flutuante {d} (desenhou {d})\n", .{ main_feitos, pip_quadros, pip_desenhados });
}
fn idleOk(_: *App) bool {
    // O demo ao vivo manda um "digitando" ou uma mensagem de vez em quando: alguns
    // quadros dela são de verdade. Um por volta do laço seria um por quadro da principal.
    return main_feitos >= 20 and pip_quadros <= 6 and pip_desenhados <= pip_quadros;
}

// --- Fechar ---------------------------------------------------------------------

fn rememberOpenMem(app: *App) void {
    pss_antes_fechar = platform.selfMemKb().pss;
    heap_antes = heapKb();
    atlas_antes = atlasKb(app);
}
fn released(app: *App) bool {
    const p = &app.pip;
    return p.win == null and p.ctx == null and p.io == null and p.tex == null and windowCount() == 1 and
        c.ImGui_GetCurrentContext() == main_ctx and !popup.in_pip and !ui.aberta and qa.find("pip/close") == null and
        app.st.settings.pip_w > 0 and app.st.settings.pip_h > 0;
}
fn gateOn(app: *App) void {
    app.qa_real_gate = true;
    gate_feitos = app.gate.built;
    gate_pulados = app.gate.skipped;
    pip_quadros = pip.medidas.quadros;
}
fn gateOff(app: *App) void {
    app.qa_real_gate = false;
    gate_feitos = app.gate.built - gate_feitos;
    gate_pulados = app.gate.skipped - gate_pulados;
    pip_quadros = pip.medidas.quadros - pip_quadros;
    std.debug.print("    fechada, em 1,2 s: a principal fez {d} quadros e pulou {d}; a flutuante fez {d}\n", .{ gate_feitos, gate_pulados, pip_quadros });
}
fn mainSkips(_: *App) bool {
    // Parada, quase todo quadro é igual ao anterior e não vai para a tela; e nenhum
    // quadro da flutuante, que não existe mais.
    return gate_feitos >= 20 and gate_pulados * 10 >= gate_feitos * 8 and pip_quadros == 0;
}
fn printMeasures(app: *App) void {
    const agora = platform.selfMemKb().pss;
    const m = pip.medidas;
    std.debug.print("    fechar: PSS {d} -> {d} KB; malloc em uso {d} -> {d} KB; atlas das fontes {d} -> {d} KB\n", .{ pss_antes_fechar, agora, heap_antes, heapKb(), atlas_antes, atlasKb(app) });
    if (m.quadros > 0) std.debug.print("    janela flutuante: {d} quadros, {d} desenhados, média {d} µs por quadro (montar + ler os pixels)\n", .{ m.quadros, m.desenhados, m.us / m.quadros });
}

// --- Lembra o tamanho -----------------------------------------------------------

var saved_w: i16 = 0;
var saved_h: i16 = 0;
fn reopen(app: *App) void {
    saved_w = app.st.settings.pip_w;
    saved_h = app.st.settings.pip_h;
    app.handle(.{ .flutuante = .{ .abrir = .{ .conversa = conversa } } });
}
fn sameSize(app: *App) bool {
    const win = app.pip.win orelse return false;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(win, &w, &h);
    return w == saved_w and h == saved_h and saved_w > 0;
}
fn closeIt(app: *App) void {
    app.handle(.{ .flutuante = .fechar });
}
fn closed(app: *App) bool {
    return app.pip.win == null and windowCount() == 1;
}
fn resizePip(app: *App) void {
    if (app.pip.win) |w| _ = c.SDL_SetWindowSize(w, 420, 560);
}
fn resizedRemembered(app: *App) bool {
    return app.st.settings.pip_w == 420 and app.st.settings.pip_h == 560;
}

pub const ops = [_]Op{
    s("janela flutuante: abrir pela aba"),
    run(openGuild0),
    expect("a conversa do servidor está aberta", onText),
    run(rememberBase),
    run(rememberActive),
    .{ .rclick = .{ .mark = "header-title" } },
    expect("o botão direito no nome da conversa (cabeçalho) abre o menu dela, com \"Abrir em janela flutuante\"", menuOfChannel),
    click("menu:Abrir em janela flutuante"),
    expect("abre uma janela à parte, sempre por cima e redimensionável, com a conversa", pipOpenConversa),
    expect("a vista compacta: o nome, as últimas mensagens e a caixa", pipMarks),
    expect("a principal continua como estava (a aba, a caixa dela, o contexto do ImGui)", mainUntouched),
    .{ .wait = 300 },
    run(shotConversa),
    run(memOpen),
    expect("a janela flutuante não ganha um renderizador (nem contexto de GPU) só dela", noOwnRenderer),

    s("janela flutuante: pelo menu da aba também"),
    run(tabsOn),
    expect("com as abas do tema ligadas", tabsShown),
    .{ .rclick = .{ .dyn = tTextTab } },
    expect("o menu da aba (o dos conjuntos) tem \"Abrir em janela flutuante\" para a conversa dela", menuHasPip),
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o menu", menuClosed),
    run(tabsOff),

    s("janela flutuante: mensagem nova ao vivo"),
    run(injectNew),
    expect("a mensagem que chegou aparece embaixo na janela flutuante", newInPip),

    s("janela flutuante: responder pela caixa dela"),
    run(rememberSends),
    run(pipOn),
    click("pip/composer"),
    .{ .text = enviado },
    key(c.ImGuiKey_Enter),
    run(pipOff),
    expect("a mensagem sai na conversa dela e o gateway recebe", pipSent),
    expect("a caixa dela esvazia e a da principal fica como estava", boxesClean),
    run(resizePip),
    expect("o tamanho novo fica guardado", resizedRemembered),

    s("janela flutuante: voltar para a principal"),
    run(otherChannel),
    expect("a principal está em outra conversa", onOther),
    run(pipOn),
    click("pip/back"),
    run(pipOff),
    expect("o botão de voltar abre a conversa dela na principal", backOpened),

    s("janela flutuante: call"),
    run(joinCall),
    run(showCall),
    expect("na call, com a tela dela e o botão da janela flutuante", callView),
    click("pip-call"),
    expect("a call vai para a mesma janela flutuante: os quadros e os botões, sem caixa", pipCall),
    run(pipOn),
    click("pip/grid-mic"),
    expect("o microfone da janela flutuante muta", muted),
    click("pip/grid-mic"),
    expect("e desmuta", unmuted),
    click("pip/grid-deaf"),
    expect("o fone ensurdece", deafened),
    click("pip/grid-deaf"),
    expect("e volta a ouvir", undeafened),
    run(pipOff),
    .{ .wait = 300 },
    run(shotCall),

    s("janela flutuante: com a principal na bandeja"),
    run(toTray),
    expect("a principal vai para a bandeja e a flutuante continua aberta", hiddenPipOpen),
    run(speakDuda),
    expect("quem fala aparece na janela flutuante com a principal escondida", speakingInPip),
    run(wakeShow),
    expect("a principal volta da bandeja e a flutuante continua", shownAgain),

    s("janela flutuante: de volta à conversa"),
    run(backToConversa),
    expect("a mesma janela volta para a conversa", pipOnConversa),
    run(leaveCall),
    expect("sair da call não fecha a janela da conversa", stillConversa),

    s("janela flutuante: parada não faz quadro"),
    .{ .wait = 1500 },
    run(idleStart),
    .{ .wait = 1500 },
    run(idleStop),
    expect("parada, a flutuante quase não monta quadro (a principal monta sem parar no QA)", idleOk),

    s("janela flutuante: fechar devolve tudo"),
    run(rememberOpenMem),
    run(pipOn),
    click("pip/close"),
    run(pipOff),
    expect("fechar solta a janela, o contexto do ImGui e a textura, e guarda o lugar", released),
    run(gateOn),
    .{ .wait = 1200 },
    run(gateOff),
    expect("a principal volta a pular os quadros iguais, e a flutuante não faz mais nenhum", mainSkips),
    // O tique de 2 s devolve ao sistema o que o malloc soltou (`trim_wanted`).
    .{ .wait = 2500 },
    run(printMeasures),

    s("janela flutuante: lembra o tamanho"),
    run(reopen),
    expect("abre de novo com o tamanho de antes", sameSize),
    run(closeIt),
    expect("e fecha pela ação também", closed),

    s("janela flutuante: a call acaba e ela fecha sozinha"),
    run(joinCall),
    run(openPipCall),
    expect("a call na janela flutuante", pipOnCall),
    run(leaveCall),
    expect("saiu da call: a janela flutuante dela fecha sozinha", closed),
};
