//! A janela flutuante (picture-in-picture) sem o SDL: o que ela segue, onde abre, o que
//! fica guardado, como a vista compacta se divide e quando ela precisa de um quadro.
//! Testado em `zig build test`; quem abre a janela, desenha e repassa os eventos é
//! app_flutuante.zig, e a vista é ui/flutuante.zig.
const std = @import("std");
const types = @import("types.zig");
const layout = @import("../theme/layout.zig");
const Rect = layout.Rect;
const Id = types.Id;

/// O que a janela mostra: uma conversa (as últimas mensagens e uma caixa para
/// responder) ou a call em que estamos (os quadros de quem está e os botões).
pub const Alvo = union(enum) {
    conversa: Id,
    call: Id,

    pub fn canal(a: Alvo) Id {
        return switch (a) {
            inline else => |id| id,
        };
    }
};

/// O que a interface pede (o menu da conversa, a barra de abas, a tela da call, os
/// botões da própria janela): abrir para algo, fechar, ou voltar para a principal.
pub const Pedido = union(enum) {
    abrir: Alvo,
    fechar,
    /// Mostra a janela principal na conversa (ou na call) que a flutuante segue.
    voltar,
};

/// Que conversa dá para pôr na janela flutuante: as de texto (canal, DM, grupo, thread)
/// que a conta pode ver. Fórum é uma lista de posts, e voz e categoria não têm conversa.
pub fn conversaFlutua(kind: types.ChannelKind, acesso: bool) bool {
    return acesso and kind == .text;
}

/// Posição e tamanho no sistema de coordenadas do SDL (o mesmo da janela principal:
/// pixels no Windows e no X11, pontos no Wayland).
pub const Geo = struct { x: i32 = 0, y: i32 = 0, w: i32, h: i32 };

/// Tamanho de abertura e mínimo, em pontos (a escala do monitor multiplica).
pub const padrao_w: i32 = 360;
pub const padrao_h: i32 = 480;
pub const min_w: i32 = 260;
pub const min_h: i32 = 200;
/// Distância da borda da área útil no canto onde ela abre da primeira vez.
const margem: i32 = 24;
/// Quanto da janela guardada (de largura e de altura) precisa cair na tela.
const alca: i32 = 32;

fn escalado(v: i32, s: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * s));
}

