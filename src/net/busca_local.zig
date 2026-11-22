//! A busca local (ui/search.zig): o índice de core/busca_indice.zig com as mensagens que o
//! app tem, na memória e no cache em disco (net/msg_cache.zig), em dia a cada evento:
//! mensagem nova, editada ou apagada e cada página do histórico (que também tira o que foi
//! apagado enquanto o app estava fechado; a página mais nova, também o que era mais novo
//! que ela). Nada aqui fala com o Discord: o índice só vê o que já chegou.
//!
//! Fica em <cache>/messages/<conta>/busca.lci, ao lado do cache, só para o dono. É lido
//! numa thread de prioridade baixa quando o READY chega (ou quando a busca abre); o que
//! chega enquanto isso vai para um índice pequeno, juntado no fim. Sem o arquivo (primeira vez,
//! estragado, outra versão), refaz a partir dos arquivos do cache; os arquivos do cache
//! mais novos que ele (o app caiu antes de gravar) também entram. Grava com mudanças a
//! cada 5 minutos, ao sair da conta e ao fechar.
//!
//! "Guardar mensagens no disco" desligado: só na memória, nada lido nem gravado. "Apagar
//! cache" e a conta removida levam o arquivo junto; "Apagar todos os dados" leva a pasta
//! inteira (e daí em diante nada grava, ver platform/fsutil.zig). Com a janela escondida
//! há um tempo, o índice sai da memória (gravado antes) e volta quando a busca abrir.
const std = @import("std");
const c = @import("c");
const types = @import("../core/types.zig");
const ev = @import("../core/event.zig");
const bi = @import("../core/busca_indice.zig");
const sq = @import("../core/search_query.zig");
const format = @import("../core/cache_format.zig");
const Store = @import("../core/store.zig").Store;
const msg_cache = @import("msg_cache.zig");
const fsutil = @import("../platform/fsutil.zig");
const Id = types.Id;

const alloc = std.heap.c_allocator;

const file_name = msg_cache.search_index_file;
/// Com mudanças, grava no máximo a cada tanto (e sempre ao sair da conta e ao fechar).
const save_every_ms: u64 = 5 * 60 * 1000;
/// "Só quem usou vê" (resposta de interação): fica de fora, como no cache.
const ephemeral: u32 = 1 << 6;

/// O índice da conta. Antes de o disco chegar (ou com ele desligado), só o que chegou
/// nesta sessão.
var index: ?*bi.Index = null;
var acct_buf: [24]u8 = undefined;
var acct_len: usize = 0;
/// O que estava no disco já está em `index` (ou não havia nada para ler).
var merged = false;
/// Saiu da memória com a janela escondida (ou não deu para ler): só volta com a busca.
var released = false;
/// O que mudou antes de o disco chegar, para aplicar no que vier dele.
var pending_dels: std.ArrayList(Id) = .empty;
const Prune = struct { channel: Id, min: Id, max: Id, keep: []Id };
var pending_prunes: std.ArrayList(Prune) = .empty;
var dirty = false;
var saved_ms: u64 = 0;
/// A última gravação que não deu (disco cheio, pasta sumiu): com a janela escondida, não
/// tenta de novo a cada volta do laço.
var failed_ms: u64 = 0;
/// Muda quando o índice é trocado (o disco chegou, apagou, saiu da memória).
var swaps: u32 = 0;
/// Tamanho do arquivo (o último lido ou gravado).
var disk_bytes: u64 = 0;
/// Para o QA e as medidas: leituras do arquivo, arquivos do cache lidos para refazer,
/// e o tempo da última consulta.
pub var loads: u32 = 0;
pub var cache_files_read: u32 = 0;
pub var last_query_ns: u64 = 0;
var wake_fn: ?*const fn () void = null;

/// Acorda o laço quando a leitura em segundo plano termina.
pub fn setWake(f: *const fn () void) void {
    wake_fn = f;
}

// --- A leitura do disco, numa thread -------------------------------------------------

const Job = struct {
    dir_buf: [512]u8 = undefined,
    dir_len: usize = 0,
    result: ?*bi.Index = null,
    from_file: bool = false,
    file_bytes: u64 = 0,
    files_read: u32 = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,

    fn dir(j: *const Job) []const u8 {
        return j.dir_buf[0..j.dir_len];
    }
};
var job: ?*Job = null;

