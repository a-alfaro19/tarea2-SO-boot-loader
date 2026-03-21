#include <efi.h>
#include <efilib.h>

EFI_STATUS EFIAPI efi_main(EFI_HANDLE ImageHandle,
                            EFI_SYSTEM_TABLE *SystemTable)
{
    InitializeLib(ImageHandle, SystemTable);
    SystemTable->BootServices->SetWatchdogTimer(0, 0, 0, NULL);

    SystemTable->ConOut->ClearScreen(SystemTable->ConOut);
    Print(L"Input test: waiting for key OR 10s timer.\n");
    Print(L"WaitForKey ptr: 0x%lx\n\n",
          (UINTN)SystemTable->ConIn->WaitForKey);

    /* Create a 10-second timer as fallback */
    EFI_EVENT timer;
    SystemTable->BootServices->CreateEvent(EVT_TIMER, 0, NULL, NULL, &timer);
    SystemTable->BootServices->SetTimer(timer, TimerRelative, 100000000ULL);

    EFI_EVENT events[2];
    events[0] = SystemTable->ConIn->WaitForKey;
    events[1] = timer;

    /* Count how many valid events we have */
    UINTN num_events = (SystemTable->ConIn->WaitForKey != NULL) ? 2 : 1;
    /* If WaitForKey is NULL, only wait on timer */
    EFI_EVENT *evp = (num_events == 2) ? events : &timer;

    Print(L"Calling WaitForEvent with %d event(s)...\n", num_events);

    UINTN idx;
    EFI_STATUS s = SystemTable->BootServices->WaitForEvent(
        num_events, evp, &idx);

    Print(L"WaitForEvent returned: %r  idx=%d\n", s, (UINTN)idx);

    if (!EFI_ERROR(s)) {
        if (idx == 0 && num_events == 2) {
            EFI_INPUT_KEY key;
            SystemTable->ConIn->ReadKeyStroke(SystemTable->ConIn, &key);
            Print(L"KEY: scan=0x%02x char=0x%04x\n",
                  (UINTN)key.ScanCode, (UINTN)key.UnicodeChar);
            Print(L"INPUT WORKS!\n");
        } else {
            Print(L"Timer fired (no key received).\n");
        }
    }

    SystemTable->BootServices->CloseEvent(timer);
    Print(L"\nDone. Stalling 5s...\n");
    SystemTable->BootServices->Stall(5000000);
    return EFI_SUCCESS;
}
