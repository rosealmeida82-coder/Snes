; ============================================================================
; Jogo da Mira - 100% Assembly 65816 Puro (Sintaxe ASAR)
; Compilar com: asar jogo.asm jogo.sfc
; ============================================================================

lorom                       ; Mapeamento de memória padrão (LoROM)

; ----------------------------------------------------------------------------
; Variáveis na WRAM (espelho do banco $00: $0000-$1FFF)
; Não usar ORG/SKIP para reservar RAM: essas diretivas posicionam dados na ROM.
; ----------------------------------------------------------------------------
!cursorX    = $0000
!cursorY    = $0002
!alvoX      = $0004
!alvoY      = $0006
!pontos     = $0008
!semente    = $000A
!pad0       = $000C
!pad0_old   = $000E
!pad0_down  = $0010
!temp       = $0012
!digitoCen  = $0014
!digitoDez  = $0016
!digitoUni  = $0018
!oam_buffer = $0200

; ----------------------------------------------------------------------------
; Vetores de Interrupção e Cabeçalho do Cartucho (Obrigatório para emuladores)
; ----------------------------------------------------------------------------
org $00FFC0
    db "JOGO MIRA ASM        " ; Título interno (exatos 21 bytes)
    db $20                  ; Modo LoROM, velocidade lenta (2.68 MHz)
    db $00                  ; Tipo: Apenas ROM (sem bateria/save)
    db $05                  ; Tamanho ROM: 32 KB (2^(5+10))
    db $00                  ; Tamanho SRAM: 0 KB
    db $01                  ; Região: América do Norte (NTSC)
    db $00                  ; ID Desenvolvedor
    db $00                  ; Versão 1.0
    dw $FFFF, $0000         ; Checksum complementar e Checksum (asar corrige)

; Vetores Nativos (65816): COP, BRK, ABORT, NMI, reservado, IRQ
org $00FFE4
    dw EmptyHandler, EmptyHandler, EmptyHandler, VBlank_NMI
    dw EmptyHandler, EmptyHandler

; Vetores em modo de emulação: COP, reservado, ABORT, NMI, RESET, IRQ/BRK
org $00FFF4
    dw EmptyHandler, EmptyHandler, EmptyHandler, VBlank_NMI
    dw Reset, EmptyHandler

; ============================================================================
; Início do Código na ROM (Banco $00, Endereço $8000)
; ============================================================================
org $008000

Reset:
    sei                     ; Desabilita interrupções
    clc
    xce                     ; Sai do modo de emulação 6502 -> Entra no modo nativo 65816
    rep #$38                ; A, X, Y = 16 bits; desativa modo decimal
    lda #$0000
    tcd                     ; Direct Page = $0000
    phk
    plb                     ; DBR = banco do código (banco $00)
    ldx #$1FFF
    txs                     ; Configura o ponteiro da pilha (Stack) no topo da WRAM

    ; --- Limpa todos os registradores da PPU (Vídeo) ---
    sep #$20                ; Acumulador (A) = 8 bits
    lda #$80
    sta $2100               ; Desliga a tela (Force Blank) para poder escrever na VRAM

    ldx #$2101
-   stz $00,x               ; Zera registradores $2101 a $2133
    inx
    cpx #$2134
    bne -

    ; --- Configura Modo de Vídeo e Sprites ---
    lda #$01
    sta $2105               ; BG Mode 1
    lda #$00                ; Sprites: 8x8 (pequeno) e 16x16 (grande), base VRAM $0000
    sta $2101
    lda #$10                ; Habilita APENAS a camada de Sprites (OBJ) na tela principal
    sta $212C

    ; --- Transfere Paleta de Cores para CGRAM via DMA ---
    lda #$80                ; Cor 128 (início da paleta 0 dos Sprites)
    sta $2121
    ldx #$2200              ; Canal DMA 0: Escrita na CGRAM ($2122)
    stx $4300
    ldx #sprites_pal        ; Endereço dos dados na ROM
    stx $4302
    lda #:sprites_pal       ; Banco da ROM
    sta $4304
    ldx #32                 ; Tamanho: 32 bytes (16 cores)
    stx $4305
    lda #$01
    sta $420B               ; Dispara DMA Canal 0

    ; --- Transfere Tiles (Gráficos) para VRAM via DMA ---
    lda #$80
    sta $2115               ; Incrementa endereço da VRAM após escrever byte alto
    ldx #$0000
    stx $2116               ; Endereço inicial da VRAM = $0000
    ldx #$1801              ; Canal DMA 0: Escrita dupla na VRAM ($2118/$2119)
    stx $4300
    ldx #sprites_gfx
    stx $4302
    lda #:sprites_gfx       ; CORRIGIDO: Usa 'sta' para o banco do DMA ($4304)
    sta $4304
    ldx #960                ; Tamanho: 30 tiles * 32 bytes = 960 bytes
    stx $4305
    lda #$01
    sta $420B               ; Dispara DMA Canal 0

    ; --- Inicializa Variáveis do Jogo ---
    rep #$20                ; A = 16 bits
    lda #120
    sta !cursorX
    lda #100
    sta !cursorY
    lda #60
    sta !alvoX
    lda #60
    sta !alvoY
    stz !pontos
    lda #1234
    sta !semente
    stz !pad0
    stz !pad0_old

    ; Esconde todos os 128 sprites inicialmente (Y = 224)
    ldx #$0000
    sep #$20
    lda #224
