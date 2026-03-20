; =============================================================================
; game.asm - "My Name" Bootable Game
; CE 4303 - Principios de Sistemas Operativos
;
; Displays two names on screen at a random position. Arrow keys rotate the
; name text in different ways. 'R' restarts, ESC quits.
;
; Entry points:
;   - Legacy: loaded at 0x1000 by boot.asm, CPU in real mode
;   - UEFI:   called as a C function pointer after ExitBootServices;
;             we set up our own segments and switch to real mode isn't needed
;             because EDK2 leaves us in long mode — so for UEFI we use
;             VGA linear framebuffer via UEFI GOP instead.
;
; For simplicity and hardware compatibility, this file implements the
; LEGACY (real mode) version.  The UEFI payload (game_uefi.asm) is a
; separate file that uses 64-bit protected mode and VESA/GOP.
;
; Build:
;   nasm -f bin game.asm -o game.bin
;
; The first two bytes MUST be 0xFD 0xDE so that boot.asm magic-number check
; (cmp word [0x1000], 0xDEFD) passes.  NASM stores words little-endian, so
;   dw 0xDEFD  →  bytes [0xFD, 0xDE]  →  word at address == 0xDEFD  ✓
; =============================================================================

    org 0x1000          ; Legacy: loaded here by boot.asm
    bits 16

; --------------------------------------------------------------------------
; Magic number (must be first two bytes)
; --------------------------------------------------------------------------
    dw 0xDEFD           ; Magic signature checked by boot.asm

; =============================================================================
; ENTRY POINT
; =============================================================================
game_start:
    ; Re-initialize segments (we may arrive from boot.asm with unknown state)
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000      ; Stack safely below our code at 0x1000
    sti

    ; Seed pseudo-RNG with timer tick count
    xor ax, ax
    int 0x1A            ; BIOS get clock ticks → CX:DX
    mov [rng_seed], dx

    call show_confirm_screen
    call game_loop
    ; If game_loop returns (ESC pressed) we reach here
    jmp reboot

; =============================================================================
; CONFIRMATION SCREEN
; Waits for 'Y' to start or ESC to abort.
; =============================================================================
show_confirm_screen:
    call clear_screen

    mov si, str_title
    mov dh, 8           ; Row
    mov dl, 22          ; Col
    call print_at

    mov si, str_confirm
    mov dh, 12
    mov dl, 15
    call print_at

    mov si, str_controls
    mov dh, 14
    mov dl, 10
    call print_at

.wait_key:
    mov ah, 0x00
    int 0x16            ; BIOS: wait for keystroke → AH=scan AL=ASCII

    cmp al, 'y'
    je .done
    cmp al, 'Y'
    je .done
    cmp al, 0x1B        ; ESC
    je reboot
    jmp .wait_key

.done:
    ret

; =============================================================================
; MAIN GAME LOOP
; =============================================================================
game_loop:
    ; --- Initialize game state ---
    call init_game_state
    call render_names

.poll:
    ; Check for keypress (non-blocking)
    mov ah, 0x01
    int 0x16
    jz .poll            ; Zero flag set = no key waiting

    ; Read the key
    mov ah, 0x00
    int 0x16            ; AH = scan code, AL = ASCII

    ; --- ESC: quit ---
    cmp al, 0x1B
    je .quit

    ; --- R: restart ---
    cmp al, 'r'
    je game_loop
    cmp al, 'R'
    je game_loop

    ; --- Arrow keys: scan code in AH, AL == 0x00 or 0xE0 ---
    cmp ah, 0x48        ; Up arrow
    je .arrow_up
    cmp ah, 0x50        ; Down arrow
    je .arrow_down
    cmp ah, 0x4B        ; Left arrow
    je .arrow_left
    cmp ah, 0x4D        ; Right arrow
    je .arrow_right

    jmp .poll

.arrow_left:
    ; Rotate 90° left on vertical axis: cycle through state 0→3→2→1→0
    ; State meanings: 0=normal, 1=rotated_right_90, 2=flipped_180v, 3=rotated_left_90
    mov al, [rotation_state]
    dec al
    and al, 3           ; Keep in 0-3 range
    mov [rotation_state], al
    call render_names
    jmp .poll

