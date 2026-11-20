//! QA das primitivas novas dos temas (entra na bateria por tema do qa_runner.zig):
//! textura gerada uma vez, tema parado que não pede quadros, movimento lento que
//! obedece a "reduzir movimento" e as marcas de cada tema que usa alguma coisa.
//! Também a prévia da resposta a uma mensagem sem texto, em cada tema.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const fx = @import("ui/fx.zig");
const anim = @import("ui/anim.zig");
const extra = @import("ui/comp_extra.zig");
const messages = @import("ui/comp_messages.zig");
const gw = @import("net/fake_gateway.zig");
const types = @import("core/types.zig");
const reply_preview = @import("core/reply_preview.zig");
const sys = @import("platform/sys.zig");
const theme = @import("theme/theme.zig");

fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}

var generated0: u32 = 0;
var wakes0: u32 = 0;

fn remember(_: *App) void {
    generated0 = fx.generated;
    wakes0 = fx.motion_wakes;
}

fn noNewTexture(_: *App) bool {
    return fx.generated == generated0;
}

fn noMotionWake(_: *App) bool {
    return fx.motion_wakes == wakes0;
}

/// Ao redimensionar, refaz só o que depende do tamanho: uma vez, não por quadro.
fn fewNewTextures(_: *App) bool {
    return fx.generated -% generated0 <= 4;
}

fn themeIs(app: *App, name: []const u8) bool {
    return std.mem.eql(u8, app.themes.name(), name);
}

/// Os prints deste tema usam mesmo as primitivas (se ele for um dos que usam).
fn themeMarks(app: *App) bool {
    if (themeIs(app, "orbital")) {
        const word = qa.find("display:ORBITAL") orelse return false;
        // Tracking de verdade: 7 letras mono de 15 px mais 6 × 8 de espaço.
        if (word.w < 95) return false;
        const run = qa.find("display:01") orelse return false;
        if (run.w < 60) return false; // "01" grande + "CANAIS" espaçado na mesma linha
        return qa.find("backdrop:starfield") != null and qa.find("backdrop:orbit") != null and
            qa.find("shape:arc") != null and qa.find("rule:dashed") != null and fx.live_entries > 0;
    }
    if (themeIs(app, "editorial")) {
        return qa.find("display:larperCord") != null and qa.find("rule:oxford") != null and
            qa.find("rule:double") != null and fx.live_entries > 0;
    }
    if (themeIs(app, "cupertino")) {
        return qa.find("backdrop:dunes") != null and qa.find("winctl:close") != null and
            qa.find("winctl:minimize") != null and qa.find("winctl:zoom") != null;
    }
    if (themeIs(app, "vidro")) return qa.find("backdrop:aurora") != null and fx.live_entries > 0;
    return true;
}

fn setMotion(app: *App, on: bool) void {
    if (!themeIs(app, "orbital")) return;
    if (app.themes.setOption("movimento", on)) {}
}

fn motionOn(app: *App) void {
    setMotion(app, true);
    wakes0 = fx.motion_wakes;
}

fn motionOff(app: *App) void {
    setMotion(app, false);
    wakes0 = fx.motion_wakes;
}

/// Pediu quadro, e não mais que 15 por segundo.
fn motionWakes(app: *App) bool {
    if (!themeIs(app, "orbital")) return true;
    if (fx.motion_wakes == wakes0) return false;
    return anim.next_wake_ms - anim.now_ms <= 100 and fx.last_period_ms >= 66;
}

fn reduceOn(app: *App) void {
    app.st.settings.reduce_motion = true;
}

fn reduceOff(app: *App) void {
    app.st.settings.reduce_motion = false;
}

fn reducedStill(app: *App) bool {
    _ = app;
    return fx.motion_wakes == wakes0;
}

fn rememberWakes(_: *App) void {
    wakes0 = fx.motion_wakes;
}

/// `hover-bg` do painel do orbital acende com o mouse em cima.
fn hoverLit(app: *App) bool {
    return !themeIs(app, "orbital") or fx.hover_seen > 0.9;
}

// Os botões da janela: fechar conta (no QA não sai de verdade), maximizar pede
// ao sistema e não pode quebrar a tela. Outros temas não têm a marca: o robô pula.
var closes0: u32 = 0;

fn rememberCloses(_: *App) void {
    closes0 = extra.qa_close_requests;
}

fn tWinClose(app: *App, b: []u8) []const u8 {
    if (!themeIs(app, "cupertino")) return "";
    return std.fmt.bufPrint(b, "winctl:close", .{}) catch "";
}

