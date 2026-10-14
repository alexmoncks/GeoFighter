# GEO FIGHTER: desenho técnico

Estado em 14/10/2026: demo de teste com dois personagens, câmera em diagonal vista de cima, abertura com giro de 360° em volta do ringue, golpes especiais (pulo, voadora, agachamento, rasteira, passo lateral) e lutadores de 420 vértices, que exigem o geo3d v2.0. Este documento registra como o 3D foi organizado, o que foi medido e o que falta para o jogo completo (6 personagens, 8 cenários).

## 1. Ideia central

Num jogo de luta a câmera quase não gira. O demo tira proveito disso de duas formas:

- **Na luta, a câmera nunca gira.** Ela fica em diagonal e do alto (28° de lado, 24° de inclinação) e só desliza ao longo do ringue. Cada pose é calculada no PC e gravada pronta na ROM; o Z80 só multiplica a posição de cada lutador por um vetor constante (9 multiplicações por quadro).
- **Na abertura, só a câmera se move.** Os lutadores ficam parados na guarda, então são gravados uma segunda vez com os vértices já na posição do mundo, e cada quadro do giro é um único registro de câmera para a cena inteira.
- **No passo lateral, quem gira é o ringue.** Os dois lutadores continuam desenhados sobre a mesma linha, com as mesmas poses prontas; o eixo da luta gira porque o ringue é desenhado girado embaixo deles. Custa uma tabela de 128 matrizes do ringue (3 KB) e nenhuma conta a mais no Z80.

## 2. Regras de otimização aplicadas

As regras vêm do `engine.md` do VECTOR RAID e do README do geo3d.

| Regra medida | Como o Geo Fighter aplica |
|---|---|
| Enviar uma face custa 61 µs de Z80; no máximo 96 por quadro | Nenhuma face é enviada durante o jogo: todas ficam residentes no geo3d |
| Cada RUN custa cerca de 0,2 ms; no geo3d v2.0 ele transforma só a faixa VFIRST..VFIRST+NVERT-1 | Uma passada só de transformação por parte do corpo, cada uma só com os vértices da sua parte |
| Um RUN com NFACE = 0 só transforma; um com NVERT = 0 só desenha | A última passada desenha tudo, com uma única ordenação de profundidade para os dois lutadores |
| Cada RUN pinta só as faces FFIRST..FFIRST+NFACE-1 (geo3d v2.0) | O ringue e os lutadores têm faixas de faces próprias; a passada que escondia o ringue (TZ = -2048) deixou de existir |
| Cada comando do VDP emitido pelo Z80 custa 0,2 ms: poucos e grandes | Fundo em 1 preenchimento; barra de status desenhada uma vez por round; mensagens copiadas por um só LMMM |
| O que não muda a cada quadro não entra no quadro | Matrizes, translações, normais e o caminho da câmera pré-calculados; texto das mensagens desenhado no boot em linhas ocultas |
| Nada escreve nos registradores de comando enquanto o geo3d roda | A ordem do quadro garante: preenchimento, depois geo3d, depois a mensagem |

## 3. Um quadro

Tela: SCREEN 8 com paleta estendida (256 cores de 15 bits), duas páginas, 30 quadros por segundo. As linhas 0 a 19 são a barra de status; a vista 3D ocupa as linhas 20 a 211.

| Etapa | O que faz | Luta | Giro de abertura |
|---|---|---|---|
| `frame_begin` | piso em volta do ringue: 1 HMMV | 0,29 ms | 0,29 ms |
| `logic` | um passo do round; na luta, inclui as 9 multiplicações da câmera | 2,59 ms | 0,05 ms |
| `hud_bars` | barras de vida, só quando mudam | 0,05 ms | 0,01 ms |
| `scene_draw` | ringue e passadas de transformação | 0,80 ms | 3,30 ms |
| `geo_wait` | espera a passada final pintar os lutadores | 14,22 ms | 4,46 ms |
| `msg_draw` | mensagem sobre a imagem, quando há | 0,01 ms | 0,01 ms |
| **Total** | de 33,4 ms disponíveis | **18,0 ms (máximo 19,7)** | **8,1 ms (máximo 10,0)** |

