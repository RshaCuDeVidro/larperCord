//! Os atalhos de teclado do app, numa lista só. Configurações → Atalhos de
//! teclado desenha a partir dela, e tools/gen_site.py lê este arquivo para
//! gerar a página de atalhos do site: as duas nunca ficam diferentes.
//!
//! Quem trata cada tecla continua no lugar dela (ui/root.zig, ui/vim.zig, a
//! caixa de texto em ui/comp_messages.zig, a lista de sugestões em
//! ui/autocomplete.zig). Mudou uma tecla lá, mude a linha aqui.
//!
//! O gerador do site lê com expressão regular: uma entrada por linha, no
//! formato `.{ .campo = "texto", ... },`, e os grupos na ordem de `grupos`.
//! As teclas levam `+` entre as que vão juntas e ` / ` entre alternativas.
//!
//! Os que têm `.acao` dá para trocar em Configurações → Atalhos de teclado (#18):
//! as `teclas` daqui são o padrão, e a troca fica no settings.kdl como
//! `keybind "paleta" "Ctrl+J"` (`Personalizados`). Quem trata uma `acao` pergunta a
//! ui/teclas.zig, nunca a tecla direto.

const std = @import("std");
const comb = @import("../core/combinacao.zig");
const Combinacao = comb.Combinacao;

pub const Grupo = enum { geral, janela, abas, voz, caixa, vim };

/// Os atalhos que dá para trocar.
pub const Acao = enum { paleta, paleta_acoes, buscar, configuracoes, caixa_entrada, salvas, proximo_tema, tema_anterior, tela_cheia, proxima_aba, aba_anterior, fechar_aba, mutar, ensurdecer };
const n_acoes = @typeInfo(Acao).@"enum".field_names.len;

pub const Atalho = struct {
    grupo: Grupo,
    pt: []const u8,
    en: []const u8,
    teclas: []const u8,
    /// As teclas em português, quando o nome muda ("Ctrl+Clique").
    teclas_pt: ?[]const u8 = null,
    /// Dá para trocar (Configurações → Atalhos de teclado).
    acao: ?Acao = null,
};

pub const NomeGrupo = struct { id: Grupo, pt: []const u8, en: []const u8 };

pub const grupos = [_]NomeGrupo{
    .{ .id = .geral, .pt = "Geral", .en = "General" },
    .{ .id = .janela, .pt = "Janela e tema", .en = "Window and theme" },
    .{ .id = .abas, .pt = "Abas", .en = "Tabs" },
    .{ .id = .voz, .pt = "Voz", .en = "Voice" },
    .{ .id = .caixa, .pt = "Caixa de texto", .en = "Message box" },
    .{ .id = .vim, .pt = "Navegação vim", .en = "Vim navigation" },
};

