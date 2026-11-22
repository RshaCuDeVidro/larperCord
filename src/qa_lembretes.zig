//! QA dos lembretes (QA_SUITE=lembretes): "Me lembrar…" pelo menu do botão direito,
//! a escolha pronta com a anotação, o arquivo, o relógio adiantado (o robô não espera
//! 20 minutos), o aviso na tela, o mascote do canto levando o bilhete, o número em cima
//! do botão das salvas, a notificação do sistema só sem foco e fora do "Não perturbe",
//! adiar, ir para a mensagem, concluir, a aba Lembretes com editar e excluir, outro
//! horário (e o horário que já passou), vários vencidos de uma vez, e o app dormindo
//! até o próximo vencimento em vez de ficar conferindo.
//!
//! lembretes-a e lembretes-b (dois processos, tools/qa.sh): o que fica gravado ao
//! fechar volta ao abrir, e o que venceu com o app fechado avisa logo, atrasado.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const core = @import("core/lembretes.zig");
const ui = @import("ui/lembretes.zig");
const app_lembretes = @import("app_lembretes.zig");
const saved_ui = @import("ui/saved.zig");
const pet = @import("ui/mascote_pet.zig");
const store_mod = @import("core/store.zig");
const Id = @import("core/types.zig").Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn expectLong(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 8000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn dyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .click = .{ .dyn = f } };
}
fn rdyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}

fn ch(i: usize) Id {
    return gw.channelId(0, i);
}

fn now() i64 {
    return ui.clock(gw.nowMs());
}

fn list(app: *App) *core.List {
    return &app.st.lembretes;
}

fn markFmt(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

fn has(comptime fmt: []const u8, args: anytype) bool {
    var b: [64]u8 = undefined;
    return qa.find(markFmt(&b, fmt, args)) != null;
}

// --- As mensagens ------------------------------------------------------------------

/// Até três mensagens de outras pessoas na conversa aberta (a mais recente primeiro).
var msgs: [3]Id = @splat(0);
var channel: Id = 0;
/// O lembrete de cada passo.
var rid: u32 = 0;
var rid2: u32 = 0;
var fired_before: u32 = 0;
var desktop_before: u32 = 0;
var due_before: i64 = 0;
const nota = "ver o PR depois";

fn pickMessages(app: *App) void {
    msgs = @splat(0);
    const id = app.st.activeChannel() orelse return;
    channel = id;
    const cs = app.store.channel(id) orelse return;
    var n: usize = 0;
    var i = cs.messages.items.len;
    while (i > 0 and n < msgs.len) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.author == app.store.me or m.msg.id == 0 or m.msg.system != .none) continue;
        msgs[n] = m.msg.id;
        n += 1;
    }
}
fn messagesPicked(_: *App) bool {
    return msgs[0] != 0 and msgs[1] != 0 and msgs[2] != 0;
}
/// A conversa pode abrir mais acima (na linha das novas, ou ainda rolando): desce até
/// o fim antes de clicar nas mais recentes.
fn toBottom(app: *App) void {
    if (app.st.activeChannel()) |id| app.st.scrollOf(id).stick_bottom = true;
}
/// As três escolhidas estão desenhadas na tela (escolhe de novo a cada olhada: a
/// conversa pode ter mudado desde a primeira).
fn messagesOnScreen(app: *App) bool {
    pickMessages(app);
    if (!messagesPicked(app)) return false;
    for (msgs) |m| if (!has("msg:{d}", .{m})) return false;
    return true;
}
fn tMsg0(_: *App, b: []u8) []const u8 {
    return markFmt(b, "msg:{d}", .{msgs[0]});
}
fn tMsg1(_: *App, b: []u8) []const u8 {
    return markFmt(b, "msg:{d}", .{msgs[1]});
}
fn tMsg2(_: *App, b: []u8) []const u8 {
    return markFmt(b, "msg:{d}", .{msgs[2]});
}

