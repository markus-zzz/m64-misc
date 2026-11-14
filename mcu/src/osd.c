#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/shell/shell.h>

#include "fpga_spi.h"
#include "leds.h"
#include "menu.h"
#include "osd.h"

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

#include <zephyr/kernel.h>
#include <zephyr/sys/reboot.h>

#define POLL_STACK_SIZE 2048
#define POLL_PRIO 5

#define N64_CTRLR_START 0x10000000
#define N64_CTRLR_A 0x80000000
#define N64_CTRLR_B 0x40000000
#define N64_CTRLR_DPAD_UP 0x08000000
#define N64_CTRLR_DPAD_DOWN 0x04000000
#define N64_CTRLR_DPAD_LEFT 0x02000000
#define N64_CTRLR_DPAD_RIGHT 0x01000000

static int osd_active = 0;

static void action_sys_reboot(struct MenuItem *item, void *opaque) { sys_reboot(SYS_REBOOT_COLD); }

static const char *colors_str[] = {"off", "red", "green", "blue", NULL};
static const uint32_t colors_rgb[] = {0x000000, 0xff0000, 0x00ff00, 0x0000ff};

static void action_led_ctrl(struct MenuItem *item, void *opaque) {
  uint8_t port = (uint8_t)(long)opaque;
  uint32_t rgb = colors_rgb[item->opt_idx];
  leds_set_ctrl(port, rgb);
}

#include <zephyr/fs/fs.h>

struct MenuFileBrowserDesc {
  const char *basedir;
  uint32_t bus_addr;
};

static Menu_t *fs_browse_menu = NULL;
static void action_fs_browse_open_file(struct MenuItem *item, void *opaque) {
  struct MenuFileBrowserDesc *desc = (struct MenuFileBrowserDesc *)opaque;
  char path[64];
  snprintf(path, sizeof(path), "%s/%s", desc->basedir, item->str);
  fpga_bus_write_file(desc->bus_addr, path);
  menu_input_back();
}
static void action_fs_browse(struct MenuItem *item, void *opaque) {
  struct MenuFileBrowserDesc *desc = (struct MenuFileBrowserDesc *)opaque;
  menu_action_jump_menu(item, fs_browse_menu);
  menu_item_clear(fs_browse_menu);

  struct fs_dir_t zdp;
  fs_dir_t_init(&zdp);
  if (0 == fs_opendir(&zdp, desc->basedir)) {
    struct fs_dirent entry;
    while (1) {
      if (fs_readdir(&zdp, &entry) != 0)
        break;
      if (entry.name[0] == 0)
        break;
      char *tmp = malloc(strlen(entry.name) + 1); // XXX: Memory leak
      strcpy(tmp, entry.name);
      MenuItem_t *fs_item = menu_item_create(fs_browse_menu, tmp);
      menu_item_set_action(fs_item, action_fs_browse_open_file, opaque);
    }
    fs_closedir(&zdp);
  }
}

