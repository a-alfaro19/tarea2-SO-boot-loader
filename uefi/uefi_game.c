/*
 * uefi_game.c — UEFI C bootloader for the "My Name" game
 * CE 4303 - Principios de Sistemas Operativos
 *
 * This EFI application:
 *   1. Reads game.bin from the ESP (same FAT32 partition as BOOTX64.EFI)
 *   2. Loads it at physical address 0x10000 (64KB mark, safe in low memory)
 *   3. Exits Boot Services
 *   4. Uses a real-mode trampoline to switch from 64-bit long mode back to
 *      16-bit real mode and jumps into the game
 *
 * game.bin starts with dw 0xDEFD as a magic number (validated before jump).
 */

#include <efi.h>
#include <efilib.h>

#define GAME_LOAD_ADDR  0x10000ULL   /* physical address to load game.bin */
#define GAME_MAGIC      0xDEFD       /* first word of game.bin */

/* ============================================================================
 * Real-mode trampoline — assembled bytes that:
 *   - disable protected mode (clear PE bit in CR0)
 *   - far-jump to real mode
 *   - set up segments
 *   - jump to game at 0x1000:0000
 *
 * This blob is copied to a fixed low-memory address and executed.
 * We use 0x8000 as the trampoline location (safe, below our game at 0x10000).
 * ========================================================================== */
static const UINT8 trampoline[] = {
    /* CLI */
    0xFA,
    /* MOV EAX, CR0 */
    0x0F, 0x20, 0xC0,
    /* AND EAX, 0x7FFFFFFE  (clear PE bit 0 and PG bit 31) */
    0x25, 0xFE, 0xFF, 0xFF, 0x7F,
    /* MOV CR0, EAX */
    0x0F, 0x22, 0xC0,
    /* Far jump to flush pipeline and enter real mode: JMP 0x0000:real_mode */
    /* 0xEA <offset16> <seg16> — offset=16 bytes from start of trampoline+16 */
    0xEA, 0x10, 0x00, 0x00, 0x00,
    /* --- real mode code starts here (offset 16 = 0x10) --- */
    /* XOR AX, AX */
    0x31, 0xC0,
    /* MOV DS, AX */
    0x8E, 0xD8,
    /* MOV ES, AX */
    0x8E, 0xC0,
    /* MOV SS, AX */
    0x8E, 0xD0,
    /* MOV SP, 0x7000 */
    0xBC, 0x00, 0x70,
    /* STI */
    0xFB,
    /* Far jump to game: JMP 0x1000:0x0000 */
    0xEA, 0x00, 0x00, 0x00, 0x10,
};

/* ============================================================================
 * Read game.bin from the ESP into memory at GAME_LOAD_ADDR
 * ========================================================================== */
static EFI_STATUS load_game(EFI_HANDLE ImageHandle,
                             EFI_SYSTEM_TABLE *ST)
{
    /* Get the loaded image to find which device we booted from */
    EFI_GUID lip_guid = EFI_LOADED_IMAGE_PROTOCOL_GUID;
    EFI_LOADED_IMAGE *loaded = NULL;
    EFI_STATUS s = ST->BootServices->HandleProtocol(
        ImageHandle, &lip_guid, (VOID **)&loaded);
    if (EFI_ERROR(s)) {
        Print(L"LoadedImage protocol failed: %r\n", s);
        return s;
    }

    /* Get the filesystem on the boot device */
    EFI_GUID sfsp_guid = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = NULL;
    s = ST->BootServices->HandleProtocol(
        loaded->DeviceHandle, &sfsp_guid, (VOID **)&fs);
    if (EFI_ERROR(s)) {
        Print(L"FileSystem protocol failed: %r\n", s);
        return s;
    }

    /* Open root directory */
    EFI_FILE_PROTOCOL *root = NULL;
    s = fs->OpenVolume(fs, &root);
    if (EFI_ERROR(s)) {
        Print(L"OpenVolume failed: %r\n", s);
        return s;
    }

    /* Open game.bin */
    EFI_FILE_PROTOCOL *file = NULL;
    s = root->Open(root, &file, L"game.bin",
                   EFI_FILE_MODE_READ, 0);
    if (EFI_ERROR(s)) {
        Print(L"Cannot open game.bin: %r\n", s);
        Print(L"Make sure game.bin is in the root of the ESP.\n");
        root->Close(root);
        return s;
    }

    /* Read game.bin directly into GAME_LOAD_ADDR */
    UINTN size = 16384; /* 16KB max — way more than enough */
    VOID *dest = (VOID *)GAME_LOAD_ADDR;
    s = file->Read(file, &size, dest);
    file->Close(file);
    root->Close(root);

    if (EFI_ERROR(s)) {
        Print(L"Read failed: %r\n", s);
        return s;
    }

    Print(L"Loaded game.bin: %d bytes at 0x%lx\n", (UINTN)size,
          (UINTN)GAME_LOAD_ADDR);

    /* Validate magic */
    UINT16 magic = *(UINT16 *)dest;
    if (magic != GAME_MAGIC) {
        Print(L"Bad magic: 0x%04x (expected 0x%04x)\n",
              (UINTN)magic, (UINTN)GAME_MAGIC);
        return EFI_LOAD_ERROR;
    }

    Print(L"Magic OK.\n");
    return EFI_SUCCESS;
}

