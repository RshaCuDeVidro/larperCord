//! QA de exportar conversa e salvar mídia (vai junto da bateria midia): os três
//! formatos num arquivo escolhido por um "seletor" injetado (nenhuma janela abre),
//! conferidos lendo o que foi gravado; exportar não pede nada ao Discord: nenhum
//! comando para o gateway (o falso conta tudo o que sai, API inclusive) e nenhum
//! download de mídia (o contador de ui/images.zig e o download de mentira), do
//! começo ao fim, com a mídia ligada também (só o que já está no computador vai
//! para a pasta; os arquivos da CDN ficam como link); cancelar no meio não deixa
//! arquivo; e "Salvar…" / "Salvar em Downloads" numa imagem, num vídeo, num arquivo
//! da CDN (aí sim um download, pelo clique) e no visualizador, com uma pasta
//! pessoal de mentira (qa-out/salvar-home: a Downloads de verdade nunca recebe nada).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const salvar = @import("core/salvar.zig");
const job = @import("net/exportar.zig");
const ui = @import("ui/exportar.zig");
const pastas = @import("platform/pastas.zig");
const video = @import("ui/video.zig");
const images = @import("ui/images.zig");
const platform = @import("platform/window.zig");
const StoredMessage = @import("core/store.zig").StoredMessage;
const Id = types.Id;

const media: Id = gw.media_channel;
const dir = "qa-out/exportar";
const home = "qa-out/salvar-home";

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn rclick(k: []const u8) Op {
    return .{ .rclick = .{ .mark = k } };
}
fn rdyn(f: *const fn (*App, []u8) []const u8) Op {
    return .{ .rclick = .{ .dyn = f } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 5000 } };
}
fn slow(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 30000 } };
}

fn load(alloc: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    var size: usize = 0;
    const data = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(data);
    return alloc.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]) catch null;
}

fn exists(path: [*:0]const u8) bool {
    var info: c.SDL_PathInfo = undefined;
    return c.SDL_GetPathInfo(path, &info);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (c.SDL_getenv("QA_DEBUG") != null) std.debug.print("[exportar] " ++ fmt ++ "\n", args);
}

// --- O download de mentira (só o "Salvar" baixa) -------------------------------------

const Fake = struct {
    var mutex: ?*c.SDL_Mutex = null;
    var calls: std.atomic.Value(u32) = .init(0);
    /// Endereço fora da CDN ou com caminho de API (tem que ficar 0).
    var bad: std.atomic.Value(u32) = .init(0);
    var sleep_ms: u32 = 300;
    var last: [512]u8 = undefined;
    var last_len: usize = 0;

    fn reset(sleep: u32) void {
        if (mutex == null) mutex = c.SDL_CreateMutex();
        calls.store(0, .release);
        bad.store(0, .release);
        sleep_ms = sleep;
        last_len = 0;
    }

    fn fetch(url: [:0]const u8, sink: images.Sink, stop: *std.atomic.Value(bool)) bool {
        _ = calls.fetchAdd(1, .acq_rel);
        if (has(url, "/api") or has(url, "discord.com/") or !salvar.safeMediaUrl(url)) _ = bad.fetchAdd(1, .acq_rel);
        c.SDL_LockMutex(mutex);
        last_len = @min(url.len, last.len);
        @memcpy(last[0..last_len], url[0..last_len]);
        c.SDL_UnlockMutex(mutex);
        // "Baixando" aos pouquinhos: o cancelar interrompe no meio, como o de verdade.
        var t: u32 = 0;
        while (t < sleep_ms) : (t += 20) {
            if (stop.load(.acquire)) return false;
            c.SDL_Delay(20);
        }
        var body: [600]u8 = undefined;
        const b = std.fmt.bufPrint(&body, "QA-FAKE-MEDIA:{s}", .{url}) catch return false;
        return sink.write(sink.ctx, b, @intCast(b.len));
    }
};

// --- Começo ---------------------------------------------------------------------------

