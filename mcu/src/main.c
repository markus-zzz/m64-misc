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
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/logging/log.h>
#include <zephyr/version.h>
#include <stdio.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

/* CDC-ACM device backing the console; used here to poll DTR at boot. */
static const struct device *const cdc_dev =
	DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

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

int main(void)
{
	/*
	 * The USB device stack is brought up automatically at boot
	 * (CONFIG_USB_DEVICE_INITIALIZE_AT_BOOT), and the CDC-ACM port is the
	 * chosen console, so printk()/LOG output goes over USB directly.
	 */

	/* Wait (up to 10 s) for the host to open the port so the banner is
	 * not lost, but still boot headless if nobody connects. */
	if (wait_for_dtr(10000)) {
		LOG_INF("host terminal connected (DTR)");
	} else {
		LOG_INF("DTR wait timed out; continuing headless");
	}
	print_banner();

	/* Nothing else to do here: the interactive shell runs in its own
	 * thread on the USB CDC-ACM console. */
	return 0;
}