static void poll_thread(void *p1, void *p2, void *p3) {

  // Setup basic menu system
  Menu_t *main_menu = menu_create(NULL, "Main Menu");
  Menu_t *led_ctrl_menu = menu_create(main_menu, "LED Control Menu");
  fs_browse_menu = menu_create(main_menu, "File System Browser");

  // Populate 'Main Menu'
  MenuItem_t *led_ctrl_item = menu_item_create(main_menu, "LED Control");
  menu_item_set_action(led_ctrl_item, menu_action_jump_menu, led_ctrl_menu);

  static struct MenuFileBrowserDesc sprite_desc = {.basedir = "/SD:/", .bus_addr = 0x40000000};
  MenuItem_t *fs_browse_sprite_item = menu_item_create(main_menu, "Load Sprite Data");
  menu_item_set_action(fs_browse_sprite_item, action_fs_browse, &sprite_desc);

  static struct MenuFileBrowserDesc audio_desc = {.basedir = "/SD:/", .bus_addr = 0x50000000};
  MenuItem_t *fs_browse_audio_item = menu_item_create(main_menu, "Load Audio Data");
  menu_item_set_action(fs_browse_audio_item, action_fs_browse, &audio_desc);

  MenuItem_t *item_sys_reboot = menu_item_create(main_menu, "System Reboot");
  menu_item_set_action(item_sys_reboot, action_sys_reboot, NULL);

  // Populate 'LED Control Menu'
  MenuItem_t *led_0_item = menu_item_create(led_ctrl_menu, "LED Color Controller Port #0");
  led_0_item->opt_list = colors_str;
  menu_item_set_action(led_0_item, action_led_ctrl, (void *)0); // Port #0

  MenuItem_t *led_1_item = menu_item_create(led_ctrl_menu, "LED Color Controller Port #1");
  led_1_item->opt_list = colors_str;
  menu_item_set_action(led_1_item, action_led_ctrl, (void *)1); // Port #1

  MenuItem_t *led_2_item = menu_item_create(led_ctrl_menu, "LED Color Controller Port #2");
  led_2_item->opt_list = colors_str;
  menu_item_set_action(led_2_item, action_led_ctrl, (void *)2); // Port #2

  MenuItem_t *led_3_item = menu_item_create(led_ctrl_menu, "LED Color Controller Port #3");
  led_3_item->opt_list = colors_str;
  menu_item_set_action(led_3_item, action_led_ctrl, (void *)3); // Port #3

  int64_t next = k_uptime_get();
  uint32_t ctrlr_prev = 0;
  while (1) {
    next += 100;
    k_sleep(K_TIMEOUT_ABS_MS(next)); /* absolute deadline: no drift */
    /* do the poll here */
    uint32_t ctrlr_curr;
    (void)fpga_bus_read32(0x10000104, &ctrlr_curr);
    if (ctrlr_curr == 0xffffffff)
      continue; // No ctrlr connected

    // Handle auto-repeat for navigation keys
    static uint32_t navigation_keys_prev = 0;
    static uint64_t navigation_timeout;
    const uint32_t navigation_mask = 0x0f000000;
    uint32_t navigation_keys = ctrlr_curr & navigation_mask;
    uint64_t uptime = k_uptime_get();
    if (navigation_keys) {
      if (navigation_keys_prev != navigation_keys) {
        navigation_timeout = uptime + 600; // initial delay
      } else if (uptime >= navigation_timeout ) {
        // Fake a pos-edge
        ctrlr_prev &= ~navigation_keys;
        navigation_timeout = uptime + 200; // repeat delay
      }
    }
    navigation_keys_prev = navigation_keys;

    uint32_t ctrlr_down_edge = ~ctrlr_prev & ctrlr_curr;
    uint32_t ctrlr_up_edge = ctrlr_prev & ~ctrlr_curr;

    if (ctrlr_down_edge & N64_CTRLR_START) {
      osd_active = !osd_active;
      osd_enable(osd_active);
    }

    if (osd_active) {
      if (ctrlr_down_edge & N64_CTRLR_DPAD_UP) {
        menu_input_up();
      }
      if (ctrlr_down_edge & N64_CTRLR_DPAD_DOWN) {
        menu_input_down();
      }
      if (ctrlr_down_edge & N64_CTRLR_A) {
        menu_input_select();
      }
      if (ctrlr_down_edge & N64_CTRLR_B) {
        menu_input_back();
      }

      if (ctrlr_up_edge & N64_CTRLR_DPAD_UP) {
      }
      if (ctrlr_up_edge & N64_CTRLR_DPAD_DOWN) {
      }
      menu_draw();
    }

    ctrlr_prev = ctrlr_curr;
  }
}

K_THREAD_DEFINE(osd_poll_tid, POLL_STACK_SIZE, poll_thread, NULL, NULL, NULL, POLL_PRIO, 0,
                K_TICKS_FOREVER);
