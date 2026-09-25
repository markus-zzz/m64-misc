// HDMI transmitter back-end using GTH transceivers (UltraScale+), replacing the
// OSERDES-based serializer for boards where the TMDS pairs are wired to MGTHTX
// pins (via an SN75DP159 redriver).
//
// Topology (Quad 226): 4 GTH TX channels = 3 TMDS data lanes + 1 TMDS clock
// lane. Raw mode (8b/10b disabled), 40-bit TX datapath.
//
// Rate plan (1080p60, HDMI 1.4):
//   pixel clock  = 148.5 MHz
//   line rate    = 1.485 Gb/s  (= 10 * pixel)
//   TXUSRCLK2    = 1.485e9 / 40 = 37.125 MHz (from the IP's TX user clocking)
//   => 40 bits per lane per TXUSRCLK2 tick = 4 TMDS symbols per lane.
//
// The external MGTREFCLK (148.5 MHz from the board PLL) drives the GT CPLL.
// The IP builds the TX user-clock network internally (LOCATE_TX_USER_CLOCKING =
// CORE) and outputs gtwiz_userclk_tx_usrclk2_out; the parent derives the
// 148.5 MHz pixel clock as 4x that clock.
//
// Bit order: GT transmits gtwiz_userdata_tx_in[0] first, and each 10-bit TMDS
// symbol is sent LSB-first, matching TMDS.

