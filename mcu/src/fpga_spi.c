/*
 * Pin map (muxed in m64.dts &octospi1):
 *   CLK = PF10   NCS = PE11
 *   IO0 = PF8    IO1 = PF9    IO2 = PF7    IO3 = PF6
 *
 * Mirrors the essential parts of Zephyr's flash_stm32_ospi.c
 * stm32_ospi_init(): enable the peripheral + I/O-manager clocks, apply the
 * pinctrl state, HAL_OSPI_Init(), then HAL_OSPIM_Config() to route the
 * controller to physical I/O port 1.
 */

#include <errno.h>
#include <soc.h>
#include <stdlib.h>
#include <zephyr/device.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(m64_ospi, LOG_LEVEL_INF);

#define OSPI_NODE DT_NODELABEL(octospi1)

PINCTRL_DT_DEFINE(OSPI_NODE);
static const struct pinctrl_dev_config *ospi_pcfg = PINCTRL_DT_DEV_CONFIG_GET(OSPI_NODE);

static OSPI_HandleTypeDef hospi;

#define OSPI_CLOCK_PRESCALER 256U

void fpga_spi_init(void) {
  int rc;

  /* 1. Peripheral + I/O-manager kernel/bus clocks. */
  __HAL_RCC_OSPI1_CLK_ENABLE();
  __HAL_RCC_OCTOSPIM_CLK_ENABLE();

  /* 2. Pin mux (CLK / NCS / IO0..IO3) via Zephyr pinctrl. */
  rc = pinctrl_apply_state(ospi_pcfg, PINCTRL_STATE_DEFAULT);
  if (rc < 0) {
    LOG_ERR("pinctrl apply failed (%d)", rc);
    return;
  }

  /* 3. Core controller init. */
  hospi.Instance = OCTOSPI1;
  hospi.Init.FifoThreshold = 4;
  hospi.Init.DualQuad = HAL_OSPI_DUALQUAD_DISABLE;
  hospi.Init.MemoryType = HAL_OSPI_MEMTYPE_MICRON; /* plain STR framing */
  hospi.Init.DeviceSize = 32;                      /* 4GB address space */
  hospi.Init.ChipSelectHighTime = 2;
  hospi.Init.FreeRunningClock = HAL_OSPI_FREERUNCLK_DISABLE;
  hospi.Init.ClockMode = HAL_OSPI_CLOCK_MODE_0;
  hospi.Init.ClockPrescaler = OSPI_CLOCK_PRESCALER;
  hospi.Init.SampleShifting = HAL_OSPI_SAMPLE_SHIFTING_NONE;
  hospi.Init.DelayHoldQuarterCycle = HAL_OSPI_DHQC_DISABLE;
  hospi.Init.ChipSelectBoundary = 0;
  hospi.Init.DelayBlockBypass = HAL_OSPI_DELAY_BLOCK_BYPASSED;
#if defined(OCTOSPI_DCR2_WRAPSIZE)
  hospi.Init.WrapSize = HAL_OSPI_WRAP_NOT_SUPPORTED;
#endif
  if (HAL_OSPI_Init(&hospi) != HAL_OK) {
    LOG_ERR("HAL_OSPI_Init failed");
    return;
  }

  /* 4. Route the controller to physical I/O port 1. */
  OSPIM_CfgTypeDef m = {0};
  m.ClkPort = 1;
  m.NCSPort = 1;
  m.IOLowPort = HAL_OSPIM_IOPORT_1_LOW;   /* IO0..IO3 */
  m.IOHighPort = HAL_OSPIM_IOPORT_1_HIGH; /* IO4..IO7 (unused, harmless) */
#if defined(OCTOSPIM_CR_MUXEN)
  m.Req2AckTime = 1;
#endif
  if (HAL_OSPIM_Config(&hospi, &m, HAL_OSPI_TIMEOUT_DEFAULT_VALUE) != HAL_OK) {
    LOG_ERR("HAL_OSPIM_Config failed");
    return;
  }

  LOG_INF("OCTOSPI1 up (SCLK = kernel/%u)", OSPI_CLOCK_PRESCALER);
}

