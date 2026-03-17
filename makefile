ASM=nasm
BOOTLOADER=boot.bin
GAME=game.bin
IMAGE=floppy.img

# UEFI variables
CC=gcc
LD=ld
OBJCOPY=objcopy
ARCH=x86_64
UEFI_BOOTLOADER=uefi_boot.efi
UEFI_IMAGE=uefi.img
DISK_SIZE=93750  # 48 MB

# GNU-EFI paths (adjust if needed)
GNU_EFI_INC=/usr/include/efi
GNU_EFI_INC_ARCH=/usr/include/efi/$(ARCH)
GNU_EFI_LIBS=/usr/lib
GNU_EFI_CRT=$(GNU_EFI_LIBS)/crt0-efi-$(ARCH).o
GNU_EFI_LD_SCRIPT=$(GNU_EFI_LIBS)/elf_$(ARCH)_efi.lds

CFLAGS=-fno-stack-protector -fpic -fshort-wchar -mno-red-zone -DEFI_FUNCTION_WRAPPER -I$(GNU_EFI_INC) -I$(GNU_EFI_INC_ARCH)
LDFLAGS=-nostdlib -znocombreloc -shared -Bsymbolic -T $(GNU_EFI_LD_SCRIPT)
OBJCOPY_FLAGS=-j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym -j .rel -j .rela -j .reloc --output-target=efi-app-$(ARCH)

# Verify if game.asm exists
GAME_SRC=$(wildcard game.asm)

# Set available dependencies
ifeq ($(GAME_SRC),game.asm)
    DEPENDENCIES=$(BOOTLOADER) $(GAME)
    ADD_GAME=dd if=$(GAME) of=$(IMAGE) bs=512 seek=1 conv=notrunc
    UEFI_ADD_GAME=mkdir -p esp_temp && cp $(GAME) esp_temp/game.bin
else
    DEPENDENCIES=$(BOOTLOADER)
    ADD_GAME=@echo "Warning: game.asm not founded, omitting game.bin"
    UEFI_ADD_GAME=@echo "Warning: game.asm not founded, omitting game.bin"
endif

all: bios uefi

bios: $(IMAGE)

uefi: $(UEFI_IMAGE)

$(BOOTLOADER): boot.asm
	$(ASM) -f bin boot.asm -o $(BOOTLOADER)

$(GAME): game.asm
	$(ASM) -f bin game.asm -o $(GAME)

$(IMAGE): $(DEPENDENCIES)
	dd if=/dev/zero of=$(IMAGE) bs=512 count=2880
	dd if=$(BOOTLOADER) of=$(IMAGE) conv=notrunc
	$(ADD_GAME)

$(UEFI_BOOTLOADER): uefi_boot.c
	$(CC) -c uefi_boot.c $(CFLAGS) -o uefi_boot.o
	$(LD) uefi_boot.o $(GNU_EFI_CRT) $(LDFLAGS) -L $(GNU_EFI_LIBS) -l:libgnuefi.a -l:libefi.a -o uefi_boot.so
	$(OBJCOPY) $(OBJCOPY_FLAGS) uefi_boot.so $(UEFI_BOOTLOADER)
	rm uefi_boot.o uefi_boot.so

$(UEFI_IMAGE): $(UEFI_BOOTLOADER) $(if $(GAME_SRC),$(GAME))
	dd if=/dev/zero of=$(UEFI_IMAGE) bs=1M count=64

	mformat -i $(UEFI_IMAGE) ::

	mmd -i $(UEFI_IMAGE) ::/EFI
	mmd -i $(UEFI_IMAGE) ::/EFI/BOOT

	mcopy -i $(UEFI_IMAGE) $(UEFI_BOOTLOADER) ::/EFI/BOOT/BOOTX64.EFI

ifeq ($(GAME_SRC),game.asm)
	mcopy -i $(UEFI_IMAGE) $(GAME) ::/game.bin
endif

run-bios: $(IMAGE)
	qemu-system-x86_64 -fda $(IMAGE)

OVMF_PATH=/usr/share/OVMF
OVMF_CODE=$(OVMF_PATH)/OVMF_CODE_4M.fd
OVMF_VARS=OVMF_VARS.fd

run-uefi: $(UEFI_IMAGE)
	qemu-system-x86_64 \
	-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
	-drive if=pflash,format=raw,file=$(OVMF_VARS) \
	-drive file=uefi.img,format=raw \
	-m 512 \
	-no-reboot -no-shutdown

clean:
	rm -f $(BOOTLOADER) $(GAME) $(IMAGE) $(UEFI_BOOTLOADER) $(UEFI_IMAGE)
