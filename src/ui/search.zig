//! Busca de mensagens (Ctrl+F ou a caixa do cabeçalho), num painel ao lado da conversa
//! (o desenho fica em search_view.zig).
//!
//! A cada tecla, procura no índice das mensagens que o app tem, na memória e no cache em
//! disco (net/busca_local.zig, core/busca_indice.zig): a resposta vem na hora, sem falar
//! com o Discord, então funciona offline. A última palavra vale como começo de palavra
//! enquanto é digitada. O Enter pergunta ao Discord, que tem o histórico inteiro, e o que
//! ele achou entra junto com o que já estava aqui (cada mensagem uma vez); só o Enter, a
//! troca de página e a de ordem saem para a rede. Sem conexão, nem tenta.
//! Filtros: ver core/search_query.zig.
//! Clicar num resultado abre a conversa e pula até a mensagem, com o painel aberto.
const std = @import("std");
const c = @import("c");
const d = @import("draw.zig");
const qa = @import("qa.zig");
const anim = @import("anim.zig");
const icons = @import("icons.zig");
const i18n = @import("i18n.zig");
const w = @import("widgets.zig");
const types = @import("../core/types.zig");
const sq = @import("../core/search_query.zig");
const busca = @import("../net/busca_local.zig");
const bi = @import("../core/busca_indice.zig");
const store_mod = @import("../core/store.zig");
const ev = @import("../core/event.zig");
const view = @import("search_view.zig");
const sugg = @import("search_sugg.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

pub var open = false;
var appearing = false;
var focus = false;
var query: [256]u8 = @splat(0);
pub var selected: usize = 0;
/// A caixa de texto está ativa (e estava no quadro anterior: o Esc a solta no próprio quadro).
pub var input_active = false;
var was_active = false;
/// As setas escolheram um resultado: o Enter abre ele em vez de buscar.
var arrow_moved = false;
pub var scroll_to_selected = false;
var text_sync = false;
var cursor_end = false;
var tab_pressed = false;
/// Onde o painel fica neste quadro (ver `reserve`).
pub var panel: d.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// De onde vem a lista: deste computador ou da busca do Discord.
pub const Source = enum { local, server };
pub const ServerState = enum { idle, loading, done, indexing, forbidden, failed };
pub var source: Source = .local;
pub var server: ServerState = .idle;
/// Quantas o Discord achou, e a página que está na tela.
pub var total: u32 = 0;
pub var offset: u32 = 0;
pub var sort: sq.Sort = .newest;
/// Quantas mensagens o Discord já indexou, enquanto prepara a busca.
pub var indexed: u32 = 0;
/// A consulta da lista que está na tela (os termos marcados no texto).
pub var view_query: sq.Query = .{};
var req_id: u32 = 0;
var retry_at_ms: i64 = 0;
var retries: u8 = 0;
var delivered: ?ev.SearchResults = null;
var problem_buf: [240]u8 = undefined;
var problem_len: usize = 0;
/// As últimas buscas no Discord, só enquanto o app está aberto.
var recent_buf: [5][256]u8 = undefined;
var recent_len: [5]u16 = @splat(0);
var recent_n: usize = 0;
/// Muda a cada abertura: o campo do ImGui esquece o texto da vez anterior.
var gen: c_int = 0;

pub const Result = struct {
    channel: Id,
    id: Id,
    ts: i64,
    author_id: Id = 0,
    author: []const u8,
    where: []const u8,
    snippet: []const u8,
    /// Está neste computador (no índice da busca local).
    local: bool = false,
    /// Linhas do trecho nessa largura (ver search_view.zig).
    lines: u8 = 1,
    wrap_w: f32 = 0,
};
var res_arena: std.heap.ArenaAllocator = .init(alloc);
pub var results: std.ArrayList(Result) = .empty;
/// Quantas casaram neste computador (antes do corte em `max_results`).
pub var found: usize = 0;
const max_results = 200;
/// O índice ainda está vindo do disco (os resultados crescem quando ele chegar).
pub var scanning = false;
var built = false;
/// A versão do índice da lista na tela: mudou (mensagem nova, editada, apagada), refaz.
var shown_gen: u32 = 0;
var local_hits: std.ArrayList(bi.Hit) = .empty;
/// O Enter não foi ao Discord porque o app está sem conexão.
pub var offline = false;

/// Ctrl+F: abre; com o painel aberto, volta para a caixa de texto; com ela ativa, fecha.
pub fn toggle() void {
    if (!open) return start();
    if (input_active) close() else refocus();
}

/// A caixa do cabeçalho: abre, ou volta para a caixa de texto.
pub fn focusOrStart() void {
    if (open) refocus() else start();
}

fn refocus() void {
    appearing = true;
    focus = false;
}

pub fn start() void {
    open = true;
    gen +%= 1;
    appearing = true;
    focus = false;
    @memset(&query, 0);
    selected = 0;
    built = false;
    scanning = false;
    source = .local;
    server = .idle;
    total = 0;
    offset = 0;
    problem_len = 0;
    offline = false;
    input_active = false;
    was_active = false;
    arrow_moved = false;
    view_query = .{};
    view.scroll_y = 0;
    sugg.count = 0;
    sugg.selected = null;
    req_id +%= 1;
}

/// Com a janela escondida há um tempo e a busca fechada, o índice sai da memória (gravado
/// antes; volta quando a busca abrir). true: soltou alguma coisa.
pub fn releaseIdle(hidden: bool) bool {
    if (open or !hidden) return false;
    return busca.releaseHidden();
}

/// Fecha. O índice fica (ele acompanha as mensagens com o painel fechado); a lista sai.
pub fn close() void {
    open = false;
    scanning = false;
    input_active = false;
    if (delivered) |r| freeHits(r.hits);
    delivered = null;
    results.clearAndFree(alloc);
    local_hits.clearAndFree(alloc);
    _ = res_arena.reset(.free_all);
    found = 0;
}

// --- Busca ---------------------------------------------------------------------------

fn clearResults() void {
    results.clearRetainingCapacity();
    _ = res_arena.reset(.retain_capacity);
    found = 0;
}

fn firstTerm(q: *const sq.Query) []const u8 {
    return if (q.n_terms > 0) q.term(0) else "";
}

/// `keep`: a lista só cresceu ou mudou por baixo; a seleção fica onde estava.
fn rebuild(ctx: *d.Ctx, keep: bool) void {
    clearResults();
    if (!keep) {
        selected = 0;
        view.scroll_y = 0;
    }
    const q = sq.Query.parse(text());
    view_query = q;
    shown_gen = busca.generation();
    // "Fixada", prévia de link, figurinha: só o Discord tem como saber.
    if (q.empty() or q.serverOnly()) return;
    found = busca.find(ctx.store, &q, text(), false, max_results, &local_hits);
    const ix = busca.current() orelse return;
    const ra = res_arena.allocator();
    for (local_hits.items) |h| {
        const r = localResult(ctx, ra, ix, h.doc, &q) orelse continue;
        results.append(alloc, r) catch return;
    }
    if (selected >= results.items.len) selected = 0;
}

/// Um resultado do índice: o texto guardado nele, o nome de agora se o app conhece a pessoa.
fn localResult(ctx: *d.Ctx, ra: std.mem.Allocator, ix: *const bi.Index, doc: u32, q: *const sq.Query) ?Result {
    const dd = &ix.docs.items[doc];
    const ch = ix.channelOf(dd);
    const cs = ctx.store.channel(ch) orelse return null;
    const author_id = ix.authorOf(dd);
    const saved_name = ix.authorName(dd);
    const name = if (ctx.store.user(author_id)) |u| u.name else if (saved_name.len > 0) saved_name else "?";
    var r: Result = .{
        .channel = ch,
        .id = dd.id,
        .ts = @divTrunc(types.snowflakeTime(dd.id), 1000),
        .author_id = author_id,
        .author = ra.dupe(u8, name) catch return null,
        .where = whereLabel(ctx, ra, cs) catch return null,
        .snippet = "",
        .local = true,
    };
    snippet(ctx, ra, &r, ix.content(dd), ix.files(dd), firstTerm(q));
    return r;
}

fn whereLabel(ctx: *d.Ctx, a: std.mem.Allocator, cs: *const store_mod.ChannelState) ![]const u8 {
    if (cs.info.guild == 0) return if (cs.info.group) a.dupe(u8, cs.info.name) else std.fmt.allocPrint(a, "@{s}", .{cs.info.name});
    const g = ctx.store.guild(cs.info.guild);
    return std.fmt.allocPrint(a, "#{s} · {s}", .{ cs.info.name, if (g) |x| x.name else "" });
}

/// Texto legível de uma linha: menções viram @nome / #canal, quebras viram espaço.
fn clean(ctx: *d.Ctx, out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        // Emoji personalizado (<:nome:123> ou <a:nome:123>) vira :nome:.
        if (s[i] == '<' and i + 2 < s.len and (s[i + 1] == ':' or (s[i + 1] == 'a' and s[i + 2] == ':'))) if (std.mem.indexOfScalarPos(u8, s, i, '>')) |end| {
            const body = s[i + @as(usize, if (s[i + 1] == ':') 2 else 3) .. end];
            if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
                const piece = std.fmt.bufPrint(out[n..], ":{s}:", .{body[0..colon]}) catch break;
                n += piece.len;
                i = end + 1;
                continue;
            }
        };
        if (s[i] == '<' and i + 2 < s.len and (s[i + 1] == '@' or s[i + 1] == '#')) if (std.mem.indexOfScalarPos(u8, s, i, '>')) |end| {
            var body = s[i + 2 .. end];
            if (body.len > 0 and (body[0] == '!' or body[0] == '&')) body = body[1..];
            if (std.fmt.parseInt(Id, body, 10)) |id| {
                const name: ?[]const u8 = if (s[i + 1] == '@') (if (ctx.store.user(id)) |u| u.name else null) else (if (ctx.store.channel(id)) |cs| cs.info.name else null);
                if (name) |nm| {
                    const piece = std.fmt.bufPrint(out[n..], "{c}{s}", .{ s[i + 1], nm }) catch break;
                    n += piece.len;
                    i = end + 1;
                    continue;
                }
            } else |_| {}
        };
        // Um caractere inteiro por vez (o corte nunca parte um UTF-8).
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (n + len > out.len or i + len > s.len) break;
        if (len == 1) {
            out[n] = if (s[i] == '\n' or s[i] == '\r' or s[i] == '\t') ' ' else s[i];
        } else @memcpy(out[n .. n + len], s[i .. i + len]);
        n += len;
        i += len;
    }
    return out[0..n];
}