/// A geometria guardada nas configurações (`pip_*`); largura 0 é nunca aberta.
pub fn lida(x: i16, y: i16, w: i16, h: i16) ?Geo {
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

/// O que vai para as configurações (cabe num i16, como a largura dos painéis).
pub fn paraGuardar(g: Geo) [4]i16 {
    const lim = struct {
        fn f(v: i32) i16 {
            return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
        }
    }.f;
    return .{ lim(g.x), lim(g.y), lim(@max(g.w, 1)), lim(@max(g.h, 1)) };
}

/// Onde a janela abre. `area`: a área útil do monitor da janela principal (sem os
/// painéis do sistema); `escala`: pontos para coordenadas da janela (1 no Wayland, a do
/// monitor no Windows e no X11); `posiciona`: o sistema deixa o app escolher o lugar.
/// O Wayland não deixa: lá só o tamanho volta, e quem põe a janela é o compositor.
/// Sem nada guardado, abre com o tamanho padrão no canto de baixo à direita. Guardada
/// num lugar que não está mais na tela (o outro monitor saiu), volta para o canto com o
/// tamanho de antes; maior que o monitor, encolhe até caber.
pub fn abertura(guardada: ?Geo, area: Geo, escala: f32, posiciona: bool) Geo {
    const s = if (escala > 0) escala else 1;
    const mw = escalado(min_w, s);
    const mh = escalado(min_h, s);
    var w = if (guardada) |g| g.w else escalado(padrao_w, s);
    var h = if (guardada) |g| g.h else escalado(padrao_h, s);
    w = std.math.clamp(w, mw, @max(mw, area.w));
    h = std.math.clamp(h, mh, @max(mh, area.h));
    if (!posiciona) return .{ .w = w, .h = h };
    const m = escalado(margem, s);
    const canto: Geo = .{ .x = area.x + @max(0, area.w - w - m), .y = area.y + @max(0, area.h - h - m), .w = w, .h = h };
    const g = guardada orelse return canto;
    if (!naTela(g, area)) return canto;
    return .{
        .x = std.math.clamp(g.x, area.x, @max(area.x, area.x + area.w - w)),
        .y = std.math.clamp(g.y, area.y, @max(area.y, area.y + area.h - h)),
        .w = w,
        .h = h,
    };
}

/// Um bom pedaço da janela guardada cai na área: ela só encosta na borda. Fora disso
/// (outro monitor que saiu), não há o que encostar.
fn naTela(g: Geo, area: Geo) bool {
    const x0 = @max(g.x, area.x);
    const x1 = @min(g.x + g.w, area.x + area.w);
    const y0 = @max(g.y, area.y);
    const y1 = @min(g.y + g.h, area.y + area.h);
    return x1 - x0 >= alca and y1 - y0 >= alca;
}

/// O que guardar quando a janela muda de lugar ou de tamanho. Sem `posiciona` (Wayland),
/// a posição que o SDL diz não é a da tela: fica a que estava guardada.
pub fn guardar(atual: Geo, antes: ?Geo, posiciona: bool) Geo {
    if (posiciona) return atual;
    const a = antes orelse return .{ .w = atual.w, .h = atual.h };
    return .{ .x = a.x, .y = a.y, .w = atual.w, .h = atual.h };
}

/// As faixas da vista compacta, em pontos: a barra de cima (o nome e o botão de voltar
/// para a janela principal), o meio (as mensagens ou os quadros da call) e a de baixo
/// (a caixa de mensagem ou os botões da call).
pub const Vista = struct { topo: Rect, corpo: Rect, base: Rect };

pub const topo_h: f32 = 38;
/// A caixa de mensagem com a margem em volta e a linha do "digitando" em cima dela.
pub const caixa_h: f32 = 44;
pub const caixa_margem: f32 = 8;
pub const digitando_h: f32 = 20;
pub const botoes_h: f32 = 64;

pub fn vista(w: f32, h: f32, tipo: std.meta.Tag(Alvo)) Vista {
    const base_h: f32 = switch (tipo) {
        .conversa => caixa_h + caixa_margem * 2 + digitando_h,
        .call => botoes_h,
    };
    // Janela baixa: o meio encolhe até sumir; as barras ficam (a de baixo primeiro).
    const top = @min(topo_h, h);
    const bh = @min(base_h, @max(0, h - top));
    const corpo_h = @max(0, h - top - bh);
    return .{
        .topo = .{ .x = 0, .y = 0, .w = w, .h = top },
        .corpo = .{ .x = 0, .y = top, .w = w, .h = corpo_h },
        .base = .{ .x = 0, .y = top + corpo_h, .w = w, .h = bh },
    };
}

/// A caixa de mensagem dentro da faixa de baixo (o "digitando" fica em cima dela).
pub fn caixa(base: Rect) Rect {
    const h = @min(caixa_h, @max(0, base.h - caixa_margem * 2));
    return .{ .x = base.x + caixa_margem, .y = base.bottom() - caixa_margem - h, .w = @max(0, base.w - caixa_margem * 2), .h = h };
}

/// Continua aberta? A conversa sumiu (saiu do servidor, apagaram o canal) ou a call
/// acabou (ou já é outra): fecha sozinha, nada fica apontando para o que não existe.
pub fn segue(alvo: Alvo, existe: bool, voz: ?Id) bool {
    return switch (alvo) {
        .conversa => existe,
        .call => |ch| existe and voz != null and voz.? == ch,
    };
}

/// Quantas mensagens do fim a vista compacta mede e desenha. A mesma conversa aberta na
/// janela principal tem outra largura: com a conversa inteira, cada quadro de uma
/// mediria de novo o que a outra acabou de medir.
pub const ultimas: usize = 60;

pub fn cauda(total: usize) usize {
    return total -| ultimas;
}

/// Por que a janela flutuante desenharia agora. Ela só faz quadro quando algo dela
/// mudou: o mouse ou o teclado nela (`pendentes`), o que chegou da rede ou mudou no app
/// (`mudou`), uma animação dela; parada, não custa nada.
pub const Motivo = struct {
    pendentes: u8 = 0,
    mudou: bool = false,
    /// O mouse anda por cima sem botão apertado: no máximo um quadro a cada `mouse_ms`.
    mouse: bool = false,
    anim: bool = false,
    agora_ms: i64 = 0,
    ultimo_ms: i64 = 0,
    /// A próxima animação lenta ou virada do relógio que ela pediu.
    acordar_ms: i64 = std.math.maxInt(i64),
};

pub const mouse_ms: i64 = 33;
/// O que chega da rede (presença, digitando, mensagens) redesenha no máximo a cada
/// `rede_ms`, como na principal: uma rajada vira um quadro só.
pub const rede_ms: i64 = 50;

pub fn precisa(m: Motivo) bool {
    if (m.pendentes > 0 or m.anim) return true;
    if (m.mudou and m.agora_ms - m.ultimo_ms >= rede_ms) return true;
    if (m.mouse and m.agora_ms - m.ultimo_ms >= mouse_ms) return true;
    return m.agora_ms >= m.acordar_ms;
}

/// Até quando o laço pode dormir por causa dela (maxInt: nada marcado).
pub fn proximo(m: Motivo) i64 {
    if (m.pendentes > 0 or m.anim) return m.agora_ms;
    var t = m.acordar_ms;
    if (m.mudou) t = @min(t, m.ultimo_ms + rede_ms);
    if (m.mouse) t = @min(t, m.ultimo_ms + mouse_ms);
    return t;
}

/// O título da janela (barra de tarefas, alt+tab): "#geral · larperCord".
pub fn titulo(buf: []u8, sigilo: []const u8, nome: []const u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}{s} · larperCord", .{ sigilo, nome }, 0) catch "larperCord";
}

