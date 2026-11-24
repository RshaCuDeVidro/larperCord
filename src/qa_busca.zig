//! QA da busca de mensagens no painel: filtros, sugestões, a conversa com o Discord (o servidor
//! de mentira guarda a consulta que iria para a API), páginas, ordem e os estados de erro.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const search = @import("ui/search.zig");
const sugg = @import("ui/search_sugg.zig");
const i18n = @import("ui/i18n.zig");
const sq = @import("core/search_query.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const busca_local = @import("net/busca_local.zig");
const Window = @import("platform/window.zig").Window;
const Id = types.Id;

const geral: Id = 500005;
const memes: Id = 500006;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 6000 } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}

fn params() []const u8 {
    return gw.sent.search_params[0..gw.sent.search_len.load(.acquire)];
}
fn sent(part: []const u8) bool {
    return std.mem.indexOf(u8, params(), part) != null;
}
fn done() bool {
    return search.source == .server and search.server == .done;
}

fn toGeral(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = geral, .id = 0 } });
}
fn isOpen(_: *App) bool {
    return search.open and qa.find("search-input") != null;
}
fn isClosed(_: *App) bool {
    return !search.open;
}
fn hintInk(app: *App) bool {
    return R.hasInk(app, "search-input");
}
fn tipsShown(_: *App) bool {
    return qa.find("search-tip:from:") != null and qa.find("search-tip:pinned:") != null;
}
fn toJa(_: *App) void {
    i18n.set("ja");
}
fn toRu(_: *App) void {
    i18n.set("ru");
}
fn toPt(_: *App) void {
    i18n.set("pt");
}
fn suggShown(_: *App) bool {
    return sugg.count > 0 and qa.find("search-sugg:0") != null;
}
/// Em japonês e russo a sugestão põe a palavra que o analisador entende, não a traduzida.
fn pickedImage(_: *App) bool {
    const q = sq.Query.parse(search.text());
    return std.mem.indexOf(u8, search.text(), "has:image") != null and q.has_image and q.invalid_len == 0;
}
fn pickedToday(_: *App) bool {
    const q = sq.Query.parse(search.text());
    return std.mem.indexOf(u8, search.text(), "before:today") != null and q.max_id != 0 and q.invalid_len == 0;
}
fn typedFrom(_: *App) bool {
    return std.mem.eql(u8, search.text(), "from:") and sugg.count > 0 and qa.find("search-sugg:0") != null;
}
fn pickedPerson(_: *App) bool {
    const t = search.text();
    return std.mem.startsWith(u8, t, "from:") and t.len > 6 and t[t.len - 1] == ' ';
}
fn isEmpty(_: *App) bool {
    return search.text().len == 0;
}
fn localOnly(_: *App) bool {
    return search.source == .local and qa.find("search-run") != null;
}
/// Quantas da lista vieram só do Discord (as daqui são marcadas).
fn serverOnlyCount() usize {
    var n: usize = 0;
    for (search.results.items) |r| n += @intFromBool(!r.local);
    return n;
}
fn noDupes() bool {
    for (search.results.items, 0..) |a, i| {
        for (search.results.items[i + 1 ..]) |b| if (a.id == b.id) return false;
    }
    return true;
}
/// A primeira página do Discord junto com o que está aqui: as 25 dele, as daqui marcadas,
/// cada mensagem uma vez, mais novas primeiro.
fn firstPage(_: *App) bool {
    if (!done() or search.total != 60 or serverOnlyCount() != 25 or search.found == 0 or !noDupes()) return false;
    for (search.results.items[1..], 0..) |r, i| if (r.id > search.results.items[i].id) return false;
    return search.results.items.len == 25 + @min(search.found, 200) and qa.find("search-local:0") != null and
        sent("content=zig") and sent("sort_by=timestamp") and sent("sort_order=desc") and sent("offset=0");
}
fn secondPage(_: *App) bool {
    return done() and search.offset == 25 and search.results.items.len == 25 and sent("offset=25");
}
fn byRelevance(_: *App) bool {
    return done() and search.offset == 0 and sent("sort_by=relevance") and sent("offset=0");
}
var last_result: struct { ch: Id = 0, id: Id = 0 } = .{};
fn noteResult(_: *App) void {
    if (search.results.items.len == 0) return;
    const r = search.results.items[0];
    last_result = .{ .ch = r.channel, .id = r.id };
}
fn jumped(app: *App) bool {
    if (!search.open or app.st.activeChannel() != last_result.ch) return false;
    var b: [40]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "msg:{d}", .{last_result.id}) catch return false) != null;
}
fn filtersSent(app: *App) bool {
    if (!done()) return false;
    var it = app.store.users.valueIterator();
    var ana: Id = 0;
    while (it.next()) |u| if (std.mem.indexOf(u8, u.name, "ana") != null) {
        ana = u.id;
    };
    var b: [48]u8 = undefined;
    const author = std.fmt.bufPrint(&b, "author_id={d}", .{ana}) catch return false;
    return ana != 0 and sent(author) and sent("has=image") and sent("channel_id=500006") and sent("max_id=") and !sent("content=");
}
fn chipsShown(_: *App) bool {
    return qa.find("search-chip:0") != null and qa.find("search-chip:3") != null;
}
fn chipRemoved(_: *App) bool {
    return std.mem.indexOf(u8, search.text(), "has:") == null and std.mem.indexOf(u8, search.text(), "from:ana") != null and qa.find("search-chip:2") != null and qa.find("search-chip:3") == null;
}
var searches_before: u64 = 0;
fn noteSearches(_: *App) void {
    searches_before = gw.sent.searches.load(.monotonic);
}
fn problemNoRequest(_: *App) bool {
    return search.problem().len > 0 and gw.sent.searches.load(.monotonic) == searches_before;
}
fn serverOnlyAsked(_: *App) bool {
    return done() and sent("pinned=true") and search.results.items.len > 0;
}
fn serverOnlyHint(_: *App) bool {
    return search.source == .local and search.serverOnly() and search.results.items.len == 0;
}
fn failedShown(_: *App) bool {
    return search.server == .failed and search.source == .local and qa.find("search-retry") != null;
}
fn retried(_: *App) bool {
    return gw.sent.searches.load(.monotonic) > searches_before and search.server == .failed;
}
fn forbiddenShown(_: *App) bool {
    return search.server == .forbidden and search.source == .server;
}
fn indexingThenDone(_: *App) bool {
    return done() and search.total == 60 and gw.sent.searches.load(.monotonic) >= searches_before + 2;
}
/// O Discord não achou nada: fica só o que está neste computador (pode ser nada).
fn noResults(_: *App) bool {
    if (!done() or search.total != 0) return false;
    for (search.results.items) |r| if (!r.local) return false;
    return true;
}
fn recentShown(_: *App) bool {
    return search.recentCount() > 0 and qa.find("search-recent:0") != null;
}
fn tabCompleted(_: *App) bool {
    return std.mem.eql(u8, search.text(), "in:memes ");
}
fn palettePanelNarrow(app: *App) bool {
    // O painel reserva lugar: a conversa fica toda à esquerda dele.
    return search.panel.x > 0 and search.panel.right() <= app.io.*.DisplaySize.x + 1 and qa.find("composer") != null and qa.find("composer").?.right() <= search.panel.x + 1;
}

