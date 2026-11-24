//! Os comandos do Inspetor: a linha do Console e o `larpercord ctl inspect …` usam os
//! mesmos. Dão para ver e mexer no app sem olhar a tela: achar um elemento pelo texto,
//! pela marca do QA ou pelo componente, clicar nele, digitar, ler a árvore do quadro, a
//! rede, o gateway, o log, os eventos e os números de desempenho, trocar de tema e tirar
//! um print. Cada um escreve texto simples (o `el` escreve JSON).
//!
//! Clicar e digitar viram eventos do ImGui dados um por quadro (o ImGui precisa ver o
//! mouse chegar antes do clique), pela fila do "robô" (`feed`, no começo de cada quadro).
//! Pelo ctl, só na demonstração ou com "Deixar o ctl clicar e digitar" ligado no Console:
//! qualquer programa do usuário fala com o ctl, e clicar pela conta de verdade é coisa que
//! a pessoa liga sabendo.
const std = @import("std");
const c = @import("c");
const cap = @import("captura.zig");
const reg = @import("registros.zig");
const kit = @import("kit.zig");
const ui = @import("ui.zig");
const App = @import("../app.zig").App;

pub const Origem = enum { console, ctl };
pub const Fim = enum { pronto, depois };

/// Pelo ctl, clicar e digitar só com isto ligado (ou na demonstração). Vale até fechar o app.
pub var ctl_mexe = false;

// --- O robô ----------------------------------------------------------------------

pub const Botao = enum(u8) { left, right, middle };

const Passo = union(enum) {
    move: [2]f32,
    down: Botao,
    up: Botao,
    text: struct { buf: [96]u8, len: u8 },
    key: struct { key: c.ImGuiKey, mods: c_int, down: bool },
    wait,
};

var fila: [256]Passo = undefined;
var ini: usize = 0;
var fim_fila: usize = 0;

fn push(p: Passo) void {
    if ((fim_fila + 1) % fila.len == ini) return;
    fila[fim_fila] = p;
    fim_fila = (fim_fila + 1) % fila.len;
}

pub fn busy() bool {
    return ini != fim_fila or shot_path_len > 0;
}

pub fn clickAt(x: f32, y: f32, b: Botao) void {
    push(.{ .move = .{ x, y } });
    push(.wait);
    push(.{ .down = b });
    push(.{ .up = b });
    push(.wait);
}

fn doubleAt(x: f32, y: f32) void {
    push(.{ .move = .{ x, y } });
    push(.wait);
    push(.{ .down = .left });
    push(.{ .up = .left });
    push(.{ .down = .left });
    push(.{ .up = .left });
    push(.wait);
}

fn hoverAt(x: f32, y: f32) void {
    push(.{ .move = .{ x, y } });
    push(.wait);
    push(.wait);
}

/// No começo de cada quadro, antes do ImGui_NewFrame: um passo da fila.
pub fn feed(io: *c.ImGuiIO) void {
    if (ini == fim_fila) return;
    const p = fila[ini];
    ini = (ini + 1) % fila.len;
    switch (p) {
        .move => |m| c.ImGuiIO_AddMousePosEvent(io, m[0], m[1]),
        .down => |b| if (!ui.robotPress(@intFromEnum(b))) c.ImGuiIO_AddMouseButtonEvent(io, @intFromEnum(b), true),
        .up => |b| if (!ui.robotRelease()) c.ImGuiIO_AddMouseButtonEvent(io, @intFromEnum(b), false),
        .text => |t| {
            var z: [97]u8 = undefined;
            @memcpy(z[0..t.len], t.buf[0..t.len]);
            z[t.len] = 0;
            c.ImGuiIO_AddInputCharactersUTF8(io, &z);
        },
        .key => |k| {
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, k.down and k.mods & c.ImGuiMod_Ctrl != 0);
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Shift, k.down and k.mods & c.ImGuiMod_Shift != 0);
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Alt, k.down and k.mods & c.ImGuiMod_Alt != 0);
            c.ImGuiIO_AddKeyEvent(io, k.key, k.down);
        },
        .wait => {},
    }
}

// --- Print ------------------------------------------------------------------------

var shot_path: [512]u8 = undefined;
var shot_path_len: usize = 0;
pub var shot_result: enum { nada, ok, falhou } = .nada;

