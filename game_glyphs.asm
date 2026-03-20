; =============================================================================
; game_glyphs.asm - Block Letter Glyph Bitmaps
; CE 4303 - Principios de Sistemas Operativos
;
; Each glyph is a 5-row × 4-column bitmap stored as 20 bytes.
; A value of 1 means "draw a block here", 0 means "leave empty".
; Bytes are stored in row-major order: glyph[row * 4 + col]
;
; Grid reference (r=row, c=col):
;
;   c→  0 1 2 3
;   r0  . # # .
;   r1  # . . #
;   r2  # # # #   ← example: letter A
;   r3  # . . #
;   r4  # . . #
;
; Letters used:
;   ANDRES → A N D R E S
;   MARCO  → M A R C O
;   Full set needed: A N D R E S M C O  (9 unique letters)
;
; Visualizations of each glyph (# = filled, . = empty):
;
;   A        N        D        R        E
;   .##.     #..#     ##..     ###.     ####
;   #..#     ##.#     #.#.     #..#     #...
;   ####     #.##     #..#     ###.     ###.
;   #..#     #..#     #.#.     #.#.     #...
;   #..#     #..#     ##..     #..#     ####
;
;   S        M        C        O
;   .###     #..#     .###     .##.
;   #...     ####     #...     #..#
;   .##.     #..#     #...     #..#
;   ...#     #..#     #...     #..#
;   ###.     #..#     .###     .##.
; =============================================================================

; Letter A  (used in: ANDRES position 0, MARCO position 1)
glyph_A:
    db 0,1,1,0
    db 1,0,0,1
    db 1,1,1,1
    db 1,0,0,1
    db 1,0,0,1

; Letter N  (used in: ANDRES position 1)
glyph_N:
    db 1,0,0,1
    db 1,1,0,1
    db 1,0,1,1
    db 1,0,0,1
    db 1,0,0,1

; Letter D  (used in: ANDRES position 2)
glyph_D:
    db 1,1,0,0
    db 1,0,1,0
    db 1,0,0,1
    db 1,0,1,0
    db 1,1,0,0

; Letter R  (used in: ANDRES position 3, MARCO position 2)
glyph_R:
    db 1,1,1,0
    db 1,0,0,1
    db 1,1,1,0
    db 1,0,1,0
    db 1,0,0,1

; Letter E  (used in: ANDRES position 4)
glyph_E:
    db 1,1,1,1
    db 1,0,0,0
    db 1,1,1,0
    db 1,0,0,0
    db 1,1,1,1

; Letter S  (used in: ANDRES position 5)
glyph_S:
    db 0,1,1,1
    db 1,0,0,0
    db 0,1,1,0
    db 0,0,0,1
    db 1,1,1,0

; Letter M  (used in: MARCO position 0)
glyph_M:
    db 1,0,0,1
    db 1,1,1,1
    db 1,0,0,1
    db 1,0,0,1
    db 1,0,0,1

; Letter C  (used in: MARCO position 3)
glyph_C:
    db 0,1,1,1
    db 1,0,0,0
    db 1,0,0,0
    db 1,0,0,0
    db 0,1,1,1

; Letter O  (used in: MARCO position 4)
glyph_O:
    db 0,1,1,0
    db 1,0,0,1
    db 1,0,0,1
    db 1,0,0,1
    db 0,1,1,0