fn snippet(ctx: *d.Ctx, a: std.mem.Allocator, r: *Result, content: []const u8, files: []const u8, term: []const u8) void {
    var buf: [800]u8 = undefined;
    var line_text = clean(ctx, &buf, content);
    if (line_text.len == 0) line_text = if (files.len > 0) std.fmt.bufPrint(&buf, "📎 {s}", .{files}) catch "" else "";
    const at: usize = if (term.len > 0) (if (sq.findFold(line_text, term)) |m| m[0] else 0) else 0;
    // Janela em volta do que casou.
    var from: usize = if (at > 50) at - 50 else 0;
    while (from > 0 and (line_text[from] & 0xC0) == 0x80) from -= 1;
    var end = @min(line_text.len, from + 360);
    while (end < line_text.len and end > from and (line_text[end] & 0xC0) == 0x80) end -= 1;
    const lead: []const u8 = if (from > 0) "…" else "";
    r.snippet = std.fmt.allocPrint(a, "{s}{s}", .{ lead, line_text[from..end] }) catch return;
}

// --- O painel ------------------------------------------------------------------------

/// O desenho fica em search_view.zig.
pub const draw = view.draw;

/// O que sobra para o tema com o painel aberto. Janela estreita demais para os dois: o painel
/// cobre tudo, até fechar.
pub fn reserve(win: d.Rect) d.Rect {
    if (!open) return win;
    const pw = std.math.clamp(win.w * 0.36, 340, 480);
    if (win.w - pw < 440) {
        panel = win;
        return win;
    }
    panel = .{ .x = win.right() - pw, .y = win.y, .w = pw, .h = win.h };
    var r = win;
    r.w -= pw;
    return r;
}

