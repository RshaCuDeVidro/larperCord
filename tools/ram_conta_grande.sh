#!/usr/bin/env bash
# RAM e CPU numa conta grande, sem conta de ninguém: o executável do QA abre no Discord de
# mentira com 52 servidores e ~2.450 canais (tools/discord_falso.py --conta grande, gerado por
# tools/conta_grande.py) e a bateria QA_SUITE=conta-grande usa o app por uns 4 minutos
# (src/qa_conta_grande.zig). Enquanto isso, a cada segundo, o /proc do processo: PSS,
# anônima, pico (VmHWM) e CPU. No fim, uma tabela com a RAM por parte em cada fase.
#
# Para medir como na release, o executável otimizado com o robô e o Discord local:
#   zig build -Doptimize=fast -Dqa=true -Dqa-rede=true -p .zig-cache/rf
#   tools/ram_conta_grande.sh .zig-cache/rf/bin/larpercord [rótulo]
# (o de debug também serve, mas o alocador e os tempos são outros).
#
# O renderizador é o OpenGL, como no desktop (LARPER_RENDERER=opengles2, vulkan ou software
# mede outro): sem janela, o automático do SDL escolheria o OpenGL ES, que com o driver da
# NVIDIA aloca ~50 MB a mais. RAM_CG_NOMES=1: a glibc dá nome aos mapeamentos dela
# (glibc.mem.decorate_maps), e no smaps.txt da saída o heap e as pilhas aparecem com nome.
#
# Roda numa rede só com o 127.0.0.1 (unshare -n): nada sai da máquina, nem as imagens (o CDN
# também é o servidor local). Sem janela (SDL offscreen) e com HOME e XDG próprios. A saída
# fica em qa-out/conta-grande-<rótulo>/.
set -uo pipefail
cd "$(dirname "$0")/.."
bin="${1:-./.zig-cache/qa/bin/larpercord}"
rotulo="${2:-medida}"
[ -x "$bin" ] || { echo "conta grande: falta o executável ($bin)"; exit 1; }
command -v python3 >/dev/null || { echo "conta grande: precisa de python3"; exit 1; }

# Uma rede só com o loopback: refaz este script dentro dela.
if [ -z "${RAM_CG_DENTRO:-}" ]; then
    command -v unshare >/dev/null || { echo "conta grande: precisa do unshare (util-linux) para isolar a rede"; exit 1; }
    exec env RAM_CG_DENTRO=1 unshare --map-current-user --keep-caps --net -- "$0" "$@"
fi
ip link set lo up || { echo "conta grande: precisa do ip (iproute2) para ligar o 127.0.0.1"; exit 1; }
# Conferido: sem rota para fora (o servidor de verdade não é alcançável daqui).
if ip route 2>/dev/null | grep -q default; then echo "conta grande: a rede não ficou isolada"; exit 1; fi

out="qa-out/conta-grande-$rotulo"
rm -rf "$out" && mkdir -p "$out"/{home,config,cache,data,state,run,tmp} && chmod 700 "$out/run"
token=larper-qa-token-falso-nao-e-do-discord
coproc SRV { exec python3 -I tools/discord_falso.py --conta grande; }
srv_pid=$SRV_PID
trap 'kill "$srv_pid" 2>/dev/null' EXIT
port=""
read -r -t 20 port <&"${SRV[0]}" || true
[[ "$port" =~ ^[0-9]+$ ]] || { echo "conta grande: o Discord de mentira não subiu"; exit 1; }

env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
    SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-offscreen}" HOME="$PWD/$out/home" XDG_CONFIG_HOME="$PWD/$out/config" \
    XDG_CACHE_HOME="$PWD/$out/cache" XDG_DATA_HOME="$PWD/$out/data" XDG_STATE_HOME="$PWD/$out/state" \
    XDG_RUNTIME_DIR="$PWD/$out/run" TMPDIR="$PWD/$out/tmp" \
    QA_SUITE=conta-grande LARPER_QA_DISCORD="http://127.0.0.1:$port" LARPER_TOKEN="$token" \
    LARPER_RENDERER="${LARPER_RENDERER:-opengl}" ${RAM_CG_NOMES:+GLIBC_TUNABLES=glibc.mem.decorate_maps=1} \
    "$bin" --qa --stats --theme classico > "$out/app.log" 2>&1 &
app_pid=$!

