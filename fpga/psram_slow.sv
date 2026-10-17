`default_nettype none

module psram_slow (
  input  wire        clk,
  input  wire        rst,

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
  input  wire        ps_dqs
);

  //
  // Clock generation - generate a div 16 clock with clock enables (for both
  // posedge and negedge) as well as a phase shifted clock to be sent to the
  // PSRAM. That is to keep things simple where everything runs in a single
  // clock domain.
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

  logic frame_start_valid, frame_start_ready;
  logic frame_stop_valid, frame_stop_ready;

  logic [4:0] frame_cntr;   // Running index inside the frame (starts counting from when ps_cen is asserted)
  logic [4:0] frame_tx_off; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on;  // For when to enable the RX-gate

  // XXX: Should move into its own psram_slow_phy module
  logic [4:0] frame_tx_off_; // For when to disable TX (i.e. start driving ZZ)
  logic [4:0] frame_rx_on_;  // For when to enable the RX-gate

  logic tx_on;
  logic rx_on;

  assign frame_start_ready = ps_cen & clk_negedge;
  assign frame_stop_ready = ~ps_cen; // & clk_negedge;

  always_ff @(posedge clk) begin
    if (rst) begin
      ps_cen <= 1;
    end else if (frame_start_valid & frame_start_ready) begin
      ps_cen <= 0;
      frame_cntr <= 0;
      frame_tx_off <= frame_tx_off_;
      frame_rx_on <= frame_rx_on_;
    end else if (clk_posedge | clk_negedge) begin
      frame_cntr <= frame_cntr + 1;
    end

    if (frame_stop_valid & frame_stop_ready) ps_cen <= 1;
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
    end else if (clk_posedge | clk_negedge) begin
      for (integer i = 0; i < 8 - 1; i = i + 1) tx_shift[i] <= tx_shift[i + 1];
      tx_shift[7] <= 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) tx_on <= 0;
    else if (frame_start_valid & frame_start_ready) tx_on <= 1;
    else if (frame_cntr == frame_tx_off) tx_on <= 0;
  end

  always_ff @(posedge clk) begin
    if (ps_cen) rx_on <= 0;
    else if (frame_cntr == frame_rx_on) rx_on <= 1;
  end

  assign ps_dq = tx_on ? tx_shift[0] : 8'hzz;
  assign ps_dqs = tx_on ? 8'h00 : 8'hzz;

  //
  // RX-path
  //
  logic [2:0] dqs_sync;
  always_ff @(posedge clk) begin
    dqs_sync <= {ps_dqs, dqs_sync[2:1]};
  end
  logic [7:0] rx_shift [0:3];
  logic [3:0] rx_cntr;
  always_ff @(posedge clk) begin
    if (~rx_on) begin
      rx_cntr <= 0;
    end else if (~ps_cen & (dqs_sync[1] ^ dqs_sync[0])) begin
      for (integer i = 0; i < 4 - 1; i = i + 1) rx_shift[i] <= rx_shift[i + 1];
      rx_shift[3] <= ps_dq; // DQ stable after DQS edge
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
        if (frame_start_ready) next_state = S_GRST1;
      end
      S_GRST1: begin
        if (frame_cntr == 8) frame_stop_valid = 1;
        if (frame_stop_valid & frame_stop_ready) next_state = S_WAIT;
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
        if (frame_start_ready) next_state = S_MODE_READ1;
      end
      S_MODE_READ1: begin
        if (rx_cntr == 4) frame_stop_valid = 1;
        if (frame_stop_valid & frame_stop_ready) next_state = S_ACK;
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
        if (frame_start_ready) next_state = S_MODE_WRITE1;
      end
      S_MODE_WRITE1: begin
        if (frame_cntr == 8) frame_stop_valid = 1;
        if (frame_stop_valid & frame_stop_ready) next_state = S_ACK;
      end
      //
      // Sync Read
      //
      S_SYNC_READ0: begin
        frame_start_valid = 1;
        tx_load_en = 1;
        tx_load = '{8'h00, 8'h00, bus_addr[26:24], bus_addr[23:16], bus_addr[15:8], bus_addr[7:0], 8'h00, 8'h00};
        frame_tx_off_ = 6;
        frame_rx_on_ = 10 - 2;
        if (frame_start_ready) next_state = S_SYNC_READ1;
      end
      S_SYNC_READ1: begin
        if (rx_cntr == 4) frame_stop_valid = 1;
        if (frame_stop_valid & frame_stop_ready) next_state = S_ACK;
      end
      //
      // Sync Write
      //
      S_SYNC_WRITE0: begin
        frame_start_valid = 1;
        frame_tx_off_ = 19;
        tx_load_en = 1;
        tx_load = '{8'h80, 8'h80, bus_addr[26:24], bus_addr[23:16], bus_addr[15:8], bus_addr[7:0], 8'h00, 8'h00};
        if (frame_start_ready) next_state = S_SYNC_WRITE1;
      end
      S_SYNC_WRITE1: begin
        if (frame_cntr == 15 - 1) begin
          tx_load_en = 1;
          tx_load = '{bus_wdata[31:24], bus_wdata[23:16], bus_wdata[15:8], bus_wdata[7:0], 8'h00, 8'h00, 8'h00, 8'h00};
          next_state = S_SYNC_WRITE2;
        end
      end
      S_SYNC_WRITE2: begin
        if (frame_cntr == 19 - 1) frame_stop_valid = 1;
        if (frame_stop_valid & frame_stop_ready) next_state = S_ACK;
      end
      S_ACK: begin
        bus_ack = 1;
        next_state = S_WAIT;
      end
      S_WAIT: begin
          if (clk_posedge) next_state = S_IDLE;
      end
    endcase
  end

  assign bus_rdata = {rx_shift[0], rx_shift[1], rx_shift[2], rx_shift[3]};

endmodule

`default_nettype wire