/* ============================================================================
 * EFI ENTRY POINT
 * ========================================================================== */
EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle,
                            EFI_SYSTEM_TABLE *SystemTable)
{
    InitializeLib(ImageHandle, SystemTable);
    SystemTable->BootServices->SetWatchdogTimer(0, 0, 0, NULL);

    Print(L"\r\n=== MY NAME: UEFI Loader ===\r\n");
    Print(L"Loading game.bin...\r\n");

    EFI_STATUS s = load_game(ImageHandle, SystemTable);
    if (EFI_ERROR(s)) {
        Print(L"\r\nFailed to load game. Press any key.\r\n");
        UINTN idx;
        SystemTable->BootServices->WaitForEvent(
            1, &SystemTable->ConIn->WaitForKey, &idx);
        EFI_INPUT_KEY k;
        SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &k);
        return s;
    }

    Print(L"Preparing trampoline...\r\n");

    /* Copy trampoline to 0x8000 */
    UINT8 *tramp = (UINT8 *)0x8000ULL;
    for (UINTN i = 0; i < sizeof(trampoline); i++)
        tramp[i] = trampoline[i];

    Print(L"Exiting boot services and jumping to game...\r\n");

    /* Get memory map for ExitBootServices */
    UINTN mapSize = 0, mapKey = 0, descSize = 0;
    UINT32 descVer = 0;
    SystemTable->BootServices->GetMemoryMap(
        &mapSize, NULL, &mapKey, &descSize, &descVer);
    mapSize += 2 * descSize;
    EFI_MEMORY_DESCRIPTOR *map = NULL;
    SystemTable->BootServices->AllocatePool(
        EfiLoaderData, mapSize, (VOID **)&map);
    SystemTable->BootServices->GetMemoryMap(
        &mapSize, map, &mapKey, &descSize, &descVer);
    SystemTable->BootServices->ExitBootServices(ImageHandle, mapKey);

    /* Disable interrupts, copy trampoline, jump */
    /* At this point we're in 64-bit long mode with no OS.
     * The trampoline at 0x8000 will switch us to real mode
     * and jump to the game at 0x1000:0000 (phys 0x10000).
     *
     * We adjust the game's org: game.bin is loaded at 0x10000
     * but it was assembled with org 0x1000. So we jump 0x1000:0x0000
     * which = physical 0x10000. The game's internal offsets
     * (labels, data) are relative to 0x1000 segment base, which
     * means they resolve to physical 0x10000+offset. Correct.
     *
     * But wait — game.bin has org 0x1000, meaning all absolute
     * addresses inside it are offset from 0x1000. If we load it
     * at physical 0x10000 and set CS=0x1000, then:
     *   physical = CS*16 + IP = 0x1000*16 + addr = 0x10000 + addr ✓
     */

    /* Jump to trampoline via function pointer */
    typedef void (*JumpFn)(void);
    JumpFn jump = (JumpFn)0x8000ULL;
    jump();

    /* Never reached */
    return EFI_SUCCESS;
}
