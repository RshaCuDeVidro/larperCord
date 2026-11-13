//! "Apagar todos os dados" (Configurações → Avançado): o que o --purge do install.sh
//! e o -Purge do install.ps1 apagam, sem desinstalar o programa. Saem as duas pastas
//! do larperCord, a das configurações e a do cache (~/.config/larpercord e
//! ~/.cache/larpercord, ou as do XDG; no Windows %APPDATA%\larpercord e
//! %LOCALAPPDATA%\larpercord), com tudo dentro: configurações, temas, mascotes, sons,
//! plugins, rascunhos, mensagens salvas, o cache das conversas, o FFmpeg baixado e
//! os registros. As contas salvas saem também do chaveiro (secret-tool, os serviços
//! larpercord-account e o antigo larpercord) ou do Gerenciador de Credenciais
//! (larperCord/account/*), e o arquivo do token antigo, ~/.config/larpercord/token.
//!
//! Para valer, nada pode gravar de novo depois. `comecar` desliga o registro de
//! depuração e fecha a porta de quem grava (`on`, conferido em platform/fsutil.zig e
//! no download do FFmpeg), e o app sai sem salvar nada. `terminar` passa de novo
//! depois do encerramento, sem nenhuma thread de pé. No Windows, o que o processo
//! ainda segura (as DLLs do FFmpeg carregadas) sai por uma cópia do programa que
//! espera este processo acabar (`resto`).
//!
//! Um atalho lá dentro (um link para outra pasta) sai sozinho: nunca o que ele aponta.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const sys = @import("sys.zig");

const windows = builtin.os.tag == .windows;
/// Mais fundo que isso é um laço de pastas (ou algo que não é nosso).
const max_depth = 24;

var ativo: std.atomic.Value(bool) = .init(false);
/// QA: só apaga dentro de QA_APAGAR_RAIZ, e o chaveiro fica como está.
var qa_mode = false;
/// A segunda passada: 0 ainda não, 1 passando (o main ou o vigia), 2 feita.
var fim: std.atomic.Value(u8) = .init(0);

/// Os dados estão sendo apagados: ninguém grava mais nada.
pub fn on() bool {
    return ativo.load(.acquire);
}

/// As duas pastas do larperCord (a das configurações e a do cache).
pub const Pastas = struct {
    buf: [2][520]u8 = undefined,
    len: [2]usize = .{ 0, 0 },

    pub fn get(p: *const Pastas, i: usize) ?[:0]const u8 {
        if (p.len[i] == 0) return null;
        return p.buf[i][0..p.len[i] :0];
    }
};

pub fn pastas(out: *Pastas) void {
    var hb: [512]u8 = undefined;
    if (sys.configHome(&hb)) |base| put(out, 0, base);
    if (sys.cacheHome(&hb)) |base| put(out, 1, base);
}

fn put(out: *Pastas, i: usize, base: []const u8) void {
    // Só caminho absoluto: um XDG_CONFIG_HOME relativo apagaria a partir da pasta atual.
    if (!absolute(base)) return;
    const p = std.fmt.bufPrintSentinel(&out.buf[i], "{s}/larpercord", .{base}, 0) catch return;
    out.len[i] = p.len;
}

fn absolute(p: []const u8) bool {
    if (windows) return (p.len >= 3 and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) or std.mem.startsWith(u8, p, "\\\\");
    return p.len > 1 and p[0] == '/';
}

/// O botão foi confirmado e o laço do app parou: daqui em diante nada grava. Apaga o
/// chaveiro e as pastas uma primeira vez, antes do resto do encerramento.
pub fn comecar(qa: bool) void {
    if (sys.web) return;
    qa_mode = qa;
    ativo.store(true, .release);
    @import("debug_log.zig").set(false);
    chaveiro();
    _ = passar();
}

