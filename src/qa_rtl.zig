//! QA do texto da direita para a esquerda (entra na bateria por tema do qa_runner.zig): as
//! mensagens em árabe e hebraico do #música da demonstração (net/fake_gateway.zig) aparecem
//! com as letras ligadas e sem "?" no lugar de letra, em todo tema (o terminal usa uma fonte
//! mono sem árabe: as letras vêm das fontes reserva). O parágrafo da direita para a esquerda
//! termina na borda direita da coluna do texto (no balão, na do balão) e o latino continua à
//! esquerda, também numa mensagem com os dois. Selecionar e copiar devolvem o texto como foi
//! escrito, não a ordem da tela, e o link no meio do árabe abre. Numa mensagem curta que
//! continua o grupo, a barra de ações e o "id" do modo de desenvolvedor ficam fora do texto.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const bidi = @import("ui/bidi.zig");
const fonts = @import("ui/fonts.zig");
const types = @import("core/types.zig");
const StoredMessage = @import("core/store.zig").StoredMessage;
const Rect = @import("theme/layout.zig").Rect;
const att = @import("ui/attachments.zig");

fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

/// O trecho em árabe da frase em português (a do embed tem o mesmo nome e título).
const mixed_rtl = "فيروز - كيفك إنت";

/// O canal em que a bateria estava, para voltar no fim.
var home: types.Id = 0;

fn toMusic(app: *App) void {
    home = app.st.activeChannel() orelse 0;
    app.handle(.{ .open_message = .{ .channel = gw.rtl_channel, .id = 0 } });
    app.st.scrollOf(gw.rtl_channel).stick_bottom = true;
}

fn musicReady(app: *App) bool {
    if (app.st.activeChannel() != gw.rtl_channel) return false;
    const cs = app.store.channel(gw.rtl_channel) orelse return false;
    return cs.history == .loaded;
}

fn msgWith(app: *App, text: []const u8) ?*const StoredMessage {
    const cs = app.store.channel(gw.rtl_channel) orelse return null;
    for (cs.messages.items) |*m| if (std.mem.eql(u8, m.msg.content, text)) return m;
    return null;
}

fn textMark(app: *App, buf: []u8, text: []const u8) []const u8 {
    const m = msgWith(app, text) orelse return "";
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{m.msg.id}) catch "";
}

fn tArabic(app: *App, buf: []u8) []const u8 {
    return textMark(app, buf, gw.rtl_arabic);
}

/// As duas mensagens estão desenhadas neste quadro.
fn bothShown(app: *App) bool {
    var b: [64]u8 = undefined;
    if (qa.find(textMark(app, &b, gw.rtl_arabic)) == null) return false;
    return qa.find(textMark(app, &b, gw.rtl_hebrew)) != null;
}

/// O que vai para a tela tem as formas ligadas do árabe (lam-alef, inicial, medial, final).
fn shaped(_: *App) bool {
    const v = bidi.visual(gw.rtl_arabic) orelse return false;
    return std.mem.indexOf(u8, v, "\u{FEFC}") != null and std.mem.indexOf(u8, v, "\u{FEDF}") != null;
}

/// Toda letra RTL que vai para a tela existe em todas as fontes do atlas (a do tema mais as
/// reservas), e nenhuma ficou na lista das sem fonte: nada de "?". Como no CJK: um sistema
/// sem fonte nenhuma da escrita (procurou e não achou) não tem o que mesclar. Uma face que
/// nenhum texto da tela usou e que não tem a letra (no Windows, o itálico do Segoe UI sem o
/// árabe que o normal tem) pede as reservas como o desenho pediria, e a conferência espera
/// o próximo quadro: depois disso, ou a letra está lá, ou a escrita já foi procurada e falha.
fn noQuestionMarks(app: *App) bool {
    for ([_][]const u8{ gw.rtl_arabic, gw.rtl_hebrew, mixed_rtl, gw.rtl_urdu }) |t| {
        const v = bidi.visual(t) orelse return false;
        var it = (std.unicode.Utf8View.init(v) catch return false).iterator();
        while (it.nextCodepoint()) |cp| {
            if (!bidi.isRtl(cp) or noSystemFont(app, cp)) continue;
            for (app.fonts.faces.items) |e| if (!c.ImFont_IsGlyphInFont(e.font, cp)) {
                fonts.request(cp);
                return false;
            };
        }
    }
    for (fonts.missingLetters()) |cp| if (bidi.isRtl(cp) and !noSystemFont(app, cp)) return false;
    return true;
}

/// O sistema não tem fonte com esta letra: nem a reserva da escrita dela, nem (procurada
/// pelo bloco, como o heh goal do urdu que o DejaVu não tem) uma fonte só para o bloco.
fn noSystemFont(app: *App, cp: u32) bool {
    const g = fonts.groupOf(cp) orelse return false;
    if (app.fonts.triedGroup(g) and !app.fonts.hasGroup(g)) return true;
    const b = fonts.blockOf(cp) orelse return false;
    return app.fonts.triedBlock(b) and !app.fonts.hasBlock(b);
}

/// Arrastar do começo da frase (à direita) até depois do fim dela, à esquerda, pega a
/// mensagem inteira: na tela o começo está à direita, mas os índices são os do texto.
fn wholeSelected(app: *App) bool {
    const m = msgWith(app, gw.rtl_arabic) orelse return false;
    const sel = &app.st.selection;
    if (sel.a_id != m.msg.id or sel.b_id != m.msg.id) return false;
    return @min(sel.a_off, sel.b_off) == 0 and @max(sel.a_off, sel.b_off) == m.msg.content.len;
}