var cmds0: u64 = 0;
var fetches0: u32 = 0;
var quiet_val: u64 = std.math.maxInt(u64);
var quiet_fetches: u32 = std.math.maxInt(u32);
var quiet_since: u64 = 0;
var dialogs0: u32 = 0;
/// O "já está no computador" de verdade (ui/exportar.zig), que o cancelar deixa lento.
var local_real: @TypeOf(job.local_hook) = null;

fn removeTree(path: [:0]const u8) void {
    const Cb = struct {
        fn f(_: ?*anyopaque, d: [*c]const u8, name: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
            var b: [700]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ std.mem.span(d), std.mem.span(name) }, 0) catch return c.SDL_ENUM_CONTINUE;
            var info: c.SDL_PathInfo = undefined;
            if (c.SDL_GetPathInfo(p.ptr, &info) and info.type == c.SDL_PATHTYPE_DIRECTORY) removeTree(p) else _ = c.SDL_RemovePath(p.ptr);
            return c.SDL_ENUM_CONTINUE;
        }
    };
    _ = c.SDL_EnumerateDirectory(path.ptr, Cb.f, null);
    _ = c.SDL_RemovePath(path.ptr);
}

fn setup(app: *App) void {
    _ = app;
    removeTree(dir);
    removeTree(home);
    removeTree("qa-out/salvar");
    _ = c.SDL_CreateDirectory(dir);
    _ = c.SDL_CreateDirectory("qa-out/salvar");
    Fake.reset(300);
    job.fetch_hook = &Fake.fetch;
    local_real = job.local_hook;
    dialogs0 = ui.qa_dialogs;
    // A casa de mentira, com a Downloads trocada pelo user-dirs.dirs.
    pastas.qa_home = home;
    pastas.qa_config = home ++ "/.config";
    _ = c.SDL_CreateDirectory(home ++ "/.config");
    const dirs = "# QA\nXDG_DOWNLOAD_DIR=\"$HOME/Baixados\"\n";
    _ = c.SDL_SaveFile(home ++ "/.config/user-dirs.dirs", dirs, dirs.len);
}

fn finish(_: *App) void {
    job.fetch_hook = null;
    job.local_hook = local_real;
    ui.qa_answer = null;
    pastas.qa_home = null;
    pastas.qa_config = null;
}

/// Nada saindo para o gateway nem baixando há um tempo (para medir a exportação sozinha).
fn quiet(_: *App) bool {
    const v = gw.sent.commands.load(.monotonic);
    const f = images.fetches.load(.monotonic);
    const now = c.SDL_GetTicks();
    if (v != quiet_val or f != quiet_fetches) {
        quiet_val = v;
        quiet_fetches = f;
        quiet_since = now;
        return false;
    }
    return now - quiet_since >= 700;
}

fn snap(_: *App) void {
    cmds0 = gw.sent.commands.load(.monotonic);
    fetches0 = images.fetches.load(.monotonic);
}

/// Nenhum comando para o gateway (a API passa por ele também) desde `snap`.
fn noCommands(_: *App) bool {
    const now = gw.sent.commands.load(.monotonic);
    if (now != cmds0) dbg("comandos: antes {d}, depois {d}", .{ cmds0, now });
    return now == cmds0;
}

/// Nem comando, nem download de mídia (CDN inclusive) desde `snap`.
fn noRequests(app: *App) bool {
    const f = images.fetches.load(.monotonic);
    if (f != fetches0) dbg("downloads de mídia: antes {d}, depois {d}", .{ fetches0, f });
    return noCommands(app) and f == fetches0 and Fake.calls.load(.acquire) == 0;
}

fn goMedia(app: *App) void {
    app.st.scrollOf(media).stick_bottom = true;
}

fn menuExport(_: *App) bool {
    return qa.find("menu:Exportar conversa…") != null;
}

/// O número da marca "export-info:N" da janela aberta.
fn infoCount() ?u32 {
    var out: [4][56]u8 = undefined;
    var lens: [4]u8 = undefined;
    const prefixes = [_][]const u8{"export-info:"};
    if (qa.keysWith(&prefixes, &out, &lens) == 0) return null;
    return std.fmt.parseInt(u32, out[0]["export-info:".len..lens[0]], 10) catch null;
}