/// Depois do encerramento (as threads já pararam e os arquivos fecharam): passa de novo.
pub fn terminar() void {
    if (!on() or fim.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    acabar();
}

/// O vigia de main.zig vai encerrar o processo: o que o main não chegou a apagar sai
/// agora; se ele já está apagando, espera (até 10 s).
pub fn noVigia() void {
    if (!on()) return;
    if (fim.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) return acabar();
    var i: u32 = 0;
    while (fim.load(.acquire) == 1 and i < 100) : (i += 1) c.SDL_Delay(100);
}

fn acabar() void {
    defer fim.store(2, .release);
    if (passar()) {
        std.log.info("apagar: pastas e contas salvas apagadas", .{});
        return;
    }
    // Linux e macOS apagam até arquivo aberto: o que sobrou lá não tem como sair.
    if (windows and !qa_mode) chamarResto() else std.log.warn("apagar: sobrou algo nas pastas do larperCord", .{});
}

/// Apaga as pastas. Diz se não sobrou nada.
fn passar() bool {
    var ps: Pastas = .{};
    pastas(&ps);
    var ok = true;
    for (0..2) |i| {
        const p = ps.get(i) orelse continue;
        if (!permitida(p)) continue;
        removeTree(p, 0);
        if (sys.exists(p.ptr)) ok = false;
    }
    if (!windows) tokenAntigo(ps.get(0));
    return ok;
}

/// No QA, só o que está dentro de QA_APAGAR_RAIZ (as pastas de mentira da bateria):
/// rodar o QA sem o ambiente isolado nunca apaga as pastas de quem roda.
fn permitida(p: [:0]const u8) bool {
    if (!qa_mode) return true;
    const env: []const u8 = if (c.SDL_getenv("QA_APAGAR_RAIZ")) |v| std.mem.span(v) else "";
    const raiz = std.mem.trimEnd(u8, env, "/\\");
    const dentro = absolute(raiz) and raiz.len < p.len and std.mem.startsWith(u8, p, raiz) and (p[raiz.len] == '/' or p[raiz.len] == '\\');
    if (!dentro) std.log.warn("apagar: no QA, só dentro de QA_APAGAR_RAIZ; {s} fica", .{p});
    return dentro;
}

/// O token de antes das várias contas ficava sempre em ~/.config/larpercord/token,
/// mesmo com outro XDG_CONFIG_HOME (net/discord.zig). A pasta sai se ficou vazia.
fn tokenAntigo(config: ?[:0]const u8) void {
    const home = std.mem.span(c.SDL_getenv("HOME") orelse return);
    var db: [520]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&db, "{s}/.config/larpercord", .{home}, 0) catch return;
    if (config) |cfg| if (std.mem.eql(u8, cfg, dir)) return;
    if (!permitida(dir)) return;
    var fb: [540]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&fb, "{s}/token", .{dir}, 0) catch return;
    _ = c.unlink(file.ptr);
    _ = c.rmdir(dir.ptr);
}

/// As contas salvas no chaveiro do sistema. No QA nada roda (o chaveiro seria o de
/// quem roda): só diz o que rodaria.
fn chaveiro() void {
    if (windows) {
        if (qa_mode) return std.log.info("apagar: no QA o Gerenciador de Credenciais fica (larperCord/account/*)", .{});
        var count: c.DWORD = 0;
        var list: [*c]c.PCREDENTIALA = null;
        if (c.CredEnumerateA("larperCord/account/*", 0, &count, &list) == 0) return;
        defer c.CredFree(@ptrCast(list));
        for (0..count) |i| _ = c.CredDeleteA(list[i].*.TargetName, list[i].*.Type, 0);
        return;
    }
    // Uma entrada por conta, e a de antes das várias contas (net/accounts_store.zig).
    const cmds = [_][:0]const u8{
        "secret-tool clear service larpercord-account 2>/dev/null",
        "secret-tool clear service larpercord 2>/dev/null",
    };
    for (cmds) |cmd| {
        if (qa_mode) {
            std.log.info("apagar: no QA o chaveiro fica ({s})", .{cmd});
            continue;
        }
        if (c.popen(cmd.ptr, "r")) |f| _ = c.pclose(f);
    }
}

