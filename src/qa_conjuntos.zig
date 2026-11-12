//! QA dos conjuntos de abas (QA_SUITE=abas-conjuntos): salvar as abas com um nome
//! pelo menu da barra de abas, guardar sozinho o que muda enquanto um está em uso,
//! trocar pelo menu, pela paleta e pelo atalho (com a aba ativa e a tela dividida de
//! volta), renomear, excluir, sair, o canal que sumiu (fica de fora, com aviso), o
//! arquivo depois de "reabrir" o app, cada conta com os seus, e a troca sem rajada:
//! num conjunto de 10 abas, só o canal que aparece pede o histórico.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const cj = @import("core/conjuntos.zig");
const ui_cj = @import("ui/conjuntos.zig");
const app_cj = @import("app_conjuntos.zig");
const mosaic = @import("ui/mosaic.zig");
const acc_store = @import("net/accounts_store.zig");
const Id = @import("core/types.zig").Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn rclick(k: []const u8) Op {
    return .{ .rclick = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}
fn key(k: c_int, ctrl: bool, shift: bool) Op {
    return .{ .key = .{ .key = k, .ctrl = ctrl, .shift = shift } };
}

fn ch(i: usize) Id {
    return gw.channelId(0, i);
}

const conta_a: Id = 1000;
const conta_b: Id = 7001;
/// Um canal que nunca existiu e o #bugs do segundo servidor, que não dá para ver.
const sumido: Id = 999_999_001;
fn semAcesso() Id {
    return gw.channelId(1, 11);
}

fn list(app: *App) *cj.List {
    return &app.st.conjuntos;
}
fn setNamed(app: *App, name: []const u8) ?*cj.Set {
    const i = list(app).find(name) orelse return null;
    return &list(app).sets.items[i];
}
fn activeIs(app: *App, name: []const u8) bool {
    const set = list(app).activeSet() orelse return false;
    return std.mem.eql(u8, set.name, name);
}
fn tabsAre(app: *App, want: []const Id, tab: usize) bool {
    return std.mem.eql(Id, app.st.tabs.items, want) and app.st.tab == tab and app.st.activeChannel() == want[tab];
}
fn abasAre(set: *const cj.Set, want: []const Id, tab: usize) bool {
    return std.mem.eql(Id, set.abas.ids.items, want) and set.abas.tab == tab;
}

/// O arquivo da conta, lido de novo do disco.
var file_list: cj.List = .{};
fn readFile(owner: Id) ?*cj.List {
    var buf: [256]u8 = undefined;
    const p = ui_cj.filePath(&buf, owner) orelse return null;
    var size: usize = 0;
    const data = c.SDL_LoadFile(p.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    file_list.read(std.heap.c_allocator, @as([*]const u8, @ptrCast(data))[0..size]) catch return null;
    return &file_list;
}
fn fileTabs(owner: Id, name: []const u8) ?[]const Id {
    const l = readFile(owner) orelse return null;
    const i = l.find(name) orelse return null;
    return l.sets.items[i].abas.ids.items;
}
fn deleteFile(owner: Id) void {
    var buf: [256]u8 = undefined;
    const p = ui_cj.filePath(&buf, owner) orelse return;
    _ = c.SDL_RemovePath(p.ptr);
}

// --- Preparo -----------------------------------------------------------------------

fn ready(app: *App) bool {
    const id = app.st.activeChannel() orelse return false;
    const cs = app.store.channel(id) orelse return false;
    return app.store.ready and cs.history == .loaded;
}

var abas_before: ?bool = null;

fn prepare(app: *App) void {
    // A barra de abas aparece em qualquer tema (no clássico ela vem desligada).
    abas_before = app.themes.theme_().option("abas");
    if (abas_before) |on| if (!on) {
        _ = app.themes.setOption("abas", true);
    };
    deleteFile(conta_a);
    deleteFile(conta_b);
    ui_cj.qa_read = true;
    app_cj.reset(app);
    _ = app_cj.ready(app);
}
fn prepared(app: *App) bool {
    return app.store.ready and list(app).owner == conta_a and list(app).sets.items.len == 0 and
        tabsAre(app, &.{ ch(4), ch(9), ch(5) }, 0) and qa.find("tabs-bar") != null and qa.find("tabset-chip") == null;
}

// --- Salvar ------------------------------------------------------------------------

fn menuOpen(app: *App) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .tabs and qa.find("menu:Salvar abas como conjunto…") != null,
        else => false,
    };
}
fn emptyMenu(app: *App) bool {
    return menuOpen(app) and qa.find("menu:Sair do conjunto") == null and qa.find("menu:Renomear conjunto…") == null;
}
fn nameOpen(app: *App) bool {
    return switch (app.st.popup) {
        .tab_set_name => |t| t.rename == null and qa.find("tabset-name") != null,
        else => false,
    };
}
fn nameStillOpen(app: *App) bool {
    return nameOpen(app) and list(app).sets.items.len == 0;
}
fn savedWork(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    const l = list(app);
    return app.st.popup == .none and l.sets.items.len == 1 and activeIs(app, "trabalho") and
        abasAre(set, &.{ ch(4), ch(9), ch(5) }, 0) and std.mem.eql(Id, l.loose.ids.items, &.{ ch(4), ch(9), ch(5) });
}
fn fileHasWork(_: *App) bool {
    const t = fileTabs(conta_a, "trabalho") orelse return false;
    return std.mem.eql(Id, t, &.{ ch(4), ch(9), ch(5) });
}
fn chipShown(_: *App) bool {
    return qa.find("tabset-chip") != null;
}