`default_nettype none

module hdmi_gth_tx_top
(
    input  wire        mgtrefclk_p,         // 148.5 MHz from external PLL
    input  wire        mgtrefclk_n,
    input  wire        freerun_clk,         // stable ~25 MHz for GT reset FSM/DRP
    input  wire        reset,               // async, active-high

    input  wire        clk_pixel,           // 148.5 MHz pixel clock
    input  wire [9:0]  tmds_symbols [2:0],  // 10-bit TMDS symbol per data lane

    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,

    output wire        tx_ready,             // GT TX reset done + userclk active
    output wire        tx_reset_done_out,    // gtwiz_reset_tx_done (incl. CPLL lock)
    output wire        tx_userclk_active_out,// TX user clock network active
    output wire        txusrclk2_out         // 37.125 MHz TX user clock
);
    // -------------------------------------------------------------------------
    // Reference clock buffer.
    // -------------------------------------------------------------------------
    wire gtrefclk;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH(1'b0),
        .REFCLK_HROW_CK_SEL(2'b00),
        .REFCLK_ICNTL_RX(2'b00)
    ) refclk_buf (
        .I(mgtrefclk_p),
        .IB(mgtrefclk_n),
        .CEB(1'b0),
        .O(gtrefclk),
        .ODIV2()
    );

    // -------------------------------------------------------------------------
    // TX user clock from the IP core.
    // -------------------------------------------------------------------------
    wire txusrclk2;
    wire tx_userclk_active;
    assign txusrclk2_out = txusrclk2;

    // -------------------------------------------------------------------------
    // Symbol gathering: pack 4 consecutive pixel symbols per lane (+ the fixed
    // TMDS clock symbol) into per-lane 40-bit words, LSB-first, in the pixel
    // domain, then capture into the TXUSRCLK2 domain.
    //
    // clk_pixel = 4 * txusrclk2, both from the GT clock tree. They are
    // frequency-locked but their PHASE relationship is arbitrary (the pixel
    // MMCM and the GT introduce unknown offsets). A free-running pixel-domain
    // group counter would therefore latch word[] at an unknown offset relative
    // to the txusrclk2 capture edge, risking a wrong 40-bit boundary or a
    // setup/hold violation on the handoff.
    //
    // To make the handoff deterministic we ANCHOR the group boundary to
    // txusrclk2: a 1-bit toggle in the txusrclk2 domain is synchronized into the
    // pixel domain; each detected edge (one per 40-bit word period) re-aligns
    // the pixel-domain phase counter. This guarantees word[] completes at a
    // fixed pixel-cycle offset ahead of the txusrclk2 capture edge, giving full
    // timing margin and a stable byte boundary (see CDC constraint in io.xdc).
    // -------------------------------------------------------------------------
    localparam [9:0] TMDS_CLK_SYMBOL = 10'b0000011111;

    // txusrclk2-domain group strobe: toggles once per word period.
    reg load_toggle = 1'b0;
    always @(posedge txusrclk2)
        load_toggle <= ~load_toggle;

    // Synchronize the toggle into the pixel domain and detect its edges.
    reg [1:0] ld_sync = 2'd0;
    reg       ld_prev = 1'b0;
    wire      group_align = ld_sync[1] ^ ld_prev; // 1 pixel-cycle pulse per group
    always @(posedge clk_pixel) begin
        ld_sync <= {ld_sync[0], load_toggle};
        ld_prev <= ld_sync[1];
    end

    reg  [39:0] acc  [3:0];
    reg  [39:0] word [3:0];
    reg  [1:0]  phase = 2'd0;

    always @(posedge clk_pixel) begin
        acc[0] <= {tmds_symbols[0], acc[0][39:10]};
        acc[1] <= {tmds_symbols[1], acc[1][39:10]};
        acc[2] <= {tmds_symbols[2], acc[2][39:10]};
        acc[3] <= {TMDS_CLK_SYMBOL, acc[3][39:10]};

        if (group_align) begin
            // Re-anchor to the txusrclk2-derived boundary: this pixel cycle is
            // sub-symbol 0 of a fresh group, so a group completes 3 cycles later.
            phase <= 2'd1;
        end else begin
            if (phase == 2'd3) begin
                word[0] <= {tmds_symbols[0], acc[0][39:10]};
                word[1] <= {tmds_symbols[1], acc[1][39:10]};
                word[2] <= {tmds_symbols[2], acc[2][39:10]};
                word[3] <= {TMDS_CLK_SYMBOL, acc[3][39:10]};
                phase   <= 2'd0;
            end else begin
                phase <= phase + 2'd1;
            end
        end
    end

    reg [39:0] word_tx [3:0];
    always @(posedge txusrclk2) begin
        word_tx[0] <= word[0];
        word_tx[1] <= word[1];
        word_tx[2] <= word[2];
        word_tx[3] <= word[3];
    end

    // Flatten to the 160-bit GT bus. GT user-data bit group N drives GT channel
    // (CHANNEL_ENABLE order) X0Y(8+N). On this board:
    //   GT bit0 -> X0Y8  -> pin N5 -> TMDS D2
    //   GT bit1 -> X0Y9  -> pin L5 -> TMDS D1
    //   GT bit2 -> X0Y10 -> pin J5 -> TMDS D0
    //   GT bit3 -> X0Y11 -> pin G5 -> TMDS clock
    // word[0..2] hold TMDS data lanes 0..2; word[3] is the clock. Data lanes are
    // mapped in REVERSE to the GT channel bits to match the board wiring.
    wire [159:0] gtwiz_userdata_tx;
    assign gtwiz_userdata_tx = {word_tx[3], word_tx[0], word_tx[1], word_tx[2]};

    // -------------------------------------------------------------------------
    // GT status / reset.
    // -------------------------------------------------------------------------
    wire       gtwiz_reset_tx_done;
    wire [3:0] gtpowergood;
    wire       gtwiz_userclk_tx_reset = ~(&gtpowergood);

    assign tx_ready = gtwiz_reset_tx_done & tx_userclk_active;
    assign tx_reset_done_out    = gtwiz_reset_tx_done;
    assign tx_userclk_active_out = tx_userclk_active;

    // -------------------------------------------------------------------------
    // GT core.
    // -------------------------------------------------------------------------
    wire [3:0] gthtxp, gthtxn;
    assign tmds_data_p = gthtxp[2:0];
    assign tmds_data_n = gthtxn[2:0];
    assign tmds_clk_p  = gthtxp[3];
    assign tmds_clk_n  = gthtxn[3];

    hdmi_gth_tx gt_i (
        .gtwiz_userclk_tx_reset_in         (gtwiz_userclk_tx_reset),
        .gtwiz_userclk_tx_srcclk_out       (),
        .gtwiz_userclk_tx_usrclk_out       (),
        .gtwiz_userclk_tx_usrclk2_out      (txusrclk2),
        .gtwiz_userclk_tx_active_out       (tx_userclk_active),
        .gtwiz_userclk_rx_reset_in         (1'b1),
        .gtwiz_userclk_rx_srcclk_out       (),
        .gtwiz_userclk_rx_usrclk_out       (),
        .gtwiz_userclk_rx_usrclk2_out      (),
        .gtwiz_userclk_rx_active_out       (),
        .gtwiz_reset_clk_freerun_in        (freerun_clk),
        .gtwiz_reset_all_in                (reset),
        .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_tx_datapath_in        (1'b0),
        .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
        .gtwiz_reset_rx_datapath_in        (1'b0),
        .gtwiz_reset_rx_cdr_stable_out     (),
        .gtwiz_reset_tx_done_out           (gtwiz_reset_tx_done),
        .gtwiz_reset_rx_done_out           (),
        .gtwiz_userdata_tx_in              (gtwiz_userdata_tx),
        .gtwiz_userdata_rx_out             (),
        .drpclk_in                         ({4{freerun_clk}}),
        .gthrxn_in                         (4'b0000),
        .gthrxp_in                         (4'b0000),
        .gtrefclk0_in                      ({4{gtrefclk}}),
        .gthtxn_out                        (gthtxn),
        .gthtxp_out                        (gthtxp),
        .gtpowergood_out                   (gtpowergood),
        .rxpmaresetdone_out                (),
        .txpmaresetdone_out                ()
    );
endmodule

`default_nettype wire
