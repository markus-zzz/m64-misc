/*
 * Copyright (c) 2026 ModRetro
 * SPDX-License-Identifier: Apache-2.0
 *
 * Console on USART2 (primary). USB CDC-ACM brought up as a secondary
 * output over the USB3300 ULPI HS PHY. USART2 keeps working regardless of
 * whether USB enumerates, so boot/fault visibility is never lost.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

/* CDC-ACM UART instance from the devicetree (child of usbotg_hs). */
static const struct device *const cdc_dev =
	DEVICE_DT_GET(DT_NODELABEL(cdc_acm_uart0));

static void cdc_write_str(const char *s)
{
	if (!device_is_ready(cdc_dev)) {
		return;
	}
	while (*s) {
		uart_poll_out(cdc_dev, *s++);
	}
}

int main(void)
{
	uint32_t count = 0;
	int ret;

	/* USART2 console is already up via the kernel. */
	printk("ModRetro M64: USART2 console up (SYSCLK 280 MHz)\n");

	if (!device_is_ready(cdc_dev)) {
		LOG_ERR("CDC-ACM device not ready");
	} else {
		ret = usb_enable(NULL);
		if (ret != 0) {
			LOG_ERR("usb_enable failed: %d", ret);
		} else {
			LOG_INF("USB enabled; CDC-ACM should enumerate as /dev/ttyACM*");
		}
	}

	while (1) {
		printk("alive %u\n", count);          /* USART2 */
		cdc_write_str("alive over USB CDC-ACM\r\n");  /* USB */
		count++;
		k_msleep(1000);
	}

	return 0;
}
