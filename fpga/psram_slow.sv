`default_nettype none

module psram_slow (
  input  wire        clk,
  input  wire        rst,

  // ---- BUS interface ----
  input wire [31:0]   bus_addr,
  input wire [31:0]   bus_wdata,
  output logic [31:0] bus_rdata,
  input wire          bus_ren,
  output logic        bus_ack,

  // ---- PSRAM pins ----
  output logic       ps_clk,
  output logic       ps_cen,
  inout  wire [7:0]  ps_dq,
  input  wire        ps_dqs
);


  //
  // Clock generation
  //
  logic [3:0] clk_cntr;

  always_ff @(posedge clk) clk_cntr <= rst ? 0 : clk_cntr + 1;

  logic clk_posedge, clk_negedge;
  assign clk_posedge = clk_cntr == 4'b0000;
  assign clk_negedge = clk_cntr == 4'b1000;

  always_ff @(posedge clk) begin
    if (clk_cntr == 4'hb) ps_clk <= 1'b1;
    if (clk_cntr == 4'h3) ps_clk <= 1'b0;
  end


  logic [4:0] frame_cntr;   // Running index inside the frame (starts counting from when ps_cen is asserted)
  logic [4:0] frame_len;    // For when to deassert ps_cen and end the frame
  logic [4:0] frame_tx_off; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on;  // For when to enable the RX-gate

  // XXX: Should move into its own psram_slow_phy module
  logic [4:0] frame_len_;    // For when to deassert ps_cen and end the frame
  logic [4:0] frame_tx_off_; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on_;  // For when to enable the RX-gate

  logic tx_on;
  logic rx_on;

  assign tx_load_rdy = ps_cen & clk_negedge;

  always_ff @(posedge clk) begin
    if (rst) begin
      ps_cen <= 1;
    end else if (tx_load_en & tx_load_rdy) begin
      ps_cen <= 0;
      frame_cntr <= 0;
      frame_len <= frame_len_;
      frame_tx_off <= frame_tx_off_;
      frame_rx_on <= frame_rx_on_;
    end else if (clk_posedge | clk_negedge) begin
      frame_cntr <= frame_cntr + 1;
    end

    if (frame_cntr == frame_len) ps_cen <= 1;
  end

  //
  // TX-path
  //
  logic [7:0] tx_shift [0:7];
  logic [7:0] tx_load [0:7];
  logic       tx_load_en;
  logic       tx_load_rdy;
  always_ff @(posedge clk) begin
    if (tx_load_en) begin
      tx_shift <= tx_load;
    end else if (clk_posedge | clk_negedge) begin
      for (integer i = 0; i < 8 - 1; i = i + 1) tx_shift[i] <= tx_shift[i + 1];
      tx_shift[7] <= 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) tx_on <= 0;
    else if (tx_load_en & tx_load_rdy) tx_on <= 1;
    else if (frame_cntr == frame_tx_off) tx_on <= 0;
  end

  always_ff @(posedge clk) begin
    if (rst) rx_on <= 0;
    else if (tx_load_en & tx_load_rdy) rx_on <= 0;
    else if (frame_cntr == frame_rx_on) rx_on <= 1;
  end

  assign ps_dq = tx_on ? tx_shift[0] : 8'hzz;

  //
  // RX-path
  //
  logic [2:0] dqs_sync;
  always_ff @(posedge clk) begin
    dqs_sync <= {ps_dqs, dqs_sync[2:1]};
  end
  logic [7:0] rx_shift [0:3];
  always_ff @(posedge clk) begin
    if (~ps_cen & rx_on & (dqs_sync[1] ^ dqs_sync[0])) begin
      for (integer i = 0; i < 4 - 1; i = i + 1) rx_shift[i] <= rx_shift[i + 1];
      rx_shift[3] <= ps_dq; // XXX: Should sync for meta
    end
  end


  typedef enum logic [2:0] {
    S_INIT0, S_INIT1, S_GRST, S_IDLE, S_MODE_READ
  } state_t;
  state_t state, next_state;

  always_ff @(posedge clk) begin
    if (rst) state <= S_INIT0;
    else state <= next_state;
  end

  always_comb begin
    next_state = state;

    bus_ack = 0;
    tx_load_en = 0; // XXX: Should rename to frame_start or something;
    tx_load = '{default: 0};
    frame_len_ = 0;
    frame_tx_off_ = 0;
    frame_rx_on_ = 0;
    case (state)
      S_INIT0: begin
        tx_load_en = 1;
        tx_load = '{8'hff, 8'hff, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
        frame_len_ = 8;
        frame_tx_off_ = 8;
        if (tx_load_rdy) next_state = S_GRST;
      end
      S_GRST: begin
        if (ps_cen) next_state = S_IDLE;
      end
      S_IDLE: begin
        if (bus_ren & bus_addr[27]) begin
          tx_load_en = 1;
          tx_load = '{8'h40, 8'h40, 8'h00, 8'h00, 8'h00, bus_addr[15:8], 8'h00, 8'h00};
          frame_len_ = 18;
          frame_tx_off_ = 6;
          frame_rx_on_ = 10;
          if (tx_load_rdy) next_state = S_MODE_READ;
        end
      end
      S_MODE_READ: begin
        if (ps_cen) begin
          bus_ack = 1;
          next_state = S_IDLE;
        end
      end
    endcase
  end

  assign bus_rdata = {rx_shift[0], rx_shift[1], rx_shift[2], rx_shift[3]};

endmodule

`default_nettype wire