-   sta !oam_buffer+1,x
    inx
    inx
    inx
    inx
    cpx #512
    bne -

    ; Inicializa os 32 bytes da tabela alta da OAM.
    ldx #$0000
    lda #$00
-   sta !oam_buffer+512,x
    inx
    cpx #32
    bne -
    lda #$0A                ; Sprites 0 e 1 em 16x16; restantes em 8x8
    sta !oam_buffer+512

    ; --- Liga a Tela e Ativa Leitura Automática de Controle + NMI (VBlank) ---
    lda #$0F
    sta $2100               ; Brilho máximo, tela ligada
    lda #$81
    sta $4200               ; Habilita NMI (VBlank) e Auto-Joypad Read

; ============================================================================
; Loop Principal do Jogo
; ============================================================================
GameLoop:
    wai                     ; Aguarda a interrupção VBlank (sincronia de 60 FPS)

    rep #$30                ; A, X, Y = 16 bits
    lda !semente
    eor !pad0                ; Mistura o input do controle na !semente para aleatoriedade real
    inc !semente             ; Incrementa !semente aleatória a cada frame

    ; --- Leitura do Controle 1 (Auto-Joypad) ---
    lda !pad0
    sta !pad0_old            ; Salva estado anterior
    lda $4218               ; Lê registrador de hardware do Controle 1
    sta !pad0
    eor !pad0_old            ; Detecta botões que mudaram de estado
    and !pad0                ; Filtra apenas os que acabaram de ser apertados (padsDown)
    sta !pad0_down

    ; --- Movimento CIMA ($0800) ---
    lda !pad0
    bit #$0800
    beq +
    lda !cursorY
    cmp #2
    bcc .zeroY
    sec
    sbc #2
    sta !cursorY
    bra +
.zeroY:
    stz !cursorY
+
    ; --- Movimento BAIXO ($0400) ---
    lda !pad0
    bit #$0400
    beq +
    lda !cursorY
    cmp #207
    bcs .maxY
    clc
    adc #2
    sta !cursorY
    bra +
.maxY:
    lda #208
    sta !cursorY
+
    ; --- Movimento ESQUERDA ($0200) ---
    lda !pad0
    bit #$0200
    beq +
    lda !cursorX
    cmp #2
    bcc .zeroX
    sec
    sbc #2
    sta !cursorX
    bra +
.zeroX:
    stz !cursorX
+
    ; --- Movimento DIREITA ($0100) ---
    lda !pad0
    bit #$0100
    beq +
    lda !cursorX
    cmp #239
    bcs .maxX
    clc
    adc #2
    sta !cursorX
    bra +
.maxX:
    lda #240
    sta !cursorX
+
    ; --- Verifica Botão A ($0080) e Colisão ---
    lda !pad0_down
    bit #$0080
    beq AtualizaPlacarOAM

    ; Colisão AABB (16x16)
    lda !cursorX
    clc
    adc #16
    cmp !alvoX
    beq AtualizaPlacarOAM
    bcc AtualizaPlacarOAM

    lda !alvoX
    clc
    adc #16
    cmp !cursorX
    beq AtualizaPlacarOAM
    bcc AtualizaPlacarOAM

    lda !cursorY
    clc
    adc #16
    cmp !alvoY
    beq AtualizaPlacarOAM
    bcc AtualizaPlacarOAM

    lda !alvoY
    clc
    adc #16
    cmp !cursorY
    beq AtualizaPlacarOAM
    bcc AtualizaPlacarOAM

    ; --- Acertou o Alvo! ---
    inc !pontos
    rep #$20
    lda !pontos
    cmp #1000
    bcc +
    stz !pontos             ; Placar circular: 000 a 999