pub const lista = [_]Atalho{
    .{ .grupo = .geral, .pt = "Paleta de comandos", .en = "Command palette", .teclas = "Ctrl+K", .acao = .paleta },
    .{ .grupo = .geral, .pt = "Paleta com as ações primeiro", .en = "Palette, actions first", .teclas = "Ctrl+Shift+P", .acao = .paleta_acoes },
    .{ .grupo = .geral, .pt = "Buscar mensagens", .en = "Search messages", .teclas = "Ctrl+F", .acao = .buscar },
    .{ .grupo = .geral, .pt = "Configurações", .en = "Settings", .teclas = "Ctrl+,", .acao = .configuracoes },
    .{ .grupo = .geral, .pt = "Caixa de entrada", .en = "Inbox", .teclas = "Ctrl+I", .acao = .caixa_entrada },
    .{ .grupo = .geral, .pt = "Mensagens salvas", .en = "Saved messages", .teclas = "Ctrl+Shift+S", .acao = .salvas },
    .{ .grupo = .geral, .pt = "Copiar o texto selecionado nas mensagens", .en = "Copy the text selected in messages", .teclas = "Ctrl+C" },
    .{ .grupo = .janela, .pt = "Próximo tema", .en = "Next theme", .teclas = "F2 / Ctrl+T", .acao = .proximo_tema },
    .{ .grupo = .janela, .pt = "Tema anterior", .en = "Previous theme", .teclas = "Shift+F2 / Ctrl+Shift+T", .acao = .tema_anterior },
    .{ .grupo = .janela, .pt = "Aumentar ou diminuir a interface", .en = "Make the interface bigger or smaller", .teclas = "Ctrl + / Ctrl -" },
    .{ .grupo = .janela, .pt = "Interface no tamanho normal", .en = "Interface at normal size", .teclas = "Ctrl 0" },
    .{ .grupo = .janela, .pt = "Tela cheia", .en = "Fullscreen", .teclas = "F11 / Alt+Enter", .acao = .tela_cheia },
    .{ .grupo = .abas, .pt = "Próxima aba", .en = "Next tab", .teclas = "Ctrl+Tab", .acao = .proxima_aba },
    .{ .grupo = .abas, .pt = "Aba anterior", .en = "Previous tab", .teclas = "Ctrl+Shift+Tab", .acao = .aba_anterior },
    .{ .grupo = .abas, .pt = "Ir para a aba N", .en = "Go to tab N", .teclas = "Alt+1…9" },
    .{ .grupo = .abas, .pt = "Fechar aba", .en = "Close tab", .teclas = "Ctrl+W", .acao = .fechar_aba },
    .{ .grupo = .abas, .pt = "Abrir canal em nova aba", .en = "Open channel in a new tab", .teclas = "Ctrl+Click", .teclas_pt = "Ctrl+Clique" },
    .{ .grupo = .abas, .pt = "Fechar aba com o mouse", .en = "Close tab with the mouse", .teclas = "Middle click", .teclas_pt = "Botão do meio" },
    .{ .grupo = .voz, .pt = "Mutar ou desmutar o microfone", .en = "Mute or unmute", .teclas = "Ctrl+Shift+M", .acao = .mutar },
    .{ .grupo = .voz, .pt = "Ensurdecer ou voltar a ouvir", .en = "Deafen or undeafen", .teclas = "Ctrl+Shift+D", .acao = .ensurdecer },
    .{ .grupo = .caixa, .pt = "Nova linha", .en = "New line", .teclas = "Shift+Enter / Ctrl+Enter" },
    .{ .grupo = .caixa, .pt = "Editar a última mensagem (caixa vazia)", .en = "Edit your last message (empty box)", .teclas = "↑" },
    .{ .grupo = .caixa, .pt = "Cancelar resposta ou edição", .en = "Cancel a reply or edit", .teclas = "Esc" },
    .{ .grupo = .caixa, .pt = "Escolher na lista de @, #, :ab ou /", .en = "Pick from the @, #, :ab or / list", .teclas = "Tab / Enter" },
    .{ .grupo = .caixa, .pt = "Colar uma imagem copiada", .en = "Paste a copied image", .teclas = "Ctrl+V" },
    .{ .grupo = .vim, .pt = "Rolar para baixo / para cima", .en = "Scroll down / up", .teclas = "j / k" },
    .{ .grupo = .vim, .pt = "Topo / fim da conversa", .en = "Top / bottom of the conversation", .teclas = "gg / G" },
    .{ .grupo = .vim, .pt = "Meia página para baixo / para cima", .en = "Half page down / up", .teclas = "Ctrl+d / Ctrl+u" },
    .{ .grupo = .vim, .pt = "Próximo / anterior canal", .en = "Next / previous channel", .teclas = "J / K" },
    .{ .grupo = .vim, .pt = "Voltar para a caixa de texto", .en = "Back to the text box", .teclas = "i / Enter" },
    .{ .grupo = .vim, .pt = "Sair da caixa de texto", .en = "Leave the text box", .teclas = "Esc" },
    .{ .grupo = .vim, .pt = "Buscar (paleta)", .en = "Search (palette)", .teclas = "/" },
};

pub fn nome(g: Grupo) NomeGrupo {
    for (grupos) |n| if (n.id == g) return n;
    unreachable;
}

