//=============================================================================
// tb_dual_sched.v -- dual_frame_sched verification
//
// Key property: the two alternating frames must NEVER mix.
//   single mode (dual_en=0): output == the selected channel, cycle by cycle
//   dual mode   (dual_en=1): even frames are entirely cam0, odd are entirely cam1
//   cam1 absent:            O_ch1_lost reports it, cam0 frames keep flowing
//
// The two clocks have the same frequency but different phase (models the two
// independent recovered clocks from two sensors).
//=============================================================================
`timescale 1ns/1ps

module tb_dual_sched;

    localparam integer LINE_GRP = 480;
    localparam integer NLINES   = 8;      // lines per frame (shrunk)
    localparam integer LGAP     = 20;     // gap between lines
    localparam integer FGAP     = 200;    // gap between frames

    localparam [39:0] PAT0 = 40'h11_1111_1111;
    localparam [39:0] PAT1 = 40'h22_2222_2222;

    // ---- two clocks, same freq, different phase ----
    reg clk0 = 0, clk1 = 0;
    always #5 clk0 = ~clk0;
    initial begin #2; forever #5 clk1 = ~clk1; end

    reg rst_n = 0;
    reg dual_en = 0;
    reg sel = 0;
    reg run1 = 1;          // 0 = cam1 produces nothing (not connected)

    //-------------------------------------------------------------------------
    // ch0 source (clk0 domain)
    //-------------------------------------------------------------------------
    reg [39:0] d0;
    reg        v0, u0, l0;
    integer r0_row = 0, r0_col = 0, r0_gap = 0;

    always @(posedge clk0) begin
        u0 <= 1'b0;
        if (!rst_n) begin
            v0 <= 0; l0 <= 0; r0_row <= 0; r0_col <= 0; r0_gap <= 0;
        end else if (r0_gap != 0) begin
            r0_gap <= r0_gap - 1; v0 <= 1'b0;
        end else if (r0_col < LINE_GRP) begin
            d0     <= PAT0;
            v0     <= 1'b1;
            u0     <= (r0_row == 0 && r0_col == 0);
            l0     <= (r0_col == LINE_GRP-1);
            r0_col <= r0_col + 1;
        end else begin
            r0_col <= 0;
            v0 <= 1'b0; l0 <= 1'b0;
            if (r0_row == NLINES-1) begin
                r0_row <= 0; r0_gap <= FGAP-1;
            end else begin
                r0_row <= r0_row + 1; r0_gap <= LGAP-1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // ch1 source (clk1 domain), starts half a line later than ch0
    //-------------------------------------------------------------------------
    reg [39:0] d1;
    reg        v1, u1, l1;
    integer r1_row = 0, r1_col = 0, r1_gap = 0;

    always @(posedge clk1) begin
        u1 <= 1'b0;
        if (!rst_n || !run1) begin
            v1 <= 0; l1 <= 0; r1_row <= 0; r1_col <= 0; r1_gap <= 0;
        end else if (r1_gap != 0) begin
            r1_gap <= r1_gap - 1; v1 <= 1'b0;
        end else if (r1_col < LINE_GRP) begin
            d1     <= PAT1;
            v1     <= 1'b1;
            u1     <= (r1_row == 0 && r1_col == 0);
            l1     <= (r1_col == LINE_GRP-1);
            r1_col <= r1_col + 1;
        end else begin
            r1_col <= 0;
            v1 <= 1'b0; l1 <= 1'b0;
            if (r1_row == NLINES-1) begin
                r1_row <= 0; r1_gap <= FGAP-1;
            end else begin
                r1_row <= r1_row + 1; r1_gap <= LGAP-1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    wire [39:0] o_d;
    wire        o_v, o_u, o_l, o_src, o_lost, o_par;

    dual_frame_sched #(
        .DATA_WIDTH (40),
        .LINE_GRP   (LINE_GRP)
    ) dut (
        .I_clk      (clk0), .I_clk1 (clk1), .I_rst_n (rst_n),
        .I_dual_en  (dual_en), .I_sel (sel),
        .I_d0 (d0), .I_v0 (v0), .I_u0 (u0), .I_l0 (l0),
        .I_d1 (d1), .I_v1 (v1), .I_u1 (u1), .I_l1 (l1),
        .O_d (o_d), .O_v (o_v), .O_u (o_u), .O_l (o_l),
        .O_src (o_src), .O_ch1_lost (o_lost), .O_parity (o_par)
    );

    //-------------------------------------------------------------------------
    // statistics
    //-------------------------------------------------------------------------
    integer n_frm, n_bad0, n_bad1, n_other, n_lost;
    integer grp_pat0, grp_pat1;
    integer err = 0;

    always @(posedge clk0) begin
        if (rst_n) begin
            if (o_v) begin
                if (o_d === PAT0)      grp_pat0 = grp_pat0 + 1;
                else if (o_d === PAT1) grp_pat1 = grp_pat1 + 1;
                else                   n_other  = n_other  + 1;
                // cross-frame contamination
                if (o_src == 1'b0 && o_d === PAT1) n_bad0 = n_bad0 + 1;
                if (o_src == 1'b1 && o_d === PAT0) n_bad1 = n_bad1 + 1;
            end
            if (o_lost) n_lost = n_lost + 1;
            if (o_v && o_u) n_frm = n_frm + 1;
        end
    end

    task clr;
        begin
            n_frm = 0; n_bad0 = 0; n_bad1 = 0; n_other = 0; n_lost = 0;
            grp_pat0 = 0; grp_pat1 = 0;
        end
    endtask

    task chk(input [255:0] name,
             input integer want_pat0, input integer want_pat1,
             input integer exp_bad0,  input integer exp_bad1);
        begin
            $display("--------------------------------------------------------");
            $display("[%0s] dual=%0d sel=%0d run1=%0d", name, dual_en, sel, run1);
            $display("  frames=%0d grp_pat0=%0d grp_pat1=%0d other=%0d lost=%0d",
                     n_frm, grp_pat0, grp_pat1, n_other, n_lost);
            $display("  cross-frame: bad0=%0d bad1=%0d", n_bad0, n_bad1);
            if (n_bad0 !== exp_bad0 || n_bad1 !== exp_bad1 || n_other !== 0) begin
                $display("  >>> FAIL (cross-frame contamination)");
                err = err + 1;
            end else if (want_pat0 && grp_pat0 == 0) begin
                $display("  >>> FAIL (cam0 data expected, none seen)");
                err = err + 1;
            end else if (want_pat1 && grp_pat1 == 0) begin
                $display("  >>> FAIL (cam1 data expected, none seen)");
                err = err + 1;
            end else if (!want_pat0 && grp_pat0 != 0) begin
                $display("  >>> FAIL (cam0 data must not appear)");
                err = err + 1;
            end else if (!want_pat1 && grp_pat1 != 0) begin
                $display("  >>> FAIL (cam1 data must not appear)");
                err = err + 1;
            end else begin
                $display("  >>> OK");
            end
        end
    endtask

    localparam integer FRAME_CYC = NLINES*(LINE_GRP+LGAP) + FGAP;

    initial begin
        clr;
        repeat (10) @(posedge clk0);
        rst_n = 1;
        repeat (10) @(posedge clk0);

        //---- A: single mode, sel = cam0 ----
        run1 = 1; dual_en = 0; sel = 0;
        repeat (3*FRAME_CYC) @(posedge clk0);
        clr;
        repeat (2*FRAME_CYC) @(posedge clk0);
        chk("A single sel=cam0", 1, 0, 0, 0);

        //---- B: single mode, sel = cam1 ----
        sel = 1;
        repeat (2*FRAME_CYC) @(posedge clk0);
        clr;
        repeat (2*FRAME_CYC) @(posedge clk0);
        chk("B single sel=cam1", 0, 1, 0, 0);

        //---- C: dual alternate, both present ----
        sel = 0; dual_en = 1;
        repeat (6*FRAME_CYC) @(posedge clk0);
        clr;
        repeat (8*FRAME_CYC) @(posedge clk0);
        chk("C dual alternate both", 1, 1, 0, 0);
        if (n_frm < 4) begin
            $display("  >>> FAIL (too few output frames: %0d)", n_frm);
            err = err + 1;
        end

        //---- D: dual mode but cam1 absent ----
        dual_en = 1; run1 = 0;
        repeat (3*FRAME_CYC) @(posedge clk0);
        clr;
        repeat (6*FRAME_CYC) @(posedge clk0);
        $display("--------------------------------------------------------");
        $display("[D dual, cam1 absent] frames=%0d pat0=%0d pat1=%0d lost=%0d",
                 n_frm, grp_pat0, grp_pat1, n_lost);
        if (n_frm < 2) begin
            $display("  >>> FAIL (output stalled when cam1 absent)");
            err = err + 1;
        end else if (grp_pat1 != 0) begin
            $display("  >>> FAIL (cam1 absent but cam1 data seen)");
            err = err + 1;
        end else if (n_lost == 0) begin
            $display("  >>> FAIL (O_ch1_lost never asserted)");
            err = err + 1;
        end else begin
            $display("  >>> OK (cam0 frames flow, cam1 frames black, lost=1)");
        end

        //---- E: back to single ----
        dual_en = 0; sel = 0; run1 = 1;
        repeat (3*FRAME_CYC) @(posedge clk0);
        clr;
        repeat (2*FRAME_CYC) @(posedge clk0);
        chk("E back to single cam0", 1, 0, 0, 0);

        $display("========================================================");
        if (err == 0) $display("PASS: dual_frame_sched all checks OK");
        else          $display("FAIL: %0d check(s)", err);
        $display("========================================================");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