.arrow_right:
    ; Rotate 90° right on vertical axis
    mov al, [rotation_state]
    inc al
    and al, 3
    mov [rotation_state], al
    call render_names
    jmp .poll

.arrow_up:
    ; 180° rotation upward on horizontal axis → toggle vertical_flip
    xor byte [vertical_flip], 1
    call render_names
    jmp .poll

.arrow_down:
    ; 180° rotation downward on horizontal axis → toggle vertical_flip
    xor byte [vertical_flip], 1
    call render_names
    jmp .poll

.quit:
    ret

; =============================================================================
; INIT GAME STATE
; Randomize position, reset rotation
; =============================================================================
init_game_state:
    ; Generate random position
    call rand_byte
    ; Col: keep in 0..49 (ANDRES is 30 cols wide, 80-30=50)
    xor ah, ah
    mov bl, 50
    div bl              ; AH = remainder (0..49)
    mov [name_col], ah

    call rand_byte
    ; Row: keep in 1..8
    ; ANDRES occupies rows name_row+0..name_row+4
    ; MARCO  occupies rows name_row+7..name_row+11
    ; Bottom pixel: name_row + 11 + 4 = name_row + 15 <= 23  → name_row <= 8
    xor ah, ah
    mov bl, 8
    div bl              ; AH = remainder (0..7)
    inc ah              ; shift to 1..8
    mov [name_row], ah

    mov byte [rotation_state], 0
    mov byte [vertical_flip], 0
    ret

; =============================================================================
; RENDER NAMES
; Clears screen, then draws the two names based on current state.
; =============================================================================
render_names:
    call clear_screen

    ; Draw status bar at bottom
    mov si, str_status
    mov dh, 23
    mov dl, 0
    call print_at

    ; Pick which name arrays to use based on rotation_state and vertical_flip
    mov al, [rotation_state]
    mov ah, [vertical_flip]

    ; We have 4 horizontal rotation states × 2 vertical flip states = 8 render modes
    ; For simplicity we implement them by transforming the glyph rendering

    ; Base row/col from state
    mov bl, [name_row]
    mov bh, [name_col]

    ; Draw NAME1 block letters
    push bx
    call draw_name1
    pop bx

    ; Draw NAME2 below NAME1 (or transformed)
    push bx
    call draw_name2
    pop bx

    ret

; draw_name1: draws NAME1 "ANDRES" starting at [name_row],[name_col]
; draw_name2: draws NAME2 "MARCO"  starting at [name_row+7],[name_col]
; Each letter is 5 rows × 4 cols of block characters.

; --- Glyph rendering engine ---
; draw_name1: draws NAME1 starting at [name_row],[name_col]
draw_name1:
    mov byte [current_row_offset], 0
    mov byte [current_col_offset], 0

    ; NAME1: "ANDRES"
    mov si, glyph_A
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_N
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_D
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_R
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_E
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_S
    call draw_glyph

    ret

; draw_name2: draws NAME2 on row+7 from NAME1
draw_name2:
    mov byte [current_row_offset], 7
    mov byte [current_col_offset], 0

    ; NAME2: "MARCO"
    mov si, glyph_M
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_A
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_R
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_C
    call draw_glyph
    add byte [current_col_offset], 5

    mov si, glyph_O
    call draw_glyph

    ret

; =============================================================================
; DRAW GLYPH
; SI = pointer to 5×4 glyph data (5 rows, 4 cols, 1 byte per cell: 0=space, 1=block)
; Applies rotation_state and vertical_flip transformations.
; =============================================================================
draw_glyph:
    push si
    push bx
    push cx
    push dx

    mov al, [rotation_state]
    mov ah, [vertical_flip]

    ; For each of the 5 rows and 4 cols, compute transformed (r,c) and plot
    mov byte [glyph_row_iter], 0

.row_loop:
    mov al, [glyph_row_iter]
    cmp al, 5
    jge .glyph_done

    mov byte [glyph_col_iter], 0