/// A linha da lista de cada ação.
pub fn deAcao(acao: Acao) *const Atalho {
    for (&lista) |*a| if (a.acao == acao) return a;
    unreachable;
}

/// O que não pode virar atalho de uma ação: o que já é de outra coisa fixa (copiar,
/// colar, nova linha, a navegação vim), as teclas de texto e o tamanho da interface.
pub fn reservado(cb: Combinacao) bool {
    for (lista) |a| if (a.acao == null) {
        var buf: [4]Combinacao = undefined;
        for (comb.parseList(a.teclas, &buf)) |x| if (x.eql(cb)) return true;
    };
    const fixos = [_][]const u8{ "Esc", "Alt+F4" };
    for (fixos) |t| if (Combinacao.parse(t).?.eql(cb)) return true;
    if (cb.ctrl) switch (cb.key) {
        // Selecionar tudo, copiar, recortar, colar, desfazer, refazer (Ctrl+Y e
        // Ctrl+Shift+Z) e o tamanho da interface: quem trata essas olha só o Ctrl, então
        // com Shift ou Alt junto elas disparariam também.
        .a, .c, .v, .x, .y, .z, .equal, .minus, .@"0" => return true,
        // Andar e apagar por palavra na caixa de texto, com ou sem Shift (selecionando).
        .left, .right, .up, .down, .home, .end, .backspace, .delete, .insert => if (!cb.alt) return true,
        else => {},
    };
    // Alt+1…9: ir para a aba N.
    if (cb.alt and !cb.ctrl and !cb.shift and @intFromEnum(cb.key) >= @intFromEnum(comb.Key.@"1") and @intFromEnum(cb.key) <= @intFromEnum(comb.Key.@"9")) return true;
    return false;
}

/// Ctrl+Alt com letra, número ou sinal: em muitos teclados (ABNT2, alemão…) é o
/// AltGr, que no Windows chega como Ctrl+Alt. Digitar "/" ou "?" dispararia o atalho.
pub fn altGr(cb: Combinacao) bool {
    return cb.ctrl and cb.alt and cb.key.printable();
}