/// A janela diz quantas mensagens há no computador (e há).
fn dialogCounts(app: *App) bool {
    if (app.st.popup != .exportar or app.st.popup.exportar.channel != media) return false;
    const n = infoCount() orelse return false;
    expected = n;
    return n > 0;
}
var expected: u32 = 0;

fn answer(comptime name: []const u8) *const fn (*App) void {
    return struct {
        fn f(_: *App) void {
            ui.qa_answer = dir ++ "/" ++ name;
        }
    }.f;
}

fn suggested(comptime ext: []const u8) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            // O seletor respondeu (o arquivo é conferido no passo seguinte, que espera acabar).
            if (ui.qa_dialogs <= dialogs0) return false;
            const sname = ui.qa_suggested[0..ui.qa_suggested_len];
            dialogs0 = ui.qa_dialogs;
            return std.mem.endsWith(u8, sname, ext);
        }
    }.f;
}

// --- Os três formatos -----------------------------------------------------------------

var html_articles: usize = 0;

fn htmlOk(_: *App) bool {
    const a = std.heap.c_allocator;
    const text = load(a, dir ++ "/conversa.html") orelse return false;
    defer a.free(text);
    html_articles = count(text, "<article ");
    const ok = std.mem.startsWith(u8, text, "<!doctype html>") and std.mem.endsWith(u8, text, "</html>\n") and
        has(text, "<title>") and has(text, "--accent:#") and has(text, "aurora.png") and
        // Sem mídia: nada de imagem de fora carregando ao abrir o arquivo.
        !has(text, "<img loading=\"lazy\" src=\"http") and !has(text, "<script") and
        // (Uma mensagem nova chegando entre abrir a janela e exportar também entra.)
        html_articles >= expected and html_articles <= expected + 3 and !exists(dir ++ "/conversa.html.part");
    if (!ok) dbg("html: {d} artigos (esperava {d}), {d} bytes", .{ html_articles, expected, text.len });
    return ok;
}

fn cardOpenFolder(_: *App) bool {
    const opened = pastas.qa_opened[0..pastas.qa_opened_len];
    return std.mem.eql(u8, opened, dir);
}

fn mdOk(_: *App) bool {
    const a = std.heap.c_allocator;
    const text = load(a, dir ++ "/conversa.md") orelse return false;
    defer a.free(text);
    const ok = std.mem.startsWith(u8, text, "# ") and has(text, "\n## 20") and has(text, "aurora.png") and has(text, "\n**") and !exists(dir ++ "/conversa.md.part");
    if (!ok) dbg("md: {d} bytes", .{text.len});
    return ok;
}

fn jsonOk(_: *App) bool {
    const a = std.heap.c_allocator;
    const text = load(a, dir ++ "/conversa.json") orelse return false;
    defer a.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch {
        dbg("json não abriu", .{});
        return false;
    };
    defer parsed.deinit();
    const root = parsed.value.object;
    const msgs = (root.get("messages") orelse return false).array.items;
    if (!std.mem.eql(u8, root.get("format").?.string, "larpercord-export")) return false;
    if (root.get("version").?.integer != 1 or !std.mem.eql(u8, root.get("source").?.string, "local")) return false;
    if (root.get("message_count").?.integer != msgs.len or msgs.len < expected or msgs.len > expected + 3) {
        dbg("json: {d} mensagens, esperava {d} (html {d})", .{ msgs.len, expected, html_articles });
        return false;
    }
    var prev: u64 = 0;
    var photo = false;
    for (msgs) |m| {
        const o = m.object;
        const id = std.fmt.parseInt(u64, o.get("id").?.string, 10) catch return false;
        if (id <= prev) return false;
        prev = id;
        if (o.get("author").?.object.get("name").?.string.len == 0) return false;
        for (o.get("attachments").?.array.items) |at| {
            if (std.mem.eql(u8, at.object.get("name").?.string, "aurora.png") and std.mem.eql(u8, at.object.get("type").?.string, "image")) photo = true;
        }
    }
    return photo and root.get("conversation").?.object.get("id").?.string.len > 0;
}

