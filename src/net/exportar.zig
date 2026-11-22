//! Exportar uma conversa e salvar mídia no disco, em threads: a interface
//! (ui/exportar.zig) monta o retrato do que exportar, escolhe o arquivo e só
//! acompanha o andamento; a conversa grande não trava a tela, e o documento vai
//! para o disco aos pedaços (a memória não cresce com o tamanho do arquivo).
//!
//! REGRAS DA CONTA (não "melhore" isto num raspador; a conta de quem usa já foi
//! desativada pelo Discord por "atividade suspeita", e um robô de histórico é
//! exatamente o que eles procuram):
//!  - A exportação NÃO faz nenhum pedido ao Discord: nem à API, nem pelo gateway,
//!    nem à CDN. Só usa o que já está no computador: as mensagens na memória (o
//!    Store), o cache em disco (net/msg_cache.zig) e os arquivos que o app já
//!    tinha baixado. Nada de paginar o histórico sozinho, buscar membros, perfis,
//!    anexos ou o que for. Quem quer mais mensagens rola a conversa para cima, do
//!    jeito de sempre, antes de exportar (a janela de exportar diz isso).
//!  - Este arquivo não conhece o gateway (nem net/discord.zig nem o falso): não
//!    tem como mandar comando. A parte da exportação (entre "Exportar" e "Salvar",
//!    abaixo) nem chama o download: o teste em src/tests.zig confere os dois, e o
//!    QA conta os comandos do gateway falso e os downloads de mídia antes e
//!    depois de exportar (qa_exportar.zig).
//!  - Mídia é opcional e vem desligada. Ligada, vai para a pasta ao lado só o que
//!    já está no computador (as fotos de perfil e imagens que o app já baixou, a
//!    demonstração); o resto fica como link para o original.
//!  - Salvar uma imagem ou um vídeo é outra coisa: um arquivo, pelo clique de quem
//!    usa. Aí sim o original vem da CDN, SEM o cabeçalho Authorization (o `fetch`
//!    das imagens nunca põe: a CDN não pede), pelos mesmos domínios permitidos e
//!    pelo proxy das Configurações. discord.com/api, nunca (core/salvar.zig
//!    `safeMediaUrl` recusa antes de qualquer pedido).
const std = @import("std");
const c = @import("c");
const exportar = @import("../core/exportar.zig");
const salvar = @import("../core/salvar.zig");
const images = @import("../ui/images.zig");
const media_url = @import("media_url.zig");

const alloc = std.heap.c_allocator;

/// O QA troca o download de verdade do "Salvar" por um de mentira (conta quantos e
/// se algum endereço foi para a API).
pub var fetch_hook: ?*const fn (url: [:0]const u8, sink: images.Sink, stop: *std.atomic.Value(bool)) bool = null;

/// O que já está no computador (preenchido pela interface): a imagem pequena que
/// as imagens já baixaram do CDN, as da demonstração, um arquivo nosso.
pub var local_hook: ?*const fn (url: []const u8, out: *std.ArrayList(u8)) bool = null;

/// Maior arquivo que o "Salvar" baixa sozinho (o Discord com Nitro aceita 500 MB).
pub const max_save_bytes: u64 = 500 * 1024 * 1024;

/// Baixa `url` para `sink`: o de mentira do QA ou o `fetch` das imagens (domínios
/// permitidos, redirecionamentos conferidos, proxy, sem Authorization).
fn download(curl: *?*c.CURL, url: []const u8, sink: images.Sink, stop: *std.atomic.Value(bool)) bool {
    if (!salvar.safeMediaUrl(url)) return false;
    var zb: [2048]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{url}, 0) catch return false;
    if (fetch_hook) |h| return h(z, sink, stop);
    return images.fetch(curl, z, sink, stop, 0);
}

