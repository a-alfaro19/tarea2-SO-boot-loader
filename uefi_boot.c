#include <efi.h>
#include <efilib.h>
#include <efiapi.h>

// Game function definition
typedef void (*game_entry_t)(void);

/**
 * @brief Loads the game from disk and runs it.
 *
 * @param SystemTable Access to UEFI features.
 * @param ImageHandle Loaded program identifier.
 */
EFI_STATUS load_game_from_disk(EFI_SYSTEM_TABLE *SystemTable,
                               EFI_HANDLE ImageHandle)
{
    EFI_STATUS Status;
    EFI_LOADED_IMAGE *LoadedImage = NULL;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *FileSystem = NULL;
    EFI_FILE_HANDLE RootDir, GameFile;
    UINT64 GameSize = 0;
    VOID *GameBuffer = NULL;

    // ===================== Get loaded image protocol ====================
    Status = SystemTable->BootServices->HandleProtocol(
        ImageHandle,
        &gEfiLoadedImageProtocolGuid,
        (VOID **)&LoadedImage);
    if (EFI_ERROR(Status))
    {
        Print(L"LoadedImage Error: %r\n", Status);
        return Status;
    }

    // ===================== Get file system from device ===================
    Status = SystemTable->BootServices->HandleProtocol(
        LoadedImage->DeviceHandle,
        &gEfiSimpleFileSystemProtocolGuid,
        (VOID **)&FileSystem);
    if (EFI_ERROR(Status))
    {
        Print(L"FileSystem Error: %r\n", Status);
        return Status;
    }

    // ===================== Open root directory of the volume ("/") ====================
    Status = FileSystem->OpenVolume(FileSystem, &RootDir);
    if (EFI_ERROR(Status))
    {
        Print(L"Error opening volume: %r\n", Status);
        return Status;
    }

    // ===================== Open file ====================
    Status = RootDir->Open(RootDir, &GameFile, L"game.bin",
                           EFI_FILE_MODE_READ, 0);
    if (EFI_ERROR(Status))
    {
        Print(L"Error opening game.bin: %r\n", Status);
        RootDir->Close(RootDir);
        return Status;
    }

    // ===================== Get file info ====================
    EFI_FILE_INFO *FileInfo;
    UINTN FileInfoSize = 0;

    Status = GameFile->GetInfo(GameFile, &gEfiFileInfoGuid,
                               &FileInfoSize, NULL);
    if (Status == EFI_BUFFER_TOO_SMALL)
    {
        FileInfo = AllocatePool(FileInfoSize);
        Status = GameFile->GetInfo(GameFile, &gEfiFileInfoGuid,
                                   &FileInfoSize, FileInfo);
    }
    if (EFI_ERROR(Status))
    {
        Print(L"Error getting file info: %r\n", Status);
        return Status;
    }

    GameSize = FileInfo->FileSize;
    FreePool(FileInfo);

    // ===================== Reserve memory (Aligned pages of 4KB) ====================
    EFI_PHYSICAL_ADDRESS Address = 0;

    Status = SystemTable->BootServices->AllocatePages(
        AllocateAnyPages,
        EfiLoaderData,
        EFI_SIZE_TO_PAGES(GameSize),
        &Address);

    if (EFI_ERROR(Status))
    {
        Print(L"Error allocating pages: %r\n", Status);
        return Status;
    }

    GameBuffer = (VOID *)Address;

    // ===================== Read file content ====================
    Status = GameFile->Read(GameFile, &GameSize, GameBuffer);
    if (EFI_ERROR(Status))
    {
        Print(L"Error reading game: %r\n", Status);

        // Free reserved memory
        SystemTable->BootServices->FreePages(
            (EFI_PHYSICAL_ADDRESS)GameBuffer,
            EFI_SIZE_TO_PAGES(GameSize));
        return Status;
    }

    // ===================== Close files ====================
    GameFile->Close(GameFile);
    RootDir->Close(RootDir);

    Print(L"Game loaded on 0x%p (%ld bytes)\n", GameBuffer, GameSize);
    Print(L"Executing game...\n\n");

    // Stall 2s to display messages before exiting boot services
    SystemTable->BootServices->Stall(2000000);

    // ===================== Exit boot services ====================
    UINTN MapKey;
    UINTN DescriptorSize;
    UINT32 DescriptorVersion;
    EFI_MEMORY_DESCRIPTOR *MemoryMap;
    UINTN MemoryMapSize = 0;

    // Get current memory map
    SystemTable->BootServices->GetMemoryMap(&MemoryMapSize, NULL,
                                            &MapKey, &DescriptorSize,
                                            &DescriptorVersion);
    MemoryMap = AllocatePool(MemoryMapSize);
    Status = SystemTable->BootServices->GetMemoryMap(&MemoryMapSize, MemoryMap,
                                                     &MapKey, &DescriptorSize,
                                                     &DescriptorVersion);

    Status = SystemTable->BootServices->ExitBootServices(ImageHandle, MapKey);
    if (EFI_ERROR(Status))
    {
        Print(L"Error on ExitBootServices\n");
        return Status;
    }

    // ===================== Transfer control to loaded file ====================
    game_entry_t GameEntry = (game_entry_t)GameBuffer;
    GameEntry();

    return EFI_SUCCESS;
}

/**
 * @brief Main function for UEFI.
 *
 * @param ImageHandle Loaded program identifier.
 * @param SystemTable Access to UEFI features.
 */
EFI_STATUS
EFIAPI
efi_main(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable)
{
    // Initialize efilib functions
    InitializeLib(ImageHandle, SystemTable);

    // Clear screen
    SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
    // L prefix indicates UTF-16
    Print(L"Welcome to UEFI bootloader!\n\n");

    // Disable watchdog timer
    SystemTable->BootServices->SetWatchdogTimer(0, 0, 0, NULL);

    // Call loader function
    EFI_STATUS Status = load_game_from_disk(SystemTable, ImageHandle);

    // Errors handling
    if (EFI_ERROR(Status))
    {
        Print(L"\nError loading game. Press any key to continue.\n");

        // Wait for a key press to exit
        UINTN Index;
        SystemTable->BootServices->WaitForEvent(1,
                                                &SystemTable->ConIn->WaitForKey,
                                                &Index);
        EFI_INPUT_KEY Key;
        SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &Key);

        // Shutdown
        SystemTable->RuntimeServices->ResetSystem(
            EfiResetShutdown,
            EFI_SUCCESS,
            0,
            NULL);
    }

    return EFI_SUCCESS;
}
