`default_nettype none


module top #(
  parameter string BIOS_INIT_FILE = "bios.vh" // For simulation only (HW loads the BIOS via SPI)
) (
  input wire clk_50mhz,
  inout wire [3:0] n64_ctrl_data,
  // CLOCK IC I2C
  inout wire clk_ctr_scl,
  inout wire clk_ctr_sda,
  // HDMI sink I2C
  inout wire hdmi_ddc_i2c_scl,
  inout wire hdmi_ddc_i2c_sca,
  // MCU <-> FPGA SPI interface
  input wire       mcu_spi_clk,
  input wire       mcu_spi_ncs,
  inout wire [3:0] mcu_spi_io,
  // PSRAM #0
  output wire        ps0_cen,
  output wire        ps0_clk,
  inout  wire [1:0]  ps0_dqs,
  inout  wire [15:0] ps0_dq,
  // PSRAM #1
  output wire        ps1_cen,
  output wire        ps1_clk,
  inout  wire [1:0]  ps1_dqs,
  inout  wire [15:0] ps1_dq,
  // PSRAM #2
  output wire        ps2_cen,
  output wire        ps2_clk,
  inout  wire [1:0]  ps2_dqs,
  inout  wire [15:0] ps2_dq,
  // PSRAM #3
  output wire        ps3_cen,
  output wire        ps3_clk,
  inout  wire [1:0]  ps3_dqs,
  inout  wire [15:0] ps3_dq,
  // HDMI retimer
  output wire hdmi_out_en, // Power
  output wire hdmi_tx0_oe,
  // HDMI TMDS via GTH transceivers -> SN75DP159 redriver.
  input  wire       hdmi_mgtrefclk_p,   // 148.5 MHz from external PLL
  input  wire       hdmi_mgtrefclk_n,
  output wire [2:0] hdmi_tx_p,          // 3 TMDS data lanes
  output wire [2:0] hdmi_tx_n,
  output wire       hdmi_clk_p,         // TMDS clock lane
  output wire       hdmi_clk_n
);
  // -------------------
  // MCU SPI interface
  // -------------------
  logic [31:0] bus_addr;
  logic [31:0] bus_rdata;
  logic [31:0] bus_wdata;
  logic        bus_ren;
  logic        bus_wen;

  spi_slave u_spi_slave (
		.clk(clk_50mhz),
    .spi_cs_n(mcu_spi_ncs),
    .spi_clk(mcu_spi_clk),
    .spi_io(mcu_spi_io),
    .bus_addr(bus_addr),
    .bus_rdata(bus_rdata),
    .bus_wdata(bus_wdata),
    .bus_ren(bus_ren),
    .bus_wen(bus_wen)
  );

  // sys_reg_ctrl[0] is the CPU reset (rst). Power-on/config value holds the
  // CPU in reset until the MCU explicitly releases it by writing 0. Without a
  // non-zero init the CPU is released the instant configuration completes,
  // with no guaranteed reset pulse, so PicoRV32 never loads its PC.
  logic [31:0] sys_reg_ctrl = 32'h0000_0001;
  logic [31:0] osd_ctrl;
  logic osd_active, osd_pixel;

  always_ff @(posedge clk_50mhz) begin
    if (bus_wen) begin
      casex (bus_addr)
        32'h1000_0000: sys_reg_ctrl <= bus_wdata;
        32'h1000_0010: osd_ctrl <= bus_wdata;
      endcase
    end
  end

  logic [31:0] scratch_ram_rdata;
  always_comb begin
    casex (bus_addr)
      32'h1000_0100: bus_rdata = joybus_rdata; // Ctrl #0
      32'h1000_0104: bus_rdata = joybus_rdata; // Ctrl #1
      32'h1000_0108: bus_rdata = joybus_rdata; // Ctrl #2
      32'h1000_010c: bus_rdata = joybus_rdata; // Ctrl #3
      default: bus_rdata = scratch_ram_rdata;
    endcase
  end

  // Scratch RAM
  spram #(
      .ADDR_WIDTH(10),
      .DATA_WIDTH(32)
  ) u_scratch_ram (
      .clk (clk),
      .addr(bus_addr[31:2]),
      .rd_data(scratch_ram_rdata),
      .wr_data(bus_wdata),
      .wr_en(bus_wen && (bus_addr[31:28] == 4'h3))
  );

  // ---------------------------------------------------------------------------
  // Free-running clock (~25 MHz) for the GT reset controller / DRP, derived
  // from the 50 MHz board clock. Must be independent of the GT.
  // ---------------------------------------------------------------------------
  wire clk_50_buf;
  BUFG bufg_50 (.I(clk_50mhz), .O(clk_50_buf));

  logic freerun_toggle = 1'b0;
  always_ff @(posedge clk_50_buf)
    freerun_toggle <= ~freerun_toggle;   // 25 MHz
  wire freerun_clk;
  BUFG bufg_freerun (.I(freerun_toggle), .O(freerun_clk));

  // ---------------------------------------------------------------------------
  // GT TX back-end. Produces txusrclk2 (37.125 MHz); we build the 148.5 MHz
  // pixel clock as 4x that with an MMCM so the symbol packer is phase-coherent.
  // ---------------------------------------------------------------------------
  wire        tx_ready;
  wire        tx_reset_done;      // gtwiz_reset_tx_done (includes CPLL lock)
  wire        tx_userclk_active;  // TX user clock network active
  // CPU-controlled GT reset. The GT powers up before the CPU configures the
  // 8T49N241, so it initially fails to lock (no valid refclk). Firmware pulses
  // this after clock config so the GT re-runs its reset/lock sequence against
  // a now-valid 148.5 MHz reference. Default asserted (hold GT in reset until
  // firmware releases it).
  logic       gt_reset = 1'b1;
  wire        txusrclk2;
  logic       clk_pixel;

  logic [9:0] tmds_symbols [2:0];

  // MMCM: 37.125 MHz -> 148.5 MHz pixel clock.
  //   VCO = 37.125 * 24 = 891 MHz (in range); pixel = 891 / 6 = 148.5 MHz.
  wire clk_pixel_raw, mmcm_fb, mmcm_locked;
  MMCME4_BASE #(
    .CLKIN1_PERIOD(26.936),        // 37.125 MHz
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT_F(24.000),      // VCO = 891 MHz
    .CLKOUT0_DIVIDE_F(6.000),      // 148.5 MHz
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.0)
  ) pixel_mmcm (
    .CLKOUT0(clk_pixel_raw), .CLKOUT0B(),
    .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .CLKFBOUT(mmcm_fb), .CLKFBOUTB(),
    .LOCKED(mmcm_locked),
    .CLKIN1(txusrclk2),
    .PWRDWN(1'b0), .RST(~tx_ready),
    .CLKFBIN(mmcm_fb)
  );
  BUFG bufg_pixel (.I(clk_pixel_raw), .O(clk_pixel));

  // Reset for the HDMI core: released once GT is up and the pixel MMCM locks.
  logic [3:0] reset_sync = 4'hF;
  always_ff @(posedge clk_pixel or negedge mmcm_locked) begin
    if (!mmcm_locked)
      reset_sync <= 4'hF;
    else
      reset_sync <= {reset_sync[2:0], ~tx_ready};
  end
  logic hdmi_reset;
  assign hdmi_reset = reset_sync[3];

  // ---------------------------------------------------------------------------
  // Demo video + audio (mirrors hdmi/top/top.sv), now at 148.5 MHz / 1080p.
  // ---------------------------------------------------------------------------
  logic [15:0] audio_sample_word [1:0] = '{16'd0, 16'd0};
  logic clk_audio;
  logic [11:0] audio_div = 12'd0;
  logic        clk_audio_r = 1'b0;
  always_ff @(posedge clk_pixel) begin
    audio_div <= audio_div + 12'd1;
    if (audio_div == 12'd1546) begin   // ~148.5MHz / 3094 ~= 48 kHz
      audio_div   <= 12'd0;
      clk_audio_r <= ~clk_audio_r;
    end
  end
  assign clk_audio = clk_audio_r;

  logic [11:0] cx;
  logic [10:0] cy;
  logic [11:0] screen_width, frame_width;
  logic [10:0] screen_height, frame_height;
  logic [23:0] rgb, rgb_out;

  logic [2:0] tmds_unused;
  logic       tmds_clock_unused;

  hdmi #(
    .VIDEO_ID_CODE(16),          // 1080p60
    .VIDEO_REFRESH_RATE(60.0),
    .AUDIO_RATE(48000),
    .AUDIO_BIT_WIDTH(16),
    .SERIALIZE(0)                // use the external GTH serializer
  ) hdmi (
    .clk_pixel_x5(1'b0),         // unused: serialization is done by the GT
    .clk_pixel(clk_pixel),
    .clk_audio(clk_audio),
    .reset(hdmi_reset),
    .rgb(rgb_out),
    .audio_sample_word(audio_sample_word),
    .tmds(tmds_unused),
    .tmds_clock(tmds_clock_unused),
    .tmds_symbols(tmds_symbols),
    .cx(cx),
    .cy(cy),
    .frame_width(frame_width),
    .frame_height(frame_height),
    .screen_width(screen_width),
    .screen_height(screen_height)
  );

  hdmi_gth_tx_top gth_tx (
    .mgtrefclk_p(hdmi_mgtrefclk_p),
    .mgtrefclk_n(hdmi_mgtrefclk_n),
    .freerun_clk(freerun_clk),
    .reset(gt_reset),
    .clk_pixel(clk_pixel),
    .tmds_symbols(tmds_symbols),
    .tmds_data_p(hdmi_tx_p),
    .tmds_data_n(hdmi_tx_n),
    .tmds_clk_p(hdmi_clk_p),
    .tmds_clk_n(hdmi_clk_n),
    .tx_ready(tx_ready),
    .tx_reset_done_out(tx_reset_done),
    .tx_userclk_active_out(tx_userclk_active),
    .txusrclk2_out(txusrclk2)
  );

  logic clk, rst;
  assign clk = clk_50mhz;
  assign rst = sys_reg_ctrl[0];
  // XXX: Put the entire CPU subsystem in its own module
  logic cpu_mem_valid;
  logic cpu_mem_instr;
  logic cpu_mem_ready;
  logic [31:0] cpu_mem_addr;
  logic [31:0] cpu_mem_wdata;
  logic [3:0]  cpu_mem_wstrb;
  logic [31:0] cpu_mem_rdata;
  logic [31:0] ram_rdata;
  logic [31:0] rom_rdata;

  logic [31:0] psram_0_rdata;
  logic [31:0] psram_1_rdata;
  logic [31:0] psram_2_rdata;
  logic [31:0] psram_3_rdata;
  logic psram_0_ack;
  logic psram_1_ack;
  logic psram_2_ack;
  logic psram_3_ack;

  // CPU ROM
  spram #(
      .ADDR_WIDTH(10),
      .DATA_WIDTH(32),
      .INIT_FILE(BIOS_INIT_FILE) // For simulation only (HW loads the BIOS via SPI)
  ) u_rom (
      .clk (clk),
      .addr(rst ? bus_addr[31:2] : cpu_mem_addr[31:2]),
      .rd_data(rom_rdata),
      .wr_data({bus_wdata[7:0], bus_wdata[15:8], bus_wdata[23:16], bus_wdata[31:24]}),
      .wr_en(bus_wen && (bus_addr[31:16] == 16'h1001))
  );

  // CPU RAM
  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : ram
      spram #(
          .ADDR_WIDTH(10),
          .DATA_WIDTH(8)
      ) u_ram (
          .clk (clk),
          .addr(cpu_mem_addr[31:2]),
          .rd_data(ram_rdata[(gi+1)*8-1:gi*8]),
          .wr_data(cpu_mem_wdata[(gi+1)*8-1:gi*8]),
          .wr_en  (cpu_mem_wstrb[gi] && (cpu_mem_valid && cpu_mem_addr[31:28] == 4'h1))
      );
    end
  endgenerate

  // CPU
  picorv32 #(
      .COMPRESSED_ISA(1),
      .ENABLE_MUL(1),
      .ENABLE_DIV(1)
  ) u_cpu (
      .clk(clk),
      .resetn(~rst),
      // PicoRV32 Native Memory Interface
      .mem_valid(cpu_mem_valid),
      .mem_instr(cpu_mem_instr),
      .mem_ready(cpu_mem_ready),
      .mem_addr (cpu_mem_addr),
      .mem_wdata(cpu_mem_wdata),
      .mem_wstrb(cpu_mem_wstrb),
      .mem_rdata(cpu_mem_rdata)
  );

  // ---------------------------------------------------------------------------
  // GT TX status, synchronized into the CPU clock domain for readback.
  // These are level signals from the GT/txusrclk2 domain; a 2-FF synchronizer
  // is sufficient. Readable at 0x2000_001C:
  //   bit0 = tx_ready          (tx_reset_done & tx_userclk_active)
  //   bit1 = tx_reset_done     (GT TX reset FSM done -> implies CPLL locked)
  //   bit2 = tx_userclk_active (TX user clock network up)
  // ---------------------------------------------------------------------------
  logic [2:0] gt_stat_meta = 3'b0;
  logic [2:0] gt_stat      = 3'b0;
  always_ff @(posedge clk) begin
    gt_stat_meta <= {tx_userclk_active, tx_reset_done, tx_ready};
    gt_stat      <= gt_stat_meta;
  end

  logic [31:0] joybus_rdata;

  logic busy;
  always_comb begin
    casex (cpu_mem_addr)
      32'h0xxx_xxxx: cpu_mem_rdata = rom_rdata;
      32'h1xxx_xxxx: cpu_mem_rdata = ram_rdata;
      // Peripheral registers: fully decode the low byte (no 'x' in the offset)
      // so that e.g. 0x14/0x18/0x1c are not shadowed by 0x_4/0x_8/0x_c.
      32'h2xxx_xx04: cpu_mem_rdata = {31'h0, busy};
      32'h2xxx_xx08: cpu_mem_rdata = {30'h0, hdmi_ddc_i2c_scl, clk_ctr_scl};
      32'h2xxx_xx0c: cpu_mem_rdata = {30'h0, hdmi_ddc_i2c_sca, clk_ctr_sda};
      32'h2xxx_xx1c: cpu_mem_rdata = {29'h0, gt_stat}; // GT TX status bits
      32'h5xxx_xxxx: cpu_mem_rdata = psram_0_rdata;
      32'h6xxx_xxxx: cpu_mem_rdata = psram_1_rdata;
      32'h7xxx_xxxx: cpu_mem_rdata = psram_2_rdata;
      32'h8xxx_xxxx: cpu_mem_rdata = psram_3_rdata;
      32'h9xxx_xxxx: cpu_mem_rdata = joybus_rdata;
      default: cpu_mem_rdata = 0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) cpu_mem_ready <= 0;
    else begin
      casex (cpu_mem_addr)
        32'h0xxx_xxxx: cpu_mem_ready <= ~cpu_mem_ready & cpu_mem_valid;
        32'h1xxx_xxxx: cpu_mem_ready <= ~cpu_mem_ready & cpu_mem_valid;
        32'h2xxx_xxxx: cpu_mem_ready <= ~cpu_mem_ready & cpu_mem_valid;
        32'h5xxx_xxxx: cpu_mem_ready <= psram_0_ack & cpu_mem_valid;
        32'h6xxx_xxxx: cpu_mem_ready <= psram_1_ack & cpu_mem_valid;
        32'h7xxx_xxxx: cpu_mem_ready <= psram_2_ack & cpu_mem_valid;
        32'h8xxx_xxxx: cpu_mem_ready <= psram_3_ack & cpu_mem_valid;
        32'h9xxx_xxxx: cpu_mem_ready <= ~cpu_mem_ready & cpu_mem_valid;
        default:       cpu_mem_ready <= 0;
      endcase
    end
  end

  // Simple UART (tx only) 8N1 at 115200
  localparam PRESCALE = 50_000_000 / 115200;
  logic [9:0] uart_tx_shift;
  logic [$clog2(PRESCALE)-1:0] prescale_cntr;
  logic [3:0] shift_cntr;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 0;
      uart_tx_shift[0] <= 1'b1; // Line idle state
    end else if (cpu_mem_valid && cpu_mem_addr == 32'h2000_0000 && cpu_mem_wstrb == 4'b1111) begin
      prescale_cntr <= 0;
      shift_cntr <= 0;
      uart_tx_shift <= {1'b1, cpu_mem_wdata[7:0], 1'b0}; // Stop, data, Start
      busy <= 1;
    end else begin
      prescale_cntr <= prescale_cntr + 1;
      if (prescale_cntr == PRESCALE - 1) begin
        prescale_cntr <= 0;
        shift_cntr <= shift_cntr + 1;
        uart_tx_shift <= {1'b1, uart_tx_shift[9:1]};
        if (shift_cntr == 9) begin
          busy <= 0;
        end
      end
    end
  end

  // The two I2C registers cover SCL and SDA for up to 16 isolated I2C buses.
  // The lower 16-bit of each register is push-buttons for driving 'Z' while the
  // upper 16-bits are push-buttons for driving '0'. Pushing one button pops the
  // other.
  logic [15:0] r_clk_ctr_scl_0;
  logic [15:0] r_clk_ctr_sda_0;

  assign clk_ctr_scl = r_clk_ctr_scl_0[0] ? 1'b0 : 1'bz;
  assign clk_ctr_sda = r_clk_ctr_sda_0[0] ? 1'b0 : 1'bz;

  assign hdmi_ddc_i2c_scl = r_clk_ctr_scl_0[1] ? 1'b0 : 1'bz;
  assign hdmi_ddc_i2c_sca = r_clk_ctr_sda_0[1] ? 1'b0 : 1'bz;

  always_ff @(posedge clk) begin
    if (rst) begin
      r_clk_ctr_scl_0 <= 0;
      r_clk_ctr_sda_0 <= 0;
      gt_reset <= 1'b1; // hold GT in reset until firmware configures the clock
    end else if (cpu_mem_valid && cpu_mem_wstrb == 4'b1111) begin
      casex (cpu_mem_addr)
        32'h2000_0008:r_clk_ctr_scl_0 <= (r_clk_ctr_scl_0 & ~cpu_mem_wdata[15:0]) | cpu_mem_wdata[31:16];
        32'h2000_000c:r_clk_ctr_sda_0 <= (r_clk_ctr_sda_0 & ~cpu_mem_wdata[15:0]) | cpu_mem_wdata[31:16];
        32'h2000_0024: gt_reset <= cpu_mem_wdata[0];
      endcase
    end
  end

  assign hdmi_out_en = 1'b1;
  assign hdmi_tx0_oe = 1'b1;

  //
  // Bouncing parrot
  //

  logic [10:0] image_pos_x;
  logic [10:0] image_pos_y;

  always_ff @(posedge clk) begin
    if (rst) begin
    end else if (cpu_mem_valid && cpu_mem_wstrb == 4'b1111) begin
      if (cpu_mem_addr == 32'h2001_0000) begin
        image_pos_x <= cpu_mem_wdata[15:0];
        image_pos_y <= cpu_mem_wdata[31:16];
      end
    end
  end

  logic [23:0] rgb_array [0:128*128-1];
  logic [13:0] rgb_array_idx;
  logic [6:0] rgb_idx_h;
  logic [6:0] rgb_idx_v;
  logic [23:0] rgb_data;
  assign rgb_idx_v = image_pos_y - cy;
  assign rgb_idx_h = image_pos_x - cx;
  assign rgb_data = rgb_array[rgb_array_idx];

  always_ff @(posedge clk) begin
    if (bus_wen && (bus_addr[31:28] == 4'h4))
      rgb_array[bus_addr[31:2]] <= bus_wdata;
  end

  always_ff @(posedge clk_pixel) begin
    rgb_array_idx <= {rgb_idx_v, rgb_idx_h};
    rgb <= 24'h0;
    if ((cy > image_pos_y) && (cy <= image_pos_y + 128) && (cx > image_pos_x) && (cx <= image_pos_x + 128)) begin
      rgb <= rgb_data; // Draw image
    end
    else begin
      rgb <= (cx[6:0] == 0) || (cy[6:0] == 0) ? 24'hffffff : 24'h0;
    end
  end

  always_ff @(posedge clk_pixel) begin
    rgb_out <= rgb;
    if (osd_active) begin
      rgb_out <= {2'h0, rgb[23:18], 2'h0, rgb[15:10], 2'h0, rgb[7:2]};
      if (osd_pixel) rgb_out <= 24'hffffff;
    end
  end

  logic [15:0] audio_array [0:16'hffff];
  logic [15:0] audio_idx;

  always_ff @(posedge clk) begin
    if (bus_wen && (bus_addr[31:28] == 4'h5))
      audio_array[bus_addr[31:2]] <= bus_wdata;
  end

  logic [31:0] joybus_rdata_audio[3];
  always_ff @(posedge clk_audio) begin
    joybus_rdata_audio[0] <= joybus_rdata;
    joybus_rdata_audio[1] <= joybus_rdata_audio[0];
    joybus_rdata_audio[2] <= joybus_rdata_audio[1];

    audio_sample_word <= {audio_array[audio_idx], audio_array[audio_idx]};

    if ((joybus_rdata_audio[1] & ~joybus_rdata_audio[2]) & (1 << 29)) audio_idx <= 0;
    else if (audio_idx != 16'hffff) audio_idx <= audio_idx + 1;
  end

  //
  // PSRAMs
  //
  psram_slow psram_slow_0 (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_wdata(cpu_mem_wdata),
    .bus_rdata(psram_0_rdata),
    .bus_wstrb(cpu_mem_wstrb),
    .bus_valid(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h5)),
    .bus_ack(psram_0_ack),
    // ---- PSRAM pins ----
    .ps_clk(ps0_clk),
    .ps_cen(ps0_cen),
    .ps_dq(ps0_dq[7:0]),
    .ps_dqs(ps0_dqs[0])
  );
  psram_slow psram_slow_1 (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_wdata(cpu_mem_wdata),
    .bus_rdata(psram_1_rdata),
    .bus_wstrb(cpu_mem_wstrb),
    .bus_valid(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h6)),
    .bus_ack(psram_1_ack),
    // ---- PSRAM pins ----
    .ps_clk(ps1_clk),
    .ps_cen(ps1_cen),
    .ps_dq(ps1_dq[7:0]),
    .ps_dqs(ps1_dqs[0])
  );
  psram_slow psram_slow_2 (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_wdata(cpu_mem_wdata),
    .bus_rdata(psram_2_rdata),
    .bus_wstrb(cpu_mem_wstrb),
    .bus_valid(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h7)),
    .bus_ack(psram_2_ack),
    // ---- PSRAM pins ----
    .ps_clk(ps2_clk),
    .ps_cen(ps2_cen),
    .ps_dq(ps2_dq[7:0]),
    .ps_dqs(ps2_dqs[0])
  );
  psram_slow psram_slow_3 (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_wdata(cpu_mem_wdata),
    .bus_rdata(psram_3_rdata),
    .bus_wstrb(cpu_mem_wstrb),
    .bus_valid(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h8)),
    .bus_ack(psram_3_ack),
    // ---- PSRAM pins ----
    .ps_clk(ps3_clk),
    .ps_cen(ps3_cen),
    .ps_dq(ps3_dq[7:0]),
    .ps_dqs(ps3_dqs[0])
  );

  //
  // N64 controllers (joybus)
  //
  wire joybus_1;
  joybus_ctrl joybus (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_rdata(joybus_rdata),
    .bus_wdata(cpu_mem_wdata),
    .bus_wstrb((cpu_mem_valid && cpu_mem_addr[31:28] == 4'h9) ? cpu_mem_wstrb : 4'b0000),
    // ---- N64 controller pins ----
    .joybus_io(joybus_1)
  );

  // Be careful to avoid merging 'inout' nets
  logic joybus_1_ff;
  always_ff @(posedge clk) joybus_1_ff <= n64_ctrl_data[1];

  assign n64_ctrl_data = {mcu_spi_clk, joybus_1_ff, joybus_1, uart_tx_shift[0]};

  //
  // On Screen Display (OSD) Overlay 64x32
  //
  localparam integer RES_X = 1920;
  localparam integer RES_Y = 1080;
  localparam integer OSD_W = 64*16;
  localparam integer OSD_H = 32*16;

  localparam integer BAR_WEST  = RES_X/2-OSD_W/2;
  localparam integer BAR_EAST  = RES_X/2+OSD_W/2;
  localparam integer BAR_NORTH = RES_Y/2-OSD_H/2;
  localparam integer BAR_SOUTH = RES_Y/2+OSD_H/2;

  logic [14:0] screen_pos, screen_pos_plus_one, screen_pos_prev;
  logic screen_pos_inc;
  logic [3:0] row;
  logic osd_v_active, osd_h_active;
  assign osd_active = osd_ctrl[0] & osd_v_active & osd_h_active;
  assign screen_pos_plus_one = screen_pos + 1;
  always @(posedge clk_pixel) begin
    if (osd_active) screen_pos <= screen_pos_plus_one;

    if (cx == BAR_WEST) begin
      osd_h_active <= 1;
    end else if (cx == BAR_EAST) begin
      if (row == 15)  screen_pos_prev <= screen_pos_plus_one;
      else screen_pos <= screen_pos_prev;
      osd_h_active <= 0;
      row <= row + 1;
    end

    if (cy == BAR_NORTH) begin
      row <= 0;
      osd_v_active <= 1;
      screen_pos <= 0;
      screen_pos_prev <= 0;
    end else if (cy == BAR_SOUTH) begin
      osd_v_active <= 0;
    end
  end

  // Screen RAM 64x32x8 (2KB)
  logic [31:0] screen_dword;
  logic [7:0] screen_char;
  logic [1:0] screen_char_idx;
  always_ff @(posedge clk_pixel) screen_char_idx <= screen_pos[5:4];
  assign screen_char = screen_dword[(3-screen_char_idx)*8+:8];
  dpram #(
    .ADDR_WIDTH(9),
    .DATA_WIDTH(32)
  ) u_osd_screen_ram (
    .rd_clk(clk_pixel),
    .rd_addr(screen_pos[14:6]),
    .rd_data(screen_dword),
    .wr_clk(clk),
    .wr_addr(bus_addr[31:2]),
    .wr_data(bus_wdata),
    .wr_en(bus_wen && (bus_addr[31:16] == 16'h1002))
  );
  // Character Set RAM 128x16x16 (4KB)
  logic [31:0] char_dword;
  logic [15:0] char;
  assign char = char_dword[row[0]*16+:16];
  dpram #(
    .ADDR_WIDTH(10),
    .DATA_WIDTH(32)
  ) u_osd_charset_ram (
    .rd_clk(clk_pixel),
    .rd_addr({screen_char[6:0], row[3:1]}),
    .rd_data(char_dword),
    .wr_clk(clk),
    .wr_addr(bus_addr[31:2]),
    .wr_data(bus_wdata),
    .wr_en(bus_wen && (bus_addr[31:16] == 16'h1003))
  );

  logic [15:0] char_shift;
  always_ff @(posedge clk_pixel) begin
    if (screen_pos[3:0] == 4'h5) char_shift <= screen_char[7] ? ~char : char;
    else char_shift <= {char_shift[14:0], 1'b0};
  end

  always_ff @(posedge clk_pixel) osd_pixel <= osd_active & char_shift[15];

endmodule