// --- Guardar sozinho ---------------------------------------------------------------

fn workGotTab(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    const t = fileTabs(conta_a, "trabalho") orelse return false;
    return abasAre(set, &.{ ch(4), ch(9), ch(5), ch(6) }, 3) and std.mem.eql(Id, t, set.abas.ids.items);
}
fn workTab1(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    return set.abas.tab == 1 and app.st.activeChannel() == ch(9);
}
fn workClosed(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    const t = fileTabs(conta_a, "trabalho") orelse return false;
    return tabsAre(app, &.{ ch(4), ch(5), ch(6) }, 1) and abasAre(set, &.{ ch(4), ch(5), ch(6) }, 1) and std.mem.eql(Id, t, set.abas.ids.items);
}

// --- Segundo conjunto --------------------------------------------------------------

fn nameOpenAgain(app: *App) bool {
    return switch (app.st.popup) {
        .tab_set_name => |t| t.rename == null and qa.find("tabset-name") != null,
        else => false,
    };
}
fn savedGame(app: *App) bool {
    const game = setNamed(app, "jogo") orelse return false;
    const work = setNamed(app, "trabalho") orelse return false;
    return activeIs(app, "jogo") and abasAre(game, &.{ ch(4), ch(5), ch(6) }, 1) and abasAre(work, &.{ ch(4), ch(5), ch(6) }, 1) and
        // As soltas continuam as de antes do primeiro conjunto.
        std.mem.eql(Id, list(app).loose.ids.items, &.{ ch(4), ch(9), ch(5) });
}
fn gameOneTab(app: *App) bool {
    return tabsAre(app, &.{ch(4)}, 0);
}
fn twoSets(app: *App) bool {
    const game = setNamed(app, "jogo") orelse return false;
    const work = setNamed(app, "trabalho") orelse return false;
    return tabsAre(app, &.{ ch(9), ch(10) }, 0) and abasAre(game, &.{ ch(9), ch(10) }, 0) and abasAre(work, &.{ ch(4), ch(5), ch(6) }, 1);
}
fn menuTwoSets(app: *App) bool {
    return menuOpen(app) and qa.find("menu:trabalho") != null and qa.find("menu-on:jogo") != null and qa.find("menu-on:trabalho") == null and
        qa.find("menu:Renomear conjunto…") != null and qa.find("menu:Sair do conjunto") != null and qa.find("menu:Excluir conjunto") != null;
}
fn popupClosed(app: *App) bool {
    return app.st.popup == .none and !app.st.palette.open;
}

// --- Trocar ------------------------------------------------------------------------