fn clearToast(app: *App) void {
    app.st.toast.len = 0;
}
fn toastHas(app: *App, part: []const u8) bool {
    return app.st.toast.until_ms > gw.nowMs() and std.mem.indexOf(u8, app.st.toast.text(), part) != null;
}

/// O que está no arquivo da conta agora.
fn onDisk(app: *App) ?core.List {
    var buf: [256]u8 = undefined;
    const p = ui.filePath(&buf, app.store.me) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    var l: core.List = .{};
    l.read(app.gpa, @as([*]const u8, @ptrCast(data))[0..size]) catch {
        l.deinit(app.gpa);
        return null;
    };
    return l;
}

// --- Criar pelo menu ------------------------------------------------------------------

fn freshStart(app: *App) void {
    ui.qa_skew_ms = 0;
    app.qa_blur = false;
    clearToast(app);
}
fn emptyList(app: *App) bool {
    return list(app).items.items.len == 0 and app_lembretes.wakeAt() == std.math.maxInt(i64);
}
fn menuOffers(_: *App) bool {
    return qa.find("menu:Me lembrar…") != null;
}
fn editorOpen(app: *App) bool {
    return switch (app.st.popup) {
        .lembrete => |p| p.message == msgs[0] and p.edit == 0 and qa.find("remind-editor") != null and qa.find("remind-preset:amanha") != null,
        else => false,
    };
}
fn created(app: *App) bool {
    const r = list(app).pendingFor(msgs[0]) orelse return false;
    rid = r.id;
    const want = now() + 20 * 60 * 1000;
    return app.st.popup == .none and list(app).items.items.len == 1 and std.mem.eql(u8, r.note, nota) and
        @abs(r.due_ms - want) < 15_000 and r.channel == channel and r.author_name.len > 0 and toastHas(app, "lembrete para");
}
fn savedToDisk(app: *App) bool {
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    const r = l.find(rid) orelse return false;
    return l.items.items.len == 1 and r.message == msgs[0] and std.mem.eql(u8, r.note, nota) and r.due_ms == list(app).find(rid).?.due_ms;
}
fn sleepsUntilDue(app: *App) bool {
    // O laço dorme até o vencimento (no relógio de verdade), em vez de acordar para conferir.
    const r = list(app).find(rid) orelse return false;
    return app_lembretes.wakeAt() == r.due_ms - ui.qa_skew_ms;
}
fn menuEdits(_: *App) bool {
    return qa.find("menu:Editar lembrete…") != null and qa.find("menu:Me lembrar…") == null;
}
fn noBadge(_: *App) bool {
    return qa.find("header-saved-badge:1") == null and qa.find("header-saved-badge:2") == null;
}
fn listUpcoming(_: *App) bool {
    return saved_ui.tab == .lembretes and has("remind-section:proximos:{d}", .{1}) and has("remind-item:{d}", .{rid}) and has("remind-edit:{d}", .{rid});
}
fn savedTabFirst(app: *App) bool {
    return app.st.popup == .saved and saved_ui.tab == .salvas and qa.find("saved-tab:lembretes") != null;
}

// --- O relógio adiantado: venceu -----------------------------------------------------

fn petReady(app: *App) void {
    pet.qaLifeReset(app.images.now_ms);
    pet.qaHome();
}
fn noteCounts(_: *App) void {
    fired_before = ui.fired_n;
    desktop_before = ui.desktop_n;
}
/// O relógio dos lembretes vai até 1 s depois do vencimento de `id`.
fn skipTo(app: *App, id: u32) void {
    const r = list(app).find(id) orelse return;
    ui.qa_skew_ms = r.due_ms - gw.nowMs() + 1000;
}
fn skipToFirst(app: *App) void {
    noteCounts(app);
    skipTo(app, rid);
}
fn noticeShown(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    return ui.fired_n == fired_before + 1 and r.fired_ms != 0 and has("remind-notice:{d}", .{rid}) and qa.find("remind-notice-late") == null;
}
fn petCarries(_: *App) bool {
    return pet.goalNow() == .reminder and (pet.mode() == .trip or pet.mode() == .perch);
}
fn petDelivers(_: *App) bool {
    return pet.goalNow() == .reminder and pet.mode() == .perch and !pet.qaReminderPending();
}
fn badgeOne(_: *App) bool {
    return qa.find("header-saved-badge:1") != null;
}
fn focusedNoDesktop(_: *App) bool {
    return ui.desktop_n == desktop_before;
}

