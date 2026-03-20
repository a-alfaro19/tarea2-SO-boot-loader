; =============================================================================
; game_render.asm - Screen Rendering
; CE 4303 - Principios de Sistemas Operativos
;
; Handles all visual output using BIOS INT 10h (video services).
; INT 10h is firmware — installed by the BIOS during POST, not an OS service.
;
; INT 10h functions used:
;   AH=06h  Scroll window up (used to clear screen)
;   AH=02h  Set cursor position        DH=row, DL=col, BH=page(0)
;   AH=09h  Write char + attribute     AL=char, BL=attr, CX=count, BH=page(0)
;   AH=0Eh  Teletype output            AL=char (advances cursor automatically)
;
; VGA attribute byte (BL for AH=09h):
;   Bits 7-4 = background color, bits 3-0 = foreground color
;   0x0A = bright green on black
;   0x0E = bright yellow on black
;   0x07 = white on black (normal)
;
; Coordinate system: row 0 = top, col 0 = left. Screen is 80×25 chars.
;
; Rotation states (rotation_state variable):
;   0 = normal          out_r = src_r,     out_c = src_c
;   1 = right 90°       out_r = src_c,     out_c = 4 - src_r
;   2 = 180°            out_r = 4 - src_r, out_c = 3 - src_c
;   3 = left 90°        out_r = 3 - src_c, out_c = src_r
;
; vertical_flip additionally maps: out_r = 4 - out_r
;
; Functions:
;   clear_screen        — blank the entire screen
;   print_at            — print a null-terminated string at (DH=row, DL=col)
;   render_names        — full redraw: clear + status bar + both names
;   draw_name1          — draw "ANDRES" using current state
;   draw_name2          — draw "MARCO" using current state
;   draw_glyph          — draw one 5×4 glyph (SI=glyph pointer)
;   transform_glyph_coords — compute transformed screen (DH,DL) from glyph (r,c)
; =============================================================================

; -----------------------------------------------------------------------------
; clear_screen
; Blanks the full 80×25 display using BIOS scroll function.
; After clearing, moves cursor to top-left (0,0).
; Clobbers: AX, BX, CX, DX
; -----------------------------------------------------------------------------
clear_screen:
    mov ah, 0x06        ; INT 10h: scroll window up
    xor al, al          ; AL=0 → clear entire window
    xor cx, cx          ; CH=0 (top row), CL=0 (left col)
    mov dh, 24          ; DH=24 (bottom row)
    mov dl, 79          ; DL=79 (right col)
    mov bh, 0x07        ; Fill attribute: white on black
    int 0x10

    mov ah, 0x02        ; INT 10h: set cursor position
    xor bh, bh          ; Page 0
    xor dx, dx          ; DH=0 (row 0), DL=0 (col 0)
    int 0x10
    ret

; -----------------------------------------------------------------------------
; print_at
; Prints a null-terminated string starting at screen position (DH=row, DL=col).
; SI = pointer to string.
; Clobbers: AX, BX, SI  (DX preserved)
; -----------------------------------------------------------------------------
print_at:
    push dx

    mov ah, 0x02        ; Set cursor to starting position
    xor bh, bh
    int 0x10

.next_char:
    lodsb               ; AL = *SI++
    cmp al, 0           ; Null terminator?
    je .done
    mov ah, 0x0E        ; Teletype output — prints AL and advances cursor
    xor bh, bh
    int 0x10
    jmp .next_char

.done:
    pop dx
    ret

; -----------------------------------------------------------------------------
; render_names
; Full screen redraw: clears screen, draws status bar, then both names.
; Uses current values of: rotation_state, vertical_flip, name_row, name_col.
; Clobbers: AX, BX, CX, DX, SI
; -----------------------------------------------------------------------------
render_names:
    call clear_screen

    ; Status bar on row 23
    mov si, str_status
    mov dh, 23
    mov dl, 0
    call print_at

    ; Draw "ANDRES" (name 1)
    call draw_name1

    ; Draw "MARCO" (name 2)
    call draw_name2

    ret

; -----------------------------------------------------------------------------
; draw_name1
; Draws "ANDRES" starting at [name_row], [name_col] with row_offset=0.
; Letters are spaced 5 columns apart (4 cols wide + 1 gap).
; Clobbers: AX, BX, CX, DX, SI
; -----------------------------------------------------------------------------
draw_name1:
    mov byte [current_row_offset], 0
    mov byte [current_col_offset], 0

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

; -----------------------------------------------------------------------------
; draw_name2
; Draws "MARCO" at [name_row+7], [name_col] (7 rows below name1).
; The +7 gap = 5 rows of glyphs + 2 rows of spacing.
; Clobbers: AX, BX, CX, DX, SI
; -----------------------------------------------------------------------------
draw_name2:
    mov byte [current_row_offset], 7
    mov byte [current_col_offset], 0

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

; -----------------------------------------------------------------------------
; draw_glyph
; Draws one 5×4 glyph at the current position, applying rotation and flip.
; SI = pointer to 20-byte glyph data (from game_glyphs.asm)
;
; For each cell (row 0..4, col 0..3):
;   1. Read cell value (0=empty, 1=filled)
;   2. If empty: skip (avoids unnecessary transform call)
;   3. Call transform_glyph_coords to get final screen (DH, DL)
;   4. Draw character 0xDB (full block █) with attribute 0x0A (bright green)
;
; Clobbers: AX, BX, CX, DX  (SI preserved via push/pop)
; -----------------------------------------------------------------------------
draw_glyph:
    push si

    mov byte [glyph_row_iter], 0