/// Depois de desenhar o quadro (antes de ir para a tela): grava o print pedido.
pub fn afterRender(app: *App) void {
    if (shot_path_len == 0) return;
    // Um quadro inteiro depois do pedido, para o que mudou já aparecer.
    if (busy() and ini != fim_fila) return;
    var z: [513]u8 = undefined;
    @memcpy(z[0..shot_path_len], shot_path[0..shot_path_len]);
    z[shot_path_len] = 0;
    shot_result = if (app.win.screenshot(@ptrCast(&z))) .ok else .falhou;
    shot_path_len = 0;
}

// --- Achar elementos ------------------------------------------------------------------

/// Um seletor: `qa:nome` (a marca do QA, nos builds com o robô), `comp:nome` (o pedaço do
/// layout), `id:0x1a2b` (o id do ImGui), `@x,y` (o que está no ponto), `#n` (o n-ésimo
/// elemento do quadro) ou um texto (o elemento cujo texto, ou o texto dentro, contém isso).
pub const Achado = union(enum) { el: usize, scope: usize, ponto: [2]f32 };

pub fn achar(f: *const cap.Frame, sel: []const u8) ?Achado {
    const s = std.mem.trim(u8, sel, " \t\"");
    if (s.len == 0) return null;
    if (std.mem.startsWith(u8, s, "@")) {
        var it = std.mem.splitScalar(u8, s[1..], ',');
        const x = std.fmt.parseFloat(f32, std.mem.trim(u8, it.next() orelse return null, " ")) catch return null;
        const y = std.fmt.parseFloat(f32, std.mem.trim(u8, it.next() orelse return null, " ")) catch return null;
        if (cap.pick(f, x, y)) |i| return .{ .el = i };
        return .{ .ponto = .{ x, y } };
    }
    if (std.mem.startsWith(u8, s, "#")) {
        const i = std.fmt.parseInt(usize, s[1..], 10) catch return null;
        return if (i < f.els.items.len) .{ .el = i } else null;
    }
    if (std.mem.startsWith(u8, s, "id:")) {
        const v = std.mem.trim(u8, s[3..], " ");
        const id = std.fmt.parseInt(u32, if (std.mem.startsWith(u8, v, "0x")) v[2..] else v, 16) catch return null;
        for (f.els.items, 0..) |*e, i| if (e.id == id and (e.kind == .item or e.kind == .window)) return .{ .el = i };
        return null;
    }
    if (std.mem.startsWith(u8, s, "comp:")) {
        const name = s[5..];
        for (f.scopes.items, 0..) |*sc, i| if (i > 0 and std.mem.eql(u8, sc.name, name)) return .{ .scope = i };
        return null;
    }
    if (std.mem.startsWith(u8, s, "qa:")) {
        const key = s[3..];
        // O item (área clicável) com essa marca; se não houver, o centro dela.
        for (f.marks.items) |m| if (std.mem.eql(u8, f.str(m.key), key)) {
            for (f.els.items, 0..) |*e, i| if (e.kind == .item and cap.visible(e) and closeRect(e.rect, m.rect)) return .{ .el = i };
            // Sem um item do mesmo tamanho: o que está no meio da marca.
            const cx = m.rect.x + m.rect.w / 2;
            const cy = m.rect.y + m.rect.h / 2;
            if (cap.pick(f, cx, cy)) |i| return .{ .el = i };
            return .{ .ponto = .{ cx, cy } };
        };
        return null;
    }
    const q = if (std.mem.startsWith(u8, s, "text:")) s[5..] else s;
    // Primeiro um item cujo texto dentro bate exatamente; depois um texto que contém.
    var best: ?usize = null;
    for (f.els.items, 0..) |*e, i| {
        if (!cap.visible(e)) continue;
        if (e.kind == .item) {
            var tb: [200]u8 = undefined;
            if (std.ascii.eqlIgnoreCase(cap.textsIn(f, e.rect, e.layer, &tb), q)) return .{ .el = i };
        }
        if (best == null and e.kind == .text and kit.has(f.str(e.str), q)) best = i;
    }
    if (best) |i| return .{ .el = i };
    return null;
}

fn closeRect(a: cap.Rect, b: cap.Rect) bool {
    return @abs(a.x - b.x) + @abs(a.y - b.y) + @abs(a.w - b.w) + @abs(a.h - b.h) < 4;
}

fn centro(f: *const cap.Frame, a: Achado) [2]f32 {
    return switch (a) {
        .el => |i| blk: {
            const e = &f.els.items[i];
            const v = cap.overlap(e.rect, e.clip);
            break :blk .{ v.x + v.w / 2, v.y + v.h / 2 };
        },
        .scope => |i| .{ f.scopes.items[i].rect.x + f.scopes.items[i].rect.w / 2, f.scopes.items[i].rect.y + f.scopes.items[i].rect.h / 2 },
        .ponto => |p| p,
    };
}

