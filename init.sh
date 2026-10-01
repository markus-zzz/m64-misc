# Load default design into FPGA
m64 fpga program /SD:/fpga.bin
# Assert reset for soft CPU in FPGA
m64 fpga write32 0x10000000 1
# Download soft CPU firmware
m64 fpga write   0x10010000 /SD:/bios.bin
# De-assert reset for soft CPU in FPGA
m64 fpga write32 0x10000000 0

# Grid color set to white
m64 fpga write32 0x20000010 0xffffff
