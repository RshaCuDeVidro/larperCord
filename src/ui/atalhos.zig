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
    const fixos = [_][]const u8{ "Ctrl+A", "Ctrl+X", "Ctrl+Z", "Ctrl+Y", "Ctrl+0", "Ctrl+=", "Ctrl+-", "Esc", "Alt+F4" };
    for (fixos) |t| if (Combinacao.parse(t).?.eql(cb)) return true;
    // Alt+1…9: ir para a aba N.
    if (cb.alt and !cb.ctrl and !cb.shift and @intFromEnum(cb.key) >= @intFromEnum(comb.Key.@"1") and @intFromEnum(cb.key) <= @intFromEnum(comb.Key.@"9")) return true;
    return false;
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

    pub const Porque = enum { ok, sem_modificador, reservado, em_uso };

    /// Dá para pôr `cb` em `acao`? (Com `.em_uso`, `dono` diz de quem é.)
    pub fn pode(p: *const Personalizados, acao: Acao, cb: Combinacao) Porque {
        if (!cb.usable()) return .sem_modificador;
        if (reservado(cb)) return .reservado;
        if (p.dono(cb, acao) != null) return .em_uso;
        return .ok;
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

    /// Escreve as linhas do settings.kdl.
    pub fn write(p: *const Personalizados, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        for (p.custom, 0..) |cb, i| if (cb) |x| {
            var buf: [32]u8 = undefined;
            try out.print(gpa, "keybind \"{s}\" \"{s}\"\n", .{ @tagName(@as(Acao, @enumFromInt(i))), x.format(&buf) });
        };
    }

    /// Lê `keybind "paleta" "Ctrl+J"`. false: o nó não é nosso. Nome ou combinação
    /// que não valem (outra versão, arquivo editado à mão) ficam de fora.
    pub fn applyNode(p: *Personalizados, n: anytype) bool {
        if (!std.mem.eql(u8, n.name, "keybind")) return false;
        const name = (n.arg(0) orelse return true).asString() orelse return true;
        const text = (n.arg(1) orelse return true).asString() orelse return true;
        const acao = std.meta.stringToEnum(Acao, name) orelse return true;
        const cb = Combinacao.parse(text) orelse return true;
        if (p.pode(acao, cb) != .ok) return true;
        p.set(acao, cb);
        return true;
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