static int fpga_read(uint16_t opcode, uint32_t addr, uint8_t *buf, size_t len) {

  OSPI_RegularCmdTypeDef cmd = {
      .OperationType = HAL_OSPI_OPTYPE_COMMON_CFG,
      .FlashId = HAL_OSPI_FLASH_ID_1,
      .Instruction = opcode,
      .InstructionMode = HAL_OSPI_INSTRUCTION_1_LINE,
      .InstructionSize = HAL_OSPI_INSTRUCTION_16_BITS,
      .InstructionDtrMode = HAL_OSPI_INSTRUCTION_DTR_DISABLE,
      .Address = addr,
      .AddressMode = HAL_OSPI_ADDRESS_1_LINE,
      .AddressSize = HAL_OSPI_ADDRESS_32_BITS,
      .AddressDtrMode = HAL_OSPI_ADDRESS_DTR_DISABLE,
      .AlternateBytesMode = HAL_OSPI_ALTERNATE_BYTES_NONE,
      .DataMode = HAL_OSPI_DATA_1_LINE,
      .DataDtrMode = HAL_OSPI_DATA_DTR_DISABLE,
      .NbData = len,
      .DummyCycles = 8,
      .DQSMode = HAL_OSPI_DQS_DISABLE,
      .SIOOMode = HAL_OSPI_SIOO_INST_EVERY_CMD,
  };

  HAL_StatusTypeDef hs = HAL_OSPI_Command(&hospi, &cmd, HAL_OSPI_TIMEOUT_DEFAULT_VALUE);
  if (hs != HAL_OK) {
    LOG_ERR("HAL_OSPI_Command failed: hs=%d state=0x%lx err=0x%lx", (int)hs,
            (unsigned long)hospi.State, (unsigned long)hospi.ErrorCode);
    return -EIO;
  }
  hs = HAL_OSPI_Receive(&hospi, buf, HAL_OSPI_TIMEOUT_DEFAULT_VALUE);
  if (hs != HAL_OK) {
    LOG_ERR("HAL_OSPI_Receive failed: hs=%d state=0x%lx err=0x%lx", (int)hs,
            (unsigned long)hospi.State, (unsigned long)hospi.ErrorCode);
    /* A timed-out / errored transfer leaves the peripheral BUSY or
     * mid-CMD_CFG; abort to return it to READY so the next command
     * doesn't fail with INVALID_SEQUENCE.
     *
     * We issue the abort inline (set CR.ABORT, wait for TC) rather
     * than calling HAL_OSPI_Abort(), because that function pulls in
     * HAL_MDMA_Abort() from its (for us dead) DMA branch, and the
     * MDMA HAL module isn't built in this app. */
    SET_BIT(hospi.Instance->CR, OCTOSPI_CR_ABORT);
    while ((hospi.Instance->SR & OCTOSPI_SR_BUSY) != 0U) {
      /* spin until the peripheral drops BUSY */
    }
    __HAL_OSPI_CLEAR_FLAG(&hospi, HAL_OSPI_FLAG_TC);
    hospi.State = HAL_OSPI_STATE_READY;
    hospi.ErrorCode = HAL_OSPI_ERROR_NONE;
    return -EIO;
  }
  return 0;
}

