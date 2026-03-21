; =============================================================================
; game.asm - "My Name" Bootable Game (Legacy Real Mode)
; CE 4303 - Principios de Sistemas Operativos
; =============================================================================

    org 0x1000
    bits 16
    dw 0xDEFD

VGA_SEG     equ 0xB800
ATTR_YELLOW equ 0x0F
ATTR_GREEN  equ 0x0A

; =============================================================================
; ENTRY POINT
; =============================================================================
game_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    sti

    mov ax, 0x0003
    int 0x10

    xor ax, ax
    int 0x1A
    mov [seed], dx

    mov ax, VGA_SEG
    mov es, ax
    xor ax, ax
    mov ds, ax

    call show_confirm

.game:
    call randomize
    call render

.poll:
    mov ah, 0x01
    int 0x16
    jz .poll

    mov ah, 0x00
    int 0x16

    push ax
    xor ax, ax
    mov ds, ax
    mov ax, VGA_SEG
    mov es, ax
    pop ax

    cmp al, 0x1B
    je .quit
    cmp al, 'r'
    je .game
    cmp al, 'R'
    je .game
    cmp ah, 0x4B
    je .rotl
    cmp ah, 0x4D
    je .rotr
    cmp ah, 0x48
    je .flip
    cmp ah, 0x50
    je .flip
    jmp .poll

.rotl:
    dec byte [rot]
    and byte [rot], 3
    call render
    jmp .poll
.rotr:
    inc byte [rot]
    and byte [rot], 3
    call render
    jmp .poll
.flip:
    xor byte [vflip], 1
    call render
    jmp .poll
.quit:
    db 0xEA
    dw 0x0000
    dw 0xFFFF

; =============================================================================
; CONFIRM SCREEN
; =============================================================================
show_confirm:
    call cls
    mov si, str_title
    mov bx, 0x0818
    call pr
    mov si, str_press_y
    mov bx, 0x0C18
    call pr
    mov si, str_controls
    mov bx, 0x0E10
    call pr
.wait:
    mov ah, 0x00
    int 0x16
    push ax
    xor ax, ax
    mov ds, ax
    mov ax, VGA_SEG
    mov es, ax
    pop ax
    cmp al, 'y'
    je .go
    cmp al, 'Y'
    je .go
    cmp al, 0x1B
    je .esc
    jmp .wait
.esc:
    db 0xEA
    dw 0x0000
    dw 0xFFFF
.go:
    ret

; =============================================================================
; RANDOMIZE
; =============================================================================
randomize:
    call rng
    xor ah, ah
    mov bl, 50
    div bl
    mov [ncol], ah
    call rng
    xor ah, ah
    mov bl, 7
    div bl
    inc ah
    mov [nrow], ah
    mov byte [rot], 0
    mov byte [vflip], 0
    ret

rng:
    mov ax, [seed]
    mov cx, 6364
    mul cx
    add ax, 1013
    mov [seed], ax
    mov al, ah
    xor ah, ah
    ret

seed  dw 0
nrow  db 3
ncol  db 10
rot   db 0
vflip db 0

; =============================================================================
; RENDER
; =============================================================================
render:
    call cls
    mov si, str_status
    mov bx, 0x1700
    call pr

    mov byte [roff], 0
    mov byte [coff], 0
    mov byte [name_w], 24   ; MARCO: 5 letters * 5 - 1 = 24  (W-1)
    mov word [gp], glyph_M
    call dg
    add byte [coff], 5
    mov word [gp], glyph_A
    call dg
    add byte [coff], 5
    mov word [gp], glyph_R
    call dg
    add byte [coff], 5
    mov word [gp], glyph_C
    call dg
    add byte [coff], 5
    mov word [gp], glyph_O
    call dg
    ret

; =============================================================================
; CLS
; =============================================================================
cls:
    xor di, di
    mov cx, 80*25
    mov ax, 0x0720
.l: mov [es:di], ax
    add di, 2
    loop .l
    ret

; =============================================================================
; PR — print SI at BH=row BL=col. ES=VGA_SEG, DS=0
; =============================================================================
pr:
    xor ah, ah
    mov al, bh
    mov cl, 7
    shl ax, cl
    push ax
    xor ah, ah
    mov al, bh
    mov cl, 5
    shl ax, cl
    pop cx
    add ax, cx
    xor ch, ch
    mov cl, bl
    shl cx, 1
    add ax, cx
    mov di, ax
.l: mov al, [si]
    cmp al, 0
    je .r
    mov byte [es:di], al
    mov byte [es:di+1], ATTR_YELLOW
    add di, 2
    inc si
    jmp .l
.r: ret

; =============================================================================
; DG — draw one glyph
; =============================================================================
dg:
    mov byte [gr], 0
.rl:
    mov al, [gr]
    cmp al, 5
    jge .gd
    mov byte [gc], 0
