# Traduzindo o larperCord

Português e inglês ficam no código. Qualquer outro idioma é um arquivo `.kdl`: o texto em inglês do app à esquerda, a tradução à direita. Para traduzir não precisa de Zig, de compilador nem do repositório: um arquivo na pasta de traduções do app vale com o app aberto, e salvar atualiza o texto na hora. Pôr um idioma no app é pôr esse arquivo em `i18n/`, sem mudar código.

O [estado das traduções](page:translation-status) mostra até onde cada idioma chegou.

## O jeito rápido: o editor

O [editor de traduções](translate:new) roda no navegador, sem mandar nada para lugar nenhum:

1. Em **Começar de**, escolha **Um idioma novo** (ou um idioma que já existe, para continuar), e preencha o nome e o código dele.
2. Traduza. Cada texto em inglês vem com onde ele está no código e o que ele é (um botão, uma dica, uma configuração, um erro…). Os que faltam vêm primeiro, os marcadores são conferidos enquanto você escreve, e um texto com contagem pede cada forma de plural do seu idioma.
3. Aperte **Baixar .kdl**. O trabalho também fica no navegador, então dá para fechar a página e voltar depois.

Dá para abrir um `.kdl` que você já tem (ou soltar na página) e continuar dele.

## O arquivo

```kdl
language "Deutsch" code="de" english="German"

"Sign in" "Anmelden"
"Replying to {s}" "Antwort an {s}"
"{d} votes" one="{d} Stimme" other="{d} Stimmen"
```

O arquivo começa dizendo que idioma ele é:

| Linha | O que faz |
|---|---|
| `language "Deutsch" code="de" english="German"` | O nome na própria língua (é o que Configurações → Idioma mostra), o código e o nome em inglês. O código é o da ISO 639, com a região quando ela importa: `de`, `pt-PT`, `zh-TW`. O app escolhe o arquivo em vez do inglês quando o idioma do sistema tem o mesmo código |
| `direction "rtl"` | Opcional. O idioma é escrito da direita para a esquerda (árabe, hebraico, persa). O app já molda e ordena sozinho cada texto da direita para a esquerda; isto também marca as conversas exportadas como da direita para a esquerda |
| `font-script "ja"` | Opcional. Quais fontes reserva vêm primeiro quando o sistema tem várias: `ja`, `ko` ou `zh`. Por padrão, o código |
| `plurals "ru"` | Opcional. Usa as regras de plural de outro idioma (para um código que o app ainda não conhece) |

Depois, uma entrada por linha: o texto em inglês exatamente como está no app, e a tradução. Dentro das aspas, `\n` é uma quebra de linha, `\"` uma aspa e `\\` uma barra invertida; uma entrada longa continua na linha de baixo depois de um `\` no fim. Linhas que começam com `//` são comentários.

Um texto que não está no arquivo, ou com a tradução vazia (`"Sign in" ""`), aparece em inglês, nunca em português, então uma tradução pela metade já serve para usar e para mandar.

## Marcadores

Alguns textos têm valores que o app preenche: `{s}` é um texto, `{d}` um número, e alguns têm formatação, como `{d:0>2}`. Eles só importam nos textos que têm:

- copie como estão no texto em inglês, e eles são preenchidos na mesma ordem: `"Replying to {s}" "Antwort an {s}"`;
- para mudar a ordem, escreva `{0}`, `{1}`… no lugar: `{N}` é o N-ésimo marcador do texto em inglês, contando do 0, com a formatação dele. `"{1s} {0d}, {2d}"` (November 9, 2026) vira `"{0}. {1} {2}"`. Não misture os dois jeitos num texto;
- todo valor do texto em inglês precisa aparecer;
- `{{` e `}}` são as chaves de verdade.

Uma tradução que não segue essas regras aparece em inglês. O editor e o `tools/i18n_strings.py --check` apontam quais.

## Contagens