// --- JSON de um elemento ----------------------------------------------------------------

fn jstr(w: *std.Io.Writer, s: []const u8) void {
    std.json.Stringify.value(s, .{}, w) catch {};
}

pub fn elementJson(w: *std.Io.Writer, f: *const cap.Frame, i: usize) void {
    const e = &f.els.items[i];
    const app = ui.app_ptr;
    kit.say(w, "{{\"index\":{d},\"kind\":\"{s}\",\"rect\":[{d:.1},{d:.1},{d:.1},{d:.1}],\"visible\":{},\"layer\":{d}", &.{ kit.arg(i), kit.arg(@tagName(e.kind)), kit.arg(e.rect.x), kit.arg(e.rect.y), kit.arg(e.rect.w), kit.arg(e.rect.h), kit.arg(cap.visible(e)), kit.arg(e.layer) }) catch return;
    if (f.scopeOf(e)) |s| {
        w.writeAll(",\"scope\":") catch {};
        jstr(w, s.name);
        if (s.line > 0) {
            var lb: [160]u8 = undefined;
            w.writeAll(",\"theme\":") catch {};
            jstr(w, kit.bufSay(&lb, "{s}:{d}:{d}", &.{ kit.arg(@import("aba_elementos.zig").themeFile()), kit.arg(s.line), kit.arg(s.col) }) orelse "");
        }
    }
    const s = f.str(e.str);
    if (s.len > 0) {
        w.writeAll(switch (e.kind) {
            .image => ",\"url\":",
            .item, .window => ",\"label\":",
            else => ",\"text\":",
        }) catch {};
        jstr(w, s);
    }
    if (e.kind == .text or e.kind == .fill or e.kind == .border) {
        var hx: [12]u8 = undefined;
        w.writeAll(",\"color\":") catch {};
        jstr(w, kit.hexOf(&hx, e.color));
        if (app) |a| {
            const tok = @import("aba_elementos.zig").tokenName(a.themes.theme_(), e.color);
            if (tok.len > 0) {
                w.writeAll(",\"token\":") catch {};
                jstr(w, tok);
            }
        }
    }
    if (e.kind == .text) {
        kit.say(w, ",\"size\":{d:.0}", &.{ kit.arg(e.size) }) catch {};
        kit.say(w, ",\"contrast\":{d:.2}", &.{ kit.arg(kit.fromU32(e.color).contrast(kit.fromU32(@import("aba_elementos.zig").fundo(f, i)))) }) catch {};
    }
    if (e.kind == .image and e.tex_w > 0) kit.say(w, ",\"texture\":[{d},{d}]", &.{ kit.arg(e.tex_w), kit.arg(e.tex_h) }) catch {};
    if (e.kind == .item or e.kind == .window) {
        kit.say(w, ",\"id\":\"0x{X:0>8}\",\"status\":{d}", &.{ kit.arg(e.id), kit.arg(e.status) }) catch {};
        if (e.hit) |h| kit.say(w, ",\"hit\":{{\"id\":{d},\"hovered\":{},\"held\":{}}}", &.{ kit.arg(h.local), kit.arg(h.hovered), kit.arg(h.held) }) catch {};
        var tb: [400]u8 = undefined;
        const inside = cap.textsIn(f, e.rect, e.layer, &tb);
        if (inside.len > 0) {
            w.writeAll(",\"inside\":") catch {};
            jstr(w, inside);
        }
    }
    if (f.markFor(e.rect)) |m| {
        w.writeAll(",\"qa\":") catch {};
        jstr(w, m);
    }
    if (f.partFor(e.rect)) |pn| {
        w.writeAll(",\"part\":") catch {};
        jstr(w, pn);
    }
    w.writeAll("}") catch {};
}

fn elLine(w: *std.Io.Writer, f: *const cap.Frame, i: usize) void {
    const e = &f.els.items[i];
    var db: [200]u8 = undefined;
    const desc = @import("aba_elementos.zig").describe(f, i, &db);
    kit.say(w, "#{d}  {d:.0},{d:.0} {d:.0}×{d:.0}  {s}", &.{ kit.arg(i), kit.arg(e.rect.x), kit.arg(e.rect.y), kit.arg(e.rect.w), kit.arg(e.rect.h), kit.arg(desc) }) catch return;
    if (f.markFor(e.rect)) |m| if (e.kind != .item) kit.say(w, "  [qa:{s}]", &.{ kit.arg(m) }) catch {};
    if (f.partFor(e.rect)) |pn| kit.say(w, "  [part:{s}]", &.{ kit.arg(pn) }) catch {};
    w.writeAll("\n") catch {};
}

