OBJS = main.o start.o

all: bios.bin

main.o: main.c

%.o: %.c
	clang --target=riscv32 -march=rv32imc -std=c99 -O3 -Os -fno-inline -mno-relax -Wall -Werror -c $< -o $@

%.o: %.S
	clang --target=riscv32 -march=rv32imc -mno-relax -Wall -Werror -c $< -o $@

bios.elf: $(OBJS) system.ld
	ld.lld -T system.ld $(OBJS) -o $@ -M

bios.bin: bios.elf
	llvm-objcopy --keep-section=.text --keep-section=.data --output-target=binary $< $@

clean:
	rm -f $(OBJS) bios.elf bios.bin
