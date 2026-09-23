#include <stdalign.h>
#include <stdarg.h>
#include <stdint.h>

volatile uint32_t *const R_UART_TX_DATA = (volatile uint32_t *)0x20000000;
volatile uint32_t *const R_UART_TX_BUSY = (volatile uint32_t *)0x20000004;

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

int main(void) {

  while (1) {
    uart_print("Hello from FPGA!");
    uart_print("Testing arguments 0x%x foobar 0x%x", 0x12345678, 0xabc);
    for (volatile int i = 0; i < 1000000; i++)
      ; // Wait a while
  }

  return 0;
}
