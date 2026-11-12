//! QA do mascote personalizado (Configurações → Mascote → Personalizar): a prévia e as
//! caras, cada grade de peças, sortear, os visuais prontos, voltar ao padrão e desfazer,
//! salvar como arquivo e usar o arquivo de novo, um arquivo com desenhos por expressão
//! (relido sozinho quando muda), um arquivo quebrado com arquivo:linha:coluna, o mascote
//! do canto com chapéu, acessório, fone e fita, a abertura com o visual, temas claro e
//! escuro, o tema terminal, janela estreita, russo e japonês. Sozinho:
//! QA_SUITE=mascote-visual.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const i18n = @import("ui/i18n.zig");
const terminal = @import("ui/mascote_terminal.zig");
const visual = @import("ui/mascote_visual.zig");
const arquivos = @import("ui/mascote_arquivos.zig");
const page = @import("ui/settings_mascote.zig");
const settings_ui = @import("ui/settings.zig");

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
fn shot(name: []const u8) Op {
    return .{ .shot = name };
}
fn wait(ms: u32) Op {
    return .{ .wait = ms };
}

fn scrollTo(comptime a: page.Anchor) fn (*App) void {
    return struct {
        fn f(_: *App) void {
            page.qa_scroll = a;
        }
    }.f;
}
/// Fotografa um pedaço da página: rola até ele e espera assentar.
fn snap(comptime a: page.Anchor, comptime name: []const u8) [3]Op {
    return .{ .{ .run = scrollTo(a) }, .{ .wait = 250 }, .{ .shot = name } };
}

fn look() *const visual.Look {
    return &terminal.look;
}

// --- Abrir e fechar ---------------------------------------------------------------

fn openPage(app: *App) void {
    app.st.settings.mascot = 0;
    app.st.settings.page = .mascote;
    app.handle(.open_settings);
}
fn closePage(app: *App) void {
    app.handle(.close_settings);
}
fn clearLook(app: *App) void {
    app.st.settings.mascot_look.set("");
    app.st.settings.mascot_file.set("");
}
fn clearFiles(app: *App) void {
    clearLook(app);
    arquivos.qaClear();
}
fn defaultLook(app: *App) bool {
    return app.st.settings.mascot_look.len == 0 and app.st.settings.mascot_file.len == 0 and look().isDefault();
}
fn previewShown(_: *App) bool {
    return qa.find("mascot-preview") != null and qa.find("mascot-tab:eyes") != null and qa.find("mascot-preset:hacker") != null;
}
fn faceIs(comptime f: visual.Face) fn (*App) bool {
    return struct {
        fn ok(_: *App) bool {
            return page.previewFace() == f;
        }
    }.ok;
}
fn tabIs(comptime t: u8) fn (*App) bool {
    return struct {
        fn ok(_: *App) bool {
            return page.currentTab() == t;
        }
    }.ok;
}

// --- Peças ---------------------------------------------------------------------------

fn eyesCat(_: *App) bool {
    return look().eyes == .cat;
}
fn mouthFang(_: *App) bool {
    return look().mouth == .fang;
}
fn hatCrown(_: *App) bool {
    return look().hat == .crown;
}
fn glassesOn(_: *App) bool {
    return look().has(.glasses);
}
fn shadesOn(_: *App) bool {
    return look().has(.shades) and !look().has(.glasses);
}
fn earsBunny(_: *App) bool {
    return look().ears == .bunny;
}
fn paletteMint(_: *App) bool {
    return look().paint == .custom and look().palette == comptime visual.paletteIndex("menta");
}
fn themePaint(_: *App) bool {
    return look().paint == .theme;
}
fn hexInk(_: *App) bool {
    return look().paint == .custom and look().palette == visual.no_palette and look().colors[2].col(1) == visual.Rgba.hex(0xFF2266).col(1);
}

var before: visual.Look = .{};
var depth_before: usize = 0;
fn noteLook(_: *App) void {
    before = look().*;
    depth_before = page.undoDepth();
}
fn changed(_: *App) bool {
    return !look().eql(&before) and page.undoDepth() == depth_before + 1;
}
fn backToBefore(_: *App) bool {
    return look().eql(&before) and page.undoDepth() == depth_before;
}
fn presetIs(comptime id: []const u8) fn (*App) bool {
    return struct {
        fn ok(app: *App) bool {
            const i = visual.presetOf(look()) orelse return false;
            return std.mem.eql(u8, visual.presets[i].id, id) and app.st.settings.mascot_file.len == 0;
        }
    }.ok;
}
fn isDefault(_: *App) bool {
    return look().isDefault();
}
fn compactSaved(app: *App) bool {
    // O que fica no settings.kdl, lido de volta, é o mesmo visual.
    const back = visual.parseCompact(app.st.settings.mascot_look.slice());
    return back.eql(look());
}

