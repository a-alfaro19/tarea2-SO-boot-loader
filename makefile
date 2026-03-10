ASM=nasm
BOOTLOADER=boot.bin
GAME=game.bin
IMAGE=floppy.img

# Verify if game.asm exists
GAME_SRC=$(wildcard game.asm)

# Set avaible dependencies
ifeq ($(GAME_SRC),game.asm)
    DEPENDENCIES=$(BOOTLOADER) $(GAME)
    ADD_GAME=dd if=$(GAME) of=$(IMAGE) bs=512 seek=1 conv=notrunc
else
    DEPENDENCIES=$(BOOTLOADER)
    ADD_GAME=@echo "Warning: game.asm not founded, omitting game.bin"
endif

all: $(IMAGE)

$(BOOTLOADER): boot.asm
	$(ASM) -f bin boot.asm -o $(BOOTLOADER)

$(GAME): game.asm
	$(ASM) -f bin game.asm -o $(GAME)

$(IMAGE): $(DEPENDENCIES)
	dd if=/dev/zero of=$(IMAGE) bs=512 count=2880
	dd if=$(BOOTLOADER) of=$(IMAGE) conv=notrunc
	$(ADD_GAME)

run: $(IMAGE)
	qemu-system-x86_64 -fda $(IMAGE)

clean:
	rm -f $(BOOTLOADER) $(GAME) $(IMAGE)
