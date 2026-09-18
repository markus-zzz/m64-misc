`default_nettype none

module top(
  input wire clk_50mhz,
  output logic [3:0] n64_ctrl_data

);

  logic [7:0] cntr;

  always_ff @(posedge clk_50mhz) begin
    cntr <= cntr + 1;
  end

  // Produce square waves at the controller ports with frequencies:
  // Controller port #0: 50MHz/32
  // Controller port #1: 50MHz/64
  // Controller port #2: 50MHz/128
  // Controller port #3: 50MHz/256
  assign n64_ctrl_data = cntr[7:4];

endmodule