.col_loop:
    mov al, [glyph_col_iter]
    cmp al, 4
    jge .next_row

    ; Read glyph cell: cell = glyph_data[row*4 + col]
    mov al, [glyph_row_iter]
    mov bl, 4
    mul bl              ; AX = row * 4  (max 16, fits in AL → AH = 0)
    add al, [glyph_col_iter]
    xor ah, ah
    mov bx, si
    add bx, ax
    mov cl, [bx]        ; CL = cell value (0 or 1)

    ; Skip transform entirely for empty cells — also avoids CL being
    ; clobbered by transform_glyph_coords when vertical_flip is active.
    cmp cl, 0
    je .skip_pixel

    ; Compute transformed screen row and col
    call transform_glyph_coords  ; returns screen_r in DH, screen_c in DL

    ; Print block character at (screen_r, screen_c)
    push cx
    mov ah, 0x02        ; Set cursor position
    xor bh, bh
    int 0x10

    mov ah, 0x09        ; Write character with attribute (preserves cursor)
    mov al, 0xDB        ; Full block █
    mov bl, 0x0A        ; Attribute: bright green on black
    mov cx, 1           ; Write 1 character
    int 0x10
    pop cx

.skip_pixel:
    inc byte [glyph_col_iter]
    jmp .col_loop

.next_row:
    inc byte [glyph_row_iter]
    jmp .row_loop

.glyph_done:
    pop dx
    pop cx
    pop bx
    pop si
    ret

; =============================================================================
; TRANSFORM GLYPH COORDS
; Input:  glyph_row_iter = source row (0-4), glyph_col_iter = source col (0-3)
;         rotation_state, vertical_flip, name_row, name_col,
;         current_row_offset, current_col_offset
; Output: DH = final screen row, DL = final screen col
; Transformation table:
;   rotation_state 0 (normal):      out_r=r,    out_c=c
;   rotation_state 1 (right 90°):   out_r=c,    out_c=4-r  (rotate CW)
;   rotation_state 2 (180° horiz):  out_r=4-r,  out_c=3-c  (full flip)
;   rotation_state 3 (left 90°):    out_r=3-c,  out_c=r    (rotate CCW)
;   vertical_flip=1: additionally flip rows: out_r = max_r - out_r
; =============================================================================
transform_glyph_coords:
    mov al, [glyph_row_iter]    ; src_r
    mov bl, [glyph_col_iter]    ; src_c

    mov cl, [rotation_state]
    cmp cl, 0
    je .rot0
    cmp cl, 1
    je .rot1
    cmp cl, 2
    je .rot2
    ; else rot3

.rot3:  ; Left 90°: out_r=3-c, out_c=r
    mov ah, 3
    sub ah, bl          ; out_r = 3 - src_c
    mov bh, al          ; out_c = src_r
    jmp .apply_vflip

.rot0:  ; Normal: out_r=r, out_c=c
    mov ah, al          ; out_r = src_r
    mov bh, bl          ; out_c = src_c
    jmp .apply_vflip

.rot1:  ; Right 90°: out_r=c, out_c=4-r
    mov ah, bl          ; out_r = src_c
    mov bh, 4
    sub bh, al          ; out_c = 4 - src_r
    jmp .apply_vflip

.rot2:  ; 180°: out_r=4-r, out_c=3-c
    mov ah, 4
    sub ah, al          ; out_r = 4 - src_r
    mov bh, 3
    sub bh, bl          ; out_c = 3 - src_c
    jmp .apply_vflip

.apply_vflip:
    cmp byte [vertical_flip], 0
    je .no_vflip
    ; Flip: out_r = 4 - out_r
    mov cl, 4
    sub cl, ah
    mov ah, cl

.no_vflip:
    ; Add base position: name_row + current_row_offset + out_r
    xor dh, dh
    mov dh, [name_row]
    add dh, [current_row_offset]
    add dh, ah

    ; Col: name_col + current_col_offset + out_c
    mov dl, [name_col]
    add dl, [current_col_offset]
    add dl, bh

    ; Clamp to screen boundaries
    cmp dh, 23
    jb .row_ok
    mov dh, 23
.row_ok:
    cmp dl, 79
    jb .col_ok
    mov dl, 79
.col_ok:
    ret

; =============================================================================
; CLEAR SCREEN  (BIOS INT 10h)
; =============================================================================
clear_screen:
    mov ah, 0x06        ; Scroll up
    xor al, al          ; Scroll entire window (0 = clear)
    xor cx, cx          ; Upper-left: row 0, col 0
    mov dh, 24          ; Lower-right row
    mov dl, 79          ; Lower-right col
    mov bh, 0x07        ; Fill attribute: white on black
    int 0x10

    ; Move cursor to top-left
    mov ah, 0x02
    xor bh, bh
    xor dx, dx
    int 0x10
    ret