fn onWork(app: *App) bool {
    const game = setNamed(app, "jogo") orelse return false;
    return activeIs(app, "trabalho") and tabsAre(app, &.{ ch(4), ch(5), ch(6) }, 1) and abasAre(game, &.{ ch(9), ch(10) }, 0);
}
fn paletteShowsGame(app: *App) bool {
    const p = &app.st.palette;
    if (!p.open or p.items.items.len == 0) return false;
    const first = p.items.items[0];
    return first.kind == .tab_set and first.index == list(app).find("jogo").? and qa.find("palette-item:0") != null;
}
/// A busca da paleta no idioma da interface ("Conjunto: jogo", "Tab set: jogo"…).
fn typeQuery(app: *App, name: []const u8) void {
    var buf: [96]u8 = undefined;
    var z: [97]u8 = undefined;
    const q = @import("ui/i18n.zig").fmt(&buf, "Conjunto: {s}", "Tab set: {s}", .{name});
    @memcpy(z[0..q.len], q);
    z[q.len] = 0;
    c.ImGuiIO_AddInputCharactersUTF8(app.io, &z);
}
fn queryGame(app: *App) void {
    typeQuery(app, "jogo");
}
fn queryTrampo(app: *App) void {
    typeQuery(app, "trampo");
}
fn onGame(app: *App) bool {
    return activeIs(app, "jogo") and tabsAre(app, &.{ ch(9), ch(10) }, 0) and !app.st.palette.open;
}
fn onWorkAgain(app: *App) bool {
    return activeIs(app, "trabalho") and tabsAre(app, &.{ ch(4), ch(5), ch(6) }, 1);
}

// --- Tela dividida -----------------------------------------------------------------

fn channelMenu(app: *App) bool {
    return switch (app.st.popup) {
        .menu => |m| m.kind == .channel and qa.find("menu:Abrir ao lado") != null,
        else => false,
    };
}
fn splitSaved(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    const sp = set.abas.split;
    return mosaic.panes.count == 2 and sp.count == 2 and sp.ids[0] == ch(5) and sp.ids[1] == ch(6) and sp.focus == 1 and app.st.activeChannel() == ch(6);
}
fn gameNoSplit(app: *App) bool {
    return activeIs(app, "jogo") and !mosaic.on() and tabsAre(app, &.{ ch(9), ch(10) }, 0);
}
fn splitBack(app: *App) bool {
    const p = mosaic.panes;
    return activeIs(app, "trabalho") and p.count == 2 and p.ids[0] == ch(5) and p.ids[1] == ch(6) and p.focus == 1 and
        app.st.activeChannel() == ch(6) and qa.find("pane:1") != null;
}
fn splitClosed(app: *App) bool {
    const set = setNamed(app, "trabalho") orelse return false;
    return !mosaic.on() and set.abas.split.count == 0;
}

// --- Renomear ----------------------------------------------------------------------

fn renameOpen(app: *App) bool {
    return switch (app.st.popup) {
        .tab_set_name => |t| t.rename != null and qa.find("tabset-name") != null,
        else => false,
    };
}
fn renameRefused(app: *App) bool {
    return renameOpen(app) and qa.find("tabset-error") != null;
}
fn renamed(app: *App) bool {
    return app.st.popup == .none and setNamed(app, "trabalho") == null and activeIs(app, "trampo") and fileTabs(conta_a, "trampo") != null;
}

// --- Sem rajada --------------------------------------------------------------------

/// Dez canais que ainda não abriram nesta sessão: nove do "Zig Brasil" e um do "Memes".
fn bigTabs() [10]Id {
    var out: [10]Id = undefined;
    for ([_]usize{ 1, 2, 4, 5, 6, 7, 9, 10, 11 }, 0..) |ci, k| out[k] = gw.channelId(2, ci);
    out[9] = gw.channelId(9, 4);
    return out;
}
var hist0: u64 = 0;
var cmds0: u64 = 0;
var subs0: u64 = 0;
fn addBig(app: *App) void {
    const ids = bigTabs();
    _ = list(app).add(app.gpa, "grande", &ids, 0, .{}) catch {};
    hist0 = gw.sent.history_fetches.load(.acquire);
    cmds0 = gw.sent.commands.load(.acquire);
    subs0 = gw.sent.subscribes.load(.acquire);
}
fn bigUntouched(app: *App) bool {
    for (bigTabs()) |id| {
        const cs = app.store.channel(id) orelse return false;
        if (cs.history != .none or !app.store.canAccess(&cs.info)) return false;
    }
    return setNamed(app, "grande") != null;
}
fn bigSwitched(app: *App) bool {
    const ids = bigTabs();
    return activeIs(app, "grande") and tabsAre(app, &ids, 0);
}
/// Depois de 1,5 s: um histórico só (o da aba que aparece), e quase nada além dele.
fn bigNoBurst(app: *App) bool {
    const ids = bigTabs();
    const hist = gw.sent.history_fetches.load(.acquire) - hist0;
    const cmds = gw.sent.commands.load(.acquire) - cmds0;
    const subs = gw.sent.subscribes.load(.acquire) - subs0;
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[conjuntos] trocar para 10 abas: {d} históricos, {d} pedidos no total, {d} op 14\n", .{ hist, cmds, subs });
    if (hist != 1 or cmds > 6 or subs > 1) return false;
    const shown = app.store.channel(ids[0]) orelse return false;
    if (shown.history == .none) return false;
    for (ids[1..]) |id| {
        const cs = app.store.channel(id) orelse return false;
        if (cs.history != .none) return false;
    }
    return true;
}
fn bigLazy(app: *App) bool {
    const ids = bigTabs();
    const cs = app.store.channel(ids[3]) orelse return false;
    return app.st.activeChannel() == ids[3] and cs.history != .none and gw.sent.history_fetches.load(.acquire) - hist0 == 2;
}

