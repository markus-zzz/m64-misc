`default_nettype none


module top(
  input wire clk_50mhz,
  input wire rst_din,
  output logic [3:0] n64_ctrl_data,
  // HDMI TMDS via GTH transceivers -> SN75DP159 redriver.
  input  wire       hdmi_mgtrefclk_p,   // 148.5 MHz from external PLL
  input  wire       hdmi_mgtrefclk_n,
  output wire [2:0] hdmi_tx_p,          // 3 TMDS data lanes
  output wire [2:0] hdmi_tx_n,
  output wire       hdmi_clk_p,         // TMDS clock lane
  output wire       hdmi_clk_n
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
  always_ff @(posedge clk_audio)
    audio_sample_word <= '{audio_sample_word[1] + 16'd1, audio_sample_word[0] - 16'd1};

  logic [11:0] cx;
  logic [10:0] cy;
  logic [11:0] screen_width, frame_width;
  logic [10:0] screen_height, frame_height;
  logic [23:0] rgb = 24'd0;
  always_ff @(posedge clk_pixel)
    rgb <= {
      cx == 12'd0                 ? 8'hFF : 8'h00,
      cy == 11'd0                 ? 8'hFF : 8'h00,
      (cx == screen_width - 12'd1 ||
       cy == screen_height - 11'd1) ? 8'hFF : 8'h00
    };

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
    .reset(1'b0),
    .clk_pixel(clk_pixel),
    .tmds_symbols(tmds_symbols),
    .tmds_data_p(hdmi_tx_p),
    .tmds_data_n(hdmi_tx_n),
    .tmds_clk_p(hdmi_clk_p),
    .tmds_clk_n(hdmi_clk_n),
    .tx_ready(tx_ready),
    .txusrclk2_out(txusrclk2)
  );

  logic [2:0] rst_sync;
  always_ff @(posedge clk_50mhz) begin
    rst_sync <= {rst_din, rst_sync[2:1]};
  end

  logic clk, rst;
  assign clk = clk_50mhz;
  assign rst = rst_sync[0];
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

  // CPU ROM
  spram #(
      .ADDR_WIDTH(15),
      .DATA_WIDTH(32),
      .INIT_FILE("/tmp/bios.vh")
  ) u_rom (
      .clk (clk),
      .addr(cpu_mem_addr[31:2]),
      .rd_data(rom_rdata),
      .wr_en(1'b0)
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

  logic busy;
  always_comb begin
    casex (cpu_mem_addr)
      32'h0xxx_xxxx: cpu_mem_rdata = rom_rdata;
      32'h1xxx_xxxx: cpu_mem_rdata = ram_rdata;
      32'h2xxx_xxx4: cpu_mem_rdata = {31'h0, busy};
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

  // Output UART on all four controller ports
  assign n64_ctrl_data = {4{uart_tx_shift[0]}};

endmodule

`default_nettype wire