// --- Os comandos ------------------------------------------------------------------------

const ajuda =
    \\help                     esta lista
    \\find <texto>             elementos com esse texto (ou marca do QA, componente, cor)
    \\tree [componente]        a árvore do quadro, com o que cada pedaço desenhou
    \\el <seletor>             tudo de um elemento, em JSON
    \\click <seletor>          clica no meio (rclick, dclick e hover também)
    \\type <texto>             digita no campo em foco
    \\key <tecla>              aperta uma tecla: enter, esc, tab, ctrl+k, ctrl+shift+e…
    \\net [filtro] [n]         os últimos pedidos HTTP
    \\gw [filtro] [n]          os últimos quadros do gateway (op 1 e 11 só com "hb")
    \\log [filtro] [n]         as últimas linhas do log
    \\ev [filtro] [n]          os últimos eventos internos (ações, comandos, eventos)
    \\perf                     números de desempenho
    \\state                    a sessão, a conversa aberta e o tema
    \\theme [nome|reload]      troca ou recarrega o tema
    \\open <id do canal>       abre uma conversa
    \\shot <arquivo.png>       print da janela
    \\record on|off            gravar a rede, o log e os eventos
    \\clear [net|gw|log|ev]    limpa as listas
    \\inspector open|close|<aba>
    \\
    \\seletores: qa:nome  comp:nome  id:0x1a2b  @x,y  #n  ou um texto
    \\
;

