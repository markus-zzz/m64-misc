/*
 * Copyright (c) 2026 ModRetro
 * SPDX-License-Identifier: Apache-2.0
 *
 * USB CDC-ACM console demo: prints a system-info banner at boot and a
 * live status line every second. The USB CDC-ACM port is the primary
 * console (see zephyr,console in the board DTS), so plain printk() output
 * goes over USB automatically.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <zephyr/version.h>
#include <zephyr/linker/section_tags.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <zephyr/sys/crc.h>
#include <ff.h>
#include <soc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

/* CDC-ACM device backing the console; used here to poll DTR at boot. */
static const struct device *const cdc_dev =
	DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

/* Board GPIO: VSYS LED enable (PG15, active-high). */
static const struct gpio_dt_spec vsys_led_on =
	GPIO_DT_SPEC_GET(DT_NODELABEL(vsys_led_on), gpios);
static const struct gpio_dt_spec fpga_pwr_en =
	GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_pwr_en), gpios);

static const struct gpio_dt_spec ctrl_led_data_0 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_0), gpios);
static const struct gpio_dt_spec ctrl_led_data_1 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_1), gpios);
static const struct gpio_dt_spec ctrl_led_data_2 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_2), gpios);
static const struct gpio_dt_spec ctrl_led_data_3 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_3), gpios);

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
#define FPGA_CCLK_PIN  4U
#define FPGA_DIN_PORT  GPIOF
#define FPGA_DIN_PIN   1U

/* BSRR set/reset masks (atomic single-store level changes). */
#define FPGA_CCLK_SET  (1U << FPGA_CCLK_PIN)
#define FPGA_CCLK_CLR  (1U << (FPGA_CCLK_PIN + 16))
#define FPGA_DIN_SET   (1U << FPGA_DIN_PIN)
#define FPGA_DIN_CLR   (1U << (FPGA_DIN_PIN + 16))

static const struct gpio_dt_spec fpga_cclk =
	GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_cclk), gpios);
static const struct gpio_dt_spec fpga_din =
	GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_din), gpios);

/*
 * Bit-bang clock phase selector (experiment knob).
 *   0 = data set up BEFORE the rising CCLK edge, FPGA samples on rising edge
 *       (classic SPI mode 0 / standard Slave-Serial).
 *   1 = data set up BEFORE the falling CCLK edge, i.e. clock idles high and
 *       we present data then drop CCLK (sample on falling edge).
 * Selectable at runtime via `m64 fpga <path> <phase>` for bring-up testing.
 */
static int fpga_clk_phase;

/* Optional leading dummy bytes (each = 8 CCLKs with DIN high) sent after
 * INIT_B rises, before the bitstream. Set via `m64 fpga <path> <phase> <n>`. */
static int fpga_lead_clocks;

/* Bit order within each byte: 0 = MSB-first (standard), 1 = LSB-first.
 * UltraScale+ serial config paths sometimes expect bit-reversed bytes. */
static int fpga_lsb_first;

/* Clock out one byte, honoring fpga_clk_phase and fpga_lsb_first. */
static inline void fpga_bitbang_byte(uint8_t b)
{
	for (int k = 0; k < 8; k++) {
		int i = fpga_lsb_first ? k : (7 - k);   /* bit index this step */
		uint32_t din = (b & (1U << i)) ? FPGA_DIN_SET : FPGA_DIN_CLR;

		if (fpga_clk_phase == 0) {
			/* Idle low; sample on rising edge. */
			FPGA_DIN_PORT->BSRR = din;
			k_busy_wait(1);                     /* DIN setup */
			FPGA_CCLK_PORT->BSRR = FPGA_CCLK_SET;   /* rising: latch */
			k_busy_wait(1);
			FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR;   /* return low */
			k_busy_wait(1);
		} else {
			/* Idle high; sample on falling edge. */
			FPGA_DIN_PORT->BSRR = din;
			k_busy_wait(1);                     /* DIN setup */
			FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR;   /* falling: latch */
			k_busy_wait(1);
			FPGA_CCLK_PORT->BSRR = FPGA_CCLK_SET;   /* return high */
			k_busy_wait(1);
		}
	}
}