/// Grava o que chega direto no arquivo, até `max` bytes.
const FileSink = struct {
    io: *c.SDL_IOStream,
    max: u64,
    written: u64 = 0,
    over: bool = false,
    failed: bool = false,

    fn sink(fs: *FileSink) images.Sink {
        return .{ .ctx = fs, .write = write };
    }

    fn write(ud: *anyopaque, chunk: []const u8, total: i64) bool {
        const fs: *FileSink = @ptrCast(@alignCast(ud));
        if (fs.written + chunk.len > fs.max or total > @as(i64, @intCast(@min(fs.max, std.math.maxInt(i63))))) {
            fs.over = true;
            return false;
        }
        if (c.SDL_WriteIO(fs.io, chunk.ptr, chunk.len) != chunk.len) {
            fs.failed = true;
            return false;
        }
        fs.written += chunk.len;
        return true;
    }
};

pub const Fetched = struct { ok: bool = false, bytes: u64 = 0, over: bool = false };

/// Baixa `url` para `path` (num .part, que só vira o arquivo inteiro no fim).
fn downloadTo(curl: *?*c.CURL, url: []const u8, path: [:0]const u8, max: u64, stop: *std.atomic.Value(bool)) Fetched {
    var pb: [1100]u8 = undefined;
    const part = std.fmt.bufPrintSentinel(&pb, "{s}.part", .{path}, 0) catch return .{};
    const io = c.SDL_IOFromFile(part.ptr, "wb") orelse return .{};
    var fs: FileSink = .{ .io = io, .max = max };
    const ok = download(curl, url, fs.sink(), stop);
    const closed = c.SDL_CloseIO(io);
    if (!ok or !closed or fs.failed or fs.written == 0) {
        _ = c.SDL_RemovePath(part.ptr);
        return .{ .over = fs.over };
    }
    if (!c.SDL_RenamePath(part.ptr, path.ptr)) {
        _ = c.SDL_RemovePath(part.ptr);
        return .{};
    }
    return .{ .ok = true, .bytes = fs.written };
}

fn writeFile(path: [:0]const u8, bytes: []const u8) bool {
    var pb: [1100]u8 = undefined;
    const part = std.fmt.bufPrintSentinel(&pb, "{s}.part", .{path}, 0) catch return false;
    if (!c.SDL_SaveFile(part.ptr, bytes.ptr, bytes.len)) return false;
    if (!c.SDL_RenamePath(part.ptr, path.ptr)) {
        _ = c.SDL_RemovePath(part.ptr);
        return false;
    }
    return true;
}

/// GIF antigo do Tenor: a página (tenor.com) diz onde está o vídeo.
fn tenorVideo(curl: *?*c.CURL, page: []const u8, out: []u8, stop: *std.atomic.Value(bool)) ?[]const u8 {
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(alloc);
    var ls: ListSink = .{ .list = &html, .max = 2 * 1024 * 1024 };
    if (!download(curl, page, ls.sink(), stop)) return null;
    const v = media_url.tenorVideoFromPage(html.items) orelse return null;
    if (v.len > out.len) return null;
    @memcpy(out[0..v.len], v);
    return out[0..v.len];
}

const ListSink = struct {
    list: *std.ArrayList(u8),
    max: usize,

    fn sink(s: *ListSink) images.Sink {
        return .{ .ctx = s, .write = write };
    }

    fn write(ud: *anyopaque, chunk: []const u8, _: i64) bool {
        const s: *ListSink = @ptrCast(@alignCast(ud));
        if (s.list.items.len + chunk.len > s.max) return false;
        s.list.appendSlice(alloc, chunk) catch return false;
        return true;
    }
};

/// O endereço que vale agora para um original: o do Tenor/Giphy só com os GIFs
/// ligados nas Configurações (senão a prévia do proxy, se tiver).
fn usable(p: salvar.Pick) ?struct { url: []const u8, fallback: bool } {
    if (p.gif_host and !media_url.allowedHost(p.url)) {
        if (p.fallback.len > 0) return .{ .url = p.fallback, .fallback = true };
        return null;
    }
    return .{ .url = p.url, .fallback = false };
}