Esses tempos são do openMSX (ramo `geo3d-v2.0` do fork), onde a transformação do geo3d é instantânea; com os lutadores de 120 vértices eram 15,4 e 7,3 ms. No RTL do geo3d v2.0 simulado, com o V9968 em modo rápido, o quadro da luta leva 6,9 ms dentro do geo3d (transformar, ordenar, montar e mandar os comandos, e o V9968 desenhando); com os lutadores antigos eram 4,1 ms. Não foi medido no cartucho.

## 4. A cena residente

A cena usa **869 de 1.023 vértices e 792 de 1.023 faces** do geo3d v2.0 (o v1.0.0 guardava 255 de cada). No boot o cartucho confere o geo3d: índice 49h = 20h (versão 2.0) e XCTRL com memórias de 1.024 posições; com um geo3d mais antigo mostra "GEO3D V2.0 NECESSARIO" e para. Ele liga o modo estendido (ponteiros de 10 bits, faces de 12 bytes).

- **Vértices:** as 11 partes do lutador 0 (420), as 11 do lutador 1 (420) e por último o ringue (29).
- **Faces:** primeiro as 20 do ringue, depois as 386 de cada lutador.

As faces são carregadas uma vez, no boot. Os vértices têm dois conjuntos, trocados uma vez por round:

| Conjunto | Conteúdo | Usado em |
|---|---|---|
| Abertura | cada vértice já no mundo, com os lutadores na guarda em suas marcas | giro de 360° |
| Luta | cada vértice no sistema da sua parte do corpo | todo o resto |

Passadas por quadro na luta:

1. **Ringue:** VFIRST/NVERT = os 29 vértices dele, FFIRST/NFACE = as 20 faces dele, matriz da câmera multiplicada pelo giro do eixo da luta. São 128 posições de eixo, cada uma com a matriz e a luz prontas (24 bytes); a translação é a mesma em todas, porque o ringue gira em torno do próprio centro.
2. **Partes do corpo (22):** NFACE = 0; VFIRST/NVERT = os vértices da parte (de 24 a 56); a matriz e a translação vêm da tabela de poses, mais o vetor de posição do lutador.
3. **Final:** NVERT = 0, FFIRST/NFACE = as 772 faces dos lutadores. Ordena as faces dos dois juntas e pinta.

Passadas por quadro no giro: uma para o ringue e uma que transforma os 840 vértices dos lutadores e pinta todas as faces deles, as duas com o mesmo registro de câmera. Os vértices são enviados duas vezes por round (o conjunto da abertura e o da luta, 5,2 KB cada), em blocos de 256 bytes por OTIR.

**Luz.** As normais ficam guardadas no espaço da câmera de luta. Antes de cada passada o registrador de luz recebe o valor que combina com a matriz daquela passada, de modo que cada face mantém o mesmo tom na luta e durante todo o giro. Consequência: o tom não muda quando o membro gira.

## 5. Modelos e poses

- **Corpo:** 11 partes rígidas. Cada parte é uma pilha de anéis octogonais que compartilham vértices; cada octógono tem a mesma largura e profundidade do retângulo que substituiu, então as poses e as distâncias de golpe não mudaram. As tampas são 3 quadriláteros. O punho é um bloco de anéis retangulares e o pé, uma cunha.

| Parte | Anéis | Vértices | Faces |
|---|---|---|---|
| Quadril | 3 | 24 | 22 |
| Tronco (cintura, faixa, barriga, peito, ombros, trapézio) | 6 | 48 | 46 |
| Cabeça (pescoço, queixo, mandíbula, bochechas, têmporas, testa, topo) | 7 | 56 | 54 |
| Braço (cotovelo, bíceps, ombro), cada | 4 | 32 | 30 |
| Antebraço com punho, cada | 4 + 3 | 44 | 37 |
| Coxa (joelho, coxa, quadril), cada | 4 | 32 | 30 |
| Canela com panturrilha e pé em cunha, cada | 4 + cunha | 38 | 35 |
| **Lutador** | | **420** | **386** |