// --- Arquivos ---------------------------------------------------------------------------

fn savedAsFile(app: *App) bool {
    const f = app.st.settings.mascot_file.slice();
    if (!std.mem.eql(u8, f, "bruxo")) return false;
    const e = arquivos.find("bruxo") orelse return false;
    return e.problem == null and e.look.eql(&visual.presets[1].look) and std.mem.eql(u8, e.title.slice(), "Bruxo");
}
fn leftFile(app: *App) bool {
    return app.st.settings.mascot_file.len == 0 and look().hat == .tophat;
}
fn usingBruxo(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.mascot_file.slice(), "bruxo") and look().eql(&visual.presets[1].look);
}

const star_file =
    \\// Estrelinha: olhos e boca desenhados, com caras próprias.
    \\mascot "Estrelinha" author="QA" license="CC0-1.0"
    \\look hat="sprout" accessories="blush"
    \\colors palette="algodao-doce"
    \\eyes {
    \\    circle cx=40 cy=50 r=7 fill="white" stroke="ink" width=1.6
    \\    circle cx=41 cy=51 r=3.6
    \\    circle cx=84 cy=55 r=7 fill="white" stroke="ink" width=1.6
    \\    circle cx=85 cy=56 r=3.6
    \\    when "happy" "laugh" {
    \\        path d="M 32 53 Q 40 43 48 53" stroke="ink" width=4
    \\        path d="M 76 58 Q 84 48 92 58" stroke="ink" width=4
    \\    }
    \\    when "angry" {
    \\        polygon points="31 44 49 49 47 56 33 54" fill="ink"
    \\        polygon points="93 48 75 53 77 60 91 58" fill="ink"
    \\    }
    \\}
    \\mouth {
    \\    path d="M 55 69 Q 59.5 74 63.5 69.5 Q 67.5 74 72 69" stroke="ink" width=2.6
    \\    when "laugh" "startled" { ellipse cx=63.5 cy=72 rx=6 ry=6.5 fill="ink" }
    \\}
    \\layer "back" {
    \\    polygon points="8 70 -6 92 14 86" fill="accent"
    \\    polygon points="119 70 133 92 113 86" fill="accent"
    \\}
    \\layer "front" {
    \\    path d="M 98 22 L 101 28 L 108 29 L 103 33 L 104 40 L 98 36 L 92 40 L 93 33 L 88 29 L 95 28 Z" fill="#FFD84A" stroke="ink" width=1
    \\}
;

fn writeStar(_: *App) void {
    _ = arquivos.qaWrite("estrelinha", star_file);
}
/// O vigia da pasta acorda o app sozinho, sem ninguém pedir para reler.
fn starLoaded(_: *App) bool {
    const e = arquivos.find("estrelinha") orelse return false;
    const dw = e.drawing orelse return false;
    return e.problem == null and dw.hasVariant(.eyes, .happy) and dw.hasLayer(.front) and dw.hasLayer(.back) and arquivos.qaWatching();
}
fn usingStar(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.mascot_file.slice(), "estrelinha") and look().eyes == .custom and look().mouth == .custom and look().drawing != null;
}
fn writeBroken(_: *App) void {
    _ = arquivos.qaWrite("quebrado", "// Quebrado de propósito.\nmascot \"Quebrado\"\neyes {\n    circle cx=40 cy=50 fill=\"roxo\" r=5\n}\n");
}
fn brokenShown(_: *App) bool {
    const e = arquivos.find("quebrado") orelse return false;
    const pr = e.problem orelse return false;
    return pr.line == 4 and pr.col == 5 and pr.issue == .bad_color and qa.find("mascot-file:quebrado") != null and qa.find("mascot-file-use:quebrado") == null;
}
/// O arquivo em uso estraga: o visual de antes fica.
fn breakStar(_: *App) void {
    _ = arquivos.qaWrite("estrelinha", "mascot \"Estrelinha\"\neyes {\n  circle cx=40 cy=50 r=\n}\n");
}
fn starKeptOnError(_: *App) bool {
    const e = arquivos.find("estrelinha") orelse return false;
    return e.problem != null and look().eyes == .custom and look().drawing != null;
}
fn fixStar(_: *App) void {
    _ = arquivos.qaWrite("estrelinha", star_file);
}
fn starFixed(_: *App) bool {
    const e = arquivos.find("estrelinha") orelse return false;
    return e.problem == null and look().eyes == .custom;
}
/// Escolher outra peça com o arquivo em uso: solta o arquivo, mas os desenhos dele
/// continuam (o settings.kdl guarda de onde vêm).
fn keptDrawing(app: *App) bool {
    return app.st.settings.mascot_file.len == 0 and look().hat == .crown and look().eyes == .custom and look().drawing != null and
        std.mem.indexOf(u8, app.st.settings.mascot_look.slice(), "draw=estrelinha") != null;
}

