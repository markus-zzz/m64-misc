module synch #(parameter WIDTH = 1, parameter STAGES = 2) (
    input  wire  [WIDTH-1:0] i,      // input signal
    output logic [WIDTH-1:0] o,      // synchronized output
    input  wire              clk,    // clock to synchronize to
    output logic [WIDTH-1:0] rise,   // one-cycle rising edge pulse
    output logic [WIDTH-1:0] fall    // one-cycle falling edge pulse
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] stages [0:STAGES];

  assign o = stages[STAGES-1];
  assign rise = o & ~stages[STAGES];
  assign fall = ~o & stages[STAGES];
  always_ff @(posedge clk) begin
    stages[0] <= i;
    for (integer i = 0; i < STAGES; i = i + 1)
      stages[i+1] <= stages[i];
  end

endmodule
