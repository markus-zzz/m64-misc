`default_nettype none

module top(
	input wire clk_50mhz,
  output logic [3:0] n64_ctrl_data
);

  logic [7:0] cntr;

  always_ff @(posedge clk_50mhz) begin
    cntr <= cntr + 1;
  end

  assign n64_ctrl_data = cntr[7:4];

endmodule
