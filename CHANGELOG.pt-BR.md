# O que mudou em cada versão

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
- Tela da call, a outra metade do pedido do helpik1 (#19): clicar num canal de voz abre a call no lugar da conversa, com um quadro por pessoa: a foto e o apelido do servidor, o anel verde enquanto fala, o microfone e o som quando estão desligados, o que está jogando e o selo AO VIVO de quem transmite. Clique num quadro para o menu da pessoa (volume, silenciar para mim). O seu microfone, som, mixer e sair ficam no lugar da caixa de mensagem. Esc, "Voltar à conversa", trocar de aba ou um canal de texto voltam, e clicar no status da call na faixa de voz abre de novo. Calls em DM e grupo ganham a mesma grade em cima da conversa. Nos temas de terminal, ela aparece em texto. Sem câmera nem compartilhamento de tela, como antes.
- A tela da call segue o tema: cada quadro usa as cores, os cantos e o estilo de cartão do tema (vidro no vidro, papel no papel, recorte de jornal no editorial…), com só um toque da cor da foto de cada pessoa, e o texto troca de cor quando ficaria difícil de ler. Quem faz tema escolhe isso com `call-style` e `call-tint` no componente `messages` (veja o guia de temas). Sozinho na call, o seu quadro fica menor e embaixo o mascote cochila ao lado de "Só você por aqui" e do botão "Convidar pessoas". Os botões ficam numa barra com o tempo da call, e passar o mouse no seu quadro mostra o nível do seu microfone com a marca do limiar da detecção de voz (só então ele gasta algo).
- No mixer da call, cada pessoa ganhou "Tirar ruído" e "Igualar volume", os dois desligados de começo e só para aquela pessoa. Tirar ruído usa no som dela o mesmo supressor de ruído do seu microfone (gasta um pouco de CPU enquanto ela fala, por isso é por pessoa). Igualar volume sobe quem fala baixo e desce quem fala alto, para perto do volume dos outros, sem subir o chiado das pausas. As escolhas ficam guardadas e valem em toda call.

**Atalhos de teclado**
- Dá para trocar os atalhos, do pedido do ShuyaGit (#18). Em Configurações → Atalhos de teclado, clique num atalho e aperte as teclas novas. Combinação já usada, as fixas (copiar, colar, nova linha, andar no texto), letra sozinha e Ctrl+Alt com letra (o AltGr em muitos teclados) são recusadas com o motivo; "Padrão" volta. As dicas que citam um atalho mostram as teclas de agora.

**Texto em qualquer idioma**
- "Online", "Offline", "Proxy" e outras palavras que faltavam nos arquivos de tradução agora aparecem em japonês e em russo, assim como as descrições e as opções dos temas embutidos, o submenu de prazo do status, as dicas da caixa de mensagem e as ações das imagens, do relato do DivannKokos (#20). O cartão do tema mostra a descrição inteira, em até duas linhas, e o resto ao passar o mouse.
- O texto traduzido não sai mais cortado em russo e japonês: Sobre, o aviso de espera para entrar em servidores, a nota do modo foco e "N menções em <servidor>" com nome comprido. Botões e notas das Configurações também não passam mais da borda. Do relato do DivannKokos (#22).
- O russo usa ё onde deve, do DivannKokos (#21).
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