/// O que acontece a cada quadro, antes de desenhar.
pub fn frame(ctx: *d.Ctx) void {
    sq.now_s = @divTrunc(ctx.now_ms, 1000);
    if (!built) sq.tz_offset_s = w.utcOffset(sq.now_s);
    takeDelivered(ctx);
    if (server == .indexing) {
        if (ctx.now_ms >= retry_at_ms) sendRequest(ctx) else anim.at(retry_at_ms);
    }
    if (!built) {
        built = true;
        // A busca abriu: o índice que estava no disco vem agora, se ainda não veio.
        busca.startLoad(true);
        rebuild(ctx, false);
    }
    const arrived = busca.poll();
    scanning = busca.loading();
    // Lendo numa thread: confere de novo daqui a pouco, sem esperar evento.
    if (scanning) anim.at(ctx.now_ms + 50);
    // O disco chegou, ou chegou, mudou ou saiu mensagem: a lista daqui acompanha.
    if (source == .local and (arrived or busca.generation() != shown_gen)) rebuild(ctx, true);
}

pub fn openingKey() usize {
    return @as(u32, @bitCast(gen));
}

pub fn takeAppearing() bool {
    defer appearing = false;
    return appearing;
}

pub fn text() []const u8 {
    return std.mem.sliceTo(&query, 0);
}