/// As trocas feitas em Configurações → Atalhos de teclado (null = o padrão da lista).
pub const Personalizados = struct {
    custom: [n_acoes]?Combinacao = @splat(null),

    /// As combinações que valem agora para `acao` (a trocada, ou as do padrão).
    pub fn de(p: *const Personalizados, acao: Acao, out: []Combinacao) []Combinacao {
        if (p.custom[@intFromEnum(acao)]) |cb| {
            out[0] = cb;
            return out[0..1];
        }
        return comb.parseList(deAcao(acao).teclas, out);
    }

    /// De que ação é `cb` agora (fora `menos`).
    pub fn dono(p: *const Personalizados, cb: Combinacao, menos: ?Acao) ?Acao {
        inline for (@typeInfo(Acao).@"enum".field_names) |name| {
            const a = @field(Acao, name);
            if (a != menos) {
                var buf: [4]Combinacao = undefined;
                for (p.de(a, &buf)) |x| if (x.eql(cb)) return a;
            }
        }
        return null;
    }

    pub const Porque = enum { ok, sem_modificador, reservado, altgr, em_uso };

    /// O que vale para qualquer ação, sem olhar as outras.
    fn sozinha(cb: Combinacao) Porque {
        if (!cb.usable()) return .sem_modificador;
        if (reservado(cb)) return .reservado;
        if (altGr(cb)) return .altgr;
        return .ok;
    }

    /// Dá para pôr `cb` em `acao`? (Com `.em_uso`, `dono` diz de quem é.)
    pub fn pode(p: *const Personalizados, acao: Acao, cb: Combinacao) Porque {
        const r = sozinha(cb);
        if (r != .ok) return r;
        if (p.dono(cb, acao) != null) return .em_uso;
        return .ok;
    }

    /// Voltar `acao` ao padrão bateria em quem? (Outra ação pode ter pegado uma tecla
    /// do padrão dela enquanto ela estava trocada.) null: dá para voltar.
    pub fn donoDoPadrao(p: *const Personalizados, acao: Acao) ?Acao {
        var buf: [4]Combinacao = undefined;
        for (comb.parseList(deAcao(acao).teclas, &buf)) |cb| if (p.dono(cb, acao)) |o| return o;
        return null;
    }

    pub fn set(p: *Personalizados, acao: Acao, cb: ?Combinacao) void {
        // Igual ao padrão (uma alternativa só, a mesma): volta a ser o padrão.
        if (cb) |x| {
            var buf: [4]Combinacao = undefined;
            const def = comb.parseList(deAcao(acao).teclas, &buf);
            if (def.len == 1 and def[0].eql(x)) {
                p.custom[@intFromEnum(acao)] = null;
                return;
            }
        }
        p.custom[@intFromEnum(acao)] = cb;
    }

    pub fn trocado(p: *const Personalizados, acao: Acao) bool {
        return p.custom[@intFromEnum(acao)] != null;
    }

    /// Escreve as linhas do settings.kdl. A combinação vai entre aspas com `\` e `"`
    /// escapados: "Ctrl+\" sem escape abriria uma string que engole o resto do
    /// arquivo, e o app abriria com tudo no padrão.
    pub fn write(p: *const Personalizados, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        for (p.custom, 0..) |cb, i| if (cb) |x| {
            var buf: [32]u8 = undefined;
            try out.print(gpa, "keybind \"{s}\" \"", .{@tagName(@as(Acao, @enumFromInt(i)))});
            for (x.format(&buf)) |ch| {
                if (ch == '"' or ch == '\\') try out.append(gpa, '\\');
                try out.append(gpa, ch);
            }
            try out.appendSlice(gpa, "\"\n");
        };
    }

    /// Lê `keybind "paleta" "Ctrl+J"`. false: o nó não é nosso. Nome ou combinação
    /// que não valem (outra versão, arquivo editado à mão) ficam de fora. A briga com
    /// outra ação só se confere no fim, em `settle`: as outras linhas ainda não foram
    /// lidas, e trocar duas de lugar (a paleta no Ctrl+F e a busca no Ctrl+K) pareceria
    /// briga linha a linha.
    pub fn applyNode(p: *Personalizados, n: anytype) bool {
        if (!std.mem.eql(u8, n.name, "keybind")) return false;
        const name = (n.arg(0) orelse return true).asString() orelse return true;
        const text = (n.arg(1) orelse return true).asString() orelse return true;
        const acao = std.meta.stringToEnum(Acao, name) orelse return true;
        const cb = Combinacao.parse(text) orelse return true;
        if (sozinha(cb) != .ok) return true;
        p.set(acao, cb);
        return true;
    }

    /// Depois de ler todas as linhas: duas ações na mesma combinação (arquivo editado à
    /// mão, versão antiga) não valem. A troca que bate em outra ação volta ao padrão,
    /// até não sobrar briga; os padrões nunca brigam entre si (teste abaixo), então
    /// termina. Entre duas trocas na mesma tecla fica a de baixo na lista.
    pub fn settle(p: *Personalizados) void {
        var changed = true;
        while (changed) {
            changed = false;
            for (&p.custom, 0..) |*slot, i| if (slot.*) |cb| {
                if (p.dono(cb, @enumFromInt(i)) != null) {
                    slot.* = null;
                    changed = true;
                }
            };
        }
    }
};

test "atalhos: cada grupo aparece uma vez, na ordem, e toda linha tem texto" {
    var i: usize = 0;
    for (grupos) |g| {
        // Os de um grupo ficam juntos: a página e o site põem um título por grupo.
        while (i < lista.len and lista[i].grupo == g.id) : (i += 1) {
            const a = lista[i];
            try std.testing.expect(a.pt.len > 0 and a.en.len > 0 and a.teclas.len > 0);
            if (a.teclas_pt) |k| try std.testing.expect(k.len > 0);
        }
    }
    try std.testing.expectEqual(lista.len, i);
    try std.testing.expectEqualStrings("Voice", nome(.voz).en);
}

