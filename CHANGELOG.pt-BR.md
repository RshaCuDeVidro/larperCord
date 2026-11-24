# O que mudou em cada versão

## 0.7.0

**Escrever temas**
- Cada componente, propriedade e valor que um tema pode usar agora está listado num lugar só, o esquema dos temas, e o app confere cada tema com ele ao carregar: um nome que ele não conhece, uma propriedade que o componente não tem, um valor que não é uma das escolhas ou um número fora da faixa vira um aviso com a linha e a coluna, e um erro de digitação ganha uma sugestão (`unknown property 'varient' on messages (did you mean 'variant'?)`). Um tema que carregava antes continua carregando. `larpercord --theme-check ARQUIVO.kdl` lista todos os avisos e erros no terminal, nos dois modos e com as opções ligadas e desligadas, sem abrir janela (`--strict` falha também com aviso; o CI confere assim os temas embutidos e os da comunidade), e `--theme-schema` mostra o esquema em JSON, que o criador de temas do site agora lê.
- `extends "classico"` começa um tema a partir de outro, embutido ou da sua pasta de temas, e muda só o que for diferente: cores token por token, fontes e métricas propriedade por propriedade, estilos estilo por estilo, opções pelo nome, e o layout, a paleta e os cargos inteiros. `vars { gap 8 }` dá nome a valores, usados como `$gap` em qualquer propriedade ou dentro de uma expressão de cor, e um tema que estende uma base pode trocar as variáveis dela, também onde a base as usa. O criador de temas e a galeria da comunidade entendem os dois.
- `theme-api 2` no começo de um tema deixa a checagem estrita: o que seria aviso vira erro, e o app não carrega o tema até ele ser corrigido. Temas sem ele funcionam como antes.
- `larpercord --theme-lsp` é um servidor de linguagem para arquivos de tema: o Neovim, o Helix, o VS Code e outros editores mostram os erros e avisos enquanto você digita, completam componentes, propriedades, valores, tokens de cor, opções e variáveis, e mostram a descrição de cada um com o mouse em cima. Ele fala pela entrada e saída padrão e não abre janela, no Linux e no Windows. Os trechos para configurar estão em themes/README.pt-BR.md.

**Partes do tema**
- Um bloco `parts` muda os pedaços de dentro dos componentes, e cada pedaço em cada estado: `part "message.author:hover" color="@accent"`, `part "channel.item:selected" bg="@selected" radius=4`. Os pedaços são a linha da mensagem e o autor, o horário, o texto e a linha da resposta dela; a linha do canal, a categoria, o sinal de não lida, o selo de menções e quem está embaixo de um canal de voz; a linha do membro, o nome e o título do grupo; a caixa de mensagem e a dica dela. Os estados são hover, selected, unread, mention, speaking, muted, offline e self, e se combinam (`channel.item:selected:hover`). Um pedaço aceita fundo, cor do texto, borda, cantos, uma faixa do lado em que o texto começa (o direito em árabe ou hebraico), opacidade e peso da fonte, com cores que acompanham o modo claro ou escuro e a cor de destaque escolhida nas Configurações. Funciona em todas as variantes do layout (mensagens cozy, irc e bolhas; canais discord, tree e pills; membros discord e tty; caixa box, pill e prompt), é resolvido uma vez ao carregar o tema, e um tema sem `parts` desenha exatamente como antes. Guia: "Partes e estados" no themes/README.pt-BR.md, e o Studio Ink da galeria da comunidade usa quase todas.
- O Inspetor mostra a parte do tema embaixo de cada elemento, com os estados dela naquela hora, pronta para colar num tema (o `larpercord ctl inspect el` devolve ela também).

