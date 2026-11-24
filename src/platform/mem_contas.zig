//! O que cada biblioteca grande tem alocado agora: o SDL, o Dear ImGui, o FreeType, o curl e o
//! OpenSSL alocam pelas funções de src/platform/mem_contas.c, que somam o tamanho de cada
//! bloco e chamam o mesmo malloc. `instalar` entrega as funções a cada uma no começo do main
//! (o OpenSSL e o SDL só aceitam antes da primeira alocação), `imgui` antes do contexto do
//! ImGui, e o curl as recebe no curl_global_init_mem (ui/images.zig `curlGlobalInit`).
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Lib = enum(u8) { sdl, imgui, freetype, curl, openssl };

extern fn larper_mem_conta(i: c_int) c_longlong;

extern fn larper_sdl_malloc(n: usize) callconv(.c) ?*anyopaque;
extern fn larper_sdl_calloc(a: usize, b: usize) callconv(.c) ?*anyopaque;
extern fn larper_sdl_realloc(p: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn larper_sdl_free(p: ?*anyopaque) callconv(.c) void;
extern fn larper_imgui_alloc(n: usize, ud: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn larper_imgui_free(p: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void;
extern fn larper_freetype_alloc(n: usize, ud: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn larper_freetype_free(p: ?*anyopaque, ud: ?*anyopaque) callconv(.c) void;
extern fn larper_curl_malloc(n: usize) callconv(.c) ?*anyopaque;
extern fn larper_curl_free(p: ?*anyopaque) callconv(.c) void;
extern fn larper_curl_realloc(p: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque;
extern fn larper_curl_strdup(s: [*c]const u8) callconv(.c) [*c]u8;
extern fn larper_curl_calloc(a: usize, b: usize) callconv(.c) ?*anyopaque;
extern fn larper_ssl_malloc(n: usize, f: [*c]const u8, l: c_int) callconv(.c) ?*anyopaque;
extern fn larper_ssl_realloc(p: ?*anyopaque, n: usize, f: [*c]const u8, l: c_int) callconv(.c) ?*anyopaque;
extern fn larper_ssl_free(p: ?*anyopaque, f: [*c]const u8, l: c_int) callconv(.c) void;
extern fn CRYPTO_set_mem_functions(
    m: *const fn (usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque,
    r: *const fn (?*anyopaque, usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque,
    f: *const fn (?*anyopaque, [*c]const u8, c_int) callconv(.c) void,
) c_int;
extern fn larper_freetype_set_alloc(
    a: *const fn (usize, ?*anyopaque) callconv(.c) ?*anyopaque,
    f: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
) void;

/// Quais bibliotecas aceitaram as funções (as que não aceitaram ficam no "resto").
var aceitou: [5]bool = @splat(false);
/// No navegador não há src/platform/mem_contas.c (nem curl e OpenSSL): nada é contado.
const tem = builtin.os.tag != .emscripten;

/// No começo do main, antes de qualquer thread e de o SDL e o OpenSSL alocarem.
pub fn instalar() void {
    if (comptime !tem) return;
    aceitou[@intFromEnum(Lib.sdl)] = c.SDL_SetMemoryFunctions(larper_sdl_malloc, larper_sdl_calloc, larper_sdl_realloc, larper_sdl_free);
    aceitou[@intFromEnum(Lib.openssl)] = CRYPTO_set_mem_functions(larper_ssl_malloc, larper_ssl_realloc, larper_ssl_free) != 0;
}

/// Antes de criar o contexto do ImGui (e de qualquer fonte entrar no atlas).
pub fn imgui() void {
    if (comptime !tem) return;
    c.ImGui_SetAllocatorFunctions(larper_imgui_alloc, larper_imgui_free, null);
    larper_freetype_set_alloc(larper_freetype_alloc, larper_freetype_free);
    aceitou[@intFromEnum(Lib.imgui)] = true;
    aceitou[@intFromEnum(Lib.freetype)] = true;
}

/// O curl_global_init com as funções contadas (uma vez por processo).
pub fn curlInit() void {
    if (comptime !tem) return;
    const rc = c.curl_global_init_mem(c.CURL_GLOBAL_DEFAULT, larper_curl_malloc, larper_curl_free, larper_curl_realloc, larper_curl_strdup, larper_curl_calloc);
    if (rc == c.CURLE_OK) aceitou[@intFromEnum(Lib.curl)] = true else _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
}

/// Bytes alocados agora pela biblioteca (null = ela não usa as nossas funções).
pub fn bytes(l: Lib) ?u64 {
    if (comptime !tem) return null;
    if (!aceitou[@intFromEnum(l)]) return null;
    return @intCast(@max(0, larper_mem_conta(@intFromEnum(l))));
}
