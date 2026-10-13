# GEO FIGHTER: desenho técnico

Estado em 13/10/2026: demo de teste com dois personagens. Este documento registra como o 3D foi organizado, o que foi medido e o que falta para o jogo completo (6 personagens, 8 cenários).

## 1. Ideia central

Num jogo de luta a câmera quase não gira. O demo tira proveito disso: **a câmera nunca gira**, só desliza para os lados. Com isso, tudo o que seria conta 3D no Z80 é calculado no PC e guardado pronto na ROM, e o Z80 só soma a posição X de cada lutador.

## 2. Regras de otimização aplicadas

As regras vêm do `engine.md` do VECTOR RAID e do README do geo3d.

| Regra medida | Como o Geo Fighter aplica |
|---|---|
| Enviar uma face custa 61 µs de Z80; no máximo 96 por quadro | Nenhuma face é enviada durante a luta: todas ficam residentes no geo3d |
| Cada RUN custa cerca de 0,2 ms e reprocessa os vértices de 0 a NVERT-1 | Uma passada só de transformação por parte do corpo, da faixa mais alta para a mais baixa |
| Um RUN com NFACE = 0 só transforma; um com NVERT = 0 só desenha | A última passada desenha tudo, com uma única ordenação de profundidade para os dois lutadores |
| Face com vértice atrás do plano próximo é descartada | Uma passada com TZ = -2048 esconde o ringue antes da passada final |
| Cada comando do VDP emitido pelo Z80 custa 0,2 ms: poucos e grandes | Fundo em 4 preenchimentos; barra de status desenhada uma vez por round; mensagens copiadas por um só LMMM |
| O que não muda a cada quadro não entra no quadro | Matrizes, translações e normais pré-calculadas; texto das mensagens desenhado no boot em linhas ocultas |
| Nada escreve nos registradores de comando enquanto o geo3d roda | A ordem do quadro garante: preenchimentos, depois geo3d, depois a mensagem |

## 3. Um quadro

Tela: SCREEN 8 com paleta estendida (256 cores de 15 bits), duas páginas, 30 quadros por segundo. As linhas 0 a 19 são a barra de status; a vista 3D ocupa as linhas 20 a 211.

| Etapa | O que faz | Tempo médio (openMSX) |
|---|---|---|
| `frame_begin` | céu em 3 faixas e chão: 4 HMMV | 2,05 ms |
| `logic` | um passo do round: teclas, máquina, animação, golpes | 0,76 ms |
| `hud_bars` | barras de vida, só quando mudam | 0,04 ms |
| `scene_draw` | ringue e as 22 passadas de transformação | 1,12 ms |
| `geo_wait` | espera a passada final pintar os lutadores | 9,31 ms |
| `msg_draw` | mensagem sobre a imagem, quando há | 0,01 ms |
| **Total** | | **13,3 ms (máximo 14,0)** de 33,4 ms |

Esses tempos são do openMSX, onde a transformação do geo3d é instantânea. No hardware cada vértice transformado custa até 1,14 µs e cada linha de face cerca de 3,2 µs, então o quadro será mais longo. Não foi medido no cartucho.

## 4. A cena residente

Tudo é carregado uma vez no `geo_init`:

- **Vértices (231):** as 11 partes do lutador 0, as 11 do lutador 1 e por último o ringue.
- **Faces (169):** primeiro as 13 do ringue, depois as 78 de cada lutador.

Sequência de passadas (RUN) por quadro:

1. **Ringue:** NVERT = todos, NFACE = 13, matriz da câmera.
2. **Esconder:** NFACE = 0 e TZ atrás do plano próximo. Todos os vértices ficam escondidos, inclusive os do ringue.
3. **Partes do corpo (22):** NFACE = 0, cada uma com sua matriz e translação vindas da tabela de poses.
4. **Final:** NVERT = 0, NFACE = todas. Ordena as faces dos dois lutadores juntas e pinta. As do ringue são puladas porque seus vértices ficaram escondidos no passo 2.

