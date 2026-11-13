#!/usr/bin/env bash
# QA do "Apagar todos os dados" (Configurações → Avançado). Monta pastas de mentira em
# qa-out/apagar (HOME, XDG_CONFIG_HOME e XDG_CACHE_HOME só desta bateria), a bateria
# apagar clica no botão, cancela e confirma, e daqui de fora, com o processo já
# encerrado, confere o que sumiu e o que tinha que ficar. Depois roda de novo com
# QA_APAGAR_RAIZ apontando para outro lugar: o app não pode apagar nada fora dela.
# Nada aqui usa as pastas ou o chaveiro de quem roda.
set -uo pipefail
cd "$(dirname "$0")/.."
bin=${1:-./.zig-cache/qa/bin/larpercord}
R="$PWD/qa-out/apagar"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

seed() {
    rm -rf "$R" && mkdir -p "$R"/{home,config,cache,data,fora}
    cfg="$R/config/larpercord"; cache="$R/cache/larpercord"
    mkdir -p "$cfg"/{tokens,themes,mascots,plugins/meu,i18n} "$cache"/{messages/1,ffmpeg,lsp-scratch/x} "$R/config/outro-app" "$R/home/.config/larpercord"
    printf 'settings theme="classico"\n' > "$cfg/settings.kdl"
    printf 'account 123\n' > "$cfg/accounts"
    printf 'token-de-mentira\n' > "$cfg/tokens/123" && chmod 600 "$cfg/tokens/123"
    printf 'theme "meu"\n' > "$cfg/themes/meu.kdl"
    printf 'mascote\n' > "$cfg/mascots/meu.kdl"
    printf 'plugin\n' > "$cfg/plugins/meu/main.lua"
    printf 'som\n' > "$cfg/som.wav"
    printf 'cache\n' > "$cache/messages/1/2.bin"
    printf 'dll\n' > "$cache/ffmpeg/avcodec-61.dll"
    printf 'registro\n' > "$cache/debug.log"
    printf 'lsp\n' > "$cache/lsp-scratch/x/a.zig"
    chmod 400 "$cache/messages/1/2.bin"
    # Links lá dentro: sai o link, nunca o que ele aponta.
    printf 'fica\n' > "$R/fora/importante.txt"
    ln -s "$R/fora" "$cfg/themes/link-para-pasta"
    ln -s "$R/fora/importante.txt" "$cache/link-para-arquivo"
    # Outro programa na mesma pasta de configurações.
    printf 'fica\n' > "$R/config/outro-app/keep.txt"
    # O token de antes das várias contas: sempre em ~/.config, mesmo com outro XDG.
    printf 'antigo\n' > "$R/home/.config/larpercord/token"
}

run_app() {
    env -u LARPER_TOKEN -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY \
        QA_APAGAR_RAIZ="$1" HOME="$R/home" XDG_CONFIG_HOME="$R/config" XDG_CACHE_HOME="$R/cache" \
        XDG_DATA_HOME="$R/data" QA_SUITE=apagar timeout 120 "$bin" --qa --theme classico 2>&1
}

echo "apagar todos os dados"
seed
out=$(run_app "$R"); code=$?
line=$(echo "$out" | grep 'passaram')
echo "  bateria: ${line%%(*}"
echo "$line" | grep -q ' 0 falharam' || { bad "a bateria falhou"; echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'; }
[ "$code" = 0 ] && ok "o app fechou sozinho (código 0)" || bad "o app saiu com código $code"
echo "$out" | grep -q 'encerramento demorou' && bad "só saiu pelo vigia de 3 s" || ok "saiu sem precisar do vigia"
[ ! -e "$R/config/larpercord" ] && ok "a pasta das configurações sumiu" || { bad "sobrou a pasta das configurações:"; find "$R/config/larpercord" | sed 's/^/    /'; }
[ ! -e "$R/cache/larpercord" ] && ok "a pasta do cache sumiu (FFmpeg, registro, mensagens)" || { bad "sobrou a pasta do cache:"; find "$R/cache/larpercord" | sed 's/^/    /'; }
[ ! -e "$R/home/.config/larpercord" ] && ok "o token antigo em ~/.config sumiu" || bad "sobrou o token antigo em ~/.config"
[ -f "$R/fora/importante.txt" ] && ok "o que os links apontavam continua lá" || bad "apagou o que um link apontava"
[ -f "$R/config/outro-app/keep.txt" ] && ok "a pasta de outro programa continua lá" || bad "apagou a pasta de outro programa"
for svc in larpercord-account larpercord; do
    echo "$out" | grep -q "no QA o chaveiro fica (secret-tool clear service $svc 2>" && ok "pediria ao chaveiro: secret-tool clear service $svc" || bad "não passou pelo chaveiro ($svc)"
done

echo "apagar fora de QA_APAGAR_RAIZ não apaga nada"
seed
before=$(cd "$R" && find . | sort | md5sum)
out=$(run_app "$R/outra-raiz"); code=$?
line=$(echo "$out" | grep 'passaram')
echo "$line" | grep -q ' 0 falharam' || { bad "a bateria falhou"; echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'; }
after=$(cd "$R" && find . | sort | md5sum)
[ "$before" = "$after" ] && ok "nenhum arquivo saiu" || { bad "apagou fora da raiz:"; diff <(echo "$before") <(echo "$after"); }
echo "$out" | grep -q "só dentro de QA_APAGAR_RAIZ" && ok "e avisou por quê" || bad "não avisou que ficou"

[ "$fail" = 0 ] && echo "apagar: tudo passou" || { echo "apagar: houve falhas"; exit 1; }
