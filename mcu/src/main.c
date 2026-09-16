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
#include <zephyr/storage/disk_access.h>
#include <zephyr/fs/fs.h>
#include <ff.h>
#include <stdio.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

/* CDC-ACM device backing the console; used here to poll DTR at boot. */
static const struct device *const cdc_dev =
	DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

/* Board GPIO: VSYS LED enable (PG15, active-high). */
static const struct gpio_dt_spec vsys_led_on =
	GPIO_DT_SPEC_GET(DT_NODELABEL(vsys_led_on), gpios);

static const struct gpio_dt_spec ctrl_led_data_0 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_0), gpios);
static const struct gpio_dt_spec ctrl_led_data_1 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_1), gpios);
static const struct gpio_dt_spec ctrl_led_data_2 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_2), gpios);
static const struct gpio_dt_spec ctrl_led_data_3 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(ctrl_led_data_3), gpios);

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

SHELL_STATIC_SUBCMD_SET_CREATE(m64_sd_cmds,
	SHELL_CMD(mount,   NULL, "Mount the SD card.",       cmd_m64_sd_mount),
	SHELL_CMD(unmount, NULL, "Unmount the SD card.",     cmd_m64_sd_unmount),
	SHELL_CMD_ARG(ls,  NULL, "List a directory: ls [path]",
		      cmd_m64_sd_ls, 1, 1),
	SHELL_CMD_ARG(cat, NULL, "Print a file: cat <path>",
		      cmd_m64_sd_cat, 2, 0),
	SHELL_SUBCMD_SET_END
);

SHELL_STATIC_SUBCMD_SET_CREATE(m64_cmds,
	SHELL_CMD(leds, NULL,          "Manipulate LEDs.", cmd_m64_leds),
	SHELL_CMD(sd,   &m64_sd_cmds,  "SD card control.", NULL),
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

	/* Enable various power domains */
	(void)gpio_pin_configure_dt(&vsys_led_on, GPIO_OUTPUT_ACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_0,  GPIO_OUTPUT_ACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_1,  GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_2,  GPIO_OUTPUT_ACTIVE);
	(void)gpio_pin_configure_dt(&ctrl_led_data_3,  GPIO_OUTPUT_INACTIVE);

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
