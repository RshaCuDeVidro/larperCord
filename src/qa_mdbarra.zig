//! QA da balança de Markdown (QA_SUITE=md-barra): selecionar texto na caixa mostra
//! B e I em cima do trecho (para os dois lados do arrasto) e os botões colocam
//! ** / * nas duas pontas dele.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const qa = @import("ui/qa.zig");

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn click(k: []const u8) Op {
    return .{ .click = .{ .mark = k } };
}
fn clickAt(t: R.Target) Op {
    return .{ .click = t };
}
fn at(k: []const u8, fx: f32, fy: f32) R.Target {
    return .{ .at = .{ .key = k, .fx = fx, .fy = fy } };
}
fn expect(name: []const u8, f: *const fn (*App) bool) Op {
    return .{ .expect = .{ .name = name, .check = f } };
}
fn key(k: c_int) Op {
    return .{ .key = .{ .key = k } };
}
fn shift(k: c_int) Op {
    return .{ .key = .{ .key = k, .shift = true } };
}
fn ctrl(k: c_int) Op {
    return .{ .key = .{ .key = k, .ctrl = true } };
}
fn balanca(_: *App) bool {
    return qa.find("composer-bold") != null and qa.find("composer-italic") != null;
}
fn inputIs(app: *App, want: []const u8) bool {
    const len = std.mem.indexOfScalar(u8, &app.st.input, 0) orelse app.st.input.len;
    return std.mem.eql(u8, app.st.input[0..len], want);
}
fn boldRight(app: *App) bool {
    return inputIs(app, "**abc**defgh");
}
fn boldLeft(app: *App) bool {
    return inputIs(app, "ab**cde**fgh");
}
fn italicLeft(app: *App) bool {
    return inputIs(app, "ab*cde*fgh");
}

// A caixa vazia de novo: clica nela (foco), seleciona tudo e apaga.
const limpar = [_]Op{ clickAt(at("composer", 0.5, 0.5)), ctrl(c.ImGuiKey_A), key(c.ImGuiKey_Backspace) };

// O cursor anda cinco e volta três com Shift: seleção "cde", a ponta que se
// move (o caret, onde a balança aparece) fica à esquerda.
const selecao_esquerda = [_]Op{
    key(c.ImGuiKey_Home),
    key(c.ImGuiKey_RightArrow),
    key(c.ImGuiKey_RightArrow),
    key(c.ImGuiKey_RightArrow),
    key(c.ImGuiKey_RightArrow),
    key(c.ImGuiKey_RightArrow),
    shift(c.ImGuiKey_LeftArrow),
    shift(c.ImGuiKey_LeftArrow),
    shift(c.ImGuiKey_LeftArrow),
};

pub const ops = [_]Op{
    s("seleção na caixa mostra a balança e os botões embrulham em Markdown"),
    clickAt(at("composer", 0.5, 0.5)),
    .{ .text = "abcdefgh" },
    // Para a direita: Home, e três com Shift selecionam "abc".
    key(c.ImGuiKey_Home),
    shift(c.ImGuiKey_RightArrow),
    shift(c.ImGuiKey_RightArrow),
    shift(c.ImGuiKey_RightArrow),
    expect("seleção para a direita mostra a balança", balanca),
    .{ .shot = "md-barra-balca" },
    click("composer-bold"),
    expect("B coloca ** nas pontas", boldRight),
    .{ .shot = "md-barra-negrito" },
} ++
    limpar ++
    [_]Op{
        .{ .text = "abcdefgh" },
    } ++ selecao_esquerda ++
    [_]Op{
        expect("seleção para a esquerda mostra a balança", balanca),
        click("composer-bold"),
        expect("B vale para a esquerda também", boldLeft),
    } ++
    limpar ++
    [_]Op{
        .{ .text = "abcdefgh ijklmnop" },
        // Arrasto de mouse para a esquerda: a âncora fica à direita da ponta que se move.
        .{ .drag = .{ .from = at("composer", 0.3, 0.5), .to = at("composer", 0.02, 0.5) } },
        expect("arrastar para a esquerda mostra a balança", balanca),
    } ++
    limpar ++
    [_]Op{
        .{ .text = "abcdefgh" },
    } ++ selecao_esquerda ++
    [_]Op{
        click("composer-italic"),
        expect("I coloca * nas pontas", italicLeft),
    } ++
    // O negrito e o itálico do CJK (a fonte reserva não tem nenhum dos dois).
    limpar ++
    [_]Op{
        .{ .text = "あ **本** いと *日本語*" },
        .{ .shot = "md-barra-japones" },
    };
