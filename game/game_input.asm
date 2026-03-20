; =============================================================================
; game_input.asm - Keyboard Input Handler
; CE 4303 - Principios de Sistemas Operativos
;
; Reads keypresses using BIOS INT 16h, which is firmware — not an OS service.
; The BIOS keyboard handler is installed during POST and stays resident.
;
; INT 16h function reference:
;   AH=00h  Wait for keypress and read it   → AH=scan code, AL=ASCII char
;   AH=01h  Check keystroke buffer (no wait) → ZF=1 if empty, ZF=0 if key ready
;             If ZF=0: AH=scan code, AL=ASCII (key is NOT removed from buffer)
;
; Arrow key scan codes (AL=0x00 or 0xE0 for extended keys):
;   0x48 = Up     0x50 = Down     0x4B = Left     0x4D = Right
;
; Functions:
;   poll_key — non-blocking check; returns key in AH/AL or ZF=1 if none
;   wait_key — blocking; waits until a key is pressed, returns in AH/AL
; =============================================================================

; -----------------------------------------------------------------------------
; poll_key
; Non-blocking keypress check.
; Returns: ZF=1  if no key is waiting (caller should loop or skip)
;          ZF=0  if a key is ready: AH=scan code, AL=ASCII character
; Clobbers: AX
; -----------------------------------------------------------------------------
poll_key:
    mov ah, 0x01        ; INT 16h: peek at keyboard buffer (non-destructive)
    int 0x16            ; ZF=1 → buffer empty, ZF=0 → key available
    jz .empty           ; If empty, return with ZF=1

    ; Key is waiting — consume it from the buffer
    mov ah, 0x00
    int 0x16            ; AH=scan code, AL=ASCII
    ; ZF is now 0 (AL is non-zero for most keys; for arrows AL=0 but we
    ; test AH in the caller, so this is fine)
    ; Force ZF=0 so caller knows a key was returned
    or ax, ax           ; sets ZF=0 if AX != 0 (arrows: AH!=0 so always true)
    ret

.empty:
    ; ZF=1 already set by INT 16h AH=01h — just return
    ret

; -----------------------------------------------------------------------------
; wait_key
; Blocking keypress read. Waits until a key is pressed.
; Returns: AH=scan code, AL=ASCII character
; Clobbers: AX
; -----------------------------------------------------------------------------
wait_key:
    mov ah, 0x00        ; INT 16h: wait for and read keypress
    int 0x16            ; AH=scan code, AL=ASCII
    ret