/// O que foi copiado é o texto como foi escrito (ordem lógica, sem as formas de apresentação).
fn copiedLogical(_: *App) bool {
    const got = c.SDL_GetClipboardText() orelse return false;
    defer c.SDL_free(got);
    return std.mem.eql(u8, std.mem.span(got), gw.rtl_arabic);
}

/// Tira o aviso (o "copiado ✓") da tela de uma vez: sem texto e já saindo.
fn clearToast(app: *App) void {
    app.st.toast.len = 0;
    app.st.toast.until_ms = 0;
}

// --- Alinhamento -------------------------------------------------------------------------

/// A coluna do texto da mensagem: de onde ele começa até a borda direita (ui/comp_messages.zig).
fn colOf(id: types.Id) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "msgcol:{d}", .{id}) catch return null);
}

/// A linha `n` do texto, onde foi desenhada (ui/rich.zig marca as de texto com letra RTL).
fn lineOf(id: types.Id, n: usize) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, "text-line:{d}:{d}", .{ id, n }) catch return null);
}

fn near(a: f32, b: f32) bool {
    return @abs(a - b) <= 1;
}

/// Toda linha da mensagem a partir da `from` termina na borda direita da coluna (até 1 px).
fn linesRight(id: types.Id, from: usize) bool {
    const col = colOf(id) orelse return false;
    var n = from;
    while (lineOf(id, n)) |l| : (n += 1) {
        if (!near(l.right(), col.right())) return false;
    }
    return n > from;
}

fn rightAligned(app: *App, text: []const u8) bool {
    const m = msgWith(app, text) orelse return false;
    return linesRight(m.msg.id, 0);
}

fn arabicRight(app: *App) bool {
    return rightAligned(app, gw.rtl_arabic);
}

fn hebrewRight(app: *App) bool {
    return rightAligned(app, gw.rtl_hebrew);
}

/// A mensagem sem letra RTL mais recente na tela fica como sempre: começando na coluna, sem
/// passar pela ordem visual.
fn latinLeft(app: *App) bool {
    const cs = app.store.channel(gw.rtl_channel) orelse return false;
    var i = cs.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = &cs.messages.items[i];
        if (m.msg.content.len == 0 or bidi.hasRtl(m.msg.content)) continue;
        var b: [64]u8 = undefined;
        const t = qa.find(std.fmt.bufPrint(&b, "msgtext:{d}", .{m.msg.id}) catch return false) orelse continue;
        const col = colOf(m.msg.id) orelse continue;
        return near(t.x, col.x) and lineOf(m.msg.id, 0) == null;
    }
    return false;
}

/// A barra de ações da mensagem em árabe está na tela e não cobre o começo dela (a ponta
/// direita da primeira linha): nos temas de terminal ela fica em cima da linha do texto.
fn startUncovered(app: *App) bool {
    const m = msgWith(app, gw.rtl_arabic) orelse return false;
    const l = lineOf(m.msg.id, 0) orelse return false;
    const px = l.right() - 2;
    const py = l.y + l.h / 2;
    var seen = false;
    var b: [64]u8 = undefined;
    for (0..8) |k| {
        const r = qa.find(std.fmt.bufPrint(&b, "tb:{d}:{d}", .{ m.msg.id, k }) catch return false) orelse continue;
        seen = true;
        if (r.contains(px, py)) return false;
    }
    return seen;
}

/// A mensagem com um parágrafo latino e outro em árabe (com o link no meio).
fn mixedMsg(app: *App) ?*const StoredMessage {
    const cs = app.store.channel(gw.rtl_channel) orelse return null;
    for (cs.messages.items) |*m| if (std.mem.endsWith(u8, m.msg.content, gw.rtl_mixed_arabic)) return m;
    return null;
}

fn tMixed(app: *App, buf: []u8) []const u8 {
    const m = mixedMsg(app) orelse return "";
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{m.msg.id}) catch "";
}

fn showMixed(app: *App) void {
    if (mixedMsg(app)) |m| app.st.jump = m.msg.id;
}

fn mixedShown(app: *App) bool {
    const m = mixedMsg(app) orelse return false;
    return app.st.jump == 0 and lineOf(m.msg.id, 1) != null;
}

/// O parágrafo latino (a primeira linha) começa na coluna; cada linha do árabe termina na
/// borda direita.
fn mixedAligned(app: *App) bool {
    const m = mixedMsg(app) orelse return false;
    const col = colOf(m.msg.id) orelse return false;
    const first = lineOf(m.msg.id, 0) orelse return false;
    return near(first.x, col.x) and linesRight(m.msg.id, 1);
}

fn mixedSelected(app: *App) bool {
    const m = mixedMsg(app) orelse return false;
    const sel = &app.st.selection;
    if (sel.a_id != m.msg.id or sel.b_id != m.msg.id) return false;
    return @min(sel.a_off, sel.b_off) == 0 and @max(sel.a_off, sel.b_off) == m.msg.content.len;
}

fn mixedCopied(app: *App) bool {
    const m = mixedMsg(app) orelse return false;
    const got = c.SDL_GetClipboardText() orelse return false;
    defer c.SDL_free(got);
    return std.mem.eql(u8, std.mem.span(got), m.msg.content);
}

fn tMixedLink(_: *App, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "link:{s}", .{gw.rtl_link}) catch "";
}

fn clearOpened(_: *App) void {
    att.last_opened_len = 0;
}

fn linkOpened(_: *App) bool {
    return std.mem.eql(u8, att.last_opened[0..att.last_opened_len], gw.rtl_link);
}

