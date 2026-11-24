//! A conta grande (QA_SUITE=conta-grande, tools/ram_conta_grande.sh): o net/discord.zig de
//! verdade contra o Discord de mentira com 52 servidores e ~2.450 canais
//! (tools/conta_grande.py), usado por uns minutos como uma pessoa usaria: o servidor maior
//! com a lista de membros e o histórico rolado para cima, vinte servidores, quinze DMs, a
//! página de Desempenho e um tempo parado com o tráfego de fundo (presenças, mensagens,
//! digitando). A cada fase a RAM sai no log por parte (`ram[fase] ...`, app_memoria.zig):
//! é o que o tools/ram_conta_grande.sh junta numa tabela.
const std = @import("std");
const c = @import("c");
const App = @import("app.zig").App;
const R = @import("qa_runner.zig");
const Op = R.Op;
const types = @import("core/types.zig");
const memoria = @import("app_memoria.zig");
const settings = @import("ui/settings.zig");
const Id = types.Id;

fn s(name: []const u8) Op {
    return .{ .section = name };
}
fn expectT(name: []const u8, f: *const fn (*App) bool, ms: u32) Op {
    return .{ .expect = .{ .name = name, .check = f, .timeout_ms = ms } };
}

fn pronto(app: *App) bool {
    return app.store.ready and !app.store.demo and app.store.connection == .ready and
        app.store.guilds.items.len >= 52 and app.store.channels.count() >= 2400;
}

/// O suplementar chegou: as presenças (com jogo, música, status) dos servidores e dos amigos
/// estão no Store.
fn suplementar(app: *App) bool {
    return app.store.activities.count() > 100;
}

fn ram(comptime rotulo: []const u8) Op {
    return .{ .run = struct {
        fn f(app: *App) void {
            memoria.logar(app, rotulo);
        }
    }.f };
}

/// O canal de texto número `k` (entre os que dá para abrir) do servidor da vez.
fn textoDe(app: *App, gid: Id, k: usize) ?Id {
    const list = app.store.guild_channels.get(gid) orelse return null;
    var n: usize = 0;
    for (list.items) |cid| {
        const cs = app.store.channel(cid) orelse continue;
        if (cs.info.kind != .text or !app.store.canAccess(&cs.info)) continue;
        if (n == k) return cid;
        n += 1;
    }
    return null;
}

var alvo: Id = 0;

/// Abre o servidor `i` (na ordem do Store) e o canal de texto `k` dele, pelas mesmas ações
/// do clique na barra e na lista de canais.
fn abrir(comptime i: usize, comptime k: usize) Op {
    return .{ .run = struct {
        fn f(app: *App) void {
            const gs = app.store.guilds.items;
            if (gs.len == 0) return;
            const gid = gs[i % gs.len].id;
            app.actions.append(app.gpa, .{ .select_guild = gid }) catch {};
            alvo = textoDe(app, gid, k) orelse 0;
            if (alvo != 0) app.actions.append(app.gpa, .{ .select_channel = alvo }) catch {};
        }
    }.f };
}

fn historico(app: *App) bool {
    if (alvo == 0) return true;
    const cs = app.store.channel(alvo) orelse return false;
    return app.st.activeChannel() == alvo and cs.history == .loaded and cs.messages.items.len > 0;
}

/// A DM `k` da lista (a mais recente primeiro), pelo mesmo caminho do clique.
fn dm(comptime k: usize) Op {
    return .{ .run = struct {
        fn f(app: *App) void {
            app.actions.append(app.gpa, .{ .select_guild = 0 }) catch {};
            var n: usize = 0;
            alvo = 0;
            var it = app.store.channels.valueIterator();
            var lista: [400]Id = undefined;
            var total: usize = 0;
            while (it.next()) |p| {
                const cs = p.*;
                if (cs.info.guild != 0 or cs.info.kind != .text or cs.info.last_message == 0) continue;
                if (total < lista.len) {
                    lista[total] = cs.info.id;
                    total += 1;
                }
            }
            std.mem.sort(Id, lista[0..total], {}, std.sort.desc(Id));
            for (lista[0..total]) |id| {
                if (n == k) {
                    alvo = id;
                    break;
                }
                n += 1;
            }
            if (alvo != 0) app.actions.append(app.gpa, .{ .select_channel = alvo }) catch {};
        }
    }.f };
}

/// Rola a conversa para cima como a roda do mouse (o app pede a página mais antiga no topo).
fn rolarCima(app: *App) void {
    const io = app.io;
    c.ImGuiIO_AddMousePosEvent(io, io.*.DisplaySize.x * 0.6, io.*.DisplaySize.y * 0.5);
    c.ImGuiIO_AddMouseWheelEvent(io, 0, 25);
}

fn abrirDesempenho(app: *App) void {
    app.st.settings.open = true;
    app.st.settings.page = .desempenho;
}

