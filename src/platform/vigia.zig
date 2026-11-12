//! Vigia de pastas: uma thread que dorme até o sistema avisar que algo mudou numa das
//! pastas e então chama `wake` (os temas e os arquivos de mascote). inotify no Linux,
//! aviso de mudança de pasta no Windows; nada de olhar de tempos em tempos. No
//! navegador não há pasta para vigiar.
const std = @import("std");
const c = @import("c");
const sys = @import("sys.zig");

/// O que a thread precisa (alocado uma vez por vigia; vive enquanto o app vive).
const Job = struct {
    wake: *const fn () void,
    fd: c_int = -1,
    handles: [8]if (sys.windows) c.HANDLE else usize = undefined,
    n: u32 = 0,
};

/// Vigia `dirs` (arquivo gravado, renomeado para dentro, criado ou apagado) e, se vier,
/// `extra` só para arquivo gravado ou renomeado (a pasta do pywal). Cada rajada de
/// avisos (editores salvam em vários passos) vira uma chamada só de `wake`. Devolve
/// falso se não deu para vigiar nada.
pub fn watch(dirs: []const [:0]const u8, extra: ?[:0]const u8, wake: *const fn () void, name: [*:0]const u8) bool {
    if (sys.web) return false;
    const job = std.heap.c_allocator.create(Job) catch return false;
    job.* = .{ .wake = wake };
    const ok = if (sys.windows) watchWindows(job, dirs, name) else watchLinux(job, dirs, extra, name);
    if (!ok) std.heap.c_allocator.destroy(job);
    return ok;
}

/// No Windows: um aviso de mudança por pasta (a maior parte é só uma).
fn watchWindows(job: *Job, dirs: []const [:0]const u8, name: [*:0]const u8) bool {
    const what = c.FILE_NOTIFY_CHANGE_LAST_WRITE | c.FILE_NOTIFY_CHANGE_FILE_NAME;
    for (dirs) |dir| {
        if (job.n == job.handles.len) break;
        const h = c.FindFirstChangeNotificationA(dir.ptr, 0, what);
        if (h == c.INVALID_HANDLE_VALUE) continue;
        job.handles[job.n] = h;
        job.n += 1;
    }
    if (job.n == 0) return false;
    if (c.SDL_CreateThread(runWindows, name, job)) |t| c.SDL_DetachThread(t);
    return true;
}

fn watchLinux(job: *Job, dirs: []const [:0]const u8, extra: ?[:0]const u8, name: [*:0]const u8) bool {
    const fd = c.inotify_init1(c.IN_CLOEXEC);
    if (fd < 0) return false;
    var any = false;
    for (dirs) |dir| {
        if (c.inotify_add_watch(fd, dir.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_CREATE | c.IN_DELETE) >= 0) any = true;
    }
    if (extra) |e| {
        if (c.inotify_add_watch(fd, e.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO) >= 0) any = true;
    }
    if (!any) {
        _ = c.close(fd);
        return false;
    }
    job.fd = fd;
    if (c.SDL_CreateThread(runInotify, name, job)) |t| c.SDL_DetachThread(t);
    return true;
}

fn runInotify(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    var events: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
    while (true) {
        const n = c.read(job.fd, &events, events.len);
        if (n <= 0) return 0;
        // Junta rajadas de eventos (editores salvam em vários passos).
        c.SDL_Delay(60);
        job.wake();
    }
}

fn runWindows(data: ?*anyopaque) callconv(.c) c_int {
    const job: *Job = @ptrCast(@alignCast(data.?));
    while (true) {
        const r = c.WaitForMultipleObjects(job.n, &job.handles, 0, c.INFINITE);
        if (r >= c.WAIT_OBJECT_0 + job.n) return 0;
        // Junta rajadas de eventos (editores salvam em vários passos).
        c.SDL_Delay(60);
        _ = c.FindNextChangeNotification(job.handles[r - c.WAIT_OBJECT_0]);
        job.wake();
    }
}