pub fn serverOnly() bool {
    return view_query.serverOnly();
}

pub fn problem() []const u8 {
    return problem_buf[0..problem_len];
}

pub fn recentCount() usize {
    return recent_n;
}

pub fn recent(i: usize) []const u8 {
    return recent_buf[i][0..recent_len[i]];
}

fn inputCallback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    if (data.*.EventFlag == c.ImGuiInputTextFlags_CallbackCompletion) tab_pressed = true;
    if (text_sync) {
        text_sync = false;
        c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
        c.ImGuiInputTextCallbackData_InsertChars(data, 0, &query, null);
    }
    if (cursor_end) {
        cursor_end = false;
        data.*.CursorPos = data.*.BufTextLen;
        data.*.SelectionStart = data.*.BufTextLen;
        data.*.SelectionEnd = data.*.BufTextLen;
    }
    return 0;
}

pub fn inputField(ctx: *d.Ctx, x: f32, y: f32, width: f32) void {
    c.ImGui_SetCursorScreenPos(d.v(x, y));
    c.ImGui_PushFontFloat(ctx.ui.get(.regular), 16);
    defer c.ImGui_PopFont();
    if (!focus) {
        c.ImGui_SetKeyboardFocusHere();
        focus = true;
    }
    c.ImGui_SetNextItemWidth(width);
    c.ImGui_PushStyleColor(c.ImGuiCol_FrameBg, 0);
    defer c.ImGui_PopStyleColor();
    // O campo do ImGui esquece o texto da vez anterior.
    c.ImGui_PushIDInt(gen);
    defer c.ImGui_PopID();
    const flags = c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_CallbackCompletion;
    const edited = c.ImGui_InputTextWithHintEx("##sq", i18n.trZ("Buscar mensagens…", "Search messages…").ptr, &query, query.len, flags, inputCallback, null);
    was_active = input_active;
    input_active = c.ImGui_IsItemActive();
    if (edited) onEdited(ctx);
}

/// O texto mudou: volta para o que está neste computador, e o Discord fica para o Enter.
fn onEdited(ctx: *d.Ctx) void {
    source = .local;
    server = .idle;
    offset = 0;
    total = 0;
    problem_len = 0;
    offline = false;
    arrow_moved = false;
    // Uma resposta que ainda vinha a caminho não vale mais.
    req_id +%= 1;
    view.scroll_y = 0;
    sugg.rebuild(ctx);
    rebuild(ctx, false);
}

pub fn setText(ctx: *d.Ctx, s: []const u8) void {
    @memset(&query, 0);
    const n = @min(s.len, query.len - 1);
    @memcpy(query[0..n], s[0..n]);
    text_sync = true;
    cursor_end = true;
    focus = false;
    onEdited(ctx);
}

