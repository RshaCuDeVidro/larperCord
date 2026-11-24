#!/usr/bin/env bash
# Os temas embutidos desenham igual em dois executáveis: o print (`--shot`) de cada tema
# embutido, no escuro e no claro, em português em 100% e em japonês em 125%, sai igual byte
# por byte. Os dois PNG são gravados pelo mesmo SDL, então pixels iguais dão arquivos
# iguais; quando não dão, o ImageMagick (se houver) conta os pixels e grava a diferença.
# Serve para mostrar que uma mudança no desenho não mexe em quem não usa o recurso novo
# (um tema sem `parts`, por exemplo), comparando com o executável de antes dela:
#
#   tools/pixels_antes.sh EXECUTAVEL_ANTES EXECUTAVEL_DEPOIS [PASTA]
#
# PIXELS_TEMAS="classico terminal" limita os temas. Não abre janela (SDL offscreen) e não
# fala com o Discord: é a demonstração, sem token, sem as mensagens automáticas, com a
# hora das mensagens fixa e uma pasta de configurações só para cada executável.
set -uo pipefail
cd "$(dirname "$0")/.."
if [ $# -lt 2 ]; then
    echo "uso: $0 EXECUTAVEL_ANTES EXECUTAVEL_DEPOIS [PASTA]"
    exit 2
fi
antes=$(realpath "$1")
depois=$(realpath "$2")
out="${3:-qa-out/pixels}"
rm -rf "$out" && mkdir -p "$out"
out=$(realpath "$out")
temas="${PIXELS_TEMAS:-classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino}"
# A mesma hora nas mensagens da demonstração para os dois.
epoch=$(($(date +%s) * 1000))

# Uma pasta de configurações para cada executável, com a escala da interface.
ambiente() {
    local e="$out/env-$1"
    mkdir -p "$e"/{home,config/larpercord,cache,data,state,run,tmp} && chmod 700 "$e/run"
    printf 'settings theme="classico" ui_scale=%s\n' "$2" > "$e/config/larpercord/settings.kdl"
}

shot() { # nome executável arquivo opções…
    local e="$out/env-$1" bin="$2" png="$3"
    shift 3
    env -u LARPER_TOKEN -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS -u XDG_CURRENT_DESKTOP \
        SDL_VIDEO_DRIVER=offscreen LARPER_DEMO_EPOCH_MS="$epoch" \
        HOME="$e/home" XDG_CONFIG_HOME="$e/config" XDG_CACHE_HOME="$e/cache" XDG_DATA_HOME="$e/data" \
        XDG_STATE_HOME="$e/state" XDG_RUNTIME_DIR="$e/run" TMPDIR="$e/tmp" \
        timeout 120 "$bin" --no-live --shot "$png" "$@" > /dev/null 2>&1
}

iguais=0
diferentes=0
for passo in "pt 1" "ja 1.25"; do
    set -- $passo
    lang=$1
    escala=$2
    ambiente antes "$escala"
    ambiente depois "$escala"
    for t in $temas; do
        for modo in escuro claro; do
            nome="$lang-$escala-$t-$modo"
            a="$out/antes-$nome.png"
            b="$out/depois-$nome.png"
            shot antes "$antes" "$a" --theme "$t" --mode "$modo" --lang "$lang"
            shot depois "$depois" "$b" --theme "$t" --mode "$modo" --lang "$lang"
            if [ ! -s "$a" ] || [ ! -s "$b" ]; then
                echo "SEM PRINT  $nome"
                diferentes=$((diferentes + 1))
            elif cmp -s "$a" "$b"; then
                iguais=$((iguais + 1))
            else
                n="?"
                if command -v magick > /dev/null; then
                    n=$(magick compare -metric AE "$a" "$b" "$out/diferenca-$nome.png" 2>&1 > /dev/null)
                fi
                echo "DIFERENTE  $nome ($n pixels)"
                diferentes=$((diferentes + 1))
            fi
        done
    done
done
echo "$iguais iguais, $diferentes diferentes (prints em $out)"
[ "$diferentes" -eq 0 ]
