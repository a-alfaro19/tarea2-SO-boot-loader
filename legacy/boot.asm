org 0x7C00
bits 16

start:

    ; 1. Environment Setup
    cli                         ; Disable interrupts during setup

    xor ax, ax                  ; Clear segment registers
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov sp, 0x7C00              ; Initialize stack pointer

    sti                         ; Re-enable interrupts

    mov [BOOT_DRIVE], dl        ; Save boot drive from BIOS

    ; 2. Display Welcome Message
    mov si, hello_msg           
    call print_string

load_game:

    ; 3. Read Game from Disk (Sector 2)
    mov ah, 0x02                ; BIOS read sector function
    mov al, 16                  ; Number of sectors to read
    mov ch, 0                   ; Cylinder 0
    mov cl, 2                   ; Sector 2 (Sector 1 is the bootloader)
    mov dh, 0                   ; Head 0
    mov dl, [BOOT_DRIVE]        ; Drive to read from (Boot drive)

    mov bx, 0x1000              ; Memory address to load the game

    int 0x13                    ; BIOS disk read

    ; 4. Error Handling & Validation
    jc disk_error               ; Jump if BIOS reports a read failure (Carry Flag set)

    cmp word [0x1000], 0xDEFD   ; Verify magic number at the start of loaded data
    jne validation_error        ; Jump if signature mismatch or empty file

    ; 5. Jump to loaded game
    jmp 0x0000:0x1000       

validation_error:           
    mov si, newline          
    call print_string
    mov si, msg_bad_file
    call print_string
    jmp hang

disk_error:
    mov si, newline          
    call print_string
    mov si, error_msg       
    call print_string

hang:
    jmp hang                    ; Infinite loop to halt execution


; =================
; FUNCTIONS
; =================

print_string:                   ; Routine to print null-terminated strings
    mov ah, 0x0E                ; BIOS Teletype output function

.next:
    lodsb                       ; Load next byte from DS:SI into AL
    cmp al, 0                   ; Check if it's the null terminator (0)
    je .done
    int 0x10
    jmp .next

.done:
    ret


; =================
; DATA
; =================

newline db 13,10,0
hello_msg db "Welcome to bootloader!", 0
error_msg db "Error loading game (Disk)", 0
msg_bad_file db "Invalid game file (Sign)", 0

BOOT_DRIVE db 0

times 510-($-$$) db 0           ; Pad remaining space to 510 bytes
dw 0xAA55                       ; Boot signature