// --- No app ----------------------------------------------------------------------------

fn petLook(app: *App) void {
    app.st.settings.mascot_look.set("eyes=big mouth=cat hat=viking acc=glasses,scarf pal=oceano");
    app.st.settings.mascot_file.set("");
    app.st.settings.mascot_life = 0;
    @import("ui/mascote_pet.zig").qaHome();
}
fn petReady(_: *App) bool {
    return qa.find("pet") != null and look().hat == .viking and look().has(.glasses);
}
fn joinCall(app: *App) void {
    app.actions.append(app.gpa, .{ .toggle_voice = 500014 }) catch {};
}
fn inCall(app: *App) bool {
    return app.st.voice != null;
}
fn muteMic(app: *App) void {
    app.st.muted = true;
}
fn leaveCall(app: *App) void {
    app.st.muted = false;
    app.actions.append(app.gpa, .{ .toggle_voice = 500014 }) catch {};
}
fn outOfCall(app: *App) bool {
    return app.st.voice == null;
}
fn loginWith(comptime preset: usize, comptime opening: u8, comptime t: f32) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            var buf: [256]u8 = undefined;
            app.st.settings.mascot_look.set(visual.writeCompact(&visual.presets[preset].look, &buf));
            app.st.settings.mascot_file.set("");
            app.st.settings.mascot_opening = opening;
            if (!app.login.visible()) app.login.begin(.form);
            app.login.t = t;
            app.login.err_at = -10;
        }
    }.f;
}
fn loginShown(app: *App) bool {
    return app.login.visible() and !look().isDefault();
}
fn loginHide(app: *App) void {
    app.st.settings.mascot_opening = 0;
    app.login.phase = .hidden;
}
fn openSaved(app: *App) void {
    app.handle(.toggle_saved);
}
fn savedSleeps(_: *App) bool {
    return qa.find("saved-empty") != null;
}

// --- Temas, tamanho e idiomas ---------------------------------------------------------

fn themeNamed(comptime name: []const u8) fn (*App) void {
    return struct {
        fn f(app: *App) void {
            for (app.themes.names.items, 0..) |nm, i| if (std.mem.eql(u8, nm, name)) {
                app.actions.append(app.gpa, .{ .set_theme = i }) catch {};
            };
        }
    }.f;
}
fn themeIs(comptime name: []const u8) fn (*App) bool {
    return struct {
        fn ok(app: *App) bool {
            return std.mem.eql(u8, app.themes.name(), name);
        }
    }.ok;
}
fn lightMode(app: *App) void {
    app.st.settings.color_mode = 1;
}
fn darkMode(app: *App) void {
    app.st.settings.color_mode = 0;
}
fn pirateLook(app: *App) void {
    var buf: [256]u8 = undefined;
    app.st.settings.mascot_look.set(visual.writeCompact(&visual.presets[3].look, &buf));
    app.st.settings.mascot_file.set("");
}
fn langRu(app: *App) void {
    i18n.set(.ru);
    settings_ui.overflows.store(0, .monotonic);
    i18n.cuts.store(0, .monotonic);
    openPage(app);
}
fn langJa(app: *App) void {
    i18n.set(.ja);
    settings_ui.overflows.store(0, .monotonic);
    i18n.cuts.store(0, .monotonic);
    openPage(app);
}
fn langPt(_: *App) void {
    i18n.set(.pt);
}
fn noOverflow(_: *App) bool {
    if (settings_ui.overflows.load(.monotonic) != 0) {
        std.log.warn("texto maior que a área: \"{s}\"", .{settings_ui.last_overflow[0..settings_ui.last_overflow_len]});
        return false;
    }
    return i18n.cuts.load(.monotonic) == 0;
}
fn colorsTabOpen(_: *App) bool {
    return page.currentTab() == 5 and qa.find("mascot-hex:ink") != null;
}