// --- Adiar, sem foco, não perturbe --------------------------------------------------

fn noteDue(app: *App) void {
    clearToast(app);
    due_before = if (list(app).find(rid)) |r| r.due_ms else 0;
}
fn snoozed(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    const want = now() + core.snooze_ms;
    return r.pending() and r.fired_ms == 0 and @abs(r.due_ms - want) < 15_000 and qa.find("remind-notice") == null and
        app_lembretes.dueNow(app) == 0 and toastHas(app, "adiado");
}
fn snoozedOnDisk(app: *App) bool {
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    const r = l.find(rid) orelse return false;
    return r.due_ms == list(app).find(rid).?.due_ms and r.due_ms > due_before;
}
fn blur(app: *App) void {
    app.qa_blur = true;
    noteCounts(app);
    skipTo(app, rid);
}
fn unfocusedDesktop(app: *App) bool {
    return ui.fired_n == fired_before + 1 and ui.desktop_n == desktop_before + 1 and list(app).find(rid).?.fired_ms != 0;
}
fn dndOn(app: *App) void {
    if (app.store.users.getPtr(app.store.me)) |u| u.status = .dnd;
    noteCounts(app);
    skipTo(app, rid);
}
fn dndNoDesktop(app: *App) bool {
    return ui.fired_n == fired_before + 1 and ui.desktop_n == desktop_before and qa.find("remind-notice") != null and list(app).find(rid).?.fired_ms != 0;
}
fn dndOff(app: *App) void {
    if (app.store.users.getPtr(app.store.me)) |u| u.status = .online;
    app.qa_blur = false;
}

// --- Ir para a mensagem e concluir -----------------------------------------------------

fn toOther(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = ch(5), .id = 0 } });
}
fn onOther(app: *App) bool {
    return app.st.activeChannel() == ch(5);
}
fn jumped(app: *App) bool {
    // Abriu o canal da mensagem e foi até ela; o aviso continua até concluir ou adiar.
    return app.st.activeChannel() == channel and app.st.jump == 0 and qa.find("remind-notice") != null and has("msg:{d}", .{msgs[0]});
}
fn concluded(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    return !r.pending() and qa.find("remind-notice") == null and noBadge(app) and app_lembretes.dueNow(app) == 0 and toastHas(app, "concluído");
}
fn toggleList(app: *App) void {
    app.handle(.{ .lembrete = .toggle_list });
}
fn listDone(app: *App) bool {
    return app.st.popup == .saved and saved_ui.tab == .lembretes and has("remind-section:concluidos:{d}", .{1}) and has("remind-delete:{d}", .{rid});
}
fn doneOnDisk(app: *App) bool {
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    const r = l.find(rid) orelse return false;
    return r.done_s != 0;
}

// --- Editar com outro horário ----------------------------------------------------------

fn editorEditing(app: *App) bool {
    return switch (app.st.popup) {
        .lembrete => |p| p.edit == rid and qa.find("remind-editor-delete") != null,
        else => false,
    };
}
fn pickFuture(_: *App) void {
    // Daqui a 3 h (quem roda a esta hora vê o mesmo número).
    ui.qaPick(now() + 3 * 3_600_000);
}
fn reopened(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    const want = now() + 3 * 3_600_000;
    // O "Outro horário" não tem segundos: o minuto cheio.
    return r.pending() and @abs(r.due_ms - want) < 61_000 and app.st.popup == .none and toastHas(app, "lembrete para");
}
fn reopenedListed(_: *App) bool {
    return has("remind-section:proximos:{d}", .{1}) and has("remind-item:{d}", .{rid});
}
fn pickPast(_: *App) void {
    ui.qaPick(now() - 3_600_000);
}
fn pastRefused(app: *App) bool {
    return qa.find("remind-past") != null and switch (app.st.popup) {
        .lembrete => true,
        else => false,
    };
}
fn stillSameDue(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    return r.due_ms == due_before and switch (app.st.popup) {
        .lembrete => true,
        else => false,
    };
}
fn deleted(app: *App) bool {
    return list(app).find(rid) == null and qa.find("remind-empty") != null;
}
fn deletedOnDisk(app: *App) bool {
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    return l.items.items.len == 0;
}