// --- Canal sumido ------------------------------------------------------------------

fn addGone(app: *App) void {
    const ids = [_]Id{ ch(4), sumido, semAcesso(), ch(5) };
    _ = list(app).add(app.gpa, "sumido", &ids, 3, .{}) catch {};
}
fn goneSkipped(app: *App) bool {
    const set = setNamed(app, "sumido") orelse return false;
    const toast = app.st.toast.text();
    return activeIs(app, "sumido") and tabsAre(app, &.{ ch(4), ch(5) }, 1) and abasAre(set, &.{ ch(4), ch(5) }, 1) and
        app.st.toast.is_error and std.mem.indexOf(u8, toast, "2") != null and app.st.toast.until_ms > gw.nowMs();
}
fn goneFile(_: *App) bool {
    const t = fileTabs(conta_a, "sumido") orelse return false;
    return std.mem.eql(Id, t, &.{ ch(4), ch(5) });
}

// --- Sair e excluir ----------------------------------------------------------------

fn leftToLoose(app: *App) bool {
    return list(app).active == null and tabsAre(app, &.{ ch(4), ch(9), ch(5) }, 0) and list(app).loose.ids.items.len == 0 and
        qa.find("tabset-chip") == null and setNamed(app, "sumido") != null;
}
fn onGameFromLoose(app: *App) bool {
    return activeIs(app, "jogo") and tabsAre(app, &.{ ch(9), ch(10) }, 0) and std.mem.eql(Id, list(app).loose.ids.items, &.{ ch(4), ch(9), ch(5) });
}
fn deletedGame(app: *App) bool {
    const l = readFile(conta_a) orelse return false;
    return setNamed(app, "jogo") == null and list(app).active == null and tabsAre(app, &.{ ch(9), ch(10) }, 0) and
        list(app).loose.ids.items.len == 0 and l.find("jogo") == null and l.find("trampo") != null;
}

// --- Reabrir o app -----------------------------------------------------------------

fn onTrampo(app: *App) bool {
    return activeIs(app, "trampo") and tabsAre(app, &.{ ch(4), ch(5), ch(6) }, 1);
}
/// Como fechar e abrir: grava, esquece tudo, as abas da abertura, e o READY lê de novo.
fn restart(app: *App) void {
    app_cj.reset(app);
    app.st.tabs.clearRetainingCapacity();
    app.st.tabs.appendSlice(app.gpa, &.{ ch(4), ch(9), ch(5) }) catch {};
    app.st.tab = 0;
    mosaic.panes = .{};
    _ = app_cj.ready(app);
}
fn restored(app: *App) bool {
    const l = list(app);
    if (l.sets.items.len != 3) return false;
    for ([_][]const u8{ "trampo", "grande", "sumido" }, 0..) |name, i| if (!std.mem.eql(u8, l.sets.items[i].name, name)) return false;
    return onTrampo(app) and std.mem.eql(Id, l.loose.ids.items, &.{ ch(9), ch(10) });
}

// --- Cada conta com os seus ------------------------------------------------------