Um texto com contagem, como `{d} votes`, tem uma forma por categoria de plural do idioma, pelas [regras de plural do CLDR](https://cldr.unicode.org/index/cldr-spec/plural-rules). A chave é o plural em inglês, e cada forma vai como propriedade:

```kdl
"{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"
```

| Idioma | Formas | Que números |
|---|---|---|
| Japonês, chinês, coreano, vietnamita… | um texto para qualquer número | |
| Inglês, alemão, holandês, sueco… | `one`, `other` | 1 · 0, 2, 5, 21 |
| Francês | `one`, `many`, `other` | 0, 1 · 1000000 · 2, 5 |
| Espanhol, italiano, catalão, português europeu | `one`, `many`, `other` | 1 · 1000000 · 0, 2, 5 |
| Russo, ucraniano, bielorrusso | `one`, `few`, `many` | 1, 21, 31 · 2–4, 22 · 0, 5–20 |
| Polonês | `one`, `few`, `many` | 1 · 2–4, 22 · 0, 5, 12, 21 |
| Árabe | `zero`, `one`, `two`, `few`, `many`, `other` | 0 · 1 · 2 · 3–10 · 11–99 · 100 |

O modelo e o editor listam as formas do seu idioma com os números que usam cada uma. Um texto solto ao lado das formas (`"{d} votes" "{d} Stimmen" one="{d} Stimme"`) vale para a forma que você deixar de fora, e um idioma com uma forma só precisa só desse texto. Cada forma segue as regras dos marcadores acima.

## Testar no app

Coloque o arquivo na pasta de traduções:

| Sistema | Pasta |
|---|---|
| Linux | `~/.config/larpercord/i18n/` (ou `$XDG_CONFIG_HOME/larpercord/i18n/`) |
| Windows | `%APPDATA%\larpercord\i18n\` |

Configurações → Idioma → **Abrir a pasta de traduções** abre (e cria) a pasta. Cada arquivo dela:

- com um código novo, é um idioma novo em Configurações → Idioma;
- com o código de um idioma que vem com o app (`ja.kdl`, `ru.kdl`), vale por cima dele: só o que está no arquivo muda, então um arquivo de três linhas corrige três textos.

A lista mostra quanto do app cada idioma traduz. Salvar o arquivo atualiza o texto na hora, com um aviso; uma linha quebrada aparece em vermelho na página Idioma, com o arquivo e a linha, e o idioma fica com o texto que tinha.

## Na linha de comando

No repositório, com Python 3 (só a biblioteca padrão):

```bash
# O modelo de um idioma novo: cada texto em inglês com a tradução vazia, uma linha //: com
# onde ele está e o que ele é, e as formas de plural do idioma
python3 tools/i18n_strings.py --template de --name Deutsch --english German -o de.kdl

# Depois que o app muda: os textos novos entram vazios, os que ele não usa mais ganham /- na
# frente (o app ignora; nada que você traduziu se perde), e as linhas //: são refeitas
python3 tools/i18n_strings.py --update de.kdl

# Confere todos os arquivos de i18n/ (ou um, com --lang de, ou um em qualquer lugar, com
# --file de.kdl): arquivo quebrado, marcador errado e entrada repetida são erros; tradução
# que falta só é contada
python3 tools/i18n_strings.py --check --file de.kdl
```

## Mandar

Coloque o arquivo no repositório como `i18n/<código>.kdl` num pull request. Nada mais muda: o build junta cada arquivo daquela pasta no app, comprimido, e o idioma aparece em Configurações → Idioma e na [página de estado](page:translation-status). O CI roda a checagem em cada pull request: arquivo quebrado ou marcador errado falham, tradução que falta não.

## O que ainda não está no arquivo

- Datas: português, inglês, japonês e russo escrevem do jeito deles ("9 de novembro de 2026", "2026年11月9日"); os outros idiomas escrevem como o inglês. O tempo relativo ("há 3 dias") e todo o resto estão no arquivo.
- Plugins têm os textos deles, em cada plugin.

## Para quem mexe no código

Texto novo na interface passa por `i18n.tr` (ou `fmt`, `allocPrint`, e `plural` para contagens) com o português e o inglês lado a lado, como no resto do código. Depois:

- ponha o inglês nos `i18n/*.kdl` (traduzido, se você fala o idioma; senão o próprio texto em inglês como espaço reservado, que a [página de estado](page:translation-status) conta como "igual ao inglês");
- `python3 tools/i18n_strings.py --keys` atualiza o `i18n/keys.txt`, a lista que o app usa para dizer quanto cada idioma traduz;
- `python3 tools/i18n_strings.py --check` antes do pull request.