pub const ops = [_]Op{
    s("mascote personalizado: a página"),
    run(clearFiles),
    expect("quem nunca mexeu continua com o mascote de sempre", defaultLook),
    run(openPage),
    wait(300),
    expect("Personalizar aparece com a prévia, as categorias e os visuais prontos", previewShown),
} ++ snap(.stage, "mvis-01-previa") ++ snap(.presets, "mvis-02-prontos") ++ [_]Op{
    s("as caras da prévia"),
    click("mascot-face:1"),
    expect("Feliz", faceIs(.happy)),
    click("mascot-face:2"),
    expect("Rindo", faceIs(.laugh)),
    click("mascot-face:3"),
    expect("Susto", faceIs(.startled)),
    click("mascot-face:4"),
    expect("Bravo", faceIs(.angry)),
    click("mascot-face:5"),
    expect("Triste", faceIs(.sad)),
    click("mascot-face:6"),
    expect("Dormindo", faceIs(.sleep)),
    click("mascot-face:7"),
    expect("Tonto", faceIs(.dizzy)),
    click("mascot-face:0"),
    expect("de volta ao normal", faceIs(.prompt)),

    s("cada categoria"),
    click("mascot-opt:eyes:cat"),
    expect("olhos de gato", eyesCat),
    expect("o settings.kdl guarda o visual e ele volta igual", compactSaved),
} ++ snap(.tabs, "mvis-03-olhos") ++ [_]Op{
    click("mascot-tab:mouth"),
    expect("aba Boca", tabIs(1)),
    click("mascot-opt:mouth:fang"),
    expect("boca de dentinho", mouthFang),
} ++ snap(.tabs, "mvis-04-boca") ++ [_]Op{
    click("mascot-tab:hat"),
    expect("aba Chapéu", tabIs(2)),
    click("mascot-opt:hat:crown"),
    expect("coroa", hatCrown),
} ++ snap(.tabs, "mvis-05-chapeu") ++ [_]Op{
    click("mascot-tab:acc"),
    click("mascot-opt:acc:glasses"),
    expect("óculos", glassesOn),
    click("mascot-opt:acc:shades"),
    expect("óculos escuros tiram os outros óculos", shadesOn),
    click("mascot-opt:acc:blush"),
} ++ snap(.tabs, "mvis-06-acessorios") ++ [_]Op{
    click("mascot-tab:ears"),
    click("mascot-opt:ears:bunny"),
    expect("orelhas de coelho", earsBunny),
} ++ snap(.tabs, "mvis-07-orelhas") ++ [_]Op{
    click("mascot-tab:colors"),
    expect("aba Cores com as caixas de cor", colorsTabOpen),
    click("mascot-opt:colors:menta"),
    expect("paleta Menta", paletteMint),
} ++ snap(.tabs, "mvis-08-cores") ++ [_]Op{
    click("mascot-opt:colors:theme"),
    expect("seguir a cor do tema", themePaint),
    click("mascot-hex:ink"),
    .{ .key = .{ .key = c.ImGuiKey_A, .ctrl = true } },
    .{ .text = "#FF2266" },
    .{ .key = .{ .key = c.ImGuiKey_Enter } },
    expect("uma cor própria em hex", hexInk),
} ++ snap(.stage, "mvis-09-cor-propria") ++ [_]Op{
    s("sortear, prontos, padrão e desfazer"),
    run(noteLook),
    click("button:Sortear visual"),
    expect("sortear troca o visual (e dá para desfazer)", changed),
} ++ snap(.stage, "mvis-10-sorteado") ++ [_]Op{
    click("button:Desfazer"),
    expect("desfazer volta ao de antes", backToBefore),
    click("mascot-preset:pirata"),
    expect("visual pronto: Pirata", presetIs("pirata")),
} ++ snap(.stage, "mvis-11-pirata") ++ [_]Op{
    click("button:Padrão"),
    expect("Padrão volta ao mascote de sempre", isDefault),
    click("button:Desfazer"),
    expect("e desfazer traz o Pirata de volta", presetIs("pirata")),

    s("salvar como arquivo e usar de novo"),
    click("mascot-preset:bruxo"),
    expect("visual pronto: Bruxo", presetIs("bruxo")),
    click("button:Salvar como arquivo"),
    .{ .expect = .{ .name = "salvar cria mascots/bruxo.kdl e passa a usar o arquivo", .check = savedAsFile, .timeout_ms = 4000 } },
    click("mascot-tab:hat"),
    click("mascot-opt:hat:tophat"),
    expect("mudar uma peça solta o arquivo", leftFile),
    run(scrollTo(.files)),
    wait(250),
    click("mascot-file-use:bruxo"),
    expect("\"Usar\" no arquivo traz o visual dele de volta", usingBruxo),

    s("arquivo com desenhos próprios"),
    run(writeStar),
    .{ .expect = .{ .name = "o vigia da pasta lê o arquivo novo sozinho", .check = starLoaded, .timeout_ms = 5000 } },
    run(scrollTo(.files)),
    wait(250),
    click("mascot-file-use:estrelinha"),
    expect("usar o arquivo: olhos e boca do arquivo", usingStar),
    run(scrollTo(.stage)),
    wait(250),
    click("mascot-face:0"),
} ++ snap(.stage, "mvis-12-arquivo-normal") ++ [_]Op{
    click("mascot-face:1"),
} ++ snap(.stage, "mvis-13-arquivo-feliz") ++ [_]Op{
    click("mascot-face:4"),
} ++ snap(.stage, "mvis-14-arquivo-bravo") ++ [_]Op{
    click("mascot-face:6"),
} ++ snap(.stage, "mvis-15-arquivo-dormindo") ++ [_]Op{
    click("mascot-face:0"),
    run(breakStar),
    .{ .expect = .{ .name = "o arquivo em uso estraga: aviso com o erro e o visual de antes fica", .check = starKeptOnError, .timeout_ms = 5000 } },
    wait(200),
    shot("mvis-16-arquivo-erro-aviso"),
    run(fixStar),
    .{ .expect = .{ .name = "consertou: volta sozinho", .check = starFixed, .timeout_ms = 5000 } },
    run(scrollTo(.tabs)),
    wait(250),
    click("mascot-tab:hat"),
    click("mascot-opt:hat:crown"),
    expect("outra peça com o arquivo em uso: os desenhos dele continuam", keptDrawing),
    run(writeBroken),
    .{ .expect = .{ .name = "arquivo quebrado: o erro com arquivo:linha:coluna na lista", .check = brokenShown, .timeout_ms = 5000 } },
} ++ snap(.files, "mvis-17-arquivos") ++ [_]Op{
    s("temas, tamanho e idiomas"),
    run(pirateLook),
    run(themeNamed("terminal")),
    .{ .expect = .{ .name = "tema terminal", .check = themeIs("terminal"), .timeout_ms = 4000 } },
    wait(300),
} ++ snap(.stage, "mvis-18-terminal") ++ snap(.tabs, "mvis-19-terminal-grade") ++ [_]Op{
    run(lightMode),
    wait(300),
} ++ snap(.stage, "mvis-20-terminal-claro") ++ [_]Op{
    run(themeNamed("papel")),
    .{ .expect = .{ .name = "tema papel", .check = themeIs("papel"), .timeout_ms = 4000 } },
    wait(300),
} ++ snap(.stage, "mvis-21-papel-claro") ++ snap(.presets, "mvis-22-papel-prontos") ++ [_]Op{
    run(darkMode),
    run(themeNamed("vidro")),
    .{ .expect = .{ .name = "tema vidro", .check = themeIs("vidro"), .timeout_ms = 4000 } },
    wait(300),
} ++ snap(.stage, "mvis-23-vidro") ++ [_]Op{
    run(themeNamed("classico")),
    .{ .expect = .{ .name = "de volta ao clássico", .check = themeIs("classico"), .timeout_ms = 4000 } },
    .{ .resize = .{ 820, 700 } },
    wait(300),
} ++ snap(.stage, "mvis-24-estreita") ++ snap(.tabs, "mvis-25-estreita-grade") ++ [_]Op{
    run(langRu),
    wait(400),
    expect("russo, janela estreita: nada passa da área nem corta", noOverflow),
} ++ snap(.stage, "mvis-26-russo") ++ [_]Op{
    .{ .resize = .{ 1280, 800 } },
    run(langJa),
    wait(400),
    expect("japonês: nada passa da área nem corta", noOverflow),
} ++ snap(.stage, "mvis-27-japones") ++ snap(.files, "mvis-28-japones-arquivos") ++ [_]Op{
    run(langPt),
    run(closePage),

    s("o visual em todo lugar"),
    run(petLook),
    .{ .expect = .{ .name = "o mascote do canto com o visual", .check = petReady, .timeout_ms = 3000 } },
    run(joinCall),
    expect("em call", inCall),
    run(muteMic),
    wait(300),
    shot("mvis-29-canto-call-mudo"),
    run(leaveCall),
    expect("saiu da call", outOfCall),
    run(openSaved),
    expect("salvas vazias: o momento com o visual", savedSleeps),
    wait(600),
    shot("mvis-30-momento"),
    run(openSaved),
    run(loginWith(5, 0, 3.2)),
    expect("a abertura com o visual (Astronauta)", loginShown),
    shot("mvis-31-abertura"),
    run(loginWith(13, 3, 0.95)),
    shot("mvis-32-abertura-pixels"),
    run(loginWith(10, 4, 1.0)),
    shot("mvis-33-abertura-portal"),
    run(loginWith(0, 1, 1.9)),
    shot("mvis-34-abertura-codigo"),
    run(loginHide),
    run(clearLook),
    expect("limpo: o de sempre de novo", defaultLook),
};

