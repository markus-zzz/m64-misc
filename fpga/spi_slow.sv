`default_nettype none

// XXX: TODO: For now only supports bursts in the write direction. Should get
// more elaborate handshake in place with bus_wreq / bus_wack and bus_rreq /
// bus_rack so that the client has time to respond. If no response before next
// SPI 32-bit data word comes a long set bit in error register indicating the
// overrun/underrun.
// Also would probably benefit from splitting the FSM implementation into an
// always_ff and always_comb part.

module spi_slave (
	input wire clk,
  input wire spi_cs_n,
  input wire spi_clk,
  output wire spi_miso,
  input wire spi_mosi,
  output wire [31:0] bus_addr,
  input wire [31:0] bus_rdata,
  output wire [31:0] bus_wdata,
  output reg bus_ren,
  output reg bus_wen
);

    typedef enum logic [2:0] {
        SPI_CMD,
        SPI_ADDR,
        SPI_DUMMY_0,
        SPI_DATA,
        SPI_DUMMY_1
    } state_t;

    state_t state;
    logic [5:0] cntr;
    logic inc_addr;

    logic [15:0] reg_cmd;
    logic [31:0] reg_addr;
    logic [32:0] reg_rdata;
    logic [31:0] reg_wdata;

    logic [2:0] spi_cs_n_sync;
    logic [2:0] spi_clk_sync;
    logic [2:0] spi_mosi_sync;

    always_ff @(posedge clk) begin
      spi_cs_n_sync <= {spi_cs_n, spi_cs_n_sync[2:1]};
      spi_clk_sync <= {spi_clk, spi_clk_sync[2:1]};
      spi_mosi_sync <= {spi_mosi, spi_mosi_sync[2:1]};
    end

    always_ff @(posedge clk) begin
        bus_ren <= 0;
        bus_wen <= 0;
        inc_addr <= 0;

        if (inc_addr) begin
          reg_addr <= reg_addr + 32'h4;
        end

        if (spi_cs_n_sync[1]) begin
            state <= SPI_CMD;
            cntr <= 0;
        end else if (spi_clk_sync[1:0] == 2'b10) begin
            cntr <= cntr + 1;
            case (state)
              SPI_CMD: begin
                reg_cmd <= {reg_cmd[14:0], spi_mosi_sync[1]};
                if (cntr == 15) begin
                  cntr <= 0;
                  state <= SPI_ADDR;
                end
              end
              SPI_ADDR: begin
                reg_addr <= {reg_addr[30:0], spi_mosi_sync[1]};
                if (cntr == 31) begin
                  bus_ren <= ~reg_cmd[15];
                  cntr <= 0;
                  state <= SPI_DUMMY_0;
                end
              end
              SPI_DUMMY_0: begin
                if (cntr == 7) begin
                  reg_rdata <= {1'b0, bus_rdata};
                  cntr <= 0;
                  state <= SPI_DATA;
                end
              end
              SPI_DATA: begin
                reg_wdata <= {reg_wdata[30:0], spi_mosi_sync[1]};
                if (cntr == 31) begin
                  bus_wen <= reg_cmd[15];
                  cntr <= 0;
                  inc_addr <= 1;
                end
              end
              SPI_DUMMY_1: begin
                // Wait for spi_cs_n to go get deasserted (as it will trigger a reset of the FSM)
              end
            endcase
        end else if (spi_clk_sync[1:0] == 2'b01) begin
            case (state)
              SPI_DATA: begin
                reg_rdata <= {reg_rdata[31:0], 1'b0};
              end
            endcase
        end
    end

    assign bus_addr = reg_addr;
    assign bus_wdata = reg_wdata;
    assign spi_miso = reg_rdata[32];

endmodule