.row_loop:
    mov al, [glyph_row_iter]
    cmp al, 5
    jge .done

    mov byte [glyph_col_iter], 0

.col_loop:
    mov al, [glyph_col_iter]
    cmp al, 4
    jge .next_row

    ; Compute byte offset into glyph: index = row * 4 + col
    mov al, [glyph_row_iter]
    mov bl, 4
    mul bl              ; AX = row * 4  (max=16, fits in AL, so AH=0)
    add al, [glyph_col_iter]
    xor ah, ah

    ; Read the cell value
    mov bx, si          ; BX = glyph base pointer
    add bx, ax          ; BX = &glyph[row*4 + col]
    mov cl, [bx]        ; CL = cell value (0 or 1)

    ; Skip transform entirely for empty cells.
    ; IMPORTANT: we must not call transform with CL holding the cell value,
    ; because transform_glyph_coords uses CL as a scratch register internally
    ; (specifically during the vertical flip calculation). Testing here first
    ; avoids that register conflict entirely.
    cmp cl, 0
    je .skip_pixel

    ; Get the transformed screen coordinates for this pixel
    call transform_glyph_coords    ; → DH=screen_row, DL=screen_col

    ; Position cursor and draw block character
    push cx
    mov ah, 0x02        ; INT 10h: set cursor position
    xor bh, bh          ; Page 0
    int 0x10

    mov ah, 0x09        ; INT 10h: write character + attribute (cursor stays)
    mov al, 0xDB        ; Full block character █
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

.done:
    pop si
    ret

; -----------------------------------------------------------------------------
; transform_glyph_coords
; Converts a glyph-local (row, col) to a screen (row, col) by applying
; the current rotation_state and vertical_flip, then adding the base position.
;
; Inputs (from memory):
;   glyph_row_iter      — source row  (0..4)
;   glyph_col_iter      — source col  (0..3)
;   rotation_state      — 0=normal, 1=right90, 2=180, 3=left90
;   vertical_flip       — 0=none, 1=flip rows
;   name_row            — base screen row
;   name_col            — base screen col
;   current_row_offset  — added to name_row (0 for name1, 7 for name2)
;   current_col_offset  — added to name_col (letter position within name)
;
; Output:
;   DH = final screen row
;   DL = final screen col
;
; Clobbers: AX, BH, CL (AH and BH used as out_r / out_c temporaries)
; NOTE: CL is used as a scratch register in the vflip section.
;       Caller must NOT store a needed value in CL across this call.
; -----------------------------------------------------------------------------
transform_glyph_coords:
    mov al, [glyph_row_iter]    ; AL = src_r
    mov bl, [glyph_col_iter]    ; BL = src_c

    mov cl, [rotation_state]
    cmp cl, 0
    je .rot0
    cmp cl, 1
    je .rot1
    cmp cl, 2
    je .rot2
    ; Fall through to rot3

.rot3:  ; Left 90°: out_r = 3 - src_c,  out_c = src_r
    mov ah, 3
    sub ah, bl          ; AH = 3 - src_c
    mov bh, al          ; BH = src_r
    jmp .apply_vflip

.rot0:  ; Normal: out_r = src_r,  out_c = src_c
    mov ah, al          ; AH = src_r
    mov bh, bl          ; BH = src_c
    jmp .apply_vflip

.rot1:  ; Right 90°: out_r = src_c,  out_c = 4 - src_r
    mov ah, bl          ; AH = src_c
    mov bh, 4
    sub bh, al          ; BH = 4 - src_r
    jmp .apply_vflip

.rot2:  ; 180°: out_r = 4 - src_r,  out_c = 3 - src_c
    mov ah, 4
    sub ah, al          ; AH = 4 - src_r
    mov bh, 3
    sub bh, bl          ; BH = 3 - src_c

.apply_vflip:
    cmp byte [vertical_flip], 0
    je .no_vflip
    mov cl, 4           ; CL used as scratch here — see NOTE above
    sub cl, ah          ; CL = 4 - out_r
    mov ah, cl          ; AH = flipped out_r

.no_vflip:
    ; Final screen row = name_row + current_row_offset + out_r
    mov dh, [name_row]
    add dh, [current_row_offset]
    add dh, ah

    ; Final screen col = name_col + current_col_offset + out_c
    mov dl, [name_col]
    add dl, [current_col_offset]
    add dl, bh

    ; Clamp to safe screen area (rows 0..22, cols 0..79)
    ; Row 23 is reserved for the status bar
    cmp dh, 22
    jbe .row_ok
    mov dh, 22
.row_ok:
    cmp dl, 79
    jbe .col_ok
    mov dl, 79
.col_ok:
    ret

; -----------------------------------------------------------------------------
; Render module data
; -----------------------------------------------------------------------------

; Glyph iteration state (written during draw_glyph)
glyph_row_iter      db 0
glyph_col_iter      db 0

; Letter position state (written by draw_name1 / draw_name2)
current_row_offset  db 0
current_col_offset  db 0

; Strings
str_status  db " [<][>]=Rotate  [^][v]=Flip  [R]=Restart  [ESC]=Quit ", 0