module dpram #(
    parameter ADDR_WIDTH = 17,
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 76800,
    parameter INIT_FILE = ""     // optional $readmemh preload
) (
    // Write port
    input  logic                    wr_clk,
    input  logic                    wr_en,
    input  logic [ADDR_WIDTH-1:0]   wr_addr,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    // Read port
    input  logic                    rd_clk,
    input  logic [ADDR_WIDTH-1:0]   rd_addr,
    output logic [DATA_WIDTH-1:0]   rd_data
);

    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1] /* verilator public */;

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge wr_clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always_ff @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
