//! Identidade HTTP do cliente web do Discord.
//!
//! O app se apresenta como o cliente web (Chrome no Windows) porque é o
//! formato que o gateway e a API usam para um cliente que não é bot. Manter
//! tudo num lugar só evita o clássico "atualizei o User-Agent num arquivo e
//! esqueci no outro": inconsistência entre UA, `X-Super-Properties` e
//! `Sec-CH-UA` é justamente o que denuncia um cliente que não é navegador. O mesmo
//! vale um nível abaixo: o aperto de mão TLS e o HTTP/2 seguem o mesmo Chrome
//! (src/platform/tls_chrome.c e tools/curl-chrome-h2.patch).
//!
//! Isto não é uma garantia contra banimento: cliente de terceiro viola os
//! Termos do Discord e a decisão final é sempre da conta. O objetivo aqui é
//! só não entregar de graça um fingerprint quebrado.
const std = @import("std");

/// Chrome 156 no Windows 10/11. É a mesma versão citada nas propriedades e
/// no `Sec-CH-UA`; mudar a maior aqui muda nos três lugares. É também a do aperto de
/// mão TLS (src/platform/tls_chrome.c, medido com tools/tls_check.sh): ao trocar,
/// medir de novo.
pub const browser_major = "156";
pub const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" ++ browser_major ++ ".0.0.0 Safari/537.36";

/// Build number do bundle web do Discord. Confira em https://discord.com/login
/// (`buildNumber` no JS) de vez em quando: o cliente web manda o build dele,
/// e um número muito velho é mais um sinal de cliente que ficou parado.
pub const build_number = 667580;

/// `properties` do IDENTIFY e base do `X-Super-Properties` (que é este JSON
/// em base64). O `browser_user_agent` sai da mesma constante do UA.
pub const super_properties = std.fmt.comptimePrint(
    "{{\"os\":\"Windows\",\"browser\":\"Chrome\",\"device\":\"\",\"system_locale\":\"en-US\",\"has_client_mods\":false,\"browser_user_agent\":\"{s}\",\"browser_version\":\"{s}.0.0.0\",\"os_version\":\"10\",\"referrer\":\"\",\"referring_domain\":\"\",\"referrer_current\":\"\",\"referring_domain_current\":\"\",\"release_channel\":\"stable\",\"client_build_number\":{d},\"client_event_source\":null}}",
    .{ user_agent, browser_major, build_number },
);

/// `Sec-CH-UA` do Chrome 156: a marca GREASE, a ordem e a versão dela mudam a cada
/// versão maior (medido no Chromium 156, que manda o mesmo, com o nome dele no lugar
/// de "Google Chrome").
pub const sec_ch_ua = std.fmt.comptimePrint(
    "\"Not:A-Brand\";v=\"8\", \"Chromium\";v=\"{s}\", \"Google Chrome\";v=\"{s}\"",
    .{ browser_major, browser_major },
);

test "identidade web: UA, propriedades e client hints contam a mesma versão" {
    try std.testing.expect(std.mem.indexOf(u8, user_agent, browser_major) != null);
    try std.testing.expect(std.mem.indexOf(u8, super_properties, user_agent) != null);
    try std.testing.expect(std.mem.indexOf(u8, super_properties, "\"client_build_number\":667580") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec_ch_ua, browser_major) != null);
}