fn workerMain(data: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(data.?));
    // Sem pressa: a conversa e a rede vêm primeiro.
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_LOW);
    j.result = loadDir(j) catch null;
    j.done.store(true, .release);
    if (wake_fn) |f| f();
    return 0;
}

/// O arquivo do índice e os arquivos do cache mais novos que ele (todos, sem ele).
/// Só lê: o cache pode estar sendo gravado ao mesmo tempo (troca de nome, nunca pela
/// metade) e nada global muda aqui.
fn loadDir(j: *Job) !*bi.Index {
    const ix = try alloc.create(bi.Index);
    ix.* = bi.Index.init(alloc);
    errdefer {
        ix.deinit();
        alloc.destroy(ix);
    }
    var since: i64 = std.math.minInt(i64);
    var pbuf: [600]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ j.dir(), file_name }, 0);
    var size: usize = 0;
    if (c.SDL_LoadFile(p.ptr, &size)) |data| {
        defer c.SDL_free(data);
        if (ix.decodeInto(@as([*]const u8, @ptrCast(data))[0..size])) {
            j.from_file = true;
            j.file_bytes = size;
            var info: c.SDL_PathInfo = undefined;
            if (c.SDL_GetPathInfo(p.ptr, &info)) since = info.modify_time;
        } else |_| {
            // Estragado ou de outra versão: refaz pelo cache (a próxima gravação troca).
            ix.deinit();
        }
    }
    try readCache(j, ix, since);
    ix.tighten();
    return ix;
}

fn readCache(j: *Job, ix: *bi.Index, since: i64) !void {
    var dbuf: [520]u8 = undefined;
    const d = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{j.dir()}, 0) catch return;
    const dir = c.opendir(d.ptr) orelse return;
    defer _ = c.closedir(dir);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    while (c.readdir(dir)) |fe| {
        if (j.cancel.load(.acquire)) return;
        const name = std.mem.sliceTo(&fe.*.d_name, 0);
        if (!std.mem.endsWith(u8, name, ".lcm")) continue;
        const ch = std.fmt.parseInt(Id, name[0 .. name.len - 4], 10) catch continue;
        var fbuf: [600]u8 = undefined;
        const fp = std.fmt.bufPrintSentinel(&fbuf, "{s}/{s}", .{ j.dir(), name }, 0) catch continue;
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(fp.ptr, &info) or info.modify_time < since) continue;
        var size: usize = 0;
        const data = c.SDL_LoadFile(fp.ptr, &size) orelse continue;
        defer c.SDL_free(data);
        _ = arena.reset(.retain_capacity);
        const dec = format.decode(arena.allocator(), @as([*]const u8, @ptrCast(data))[0..size]) catch continue;
        if (dec.channel != ch) continue;
        j.files_read += 1;
        for (dec.entries) |*e| {
            if (e.msg.id == 0 or e.msg.system != .none) continue;
            var fb: [256]u8 = undefined;
            var in = bi.inputOf(&e.msg, &fb);
            in.channel = ch;
            for (dec.users) |u| if (u.id == e.msg.author) {
                in.author_name = u.name;
                break;
            };
            try ix.put(in);
        }
    }
}

fn freeIndex(ix: *bi.Index) void {
    ix.deinit();
    alloc.destroy(ix);
}

/// Espera a thread (avisada para parar) e joga fora o que ela leu.
fn cancelJob() void {
    const j = job orelse return;
    j.cancel.store(true, .release);
    if (j.thread) |t| c.SDL_WaitThread(t, null);
    if (j.result) |r| freeIndex(r);
    alloc.destroy(j);
    job = null;
}