// --- Exportar ---------------------------------------------------------------------
//
// Daqui até "Salvar" nada chama `download`, `downloadTo` nem `tenorVideo`: a
// exportação não tem caminho para a rede (src/tests.zig confere).

/// Um arquivo para a pasta ao lado do documento, se ele já estiver no computador.
pub const MediaItem = struct {
    /// O original: só para achar a cópia que o app já tem (nada é baixado).
    url: []const u8,
    /// Caminho relativo ao documento ("geral_arquivos/foto.png").
    rel: []const u8,
    /// Onde ele aparece: um anexo, a imagem de um cartão ou uma foto de perfil.
    target: union(enum) { att: struct { msg: u32, i: u16 }, emb: struct { msg: u32, i: u16 }, avatar: u32 },
    ok: bool = false,
};

/// Tudo o que a exportação precisa, já copiado da interface (nada aponta para o
/// Store, que muda enquanto a thread trabalha).
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    format: exportar.Format,
    header: exportar.Header,
    labels: exportar.Labels,
    msgs: []exportar.Msg,
    avatars: []exportar.Avatar,
    media: []MediaItem = &.{},
    /// O documento e a pasta da mídia (caminhos completos).
    path: [:0]const u8,
    media_dir: [:0]const u8 = "",
    /// A hora local das mensagens (o fuso de quem exporta).
    clock: exportar.Clock,
};

pub const Phase = enum(u8) { media, writing, done, failed, cancelled };

pub const Job = struct {
    plan: Plan,
    stop: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.media),
    msgs_done: std.atomic.Value(u32) = .init(0),
    media_done: std.atomic.Value(u32) = .init(0),
    /// Copiados para a pasta / que ficaram como link (não estavam no computador).
    media_ok: std.atomic.Value(u32) = .init(0),
    media_failed: std.atomic.Value(u32) = .init(0),
    /// Os arquivos que a exportação criou (o cancelar apaga). Só a thread mexe.
    created: std.ArrayList([:0]u8) = .empty,
    thread: ?*c.SDL_Thread = null,
    wake: *const fn () void,

    pub fn cancel(job: *Job) void {
        job.stop.store(true, .release);
    }

    pub fn finished(job: *const Job) bool {
        return switch (job.phase.load(.acquire)) {
            .done, .failed, .cancelled => true,
            else => false,
        };
    }

    /// Espera a thread e solta tudo (a thread já terminou ou foi cancelada).
    pub fn destroy(job: *Job) void {
        job.stop.store(true, .release);
        if (job.thread) |t| c.SDL_WaitThread(t, null);
        for (job.created.items) |p| alloc.free(p);
        job.created.deinit(alloc);
        job.plan.arena.deinit();
        alloc.destroy(job);
    }

    fn noteCreated(job: *Job, path: [:0]const u8) void {
        const owned = alloc.dupeSentinel(u8, path, 0) catch return;
        job.created.append(alloc, owned) catch alloc.free(owned);
    }
};

/// Começa a exportação (a thread é dona do plano daqui em diante).
pub fn start(plan: Plan, wake: *const fn () void) ?*Job {
    const job = alloc.create(Job) catch return null;
    job.* = .{ .plan = plan, .wake = wake };
    job.thread = c.SDL_CreateThread(run, "exportar", job) orelse {
        alloc.destroy(job);
        return null;
    };
    return job;
}

fn run(ud: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(ud.?));
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    const end: Phase = if (work(job)) .done else if (job.stop.load(.acquire)) .cancelled else .failed;
    if (end != .done) cleanup(job);
    job.phase.store(end, .release);
    job.wake();
    return 0;
}

