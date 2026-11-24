//! QA da página Configurações → Idioma, em japonês e com a interface em 125% (tools/qa.sh):
//! a lista sai dos arquivos (os embutidos e a pasta de traduções), cada idioma com quanto
//! ele traduz; um idioma que o app não conhece (o xx de src/ui/i18n_xx.kdl, gravado numa
//! pasta de traduções do QA dentro de qa-out/) aparece e funciona sem nenhuma linha de
//! código sobre ele; salvar o arquivo muda o texto na hora (o vigia de verdade); um erro
//! no arquivo aparece na página e o texto de antes fica; escolher cada linha aplica.
//!
//! `QA_SUITE=idioma` com `--lang ja`; o idioma passa a seguir as configurações, como no
//! app de verdade (o resto do QA fica em português).
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");
const i18n = @import("ui/i18n.zig");
const i18n_pasta = @import("ui/i18n_pasta.zig");
const settings_ui = @import("ui/settings.zig");
const paineis = @import("qa_paineis.zig");
const att = @import("ui/attachments.zig");

const xx_file = @embedFile("ui/i18n_xx.kdl");
const pasta = "qa-out/idioma/i18n";

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = 4000 } };
}
fn run(f: *const fn (*App) void) Op {
    return .{ .run = f };
}

// --- Preparar -----------------------------------------------------------------------

fn preparar(app: *App) void {
    // Daqui em diante o idioma segue as configurações (começa no japonês do --lang).
    app.opts.lang = null;
    app.qa_lang_settings = true;
    app.st.settings.language_code.set("ja");
    app.st.settings.language = 3;
    app.st.settings.ui_scale = 1.25;
    _ = i18n_pasta.qaUseDir(pasta);
    _ = i18n_pasta.qaWrite("xx.kdl", xx_file);
}
fn emJa125(app: *App) bool {
    return i18n.is("ja") and app.ui_size == 1.25;
}
/// O vigia avisou e a pasta foi lida: o xx está na lista.
fn xxNaLista(_: *App) bool {
    return i18n.match("xx") != null;
}
fn abrirIdioma(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .idioma;
    settings_ui.overflows.store(0, .monotonic);
    i18n.cuts.store(0, .monotonic);
}

// --- A lista -------------------------------------------------------------------------

/// Uma linha por idioma (o sistema, os do código, os embutidos e o da pasta), sem ninguém
/// no código saber quais são.
fn linhas(_: *App) bool {
    for ([_][]const u8{ "lang:system", "lang:pt", "lang:en", "lang:ja", "lang:ru", "lang:xx" }) |k| {
        if (qa.find(k) == null) {
            std.log.warn("sem a linha {s}", .{k});
            return false;
        }
    }
    // Uma linha por idioma, nem mais.
    var n: usize = 0;
    for (i18n.languages()) |l| {
        var b: [32]u8 = undefined;
        if (qa.find(std.fmt.bufPrint(&b, "lang:{s}", .{l.code}) catch continue) != null) n += 1;
    }
    return n == i18n.languages().len;
}
/// A porcentagem de cada arquivo: o japonês quase tudo, o xx um pouco.
fn porcentagens(_: *App) bool {
    const ja = i18n.coverage(i18n.match("ja").?) orelse return false;
    const xx = i18n.coverage(i18n.match("xx").?) orelse return false;
    if (ja < 900 or xx == 0 or xx > 100) {
        std.log.warn("porcentagens: ja {d}‰, xx {d}‰", .{ ja, xx });
        return false;
    }
    return i18n.coverage(0) == null and i18n.coverage(1) == null;
}
fn semCortes(app: *App) bool {
    if (!paineis.noOverlap(app)) {
        std.log.warn("algo se sobrepõe na página Idioma", .{});
        return false;
    }
    if (settings_ui.overflows.load(.monotonic) != 0) {
        std.log.warn("texto maior que a área: \"{s}\"", .{settings_ui.last_overflow[0..settings_ui.last_overflow_len]});
        return false;
    }
    return i18n.cuts.load(.monotonic) == 0;
}
/// A linha marcada é a do idioma das configurações.
fn marcadaJa(app: *App) bool {
    return std.mem.eql(u8, app.st.settings.language_code.slice(), "ja") and i18n.is("ja");
}

// --- O xx, só um arquivo ---------------------------------------------------------------

fn emXx(app: *App) bool {
    return i18n.is("xx") and std.mem.eql(u8, app.st.settings.language_code.slice(), "xx") and
        app.st.settings.language == 0 and std.mem.eql(u8, i18n.tr("Idioma", "Language"), "Xxlang");
}
/// O que o arquivo não traz aparece em inglês, nunca em português; o plural segue as
/// regras que o arquivo pede (plurals "ru"), e a fonte de reserva preferida é a dele.
fn xxResto(_: *App) bool {
    var b: [64]u8 = undefined;
    if (!std.mem.eql(u8, i18n.tr("Entrar", "Sign in"), "Sign in")) return false;
    if (!std.mem.eql(u8, i18n.plural(&b, 3, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{3}), "3 xvotes-few")) return false;
    if (!std.mem.eql(u8, i18n.plural(&b, 21, "{d} voto", "{d} votos", "{d} vote", "{d} votes", .{21}), "21 xvote")) return false;
    return std.mem.eql(u8, i18n.fontScript(), "ja") and i18n.rtl();
}

