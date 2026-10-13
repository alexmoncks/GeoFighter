# GEO FIGHTER

Jogo de luta 3D para MSX com o V9968 e o coprocessador geo3d, no estilo do Virtua Fighter: lutadores de polígonos sombreados num ringue 3D. O plano é ter 6 personagens e 8 cenários.

Este repositório está na fase do **demo de teste**: dois personagens (RAI e DAGO) lutam num ringue visto em diagonal e de cima, depois de a câmera dar uma volta completa em torno dele.

![Giro](docs/giro1.png) ![Giro](docs/giro2.png)

![Luta](docs/luta.png) ![Vitória](docs/vitoria.png)

## O que o demo faz

- Título, giro de 360° da câmera em volta do ringue até fechar nos lutadores, "ROUND 1", "FIGHT!", luta, nocaute, pose de vitória, novo round.
- Jogador 1 no teclado ou no joystick 1 contra a máquina. Sem apertar nada no título, a máquina joga contra si mesma.
- Golpes: soco e chute. Defesa bloqueia os dois. Barras de vida no alto.
- 30 quadros por segundo, com som de golpe, defesa e queda no PSG.

## Controles

| Ação | Teclado | Joystick 1 |
|---|---|---|
| Andar | cursores esquerda e direita | esquerda e direita |
| Soco | ESPAÇO ou Z | botão A |
| Chute | X | botão B |
| Defesa | C ou cursor para baixo | para baixo |
| Voltar ao título | RETURN | |

No demo automático, ESPAÇO ou o botão A passa o controle do RAI para você. Durante o giro de abertura, um novo toque em ESPAÇO ou no botão A pula direto para a luta.

## Como rodar

- **openMSX (fork com V9968 e geo3d):** `jogar_openmsx.bat`, ou
  `openmsx -machine C-BIOS_V9968_JP -ext geo3d -cart release/GEOFIGHTER_98.ROM -romtype ASCII16`.
- **Cartucho real (V9968 em 88h):** `release/GEOFIGHTER_88.ROM`, MegaROM ASCII16 de 128 KB.
- **Raspberry Pi com o pacote geo3d-rpi:** copie `GEOFIGHTER_98.ROM` para a pasta `roms` do cartão; o menu o reconhece sozinho pela assinatura `ROM_AS16`.

## Como montar

No WSL ou em Linux, com `z80asm` 1.8 e `python3` (sem pacotes extras):

```sh
bash build.sh          # gera out/ e copia as ROMs para release/
bash build.sh --data   # refaz também modelos, poses e tabelas
```

O `build.sh` roda `tools/gen_fighter.py`, que gera modelos, poses, paleta e tabelas, e monta as duas ROMs (perfis 98h e 88h).

Para ver as poses sem emulador:

```sh
cd tools
python3 preview.py sheet 0              # out/preview_sheet0.png: todas as poses do personagem 0
python3 preview.py scene 0 0 -64 64     # out/preview_scene.png: um quadro da luta com os dois
python3 preview.py orbit 12             # out/preview_orbit.png: 12 quadros do giro de abertura
```

## Testes

```sh
bash tests/run_tests.sh                 # boot, demo e play
bash tests/run_tests.sh skip            # o toque que corta o giro de abertura
bash tests/run_tests.sh prof proforbit  # quadros por segundo e tempo de cada etapa, na luta e no giro
SHOT=1 bash tests/run_tests.sh shots    # capturas de tela em out/test/shots
PROFILE=88 MACHINE=Philips_NMS_8250 bash tests/run_tests.sh play
```

Os testes dirigem o openMSX pelo `tests/run.tcl`: seguram teclas, esperam quadros e conferem a memória do jogo pelos rótulos do assembler. `OPENMSX=...` escolhe o emulador (o padrão é o `openmsx.exe` de `..\openmsx-geo3d`).

## Estado

| Item | Situação |
|---|---|
| Emulador, perfil 98h | funciona, 30 quadros por segundo, 15 ms de trabalho por quadro na luta e 7 ms no giro |
| Emulador, perfil 88h | funciona (testado num MSX2 com o cartucho emulado) |
| Cartucho real | ainda não testado |
| Raspberry Pi | ainda não testado |

Detalhes de como o 3D foi otimizado, formatos de dados, medições e o plano para o jogo completo estão em [docs/design.md](docs/design.md).

## Organização

| Pasta | Conteúdo |
|---|---|
| `src/` | o cartucho em assembly Z80 |
| `tools/` | gerador de modelos e poses, pré-visualização |
| `tests/` | cenários de teste no openMSX |
| `docs/` | desenho técnico e imagens |
| `release/` | ROMs prontas |
| `out/` | saída do build (fora do git) |

A base do cartucho (partida, VDP, interrupção, texto, build e testes) vem do MSX WOLF; a técnica de cena residente vem do VECTOR RAID.
