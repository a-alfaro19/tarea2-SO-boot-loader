# =============================================================================
# Makefile - My Name Bootable Game
# CE 4303 - Principios de Sistemas Operativos
#
# Targets:
#   all              - Build legacy and uefi-c
#   legacy           - Assemble legacy MBR disk image
#   uefi-c           - Compile UEFI C game into a bootable disk image
#   run-legacy       - Run legacy image in QEMU
#   run-uefi-c       - Run UEFI C image in QEMU (requires OVMF)
#   clean            - Remove all build artifacts
# =============================================================================

.PHONY: all legacy uefi-c run-legacy run-uefi-c clean

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------
NASM    := nasm
CC      := gcc
LD      := ld
DD      := dd
QEMU    := qemu-system-x86_64

# mtools: userspace FAT filesystem tools, no root or loop devices needed.
# Install: sudo apt install mtools
MFORMAT := mformat
MCOPY   := mcopy
MMD     := mmd

# gnu-efi paths (adjust if your distro installs elsewhere)
# Install: sudo apt install gnu-efi
EFI_INC     := /usr/include/efi
EFI_LIB     := /usr/lib
EFI_CRT_OBJ := $(EFI_LIB)/crt0-efi-x86_64.o
EFI_LD      := $(EFI_LIB)/elf_x86_64_efi.lds

# OVMF firmware for UEFI emulation.
# Install: sudo apt install ovmf
# QEMU needs two pflash drives:
#   OVMF_CODE.fd  - read-only firmware code
#   OVMF_VARS.fd  - writable NVRAM (EFI variable store)
OVMF_CODE := /usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS := /usr/share/OVMF/OVMF_VARS_4M.fd

# -----------------------------------------------------------------------------
# Build output directories
# -----------------------------------------------------------------------------
BUILD_LEGACY := build/legacy
BUILD_UEFI_C := build/uefi_c
BUILD_GAME   := build/game

# -----------------------------------------------------------------------------
# Default target
# -----------------------------------------------------------------------------
all: legacy uefi-c

# =============================================================================
# LEGACY BUILD
# Produces a 1.44MB floppy image:
#   Sector 1 (512 bytes): boot.asm  (MBR bootloader)
#   Sector 2+  :          game.bin  (assembled game)
# =============================================================================
legacy: $(BUILD_LEGACY)/disk.img
	@echo ""
	@echo "  Legacy disk image: $(BUILD_LEGACY)/disk.img"
	@echo "  Run with: make run-legacy"

# Assemble MBR bootloader -- must be exactly 512 bytes
$(BUILD_LEGACY)/boot.bin: legacy/boot.asm | $(BUILD_LEGACY)
	$(NASM) -f bin $< -o $@
	@size=$$(wc -c < $@); \
	if [ "$$size" -ne 512 ]; then \
	    echo "ERROR: boot.bin is $$size bytes, expected exactly 512"; exit 1; \
	fi

# Assemble game payload -- game_main.asm pulls in all modules via %include
GAME_SOURCES := game/game_main.asm \
                game/game_rand.asm \
                game/game_input.asm \
                game/game_render.asm \
                game/game_glyphs.asm

$(BUILD_GAME)/game.bin: $(GAME_SOURCES) | $(BUILD_GAME)
	$(NASM) -f bin -I game/ game/game_main.asm -o $@

# Create the floppy disk image: blank 1.44MB, then write both sectors
$(BUILD_LEGACY)/disk.img: $(BUILD_LEGACY)/boot.bin $(BUILD_GAME)/game.bin
	$(DD) if=/dev/zero                of=$@ bs=512 count=2880 status=none
	$(DD) if=$(BUILD_LEGACY)/boot.bin of=$@ bs=512 seek=0 conv=notrunc status=none
	$(DD) if=$(BUILD_GAME)/game.bin   of=$@ bs=512 seek=1 conv=notrunc status=none

# =============================================================================
# UEFI C BUILD
# Compiles uefi_game.c into a self-contained EFI application (BOOTX64.EFI),
# then packages it into a bootable FAT32 disk image using mtools.
#
# mtools lets us create and populate a FAT filesystem entirely in userspace --
# no sudo, no loop devices, no mount/umount needed.
# =============================================================================
uefi-c: $(BUILD_UEFI_C)/uefi_disk.img
	@echo ""
	@echo "  UEFI disk image: $(BUILD_UEFI_C)/uefi_disk.img"
	@echo "  Run with: make run-uefi-c"