/* Program the FPGA in Slave-Serial mode (bit-banged) from a raw .bin on SD.
 *
 * Expects a raw .bin (write_bitstream -bin_file): no header to skip.
 * Returns 0 on success, negative errno otherwise.
 */
static int fpga_program_path(const char *binpath)
{
	struct fs_file_t file;
	/* Large buffer so each SD read is a fast contiguous burst; the slow
	 * bit-bang then runs with the SD idle. This avoids interleaving many
	 * small reads with the slow clock-out, which was overrunning the
	 * marginal SD link (SDMMC_ERROR_RX_OVERRUN). 64 KiB fits in main RAM. */
	static uint8_t cfg_buf[64 * 1024];
	ssize_t n;
	int rc;

	fs_file_t_init(&file);
	rc = fs_open(&file, binpath, FS_O_READ);
	if (rc < 0) {
		LOG_ERR("open(%s) failed (%d)", binpath, rc);
		return rc;
	}

	/* Idle CCLK to the phase's resting level before starting. */
	FPGA_CCLK_PORT->BSRR = (fpga_clk_phase == 0) ?
			       FPGA_CCLK_CLR : FPGA_CCLK_SET;

	/* Ensure the config flash is deselected so it can't drive the shared
	 * IO0/DIN line while we clock the bitstream into the FPGA. */
	(void)gpio_pin_set_dt(&flash_cs, 0);   /* 0 = inactive = CS# high */

	/* Pulse PROGRAM_B low to start a fresh configuration. */
	(void)gpio_pin_set_dt(&fpga_program_b, 1);   /* assert (active low) */
	k_msleep(1);
	LOG_INF("INIT_B during clear (expect 0): %d",
		gpio_pin_get_dt(&fpga_init_b));
	(void)gpio_pin_set_dt(&fpga_program_b, 0);   /* release: drive high */

	/* Wait for INIT_B high = config memory cleared, ready for data. */
	while (gpio_pin_get_dt(&fpga_init_b) == 0) {
		k_msleep(1);
	}
	LOG_INF("FPGA ready for bitstream (bit-bang)");

	/* Optional leading dummy clocks (DIN idle high) before the bitstream. */
	if (fpga_lead_clocks > 0) {
		FPGA_DIN_PORT->BSRR = FPGA_DIN_SET;   /* DIN high during dummies */
		for (int i = 0; i < fpga_lead_clocks; i++) {
			fpga_bitbang_byte(0xFF);
		}
		LOG_INF("sent %d leading dummy bytes", fpga_lead_clocks);
	}

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

	LOG_INF("clocked %zu bytes; INIT_B dipped during load: %s",
		total_clocked, init_b_dipped ? "YES" : "NO");

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
			fpga_bitbang_byte(0xFF);   /* 64 clocks per burst */
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
#define WS2812_PORT   GPIOA
#define WS2812_PIN    0U
#define WS2812_SET    (1U << WS2812_PIN)		/* BSRR: set (drive high) */
#define WS2812_CLR    (1U << (WS2812_PIN + 16))		/* BSRR: reset (drive low) */

/* Enable the DWT cycle counter (present on Cortex-M7). Used for accurate
 * sub-microsecond delays independent of flash/cache effects. */
static void cyccnt_enable(void)
{
	CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
	DWT->CYCCNT = 0;
	DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
}

/* Busy-wait for an exact number of CPU cycles using DWT->CYCCNT.
 * always_inline so it folds into the ITCM-resident caller (no separate
 * out-of-ITCM call in the timed path). */
static inline __attribute__((always_inline))
void delay_cycles(uint32_t cycles)
{
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
__itcm_section
static void ws2812_send_color(uint8_t r, uint8_t g, uint8_t b)
{
	uint32_t grb = ((uint32_t)g << 16) | ((uint32_t)r << 8) | b;
	unsigned int key;

	/* The entire frame must be sent without interruption; any ISR that
	 * stretches a pulse corrupts the color. */
	key = irq_lock();

	for (int i = 23; i >= 0; i--) {
		if (grb & (1U << i)) {
			WS2812_PORT->BSRR = WS2812_SET;
			delay_cycles(WS2812_T1H);
			WS2812_PORT->BSRR = WS2812_CLR;
			delay_cycles(WS2812_T1L);
		} else {
			WS2812_PORT->BSRR = WS2812_SET;
			delay_cycles(WS2812_T0H);
			WS2812_PORT->BSRR = WS2812_CLR;
			delay_cycles(WS2812_T0L);
		}
	}

	irq_unlock(key);

	/* Latch: hold the line low. */
	WS2812_PORT->BSRR = WS2812_CLR;
	k_busy_wait(60);
}

/* Wait until the host opens the CDC-ACM port (asserts DTR), up to
 * timeout_ms. Returns true if DTR was seen, false on timeout so a headless
 * boot still proceeds.
 */
static bool wait_for_dtr(uint32_t timeout_ms)
{
	uint32_t dtr = 0;
	uint32_t waited = 0;

	if (!device_is_ready(cdc_dev)) {
		return false;
	}

	while (waited < timeout_ms) {
		if (uart_line_ctrl_get(cdc_dev, UART_LINE_CTRL_DTR, &dtr) == 0 && dtr) {
			/* Brief settle so the terminal is ready to receive. */
			k_msleep(100);
			return true;
		}
		k_msleep(100);
		waited += 100;
	}

	return false;
}

static void print_reset_cause(void)
{
	uint32_t cause = 0;

	if (hwinfo_get_reset_cause(&cause) != 0) {
		printk("  reset cause : (unavailable)\r\n");
		return;
	}

	printk("  reset cause : 0x%08x%s%s%s%s%s%s\r\n", cause,
	       (cause & RESET_PIN)      ? " PIN"      : "",
	       (cause & RESET_SOFTWARE) ? " SOFTWARE" : "",
	       (cause & RESET_BROWNOUT) ? " BROWNOUT" : "",
	       (cause & RESET_POR)      ? " POR"      : "",
	       (cause & RESET_WATCHDOG) ? " WATCHDOG" : "",
	       (cause & RESET_DEBUG)    ? " DEBUG"    : "");
}

static void print_device_id(void)
{
	uint8_t id[12];
	ssize_t len = hwinfo_get_device_id(id, sizeof(id));

	if (len <= 0) {
		printk("  device id   : (unavailable)\r\n");
		return;
	}

	printk("  device id   : ");
	for (ssize_t i = 0; i < len; i++) {
		printk("%02x", id[i]);
	}
	printk("\r\n");
}

static void print_banner(void)
{
	printk("\r\n");
	printk("========================================\r\n");
	printk("  ModRetro M64  -  STM32H7A3ZIT6\r\n");
	printk("========================================\r\n");
	printk("  zephyr      : %s\r\n", KERNEL_VERSION_STRING);
	printk("  board       : %s\r\n", CONFIG_BOARD);
	printk("  sys clock   : %u Hz (%u MHz)\r\n",
	       sys_clock_hw_cycles_per_sec(),
	       sys_clock_hw_cycles_per_sec() / 1000000U);
	print_reset_cause();
	print_device_id();
	printk("========================================\r\n\r\n");
}

/* FatFs mount for the SD card on SDMMC1 (disk-name "SD" from the DTS). */
static FATFS fat_fs;
static struct fs_mount_t sd_mnt = {
	.type = FS_FATFS,
	.fs_data = &fat_fs,
	.mnt_point = "/SD:",
};
static bool sd_mounted;

/* Bring up the SD disk and mount its FAT filesystem. Returns 0 on success,
 * a negative errno on failure (e.g. no card inserted). Non-fatal: the app
 * still boots without a card.
 */
static int mount_sd(void)
{
	int rc;

	if (sd_mounted) {
		return 0;
	}

	/* "SD" must match disk-name in the sdmmc node. */
	rc = disk_access_init("SD");
	if (rc != 0) {
		LOG_ERR("SD: disk_access_init failed (%d) - no card?", rc);
		return -EIO;
	}

	rc = fs_mount(&sd_mnt);
	if (rc < 0) {
		LOG_ERR("SD: fs_mount(%s) failed (%d)", sd_mnt.mnt_point, rc);
		return rc;
	}

	sd_mounted = true;
	LOG_INF("SD mounted at %s", sd_mnt.mnt_point);
	return 0;
}

/* Unmount the SD filesystem. Returns 0 on success (or if already
 * unmounted), a negative errno on failure.
 */
static int unmount_sd(void)
{
	int rc;

	if (!sd_mounted) {
		return 0;
	}

	rc = fs_unmount(&sd_mnt);
	if (rc < 0) {
		LOG_ERR("SD: fs_unmount(%s) failed (%d)", sd_mnt.mnt_point, rc);
		return rc;
	}

	sd_mounted = false;
	LOG_INF("SD unmounted from %s", sd_mnt.mnt_point);
	return 0;
}

static int cmd_m64_leds(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	shell_print(sh, "LED on");
	return 0;
}

static int cmd_m64_sd_mount(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	int rc = mount_sd();

	if (rc != 0) {
		shell_error(sh, "mount failed (%d)", rc);
		return rc;
	}
	shell_print(sh, "mounted at %s", sd_mnt.mnt_point);
	return 0;
}

static int cmd_m64_sd_unmount(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	int rc = unmount_sd();

	if (rc != 0) {
		shell_error(sh, "unmount failed (%d)", rc);
		return rc;
	}
	shell_print(sh, "unmounted");
	return 0;
}

/* List directory contents. Usage: m64 sd ls [path]
 * Path defaults to the mount point if omitted.
 */
static int cmd_m64_sd_ls(const struct shell *sh, size_t argc, char **argv)
{
	const char *path = (argc > 1) ? argv[1] : sd_mnt.mnt_point;
	struct fs_dir_t dir;
	int rc;

	if (!sd_mounted) {
		shell_error(sh, "SD not mounted (run 'm64 sd mount')");
		return -ENODEV;
	}

	fs_dir_t_init(&dir);
	rc = fs_opendir(&dir, path);
	if (rc < 0) {
		shell_error(sh, "opendir(%s) failed (%d)", path, rc);
		return rc;
	}

	while (1) {
		struct fs_dirent entry;

		rc = fs_readdir(&dir, &entry);
		if (rc < 0) {
			shell_error(sh, "readdir failed (%d)", rc);
			break;
		}
		if (entry.name[0] == '\0') {
			break;	/* end of directory */
		}

		if (entry.type == FS_DIR_ENTRY_DIR) {
			shell_print(sh, "  <DIR>  %s", entry.name);
		} else {
			shell_print(sh, "  %6zu %s", entry.size, entry.name);
		}
	}

	fs_closedir(&dir);
	return (rc < 0) ? rc : 0;
}

/* Print the contents of a file. Usage: m64 sd cat <path> */
static int cmd_m64_sd_cat(const struct shell *sh, size_t argc, char **argv)
{
	const char *path = argv[1];
	struct fs_file_t file;
	char buf[128];
	ssize_t n;
	int rc;

	if (!sd_mounted) {
		shell_error(sh, "SD not mounted (run 'm64 sd mount')");
		return -ENODEV;
	}

	fs_file_t_init(&file);
	rc = fs_open(&file, path, FS_O_READ);
	if (rc < 0) {
		shell_error(sh, "open(%s) failed (%d)", path, rc);
		return rc;
	}

	/* Stream the file to the shell in chunks. shell_fprintf with a
	 * bounded %.*s avoids assuming NUL-terminated content. */
	while ((n = fs_read(&file, buf, sizeof(buf))) > 0) {
		shell_fprintf(sh, SHELL_NORMAL, "%.*s", (int)n, buf);
	}

	if (n < 0) {
		shell_error(sh, "read failed (%d)", (int)n);
		rc = (int)n;
	} else {
		/* Ensure the prompt starts on a fresh line. */
		shell_fprintf(sh, SHELL_NORMAL, "\n");
		rc = 0;
	}

	fs_close(&file);
	return rc;
}

/* m64 sd usb on|off
 *
 * The SD card's raw blocks are exported to the host via USB Mass Storage
 * (CONFIG_USB_MASS_STORAGE, LUN = "SD"). Zephyr's FatFs and the host cannot
 * own the FAT simultaneously, so this command just manages the local mount:
 *
 *   on  : unmount FatFs so the host owns the card (m64 sd ls/cat stop working)
 *   off : remount FatFs for local access (host should have ejected first)
 *
 * The MSC USB function itself is always enumerated (it comes up at boot with
 * the rest of the USB stack); toggling the mount is what makes host access
 * safe.
 */
static int cmd_m64_sd_usb(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);

	if (strcmp(argv[1], "on") == 0) {
		int rc = unmount_sd();

		if (rc != 0) {
			shell_error(sh, "could not release SD for USB (%d)", rc);
			return rc;
		}
		shell_print(sh, "SD released to USB host (FatFs unmounted).");
		shell_warn(sh, "local 'm64 sd ls/cat' disabled until 'usb off'.");
		return 0;
	}

	if (strcmp(argv[1], "off") == 0) {
		int rc = mount_sd();

		if (rc != 0) {
			shell_error(sh, "remount failed (%d)", rc);
			return rc;
		}
		shell_print(sh, "SD reclaimed locally (FatFs remounted at %s).",
			    sd_mnt.mnt_point);
		return 0;
	}

	shell_error(sh, "usage: m64 sd usb <on|off>");
	return -EINVAL;
}

SHELL_STATIC_SUBCMD_SET_CREATE(m64_sd_cmds,
	SHELL_CMD(mount,   NULL, "Mount the SD card.",       cmd_m64_sd_mount),
	SHELL_CMD(unmount, NULL, "Unmount the SD card.",     cmd_m64_sd_unmount),
	SHELL_CMD_ARG(ls,  NULL, "List a directory: ls [path]",
		      cmd_m64_sd_ls, 1, 1),
	SHELL_CMD_ARG(cat, NULL, "Print a file: cat <path>",
		      cmd_m64_sd_cat, 2, 0),
	SHELL_CMD_ARG(usb, NULL, "Export SD over USB: usb <on|off>",
		      cmd_m64_sd_usb, 2, 0),
	SHELL_SUBCMD_SET_END
);

/* m64 ws2812 <RRGGBB> : shift a 24-bit color into the PA0 WS2812B. */
static int cmd_m64_ws2812(const struct shell *sh, size_t argc, char **argv)
{
	unsigned long v;
	char *end;

	v = strtoul(argv[1], &end, 16);
	if (*end != '\0' || v > 0xFFFFFFUL) {
		shell_error(sh, "expected a 24-bit hex color, e.g. 00ff80");
		return -EINVAL;
	}

	ws2812_send_color((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
	shell_print(sh, "sent #%06lX", v);
	return 0;
}

/* m64 fpgatoggle <pin> : slowly toggle CCLK (pin=clk) or DIN (pin=din) so
 * the pin can be probed at the FPGA to confirm the MCU is driving it.
 * Toggles ~2 Hz for 20 cycles (10 s). Ctrl-C not needed; it returns after.
 */
static int cmd_m64_fpgatoggle(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	bool do_clk = (strcmp(argv[1], "clk") == 0);
	bool do_din = (strcmp(argv[1], "din") == 0);

	if (!do_clk && !do_din) {
		shell_error(sh, "usage: m64 fpgatoggle <clk|din>");
		return -EINVAL;
	}

	shell_print(sh, "toggling %s ~2 Hz for 10 s; probe it at the FPGA...",
		    do_clk ? "CCLK(PF4)" : "DIN(PF0)");

	for (int i = 0; i < 200000; i++) {
		if (do_clk) {
			FPGA_CCLK_PORT->BSRR = (i & 1) ? FPGA_CCLK_SET
						       : FPGA_CCLK_CLR;
		} else {
			FPGA_DIN_PORT->BSRR = (i & 1) ? FPGA_DIN_SET
						      : FPGA_DIN_CLR;
		}
		k_msleep(1);
	}
	/* Leave both idle low. */
	FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR;
	FPGA_DIN_PORT->BSRR = FPGA_DIN_CLR;
	shell_print(sh, "done");
	return 0;
}

/* m64 fpgadrive : drive CCLK/DIN high and low and read the ACTUAL pin level
 * back via the input data register. If the readback doesn't follow what we
 * drive, something else is holding/contending the line (e.g. the flash on the
 * shared OCTOSPI bus, or an alternate-function owner). Works without external
 * probes since we sense the pin electrically via IDR. */
static int cmd_m64_fpgadrive(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	/* Reconfigure both pins as outputs (push-pull) and also allow reading
	 * their input state: Zephyr's GPIO_OUTPUT keeps the input buffer on
	 * for most STM32 configs, so gpio_pin_get_dt reads the live level. */
	struct {
		const char *name;
		const struct gpio_dt_spec *sp;
		uint32_t set, clr;
	} pins[] = {
		{ "CCLK(PF4)", &fpga_cclk, FPGA_CCLK_SET, FPGA_CCLK_CLR },
		{ "DIN(PF0)",  &fpga_din,  FPGA_DIN_SET,  FPGA_DIN_CLR  },
	};

	for (int p = 0; p < 2; p++) {
		(void)gpio_pin_configure_dt(pins[p].sp, GPIO_OUTPUT);

		/* Drive high, read back. */
		(pins[p].sp == &fpga_cclk ? FPGA_CCLK_PORT : FPGA_DIN_PORT)->BSRR
			= pins[p].set;
		k_busy_wait(10);
		int hi = gpio_pin_get_dt(pins[p].sp);

		/* Drive low, read back. */
		(pins[p].sp == &fpga_cclk ? FPGA_CCLK_PORT : FPGA_DIN_PORT)->BSRR
			= pins[p].clr;
		k_busy_wait(10);
		int lo = gpio_pin_get_dt(pins[p].sp);

		shell_print(sh, "%-10s drive1->read %d  drive0->read %d  %s",
			    pins[p].name, hi, lo,
			    (hi == 1 && lo == 0) ? "OK (MCU controls pin)"
					         : "!! readback mismatch - contention?");
	}
	/* Leave idle low. */
	FPGA_CCLK_PORT->BSRR = FPGA_CCLK_CLR;
	FPGA_DIN_PORT->BSRR = FPGA_DIN_CLR;
	return 0;
}

/* m64 fpgapwr on|off : control the FPGA power-enable (for A/B testing). */
static int cmd_m64_fpgapwr(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);

	if (strcmp(argv[1], "on") == 0) {
		(void)gpio_pin_set_dt(&fpga_pwr_en, 1);
		shell_print(sh, "FPGA power ENABLED (pwr_en=1)");
	} else if (strcmp(argv[1], "off") == 0) {
		(void)gpio_pin_set_dt(&fpga_pwr_en, 0);
		shell_print(sh, "FPGA power DISABLED (pwr_en=0)");
	} else {
		shell_error(sh, "usage: m64 fpgapwr <on|off>");
		return -EINVAL;
	}
	return 0;
}

/* m64 fpgastat : probe FPGA power/liveness and report config pin states.
 *
 * A dead or unpowered FPGA will not pull INIT_B low when PROGRAM_B is
 * asserted, nor release it high afterwards. This runs that handshake and
 * reports each transition, plus the static pin levels, without programming.
 */
static int cmd_m64_fpgastat(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	int init0, init1, done_before, done_after;

	/* Static state before poking anything. */
	shell_print(sh, "pwr_en=%d ss_boot_ctrl(strap)=%d",
		    gpio_pin_get_dt(&fpga_pwr_en),
		    gpio_pin_get_dt(&fpga_ss_boot_ctrl));
	shell_print(sh, "before: INIT_B=%d DONE=%d",
		    gpio_pin_get_dt(&fpga_init_b),
		    gpio_pin_get_dt(&fpga_done));
	done_before = gpio_pin_get_dt(&fpga_done);

	/* Assert PROGRAM_B: a live FPGA pulls INIT_B low while clearing. */
	(void)gpio_pin_set_dt(&fpga_program_b, 1);   /* assert (active-low) */
	k_msleep(5);
	init0 = gpio_pin_get_dt(&fpga_init_b);

	/* Release PROGRAM_B: INIT_B should go high once memory is cleared. */
	(void)gpio_pin_set_dt(&fpga_program_b, 0);
	k_msleep(5);
	init1 = gpio_pin_get_dt(&fpga_init_b);
	done_after = gpio_pin_get_dt(&fpga_done);

	shell_print(sh, "PROGRAM_B asserted : INIT_B=%d (expect 0)", init0);
	shell_print(sh, "PROGRAM_B released : INIT_B=%d (expect 1)", init1);
	shell_print(sh, "DONE before/after  : %d / %d", done_before, done_after);

	if (init0 == 0 && init1 == 1) {
		shell_print(sh, "=> FPGA is powered and its config logic responds.");
	} else if (init0 == 1 && init1 == 1) {
		shell_warn(sh, "=> INIT_B never went low: FPGA not responding to "
			       "PROGRAM_B (unpowered? PROGRAM_B not reaching it? "
			       "wrong polarity?).");
	} else {
		shell_warn(sh, "=> Unexpected INIT_B behavior; check wiring/power.");
	}
	return 0;
}

/* m64 fpga [path] [phase] : program the FPGA (Slave-Serial) from a .bin.
 *   phase 0 = sample on rising CCLK edge (default), 1 = falling edge.
 */
static int cmd_m64_fpga(const struct shell *sh, size_t argc, char **argv)
{
	const char *path = (argc > 1) ? argv[1] : "/SD:/fpga.bin";
	int rc;

	if (!sd_mounted) {
		shell_error(sh, "SD not mounted (run 'm64 sd mount')");
		return -ENODEV;
	}

	if (argc > 2) {
		fpga_clk_phase = (atoi(argv[2]) != 0) ? 1 : 0;
	}
	if (argc > 3) {
		fpga_lead_clocks = atoi(argv[3]);
	}
	if (argc > 4) {
		fpga_lsb_first = (atoi(argv[4]) != 0) ? 1 : 0;
	}
	shell_print(sh, "programming (phase %d/%s edge, %d lead bytes, %s-first)...",
		    fpga_clk_phase, fpga_clk_phase ? "falling" : "rising",
		    fpga_lead_clocks, fpga_lsb_first ? "LSB" : "MSB");

	rc = fpga_program_path(path);
	if (rc != 0) {
		shell_error(sh, "FPGA program failed (%d)", rc);
		return rc;
	}
	shell_print(sh, "FPGA programmed from %s", path);
	return 0;
}

/* m64 fpgacrc [path] : read the whole file from SD and report size + CRC32.
 *
 * Compare against the host value (e.g. python3 zlib.crc32) to confirm the SD
 * read path is not corrupting the bitstream. Uses the same 64 KiB burst reads
 * as programming. crc32_ieee() matches the standard/zlib CRC32.
 */
static int cmd_m64_fpgacrc(const struct shell *sh, size_t argc, char **argv)
{
	const char *path = (argc > 1) ? argv[1] : "/SD:/fpga.bin";
	static uint8_t buf[64 * 1024];
	struct fs_file_t file;
	uint32_t crc = 0;
	size_t total = 0;
	ssize_t n;
	int rc;

	if (!sd_mounted) {
		shell_error(sh, "SD not mounted (run 'm64 sd mount')");
		return -ENODEV;
	}

	fs_file_t_init(&file);
	rc = fs_open(&file, path, FS_O_READ);
	if (rc < 0) {
		shell_error(sh, "open(%s) failed (%d)", path, rc);
		return rc;
	}

	while ((n = fs_read(&file, buf, sizeof(buf))) > 0) {
		crc = crc32_ieee_update(crc, buf, (size_t)n);
		total += (size_t)n;
	}
	fs_close(&file);

	if (n < 0) {
		shell_error(sh, "read failed at offset %zu (%d)", total, (int)n);
		return (int)n;
	}

	shell_print(sh, "%s: %zu bytes, CRC32 = 0x%08x", path, total, crc);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(m64_cmds,
	SHELL_CMD(leds, NULL,          "Manipulate LEDs.", cmd_m64_leds),
	SHELL_CMD(sd,   &m64_sd_cmds,  "SD card control.", NULL),
	SHELL_CMD_ARG(ws2812, NULL, "Send color: ws2812 <RRGGBB>",
		      cmd_m64_ws2812, 2, 0),
	SHELL_CMD_ARG(fpga, NULL, "Program FPGA: fpga [path] [phase] [lead] [lsb]",
		      cmd_m64_fpga, 1, 4),
	SHELL_CMD(fpgastat, NULL, "Probe FPGA power/liveness (PROGRAM_B/INIT_B).",
		  cmd_m64_fpgastat),
	SHELL_CMD_ARG(fpgapwr, NULL, "FPGA power: fpgapwr <on|off>",
		      cmd_m64_fpgapwr, 2, 0),
	SHELL_CMD_ARG(fpgatoggle, NULL, "Toggle a config pin: fpgatoggle <clk|din>",
		      cmd_m64_fpgatoggle, 2, 0),
	SHELL_CMD(fpgadrive, NULL, "Drive+readback CCLK/DIN to detect contention.",
		  cmd_m64_fpgadrive),
	SHELL_CMD_ARG(fpgacrc, NULL, "CRC32 a file from SD: fpgacrc [path]",
		      cmd_m64_fpgacrc, 1, 1),
	SHELL_SUBCMD_SET_END
);

SHELL_CMD_REGISTER(m64, &m64_cmds, "M64 specific commands.", NULL);

int main(void)
{
	/*
	 * The USB device stack is brought up automatically at boot
	 * (CONFIG_USB_DEVICE_INITIALIZE_AT_BOOT), and the CDC-ACM port is the
	 * chosen console, so printk()/LOG output goes over USB directly.
	 */

  /* Force the FPGA OFF first so we can bring it up with a clean power-on
   * sequence and a stable mode strap. The FPGA samples M[2:0] at power-up;
   * if it powered up on a previous MCU boot before the strap was driven, it
   * may have latched the wrong mode. Driving pwr_en inactive now, setting the
   * strap, then powering on guarantees M[2:0]=111 is stable across sampling. */
	(void)gpio_pin_configure_dt(&fpga_pwr_en, GPIO_OUTPUT_INACTIVE);
	k_msleep(50);   /* let the FPGA rail fully discharge */

  /* Set FPGA configuration mode to 'Slave Serial' (M[2:0] = 3'b111).
   * PG13 gates two N-FETs wired high-side (1V8 -> FET -> M1/M2). Gate high
   * turns them on, driving M1/M2 to 1V8 = 1; M0 has a fixed pull-up. So
   * PG13 high => M[2:0]=111 (active-high strap control). */
	(void)gpio_pin_configure_dt(&fpga_ss_boot_ctrl, GPIO_OUTPUT_ACTIVE);
  /* Set FPGA programming interface to inactive state (PROGRAM_B deasserted;
   * active-low + open-drain, so this drives the line physically high). */
	(void)gpio_pin_configure_dt(&fpga_program_b, GPIO_OUTPUT_INACTIVE | GPIO_OPEN_DRAIN);
	(void)gpio_pin_configure_dt(&fpga_init_b, GPIO_INPUT);
	(void)gpio_pin_configure_dt(&fpga_done, GPIO_INPUT);

	/* Bit-bang config bus: CCLK (PF4) and DIN (PF0) as push-pull outputs,
	 * both idle low. This also enables the GPIOF port clock. */
	(void)gpio_pin_configure_dt(&fpga_cclk, GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&fpga_din, GPIO_OUTPUT_INACTIVE);

	/* Deselect the config flash (CS# high) so it stays off the shared
	 * CCLK/DIN bus. Active-low, so OUTPUT_INACTIVE drives PG12 high. */
	(void)gpio_pin_configure_dt(&flash_cs, GPIO_OUTPUT_INACTIVE);

	/* Enable various power domains */
	(void)gpio_pin_configure_dt(&vsys_led_on, GPIO_OUTPUT_ACTIVE);
	/* Now power the FPGA on with strap + config pins already stable. */
	(void)gpio_pin_set_dt(&fpga_pwr_en, 1);
	k_msleep(50);   /* allow power-on ramp + initial config sequence */
	/* ctrl_led_data_0 (PA0) is the WS2812B data line: configure as a
	 * push-pull output (this also enables the port clock) and idle low,
	 * then shift in a color via the bit-bang routine below. */
	(void)gpio_pin_configure_dt(&ctrl_led_data_0,  GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_1,  GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_2,  GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_3,  GPIO_OUTPUT_INACTIVE);

	/* Example: mid-brightness cyan (R=0x00, G=0x80, B=0x80). */
	cyccnt_enable();
	ws2812_send_color(0x00, 0x80, 0x80);

	/* Wait (up to 10 s) for the host to open the port so the banner is
	 * not lost, but still boot headless if nobody connects. */
	if (wait_for_dtr(10000)) {
		LOG_INF("host terminal connected (DTR)");
	} else {
		LOG_INF("DTR wait timed out; continuing headless");
	}
	print_banner();

	/* Mount the SD card (non-fatal if absent). */
	(void)mount_sd();

	/* Nothing else to do here: the interactive shell runs in its own
	 * thread on the USB CDC-ACM console. */
	return 0;
}
