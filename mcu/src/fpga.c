#include <ff.h>
#include <soc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/crc.h>

LOG_MODULE_REGISTER(m64_fpga, LOG_LEVEL_INF);

static const struct gpio_dt_spec fpga_ss_boot_ctrl =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_ss_boot_ctrl), gpios);
static const struct gpio_dt_spec fpga_init_b =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_init_b), gpios);
static const struct gpio_dt_spec fpga_program_b =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_program_b), gpios);
static const struct gpio_dt_spec fpga_done =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_done), gpios);
static const struct gpio_dt_spec flash_cs =
    GPIO_DT_SPEC_GET(DT_NODELABEL(flash_cs), gpios);

static const struct gpio_dt_spec fpga_cclk =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_cclk), gpios);
static const struct gpio_dt_spec fpga_din =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_din), gpios);

/*
 * ---------------------------------------------------------------------------
 * FPGA Slave-Serial configuration - BIT-BANG (temporary bring-up).
 *
 * CCLK = PF4, DIN = PF0, driven as plain GPIOs. This is a simple, robust
 * proof-of-life to confirm the FPGA configures: read a chunk from SD into
 * RAM, then clock it out bit-by-bit (MSB-first, data set up before the
 * rising CCLK edge, per Xilinx Slave-Serial). SD and GPIO never contend
 * because each SD read completes before we clock its bytes out.
 *
 * Not fast, but FPGA configuration is a one-time boot operation. Speed can
 * be revisited later (e.g. OCTOSPI or SPI on suitable pins).
 * ---------------------------------------------------------------------------
 */
#define FPGA_CCLK_PORT GPIOF
#define FPGA_CCLK_PIN 4U
#define FPGA_DIN_PORT GPIOF
#define FPGA_DIN_PIN 1U

/* BSRR set/reset masks (atomic single-store level changes). */
#define FPGA_CCLK_SET (1U << FPGA_CCLK_PIN)
#define FPGA_CCLK_CLR (1U << (FPGA_CCLK_PIN + 16))
#define FPGA_DIN_SET (1U << FPGA_DIN_PIN)
#define FPGA_DIN_CLR (1U << (FPGA_DIN_PIN + 16))

void fpga_setup_pins(void) {
  /* Set FPGA configuration mode to 'Slave Serial' (M[2:0] = 3'b111).
   * PG13 gates two N-FETs wired high-side (1V8 -> FET -> M1/M2). Gate high
   * turns them on, driving M1/M2 to 1V8 = 1; M0 has a fixed pull-up. So
   * PG13 high => M[2:0]=111 (active-high strap control). */
  (void)gpio_pin_configure_dt(&fpga_ss_boot_ctrl, GPIO_OUTPUT_ACTIVE);
  /* Set FPGA programming interface to inactive state (PROGRAM_B deasserted;
   * active-low + open-drain, so this drives the line physically high). */
  (void)gpio_pin_configure_dt(&fpga_program_b,
                              GPIO_OUTPUT_INACTIVE | GPIO_OPEN_DRAIN);
  (void)gpio_pin_configure_dt(&fpga_init_b, GPIO_INPUT);
  (void)gpio_pin_configure_dt(&fpga_done, GPIO_INPUT);

  /* Bit-bang config bus: CCLK (PF4) and DIN (PF0) as push-pull outputs,
   * both idle low. This also enables the GPIOF port clock. */
  (void)gpio_pin_configure_dt(&fpga_cclk, GPIO_OUTPUT_INACTIVE);
  (void)gpio_pin_configure_dt(&fpga_din, GPIO_OUTPUT_INACTIVE);

  /* Deselect the config flash (CS# high) so it stays off the shared
   * CCLK/DIN bus. Active-low, so OUTPUT_INACTIVE drives PG12 high. */
  (void)gpio_pin_configure_dt(&flash_cs, GPIO_OUTPUT_INACTIVE);
}

/* Clock out one byte. */
static inline void fpga_bitbang_byte(uint8_t b) {
  for (int k = 0; k < 8; k++) {
    uint32_t din = (b & (1U << (7 - k))) ? FPGA_DIN_SET : FPGA_DIN_CLR;

    /* Idle low; sample on rising edge. */
    FPGA_DIN_PORT->BSRR = din;
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
    FPGA_CCLK_PORT->BSRR = FPGA_CCLK_SET; /* rising: latch */
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
    FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR; /* return low */
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
    __asm__ volatile("nop" ::: "memory");
  }
}

/* Program the FPGA in Slave-Serial mode (bit-banged) from a raw .bin on SD.
 *
 * Expects a raw .bin (write_bitstream -bin_file): no header to skip.
 * Returns 0 on success, negative errno otherwise.
 */
