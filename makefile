# =============================================================================
# Makefile - My Name Bootable Game
# CE 4303 - Principios de Sistemas Operativos
#
# Targets:
#   all          - Build everything
#   legacy       - Build legacy MBR disk image
#   uefi         - Build UEFI bootable disk image
#   run-legacy   - Run legacy image in QEMU
#   run-uefi     - Run UEFI image in QEMU (requires OVMF)
#   clean        - Remove all build artifacts
# =============================================================================

.PHONY: all legacy uefi run-legacy run-uefi clean

# ---- Tools ------------------------------------------------------------------
NASM    := nasm
CC      := gcc
LD      := ld
DD      := dd
QEMU    := qemu-system-x86_64

# OVMF firmware for UEFI emulation (adjust path for your distro)
# Ubuntu/Debian: sudo apt install ovmf  → /usr/share/OVMF/OVMF_CODE.fd
# Arch:          sudo pacman -S edk2-ovmf → /usr/share/OVMF/OVMF_CODE.fd
OVMF    := /usr/share/OVMF/OVMF_CODE.fd

# ---- Output directories -----------------------------------------------------
BUILD_LEGACY    := build/legacy
BUILD_UEFI      := build/uefi
BUILD_GAME      := build/game

all: legacy uefi

# =============================================================================
# LEGACY BUILD
# Creates a raw floppy/disk image: [sector1=boot.asm][sector2=game.bin]
# =============================================================================
legacy: $(BUILD_LEGACY)/disk.img
	@echo ""
	@echo "✔ Legacy disk image: $(BUILD_LEGACY)/disk.img"
	@echo "  Run with: make run-legacy"

# 1. Assemble bootloader (must produce exactly 512 bytes)
$(BUILD_LEGACY)/boot.bin: legacy/boot.asm | $(BUILD_LEGACY)
	$(NASM) -f bin $< -o $@
	@size=$$(wc -c < $@); \
	if [ "$$size" -ne 512 ]; then \
	    echo "ERROR: boot.bin is $$size bytes, expected 512"; exit 1; \
	fi
	@echo "  boot.bin: $$(wc -c < $@) bytes"

# 2. Assemble game (legacy real-mode, flat binary)
# game_main.asm %include's all other modules — list them all as dependencies
# so make rebuilds whenever any module changes.
GAME_SOURCES := game/game_main.asm \
                game/game_rand.asm \
                game/game_input.asm \
                game/game_render.asm \
                game/game_glyphs.asm

$(BUILD_GAME)/game.bin: $(GAME_SOURCES) | $(BUILD_GAME)
	$(NASM) -f bin game/game_main.asm -o $@
	@echo "  game.bin (legacy): $$(wc -c < $@) bytes"

# 3. Create disk image: pad to 1.44MB floppy size
$(BUILD_LEGACY)/disk.img: $(BUILD_LEGACY)/boot.bin $(BUILD_GAME)/game.bin
	# Create blank 1.44MB image
	$(DD) if=/dev/zero of=$@ bs=512 count=2880 status=none
	# Write bootloader to sector 1
	$(DD) if=$(BUILD_LEGACY)/boot.bin of=$@ bs=512 seek=0 conv=notrunc status=none
	# Write game to sector 2
	$(DD) if=$(BUILD_GAME)/game.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	@echo "  Disk image created: $@"

# =============================================================================
# UEFI BUILD
# Creates a GPT disk image with an EFI System Partition containing:
#   EFI/BOOT/BOOTX64.EFI  (our UEFI bootloader)
#   game.bin               (our 64-bit game payload)
# =============================================================================
uefi: $(BUILD_UEFI)/uefi_disk.img
	@echo ""
	@echo "✔ UEFI disk image: $(BUILD_UEFI)/uefi_disk.img"
	@echo "  Run with: make run-uefi"

# 1. Build UEFI bootloader EFI application
# Requires gnu-efi: sudo apt install gnu-efi
EFI_INC     := /usr/include/efi
EFI_LIB     := /usr/lib
EFI_CRT_OBJ := $(EFI_LIB)/crt0-efi-x86_64.o
EFI_LD      := $(EFI_LIB)/elf_x86_64_efi.lds