static int fpga_write(uint16_t opcode, uint32_t addr, uint8_t *buf, size_t len) {

  OSPI_RegularCmdTypeDef cmd = {
      .OperationType = HAL_OSPI_OPTYPE_COMMON_CFG,
      .FlashId = HAL_OSPI_FLASH_ID_1,
      .Instruction = opcode,
      .InstructionMode = HAL_OSPI_INSTRUCTION_1_LINE,
      .InstructionSize = HAL_OSPI_INSTRUCTION_16_BITS,
      .InstructionDtrMode = HAL_OSPI_INSTRUCTION_DTR_DISABLE,
      .Address = addr,
      .AddressMode = HAL_OSPI_ADDRESS_1_LINE,
      .AddressSize = HAL_OSPI_ADDRESS_32_BITS,
      .AddressDtrMode = HAL_OSPI_ADDRESS_DTR_DISABLE,
      .AlternateBytesMode = HAL_OSPI_ALTERNATE_BYTES_NONE,
      .DataMode = HAL_OSPI_DATA_1_LINE,
      .DataDtrMode = HAL_OSPI_DATA_DTR_DISABLE,
      .NbData = len,
      .DummyCycles = 8,
      .DQSMode = HAL_OSPI_DQS_DISABLE,
      .SIOOMode = HAL_OSPI_SIOO_INST_EVERY_CMD,
  };

  HAL_StatusTypeDef hs = HAL_OSPI_Command(&hospi, &cmd, HAL_OSPI_TIMEOUT_DEFAULT_VALUE);
  if (hs != HAL_OK) {
    LOG_ERR("HAL_OSPI_Command failed: hs=%d state=0x%lx err=0x%lx", (int)hs,
            (unsigned long)hospi.State, (unsigned long)hospi.ErrorCode);
    return -EIO;
  }
  hs = HAL_OSPI_Transmit(&hospi, buf, HAL_OSPI_TIMEOUT_DEFAULT_VALUE);
  if (hs != HAL_OK) {
    LOG_ERR("HAL_OSPI_Transmit failed: hs=%d state=0x%lx err=0x%lx", (int)hs,
            (unsigned long)hospi.State, (unsigned long)hospi.ErrorCode);
    /* A timed-out / errored transfer leaves the peripheral BUSY or
     * mid-CMD_CFG; abort to return it to READY so the next command
     * doesn't fail with INVALID_SEQUENCE.
     *
     * We issue the abort inline (set CR.ABORT, wait for TC) rather
     * than calling HAL_OSPI_Abort(), because that function pulls in
     * HAL_MDMA_Abort() from its (for us dead) DMA branch, and the
     * MDMA HAL module isn't built in this app. */
    SET_BIT(hospi.Instance->CR, OCTOSPI_CR_ABORT);
    while ((hospi.Instance->SR & OCTOSPI_SR_BUSY) != 0U) {
      /* spin until the peripheral drops BUSY */
    }
    __HAL_OSPI_CLEAR_FLAG(&hospi, HAL_OSPI_FLAG_TC);
    hospi.State = HAL_OSPI_STATE_READY;
    hospi.ErrorCode = HAL_OSPI_ERROR_NONE;
    return -EIO;
  }
  return 0;
}

static int cmd_fpga_read32(const struct shell *sh, size_t argc, char **argv) {
  uint32_t addr = (uint32_t)strtoul(argv[1], NULL, 0);
  uint32_t data;
  int rc = fpga_read(0x0000, addr, (uint8_t *)&data, sizeof(data));
  if (rc != 0) {
    shell_error(sh, "read failed (%d)", rc);
    return rc;
  }
  data = BSWAP_32(data);
  shell_print(sh, "addr=0x%08x data=0x%08x", addr, data);

  return 0;
}

static int cmd_fpga_write32(const struct shell *sh, size_t argc, char **argv) {
  uint32_t addr = (uint32_t)strtoul(argv[1], NULL, 0);
  uint32_t data = (uint32_t)strtoul(argv[2], NULL, 0);
  data = BSWAP_32(data);
  int rc = fpga_write(0x8000, addr, (uint8_t *)&data, sizeof(data));
  if (rc != 0) {
    shell_error(sh, "write failed (%d)", rc);
    return rc;
  }

  return 0;
}

/* Attach read32/write32 as a children of the shared "m64 fpga" command. The
 * parent set (m64_fpga_cmds) is created in fpga_prg.c with
 * SHELL_SUBCMD_SET_CREATE. */
SHELL_SUBCMD_ADD((m64, fpga), read32, NULL, "read32 <addr>", cmd_fpga_read32, 2, 0);
SHELL_SUBCMD_ADD((m64, fpga), write32, NULL, "write32 <addr> <data>", cmd_fpga_write32, 3, 0);
