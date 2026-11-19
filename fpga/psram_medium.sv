`default_nettype none

module psram_medium (
  input  wire        clk,
  input  wire        rst,
  input  wire        clk_90deg,

  // ---- BUS interface ----
  input wire [31:0]   bus_addr,
  input wire [31:0]   bus_wdata,
  output logic [31:0] bus_rdata,
  input wire          bus_valid,
  input wire    [3:0] bus_wstrb,
  output logic        bus_ack,

  // ---- PSRAM pins ----
  output logic       ps_clk,
  output logic       ps_cen,
  inout  wire [7:0]  ps_dq,
  inout  wire        ps_dqs
);

  logic       ps_cen_;
  always_ff @(posedge clk) ps_cen <= ps_cen_;

  assign ps_clk = clk_90deg;

  logic frame_start_valid;
  logic frame_stop_valid;

  logic [4:0] frame_cntr;   // Running index inside the frame (starts counting from when ps_cen_ is asserted)
  logic [4:0] frame_tx_off; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on;  // For when to enable the RX-gate

  // XXX: Should move into its own psram_slow_phy module
  logic [4:0] frame_tx_off_; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on_;  // For when to enable the RX-gate

  logic tx_on;
  logic rx_on;

  always_ff @(posedge clk) begin
    if (rst) begin
      ps_cen_ <= 1;
    end else if (frame_start_valid) begin
      ps_cen_ <= 0;
      frame_cntr <= 0;
      frame_tx_off <= frame_tx_off_;
      frame_rx_on <= frame_rx_on_;
    end else begin
      frame_cntr <= frame_cntr + 1;
    end

    if (frame_stop_valid) ps_cen_ <= 1;
  end

  //
  // TX-path
  //
  logic [7:0] tx_shift [0:7]; // XXX: Make this array a type
  logic [7:0] tx_load [0:7];
  logic       tx_load_en;
  always_ff @(posedge clk) begin
    if (tx_load_en) begin
      tx_shift <= tx_load;
    end else begin
      for (integer i = 0; i < 4 - 1; i = i + 1) begin
        tx_shift[i*2+0] <= tx_shift[(i+1)*2+0];
        tx_shift[i*2+1] <= tx_shift[(i+1)*2+1];
      end
      tx_shift[6] <= 8'h00;
      tx_shift[7] <= 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) tx_on <= 0;
    else if (frame_start_valid) tx_on <= 1;
    else if (frame_cntr == frame_tx_off) tx_on <= 0;
  end

  always_ff @(posedge clk) begin
    if (ps_cen_) rx_on <= 0;
    else if (frame_cntr == frame_rx_on) rx_on <= 1;
  end

  wire [7:0] dq_tri, dq_out, dq_in;
  wire oddr_sr;
  assign oddr_sr = 1'b0;

  genvar gi;
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : oddr_dq
      ODDRE1 oddr_dq_tri (
        .C(clk),
        .D1(~tx_on),
        .D2(~tx_on),
        .Q(dq_tri[gi]),
        .SR(oddr_sr)
      );
      ODDRE1 oddr_dq (
        .C(clk),
        .D1(tx_shift[0][gi]),
        .D2(tx_shift[1][gi]),
        .Q(dq_out[gi]),
        .SR(oddr_sr)
      );
    end
  endgenerate

  wire dqs_tri, dqs_out, dqs_in;
  ODDRE1 oddr_dqs_tri (
    .C(clk),
    .D1(~tx_on),
    .D2(~tx_on),
    .Q(dqs_tri),
    .SR(oddr_sr)
  );
  ODDRE1 oddr_dqs (
    .C(clk),
    .D1(1'b0),
    .D2(1'b0),
    .Q(dqs_out),
    .SR(oddr_sr)
  );

  //
  // RX-path
  //
  wire iddr_dqs_q1;
  wire iddr_dqs_q2;

  IDDRE1 #(
    .IS_C_INVERTED(0),
    .IS_CB_INVERTED(1)
  ) iddr_dqs (
    .C(clk),
    .CB(clk),
    .D(dqs_in),
    .Q1(iddr_dqs_q1),
    .Q2(iddr_dqs_q2),
    .R(1'b0)
  );

  wire [7:0] iddr_dq_q1;
  wire [7:0] iddr_dq_q2;
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : iddr_dq
      IDDRE1 #(
        .IS_C_INVERTED(0),
        .IS_CB_INVERTED(1)
      ) iddr_dq (
        .C(clk),
        .CB(clk),
        .D(dq_in[gi]),
        .Q1(iddr_dq_q1[gi]),
        .Q2(iddr_dq_q2[gi]),
        .R(1'b0)
      );
    end
  endgenerate

  //
  // IOBUF
  //
  generate
    for (gi = 0; gi < 8; gi = gi + 1) begin
      IOBUF iobuft_dq (
        .O(dq_in[gi]),
        .T(dq_tri[gi]),
        .I(dq_out[gi]),
        .IO(ps_dq[gi])
      );
    end
  endgenerate

  IOBUF iobuft_dqs (
    .O(dqs_in),
    .T(dqs_tri),
    .I(dqs_out),
    .IO(ps_dqs)
  );


  localparam RX_SHIFT_LEN = 10;
  logic [7:0] rx_shift [0:RX_SHIFT_LEN-1];
  logic [3:0] rx_cntr;
  always_ff @(posedge clk) begin
    if (~rx_on) begin
      rx_cntr <= 0;
    end else if (~ps_cen_ & (iddr_dqs_q1 ^ iddr_dqs_q2)) begin
      for (integer i = 0; i < RX_SHIFT_LEN/2 - 1; i = i + 1) begin
        rx_shift[i*2+0] <= rx_shift[(i+1)*2+0];
        rx_shift[i*2+1] <= rx_shift[(i+1)*2+1];
      end
      rx_shift[RX_SHIFT_LEN-2] <= iddr_dq_q1;
      rx_shift[RX_SHIFT_LEN-1] <= iddr_dq_q2;
      rx_cntr <= rx_cntr + 1;
    end
  end

  typedef enum logic [3:0] {
    S_INIT, S_GRST0, S_GRST1, S_IDLE, S_MODE_READ0, S_MODE_READ1,
    S_MODE_WRITE0, S_MODE_WRITE1, S_SYNC_READ0, S_SYNC_READ1, S_SYNC_WRITE0,
    S_SYNC_WRITE1, S_SYNC_WRITE2, S_ACK, S_WAIT
  } state_t;
  state_t state, next_state;

  always_ff @(posedge clk) begin
    if (rst) state <= S_INIT;
    else state <= next_state;
  end

  always_comb begin
    next_state = state;

    frame_start_valid = 0;
    frame_stop_valid = 0;
    bus_ack = 0;
    tx_load_en = 0; // XXX: Should rename to frame_start or something;
    tx_load = '{default: 0};
    frame_tx_off_ = 0;
    frame_rx_on_ = 0;
    case (state)
      S_INIT: begin
        next_state = S_GRST0;
      end
      S_GRST0: begin
        frame_start_valid = 1;
        tx_load_en = 1;
        tx_load = '{8'hff, 8'hff, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        frame_tx_off_ = 8;
        next_state = S_GRST1;
      end
      S_GRST1: begin
        if (frame_cntr == 8) frame_stop_valid = 1;
        if (frame_stop_valid) next_state = S_WAIT;
      end
      S_IDLE: begin
        if (bus_valid) begin
          if (|bus_wstrb) begin
            next_state = bus_addr[27] ? S_MODE_WRITE0 : S_SYNC_WRITE0;
          end else begin
            next_state = bus_addr[27] ? S_MODE_READ0 : S_SYNC_READ0;
          end
        end
      end
      //
      // Mode Read
      //
      S_MODE_READ0: begin
        frame_start_valid = 1;
        tx_load_en = 1;
        tx_load = '{8'h40, 8'h40, 8'h00, 8'h00, 8'h00, bus_addr[15:8], 8'h00, 8'h00};
        frame_tx_off_ = 6;
        frame_rx_on_ = 10;
        next_state = S_MODE_READ1;
      end
      S_MODE_READ1: begin
        if (rx_cntr == 4) frame_stop_valid = 1;
        if (frame_stop_valid) next_state = S_ACK;
      end
      //
      // Mode Write
      //
      S_MODE_WRITE0: begin
        frame_start_valid = 1;
        tx_load_en = 1;
        tx_load = '{8'hC0, 8'hC0, 8'h00, 8'h00, 8'h00, bus_addr[15:8], bus_wdata[7:0], 8'h00};
        frame_tx_off_ = 7;
        frame_rx_on_ = 10;
        next_state = S_MODE_WRITE1;
      end
      S_MODE_WRITE1: begin
        if (frame_cntr == 8) frame_stop_valid = 1;
        if (frame_stop_valid) next_state = S_ACK;
      end
      //
      // Sync Read
      //
      S_SYNC_READ0: begin
        frame_start_valid = 1;
        tx_load_en = 1;
        tx_load = '{8'h00, 8'h00, bus_addr[26:24], bus_addr[23:16], bus_addr[15:8], bus_addr[7:0], 8'h00, 8'h00};
        frame_tx_off_ = 3;
        frame_rx_on_ = 6;
        next_state = S_SYNC_READ1;
      end
      S_SYNC_READ1: begin
        if (rx_cntr == 4) frame_stop_valid = 1;
        if (frame_stop_valid) next_state = S_ACK;
      end
      //
      // Sync Write
      //
      S_SYNC_WRITE0: begin
        frame_start_valid = 1;
        frame_tx_off_ = 8;
        tx_load_en = 1;
        tx_load = '{8'h80, 8'h80, bus_addr[26:24], bus_addr[23:16], bus_addr[15:8], bus_addr[7:0], 8'h00, 8'h00};
        next_state = S_SYNC_WRITE1;
      end
      S_SYNC_WRITE1: begin
        if (frame_cntr == 6) begin
          tx_load_en = 1;
          tx_load = '{bus_wdata[31:24], bus_wdata[23:16], bus_wdata[15:8], bus_wdata[7:0], 8'h00, 8'h00, 8'h00, 8'h00};
          next_state = S_SYNC_WRITE2;
        end
      end
      S_SYNC_WRITE2: begin
        if (frame_cntr == 8) frame_stop_valid = 1;
        if (frame_stop_valid) next_state = S_ACK;
      end
      S_ACK: begin
        bus_ack = 1;
        next_state = S_WAIT;
      end
      S_WAIT: begin
        next_state = S_IDLE;
      end
    endcase
  end

  assign bus_rdata = {rx_shift[0], rx_shift[1], rx_shift[2], rx_shift[3]};

endmodule

`default_nettype wire
