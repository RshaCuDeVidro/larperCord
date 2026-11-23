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
# Os fundos procedurais novos e o papel de parede também: parados, não acordam o laço
# nenhuma vez a mais; em movimento, no máximo 15 quadros por segundo (300 em 20 s). A
# linha mostra também o CPU do processo na janela medida (só informa, não reprova).
# Uso: tools/qa_parado.sh <executável>   (o tools/qa.sh chama com o de depuração)
set -uo pipefail
bin="${1:?uso: tools/qa_parado.sh <executável>}"
cd "$(dirname "$0")/.."
fail=0
# Tema de teste com os fundos novos lado a lado e um caminho; o movimento é a opção do
# tema, ligada ou não de começo ($1 = true ou false).
fundos_theme() {
    printf 'theme "qa-fundos" description="Fundos novos e caminho, para medir o laço parado."\n'
    printf 'options { option "movimento" label="Movimento" default=#%s; }\n' "$1"
    cat <<'KDL'
layout {
    stack {
        wallpaper fit=cover dim=0.2
        column {
            row height=300 {
                stack { rain motion="$movimento" motion-fps=30; }
                stack { matrix motion="$movimento" motion-fps=30; }
                stack { waves motion="$movimento" motion-fps=30; }
                stack { particles motion="$movimento" motion-fps=30; }
                shape kind=path width=120 viewbox="0 0 24 24" fill=accent d="M12 1 A11 11 0 1 1 12 23 A11 11 0 1 1 12 1 Z"
            }
            row flex=1 {
                channel-list width=240
                column flex=1 { messages flex=1; composer height=46; }
            }
        }
    }
}
KDL
}
measure() {
    local name=$1 max=$2 opts=$3 theme=${4:-classico} motion=${5:-false}
    local h; h="$PWD/qa-out/parado-$name"
    rm -rf "$h"; mkdir -p "$h/config/larpercord/themes" "$h/data" "$h/cache" "$h/state" "$h/run"; chmod 700 "$h/run"
    if [ "$theme" = qa-fundos ]; then
        fundos_theme "$motion" > "$h/config/larpercord/themes/qa-fundos.kdl"
        # Um BMP de 2×2 (vermelho e azul), o papel de parede: o formato mais simples que o app abre.
        printf '\x42\x4d\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x18\x00\x00\x00\x00\x00\x10\x00\x00\x00\x13\x0b\x00\x00\x13\x0b\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$h/papel.bmp"
        printf '\x00\x00\xff\xff\x00\x00\x00\x00\x00\x00\xff\xff\x00\x00\x00\x00' >> "$h/papel.bmp"
        opts="$opts wallpaper=\"$h/papel.bmp\""
    fi
    printf 'settings theme="%s" close_to_tray=#false voice_timer=#false autoplay_gifs=#false %s\n' "$theme" "$opts" > "$h/config/larpercord/settings.kdl"
    env -u LARPER_TOKEN -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY SDL_VIDEO_DRIVER=offscreen \
        HOME="$h" XDG_CONFIG_HOME="$h/config" XDG_DATA_HOME="$h/data" XDG_CACHE_HOME="$h/cache" XDG_STATE_HOME="$h/state" XDG_RUNTIME_DIR="$h/run" \
        LARPER_NO_PICS=1 "$bin" --demo --no-live --stats --theme "$theme" > "$h/log" 2>&1 &
    local pid=$!
    sleep 15
    local l0; l0=$(wc -l < "$h/log")
    local c0; c0=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    sleep 20
    local l1; l1=$(wc -l < "$h/log")
    local c1; c1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    # Tiques de 1/100 s em 20 s: a porcentagem de um núcleo.
    local cpu; cpu=$(awk -v d=$((c1 - c0)) 'BEGIN{printf "%.1f", d/20}')
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
        printf "%-34s %s voltas em 20 s (até %s), CPU %s%%\n" "parado: $name" "$turns" "$max" "$cpu"
    else
        printf "%-34s %s voltas em 20 s (limite %s), CPU %s%% ✗\n" "parado: $name" "$turns" "$max" "$cpu"
        fail=1
    fi
}
measure "sem o mascote" 6 "mascot_pet=#false"
measure "mascote, vida própria desligada" 60 "mascot_pet=#true mascot_life=0"
measure "fundos novos e papel de parede" 6 "mascot_pet=#false" qa-fundos
# motion-fps=30 no tema: o app limita a 15.
measure "fundos novos em movimento" 340 "mascot_pet=#false" qa-fundos true
exit $fail