+
    jsr PlaySound           ; Sem driver SPC700: rotina silenciosa por enquanto

    lda #220
    jsr Aleatorio
    clc
    adc #10
    sta !alvoX

    lda #188
    jsr Aleatorio
    clc
    adc #10
    sta !alvoY

    ; --- Atualiza Buffer OAM na RAM (Sprites e Placar) ---
AtualizaPlacarOAM:
    jsr ConverterPontos     ; Separa !pontos em Centenas, Dezenas e Unidades

    sep #$20                ; A = 8 bits
    
    ; Sprite 0: Mira
    lda !cursorX
    sta !oam_buffer+0        ; Posição X
    lda !cursorY
    sta !oam_buffer+1        ; Posição Y
    lda #$00
    sta !oam_buffer+2        ; Tile 0
    lda #$30                ; Prioridade 3, Paleta 0
    sta !oam_buffer+3

    ; Sprite 1: Alvo
    lda !alvoX
    sta !oam_buffer+4        ; Posição X
    lda !alvoY
    sta !oam_buffer+5        ; Posição Y
    lda #$02
    sta !oam_buffer+6        ; Tile 2
    lda #$20                ; Prioridade 2, Paleta 0
    sta !oam_buffer+7

    ; Sprite 2: Placar - Centenas
    lda #16                 ; X fixo
    sta !oam_buffer+8
    lda #8                  ; Y fixo
    sta !oam_buffer+9
    rep #$20
    lda !digitoCen
    clc : adc #20           ; Tiles 20..29: números 8x8 carregados na VRAM
    sep #$20
    sta !oam_buffer+10
    lda #$30
    sta !oam_buffer+11

    ; Sprite 3: Placar - Dezenas
    lda #32
    sta !oam_buffer+12
    lda #8
    sta !oam_buffer+13
    rep #$20
    lda !digitoDez
    clc : adc #20
    sep #$20
    sta !oam_buffer+14
    lda #$30
    sta !oam_buffer+15

    ; Sprite 4: Placar - Unidades
    lda #48
    sta !oam_buffer+16
    lda #8
    sta !oam_buffer+17
    rep #$20
    lda !digitoUni
    clc : adc #20
    sep #$20
    sta !oam_buffer+18
    lda #$30
    sta !oam_buffer+19

    ; Tabela alta da OAM: sprites 0 e 1 em 16x16; dígitos em 8x8.
    lda #$0A
    sta !oam_buffer+512

    jmp GameLoop

; ============================================================================
; Interrupção VBlank (Roda automaticamente 60x por segundo)
; ============================================================================
VBlank_NMI:
    php
    rep #$30
    pha
    phx

    sep #$20
    lda $4210               ; Reconhece a interrupção NMI

    ; Copia !oam_buffer da RAM para a OAM da PPU via DMA
    stz $2102
    stz $2103               ; Endereço inicial OAM = $0000
    ldx #$0400              ; Canal DMA 0: Escrita na OAM ($2104)
    stx $4300
    ldx #!oam_buffer
    stx $4302
    stz $4304               ; Banco $00
    ldx #544                ; Tamanho total da tabela OAM
    stx $4305
    lda #$01
    sta $420B               ; Dispara DMA

    rep #$30
    plx
    pla
    plp
    rti

EmptyHandler:
    rti

; ============================================================================
; Sub-rotina de som (desativada até existir um driver SPC700 funcional)
; ============================================================================
PlaySound:
    ; TODO: implementar e enviar um driver SPC700 antes de disparar efeitos.
    ; Escrever apenas nas portas $2140/$2141 não produz som por si só.
    rts