fn work(job: *Job) bool {
    const plan = &job.plan;
    if (plan.media.len > 0) {
        job.phase.store(.media, .release);
        if (!c.SDL_CreateDirectory(plan.media_dir.ptr)) return false;
        if (!copyLocal(job)) return false;
        // Os que estavam no computador entram no documento no lugar do link.
        for (plan.media) |*m| if (m.ok) switch (m.target) {
            .att => |a| @constCast(&plan.msgs[a.msg].atts[a.i]).local = m.rel,
            .emb => |e| @constCast(&plan.msgs[e.msg].embeds[e.i]).image_local = m.rel,
            .avatar => |i| plan.avatars[i].path = m.rel,
        };
    }
    job.phase.store(.writing, .release);
    job.wake();
    var pb: [1100]u8 = undefined;
    const part = std.fmt.bufPrintSentinel(&pb, "{s}.part", .{plan.path}, 0) catch return false;
    const io = c.SDL_IOFromFile(part.ptr, "wb") orelse return false;
    var out: BufSink = .{ .io = io };
    var w: exportar.Writer = .{ .format = plan.format, .out = out.sink(), .clock = plan.clock, .labels = plan.labels, .gpa = alloc, .avatars = plan.avatars };
    plan.header.avatars = plan.avatars;
    w.begin(&plan.header);
    for (plan.msgs, 0..) |*m, i| {
        if (job.stop.load(.acquire) or out.failed) break;
        w.message(m);
        job.msgs_done.store(@intCast(i + 1), .release);
        // De vez em quando a tela acompanha (sem acordar a cada mensagem).
        if (i % 200 == 199) job.wake();
    }
    w.end(&plan.header);
    out.flush();
    const closed = c.SDL_CloseIO(io);
    if (job.stop.load(.acquire) or out.failed or !closed) {
        _ = c.SDL_RemovePath(part.ptr);
        return false;
    }
    if (!c.SDL_RenamePath(part.ptr, plan.path.ptr)) {
        _ = c.SDL_RemovePath(part.ptr);
        return false;
    }
    return true;
}

/// Cancelou ou falhou: sai o que esta exportação criou (e a pasta, se ficou vazia).
fn cleanup(job: *Job) void {
    for (job.created.items) |p| _ = c.SDL_RemovePath(p.ptr);
    if (job.plan.media_dir.len > 0) _ = c.SDL_RemovePath(job.plan.media_dir.ptr);
}

/// A mídia: copia para a pasta o que já está no computador (`local_hook`: a
/// memória das imagens, a demonstração, um arquivo nosso). O que não está fica
/// como link para o original; nada é baixado. false = cancelou.
fn copyLocal(job: *Job) bool {
    const plan = &job.plan;
    var local: std.ArrayList(u8) = .empty;
    defer local.deinit(alloc);
    for (plan.media, 0..) |*m, i| {
        if (job.stop.load(.acquire)) return false;
        defer {
            job.media_done.store(@intCast(i + 1), .release);
            job.wake();
        }
        local.clearRetainingCapacity();
        const have = if (local_hook) |h| h(m.url, &local) and local.items.len > 0 else false;
        if (!have) {
            _ = job.media_failed.fetchAdd(1, .acq_rel);
            continue;
        }
        var pb: [1100]u8 = undefined;
        const base = m.rel[if (std.mem.lastIndexOfScalar(u8, m.rel, '/')) |k| k + 1 else 0..];
        const path = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ plan.media_dir, base }, 0) catch {
            _ = job.media_failed.fetchAdd(1, .acq_rel);
            continue;
        };
        job.noteCreated(path);
        if (writeFile(path, local.items)) {
            m.ok = true;
            _ = job.media_ok.fetchAdd(1, .acq_rel);
        } else _ = job.media_failed.fetchAdd(1, .acq_rel);
    }
    return !job.stop.load(.acquire);
}

/// O documento vai para o disco em pedaços de 64 KB.
const BufSink = struct {
    io: *c.SDL_IOStream,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    failed: bool = false,

    fn sink(b: *BufSink) exportar.Sink {
        return .{ .ctx = b, .writeFn = write };
    }

    fn write(ud: *anyopaque, bytes: []const u8) void {
        const b: *BufSink = @ptrCast(@alignCast(ud));
        if (b.failed) return;
        if (b.len + bytes.len > b.buf.len) b.flush();
        if (bytes.len > b.buf.len) {
            if (c.SDL_WriteIO(b.io, bytes.ptr, bytes.len) != bytes.len) b.failed = true;
            return;
        }
        @memcpy(b.buf[b.len..][0..bytes.len], bytes);
        b.len += bytes.len;
    }

    fn flush(b: *BufSink) void {
        if (b.len == 0 or b.failed) return;
        if (c.SDL_WriteIO(b.io, &b.buf, b.len) != b.len) b.failed = true;
        b.len = 0;
    }
};