fn tWinZoom(app: *App, b: []u8) []const u8 {
    if (!themeIs(app, "cupertino")) return "";
    return std.fmt.bufPrint(b, "winctl:zoom", .{}) catch "";
}

fn closeRequested(app: *App) bool {
    return !themeIs(app, "cupertino") or extra.qa_close_requests == closes0 + 1;
}

fn stillUsable(app: *App) bool {
    return app.store.ready and qa.find("composer") != null;
}

pub const ops_window = [_]Op{
    .{ .run = rememberCloses },
    .{ .click = .{ .dyn = tWinClose } },
    expect("o botão de fechar pede para sair", closeRequested),
    .{ .click = .{ .dyn = tWinZoom } },
    .{ .wait = 150 },
    expect("maximizar não quebra a tela", stillUsable),
    .{ .click = .{ .dyn = tWinZoom } },
    .{ .wait = 150 },
    expect("restaurar não quebra a tela", stillUsable),
};

fn settingsInReach(_: *App) bool {
    return qa.find("user-btn:2") != null or qa.find("header-settings") != null;
}

pub const ops_static = [_]Op{
    expect("primitivas do tema estão na tela", themeMarks),
    expect("o botão de configurações está à vista", settingsInReach),
    .{ .hover = .{ .mark = "composer" } },
    .{ .wait = 400 },
    expect("fundo no hover acende", hoverLit),
    .{ .run = remember },
    .{ .wait = 250 },
    expect("textura gerada uma vez, não por quadro", noNewTexture),
    expect("tema parado não pede quadros", noMotionWake),
};

pub const ops_motion = [_]Op{
    .{ .run = motionOn },
    .{ .wait = 120 },
    expect("fundo em movimento pede no máximo 15 quadros/s", motionWakes),
    .{ .run = reduceOn },
    .{ .wait = 50 },
    .{ .run = rememberWakes },
    .{ .wait = 150 },
    expect("\"reduzir movimento\" para o fundo", reducedStill),
    .{ .run = reduceOff },
    .{ .run = motionOff },
    .{ .wait = 50 },
    .{ .run = remember },
    .{ .wait = 120 },
    expect("desligou o movimento: parado de novo", noMotionWake),
};

pub const ops_resize_before = [_]Op{.{ .run = remember }};
pub const ops_resize_after = [_]Op{expect("redimensionar refaz só o que depende do tamanho", fewNewTextures)};

// --- Prévia da resposta a uma mensagem sem texto -----------------------------------
// No #zig da demonstração (fake_gateway.zig `demoReplyPreviews`) há respostas a um
// arquivo sozinho, a uma mensagem de voz, a uma figurinha, a uma imagem e a um
// cartão de bot. A linha da resposta mostra o ícone e o que a original tem (nos
// temas de terminal, a etiqueta entre colchetes), e o clique nela leva à original.

var reply_id: types.Id = 0;
var orig_id: types.Id = 0;

fn zigLoaded(app: *App) bool {
    const cs = app.store.channel(gw.reply_preview_channel) orelse return false;
    return app.st.activeChannel() == gw.reply_preview_channel and cs.history == .loaded;
}

/// Temas só de texto: a prévia vem sem ícone.
fn textOnly(app: *App) bool {
    return themeIs(app, "terminal") or themeIs(app, "subsolo");
}

/// Vai até a resposta cuja original (sem texto) é do tipo `kind`.
fn jumpToReply(app: *App, kind: reply_preview.Kind) void {
    reply_id = 0;
    const cs = app.store.channel(gw.reply_preview_channel) orelse return;
    for (cs.messages.items) |*m| {
        if (m.msg.reply_to == 0) continue;
        const f = app.store.find(cs, m.msg.reply_to) orelse continue;
        const lb = reply_preview.of(&f.msg);
        if (lb.kind != kind) continue;
        if (kind == .file and !std.mem.eql(u8, lb.text, gw.reply_preview_file)) continue;
        reply_id = m.msg.id;
        orig_id = f.msg.id;
        app.handle(.{ .jump_to = reply_id });
        return;
    }
}
fn toFile(app: *App) void {
    jumpToReply(app, .file);
}
fn toVoice(app: *App) void {
    jumpToReply(app, .voice);
}
fn toSticker(app: *App) void {
    jumpToReply(app, .sticker);
}
fn toImage(app: *App) void {
    jumpToReply(app, .image);
}
fn toEmbed(app: *App) void {
    jumpToReply(app, .embed);
}