/// Um filtro no fim do que já está escrito.
pub fn appendText(ctx: *d.Ctx, s: []const u8) void {
    var buf: [query.len]u8 = undefined;
    const now = text();
    const sep: []const u8 = if (now.len > 0 and now[now.len - 1] != ' ') " " else "";
    setText(ctx, std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ now, sep, s }) catch return);
}

pub fn removeRange(ctx: *d.Ctx, from: usize, to: usize) void {
    var buf: [query.len]u8 = undefined;
    const now = text();
    const before = std.mem.trimEnd(u8, now[0..from], " ");
    const after = std.mem.trimStart(u8, now[to..], " ");
    const sep: []const u8 = if (before.len > 0 and after.len > 0) " " else "";
    setText(ctx, std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ before, sep, after }) catch return);
}

/// As teclas da busca. Depois de desenhar: aqui a busca pode fechar.
pub fn keys(ctx: *d.Ctx) void {
    const st = ctx.st;
    if (st.palette.open or st.popup != .none or st.viewer != null) return;
    // O ImGui solta a caixa no próprio quadro do Esc: vale como estava antes.
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and (was_active or !ctx.io.*.WantTextInput)) return close();
    if (!was_active) return;
    const n = results.items.len;
    const with_sugg = sugg.count > 0;
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_DownArrow)) {
        if (with_sugg) {
            sugg.move(1);
        } else if (n > 0) {
            selected = (selected + 1) % n;
            arrow_moved = true;
            scroll_to_selected = true;
        }
    }
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_UpArrow)) {
        if (with_sugg) {
            sugg.move(-1);
        } else if (n > 0) {
            selected = (selected + n - 1) % n;
            arrow_moved = true;
            scroll_to_selected = true;
        }
    }
    if (tab_pressed) {
        tab_pressed = false;
        if (with_sugg) sugg.accept(ctx, sugg.selected orelse 0);
        return;
    }
    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Enter) or c.ImGui_IsKeyPressed(c.ImGuiKey_KeypadEnter)) {
        if (with_sugg) if (sugg.selected) |i| return sugg.accept(ctx, i);
        // Escolheu com as setas, ou já está vendo o que o Discord achou: abre a mensagem.
        const same_answer = source == .server and server == .done and n > 0;
        if (n > 0 and (arrow_moved or same_answer)) return choose(ctx, results.items[selected]);
        askServer(ctx);
    }
}

pub fn choose(ctx: *d.Ctx, r: Result) void {
    arrow_moved = false;
    ctx.act(.{ .open_message = .{ .channel = r.channel, .id = r.id } });
}

// --- A busca do Discord -----------------------------------------------------------------

pub fn askServer(ctx: *d.Ctx) void {
    offset = 0;
    sendRequest(ctx);
}

pub fn changeSort(ctx: *d.Ctx, to: sq.Sort) void {
    sort = to;
    offset = 0;
    sendRequest(ctx);
}

pub fn changePage(ctx: *d.Ctx, to: u32) void {
    offset = to;
    sendRequest(ctx);
}

fn setProblem(comptime pt: []const u8, comptime en: []const u8, args: anytype) void {
    problem_len = i18n.fmt(&problem_buf, pt, en, args).len;
}

fn findUser(ctx: *d.Ctx, guild: Id, needle: []const u8) ?Id {
    var best: ?Id = null;
    var best_score: u8 = 0;
    var it = ctx.store.users.valueIterator();
    while (it.next()) |u| {
        const score = sq.userScore(u.name, needle);
        if (score == 0) continue;
        const total_score = score + @as(u8, @intFromBool(ctx.store.members.contains(.{ guild, u.id })));
        if (total_score > best_score) {
            best = u.id;
            best_score = total_score;
        }
    }
    return best;
}

