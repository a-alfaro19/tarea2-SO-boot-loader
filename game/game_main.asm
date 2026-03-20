; =============================================================================
; game_main.asm - "My Name" Bootable Game  (Legacy / Real Mode entry)
; CE 4303 - Principios de Sistemas Operativos
;
; This is the root file. NASM assembles this file and pulls in all modules
; via %include, producing a single flat binary: game.bin
;
; Build:
;   nasm -f bin game_main.asm -o game.bin
;
; Memory layout at runtime (legacy boot):
;   0x0000:0x7C00  boot.asm (MBR bootloader)
;   0x0000:0x1000  game.bin loaded here by boot.asm  ← we execute from here
;   0x0000:0x7000  stack (grows downward, safe gap between stack and code)
;
; First two bytes MUST be the magic word 0xDEFD so boot.asm's validation
; check passes:  cmp word [0x1000], 0xDEFD
; NASM stores 'dw 0xDEFD' as bytes [0xFD, 0xDE] (little-endian), which the
; CPU reads back as the 16-bit word 0xDEFD. ✓
;
; Modules included (order matters — data labels must exist before use):
;   game_rand.asm    PRNG: seed_rng, rand_byte, rng_seed
;   game_input.asm   Keyboard: poll_key, wait_key
;   game_render.asm  Screen: clear_screen, print_at, render_names, draw_glyph...
;   game_glyphs.asm  Glyph bitmaps: glyph_A, glyph_N, ... glyph_O
; =============================================================================

    org 0x1000          ; Binary loads at this address by boot.asm
    bits 16             ; Real mode — 16-bit instructions

; -----------------------------------------------------------------------------
; Magic signature (MUST be the very first two bytes of the binary)
; boot.asm checks: cmp word [0x1000], 0xDEFD
; -----------------------------------------------------------------------------
    dw 0xDEFD


; =============================================================================
; ENTRY POINT
; =============================================================================
game_start:
    ; Reinitialize segment registers — boot.asm may have left them in any state
    cli                         ; Disable interrupts while setting up segments
    xor ax, ax
    mov ds, ax                  ; DS = 0x0000
    mov es, ax                  ; ES = 0x0000 (needed for string instructions)
    mov ss, ax                  ; SS = 0x0000
    mov sp, 0x7000              ; Stack at 0x7000, grows down — safely below our
    sti                         ; code at 0x1000 and boot sector at 0x7C00

    call seed_rng               ; Seed PRNG from BIOS timer (INT 0x1A)

    call show_confirm_screen    ; Show welcome screen, wait for Y/ESC

    call game_loop              ; Run main game loop (returns on ESC)

    jmp reboot                  ; Clean exit — jump to BIOS warm reboot vector

; =============================================================================
; CONFIRMATION SCREEN
; Displays title and controls. Waits for 'Y' to start or ESC to quit.
; =============================================================================
show_confirm_screen:
    call clear_screen

    mov si, str_title
    mov dh, 8           ; Row 8 — vertically centered
    mov dl, 24          ; Col 24 — horizontally centered
    call print_at

    mov si, str_press_y
    mov dh, 12
    mov dl, 24
    call print_at

    mov si, str_controls_hint
    mov dh, 14
    mov dl, 16
    call print_at

.wait_key:
    call wait_key       ; Blocking read → AH=scan, AL=ASCII

    cmp al, 'y'
    je .confirmed
    cmp al, 'Y'
    je .confirmed
    cmp al, 0x1B        ; ESC scan: also AL=0x1B for ESC ASCII
    je reboot           ; ESC on confirm screen → reboot immediately
    jmp .wait_key

.confirmed:
    ret

; =============================================================================
; MAIN GAME LOOP
; Initializes game state, renders, then polls for input in a tight loop.
; Returns (via 'ret') when the player presses ESC.
; =============================================================================
game_loop:
    call init_game_state        ; Randomize position, reset rotation
    call render_names           ; Draw both names on screen

