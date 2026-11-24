# Inspetor

[English](inspector.md) · **Português**

As ferramentas de desenvolvedor do larperCord. Aperte **F12** (ou **Ctrl+Shift+I**) para abrir, ou **Ctrl+Shift+E** para ir direto a escolher um elemento na tela. Os dois atalhos podem ser trocados em Configurações → Atalhos de teclado. Ele também está na paleta de comandos e em Configurações → Avançado.

Ele fica encaixado à direita ou embaixo, e o app cabe no resto da janela. Também pode ficar solto por cima. Arraste a beirada para mudar o tamanho.

Fechado e nunca aberto, não custa nada: nem memória, nem trabalho a mais em cada quadro. Tudo o que ele grava fica na memória e some ao fechar o app. O token nunca é gravado: o cabeçalho `Authorization` não é guardado, o `token` do IDENTIFY, do RESUME e do gateway de voz aparece como asteriscos, e qualquer coisa com cara de token é mascarada.

## Abas

- **Elementos**: o quadro atual como árvore. Primeiro vêm os pedaços do layout do tema (`row`, `column`, cada componente) e, dentro de cada um, o que ele desenhou: caixas, textos, imagens e áreas clicáveis. Passe o mouse numa linha e o elemento acende na tela. Escolha um pedaço e você vê:
  - o arquivo e a linha do nó do `.kdl` que o desenha, com todas as propriedades;
  - a parte do tema de que ele faz parte, com os estados de agora (`channel.item:hover:selected`), o nome que o bloco
    `parts` de um tema usa ([Partes e estados](../themes/README.pt-BR.md#partes-e-estados));
  - cada cor com o nome no tema (`accent`, `muted`, `sidebar 50%`…) e o hex;
  - a fonte, o tamanho e o contraste de um texto com o fundo embaixo dele (WCAG AA/AAA);
  - o id, o rótulo e o estado de um item clicável do Dear ImGui, e o nome da marca do QA nos builds com o robô;
  - quantos microssegundos aquele componente levou para desenhar.

  A busca acha elementos por texto, componente, cor ou marca do QA.
- **Console**: as linhas de log do app (as mesmas do registro de depuração, sem precisar ligá-lo), com filtro por nível e texto, e os avisos e erros em destaque. Embaixo fica a linha de comandos; `help` lista os comandos.
- **Rede**: cada pedido HTTP: a API do Discord, as imagens e vídeos, os plugins. Cada linha tem o status, o tempo, o tamanho e quanto o pedido esperou o rate limit. Escolha um para ver os cabeçalhos (os do rate limit numa seção própria), o que foi enviado, a resposta em árvore de JSON e quanto durou cada fase (nome, conexão, TLS, primeiro byte). **Copiar como curl** põe `$LARPER_TOKEN` onde iria o token.
- **Gateway**: cada quadro do WebSocket do Discord e do gateway de voz, com a direção, o nome do op (o nome do evento, no Dispatch), o seq e o tamanho. Os heartbeats ficam escondidos por padrão. Escolha um para abrir o conteúdo em árvore. Sem nada escolhido, mostra quantos de cada tipo chegaram, os bytes que entraram e saíram e a latência do heartbeat.
- **Eventos**: o que a interface pediu ao app (ações), o que o app pediu à rede (comandos) e o que a rede entregou (eventos), na ordem em que aconteceram.
- **Desempenho**: o tempo de CPU dos últimos 300 quadros num gráfico, quantos saíram iguais e não foram desenhados, o custo de cada componente, o que vai para a GPU (listas de desenho, comandos, vértices), a memória e a CPU do processo.
- **Estado**: a sessão, a conversa aberta, as cores do tema (clique para copiar o hex) e a janela (tamanho, escala, renderizador).

## Comandos

A linha de comandos do Console e o `larpercord ctl inspect …` aceitam os mesmos comandos:

```
help                     a lista
find <texto>             elementos com esse texto (ou marca do QA, componente, cor)
tree [componente]        a árvore do quadro, com o que cada pedaço desenhou
el <seletor>             tudo de um elemento, em JSON
click <seletor>          clica no meio (rclick, dclick e hover também)
type <texto>             digita no campo em foco
key <tecla>              aperta uma tecla: enter, esc, tab, ctrl+k, ctrl+shift+e…
net [filtro] [n]         os últimos pedidos HTTP
gw [filtro] [n]          os últimos quadros do gateway (op 1 e 11 só com "hb")
log [filtro] [n]         as últimas linhas do log
ev [filtro] [n]          os últimos eventos internos
perf                     números de desempenho
state                    a sessão, a conversa aberta e o tema
theme [nome|reload]      troca ou recarrega o tema
open <id do canal>       abre uma conversa
shot <arquivo.png>       print da janela
record on|off            grava a rede, o log e os eventos mesmo com o Inspetor fechado
clear [net|gw|log|ev]    limpa as listas
inspector open|close|<aba>
```

Seletores: `qa:nome` (uma marca do QA, nos builds com o robô), `comp:nome` (um pedaço do layout), `id:0x1a2b` (um id do Dear ImGui), `@x,y` (o que estiver naquele ponto), `#n` (o n-ésimo elemento do quadro) ou um texto (o elemento cujo texto, ou o texto dentro dele, bate).

Clicar e digitar passam pela fila de entrada do Dear ImGui, um passo por quadro, como o robô do QA faz. **Pelo `ctl`**, clicar e digitar só funcionam no modo demonstração ou depois que você liga **Deixar o ctl clicar e digitar** no Console. Qualquer programa rodando com o seu usuário fala com o `ctl`, então agir na sua conta de verdade é algo que você liga sabendo, e só fica ligado até fechar o app.

## Começar com ele aberto

`larpercord --inspect` (ou `LARPER_INSPECT=1`) abre com o Inspetor aberto e gravando desde o começo, então os pedidos feitos enquanto o app abre também aparecem.