// --- Neste computador ---------------------------------------------------------------

/// Tudo daqui, nada perguntado ao Discord, e cada trecho com `piece` (sem acento).
fn allLocalWith(piece: []const u8) bool {
    if (search.source != .local or search.scanning or search.results.items.len == 0) return false;
    if (gw.sent.searches.load(.monotonic) != searches_before) return false;
    for (search.results.items) |r| if (!r.local or !sq.containsFold(r.snippet, piece)) return false;
    return qa.find("search-local:0") != null;
}
var timing_logged = false;
fn prefixFound(_: *App) bool {
    if (!allLocalWith("hypr")) return false;
    const st = busca_local.stats();
    if (!timing_logged) {
        timing_logged = true;
        std.log.info("busca local: {d} mensagens no índice, {d} palavras, {d} KB na memória, consulta em {d} µs", .{ st.docs, st.words, st.mem / 1024, busca_local.last_query_ns / 1000 });
    }
    // O orçamento: bem menos de 10 ms (no build de depuração, só que respondeu).
    return @import("builtin").mode == .debug or busca_local.last_query_ns < 10 * std.time.ns_per_ms;
}
fn accentFound(_: *App) bool {
    return allLocalWith("nao sei");
}
fn wallpaperFound(_: *App) bool {
    return allLocalWith("wallp");
}