/// A thread terminou: junta o que chegou enquanto isso no que veio do disco.
fn takeJob() bool {
    const j = job orelse return false;
    if (!j.done.load(.acquire)) return false;
    if (j.thread) |t| c.SDL_WaitThread(t, null);
    job = null;
    defer alloc.destroy(j);
    const loaded = j.result orelse {
        // Não deu (sem memória): fica o desta sessão, sem gravar por cima do arquivo.
        released = true;
        return false;
    };
    var changed = !j.from_file or j.files_read > 0;
    if (index) |live| {
        for (live.docs.items) |*d| {
            if (!d.alive()) continue;
            loaded.put(live.inputOfDoc(d)) catch {};
            changed = true;
        }
        freeIndex(live);
    }
    for (pending_dels.items) |id| changed = loaded.remove(id) or changed;
    for (pending_prunes.items) |pr| {
        changed = loaded.pruneRange(pr.channel, pr.min, pr.max, pr.keep) > 0 or changed;
        alloc.free(pr.keep);
    }
    pending_dels.clearRetainingCapacity();
    pending_prunes.clearRetainingCapacity();
    index = loaded;
    merged = true;
    swaps +%= 1;
    loads += 1;
    cache_files_read += j.files_read;
    if (j.from_file) disk_bytes = j.file_bytes;
    // O arquivo não tinha tudo (veio do cache, ou chegou coisa nova): grava na próxima.
    if (changed) dirty = true;
    return true;
}

fn dropAll() void {
    if (index) |ix| freeIndex(ix);
    index = null;
    for (pending_prunes.items) |pr| alloc.free(pr.keep);
    pending_prunes.clearRetainingCapacity();
    pending_dels.clearRetainingCapacity();
    swaps +%= 1;
}

// --- A conta e o "Guardar mensagens no disco" ------------------------------------------

/// Confere a conta do cache (barato: roda a cada operação) e pega o que a thread leu.
fn ensure() void {
    _ = takeJob();
    const acct = msg_cache.account();
    if (std.mem.eql(u8, acct, acct_buf[0..acct_len])) return;
    // Ainda sem conta → a conta da sessão: o que já chegou é dela.
    if (acct_len == 0 and acct.len > 0) {
        setAcct(acct);
        return;
    }
    // Outra conta (ou saiu dela): nada da anterior fica. O que ela tinha de novo já foi
    // gravado (`reset`, ao sair da conta).
    cancelJob();
    dropAll();
    setAcct(acct);
    dirty = false;
    disk_bytes = 0;
}

fn setAcct(acct: []const u8) void {
    const n = @min(acct.len, acct_buf.len);
    @memcpy(acct_buf[0..n], acct[0..n]);
    acct_len = n;
    merged = false;
    released = false;
}

fn target() ?*bi.Index {
    ensure();
    if (index) |ix| return ix;
    const ix = alloc.create(bi.Index) catch return null;
    ix.* = bi.Index.init(alloc);
    index = ix;
    return ix;
}

/// Lê o disco (numa thread) se ainda não leu. `force`: a busca abriu (vale mesmo depois de
/// o índice sair da memória com a janela escondida).
pub fn startLoad(force: bool) void {
    ensure();
    if (force) released = false;
    if (merged or job != null or released or !msg_cache.usable()) return;
    var buf: [512]u8 = undefined;
    const dir = msg_cache.accountDir(&buf) orelse return;
    const j = alloc.create(Job) catch return;
    j.* = .{};
    @memcpy(j.dir_buf[0..dir.len], dir);
    j.dir_len = dir.len;
    job = j;
    j.thread = c.SDL_CreateThread(workerMain, "busca", j);
    if (j.thread == null) {
        // Sem thread (o navegador): lê aqui mesmo.
        j.result = loadDir(j) catch null;
        j.done.store(true, .release);
    }
}

/// O que a thread leu, se já terminou. true: o índice mudou.
pub fn poll() bool {
    const before = swaps;
    ensure();
    return swaps != before;
}

pub fn loading() bool {
    return job != null;
}

/// Saiu da memória (janela escondida) e só volta quando a busca abrir; o que chega até lá
/// fica num índice pequeno, desta sessão.
pub fn isReleased() bool {
    return released;
}

/// Muda a cada mudança no índice (a lista na tela refaz).
pub fn generation() u32 {
    return swaps +% (if (index) |ix| ix.gen else 0);
}

/// O tique do relógio: lê o disco se ainda não leu (o cache religado), compacta quando
/// vale e grava o que mudou (no máximo a cada 5 minutos).
pub fn tick(ready: bool) void {
    ensure();
    if (ready) startLoad(false);
    const ix = index orelse return;
    if (merged and ix.wantsCompact()) ix.compact() catch {};
    if (dirty and merged and c.SDL_GetTicks() -| saved_ms >= save_every_ms) flush();
}

