#!/usr/bin/env bash
# Compara a impressão das conexões do larperCord com a de um Chrome: o JA4 do aperto de
# mão TLS (src/platform/tls_chrome.c) e a do HTTP/2 (tools/curl-chrome-h2.patch, só no
# curl que o tools/linux_deps.sh compila). Sem token: o binário só fala com tls.peet.ws,
# que devolve o que recebeu.
#   tools/tls_check.sh [binário]        (padrão: zig-out/bin/larpercord)
# Os valores são os do Chromium 156 medidos no mesmo site. Ao trocar browser_major em
# src/net/web_client.zig, medir um Chrome dessa versão e trocar aqui e em
# src/net/tls_ja4.zig.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${1:-zig-out/bin/larpercord}
chrome_ja4=t13d1516h2_8daaf6152771_806a8c22fdea
chrome_h2='1:65536;2:0;4:6291456;6:262144|15663105|0|m,a,s,p'

out=$("$bin" --tls-fingerprint 2>&1) || { echo "$out" >&2; exit 1; }
read -r ja4 h2 < <(printf '%s' "$out" | python3 -I -c '
import sys, json
d = json.load(sys.stdin)
print(d["tls"]["ja4"], (d.get("http2") or {}).get("akamai_fingerprint") or "sem-http2")')

ok=0
if [ "$ja4" = "$chrome_ja4" ]; then echo "TLS (JA4)  igual ao Chrome: $ja4"; else echo "TLS (JA4)  diferente: $ja4 (Chrome: $chrome_ja4)"; ok=1; fi
if [ "$h2" = "$chrome_h2" ]; then echo "HTTP/2     igual ao Chrome: $h2"; else echo "HTTP/2     diferente: $h2 (Chrome: $chrome_h2)"; ok=1; fi
exit $ok