; =============================================================================
; PRINT_AT: print null-terminated string at (DH=row, DL=col)
; =============================================================================
print_at:
    push si
    push dx
    ; Set cursor
    mov ah, 0x02
    xor bh, bh
    int 0x10

.next:
    lodsb
    cmp al, 0
    je .done
    mov ah, 0x0E
    xor bh, bh
    int 0x10
    jmp .next
.done:
    pop dx
    pop si
    ret

; =============================================================================
; SIMPLE LCG PSEUDO-RANDOM NUMBER GENERATOR
; Returns a pseudo-random byte in AL
; =============================================================================
rand_byte:
    push dx                 ; mul cx will clobber DX — preserve it
    mov ax, [rng_seed]
    mov cx, 6364            ; LCG multiplier
    mul cx                  ; DX:AX = AX * CX  (DX = high word, discarded)
    add ax, 1013            ; + LCG increment
    mov [rng_seed], ax
    mov al, ah              ; Return high byte (better distribution than low)
    xor ah, ah
    pop dx
    ret

; =============================================================================
; REBOOT
; =============================================================================
reboot:
    ; BIOS warm reboot via triple fault / jump to FFFF:0000
    db 0xEA             ; JMP FAR
    dw 0x0000           ; Offset
    dw 0xFFFF           ; Segment → FFFF:0000

; =============================================================================
; MUTABLE GAME STATE
; =============================================================================
rotation_state  db 0    ; 0=normal, 1=right90, 2=180, 3=left90
vertical_flip   db 0    ; 0=no flip, 1=vertically flipped
name_row        db 5    ; Starting row for name rendering
name_col        db 10   ; Starting col for name rendering
rng_seed        dw 0    ; PRNG seed

; Glyph iteration variables (used inside draw_glyph)
glyph_row_iter      db 0
glyph_col_iter      db 0
current_row_offset  db 0
current_col_offset  db 0

; =============================================================================
; STRINGS
; =============================================================================
str_title       db "=== MY NAME: ANDRES & MARCO ===", 0
str_confirm     db "Press Y to start or ESC to exit", 0
str_controls    db "Arrow keys: rotate | R: restart | ESC: quit", 0
str_status      db " [Arrows]=Rotate  [R]=Restart  [ESC]=Quit ", 0

; =============================================================================
; BLOCK-LETTER GLYPHS (5 rows x 4 cols, 1=filled, 0=empty)
; Each glyph is 20 bytes.
; Used by ANDRES (A N D R E S) and MARCO (M A R C O)
; =============================================================================

; Letter A
glyph_A:
    db 0,1,1,0
    db 1,0,0,1
    db 1,1,1,1
    db 1,0,0,1
    db 1,0,0,1

; Letter N
glyph_N:
    db 1,0,0,1
    db 1,1,0,1
    db 1,0,1,1
    db 1,0,0,1
    db 1,0,0,1

; Letter D
glyph_D:
    db 1,1,0,0
    db 1,0,1,0
    db 1,0,0,1
    db 1,0,1,0
    db 1,1,0,0

; Letter R
glyph_R:
    db 1,1,1,0
    db 1,0,0,1
    db 1,1,1,0
    db 1,0,1,0
    db 1,0,0,1

; Letter E
glyph_E:
    db 1,1,1,1
    db 1,0,0,0
    db 1,1,1,0
    db 1,0,0,0
    db 1,1,1,1

; Letter S
glyph_S:
    db 0,1,1,1
    db 1,0,0,0
    db 0,1,1,0
    db 0,0,0,1
    db 1,1,1,0

; Letter M
glyph_M:
    db 1,0,0,1
    db 1,1,1,1
    db 1,0,0,1
    db 1,0,0,1
    db 1,0,0,1

; Letter C
glyph_C:
    db 0,1,1,1
    db 1,0,0,0
    db 1,0,0,0
    db 1,0,0,0
    db 0,1,1,1

; Letter O
glyph_O:
    db 0,1,1,0
    db 1,0,0,1
    db 1,0,0,1
    db 1,0,0,1
    db 0,1,1,0