/// Uma mensagem chegando, editada e apagada como se viesse do Discord.
var injected: Id = 0;
fn push(app: *App, e: @import("core/event.zig").Event) void {
    app.events.push(e);
    Window.wake(app.win.wake_type, .gateway);
}
fn injectMessage(app: *App) void {
    injected = types.makeSnowflake(gw.nowMs(), 0x3c123);
    const content = std.heap.c_allocator.dupe(u8, "qa: alguém tocou xilofone na call") catch return;
    push(app, .{ .message_create = .{ .id = injected, .channel = geral, .author = 1001, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
}
fn editInjected(app: *App) void {
    const content = std.heap.c_allocator.dupe(u8, "qa: era um trombone, na verdade") catch return;
    push(app, .{ .message_update = .{ .channel = geral, .id = injected, .content = content } });
}
fn deleteInjected(app: *App) void {
    push(app, .{ .message_delete = .{ .channel = geral, .id = injected } });
}
fn topIsInjected() bool {
    if (search.results.items.len == 0 or search.source != .local) return false;
    return search.results.items[0].id == injected and search.results.items[0].local;
}
fn injectedFound(_: *App) bool {
    return topIsInjected();
}
fn injectedListed() bool {
    for (search.results.items) |r| if (r.id == injected) return true;
    return false;
}
fn editedAway(_: *App) bool {
    return search.source == .local and !injectedListed();
}
fn injectedEdited(_: *App) bool {
    return topIsInjected() and sq.containsFold(search.results.items[0].snippet, "trombone");
}
fn deletedGone(_: *App) bool {
    return search.source == .local and !injectedListed() and !busca_local.contains(injected);
}

/// A última mensagem do canal, apagada com o app fechado: a página mais nova não traz ela
/// (e o servidor de mentira não guarda o que chega ao vivo, então tirar a conversa da
/// memória e abrir de novo é o mesmo caso).
var away: Id = 0;
fn injectAway(app: *App) void {
    away = types.makeSnowflake(gw.nowMs(), 0x3c124);
    const content = std.heap.c_allocator.dupe(u8, "qa: some enquanto o app está fechado") catch return;
    push(app, .{ .message_create = .{ .id = away, .channel = geral, .author = 1001, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = content } });
}
fn awayIndexed(app: *App) bool {
    return busca_local.contains(away) and app.st.activeChannel() == geral;
}
fn reopenGeral(app: *App) void {
    const cs = app.store.channel(geral) orelse return;
    app.store.unload(cs);
    app.actions.append(app.gpa, .{ .focus_tab = app.st.tab }) catch {};
}
fn awayPruned(app: *App) bool {
    const cs = app.store.channel(geral) orelse return false;
    return cs.history == .loaded and !cs.cached and cs.messages.items.len > 0 and !busca_local.contains(away);
}

fn goOffline(app: *App) void {
    @import("ui/root.zig").qa_banner = true;
    app.store.connection = .offline;
    searches_before = gw.sent.searches.load(.monotonic);
}
fn backOnline(app: *App) void {
    app.store.connection = .ready;
    @import("ui/root.zig").qa_banner = false;
}
fn offlineLocal(app: *App) bool {
    return app.store.connection == .offline and wallpaperFound(app);
}
fn offlineNoAsk(_: *App) bool {
    return search.offline and search.server == .failed and search.source == .local and search.results.items.len > 0 and
        gw.sent.searches.load(.monotonic) == searches_before and qa.find("search-failed:offline") != null;
}

/// O índice vai para o disco, sai da memória e volta ao abrir a busca.
var loads_before: u32 = 0;
var docs_before: usize = 0;
fn flushAndRelease(_: *App) void {
    busca_local.flush();
    search.close();
    loads_before = busca_local.loads;
    docs_before = busca_local.stats().docs;
    _ = search.releaseIdle(true);
}
fn released(_: *App) bool {
    const st = busca_local.stats();
    // O que chega depois (uma página pedida pelo pulo acima) fica num índice pequeno, só
    // desta sessão: o do disco não volta até a busca abrir.
    return busca_local.isReleased() and st.docs < docs_before and st.disk > 0 and
        @import("platform/sys.zig").fileSize("qa-out/cache/demo/" ++ @import("net/msg_cache.zig").search_index_file) == st.disk;
}
fn reloaded(app: *App) bool {
    return busca_local.loads > loads_before and prefixFound(app);
}
fn statsShown(_: *App) bool {
    const st = busca_local.stats();
    return qa.find("search-index-stats") != null and st.docs > 0 and st.mem > 0 and st.disk > 0;
}
fn settingsOpen(app: *App) bool {
    return app.st.settings.open;
}

pub const ops = [_]Op{
    s("busca: o painel e os filtros"),
    .{ .run = toGeral },
    .{ .wait = 300 },
    click("header-find"),
    expect("a caixa do cabeçalho abre o painel", isOpen),
    expect("a dica aparece na caixa de texto", hintInk),
    expect("sem nada digitado, os filtros", tipsShown),
    expect("a conversa fica ao lado do painel, sem nada por baixo", palettePanelNarrow),
    .{ .wait = 200 },
    .{ .shot = "busca-vazia" },
    click("search-tip:from:"),
    expect("clicar num filtro escreve ele e sugere pessoas", typedFrom),
    .{ .wait = 150 },
    .{ .shot = "busca-sugestoes" },
    click("search-sugg:0"),
    expect("escolher a pessoa completa o filtro", pickedPerson),
    click("search-clear"),
    expect("o X limpa a caixa", isEmpty),
    .{ .text = "in:mem" },
    .{ .wait = 100 },
    key(c.ImGuiKey_Tab),
    expect("Tab completa o canal", tabCompleted),
    click("search-clear"),

    s("busca: sugestões em japonês vão na consulta sem traduzir"),
    .{ .run = toJa },
    .{ .text = "has:i" },
    expect("ja: has: sugere", suggShown),
    click("search-sugg:0"),
    expect("ja: escolher põe has:image, que a busca entende", pickedImage),
    click("search-clear"),
    .{ .text = "before:t" },
    expect("ja: before: sugere", suggShown),
    click("search-sugg:0"),
    expect("ja: escolher põe before:today, que a busca entende", pickedToday),
    click("search-clear"),

    s("busca: sugestões em russo vão na consulta sem traduzir"),
    .{ .run = toRu },
    .{ .text = "has:i" },
    expect("ru: has: sugere", suggShown),
    click("search-sugg:0"),
    expect("ru: escolher põe has:image, que a busca entende", pickedImage),
    click("search-clear"),
    .{ .text = "before:t" },
    expect("ru: before: sugere", suggShown),
    click("search-sugg:0"),
    expect("ru: escolher põe before:today, que a busca entende", pickedToday),
    click("search-clear"),
    .{ .run = toPt },

    s("busca: neste computador, na hora"),
    .{ .run = noteSearches },
    .{ .text = "hypr" },
    expect("o começo de uma palavra já acha, na hora e sem perguntar ao Discord", prefixFound),
    .{ .wait = 150 },
    .{ .shot = "busca-local" },
    click("search-clear"),
    .{ .text = "nao sei" },
    expect("sem acento acha com acento", accentFound),
    click("search-clear"),
    .{ .run = injectMessage },
    .{ .text = "xilof" },
    expect("a mensagem que acabou de chegar já aparece", injectedFound),
    .{ .run = editInjected },
    expect("editada: o texto antigo sai da busca", editedAway),
    click("search-clear"),
    .{ .text = "tromb" },
    expect("e o novo entra", injectedEdited),
    .{ .run = deleteInjected },
    expect("apagada: sai da busca e do índice", deletedGone),
    click("search-clear"),

    s("busca: sem conexão"),
    .{ .run = goOffline },
    .{ .text = "wallp" },
    expect("sem conexão, acha o que está neste computador", offlineLocal),
    key(c.ImGuiKey_Enter),
    expect("o Enter sem conexão não pergunta nada ao Discord e avisa", offlineNoAsk),
    .{ .wait = 150 },
    .{ .shot = "busca-offline" },
    .{ .run = noteResult },
    click("search-result:0"),
    .{ .expect = .{ .name = "clicar num resultado daqui pula até a mensagem", .check = jumped, .timeout_ms = 8000 } },
    .{ .run = backOnline },
    click("search-clear"),

    s("busca: o índice no disco"),
    .{ .run = flushAndRelease },
    expect("vai para o disco ao lado do cache e sai da memória", released),
    // O pulo acima pode ter ido para outro servidor (uma mensagem que chegou ao vivo é a
    // mais nova): a busca no Discord abaixo conta com o servidor do #geral.
    .{ .run = toGeral },
    click("header-find"),
    .{ .text = "hypr" },
    .{ .expect = .{ .name = "volta do disco ao abrir a busca e acha o mesmo", .check = reloaded, .timeout_ms = 8000 } },
    click("search-clear"),

    s("busca: no Discord"),
    .{ .text = "zig" },
    expect("digitando, procura neste computador e oferece o Discord", localOnly),
    expect("o que se digita aparece na tela", hintInk),
    key(c.ImGuiKey_Enter),
    expect("Enter pergunta ao Discord, com a consulta certa", firstPage),
    .{ .wait = 250 },
    .{ .shot = "busca-discord" },
    click("search-page:next"),
    expect("a próxima página pede o offset 25", secondPage),
    click("search-sort:relevance"),
    expect("trocar a ordem pede de novo, do começo", byRelevance),
    click("search-sort:newest"),
    .{ .expect = .{ .name = "volta para as mais recentes", .check = firstPage, .timeout_ms = 6000 } },
    .{ .run = noteResult },
    click("search-result:0"),
    .{ .expect = .{ .name = "clicar pula até a mensagem, com o painel aberto", .check = jumped, .timeout_ms = 8000 } },

    s("busca: filtros no Discord"),
    // O pulo acima vai para a conversa do resultado, que pode ser de outro servidor (uma
    // mensagem que chegou ao vivo é a mais nova): "in:memes" conta com o do #geral.
    .{ .run = toGeral },
    click("search-clear"),
    .{ .text = "from:ana has:imagem in:memes before:2026-01-02" },
    expect("as etiquetas mostram os filtros", chipsShown),
    click("search-run"),
    expect("os filtros viram os parâmetros da API", filtersSent),
    .{ .wait = 150 },
    .{ .shot = "busca-filtros" },
    click("search-chip:1"),
    expect("a etiqueta tira o filtro do texto", chipRemoved),
    click("search-clear"),
    .{ .text = "pinned:true" },
    expect("filtro que só o Discord resolve avisa em vez de mostrar errado", serverOnlyHint),
    key(c.ImGuiKey_Enter),
    expect("e vai para a API", serverOnlyAsked),

    s("busca: o que pode dar errado"),
    click("search-clear"),
    .{ .run = noteSearches },
    .{ .text = "from:ninguem-existe" },
    key(c.ImGuiKey_Enter),
    expect("pessoa desconhecida avisa e não pergunta nada", problemNoRequest),
    click("search-clear"),
    .{ .text = "before:logo" },
    key(c.ImGuiKey_Enter),
    expect("data que não dá para entender avisa e não pergunta nada", problemNoRequest),
    click("search-clear"),
    .{ .text = "falha" },
    key(c.ImGuiKey_Enter),
    expect("sem resposta, avisa e fica com o que está aqui", failedShown),
    .{ .wait = 150 },
    .{ .shot = "busca-falha" },
    .{ .run = noteSearches },
    click("search-retry"),
    expect("tentar de novo pergunta outra vez", retried),
    click("search-clear"),
    .{ .text = "proibido" },
    key(c.ImGuiKey_Enter),
    expect("sem permissão, explica", forbiddenShown),
    click("search-clear"),
    .{ .run = noteSearches },
    .{ .text = "indexando" },
    key(c.ImGuiKey_Enter),
    .{ .expect = .{ .name = "o Discord ainda indexando: tenta de novo sozinho", .check = indexingThenDone, .timeout_ms = 8000 } },
    click("search-clear"),
    .{ .text = "nada" },
    key(c.ImGuiKey_Enter),
    expect("nenhum resultado, sem erro", noResults),
    .{ .wait = 150 },
    .{ .shot = "busca-nada" },
    click("search-clear"),
    expect("as últimas buscas ficam na lista", recentShown),
    .{ .wait = 150 },
    .{ .shot = "busca-recentes" },
    click("search-recent:0"),
    expect("clicar numa busca recente faz ela de novo", noResults),
    .{ .wait = 100 },
    key(c.ImGuiKey_Escape),
    expect("Esc fecha o painel", isClosed),

    s("busca: o tamanho do índice nas Configurações"),
    .{ .key = .{ .key = c.ImGuiKey_Comma, .ctrl = true } },
    expect("abre as Configurações", settingsOpen),
    click("settings:Privacidade"),
    expect("Privacidade mostra as mensagens da busca, o disco e a memória", statsShown),
    .{ .wait = 150 },
    .{ .shot = "busca-privacidade" },
    key(c.ImGuiKey_Escape),

    // No fim: abrir a conversa de novo traz pessoas novas para a lista, e os passos de
    // "from:" acima contam com as de antes.
    s("busca: apagada com o app fechado"),
    .{ .run = toGeral },
    .{ .run = injectAway },
    expect("a última mensagem do canal entra no índice", awayIndexed),
    .{ .run = reopenGeral },
    .{ .expect = .{ .name = "a página mais nova não traz a última, e ela sai do índice", .check = awayPruned, .timeout_ms = 6000 } },
};