// --- O que chega -------------------------------------------------------------------------

fn add(store: *const Store, m: *const types.Message) void {
    if (m.id == 0 or m.flags & ephemeral != 0 or m.system != .none) return;
    const ix = target() orelse return;
    var fb: [256]u8 = undefined;
    var in = bi.inputOf(m, &fb);
    if (store.user(m.author)) |u| in.author_name = u.name;
    const g0 = ix.gen;
    ix.put(in) catch return;
    if (ix.gen != g0) dirty = true;
}

fn inMemory(store: *const Store, ch: Id, id: Id) bool {
    const cs = store.channel(ch) orelse return false;
    return store.find(cs, id) != null;
}

/// A página mais nova de um canal (a do presente): o maior ID dela, para o `afterEvent`
/// (depois do Store, as mensagens do evento já são dele).
var newest_page: struct { ch: Id = 0, hi: Id = 0 } = .{};

/// Antes de o Store aplicar o evento (ele fica com o texto, ou o libera).
pub fn beforeEvent(store: *const Store, e: ev.Event) void {
    switch (e) {
        .message_create => |m| add(store, &m),
        .history => |h| {
            newest_page = .{};
            if (h.messages.len == 0) return;
            for (h.messages) |*m| add(store, m);
            const hi = page(h.channel, h.messages);
            if (!h.older and !h.around and !h.newer) newest_page = .{ .ch = h.channel, .hi = hi };
        },
        // Na memória, o Store junta a edição com o que tinha: indexa depois (afterEvent).
        .message_update => |u| if ((u.content != null or u.attachments != null) and !inMemory(store, u.channel, u.id)) updateAway(u.id, u.content, u.attachments),
        .message_delete => |del| remove(del.id),
        else => {},
    }
}

/// Depois de o Store aplicar: a edição de uma mensagem que está na memória e o fim da
/// página mais nova.
pub fn afterEvent(store: *const Store, e: ev.Event) void {
    switch (e) {
        .message_update => |u| {
            if (u.content == null and u.attachments == null) return;
            const cs = store.channel(u.channel) orelse return;
            const m = store.find(cs, u.id) orelse return;
            if (m.pending or m.deleted) return;
            add(store, &m.msg);
        },
        .history => |h| {
            const np = newest_page;
            newest_page = .{};
            if (np.ch == h.channel and np.hi != 0) pastNewest(store, np.ch, np.hi);
        },
        else => {},
    }
}

/// Depois da página mais nova: o que o índice tem desse canal depois dela e a conversa não
/// tem foi apagado (com o app fechado, quando era a última). O que chegou ao vivo enquanto
/// a página vinha está na conversa e fica.
fn pastNewest(store: *const Store, ch: Id, hi: Id) void {
    const cs = store.channel(ch) orelse return;
    var live: std.ArrayList(Id) = .empty;
    defer live.deinit(alloc);
    for (cs.messages.items) |*m| if (m.msg.id > hi) live.append(alloc, m.msg.id) catch return;
    const ix = target() orelse return;
    const max = std.math.maxInt(Id);
    if (ix.pruneRange(ch, hi + 1, max, live.items) > 0) dirty = true;
    if (!merged and msg_cache.usable()) {
        const keep = live.toOwnedSlice(alloc) catch return;
        pending_prunes.append(alloc, .{ .channel = ch, .min = hi + 1, .max = max, .keep = keep }) catch alloc.free(keep);
    }
}

