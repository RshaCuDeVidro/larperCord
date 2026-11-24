#!/usr/bin/env bash
# Os temas embutidos desenham igual em dois executáveis: o print (`--shot`) de cada tema
# embutido, no escuro e no claro, em português em 100% e em japonês em 125%, comparado
# pixel por pixel. Serve para mostrar que uma mudança no desenho não mexe em quem não usa o
# recurso novo (um tema sem `parts`, por exemplo), comparando com o executável de antes dela:
#
#   tools/pixels_antes.sh EXECUTAVEL_ANTES EXECUTAVEL_DEPOIS [PASTA]
#
# O mesmo executável não sai igual de um print para o outro em alguns pixels (uma figurinha
# da demonstração, o cursor, o relógio do cupertino e do orbital): cada executável tira
# PIXELS_VEZES prints (6) de cada tela, e o que muda entre os prints de um mesmo executável
# fica de fora da comparação (a conta aparece no resultado). Todo o resto tem de ser igual
# nos dois; um pixel que só às vezes muda pode escapar e aparecer como diferente numa
# rodada e igual na outra (rode de novo a tela que deu diferente). Precisa do Python com o
# Pillow. PIXELS_TEMAS="classico terminal" limita os temas.
#
# Não abre janela (SDL offscreen) e não fala com o Discord: é a demonstração, sem token,
# sem as mensagens automáticas, com a hora das mensagens fixa e uma pasta de configurações
# só para cada executável.
set -uo pipefail
cd "$(dirname "$0")/.."
if [ $# -lt 2 ]; then
    echo "uso: $0 EXECUTAVEL_ANTES EXECUTAVEL_DEPOIS [PASTA]"
    exit 2
fi
if ! python3 -c "import PIL" 2> /dev/null; then
    echo "precisa do Python com o Pillow (python3 -m pip install pillow)"
    exit 2
fi
antes=$(realpath "$1")
depois=$(realpath "$2")
out="${3:-qa-out/pixels}"
rm -rf "$out" && mkdir -p "$out"
out=$(realpath "$out")
temas="${PIXELS_TEMAS:-classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino}"
vezes="${PIXELS_VEZES:-6}"
# A mesma hora nas mensagens da demonstração para os dois.
epoch=$(($(date +%s) * 1000))

# Uma pasta de configurações para cada executável, com a escala da interface e sem o que
# muda sozinho de um print para o outro: o GIF, as animações, o tempo da call, o mascote
# (que tem humor próprio) e a barra de status (com a memória e o tempo do quadro, que não
# são iguais nos dois).
ambiente() {
    local e="$out/env-$1"
    mkdir -p "$e"/{home,config/larpercord,cache,data,state,run,tmp} && chmod 700 "$e/run"
    printf 'settings theme="classico" ui_scale=%s autoplay_gifs=#false reduce_motion=#true voice_timer=#false mascot_life=0 mascot_pet=#false show_status_bar=#false\n' "$2" > "$e/config/larpercord/settings.kdl"
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

# Compara os prints de uma tela: "iguais" ou "diferentes", com os pixels que ficaram de fora.
compara() { # nome
    python3 - "$out" "$1" "$vezes" << 'PY'
import sys
from PIL import Image, ImageChops
out, nome, vezes = sys.argv[1], sys.argv[2], int(sys.argv[3])
def abre(lado, i):
    return Image.open(f"{out}/{lado}-{nome}-{i}.png").convert("RGB")
a = [abre("antes", i) for i in range(vezes)]
b = [abre("depois", i) for i in range(vezes)]
if a[0].size != b[0].size:
    print("diferentes: tamanho", a[0].size, b[0].size)
    sys.exit(0)
def muda(x, y):
    return ImageChops.difference(x, y).convert("L").point(lambda v: 255 if v else 0)
instavel = Image.new("L", a[0].size, 0)
for lista in (a, b):
    for i in range(1, vezes):
        instavel = ImageChops.lighter(instavel, muda(lista[0], lista[i]))
dif = ImageChops.subtract(muda(a[0], b[0]), instavel)
n = dif.histogram()[255]
fora = instavel.histogram()[255]
if n:
    dif.save(f"{out}/diferenca-{nome}.png")
    print(f"diferentes: {n} pixels em {dif.getbbox()}, {fora} instáveis de fora")
else:
    print(f"iguais ({fora} pixels instáveis de fora)")
PY
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
            falta=0
            for i in $(seq 0 $((vezes - 1))); do
                shot antes "$antes" "$out/antes-$nome-$i.png" --theme "$t" --mode "$modo" --lang "$lang"
                shot depois "$depois" "$out/depois-$nome-$i.png" --theme "$t" --mode "$modo" --lang "$lang"
                [ -s "$out/antes-$nome-$i.png" ] && [ -s "$out/depois-$nome-$i.png" ] || falta=1
            done
            if [ "$falta" = 1 ]; then
                echo "SEM PRINT   $nome"
                diferentes=$((diferentes + 1))
                continue
            fi
            r=$(compara "$nome")
            case "$r" in
                iguais*) iguais=$((iguais + 1)) ;;
                *) diferentes=$((diferentes + 1)) ;;
            esac
            printf '%-30s %s\n' "$nome" "$r"
        done
    done
done
echo "$iguais iguais, $diferentes diferentes (prints em $out)"
[ "$diferentes" -eq 0 ]
