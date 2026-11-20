#!/usr/bin/env bash
# QA completo: a bateria geral no tema classico, a tela de login e a bateria
# por tema em todos os temas, no escuro e no claro. Não abre janela. Prints em qa-out/.
#
# QA_PARTE: só um pedaço, para a CI dividir o QA entre várias máquinas ao mesmo tempo:
# "geral", "outras" (o resto das baterias, o login e os scripts) ou "temas:classico,vidro"
# (a bateria por tema só nesses). Sem ela, tudo. QA_BIN: um executável já compilado
# (com o robô), no lugar de compilar aqui.
set -uo pipefail
cd "$(dirname "$0")/.."
parte="${QA_PARTE:-}"
if [ -n "${QA_BIN:-}" ]; then
    bin="$QA_BIN"
else
    # Debug (com as checagens de segurança), instalado à parte para não trocar
    # o executável de zig-out/ (que é ReleaseFast).
    zig build -Doptimize=debug -p .zig-cache/qa || exit 1
    bin=./.zig-cache/qa/bin/larpercord
fi
rm -rf qa-out && mkdir -p qa-out
total_fail=0
run() {
    local label="$1"; shift
    # Cada bateria começa sem o cache de mensagens da anterior (QA_KEEP_CACHE: a que
    # abre pelo que a anterior gravou).
    [ -n "${QA_KEEP_CACHE:-}" ] || rm -rf qa-out/cache
    local out; out=$("$@" 2>&1 | grep -v '^info:')
    local line; line=$(echo "$out" | grep 'passaram')
    local summary="${line%%(*}"
    printf "%-24s %s\n" "$label" "${summary:-saiu antes do fim, sem o resumo}"
    if ! echo "$line" | grep -q ' 0 falharam'; then
        total_fail=1
        if [ -z "$line" ]; then
            # Caiu ou travou no meio: o fim da saída mostra onde (o panic do Debug).
            echo "$out" | tail -n 25 | sed 's/^/    /'
        else
            echo "$out" | sed -n '/^Falhas:/,$p' | sed 's/^/    /'
        fi
    fi
}
temas="classico vidro terminal subsolo orbital editorial bolhas zen papel escritorio cupertino"
case "$parte" in
    "" | geral | outras) ;;
    temas:*) temas="${parte#temas:}"; temas="${temas//,/ }" ;;
    *) echo "QA_PARTE desconhecida: $parte (geral, outras ou temas:<tema>,<tema>)"; exit 1 ;;