**Temas**
- Formas vetoriais: `shape kind=path d="…"` desenha o caminho do SVG (`M`, `L`, `H`, `V`, `C`, `S`, `Q`, `T`, `A` e `Z`, maiúscula absoluta e minúscula relativa), preenchido com `fill=` (`fill-rule=nonzero|evenodd`, com buraco e tudo) e/ou com traço de `color=` e `thickness=`. O `viewbox=` diz que parte das coordenadas cabe no nó, sem deformar e na escala da interface. O caminho é lido e vira retas uma vez, ao carregar o tema, e o preenchimento vira uma máscara feita uma vez por tamanho; um erro para o tema com a linha do `shape` e o caractere de `d` onde ele está. Até 1024 comandos.
- Quatro fundos procedurais novos: `rain` (a inclinação do vento com `angle=`), `matrix` (colunas de caracteres desenhados pelo app, sem depender de fonte), `waves` (`lines=`) e `particles` (poeira fina e discos grandes desfocados), com `density=`, `seed=` e `motion=` como os outros. São máscaras feitas uma vez e tingidas com as cores do tema: parados, nunca acordam o app; em movimento, no máximo 15 quadros por segundo, e param com "Reduzir movimento" e com a janela escondida ou em segundo plano.
- Papel de parede: Configurações → Aparência → Papel de parede → "Escolher imagem…" põe uma imagem do seu computador (PNG, JPEG, WebP ou BMP) atrás do tema. É sempre um arquivo local escolhido no seletor do sistema: tema nenhum aponta para arquivo ou endereço, e nada vai para a internet. O ajuste (o do tema, Preencher, Inteira, Repetir ou Centro) e o Escurecer ficam no settings.kdl, e Remover tira a imagem. Um tema decide onde ela cai com um nó `wallpaper` (`fit=`, `dim=`, `blur=`, `opacity=`, `radius=`); nos temas sem ele, como os que vêm com o app, ela vai atrás do layout inteiro e os painéis ficam translúcidos só até onde o texto mantém o contraste, com o fundo animado do tema saindo da frente. A imagem é lida em segundo plano e reduzida ao que cobre a janela, nunca pede quadro e sai da memória enquanto a janela está escondida.
- O criador de temas do site confere e mostra os nós novos, e recusa o que o app recusa. Guia: themes/README.pt-BR.md. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Traduções**
- Todo idioma além do português e do inglês agora é só um arquivo. Cada `i18n/*.kdl` diz que idioma ele é na primeira linha (`language "日本語" code="ja" english="Japanese"`, e se precisar `direction "rtl"`, `font-script` e `plurals`), e o build junta cada arquivo daquela pasta no app, comprimido: pôr um idioma novo não muda código. Um `.kdl` na pasta de traduções (`~/.config/larpercord/i18n/`, `%APPDATA%\larpercord\i18n\`) com um código novo é um idioma novo em Configurações → Idioma; com o código de um embutido, vale por cima dele. O texto que falta aparece em inglês, nunca em português. Quem tinha japonês ou russo salvo continua com ele.
- Salvar um arquivo na pasta de traduções atualiza o texto do app na hora, como os temas. Uma linha com erro aparece em vermelho na página Idioma, com o arquivo e a linha, e o idioma fica com o texto que tinha até o arquivo abrir de novo.
- Configurações → Idioma lista cada idioma com quanto do app ele traduz (日本語 — 99%) e de onde vem o arquivo dele, tem botões para a pasta de traduções e para o editor de traduções, e "Seguir o sistema" diz que idioma é esse agora. O idioma do sistema agora acha um arquivo de tradução também (`de` com um `de.kdl`), com a região primeiro (`pt-PT` antes de `pt`), e o `--lang` aceita qualquer código.
- Formas de plural: um texto com contagem tem uma forma por categoria do CLDR do idioma (`"{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"`), com as regras de 20 famílias de idiomas. O tempo relativo ("há 3 dias", "через 2 минуты") saiu do código e foi para os arquivos, então qualquer idioma traduz, e votos, threads, não lidas, menções, resultados, abas, membros, plugins encontrados e amigos e servidores em comum contam com as formas de cada idioma: o russo diz "21 голос", e uma enquete ou um convite com um voto ou um membro não diz mais "1 votos" ou "1 membros".
- No site: um editor de traduções (cada texto em inglês com onde ele está no código e o que ele é, os marcadores conferidos enquanto você escreve, os que faltam primeiro, as formas de plural do idioma e o `.kdl` para baixar; roda no navegador e guarda o trabalho lá), o guia "Traduzindo o larperCord" e uma página com o estado de cada idioma.
- O `tools/i18n_strings.py --template de` gera o modelo de um idioma novo (cada texto vazio, com onde ele está e o que ele é), o `--update` atualiza uma tradução sem perder nada (os textos que o app largou ganham `/-`), o `--keys` mantém a lista que o app usa para contar, e o `--check` confere cada arquivo. O CI falha com arquivo quebrado ou marcador errado; tradução que falta só avisa.
- As conversas exportadas seguem uma tradução da direita para a esquerda (`dir="rtl"` na página), e cada mensagem fica na direção dela. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Plugins**
- Rótulos em qualquer idioma: `larper.tr{ pt = "olá", en = "hello", ja = "こんにちは" }` escolhe o idioma da interface (o código exato, depois o idioma base, depois o inglês), `larper.lang()` devolve o código de verdade (`"ja"`, `"ru"`…) e `-- @name:<código>` e `-- @description:<código>` traduzem o cartão do plugin. Menus, escolhas, o painel e as opções aceitam as mesmas tabelas. O `larper.tr("olá", "hello")` antigo continua funcionando.
- HTTP de verdade: `larper.http.put`, `patch`, `delete`, `head` e `request` além de `get` e `post`. `*.exemplo.com` em `@hosts` vale para os subdomínios (um curinga num domínio de topo inteiro, num sufixo público ou numa hospedagem compartilhada impede o plugin de começar, e os domínios do Discord não podem ser declarados de jeito nenhum). `Authorization` e `X-API-Key` só vão para os hosts de `@credentials` que você aprovou, e o cartão avisa. O `res.headers` traz uma lista de cabeçalhos permitidos, e um redirecionamento só é seguido para um host aprovado, por HTTPS, até 5. O cartão do plugin lista os 32 últimos pedidos, nunca o valor de um cabeçalho nem um corpo.
- `larper.secrets` guarda chaves de API e senhas no chaveiro do sistema (o Gerenciador de Credenciais no Windows, o Secret Service no Linux), separado por plugin e nunca no log.
- Ações nas mensagens: `larper.react`, `larper.reply`, `larper.edit` (só nas suas), `larper.delete` e `larper.attach` (os dois perguntam antes, na tela), `larper.pin`, `larper.unpin`, `larper.thread`, e `larper.send` com `reply_to`. Elas só rodam direto de um gesto no plugin (o comando, o atalho, um botão do painel ou um item do menu dele, nunca um evento, um temporizador ou uma resposta HTTP), com limite por gesto e por minuto, e vão pelo mesmo caminho dos botões do app.

## 0.6.8

**Controle de fora**
- O `larpercord ctl` controla o larperCord que já está aberto, por scripts, barras de status e atalhos do sistema: `status` e `unread` respondem em JSON (conexão, conta, a call com o canal e o servidor, mudo, surdo, aperte para falar, menções, DMs e canais não lidos); `mute`, `unmute`, `toggle-mute`, `deafen`, `undeafen` e `toggle-deafen` fazem o mesmo dos botões e de `Ctrl+Shift+M`/`D`, com o som e o que vai para o Discord; `show`, `hide` e `toggle` fazem o que a bandeja faz; `open` recebe um link do Discord ou o ID de um canal. Funciona com a janela escondida na bandeja, e responde no terminal também no Windows. Exemplos para cada ambiente em docs/ctl.pt-BR.md.
- Aperte para falar em qualquer lugar no Linux: no modo aperte para falar, `ptt-down` e `ptt-up` apertam e soltam a tecla de fora, então um atalho do compositor (o `bind`/`bindr` do Hyprland, o `bindsym --release` do Sway) fala mesmo com outra janela em foco, igual à tecla de Configurações → Voz. Os atalhos do KDE e do GNOME, que não disparam ao soltar, usam o `ptt-toggle`. Sair da call solta.
- O `watch` fica rodando e escreve uma linha cada vez que algo muda: o status em JSON, `--waybar` para um módulo do waybar (o número de menções, um ícone por estado para call, mudo, surdo, falando, menções e não lidas, e um tooltip) ou `--format text` para o polybar. Com o app fechado ele mostra offline e volta sozinho quando o app abre.
- Para barras que querem mais: na call, o `status` e o `watch` listam quem está nela com a foto, quem fala agora (uma linha nova sai quando alguém começa ou para de falar), o volume de cada um, o seu status e o ping do gateway. O `mentions` traz as DMs não lidas e as menções com o começo de cada mensagem e um link para abrir, o `channels` traz cada servidor, canal e DM com as não lidas (para um lançador), o `presence` troca o seu status e o `volume` muda o volume de alguém.
- Só o seu usuário consegue usar: o app escuta em 127.0.0.1, numa porta sorteada, e cada conexão começa com uma chave que muda a cada vez que o app abre, num arquivo que só você lê. Vem ligado, e Configurações → Avançado → Controle externo desliga; desligado, nada escuta. Sem ninguém usando, não custa nada: nada fica conferindo e nenhum quadro é desenhado. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Menções**
- O `@` acha qualquer pessoa do servidor: digitar `@` e um nome na caixa de texto de um servidor agora também pede ao Discord os membros cujo nome de usuário ou apelido no servidor começa com o que foi digitado, não só quem o larperCord já tinha carregado. Num servidor grande a lista de membros só traz quem está online, então mencionar alguém offline que não tinha escrito há pouco não dava. Eles entram na lista com o apelido, a foto e a cor do cargo; um "buscando no servidor…" parado aparece enquanto a resposta não chega, e quem estava escolhido continua escolhido quando a lista se refaz.
- Vai com calma com a sua conta: o Discord aceita um pedido de membros por servidor a cada 30 segundos, e a busca divide essa janela com o pedido dos autores das mensagens antigas (e passa na frente dele). Ela espera 300 ms depois da última tecla e precisa de 2 letras, pede 10 pessoas como o cliente oficial, nunca pede de novo o que já voltou (nem um nome mais comprido quando o mais curto voltou com menos de 10), guarda só a última busca enquanto espera e manda no máximo 4 por minuto somando todos os servidores. Nunca em DM ou grupo, e não nos servidores cuja lista de membros já tem todo mundo. O japonês segue o texto novo; o russo está em inglês por enquanto.

**Mensagens**
- Selecionar texto na caixa de mensagem mostra B e I em cima do trecho, do lado onde ele termina: eles colocam ** e * ao redor do selecionado, para negrito e itálico, e a prévia do markdown atualiza na hora. Configurações → Chat → "Barra de formatação" desliga, do ryokky3 (#31). O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Imagens privadas**
- A localização e os dados da câmera saem das fotos e dos vídeos antes de enviar: Configurações → Privacidade → "Tirar a localização e os dados da câmera de fotos e vídeos", ligada de começo. O que vai para o Discord é uma cópia sem o GPS, o modelo da câmera e o resto que fica escondido no arquivo (Exif e XMP no JPEG, no PNG e no WebP, os blocos de texto e de data do PNG, as caixas de lugar e de câmera de um MP4 ou MOV do celular); a imagem em si não é recomprimida, e a foto tirada de lado continua de pé. O arquivo no seu computador nunca muda: a cópia é feita na hora de enviar, numa pasta temporária que só o seu usuário abre, e some quando o envio acaba. GIF, mensagem de voz e os outros arquivos vão como estão, e um arquivo quebrado vai como está em vez de não ir.
- Cortar e esconder partes de uma imagem antes de enviar: uma imagem na bandeja (um print colado com Ctrl+V, por exemplo) tem o botão Editar, que abre um editor por cima da janela. Arraste para cortar, com o tamanho na tela e alças nos cantos e nas bordas; arraste sobre um nome, um endereço ou um rosto para esconder com blocos grandes ou uma tarja preta. O pedaço escondido some do arquivo que vai, não fica só coberto: os blocos são grandes e levam um pouco de ruído sorteado, e não tem desfoque leve, que dá para ler de volta. Desfazer (Ctrl+Z), Recomeçar, Cancelar (Esc) e Pronto (Enter); Pronto põe na bandeja um PNG do resultado no lugar do original, com o mesmo spoiler e o mesmo texto alternativo. Abrem no editor imagens de até 20 megapixels, a foto tirada de lado abre de pé, e as imagens coladas e editadas agora também ficam nessa pasta temporária. O japonês segue os textos novos; em russo eles aparecem em inglês por enquanto.

**Inspetor (ferramentas de desenvolvedor)**
- F12 (ou Ctrl+Shift+I) abre o Inspetor, encaixado à direita ou embaixo com o app cabendo no resto, ou solto. Ctrl+Shift+E escolhe um elemento na tela: o clique escolhe em vez de chegar ao app, e um cartão mostra o que ele é, o tamanho, a cor com o nome dela no tema, a fonte, o contraste com o fundo e o arquivo e a linha do tema que o desenha. Os dois atalhos podem ser trocados, e ele também está na paleta de comandos e em Configurações → Avançado.
- Elementos mostra o quadro como árvore: os pedaços do layout do tema e, dentro de cada um, as caixas, textos, imagens e áreas clicáveis que ele desenhou, com as propriedades do nó do `.kdl`, o id e o estado no Dear ImGui, a marca do QA nos builds com o robô e quanto cada componente levou para desenhar. Busca por texto, componente, cor ou marca.
- Rede lista cada pedido HTTP (a API do Discord, as imagens, os plugins) com o status, o tempo, o tamanho e quanto esperou o rate limit; escolhido um, mostra os cabeçalhos, o que foi enviado, a resposta em árvore de JSON e o tempo de cada fase, e copia como uma linha do curl. Gateway lista cada quadro do gateway e do gateway de voz, sem os heartbeats, com o conteúdo em árvore. O token nunca é gravado: nada de cabeçalho Authorization, e o token do IDENTIFY e do RESUME aparece como asteriscos.
- Console mostra o log sem precisar ligar o registro de depuração e tem uma linha de comandos (`help`) que também acha, clica e digita, lê a árvore do quadro, a rede e o log, troca de tema e tira prints; de fora, os mesmos comandos rodam como `larpercord ctl inspect …`. Eventos mostra o que a interface pediu ao app, o que o app pediu à rede e o que voltou. Desempenho mostra num gráfico os últimos 300 quadros e o custo de cada componente, o trabalho da GPU, a memória e a CPU. Estado mostra a sessão, a conversa aberta, as cores do tema e a janela.
- Fechado e nunca aberto, não custa nada. O que ele grava fica só na memória. `--inspect` abre com ele gravando desde o começo. Guia: docs/inspector.pt-BR.md. Os textos novos em russo estão em inglês por enquanto.

**Chamadas**
- Arraste alguém da call até outro canal de voz na lista de canais para mover a pessoa para lá, como no Discord (com "Mover membros"). Um clique continua abrindo o perfil; Esc ou soltar em outro lugar cancela.

**Vídeos**
- Vídeo em tela cheia: o botão novo na ponta direita da barra do vídeo, dois cliques no vídeo, ou F com o mouse em cima dele ou com ele tocando, põe a janela em tela cheia de verdade com o vídeo por cima do app inteiro, no preto, e os mesmos controles: play/pausa, a barra de progresso com o tempo, volume e sair da tela cheia. Tocando, os controles e o cursor do mouse somem depois de 2 segundos sem mexer o mouse e voltam quando ele mexe (com "Reduzir movimento", sem esmaecer). Espaço toca ou pausa, ← e → pulam 5 s, ↑ e ↓ mudam o volume e M tira o som; Esc, F, F11, dois cliques ou o botão saem. O vídeo continua de onde estava, sem recomeçar nem baixar de novo, e a janela volta exatamente como estava: em janela, maximizada, ou ainda em tela cheia se já estava (F11). Sair da tela cheia pelo sistema (um atalho da área de trabalho) tira o vídeo junto, e fechar para a bandeja sai da tela cheia antes, então a janela volta da bandeja como era antes. Na call, os atalhos de mudo e ensurdecer continuam valendo, e uma chamada chegando aparece por cima do vídeo. O resto do app não é desenhado enquanto o vídeo está em tela cheia.
- Em tela cheia o vídeo é decodificado até o tamanho da tela, no máximo 1080p, em vez dos 854×480 da conversa, e volta a esse tamanho na saída, também pausado. Com um vídeo 1080p são uns 25 MB a mais enquanto está em tela cheia (três quadros de 8 MB esperando a vez mais a textura), devolvidos na saída; um vídeo menor nunca passa do tamanho dele. Sem FFmpeg, onde o play abre o navegador, não tem botão. As teclas estão em Configurações → Atalhos de teclado. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto. O QA tem uma bateria nova para isso (o botão, a janela antes e depois, F11 antes, maximizada, sair pelo sistema, os controles sumindo, as teclas, o tamanho da decodificação e a memória, "Reduzir movimento" e a bandeja), que roda também num tema claro, em japonês e em 125%.

**Notificações**
- Responder pela notificação: as notificações de DM e menção agora têm os botões Marcar como lida e Responder, e o clique na notificação traz a janela (também da bandeja) naquela conversa, na mensagem. Marcar como lida lê a conversa como o item do menu, sem mostrar a janela. Onde a notificação tem caixa de texto, o que você digita sai como resposta àquela mensagem, também sem mostrar a janela, mencionando ou não o autor como o "@ LIGADO/DESLIGADO" da caixa de texto; onde não tem, Responder abre a conversa com a resposta pronta. A resposta segue as mesmas regras da caixa de texto (modo lento, permissões, castigo, ainda conectando): quando não pode sair, o texto vira o rascunho da conversa e outra notificação diz por quê, abrindo a conversa para tentar de novo. Ler uma conversa aqui ou em outro aparelho fecha as notificações dela, e sair do app fecha todas, para nenhum botão ficar sem ninguém para atender. Configurações → Notificações → "Responder pela notificação" desliga os botões. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.
- No Linux, as notificações vão direto para o servidor de notificações pelo D-Bus em vez do notify-send, sem dependência nova (a mesma libdbus que o ícone da bandeja abre). O KDE Plasma ganha a caixa de texto na notificação; o GNOME e os outros com botões ganham os botões, e Responder abre a conversa. No Wayland, a janela vem com o foco pela ficha de ativação que o servidor manda. Sem D-Bus ou sem servidor de notificações, volta o notify-send de antes, e ele troca quando um servidor aparece ou muda.
- No Windows, as notificações são avisos de verdade com os botões e uma caixa de texto ao lado de Responder, registrados só para o seu usuário (sem administrador), sem mudar como a janela se agrupa com o atalho do menu Iniciar. Se o Windows não aceitar, elas saem como o balão da bandeja de antes. Lembretes, chamadas, atualizações e as notificações dos plugins continuam chegando, agora com um clique que traz a janela.
- O QA ganhou uma bateria com uma sessão D-Bus particular e um servidor de notificações de mentira dentro do próprio binário do app: servidores como o do KDE e o do GNOME, marcar como lida e a resposta pela notificação com a janela na bandeja, uma resposta barrada pelo modo lento, o clique com a ficha de ativação, o servidor que some e nenhuma sessão.

**Texto em qualquer idioma**
- O nome do mascote Terminal em Configurações → Mascote passa pela tradução, como o Clássico ao lado (#20).
- Em inglês, a chave "Games" do mascote (o d20, dar comida, o esconde-esconde) virou "Tricks" e não tem mais o mesmo nome da página Games da Privacidade; em japonês as duas ficam 遊び e ゲーム (#20).
- Negrito e itálico agora aparecem em japonês também. Nenhuma fonte japonesa tem os dois, então a fonte reserva desenhava **negrito** normal e *itálico* em pé; as letras que vêm dela agora são engrossadas e inclinadas de mentira, só nos trechos que pedem, do ryokky3 (#31).
- Símbolos que a fonte de emoji colorida não tem, como o ⛧, agora vêm de outra fonte do sistema em vez de aparecer como um quadradinho, como as letras das outras escritas já vinham. A letra ou o símbolo que falta na fonte achada para o bloco do Unicode dele procura uma fonte só dele, o símbolo que só a fonte do japonês, do chinês ou do coreano tem não fica mais como quadradinho, e até 12 dessas fontes podem entrar, em vez de 8. De ErnstBecker (#48).

**Pastas de servidores**
- As pastas da barra de servidores agora dão para editar, e a mudança vai para a sua conta do Discord como no app oficial: arraste um servidor em cima de outro para fazer uma pasta com os dois, arraste servidores para dentro de uma pasta, para fora dela e entre os outros, e arraste uma pasta inteira para outro lugar. O botão direito na pasta tem Configurações da pasta (um nome, e uma cor da paleta ou qualquer código hexadecimal), Marcar pasta como lida (todos os servidores dela, num pedido só) e Remover pasta (os servidores ficam, soltos, onde ela estava); o menu do servidor tem Adicionar à pasta… (as suas pastas ou uma nova) e Remover da pasta. Uma pasta sem nome mostra os nomes dos servidores dela. Abrir e fechar uma pasta fica só neste computador.
- A barra muda na hora e a conta grava cada mudança; várias seguidas em menos de um segundo vão juntas. Cada gravação é um pedido só, feito a partir da cópia das configurações da conta que o app já recebe do Discord (ao conectar, quando outro aparelho muda algo e na resposta de cada gravação); só sem essa cópia ele as lê antes. Se outro aparelho gravou algo no meio, o Discord recusa e responde com as configurações como estão, e a mudança é feita de novo por cima delas. Só as pastas vão para o Discord: todo o resto das configurações da conta, inclusive o que o app não conhece, fica exatamente como estava, e a pasta que não mudou volta byte a byte. Se as configurações vêm num formato que o app não consegue ler inteiro, nada é gravado. Se a gravação falha, a barra volta ao que a conta tem e um aviso diz por quê. Uma mudança feita em outro aparelho reorganiza a barra aqui assim que chega.
- As pastas agora aparecem em toda barra de servidores que tem espaço para elas: a em pé, a deitada e a lista (papel, escritorio, cupertino). No dock e nas abas do terminal os servidores continuam um a um, então arrastar lá só reordena (solto no meio dos servidores de uma pasta, o servidor entra nela), e os menus valem em todo lugar. O QA tem baterias novas que arrastam, renomeiam, mudam a cor, levam servidores para dentro e para fora, reordenam, desfazem uma pasta, fazem uma gravação falhar e recebem uma mudança de outro aparelho, decodificando cada pedido de volta e contando os pedidos de cada gravação. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Conexão**
- Entrar e cada reconexão não esperam mais até um segundo antes de mandar o IDENTIFY ou o RESUME. Quando a primeira mensagem do Discord chegava junto com a resposta da conexão, o app só a via um segundo depois.
- Um token que o Discord recusa (4004) depois de a conexão cair algumas vezes seguidas agora mostra o motivo na tela de entrada, e não "a conexão está caindo; vou tentar com mais calma", que nem era verdade: depois disso nada tenta de novo.

**GIFs favoritos**
- A aba Favoritos do seletor de GIFs abre na hora com todos os GIFs já tocando: o larperCord guarda no seu computador um clipe pequeno de cada favorito e toca dali, sem baixar nada, e mostra a lista da última vez até a do Discord chegar. A estrela num GIF faz o clipe dele com o arquivo que acabou de tocar, sem baixar de novo; os favoritos que ainda não têm clipe (guardados em outro aparelho, ou antes desta versão) ganham um em segundo plano quando o seletor abre, um por vez, pelo mesmo caminho das imagens, então o modo economia e "Animar GIFs do Tenor e do Giphy" desligado continuam querendo dizer que nada é baixado (essas células ficam como antes). Enviar continua mandando o link do GIF, igual a antes.
- Os clipes são WebPs animados de uns 40 KB: até 160 px no lado maior com a interface em 100% (mais nas escalas maiores), 15 quadros por segundo e os primeiros 6 segundos; um GIF de até 64 KB fica como veio. Ficam em `~/.cache/larpercord/gif-favorites/<conta>` (`%LOCALAPPDATA%\larpercord\gif-favorites` no Windows), com pastas 700 e arquivos 600 no Linux, com teto de 50 MB por conta, saindo o clipe mostrado há mais tempo; um GIF tirado dos favoritos perde o clipe na próxima vez que a lista é lida. Configurações → Privacidade mostra quantos são e soma o tamanho deles no do cache, e Apagar cache, a conta removida e Apagar todos os dados levam todos. Compilar do código agora também pede a libwebpmux (vem no pacote libwebp no Arch e no Fedora, e no `libwebp-dev` no Debian e no Ubuntu); a versão portátil para Linux e a de Windows já levam dentro. O japonês segue o texto novo; em russo ele aparece em inglês por enquanto.

**Mais leve na bandeja**
- Fechar para a bandeja agora devolve memória em vez de só esconder a janela: a janela, o renderizador (o contexto da GPU) e todas as texturas vão embora, com o atlas das fontes, as imagens, os quadros dos GIFs, o quadro do vídeo, os efeitos do tema e o editor de imagem, e o que foi solto volta ao sistema (`malloc_trim` no Linux; no Windows os heaps do processo são compactados e o conjunto de trabalho esvazia). Na volta (o ícone da bandeja, um segundo larperCord, uma notificação, `larpercord ctl show`, o botão de voltar da janela flutuante) sai uma janela nova com o mesmo tamanho, o mesmo lugar, maximizada ou em tela cheia como estava e transparente (o tema de vidro), e a caixa de texto guarda o que você estava escrevendo. As imagens pequenas que estavam na tela (avatares, ícones dos servidores, emojis) ficam na RAM em pixels, então a janela volta inteira sem baixar nada de novo; as maiores carregam de novo quando aparecem, e o vídeo pausado continua de onde estava. Mensagens, notificações de DM, lembretes, calls e o `ctl` continuam funcionando na bandeja. No nosso QA, com o OpenGL por software do Mesa, o app foi de uns 100 MB para 52 MB (PSS) na bandeja, e de 176 MB para 73 MB de RSS; numa GPU de verdade, a memória do driver para o contexto vai junto (dezenas de MB com a NVIDIA).
- Com a janela flutuante aberta a principal só se esconde, como antes, porque a flutuante desenha com o renderizador, as fontes e as imagens dela; fechar a flutuante com a principal na bandeja solta tudo. Voltar da bandeja leva um pouco mais do que mostrar uma janela escondida, porque o renderizador começa de novo.
- Com a janela aberta, uma imagem que não é desenhada há um minuto (rolou para longe, outro canal) sai da memória, com os quadros dos GIFs, e carrega de novo quando volta à tela; já era assim, e agora o QA confere adiantando o relógio das imagens. O QA também vai para a bandeja e volta duas vezes, conferindo que nada da GPU fica na bandeja, que a tela volta desenhada igual pixel por pixel (o nome de um canal e a foto de alguém da lista de membros), que as imagens voltam, que a caixa de texto guarda o texto e que uma DM na bandeja ainda vira notificação.

**Desempenho**
- O mascote do canto parado não se desenha mais do zero a cada quadro. O corpo dele é uma forma cheia de curvas que o Dear ImGui corta em triângulos ponto a ponto, a parte mais cara do desenho, e isso acontecia de novo em todo quadro em que outra coisa mexia: um GIF tocando, alguém digitando, o tempo de uma call andando. Agora, quando nada nele mudou desde o quadro anterior (a pose, para onde os olhos olham, o visual do Personalizar, o tamanho, a escala da interface, a cor do tema), os triângulos da última vez são copiados de volta como estavam, e a tela sai igual pixel a pixel. Invisível (meio transparente), a textura em que ele é desenhado também é reaproveitada. Assim que ele mexe, é desenhado como antes. Na nossa medição (a demonstração com um GIF tocando, o tema classico em 1280×800), um quadro com o mascote foi de uns 1,08 ms para 0,89 ms, e o mascote em si de uns 245 µs para uns 60 µs; redesenhando sem parar, um quadro foi de 0,94 ms para 0,73 ms. O QA compara o desenho reaproveitado com um feito na hora, pixel a pixel, em casa, dormindo, com um visual cheio de peças, invisível e com a interface em 125%, confere que as peças que mexem com o relógio (o chapéu de hélice, a auréola) continuam mexendo e que ele volta certo da bandeja.

**Memória**
- Configurações → Desempenho agora divide toda a RAM do app em partes que somam o total, sem sobrar memória sem nome: o programa, as bibliotecas do sistema, as fontes, o driver de vídeo, outros arquivos mapeados, as pilhas das threads, o heap em uso (a janela e as texturas no SDL, a interface no Dear ImGui, as letras no FreeType, as conexões no curl, a criptografia no OpenSSL, os plugins no Lua, as mensagens, as pessoas e os servidores, e o resto do app e das bibliotecas), o heap livre ainda não devolvido e o que o driver de vídeo e as bibliotecas pegam fora do malloc. As partes são medidas: saem do mapa de memória do processo e de contadores nas funções de alocação das próprias bibliotecas; só os dados da conta continuam estimativa, marcados com ~, e o resto do heap fica com a diferença. Antes, os blocos grandes do heap (cada um um mapeamento próprio) apareciam como memória sem nome. O `--stats` mostra a mesma lista quando a abertura acaba e uma vez por minuto. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.
- As mensagens ocupam menos memória: as reações ficam num bloco próprio, só nas mensagens que têm alguma, em vez de oito lugares vazios em cada mensagem guardada (uma mensagem na memória foi de 648 para 272 bytes, com as mesmas oito reações no máximo); a lista de mensagens de uma conversa que está fora da tela há 30 segundos devolve o espaço que tinha reservado para as que viessem; e depois de um READY grande o gateway fica com 64 KB de buffers em vez de até 2 MB.
- O `tools/ram_conta_grande.sh` mede RAM e CPU numa conta de mentira do tamanho de uma grande de verdade (52 servidores, 2.450 canais, cargos, emojis, algumas centenas de DMs, listas de membros, páginas de histórico, imagens e tráfego de fundo), gerada pelo `tools/conta_grande.py` e servida pelo Discord de mentira do QA de rede, numa rede só com o 127.0.0.1: sem conta nenhuma, e nada sai do computador. Ele usa o build do QA com `-Dqa=true -Dqa-rede=true`, que nunca vai para as releases.
- `-Dmimalloc=true` compila com o mimalloc 3.6.1 (MIT, em `third_party/mimalloc`) no lugar do malloc do sistema, no Linux e no Windows. Na conta de mentira ele usou umas três vezes a RAM (a memória que ele solta fica com ele em vez de voltar ao sistema) com a mesma CPU, então as releases continuam com o malloc do sistema e o mimalloc fica como opção para quem quiser testar.

## 0.6.7

**Janela flutuante**
- Picture-in-picture: clique com o botão direito no nome da conversa no cabeçalho, numa aba ou num canal (ou use a paleta de comandos) e escolha "Abrir em janela flutuante", ou aperte o botão novo na barra da call: uma janela pequena à parte, sempre por cima e redimensionável, acompanha aquela conversa ao vivo com uma caixa para responder, ou a call com o quadro de cada um, quem está falando e os botões de mutar, ensurdecer e sair. O botão da setinha traz a janela principal de volta naquela conversa ou call, até da bandeja, e a flutuante continua funcionando com a principal escondida na bandeja. A barra de cima arrasta a janela, ela lembra o tamanho e o lugar, fecha sozinha quando a call acaba, e fica uma aberta de cada vez.
- Continua leve: desenha com as fontes, as fotos e os emojis da janela principal (nada é carregado duas vezes), só quando algo nela muda, e fechada não custa nada. No Wayland quem decide se uma janela fica por cima é o compositor (o KWin e o Hyprland deixam fixar), e o app avisa na primeira vez. O japonês segue os textos novos; os novos em russo estão em inglês por enquanto.

**Mensagens**
- Lembretes de mensagens: botão direito numa mensagem → Me lembrar… e escolha em 20 minutos, em 1 hora, em 3 horas, amanhã às 9:00, semana que vem (a segunda às 9:00) ou a data e hora que quiser, com uma anotação curta opcional. "Amanhã" e "semana que vem" seguem o seu relógio, com horário de verão. Na hora, um aviso fica no canto até você ir para a mensagem, adiar 10 minutos ou concluir; o mascote do canto leva um bilhetinho até ele, e com a janela sem foco ou na bandeja sai uma notificação do sistema, pelo mesmo caminho das DMs e nunca no "Não perturbe". O que venceu com o app fechado aparece como atrasado ao abrir. O painel das mensagens salvas ganhou a aba Lembretes, com o que venceu, o que vem e o que foi concluído, com editar e excluir, e o botão das salvas mostra quantos venceram. O app não fica conferindo de tempo em tempo: dorme até o próximo lembrete. Os lembretes ficam só no seu computador, um arquivo por conta ao lado das mensagens salvas, e "Apagar todos os dados" leva junto. O japonês segue os textos novos; as linhas novas em russo estão em inglês por enquanto.
- Mensagem com um `*` sozinho (ou `**`, `~~`, `||` sem nada que feche) não some mais: o marcador se engolia e levava o resto da mensagem para o estilo, então uma mensagem que era só "*" aparecia vazia. Agora o marcador só dá estilo quando tem par, como no Discord, e senão aparece como foi digitado. `2 * 3 * 4` também aparece como foi digitado.
- A busca acha as mensagens na hora, enquanto você digita, mesmo sem internet: o larperCord mantém um índice das mensagens que ele já tem, as carregadas na memória e as do cache de mensagens no disco, e o mantém em dia quando mensagens chegam, são editadas ou apagadas e quando páginas do histórico carregam (o que também tira as apagadas com o app fechado). Enquanto você digita, a última palavra vale como começo de palavra ("hypr" acha "hyprland"); acento e maiúscula não importam, e japonês e chinês são achados caractere por caractere. from:, in:, mentions:, has:link, image, file, video e sound, before:, after: e during: também funcionam neste computador; pinned:, has:embed e has:sticker continuam precisando do Discord. Os resultados daqui vêm marcados "neste computador".
- O Enter continua buscando no Discord, que tem o histórico inteiro, e o que ele acha entra junto com o daqui, cada mensagem uma vez. Sem conexão, o Enter nem tenta e avisa. Montar o índice nunca pede nada ao Discord.
- O índice fica gravado ao lado do cache de mensagens, por conta, e só o seu usuário lê. Ele é lido em segundo plano, refeito a partir do cache quando falta, segue Configurações → Privacidade → "Guardar mensagens no disco" (desligado: só na memória) e vai embora com Apagar cache, com a conta removida e com Apagar todos os dados. Configurações → Privacidade mostra quantas mensagens ele tem e o tamanho no disco e na memória. Nas nossas medidas, 50.000 mensagens ocupam cerca de 10 MB na memória e 4 MB no disco, e uma busca leva menos de 2 ms. O japonês segue os textos novos; em russo eles aparecem em inglês por enquanto.

**Exportar e salvar**
- Exportar uma conversa: botão direito num canal ou numa DM (ou no nome da conversa, no cabeçalho) → Exportar conversa… e escolha HTML (uma página só, que abre sem internet, com as cores do tema da hora, autores, fotos de perfil que já estavam no computador, horários, formatação, respostas, anexos e os cartões de link básicos), Markdown ou JSON (campos documentados, IDs como texto, horas em ISO), o período entre os dias que estão no computador e se inclui a mídia. O arquivo vai para onde você escolher no seletor do sistema, a mídia numa pasta ao lado. Roda em segundo plano, com andamento e Cancelar, e termina com Abrir e Abrir pasta.
- Exportar nunca pede nada ao Discord, nem à CDN: só usa o que já está no computador (as mensagens na memória e no cache de mensagens, e os arquivos que o app já baixou). A janela diz quantas mensagens são e desde quando; para incluir as mais antigas, role a conversa para cima antes. A mídia vem desligada; ligada, vão para a pasta as fotos de perfil e as imagens que já estavam no computador, e o resto fica como link para o original. O QA conta cada comando que o app manda e cada download de mídia que ele começa, e confere que exportar não começa nenhum.
- Salvar imagens, GIFs, vídeos e arquivos no disco: botão direito em um deles (ou os botões do visualizador de imagens) → Salvar… (seletor do sistema com um nome sugerido e a extensão certa) ou Salvar em Downloads (a pasta Downloads do sistema, do user-dirs no Linux e da Known Folder no Windows, com outro nome se o arquivo já existe). Salva o arquivo original, não a prévia reduzida (no Tenor e no Giphy, o GIF de verdade, com Configurações → Privacidade → Animar GIFs do Tenor e do Giphy ligado), aproveitando o que já foi baixado, pelos mesmos domínios permitidos e pelo mesmo proxy das imagens, sem a sua conta. O russo mostra os textos novos em inglês por enquanto; o japonês segue os textos novos.

**Presença**
- A capa do "Ouvindo Spotify": a imagem grande da atividade ("spotify:<id>") vem da CDN do Spotify (i.scdn.co), como o app oficial baixa. Um id furado deixa o cartão sem a imagem. Com proxy configurado, a capa passa por ele, como a mídia de fora toda.
- Mostrar o jogo aberto (Configurações → Privacidade, desligado de começo): o seu status mostra "Jogando <jogo>" com o tempo de jogo para os jogos da sua lista, achados olhando os programas abertos de 15 em 15 segundos, do jeito que o Discord do computador acha os jogos. Funciona com jogo que não usa Rich Presence, como o Dota 2 (#36). Acrescente um jogo pela lista dos programas abertos agora (com filtro; os do sistema e os de fundo ficam de fora) ou escolhendo o executável. Cada jogo tem um nome que dá para mudar, um botão de ligar e desligar e "Só este arquivo", que confere também o caminho inteiro. Só os jogos da lista vão para o Discord; com vários abertos, vale o primeiro da lista, e fechar o jogo limpa. Um jogo rodando pelo Wine ou pelo Proton aparece pelo .exe. Com uma atividade do Rich Presence ligada também, as duas vão para o Discord lado a lado, sem uma tomar o lugar da outra (o mesmo jogo pelos dois aparece uma vez), no mesmo ritmo do Rich Presence. Desligado, nada olha os seus processos. O japonês segue os textos novos; os textos novos em russo ficam em inglês por enquanto.

**Servidores**
- Levou kick ou ban de um servidor (ou saiu dele): nada mais vai para lá. A lista de membros do canal que estava aberto lá não é pedida de novo a cada reconexão, o que esperava para ir para ele é descartado, e a call de lá acaba quieta em vez de tentar voltar com o token velho. O mesmo quando acontece com a conexão caída e a sessão nova simplesmente não traz o servidor de volta.

**Rede e privacidade**
- A conexão agora parece o Chrome que o app já dizia ser. O app mandava os cabeçalhos do Chrome, mas conectava do jeito padrão do OpenSSL, e a impressão da conexão (JA4) dizia outra coisa. Agora o aperto de mão TLS leva as mesmas cifras, grupos, assinaturas e extensões do Chrome 156, com o mesmo JA4. No Linux, o binário da release também fala HTTP/2 com as configurações do Chrome e aceita br e zstd, onde antes caía para HTTP/1.1. No Windows também (abaixo).
- Com o registro de depuração ligado (Configurações → Avançado), cada pedido à API do Discord (método, caminho e status) e cada op que sai pelo gateway (o número e o servidor) ficam anotados, sem token nem conteúdo, para ver o que o app mandou se a conta for marcada de novo.
- `--tls-fingerprint` mostra a impressão TLS e HTTP/2 do app, como um site que devolve o que recebeu a vê, e tools/tls_check.sh compara com a do Chrome. Nenhum dos dois usa token.

**Mais leve**
- O arquivo do app ficou uns 360 KB menor: as traduções em japonês e russo, o changelog e a tabela de emoji vão dentro dele comprimidos e só abrem quando precisa (ao escolher o idioma, abrir Atualizações ou aparecer o primeiro emoji). O último emoji da tabela, a bandeira do País de Gales, não lê mais um byte além do fim dela.

**Texto em qualquer idioma**
- Russo: 341 textos que tinham sido traduzidos por máquina (entre a 0.6.2 e a 0.6.6) voltaram para o inglês, como espaço reservado para alguém traduzir; outros 63 estão sendo reescritos no pull request do DivannKokos (#29). Tudo o que pIat0n e DivannKokos traduziram fica. `tools/i18n_strings.py --lang ru --check` diz quantos faltam, e o começo do i18n/ru.kdl explica como mandar uma tradução.
- Os títulos das páginas Chat e Plugins passam pela tradução, e os textos que os temas desenham (como o "TRIPULAÇÃO" do orbital ou o "SEÇÕES" do editorial) dá para traduzir nos arquivos de idioma (#20).
- Frases que eram cortadas com "…" em lugares estreitos agora quebram a linha: a coluna Ativos agora vazia, a aba de adicionar amigo, os pedidos de mensagem, as configurações de voz e do cronômetro, o comando do servidor de linguagem e as threads arquivadas (#20).

**Mascote**
- Status invisível: o mascote do canto agora fica transparente como uma figura só. Antes cada peça ficava transparente sozinha, então as orelhas apareciam através do corpo onde se cobrem e, com chapéu, pareciam um par de óculos. Agora o mascote inteiro, com chapéu e fone, é desenhado de uma vez e some por igual. O clone do Ctrl+C some do mesmo jeito.
- Configurações → Mascote → Personalizar ganhou os controles Altura dos olhos e Altura da boca, que sobem e descem os olhos e a boca no rosto, em todo estilo de olho e de boca e nos desenhos dos arquivos de mascote. Levar um até o outro empurra o outro junto, então nunca ficam mais perto do que no desenho de sempre. Os óculos, as olheiras e a lupa acompanham os olhos; o bigode, a fita do mudo e o chiclete acompanham a boca. As alturas aparecem onde o visual aparece e ficam salvas com ele e no "Salvar como arquivo" (`eye-height` e `mouth-height` nos arquivos de mascote, veja mascots/README.pt-BR.md). Padrão volta os dois ao lugar, e Desfazer desfaz um arraste inteiro. O japonês segue os textos novos; as duas linhas novas do russo ficam em inglês até alguém traduzir.
- O Personalizar ganhou o campo Nome: o nome aparece num balãozinho ao parar o mouse em cima do mascote do canto e embaixo da prévia grande, e fica salvo com o visual e no "Salvar como arquivo" (`name` nos arquivos de mascote). Padrão e os visuais prontos não tiram o nome.
- Personalizar → Mais ajustes abre mais controles: posição dos olhos, espaço entre eles, olhos desalinhados (um mais alto que o outro), tamanho dos olhos, posição e tamanho da boca, tamanho e ângulo das orelhas, corpo mais redondo ou mais quadrado, mais magrinho ou mais gordinho, e a força das bochechas. Olhos de duas cores dá ao olho direito uma cor só dele, de umas prontas ou em hex. Óculos, bochechas, sardas e olheiras acompanham os olhos; o bigode, a fita do mudo, o chiclete e o microfone da call acompanham a boca; orelhas, chapéus, o fone, o que vai no pescoço e as formas dos arquivos de mascote acompanham o corpo, e olhos e boca que crescem guardam distância um do outro. Tudo aparece onde o visual aparece e fica salvo com ele e no "Salvar como arquivo" (as chaves estão em mascots/README.pt-BR.md); Padrão volta tudo e Desfazer desfaz um arraste inteiro. O japonês segue os textos novos; as linhas novas do russo ficam em inglês até alguém traduzir.
- Na prévia grande dá para pegar os olhos ou a boca e arrastar, com os mesmos limites dos controles e um desfazer por arraste.
- O mascote do canto reage ao que você digita, tudo calculado no seu computador a partir do texto da caixa de mensagem. Texto TODO EM MAIÚSCULAS faz ele tapar as orelhas, um ||spoiler|| faz ele tapar os olhos até você mandar (ou tirar da caixa), um bloco de código põe óculos nele para revisar, e uma mensagem longa faz ele segurar um pergaminho que desenrola enquanto você escreve e, perto do limite, se afastar preocupado (2000 caracteres, 4000 com Nitro, ou o que cabe na caixa, o que vier antes). Digitar @ ou # faz ele apontar para a lista de membros ou a de canais, um / no começo abre um terminalzinho do lado dele com o seu comando, e muito Backspace seguido rende uma xícara de chá ou tapinhas no braço. Ele também tem uns segredos (tente `>_`, `miau` ou `meow`, `sudo` e `rm -rf`). Nada disso cobre o texto que você está digitando. Configurações → Mascote → Reage ao que você digita desliga.
- Brincadeiras (Configurações → Mascote → Brincadeiras). De vez em quando (uma em 50 mensagens) ele rola um d20 quando você manda: o 20 traz confete e o 1 derruba ele. Arraste um emoji do seletor de emoji ou de uma reação da conversa até ele e ele come, e os olhos dele viram aquele emoji por um instante. Um link solto em cima dele entra num portalzinho, e uma imagem solta em cima dele vira um quadro que ele segura (o arquivo vai para os anexos do mesmo jeito, como antes). De vez em quando, parado e com a vida própria Normal ou Agitada, ele brinca de esconde-esconde atrás da lista de canais (ou da de membros), só com as pontinhas das orelhas de fora: clique nelas para achar, ou ele volta sozinho depois de 30 segundos.
- Mais atalhos que ele percebe, junto com Ctrl+C, Ctrl+Z e Ctrl+F: Ctrl+K pula num portal, Ctrl+S segura um disquete, Ctrl+P imprime a própria pata, Ctrl+X pega uma tesoura, Ctrl+V cospe um clone, e Esc faz ele se enfiar na caixa de mensagem por um instante, mas só quando o Esc não tinha mais nada para fechar (um menu, a paleta, uma resposta, o texto da caixa…) e no máximo uma vez a cada 20 segundos. As teclas continuam fazendo o que sempre fizeram. Elas fazem parte das Brincadeiras. As duas chaves novas vêm ligadas e descansam com a vida própria Desligada ou com Reduzir movimento ligado. O japonês segue os textos novos; as linhas novas do russo ficam em inglês até alguém traduzir.
- Escreva o nome do mascote (Personalizar → Nome) na caixa de mensagem e ele responde "Me chamou?". As patinhas nos olhos, os óculos e os olhos de emoji seguem o lugar, o espaço, o tamanho e a altura dos olhos escolhidos em Personalizar.

**Atualizações**
- Versão nova não fica mais escondida num toast de menos de dois segundos: uma faixa no topo diz qual versão saiu e fica até você fechar, com "Atualizar agora", o progresso do download e "Reiniciar agora" quando ela está instalada; fechar vale até o app abrir de novo. O botão das configurações fica com um pontinho enquanto houver o que atualizar, e com o app na bandeja ou sem foco vai também uma notificação do sistema. Instalado por gerenciador de pacotes, o botão explica como atualizar por ele.
- Configurações → Atualizações → "Atualizar sozinho", desligado de começo: achou versão nova, baixa e instala em segundo plano (com a assinatura conferida como sempre) e ela abre na próxima vez que o app abrir.

**Notificações**
- Som de mensagem nova, como no Discord: um aviso curto com mensagem direta, grupo e menção (@everyone, @here e os seus cargos também, seguindo as notificações do servidor), ligado de começo em Configurações → Notificações → Som de mensagem nova. Toca com a janela fora de foco ou escondida na bandeja, e em outra conversa; não na conversa que você está olhando, nas suas próprias mensagens, em canais e servidores silenciados, nem em Não perturbe. Uma rajada de mensagens toca uma vez a cada 1,5 segundo. O som pode ser desligado, trocado por outro embutido ou por um arquivo seu, com volume próprio, ali mesmo ou em Configurações → Voz → Sons, e sai na mesma saída dos sons da call. A demonstração recebe uma DM de um amigo de vez em quando. Os textos novos ficam em inglês no russo até alguém traduzir.

**Instalação**
- Abrir pelo lançador de apps no Wayland (que define XDG_ACTIVATION_TOKEN para dar o foco à janela) não derruba mais o app na abertura. A ficha é apagada do ambiente quando a janela aparece, e a cópia do ambiente que o app guardava ainda apontava para a lista antiga, mais curta (#44).
- O Windows agora é um `larpercord.exe` só, com a SDL3, o curl e o OpenSSL dentro: a DLL oficial do curl traz o próprio OpenSSL, fora do alcance do app, então a conexão só conseguia parecer a do Chrome com eles compilados juntos. O zip foi de 11,4 para 9,6 MB. As três DLLs continuam na release para as versões antigas conseguirem se atualizar; o `.exe` novo não carrega as que sobram na pasta, e o `install.ps1` as apaga.

**Chamadas**
- Com o aperte para falar ligado, o "Desligado" da supressão de ruído volta a funcionar: ele tinha o mesmo número da caixa do atalho, logo acima (#35).
- Gravar áudio na caixa de mensagem: o botão do microfone ao lado das opções (ou Ctrl+Shift+R, que dá para trocar em Configurações → Atalhos de teclado) grava pelo microfone escolhido em Configurações → Voz, com o volume e a supressão de ruído de lá. Enquanto grava, uma barra fica no lugar da caixa com o tempo e o nível ao vivo; Enviar (Enter) manda e Cancelar (Esc) joga fora. Vai como um arquivo .ogg comum (Opus, mono, 32 kbit/s, uns 240 KB por minuto), pelo mesmo caminho de qualquer arquivo anexado e respondendo se a caixa está respondendo, e o texto que você estava escrevendo continua na caixa. Até 10 minutos, com aviso nos últimos 30 segundos. Não grava durante uma call nem onde você não pode anexar arquivos (o botão diz o motivo), e Configurações → Chat → Botão de gravar áudio esconde ele.

**Mídia e GIFs**
- Arquivos de áudio mandados no chat (.mp3, .ogg, .wav, .flac, .m4a…) agora tocam na própria conversa, em vez de só baixar. O player mostra a forma de onda do arquivo inteiro como barra (o que já tocou na cor de destaque do tema; clique ou arraste para pular, e o mouse em cima mostra o tempo daquele ponto), o tempo atual e o total, o nome e o tamanho do arquivo, um botão de velocidade (1×, 1,5×, 2×) e um de baixar. Com o mouse em cima, espaço toca ou pausa e ← → pulam 5 segundos (quando nenhuma caixa de texto está com o foco). As capas de spoiler e de conteúdo sensível continuam cobrindo até o clique.
- Ogg Opus, MP3 e WAV/AIFF tocam sem instalar nada: MP3 e WAV pelo dr_mp3 e dr_wav (do dr_libs, domínio público), embutidos no app. FLAC, Ogg Vorbis, AAC/M4A e outros tocam pelo FFmpeg quando ele está instalado (o mesmo dos vídeos); sem ele, ficam como cartão de arquivo, avisando. Arquivos de até 32 MB. O som vai para o dispositivo de saída e o volume escolhidos em Configurações → Voz, um áudio por vez, e para quando você sai da conversa ou a janela vai para a bandeja.
- Enquanto um áudio ou uma mensagem de voz toca, barrinhas dançam com o som: ao lado do nome do arquivo e em volta do botão de tocar das mensagens de voz. Elas só andam tocando, com a janela em foco e sem "Reduzir movimento"; fora isso, só a barra de progresso anda, e pausado nada é redesenhado. Configurações → Chat → Visualizador de áudio desliga.

**Atalhos de teclado**
- Ctrl+R reinicia o larperCord, como o botão em Configurações → Atualizações, e dá para trocar em Configurações → Atalhos de teclado. De ErnstBecker (#42).

**Temas**
- Seis temas novos na galeria da comunidade do site: Rose Pine, Tokyo Night, Kanagawa, Dracula, One Dark e GitHub Dark. De mealet (#43).

## 0.6.6

**Aparência**
- Configurações → Aparência escolhe as fontes da interface e do código entre as instaladas no dispositivo: a lista lê os arquivos de fonte, com o nome da família de cada arquivo (o Windows lê C:\Windows\Fonts e a sua pasta de fontes; nos outros sistemas, o fontconfig responde). "Do tema" volta ao que o tema pede, e a escolha fica salva, do ryokky3 (#26). O japonês segue os textos novos.

## 0.6.5

**Mascote**
- Um mascote novo, o Terminal, com a piscadinha ">_", agora é o principal, com uma abertura toda nova: um cursor de terminal pisca, uma linha de TV de tubo acende e abre o corpo, as orelhas saltam, o rosto é digitado, ele mostra "..." enquanto conecta e desliga como uma TV antiga quando o app abre. O demo também mostra a abertura inteira.
- Mais quatro aberturas para escolher em Configurações → Mascote → Abertura: Código, TV, Pixels e Portal, ou Sortear, para cada vez ser uma. "Ver a abertura de novo" toca de novo.
- O mascote ganhou uma aba própria nas Configurações. O de antes, o Clássico, está a um clique lá, com a prévia dos dois ao vivo. A escolha troca o ícone do app onde dá: a janela e a barra de tarefas, a bandeja, os avisos do Windows e, no Linux, o ícone do menu de aplicativos. No Windows, o ícone do próprio arquivo do app continua o Terminal.
- O mascote aparece pelo app: dormindo na caixa de entrada, nos fixados, nas mensagens salvas e na lista de amigos vazios, e carregando junto com a conversa. Clique nele na tela de entrada ou em Configurações → Sobre e ele reage.
- Mascote no canto: ele senta em cima da caixa de mensagem (Configurações → Mascote → Mascote no canto, ligado de começo). Os olhos seguem o mouse, ele digita junto, pula quando você manda, se assusta com menção e ri, comemora, fica triste ou acena com o que você escreve (tudo calculado no seu computador). Dorme depois de uns minutos parado. Pegue e jogue e ele quica nas bordas da janela, fica tonto e volta andando. Passe o mouse devagar por cima para fazer carinho, dê dois cliques para um truque, e cutucado demais ele emburra uns segundos, cada vez de um jeito.
- Ele também bota fone em call, com fita na boca enquanto você está mudo. Pega fogo quando você digita rápido, fica tonto quando a conversa rola rápido demais, come o arquivo que você arrasta para a janela e fica preocupado quando a mensagem não sai. De madrugada tem olheiras e boceja, de manhã se espreguiça, em algumas datas usa chapéu, e pega a cor de destaque do tema. Reage ao emoji que você põe nas mensagens e mostra o seu status: uma lua no ausente, uma plaquinha no não perturbe (aí menção não assusta), meio transparente no invisível. Ctrl+C faz um clone, Ctrl+Z faz ele andar para trás, Ctrl+F dá uma lupa para ele, e a roda do mouse em cima dele faz cócegas. Clique com o botão direito para Fazer um truque, Dormir, Esconder por 1 hora e Trocar de mascote.
- Vida própria: deixado à toa, de vez em quando ele faz alguma coisa sozinho. Toma café, lê, joga no portátil, faz bola de chiclete, assobia, faz exercício, caça uma mosquinha, pesca um emoji das reações da conversa, empilha blocos que caem em cima dele quando você mexe, rabisca um coração na caixa de mensagem até você digitar e rega a plantinha. Às vezes sai passeando pela janela: senta na última mensagem, sobe na lista de membros, fica pendurado no cabeçalho ou espia por trás da lista de canais.
- Ele também brinca com a interface. Senta no "digitando…", leva mensagem apagada para a lixeira, passa a borracha na editada, empurra o botão de voltar ao fim, se segura (ou cai) quando você muda o tamanho da janela e leva uma cartinha até o ícone das DMs quando chega uma. Tenta pegar a setinha do mouse parada perto dele e senta nela quando ela para em cima. Pula junto quando você troca de canal e espia quando você abre uma thread.
- Com a janela sem foco, ele espera você; sumiu por 20 minutos, monta uma barraca com fogueira. Na volta, desmonta, corre até o mouse e, depois de horas, diz que sentiu saudade. A plantinha dele cresce um pouco a cada dia de uso até virar uma arvorezinha, e murcha depois de uma semana sem você, até ser regada.
- Em Configurações → Mascote dá para escolher o quanto ele se mexe (desligada, calma, normal, agitada), com uma chave para o passeio, a interface, o mouse, a espera e a plantinha.
- Continua leve: só desenha quadros a mais por um instante quando algo acontece, e só com a janela em foco. A vida própria só começa depois de 8 segundos sem você mexer em nada e para quando ele dorme; medido no demo, uns 0,5% de um núcleo enquanto ele está acordado e à toa.
- Personalize o mascote Terminal em Configurações → Mascote → Personalizar: 15 olhos, 16 bocas (:3, uwu, língua, dentinho, vampiro, aberta, boquinha, reta, ondulada, de lado, dentes, biquinho, assobio, dentuço e o cursor "_"), 22 chapéus (coroa, cartola, touca, boné, caubói, chef, auréola, chifrinhos, coroa de flores, viking, mago, laço, hélice, boina, tiara, pirata, capacete, brotinho, antenas e os três das datas), 12 acessórios (óculos, óculos escuros, monóculo, tapa-olho, bochechas, sardas, curativo, bigode, gravatinha, cachecol, bandana, brinco), 6 orelhas e 14 paletas de cores, ou um hex seu para cada cor, ou a cor de destaque do tema. Todo olho e toda boca funcionam com todas as caras: uma prévia grande troca entre elas e mostra o fone da call e a fita do mudo.
- 16 visuais prontos (Hacker, Bruxo, Realeza, Pirata, Chef, Astronauta, Nerd, Gatinho, Vampiro, Caubói, Fofura, Diabinho, Robô, Anjinho, Viking, Jardim), e Sortear visual, Padrão e Desfazer. O visual aparece onde o mascote aparece: nas cinco aberturas, no Sobre, nas listas vazias e no mascote do canto, com tudo o que ele já fazia. O visual padrão continua igual ao de antes. O chapéu das datas continua quando nenhum chapéu está escolhido, e Configurações → Mascote → Chapéu nas datas desliga.
- Arquivos de mascote: um .kdl na pasta de mascotes (~/.config/larpercord/mascots, %APPDATA%\larpercord\mascots no Windows) escolhe peças e cores, ou desenha olhos, boca e camadas na frente ou atrás do corpo com círculos, elipses, retângulos, linhas e caminhos, um desenho por expressão. "Salvar como arquivo" grava o visual de agora, a lista da aba escolhe um arquivo, "Abrir pasta" abre a pasta, salvar o arquivo atualiza o mascote na hora, e um arquivo com erro mostra arquivo:linha:coluna enquanto o mascote fica com a última versão que funcionou. O formato está em mascots/README.pt-BR.md, e o site tem uma galeria de mascotes da comunidade com quatro exemplos.

**Mensagens**
- Árabe e hebraico na caixa de mensagem aparecem na ordem certa e alinhados à direita, como nas mensagens enviadas, do relato do majd-tqe (#9). Cursor, clique, seleção e Backspace seguem o texto na tela, e ← e → andam pela tela em vez da ordem do texto.
- Mensagens antigas agora mostram o apelido, a foto do servidor e a cor do cargo, como as novas. O histórico do Discord não diz quem o autor é no servidor, então o larperCord pede ao gateway quem ele ainda não conhece: no máximo um pedido por servidor a cada 30 segundos (o limite do Discord), juntando as páginas carregadas nesse meio-tempo, até 100 pessoas por pedido, cada pessoa uma vez por sessão, nunca em DMs ou grupos, no mesmo ritmo do resto que vai para o gateway. Se o Discord pede calma, o mesmo pedido espera mais a cada vez, e depois de três recusas seguidas aquele servidor para de pedir até o fim da sessão.

**Abas**
- Conjuntos de abas salvos: guarde grupos de abas, como "trabalho" ou "jogo", e troque entre eles de uma vez. Clique com o botão direito na barra de abas (ou use a paleta de comandos) para salvar as abas abertas como conjunto, trocar, renomear, excluir ou sair dele. Com um conjunto em uso, as abas que você abre, fecha ou troca ficam salvas nele, junto com a tela dividida, e o nome dele aparece antes das abas. Trocar só carrega o canal que aparece; as outras abas carregam quando você abre, então um conjunto de 10 abas não vira 10 pedidos ao Discord. Um canal que você não vê mais fica de fora, com um aviso curto. Os conjuntos ficam por conta, só neste computador, e o que estava em uso volta quando o app abre. Ctrl+Shift+PageDown vai para o próximo conjunto (dá para trocar em Configurações → Atalhos de teclado).

**Servidores**
- Perfil do servidor, pedido do helpik1 (#19): num servidor, cada pessoa aparece com o apelido e a foto que escolheu para ele, no lugar dos globais, em todo lugar: mensagens, respostas e menções, lista de membros, lista da call no canal de voz e mixer da call, a lista do @ na caixa de mensagem (que acha pelos dois nomes) e o cartão de perfil, que mostra o apelido com o nome global menor embaixo, e a bio, os pronomes e o banner do servidor quando a pessoa tem. Em DM e grupo continuam o nome e a foto globais.

**Chamadas**
- O mudo de uma call continua na próxima: sair mudo (até fechando o app à força) abre a seguinte mudo, sair sem mudo abre sem mudo, do ryokky3 (#27).
- Tela da call, a outra metade do pedido do helpik1 (#19): clicar num canal de voz abre a call no lugar da conversa, com um quadro por pessoa: a foto e o apelido do servidor, o anel verde enquanto fala, o microfone e o som quando estão desligados, o que está jogando e o selo AO VIVO de quem transmite. Clique num quadro para o menu da pessoa (volume, silenciar para mim). O seu microfone, som, mixer e sair ficam no lugar da caixa de mensagem. Esc, "Voltar à conversa", trocar de aba ou um canal de texto voltam, e clicar no status da call na faixa de voz abre de novo. Calls em DM e grupo ganham a mesma grade em cima da conversa. Nos temas de terminal, ela aparece em texto. Sem câmera nem compartilhamento de tela, como antes.
- A tela da call segue o tema: cada quadro usa as cores, os cantos e o estilo de cartão do tema (vidro no vidro, papel no papel, recorte de jornal no editorial…), com só um toque da cor da foto de cada pessoa, e o texto troca de cor quando ficaria difícil de ler. Quem faz tema escolhe isso com `call-style` e `call-tint` no componente `messages` (veja o guia de temas). Sozinho na call, o seu quadro fica menor e embaixo o mascote cochila ao lado de "Só você por aqui" e do botão "Convidar pessoas". Os botões ficam numa barra com o tempo da call, e passar o mouse no seu quadro mostra o nível do seu microfone com a marca do limiar da detecção de voz (só então ele gasta algo).
- No mixer da call, cada pessoa ganhou "Tirar ruído" e "Igualar volume", os dois desligados de começo e só para aquela pessoa. Tirar ruído usa no som dela o mesmo supressor de ruído do seu microfone (gasta um pouco de CPU enquanto ela fala, por isso é por pessoa). Igualar volume sobe quem fala baixo e desce quem fala alto, para perto do volume dos outros, sem subir o chiado das pausas. As escolhas ficam guardadas e valem em toda call.

**Atalhos de teclado**
- Dá para trocar os atalhos, do pedido do ShuyaGit (#18). Em Configurações → Atalhos de teclado, clique num atalho e aperte as teclas novas. Combinação já usada, as fixas (copiar, colar, nova linha, andar no texto), letra sozinha e Ctrl+Alt com letra (o AltGr em muitos teclados) são recusadas com o motivo; "Padrão" volta. As dicas que citam um atalho mostram as teclas de agora.

**Texto em qualquer idioma**
- "Online", "Offline", "Proxy" e outras palavras que faltavam nos arquivos de tradução agora aparecem em japonês e em russo, assim como as descrições e as opções dos temas embutidos, o submenu de prazo do status, as dicas da caixa de mensagem e as ações das imagens, do relato do DivannKokos (#20). O cartão do tema mostra a descrição inteira, em até duas linhas, e o resto ao passar o mouse.
- O texto traduzido não sai mais cortado em russo e japonês: Sobre, o aviso de espera para entrar em servidores, a nota do modo foco e "N menções em <servidor>" com nome comprido. Botões e notas das Configurações também não passam mais da borda. Do relato do DivannKokos (#22).
- O russo usa ё onde deve, do DivannKokos (#21).
- O texto em japonês, chinês e coreano aparece na caixa de mensagem enquanto você escolhe o candidato, com o sublinhado, em vez de só depois de decidir, do ryokky3 (#23). Nos outros campos (busca, paleta de comandos, Configurações), ele aparece numa caixinha no cursor.
- Com árabe ou hebraico no fim da conversa, o botão de voltar ao fim vai para o canto esquerdo em vez de cobrir o começo dessas linhas.

**Mais leve**
- O larperCord agora abre direto nos seus servidores, canais e conversas recentes a partir do que guardou da última vez, sem esperar o Discord: nos nossos testes, a primeira tela útil passou de uns 1,6 s para uns 0,1 s. Enquanto conecta, a caixa diz que dá para enviar quando conectar, e nada pula quando os dados de verdade chegam; o conjunto de abas em uso volta junto. Segue Configurações → Privacidade → "Guardar mensagens no disco", e Apagar cache apaga junto.
- No Linux, a memória não se acumula mais depois de horas de uso: os buffers de imagem liberados voltam ao sistema em vez de ficar presos nas arenas da glibc de cada thread. Na conta do desenvolvedor, depois de 4h30, eram uns 190 MB parados à toa.
- Configurações → Desempenho deixa escolher o renderizador: Automático ou um dos que o SDL tem no seu computador (Vulkan, OpenGL, Direct3D…). Vale na próxima vez que o app abrir; se o escolhido não abrir, o app abre no automático e avisa. Serve para quando um deles se dá mal com o driver da sua placa de vídeo.

**Instalação**
- `install.sh --purge` e `install.ps1 -Purge` também apagam as configurações, o cache, o FFmpeg baixado, os seus sons e as contas salvas, do pedido do DivannKokos (#12). Desinstalar sem a opção continua guardando as configurações.
- Configurações → Avançado → "Apagar todos os dados…" faz o mesmo de dentro do app, sem desinstalar: depois de confirmar, apaga as configurações, os seus temas, mascotes, sons e plugins, os rascunhos e as mensagens salvas, o cache das conversas, o FFmpeg baixado, os registros de depuração e as contas salvas com os tokens do chaveiro (no Windows, do Gerenciador de Credenciais), e fecha. Nada é gravado de novo na saída.

**Site e documentação**
- Criador de temas: um divisor entre as prévias clara e escura dá mais largura a uma delas; clique duplo volta ao meio.

## 0.6.4

**Conversas**
- A lista de DMs mantém a conversa mais recente em cima, ao vivo: uma mensagem que você recebe ou manda sobe a DM na hora.
- Uma DM nova aparece no topo, mesmo quando só a mensagem dela chega, e uma DM que você fechou volta quando chega uma mensagem nova nela.

**Mensagens**
- Depois de escolher um emoji, pelo seletor ou pela lista do `:`, o cursor fica logo depois dele em vez de pular para o começo da caixa.
- O emoji das reações fica no meio do chip, com qualquer fonte de emoji.
- As barras invertidas do markdown somem como no Discord: `\.`, `\*`, `\_`, `\~` e `\\` mostram só o caractere, fora do código, nas mensagens e nos embeds.
- "1. Hello" mantém o espaço depois do número.
- No layout de balões (Bolhas, Cupertino), o "(apagada)" do registro de mensagens não cobre mais o texto alinhado à direita.

**Mídia e GIFs**
- GIFs longos, como os do Klipy, voltam a tocar sozinhos, não só com o mouse em cima. Isso quebrou na 0.6.2.
- Imagens de embed que o proxy de mídia do Discord não reduz, como as dos cartões do X/Twitter, agora carregam pela original. Com o log de depuração ligado, ele diz por que uma imagem falhou.
- GIFs e emojis animados param enquanto a janela do larperCord está sem foco, como no Discord, então a janela aberta em outro monitor ou atrás de um jogo não fica redesenhando por causa deles. Com o mouse em cima, continuam tocando. As imagens e miniaturas dos embeds de link agora também seguem "Reproduzir GIFs automaticamente"; antes tocavam sempre.

**Chamadas**
- Canais de voz com call mostram há quanto tempo ela está rolando, como no Discord (`16:42:14`). Escolha o formato, ou desligue, em Configurações → Aparência → Canais de voz. Também dá para escrever o seu com `{H}`, `{mm}`, `{ss}` e os outros campos. O app só acorda por isso com algum tempo na tela, e só quando o texto muda: uma vez por segundo com segundos, no máximo uma vez por minuto sem.
- O menu do botão direito de quem está na sua call tem o Volume do usuário, de 0 a 200% (100% é o normal), e Silenciar para mim, a partir do pedido de mdvtnk (#17). Ele aparece onde a pessoa estiver: no canal de voz, na lista de membros, numa mensagem, numa call de DM. É o mesmo ajuste do mixer da call, então os dois andam juntos e fica salvo. Silenciar mantém o volume dela, então tirar o silêncio volta para o mesmo nível, no menu e no mixer.
- Nos temas de estilo terminal (Terminal, Subsolo), [mixer] e [sair] na faixa de voz respondem onde estão escritos. A área de clique ficava num ponto fixo perto da borda direita e mudava com o nome do canal e o tamanho da fonte.
- Quem você silenciou no botão do mixer antigo (volume em zero) aparece como Silenciar para mim, e tirar o silêncio volta para o volume normal.

**Voz**
- No Windows, o aperte para falar funciona com outra janela em foco, como um jogo, a pedido do helpik1 (#14). O app lê a tecla sem gancho de teclado, e o outro programa continua recebendo a tecla. No Linux ainda precisa da janela do larperCord em foco.

**Bandeja**
- No KDE e no GNOME com Wayland, clicar no ícone da bandeja traz a janela para a frente quando ela está atrás de outra ou minimizada. Antes o KDE só marcava a janela como pedindo atenção, e o GNOME mostrava um aviso de "está pronto".

**Texto em qualquer idioma**
- Interface em russo, traduzida pelo pIat0n (#15, #16). Escolha "Русский" em Configurações → Idioma, ou o app segue um sistema em russo. As datas usam os nomes dos meses e dos dias da semana em russo.
- Os horários do Discord aparecem em japonês e em russo, também os relativos, como "3日前" e "3 дня назад", com os plurais do russo. Antes saíam em inglês.
- Em japonês, as datas voltam a sair na ordem certa (algumas apareciam dia/mês ou ano/dia/mês), e as sugestões `has:` e `before:` da busca funcionam em japonês e russo.
- Mais correções no árabe e no hebraico, a partir do relato de majd-tqe (#9). Título, autor e nome de campo de embed que começam em árabe ou hebraico terminam na borda direita do cartão, como a descrição.
- Uma linha que começa com número, como "1." ou "12-", fica da direita para a esquerda, com o número e o ponto ou o traço na ordem certa.
- Parênteses saem espelhados, e o "؟" e as outras pontuações ficam no lugar certo quando a frase tem inglês no meio.
- Os marcadores de lista, com bolinha ou número, ficam à direita.
- O espaço a mais antes de alguns emojis, como ⚠️ e ✔️, sumiu.
- A letra ہ do urdu aparece em vez de `?`, e as Configurações não dizem mais que falta fonte para o árabe quando o DejaVu Sans o tem.
- As bandeiras da Inglaterra, da Escócia e do País de Gales, e alguns caracteres invisíveis raros, não custam mais cerca de 5,5 MB de memória para cada fonte e tamanho.

**Limitações conhecidas**
- Árabe e hebraico digitados na caixa de mensagem ainda vão da esquerda para a direita. A mensagem aparece certa depois de enviada.
- Escritas que precisam de composição, como devanágari, bengali, tailandês ou khmer, mostram as letras de verdade uma a uma, sem as ligaduras nem os sinais de vogal reposicionados.
- O `.exe` único do Windows é opcional, para quem compila com `-Dsingle-exe=true`. As releases continuam com o `.exe` e as DLLs.
- Comandos de apps no botão direito, arquivos nos formulários de bots e gravar mensagens de voz ainda não têm suporte.

## 0.6.3

**Chamadas**
- Ser movido para outro canal de voz não tira mais você da call: o larperCord segue você até o canal novo.

**Projeto**
- Todos os arquivos de uma release agora são compilados no GitHub, cada um com o atestado de que saiu deste código.

## 0.6.2

**Chamadas**
- Ligue de qualquer DM ou grupo pelo botão de telefone no cabeçalho, em todos os temas. Uma chamada chegando mostra um cartão com Atender e Recusar e toca até você responder. Ela também manda uma notificação do sistema e pisca a barra de tarefas, mesmo com o app na bandeja.
- No Não perturbe, ou numa DM ou grupo silenciado, o cartão aparece sem o toque. O toque para quando você atende em outro aparelho ou quem ligou desiste.
- Configurações → Voz → Sons escolhe cada som da call: Desligado, Clássico, Suave, Cristal, Retrô ou um arquivo seu em WAV ou Ogg Opus, com prévia e volume. Alguém entrando ou saindo da sua call também tem som, desligado de início.
- Botão direito no microfone ou no fone troca o dispositivo e o volume dele, mesmo no meio da call. Ctrl+Shift+M muta e Ctrl+Shift+D ensurdece.
- O começo de uma palavra depois de uma pausa curta de quem fala não engasga mais. Os quadros de silêncio dessa pessoa agora tocam, e a reserva continua lá quando ela volta a falar.

**Bots e apps**
- Botões e menus de seleção nas mensagens de bots funcionam. Um bot que não responde mostra "Esta interação falhou", e as respostas que só você vê podem ser dispensadas.
- Os formulários dos bots (modais) abrem no app, com campos de texto, seleções e grupos de opção e de caixas de marcar.
- Digitar `/` lista os comandos de barra dos bots do servidor e dos seus apps. Um painel preenche subcomandos, opções, escolhas, sugestões enquanto você digita, e arquivos.
- Um clique que esperou mais de 12 s, numa reconexão por exemplo, é descartado em vez de chegar atrasado ao bot.

**Mensagens**
- Respondendo, o "@ LIGADO / @ DESLIGADO" da barra da resposta escolhe se o autor recebe a menção.
- Um botão ao lado do GIF manda a próxima mensagem em silêncio (ou comece com `@silent `), sem prévia de links, ou sem mencionar ninguém.
- Cada arquivo da bandeja de envio pode virar spoiler e ganhar um texto alternativo.
- Vote nas enquetes, tire o voto ou veja o resultado antes. A contagem atualiza na hora, e clicar numa resposta mostra quem votou nela.
- Botão direito numa reação, ou Ver reações no menu da mensagem, mostra quem reagiu, com as super reações à parte.
- O painel de mensagens fixadas carrega mais de 50.
- A resposta a uma mensagem sem texto mostra o que ela tinha: o nome do arquivo, a figurinha, uma mensagem de voz, a pergunta da enquete ou o título do embed.
- As menções são destacadas pela regra do Discord: você, respostas que te mencionam, os seus cargos, @everyone e @here, seguindo o que o servidor suprime. Os contadores de não lidas, a caixa de entrada e as notificações usam a mesma regra, e o destaque aparece em todos os temas.

**Mídia e GIFs**
- Spoilers e mídias que o Discord marca como sensíveis ficam atrás de uma capa até você clicar, e nada é baixado antes disso.
- Imagens com o link do Discord vencido são renovadas sozinhas, só as que estão na tela.
- Mensagens de voz têm um player: tocar, pausar, uma onda para pular e a duração.
- O seletor de GIFs tem a aba Figurinhas, com as deste servidor, as dos seus outros servidores e as do próprio Discord. Um clique envia.
- Passe o mouse num GIF, numa mensagem ou no seletor, e clique na estrela para pôr nos seus favoritos ou tirar.
- GIFs longos tocam todos os quadros na velocidade certa. Num teste de 16 s, a 0.6.1 guardava 25 de 400 quadros; agora tocam todos, em cerca de 8 MB.
- Configurações → Chat → Vídeos tem Escolher a pasta do FFmpeg… para um FFmpeg 7, 8 ou 9 "shared" que você já tem: o app confere se a pasta tem o conjunto inteiro e procura nela antes de tudo. Sem o FFmpeg, a página diz o porquê: os nomes de arquivo que procurou, um `ffmpeg` no PATH que é uma versão estática, sem as bibliotecas (é o que o winget, o choco e o gyan.dev instalam), uma versão que o app não usa ou uma biblioteca que está lá e não carregou, com o motivo dado pelo sistema. No Windows o app também procura as DLLs em cada pasta do PATH. A partir do relato de DivannKokos (#10).

**Sua conta**
- Bloquear e desbloquear pelo menu da pessoa ou pelo perfil completo.
- Ignorar fica gravado na sua conta do Discord. Quem você ignorou antes continua ignorado neste computador, e Configurações → Alertas e filtros lista os dois.
- Adicionar amigo nos perfis e no menu da pessoa, e uma aba Adicionar amigo na página Amigos que aceita o nome de usuário. Os pedidos enviados podem ser cancelados na aba Pendentes.
- Silenciar e o nível das notificações sincronizam com a sua conta, para servidores, categorias, canais e DMs, e o que você muda no celular aparece na hora.
- Mudar o status grava na sua conta, então sair do Invisível funciona. Ausente, Não perturbe e Invisível podem durar de 15 minutos a 3 dias, e o app abre com o status que a sua conta tem.
- Clique no seu nome para definir um status personalizado, com texto, um emoji e quando ele some.
- Configurações → Minha conta edita o nome que aparece, os pronomes e o Sobre mim.
- Rich Presence: jogos e apps que têm suporte podem mostrar o que você está jogando. Vem desligado, em Configurações → Privacidade, e desligado nada fica escutando.

**Conversas**
- DMs de quem não é seu amigo vão para Pedidos de mensagem, embaixo de Amigos, com uma aba de Spam, Aceitar e Recusar. Elas não notificam.
- Botão direito num grupo → Pessoas do grupo… adiciona amigos ou, se o grupo é seu, tira alguém. Sair pede confirmação.
- Edite uma thread pelo menu dela ou clicando no título: nome, tags do fórum e auto-arquivar. Arquivar e trancar são um clique.
- O painel de threads tem a aba Privadas, com as threads privadas arquivadas.

**Servidores**
- Expulsar, banir, castigar, e silenciar ou ensurdecer no servidor pelo menu da pessoa, só quando você pode. Expulsar, banir e castigar pedem confirmação e aceitam um motivo para o registro de auditoria. Banimentos, no menu do servidor, lista quem está banido e revoga.
- Entrar por um convite avisa antes: entrar ou sair de muitos servidores rápido é o motivo mais comum para contas em clientes de terceiros serem bloqueadas.
- Se um servidor pede para aceitar as regras, a caixa de mensagem avisa e abre as regras, e você responde cada item. Servidores com boas-vindas têm isso no menu.
- A caixa de mensagem mostra o modo lento com contagem regressiva, e diz por que você não pode enviar: sem permissão, thread trancada, castigo ou quarentena do AutoMod.
- Se o Discord recusa uma mensagem por ser rápida demais, você vê quanto esperar, e a mensagem fica para reenviar.

**Texto em qualquer idioma**
- Árabe e hebraico aparecem certos, a partir do relato de majd-tqe (#9). As letras árabes saem ligadas, e o texto da direita para a esquerda vem na ordem certa nas mensagens, nos embeds e nos nomes de pessoas, canais e servidores. Parágrafos da direita para a esquerda ficam alinhados à direita nas mensagens e nos embeds, cada um por si quando a mensagem mistura idiomas. Copiar continua devolvendo exatamente o que foi escrito.
- Uma letra que falta na fonte do tema, em qualquer escrita (tailandês, devanágari, etíope, georgiano, armênio, tibetano…), vem de uma fonte do sistema que a tenha, em vez de `?`. Cada bloco é procurado uma vez, só quando um texto assim aparece.
- A interface inteira agora está em japonês, partindo da tradução de nakayama900. As traduções ficam num arquivo por idioma (`i18n/ja.kdl`, o texto em inglês e depois a tradução), então qualquer pessoa corrige uma linha ou começa um idioma novo sem mexer no código; uma cópia na pasta de configurações substitui a embutida.

**Temas**
- O rodapé do Zen mostra o seu status e os botões de mudo e ensurdecer, e a faixa de servidores ganha fundo quando aparece.
- Terminal, Subsolo, Orbital e Editorial mostram os botões [mic] [fone], riscados quando ligados. A manchete do Editorial vira uma linha só em janelas baixas.
- O Papel tem busca, botão de membros e a coluna da "Chamada", e o cabeçalho mínimo (Zen, Cupertino, Bolhas, Orbital, Editorial, Papel) tem botão de busca.
- Para quem faz temas: `hide-below-height=`, `only-below-height=` e os itens `me`, `mic` e `deaf` da barra de status.

**Rede e privacidade**
- O proxy tem uma página só dele, Configurações → Rede, com campos separados: tipo (HTTP, HTTPS, SOCKS5, SOCKS5h para o Tor), endereço, porta, login e senha, que aceitam qualquer caractere. Colar uma URL inteira preenche todos, e o proxy salvo continua valendo. A tela de entrada tem o mesmo formulário ("Conectar por um proxy"), que vale também para entrar, e quando a entrada não chega ao Discord ela diz o porquê e pergunta "Não consegui chegar ao Discord — tentar um proxy?". Um proxy trocado já vale na próxima tentativa de conexão. A partir do relato de degger80 no #6, com as sugestões de DivannKokos.
- As calls de voz sempre conectam direto, mesmo com "Usar o proxy em tudo", e a configuração agora diz isso.
- Configurações → Avançado → Depuração conta quantas vezes o Discord pediu captcha, pediu verificação da conta ou recusou a sessão.
- Toda conexão com o Discord, inclusive a voz e os servidores de imagens dele, usa os mesmos cabeçalhos do cliente web, só por https e wss, e sempre confere o certificado.

**Mais leve**
- O download para Linux foi de 15,36 para 14,25 MB e não exporta nenhum símbolo (a 0.6.1 exportava 4.988). O OpenSSL agora é compilado só com o que o app usa, e a SDL3 e o curl deixam o resto de fora.
- Um quadro ficou cerca de 7% mais rápido, e a primeira conversa aparece cerca de 10% antes: no Linux, o fontconfig se prepara enquanto a janela abre. A memória e o CPU parado continuam iguais.
- O zip do Windows cresceu cerca de 4% com as novidades desta versão.

**Linux e Windows**
- Num desktop Wayland o app roda nativo, com o X11 de reserva, de Kainoa Kanter (ThatOneCalculator) no #1.
- Com Fechar para a bandeja ligado, como vem por padrão, o ícone fica na bandeja da abertura até sair, como no app oficial: Abrir e Sair no menu dele funcionam com a janela aberta, e o clique esquerdo no ícone mostra ou esconde a janela, no Windows e no Linux. Desligado, não há ícone e fechar encerra o app. No Linux o ícone é um processo pequeno à parte que fala o protocolo da bandeja pelo D-Bus, sem GTK: cerca de 6 MB e nenhum despertar parado, contra uns 14 MB e 20 despertares por segundo com o libappindicator. Volta sozinho se cair. A pedido de DivannKokos (#11).
- Uma atualização troca o arquivo que você roda de fato, com o nome que ele tiver, e reabre esse arquivo. Antes, o download para Linux continuava na versão velha e o Reiniciar podia não abrir nada.
- O app abre num sistema sem nenhuma fonte, como um Windows ou wine sem `C:\Windows\Fonts`, com a fonte que vem dentro do Dear ImGui.
- No Windows, as dicas do app citam as pastas do Windows e o Gerenciador de Credenciais, e o OpenSSL não lê mais um `openssl.cnf` de uma pasta que outro usuário poderia criar.
- `larpercord --version` mostra a versão, para scripts e pacotes.

**Site e documentação**
- O site tem um criador de temas com prévia ao vivo, conferência de contraste e um `.kdl` para baixar. Ele também aproveita as cores de um tema do BetterDiscord ou do Vencord.
- Uma galeria de temas da comunidade, conferida em todo build: veja um tema ao vivo, abra no criador ou baixe.
- Experimente no navegador: o app de verdade no modo demonstração, compilado para WebAssembly, sem conta e sem rede.
- Páginas novas com o que o larperCord tem e o Discord não, com todos os atalhos de teclado, e um diretório de plugins com um gerador que escreve um plugin em Lua para você.
- A seção de download escolhe pelo seu sistema (AUR, script de instalação ou zip), e a documentação cobre o Windows ao lado do Linux.

**Correções**
- Entrar, sair, mudo e ensurdecer não se perdem mais quando a conexão cai bem nessa hora. Eles vão de novo quando a sessão é retomada.
- Depois de reiniciar, os limites de memória para imagens, cada GIF e mensagens caíam para o mínimo, o que deixava os GIFs travados. Agora eles carregam como foram salvos, o arquivo de configurações da 0.6.1 é corrigido, e cada GIF volta a poder usar 32 MB.
- O nome de quem está offline voltou a ficar legível em todos os temas.
- Os menus de contexto param na altura da janela e rolam.
- Segurar Ctrl+Tab troca de aba uma vez por toque, e passar rápido pelos canais só pede ao Discord a lista de membros daquele em que você para.
- No Windows, dá para abrir, copiar ou anexar o registro de depuração com ele ligado. Antes, nenhum outro programa conseguia ler o arquivo até você desligar.

**Limitações conhecidas**
- Árabe e hebraico digitados na caixa de mensagem ainda vão da esquerda para a direita. A mensagem aparece certa depois de enviada.
- Escritas que precisam de composição, como devanágari, bengali, tailandês ou khmer, mostram as letras de verdade uma a uma, sem as ligaduras nem os sinais de vogal reposicionados.
- O `.exe` único do Windows é opcional, para quem compila com `-Dsingle-exe=true`. As releases continuam com o `.exe` e as DLLs.
- Comandos de apps no botão direito, arquivos nos formulários de bots e gravar mensagens de voz ainda não têm suporte.

## 0.6.1

**Mais idiomas e telas**
- A interface tem versão em japonês, de nakayama900. Texto ainda sem tradução aparece em inglês.
- Texto em japonês, coreano e chinês agora aparece. As fontes só carregam quando uma letra precisa delas, e o idioma da interface escolhe a forma das letras.
- A interface segue a escala da tela no Windows e no X11, de Davyd Khanin. Ela não fica mais minúscula em 125% ou 150%.
- Configurações → Aparência tem o tamanho da interface, de 75 a 200%, e Ctrl + , Ctrl - e Ctrl 0 mudam de qualquer lugar.
- F11 e Alt+Enter ligam e desligam a tela cheia.
- Nomes de canais e pessoas em letras estilizadas (𝗠𝗲𝗺𝗲𝘀, ʀᴇɢʀᴀs) aparecem em letras comuns quando nenhuma fonte tem o desenho, em vez de `??????`. Configurações → Avançado lista as escritas que continuam sem fonte.

**Mais nítido**
- O texto pequeno ficou nítido. Tamanhos como 13,5 eram gerados em 14 e encolhidos como imagem, o que borrava quase todo texto cinza.
- O texto também encaixa nos pixels da tela em tamanhos como 125%.
- O texto secundário tem contraste mínimo em todos os temas, inclusive os da comunidade.
- Configurações → Avançado → Texto muda o peso do texto e como as letras encaixam nos pixels, na hora.
- Avatares, ícones e imagens ficam guardados no tamanho em que aparecem e são reduzidos com um filtro melhor. Antes, uma foto de 128 px era encolhida pela placa de vídeo sem filtro, o que serrilhava. Isso também gasta menos memória.
- As imagens não saem mais esticadas nem cortadas nas mensagens, nos embeds e na tela cheia, inclusive depois de redimensionar a janela.

**Chamadas**
- Corrigidas as rajadas de ruído alto, de Davyd Khanin. Alguns pacotes de voz vêm com padding, e o app mandava esses pacotes ainda cifrados para o decodificador.
- O começo de uma frase depois de uma pausa não sai mais alto do que deveria. Os quadros de silêncio agora passam pelo decodificador, e ele recomeça depois de uma pausa ou de um buraco grande.
- Configurações → Avançado tem um registro de depuração: ligue, faça o problema acontecer e mande o arquivo, sem terminal. Ele também anota saltos de volume e quantos pacotes vieram com padding.

**Novidades**
- A busca tem um painel lateral com filtros, ordem e páginas. Digitando, ela procura neste computador, e com Enter, no Discord.
- Encaminhar uma mensagem para outro canal.
- Entrar em um servidor por link ou código, e criar e editar convites nos menus do servidor e do canal.
- Seletor de GIFs ao lado do botão de emoji: em alta, busca e seus favoritos do Discord. O GIF anima com o mouse em cima.
- Copiar a imagem na tela cheia, e ampliar com a roda do mouse. Ctrl+V cola PNG, BMP, JPEG, GIF e WebP.
- Sair de um servidor pelo menu dele, com confirmação.
- O painel de mensagens fixadas mostra imagens, vídeos e prévias de link.
- Configurações → Chat pode baixar o FFmpeg no Windows para os vídeos tocarem no app, com aviso antes e SHA-256 conferido.
- Configurações → Desempenho tem limites para imagens, cada GIF e mensagens na memória.

**Correções**
- Quem está invisível não aparece mais online por um instante ao abrir o app. O status agora vai já na primeira conexão.
- Reconectar ficou mais calmo: uma conexão só conta como boa depois de um minuto. Um servidor que aceita e derruba não vira mais uma nova tentativa de login a cada poucos segundos.
- Segurar Shift+J ou Shift+K no modo Vim não varre mais os canais.
- Arrastar a barra de rolagem das mensagens não trava mais quando o mouse escapa dela ou quando mensagens antigas carregam.
- Um GIF que declara um tamanho enorme é recusado antes de decodificar, de svindler, para um arquivo pequeno não acabar com a sua memória.
- Temas sem o painel do usuário, como o Zen, têm um botão de configurações no cabeçalho.
- Instalado por um gerenciador de pacotes, o app avisa para atualizar por ele.

**Projeto**
- O larperCord agora usa a licença GPL-3.0.

## 0.6.0

**Plugins**
- A tradução agora tem opções: idioma de destino e de origem no cartão em Configurações → Plugins, e "Traduzir para…" no botão direito para uma mensagem só. Um 🌐 na barra da mensagem, e `/tr es olá` põe uma tradução na caixa de mensagem.
- Anti-golpe marca em vermelho os golpes clássicos de Discord nas mensagens dos outros: endereços que imitam o Discord ou a Steam, Nitro grátis falso com link, links encurtados com isca. Roda no seu computador, sem rede, e endereços oficiais nunca são marcados.
- Radar de CVE acha `CVE-2021-44228` nas mensagens e mostra embaixo a severidade, a nota CVSS e um resumo, do registro oficial. Cada número é pedido uma vez, e só depois de aprovar o host.
- Cartões do GitHub põem o título, o estado e as estrelas embaixo de `dono/repo#123` e de links do GitHub.
- O que perdi resume as mensagens não lidas de um canal: quantas de cada pessoa, menções a você, perguntas sem resposta, links e arquivos, com um clique até cada um.
- Também novos: Links limpos tira o rastreio dos links que você envia, e Links e arquivos lista o que foi compartilhado no canal.
- Lembretes entendem hora e data (`/remind amanhã 9h`, `/remind todo dia 8:30`), têm uma segunda lista no botão direito, e o que já avisou pode voltar em 10 minutos.
- Destaques mostra quantos você não viu, silencia um canal, acompanha edições e pode usar as notificações do sistema.
- Favoritos, o filtro de palavras, trechos, horários, estatísticas e os plugins de demonstração não vêm mais com o app: os dois primeiros viraram funções do próprio app. Quem tem continua usando, e um botão arquiva em `plugins/antigos/`. Nada é apagado.
- Um plugin incluído com versão nova mostra um botão de atualizar no cartão, e guarda o seu arquivo como `.bak`.
- Novo para quem faz plugins: opções no cartão (`larper.settings`, `select`, `toggle`), segunda lista e botão na barra nos menus, sugestões na caixa de mensagem (`larper.completions`), regras para o que você envia (`larper.rewrite`), `larper.copy`, `larper.open`, um número na etiqueta do painel, notas em vermelho, os eventos `edit`, `dismiss` e `hosts`, um filtro `contains` que mantém as mensagens longe do Lua, e anexos, respostas, menções e a posição de leitura em `larper.messages`.
- Um plugin atrasado perde mensagens em vez de segurar os outros, e o cartão dele diz isso. Cada plugin tem o próprio limite de notificações do sistema: um barulhento não come o aviso de um lembrete.
- O cartão avisa quando um plugin lê mensagens e também consegue mandar algo para fora.
- Fechar uma tradução com o × não faz mais o próximo "Traduzir" não fazer nada.

**Mensagens**
- Horários `<t:…>` aparecem como uma data ou "em 2 horas", no seu fuso, em vez do código.
- Em cima de um link, o cursor vira a mãozinha. A seleção de texto estava passando por cima dela.
- Arrastar a barra de rolagem das mensagens não seleciona mais o texto, e a alça de redimensionar não cobre mais a barra.
- Marcar como lida e como não lida agora sempre chega ao Discord. Com o status invisível, ficava só no seu computador e voltava na próxima conexão. O status não impede mais a confirmação de leitura; com a janela sem foco, ela continua não indo sozinha.

**Mais leve**
- Quadro que sai igual ao anterior não é desenhado de novo, então eventos da rede que não mudam nada na tela custam menos.
- Mexer o mouse sem botão apertado pede menos quadros.
- Depois de um minuto na bandeja ou minimizada, as imagens saem da memória, menos as pequenas que estavam na tela.
- Configurações → Desempenho mostra para onde vai a memória: imagens, mensagens, pessoas, servidores, fontes, driver e bibliotecas.

**Contas**
- A tela de login mostra todas as contas salvas como botões, venha de onde vier, com um aviso para usar conta secundária antes de colar um token.
- Quando o Discord recusa um token, o app esquece esse token em vez de tentar de novo a cada abertura. Se a sessão acabar com o app aberto, ele volta para a tela de login.

**Instalação**
- O download para Linux roda em distros de 2022 para cá (glibc 2.34), e não exige mais uma bem recente. SDL3, libcurl e OpenSSL agora vêm dentro dele, então o arquivo foi de cerca de 7 MB para cerca de 15 MB.
- O GitHub Actions compila o arquivo para Linux, abre em Ubuntu, Debian, Fedora, openSUSE e Arch, e publica um atestado que dá para conferir com `gh attestation verify`.
- O instalador do Linux dá ao atalho o ID da janela, para as barras que procuram o ícone desse jeito acharem. Rodar de novo troca o atalho antigo.

## 0.5.0

**Windows**
- O larperCord agora roda no Windows 10 e 11, a partir do mesmo código.
- Os tokens ficam no Gerenciador de Credenciais do Windows.

**Atualizações**
- Verifica se há versão nova ao abrir ou em Configurações → Atualizações.
- Um botão baixa, instala e reinicia. As atualizações são assinadas, e uma versão sem a assinatura certa não é instalada.
- Botão de reiniciar nas Configurações, e esta página.

**Voz**
- Supressão de ruído no microfone com RNNoise, ligada por padrão e trocável em plena call. Não roda com a tecla do aperte para falar solta.
- Menos engasgos e nada de estalos quando um pacote se perde ou chega fora de ordem; a folga de áudio cresce quando a rede engasga.
- As pessoas não somem mais por um instante quando alguém entra ou sai da call.
- Quando a rede trava, a voz se apaga em vez de cortar no meio da palavra, e volta sem estalo.
- A pausa da porta de ruído de alguém não é mais tratada como rede ruim, o que mantém o atraso do áudio baixo.
- A supressão de ruído usa menos CPU nas versões publicadas: ela escolhe o caminho mais rápido para o seu processador ao rodar.

**Bandeja**
- Fechar e reabrir não empilha mais ícones na bandeja. No Linux o ícone fica num processo pequeno à parte, que só existe com a janela escondida, e o GTK fica fora do app.

**Layout**
- Arraste a borda da lista de canais, da lista de membros ou dos painéis da tela dividida para mudar a largura. Duplo clique volta à largura do tema, e a sua escolha fica salva e vale nos outros temas.
- Conversa estreita continua funcionando: a caixa de busca sai antes dos botões.

**Mensagens**
- Etiqueta BOT ao lado do nome de bots e webhooks, com um ✓ nos bots verificados, nas mensagens, na lista de membros, nas DMs e nos perfis.
- Mensagens de webhook ficam com o nome e a foto com que cada uma foi enviada.
- Mensagens de bot no formato novo de componentes, que apareciam em branco. Encaminhadas e enquetes aparecem como cartões.
- O texto de embeds pode ser selecionado e copiado.
- Markdown do Discord: títulos, texto pequeno, citações, listas e links `[texto](url)`. Número de linha nos blocos de código.
- A seleção de texto dentro de um bloco de código agora aparece.
- Esc cancela a edição de uma mensagem.
- Botão direito ou do meio não dispara mais o clique normal de um botão. Na barra de ações da mensagem, por exemplo, ele adicionava a reação.
- Erros no código enquanto digita um bloco, opcional, com o servidor de linguagem que você escolher.

**Servidores e grupos**
- Editar um servidor (nome, descrição, ícone, banner) ou um grupo de DM (nome, ícone).
- Excluir threads.
- Banner do servidor no topo da lista de canais e nos cartões de convite.
- Clique no banner de um servidor para ver a imagem inteira, e o mesmo no banner de um perfil. Os menus do servidor e da pessoa também abrem o ícone ou a foto.
- Ícones de amigos, de grupo e do alfinete redesenhados.

**Plugins**
- Os plugins agora rodam numa thread só deles: um lento ou travado não engasga a interface, e é parado com o erro no cartão. Sem plugin ligado, a thread nem existe e nenhum Lua é carregado.
- Plugins novos que vêm com o app: favoritos, lembretes, destaques, filtro local, trechos, tradução e estatísticas do canal. Configurações → Plugins instala, sem mexer nos seus arquivos.
- Configurações → Plugins mostra um cartão para cada plugin, a partir de um cabeçalho no começo do arquivo: nome, descrição, versão, o que ele pede, erros e um jeito de abrir o painel, mesmo desligado.
- O que os plugins podem fazer agora: painéis numa lateral que se encaixa de qualquer lado, entradas no botão direito de mensagens e pessoas, selos, notas e recolher com "mostrar" embaixo das mensagens, dados próprios, temporizadores, notificações do sistema, mensagens carregadas, pular para uma mensagem e pôr texto na caixa de mensagem.
- HTTPS opcional para plugins, só para os hosts que você aprovar um a um, sem cookies, token nem cabeçalhos do Discord.
- Os arquivos que já estavam na pasta de plugins continuam funcionando, e os exemplos das versões antigas não são apagados.

**Mais leve**
- Executável menor, abertura mais rápida e menos memória.

## 0.4.0

Primeira versão pública: conexão real com o Discord, voz com criptografia de ponta a ponta, threads e fóruns, leitura sincronizada, busca, plugins em Lua e 11 temas.
