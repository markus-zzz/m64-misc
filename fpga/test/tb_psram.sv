`timescale 1ps/1ps
`default_nettype none

// tb_psram_ddr - end-to-end MRR against the native-BITSLICE controller with a
// FAITHFUL DDR APS256 model that decodes C/A on actual CK edges.
//
// This replaces the earlier stub model (which merely counted CK cycles for the
// C/A phase and would rubber-stamp a wrong command). Here the model:
//   * waits for CE# low
//   * samples A/DQ[7:0] on EVERY CK edge (DDR), building the command frame
//   * on the 1st CK rising edge the byte must be the instruction 40h, else it
//     flags the command as malformed and drives NOTHING back (just like the
//     real device - no DQS)
//   * MA is taken from the 6th edge (3rd CK falling)
//   * after LC CK cycles of latency it drives DQS + the addressed register
//     byte on DQ, DQS toggling per beat, until CE# high
// This way the sim only passes if the controller presents a correctly framed
// DDR command - which is exactly the property we need to verify.

module tb_psram;

  localparam [7:0] MR0 = 8'h08;    // datasheet default (LC=5, VL, full drive)
  localparam [7:0] MR1 = 8'h8D;    // {ULP=1, rsvd=00, vendor=01101}
  localparam [7:0] MA  = 8'h01;    // read MR1
  localparam int   LAT = 5;

  logic rst = 1'b1;
  logic clk_sys  = 1'b0; always #2500 clk_sys  = ~clk_sys;   // 200 MHz

  logic        start = 1'b0;
  logic [7:0]  mode_addr = MA;
  logic [8:0]  dqs_tap = 9'd0, tx_tap = 9'd0;
  logic [7:0]  gate_start = 8'd4, gate_len = 8'd11;
  wire         busy, done, phy_ready, init_ok;
  wire [7:0]   rd_reg;
  wire [31:0]  rd_raw, rd_dbg;
  wire         ps_clk, ps_cen;
  wire [7:0]   ps_dq;
  wire         ps_dqs;

  // bidir DQ / DQS modelled with tri-state nets
  logic        dev_drive = 1'b0;
  logic [7:0]  dev_dq = 8'h00;
  logic        dev_dqs = 1'b0;
  assign ps_dq  = dev_drive ? dev_dq  : 8'bz;
  assign ps_dqs = dev_drive ? dev_dqs : 1'bz;

  psram_slow dut(
    .clk(clk_sys),
    .rst(rst),
    // ---- BUS interface ----
    .bus_addr(32'h0800_0100),
    .bus_wdata(),
    .bus_rdata(),
    .bus_ren(1'b1),
    .bus_ack(),
    // ---- PSRAM pins ----
    .ps_clk(ps_clk),
    .ps_cen(ps_cen),
    .ps_dq(ps_dq),
    .ps_dqs(ps_dqs)
  );


  // ---------------- faithful DDR device model ----------------
  logic [7:0]  frame [0:5];
  integer      edgei;
  logic        cmd_ok;
  reg   [7:0]  reg_file [0:2];
  initial begin reg_file[0]=MR0; reg_file[1]=MR1; reg_file[2]=8'hDC; end

  // sample C/A on every CK edge while CE# low
  task automatic run_device;
    integer i;
    logic [7:0] ma_seen;
    begin
      @(negedge ps_cen);
      $display("  device: CE# low at %0t", $time);
      // Datasheet 7.3: instruction is latched on the 1st CK RISING edge after
      // CE# low. Align the capture to that edge explicitly (don't just take the
      // first transition, which could be a falling edge depending on phase).
      @(posedge ps_clk);
      edgei = 0;
      frame[0] = ps_dq;                    // edge 0 = 1st rising = instruction
      for (i = 1; i < 6; i = i + 1) begin
        @(ps_clk);                         // each subsequent CK edge (DDR)
        frame[i] = ps_dq;
      end
      cmd_ok  = (frame[0] === 8'h40);
      ma_seen = frame[5];
      $display("  device: frame=%p  instr=0x%02h ma=0x%02h ok=%0d",
               frame, frame[0], ma_seen, cmd_ok);
      if (frame[0] === 8'hFF) begin
        $display("  device: Global Reset accepted");
        @(posedge ps_cen);       // wait for frame to end, then re-arm
        return;
      end
      if (!cmd_ok) begin
        $display("  device: MALFORMED COMMAND - not responding (no DQS)");
        @(posedge ps_cen);
        return;                  // real device would stay silent
      end
      // read latency
      repeat (LAT) @(posedge ps_clk);
      // drive data: alternate addressed register and the next (MR1/MR2...)
      dev_drive = 1'b1; dev_dqs = 1'b0;
      fork
        begin : datarun
          forever begin
            dev_dq  = reg_file[(ma_seen + 0) % 3]; dev_dqs = 1'b1; # (16 * 2500);
            dev_dq  = reg_file[(ma_seen + 1) % 3]; dev_dqs = 1'b0; # (16 * 2500);
          end
        end
        begin @(posedge ps_cen); disable datarun; end
      join
      dev_drive = 1'b0; dev_dqs = 1'b0;
    end
  endtask

  initial forever run_device;

  // hard global stop so a hung wait() cannot run forever
  initial begin #300_000_000; $display("GLOBAL TIMEOUT"); $finish; end

  // ---------------- stimulus ----------------
  initial begin
    $dumpfile("tb_psram.vcd");
    $dumpvars(0, tb_psram);

    repeat (40) @(posedge clk_sys);
    rst = 1'b0;

    // wait for init (Global Reset) + bring-up
    fork : wi
      begin wait (init_ok && phy_ready); disable wi; end
      begin #200_000_000; $display("TIMEOUT waiting init/phy_ready"); disable wi; end
    join
    $display("init_ok=%0d phy_ready=%0d at %0t", init_ok, phy_ready, $time);

    repeat (10) @(posedge clk_sys);
    // Sweep gate_start to find where the gated read window catches the data.
    // The command phase is already correct (device responds); this tunes the
    // capture timing against a responding device.
    for (int gs = 0; gs <= 20; gs++) begin
      gate_start = gs[7:0];
      @(posedge clk_sys) start = 1'b1;
      fork : ws
        begin wait (busy); disable ws; end
        begin repeat (2000) @(posedge clk_sys); disable ws; end
      join
      @(posedge clk_sys) start = 1'b0;
      fork : wd
        begin wait (done); disable wd; end
        begin #20_000_000; disable wd; end
      join
      @(posedge clk_sys);
      $display("GATE gs=%0d rd_reg=0x%02h rd_raw=0x%08h cap_done=%0b fifo_empty=0x%02h dqs=0x%02h",
               gs, rd_reg, rd_raw, rd_dbg[26], rd_dbg[23:16], rd_dbg[7:0]);
      if (rd_reg === reg_file[MA])
        $display("PASS: gate_start=%0d -> MRR expected=0x%02h", gs, rd_reg);
      repeat (30) @(posedge clk_sys);
    end
    $finish;
  end

endmodule

`default_nettype wire
