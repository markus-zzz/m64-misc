`timescale 1ps/1ps
//
// Crude and simplistic model of - APS256XXN-OBx9 OPI/HPI Xccela PSRAM
//
module psram_model(
  input wire        ps_clk,
  input wire        ps_cen,
  inout wire [1:0]  ps_dqs,
  inout wire [15:0] ps_dq
);

  localparam int   LAT = 5;

  // Continuously measure the half period of ps_clk (for use when driving ps_dqs)
  real ps_clk_half_period;
  initial begin
    real t_prev;
    @(ps_clk);
    t_prev = $realtime;
    forever begin
      @(ps_clk);
      ps_clk_half_period = $realtime - t_prev;
      t_prev = $realtime;
    end
  end

  // bidir DQ / DQS modelled with tri-state nets
  logic        dev_drive = 1'b0;
  logic [7:0]  dev_dq = 8'h00;
  logic        dev_dqs = 1'b0;
  assign ps_dq  = dev_drive ? dev_dq  : 8'bz;
  assign ps_dqs = dev_drive ? dev_dqs : 1'bz;

  logic [7:0]  frame [0:5];

  // PSRAM0: MR0=0x08 MR1=0x8d MR2=0xdf MR3=0xa0 MR4=0x40 MR8=0x05
  // PSRAM3: MR0=0x08 MR1=0x8d MR2=0xde MR3=0xa0 MR4=0x40 MR8=0x05
  logic [7:0]  mode_regs [0:8];
  integer mode_adjs [0:8];
  logic [7:0] mem_array [0:32*1024*1024-1];
  initial begin
    mode_regs = '{8'h08, 8'h8d, 8'hdf, 8'ha0, 8'h40, 8'hxx, 8'hxx, 8'hxx, 8'h05};
    mode_adjs = '{1,2,3,4,8,5,6,7,0};
  end

  task automatic run_device;
    begin
      @(negedge ps_cen);
      $display(" [%m]: CE# low at %0t", $time);
      // Datasheet 7.3: instruction is latched on the 1st CK RISING edge after
      // CE# low. Align the capture to that edge explicitly (don't just take the
      // first transition, which could be a falling edge depending on phase).
      @(posedge ps_clk);
      frame[0] = ps_dq;                    // edge 0 = 1st rising = instruction
      for (integer i = 1; i < 6; i = i + 1) begin
        @(ps_clk);                         // each subsequent CK edge (DDR)
        frame[i] = ps_dq;
      end

      if (frame[0] != frame[1]) begin
        $display(" [%m]: MALFORMED FRAME %p", frame);
        @(posedge ps_cen);
        return;                  // real device would stay silent
      end

      case (frame[0])
      8'hFF: begin // Global Reset
        $display(" [%m]: Global Reset accepted");
        @(posedge ps_cen);
        return;
      end
      8'hC0: begin // Mode Register Write
        logic [7:0] ma, mr;
        ma = frame[5];
        @(posedge ps_clk);
        mr = ps_dq[7:0];
        $display(" [%m]: Mode Register Write accepted - MA=%h MR=%h", ma, mr);
        mode_regs[ma] = mr;
        $display(" [%m]: Mode Registers %p", mode_regs);
        @(posedge ps_cen);
        return;
      end
      8'h40: begin // Mode Register Read
        logic [7:0] ma;
        logic [7:0] rspcntr;
        ma = frame[5];
        $display(" [%m]: Mode Register Read accepted - MA=%h", ma);
        // read latency
        repeat (LAT - 1) @(negedge ps_clk);
        // drive data: alternate addressed register and the next (MR1/MR2...)
        dev_drive = 1'b1; dev_dqs = 1'b0; // XXX:TODO: dqs should drop almost immediately after command
        # (ps_clk_half_period/2); // XXX: tDQSCK
        rspcntr = 0;
        fork
          begin : datarun
            forever begin
//              dev_dq  = mode_regs[ma]; dev_dqs = 1'b1; # (ps_clk_half_period);
//              dev_dq  = mode_regs[mode_adjs[ma]]; dev_dqs = 1'b0; # (ps_clk_half_period);
              dev_dq  = rspcntr; rspcntr = rspcntr + 1; dev_dqs = 1'b1; # (ps_clk_half_period);
              dev_dq  = rspcntr; rspcntr = rspcntr + 1; dev_dqs = 1'b0; # (ps_clk_half_period);
            end
          end
          begin @(posedge ps_cen); disable datarun; end
        join
        dev_drive = 1'b0; dev_dqs = 1'b0;
      end
      8'h80: begin // Sync Write
        logic [31:0] addr;
        addr = {frame[2], frame[3], frame[4], frame[5]};
        $display(" [%m]: Sync Write accepted - addr=%h", addr);
        // write latency
        repeat (LAT - 1) @(negedge ps_clk);
        fork
          begin : datarun
            forever begin
              @(ps_clk)
              if (~ps_dqs) mem_array[addr] = ps_dq;
              $display(" [%m]:  mem_array[%h] = %h", addr, mem_array[addr]);
              addr = addr + 1;
            end
          end
          begin @(posedge ps_cen); disable datarun; end
        join
      end
      8'h00: begin // Sync Read
        logic [31:0] addr;
        addr = {frame[2], frame[3], frame[4], frame[5]};
        $display(" [%m]: Sync Read accepted - addr=%h", addr);
        // read latency
        repeat (LAT - 1) @(negedge ps_clk);
        // drive data
        dev_drive = 1'b1; dev_dqs = 1'b0; // XXX:TODO: dqs should drop almost immediately after command
        # (ps_clk_half_period/2); // XXX: tDQSCK
        fork
          begin : datarun
            forever begin
              dev_dq  = mem_array[addr]; dev_dqs = ~dev_dqs; # (ps_clk_half_period);
              $display(" [%m]:  mem_array[%h] = %h", addr, mem_array[addr]);
              addr = addr + 1;
            end
          end
          begin @(posedge ps_cen); disable datarun; end
        join
        dev_drive = 1'b0; dev_dqs = 1'b0;
      end
      default: begin
        $display(" [%m]: UNKNOWN COMMAND %h", frame[0]);
        @(posedge ps_cen);
      end
      endcase
    end
  endtask

  initial forever run_device;

endmodule

module tb_full;
  // -------- clocks --------
  // 50 MHz board clock: period 20000 ps.
  logic clk_50mhz = 1'b0;
  always #10000 clk_50mhz = ~clk_50mhz;

  // 148.5 MHz MGT reference clock: period ~6734 ps -> half 3367 ps.
  logic refclk = 1'b0;
  always #3367 refclk = ~refclk;
  wire hdmi_mgtrefclk_p =  refclk;
  wire hdmi_mgtrefclk_n = ~refclk;

  // -------- DUT I/O --------
  logic [3:0] n64_ctrl_data;
  wire  [2:0] hdmi_tx_p, hdmi_tx_n;
  wire        hdmi_clk_p, hdmi_clk_n;

  wire tx_ready     = dut.tx_ready;

  wire ps0_clk, ps1_clk, ps2_clk, ps3_clk;
  wire ps0_cen, ps1_cen, ps2_cen, ps3_cen;
  wire [15:0] ps0_dq, ps1_dq, ps2_dq, ps3_dq;
  wire [1:0]  ps0_dqs, ps1_dqs, ps2_dqs, ps3_dqs; 

  top #(
    .BIOS_INIT_FILE(`BIOS_VH)
  ) dut (
    .clk_50mhz(clk_50mhz),
    .n64_ctrl_data(n64_ctrl_data),
    .hdmi_mgtrefclk_p(hdmi_mgtrefclk_p),
    .hdmi_mgtrefclk_n(hdmi_mgtrefclk_n),
    .hdmi_tx_p(hdmi_tx_p),
    .hdmi_tx_n(hdmi_tx_n),
    .hdmi_clk_p(hdmi_clk_p),
    .hdmi_clk_n(hdmi_clk_n),

    .ps0_clk(ps0_clk),
    .ps0_cen(ps0_cen),
    .ps0_dqs(ps0_dqs),
    .ps0_dq(ps0_dq),

    .ps1_clk(ps1_clk),
    .ps1_cen(ps1_cen),
    .ps1_dqs(ps1_dqs),
    .ps1_dq(ps1_dq),

    .ps2_clk(ps2_clk),
    .ps2_cen(ps2_cen),
    .ps2_dqs(ps2_dqs),
    .ps2_dq(ps2_dq),

    .ps3_clk(ps3_clk),
    .ps3_cen(ps3_cen),
    .ps3_dqs(ps3_dqs),
    .ps3_dq(ps3_dq)
  );

  psram_model psram_0(
    .ps_clk(ps0_clk),
    .ps_cen(ps0_cen),
    .ps_dqs(ps0_dqs),
    .ps_dq(ps0_dq)
  );
  psram_model psram_1(
    .ps_clk(ps1_clk),
    .ps_cen(ps1_cen),
    .ps_dqs(ps1_dqs),
    .ps_dq(ps1_dq)
  );
  psram_model psram_2(
    .ps_clk(ps2_clk),
    .ps_cen(ps2_cen),
    .ps_dqs(ps2_dqs),
    .ps_dq(ps2_dq)
  );
  psram_model psram_3(
    .ps_clk(ps3_clk),
    .ps_cen(ps3_cen),
    .ps_dqs(ps3_dqs),
    .ps_dq(ps3_dq)
  );

  // -------- PSRAM register-bus write helper --------
  // The fast PSRAM controller (PSRAM0) is driven from the 0x4000_xxxx register
  // window on top's internal bus_* signals (normally sourced by the SPI slave).
  // Here we drive them directly via force/release, one write per clk_50mhz.
  //
  // NOTE: xsim forbids a 'force' RHS from referencing an automatic variable, so
  // the write payload is staged through these static tb-level regs first.
  reg [31:0] ps_reg_addr;
  reg [31:0] ps_reg_wdata;
  task psram_reg_write(input [31:0] addr, input [31:0] data);
    begin
      @(negedge clk_50mhz);
      ps_reg_addr  = addr;
      ps_reg_wdata = data;
      force dut.bus_addr  = ps_reg_addr;
      force dut.bus_wdata = ps_reg_wdata;
      force dut.bus_wen   = 1'b1;
      @(negedge clk_50mhz);
      force dut.bus_wen   = 1'b0;
      release dut.bus_addr;
      release dut.bus_wdata;
      release dut.bus_wen;
    end
  endtask

  // -------- test sequence --------
  initial begin
    $dumpfile("tb_full.vcd");
    $dumpvars(0, tb_full);

    $display("[%0t] simulation start", $time);
    force dut.rst = 1'b1;
    repeat (40) @(posedge clk_50mhz);
    force dut.rst = 1'b0;

    // The GT reset (gt_reset) is normally released by firmware. Here we
    // release the GT directly so that it free-runs.
    force dut.gt_reset = 1'b0;

    // Release the global soft reset the way firmware does on hardware: write 0
    // to sys_reg_ctrl (0x1000_0000). sys_reg_ctrl[0] both is the CPU 'rst' and
    // gates the fast PSRAM controller's reset chain (psram_rst_sync). Without
    // this, psram_rst stays asserted and the PHY bring-up FSM never leaves
    // B_RESET (observed: psram_rst=1 for the whole run).
    psram_reg_write(32'h1000_0000, 32'h0000_0000);

    // ---------------- PSRAM0 fast-controller exercise ----------------
    // Wait for the PSRAM MMCM to lock and the PHY bring-up FSM to complete
    // (phy_ready) and the device Phase-2 init (init_ok) to finish. The
    // controller runs its own Global Reset automatically out of reset.
    $display("[%0t] PSRAM: waiting for MMCM lock + phy_ready + init_ok", $time);
    wait (dut.psram_mmcm_locked === 1'b1);
    $display("[%0t] PSRAM: MMCM locked", $time);
    // Probe PHY bring-up internals periodically so we can see where it stalls.
    fork
      begin : probe
        repeat (10) begin
          #1_000_000;
          $display("[%0t] PSRAM PROBE: psram_rst=%b pll_locked=%b phy.bstate=%0d phy_ready=%b clkoutphyen=%b init_ok=%b",
                   $time, dut.psram_rst, dut.psram_ctrl_0.phy.pll_locked,
                   dut.psram_ctrl_0.phy.bstate, dut.psram_phy_ready,
                   dut.psram_ctrl_0.phy.clkoutphyen, dut.psram_init_ok);
        end
      end
    join_none
    fork : wait_bringup
      begin
        wait (dut.psram_phy_ready === 1'b1);
        $display("[%0t] PSRAM: phy_ready", $time);
        wait (dut.psram_init_ok === 1'b1);
        $display("[%0t] PSRAM: init_ok (device Phase-2 init done)", $time);
      end
      begin
        // Don't hang the whole sim if bring-up never completes.
        #20_000_000;
        $display("[%0t] PSRAM: WARNING bring-up timeout (phy_ready=%b init_ok=%b)",
                 $time, dut.psram_phy_ready, dut.psram_init_ok);
      end
    join_any
    disable wait_bringup;

    // Issue a Mode Register Read of MR1 (Vendor ID). mode_addr = 0x01 in
    // bits[15:8]; bit[0] toggles the start request.
    $display("[%0t] PSRAM: issuing MRR of MR1", $time);
    psram_reg_write(32'h4000_0000, 32'h0000_0101);

    // Wait for the controller to report done, then print the captured byte.
    fork : wait_done
      begin
        wait (dut.psram_done === 1'b1);
        $display("[%0t] PSRAM: MRR done - rd_reg=0x%02h rd_raw=0x%08h",
                 $time, dut.psram_rd_reg, dut.psram_rd_raw);
      end
      begin
        #10_000_000;
        $display("[%0t] PSRAM: WARNING MRR timeout (busy=%b done=%b)",
                 $time, dut.psram_busy, dut.psram_done);
      end
    join_any
    disable wait_done;

    #100_000_000;
    $display("[%0t] absolute timeout - finishing", $time);
    $finish;
  end
endmodule