// --- Vários vencidos ---------------------------------------------------------------------

fn twoCreated(app: *App) bool {
    const a = list(app).pendingFor(msgs[1]) orelse return false;
    const b = list(app).pendingFor(msgs[2]) orelse return false;
    rid = a.id;
    rid2 = b.id;
    return list(app).items.items.len == 2;
}
fn skipBoth(app: *App) void {
    noteCounts(app);
    const a = list(app).find(rid) orelse return;
    const b = list(app).find(rid2) orelse return;
    ui.qa_skew_ms = @max(a.due_ms, b.due_ms) - gw.nowMs() + 1000;
}
fn twoDue(_: *App) bool {
    return ui.fired_n == fired_before + 2 and qa.find("header-saved-badge:2") != null and has("remind-notice-more:{d}", .{1}) and has("remind-notice:{d}", .{rid});
}
fn nextInLine(app: *App) bool {
    const a = list(app).find(rid) orelse return false;
    return !a.pending() and has("remind-notice:{d}", .{rid2}) and qa.find("remind-notice-more:1") == null and badgeOne(app);
}
fn allDone(app: *App) bool {
    return app_lembretes.dueNow(app) == 0 and qa.find("remind-notice") == null and noBadge(app) and app_lembretes.wakeAt() == std.math.maxInt(i64);
}
fn headerOpensReminders(app: *App) bool {
    return app.st.popup == .saved and saved_ui.tab == .lembretes;
}
fn closeAll(app: *App) void {
    app.st.popup = .none;
    ui.qa_skew_ms = 0;
}

