# Desempenho

## Os números

| | RAM (PSS) | CPU parado | Binário |
|---|---|---|---|
| Vesktop (Electron) | 1.279 MB | 12–47% ¹ | 287 MB |
| Discord Phoenix (Rust) ² | ~290 MB | 0,1% | não lançado |
| **larperCord**, conta real ³ | **~130 MB** | **0–0,4%** ⁴ | **~14 MB** |

¹ Média desde a abertura, medida com `ps`. Arch Linux, Hyprland, GTX 1050 Ti, janela de 1280×800, build `ReleaseFast`.

² Não medido por nós e não é um teste lado a lado. É uma versão inicial para Windows 11, de um print do Gerenciador de Tarefas [postado pelo CTO do Discord](https://x.com/svishnevskiy/status/2118081920194203799) ([matéria](https://www.windowslatest.com/2026/11/05/discord-is-killing-its-electron-app-that-can-eat-4gb-of-ram-on-windows-11-and-the-rust-rebuild-uses-just-290mb/)). O app ainda não saiu, e esse print diz pouco sobre o uso normal.

³ 125–140 MB no uso normal de uma conta, no mesmo PC, com um i5-2400S, e cerca de 70 MB logo depois de abrir. O seu depende dos seus servidores, membros e imagens. Configurações → Desempenho mostra para onde vai.

⁴ Medido nos 11 temas, com dados de demonstração, GPU de verdade, janela de verdade num workspace escondido do Hyprland e reprodução automática de GIFs desligada. Uma janela à vista pode medir diferente.

Leia esses números com as ressalvas certas:

- **Uma conta real usa mais** do que os dados de demonstração. Mais servidores, mais membros, mais imagens.
- **Parado quer dizer que nada está se mexendo.** Um GIF animado na tela custa cerca de 2,5% de CPU. O primeiro canal da demonstração tem um, então a medição desliga a reprodução automática.
- **Boa parte do PSS não é do app.** É o driver da NVIDIA e bibliotecas do sistema como libcurl e OpenSSL. Numa medição entre os temas, a memória anônima ficou em cerca de 25 MB.
- **O arquivo publicado para Linux traz SDL3, libcurl e OpenSSL dentro**, para rodar em mais distros, compilados só com as partes que o app usa. Compilado com as cópias do sistema, ele tem cerca de 8 MB. Estes números de RAM vêm desse tipo de build; lado a lado na demonstração, o arquivo publicado usou cerca de 2 MB a mais.
- **O mascote só se mexe com a janela em foco.** A vida própria dele custa uns 0,5% de um núcleo enquanto ele está acordado, e nada depois que ele dorme, passados uns minutos parado. A janela medida aqui estava sem foco, então estes números não incluem ele. Veja [O mascote](page:mascot#quanto-custa).
- Os números do Vesktop vêm de uma única execução anterior na mesma máquina.

## Meça você mesmo

```bash
tools/membench.sh 60
```

Para cada tema, ele abre o app em modo demonstração com configurações limpas e a reprodução automática de GIFs desligada, espera, mede a CPU parada durante 5 segundos, lê o PSS em `/proc/<pid>/smaps_rollup` e falha se algum tema passar do orçamento em MB. Por causa dessa variação, o `terminal` às vezes falha com 60.

O `tools/membench.sh` é um script de Linux, porque lê o `/proc`. No Windows, use Configurações → Desempenho: lá o número da RAM é a memória privada do processo (a coluna "Tamanho da confirmação", ou "Commit size", do Gerenciador de Tarefas), e não o PSS, então não dá para comparar direto com os números acima.

A página Desempenho nas configurações mostra números ao vivo, inclusive para onde vai a memória na sua conta, e o `--stats` imprime a linha do tempo da abertura e o custo de cada quadro. Se um backend de renderização se der mal com o driver da sua placa de vídeo, a mesma página escolhe outro em **Renderizador**.

## Dez decisões

1. **Dorme quando nada acontece.** O laço espera em `SDL_WaitEvent`. Rede, mudanças nos arquivos (inotify no Linux, avisos de pasta no Windows) e o relógio acordam o app por eventos. Sem animação, sem redesenho. Quadro que sai igual ao anterior nem chega à GPU, e o mouse só andando pede menos quadros.
2. **Nada de navegador.** Tudo é desenhado com o `ImDrawList` do Dear ImGui sobre o SDL_Renderer.
3. **Fontes mapeadas, não copiadas.** Cada arquivo de fonte vira um mapa de memória (`mmap` no Linux, `MapViewOfFile` no Windows) usado por todos os pesos e famílias, então só as páginas lidas ficam na RAM. Carregar 4 pesos do Inter mais emoji do jeito ingênuo custava cerca de 90 MB.
4. **Só o driver de vídeo necessário.** Em máquinas Linux só com GPU NVIDIA, o glvnd também carregava o Mesa e o LLVM (cerca de 23 MB) à toa. O app detecta isso e evita.
5. **Markdown interpretado uma vez**, quando a mensagem chega. A interface só faz o layout dos trechos, com cache de altura por largura.
6. **Lista virtualizada.** Busca binária pelo primeiro item visível, depois desenha só a tela.
7. **Memória com teto.** 1.500 mensagens por canal e, por padrão, 2.000 no total, e depois disso a conversa vista há mais tempo é descarregada. As imagens ficam com 32 MB por padrão, e qualquer download isolado para em 32 MB. Configurações → Desempenho muda esses limites: de 500 a 5.000 mensagens, de 16 a 128 MB de imagens e de 4 a 32 MB para cada GIF. Depois de um minuto na bandeja ou minimizada, as imagens também saem da memória, menos as pequenas que estavam na tela.
8. **No Linux, a memória liberada volta ao sistema.** O fontconfig é liberado depois que as fontes são resolvidas (`FcFini` e `malloc_trim`), e os buffers grandes de imagem ganham um mapa de memória próprio, então liberar devolve a memória em vez de deixá-la nas arenas da glibc de cada thread. Antes da 0.6.5, depois de 4h30 na conta do desenvolvedor, uns 190 MB ficavam parados ali à toa. O Windows não tem fontconfig: as fontes são abertas direto de `C:\Windows\Fonts`.
9. **Sem cursor piscando.** Ele manteria a CPU acordada à toa.
10. **As coisas começam quando você pede.** A thread de voz na primeira call e o FFmpeg no primeiro vídeo. O vídeo fora da tela é liberado depois de 30 segundos, e sem plugin ligado não há thread de plugins, estado de Lua nem trabalho extra por mensagem, tecla ou quadro.

## O orçamento no CI

A suíte de testes cobre as partes puras, e um job separado compila o app inteiro e roda o QA completo fora da tela. Veja [Contribuindo](page:contributing).
