//! Quando o aviso de versão nova aparece (ui/aviso_atualizacao.zig) e quando a
//! atualização se instala sozinha. Antes, o aviso era um toast de 1,8 s: com a janela
//! na bandeja ou sem foco, ninguém via, e a versão nova só aparecia para quem abrisse
//! Configurações → Atualizações. Lógica pura.
const std = @import("std");

pub const Fase = enum { nada, disponivel, baixando, pronta, falhou };

/// A faixa no topo: com versão nova, baixando ou pronta, até a pessoa fechar (vale
/// para aquela versão, até o app abrir de novo). Erro só depois de um "Atualizar
/// agora" (`tentou`): sem rede, ao abrir, ninguém precisa saber. Na página de
/// Atualizações a faixa some (diria o mesmo duas vezes).
pub fn faixa(fase: Fase, versao: []const u8, fechada_para: []const u8, tentou: bool, na_pagina: bool) bool {
    if (na_pagina) return false;
    const vale = switch (fase) {
        .nada => false,
        .disponivel, .baixando, .pronta => true,
        .falhou => tentou,
    };
    const fechada = fechada_para.len > 0 and std.mem.eql(u8, versao, fechada_para);
    return vale and !fechada;
}

/// O pontinho no botão das configurações: enquanto houver o que atualizar, mesmo com a
/// faixa fechada.
pub fn ponto(fase: Fase) bool {
    return fase == .disponivel or fase == .baixando or fase == .pronta;
}

/// "Atualizar sozinho": baixa e instala ao achar a versão nova (uma vez por versão), a
/// não ser que um gerenciador de pacotes cuide do app.
pub fn instalarSozinho(ligado: bool, gerenciado: bool, fase: Fase, versao: []const u8, ja_tentou: []const u8) bool {
    return ligado and !gerenciado and fase == .disponivel and versao.len > 0 and !std.mem.eql(u8, versao, ja_tentou);
}

const t = std.testing;

test "a faixa fica até fechar, e fechar vale para aquela versão" {
    try t.expect(faixa(.disponivel, "0.6.7", "", false, false));
    try t.expect(faixa(.baixando, "0.6.7", "", true, false));
    try t.expect(faixa(.pronta, "0.6.7", "", true, false));
    try t.expect(!faixa(.disponivel, "0.6.7", "0.6.7", false, false));
    // Saiu outra versão: aparece de novo.
    try t.expect(faixa(.disponivel, "0.6.8", "0.6.7", false, false));
    try t.expect(!faixa(.nada, "", "", false, false));
    // Na página de Atualizações, não.
    try t.expect(!faixa(.disponivel, "0.6.7", "", false, true));
}

test "erro só depois de pedir para atualizar" {
    try t.expect(!faixa(.falhou, "", "", false, false));
    try t.expect(faixa(.falhou, "", "", true, false));
}

test "o pontinho e o atualizar sozinho" {
    try t.expect(ponto(.disponivel) and ponto(.pronta) and ponto(.baixando));
    try t.expect(!ponto(.nada) and !ponto(.falhou));
    try t.expect(instalarSozinho(true, false, .disponivel, "0.6.7", ""));
    try t.expect(!instalarSozinho(false, false, .disponivel, "0.6.7", ""));
    try t.expect(!instalarSozinho(true, true, .disponivel, "0.6.7", ""));
    try t.expect(!instalarSozinho(true, false, .disponivel, "0.6.7", "0.6.7"));
    try t.expect(!instalarSozinho(true, false, .pronta, "0.6.7", ""));
}
