; =============================================================================
; game.asm - "My Name" Bootable Game  (Legacy / Real Mode)
; CE 4303 - Principios de Sistemas Operativos
;
; Single flat file. Build:
;   nasm -f bin game.asm -o game.bin
;
; Loaded by boot.asm at 0x0000:0x1000. First two bytes = magic 0xDEFD.
; =============================================================================

    org 0x1000
    bits 16

    dw 0xDEFD           ; Magic number checked by boot.asm

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

    ; Set 80x25 color text mode
    mov ax, 0x0003
    int 0x10
    ; NOTE: we do NOT try to restore DS here. BIOS calls clobber DS freely.
    ; All string printing uses BX as pointer (not lodsb/DS) so it doesn't matter.

    call seed_rng
    call show_confirm_screen
    call game_loop
    jmp reboot

; =============================================================================
; CONFIRMATION SCREEN
; =============================================================================
show_confirm_screen:
    call clear_screen

    mov bx, str_title
    mov dh, 8
    mov dl, 24
    call print_at

    mov bx, str_press_y
    mov dh, 12
    mov dl, 24
    call print_at

    mov bx, str_controls
    mov dh, 14
    mov dl, 16
    call print_at

.wait:
    mov ah, 0x00
    int 0x16            ; Wait for keypress
    cmp al, 'y'
    je .done
    cmp al, 'Y'
    je .done
    cmp al, 0x1B
    je reboot
    jmp .wait
.done:
    ret

; =============================================================================
; GAME LOOP
; =============================================================================
game_loop:
    call init_game_state
    call render_names

.poll:
    mov ah, 0x01
    int 0x16            ; Check keyboard buffer (non-blocking)
    jz .poll            ; ZF=1 = empty

    mov ah, 0x00
    int 0x16            ; Read key

    cmp al, 0x1B
    je .quit

    cmp al, 'r'
    je game_loop
    cmp al, 'R'
    je game_loop

    cmp ah, 0x4B        ; Left arrow
    je .rotate_left
    cmp ah, 0x4D        ; Right arrow
    je .rotate_right
    cmp ah, 0x48        ; Up arrow
    je .flip
    cmp ah, 0x50        ; Down arrow
    je .flip

    jmp .poll

.rotate_left:
    mov al, [rotation_state]
    dec al
    and al, 3
    mov [rotation_state], al
    call render_names
    jmp .poll

.rotate_right:
    mov al, [rotation_state]
    inc al
    and al, 3
    mov [rotation_state], al
    call render_names
    jmp .poll

.flip:
    xor byte [vertical_flip], 1
    call render_names
    jmp .poll

.quit:
    ret

; =============================================================================
; INIT GAME STATE
; =============================================================================
init_game_state:
    call rand_byte
    xor ah, ah
    mov bl, 50
    div bl
    mov [name_col], ah

    call rand_byte
    xor ah, ah
    mov bl, 7
    div bl
    inc ah
    mov [name_row], ah

    mov byte [rotation_state], 0
    mov byte [vertical_flip], 0
    ret

; =============================================================================
; REBOOT
; =============================================================================
reboot:
    db 0xEA
    dw 0x0000
    dw 0xFFFF

; =============================================================================
; GAME STATE
; =============================================================================
rotation_state  db 0
vertical_flip   db 0
name_row        db 3
name_col        db 10

; =============================================================================
; STRINGS
; =============================================================================
str_title       db "=== MY NAME: ANDRES & MARCO ===", 0
str_press_y     db "Press Y to play or ESC to exit", 0
str_controls    db "[Arrows]=Rotate  [R]=Restart  [ESC]=Quit", 0
str_status      db " [<][>]=Rotate  [^][v]=Flip  [R]=Restart  [ESC]=Quit ", 0

; =============================================================================
; PRNG
; =============================================================================
seed_rng:
    xor ax, ax
    int 0x1A
    mov [rng_seed], dx
    ret

rand_byte:
    push dx
    mov ax, [rng_seed]
    mov cx, 6364
    mul cx
    add ax, 1013
    mov [rng_seed], ax
    mov al, ah
    xor ah, ah
    pop dx
    ret

rng_seed    dw 0

; =============================================================================
; RENDERING
; =============================================================================

clear_screen:
    mov ah, 0x06
    xor al, al
    xor cx, cx
    mov dh, 24
    mov dl, 79
    mov bh, 0x07
    int 0x10
    mov ah, 0x02
    xor bh, bh
    xor dx, dx
    int 0x10
    ret

