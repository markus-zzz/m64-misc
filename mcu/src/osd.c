#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/shell/shell.h>

#include "fpga_spi.h"
#include "osd.h"

#define OSD_WIDTH 64
#define ODS_HEIGHT 32

static char osdbuf[2048];

int osd_printf(unsigned x, unsigned y, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int rc = vsnprintf(&osdbuf[y * OSD_WIDTH + x], OSD_WIDTH - x, fmt, ap);
  va_end(ap);
  return rc;
}

void osd_invert(unsigned x, unsigned y, unsigned len) {
  for (unsigned i = 0; i < MIN(len, OSD_WIDTH - x); i++) {
    osdbuf[y * OSD_WIDTH + x + i] ^= 0x80;
  }
}

void osd_clear(void) { memset(osdbuf, 0, sizeof(osdbuf)); }

void osd_flush(void) { fpga_bus_write(0x10020000, osdbuf, sizeof(osdbuf)); }

void osd_enable(int enable) { fpga_bus_write32(0x10000010, enable != 0); }

static int cmd_osd_print(const struct shell *sh, size_t argc, char **argv) {
  unsigned x = (unsigned)strtoul(argv[1], NULL, 0);
  unsigned y = (unsigned)strtoul(argv[2], NULL, 0);
  osd_printf(x, y, argv[3]);
  osd_flush();
  return 0;
}

static int cmd_osd_invert(const struct shell *sh, size_t argc, char **argv) {
  unsigned x = (unsigned)strtoul(argv[1], NULL, 0);
  unsigned y = (unsigned)strtoul(argv[2], NULL, 0);
  unsigned len = (unsigned)strtoul(argv[3], NULL, 0);
  osd_invert(x, y, len);
  osd_flush();
  return 0;
}

static int cmd_osd_clear(const struct shell *sh, size_t argc, char **argv) {
  osd_clear();
  osd_flush();
  return 0;
}

static int cmd_osd_on(const struct shell *sh, size_t argc, char **argv) {
  osd_enable(1);
  return 0;
}

static int cmd_osd_off(const struct shell *sh, size_t argc, char **argv) {
  osd_enable(0);
  return 0;
}

SHELL_SUBCMD_SET_CREATE(m64_osd_cmds, (m64, osd));
SHELL_SUBCMD_ADD((m64), osd, &m64_osd_cmds, "OSD Overlay control.", NULL, 1, 0);
SHELL_SUBCMD_ADD((m64, osd), print, NULL, "print <x> <y> <str>", cmd_osd_print, 4, 0);
SHELL_SUBCMD_ADD((m64, osd), invert, NULL, "invert <x> <y> <len>", cmd_osd_invert, 4, 0);
SHELL_SUBCMD_ADD((m64, osd), clear, NULL, "clear", cmd_osd_clear, 1, 0);
SHELL_SUBCMD_ADD((m64, osd), on, NULL, "on", cmd_osd_on, 1, 0);
SHELL_SUBCMD_ADD((m64, osd), off, NULL, "off", cmd_osd_off, 1, 0);
