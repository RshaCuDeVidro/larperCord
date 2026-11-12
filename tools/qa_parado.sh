#!/usr/bin/env bash
# Parado não gasta: abre o demo sem janela (sem rede, sem a conta de ninguém), espera
# a abertura assentar e conta quantas vezes o laço da janela acordou em 20 s, pelo
# --stats ("laço: N voltas", que o relógio escreve a cada 2 s com o total). Cada
# quadro precisa de uma volta, e um laço de animação esquecido dá centenas. Sem o
# mascote do canto, o app tem que dormir esperando eventos (o ping da rede, e só);
# com ele e a vida própria desligada, só piscar e um bocejo de madrugada.
# Não conta pelas linhas "N quadros em 2 s": essas só saem no próximo quadro, e o fim
# da abertura (aos 4 s) aparece somado no primeiro quadro depois dela, às vezes no
# meio da janela medida.
# Uso: tools/qa_parado.sh <executável>   (o tools/qa.sh chama com o de depuração)
set -uo pipefail
bin="${1:?uso: tools/qa_parado.sh <executável>}"
cd "$(dirname "$0")/.."
fail=0
measure() {
    local name=$1 max=$2 opts=$3
    local h; h="$PWD/qa-out/parado-$name"
    rm -rf "$h"; mkdir -p "$h/config/larpercord" "$h/data" "$h/cache" "$h/state" "$h/run"; chmod 700 "$h/run"
    printf 'settings theme="classico" close_to_tray=#false voice_timer=#false autoplay_gifs=#false %s\n' "$opts" > "$h/config/larpercord/settings.kdl"
    env -u LARPER_TOKEN -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY SDL_VIDEO_DRIVER=offscreen \
        HOME="$h" XDG_CONFIG_HOME="$h/config" XDG_DATA_HOME="$h/data" XDG_CACHE_HOME="$h/cache" XDG_STATE_HOME="$h/state" XDG_RUNTIME_DIR="$h/run" \
        LARPER_NO_PICS=1 "$bin" --demo --no-live --stats --theme classico > "$h/log" 2>&1 &
    local pid=$!
    sleep 15
    local l0; l0=$(wc -l < "$h/log")
    sleep 20
    local l1; l1=$(wc -l < "$h/log")
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    local t0 t1
    t0=$(head -n "$l0" "$h/log" | grep -o '^info: laço: [0-9]*' | tail -1 | grep -o '[0-9]*$')
    t1=$(head -n "$l1" "$h/log" | grep -o '^info: laço: [0-9]*' | tail -1 | grep -o '[0-9]*$')
    if [ -z "$t0" ] || [ -z "$t1" ]; then
        printf "%-34s sem as linhas do --stats ✗\n" "parado: $name"
        fail=1
        return
    fi
    local turns=$((t1 - t0))
    if [ "$turns" -le "$max" ]; then
        printf "%-34s %s voltas em 20 s (até %s)\n" "parado: $name" "$turns" "$max"
    else
        printf "%-34s %s voltas em 20 s (limite %s) ✗\n" "parado: $name" "$turns" "$max"
        fail=1
    fi
}
measure "sem o mascote" 6 "mascot_pet=#false"
measure "mascote, vida própria desligada" 60 "mascot_pet=#true mascot_life=0"
exit $fail