$(BUILD_UEFI)/uefi_boot.o: uefi/uefi_boot.c | $(BUILD_UEFI)
	$(CC) -I$(EFI_INC) -I$(EFI_INC)/x86_64 \
	      -fno-stack-protector -fpic -fshort-wchar -mno-red-zone \
	      -Wall -DEFI_FUNCTION_WRAPPER \
	      -c $< -o $@

$(BUILD_UEFI)/uefi_boot.so: $(BUILD_UEFI)/uefi_boot.o
	$(LD) -nostdlib -znocombreloc -T $(EFI_LD) -shared \
	      -Bsymbolic -L$(EFI_LIB) $(EFI_CRT_OBJ) $< \
	      -o $@ -lefi -lgnuefi

$(BUILD_UEFI)/BOOTX64.EFI: $(BUILD_UEFI)/uefi_boot.so
	objcopy -j .text -j .sdata -j .data -j .dynamic \
	        -j .dynsym -j .rel -j .rela -j .reloc \
	        --target=efi-app-x86_64 $< $@

# 2. Assemble 64-bit game payload
$(BUILD_GAME)/game_uefi.bin: game/game_uefi.asm | $(BUILD_GAME)
	$(NASM) -f bin $< -o $@
	@echo "  game_uefi.bin: $$(wc -c < $@) bytes"

# 3. Create UEFI bootable FAT image
$(BUILD_UEFI)/uefi_disk.img: $(BUILD_UEFI)/BOOTX64.EFI $(BUILD_GAME)/game_uefi.bin
	# Create blank 64MB image
	$(DD) if=/dev/zero of=$@ bs=1M count=64 status=none
	# Create GPT partition table with one EFI System Partition
	parted -s $@ mklabel gpt
	parted -s $@ mkpart EFI fat32 1MiB 63MiB
	parted -s $@ set 1 esp on
	# Format the partition as FAT32 (using losetup)
	@LOOP=$$(sudo losetup --find --show --partscan $@); \
	sudo mkfs.fat -F 32 $${LOOP}p1; \
	sudo mkdir -p /tmp/efi_mount; \
	sudo mount $${LOOP}p1 /tmp/efi_mount; \
	sudo mkdir -p /tmp/efi_mount/EFI/BOOT; \
	sudo cp $(BUILD_UEFI)/BOOTX64.EFI /tmp/efi_mount/EFI/BOOT/; \
	sudo cp $(BUILD_GAME)/game_uefi.bin /tmp/efi_mount/game.bin; \
	sudo umount /tmp/efi_mount; \
	sudo losetup -d $$LOOP
	@echo "  UEFI disk image created: $@"

# =============================================================================
# RUN TARGETS
# =============================================================================
run-legacy: $(BUILD_LEGACY)/disk.img
	@echo "Running legacy boot in QEMU..."
	$(QEMU) \
	    -drive format=raw,file=$(BUILD_LEGACY)/disk.img \
	    -m 32M \
	    -no-reboot \
	    -display sdl \
	    -name "My Name - Legacy Boot"

run-uefi: $(BUILD_UEFI)/uefi_disk.img
	@echo "Running UEFI boot in QEMU..."
	@if [ ! -f "$(OVMF)" ]; then \
	    echo "ERROR: OVMF not found at $(OVMF)"; \
	    echo "Install with: sudo apt install ovmf"; \
	    exit 1; \
	fi
	$(QEMU) \
	    -drive if=pflash,format=raw,file=$(OVMF),readonly=on \
	    -drive format=raw,file=$(BUILD_UEFI)/uefi_disk.img \
	    -m 256M \
	    -no-reboot \
	    -display sdl \
	    -name "My Name - UEFI Boot"

# Quick run without SDL (useful for headless/CI)
run-legacy-nographic: $(BUILD_LEGACY)/disk.img
	$(QEMU) \
	    -drive format=raw,file=$(BUILD_LEGACY)/disk.img \
	    -m 32M \
	    -no-reboot \
	    -nographic \
	    -name "My Name - Legacy Boot"

# =============================================================================
# BUILD DIRECTORIES
# =============================================================================
$(BUILD_LEGACY):
	mkdir -p $@

$(BUILD_UEFI):
	mkdir -p $@

$(BUILD_GAME):
	mkdir -p $@

# =============================================================================
# CLEAN
# =============================================================================
clean:
	rm -rf build/
	@echo "Cleaned."