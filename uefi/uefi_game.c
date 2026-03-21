/* UEFI Step 9: WaitForKey is valid - skip Reset, use WaitForEvent directly */

#include <efi.h>
#include <efilib.h>

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle,
                            EFI_SYSTEM_TABLE *SystemTable)
{
    InitializeLib(ImageHandle, SystemTable);
    SystemTable->BootServices->SetWatchdogTimer(0, 0, 0, NULL);

    /* Do NOT call ConIn->Reset — it hangs with virtio-gpu.
       WaitForKey is already valid on entry. */

    SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
    Print(L"Step 9: skip Reset, use WaitForEvent directly.\n");
    Print(L"WaitForKey: 0x%lx\n\n",
          (UINTN)SystemTable->ConIn->WaitForKey);
    Print(L"Press any key...\n");

    UINTN idx;
    EFI_STATUS s = SystemTable->BootServices->WaitForEvent(
        1, &SystemTable->ConIn->WaitForKey, &idx);

    Print(L"WaitForEvent returned: %r\n", s);

    if (!EFI_ERROR(s))
    {
        EFI_INPUT_KEY key;
        SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &key);
        Print(L"Key: scan=0x%02x char=0x%04x\n",
              (UINTN)key.ScanCode, (UINTN)key.UnicodeChar);
        Print(L"\nINPUT WORKS! Press another key to exit.\n");
        SystemTable->BootServices->WaitForEvent(
            1, &SystemTable->ConIn->WaitForKey, &idx);
        SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &key);
    }

    return EFI_SUCCESS;
}