# SPDX-License-Identifier: Apache-2.0

# Application entry point
cmake_minimum_required(VERSION 3.20.0)

# Point Zephyr at this repo's out-of-tree board directory.
set(BOARD_ROOT ${CMAKE_CURRENT_SOURCE_DIR})

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(m64_app)

target_sources(app PRIVATE src/main.c src/leds.c src/fpga.c)
