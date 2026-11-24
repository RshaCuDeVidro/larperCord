//! Para onde o app fala com o Discord: a API e o gateway.
//!
//! No executável de quem usa, os endereços são fixos (discord.com e gateway.discord.gg).
//! O executável do QA (debug e com o robô, -Dqa) pode trocá-los por um Discord de mentira
//! local (tools/discord_falso.py, QA_SUITE=rede), para o código de rede de verdade
//! (net/discord.zig: WebSocket, zlib-stream, RESUME, rate limit) rodar no QA sem a conta de
//! ninguém. A troca só aceita http/ws em 127.0.0.1 e não existe fora desse executável:
//! `usarLocal` nem compila em outro (ver `pode_trocar`), e o resto devolve os fixos. Com a
//! troca ligada, o CDN e o proxy de mídia vão para o mesmo servidor (`midiaLocal`).
const std = @import("std");
const builtin = @import("builtin");

pub const api_fixa = "https://discord.com/api/v10";
/// A busca vai na versão que o cliente do Discord usa (o caminho já traz o /v9).
pub const api_raiz_fixa = "https://discord.com/api";
pub const gateway_fixo = "wss://gateway.discord.gg";

/// O token do Discord de mentira: fixo, de propósito sem cara de token do Discord (que tem
/// três partes separadas por ponto). Com a troca ligada, o app só aceita este: um token de
/// verdade esquecido no LARPER_TOKEN nunca vai para o servidor local.
pub const token_qa = "larper-qa-token-falso-nao-e-do-discord";

/// Só no executável do QA em debug, ou num otimizado com -Dqa -Dqa-rede (medir a RAM como
/// na release, tools/ram_conta_grande.sh). Num ReleaseFast comum (mesmo com -Dqa) é false,
/// e os endereços ficam os fixos sem nem olhar a variável.
pub const pode_trocar = @import("build_options").qa and (builtin.mode == .debug or @import("build_options").qa_rede);

var porta: u16 = 0;
var buf_api: [48]u8 = undefined;
var buf_raiz: [48]u8 = undefined;
var buf_ws: [32]u8 = undefined;
var buf_http: [32]u8 = undefined;
var len_api: usize = 0;
var len_raiz: usize = 0;
var len_ws: usize = 0;
var len_http: usize = 0;

/// A porta de "http://127.0.0.1:<porta>" (com ou sem a barra no fim). Qualquer outra coisa
/// (outro host, https, localhost, caminho, usuário, porta 0) é null.
pub fn portaLocal(url: []const u8) ?u16 {
    const prefixo = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefixo)) return null;
    var resto = url[prefixo.len..];
    if (resto.len > 0 and resto[resto.len - 1] == '/') resto = resto[0 .. resto.len - 1];
    if (resto.len == 0 or resto.len > 5) return null;
    for (resto) |ch| if (!std.ascii.isDigit(ch)) return null;
    const p = std.fmt.parseInt(u16, resto, 10) catch return null;
    return if (p == 0) null else p;
}

/// Liga a troca (QA_SUITE=rede). false = endereço recusado, e nada muda.
pub fn usarLocal(url: []const u8) bool {
    comptime std.debug.assert(pode_trocar);
    const p = portaLocal(url) orelse return false;
    len_api = (std.fmt.bufPrint(&buf_api, "http://127.0.0.1:{d}/api/v10", .{p}) catch return false).len;
    len_raiz = (std.fmt.bufPrint(&buf_raiz, "http://127.0.0.1:{d}/api", .{p}) catch return false).len;
    len_ws = (std.fmt.bufPrint(&buf_ws, "ws://127.0.0.1:{d}", .{p}) catch return false).len;
    len_http = (std.fmt.bufPrint(&buf_http, "http://127.0.0.1:{d}", .{p}) catch return false).len;
    porta = p;
    return true;
}

/// A troca está ligada (sempre false fora do executável do QA).
pub inline fn local() bool {
    if (comptime !pode_trocar) return false;
    return porta != 0;
}

pub fn api() []const u8 {
    return if (local()) buf_api[0..len_api] else api_fixa;
}

pub fn apiRaiz() []const u8 {
    return if (local()) buf_raiz[0..len_raiz] else api_raiz_fixa;
}

pub fn gateway() []const u8 {
    return if (local()) buf_ws[0..len_ws] else gateway_fixo;
}

/// "http://127.0.0.1:<porta>" do servidor de mentira (o canal de controle do QA).
pub fn baseLocal() []const u8 {
    return if (local()) buf_http[0..len_http] else "";
}

/// Protocolos que o curl aceita no REST e no WebSocket: só os com TLS no de verdade.
pub fn protocolosRest() [*:0]const u8 {
    return if (local()) "http" else "https";
}