// --- Mensagem curta que continua o grupo -------------------------------------------------

/// "obrigado": curta, em árabe, da mesma pessoa da última mensagem do #música e 20 s depois
/// dela. Continua o grupo: no layout cozy (e no compacto) não tem a linha do nome em cima, e a
/// barra de ações cai na altura da primeira linha do texto.
const short_rtl = "شكرا";
var short_id: types.Id = 0;

fn pushShort(app: *App) void {
    const cs = app.store.channel(gw.rtl_channel) orelse return;
    const items = cs.messages.items;
    if (items.len == 0) return;
    const last = &items[items.len - 1];
    const content = std.heap.c_allocator.dupe(u8, short_rtl) catch return;
    short_id = types.makeSnowflake(gw.nowMs(), 0x3e000);
    app.events.push(.{ .message_create = .{ .id = short_id, .channel = gw.rtl_channel, .author = last.msg.author, .timestamp = last.msg.timestamp + 20, .content = content } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
    app.st.scrollOf(gw.rtl_channel).stick_bottom = true;
}

fn tShort(_: *App, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{short_id}) catch "";
}

fn markOf(comptime fmt: []const u8, id: types.Id) ?Rect {
    var b: [64]u8 = undefined;
    return qa.find(std.fmt.bufPrint(&b, fmt, .{id}) catch return null);
}

/// Na tela, alinhada à direita e sem a linha do nome em cima (o texto começa no alto da linha
/// dela; no cozy, a que abre o grupo tem o nome antes, e no balão, o nome fora dele).
fn shortShown(_: *App) bool {
    const row = markOf("msg:{d}", short_id) orelse return false;
    const t = markOf("msgtext:{d}", short_id) orelse return false;
    return t.y - row.y < 12 and linesRight(short_id, 0);
}

/// Sobe a conversa um pouco: o botão de voltar ao fim aparece, com a curta embaixo dele.
fn nudgeUp(app: *App) void {
    const sc = app.st.scrollOf(gw.rtl_channel);
    sc.stick_bottom = false;
    sc.target = @max(0, sc.pos - 12);
}

fn stickBottom(app: *App) void {
    app.st.scrollOf(gw.rtl_channel).stick_bottom = true;
}

/// A curta começa na borda direita: o botão foi para o canto esquerdo, longe dela.
fn jumpLeftOfShort(_: *App) bool {
    const jb = qa.find("jump-bottom") orelse return false;
    const t = markOf("msgtext:{d}", short_id) orelse return false;
    return jb.right() < t.x;
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom();
}

/// A barra de ações da mensagem: os botões e a borda dela em volta (ui/comp_messages.zig).
fn barOf(id: types.Id) ?Rect {
    var b: [64]u8 = undefined;
    var lo_x: f32 = std.math.floatMax(f32);
    var hi_x: f32 = 0;
    var y: f32 = 0;
    var seen = false;
    for (0..8) |k| {
        const r = qa.find(std.fmt.bufPrint(&b, "tb:{d}:{d}", .{ id, k }) catch return null) orelse continue;
        lo_x = @min(lo_x, r.x);
        hi_x = @max(hi_x, r.right());
        y = r.y;
        seen = true;
    }
    if (!seen) return null;
    return .{ .x = lo_x - 4, .y = y - 2, .w = hi_x - lo_x + 8, .h = 36 };
}

/// Com o mouse em cima da mensagem curta, a barra de ações aparece e não cobre nada do texto.
fn shortUncovered(_: *App) bool {
    const t = markOf("msgtext:{d}", short_id) orelse return false;
    const bar = barOf(short_id) orelse return false;
    return !overlaps(bar, t);
}

/// O duplo clique no meio dela seleciona a palavra, não aperta um botão da barra (o de
/// responder ficava bem ali).
fn shortWordSelected(app: *App) bool {
    const sel = &app.st.selection;
    if (sel.a_id != short_id or sel.b_id != short_id) return false;
    return @min(sel.a_off, sel.b_off) == 0 and @max(sel.a_off, sel.b_off) == short_rtl.len and app.st.reply_to != short_id;
}

var dev_before = false;
var compact_before = false;

fn devOn(app: *App) void {
    dev_before = app.st.settings.developer_mode;
    app.st.settings.developer_mode = true;
}

fn devBack(app: *App) void {
    app.st.settings.developer_mode = dev_before;
}

/// O "id N" do modo de desenvolvedor (só no layout cozy) fica fora do texto: a linha de baixo
/// termina na borda direita, onde ele costuma ficar.
fn devIdClear(_: *App) bool {
    const id = markOf("devid:{d}", short_id) orelse return qa.find("msg-layout:cozy") == null;
    const t = markOf("msgtext:{d}", short_id) orelse return false;
    return !overlaps(id, t);
}

fn compactOn(app: *App) void {
    compact_before = app.st.settings.compact;
    app.st.settings.compact = true;
}

fn compactBack(app: *App) void {
    app.st.settings.compact = compact_before;
}

fn dropShort(app: *App) void {
    app.events.push(.{ .message_delete = .{ .channel = gw.rtl_channel, .id = short_id, .local = true } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
}

fn shortGone(app: *App) bool {
    const cs = app.store.channel(gw.rtl_channel) orelse return false;
    return app.store.find(cs, short_id) == null;
}

// --- Issue #9: o que um leitor de árabe mandou -----------------------------------------

/// Uma mensagem do #regras de "os larpers" (net/fake_gateway.zig, `demoRtlRules`) pelo texto.
fn rulesMsg(app: *App, text: []const u8) ?*const StoredMessage {
    const cs = app.store.channel(gw.rtl_rules_channel) orelse return null;
    for (cs.messages.items) |*m| if (std.mem.eql(u8, m.msg.content, text)) return m;
    return null;
}

/// A mensagem cujo embed tem esta descrição.
fn rulesEmbedMsg(app: *App, description: []const u8) ?*const StoredMessage {
    const cs = app.store.channel(gw.rtl_rules_channel) orelse return null;
    for (cs.messages.items) |*m| {
        for (m.msg.embeds) |e| if (std.mem.eql(u8, e.description, description)) return m;
    }
    return null;
}

fn toRules(app: *App) void {
    app.handle(.{ .open_message = .{ .channel = gw.rtl_rules_channel, .id = 0 } });
    app.st.scrollOf(gw.rtl_rules_channel).stick_bottom = true;
}

fn rulesReady(app: *App) bool {
    if (app.st.activeChannel() != gw.rtl_rules_channel) return false;
    const cs = app.store.channel(gw.rtl_rules_channel) orelse return false;
    return cs.history == .loaded;
}

/// Leva a conversa até a mensagem (o destaque do pulo some em 1,6 s; o print espera).
fn jumpTo(app: *App, m: ?*const StoredMessage) void {
    if (m) |x| app.st.jump = x.msg.id;
}

fn jumpX(app: *App) void {
    jumpTo(app, rulesEmbedMsg(app, gw.rtl_x_description));
}
fn jumpBot(app: *App) void {
    jumpTo(app, rulesEmbedMsg(app, gw.rtl_bot_description));
}
fn jumpRulesEmbed(app: *App) void {
    jumpTo(app, rulesEmbedMsg(app, gw.rtl_rules_embed));
}
fn jumpRulesText(app: *App) void {
    jumpTo(app, rulesMsg(app, gw.rtl_rules_text));
}
fn jumpUrdu(app: *App) void {
    jumpTo(app, rulesMsg(app, gw.rtl_urdu));
}

fn jumped(app: *App) bool {
    return app.st.jump == 0;
}

fn tOrdered(app: *App, buf: []u8) []const u8 {
    const m = rulesMsg(app, gw.rtl_ordered) orelse return "";
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{m.msg.id}) catch "";
}

// Onde cada trecho foi desenhado (ui/rich.zig, `qa_watch`): a ordem visual de verdade.

const rich = @import("ui/rich.zig");
const d = @import("ui/draw.zig");

/// Passa a anotar os trechos do texto que começa em `ptr` (vale a partir do próximo quadro).
fn watch(ptr: ?[*]const u8) void {
    rich.qa_watch = ptr;
    rich.qa_runs_n = 0;
}

fn watching(ptr: [*]const u8) bool {
    return rich.qa_watch != null and rich.qa_watch.? == ptr;
}

fn runs() []const rich.QaRun {
    return rich.qa_runs[0..rich.qa_runs_n];
}

/// O trecho que começa no byte `off` do texto vigiado (o marcador: `marker`).
fn runAt(off: usize, marker: bool) ?rich.QaRun {
    for (runs()) |r| if (r.off == off and r.marker == marker) return r;
    return null;
}

/// O trecho que contém o byte `off`.
fn runWith(off: usize) ?rich.QaRun {
    for (runs()) |r| if (!r.marker and off >= r.off and off < r.off + r.len) return r;
    return null;
}

fn sameLine(a: rich.QaRun, b: rich.QaRun) bool {
    return @abs(a.y - b.y) < 1;
}

fn watchMsg(app: *App, text: []const u8) bool {
    const m = rulesMsg(app, text) orelse return false;
    if (!watching(m.msg.content.ptr)) {
        watch(m.msg.content.ptr);
        return false;
    }
    return rich.qa_runs_n > 0;
}

fn watchEmbed(app: *App, description: []const u8) ?[]const u8 {
    const m = rulesEmbedMsg(app, description) orelse return null;
    const e = m.msg.embeds[0].description;
    if (!watching(e.ptr)) {
        watch(e.ptr);
        return null;
    }
    return if (rich.qa_runs_n > 0) e else null;
}

/// "1. Hello": o número fica na margem e o texto começa depois dele, com espaço.
fn orderedLatin(app: *App) bool {
    if (!watchMsg(app, gw.rtl_ordered_latin)) return false;
    const mk = runAt(0, true) orelse return false;
    const hello = runAt(3, false) orelse return false;
    return mk.x + mk.w + 2 <= hello.x;
}

/// O marcador `mk` está à direita de todo o texto da linha dele, e o texto termina perto dele.
fn markerRightOfText(mk: rich.QaRun) bool {
    var any = false;
    for (runs()) |r| {
        if (r.marker or !sameLine(r, mk)) continue;
        any = true;
        if (r.x + r.w > mk.x + 0.5) return false;
    }
    return any;
}

/// "1. السلام عليكم": item numerado em árabe, o número à direita do texto (como ".1").
fn orderedRtl(app: *App) bool {
    if (!watchMsg(app, gw.rtl_ordered)) return false;
    const mk = runAt(0, true) orelse return false;
    return mk.rtl and markerRightOfText(mk);
}

fn jumpWide(app: *App) void {
    jumpTo(app, rulesMsg(app, gw.rtl_ordered_wide));
}

/// O marcador da linha que começa no byte `off` foi desenhado como `want`.
fn markerShows(off: usize, want: []const u8) bool {
    const mk = runAt(off, true) orelse return false;
    return std.mem.eql(u8, mk.shown[0..mk.shown_len], want);
}

/// A linha `n` (contando do 0) de `text` começa neste byte.
fn lineStart(text: []const u8, n: usize) usize {
    var at: usize = 0;
    for (0..n) |_| at = std.mem.indexOfScalarPos(u8, text, at, '\n').? + 1;
    return at;
}

/// "10.", "12." e "123." num parágrafo RTL saem ".10", ".12" e ".123", à direita do texto;
/// em português, "10." e "1000." como estão.
fn wideNumbers(app: *App) bool {
    if (!watchMsg(app, gw.rtl_ordered_wide)) return false;
    const t = gw.rtl_ordered_wide;
    if (!markerShows(lineStart(t, 0), ".10") or !markerShows(lineStart(t, 1), ".12") or !markerShows(lineStart(t, 2), ".123")) return false;
    for (0..3) |n| if (!markerRightOfText(runAt(lineStart(t, n), true).?)) return false;
    return true;
}

/// O marcador de cada item da mensagem fica dentro da coluna do texto: o número largo empurra
/// o item para dentro em vez de passar da borda (a esquerda, ou a direita num parágrafo RTL).
fn markersInColumn(app: *App, text: []const u8) bool {
    if (!watchMsg(app, text)) return false;
    const m = rulesMsg(app, text) orelse return false;
    const col = colOf(m.msg.id) orelse return false;
    var any = false;
    for (runs()) |r| if (r.marker) {
        any = true;
        if (r.x < col.x - 0.5 or r.x + r.w > col.right() + 0.5) return false;
    };
    return any;
}

fn wideInColumnRtl(app: *App) bool {
    return markersInColumn(app, gw.rtl_ordered_wide);
}

fn wideInColumnLtr(app: *App) bool {
    if (!markersInColumn(app, gw.ltr_ordered_wide)) return false;
    // E o texto de "10." e o de "1000." começam no mesmo x.
    const t = gw.ltr_ordered_wide;
    const a = runAt(lineStart(t, 0) + 4, false) orelse return false;
    const b = runAt(lineStart(t, 1) + 6, false) orelse return false;
    return @abs(a.x - b.x) < 0.5;
}

fn jumpCode(app: *App) void {
    jumpTo(app, rulesMsg(app, gw.rtl_code));
}

fn tCode(app: *App, buf: []u8) []const u8 {
    const m = rulesMsg(app, gw.rtl_code) orelse return "";
    return std.fmt.bufPrint(buf, "msgtext:{d}", .{m.msg.id}) catch "";
}

/// Arrastar da ponta direita do código em árabe até o meio pega o começo dele (o texto do
/// código sai da direita para a esquerda, e a seleção acompanha).
fn codeSelectedFromStart(app: *App) bool {
    const m = rulesMsg(app, gw.rtl_code) orelse return false;
    const sel = &app.st.selection;
    if (sel.a_id != m.msg.id or sel.b_id != m.msg.id) return false;
    const lo = @min(sel.a_off, sel.b_off);
    const hi = @max(sel.a_off, sel.b_off);
    return lo == 1 and hi > 1 and hi + 1 < m.msg.content.len;
}

/// U+E0100 (seletor de variação do plano 14) e as letras escondidas das bandeiras não
/// esticam as tabelas por caractere da fonte (ImFontBaked_Slot): num tamanho que nada mais
/// usa, elas ficam do tamanho das do começo do Unicode e dos emoji.
fn planeFourteenSmall(app: *App) bool {
    const f = app.fonts.families.items[0].get(.regular);
    _ = d.width(f, 37, "\u{E0100}\u{E0067}");
    const n = larper_font_index_size(f, d.fontPx(37));
    return n > 0 and n <= 0x4200;
}
extern fn larper_font_index_size(font: *c.ImFont, size: f32) c_int;

fn wideNumbersLtr(app: *App) bool {
    if (!watchMsg(app, gw.ltr_ordered_wide)) return false;
    const t = gw.ltr_ordered_wide;
    return markerShows(lineStart(t, 0), "10.") and markerShows(lineStart(t, 1), "1000.");
}

/// "- مرحبا\n- مرحبا 😃": os dois "•" à direita do texto, e o emoji à esquerda da palavra.
fn bulletsRtl(app: *App) bool {
    if (!watchMsg(app, gw.rtl_list)) return false;
    const second = std.mem.indexOfScalar(u8, gw.rtl_list, '\n').? + 1;
    const a = runAt(0, true) orelse return false;
    const b = runAt(second, true) orelse return false;
    if (!markerRightOfText(a) or !markerRightOfText(b)) return false;
    const word = runAt(second + 2, false) orelse return false;
    const emoji = runWith(std.mem.indexOf(u8, gw.rtl_list, "😃").?) orelse return false;
    return emoji.x + emoji.w <= word.x + 0.5;
}

/// "12- السلام عليكم": parágrafo RTL (o número não decide a direção), o 12 na ponta direita e
/// o traço à esquerda dele.
fn dashLeft(app: *App) bool {
    if (!watchMsg(app, gw.rtl_dash)) return false;
    const num = runAt(0, false) orelse return false;
    const dash = runAt(2, false) orelse return false;
    for (runs()) |r| if (r.x > num.x) return false;
    return dash.x + dash.w <= num.x + 0.5 and rightAlignedRules(app, gw.rtl_dash);
}

fn rightAlignedRules(app: *App, text: []const u8) bool {
    const m = rulesMsg(app, text) orelse return false;
    return linesRight(m.msg.id, 0);
}

/// "مساء الخير what is the problem؟": o "؟" grudado no inglês vai para o fim da frase árabe,
/// a ponta esquerda da linha.
fn questionLast(app: *App) bool {
    if (!watchMsg(app, gw.rtl_question)) return false;
    const q = runWith(std.mem.indexOf(u8, gw.rtl_question, "؟").?) orelse return false;
    if (!q.rtl) return false;
    for (runs()) |r| if (r.x < q.x) return false;
    return rightAlignedRules(app, gw.rtl_question);
}

/// "السلام عليكم (تجربة)": o trecho dos parênteses sai espelhado (na tela, "(" à esquerda e
/// ")" à direita da palavra, abrindo para ela).
fn parensMirrored(app: *App) bool {
    if (!watchMsg(app, gw.rtl_parens)) return false;
    const off = std.mem.indexOfScalar(u8, gw.rtl_parens, '(').?;
    const r = runAt(off, false) orelse return false;
    if (!r.rtl) return false;
    const v = bidi.visualRun(gw.rtl_parens[r.off..][0..r.len], true) orelse return false;
    return v[0] == '(' and v[v.len - 1] == ')';
}

/// O embed do bot: "( ✔️ )" no meio do árabe: o "(" do texto fica à direita do emoji, o ")"
/// à esquerda, os dois espelhados.
fn botParens(app: *App) bool {
    const e = watchEmbed(app, gw.rtl_bot_description) orelse return false;
    const open_at = std.mem.indexOf(u8, e, "( ").?;
    const open = runAt(open_at, false) orelse return false;
    const emoji = runAt(open_at + 2, false) orelse return false;
    const close = runAt(std.mem.indexOf(u8, e, " )").? + 1, false) orelse return false;
    return open.rtl and close.rtl and open.x > emoji.x and emoji.x > close.x;
}

/// As regras em itálico: "1.يمنع" é RTL, o 1 na ponta direita e o ponto logo à esquerda dele;
/// toda linha termina na mesma borda direita, também a da citação (a barra fica à esquerda).
fn rulesPeriod(app: *App) bool {
    const e = watchEmbed(app, gw.rtl_rules_embed) orelse return false;
    const at = std.mem.indexOf(u8, e, gw.rtl_period).?;
    const one = runAt(at, false) orelse return false;
    const dot = runAt(at + 1, false) orelse return false;
    if (!sameLine(one, dot) or dot.x + dot.w > one.x + 0.5) return false;
    var edge: f32 = 0;
    for (runs()) |r| edge = @max(edge, r.x + r.w);
    if (@abs(one.x + one.w - edge) > 1) return false;
    const q = std.mem.indexOf(u8, e, "3.").?;
    const three = runAt(q, false) orelse return false;
    return @abs(three.x + three.w - edge) <= 1;
}

/// O texto de uma linha de um embed (autor, título, nome de campo) termina na borda direita da
/// coluna, quando começa por letra RTL.
fn embedTextRight(ptr: [*]const u8) bool {
    var b: [48]u8 = undefined;
    const t = qa.find(std.fmt.bufPrint(&b, "embed-text:{x}", .{@intFromPtr(ptr)}) catch return false) orelse return false;
    const col = qa.find(std.fmt.bufPrint(&b, "embed-col:{x}", .{@intFromPtr(ptr)}) catch return false) orelse return false;
    return near(t.right(), col.right()) and t.x > col.x + 4;
}

fn botTitleRight(app: *App) bool {
    const m = rulesEmbedMsg(app, gw.rtl_bot_description) orelse return false;
    const e = m.msg.embeds[0];
    return embedTextRight(e.title.ptr) and embedTextRight(e.fields[0].name.ptr);
}

fn xAuthorRight(app: *App) bool {
    const m = rulesEmbedMsg(app, gw.rtl_x_description) orelse return false;
    return embedTextRight(m.msg.embeds[0].author.ptr);
}

/// A barra invertida do markdown (`\.`, `\~`) não aparece: o que vai para a tela não tem
/// nenhuma, e o "12~24" fica inteiro.
fn noBackslash(app: *App) bool {
    const m = rulesEmbedMsg(app, gw.rtl_x_description) orelse return false;
    if (m.embed_spans.len == 0) return false;
    var tilde = false;
    for (m.embed_spans[0]) |sp| {
        if (std.mem.indexOfScalar(u8, sp.text, '\\') != null) return false;
        if (std.mem.indexOf(u8, sp.text, "~24") != null) tilde = true;
    }
    return tilde;
}

/// Invisíveis de formatação não ocupam lugar em fonte nenhuma: o seletor de variação do ✔️ e do
/// ⚠️ (que abria um espaço do lado do emoji), a marca de direção do árabe e afins.
fn invisiblesZero(app: *App) bool {
    for (app.fonts.families.items) |fam| {
        const f = fam.get(.regular);
        if (@abs(d.width(f, 14, "✔\u{FE0F}") - d.width(f, 14, "✔")) > 0.01) return false;
        if (@abs(d.width(f, 14, "⚠\u{FE0F}") - d.width(f, 14, "⚠")) > 0.01) return false;
        if (d.width(f, 14, "\u{061C}\u{2066}\u{2069}\u{180E}\u{E0100}\u{00AD}\u{200D}") > 0.01) return false;
    }
    return true;
}

fn unwatch(_: *App) void {
    watch(null);
}

// --- "(apagada)" numa mensagem RTL -------------------------------------------------------

var deleted_id: types.Id = 0;
var log_before = false;

/// Uma mensagem em árabe de outra pessoa, apagada com o registro de mensagens ligado: fica na
/// tela com o "(apagada)" antes da linha dela.
fn pushDeleted(app: *App) void {
    log_before = app.st.settings.message_log;
    app.st.settings.message_log = true;
    app.store.keep_log = true;
    const cs = app.store.channel(gw.rtl_rules_channel) orelse return;
    const items = cs.messages.items;
    if (items.len == 0) return;
    const content = std.heap.c_allocator.dupe(u8, gw.rtl_parens) catch return;
    deleted_id = types.makeSnowflake(gw.nowMs(), 0x3e100);
    app.events.push(.{ .message_create = .{ .id = deleted_id, .channel = gw.rtl_rules_channel, .author = 1003, .timestamp = items[items.len - 1].msg.timestamp + 30, .content = content } });
    app.events.push(.{ .message_delete = .{ .channel = gw.rtl_rules_channel, .id = deleted_id } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
    app.st.scrollOf(gw.rtl_rules_channel).stick_bottom = true;
}

/// O "(apagada)" está na tela e não fica em cima de nenhuma linha do texto (no balão, que se
/// alarga para caber os dois).
fn deletedClear(_: *App) bool {
    const lbl = markOf("edited:{d}", deleted_id) orelse return false;
    var n: usize = 0;
    while (lineOf(deleted_id, n)) |l| : (n += 1) {
        if (overlaps(lbl, l)) return false;
    }
    return n > 0;
}

fn dropDeleted(app: *App) void {
    app.events.push(.{ .message_delete = .{ .channel = gw.rtl_rules_channel, .id = deleted_id, .local = true } });
    @import("platform/window.zig").Window.wake(app.win.wake_type, .gateway);
    app.st.settings.message_log = log_before;
    app.store.keep_log = log_before;
}

fn deletedGone(app: *App) bool {
    const cs = app.store.channel(gw.rtl_rules_channel) orelse return false;
    return app.store.find(cs, deleted_id) == null;
}

fn toBottom(app: *App) void {
    app.st.scrollOf(gw.rtl_rules_channel).stick_bottom = true;
}

fn goHome(app: *App) void {
    if (home != 0) app.handle(.{ .open_message = .{ .channel = home, .id = 0 } });
}

fn atHome(app: *App) bool {
    return home == 0 or app.st.activeChannel() == home;
}

pub const ops_theme = [_]Op{
    .{ .section = "árabe e hebraico" },
    run(toMusic),
    expect("o #música abre", musicReady),
    .{ .wait = 400 },
    expect("as mensagens em árabe e hebraico aparecem", bothShown),
    expect("o árabe vai para a tela com as letras ligadas", shaped),
    expect("nenhuma letra árabe ou hebraica sem fonte (nada de ?)", noQuestionMarks),
    expect("o árabe termina na borda direita da coluna", arabicRight),
    expect("o hebraico termina na borda direita da coluna", hebrewRight),
    expect("a mensagem em português continua à esquerda", latinLeft),
    .{ .hover = .{ .dyn_at = .{ .f = tArabic, .fx = 0.5, .fy = 0.5 } } },
    expect("com o mouse em cima, a barra de ações não cobre o começo do árabe", startUncovered),
    // Para o print: o mouse acima da janela, sem a barra de ações de uma mensagem por cima.
    .{ .hover = .{ .dyn_at = .{ .f = tArabic, .fx = 0.5, .fy = -60 } } },
    .{ .shot = "rtl" },
    run(clearToast),
    // Da borda direita da frase (onde ela começa; logo à direita, nos temas de terminal, já é
    // a faixa da barra de rolagem) até depois do fim, à esquerda.
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tArabic, .fx = 1.0, .fy = 0.5 } }, .to = .{ .dyn_at = .{ .f = tArabic, .fx = -0.02, .fy = 0.5 } } } },
    expect("arrastar da direita para a esquerda seleciona a mensagem inteira", wholeSelected),
    .{ .shot = "rtl-selecao" },
    .{ .key = .{ .key = c.ImGuiKey_C, .ctrl = true } },
    expect("copiar devolve o texto como foi escrito", copiedLogical),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    run(showMixed),
    expect("a mensagem com um parágrafo latino e outro árabe aparece", mixedShown),
    .{ .wait = 600 },
    expect("na mensagem mista, o latino fica à esquerda e o árabe termina na direita", mixedAligned),
    // Do começo do latino (à esquerda da primeira linha) até o fim do árabe (à esquerda da
    // última linha, que é onde ele acaba na tela).
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tMixed, .fx = -0.02, .fy = 0.12 } }, .to = .{ .dyn_at = .{ .f = tMixed, .fx = -0.02, .fy = 0.92 } } } },
    expect("arrastar seleciona a mensagem mista inteira", mixedSelected),
    .{ .key = .{ .key = c.ImGuiKey_C, .ctrl = true } },
    expect("copiar a mista devolve o texto como foi escrito", mixedCopied),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    run(clearOpened),
    .{ .click = .{ .dyn = tMixedLink } },
    expect("o link no meio do árabe abre", linkOpened),
    // Print sem o aviso do copiar, sem o mouse em cima e depois do destaque do pulo (1,6 s).
    run(clearToast),
    .{ .hover = .{ .dyn_at = .{ .f = tMixed, .fx = 0.5, .fy = -60 } } },
    .{ .wait = 1000 },
    .{ .shot = "rtl-mista" },
    // Curta, em árabe, continuando o grupo: a barra de ações não esconde a frase nem pega o
    // clique nela, e o "id" do modo de desenvolvedor fica fora dela; no compacto também.
    run(pushShort),
    expect("uma mensagem curta em árabe continua o grupo, alinhada à direita", shortShown),
    .{ .hover = .{ .dyn_at = .{ .f = tShort, .fx = 0.5, .fy = 0.5 } } },
    expect("com o mouse em cima, a barra de ações não cobre a mensagem curta", shortUncovered),
    .{ .dclick = .{ .dyn_at = .{ .f = tShort, .fx = 0.5, .fy = 0.5 } } },
    expect("o duplo clique no meio dela seleciona a palavra, sem responder", shortWordSelected),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    run(devOn),
    .{ .hover = .{ .dyn_at = .{ .f = tShort, .fx = 0.5, .fy = 0.5 } } },
    expect("no modo de desenvolvedor, o id não fica em cima dela", devIdClear),
    run(devBack),
    run(compactOn),
    .{ .wait = 300 },
    .{ .hover = .{ .dyn_at = .{ .f = tShort, .fx = 0.5, .fy = 0.5 } } },
    expect("no modo compacto, a barra de ações também não cobre a mensagem curta", shortUncovered),
    .{ .shot = "rtl-curta" },
    run(compactBack),
    .{ .wait = 300 },
    run(nudgeUp),
    .{ .hover = .{ .dyn_at = .{ .f = tShort, .fx = 0.5, .fy = -60 } } },
    .{ .wait = 400 },
    expect("com a curta em árabe embaixo dele, o botão de voltar ao fim fica à esquerda", jumpLeftOfShort),
    .{ .shot = "rtl-voltar-ao-fim" },
    run(stickBottom),
    run(dropShort),
    expect("a mensagem curta sai", shortGone),
    // Issue #9: os casos do leitor de árabe, cada um num print (comparar com o Discord).
    run(toRules),
    expect("o #regras com os casos do issue #9 abre", rulesReady),
    .{ .wait = 400 },
    .{ .hover = .{ .dyn_at = .{ .f = tOrdered, .fx = 0.5, .fy = -60 } } },
    expect("\"1. Hello\": o número na margem e o texto depois dele, com espaço", orderedLatin),
    expect("\"1. السلام عليكم\": item numerado em árabe, com o número à direita do texto", orderedRtl),
    expect("lista com marcador em árabe: o • à direita do texto e o emoji à esquerda da palavra", bulletsRtl),
    expect("\"12- السلام\": parágrafo RTL, o traço à esquerda do número", dashLeft),
    expect("o ؟ depois do inglês vai para o fim da frase árabe", questionLast),
    expect("os parênteses de \"(تجربة)\" saem espelhados", parensMirrored),
    expect("invisíveis de formatação (o FE0F do ✔️) não abrem espaço do lado do emoji", invisiblesZero),
    .{ .shot = "rtl9-lista" },
    run(pushDeleted),
    expect("uma mensagem em árabe apagada fica com o \"(apagada)\" fora do texto", deletedClear),
    .{ .shot = "rtl9-apagada" },
    run(dropDeleted),
    expect("a apagada sai", deletedGone),
    run(jumpWide),
    expect("a lista com números de dois e três algarismos aparece", jumped),
    .{ .wait = 1700 },
    expect("\"12. نص\": o número da lista sai \".12\", não \".21\" (e \".10\", \".123\")", wideNumbers),
    expect("\"1000. World\": número largo da lista em português, como está", wideNumbersLtr),
    expect("número largo da lista em árabe não passa da borda direita da coluna", wideInColumnRtl),
    expect("número largo da lista em português não passa da borda esquerda da coluna", wideInColumnLtr),
    .{ .shot = "rtl9-numeros" },
    run(jumpCode),
    expect("o código em árabe aparece", jumped),
    .{ .wait = 1700 },
    .{ .drag = .{ .from = .{ .dyn_at = .{ .f = tCode, .fx = 0.97, .fy = 0.5 } }, .to = .{ .dyn_at = .{ .f = tCode, .fx = 0.5, .fy = 0.5 } } } },
    expect("arrastar da ponta direita do código em árabe até o meio pega o começo dele", codeSelectedFromStart),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("U+E0100 e as letras das bandeiras não esticam as tabelas da fonte", planeFourteenSmall),
    run(jumpX),
    expect("o embed do X aparece", jumped),
    .{ .wait = 1700 },
    expect("o autor em árabe do embed do X termina na borda direita", xAuthorRight),
    expect("a barra invertida do markdown (\\. e \\~) não aparece na descrição", noBackslash),
    .{ .shot = "rtl9-x" },
    run(jumpBot),
    expect("o embed do bot aparece", jumped),
    .{ .wait = 1700 },
    expect("o título e o nome do campo em árabe terminam na borda direita do embed", botTitleRight),
    expect("o emoji entre parênteses no meio do árabe: \"( ✔️ )\" na ordem certa", botParens),
    .{ .shot = "rtl9-bot" },
    run(jumpRulesEmbed),
    expect("o embed das regras aparece", jumped),
    .{ .wait = 1700 },
    expect("\"1.يمنع\": RTL, o ponto à esquerda do 1 e toda linha (também a citada) na borda direita", rulesPeriod),
    .{ .shot = "rtl9-regras" },
    run(jumpRulesText),
    expect("as regras com marcador aparecem", jumped),
    .{ .wait = 1700 },
    .{ .shot = "rtl9-avisos" },
    run(unwatch),
    run(toBottom),
    run(goHome),
    expect("volta para o canal de antes", atHome),
};