// --- Salvar uma imagem ou um vídeo ----------------------------------------------------

pub const SaveJob = struct {
    pick: salvar.Pick,
    /// Guardados no próprio trabalho (a interface solta o dela).
    url_buf: [2048]u8 = undefined,
    fallback_buf: [2048]u8 = undefined,
    path: [1100]u8 = undefined,
    path_len: usize = 0,
    /// O arquivo inteiro já estava no computador (é só gravar).
    local: []u8 = &.{},
    stop: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.media),
    /// Saiu a prévia do proxy (o GIF do Tenor/Giphy está desligado nas Configurações).
    used_fallback: bool = false,
    too_big: bool = false,
    thread: ?*c.SDL_Thread = null,
    wake: *const fn () void,

    pub fn pathSlice(j: *const SaveJob) [:0]const u8 {
        return j.path[0..j.path_len :0];
    }

    pub fn cancel(j: *SaveJob) void {
        j.stop.store(true, .release);
    }

    pub fn finished(j: *const SaveJob) bool {
        return switch (j.phase.load(.acquire)) {
            .done, .failed, .cancelled => true,
            else => false,
        };
    }

    pub fn destroy(j: *SaveJob) void {
        j.stop.store(true, .release);
        if (j.thread) |t| c.SDL_WaitThread(t, null);
        if (j.local.len > 0) alloc.free(j.local);
        alloc.destroy(j);
    }
};

/// Salva o original em `path`. `local`: os bytes, se já estavam no computador
/// (o trabalho fica com eles).
pub fn startSave(pick: salvar.Pick, path: []const u8, local: []u8, wake: *const fn () void) ?*SaveJob {
    const j = alloc.create(SaveJob) catch return null;
    j.* = .{ .pick = pick, .local = local, .wake = wake };
    if (pick.url.len > j.url_buf.len or pick.fallback.len > j.fallback_buf.len or path.len >= j.path.len) {
        alloc.destroy(j);
        return null;
    }
    @memcpy(j.url_buf[0..pick.url.len], pick.url);
    @memcpy(j.fallback_buf[0..pick.fallback.len], pick.fallback);
    j.pick.url = j.url_buf[0..pick.url.len];
    j.pick.fallback = j.fallback_buf[0..pick.fallback.len];
    j.pick.name = "";
    @memcpy(j.path[0..path.len], path);
    j.path[path.len] = 0;
    j.path_len = path.len;
    j.thread = c.SDL_CreateThread(saveRun, "salvar", j) orelse {
        alloc.destroy(j);
        return null;
    };
    return j;
}

fn saveRun(ud: ?*anyopaque) callconv(.c) c_int {
    const j: *SaveJob = @ptrCast(@alignCast(ud.?));
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    const ok = saveWork(j);
    j.phase.store(if (ok) .done else if (j.stop.load(.acquire)) .cancelled else .failed, .release);
    j.wake();
    return 0;
}

fn saveWork(j: *SaveJob) bool {
    const path = j.pathSlice();
    if (j.local.len > 0) return writeFile(path, j.local);
    var curl: ?*c.CURL = null;
    defer if (curl) |h| c.curl_easy_cleanup(h);
    const use = usable(j.pick) orelse return false;
    j.used_fallback = use.fallback;
    var vb: [1024]u8 = undefined;
    const url = if (j.pick.page and !use.fallback) (tenorVideo(&curl, use.url, &vb, &j.stop) orelse return false) else use.url;
    const got = downloadTo(&curl, url, path, max_save_bytes, &j.stop);
    j.too_big = got.over;
    return got.ok;
}
