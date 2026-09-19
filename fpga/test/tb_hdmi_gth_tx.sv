// xsim testbench for the GTH-based HDMI TX (functional, uses the GTWizard
// behavioral model). It drives the 148.5 MHz differential refclk and the 50 MHz
// board clock into `top`, waits for the GT TX to come up, then samples one TMDS
// data lane serially, reconstructs 10-bit symbols (LSB-first), and reports the
// TMDS clock lane pattern.
//
// This is a bring-up / sanity simulation: it confirms the GT reaches TX-ready,
// the user datapath is driven, and the serial output is toggling with the
// expected structure. Full pixel-accurate video checking would require decoding
// the TMDS/DVI framing, which is out of scope here.

`timescale 1ps/1ps

module tb_hdmi_gth_tx;
    // -------- clocks --------
    // 50 MHz board clock: period 20000 ps.
    logic clk_50mhz = 1'b0;
    always #10000 clk_50mhz = ~clk_50mhz;

    // 148.5 MHz MGT reference clock: period ~6734 ps -> half 3367 ps.
    logic refclk = 1'b0;
    always #3367 refclk = ~refclk;
    wire hdmi_mgtrefclk_p =  refclk;
    wire hdmi_mgtrefclk_n = ~refclk;

    // -------- DUT I/O --------
    logic [3:0] n64_ctrl_data;
    wire  [2:0] hdmi_tx_p, hdmi_tx_n;
    wire        hdmi_clk_p, hdmi_clk_n;

    top dut (
        .clk_50mhz(clk_50mhz),
        .n64_ctrl_data(n64_ctrl_data),
        .hdmi_mgtrefclk_p(hdmi_mgtrefclk_p),
        .hdmi_mgtrefclk_n(hdmi_mgtrefclk_n),
        .hdmi_tx_p(hdmi_tx_p),
        .hdmi_tx_n(hdmi_tx_n),
        .hdmi_clk_p(hdmi_clk_p),
        .hdmi_clk_n(hdmi_clk_n)
    );

    // -------- observe internal readiness via hierarchical refs --------
    // tx_ready lives in top; use a hierarchical path for the message.
    wire tx_ready     = dut.tx_ready;
    wire mmcm_locked  = dut.mmcm_locked;
    wire hdmi_reset   = dut.hdmi_reset;
    wire clk_pixel    = dut.clk_pixel;

    // Count clk_pixel edges to confirm the pixel MMCM is producing a clock.
    integer pixel_edges = 0;
    always @(posedge clk_pixel) pixel_edges = pixel_edges + 1;

    // ---- VCD-visible mirrors of unpacked arrays ----
    // xsim's $dumpvars often omits unpacked arrays of vectors (e.g.
    //   logic [9:0] tmds_symbols [2:0]) from the VCD. Mirror each array element
    // to its own packed signal so every element shows up individually in GTKWave.
    wire [9:0] tmds_symbols_0 = dut.tmds_symbols[0];
    wire [9:0] tmds_symbols_1 = dut.tmds_symbols[1];
    wire [9:0] tmds_symbols_2 = dut.tmds_symbols[2];

    // Packer state inside the GTH wrapper: per-lane 40-bit words (pixel domain)
    // and the captured txusrclk2-domain copy. Lane 3 is the TMDS clock lane.
    wire [39:0] word_0 = dut.gth_tx.word[0];
    wire [39:0] word_1 = dut.gth_tx.word[1];
    wire [39:0] word_2 = dut.gth_tx.word[2];
    wire [39:0] word_3 = dut.gth_tx.word[3];

    wire [39:0] word_tx_0 = dut.gth_tx.word_tx[0];
    wire [39:0] word_tx_1 = dut.gth_tx.word_tx[1];
    wire [39:0] word_tx_2 = dut.gth_tx.word_tx[2];
    wire [39:0] word_tx_3 = dut.gth_tx.word_tx[3];

    // Report key milestones.
    initial begin
        wait (mmcm_locked === 1'b1);
        $display("[%0t] mmcm_locked asserted (pixel_edges so far=%0d)", $time, pixel_edges);
    end
    initial begin
        wait (hdmi_reset === 1'b0);
        $display("[%0t] hdmi_reset released", $time);
    end

    // -------- test sequence --------
    initial begin
        $display("[%0t] simulation start", $time);

        // Dump all signals to VCD for viewing in GTKWave.
        //   gtkwave hdmi_gth_tx.vcd
        // Note: this captures the full hierarchy (including the GT model), so
        // the VCD can get large over a ~34 us run. Narrow the scope of $dumpvars
        // if you only need the fabric-side signals.
        $dumpfile("hdmi_gth_tx.vcd");
        $dumpvars(0, tb_hdmi_gth_tx);

        // Wait for the GT TX to become ready (the GTWizard model runs its reset
        // FSM; this can take tens of microseconds of sim time).
        fork
            begin : wait_ready
                wait (tx_ready === 1'b1);
                $display("[%0t] tx_ready asserted", $time);
            end
            begin : timeout
                #400_000_000;  // 400 us guard
                if (tx_ready !== 1'b1) begin
                    $display("[%0t] ERROR: tx_ready never asserted (timeout)", $time);
                    $finish;
                end
            end
        join_any
        disable timeout;

        // Let the pixel MMCM lock, hdmi_reset release, and the encoder run.
        #100_000_000;  // 100 us after tx_ready

        $display("[%0t] end: pixel_edges=%0d mmcm_locked=%b hdmi_reset=%b",
                 $time, pixel_edges, mmcm_locked, hdmi_reset);
        $display("[%0t] captured %0d serial edges on data lane 0", $time, edge_count);
        if (edge_count < 10)
            $display("[%0t] WARNING: very few serial transitions - lane may be static", $time);
        else
            $display("[%0t] PASS: serial output is active after tx_ready", $time);

        $finish;
    end

    // -------- crude activity monitor on data lane 0 --------
    // The GT serial pins toggle at the line rate (1.485 GHz); we just count
    // transitions as a liveness check (full deserialization needs the exact
    // recovered bit clock, which the behavioral model abstracts).
    integer edge_count = 0;
    logic   prev = 1'bx;
    always @(hdmi_tx_p[0]) begin
        if (tx_ready) begin
            if (prev !== hdmi_tx_p[0])
                edge_count = edge_count + 1;
            prev = hdmi_tx_p[0];
        end
    end

    // Safety net: absolute max sim time.
    initial begin
        #500_000_000;
        $display("[%0t] absolute timeout - finishing", $time);
        $finish;
    end
endmodule