static int fpga_program_path(const char *binpath) {
  struct fs_file_t file;
  /* Large buffer so each SD read is a fast contiguous burst; the slow
   * bit-bang then runs with the SD idle. This avoids interleaving many
   * small reads with the slow clock-out, which was overrunning the
   * marginal SD link (SDMMC_ERROR_RX_OVERRUN). 64 KiB fits in main RAM. */
  static uint8_t cfg_buf[1024];
  ssize_t n;
  int rc;

  fs_file_t_init(&file);
  rc = fs_open(&file, binpath, FS_O_READ);
  if (rc < 0) {
    LOG_ERR("open(%s) failed (%d)", binpath, rc);
    return rc;
  }

  /* Idle CCLK to the phase's resting level before starting. */
  FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR;

  /* Ensure the config flash is deselected so it can't drive the shared
   * IO0/DIN line while we clock the bitstream into the FPGA. */
  (void)gpio_pin_set_dt(&flash_cs, 0); /* 0 = inactive = CS# high */

  /* Pulse PROGRAM_B low to start a fresh configuration. */
  (void)gpio_pin_set_dt(&fpga_program_b, 1); /* assert (active low) */
  k_msleep(1);
  LOG_INF("INIT_B during clear (expect 0): %d", gpio_pin_get_dt(&fpga_init_b));
  (void)gpio_pin_set_dt(&fpga_program_b, 0); /* release: drive high */

  /* Wait for INIT_B high = config memory cleared, ready for data.
   * Bounded so a stuck-low INIT_B fails loudly instead of hanging the
   * shell thread forever (which also blocks deferred log draining). */
  int init_b_timeout_ms = 100;
  while (gpio_pin_get_dt(&fpga_init_b) == 0) {
    if (--init_b_timeout_ms < 0) {
      LOG_ERR("INIT_B stuck low: FPGA not clearing config "
              "memory (check PROGRAM_B, INIT_B pull-up, "
              "power, straps)");
      fs_close(&file);
      return -ETIMEDOUT;
    }
    k_msleep(1);
  }
  LOG_INF("FPGA ready for bitstream (bit-bang)");

  /* Read a big block, then clock it out; repeat. SD and GPIO never
   * overlap, and each SD session is a fast burst.
   *
   * While clocking, watch INIT_B: in Slave-Serial a listening FPGA pulls
   * INIT_B low if it hits a CRC error, so a dip proves our data is
   * actually reaching the config engine. Never dipping across the whole
   * image means the FPGA isn't seeing CCLK/DIN as config input at all.
   */
  bool init_b_dipped = false;
  size_t total_clocked = 0;

  while ((n = fs_read(&file, cfg_buf, sizeof(cfg_buf))) > 0) {
    for (ssize_t i = 0; i < n; i++) {
      fpga_bitbang_byte(cfg_buf[i]);

      /* Cheap periodic check (every 256 bytes). */
      if (((i & 0xFF) == 0) && !init_b_dipped &&
          gpio_pin_get_dt(&fpga_init_b) == 0) {
        init_b_dipped = true;
        LOG_WRN("INIT_B went LOW at ~%zu bytes "
                "(FPGA flagged a config/CRC error - "
                "data IS reaching it)",
                total_clocked + (size_t)i);
      }
    }
    total_clocked += (size_t)n;
  }
  fs_close(&file);

  LOG_INF("clocked %zu bytes; INIT_B dipped during load: %s", total_clocked,
          init_b_dipped ? "YES" : "NO");

  if (n < 0) {
    LOG_ERR("read failed (%d)", (int)n);
    return (int)n;
  }

  /*
   * Startup: after the last data byte the FPGA needs extra CCLK cycles
   * to complete its startup sequence and release DONE. DONE is asserted
   * partway through startup, so clock in bursts and poll DONE rather
   * than sending a fixed number of clocks. Bail out after a generous
   * bound (~ a few thousand extra clocks).
   */
  for (int burst = 0; burst < 256; burst++) {
    for (int i = 0; i < 8; i++) {
      fpga_bitbang_byte(0xFF); /* 64 clocks per burst */
    }
    if (gpio_pin_get_dt(&fpga_done) == 1) {
      LOG_INF("FPGA configured: DONE high after %d startup clocks",
              (burst + 1) * 64);
      return 0;
    }
  }

  LOG_ERR("FPGA config failed: DONE low (INIT_B=%d)",
          gpio_pin_get_dt(&fpga_init_b));
  return -EIO;
}

/* m64 fpga [path] [phase] : program the FPGA (Slave-Serial) from a .bin.
 *   phase 0 = sample on rising CCLK edge (default), 1 = falling edge.
 */
static int cmd_m64_fpga(const struct shell *sh, size_t argc, char **argv) {
  const char *path = (argc > 1) ? argv[1] : "/SD:/fpga.bin";
  int rc;

  shell_print(sh, "programming...");

  rc = fpga_program_path(path);
  if (rc != 0) {
    shell_error(sh, "FPGA program failed (%d)", rc);
    return rc;
  }
  shell_print(sh, "FPGA programmed from %s", path);
  return 0;
}

/* Attach "fpga" as a subcommand of the "m64" root command defined in main.c.
 * The parent's subcommand set is created there with SHELL_SUBCMD_SET_CREATE. */
SHELL_SUBCMD_ADD((m64), fpga, NULL, "Program FPGA: fpga [path]", cmd_m64_fpga,
                 1, 1);