/// Roda uma linha. `depois`: precisa de um quadro gravado que ainda não existe (quem
/// chamou repete a mesma linha no próximo quadro).
pub fn run(app: *App, line: []const u8, w: *std.Io.Writer, origem: Origem) Fim {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = it.next() orelse return .pronto;
    const rest = std.mem.trim(u8, line[cmd.len..], " ");
    const eq = std.mem.eql;
    if (eq(u8, cmd, "help") or eq(u8, cmd, "ajuda")) {
        w.writeAll(ajuda) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "find") or eq(u8, cmd, "tree") or eq(u8, cmd, "el") or eq(u8, cmd, "click") or eq(u8, cmd, "rclick") or eq(u8, cmd, "dclick") or eq(u8, cmd, "hover")) {
        // Precisa do quadro gravado: com o Inspetor fechado (ou noutra aba), pede alguns.
        const f = frameFresh() orelse {
            // Pede os quadros uma vez só: pedir de novo a cada tentativa nunca deixava a conta
            // chegar ao quadro gravado (o Inspetor fechado, pelo ctl).
            if (ui.quadros_pedidos == 0) ui.quadros_pedidos = 3;
            return .depois;
        };
        if (eq(u8, cmd, "find")) return find(f, rest, w);
        if (eq(u8, cmd, "tree")) return tree(f, rest, w);
        const a = achar(f, rest) orelse {
            kit.say(w, "nada com \"{s}\" neste quadro\n", &.{ kit.arg(rest) }) catch {};
            return .pronto;
        };
        if (eq(u8, cmd, "el")) {
            switch (a) {
                .el => |i| elementJson(w, f, i),
                .scope => |si| {
                    const s = &f.scopes.items[si];
                    kit.say(w, "{{\"scope\":\"{s}\",\"line\":{d},\"rect\":[{d:.1},{d:.1},{d:.1},{d:.1}],\"us\":{d}}}", &.{ kit.arg(s.name), kit.arg(s.line), kit.arg(s.rect.x), kit.arg(s.rect.y), kit.arg(s.rect.w), kit.arg(s.rect.h), kit.arg(s.us) }) catch {};
                },
                .ponto => |p| kit.say(w, "{{\"point\":[{d:.1},{d:.1}]}}", &.{ kit.arg(p[0]), kit.arg(p[1]) }) catch {},
            }
            w.writeAll("\n") catch {};
            return .pronto;
        }
        if (!podeMexer(app, origem, w)) return .pronto;
        const p = centro(f, a);
        if (eq(u8, cmd, "click")) clickAt(p[0], p[1], .left) else if (eq(u8, cmd, "rclick")) clickAt(p[0], p[1], .right) else if (eq(u8, cmd, "dclick")) doubleAt(p[0], p[1]) else hoverAt(p[0], p[1]);
        kit.say(w, "{s} em {d:.0},{d:.0}\n", &.{ kit.arg(cmd), kit.arg(p[0]), kit.arg(p[1]) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "type")) {
        if (!podeMexer(app, origem, w)) return .pronto;
        // Um quadro antes: o campo que acabou de pedir o foco já está ativo quando o texto chega.
        push(.wait);
        var s = rest;
        while (s.len > 0) {
            var n = @min(s.len, 96);
            while (n < s.len and n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
            var p: Passo = .{ .text = .{ .buf = undefined, .len = @intCast(n) } };
            @memcpy(p.text.buf[0..n], s[0..n]);
            push(p);
            s = s[n..];
        }
        push(.wait);
        kit.say(w, "digitou {d} bytes\n", &.{ kit.arg(rest.len) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "key")) {
        if (!podeMexer(app, origem, w)) return .pronto;
        const k = parseKey(rest) orelse {
            kit.say(w, "tecla desconhecida: {s}\n", &.{ kit.arg(rest) }) catch {};
            return .pronto;
        };
        push(.{ .key = .{ .key = k.key, .mods = k.mods, .down = true } });
        push(.{ .key = .{ .key = k.key, .mods = k.mods, .down = false } });
        push(.wait);
        kit.say(w, "tecla {s}\n", &.{ kit.arg(rest) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "net")) return listNet(rest, w);
    if (eq(u8, cmd, "gw")) return listGw(rest, w);
    if (eq(u8, cmd, "log")) return listLog(rest, w);
    if (eq(u8, cmd, "ev")) return listEv(rest, w);
    if (eq(u8, cmd, "perf")) return @import("aba_desempenho.zig").texto(app, w);
    if (eq(u8, cmd, "state")) return @import("aba_estado.zig").texto(app, w);
    if (eq(u8, cmd, "theme")) {
        if (rest.len == 0) {
            kit.say(w, "{s} ({s})\n", &.{ kit.arg(app.themes.name()), kit.arg(@tagName(app.themes.mode)) }) catch {};
        } else if (eq(u8, rest, "reload")) {
            const ok = app.themes.reload();
            kit.say(w, "{s}\n", &.{ kit.arg(if (ok) "recarregado" else (app.themes.last_error orelse "erro no tema")) }) catch {};
            if (ok) app.st.theme_gen +%= 1;
        } else if (app.themes.indexOf(rest)) |i| {
            app.handle(.{ .set_theme = i });
            kit.say(w, "tema {s}\n", &.{ kit.arg(rest) }) catch {};
        } else kit.say(w, "tema desconhecido: {s}\n", &.{ kit.arg(rest) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "open")) {
        const id = std.fmt.parseInt(u64, rest, 10) catch {
            w.writeAll("open precisa do id do canal\n") catch {};
            return .pronto;
        };
        if (app.store.channel(id) == null) {
            kit.say(w, "canal {d} não está carregado\n", &.{ kit.arg(id) }) catch {};
            return .pronto;
        }
        app.openChannel(id, false);
        kit.say(w, "aberto {d}\n", &.{ kit.arg(id) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "shot")) {
        if (rest.len == 0 or rest.len >= shot_path.len) {
            w.writeAll("shot precisa de um arquivo .png\n") catch {};
            return .pronto;
        }
        @memcpy(shot_path[0..rest.len], rest);
        shot_path_len = rest.len;
        shot_result = .nada;
        app.gate.redraw();
        kit.say(w, "print em {s} no próximo quadro\n", &.{ kit.arg(rest) }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "record")) {
        const on = !eq(u8, rest, "off");
        ui.gravar_fechado = on;
        reg.gravar(on or ui.aberto());
        kit.say(w, "gravando: {s}\n", &.{ kit.arg(if (reg.gravando()) "sim" else "não") }) catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "clear")) {
        if (rest.len == 0 or eq(u8, rest, "net")) reg.net.clear();
        if (rest.len == 0 or eq(u8, rest, "gw")) reg.gw.clear();
        if (rest.len == 0 or eq(u8, rest, "log")) reg.lines.clear();
        if (rest.len == 0 or eq(u8, rest, "ev")) reg.evs.clear();
        w.writeAll("limpo\n") catch {};
        return .pronto;
    }
    if (eq(u8, cmd, "inspector")) {
        if (eq(u8, rest, "open")) ui.open() else if (eq(u8, rest, "close")) ui.close() else if (std.meta.stringToEnum(ui.Aba, rest)) |a| {
            ui.open();
            ui.aba = a;
        } else {
            w.writeAll("inspector open, close ou uma aba (elementos, console, rede, gateway, eventos, desempenho, estado)\n") catch {};
            return .pronto;
        }
        w.writeAll("ok\n") catch {};
        return .pronto;
    }
    kit.say(w, "comando desconhecido: {s} (veja help)\n", &.{ kit.arg(cmd) }) catch {};
    return .pronto;
}

/// Um quadro gravado recente (do último segundo, mais ou menos): o de agora, não um velho
/// de quando o Inspetor estava aberto.
fn frameFresh() ?*const cap.Frame {
    const f = cap.last() orelse return null;
    if (!ui.wantsCapture() and ui.quadros_pedidos == 0) return null;
    if (ui.quadros_pedidos > 1) return null;
    return f;
}

fn podeMexer(app: *App, origem: Origem, w: *std.Io.Writer) bool {
    if (origem == .console or app.store.demo or ctl_mexe) return true;
    w.writeAll("pelo ctl, clicar e digitar só na demonstração ou com \"Deixar o ctl clicar e digitar\" ligado no Console do Inspetor\n") catch {};
    return false;
}

fn find(f: *const cap.Frame, q: []const u8, w: *std.Io.Writer) Fim {
    var n: usize = 0;
    for (f.els.items, 0..) |*e, i| {
        if (!cap.visible(e) or e.kind == .window) continue;
        var db: [200]u8 = undefined;
        const desc = @import("aba_elementos.zig").describe(f, i, &db);
        const mk = f.markFor(e.rect) orelse "";
        if (!(kit.has(f.str(e.str), q) or kit.has(desc, q) or kit.has(mk, q))) continue;
        elLine(w, f, i);
        n += 1;
        if (n >= 200) {
            w.writeAll("… (mais de 200)\n") catch {};
            break;
        }
    }
    if (n == 0) kit.say(w, "nada com \"{s}\"\n", &.{ kit.arg(q) }) catch {};
    return .pronto;
}

fn tree(f: *const cap.Frame, only: []const u8, w: *std.Io.Writer) Fim {
    for (f.scopes.items[1..], 1..) |*s, si| {
        if (only.len > 0 and !std.mem.eql(u8, s.name, only)) continue;
        for (0..s.depth) |_| w.writeAll("  ") catch {};
        kit.say(w, "<{s}> {d:.0},{d:.0} {d:.0}×{d:.0}", &.{ kit.arg(s.name), kit.arg(s.rect.x), kit.arg(s.rect.y), kit.arg(s.rect.w), kit.arg(s.rect.h) }) catch {};
        if (s.line > 0) kit.say(w, " :{d}", &.{ kit.arg(s.line) }) catch {};
        if (s.us > 0) kit.say(w, " {d}µs", &.{ kit.arg(s.us) }) catch {};
        w.writeAll("\n") catch {};
        // Com um componente pedido, o que ele desenhou também.
        if (only.len == 0) continue;
        for (f.els.items, 0..) |*e, i| if (e.scope == si and cap.visible(e)) {
            for (0..s.depth + 1) |_| w.writeAll("  ") catch {};
            elLine(w, f, i);
        };
    }
    return .pronto;
}

/// "filtro n" ou "n" ou "filtro": o filtro e quantas linhas (padrão 30).
fn args(rest: []const u8) struct { q: []const u8, n: usize } {
    var q = rest;
    var n: usize = 30;
    if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |sp| {
        if (std.fmt.parseInt(usize, rest[sp + 1 ..], 10)) |v| {
            n = v;
            q = std.mem.trim(u8, rest[0..sp], " ");
        } else |_| {}
    } else if (std.fmt.parseInt(usize, rest, 10)) |v| {
        n = v;
        q = "";
    } else |_| {}
    return .{ .q = q, .n = @min(n, 2000) };
}

const Coleta = struct { ids: std.ArrayList(u32) = .empty, q: []const u8, hb: bool = false };

fn listNet(rest: []const u8, w: *std.Io.Writer) Fim {
    const a = args(rest);
    var col: Coleta = .{ .q = a.q };
    defer col.ids.deinit(std.heap.c_allocator);
    reg.net.each(&col, struct {
        fn f(cc: *Coleta, n: *const reg.Net) void {
            if (cc.q.len > 0 and !kit.has(n.url, cc.q) and !kit.has(n.methodStr(), cc.q)) return;
            cc.ids.append(std.heap.c_allocator, n.id) catch {};
        }
    }.f);
    const from = col.ids.items.len -| a.n;
    for (col.ids.items[from..]) |id| {
        var n: reg.Net = .{};
        if (!reg.net.copy(id, &n)) continue;
        defer reg.NetLog.freeCopy(&n);
        var tb: [16]u8 = undefined;
        var db: [24]u8 = undefined;
        var sb: [24]u8 = undefined;
        kit.say(w, "{s}  {s} {s}  {s}  {s}  {s}  {s}", &.{ kit.arg(kit.clock(&tb, n.started_ms)), kit.arg(n.methodStr()), kit.arg(n.url), kit.arg(if (n.pending) "pendente" else if (n.failed) "falhou" else kit.bufSay(&sb, "{d}", &.{ kit.arg(n.status) }) orelse ""), kit.arg(kit.durText(&db, n.dur_us)), kit.arg(@tagName(n.kind)), kit.arg(n.noteStr()) }) catch {};
        if (n.waited_ms > 0) kit.say(w, "  esperou {d} ms", &.{ kit.arg(n.waited_ms) }) catch {};
        w.writeAll("\n") catch {};
    }
    if (col.ids.items.len == 0) w.writeAll(if (reg.gravando()) "nenhum pedido gravado\n" else "a gravação está desligada (record on)\n") catch {};
    return .pronto;
}

fn listGw(rest: []const u8, w: *std.Io.Writer) Fim {
    const a = args(rest);
    var col: Coleta = .{ .q = a.q, .hb = std.mem.indexOf(u8, a.q, "hb") != null };
    if (col.hb) col.q = "";
    defer col.ids.deinit(std.heap.c_allocator);
    reg.gw.each(&col, struct {
        fn f(cc: *Coleta, g: *const reg.Gw) void {
            if (!cc.hb and g.conn == .main and (g.op == 1 or g.op == 11)) return;
            if (cc.q.len > 0) {
                var nb: [48]u8 = undefined;
                if (!kit.has(g.name(), cc.q) and !kit.has(@import("aba_gateway.zig").opName(g, &nb), cc.q)) return;
            }
            cc.ids.append(std.heap.c_allocator, g.id) catch {};
        }
    }.f);
    const from = col.ids.items.len -| a.n;
    const Ctx = struct { w: *std.Io.Writer, want: []const u32 };
    var ctx: Ctx = .{ .w = w, .want = col.ids.items[from..] };
    reg.gw.each(&ctx, struct {
        fn f(cc: *Ctx, g: *const reg.Gw) void {
            if (std.mem.indexOfScalar(u32, cc.want, g.id) == null) return;
            var tb: [16]u8 = undefined;
            var nb: [48]u8 = undefined;
            kit.say(cc.w, "{s}  {s} {s}  {s}  {d} B  {s}\n", &.{ kit.arg(kit.clock(&tb, g.time_ms)), kit.arg(if (g.dir == .out) "↑" else "↓"), kit.arg(@tagName(g.conn)), kit.arg(@import("aba_gateway.zig").opName(g, &nb)), kit.arg(g.size), kit.arg(g.payload[0..@min(g.payload.len, 160)]) }) catch {};
        }
    }.f);
    if (col.ids.items.len == 0) w.writeAll("nenhum quadro gravado\n") catch {};
    return .pronto;
}

fn listLog(rest: []const u8, w: *std.Io.Writer) Fim {
    const a = args(rest);
    const Ctx = struct { w: *std.Io.Writer, q: []const u8, skip: usize, n: usize = 0 };
    // Duas passadas: contar o que bate, depois escrever só os últimos `n`.
    var count: Ctx = .{ .w = w, .q = a.q, .skip = 0 };
    reg.lines.each(&count, struct {
        fn f(cc: *Ctx, l: *const reg.Line) void {
            if (cc.q.len == 0 or kit.has(l.text, cc.q) or kit.has(l.scopeStr(), cc.q)) cc.n += 1;
        }
    }.f);
    var out: Ctx = .{ .w = w, .q = a.q, .skip = count.n -| a.n };
    reg.lines.each(&out, struct {
        fn f(cc: *Ctx, l: *const reg.Line) void {
            if (!(cc.q.len == 0 or kit.has(l.text, cc.q) or kit.has(l.scopeStr(), cc.q))) return;
            cc.n += 1;
            if (cc.n <= cc.skip) return;
            var tb: [16]u8 = undefined;
            kit.say(cc.w, "{s}  {s}  {s}\n", &.{ kit.arg(kit.clock(&tb, l.time_ms)), kit.arg(@tagName(l.level)), kit.arg(l.text) }) catch {};
        }
    }.f);
    if (count.n == 0) w.writeAll("nenhuma linha\n") catch {};
    return .pronto;
}

fn listEv(rest: []const u8, w: *std.Io.Writer) Fim {
    const a = args(rest);
    const Ctx = struct { w: *std.Io.Writer, q: []const u8, skip: usize, n: usize = 0 };
    var count: Ctx = .{ .w = w, .q = a.q, .skip = 0 };
    reg.evs.each(&count, struct {
        fn f(cc: *Ctx, e: *const reg.Ev) void {
            if (cc.q.len == 0 or kit.has(e.tag, cc.q) or kit.has(e.text, cc.q)) cc.n += 1;
        }
    }.f);
    var out: Ctx = .{ .w = w, .q = a.q, .skip = count.n -| a.n };
    reg.evs.each(&out, struct {
        fn f(cc: *Ctx, e: *const reg.Ev) void {
            if (!(cc.q.len == 0 or kit.has(e.tag, cc.q) or kit.has(e.text, cc.q))) return;
            cc.n += 1;
            if (cc.n <= cc.skip) return;
            var tb: [16]u8 = undefined;
            kit.say(cc.w, "{s}  {s}  {s}  {s}\n", &.{ kit.arg(kit.clock(&tb, e.time_ms)), kit.arg(@tagName(e.kind)), kit.arg(e.tag), kit.arg(e.text) }) catch {};
        }
    }.f);
    if (count.n == 0) w.writeAll("nenhum evento\n") catch {};
    return .pronto;
}

const Tecla = struct { key: c.ImGuiKey, mods: c_int };

fn parseKey(s: []const u8) ?Tecla {
    var mods: c_int = 0;
    var key: c.ImGuiKey = c.ImGuiKey_None;
    var it = std.mem.tokenizeScalar(u8, s, '+');
    while (it.next()) |raw| {
        var lb: [16]u8 = undefined;
        if (raw.len > lb.len) return null;
        const p = std.ascii.lowerString(&lb, raw);
        if (std.mem.eql(u8, p, "ctrl")) {
            mods |= c.ImGuiMod_Ctrl;
        } else if (std.mem.eql(u8, p, "shift")) {
            mods |= c.ImGuiMod_Shift;
        } else if (std.mem.eql(u8, p, "alt")) {
            mods |= c.ImGuiMod_Alt;
        } else key = keyName(p) orelse return null;
    }
    if (key == c.ImGuiKey_None) return null;
    return .{ .key = key, .mods = mods };
}

fn keyName(p: []const u8) ?c.ImGuiKey {
    const named = [_]struct { n: []const u8, k: c.ImGuiKey }{
        .{ .n = "enter", .k = c.ImGuiKey_Enter },     .{ .n = "esc", .k = c.ImGuiKey_Escape },
        .{ .n = "escape", .k = c.ImGuiKey_Escape },   .{ .n = "tab", .k = c.ImGuiKey_Tab },
        .{ .n = "space", .k = c.ImGuiKey_Space },     .{ .n = "backspace", .k = c.ImGuiKey_Backspace },
        .{ .n = "delete", .k = c.ImGuiKey_Delete },   .{ .n = "up", .k = c.ImGuiKey_UpArrow },
        .{ .n = "down", .k = c.ImGuiKey_DownArrow },  .{ .n = "left", .k = c.ImGuiKey_LeftArrow },
        .{ .n = "right", .k = c.ImGuiKey_RightArrow }, .{ .n = "home", .k = c.ImGuiKey_Home },
        .{ .n = "end", .k = c.ImGuiKey_End },         .{ .n = "pageup", .k = c.ImGuiKey_PageUp },
        .{ .n = "pagedown", .k = c.ImGuiKey_PageDown }, .{ .n = ",", .k = c.ImGuiKey_Comma },
    };
    for (named) |x| if (std.mem.eql(u8, p, x.n)) return x.k;
    if (p.len == 1 and p[0] >= 'a' and p[0] <= 'z') return c.ImGuiKey_A + @as(c.ImGuiKey, p[0] - 'a');
    if (p.len == 1 and p[0] >= '0' and p[0] <= '9') return c.ImGuiKey_0 + @as(c.ImGuiKey, p[0] - '0');
    if (p.len >= 2 and p[0] == 'f') {
        const n = std.fmt.parseInt(u8, p[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return c.ImGuiKey_F1 + @as(c.ImGuiKey, n - 1);
    }
    return null;
}
