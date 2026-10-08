`default_nettype none


module top(
  input wire clk_50mhz,
  output logic [3:0] n64_ctrl_data,
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
    .spi_miso(mcu_spi_io[1]),
    .spi_mosi(mcu_spi_io[0]),
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
  logic [31:0] app_reg_color;

  always_ff @(posedge clk_50mhz) begin
    if (bus_wen) begin
      casex (bus_addr)
        32'h1000_xx00: sys_reg_ctrl  <= bus_wdata;
        32'h2xxx_xx10: app_reg_color <= bus_wdata;
      endcase
    end
  end

  // Scratch RAM
  spram #(
      .ADDR_WIDTH(10),
      .DATA_WIDTH(32)
  ) u_scratch_ram (
      .clk (clk),
      .addr(bus_addr[31:2]),
      .rd_data(bus_rdata),
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
  logic [23:0] rgb;

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
    .rgb(rgb),
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
      .DATA_WIDTH(32)
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

  // Output UART and I2C on controller ports
  assign n64_ctrl_data = {mcu_spi_clk, mcu_spi_ncs, mcu_spi_io[0], uart_tx_shift[0]};

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
  logic [10:0] image_dir_x;
  logic [10:0] image_dir_y;

  logic [23:0] rgb_array [0:128*128-1];
  logic [13:0] rgb_array_idx;
  logic [6:0] rgb_idx_h;
  logic [6:0] rgb_idx_v;
  logic [23:0] rgb_data;
  assign rgb_idx_v = image_pos_y - cy;
  assign rgb_idx_h = image_pos_x - cx;
  assign rgb_data = rgb_array[rgb_array_idx];

  always_ff @(posedge clk_pixel) begin
    rgb_array_idx <= {rgb_idx_v, rgb_idx_h};

    if ((cy > image_pos_y) && (cy <= image_pos_y + 128) && (cx > image_pos_x) && (cx <= image_pos_x + 128)) begin
      // Draw image
      rgb <= rgb_data;
    end
    else begin
      rgb <= (cx[6:0] == 0) || (cy[6:0] == 0) ? app_reg_color[23:0] : 24'h0; // XXX: CDC
    end
  end

  //
  // Crap code to bounce image
  //
  // rst lives in the clk_50mhz domain; synchronize it into clk_pixel before
  // using it as a reset here, otherwise it becomes an unconstrained inter-clock
  // path (setup violation + reset-recovery/metastability hazard).
  //
  logic rst_pixel;
  synch sync_rst_pixel(.i(rst), .o(rst_pixel), .clk(clk_pixel));

  always_ff @(posedge clk_pixel) begin
    if (rst_pixel) begin
      image_pos_x <= 0;
      image_pos_y <= 0;
      image_dir_x <= 1;
      image_dir_y <= 1;
    end
    else if (cx == 0 && cy == 0) begin
      if (image_dir_x == 1 && image_pos_x >= screen_width - 128) image_dir_x <= -1;
      else if ($signed(image_dir_x) == -1 && image_pos_x == 0) image_dir_x <= 1;
      else image_pos_x <= image_pos_x + image_dir_x;

      if (image_dir_y == 1 && image_pos_y >= screen_height - 128) image_dir_y <= -1;
      else if ($signed(image_dir_y) == -1 && image_pos_y == 0) image_dir_y <= 1;
      else image_pos_y <= image_pos_y + image_dir_y;

    end
  end

  initial begin
    $readmemh("/tmp/parrot.dat", rgb_array);
  end

  logic [15:0] audio_array [0:16'hffff];
  logic [15:0] audio_idx;
  initial begin
    $readmemh("/tmp/boing.dat", audio_array);
  end

  always_ff @(posedge clk_audio) begin
    audio_sample_word <= {audio_array[audio_idx], audio_array[audio_idx]};
    audio_idx <= audio_idx + 1;
  end

  //
  // PSRAMs
  //
  psram_slow psram_slow_0 (
    .clk(clk),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(cpu_mem_addr),
    .bus_wdata(),
    .bus_rdata(psram_0_rdata),
    .bus_ren(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h5)),
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
    .bus_wdata(),
    .bus_rdata(psram_1_rdata),
    .bus_ren(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h6)),
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
    .bus_wdata(),
    .bus_rdata(psram_2_rdata),
    .bus_ren(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h7)),
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
    .bus_wdata(),
    .bus_rdata(psram_3_rdata),
    .bus_ren(cpu_mem_valid && (cpu_mem_addr[31:28] == 4'h8)),
    .bus_ack(psram_3_ack),
    // ---- PSRAM pins ----
    .ps_clk(ps3_clk),
    .ps_cen(ps3_cen),
    .ps_dq(ps3_dq[7:0]),
    .ps_dqs(ps3_dqs[0])
  );

endmodule