; ============================================================================
; Sub-rotina: Aleatorio (Entrada: A = max | Saída: A = resto da divisão)
; ============================================================================
Aleatorio:
    sta !temp                ; Salva 'max'
    sep #$20                ; A = 8 bits para acessar registradores matemáticos

    lda !semente
    sta $4202               ; Multiplicando A
    lda #173
    sta $4203               ; Multiplicador B
    nop : nop : nop : nop

    rep #$20                ; A = 16 bits
    lda $4216               ; Lê resultado da multiplicação
    clc
    adc #13849
    sta !semente

    sta $4204               ; Dividendo (16 bits)
    sep #$20
    lda !temp
    sta $4206               ; Divisor (8 bits)
    nop : nop : nop : nop : nop : nop : nop : nop

    rep #$20
    lda $4216               ; Lê o RESTO da divisão (módulo %)
    rts

; ============================================================================
; Sub-rotina: Converte pontos (16-bit) em Centenas, Dezenas e Unidades
; ============================================================================
ConverterPontos:
    rep #$30
    lda !pontos
    
    sta $4204               ; Divide !pontos por 10
    sep #$20
    lda #10
    sta $4206
    nop : nop : nop : nop : nop : nop : nop : nop
    
    rep #$20
    lda $4216               ; Resto = Unidades
    sta !digitoUni
    lda $4214               ; Quociente
    
    sta $4204               ; Divide quociente por 10 novamente
    sep #$20
    lda #10
    sta $4206
    nop : nop : nop : nop : nop : nop : nop : nop
    
    rep #$20
    lda $4216               ; Resto = Dezenas
    sta !digitoDez
    lda $4214               ; Quociente = Centenas
    sta !digitoCen
    rts

; ============================================================================
; Dados Gráficos e Paleta (ROM)
; ============================================================================
sprites_gfx:
; Tile 0: Mira Superior Esquerda
db $FF,$00, $80,$00, $80,$00, $80,$00, $80,$00, $80,$00, $80,$00, $81,$00
fillbyte $00 : fill 16
; Tile 1: Mira Superior Direita
db $FF,$00, $01,$00, $01,$00, $01,$00, $01,$00, $01,$00, $01,$00, $81,$00
fillbyte $00 : fill 16
; Tile 2: Alvo Superior Esquerdo
fillbyte $FF : fill 16
fillbyte $00 : fill 16
; Tile 3: Alvo Superior Direito
fillbyte $FF : fill 16
fillbyte $00 : fill 16
; Tiles 4 a 15: Vazios / Espaço reservado (384 bytes)
fillbyte $00 : fill 384
; Tile 16: Mira Inferior Esquerda
db $81,$00, $80,$00, $80,$00, $80,$00, $80,$00, $80,$00, $80,$00, $FF,$00
fillbyte $00 : fill 16
; Tile 17: Mira Inferior Direita
db $81,$00, $01,$00, $01,$00, $01,$00, $01,$00, $01,$00, $01,$00, $FF,$00
fillbyte $00 : fill 16
; Tile 18: Alvo Inferior Esquerdo
fillbyte $FF : fill 16
fillbyte $00 : fill 16
; Tile 19: Alvo Inferior Direito
fillbyte $FF : fill 16
fillbyte $00 : fill 16

; Tiles 20 a 29: dígitos 0-9 em 8x8, formato planar 4bpp
; Dígito 0
db $3C, $00, $66, $00, $6E, $00, $76, $00
db $66, $00, $66, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 1
db $18, $00, $38, $00, $18, $00, $18, $00
db $18, $00, $18, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 2
db $3C, $00, $66, $00, $06, $00, $0C, $00
db $30, $00, $60, $00, $7E, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 3
db $3C, $00, $66, $00, $06, $00, $1C, $00
db $06, $00, $66, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 4
db $0C, $00, $1C, $00, $2C, $00, $4C, $00
db $7E, $00, $0C, $00, $0C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 5
db $7E, $00, $60, $00, $7C, $00, $06, $00
db $06, $00, $66, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 6
db $3C, $00, $60, $00, $60, $00, $7C, $00
db $66, $00, $66, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 7
db $7E, $00, $06, $00, $0C, $00, $18, $00
db $30, $00, $30, $00, $30, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 8
db $3C, $00, $66, $00, $66, $00, $3C, $00
db $66, $00, $66, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
; Dígito 9
db $3C, $00, $66, $00, $66, $00, $3E, $00
db $06, $00, $06, $00, $3C, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00
db $00, $00, $00, $00, $00, $00, $00, $00

sprites_pal:
dw $0000, $7FFF, $001F, $001F
dw $0000, $0000, $0000, $0000, $0000, $0000, $0000, $0000
dw $0000, $0000, $0000, $0000