Com os anéis retangulares do geo3d v1.0.0 o lutador tinha 120 vértices e 96 faces. O ringue passou de 2 × 2 para 4 × 4 ladrilhos.

- **Personagens:** mesma estrutura, com medidas e cores próprias. RAI é esguio, de kimono branco com faixa preta. DAGO é mais largo, de barba, luvas vermelhas e calção azul.
- **Pose:** ângulos de cada junta. O `gen_fighter.py` resolve a cinemática e grava, para cada pose, direção e parte, o registro pronto para o geo3d: 9 palavras de matriz e 3 de translação, 24 bytes.
- **Tamanho:** 264 bytes por pose, 62 poses por banco de 16 KB. Cada personagem, em cada direção, ocupa dois bancos; o número da pose escolhe o banco.
- **Animações (19):** guarda, passo à frente, passo atrás, soco, chute, defesa, defesa atingida, golpe recebido, queda, vitória, agachado, defesa agachada atingida, soco baixo, rasteira, pulo, voadora, soco de cima e os dois passos laterais. São 122 poses.
- **Pulo e golpes do ar:** as três animações têm os mesmos 10 passos e as mesmas alturas (3 no chão, 5 no ar, 2 de aterrissagem). Por isso o pulo vira voadora ou soco de cima só trocando a animação, sem mexer no passo.
- **Giro de abertura:** 120 quadros de 30 bytes (registro de câmera e luz). A câmera dá uma volta completa, desce de 38° para 24° e aproxima de 1150 para 560 unidades. O último quadro é exatamente a câmera de luta.
- **Cores:** rampas de 7 tons na paleta de 256. O geo3d soma o nível de luz à cor base da face.

Limites atuais: 122 de 124 poses nos dois bancos; 869 de 1.023 vértices e 792 de 1.023 faces. A ROM tem 256 KB: 11 bancos usados (0 código, 1 abertura e ringue, 2 a 9 poses, 10 vértices e faces da cena) e 5 livres. O tamanho das poses não depende dos vértices: cada parte continua com um registro de 24 bytes por pose.

## 6. Jogabilidade do demo

| Golpe | Comando | Altura | Acerta no passo | Alcance | Dano |
|---|---|---|---|---|---|
| Soco | soco | alto | 3 | 86 | 9 |
| Chute | chute | médio | 4 | 102 | 14 |
| Soco baixo | agachado, soco | baixo | 2 | 82 | 6 |
| Rasteira | agachado, chute | baixo | 3 | 104 | 12 |
| Voadora | pulo com chute | de cima | 6 | 104 | 16 |
| Soco de cima | pulo com soco | de cima | 6 | 88 | 12 |

O que cada altura faz:

| Altura | Defesa em pé | Defesa agachada | Outros casos |
|---|---|---|---|
| Alto | segura | o golpe passa por cima | |
| Médio | segura | segura | |
| Baixo | acerta | segura | não pega quem está no ar |
| De cima | segura | acerta | |