.cl:
    mov al, [gc]
    cmp al, 4
    jge .nr
    mov al, [gr]
    shl al, 1
    shl al, 1
    add al, [gc]
    xor ah, ah
    mov bx, [gp]
    add bx, ax
    mov al, [bx]
    cmp al, 0
    je .sk
    call tf
    xor ah, ah
    mov al, bh
    mov cl, 7
    shl ax, cl
    push ax
    xor ah, ah
    mov al, bh
    mov cl, 5
    shl ax, cl
    pop cx
    add ax, cx
    xor ch, ch
    mov cl, bl
    shl cx, 1
    add ax, cx
    mov di, ax
    mov byte [es:di],   0xDB
    mov byte [es:di+1], ATTR_GREEN
.sk:
    inc byte [gc]
    jmp .cl
.nr:
    inc byte [gr]
    jmp .rl
.gd:
    ret

; =============================================================================
; TF — rotate whole name as one unit → BH=screen_row BL=screen_col
;
; Global position within the name:
;   gR = [gr]            row within glyph (0..4)
;   gC = [coff] + [gc]   global col across all letters (0..W-1)
;
; Rotations (H-1=4, W-1=[name_w]):
;   rot0: out_r=gR,        out_c=gC
;   rot1: out_r=gC,        out_c=4-gR     (right 90°, whole name clockwise)
;   rot2: out_r=4-gR,      out_c=name_w-gC (180°)
;   rot3: out_r=name_w-gC, out_c=gR       (left 90°)
;
; vflip: out_r = 4 - out_r
; AL=out_r, AH=out_c on exit from rotation section
; =============================================================================
tf:
    ; Compute gR (AL) and gC (AH)
    mov al, [gr]
    mov ah, [gc]
    add ah, [coff]          ; AH = global col gC

    mov cl, [rot]
    cmp cl, 1
    je .r1
    cmp cl, 2
    je .r2
    cmp cl, 3
    je .r3

.r0:                        ; normal
    jmp .vf                 ; AL=gR, AH=gC already correct

.r1:                        ; right 90°: out_r=gC, out_c=4-gR
    xchg al, ah             ; AL=gC, AH=gR
    mov cl, 4
    sub cl, ah
    mov ah, cl              ; AH = 4-gR
    jmp .vf

.r2:                        ; 180°: out_r=4-gR, out_c=name_w-gC
    mov cl, 4
    sub cl, al
    mov al, cl              ; AL = 4-gR
    mov cl, [name_w]
    sub cl, ah
    mov ah, cl              ; AH = name_w-gC
    jmp .vf

.r3:                        ; left 90°: out_r=name_w-gC, out_c=gR
    mov cl, [name_w]
    sub cl, ah
    mov ah, al              ; AH = gR (save before overwrite)
    mov al, cl              ; AL = name_w-gC

.vf:
    cmp byte [vflip], 0
    je .nv
    mov cl, 4
    sub cl, al
    mov al, cl              ; AL = 4-out_r
.nv:
    ; BH = screen row = nrow + roff + out_r
    ; BL = screen col = ncol + out_c
    mov bh, [nrow]
    add bh, [roff]
    add bh, al
    mov bl, [ncol]
    add bl, ah
    cmp bh, 22
    jbe .rok
    mov bh, 22
.rok:
    cmp bl, 79
    jbe .cok
    mov bl, 79
.cok:
    ret

; =============================================================================
; STATE
; =============================================================================
gr     db 0
gc     db 0
roff   db 0
coff   db 0
gp     dw 0
name_w db 29    ; W-1 of current name (29=ANDRES, 24=MARCO)

; =============================================================================
; STRINGS
; =============================================================================
str_title    db "=== MY NAME: ANDRES & MARCO ===", 0
str_press_y  db "Press Y to play or ESC to exit", 0
str_controls db "[Arrows]=Rotate  [R]=Restart  [ESC]=Quit", 0
str_status   db " [<][>]=Rotate  [^][v]=Flip  [R]=Restart  [ESC]=Quit ", 0

; =============================================================================
; GLYPHS
; =============================================================================
glyph_A: db 0,1,1,0, 1,0,0,1, 1,1,1,1, 1,0,0,1, 1,0,0,1
glyph_N: db 1,0,0,1, 1,1,0,1, 1,0,1,1, 1,0,0,1, 1,0,0,1
glyph_D: db 1,1,0,0, 1,0,1,0, 1,0,0,1, 1,0,1,0, 1,1,0,0
glyph_R: db 1,1,1,0, 1,0,0,1, 1,1,1,0, 1,0,1,0, 1,0,0,1
glyph_E: db 1,1,1,1, 1,0,0,0, 1,1,1,0, 1,0,0,0, 1,1,1,1
glyph_S: db 0,1,1,1, 1,0,0,0, 0,1,1,0, 0,0,0,1, 1,1,1,0
glyph_M: db 1,0,0,1, 1,1,1,1, 1,0,0,1, 1,0,0,1, 1,0,0,1
glyph_C: db 0,1,1,1, 1,0,0,0, 1,0,0,0, 1,0,0,0, 0,1,1,1
glyph_O: db 0,1,1,0, 1,0,0,1, 1,0,0,1, 1,0,0,1, 0,1,1,0