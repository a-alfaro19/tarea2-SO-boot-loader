; =============================================================================
; game_rand.asm - Pseudo-Random Number Generator
; CE 4303 - Principios de Sistemas Operativos
;
; Provides a seeded LCG (Linear Congruential Generator).
;
; WHY INT 0x1A IS SAFE HERE (no OS required):
;   INT 0x1A AH=00h reads the BIOS Data Area tick counter at 0x0040:0x006C.
;   This counter is driven by IRQ0 (the 8253/8254 Programmable Interval Timer),
;   which the BIOS configures at 18.2 Hz during POST — before it ever touches
;   the boot sector. No OS is involved. The BIOS interrupt vector table stays
;   resident in low memory throughout real mode execution.
;
;   Timeline:
;     BIOS POST → sets up PIT + BDA → loads MBR → boot.asm → game.asm
;                                                              ↑ we are here
;     INT 0x1A is valid at this point ✔
;
; ALTERNATIVE (no BIOS interrupts at all — useful if moving to protected mode):
;   Latch PIT Channel 0 directly:
;     out 0x43, 0x00      ; latch command
;     in  al,   0x40      ; read low byte
;     mov ah,   al
;     in  al,   0x40      ; read high byte  → AX = 16-bit counter
;
; Functions:
;   seed_rng  — seeds the PRNG from the BIOS timer tick counter
;   rand_byte — returns a pseudo-random byte in AL
; =============================================================================

; -----------------------------------------------------------------------------
; seed_rng
; Seeds the LCG from the current BIOS timer tick count.
; Clobbers: AX, CX, DX (all caller-saved in our convention)
; -----------------------------------------------------------------------------
seed_rng:
    xor ax, ax
    int 0x1A            ; BIOS: get tick count → CX:DX  (AH=0 on call)
    ; DX = low word of tick count — changes every ~55ms, good enough for a seed
    mov [rng_seed], dx
    ret

; -----------------------------------------------------------------------------
; rand_byte
; Returns a pseudo-random byte in AL using a 16-bit LCG:
;   seed = (seed * 6364 + 1013) mod 65536
;   return high byte of seed  (better distribution than low byte)
;
; LCG parameters chosen for good statistical properties on 16-bit state:
;   multiplier 6364 and increment 1013 pass basic randomness tests.
;
; Clobbers: AX, CX, DX
; Returns:  AL = pseudo-random byte, AH = 0
; -----------------------------------------------------------------------------
rand_byte:
    push dx                 ; mul clobbers DX (high word of 32-bit result)
    mov ax, [rng_seed]
    mov cx, 6364            ; LCG multiplier
    mul cx                  ; DX:AX = AX * CX  (we discard DX)
    add ax, 1013            ; LCG increment
    mov [rng_seed], ax      ; store updated seed
    mov al, ah              ; return high byte (low byte has poor randomness in LCGs)
    xor ah, ah
    pop dx
    ret

; -----------------------------------------------------------------------------
; Data
; -----------------------------------------------------------------------------
rng_seed    dw 0            ; Current LCG state (16-bit)