test "atalhos personalizáveis: cada ação tem padrão que vale, e os padrões não brigam" {
    var p: Personalizados = .{};
    inline for (@typeInfo(Acao).@"enum".field_names) |name| {
        const a = @field(Acao, name);
        var buf: [4]Combinacao = undefined;
        const l = p.de(a, &buf);
        try std.testing.expect(l.len > 0);
        for (l) |cb| {
            try std.testing.expect(cb.usable());
            try std.testing.expect(!reservado(cb));
            try std.testing.expectEqual(@as(?Acao, null), p.dono(cb, a));
        }
    }
}

test "atalhos personalizáveis: trocar, recusar o que não pode, e ir e voltar pelo settings.kdl" {
    const kdl = @import("../theme/kdl.zig");
    const gpa = std.testing.allocator;
    var p: Personalizados = .{};
    const j = Combinacao.parse("Ctrl+J").?;
    try std.testing.expectEqual(Personalizados.Porque.ok, p.pode(.paleta, j));
    p.set(.paleta, j);
    var buf: [4]Combinacao = undefined;
    try std.testing.expect(p.de(.paleta, &buf)[0].eql(j));
    // Ctrl+K deixou de ser da paleta; Ctrl+F continua da busca.
    try std.testing.expectEqual(@as(?Acao, null), p.dono(Combinacao.parse("Ctrl+K").?, null));
    try std.testing.expectEqual(Personalizados.Porque.em_uso, p.pode(.mutar, Combinacao.parse("Ctrl+F").?));
    try std.testing.expectEqual(Personalizados.Porque.reservado, p.pode(.mutar, Combinacao.parse("Ctrl+C").?));
    try std.testing.expectEqual(Personalizados.Porque.reservado, p.pode(.mutar, Combinacao.parse("Alt+3").?));
    try std.testing.expectEqual(Personalizados.Porque.sem_modificador, p.pode(.mutar, Combinacao.parse("M").?));
    // Pôr de volta o próprio padrão não conta como troca.
    p.set(.buscar, Combinacao.parse("Ctrl+F").?);
    try std.testing.expect(!p.trocado(.buscar));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.write(&out, gpa);
    try out.appendSlice(gpa, "keybind \"naoexiste\" \"Ctrl+L\"\nkeybind \"mutar\" \"Ctrl+C\"\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Personalizados = .{};
    for (nodes) |*n| try std.testing.expect(back.applyNode(n));
    try std.testing.expect(back.de(.paleta, &buf)[0].eql(j));
    // O que não vale ficou de fora: mutar continua no padrão.
    try std.testing.expect(!back.trocado(.mutar));
}

test "atalhos personalizáveis: Ctrl+\\ vai e volta sem estragar o resto do settings.kdl" {
    const kdl = @import("../theme/kdl.zig");
    const gpa = std.testing.allocator;
    var p: Personalizados = .{};
    const bs = Combinacao.parse("Ctrl+\\").?;
    try std.testing.expectEqual(Personalizados.Porque.ok, p.pode(.paleta, bs));
    p.set(.paleta, bs);
    p.set(.mutar, Combinacao.parse("Alt+M").?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.write(&out, gpa);
    // O que vem depois no arquivo continua sendo lido.
    try out.appendSlice(gpa, "voice-volume \"1234\" 0.5\n");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    var back: Personalizados = .{};
    for (nodes[0..2]) |*n| try std.testing.expect(back.applyNode(n));
    back.settle();
    var buf: [4]Combinacao = undefined;
    try std.testing.expect(back.de(.paleta, &buf)[0].eql(bs));
    try std.testing.expect(back.de(.mutar, &buf)[0].eql(Combinacao.parse("Alt+M").?));
    try std.testing.expectEqualStrings("voice-volume", nodes[2].name);
}

test "atalhos personalizáveis: duas ações trocadas de lugar sobrevivem a reabrir" {
    const kdl = @import("../theme/kdl.zig");
    const gpa = std.testing.allocator;
    var p: Personalizados = .{};
    const f = Combinacao.parse("Ctrl+F").?;
    const k = Combinacao.parse("Ctrl+K").?;
    // Na sessão: a busca sai do Ctrl+F, depois a paleta vai para ele, e a busca para o Ctrl+K.
    p.set(.buscar, Combinacao.parse("Ctrl+J").?);
    try std.testing.expectEqual(Personalizados.Porque.ok, p.pode(.paleta, f));
    p.set(.paleta, f);
    try std.testing.expectEqual(Personalizados.Porque.ok, p.pode(.buscar, k));
    p.set(.buscar, k);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try p.write(&out, gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const nodes = try kdl.parse(arena.allocator(), out.items, null);
    var back: Personalizados = .{};
    for (nodes) |*n| _ = back.applyNode(n);
    back.settle();
    var buf: [4]Combinacao = undefined;
    try std.testing.expect(back.de(.paleta, &buf)[0].eql(f));
    try std.testing.expect(back.de(.buscar, &buf)[0].eql(k));
}

test "atalhos personalizáveis: briga no arquivo volta ao padrão, e Padrão não pisa em ninguém" {
    var p: Personalizados = .{};
    // Arquivo editado à mão: a paleta e o mudo no mesmo Alt+P, e o mudo no Ctrl+F da busca.
    p.custom[@intFromEnum(Acao.paleta)] = Combinacao.parse("Alt+P").?;
    p.custom[@intFromEnum(Acao.mutar)] = Combinacao.parse("Alt+P").?;
    p.custom[@intFromEnum(Acao.ensurdecer)] = Combinacao.parse("Ctrl+F").?;
    p.settle();
    try std.testing.expect(!p.trocado(.paleta));
    try std.testing.expect(p.trocado(.mutar));
    try std.testing.expect(!p.trocado(.ensurdecer));
    inline for (@typeInfo(Acao).@"enum".field_names) |name| {
        const a = @field(Acao, name);
        var buf: [4]Combinacao = undefined;
        for (p.de(a, &buf)) |cb| try std.testing.expectEqual(@as(?Acao, null), p.dono(cb, a));
    }
    // O próximo tema sai do F2/Ctrl+T, a paleta pega o Ctrl+T: o tema não volta ao padrão.
    var q: Personalizados = .{};
    q.set(.proximo_tema, Combinacao.parse("F5").?);
    q.set(.paleta, Combinacao.parse("Ctrl+T").?);
    try std.testing.expectEqual(@as(?Acao, .paleta), q.donoDoPadrao(.proximo_tema));
    try std.testing.expectEqual(@as(?Acao, null), q.donoDoPadrao(.paleta));
}

test "atalhos personalizáveis: as teclas da caixa de texto, do zoom e o AltGr ficam de fora" {
    const p: Personalizados = .{};
    for ([_][]const u8{ "Ctrl+Shift+C", "Ctrl+Shift+V", "Ctrl+Alt+0", "Ctrl+Shift+=", "Ctrl+Shift+Z", "Ctrl+→", "Ctrl+Shift+←", "Ctrl+Backspace", "Ctrl+Delete", "Ctrl+Insert", "Ctrl+Home" }) |t|
        try std.testing.expectEqual(Personalizados.Porque.reservado, p.pode(.mutar, Combinacao.parse(t).?));
    for ([_][]const u8{ "Ctrl+Alt+Q", "Ctrl+Alt+W", "Ctrl+Alt+7", "Ctrl+Alt+/", "Ctrl+Shift+Alt+E" }) |t|
        try std.testing.expectEqual(Personalizados.Porque.altgr, p.pode(.mutar, Combinacao.parse(t).?));
    for ([_][]const u8{ "Ctrl+Alt+F5", "Ctrl+Alt+←", "Alt+M", "Ctrl+Shift+J", "Ctrl+PageDown" }) |t|
        try std.testing.expectEqual(Personalizados.Porque.ok, p.pode(.mutar, Combinacao.parse(t).?));
}
