/*
 * Copyright (c) 2026 ModRetro
 * SPDX-License-Identifier: Apache-2.0
 *
 * USB CDC-ACM console demo: prints a system-info banner at boot and a
 * live status line every second. Also mirrors to the USART2 console.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/logging/log.h>
#include <stdio.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

static const struct device *const cdc_dev =
	DEVICE_DT_GET(DT_NODELABEL(cdc_acm_uart0));

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

/* Send a string to the USB CDC-ACM console (no-op if not ready). */
static void usb_puts(const char *s)
{
	if (!device_is_ready(cdc_dev)) {
		return;
	}
	while (*s) {
		uart_poll_out(cdc_dev, *s++);
	}
}

static void usb_printf(const char *fmt, ...)
{
	char buf[160];
	va_list ap;

	va_start(ap, fmt);
	vsnprintk(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	usb_puts(buf);
}

static void print_reset_cause(void)
{
	uint32_t cause = 0;

	if (hwinfo_get_reset_cause(&cause) != 0) {
		usb_puts("  reset cause : (unavailable)\r\n");
		return;
	}

	usb_printf("  reset cause : 0x%08x%s%s%s%s%s%s\r\n", cause,
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
		usb_puts("  device id   : (unavailable)\r\n");
		return;
	}

	usb_puts("  device id   : ");
	for (ssize_t i = 0; i < len; i++) {
		usb_printf("%02x", id[i]);
	}
	usb_puts("\r\n");
}

static void print_banner(void)
{
	usb_puts("\r\n");
	usb_puts("========================================\r\n");
	usb_puts("  ModRetro M64  -  STM32H7A3ZIT6\r\n");
	usb_puts("========================================\r\n");
	usb_printf("  zephyr      : %s\r\n", KERNEL_VERSION_STRING);
	usb_printf("  board       : %s\r\n", CONFIG_BOARD);
	usb_printf("  sys clock   : %u Hz (%u MHz)\r\n",
		   sys_clock_hw_cycles_per_sec(),
		   sys_clock_hw_cycles_per_sec() / 1000000U);
	print_reset_cause();
	print_device_id();
	usb_puts("========================================\r\n\r\n");
}

int main(void)
{
	uint32_t count = 0;

	printk("ModRetro M64: USART2 console up (SYSCLK 280 MHz)\n");

	if (device_is_ready(cdc_dev) && usb_enable(NULL) == 0) {
		LOG_INF("USB enabled; CDC-ACM on /dev/ttyACM*");
	} else {
		LOG_ERR("USB CDC-ACM not available");
	}

	/* Wait (up to 10 s) for the host to open the port so the banner is
	 * not lost, but still boot headless if nobody connects. */
	if (wait_for_dtr(10000)) {
		LOG_INF("host terminal connected (DTR)");
	} else {
		LOG_INF("DTR wait timed out; continuing headless");
	}
	print_banner();

	while (1) {
		int64_t up_ms = k_uptime_get();
		uint32_t s = (uint32_t)(up_ms / 1000);

		usb_printf("[#%05u] uptime %02u:%02u:%02u  ticks=%u\r\n",
			   count,
			   s / 3600, (s % 3600) / 60, s % 60,
			   (unsigned int)k_uptime_ticks());

		count++;
		k_msleep(1000);
	}

	return 0;
}
