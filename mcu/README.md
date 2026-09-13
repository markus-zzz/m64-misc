# ModRetro M64 — Zephyr out-of-tree board

Out-of-tree Zephyr board definition and sample application for the
**STM32H7A3ZIT6** (LQFP144).

- Vendor: `modretro`
- Board:  `m64`

## Layout

```
mcu/
├── CMakeLists.txt              # App build; sets BOARD_ROOT to this dir
├── prj.conf                    # App Kconfig
├── src/main.c                  # Blinky sample (uses led0 alias)
└── boards/modretro/m64/
    ├── board.yml               # Board metadata + SoC (stm32h7a3xx)
    ├── board.cmake             # Flash/debug runners (dfu-util, openocd, cube)
    ├── Kconfig.m64             # BOARD_M64 -> selects SOC_STM32H7A3XX
    ├── m64_defconfig           # Board default Kconfig
    ├── m64.dts                 # Board devicetree  <-- MAIN FILE TO EDIT
    └── m64.yaml                # Twister/test metadata
```

## Before you build: fill in the TODOs

All schematic-specific values live in `boards/modretro/m64/m64.dts`, marked
with `TODO`:

1. **HSE crystal frequency** (`&clk_hse` `clock-frequency`). If there is no
   external crystal, switch the PLL source to HSI and remove the HSE block.
2. **PLL divisors** (`&pll` `div-m`/`mul-n`/`div-p`). `div-m` must bring the
   PLL input into the 1–16 MHz range for your crystal.
3. **Console UART + pins** (`&usart3` and the `chosen` node). Defaults to
   USART3 on PD8/PD9.
4. **LED and button GPIOs** (`leds`/`buttons` nodes). Set correct ports/pins.

## Build

Requires a Zephyr workspace with `ZEPHYR_BASE` set (see Zephyr's getting
started guide). From this directory:

```bash
west build -b m64 .
```

Because `CMakeLists.txt` sets `BOARD_ROOT` to this directory, west finds the
board under `boards/modretro/m64/` automatically. Alternatively:

```bash
west build -b m64 . -- -DBOARD_ROOT=$(pwd)
```

## Flash

Via SWD debug probe (ST-LINK, etc.):

```bash
west flash                        # uses openocd by default
west flash --runner stm32cubeprogrammer
```

Via USB DFU (STM32 system-memory ROM bootloader). Boot the MCU into system
memory (BOOT0 high, then reset) and connect the MCU's own USB port:

```bash
west flash --runner dfu-util
```

A udev rule may be needed for non-root DFU access:

```
# /etc/udev/rules.d/50-stm32-dfu.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="df11", MODE="0666"
```