/// Apaga `path` e tudo dentro. Um link (para arquivo ou pasta) sai sozinho.
fn removeTree(path: [:0]const u8, depth: u8) void {
    if (windows) return removeTreeWin(path, depth);
    var st: c.struct_stat = undefined;
    if (c.lstat(path.ptr, &st) != 0) return;
    if (st.st_mode & c.S_IFMT != c.S_IFDIR) {
        _ = c.unlink(path.ptr);
        return;
    }
    if (depth < max_depth) if (c.opendir(path.ptr)) |dir| {
        defer _ = c.closedir(dir);
        while (c.readdir(dir)) |e| {
            const name = std.mem.sliceTo(&e.*.d_name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var b: [1024]u8 = undefined;
            const sub = std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ path, name }, 0) catch continue;
            removeTree(sub, depth + 1);
        }
    };
    _ = c.rmdir(path.ptr);
}

fn removeTreeWin(path: [:0]const u8, depth: u8) void {
    if (!windows) return;
    const attr = c.GetFileAttributesA(path.ptr);
    if (attr == 0xFFFFFFFF) return;
    // Só leitura: o Windows não deixa apagar.
    if (attr & c.FILE_ATTRIBUTE_READONLY != 0) _ = c.SetFileAttributesA(path.ptr, attr & ~@as(c.DWORD, c.FILE_ATTRIBUTE_READONLY));
    if (attr & c.FILE_ATTRIBUTE_DIRECTORY == 0) {
        _ = c.DeleteFileA(path.ptr);
        return;
    }
    // Junção ou link de pasta: sai o link, sem entrar nele.
    if (attr & c.FILE_ATTRIBUTE_REPARSE_POINT == 0 and depth < max_depth) {
        var pb: [1024]u8 = undefined;
        const pattern = std.fmt.bufPrintSentinel(&pb, "{s}\\*", .{path}, 0) catch return;
        var fd: c.WIN32_FIND_DATAA = undefined;
        const h = c.FindFirstFileA(pattern.ptr, &fd);
        if (h != c.INVALID_HANDLE_VALUE) {
            defer _ = c.FindClose(h);
            while (true) {
                const name = std.mem.sliceTo(&fd.cFileName, 0);
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                    var b: [1024]u8 = undefined;
                    if (std.fmt.bufPrintSentinel(&b, "{s}\\{s}", .{ path, name }, 0)) |sub| removeTreeWin(sub, depth + 1) else |_| {}
                }
                if (c.FindNextFileA(h, &fd) == 0) break;
            }
        }
    }
    _ = c.RemoveDirectoryA(path.ptr);
}

/// Windows: uma cópia do programa espera este processo acabar e apaga o que ele segurava.
fn chamarResto() void {
    if (!windows) return;
    var eb: [1024]u8 = undefined;
    const n = c.GetModuleFileNameA(null, &eb, eb.len);
    if (n == 0 or n >= eb.len) return;
    eb[n] = 0;
    var pb: [16]u8 = undefined;
    const pid = std.fmt.bufPrintSentinel(&pb, "{d}", .{c.GetCurrentProcessId()}, 0) catch return;
    const flag: [:0]const u8 = "--apagar-resto";
    var argv = [_:null]?[*:0]const u8{ eb[0..n :0].ptr, flag.ptr, pid.ptr };
    if (c.SDL_CreateProcess(@ptrCast(&argv), false)) |p| c.SDL_DestroyProcess(p);
    std.log.info("apagar: o resto sai depois que o app fechar", .{});
}

/// `larpercord --apagar-resto PID` (só o próprio app chama, ver `chamarResto`): espera o
/// processo PID acabar e apaga as pastas, tentando de novo por uns segundos.
pub fn resto(pid: u32) void {
    if (sys.web) return;
    if (windows) {
        if (c.OpenProcess(c.SYNCHRONIZE, 0, pid)) |h| {
            _ = c.WaitForSingleObject(h, 30_000);
            _ = c.CloseHandle(h);
        }
    } else {
        var i: u32 = 0;
        while (i < 300 and c.kill(@intCast(pid), 0) == 0) : (i += 1) c.SDL_Delay(100);
    }
    var tries: u32 = 0;
    while (!passar() and tries < 20) : (tries += 1) c.SDL_Delay(500);
}