fn escala125(app: *App) void {
    app.st.settings.ui_scale = 1.25;
}
fn escala100(app: *App) void {
    app.st.settings.ui_scale = 1;
}
fn escalaAplicada(app: *App) bool {
    return app.ui_size == 1.25;
}

/// Desce a página de Configurações até a divisão da RAM (para o print).
fn rolarPagina(app: *App) void {
    const io = app.io;
    c.ImGuiIO_AddMousePosEvent(io, io.*.DisplaySize.x * 0.6, io.*.DisplaySize.y * 0.5);
    c.ImGuiIO_AddMouseWheelEvent(io, 0, -9);
}

var antes: usize = 0;
fn guardaQuantas(app: *App) void {
    const cs = app.store.channel(alvo) orelse return;
    antes = cs.messages.items.len;
}
fn maisAntigas(app: *App) bool {
    const cs = app.store.channel(alvo) orelse return false;
    return cs.messages.items.len > antes;
}

fn rolagem() [4]Op {
    return .{ .{ .run = guardaQuantas }, .{ .run = rolarCima }, .{ .wait = 700 }, .{ .run = rolarCima } };
}

fn vinteServidores() [20 * 4]Op {
    var out: [20 * 4]Op = undefined;
    for (0..20) |i| {
        out[i * 4 + 0] = abrir(i + 1, i % 2);
        out[i * 4 + 1] = .{ .wait = 400 };
        out[i * 4 + 2] = expectT("o canal abre com o histórico", historico, 10000);
        out[i * 4 + 3] = .{ .wait = 900 };
    }
    return out;
}

fn quinzeDms() [15 * 3]Op {
    var out: [15 * 3]Op = undefined;
    for (0..15) |i| {
        out[i * 3 + 0] = dm(i);
        out[i * 3 + 1] = expectT("a DM abre com o histórico", historico, 10000);
        out[i * 3 + 2] = .{ .wait = 600 };
    }
    return out;
}

fn desempenhoMostrado(app: *App) bool {
    const pt = settings.mem_partes_vistas;
    return settings.mem_use.n_channels >= 2400 and app.stats.frames_built > 0 and
        pt.total_kb > 0 and pt.soma() == pt.total_kb and pt.heapUsado() > 0;
}

pub const ops = [_]Op{
    s("conta grande: conectar"),
    expectT("READY da conta grande: 52 servidores e ~2.450 canais no Store", pronto, 30000),
    ram("READY"),
    expectT("o READY_SUPPLEMENTAL chega (presenças e membros)", suplementar, 15000),
    .{ .wait = 3000 },
    ram("READY + 3 s"),

    s("conta grande: o servidor maior"),
    abrir(0, 0),
    expectT("o canal abre com o histórico", historico, 10000),
    .{ .wait = 1500 },
} ++ rolagem() ++ [_]Op{
    .{ .wait = 1200 },
} ++ rolagem() ++ [_]Op{
    .{ .wait = 1200 },
} ++ rolagem() ++ [_]Op{
    expectT("rolar para cima traz as mensagens mais antigas", maisAntigas, 10000),
    .{ .wait = 1500 },
    ram("servidor maior"),

    s("conta grande: vinte servidores"),
} ++ vinteServidores() ++ [_]Op{
    ram("20 servidores"),

    s("conta grande: quinze DMs"),
} ++ quinzeDms() ++ [_]Op{
    ram("15 DMs"),

    s("conta grande: Desempenho"),
    // Pela página e não pelo nome na lista: a bateria também roda em outro idioma (--lang).
    .{ .run = abrirDesempenho },
    .{ .wait = 400 },
    expectT("a página de Desempenho mostra a conta grande, com as partes da RAM somando o total", desempenhoMostrado, 8000),
    .{ .wait = 2500 },
    .{ .run = rolarPagina },
    .{ .wait = 600 },
    .{ .shot = "conta-grande-desempenho" },
    // A mesma página com a interface em 125% (e no idioma que a bateria rodar, --lang).
    .{ .run = escala125 },
    expectT("a interface vai a 125%", escalaAplicada, 4000),
    .{ .run = rolarPagina },
    .{ .wait = 800 },
    expectT("a 125%, as partes continuam somando o total", desempenhoMostrado, 4000),
    .{ .shot = "conta-grande-desempenho-125" },
    .{ .run = escala100 },
    .{ .wait = 400 },
    .{ .key = .{ .key = c.ImGuiKey_Escape } },
    .{ .wait = 400 },

    s("conta grande: parado, com o tráfego de fundo"),
    abrir(0, 0),
    expectT("de volta ao servidor maior", historico, 10000),
    .{ .wait = 20000 },
    ram("parado 20 s"),
    .{ .wait = 20000 },
    ram("parado 40 s"),
    .{ .wait = 20000 },
    ram("parado 60 s"),
};
