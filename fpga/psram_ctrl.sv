`default_nettype none

// -----------------------------------------------------------------------------
// psram_ctrl - APS256 PSRAM controller (x8 lane 0), native-BITSLICE PHY.
//
// Wraps psram_phy (the verified bidirectional byte-group PHY: BISC bring-up,
// RX_GATING gated DDR capture, TBYTE_CTL="T" tristate) with a command FSM that
// performs a Mode Register Read (MRR, cmd 40h): drive CK/CE# and {40h, X, MA}
// out on DQ[7:0] via the PHY TX path, drop drive, wait read latency, open the
// gated read window (rd_en), and extract the register byte from the captured
// deserialized data.
//
// Clocking: clk_sys = command/CK + app/FIFO-read clock. clk_pll_ref = in-bank
// GC reference for the PHY PLL (CLKOUTPHY = 800 MHz BISC plane). riu_clk for the
// BITSLICE_CONTROL RIU.
//
// For MRR the register value (Data0) returns on DQ[7:0]. Each DQ pin's first
// captured serial bit is dq_q[i*4]. We assemble rd_reg from those bits once the
// read window has produced data.
// -----------------------------------------------------------------------------

module psram_ctrl #(
  parameter int READ_LATENCY = 5,         // MR0[4:2] LC (default 5)
  parameter int DQS_TAPS     = 0,         // DQS centering taps (COUNT mode)
  parameter LOOPBACK         = "FALSE"    // "TRUE" = datapath diagnostic build
) (
  input  wire        clk_sys,
  output wire        clk_cmd,             // 200 MHz PLL-derived cmd clock (to top)
  input  wire        clk_pll_ref,
  input  wire        riu_clk,
  input  wire        rst,
  // register-bus facing
  input  wire        start,               // pulse: begin one MRR
  input  wire [7:0]  mode_addr,
  input  wire [8:0]  dqs_tap,             // runtime DQS centering tap
  input  wire [8:0]  tx_tap,              // runtime C/A TX delay tap
  input  wire        tx_tap_load,         // pulse to load tx_tap
  input  wire        dqs_tap_load,        // pulse to load the tap
  output wire [8:0]  dqs_tap_cur,         // current tap (readback)
  input  wire [7:0]  gate_start,          // runtime PHY_RDEN open offset
  input  wire [7:0]  gate_len,            // runtime read-window length
  input  wire        quiet,               // 1 = control experiment: CE# high, no cmd
  input  wire        ck_off,              // 1 = also hold CK static (phantom-strobe test)
  input  wire        ck_inv,              // 1 = invert CK phase (see ODDRE1 below)
  input  wire        grst_req,            // pulse/level: run Global Reset (Phase 2 init)
  output wire        init_ok,             // device Phase 2 init completed
  input  wire        loopback_en,         // 1 = drive test pattern for loopback capture
  input  wire [7:0]  lb_pattern,          // pattern driven on DQ in loopback mode
  input  wire        drive_hold,          // 1 = drive lb_pattern on DQ indefinitely
  output logic       busy,
  output logic       done,
  output logic [7:0] rd_reg,
  output logic [31:0] rd_raw,             // raw captured dq_q at sample (debug)
  output logic [31:0] rd_dbg,             // {6'b0,vtc,dly, fifo_empty[7:0], 8'b0, dqs_as_data[7:0]}
  output wire [255:0] cap_words,          // 8 captured words (debug stream)
  output wire        phy_ready,            // BISC complete
  // PSRAM pins (x8 lane 0 = byte group 2)
  output wire        ps_clk,
  output wire        ps_cen,
  input  wire        ps_dqs,              // DQS[0]
  inout  wire [7:0]  ps_dq                // DQ[7:0]
);

  // ---- PHY instance ----
  // ---- Phase-aligned transaction launch ----------------------------------
  // The deserializer groups incoming beats into 4-beat words on FIFO_RD_CLK
  // boundaries (4 beats = 2 CK cycles = 2 clk_cmd cycles = 1 FIFO_RD_CLK
  // period). The start pulse is CDC'd in from the 50 MHz bus domain, so it
  // lands on an arbitrary clk_sys cycle; the command - and therefore the
  // device's DQS burst - then arrives at an arbitrary phase relative to that
  // word boundary, and the captured window lands on a random beat offset.
  // On hardware that showed as rd_raw taking one of ~7 sliding-window values
  // at random, unaffected by the delay tap and unaffected by anchoring the
  // FIFO read pointer.
  //
  // phase_tgl is a free-running divide-by-2 of clk_sys. Its phase relative to
  // FIFO_RD_CLK is now fixed (both are outputs of the same PLL), which
  // is all we need: launching every transaction on the same parity makes the
  // beat grouping identical every time. Any fixed offset is then absorbed by
  // the sample point / delay tap.
  logic phase_tgl, start_pending;
  logic quiet_r, ck_off_r, lb_r;
  logic cen_r, init_done;
  always_ff @(posedge clk_cmd or posedge rst)
    if (rst) phase_tgl <= 1'b0;           // must have a defined initial value;
    else     phase_tgl <= ~phase_tgl;     // a reset-less toggle stays X in sim

  wire [31:0] dq_q;
  wire        pll_locked;
  wire [7:0]  dqs_as_data, dq_fifo_empty;
  wire        dbg_dly_rdy, dbg_vtc_rdy, dbg_cap_done;
  logic       rd_en;
  logic [31:0] tx_beats;        // 4 C/A beats per clk_cmd cycle {b3,b2,b1,b0}
  logic       tx_oe;

  // In loopback the DQS slice TX drives 1010 every beat = a half-beat-rate
  // square wave, i.e. exactly what DQS looks like. Else all-zero (pin unused).
  wire [7:0] strobe_pat = lb_r ? 8'b10101010 : 8'b0;

  // drive_hold statically drives lb_pattern onto all four beats (CE# stays high
  // so the device ignores it). Output-path / pin-mapping test pollable by SW.
  wire [31:0] tx_beats_eff = drive_hold ? {4{lb_pattern}} : tx_beats;
  wire        tx_oe_eff    = drive_hold ? 1'b1 : tx_oe;

  psram_phy #(.DQS_TAPS(DQS_TAPS), .LOOPBACK(LOOPBACK)) phy (
    .clk_app(clk_sys), .clk_cmd(clk_cmd),
    .clk_pll_ref(clk_pll_ref), .riu_clk(riu_clk),
    .rst(rst), .rd_en(rd_en),
    .dqs_tap(dqs_tap), .dqs_tap_load(dqs_tap_load), .dqs_tap_cur(dqs_tap_cur),
    .tx_tap(tx_tap), .tx_tap_load(tx_tap_load), .strobe_pat(strobe_pat),
    .tx_beats(tx_beats_eff), .tx_oe(tx_oe_eff),
    .dq_io(ps_dq), .dqs_pin(ps_dqs),
    .phy_ready(phy_ready), .pll_locked(pll_locked), .dq_q(dq_q),
    .cap_words(cap_words),
    .dqs_as_data(dqs_as_data), .dq_fifo_empty(dq_fifo_empty),
    .dbg_cap_done(dbg_cap_done),
    .dbg_dly_rdy(dbg_dly_rdy), .dbg_vtc_rdy(dbg_vtc_rdy)
  );

  // Assemble the MRR byte: DQ bit i's first captured serial bit = dq_q[i*4].
  wire [7:0] rd_byte;
  genvar i;
  generate for (i = 0; i < 8; i = i + 1) begin : gen_rb
    assign rd_byte[i] = dq_q[i*4];
  end endgenerate

  // ---- CK generation (ODDRE1 1-0 pattern), gated by ck_en ----
  logic ck_en;
  wire  ck_oddr;
  // UG861: "When DATA_WIDTH=4, the divided clock is inverted." The clock that
  // actually launches DQ data out of the TX bitslice is therefore inverted
  // relative to clk_cmd, so CK generated from clk_cmd directly would sit 180
  // degrees away from the data - DQ would transition exactly on the CK edges
  // the device latches on. ck_inv selects the CK phase at runtime so both
  // polarities can be tested without a rebuild.
  ODDRE1 #(.SRVAL(1'b0)) oddr_ck (
    .Q(ck_oddr), .C(clk_cmd),
    .D1(ck_inv ? 1'b0   : ck_en),
    .D2(ck_inv ? ck_en  : 1'b0),
    .SR(rst)
  );
  OBUF obuf_ck (.I(ck_oddr), .O(ps_clk));

  // CE# is explicitly registered so the Global Reset frame can drive it
  // independently of a normal transaction.
  //   - quiet/loopback modes hold it deasserted (device ignores everything)
  //   - the Global Reset frame asserts it for exactly 4 clocked cycles
  // Phase 1 requires CE# HIGH and CLK LOW out of reset, which the idle state
  // satisfies (cen_r=1, ck_en=0 -> ODDRE1 drives a static low).
  assign ps_cen = cen_r | drive_hold;   // never select the device while forcing DQ
  assign init_ok = init_done;

  // ---- command FSM ----
  localparam int CA_CYCLES  = 3;
  localparam int GATE_START = READ_LATENCY - 1;
  localparam int GATE_LEN   = READ_LATENCY + 6;
  // Global Reset (datasheet 6.2): command FFh, frame = 4 clocked CE# lows,
  // then tRST >= 2us before the device is ready. At 200 MHz, 2us = 400 cycles;
  // use 600 for margin. Clocking is optional during tRST.
  localparam int GRST_FRAME = 4;
  localparam int GRST_WAIT  = 600;

  typedef enum logic [3:0] {
    S_INIT, S_GRST_CMD, S_GRST_WAIT,
    S_IDLE, S_CMD, S_LAT, S_CAP, S_DONE
  } state_t;
  state_t state;
  logic [15:0] cnt;

  always_ff @(posedge clk_cmd or posedge rst) begin
    if (rst) begin
      state   <= S_INIT;
      busy    <= 1'b0; done <= 1'b0; rd_reg <= 8'h00; rd_raw <= 32'h0; rd_dbg <= 32'h0;
      start_pending <= 1'b0; quiet_r <= 1'b0; ck_off_r <= 1'b0; lb_r <= 1'b0;
      tx_beats <= 32'h0; tx_oe <= 1'b0; rd_en <= 1'b0; ck_en <= 1'b0; cnt <= '0;
      cen_r   <= 1'b1; init_done <= 1'b0;
    end else begin
      // Latch an incoming start request; it is launched later on the aligned
      // clock phase. (Cleared in S_IDLE at launch, which wins if coincident.)
      if (start) start_pending <= 1'b1;
      // 'done' is sticky: set when a transaction completes, cleared at the next
      // start. (Slow SPI polling would miss a 1-cycle pulse.)
      case (state)
        // ---- Phase 2 power-up initialization (datasheet section 6) --------
        // The device self-initializes (Phase 1) but then REQUIRES the host to
        // complete Phase 2, via the RESET# pin or a Global Reset command.
        // Without it the device is not ready for operation and ignores
        // commands - which is why it never answered an MRR.
        S_INIT: begin
          cen_r <= 1'b1; ck_en <= 1'b0; tx_oe <= 1'b0;
          if (phy_ready && (grst_req || !init_done)) begin
            cnt     <= '0;
            cen_r   <= 1'b0;              // CE# low for the command frame
            ck_en   <= 1'b1;              // clock the frame
            tx_beats <= {4{8'hFF}};      // Global Reset FFh on every beat
            tx_oe   <= 1'b1;
            state   <= S_GRST_CMD;
          end
        end
        S_GRST_CMD: begin
          if (cnt >= GRST_FRAME-1) begin
            cen_r <= 1'b1;                // release CE# after 4 clocked lows
            tx_oe <= 1'b0;
            cnt   <= '0;
            state <= S_GRST_WAIT;
          end else cnt <= cnt + 16'd1;
        end
        S_GRST_WAIT: begin
          ck_en <= 1'b0;                  // clocking optional during tRST
          if (cnt >= GRST_WAIT) begin
            init_done <= 1'b1;
            cnt       <= '0;
            state     <= S_IDLE;
          end else cnt <= cnt + 16'd1;
        end
        S_IDLE: begin
          busy <= 1'b0; tx_oe <= 1'b0; rd_en <= 1'b0; ck_en <= 1'b0;
          cen_r <= 1'b1;
          if (grst_req) begin              // manual re-init request
            state <= S_INIT;
          end else
          // Only accept a start once the PHY has finished bring-up and the
          // device has been initialized, AND only on a fixed clock phase.
          if (start_pending && phy_ready && init_done && !phase_tgl) begin
            busy    <= 1'b1; ck_en <= 1'b0; cnt <= '0; done <= 1'b0;
            // CK is started in S_CMD (cnt==0), one clk_cmd after the first
            // beats are loaded, so CK's 1st rising edge aligns with beat0 at
            // the pin despite the TX serializer latency.
            quiet_r <= quiet;             // latch control-experiment mode
            ck_off_r <= ck_off;
            lb_r    <= loopback_en;
            cen_r   <= (quiet | loopback_en);    // CE# LOW (0) only for a real
                                                 // cmd; HIGH for quiet/loopback
            // At launch load IDLE so the serializer flushes stale bus (the
            // prior GRST FF); the real 40h is loaded in S_CMD cnt0 together
            // with CK start, so they share a known phase.
            tx_beats <= loopback_en ? {4{lb_pattern}} : 32'h0;
            tx_oe   <= loopback_en ? 1'b1 : ~quiet;
            state   <= S_CMD;
            start_pending <= 1'b0;
          end
        end
        // DDR command framing. Established in tb_tx_map:
        //   * each 4-beat serializer load must be held stable for TWO clk_cmd
        //     cycles, else it never serializes out (single-cycle loads are
        //     overwritten before emission).
        //   * within a held load: D0->CK falling, D1->rising, D2->falling,
        //     D3->rising. Device edge0 (1st rising after CE#) = D1.
        // Target flat edge sequence: edge0=40h (instr), edge5=MA (3rd falling).
        //   load A (held cnt1,2): D1=40h  -> edge0=40, edges1,2 = 00
        //   load B (held cnt3,4): D2=MA   -> edge5=MA, others 00
        //   cnt5,6: idle hold to flush the last beats, then release.
        // DDR command framing as a SINGLE continuous beat stream (robust: no
        // separately-tuned loads whose inter-load timing drifted between sim
        // and silicon and dropped MA).
        //
        // Flat edge sequence (device edge0 = 1st CK rising):
        //   e0=40h e1=00 e2=00 e3=00 e4=00 e5=MA e6=00 e7=00
        // Mapping to serializer D-lanes (D0->falling, D1->rising, D2->falling,
        // D3->rising; device edge0 is a RISING edge = D1). So beats stream as
        //   D1 D2 D3 | D0 D1 D2 D3 | D0 ...  aligned to edges 0,1,2,3,4,5,...
        // One load (held 2 clk_cmd cycles) emits D0..D3 = 4 edges. Two loads
        // cover edges -1..6. With edge0=D1 of load A:
        //   load A {D3=00,D2=00,D1=40,D0=xx} -> edges 0,1,2 = 40,00,00 (D0=e-1)
        //   load B {D3=00,D2=MA,D1=00,D0=00} -> edges 3,4,5,6 = 00,00,MA,00
        // which places 40h@e0 and MA@e5. CK is started together with load A at
        // a FIXED one-cnt offset so instruction and MA share one timing base.
        S_CMD: if (lb_r) begin
          if (cnt >= CA_CYCLES-1) begin cnt <= '0; state <= S_LAT; end
          else cnt <= cnt + 8'd1;
        end else begin
          case (cnt)
            8'd0: begin
              tx_beats <= 32'h0;                        // flush stale bus
              cnt      <= cnt + 8'd1;
            end
            8'd1: begin
              tx_beats <= {8'h00, 8'h40, 8'h40, 8'h00}; // load A (D1=40h)
              cnt      <= cnt + 8'd1;
            end
            8'd2: begin
              tx_beats <= {8'h00, 8'h40, 8'h40, 8'h00}; // hold A 2nd cycle
              cnt      <= cnt + 8'd1;
            end
            8'd3: begin
              tx_beats <= {8'h00, mode_addr, 8'h00, 8'h00}; // load B (D2=MA)
              ck_en    <= ~ck_off_r;    // CK start (sim-verified position)
              cnt      <= cnt + 8'd1;
            end
            8'd4: begin
              tx_beats <= {8'h00, mode_addr, 8'h00, 8'h00}; // hold B 2nd cycle
              cnt      <= cnt + 8'd1;
            end
            8'd5, 8'd6, 8'd7, 8'd8: begin
              tx_beats <= 32'h0;        // extended idle hold so load B's MA
                                        // fully clocks out before tx_oe drops
                                        // (serializer latency margin for HW)
              cnt      <= cnt + 8'd1;
            end
            default: begin
              tx_oe    <= 1'b0;
              tx_beats <= 32'h0;
              cnt      <= '0;
              state    <= S_LAT;
            end
          endcase
        end
        S_LAT: begin
          // gate_start is runtime-settable so the PHY_RDEN window position can
          // be swept against the device's actual DQS preamble arrival (the
          // compile-time READ_LATENCY-1 was only an assumption).
          if (cnt >= gate_start) begin
            rd_en <= 1'b1;                // open gated read window
            cnt   <= '0;
            state <= S_CAP;
          end else cnt <= cnt + 8'd1;
        end
        S_CAP: begin
          // Hold the gated window open long enough for the device's preamble +
          // data to propagate through the gate and the RX FIFO (fwft) into the
          // clk_sys domain, then sample. Fixed late sample point within the
          // window (empirically data is stable well before GATE_LEN).
          if (cnt >= gate_len) begin
            rd_reg <= rd_byte;
            rd_raw <= dq_q;              // capture full raw window for debug
            rd_dbg <= {5'b0, dbg_cap_done, dbg_vtc_rdy, dbg_dly_rdy,
                       dq_fifo_empty, 8'b0, dqs_as_data};
            rd_en  <= 1'b0; ck_en <= 1'b0;
            state  <= S_DONE;
          end else cnt <= cnt + 8'd1;
        end
        S_DONE: begin
          busy <= 1'b0; done <= 1'b1; state <= S_IDLE;   // sticky done
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
