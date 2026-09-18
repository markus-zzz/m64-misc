#include <ff.h>
#include <soc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/linker/section_tags.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>

LOG_MODULE_REGISTER(m64_leds, LOG_LEVEL_INF);

static const struct gpio_dt_spec ctrl_led_data_0 =
    GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_0), gpios);
static const struct gpio_dt_spec ctrl_led_data_1 =
    GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_1), gpios);
static const struct gpio_dt_spec ctrl_led_data_2 =
    GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_2), gpios);
static const struct gpio_dt_spec ctrl_led_data_3 =
    GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_3), gpios);

/*
 * Bit-banged WS2812B driver on ctrl_led_data_0 (PA0).
 *
 * The WS2812 GPIO strip driver in Zephyr is Nordic-only, and PA0 is not an
 * SPI MOSI pin, so we drive the protocol by hand. Data is written straight
 * to the GPIO port's BSRR register (atomic set/reset, single store) rather
 * than through the GPIO API, which is far too slow for the sub-microsecond
 * bit timing.
 *
 * Timing (WS2812B, ~±150 ns tolerance):
 *   1 bit: ~0.8 us high, ~0.45 us low
 *   0 bit: ~0.4 us high, ~0.85 us low
 *   reset: line low >= ~50 us
 *
 * Delays are spin loops calibrated for the 280 MHz core clock. The NOP
 * counts are approximate and may need trimming on a scope.
 */

/* Enable the DWT cycle counter (present on Cortex-M7). Used for accurate
 * sub-microsecond delays independent of flash/cache effects. */
static void cyccnt_enable(void) {
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
  DWT->CYCCNT = 0;
  DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

/* Busy-wait for an exact number of CPU cycles using DWT->CYCCNT.
 * always_inline so it folds into the ITCM-resident caller (no separate
 * out-of-ITCM call in the timed path). */
static inline __attribute__((always_inline)) void
delay_cycles(uint32_t cycles) {
  uint32_t start = DWT->CYCCNT;

  while ((DWT->CYCCNT - start) < cycles) {
    /* spin */
  }
}

/* Core clock is 280 MHz -> 1 cycle ≈ 3.571 ns.
 * WS2812B bit timing:
 *   T1H 0.80 us ≈ 224 cyc   T1L 0.45 us ≈ 126 cyc
 *   T0H 0.40 us ≈ 112 cyc   T0L 0.85 us ≈ 238 cyc
 */
#define WS2812_T1H 224
#define WS2812_T1L 126
#define WS2812_T0H 112
#define WS2812_T0L 238

/* Shift a single 24-bit color into one WS2812B pixel on PA0.
 * WS2812 wire order is GRB, MSB first.
 *
 * Placed in ITCM (__itcm_section) so instruction fetches are zero-wait-state
 * and deterministic: executing from flash/cache can stall mid-pulse and
 * jitter the WS2812 bit timing. */
__itcm_section static void ws2812_send_color(GPIO_TypeDef *port, unsigned pin,
                                             uint32_t grb) {
  uint32_t set_mask = 1U << pin;
  uint32_t clr_mask = 1U << (pin + 16);

  /* The entire frame must be sent without interruption; any ISR that
   * stretches a pulse corrupts the color. */
  unsigned key = irq_lock();

  for (int i = 23; i >= 0; i--) {
    if (grb & (1U << i)) {
      port->BSRR = set_mask;
      delay_cycles(WS2812_T1H);
      port->BSRR = clr_mask;
      delay_cycles(WS2812_T1L);
    } else {
      port->BSRR = set_mask;
      delay_cycles(WS2812_T0H);
      port->BSRR = clr_mask;
      delay_cycles(WS2812_T0L);
    }
  }

  irq_unlock(key);

  /* Latch: hold the line low. */
  port->BSRR = clr_mask;
  k_busy_wait(60);
}

/* m64 ws2812 <RRGGBB> : shift a 24-bit color into the PA0 WS2812B. */
static int cmd_m64_leds(const struct shell *sh, size_t argc, char **argv) {
  unsigned long v;
  char *end;

  v = strtoul(argv[1], &end, 16);
  if (*end != '\0' || v > 0xFFFFFFUL) {
    shell_error(sh, "expected a 24-bit hex color, e.g. 00ff80");
    return -EINVAL;
  }
  uint8_t r = (v >> 16) & 0xFF;
  uint8_t g = (v >> 8) & 0xFF;
  uint8_t b = v & 0xFF;
  uint32_t grb = ((uint32_t)g << 16) | ((uint32_t)r << 8) | b;

  ws2812_send_color(GPIOA, 0, grb);  // Controller port #0
  ws2812_send_color(GPIOB, 3, grb);  // Controller port #1
  ws2812_send_color(GPIOB, 4, grb);  // Controller port #2
  ws2812_send_color(GPIOD, 15, grb); // Controller port #3

  shell_print(sh, "sent #%06lX", v);
  return 0;
}

void leds_setup_pins(void) {
  (void)gpio_pin_configure_dt(&ctrl_led_data_0, GPIO_OUTPUT_INACTIVE);
  (void)gpio_pin_configure_dt(&ctrl_led_data_1, GPIO_OUTPUT_INACTIVE);
  (void)gpio_pin_configure_dt(&ctrl_led_data_2, GPIO_OUTPUT_INACTIVE);
  (void)gpio_pin_configure_dt(&ctrl_led_data_3, GPIO_OUTPUT_INACTIVE);

  cyccnt_enable();
}

SHELL_SUBCMD_ADD((m64), leds, NULL, "Manipulate LEDs", cmd_m64_leds, 2, 0);
