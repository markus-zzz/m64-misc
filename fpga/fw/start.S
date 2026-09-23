.text
.globl _start
.p2align 2
.type _start,@function
_start:
	// no more than 16 bytes here !
	j start

.balign 16
.balign 0x4
start:
  // Clear .bss
  la x26, _bss_start
  la x27, _bss_end
bss_clear_loop:
  beq x26, x27, bss_clear_done
  sb x0, 0(x26)
  addi x26, x26, 1
  j bss_clear_loop
bss_clear_done:
  // Initialize .data
  la x26, _idata_start
  la x27, _data_start
  la x28, _data_end
data_init_loop:
  beq x27, x28, data_init_done
  lb x10, 0(x26)
  sb x10, 0(x27)
  addi x26, x26, 1
  addi x27, x27, 1
  j data_init_loop
data_init_done:
  // Setup stack
  la    sp, __stacktop
  // Call main()
  call  main
  j     0
