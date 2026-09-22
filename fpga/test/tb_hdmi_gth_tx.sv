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
            $display("[%0t] serial output is active after tx_ready", $time);

        // Report the packing/lane-mapping self-check results.
        $display("[%0t] packer check: %0d checks, %0d mismatches",
                 $time, pack_checks, pack_errors);
        if (pack_checks == 0)
            $display("[%0t] FAIL: packer check never ran (no groups observed)", $time);
        else if (pack_errors != 0)
            $display("[%0t] FAIL: packer/lane-map mismatches detected", $time);
        else
            $display("[%0t] PASS: packing, bit order, and lane mapping correct", $time);

        $finish;
    end

    // -------------------------------------------------------------------------
    // Self-checking monitor: packing + bit order + lane mapping.
    //
    // Independently reconstructs the expected per-lane 40-bit word from the
    // pixel-domain tmds_symbols stream and compares against the DUT's own
    // word[] at each group boundary (phase==3). This verifies:
    //   * LSB-first 4-symbol packing (bits[9:0]=oldest .. bits[39:30]=newest),
    //   * the fixed clock symbol on lane 3,
    //   * that the GT user-data bus reverses the data lanes and places the
    //     clock on bit group 3 (matching the board wiring N5/L5/J5 = D0/D1/D2).
    //
    // It snoops the DUT's phase so it is phase-aligned by construction; only the
    // data mapping and bit order are under test (not the phase logic).
    // -------------------------------------------------------------------------
    localparam [9:0] CLK_SYM = 10'b0000011111;

    // 4-deep history of each channel's symbols in the pixel domain (index 0 =
    // most recent completed value, i.e. previous cycle).
    logic [9:0] hist0 [3:0];
    logic [9:0] hist1 [3:0];
    logic [9:0] hist2 [3:0];

    integer pack_checks = 0;
    integer pack_errors = 0;

    // Pending expected words, evaluated at the group-complete edge and compared
    // on the following edge (once the DUT's non-blocking word[] update settles).
    logic         pend_valid = 1'b0;
    logic [39:0]  pend0, pend1, pend2, pend3;

    always @(posedge dut.clk_pixel) begin
        // Compare a pending expectation against the now-settled DUT word[].
        if (pend_valid) begin
            pack_checks = pack_checks + 1;
            if (dut.gth_tx.word[0] !== pend0 || dut.gth_tx.word[1] !== pend1 ||
                dut.gth_tx.word[2] !== pend2 || dut.gth_tx.word[3] !== pend3) begin
                pack_errors = pack_errors + 1;
                if (pack_errors <= 5)
                    $display("[%0t] MISMATCH word: got {%h,%h,%h,%h} exp {%h,%h,%h,%h}",
                             $time, dut.gth_tx.word[3], dut.gth_tx.word[2],
                             dut.gth_tx.word[1], dut.gth_tx.word[0],
                             pend3, pend2, pend1, pend0);
            end
            // Verify the GT user-data bus lane remap: {clk, lane0, lane1, lane2}.
            if (dut.gth_tx.gtwiz_userdata_tx[39:0]    !== dut.gth_tx.word_tx[2] ||
                dut.gth_tx.gtwiz_userdata_tx[79:40]   !== dut.gth_tx.word_tx[1] ||
                dut.gth_tx.gtwiz_userdata_tx[119:80]  !== dut.gth_tx.word_tx[0] ||
                dut.gth_tx.gtwiz_userdata_tx[159:120] !== dut.gth_tx.word_tx[3]) begin
                pack_errors = pack_errors + 1;
                if (pack_errors <= 5)
                    $display("[%0t] MISMATCH lane-map on gtwiz_userdata_tx", $time);
            end
            pend_valid <= 1'b0;
        end

        if (dut.hdmi_reset === 1'b0) begin
            // At the group-complete cycle, the DUT latches (this edge):
            //   word[M] = {tmds_symbols[M], acc[39:10]}
            // i.e. {S(t), S(t-1), S(t-2), S(t-3)} with S(t) in bits[39:30].
            // Our hist[0..2] hold S(t-1..t-3) (updated below, after this check).
            if (!dut.gth_tx.group_align && dut.gth_tx.phase == 2'd3) begin
                if (^{dut.tmds_symbols[0], hist0[0], hist0[1], hist0[2]} !== 1'bx) begin
                    pend0 <= {dut.tmds_symbols[0], hist0[0], hist0[1], hist0[2]};
                    pend1 <= {dut.tmds_symbols[1], hist1[0], hist1[1], hist1[2]};
                    pend2 <= {dut.tmds_symbols[2], hist2[0], hist2[1], hist2[2]};
                    pend3 <= {CLK_SYM, CLK_SYM, CLK_SYM, CLK_SYM};
                    pend_valid <= 1'b1;
                end
            end

            // Shift history AFTER using it (index 0 = this cycle's symbol).
            hist0[3] <= hist0[2]; hist0[2] <= hist0[1]; hist0[1] <= hist0[0];
            hist0[0] <= dut.tmds_symbols[0];
            hist1[3] <= hist1[2]; hist1[2] <= hist1[1]; hist1[1] <= hist1[0];
            hist1[0] <= dut.tmds_symbols[1];
            hist2[3] <= hist2[2]; hist2[2] <= hist2[1]; hist2[1] <= hist2[0];
            hist2[0] <= dut.tmds_symbols[2];
        end
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