# Step 1: Compile to ELF object
$(BUILD_UEFI_C)/game_uefi.o: uefi/uefi_game.c | $(BUILD_UEFI_C)
	$(CC) -I$(EFI_INC) -I$(EFI_INC)/x86_64 \
	      -fno-stack-protector -fpic -fshort-wchar -mno-red-zone \
	      -Wall -DEFI_FUNCTION_WRAPPER \
	      -c $< -o $@

# Step 2: Link into a shared ELF using the EFI linker script
$(BUILD_UEFI_C)/game_uefi.so: $(BUILD_UEFI_C)/game_uefi.o
	$(LD) -nostdlib -znocombreloc \
	      -T $(EFI_LD) -shared -Bsymbolic \
	      -L$(EFI_LIB) $(EFI_CRT_OBJ) $< \
	      -o $@ -lefi -lgnuefi

# Step 3: Strip to a PE/COFF EFI binary
$(BUILD_UEFI_C)/BOOTX64.EFI: $(BUILD_UEFI_C)/game_uefi.so
	objcopy \
	    -j .text -j .sdata -j .data -j .dynamic \
	    -j .dynsym -j .rel -j .rela -j .reloc \
	    --target=efi-app-x86_64 $< $@

# Step 4: Create a FAT32 disk image and populate it with mtools.
#
# mtools operates on raw image files directly via the @@@ offset syntax:
#   file@@@offset means "treat the file starting at byte <offset> as a
#   FAT filesystem". 1MiB = 1048576 bytes = where parted placed the ESP.
# MTOOLS_SKIP_CHECK=1 suppresses geometry mismatch warnings on raw files.
$(BUILD_UEFI_C)/uefi_disk.img: $(BUILD_UEFI_C)/BOOTX64.EFI
	$(DD) if=/dev/zero of=$@ bs=1M count=64 status=none
	parted -s $@ mklabel gpt
	parted -s $@ mkpart EFI fat32 1MiB 63MiB
	parted -s $@ set 1 esp on
	MTOOLS_SKIP_CHECK=1 $(MFORMAT) -i $@@@1M -F -v EFI
	MTOOLS_SKIP_CHECK=1 $(MMD)     -i $@@@1M ::/EFI
	MTOOLS_SKIP_CHECK=1 $(MMD)     -i $@@@1M ::/EFI/BOOT
	MTOOLS_SKIP_CHECK=1 $(MCOPY)   -i $@@@1M \
	    $(BUILD_UEFI_C)/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

# =============================================================================
# RUN TARGETS
# =============================================================================

# Legacy: boot from floppy image.
# -drive if=floppy tells QEMU to present this as floppy drive A:.
# The BIOS sets DL=0x00 when jumping to the MBR, which is what
# boot.asm expects when it saves the boot drive number.
run-legacy: $(BUILD_LEGACY)/disk.img
	$(QEMU) \
	    -drive if=floppy,format=raw,file=$(BUILD_LEGACY)/disk.img \
	    -m 32M \
	    -no-reboot \
	    -display gtk \
	    -name "My Name - Legacy Boot"

# UEFI: boot from disk image using OVMF firmware.
# Two pflash drives are required:
#   index=0: OVMF_CODE.fd (read-only firmware code)
#   index=1: OVMF_VARS.fd (writable NVRAM / EFI variable store)
# We copy VARS to build/ so QEMU can write to it without touching
# the system-installed file.
run-uefi-c: $(BUILD_UEFI_C)/uefi_disk.img
	@if [ ! -f "$(OVMF_CODE)" ]; then \
	    echo "ERROR: OVMF not found at $(OVMF_CODE)"; \
	    echo "Install with: sudo apt install ovmf"; \
	    echo "Then check available files with: ls /usr/share/OVMF/"; \
	    exit 1; \
	fi
	@cp $(OVMF_VARS) $(BUILD_UEFI_C)/OVMF_VARS_runtime.fd
	$(QEMU) \
	    -drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
	    -drive if=pflash,format=raw,file=$(BUILD_UEFI_C)/OVMF_VARS_runtime.fd \
	    -drive format=raw,file=$(BUILD_UEFI_C)/uefi_disk.img \
	    -m 256M \
	    -no-reboot \
	    -display gtk \
	    -name "My Name - UEFI C Game"

# =============================================================================
# BUILD DIRECTORIES
# =============================================================================
$(BUILD_LEGACY) $(BUILD_UEFI_C) $(BUILD_GAME):
	mkdir -p $@

# =============================================================================
# CLEAN
# =============================================================================
clean:
	rm -rf build/