/// Editada fora da memória: o texto novo vem do evento; o resto, do que o índice tinha.
fn updateAway(id: Id, content: ?[]const u8, attachments: ?[]types.Attachment) void {
    const ix = target() orelse return;
    const d = ix.docOf(id) orelse return;
    const old = ix.inputOfDoc(d);
    // Cópias: guardar a versão nova pode mover o texto do índice.
    var cb: [bi.max_text]u8 = undefined;
    var fbuf: [256]u8 = undefined;
    const text = content orelse old.content;
    const n = bi.utf8Cut(text, cb.len);
    @memcpy(cb[0..n], text[0..n]);
    const nf = @min(old.files.len, fbuf.len);
    @memcpy(fbuf[0..nf], old.files[0..nf]);
    var in: bi.Input = .{ .id = id, .channel = old.channel, .author = old.author, .content = cb[0..n], .files = fbuf[0..nf], .flags = old.flags };
    in.flags = (in.flags & ~bi.f_link) | (if (bi.hasLink(in.content)) bi.f_link else 0);
    if (attachments) |list| {
        var nb: [256]u8 = undefined;
        const m: types.Message = .{ .id = id, .channel = old.channel, .author = old.author, .timestamp = 0, .content = in.content, .attachments = list };
        const fresh = bi.inputOf(&m, &nb);
        const only_embeds = for (list) |a| {
            if (!a.embed) break false;
        } else true;
        if (only_embeds) {
            // Só a prévia de um link mudou: os anexos de verdade continuam.
            in.flags |= fresh.flags & (bi.f_image | bi.f_video);
        } else {
            in.flags = fresh.flags;
            const k = @min(fresh.files.len, fbuf.len);
            @memcpy(fbuf[0..k], fresh.files[0..k]);
            in.files = fbuf[0..k];
        }
    }
    const g0 = ix.gen;
    ix.put(in) catch return;
    if (ix.gen != g0) dirty = true;
}

/// Apagada (por evento ou por nós).
pub fn remove(id: Id) void {
    const ix = target() orelse return;
    if (ix.remove(id)) dirty = true;
    // O disco ainda vai chegar: ela não pode voltar com ele.
    if (!merged and msg_cache.usable()) pending_dels.append(alloc, id) catch {};
}

/// Uma página do histórico: o que o índice tem nessa faixa do canal e não veio foi
/// apagado (inclusive com o app fechado). Devolve o maior ID da página (0: nenhum).
fn page(ch: Id, msgs: []const types.Message) Id {
    var lo: Id = std.math.maxInt(Id);
    var hi: Id = 0;
    for (msgs) |m| if (m.id != 0) {
        lo = @min(lo, m.id);
        hi = @max(hi, m.id);
    };
    if (hi == 0) return 0;
    const ix = target() orelse return hi;
    const keep = alloc.alloc(Id, msgs.len) catch return hi;
    for (msgs, keep) |m, *k| k.* = m.id;
    if (ix.pruneRange(ch, lo, hi, keep) > 0) dirty = true;
    if (!merged and msg_cache.usable()) {
        pending_prunes.append(alloc, .{ .channel = ch, .min = lo, .max = hi, .keep = keep }) catch alloc.free(keep);
        return hi;
    }
    alloc.free(keep);
    return hi;
}

// --- Gravar, apagar, soltar --------------------------------------------------------------