.poll:
    call poll_key               ; Non-blocking key check → ZF=1 if no key
    jz .poll                    ; No key yet — keep polling

    ; AH = scan code, AL = ASCII character

    ; --- ESC: end game ---
    cmp al, 0x1B
    je .quit

    ; --- R / r: restart with new random position ---
    cmp al, 'r'
    je game_loop
    cmp al, 'R'
    je game_loop

    ; --- Arrow keys (extended): AL = 0x00 or 0xE0, AH = scan code ---
    cmp ah, 0x4B        ; Left arrow scan code
    je .rotate_left
    cmp ah, 0x4D        ; Right arrow scan code
    je .rotate_right
    cmp ah, 0x48        ; Up arrow scan code
    je .flip_vertical
    cmp ah, 0x50        ; Down arrow scan code
    je .flip_vertical   ; Up and down both toggle the same flip bit

    jmp .poll           ; Unknown key — ignore

.rotate_left:
    ; Cycle rotation: 0 → 3 → 2 → 1 → 0 (counter-clockwise)
    mov al, [rotation_state]
    dec al
    and al, 3           ; Wrap: -1 mod 4 = 3 (AND with 3 works for power-of-2)
    mov [rotation_state], al
    call render_names
    jmp .poll

.rotate_right:
    ; Cycle rotation: 0 → 1 → 2 → 3 → 0 (clockwise)
    mov al, [rotation_state]
    inc al
    and al, 3           ; Wrap: 4 mod 4 = 0
    mov [rotation_state], al
    call render_names
    jmp .poll

.flip_vertical:
    ; Toggle vertical flip (both up and down arrow do this — each press flips)
    xor byte [vertical_flip], 1
    call render_names
    jmp .poll

.quit:
    ret

; =============================================================================
; INIT GAME STATE
; Picks a random screen position for the names and resets rotation.
;
; Safe column range: 0..49
;   ANDRES is 6 letters × 5 cols = 30 pixels wide → 80 - 30 = 50 → max col=49
;
; Safe row range: 1..8
;   ANDRES: rows name_row..name_row+4
;   MARCO:  rows name_row+7..name_row+11  (7 row offset + 4 rows tall)
;   Bottom pixel: name_row + 11 + 4 = name_row + 15
;   Row 23 = status bar (reserved) → name_row + 15 ≤ 22 → name_row ≤ 7
;   We use name_row = (rand % 7) + 1, giving range 1..7
; =============================================================================
init_game_state:
    call rand_byte
    xor ah, ah
    mov bl, 50
    div bl              ; AH = rand mod 50  (0..49)
    mov [name_col], ah

    call rand_byte
    xor ah, ah
    mov bl, 7
    div bl              ; AH = rand mod 7  (0..6)
    inc ah              ; → 1..7
    mov [name_row], ah

    mov byte [rotation_state], 0
    mov byte [vertical_flip], 0
    ret

; =============================================================================
; REBOOT
; Jumps to the BIOS reset vector at FFFF:0000, which triggers a warm reboot.
; Encoded as a raw far jump (JMP FAR ptr) because NASM's jmp syntax in
; 16-bit real mode doesn't support segment:offset literals directly.
; =============================================================================
reboot:
    db 0xEA             ; Opcode: JMP FAR imm16:imm16
    dw 0x0000           ; Offset
    dw 0xFFFF           ; Segment → jumps to FFFF:0000 (BIOS reset)

; =============================================================================
; GAME STATE (mutable variables)
; =============================================================================
rotation_state  db 0    ; 0=normal, 1=right 90°, 2=180°, 3=left 90°
vertical_flip   db 0    ; 0=no flip, 1=rows flipped
name_row        db 3    ; Current top row of name block (randomized on start)
name_col        db 10   ; Current left col of name block (randomized on start)

; =============================================================================
; STRINGS (confirmation screen only — render strings live in game_render.asm)
; =============================================================================
str_title           db "=== MY NAME: ANDRES & MARCO ===", 0
str_press_y         db "Press Y to play or ESC to exit", 0
str_controls_hint   db "[Arrows]=Rotate  [R]=Restart  [ESC]=Quit", 0

; =============================================================================
; MODULE INCLUDES
; These are textual includes — NASM pastes each file's content here in order.
; All labels from included files are visible to all other files.
; The final binary is assembled as one flat unit.
; =============================================================================
%include "game_rand.asm"
%include "game_input.asm"
%include "game_render.asm"
%include "game_glyphs.asm"