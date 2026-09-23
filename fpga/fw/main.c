#include <stdalign.h>
#include <stdarg.h>
#include <stdint.h>

volatile uint32_t *const R_UART_TX_DATA = (volatile uint32_t *)0x20000000;
volatile uint32_t *const R_UART_TX_BUSY = (volatile uint32_t *)0x20000004;

#define I2C_DRIVE_Z 0x0
#define I2C_DRIVE_0 0x2

volatile uint32_t *const R_I2C_SCL = (volatile uint32_t *)0x20000008; // {oe, scl}
volatile uint32_t *const R_I2C_SDA = (volatile uint32_t *)0x2000000c; // {oe, sda}

static void uart_putchar(char c) {
  while (*R_UART_TX_BUSY)
    ;
  *R_UART_TX_DATA = c;
}

void uart_print(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  const char *p = fmt;
  while (*p != '\0') {
    if (p[0] == '%' && p[1] == 'x') {
      static const char hexdigits[] = "0123456789abcdef";
      uint32_t arg = va_arg(ap, uint32_t);
      for (unsigned i = 0; i < 32; i += 4) {
        uart_putchar(hexdigits[(arg >> (28 - i)) & 0xf]);
      }
      p++;
    } else {
      uart_putchar(*p);
    }
    p++;
  }
  va_end(ap);
  uart_putchar('\r');
  uart_putchar('\n');
}

void i2c_delay() {
  for (volatile int i = 0; i < 50; i++)
    ;
}

void i2c_start() {
  // Ensure both lines are released high, then pull SDA low while SCL is high
  // to generate the START condition. Works for both start and repeated start.
  *R_I2C_SDA = I2C_DRIVE_Z;
  *R_I2C_SCL = I2C_DRIVE_Z;
  i2c_delay();
  *R_I2C_SDA = I2C_DRIVE_0; // SDA falling edge while SCL high => START
  i2c_delay();
  *R_I2C_SCL = I2C_DRIVE_0; // Pull SCL low to prepare for first data bit
  i2c_delay();
}

void i2c_stop() {
  *R_I2C_SCL = I2C_DRIVE_0;
  *R_I2C_SDA = I2C_DRIVE_0;
  i2c_delay();
  *R_I2C_SCL = I2C_DRIVE_Z;
  i2c_delay();
  *R_I2C_SDA = I2C_DRIVE_Z;
  i2c_delay();
}

uint8_t i2c_write_byte(uint8_t byte) {
  for (int i = 0; i < 8; i++) {
    *R_I2C_SCL = I2C_DRIVE_0;
    i2c_delay();
    *R_I2C_SDA = ((byte >> (7 - i)) & 1) ? I2C_DRIVE_Z : I2C_DRIVE_0;
    i2c_delay();
    *R_I2C_SCL = I2C_DRIVE_Z;
    i2c_delay();
    i2c_delay();
  }
  // Get acknowledge from device
  *R_I2C_SCL = I2C_DRIVE_0;
  *R_I2C_SDA = I2C_DRIVE_Z;
  i2c_delay();
  i2c_delay();
  *R_I2C_SCL = I2C_DRIVE_Z;
  i2c_delay();
  uint8_t ack = *R_I2C_SDA & 1;
  *R_I2C_SCL = I2C_DRIVE_0; // Leave SCL low for a known state
  i2c_delay();
  return ack;
}

uint8_t i2c_read_byte(unsigned ack) {
  uint8_t data = 0;
  *R_I2C_SDA = I2C_DRIVE_Z;
  for (int i = 0; i < 8; i++) {
    *R_I2C_SCL = I2C_DRIVE_0;
    i2c_delay();
    *R_I2C_SCL = I2C_DRIVE_Z; // Release SCL high
    i2c_delay();
    data |= (*R_I2C_SDA & 1) << (7 - i); // Sample SDA while SCL is high
    i2c_delay();
  }
  // Send acknowledge to device
  *R_I2C_SCL = I2C_DRIVE_0;
  *R_I2C_SDA = ack ? I2C_DRIVE_0 : I2C_DRIVE_Z;
  i2c_delay();
  i2c_delay();
  *R_I2C_SCL = I2C_DRIVE_Z;
  i2c_delay();
  i2c_delay();
  *R_I2C_SCL = I2C_DRIVE_0; // Leave SCL low for a known state
  i2c_delay();
  return data;
}

int ext_clock_write_reg(uint16_t addr, const uint8_t *data, unsigned count) {
  i2c_start();
  unsigned nack = 0;
  nack |= i2c_write_byte((0x7c << 1) | 0); // I2C address for write
  nack |= i2c_write_byte(addr >> 8);       // MSB byte of addr
  nack |= i2c_write_byte(addr & 0xff);     // LSB byte of addr
  for (unsigned i = 0; i < count; i++) {
    nack |= i2c_write_byte(data[i]);
  }
  if (nack) {
    uart_print("ext_clock_write_reg: NACK for addr 0x%x", addr);
  }
  i2c_stop();
  return nack;
}

int ext_clock_read_reg(uint16_t addr, uint8_t *data, unsigned count) {
  i2c_start();
  unsigned nack = 0;
  nack |= i2c_write_byte((0x7c << 1) | 0); // I2C address for write
  nack |= i2c_write_byte(addr >> 8);       // MSB byte of addr
  nack |= i2c_write_byte(addr & 0xff);     // LSB byte of addr
  if (nack) {
    uart_print("ext_clock_read_reg: NACK for addr 0x%x", addr);
  }
  i2c_start();                     // Repeated Start
  i2c_write_byte((0x7c << 1) | 1); // I2C address for read
  for (unsigned i = 0; i < count; i++) {
    data[i] = i2c_read_byte(i < count - 1);
    // uart_print("addr: 0x%x data: 0x%x", addr + i, data[i]);
  }
  i2c_stop();
  return nack;
}

int main(void) {

  *R_I2C_SCL = I2C_DRIVE_Z;
  *R_I2C_SDA = I2C_DRIVE_Z;

  unsigned idx = 0;
  while (1) {
    uart_print("Hello from FPGA!");
    uart_print("Testing arguments 0x%x foobar 0x%x", 0x12345678, idx++);

    uint8_t data[8];

    ext_clock_read_reg(0x0002, data, 4);
    uint16_t dev_id = ((uint16_t)data[0] << 12) | (data[1] << 4) | (data[2] >> 4);
    uart_print("ext_clock: DEV_ID: 0x%x", dev_id);
    uint16_t dash_code = ((uint16_t)(data[2] & 0xf) << 7) | (data[3] >> 1);
    uart_print("ext_clock: DASH_CODE: 0x%x", dash_code);

    ext_clock_read_reg(0x0006, data, 2);
    uint8_t uftadd = data[0];
    uart_print("ext_clock: UFTADD: 0x%x", uftadd);

    for (volatile int i = 0; i < 1000000; i++)
      ; // Wait a while
  }

  return 0;
}