A iluminação é feita na passada final com a matriz identidade, então as normais ficam guardadas já no espaço da câmera, para a pose de guarda. Consequência: o tom de cada face não muda quando o membro gira.

## 5. Modelos e poses

- **Corpo:** 11 partes rígidas (quadril, tronco, cabeça, 2 braços, 2 antebraços, 2 coxas, 2 canelas com pé), cada uma um ou dois prismas. Por lutador: 104 vértices e 78 faces.
- **Personagens:** mesma estrutura, com medidas e cores próprias. RAI é esguio, de kimono branco. DAGO é mais largo, sem camisa, de calção azul.
- **Pose:** ângulos de cada junta. O `gen_fighter.py` resolve a cinemática e grava, para cada pose, direção e parte, o registro pronto para o geo3d: 9 palavras de matriz e 3 de translação, 24 bytes.
- **Tamanho:** 264 bytes por pose. Um banco de 16 KB guarda as poses de um personagem numa direção.
- **Animações (10):** guarda, passo à frente, passo atrás, soco, chute, defesa, defesa atingida, golpe recebido, queda e vitória. São 62 poses.
- **Cores:** rampas de 7 tons na paleta de 256. O geo3d soma o nível de luz à cor base da face.

O limite atual: 62 poses enchem exatamente um banco. Mais golpes exigem dividir as poses em dois bancos por direção.

## 6. Jogabilidade do demo

| Golpe | Acerta no passo | Alcance | Dano |
|---|---|---|---|
| Soco | 3 | 86 | 9 |
| Chute | 4 | 102 | 14 |

- A vida vai de 0 a 100. A defesa anula o dano e reduz o empurrão.
- Os lutadores ficam dentro do ringue e nunca a menos de 72 unidades um do outro.
- A máquina se aproxima, escolhe entre soco, chute, recuo e defesa, e defende na maior parte das vezes quando o adversário ataca ao alcance.

## 7. Limitações conhecidas

- A câmera não gira nem aproxima.
- Os lutadores não trocam de lado, não pulam e não agarram.
- O sombreamento não acompanha a rotação dos membros.
- A ordenação de profundidade é por face, então membros que se atravessam podem aparecer na ordem errada.
- Um só cenário, sem música, sem contagem de rounds nem relógio.
- Não testado no cartucho real nem no Raspberry Pi.

## 8. Plano para o jogo completo

| Parte | Como fazer dentro das mesmas regras |
|---|---|
| 6 personagens | Mesma estrutura de 11 partes; cada um com medidas, cores e golpes próprios. Seleção de personagem carrega vértices e faces dos dois escolhidos |
| 8 cenários | O chão do ringue continua 3D ao vivo. O fundo é desenhado uma vez pelo geo3d em páginas ocultas e copiado a cada quadro por HMMM, com deslocamento lateral |
| Mais golpes | Dois bancos de poses por personagem e direção; golpes altos, baixos e agarrões como animações novas |
| Aproximação da câmera | Mudar a distância focal (registrador F) e o centro vertical por quadro, sem custo de Z80 |
| Troca de lado | Reenviar as faces dos dois lutadores com as normais da outra direção: 156 faces, cerca de 10 ms, uma vez |
| 2 jogadores | Ler o joystick 2; o lutador 1 já aceita ficar sem a máquina |
| Som | Efeitos no PSG já existem; música pelo tocador de fluxos do VECTOR RAID |
| Tamanho da ROM | Cerca de 6 bancos por personagem com o dobro de golpes: 36 bancos mais cenários, dentro de 1 MB |

## 9. Decisões em aberto

1. Nomes e estilos dos 4 personagens que faltam.
2. Temas dos 8 cenários.
3. Se o repositório será público ou privado, e a licença. Os fontes levam o cabeçalho MIT por seguirem o padrão do geo3d.
4. Se o alvo de velocidade é o cartucho real a 3,58 MHz ou também a turboR.