pub const ops = [_]Op{
    s("lembretes: criar pelo menu do botão direito"),
    run(freshStart),
    expect("começa sem lembretes, e o app sem hora para acordar", emptyList),
    run(toBottom),
    expect("três mensagens de outras pessoas na tela", messagesOnScreen),
    rdyn(tMsg0),
    expect("o menu da mensagem tem \"Me lembrar…\"", menuOffers),
    click("menu:Me lembrar…"),
    expect("abre a janelinha com as escolhas prontas", editorOpen),
    .{ .shot = "lembrete-editor" },
    click("remind-note"),
    .{ .text = nota },
    click("remind-preset:20min"),
    expect("em 20 minutos, com a anotação, e o aviso de confirmação", created),
    expect("o lembrete vai para o arquivo da conta", savedToDisk),
    expect("o app dorme até o vencimento (sem conferir de tempo em tempo)", sleepsUntilDue),
    expect("antes da hora, nada no botão das salvas", noBadge),
    rdyn(tMsg0),
    expect("a mesma mensagem agora oferece \"Editar lembrete…\"", menuEdits),
    key(c.ImGuiKey_Escape),
    click("header-saved"),
    expect("sem nada vencido, o botão abre nas salvas", savedTabFirst),
    click("saved-tab:lembretes"),
    expect("a aba Lembretes mostra o que vem, com editar", listUpcoming),
    .{ .shot = "lembretes-lista-proximos" },
    key(c.ImGuiKey_Escape),

    s("lembretes: venceu"),
    run(petReady),
    run(skipToFirst),
    expectLong("o aviso aparece na tela (sem atraso)", noticeShown),
    expect("o mascote do canto sai com o bilhete", petCarries),
    expectLong("e entrega no aviso", petDelivers),
    .{ .shot = "lembrete-mascote" },
    expect("o número aparece em cima do botão das salvas", badgeOne),
    expect("com a janela em foco, só o aviso (sem notificação do sistema)", focusedNoDesktop),
    .{ .shot = "lembrete-aviso" },

    s("lembretes: adiar, sem foco e não perturbe"),
    run(noteDue),
    click("remind-notice-snooze"),
    expect("Adiar 10 min tira o aviso e volta daqui a 10 minutos", snoozed),
    expect("o adiamento vai para o arquivo", snoozedOnDisk),
    run(blur),
    expectLong("sem foco, venceu de novo e sai a notificação do sistema", unfocusedDesktop),
    click("remind-notice-snooze"),
    run(dndOn),
    expectLong("no não perturbe, só o aviso (nenhuma notificação)", dndNoDesktop),
    run(dndOff),

    s("lembretes: ir para a mensagem e concluir"),
    run(toOther),
    expect("em outro canal", onOther),
    run(clearToast),
    click("remind-notice-open"),
    expectLong("Ir para a mensagem abre o canal nela, e o aviso fica", jumped),
    click("remind-notice-done"),
    expect("Concluir tira o aviso e o número do botão", concluded),
    expect("concluído no arquivo também", doneOnDisk),
    run(toggleList),
    expect("a lista mostra o concluído, com excluir", listDone),
    .{ .shot = "lembretes-lista" },

    s("lembretes: editar com outro horário"),
    dyn(struct {
        fn f(_: *App, b: []u8) []const u8 {
            return markFmt(b, "remind-edit:{d}", .{rid});
        }
    }.f),
    expect("Editar abre a janelinha do lembrete", editorEditing),
    run(pickFuture),
    .{ .wait = 120 },
    .{ .shot = "lembrete-outro-horario" },
    run(clearToast),
    click("remind-create"),
    expect("Salvar com outro horário volta a valer, no minuto escolhido", reopened),
    run(toggleList),
    expect("e ele volta para os próximos", reopenedListed),
    key(c.ImGuiKey_Escape),
    rdyn(tMsg0),
    click("menu:Editar lembrete…"),
    expect("o menu abre o mesmo lembrete", editorEditing),
    run(noteDue),
    run(pickPast),
    expect("um horário que já passou aparece em vermelho", pastRefused),
    click("remind-create"),
    expect("e não salva", stillSameDue),
    click("remind-editor-delete"),
    run(toggleList),
    expect("Excluir tira da lista (fica vazia, com o mascote)", deleted),
    expect("e do arquivo", deletedOnDisk),
    .{ .shot = "lembretes-vazio" },
    key(c.ImGuiKey_Escape),

    s("lembretes: vários de uma vez"),
    rdyn(tMsg1),
    click("menu:Me lembrar…"),
    click("remind-preset:20min"),
    rdyn(tMsg2),
    click("menu:Me lembrar…"),
    click("remind-preset:1h"),
    expect("dois lembretes", twoCreated),
    run(skipBoth),
    expectLong("venceram os dois: um aviso de cada vez, com o número dos outros", twoDue),
    click("header-saved"),
    expect("com algo vencido, o botão abre direto nos lembretes", headerOpensReminders),
    key(c.ImGuiKey_Escape),
    click("remind-notice-done"),
    expect("concluído o primeiro, o próximo toma o lugar", nextInLine),
    click("remind-notice-done"),
    expect("e sem nada vencido, nada de aviso, número ou hora para acordar", allDone),
    run(closeAll),
};

// --- Reabrir: dois processos ------------------------------------------------------------