test "abre no canto de baixo à direita com o tamanho padrão" {
    const area: Geo = .{ .x = 0, .y = 0, .w = 1920, .h = 1040 };
    const g = abertura(null, area, 1, true);
    try std.testing.expectEqual(@as(i32, padrao_w), g.w);
    try std.testing.expectEqual(@as(i32, padrao_h), g.h);
    try std.testing.expectEqual(@as(i32, 1920 - padrao_w - margem), g.x);
    try std.testing.expectEqual(@as(i32, 1040 - padrao_h - margem), g.y);
    // A 150% (Windows, X11) o tamanho vem em pixels.
    const g2 = abertura(null, area, 1.5, true);
    try std.testing.expectEqual(@as(i32, 540), g2.w);
    try std.testing.expectEqual(@as(i32, 720), g2.h);
}

test "volta onde estava, dentro da tela" {
    const area: Geo = .{ .x = 0, .y = 30, .w = 1920, .h = 1050 };
    const g = abertura(.{ .x = 100, .y = 200, .w = 400, .h = 500 }, area, 1, true);
    try std.testing.expectEqual(Geo{ .x = 100, .y = 200, .w = 400, .h = 500 }, g);
    // Um pedaço para fora: encosta na borda.
    const g2 = abertura(.{ .x = 1700, .y = 900, .w = 400, .h = 500 }, area, 1, true);
    try std.testing.expectEqual(@as(i32, 1520), g2.x);
    try std.testing.expectEqual(@as(i32, 580), g2.y);
    // Embaixo do painel de cima (y < 30): desce até a área útil.
    const g3 = abertura(.{ .x = 100, .y = 10, .w = 400, .h = 500 }, area, 1, true);
    try std.testing.expectEqual(@as(i32, 30), g3.y);
}

test "monitor que saiu: volta para o canto com o tamanho de antes" {
    const area: Geo = .{ .x = 0, .y = 0, .w = 1366, .h = 728 };
    const g = abertura(.{ .x = 2500, .y = 100, .w = 420, .h = 520 }, area, 1, true);
    try std.testing.expectEqual(@as(i32, 420), g.w);
    try std.testing.expectEqual(@as(i32, 1366 - 420 - margem), g.x);
    try std.testing.expectEqual(@as(i32, 728 - 520 - margem), g.y);
}

test "tamanho entre o mínimo e o monitor" {
    const area: Geo = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const big = abertura(.{ .x = 0, .y = 0, .w = 3000, .h = 2000 }, area, 1, true);
    try std.testing.expectEqual(@as(i32, 800), big.w);
    try std.testing.expectEqual(@as(i32, 600), big.h);
    const tiny = abertura(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, area, 1, true);
    try std.testing.expectEqual(@as(i32, min_w), tiny.w);
    try std.testing.expectEqual(@as(i32, min_h), tiny.h);
}

test "Wayland: só o tamanho volta e a posição guardada não muda" {
    const area: Geo = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const g = abertura(.{ .x = 700, .y = 300, .w = 400, .h = 500 }, area, 1, false);
    try std.testing.expectEqual(@as(i32, 400), g.w);
    try std.testing.expectEqual(@as(i32, 0), g.x);
    // O SDL diz 0,0 no Wayland: guardar mantém a de antes.
    const s = guardar(.{ .x = 0, .y = 0, .w = 380, .h = 450 }, .{ .x = 700, .y = 300, .w = 400, .h = 500 }, false);
    try std.testing.expectEqual(Geo{ .x = 700, .y = 300, .w = 380, .h = 450 }, s);
    // Nos outros, guarda o que está.
    const x = guardar(.{ .x = 10, .y = 20, .w = 380, .h = 450 }, .{ .x = 700, .y = 300, .w = 400, .h = 500 }, true);
    try std.testing.expectEqual(Geo{ .x = 10, .y = 20, .w = 380, .h = 450 }, x);
}