// --- Mídia ligada ----------------------------------------------------------------------

const n_cdn = 6;
var injected: [n_cdn]Id = @splat(0);

/// Arquivos (não imagens: a conversa não baixa nada deles) com endereço da CDN.
fn inject(app: *App) void {
    const ca = std.heap.c_allocator;
    for (&injected, 0..) |*slot, i| {
        const id = types.makeSnowflake(gw.nowMs(), 0x3e000 + i);
        slot.* = id;
        const atts = ca.alloc(types.Attachment, 1) catch return;
        var nb: [64]u8 = undefined;
        var ub: [160]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "qa-relatorio-{d}.pdf", .{i + 1}) catch return;
        const url = std.fmt.bufPrint(&ub, "https://cdn.discordapp.com/attachments/{d}/{d}/{s}?ex=qa&is=qa&hm=qa", .{ media, id, name }) catch return;
        atts[0] = .{ .url = ca.dupe(u8, url) catch return, .filename = ca.dupe(u8, name) catch return, .size = 1000 + @as(u32, @intCast(i)) };
        app.events.push(.{ .message_create = .{ .id = id, .channel = media, .author = 1002, .timestamp = @divTrunc(gw.nowMs(), 1000), .content = ca.dupe(u8, "segue o relatório") catch return, .attachments = atts } });
    }
    platform.Window.wake(app.win.wake_type, .gateway);
}

fn injectedArrived(app: *App) bool {
    for (injected) |id| if (app.store.findAny(id) == null) return false;
    return true;
}

fn mediaOk(_: *App) bool {
    if (ui.busy()) return false;
    const a = std.heap.c_allocator;
    const text = load(a, dir ++ "/conversa-midia.html") orelse return false;
    defer a.free(text);
    // O que já estava no computador (as imagens e o vídeo da demonstração) foi para a pasta.
    const local_photo = exists(dir ++ "/conversa-midia_arquivos/aurora.png");
    const local_video = exists(dir ++ "/conversa-midia_arquivos/gravacao.mp4");
    // Os da CDN não estavam: nenhum foi baixado, ficaram como link para o original.
    var cdn_files: usize = 0;
    var cdn_links: usize = 0;
    for (1..n_cdn + 1) |i| {
        var pb: [128]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&pb, dir ++ "/conversa-midia_arquivos/qa-relatorio-{d}.pdf", .{i}, 0) catch continue;
        if (exists(p.ptr)) cdn_files += 1;
        var lb: [128]u8 = undefined;
        const link = std.fmt.bufPrint(&lb, "/qa-relatorio-{d}.pdf?ex=qa&amp;is=qa&amp;hm=qa\">qa-relatorio-{d}.pdf</a>", .{ i, i }) catch continue;
        if (has(text, "href=\"https://cdn.discordapp.com/attachments/") and has(text, link)) cdn_links += 1;
    }
    const card = ui.qaCardText(0);
    const as_links = has(card, "link");
    dbg("mídia: foto local {}, vídeo local {}, {d} da CDN na pasta, {d} como link, cartão \"{s}\"", .{ local_photo, local_video, cdn_files, cdn_links, card });
    return local_photo and local_video and cdn_files == 0 and cdn_links == n_cdn and as_links and
        has(text, "src=\"conversa-midia_arquivos/aurora.png\"") and !exists(dir ++ "/conversa-midia.html.part");
}

// --- Cancelar ----------------------------------------------------------------------------

/// O "já está no computador" devagar (um pouco por arquivo), para dar tempo de cancelar.
const Slow = struct {
    var active: std.atomic.Value(u32) = .init(0);

    fn get(url: []const u8, out: *std.ArrayList(u8)) bool {
        _ = active.fetchAdd(1, .acq_rel);
        defer _ = active.fetchSub(1, .acq_rel);
        c.SDL_Delay(400);
        const real = local_real orelse return false;
        return real(url, out);
    }
};