esac
if [ -z "$parte" ] || [ "$parte" = geral ]; then
run "geral (classico)" $bin --qa --theme classico
fi
if [ -z "$parte" ] || [ "$parte" = outras ]; then
QA_SUITE=extras LARPER_NO_FFMPEG=1 run "extras" $bin --qa --theme classico
QA_SUITE=envio run "envio" $bin --qa --theme classico
# Um tema da pasta do usuário que estende outro (extends, vars) e recarrega quando a base muda.
QA_SUITE=tema-herda run "tema que estende outro" $bin --qa --theme classico
QA_SUITE=limites run "limites" $bin --qa --theme classico
# Pedidos de mensagem e grupo: aceitar, recusar e sair mudam a lista de DMs para o resto.
QA_SUITE=social run "social" $bin --qa --theme classico
QA_SUITE=midia run "midia" $bin --qa --theme classico
# Rich Presence: o discord-ipc num XDG_RUNTIME_DIR só do QA (nunca o de um Discord aberto).
mkdir -p qa-out/run && chmod 700 qa-out/run
QA_SUITE=presenca XDG_RUNTIME_DIR="$PWD/qa-out/run" run "presença" $bin --qa --theme classico
QA_SUITE=moderacao run "moderação" $bin --qa --theme classico
QA_SUITE=entrada run "entrada" $bin --qa --theme classico
QA_SUITE=interacoes run "interações" $bin --qa --theme classico
# Tempo da call nos canais de voz: op 43, formato, e quando o app acorda por ele.
QA_SUITE=cronometro run "tempo da call" $bin --qa --theme classico
# Perfil de servidor (#19): apelido e foto de lá em cada lugar, o global fora dele.
QA_SUITE=perfil run "perfil do servidor" $bin --qa --theme classico
# Tela da call: a grade com cada um, os botões, ir e voltar, muita gente e a DM.
QA_SUITE=call run "tela da call" $bin --qa --theme classico
QA_SUITE=flutuante run "janela flutuante" $bin --qa --theme classico
# larpercord ctl: a porta da demonstração (ctl-demo.port) só abre com LARPER_CTL.
QA_SUITE=ctl LARPER_CTL=1 run "controle externo" $bin --qa --theme classico
# Imagem privada: colar, cortar e esconder no editor da bandeja (o PNG que sai conferido
# pixel a pixel) e a localização que sai antes de enviar, ligada e desligada; depois o
# editor num tema claro, em japonês e com a interface em 125%.
QA_SUITE=imagem run "imagem privada" $bin --qa --theme classico
QA_SUITE=imagem-tema QA_PREFIX=papel-claro-ja- run "imagem (japonês, 125%)" $bin --qa --theme papel --mode claro --lang ja
# Inspetor (F12): elementos, escolher na tela, comandos, rede, gateway, eventos, fechar.
QA_SUITE=inspetor run "inspetor" $bin --qa --theme classico
# Arrastar alguém da call para outro canal de voz (e soltar fora não mover).
QA_SUITE=arrastar run "arrastar para mover" $bin --qa --theme classico
# Notificações que respondem: um dbus-daemon particular e o servidor de mentira do próprio
# binário (o do KDE, com caixa de texto, e o do GNOME), sem nunca usar a sessão de quem roda.
QA_SUITE=notificacao run "notificações" $bin --qa --theme classico
# Op 8: os membros dos autores das páginas (DM nunca, no máximo um por servidor a cada
# 30 s, as páginas se juntando, sem repetir), e o apelido e a cor do cargo numa
# mensagem antiga depois da resposta.
QA_SUITE=membros run "membros das páginas" $bin --qa --theme classico
# Abrir pelo retrato em disco: a primeira grava, a segunda abre por ele com o READY
# atrasado, sem apagar o cache entre as duas (as conversas da demonstração são as mesmas).
epoch=$(( $(date +%s) * 1000 ))
# (O conjunto de abas em uso volta junto: QA_TABSETS_READ lê o arquivo desde a abertura.)
QA_TABSETS_READ=1 LARPER_DEMO_EPOCH_MS=$epoch QA_SUITE=cache-a run "retrato (grava)" $bin --qa --theme classico
QA_KEEP_CACHE=1 QA_TABSETS_READ=1 LARPER_DEMO_EPOCH_MS=$epoch LARPER_DEMO_READY_MS=2500 QA_SUITE=cache-b run "retrato (abre)" $bin --qa --theme classico
QA_SUITE=mascote run "mascote" $bin --qa --theme classico
# Lembretes: o relógio adiantado pelo QA, o aviso, o mascote e a notificação; depois dois
# processos: o que fica gravado volta, e o que venceu com o app fechado avisa atrasado.
QA_SUITE=lembretes run "lembretes" $bin --qa --theme classico
# (O mesmo começo da demonstração nos dois: as mensagens têm os mesmos IDs.)
epoch=$(( $(date +%s) * 1000 ))
LARPER_DEMO_EPOCH_MS=$epoch QA_SUITE=lembretes-a run "lembretes (antes)" $bin --qa --theme classico
LARPER_DEMO_EPOCH_MS=$epoch QA_LEMBRETES_READ=1 QA_SUITE=lembretes-b run "lembretes (depois)" $bin --qa --theme classico
# Apagar todos os dados: pastas de mentira em qa-out/apagar, conferidas de fora depois que
# o app fecha, e nada apagado fora delas.
bash tools/qa_apagar.sh "$bin" || total_fail=1
# Parado não gasta: quadros desenhados com o app à toa (o --stats do demo).
bash tools/qa_parado.sh "$bin" || total_fail=1
QA_SUITE=render run "renderizador" $bin --qa --theme classico
QA_SUITE=atalhos run "atalhos personalizáveis" $bin --qa --theme classico
# Um settings.kdl que pede um renderizador que não existe: abre no automático e avisa.
mkdir -p qa-out/render-cfg/larpercord && printf 'settings renderer="naoexiste"\n' > qa-out/render-cfg/larpercord/settings.kdl
QA_SUITE=render-falha XDG_CONFIG_HOME="$PWD/qa-out/render-cfg" run "renderizador que não abre" $bin --qa --theme classico
# Fontes reserva (CJK) só quando um texto pede, e o mixer da call: fora da geral.
QA_SUITE=escritas run "escritas" $bin --qa --theme classico
# Sem fonte nenhuma no sistema (o fontconfig sem pasta de fontes): abre com a do ImGui.
printf '<?xml version="1.0"?>\n<fontconfig><cachedir>%s/qa-out/fc-cache</cachedir></fontconfig>\n' "$PWD" > qa-out/sem-fontes.conf
QA_SUITE=sem-fontes FONTCONFIG_FILE="$PWD/qa-out/sem-fontes.conf" run "sem fontes" $bin --qa --theme classico
QA_SUITE=voice run "mixer da call" $bin --qa --theme classico
# As outras baterias do qa_runner.zig rodam dentro da geral ou da "tema" (threads, conta,
# proxy, chamada, voz, dispositivos, rtl...) ou têm script próprio: lsp-quit em
# tools/qa_lsp.sh, bandeja-* em tools/qa_bandeja.sh, plugins-tls em tools/qa_http_tls.sh.
# ffmpeg, plugins-real, vitrine e lsp-real usam a rede ou programas de verdade.
# Plugins: o que fica gravado ao fechar continua lá ao abrir de novo (outro processo).
QA_SUITE=plugins-a run "plugins (antes)" $bin --qa
sleep 2.5
QA_SUITE=plugins-b run "plugins (depois)" $bin --qa
for m in escuro claro; do
    QA_SUITE=login QA_PREFIX="$m-" run "login ($m)" $bin --qa --mode "$m"
done
fi
if [ -z "$parte" ] || [[ "$parte" == temas:* ]]; then
for t in $temas; do
    for m in escuro claro; do
        QA_SUITE=tema QA_PREFIX="$t-$m-" run "$t ($m)" $bin --qa --theme "$t" --mode "$m"
    done
done
fi
[ "$total_fail" = 0 ] && echo "tudo passou ✓" || { echo "houve falhas"; exit 1; }