- **Comandos:** o que está segurado (andar, defesa, agachar) e o que foi apertado neste quadro (soco, chute, pulo, passos laterais) ficam em dois bytes por lutador, escritos pelo teclado ou pela máquina.
- **Agachar:** segurar para baixo. Agachado o lutador já está em defesa.
- **Defesa em pé:** tecla C, ou andar para trás quando o adversário ataca a menos de 130 unidades.
- **Pulo:** 20 quadros (0,67 s). No ar, esquerda e direita ainda deslocam o lutador. Soco ou chute apertado junto, ou até o 5º passo do pulo, vira o golpe do ar.
- **Passo lateral:** dois toques para cima ou para baixo em até 9 quadros (0,3 s). O primeiro toque para cima começa um pulo; se o segundo chega enquanto o lutador ainda está no chão, o pulo vira passo lateral. O passo dura 10 quadros e gira o eixo 22,5°, um entalhe de 2,8° por quadro. Nos passos do meio o lutador está fora da linha e nenhum golpe o acerta.
- A vida vai de 0 a 100. A defesa anula o dano e reduz o empurrão.
- Os lutadores ficam dentro do ringue e nunca a menos de 72 unidades um do outro. O ringue tem 240 de meio lado e os lutadores ficam a no máximo 190 do centro, então continuam sobre ele em qualquer giro do eixo.
- A máquina se aproxima e escolhe entre soco, chute, soco baixo, rasteira, voadora, recuo, as duas defesas e o passo lateral. Quando o adversário ataca ao alcance, ela usa na maior parte das vezes a defesa que segura a altura daquele golpe, e às vezes sai com um passo lateral.
- Um novo toque no botão de soco corta o giro de abertura.

## 7. Limitações conhecidas

- O jogo exige o geo3d v2.0, que ainda não é o firmware oficial do V9968 (é o v1.0.0) e não rodou em hardware. Sobram 154 vértices e 231 faces para cenário ou detalhe.
- Na luta a câmera desliza, mas não gira nem aproxima. O giro do eixo é o ringue girando; o piso em volta é liso, então não denuncia o truque, mas um cenário com fundo desenhado vai precisar girar junto.
- Os lutadores não trocam de lado, não pulam um por cima do outro e não agarram.
- Quem leva um golpe no ar ou agachado passa direto para a animação de golpe recebido em pé.
- Ao soltar a defesa ou o agachamento o lutador volta à guarda sem quadros de transição.
- O sombreamento não acompanha a rotação dos membros.
- A ordenação de profundidade é por face, então membros que se atravessam podem aparecer na ordem errada.
- Um só cenário, sem música, sem contagem de rounds nem relógio.
- Não testado no cartucho real nem no Raspberry Pi.

## 8. Plano para o jogo completo

| Parte | Como fazer dentro das mesmas regras |
|---|---|
| 6 personagens | Mesma estrutura de 11 partes; cada um com medidas, cores e golpes próprios. A seleção de personagem carrega vértices e faces dos dois escolhidos |
| 8 cenários | O ringue continua 3D ao vivo, com ladrilhos e saia de cores próprias. Elementos de fundo desenhados uma vez pelo geo3d em páginas ocultas e copiados por HMMM |
| Mais golpes | Já são dois bancos de poses por personagem e direção, quase cheios; agarrões e golpes próprios de cada personagem pedem um terceiro |
| Mais polígonos | Feito com o geo3d v2.0 (420 vértices por lutador). Sobram 154 vértices e 231 faces da cena para cenário; personagens maiores cabem trocando o ringue por um piso mais simples |
| Câmeras de replay e de vitória | Mesma técnica do giro: um conjunto de vértices no mundo e uma tabela de registros de câmera |
| Troca de lado | Reenviar as faces dos dois lutadores com as normais da outra direção: 772 faces de 12 bytes, cerca de 60 ms com OTIR, uma vez |
| 2 jogadores | Ler o joystick 2; o lutador 1 já aceita ficar sem a máquina |
| Som | Efeitos no PSG já existem; música pelo tocador de fluxos do VECTOR RAID |
| Tamanho da ROM | Cerca de 6 bancos por personagem com o dobro de golpes: 36 bancos mais cenários, dentro de 1 MB |

## 9. Decisões em aberto

1. Nomes e estilos dos 4 personagens que faltam.
2. Temas dos 8 cenários.
3. Se o repositório será público ou privado, e a licença. Os fontes levam o cabeçalho MIT por seguirem o padrão do geo3d.
4. Se o alvo de velocidade é o cartucho real a 3,58 MHz ou também a turboR.