fn slowLocal(_: *App) void {
    job.local_hook = &Slow.get;
}

fn copying(_: *App) bool {
    return ui.busy() and Slow.active.load(.acquire) >= 1;
}

fn cancelled(_: *App) bool {
    if (ui.busy()) return false;
    const leftovers = exists(dir ++ "/cancelada.html") or exists(dir ++ "/cancelada.html.part") or exists(dir ++ "/cancelada_arquivos/aurora.png") or exists(dir ++ "/cancelada_arquivos");
    return !leftovers and (has(ui.qaCardText(0), "cancelada") or has(ui.qaCardText(0), "cancelled"));
}

fn localAgain(_: *App) void {
    job.local_hook = local_real;
}

// --- Salvar ------------------------------------------------------------------------------

fn msgWith(app: *App, filename: []const u8) ?struct { m: *StoredMessage, i: usize } {
    const cs = app.store.channel(media) orelse return null;
    var k = cs.messages.items.len;
    while (k > 0) {
        k -= 1;
        const m = &cs.messages.items[k];
        for (m.msg.attachments, 0..) |a, i| if (std.mem.eql(u8, a.filename, filename)) return .{ .m = m, .i = i };
    }
    return null;
}

fn attMark(app: *App, buf: []u8, filename: []const u8) []const u8 {
    const f = msgWith(app, filename) orelse return "";
    return std.fmt.bufPrint(buf, "att:{d}:{d}", .{ f.m.msg.id, f.i }) catch "";
}

fn jumpTo(comptime filename: []const u8) *const fn (*App) void {
    return struct {
        fn f(app: *App) void {
            if (msgWith(app, filename)) |x| app.handle(.{ .jump_to = x.m.msg.id });
        }
    }.f;
}

fn attShown(comptime filename: []const u8) *const fn (*App) bool {
    return struct {
        fn f(app: *App) bool {
            var b: [64]u8 = undefined;
            const k = attMark(app, &b, filename);
            return k.len > 0 and qa.find(k) != null;
        }
    }.f;
}

fn attTarget(comptime filename: []const u8) *const fn (*App, []u8) []const u8 {
    return struct {
        fn f(app: *App, buf: []u8) []const u8 {
            return attMark(app, buf, filename);
        }
    }.f;
}

fn saveMenu(_: *App) bool {
    return qa.find("menu:Salvar…") != null and qa.find("menu:Salvar em Downloads") != null;
}

fn savedFile(comptime path: [:0]const u8, comptime kind: enum { png, mp4, fake }) *const fn (*App) bool {
    return struct {
        fn f(_: *App) bool {
            if (ui.busy()) return false;
            const a = std.heap.c_allocator;
            const b = load(a, path) orelse return false;
            defer a.free(b);
            return switch (kind) {
                .png => std.mem.startsWith(u8, b, "\x89PNG"),
                .mp4 => b.len == video.demo_mp4.len and std.mem.eql(u8, b, video.demo_mp4),
                .fake => std.mem.startsWith(u8, b, "QA-FAKE-MEDIA:https://cdn.discordapp.com/attachments/"),
            } and !partLeft(path);
        }
    }.f;
}

fn partLeft(path: []const u8) bool {
    var b: [600]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&b, "{s}.part", .{path}, 0) catch return true;
    return exists(p.ptr);
}

fn savedToDownloadsCard(app: *App) bool {
    return savedFile(home ++ "/Baixados/aurora.png", .png)(app) and has(ui.qaCardText(1), "Downloads");
}

fn askedName(_: *App) bool {
    return ui.qa_dialogs > dialogs0 and std.mem.eql(u8, ui.qa_suggested[0..ui.qa_suggested_len], "aurora.png");
}

fn answerSave(_: *App) void {
    dialogs0 = ui.qa_dialogs;
    // Sem extensão: o app põe a do arquivo.
    ui.qa_answer = "qa-out/salvar/escolhido";
}