fn twoAccounts(app: *App) void {
    acc_store.list = .{};
    _ = acc_store.list.upsert(app.store.me, "rsha", "", false);
    _ = acc_store.list.upsert(conta_b, "conta-b", "", false);
    acc_store.list.active = app.store.me;
    acc_store.session = app.store.me;
}
fn toB(app: *App) void {
    app.handle(.{ .switch_account = conta_b });
}
fn toA(app: *App) void {
    app.handle(.{ .switch_account = conta_a });
}
fn onBEmpty(app: *App) bool {
    return acc_store.session == conta_b and app.store.ready and app.login.phase != .form and list(app).owner == conta_b and
        list(app).sets.items.len == 0 and list(app).active == null and qa.find("tabs-bar") != null;
}
fn savedB(app: *App) bool {
    const b = fileTabs(conta_b, "conta-b") orelse return false;
    return activeIs(app, "conta-b") and list(app).sets.items.len == 1 and b.len > 0 and fileTabs(conta_a, "conta-b") == null;
}
fn backOnA(app: *App) bool {
    return acc_store.session == conta_a and app.store.ready and app.login.phase != .form and list(app).owner == conta_a and
        setNamed(app, "conta-b") == null and list(app).sets.items.len == 3 and onTrampo(app);
}

// --- Atalho e fim --------------------------------------------------------------------

fn onGrande(app: *App) bool {
    return activeIs(app, "grande") and app.st.tabs.items.len == 10;
}
fn cleanup(app: *App) void {
    app.st.conjuntos.clear(app.gpa);
    deleteFile(conta_a);
    deleteFile(conta_b);
    ui_cj.qa_read = false;
    if (abas_before) |on| if (!on) {
        _ = app.themes.setOption("abas", false);
    };
    acc_store.list = .{};
    acc_store.session = app.store.me;
    file_list.deinit(std.heap.c_allocator);
    file_list = .{};
}

