# Escrevendo mascotes

[English](README.md) · **Português**

O mascote Terminal (o gato roxo com a cara `>_`) veste o que você quiser. Em Configurações → Mascote →
**Personalizar** você escolhe olhos, bocas, chapéus, acessórios, orelhas e cores de uma biblioteca, com prévia
ao vivo. Um arquivo de mascote vai além: é um arquivo [KDL](https://kdl.dev) que escolhe essas mesmas peças **e
pode desenhar as próprias** com formas simples, um desenho por expressão. O arquivo é só dado: nada nele roda.

Ponha o arquivo, por exemplo `meu-mascote.kdl`, na pasta de mascotes:

| Sistema | Pasta |
|---|---|
| Linux | `~/.config/larpercord/mascots/` (ou `$XDG_CONFIG_HOME/larpercord/mascots/` quando essa variável existe) |
| Windows | `%APPDATA%\larpercord\mascots\`, em geral `C:\Users\<você>\AppData\Roaming\larpercord\mascots\`. Para abrir, cole `%APPDATA%\larpercord` na barra de endereço do Explorador de Arquivos |

O jeito mais fácil de começar: monte um visual em Configurações → Mascote → Personalizar e aperte **Salvar como
arquivo**. O app grava o arquivo na pasta, passa a usar ele e mostra em **Arquivos de mascote**, onde **Abrir
pasta** abre a pasta para você. **Daí em diante, salvar o arquivo atualiza o mascote na hora**, em todo lugar
onde ele aparece: a abertura, a página Sobre, as listas vazias e o mascote do canto. Se tiver erro, o cartão do
arquivo mostra `arquivo:linha:coluna` e o mascote fica com a última versão que funcionou.

Salve o arquivo em UTF-8 (no Windows, o "UTF-8" do Bloco de Notas serve).

## Exemplo mínimo

```kdl
mascot "Pirata Pedro" author="você" license="CC0-1.0"

look eyes="dots" mouth="fang" hat="pirate" ears="pointy" accessories="eyepatch earring"
colors palette="lava"
```

Isso já é um mascote inteiro: três linhas, nenhum desenho. Todo o resto abaixo é opcional.

## Nós do arquivo

| Nó | O que faz |
|---|---|
| `mascot "nome" author=… license=… description=…` | as informações. O nome aparece na lista de arquivos |
| `look eyes=… mouth=… hat=… ears=… accessories="…"` | peças da biblioteca (listas abaixo). O que ficar de fora continua o padrão |
| `colors palette="…"` ou `colors body-top="#…" …` ou `colors theme=#true` | as cinco cores (abaixo) |
| `eyes { … }` | olhos próprios, desenhados com formas. Valem no lugar de `look eyes=` |
| `mouth { … }` | boca própria, desenhada com formas. Vale no lugar de `look mouth=` |
| `layer "front" { … }` | formas na frente de tudo (um chapéu seu, óculos, um adesivo…) |
| `layer "back" { … }` | formas atrás do corpo (asas, um rabo, uma capa…) |

Nó, peça ou cor desconhecidos são erro com `arquivo:linha:coluna`: um erro de digitação nunca passa batido.

## Peças

**Olhos** (`look eyes=`): `prompt` (o `>_`, o padrão), `dots`, `ovals`, `big`, `cat`, `sleepy`, `happy`,
`wink`, `stars`, `hearts`, `pixel`, `binary`, `cyclops`, `lashes`, `visor`.

**Bocas** (`look mouth=`): `smile` (o padrão), `cursor`, `cat` (`:3`), `uwu`, `tongue`, `fang`, `vampire`,
`open`, `o`, `flat`, `wavy`, `smirk`, `grin`, `pout`, `whistle`, `bunny`.

**Chapéus** (`look hat=`): `none` (o padrão), `crown`, `tophat`, `beanie`, `cap`, `cowboy`, `chef`, `halo`,
`horns`, `flowers`, `viking`, `wizard`, `bow`, `propeller`, `beret`, `tiara`, `pirate`, `helmet`, `sprout`,
`antenna`, e os das datas: `santa`, `witch`, `party`. Com um chapéu escolhido, o mascote do canto não troca pelo
das datas.

**Acessórios** (`look accessories=`, vários separados por espaço): `glasses`, `shades`, `monocle`, `eyepatch`,
`blush`, `freckles`, `bandaid`, `mustache`, `bowtie`, `scarf`, `bandana`, `earring`. Óculos (`glasses`,
`shades`, `monocle`, `eyepatch`) e o que vai no pescoço (`bowtie`, `scarf`, `bandana`) são um de cada vez: vale
o último.

**Orelhas** (`look ears=`): `pointy` (o padrão), `round`, `floppy`, `bunny`, `tiny`, `none`.

Todo olho e toda boca têm uma versão para cada expressão (feliz, rindo, susto, bravo, triste, dormindo, tonto,
preocupado), e mais a piscada, o olhar, comendo e a cara de erro.

## Cores

```kdl
colors palette="meia-noite"
colors palette="menta" accent="#FF3366"         // uma paleta com uma cor trocada
colors body-top="#9D40FF" body-bottom="#7A1FE6" ink="#12061F" tufts="#F7A8FF" accent="#29E6FF"
colors theme=#true                               // segue a cor de destaque do tema
```

| Nome | O que pinta |
|---|---|
| `body-top`, `body-bottom` | o degradê do corpo, de cima para baixo |
| `ink` | o rosto (olhos, boca, bigode, armação dos óculos). Deixe com contraste com o corpo |
| `tufts` | a parte de dentro das orelhas, e uma segunda cor suave |
| `accent` | os detalhes: o fone em call, a gravatinha, o cachecol, a íris dos olhos de gato |

Paletas: `uva`, `menta`, `por-do-sol`, `oceano`, `morango`, `limao`, `grafite`, `neve`, `caramelo`, `matrix`,
`algodao-doce`, `lava`, `meia-noite`, `floresta`.

Sem o nó `colors`, o mascote fica no roxo de sempre, e o mascote do canto segue a cor de destaque do tema, como
sempre foi.

## Desenhando peças próprias

Dentro de `eyes`, `mouth` e `layer`, cada linha é uma forma. As coordenadas são nas unidades do desenho do
mascote (as mesmas de `assets/mascote-terminal.svg`, viewBox `-10 -34 147.14 134`):

- o corpo vai de x 0 a 127, o alto da cabeça fica em y ≈ 7 e os pés em y ≈ 96;
- os olhos de sempre ficam em (40, 50) e (84, 55): o rosto é um pouco inclinado, o lado direito mais baixo;
- a boca fica em volta de (63.5, 70);
- as pontas das orelhas ficam em cerca de (21, −15) e (106, −15); os chapéus assentam em y ≈ 5.

| Forma | Atributos |
|---|---|
| `circle` | `cx cy r` |
| `ellipse` | `cx cy rx ry`, `rotate` opcional (em graus) |
| `rect` | `x y w h`, `r` opcional (cantos redondos) |
| `line` | `x1 y1 x2 y2` |
| `polyline` | `points="x y x y …"` (aberta) |
| `polygon` | `points="x y x y …"` (fechada) |
| `path` | `d="M … L … H … V … Q … C … Z"`, como no SVG: maiúscula é absoluta, minúscula relativa; `Z` fecha e pinta |

Toda forma aceita também `fill`, `stroke`, `width` (a espessura do traço, 3 se não disser) e `opacity` (de 0 a
1). Uma cor é `#RRGGBB`, `#RRGGBBAA`, uma das cinco do mascote (`ink`, `body-top`, `body-bottom`, `tufts`,
`accent`: seguem a paleta), `white`, `black` ou `none`. Sem `fill` nem `stroke`, as formas fechadas são pintadas
com `ink` e as abertas riscadas com ela.

Os olhos e a boca andam com o rosto (seguem o mouse e dão um pulinho quando você digita); `front` e `back`
andam com o corpo.

### Um desenho por expressão

```kdl
eyes {
    // o padrão: vale para toda expressão que não tem bloco próprio
    circle cx=40 cy=50 r=5
    circle cx=84 cy=55 r=5
    when "happy" "laugh" {
        path d="M 32 54 Q 40 44 48 54" stroke="ink" width=4
        path d="M 76 58 Q 84 48 92 58" stroke="ink" width=4
    }
    when "sleep" {
        line x1=33 y1=52 x2=47 y2=52
        line x1=77 y1=56 x2=91 y2=56
    }
}
```

As expressões: `normal`, `happy`, `laugh`, `startled`, `angry`, `sad`, `sleep`, `dizzy`, `worried`, e mais
`error` (o login deu errado) e `eat` (a boca abre: comendo, bocejando). Um `when` pode listar várias.

O que acontece quando falta um bloco:

- a piscada aperta cada olho no lugar, então qualquer desenho pisca;
- `sleep` sem bloco próprio fecha os olhos do padrão do mesmo jeito;
- `error` e `dizzy` sem bloco usam os olhos de `x` e as espirais de sempre;
- `eat` sem bloco usa a boca redonda aberta de sempre;
- o "…" de conectando fica sempre no lugar da boca.

### Limites

Um arquivo tem no máximo 64 KB, 256 formas e 4096 pontos (256 por forma; uma curva vira uns 10 pontos). Os
números ficam entre −400 e 400 e o traço abaixo de 40.

## Um exemplo completo

```kdl
mascot "Estrelinha" author="você" license="CC0-1.0" description="Olhos que piscam e riem."

look hat="sprout" accessories="blush"
colors palette="algodao-doce"

eyes {
    circle cx=40 cy=50 r=7 fill="white" stroke="ink" width=1.6
    circle cx=41 cy=51 r=3.6
    circle cx=84 cy=55 r=7 fill="white" stroke="ink" width=1.6
    circle cx=85 cy=56 r=3.6
    when "happy" "laugh" {
        path d="M 32 53 Q 40 43 48 53" stroke="ink" width=4
        path d="M 76 58 Q 84 48 92 58" stroke="ink" width=4
    }
}

mouth {
    path d="M 55 69 Q 59.5 74 63.5 69.5 Q 67.5 74 72 69" stroke="ink" width=2.6
    when "laugh" "startled" { ellipse cx=63.5 cy=72 rx=6 ry=6.5 fill="ink" }
}

layer "front" {
    path d="M 98 22 L 101 28 L 108 29 L 103 33 L 104 40 L 98 36 L 92 40 L 93 33 L 88 29 L 95 28 Z" fill="#FFD84A" stroke="ink" width=1
}
```

Mais exemplos, cada um mostrando uma parte do formato, estão em [`community/`](community/).

## Compartilhar seu mascote

Os mascotes que as pessoas mandam aparecem na
[galeria de mascotes da comunidade](https://rshacudevidro.github.io/larperCord/pt/community-mascots.html), com
uma imagem e o arquivo para baixar.

1. Faça o mascote e confira no app: nenhum erro no cartão dele em Configurações → Mascote → Arquivos de
   mascote, e toda expressão bonita na prévia grande (os botões embaixo dela trocam a cara, o fone e a fita).
2. Preencha o nó `mascot`: um nome, `author=`, `license=` (uma licença aberta escrita pelo identificador SPDX,
   como `CC0-1.0`, `CC-BY-4.0` ou `MIT`) e `description=`.
3. Faça um fork do [repositório](https://github.com/RshaCuDeVidro/larperCord), ponha o arquivo em
   `mascots/community/` e abra um pull request. Um mascote por pull request. Uma captura de tela dele no pull
   request ajuda.

Regras: um nome só dele, um desenho original (nada de redesenhar personagem ou logo de outra pessoa), e só
arquivos `.kdl` na pasta.