/// Grava o índice, se mudou e o disco já foi lido (senão o arquivo perderia o que só ele
/// tinha). Num .tmp e depois troca de nome, como o cache.
pub fn flush() void {
    ensure();
    if (!dirty or !merged or !msg_cache.usable()) return;
    const ix = index orelse return;
    var pbuf: [512]u8 = undefined;
    const p = msg_cache.accountFile(&pbuf, file_name) orelse return;
    saved_ms = c.SDL_GetTicks();
    if (ix.count() == 0) {
        _ = c.unlink(p.ptr);
        disk_bytes = 0;
        dirty = false;
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    failed_ms = saved_ms;
    ix.encode(alloc, &out) catch return;
    if (!msg_cache.ensureAccountDir() or !fsutil.replacePrivate(p, out.items)) return;
    failed_ms = 0;
    disk_bytes = out.items.len;
    dirty = false;
}

/// Ao fechar e ao sair da conta: o que mudou vai para o disco. O disco ainda não lido é
/// lido agora (o arquivo gravado precisa ter o que já tinha).
pub fn finish() void {
    ensure();
    if (!dirty or !msg_cache.usable()) return;
    if (!merged) {
        startLoad(true);
        if (job) |j| if (j.thread) |t| {
            c.SDL_WaitThread(t, null);
            j.thread = null;
        };
        _ = takeJob();
    }
    flush();
}

/// Saiu da conta: grava e esquece (a próxima conta começa do zero).
pub fn reset() void {
    finish();
    cancelJob();
    dropAll();
    acct_len = 0;
    merged = false;
    released = false;
    dirty = false;
    failed_ms = 0;
    disk_bytes = 0;
}

/// "Apagar cache": o arquivo foi junto (msg_cache.clearAll). O que está na tela continua
/// achável, sem voltar para o disco até algo mudar (como o cache).
pub fn clear(store: *const Store) void {
    ensure();
    cancelJob();
    dropAll();
    merged = true;
    released = false;
    disk_bytes = 0;
    var it = store.channels.valueIterator();
    while (it.next()) |cs| for (cs.*.messages.items) |*m| {
        if (!m.pending and !m.deleted) add(store, &m.msg);
    };
    if (index) |ix| ix.tighten();
    dirty = false;
}

/// Janela escondida há um tempo: grava e solta a memória; volta quando a busca abrir.
pub fn releaseHidden() bool {
    ensure();
    if (!merged or job != null or !msg_cache.usable()) return false;
    const ix = index orelse return false;
    if (ix.count() == 0) return false;
    if (failed_ms != 0 and c.SDL_GetTicks() -| failed_ms < 60_000) return false;
    flush();
    if (dirty) return false;
    dropAll();
    merged = false;
    released = true;
    return true;
}

pub fn deinit() void {
    cancelJob();
    dropAll();
    pending_dels.deinit(alloc);
    pending_prunes.deinit(alloc);
}

// --- Consultar ---------------------------------------------------------------------------

/// O índice de agora (vale até o próximo evento ou quadro).
pub fn current() ?*const bi.Index {
    return index;
}

pub fn contains(id: Id) bool {
    const ix = index orelse return false;
    return ix.contains(id);
}

/// Procura no índice: quantas casaram, e as `limit` mais novas (ou mais antigas) em `out`.
/// Só canais de texto que o app conhece (e o "em:"); "menciona:" vale para quem o app já
/// carregou com esse nome.
pub fn find(store: *const Store, q: *const sq.Query, raw: []const u8, oldest: bool, limit: usize, out: *std.ArrayList(bi.Hit)) usize {
    out.clearRetainingCapacity();
    const ix = target() orelse return 0;
    var ok: std.ArrayList(bool) = .empty;
    defer ok.deinit(alloc);
    ok.ensureTotalCapacity(alloc, ix.channels.items.len) catch return 0;
    for (ix.channels.items) |ch| {
        const cs = store.channel(ch);
        ok.appendAssumeCapacity(if (cs) |x| x.info.kind == .text and (q.in_len == 0 or sq.containsFold(x.info.name, q.in())) else false);
    }
    var who: std.ArrayList(Id) = .empty;
    defer who.deinit(alloc);
    if (q.mentions_len > 0) {
        var it = store.users.valueIterator();
        while (it.next()) |u| if (sq.userScore(u.name, q.mentions()) > 0) who.append(alloc, u.id) catch {};
    }
    var terms: [sq.max_terms][]const u8 = undefined;
    for (0..q.n_terms) |i| terms[i] = q.term(i);
    var flags: u8 = 0;
    if (q.has_link) flags |= bi.f_link;
    if (q.has_image) flags |= bi.f_image;
    if (q.has_file) flags |= bi.f_file;
    if (q.has_video) flags |= bi.f_video;
    if (q.has_sound) flags |= bi.f_sound;
    const t0 = c.SDL_GetTicksNS();
    const total = ix.search(alloc, .{
        .terms = terms[0..q.n_terms],
        .prefix_last = sq.typingLast(raw),
        .from = q.from(),
        .mentions = if (q.mentions_len > 0) who.items else null,
        .flags = flags,
        .min_id = q.min_id,
        .max_id = q.max_id,
        .channel_ok = ok.items,
        .oldest = oldest,
        .limit = limit,
    }, out) catch 0;
    last_query_ns = c.SDL_GetTicksNS() - t0;
    return total;
}

pub const Stats = struct { docs: usize, words: usize, mem: usize, disk: u64, loading: bool };

/// Para as Configurações e as medidas.
pub fn stats() Stats {
    const ix = index;
    return .{
        .docs = if (ix) |x| x.count() else 0,
        .words = if (ix) |x| x.wordCount() else 0,
        .mem = if (ix) |x| x.memBytes() else 0,
        .disk = disk_bytes,
        .loading = job != null,
    };
}