/// A linha da resposta tem a marca do tipo e o ícone desenhado (no terminal,
/// sem ícone e com a etiqueta em texto).
fn kindShown(app: *App, kind: reply_preview.Kind) bool {
    if (reply_id == 0) return false;
    var kb: [64]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "reply-kind:{d}:{s}", .{ reply_id, @tagName(kind) }) catch return false;
    if (qa.find(k) == null) return false;
    var ib: [48]u8 = undefined;
    const icon = std.fmt.bufPrint(&ib, "reply-icon:{d}", .{reply_id}) catch return false;
    const has_icon = qa.find(icon) != null;
    // Embed mostra o título, sem ícone.
    if (kind == .embed or textOnly(app)) return !has_icon and R.hasInk(app, k);
    return has_icon and R.hasInk(app, icon);
}
fn fileShown(app: *App) bool {
    return kindShown(app, .file);
}
fn voiceShown(app: *App) bool {
    return kindShown(app, .voice);
}
fn stickerShown(app: *App) bool {
    return kindShown(app, .sticker);
}
fn imageShown(app: *App) bool {
    return kindShown(app, .image);
}
fn embedShown(app: *App) bool {
    return kindShown(app, .embed);
}

fn tReplyLine(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "reply-line:{d}", .{reply_id}) catch "";
}
fn jumpedToOriginal(app: *App) bool {
    var b: [40]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "msg:{d}", .{orig_id}) catch return false;
    return app.st.jump == 0 and messages.jumpedTo() == orig_id and qa.find(m) != null;
}
fn backToBottom(app: *App) void {
    app.st.scrollOf(gw.reply_preview_channel).stick_bottom = true;
}

pub const ops_reply = [_]Op{
    .{ .expect = .{ .name = "o #zig abre com as respostas da demonstração", .check = zigLoaded, .timeout_ms = 4000 } },
    .{ .run = toVoice },
    expect("resposta a uma mensagem de voz: microfone e \"Mensagem de voz\"", voiceShown),
    .{ .run = toSticker },
    expect("resposta a uma figurinha: ícone e o nome dela", stickerShown),
    .{ .run = toImage },
    expect("resposta a uma imagem: ícone e \"Clique para ver o anexo\"", imageShown),
    .{ .run = toEmbed },
    expect("resposta a um cartão de bot: o título dele", embedShown),
    .{ .run = toFile },
    expect("resposta a um arquivo sozinho: ícone e o nome do arquivo", fileShown),
    // O destaque do pulo apaga antes do print.
    .{ .wait = 1700 },
    .{ .shot = "resposta" },
    .{ .click = .{ .dyn = tReplyLine } },
    expect("o clique na prévia leva ao arquivo", jumpedToOriginal),
    .{ .run = backToBottom },
};

// --- Tema do usuário que estende outro (QA_SUITE=tema-herda) -----------------------------
// Dois arquivos na pasta de temas do usuário (a do ambiente isolado do QA): `qa-base` estende
// o classico e põe a cor numa variável; `qa-herdeiro` estende o `qa-base` e troca a variável.
// O app carrega o herdeiro com o layout do classico, a cor do herdeiro nas cores que a base
// calcula, e recarrega quando a base muda (o que o vigia da pasta faz ao salvar).

const base_v1 =
    \\// Base de usuário do QA: o classico com o destaque numa variável.
    \\theme "qa-base"
    \\extends "classico"
    \\vars { destaque "#e0218a" }
    \\colors { accent "$destaque"; mention "$destaque" }
    \\
;
const base_v2 =
    \\// A mesma base, agora com um vermelho próprio para o perigo.
    \\theme "qa-base"
    \\extends "classico"
    \\vars { destaque "#e0218a" }
    \\colors { accent "$destaque"; mention "$destaque"; danger "#ff2020" }
    \\
;
const herdeiro =
    \\// Herda do qa-base (que herda do classico) e troca só a variável.
    \\theme "qa-herdeiro" description="Herda do qa-base, que herda do classico."
    \\extends "qa-base"
    \\vars { destaque "#1fb26b" }
    \\colors { link "mix($destaque, white, 0.3)" }
    \\
;

var dir_buf: [600]u8 = undefined;

fn userThemes() ?[:0]const u8 {
    var hb: [512]u8 = undefined;
    const base = sys.configHome(&hb) orelse return null;
    return std.fmt.bufPrintSentinel(&dir_buf, "{s}/larpercord/themes", .{base}, 0) catch null;
}