var stamp_antes: u32 = 0;

fn salvarXx(_: *App) void {
    stamp_antes = i18n.stamp();
    const novo = std.mem.replaceOwned(u8, std.heap.c_allocator, xx_file, "\"Xxlang\"", "\"Xxlang salvo\"") catch return;
    defer std.heap.c_allocator.free(novo);
    _ = i18n_pasta.qaWrite("xx.kdl", novo);
}
/// O vigia avisou, a tabela foi refeita e o texto novo está na tela.
fn recarregado(_: *App) bool {
    return i18n.stamp() != stamp_antes and std.mem.eql(u8, i18n.tr("Idioma", "Language"), "Xxlang salvo");
}
fn quebrarXx(_: *App) void {
    const novo = std.mem.concat(std.heap.c_allocator, u8, &.{ xx_file, "\"Xxlang\" \"a\" \"b\"\n" }) catch return;
    defer std.heap.c_allocator.free(novo);
    _ = i18n_pasta.qaWrite("xx.kdl", novo);
}
/// O erro aparece na página (arquivo e linha) e o texto de antes continua.
fn erroNaPagina(_: *App) bool {
    const i = i18n.match("xx") orelse return false;
    const pr = i18n.languages()[i].problem orelse return false;
    return std.mem.startsWith(u8, pr, "xx.kdl:") and qa.find("lang-problem:xx") != null and
        std.mem.eql(u8, i18n.tr("Idioma", "Language"), "Xxlang salvo");
}
fn consertarXx(_: *App) void {
    _ = i18n_pasta.qaWrite("xx.kdl", xx_file);
}
fn consertado(_: *App) bool {
    const i = i18n.match("xx") orelse return false;
    return i18n.languages()[i].problem == null and qa.find("lang-problem:xx") == null and
        std.mem.eql(u8, i18n.tr("Idioma", "Language"), "Xxlang");
}

// --- As outras linhas ----------------------------------------------------------------

fn emRu(app: *App) bool {
    return i18n.is("ru") and app.st.settings.language == 4 and std.mem.eql(u8, i18n.tr("Idioma", "Language"), "Язык");
}
fn seguindoSistema(app: *App) bool {
    return app.st.settings.language_code.len == 0 and app.st.settings.language == 0 and i18n.is(i18n.system());
}
fn tEditor(_: *App, b: []u8) []const u8 {
    return std.fmt.bufPrint(b, "button:{s}", .{i18n.tr("Editor de traduções", "Translation editor")}) catch "";
}
fn editorAberto(_: *App) bool {
    const url = att.last_opened[0..att.last_opened_len];
    return std.mem.endsWith(u8, url, "/larperCord/translate.html");
}

fn fim(app: *App) void {
    app.st.settings.open = false;
    app.st.settings.ui_scale = 1;
}

pub const ops = [_]Op{
    s("idioma: a lista sai dos arquivos"),
    run(preparar),
    expect("em japonês, com a interface em 125%", emJa125),
    expect("um arquivo na pasta de traduções vira um idioma sozinho", xxNaLista),
    run(abrirIdioma),
    .{ .wait = 300 },
    expect("uma linha por idioma: sistema, pt, en, os embutidos e o da pasta", linhas),
    expect("cada arquivo com quanto ele traduz", porcentagens),
    expect("a linha marcada é a do idioma salvo", marcadaJa),
    expect("nada cortado, fora da área nem por cima de outra coisa (japonês, 125%)", semCortes),
    .{ .shot = "idioma-lista" },
    s("idioma: um idioma novo, sem código"),
    click("lang:xx"),
    .{ .wait = 300 },
    expect("escolher o xx aplica na hora e salva o código", emXx),
    expect("o que falta é inglês, o plural e a fonte são os do arquivo", xxResto),
    .{ .shot = "idioma-xx" },
    s("idioma: o arquivo salvo muda o texto na hora"),
    run(salvarXx),
    expect("salvar o arquivo atualiza o texto (o vigia de verdade)", recarregado),
    run(quebrarXx),
    expect("um erro no arquivo aparece na página, e o texto de antes fica", erroNaPagina),
    .{ .shot = "idioma-erro" },
    run(consertarXx),
    expect("consertado, o erro some e o arquivo vale de novo", consertado),
    s("idioma: as outras linhas"),
    click("lang:ru"),
    .{ .wait = 300 },
    expect("o russo vem do arquivo embutido (e vale para uma versão antiga: 4)", emRu),
    click("lang:system"),
    .{ .wait = 300 },
    expect("seguir o sistema não salva código nenhum", seguindoSistema),
    click("lang:ja"),
    .{ .wait = 300 },
    expect("de volta ao japonês", marcadaJa),
    .{ .click = .{ .dyn = tEditor } },
    .{ .wait = 150 },
    expect("o botão abre o editor de traduções do site", editorAberto),
    run(fim),
    .{ .wait = 200 },
};
