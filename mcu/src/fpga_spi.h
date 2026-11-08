#ifndef M64_FPGA_SPI_H
#define M64_FPGA_SPI_H

#include <stddef.h>
#include <stdint.h>

void fpga_spi_init(void);
int fpga_bus_read32(uint32_t addr, uint32_t *data);
int fpga_bus_write(uint32_t addr, uint8_t *buf, size_t len);
int fpga_bus_write32(uint32_t addr, uint32_t data);
int fpga_bus_write_file(uint32_t addr, const char *path);

#endif /* M64_FPGA_SPI_H */