// --- A folha de conferência (QA_SUITE=mascote-folha) ---------------------------------

const folha = @import("ui/mascote_folha.zig");

fn sheetFn(comptime k: folha.Sheet) fn (*App) void {
    return struct {
        fn f(_: *App) void {
            folha.sheet = k;
        }
    }.f;
}
fn sheetOp(comptime k: folha.Sheet) [3]Op {
    return sheetAs(k, "mfolha-" ++ @tagName(k));
}
fn sheetAs(comptime k: folha.Sheet, comptime name: []const u8) [3]Op {
    return .{ .{ .run = sheetFn(k) }, .{ .wait = 200 }, .{ .shot = name } };
}

/// Copia os exemplos de mascots/community/ (do repositório) para a pasta do QA.
fn copyCommunity(_: *App) void {
    arquivos.qaClear();
    var n: c_int = 0;
    const names = c.SDL_GlobDirectory("mascots/community", "*.kdl", 0, &n) orelse return;
    defer c.SDL_free(@ptrCast(names));
    for (0..@intCast(n)) |i| {
        const nm = std.mem.span(names[i] orelse continue);
        var pb: [256]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&pb, "mascots/community/{s}", .{nm}, 0) catch continue;
        var size: usize = 0;
        const data = c.SDL_LoadFile(path.ptr, &size) orelse continue;
        defer c.SDL_free(data);
        _ = arquivos.qaWrite(nm[0 .. nm.len - 4], @as([*]const u8, @ptrCast(data))[0..size]);
    }
    arquivos.reload();
}
/// Todo exemplo da comunidade abre sem erro.
fn communityOk(_: *App) bool {
    const list = arquivos.list();
    if (list.len < 3) return false;
    for (list) |*e| if (e.problem) |pr| {
        std.log.warn("{s}.kdl:{d}:{d}: {s}", .{ e.name.slice(), pr.line, pr.col, @tagName(pr.issue) });
        return false;
    };
    return true;
}

pub const ops_folha = [_]Op{
    s("folha de conferência do mascote"),
    run(clearLook),
    run(openPage),
    wait(300),
} ++ sheetOp(.eyes0) ++ sheetOp(.eyes1) ++ sheetOp(.eyes2) ++ sheetOp(.mouth0) ++ sheetOp(.mouth1) ++ sheetOp(.mouth2) ++
    sheetOp(.hats0) ++ sheetOp(.hats1) ++ sheetOp(.acc) ++ sheetOp(.ears) ++ sheetOp(.small) ++ sheetOp(.palettes) ++ sheetOp(.combos) ++ sheetOp(.detail) ++ [_]Op{
    run(sheetFn(.none)),
    run(copyCommunity),
    expect("os exemplos de mascots/community abrem sem erro", communityOk),
} ++ sheetOp(.community) ++ [_]Op{
    run(sheetFn(.none)),
    run(lightMode),
} ++ sheetAs(.palettes, "mfolha-palettes-claro") ++ sheetAs(.community, "mfolha-community-claro") ++ [_]Op{
    run(darkMode),
    run(sheetFn(.none)),
    run(clearFiles),
    run(closePage),
};