; -----------------------------------------------------------------------------
; print_at
; BX = pointer to null-terminated string, DH = row, DL = col
;
; KEY DESIGN: uses [bx] to read characters, NOT lodsb.
; BIOS INT 10h calls clobber DS on every call. lodsb depends on DS:SI.
; BX is never modified by any BIOS call, so using [bx] + inc bx is safe.
; -----------------------------------------------------------------------------
print_at:
    push bx
    push dx

    mov ah, 0x02        ; Set cursor position
    xor bh, bh
    int 0x10

.next:
    mov al, [bx]        ; Read byte using BX — completely independent of DS
    cmp al, 0
    je .done
    mov ah, 0x0E        ; Teletype output
    xor bh, bh
    int 0x10            ; DS may be clobbered here — doesn't matter, we use BX
    inc bx
    jmp .next

.done:
    pop dx
    pop bx
    ret

render_names:
    call clear_screen

    mov bx, str_status
    mov dh, 23
    mov dl, 0
    call print_at

    call draw_name1
    call draw_name2
    ret

draw_name1:
    mov byte [cur_row_off], 0
    mov byte [cur_col_off], 0
    mov word [glyph_ptr], glyph_A
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_N
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_D
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_R
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_E
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_S
    call draw_glyph
    ret

draw_name2:
    mov byte [cur_row_off], 7
    mov byte [cur_col_off], 0
    mov word [glyph_ptr], glyph_M
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_A
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_R
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_C
    call draw_glyph
    add byte [cur_col_off], 5
    mov word [glyph_ptr], glyph_O
    call draw_glyph
    ret

draw_glyph:
    ; glyph_ptr must be set by caller before calling this function.
    ; Stored in memory so INT 10h calls cannot clobber it.
    mov byte [glyph_row], 0

.row_loop:
    mov al, [glyph_row]
    cmp al, 5
    jge .done

    mov byte [glyph_col], 0

.col_loop:
    mov al, [glyph_col]
    cmp al, 4
    jge .next_row

    ; Compute index = row*4 + col, read cell value
    mov al, [glyph_row]
    mov bl, 4
    mul bl              ; AX = row*4
    add al, [glyph_col]
    xor ah, ah
    mov bx, [glyph_ptr] ; Reload glyph base from memory each time
    add bx, ax
    mov cl, [bx]        ; CL = cell value

    cmp cl, 0
    je .skip

    call transform_coords   ; -> DH=row, DL=col

    ; Draw block character — use push/pop to protect DX across INT 10h
    push dx
    mov ah, 0x02        ; Set cursor
    xor bh, bh
    int 0x10            ; May clobber SI, DS, etc — we don't care
    pop dx

    push dx
    mov ah, 0x09        ; Write char + attribute
    mov al, 0xDB        ; Full block
    mov bl, 0x0A        ; Bright green
    mov cx, 1
    int 0x10
    pop dx

.skip:
    inc byte [glyph_col]
    jmp .col_loop

.next_row:
    inc byte [glyph_row]
    jmp .row_loop

.done:
    ret

transform_coords:
    mov al, [glyph_row]
    mov bl, [glyph_col]

    mov cl, [rotation_state]
    cmp cl, 1
    je .rot1
    cmp cl, 2
    je .rot2
    cmp cl, 3
    je .rot3

.rot0:
    mov ah, al
    mov bh, bl
    jmp .vflip
.rot1:
    mov ah, bl
    mov bh, 4
    sub bh, al
    jmp .vflip
.rot2:
    mov ah, 4
    sub ah, al
    mov bh, 3
    sub bh, bl
    jmp .vflip
.rot3:
    mov ah, 3
    sub ah, bl
    mov bh, al

.vflip:
    cmp byte [vertical_flip], 0
    je .no_vflip
    mov cl, 4
    sub cl, ah
    mov ah, cl
.no_vflip:
    mov dh, [name_row]
    add dh, [cur_row_off]
    add dh, ah
    mov dl, [name_col]
    add dl, [cur_col_off]
    add dl, bh
    cmp dh, 22
    jbe .row_ok
    mov dh, 22
.row_ok:
    cmp dl, 79
    jbe .col_ok
    mov dl, 79
.col_ok:
    ret

; =============================================================================
; RENDER STATE
; =============================================================================
glyph_row   db 0
glyph_col   db 0
cur_row_off db 0
cur_col_off db 0
glyph_ptr   dw 0        ; Glyph base pointer — stored in memory, not a register,
                        ; so INT 10h calls cannot clobber it

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