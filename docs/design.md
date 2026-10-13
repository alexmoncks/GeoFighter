# GEO FIGHTER: desenho técnico

Estado em 13/10/2026: demo de teste com dois personagens, câmera em diagonal vista de cima e abertura com giro de 360° em volta do ringue. Este documento registra como o 3D foi organizado, o que foi medido e o que falta para o jogo completo (6 personagens, 8 cenários).

## 1. Ideia central

Num jogo de luta a câmera quase não gira. O demo tira proveito disso de duas formas:

- **Na luta, a câmera nunca gira.** Ela fica em diagonal e do alto (28° de lado, 24° de inclinação) e só desliza ao longo do ringue. Cada pose é calculada no PC e gravada pronta na ROM; o Z80 só multiplica a posição de cada lutador por um vetor constante (9 multiplicações por quadro).
- **Na abertura, só a câmera se move.** Os lutadores ficam parados na guarda, então são gravados uma segunda vez com os vértices já na posição do mundo, e cada quadro do giro é um único registro de câmera para a cena inteira.

## 2. Regras de otimização aplicadas

As regras vêm do `engine.md` do VECTOR RAID e do README do geo3d.

| Regra medida | Como o Geo Fighter aplica |
|---|---|
| Enviar uma face custa 61 µs de Z80; no máximo 96 por quadro | Nenhuma face é enviada durante o jogo: todas ficam residentes no geo3d |
| Cada RUN custa cerca de 0,2 ms e reprocessa os vértices de 0 a NVERT-1 | Uma passada só de transformação por parte do corpo |
| Um RUN com NFACE = 0 só transforma; um com NVERT = 0 só desenha | A última passada desenha tudo, com uma única ordenação de profundidade para os dois lutadores |
| Face com vértice atrás do plano próximo é descartada | Uma passada com TZ = -2048 esconde o ringue antes da passada final |
| Cada comando do VDP emitido pelo Z80 custa 0,2 ms: poucos e grandes | Fundo em 1 preenchimento; barra de status desenhada uma vez por round; mensagens copiadas por um só LMMM |
| O que não muda a cada quadro não entra no quadro | Matrizes, translações, normais e o caminho da câmera pré-calculados; texto das mensagens desenhado no boot em linhas ocultas |
| Nada escreve nos registradores de comando enquanto o geo3d roda | A ordem do quadro garante: preenchimento, depois geo3d, depois a mensagem |

## 3. Um quadro

Tela: SCREEN 8 com paleta estendida (256 cores de 15 bits), duas páginas, 30 quadros por segundo. As linhas 0 a 19 são a barra de status; a vista 3D ocupa as linhas 20 a 211.

| Etapa | O que faz | Luta | Giro de abertura |
|---|---|---|---|
| `frame_begin` | piso em volta do ringue: 1 HMMV | 0,29 ms | 0,29 ms |
| `logic` | um passo do round; na luta, inclui as 9 multiplicações da câmera | 2,57 ms | 0,05 ms |
| `hud_bars` | barras de vida, só quando mudam | 0,06 ms | 0,01 ms |
| `scene_draw` | ringue e passadas de transformação | 0,69 ms | 3,24 ms |
| `geo_wait` | espera a passada final pintar os lutadores | 11,53 ms | 3,72 ms |
| `msg_draw` | mensagem sobre a imagem, quando há | 0,01 ms | 0,01 ms |
| **Total** | de 33,4 ms disponíveis | **15,2 ms (máximo 16,8)** | **7,3 ms (máximo 8,7)** |

Esses tempos são do openMSX, onde a transformação do geo3d é instantânea. No hardware cada vértice transformado custa até 1,14 µs e cada linha de face cerca de 3,2 µs, então o quadro será mais longo. Não foi medido no cartucho.

## 4. A cena residente

Tudo cabe no limite do geo3d: **253 de 255 vértices e 200 de 255 faces**.

- **Vértices:** as 11 partes do lutador 0 (120), as 11 do lutador 1 (120) e por último o ringue (13).
- **Faces:** primeiro as 8 do ringue, depois as 96 de cada lutador.

As faces são carregadas uma vez, no boot. Os vértices têm dois conjuntos, trocados uma vez por round:

| Conjunto | Conteúdo | Usado em |
|---|---|---|
| Abertura | cada vértice já no mundo, com os lutadores na guarda em suas marcas | giro de 360° |
| Luta | cada vértice no sistema da sua parte do corpo | todo o resto |

Passadas por quadro na luta:

1. **Ringue:** NVERT = todos, NFACE = 8, matriz da câmera.
2. **Esconder:** NFACE = 0 e TZ atrás do plano próximo. Todos os vértices ficam escondidos, inclusive os do ringue.
3. **Partes do corpo (22):** NFACE = 0, cada uma com sua matriz e translação vindas da tabela de poses, mais o vetor de posição do lutador.
4. **Final:** NVERT = 0, NFACE = todas. Ordena as faces dos dois lutadores juntas e pinta. As do ringue são puladas porque seus vértices ficaram escondidos no passo 2.

Passadas por quadro no giro: o ringue, a passada que esconde, e uma só passada que transforma os 240 vértices dos lutadores e pinta todas as faces deles, as três com o mesmo registro de câmera.