pub fn protocolosWs() [*:0]const u8 {
    return if (local()) "http,ws" else "https,wss";
}

/// O `resume_gateway_url` do READY. No Discord de verdade vale o que ele mandar; com a
/// troca ligada, só um caminho no mesmo servidor local (um endereço de fora é ignorado e
/// a reconexão volta para o gateway local).
pub fn retomadaAceita(url: []const u8) bool {
    if (!local()) return true;
    const base = gateway();
    if (!std.mem.startsWith(u8, url, base)) return false;
    return url.len == base.len or url[base.len] == '/';
}

/// O CDN e o proxy de mídia do Discord no servidor de mentira (imagens da conta grande):
/// "https://cdn.discordapp.com/x" vira "<base>/cdn/cdn.discordapp.com/x". Outro endereço
/// fica como está (null).
pub fn trocaMidia(buf: []u8, base: []const u8, url: []const u8) ?[:0]const u8 {
    const pre = "https://";
    if (!std.mem.startsWith(u8, url, pre)) return null;
    const resto = url[pre.len..];
    const host = resto[0 .. std.mem.indexOfAny(u8, resto, "/?#@:") orelse resto.len];
    if (!std.mem.eql(u8, host, "cdn.discordapp.com") and !std.mem.eql(u8, host, "media.discordapp.net")) return null;
    if (resto.len == host.len or resto[host.len] != '/') return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/cdn/{s}", .{ base, resto }, 0) catch null;
}

/// A URL de mídia que o curl pede: a do servidor de mentira com a troca ligada (só o CDN
/// do Discord), senão null (fica a de verdade, sempre fora do QA).
pub fn midiaLocal(buf: []u8, url: []const u8) ?[:0]const u8 {
    if (!local()) return null;
    return trocaMidia(buf, baseLocal(), url);
}

/// Protocolos do download de mídia: só https no de verdade.
pub fn protocolosMidia() [*:0]const u8 {
    return if (local()) "http,https" else "https";
}

/// Esperas da reconexão (net/discord.zig `run`): com o servidor local, um décimo, para cada
/// queda do QA levar uma fração de segundo e não os 2, 4, 8 s de uma rede de verdade (a
/// conta das esperas em si é testada em net/retry.zig).
pub fn espera(ms: u32) u32 {
    return if (local()) ms / 10 else ms;
}

test "endereço do Discord de mentira: só http em 127.0.0.1 com porta" {
    const t = std.testing;
    try t.expectEqual(@as(?u16, 8080), portaLocal("http://127.0.0.1:8080"));
    try t.expectEqual(@as(?u16, 65535), portaLocal("http://127.0.0.1:65535/"));
    try t.expectEqual(@as(?u16, null), portaLocal("https://127.0.0.1:8080"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://localhost:8080"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1.evil.com:8080"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1:8080@evil.com"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1:8080/api"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1:0"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1:70000"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://127.0.0.1:"));
    try t.expectEqual(@as(?u16, null), portaLocal("http://discord.com"));
    try t.expectEqual(@as(?u16, null), portaLocal("ws://127.0.0.1:8080"));
    // O CDN e o proxy de mídia vão para o servidor local; o resto não muda.
    var b: [128]u8 = undefined;
    try t.expectEqualStrings("http://127.0.0.1:9/cdn/cdn.discordapp.com/avatars/1/a.png?size=128", trocaMidia(&b, "http://127.0.0.1:9", "https://cdn.discordapp.com/avatars/1/a.png?size=128").?);
    try t.expectEqualStrings("http://127.0.0.1:9/cdn/media.discordapp.net/attachments/1/2/x.png", trocaMidia(&b, "http://127.0.0.1:9", "https://media.discordapp.net/attachments/1/2/x.png").?);
    try t.expectEqual(@as(?[:0]const u8, null), trocaMidia(&b, "http://127.0.0.1:9", "https://cdn.discordapp.com.evil.org/x"));
    try t.expectEqual(@as(?[:0]const u8, null), trocaMidia(&b, "http://127.0.0.1:9", "https://cdn.discordapp.com@evil.org/x"));
    try t.expectEqual(@as(?[:0]const u8, null), trocaMidia(&b, "http://127.0.0.1:9", "http://cdn.discordapp.com/x"));
    try t.expectEqual(@as(?[:0]const u8, null), trocaMidia(&b, "http://127.0.0.1:9", "https://example.org/x.png"));
    // O token de mentira não tem a forma de um token do Discord (partes separadas por ponto).
    try t.expect(std.mem.indexOfScalar(u8, token_qa, '.') == null);
}