fn cdnOriginal(app: *App) bool {
    if (!savedFile(home ++ "/Baixados/qa-relatorio-1.pdf", .fake)(app)) return false;
    const last = Fake.last[0..Fake.last_len];
    return Fake.calls.load(.acquire) == 1 and Fake.bad.load(.acquire) == 0 and std.mem.startsWith(u8, last, "https://cdn.discordapp.com/attachments/") and std.mem.indexOf(u8, last, "qa-relatorio-1.pdf") != null;
}

fn resetFake(_: *App) void {
    Fake.reset(100);
}

fn viewerOpen(app: *App) bool {
    return app.st.viewer != null and qa.find("viewer:Salvar em Downloads") != null;
}

fn viewerClosed(app: *App) bool {
    return app.st.viewer == null;
}

fn saveFolderOpened(_: *App) bool {
    return std.mem.eql(u8, pastas.qa_opened[0..pastas.qa_opened_len], home ++ "/Baixados");
}

pub const ops = [_]Op{
    s("exportar conversa"),
    .{ .run = setup },
    click("guild:500000"),
    click("channel:500008"),
    .{ .run = goMedia },
    .{ .wait = 300 },
    // Pelo cabeçalho: o botão direito no nome da conversa.
    rclick("header-title"),
    expect("o botão direito no nome da conversa tem \"Exportar conversa…\"", menuExport),
    click("menu:Exportar conversa…"),
    expect("a janela diz quantas mensagens há neste computador", dialogCounts),
    .{ .shot = "exportar-janela" },
    .{ .expect = .{ .name = "a rede fica parada antes de exportar", .check = quiet, .timeout_ms = 8000 } },
    .{ .run = snap },
    click("export-format:html"),
    .{ .run = answer("conversa.html") },
    click("export-go"),
    expect("o seletor injetado recebe o nome sugerido em .html (nenhuma janela abre)", suggested(".html")),
    expect("HTML: um arquivo só, com as cores do tema, cada mensagem, sem imagem de fora", htmlOk),
    .{ .shot = "exportar-cartao" },
    click("export-card:folder"),
    expect("\"Abrir pasta\" no cartão abre a pasta do arquivo", cardOpenFolder),
    // Pela lista de canais, em Markdown.
    rclick("channel:500008"),
    expect("o botão direito no canal tem \"Exportar conversa…\"", menuExport),
    click("menu:Exportar conversa…"),
    expect("abre a janela de novo", dialogCounts),
    click("export-format:markdown"),
    .{ .run = answer("conversa.md") },
    click("export-go"),
    expect("o nome sugerido vem em .md", suggested(".md")),
    expect("Markdown: título, dias, autores e anexos", mdOk),
    rclick("header-title"),
    click("menu:Exportar conversa…"),
    expect("abre a janela outra vez", dialogCounts),
    click("export-format:json"),
    .{ .run = answer("conversa.json") },
    click("export-go"),
    expect("o nome sugerido vem em .json", suggested(".json")),
    expect("JSON: estrutura documentada, IDs em ordem, as mesmas mensagens do HTML", jsonOk),
    expect("exportar nos três formatos não mandou comando ao gateway nem baixou nada", noRequests),

    s("exportar com mídia"),
    .{ .run = inject },
    expect("chegam 6 mensagens com arquivos da CDN", injectedArrived),
    // As mensagens novas na conversa aberta são marcadas como lidas (isso é do app, não
    // da exportação): conta de novo a partir daqui.
    .{ .expect = .{ .name = "a rede para de novo", .check = quiet, .timeout_ms = 8000 } },
    .{ .run = snap },
    rclick("header-title"),
    click("menu:Exportar conversa…"),
    expect("a janela conta as novas", dialogCounts),
    click("export-format:html"),
    click("export-media"),
    .{ .shot = "exportar-midia" },
    .{ .run = answer("conversa-midia.html") },
    click("export-go"),
    expect("o nome sugerido vem em .html", suggested(".html")),
    slow("mídia: o que estava no computador vai para a pasta, os arquivos da CDN ficam como link", mediaOk),
    .{ .shot = "exportar-midia-cartao" },
    expect("exportar com mídia não mandou comando nem baixou nada (nem da CDN)", noRequests),

    s("cancelar a exportação"),
    .{ .run = slowLocal },
    rclick("header-title"),
    click("menu:Exportar conversa…"),
    expect("a janela abre (com a mídia ainda ligada)", dialogCounts),
    .{ .run = answer("cancelada.html") },
    click("export-go"),
    expect("começa a copiar a mídia do computador", copying),
    .{ .shot = "exportar-andamento" },
    click("export-card:cancel"),
    expect("cancelar no meio para e não deixa arquivo nem pasta", cancelled),
    .{ .run = localAgain },
    expect("cancelar também não pediu nada ao Discord", noRequests),

    s("salvar mídia"),
    .{ .run = jumpTo("aurora.png") },
    expect("a foto aparece na conversa", attShown("aurora.png")),
    .{ .expect = .{ .name = "a rede fica parada antes de salvar", .check = quiet, .timeout_ms = 8000 } },
    .{ .run = snap },
    rdyn(attTarget("aurora.png")),
    expect("o botão direito na imagem tem \"Salvar…\" e \"Salvar em Downloads\"", saveMenu),
    .{ .shot = "salvar-menu" },
    click("menu:Salvar em Downloads"),
    expect("vai para a Downloads do user-dirs.dirs (o arquivo inteiro, PNG) e o cartão diz onde", savedToDownloadsCard),
    .{ .shot = "salvar-cartao" },
    click("save-card:folder"),
    expect("\"Abrir pasta\" abre a Downloads", saveFolderOpened),
    rdyn(attTarget("aurora.png")),
    click("menu:Salvar em Downloads"),
    expect("de novo: um nome novo, sem apagar o outro", savedFile(home ++ "/Baixados/aurora (1).png", .png)),
    .{ .run = answerSave },
    rdyn(attTarget("aurora.png")),
    click("menu:Salvar…"),
    expect("\"Salvar…\" sugere o nome do arquivo", askedName),
    expect("e grava onde o seletor disse, com a extensão", savedFile("qa-out/salvar/escolhido.png", .png)),
    .{ .click = .{ .dyn = attTarget("aurora.png") } },
    expect("o visualizador tem \"Salvar…\" e \"Salvar em Downloads\"", viewerOpen),
    .{ .shot = "salvar-visualizador" },
    click("viewer:Salvar em Downloads"),
    expect("salvar do visualizador grava o original", savedFile(home ++ "/Baixados/aurora (2).png", .png)),
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    expect("Esc fecha o visualizador", viewerClosed),
    expect("salvar a imagem não mandou nenhum comando ao gateway", noCommands),
    .{ .run = jumpTo("gravacao.mp4") },
    expect("o vídeo aparece", attShown("gravacao.mp4")),
    .{ .expect = .{ .name = "a rede fica parada", .check = quiet, .timeout_ms = 8000 } },
    .{ .run = snap },
    rdyn(attTarget("gravacao.mp4")),
    click("menu:Salvar em Downloads"),
    expect("o vídeo salvo é o arquivo de vídeo, não a prévia", savedFile(home ++ "/Baixados/gravacao.mp4", .mp4)),
    expect("salvar o vídeo não mandou nada ao gateway", noCommands),
    .{ .run = jumpTo("qa-relatorio-1.pdf") },
    expect("o arquivo da CDN aparece", attShown("qa-relatorio-1.pdf")),
    .{ .expect = .{ .name = "a rede fica parada", .check = quiet, .timeout_ms = 8000 } },
    .{ .run = snap },
    .{ .run = resetFake },
    rdyn(attTarget("qa-relatorio-1.pdf")),
    click("menu:Salvar em Downloads"),
    expect("o que não está no computador vem da CDN, pelo endereço original, sem a API", cdnOriginal),
    expect("baixar da CDN não mandou nada ao gateway", noCommands),
    .{ .run = finish },
};