fn findChannel(ctx: *d.Ctx, guild: Id, needle: []const u8) ?Id {
    var best: ?Id = null;
    var best_score: u8 = 0;
    for (ctx.store.channelsOf(guild)) |id| {
        const cs = ctx.store.channel(id) orelse continue;
        if (cs.info.kind != .text) continue;
        var b: [64]u8 = undefined;
        const name = sq.foldInto(&b, cs.info.name);
        const score: u8 = if (std.mem.eql(u8, name, needle)) 3 else if (std.mem.startsWith(u8, name, needle)) 2 else if (std.mem.indexOf(u8, name, needle) != null) 1 else 0;
        if (score > best_score) {
            best = id;
            best_score = score;
        }
    }
    return best;
}

/// Pede a página atual. O Discord busca no servidor inteiro; em conversa direta, nela.
fn sendRequest(ctx: *d.Ctx) void {
    problem_len = 0;
    const src = text();
    const q = sq.Query.parse(src);
    if (q.invalid_len > 0) return setProblem("Não entendi este filtro: {s}. Datas como 2026-11-06 ou 06/11/2026.", "I didn't understand this filter: {s}. Dates look like 2026-11-06 or 06/11/2026.", .{q.invalid()});
    if (q.empty()) return;
    // Sem conexão: nem tenta. Fica o que está neste computador, com o aviso.
    if (ctx.store.connection == .offline or ctx.store.connection == .failed) {
        remember(src);
        req_id +%= 1;
        source = .local;
        server = .failed;
        offline = true;
        rebuild(ctx, false);
        return;
    }
    offline = false;
    const ch = ctx.st.activeChannel() orelse return setProblem("Abra um servidor ou uma conversa para buscar no Discord.", "Open a server or a conversation to search Discord.", .{});
    const cs = ctx.store.channel(ch) orelse return setProblem("Abra um servidor ou uma conversa para buscar no Discord.", "Open a server or a conversation to search Discord.", .{});
    const guild = cs.info.guild;
    var ids: sq.ApiIds = .{};
    if (q.from_len > 0) ids.author = findUser(ctx, guild, q.from()) orelse return setProblem("Não achei \"{s}\" entre as pessoas que o app já carregou.", "Couldn't find \"{s}\" among the people the app has loaded.", .{q.from()});
    if (q.mentions_len > 0) ids.mentions = findUser(ctx, guild, q.mentions()) orelse return setProblem("Não achei \"{s}\" entre as pessoas que o app já carregou.", "Couldn't find \"{s}\" among the people the app has loaded.", .{q.mentions()});
    if (q.in_len > 0) {
        if (guild == 0) return setProblem("O filtro de canal só vale dentro de um servidor.", "The channel filter only works inside a server.", .{});
        ids.channel = findChannel(ctx, guild, q.in()) orelse return setProblem("Não achei o canal \"{s}\" neste servidor.", "Couldn't find channel \"{s}\" in this server.", .{q.in()});
    }
    var buf: [1024]u8 = undefined;
    const params = sq.apiParams(&buf, &q, ids, sort, offset) orelse return setProblem("Essa busca ficou longa demais.", "This search got too long.", .{});
    const owned = alloc.dupe(u8, params) catch return;
    req_id +%= 1;
    ctx.act(.{ .search_messages = .{ .req = req_id, .guild = guild, .channel = ch, .params = owned } });
    // Tentando de novo porque o Discord ainda indexava: a tela continua explicando isso.
    if (server == .indexing) {
        retry_at_ms = ctx.now_ms + 60_000;
    } else {
        retries = 0;
        server = .loading;
    }
    source = .server;
    view_query = q;
    remember(src);
    clearResults();
    selected = 0;
    arrow_moved = false;
    scroll_to_selected = false;
    view.scroll_y = 0;
}

fn remember(s: []const u8) void {
    var at: usize = recent_n;
    for (0..recent_n) |i| {
        if (std.mem.eql(u8, recent(i), s)) at = i;
    }
    if (at == recent_n) {
        if (recent_n < recent_buf.len) recent_n += 1 else at = recent_buf.len - 1;
    }
    if (at >= recent_n) at = recent_n - 1;
    var i = at;
    while (i > 0) : (i -= 1) {
        recent_buf[i] = recent_buf[i - 1];
        recent_len[i] = recent_len[i - 1];
    }
    const n = @min(s.len, recent_buf[0].len);
    @memcpy(recent_buf[0][0..n], s[0..n]);
    recent_len[0] = @intCast(n);
}