fn writeTheme(name: []const u8, src: []const u8) void {
    const dir = userThemes() orelse return;
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kdl", .{ dir, name }, 0) catch return;
    _ = c.SDL_SaveFile(path.ptr, src.ptr, src.len);
}

fn removeTheme(name: []const u8) void {
    const dir = userThemes() orelse return;
    var pb: [700]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}.kdl", .{ dir, name }, 0) catch return;
    _ = c.SDL_RemovePath(path.ptr);
}

/// A pasta só é vigiada se existia ao abrir: aqui ela entra na lista à mão, como no
/// próximo início, e a lista é refeita.
fn setupUserThemes(app: *App) void {
    const dir = userThemes() orelse return;
    var hb: [512]u8 = undefined;
    const cfg = sys.configHome(&hb) orelse return;
    var pb: [600]u8 = undefined;
    _ = c.SDL_CreateDirectory((std.fmt.bufPrintSentinel(&pb, "{s}/larpercord", .{cfg}, 0) catch return).ptr);
    _ = c.SDL_CreateDirectory(dir.ptr);
    writeTheme("qa-base", base_v1);
    writeTheme("qa-herdeiro", herdeiro);
    const known = for (app.themes.dirs.items) |d| {
        if (std.mem.eql(u8, d, dir)) break true;
    } else false;
    if (!known) if (app.themes.gpa.dupeSentinel(u8, dir, 0)) |copy| {
        app.themes.dirs.append(app.themes.gpa, copy) catch app.themes.gpa.free(copy);
    } else |_| {};
    app.themes.scan() catch {};
}

fn pickHeir(app: *App) void {
    if (app.themes.indexOf("qa-herdeiro")) |i| app.handle(.{ .set_theme = i });
}

fn near(got: theme.Rgba, want: u32) bool {
    const w = theme.Rgba.hex(want);
    return @abs(got.r - w.r) < 0.01 and @abs(got.g - w.g) < 0.01 and @abs(got.b - w.b) < 0.01;
}

fn heirLoaded(app: *App) bool {
    if (!themeIs(app, "qa-herdeiro")) return false;
    const t = app.themes.theme_();
    // A variável do herdeiro vale nas cores que a base calcula; o resto é do classico.
    return near(t.c(.accent), 0x1fb26b) and near(t.c(.mention), 0x1fb26b) and t.has_user_panel and t.has_member_list and
        t.warnings.len == 0 and app.themes.last_warning == null and std.mem.eql(u8, t.name, "qa-herdeiro");
}

fn heirDrawn(_: *App) bool {
    // O layout do classico: servidores, canais, conversa e caixa de texto.
    return qa.find("composer") != null and qa.find("guild:0") != null;
}

fn changeBase(app: *App) void {
    writeTheme("qa-base", base_v2);
    // O que o vigia da pasta chama quando um .kdl muda.
    _ = app.themes.reload();
}

fn heirFollowsBase(app: *App) bool {
    if (!themeIs(app, "qa-herdeiro")) return false;
    const t = app.themes.theme_();
    return near(t.c(.danger), 0xff2020) and near(t.c(.accent), 0x1fb26b);
}

fn cleanUp(app: *App) void {
    removeTheme("qa-herdeiro");
    removeTheme("qa-base");
    app.themes.scan() catch {};
    if (app.themes.indexOf("classico")) |i| app.handle(.{ .set_theme = i });
}

fn backOnClassico(app: *App) bool {
    return themeIs(app, "classico") and app.themes.indexOf("qa-herdeiro") == null;
}

pub const ops_heranca = [_]Op{
    .{ .section = "tema do usuário que estende o classico" },
    .{ .run = setupUserThemes },
    .{ .run = pickHeir },
    .{ .wait = 300 },
    expect("qa-herdeiro (extends qa-base, que estende o classico) carrega com a variável dele nas cores da base", heirLoaded),
    expect("e desenha o layout do classico", heirDrawn),
    .{ .shot = "tema-herdeiro" },
    .{ .run = changeBase },
    .{ .wait = 200 },
    expect("a base mudou: o herdeiro recarrega com a cor nova dela e continua com a dele", heirFollowsBase),
    .{ .shot = "tema-herdeiro-base-mudou" },
    .{ .run = cleanUp },
    .{ .wait = 200 },
    expect("de volta ao classico, sem os arquivos do teste", backOnClassico),
};