**Luz.** As normais ficam guardadas no espaço da câmera de luta. Antes de cada passada o registrador de luz recebe o valor que combina com a matriz daquela passada, de modo que cada face mantém o mesmo tom na luta e durante todo o giro. Consequência: o tom não muda quando o membro gira.

## 5. Modelos e poses

- **Corpo:** 11 partes rígidas. Cada parte é uma pilha de anéis retangulares que compartilham vértices, o que dá mais faces por vértice que caixas soltas.

| Parte | Anéis | Vértices | Faces |
|---|---|---|---|
| Quadril | 2 | 8 | 6 |
| Tronco (cintura, costelas, peito, ombros) | 4 | 16 | 14 |
| Cabeça (queixo, maçãs, topo) | 3 | 12 | 10 |
| Braço, cada | 2 | 8 | 6 |
| Antebraço com punho, cada | 3 | 12 | 10 |
| Coxa, cada | 2 | 8 | 6 |
| Canela com pé em cunha, cada | 2 + cunha | 14 | 11 |
| **Lutador** | | **120** | **96** |

- **Personagens:** mesma estrutura, com medidas e cores próprias. RAI é esguio, de kimono branco com faixa preta. DAGO é mais largo, de barba, luvas vermelhas e calção azul.
- **Pose:** ângulos de cada junta. O `gen_fighter.py` resolve a cinemática e grava, para cada pose, direção e parte, o registro pronto para o geo3d: 9 palavras de matriz e 3 de translação, 24 bytes.
- **Tamanho:** 264 bytes por pose. Um banco de 16 KB guarda as poses de um personagem numa direção.
- **Animações (10):** guarda, passo à frente, passo atrás, soco, chute, defesa, defesa atingida, golpe recebido, queda e vitória. São 62 poses.
- **Giro de abertura:** 120 quadros de 30 bytes (registro de câmera e luz). A câmera dá uma volta completa, desce de 38° para 24° e aproxima de 1150 para 560 unidades. O último quadro é exatamente a câmera de luta.
- **Cores:** rampas de 7 tons na paleta de 256. O geo3d soma o nível de luz à cor base da face.

Limites atuais: 62 poses enchem exatamente um banco, e os vértices estão a 2 do teto do geo3d.

## 6. Jogabilidade do demo

| Golpe | Acerta no passo | Alcance | Dano |
|---|---|---|---|
| Soco | 3 | 86 | 9 |
| Chute | 4 | 102 | 14 |

- A vida vai de 0 a 100. A defesa anula o dano e reduz o empurrão.
- Os lutadores ficam dentro do ringue e nunca a menos de 72 unidades um do outro.
- A máquina se aproxima, escolhe entre soco, chute, recuo e defesa, e defende na maior parte das vezes quando o adversário ataca ao alcance.
- Um novo toque no botão de soco corta o giro de abertura.

## 7. Limitações conhecidas

- Mais polígonos nos lutadores exigem mudar a técnica: o geo3d guarda no máximo 255 vértices e 255 faces de uma vez, e a cena já usa 253 e 200.
- Na luta a câmera desliza, mas não gira nem aproxima.
- Os lutadores não trocam de lado, não pulam e não agarram.
- O sombreamento não acompanha a rotação dos membros.
- A ordenação de profundidade é por face, então membros que se atravessam podem aparecer na ordem errada.
- Um só cenário, sem música, sem contagem de rounds nem relógio.
- Não testado no cartucho real nem no Raspberry Pi.

## 8. Plano para o jogo completo

| Parte | Como fazer dentro das mesmas regras |
|---|---|
| 6 personagens | Mesma estrutura de 11 partes; cada um com medidas, cores e golpes próprios. A seleção de personagem carrega vértices e faces dos dois escolhidos |
| 8 cenários | O ringue continua 3D ao vivo, com ladrilhos e saia de cores próprias. Elementos de fundo desenhados uma vez pelo geo3d em páginas ocultas e copiados por HMMM |
| Mais golpes | Dois bancos de poses por personagem e direção; golpes altos, baixos e agarrões como animações novas |
| Mais polígonos | Desenhar o ringue numa etapa própria, com os vértices trocados a cada quadro (cerca de 1,7 ms de Z80), libera 13 vértices; além disso, só reenviando vértices e faces por quadro, o que custa a taxa de quadros |
| Câmeras de replay e de vitória | Mesma técnica do giro: um conjunto de vértices no mundo e uma tabela de registros de câmera |
| Troca de lado | Reenviar as faces dos dois lutadores com as normais da outra direção: 192 faces, cerca de 12 ms, uma vez |
| 2 jogadores | Ler o joystick 2; o lutador 1 já aceita ficar sem a máquina |
| Som | Efeitos no PSG já existem; música pelo tocador de fluxos do VECTOR RAID |
| Tamanho da ROM | Cerca de 6 bancos por personagem com o dobro de golpes: 36 bancos mais cenários, dentro de 1 MB |

## 9. Decisões em aberto

1. Nomes e estilos dos 4 personagens que faltam.
2. Temas dos 8 cenários.
3. Se o repositório será público ou privado, e a licença. Os fontes levam o cabeçalho MIT por seguirem o padrão do geo3d.
4. Se o alvo de velocidade é o cartucho real a 3,58 MHz ou também a turboR.