test "o guardado nas configurações vai e volta" {
    try std.testing.expectEqual(@as(?Geo, null), lida(0, 0, 0, 0));
    const v = paraGuardar(.{ .x = -1200, .y = 40, .w = 380, .h = 520 });
    try std.testing.expectEqual(Geo{ .x = -1200, .y = 40, .w = 380, .h = 520 }, lida(v[0], v[1], v[2], v[3]).?);
    // Fora do que um i16 guarda: encosta no limite.
    const big = paraGuardar(.{ .x = 100_000, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(i16, std.math.maxInt(i16)), big[0]);
}

test "vista compacta: as barras ficam e o meio encolhe" {
    const v = vista(360, 480, .conversa);
    try std.testing.expectEqual(@as(f32, topo_h), v.corpo.y);
    try std.testing.expectEqual(@as(f32, 480), v.base.bottom());
    try std.testing.expectEqual(@as(f32, 480 - topo_h - (caixa_h + caixa_margem * 2 + digitando_h)), v.corpo.h);
    const cx = caixa(v.base);
    try std.testing.expectEqual(@as(f32, caixa_h), cx.h);
    try std.testing.expectEqual(v.base.bottom() - caixa_margem, cx.bottom());
    try std.testing.expectEqual(@as(f32, 360 - caixa_margem * 2), cx.w);
    const call = vista(360, 300, .call);
    try std.testing.expectEqual(@as(f32, botoes_h), call.base.h);
    try std.testing.expectEqual(@as(f32, 300 - topo_h - botoes_h), call.corpo.h);
    // Baixa demais: o meio some, nada fica com altura negativa.
    const low = vista(360, 60, .call);
    try std.testing.expectEqual(@as(f32, 0), low.corpo.h);
    try std.testing.expect(low.base.h >= 0 and low.base.bottom() <= 60);
}

test "fecha sozinha quando o que ela segue some" {
    try std.testing.expect(segue(.{ .conversa = 5 }, true, null));
    try std.testing.expect(!segue(.{ .conversa = 5 }, false, null));
    try std.testing.expect(segue(.{ .call = 7 }, true, 7));
    try std.testing.expect(!segue(.{ .call = 7 }, true, null));
    try std.testing.expect(!segue(.{ .call = 7 }, true, 8));
    try std.testing.expectEqual(@as(Id, 7), (Alvo{ .call = 7 }).canal());
}

test "só conversa de texto que a conta vê vai para a janela flutuante" {
    try std.testing.expect(conversaFlutua(.text, true));
    try std.testing.expect(!conversaFlutua(.text, false));
    try std.testing.expect(!conversaFlutua(.forum, true));
    try std.testing.expect(!conversaFlutua(.voice, true));
    try std.testing.expect(!conversaFlutua(.category, true));
}

test "a cauda da conversa" {
    try std.testing.expectEqual(@as(usize, 0), cauda(10));
    try std.testing.expectEqual(@as(usize, 0), cauda(ultimas));
    try std.testing.expectEqual(@as(usize, 40), cauda(ultimas + 40));
}

test "quadro só quando algo dela mudou" {
    try std.testing.expect(!precisa(.{ .agora_ms = 1000, .ultimo_ms = 900 }));
    try std.testing.expect(precisa(.{ .pendentes = 1 }));
    try std.testing.expect(precisa(.{ .anim = true }));
    // O que chegou da rede: no máximo um quadro a cada `rede_ms`.
    try std.testing.expect(!precisa(.{ .mudou = true, .agora_ms = 1020, .ultimo_ms = 1000 }));
    try std.testing.expect(precisa(.{ .mudou = true, .agora_ms = 1000 + rede_ms, .ultimo_ms = 1000 }));
    try std.testing.expectEqual(@as(i64, 1000 + rede_ms), proximo(.{ .mudou = true, .agora_ms = 1020, .ultimo_ms = 1000 }));
    // O mouse andando: no máximo um quadro a cada `mouse_ms`.
    try std.testing.expect(!precisa(.{ .mouse = true, .agora_ms = 1010, .ultimo_ms = 1000 }));
    try std.testing.expect(precisa(.{ .mouse = true, .agora_ms = 1000 + mouse_ms, .ultimo_ms = 1000 }));
    try std.testing.expectEqual(@as(i64, 1000 + mouse_ms), proximo(.{ .mouse = true, .agora_ms = 1010, .ultimo_ms = 1000 }));
    // A hora marcada por uma animação lenta.
    try std.testing.expect(!precisa(.{ .agora_ms = 1000, .acordar_ms = 1500 }));
    try std.testing.expect(precisa(.{ .agora_ms = 1500, .acordar_ms = 1500 }));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), proximo(.{ .agora_ms = 5 }));
}

test "título da janela" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("#geral · larperCord", titulo(&buf, "#", "geral"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("larperCord", titulo(&tiny, "#", "um nome comprido"));
}
