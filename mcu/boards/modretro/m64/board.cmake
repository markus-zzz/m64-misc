# SPDX-License-Identifier: Apache-2.0

# dfu-util: STM32 system-memory ROM bootloader (VID:PID 0483:df11).
# Boot the MCU into system memory (BOOT0) before flashing.
board_runner_args(dfu-util "--pid=0483:df11" "--alt=0" "--dfuse")

# openocd / stm32cubeprogrammer for SWD flashing via a debug probe.
board_runner_args(openocd "--target-handle=_CHIPNAME.cpu0")

include(${ZEPHYR_BASE}/boards/common/dfu-util.board.cmake)
include(${ZEPHYR_BASE}/boards/common/openocd.board.cmake)
include(${ZEPHYR_BASE}/boards/common/stm32cubeprogrammer.board.cmake)