/// O relógio dos lembretes 2 h atrás: o "em 20 minutos" criado agora já venceu de
/// verdade quando o outro processo abrir.
fn skewBack(app: *App) void {
    freshStart(app);
    ui.qa_skew_ms = -2 * 3_600_000;
}
fn threeCreated(app: *App) bool {
    const a = list(app).pendingFor(msgs[0]) orelse return false;
    const b = list(app).pendingFor(msgs[1]) orelse return false;
    const cc = list(app).pendingFor(msgs[2]) orelse return false;
    rid = a.id;
    rid2 = b.id;
    _ = cc;
    return list(app).items.items.len == 3 and std.mem.eql(u8, a.note, "venceu com o app fechado");
}
fn doneThird(app: *App) void {
    if (list(app).pendingFor(msgs[2])) |r| app.handle(.{ .lembrete = .{ .done = r.id } });
}
fn writtenForLater(app: *App) bool {
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    var done_n: usize = 0;
    for (l.items.items) |*r| {
        if (!r.pending()) done_n += 1;
    }
    // O primeiro já passou no relógio de verdade; o segundo é amanhã.
    const a = l.find(rid) orelse return false;
    return l.items.items.len == 3 and done_n == 1 and a.due_ms < gw.nowMs() and ui.fired_n == 0;
}

pub const ops_a = [_]Op{
    s("lembretes: antes de fechar"),
    run(skewBack),
    run(toBottom),
    expect("três mensagens de outras pessoas na tela", messagesOnScreen),
    rdyn(tMsg0),
    click("menu:Me lembrar…"),
    click("remind-note"),
    .{ .text = "venceu com o app fechado" },
    click("remind-preset:20min"),
    rdyn(tMsg1),
    click("menu:Me lembrar…"),
    click("remind-preset:amanha"),
    rdyn(tMsg2),
    click("menu:Me lembrar…"),
    click("remind-preset:3h"),
    expect("três lembretes, com a anotação", threeCreated),
    run(doneThird),
    expect("gravados (um concluído), nenhum vencido ainda neste processo", writtenForLater),
};

fn loadedBack(app: *App) bool {
    const l = list(app);
    if (l.items.items.len != 3) return false;
    var pend: usize = 0;
    var late_one: ?*core.Reminder = null;
    for (l.items.items) |*r| {
        if (r.pending()) pend += 1;
        if (r.pending() and std.mem.eql(u8, r.note, "venceu com o app fechado")) late_one = r;
    }
    const a = late_one orelse return false;
    rid = a.id;
    return pend == 2 and a.content.len > 0 and a.author_name.len > 0;
}
fn lateOnStart(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    return r.late() and ui.fired_n == 1 and qa.find("remind-notice-late") != null and has("remind-notice:{d}", .{rid}) and badgeOne(app);
}
fn onlyThatOne(app: *App) bool {
    // O de amanhã não avisou, e o app dorme até ele.
    var next: ?*core.Reminder = null;
    for (list(app).items.items) |*r| {
        if (r.pending() and r.id != rid) next = r;
    }
    const n = next orelse return false;
    return n.fired_ms == 0 and n.due_ms > now() and app_lembretes.wakeAt() == n.due_ms;
}
fn lateJumped(app: *App) bool {
    // A mensagem guardada continua apontando para a certa depois de reabrir.
    const r = list(app).find(rid) orelse return false;
    return app.st.activeChannel() == r.channel and app.st.jump == 0 and has("msg:{d}", .{r.message}) and qa.find("remind-notice") != null;
}
fn lateDone(app: *App) bool {
    const r = list(app).find(rid) orelse return false;
    if (r.pending() or qa.find("remind-notice") != null) return false;
    var l = onDisk(app) orelse return false;
    defer l.deinit(app.gpa);
    const d = l.find(rid) orelse return false;
    return d.done_s != 0;
}

pub const ops_b = [_]Op{
    s("lembretes: depois de reabrir"),
    expect("os três voltam do arquivo (dois pendentes, um concluído)", loadedBack),
    expectLong("o que venceu com o app fechado avisa ao abrir, atrasado", lateOnStart),
    .{ .shot = "lembrete-atrasado" },
    expect("o de amanhã espera, e o app dorme até ele", onlyThatOne),
    run(toOther),
    expect("em outro canal", onOther),
    click("remind-notice-open"),
    expectLong("Ir para a mensagem ainda acha a mensagem certa", lateJumped),
    click("remind-notice-done"),
    expect("concluir o atrasado vai para o arquivo", lateDone),
};