pub const ops = [_]Op{
    s("conjuntos de abas: preparo"),
    expect("app conecta e carrega o histórico", ready),
    run(prepare),
    expect("começa sem conjunto, com as 3 abas da abertura e a barra de abas", prepared),

    s("conjuntos de abas: salvar"),
    rclick("tabs-bar"),
    expect("botão direito na barra de abas abre o menu dos conjuntos", emptyMenu),
    click("menu:Salvar abas como conjunto…"),
    expect("Salvar abas como conjunto… pede o nome", nameOpen),
    click("tabset-save"),
    .{ .wait = 150 },
    expect("sem nome, Salvar não faz nada", nameStillOpen),
    click("tabset-name"),
    .{ .text = "trabalho" },
    .{ .shot = "conjuntos-nome" },
    click("tabset-save"),
    expect("salva «trabalho» com as 3 abas e ele fica em uso", savedWork),
    expect("o arquivo da conta tem o conjunto", fileHasWork),
    expect("a etiqueta do conjunto aparece antes das abas", chipShown),

    s("conjuntos de abas: guarda sozinho"),
    .{ .ctrl_click = .{ .mark = "channel:500007" } },
    expect("abrir uma aba guarda ela no conjunto e no arquivo", workGotTab),
    click("tab:1"),
    expect("trocar de aba guarda a ativa no conjunto", workTab1),
    key(c.ImGuiKey_W, true, false),
    expect("fechar uma aba tira ela do conjunto e do arquivo", workClosed),

    s("conjuntos de abas: segundo conjunto"),
    rclick("tabs-bar"),
    click("menu:Salvar abas como conjunto…"),
    expect("a janela do nome abre de novo, vazia", nameOpenAgain),
    .{ .text = "jogo" },
    key(c.ImGuiKey_Enter, false, false),
    expect("Enter salva «jogo» com as mesmas abas, e «trabalho» fica como estava", savedGame),
    key(c.ImGuiKey_W, true, false),
    key(c.ImGuiKey_W, true, false),
    expect("fecha duas abas em «jogo»", gameOneTab),
    click("channel:500010"),
    .{ .ctrl_click = .{ .mark = "channel:500011" } },
    click("tab:0"),
    expect("«jogo» fica com as abas dele, e «trabalho» com as dele", twoSets),
    rclick("tabs-bar"),
    expect("o menu lista os dois, com o visto no em uso, e renomear, sair e excluir", menuTwoSets),
    .{ .shot = "conjuntos-menu" },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha o menu", popupClosed),

    s("conjuntos de abas: trocar"),
    rclick("tabs-bar"),
    click("menu:trabalho"),
    expect("pelo menu: volta «trabalho» com as abas e a aba ativa dele", onWork),
    key(c.ImGuiKey_K, true, false),
    run(queryGame),
    expect("a paleta mostra «Conjunto: jogo» em primeiro", paletteShowsGame),
    .{ .shot = "conjuntos-paleta" },
    key(c.ImGuiKey_Enter, false, false),
    expect("pela paleta: volta «jogo»", onGame),
    key(c.ImGuiKey_PageDown, true, true),
    expect("Ctrl+Shift+PageDown vai para o próximo conjunto", onWorkAgain),

    s("conjuntos de abas: tela dividida"),
    rclick("channel:500007"),
    expect("menu do canal com Abrir ao lado", channelMenu),
    click("menu:Abrir ao lado"),
    expect("a tela dividida fica guardada no conjunto", splitSaved),
    rclick("tabs-bar"),
    click("menu:jogo"),
    expect("«jogo» não tem tela dividida", gameNoSplit),
    rclick("tabs-bar"),
    click("menu:trabalho"),
    expect("voltar para «trabalho» traz a tela dividida dele", splitBack),
    .{ .shot = "conjuntos-tela-dividida" },
    click("pane-close:1"),
    expect("fechar o painel tira a tela dividida do conjunto", splitClosed),

    s("conjuntos de abas: renomear"),
    rclick("tabs-bar"),
    click("menu:Renomear conjunto…"),
    expect("Renomear abre a janela com o nome", renameOpen),
    key(c.ImGuiKey_A, true, false),
    .{ .text = "JOGO" },
    expect("nome de outro conjunto (outra caixa) é recusado com o motivo", renameRefused),
    .{ .shot = "conjuntos-nome-repetido" },
    key(c.ImGuiKey_A, true, false),
    .{ .text = "trampo" },
    key(c.ImGuiKey_Enter, false, false),
    expect("renomeia para «trampo», também no arquivo", renamed),

    s("conjuntos de abas: sem rajada de pedidos"),
    run(addBig),
    expect("um conjunto de 10 abas que ainda não abriram", bigUntouched),
    rclick("tabs-bar"),
    click("menu:grande"),
    expect("troca para as 10 abas", bigSwitched),
    .{ .wait = 1500 },
    expect("só a aba que aparece pede o histórico (1 pedido, não 10)", bigNoBurst),
    .{ .shot = "conjuntos-grande" },
    .{ .key = .{ .key = c.ImGuiKey_4, .alt = true } },
    expect("as outras carregam quando abertas, uma por vez", bigLazy),

    s("conjuntos de abas: canal sumido"),
    run(addGone),
    rclick("tabs-bar"),
    click("menu:sumido"),
    expect("o canal que sumiu e o sem acesso ficam de fora, com aviso", goneSkipped),
    .{ .shot = "conjuntos-aviso" },
    expect("e saem do conjunto no arquivo", goneFile),

    s("conjuntos de abas: sair e excluir"),
    rclick("tabs-bar"),
    click("menu:Sair do conjunto"),
    expect("Sair volta para as abas soltas de antes do primeiro conjunto", leftToLoose),
    rclick("tabs-bar"),
    click("menu:jogo"),
    expect("entrar em «jogo» guarda as abas soltas", onGameFromLoose),
    rclick("tabs-bar"),
    click("menu:Excluir conjunto"),
    expect("excluir tira o conjunto (e do arquivo); as abas ficam abertas, soltas", deletedGame),

    s("conjuntos de abas: reabrir o app"),
    key(c.ImGuiKey_K, true, false),
    run(queryTrampo),
    expect("a paleta acha «trampo»", struct {
        fn f(app: *App) bool {
            const p = &app.st.palette;
            return p.open and p.items.items.len > 0 and p.items.items[0].kind == .tab_set;
        }
    }.f),
    key(c.ImGuiKey_Enter, false, false),
    expect("entra em «trampo»", onTrampo),
    run(restart),
    expect("depois de reabrir: os conjuntos, o em uso, as abas e a aba ativa voltam", restored),

    s("conjuntos de abas: cada conta com os seus"),
    run(twoAccounts),
    run(toB),
    .{ .expect = .{ .name = "a outra conta começa sem conjunto nenhum", .check = onBEmpty, .timeout_ms = 8000 } },
    rclick("tabs-bar"),
    click("menu:Salvar abas como conjunto…"),
    .{ .text = "conta-b" },
    key(c.ImGuiKey_Enter, false, false),
    expect("o conjunto dela vai para o arquivo dela, não para o da primeira", savedB),
    run(toA),
    .{ .expect = .{ .name = "voltar para a primeira traz os conjuntos dela e o em uso", .check = backOnA, .timeout_ms = 8000 } },

    s("conjuntos de abas: atalho e fim"),
    key(c.ImGuiKey_PageDown, true, true),
    expect("o atalho passa para o seguinte da lista", onGrande),
    run(cleanup),
};