fn freeHits(hits: []ev.SearchHit) void {
    for (hits) |h| {
        alloc.free(h.author_name);
        alloc.free(h.content);
        alloc.free(h.files);
    }
    if (hits.len > 0) alloc.free(hits);
}

/// A resposta chegou (da thread da interface, entre os quadros).
pub fn deliver(r: ev.SearchResults) void {
    if (delivered) |old| freeHits(old.hits);
    delivered = r;
}

fn takeDelivered(ctx: *d.Ctx) void {
    const r = delivered orelse return;
    delivered = null;
    defer freeHits(r.hits);
    if (r.req != req_id) return;
    switch (r.status) {
        .ok => {
            server = .done;
            total = r.total;
            loadHits(ctx, r.hits);
        },
        .indexing => {
            retries +|= 1;
            if (retries > 10) return serverFailed(ctx);
            server = .indexing;
            indexed = r.indexed;
            retry_at_ms = ctx.now_ms + @max(r.retry_ms, 1000);
        },
        .forbidden => server = .forbidden,
        .failed => serverFailed(ctx),
    }
}

/// Sem resposta: fica o que está neste computador, com um aviso.
fn serverFailed(ctx: *d.Ctx) void {
    source = .local;
    server = .failed;
    offline = false;
    rebuild(ctx, false);
}

fn order() bi.Order {
    return switch (sort) {
        .newest => .newest,
        .oldest => .oldest,
        .relevance => .relevance,
    };
}

/// A resposta do Discord. Na primeira página, o que está neste computador entra junto,
/// cada mensagem uma vez: o Discord só acrescenta o que não está aqui.
fn loadHits(ctx: *d.Ctx, server_hits: []const ev.SearchHit) void {
    clearResults();
    const ra = res_arena.allocator();
    const term = firstTerm(&view_query);
    local_hits.clearRetainingCapacity();
    if (offset == 0 and !view_query.serverOnly()) found = busca.find(ctx.store, &view_query, text(), sort == .oldest, max_results, &local_hits);
    shown_gen = busca.generation();
    const ix = busca.current();
    var local_ids: std.ArrayList(Id) = .empty;
    defer local_ids.deinit(alloc);
    var server_ids: std.ArrayList(Id) = .empty;
    defer server_ids.deinit(alloc);
    var items: std.ArrayList(bi.Item) = .empty;
    defer items.deinit(alloc);
    local_ids.ensureTotalCapacity(alloc, local_hits.items.len) catch return;
    server_ids.ensureTotalCapacity(alloc, server_hits.len) catch return;
    for (local_hits.items) |h| local_ids.appendAssumeCapacity(h.id);
    for (server_hits) |h| server_ids.appendAssumeCapacity(h.id);
    bi.merge(alloc, local_ids.items, server_ids.items, order(), &items) catch return;
    for (items.items) |it| {
        var r: ?Result = null;
        if (it.origin != .server) if (ix) |x| {
            r = localResult(ctx, ra, x, local_hits.items[it.local_i].doc, &view_query);
        };
        if (r == null and it.origin != .local) {
            r = serverResult(ctx, ra, server_hits[it.server_i], term);
            // Numa página seguinte, a que também está aqui continua marcada.
            if (r) |*x| x.local = busca.contains(x.id);
        }
        results.append(alloc, r orelse continue) catch return;
    }
}

fn serverResult(ctx: *d.Ctx, ra: std.mem.Allocator, h: ev.SearchHit, term: []const u8) ?Result {
    const name = if (ctx.store.user(h.author)) |u| u.name else h.author_name;
    const where = if (ctx.store.channel(h.channel)) |cs| whereLabel(ctx, ra, cs) catch return null else i18n.tr("canal que não está na lista", "channel not in the list");
    var r: Result = .{
        .channel = h.channel,
        .id = h.id,
        .ts = @divTrunc(types.snowflakeTime(h.id), 1000),
        .author_id = h.author,
        .author = ra.dupe(u8, name) catch return null,
        .where = where,
        .snippet = "",
    };
    snippet(ctx, ra, &r, h.content, h.files, term);
    return r;
}
