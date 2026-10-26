`default_nettype none

module joybus_ctrl (
  input  wire        clk,
  input  wire        rst,

  // ---- BUS interface ----
  input wire [31:0]   bus_addr,
  input wire [31:0]   bus_wdata,
  output logic [31:0] bus_rdata,
  input wire          bus_valid,
  input wire    [3:0] bus_wstrb,
  output logic        bus_ack,

  // ---- N64 controller pins ----
  inout wire joybus_io
);

  localparam PRESCALE = 50;

  logic [7:0] frame_cntr;
  logic [7:0] frame_len;
  logic [7:0] frame_01_pos;

  logic [2:0] bit_cntr;

  logic [7:0] tx_shift;
  logic [31:0] rx_shift;

  typedef enum logic [3:0] {
    S_IDLE, S_TX0, S_TX1, S_TX2, S_TX3, S_TX4, S_RX0, S_RX1, S_RX2
  } state_t;

  state_t state;

  logic joybus_zero;
  assign joybus_io = joybus_zero ? 1'b0 : 1'bz;

  logic [3:0] joybus_in_shift;
  always_ff @(posedge clk) joybus_in_shift <= {joybus_in_shift[2:0], joybus_io};

  logic [3:0] rx_symbol;

  logic [31:0] joybus_rx;
  assign bus_rdata = joybus_rx;

  logic [15:0] wait_cntr;
  always_ff @(posedge clk) begin
    if (rst) wait_cntr <= 0;
    else wait_cntr <= wait_cntr + 1;
  end

  always_ff @(posedge clk) begin
    if (rst || wait_cntr == 0) begin
      // If FSM was stuck mark frame as bad
      if (state != S_IDLE) joybus_rx <= 32'hffff_ffff;
      joybus_zero <= 0;
      state <= S_TX0;
    end else begin
      frame_cntr <= frame_cntr + 1;
      case (state)
        S_IDLE: begin
          // Wait until interrupted
        end
        S_TX0: begin
          tx_shift <= 8'h01; // Command: Controller State
          bit_cntr <= 0;
          state <= S_TX1;
        end
        S_TX1: begin
          frame_cntr <= 0;
          frame_len <= PRESCALE * 4 - 1;
          frame_01_pos <= tx_shift[7] ? PRESCALE * 1 - 1 : PRESCALE * 3 - 1;
          joybus_zero <= 1;
          state <= S_TX2;
        end
        S_TX2: begin
          if (frame_cntr == frame_01_pos) joybus_zero <= 0;
          if (frame_cntr == frame_len) begin
            tx_shift <= {tx_shift[6:0], 1'b0};
            bit_cntr <= bit_cntr + 1;
            state <= (bit_cntr == 7) ? S_TX3 : S_TX1;
          end
        end
        S_TX3: begin // Send: Console Stop Bit
          frame_cntr <= 0;
          frame_len <= PRESCALE * 3 - 1;
          frame_01_pos <= PRESCALE * 1 - 1;
          joybus_zero <= 1;
          state <= S_TX4;
        end
        S_TX4: begin
          if (frame_cntr == frame_01_pos) joybus_zero <= 0;
          if (frame_cntr == frame_len) state <= S_RX0;
        end
        S_RX0: begin
          if (~joybus_in_shift[3]) begin
            frame_cntr <= PRESCALE / 2;
            bit_cntr <= 0;
            state <= S_RX1;
          end
        end
        S_RX1: begin
          if (frame_cntr == PRESCALE - 1) begin
            rx_symbol <= {rx_symbol[2:0], joybus_in_shift[3]};
            bit_cntr <= bit_cntr + 1;
            frame_cntr <= 0;
            if (bit_cntr == 3) state <= S_RX2;
          end
        end
        S_RX2: begin
          state <= S_RX0;
          case (rx_symbol)
            4'b0001: rx_shift <= {rx_shift[30:0], 1'b0}; // Zero
            4'b0111: rx_shift <= {rx_shift[30:0], 1'b1}; // One
            4'b0011: begin // Controller Stop Bit
              joybus_rx <= rx_shift;
              state <= S_IDLE;
            end
            default: begin // Corrupt frame
              joybus_rx <= 32'hffff_ffff;
              state <= S_IDLE;
            end
          endcase
        end
      endcase
    end
  end

endmodule

`default_nettype wire
