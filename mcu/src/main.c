#include <ff.h>
#include <soc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/fs/fs.h>
#include <zephyr/kernel.h>
#include <zephyr/linker/section_tags.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <zephyr/storage/disk_access.h>
#include <zephyr/sys/crc.h>
#include <zephyr/version.h>

LOG_MODULE_REGISTER(m64, LOG_LEVEL_INF);

void leds_setup_pins(void);
void fpga_setup_pins(void);

/* Board GPIO: VSYS LED enable (PG15, active-high). */
static const struct gpio_dt_spec vsys_led_on =
    GPIO_DT_SPEC_GET(DT_NODELABEL(vsys_led_on), gpios);
static const struct gpio_dt_spec fpga_pwr_en =
    GPIO_DT_SPEC_GET(DT_NODELABEL(fpga_pwr_en), gpios);

/* FatFs mount for the SD card on SDMMC1 (disk-name "SD" from the DTS). */
static FATFS fat_fs;
static struct fs_mount_t sd_mnt = {
    .type = FS_FATFS,
    .fs_data = &fat_fs,
    .mnt_point = "/SD:",
};

static bool sd_mounted = false;

/* Bring up the SD disk and mount its FAT filesystem. Returns 0 on success,
 * a negative errno on failure (e.g. no card inserted). Non-fatal: the app
 * still boots without a card.
 */
static int mount_sd(void) {
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
static int unmount_sd(void) {
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

static int cmd_m64_sd_mount(const struct shell *sh, size_t argc, char **argv) {
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

static int cmd_m64_sd_unmount(const struct shell *sh, size_t argc,
                              char **argv) {
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
static int cmd_m64_sd_ls(const struct shell *sh, size_t argc, char **argv) {
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
      break; /* end of directory */
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
static int cmd_m64_sd_cat(const struct shell *sh, size_t argc, char **argv) {
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

SHELL_STATIC_SUBCMD_SET_CREATE(
    m64_sd_cmds, SHELL_CMD(mount, NULL, "Mount the SD card.", cmd_m64_sd_mount),
    SHELL_CMD(unmount, NULL, "Unmount the SD card.", cmd_m64_sd_unmount),
    SHELL_CMD_ARG(ls, NULL, "List a directory: ls [path]", cmd_m64_sd_ls, 1, 1),
    SHELL_CMD_ARG(cat, NULL, "Print a file: cat <path>", cmd_m64_sd_cat, 2, 0),
    SHELL_SUBCMD_SET_END);

/* Distributed subcommand set for the "m64" root command. Other translation
 * units (e.g. fpga.c) append their own subcommands with SHELL_SUBCMD_ADD
 * against parent (m64)
 */
SHELL_SUBCMD_SET_CREATE(m64_cmds, (m64));

SHELL_SUBCMD_ADD((m64), sd, &m64_sd_cmds, "SD card control.", NULL, 1, 0);

SHELL_CMD_REGISTER(m64, &m64_cmds, "M64 specific commands.", NULL);

int main(void) {
  leds_setup_pins();
  fpga_setup_pins();

  /* Enable various power domains */
  (void)gpio_pin_configure_dt(&vsys_led_on, GPIO_OUTPUT_ACTIVE);
  /* Now power the FPGA on with strap + config pins already stable. */
  (void)gpio_pin_configure_dt(&fpga_pwr_en, GPIO_OUTPUT_INACTIVE);
  (void)gpio_pin_set_dt(&fpga_pwr_en, 0);
  k_msleep(50); /* allow power-on ramp + initial config sequence */
  (void)gpio_pin_set_dt(&fpga_pwr_en, 1);
  k_msleep(50); /* allow power-on ramp + initial config sequence */

  /* Mount the SD card (non-fatal if absent). */
  (void)mount_sd();

  /* Nothing else to do here: the interactive shell runs in its own
   * thread on the USB CDC-ACM console. */
  return 0;
}