# As amostras do /proc, de segundo em segundo, até o app sair (e ele sai em 15 min de qualquer
# jeito: o limite fica aqui, para o PID medido ser o do app e não o de um timeout).
python3 -I - "$app_pid" "$out/amostras.tsv" <<'EOF'
import os, signal, sys, time
pid, path = int(sys.argv[1]), sys.argv[2]
tck = os.sysconf("SC_CLK_TCK")
t0 = time.monotonic()
with open(path, "w") as out:
    out.write("s\tpss_kb\tanon_kb\tfile_kb\trss_kb\thwm_kb\tcpu_s\n")
    while True:
        if time.monotonic() - t0 > 900:
            os.kill(pid, signal.SIGKILL)
            break
        try:
            roll = open(f"/proc/{pid}/smaps_rollup").read()
            status = open(f"/proc/{pid}/status").read()
            stat = open(f"/proc/{pid}/stat").read()
        except OSError:
            break
        f = {}
        for line in (roll + status).splitlines():
            k, _, v = line.partition(":")
            v = v.split()
            if v and v[0].isdigit():
                f[k] = int(v[0])
        rest = stat[stat.rindex(")") + 2:].split()
        cpu = (int(rest[11]) + int(rest[12])) / tck
        out.write(f"{time.monotonic() - t0:.1f}\t{f.get('Pss', 0)}\t{f.get('Pss_Anon', 0)}\t{f.get('Pss_File', 0)}\t"
                  f"{f.get('VmRSS', 0)}\t{f.get('VmHWM', 0)}\t{cpu:.2f}\n")
        out.flush()
        # O mapa inteiro de 10 em 10 s: o último fica para quem quiser olhar mapeamento por mapeamento.
        if int(time.monotonic() - t0) % 10 == 0:
            try:
                data = open(f"/proc/{pid}/smaps").read()
                with open(os.path.join(os.path.dirname(path), "smaps.txt"), "w") as sm:
                    sm.write(data)
            except OSError:
                pass
        time.sleep(1)
EOF
wait "$app_pid"
rc=$?
python3 -I - "$out" "$bin" "$rc" <<'EOF' | tee "$out/resumo.txt"
import os, re, sys
out, binp, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
log = open(f"{out}/app.log", errors="replace").read()
rows = [l.split("\t") for l in open(f"{out}/amostras.tsv").read().splitlines()[1:]]
rows = [[float(x) for x in r] for r in rows if len(r) == 7]
res = re.search(r"(\d+) passaram, (\d+) falharam", log)
print(f"executável: {binp} ({os.path.getsize(binp) / 1e6:.2f} MB), saída {rc}")
print(f"bateria: {res.group(0) if res else 'sem o resumo (saiu antes do fim)'}")
rend = re.search(r"renderer: (\S+)", log)
print(f"renderizador: {rend.group(1) if rend else '?'}")
if rows:
    mb = lambda kb: kb / 1024
    last = rows[-1]
    tail = [r for r in rows if r[0] >= last[0] - 60]
    print(f"amostras: {len(rows)} em {last[0]:.0f} s")
    print(f"PSS: pico {mb(max(r[1] for r in rows)):.1f} MB, média do último minuto {mb(sum(r[1] for r in tail) / len(tail)):.1f} MB")
    print(f"anônima: pico {mb(max(r[2] for r in rows)):.1f} MB, média do último minuto {mb(sum(r[2] for r in tail) / len(tail)):.1f} MB")
    print(f"pico do RSS (VmHWM): {mb(last[5]):.1f} MB")
    idle = last[6] - tail[0][6]
    print(f"CPU: {last[6]:.1f} s no total, {idle / max(1, last[0] - tail[0][0]) * 100:.1f}% no último minuto (parado, com o tráfego)")
print("RAM por parte em cada fase (do próprio app, MB):")
fases = {}
for m in re.finditer(r"ram\[([^\]]+)\] (.*)", log):
    fases.setdefault(m.group(1), []).append(m.group(2).strip())
for f, lines in fases.items():
    print(f"  [{f}]")
    for l in lines:
        print(f"    {l}")
fails = re.search(r"Falhas:.*", log, re.S)
if fails:
    print(fails.group(0)[:2000])
EOF
python3 -I -c 'import json,sys,urllib.request; print("servidor:", json.load(urllib.request.urlopen(sys.argv[1] + "/ctl/conta", timeout=5)))' "http://127.0.0.1:$port" 2>/dev/null
[ "$rc" = 0 ]
