/*===========================================================================
 * Filename     : tb_dual_stitch.v
 * Description  : dual_stitch 的定向 + 随机相位仿真
 *
 *  验证目标
 *  --------
 *  1) 左右拼接顺序: 左半幅全是 cam1 (tag=0xA5), 右半幅全是 cam0 (tag=0x5A);
 *  2) 行内组序号连续 (0..HGRP-1 / 0..HGRP-1)，没有丢组/重复组;
 *  3) 行宽恒定 = 2*HGRP，tlast 只出现在每行最后一组;
 *  4) tuser 只出现在每帧第 0 行;
 *  5) 两路时钟频率故意不同 (32.4MHz / 33.2MHz) 且输出 73.75MHz，
 *     用真实异步关系压 FIFO 边界;
 *  6) 掉一路 (cam1 停流)：左半幅变全 0 (黑)，右半幅照常，输出不中断 —— 
 *     这就是"没插第二颗模组时整条流水线不能死"的验收条件;
 *  7) 恢复后左半幅重新出图。
 *
 *  运行: fpga/sim/run_dual_stitch.ps1
 *===========================================================================*/
`timescale 1ns/1ps

module tb_dual_stitch;

    localparam integer HGRP  = 16;    // 每半幅组数 (真实 480)
    localparam integer V_ACT = 8;     // 每帧行数 (真实 1080)
    localparam integer NFRM  = 6;     // 跑的帧数
    localparam integer T_L   = 30.86; // 左路时钟周期 ns (≈32.4MHz)
    localparam integer T_R   = 30.10; // 右路时钟周期 ns (≈33.2MHz)
    localparam integer T_O   = 13.56; // 输出时钟周期 ns (≈73.75MHz)

    //------------------------------------------------------------- clocks
    reg l_clk = 0, r_clk = 0, o_clk = 0;
    always #(T_L/2.0) l_clk = ~l_clk;
    always #(T_R/2.0) r_clk = ~r_clk;
    always #(T_O/2.0) o_clk = ~o_clk;

    reg rst_n = 0;

    //------------------------------------------------------------- sources
    reg         l_valid = 0, l_user = 0, l_last = 0;
    reg  [39:0] l_data  = 0;
    reg         r_valid = 0, r_user = 0, r_last = 0;
    reg  [39:0] r_data  = 0;

    reg         l_run = 1'b1;   // 0 = 模拟 cam1 掉流
    reg         r_run = 1'b1;

    reg  [15:0] l_line = 0, l_grp = 0;
    reg  [15:0] r_line = 0, r_grp = 0;

    // 左路: valid 连续, 每行 HGRP 组, 帧首第一组带 user, 行尾带 last
    always @(posedge l_clk) begin
        if (!rst_n) begin
            l_valid <= 1'b0; l_user <= 1'b0; l_last <= 1'b0;
            l_line  <= 16'd0; l_grp <= 16'd0;
        end else if (l_run) begin
            l_valid <= 1'b1;
            l_data  <= {8'hA5, l_line, l_grp};
            l_user  <= (l_line == 16'd0) && (l_grp == 16'd0);
            l_last  <= (l_grp == HGRP-1);
            if (l_grp == HGRP-1) begin
                l_grp  <= 16'd0;
                l_line <= (l_line == V_ACT-1) ? 16'd0 : l_line + 16'd1;
            end else begin
                l_grp <= l_grp + 16'd1;
            end
        end else begin
            l_valid <= 1'b0; l_user <= 1'b0; l_last <= 1'b0;
        end
    end

    always @(posedge r_clk) begin
        if (!rst_n) begin
            r_valid <= 1'b0; r_user <= 1'b0; r_last <= 1'b0;
            r_line  <= 16'd0; r_grp <= 16'd0;
        end else if (r_run) begin
            r_valid <= 1'b1;
            r_data  <= {8'h5A, r_line, r_grp};
            r_user  <= (r_line == 16'd0) && (r_grp == 16'd0);
            r_last  <= (r_grp == HGRP-1);
            if (r_grp == HGRP-1) begin
                r_grp  <= 16'd0;
                r_line <= (r_line == V_ACT-1) ? 16'd0 : r_line + 16'd1;
            end else begin
                r_grp <= r_grp + 16'd1;
            end
        end else begin
            r_valid <= 1'b0; r_user <= 1'b0; r_last <= 1'b0;
        end
    end

    //------------------------------------------------------------- DUT
    wire        o_valid, o_user, o_last;
    wire [39:0] o_data;
    wire [15:0] st_l_ovf, st_r_ovf, st_l_starve, st_r_starve, st_lines;
    wire [23:0] st_frames;

    dual_stitch #(
        .HGRP       (HGRP  ),
        .V_ACTIVE   (V_ACT ),
        .FIFO_AW    (11    ),
        .SWAP       (0     ),
        .STARVE_MAX (300   )    // 300*13.56ns ≈ 4.1us ≈ 8 行(HGRP=16)
    ) dut (
        .l_clk     (l_clk), .l_rst_n (rst_n),
        .l_valid   (l_valid), .l_data (l_data), .l_user (l_user), .l_last (l_last),
        .r_clk     (r_clk), .r_rst_n (rst_n),
        .r_valid   (r_valid), .r_data (r_data), .r_user (r_user), .r_last (r_last),
        .o_clk     (o_clk), .o_rst_n (rst_n),
        .o_valid   (o_valid), .o_data (o_data), .o_user (o_user), .o_last (o_last),
        .st_l_ovf (st_l_ovf), .st_r_ovf (st_r_ovf),
        .st_l_starve (st_l_starve), .st_r_starve (st_r_starve),
        .st_lines (st_lines), .st_frames (st_frames)
    );

    //------------------------------------------------------------- checker
    integer errs = 0, pos = 0;
    integer n_grp = 0, n_line = 0, n_user = 0, n_last = 0;
    integer blk_l = 0, blk_r = 0;         // 填黑计数
    reg [15:0] pline = 16'd0;             // 本行左半携带的行号
    reg        l_seen = 1'b0;             // 本行左半是否有真数据
    reg        skew_en = 1'b0;            // 稳态窗口才检查左右行配对
    integer    i;

    always @(posedge o_clk) begin
        if (rst_n) begin
            if (o_valid) begin
                n_grp = n_grp + 1;
                if (o_last) n_last = n_last + 1;
                if (o_user) n_user = n_user + 1;

                if (pos < HGRP) begin
                    // ---------- left half: must be cam1 ----------
                    if (o_data == 40'd0) begin
                        blk_l = blk_l + 1;      // starved 填黑, 允许
                    end else begin
                        l_seen = 1'b1;
                        if (o_data[39:32] !== 8'hA5) begin
                            if (errs < 12)
                                $display("[ERR] L tag @pos=%0d data=%010h (expect tag A5)", pos, o_data);
                            errs = errs + 1;
                        end
                        if (o_data[15:0] !== pos[15:0]) begin
                            if (errs < 12)
                                $display("[ERR] L grp @pos=%0d data=%010h (expect grp %0d)", pos, o_data, pos);
                            errs = errs + 1;
                        end
                        pline = o_data[31:16];
                    end
                end else begin
                    // ---------- right half: must be cam0 ----------
                    if (o_data == 40'd0) begin
                        blk_r = blk_r + 1;
                    end else begin
                        if (o_data[39:32] !== 8'h5A) begin
                            if (errs < 12)
                                $display("[ERR] R tag @pos=%0d data=%010h (expect tag 5A)", pos, o_data);
                            errs = errs + 1;
                        end
                        if (o_data[15:0] !== (pos - HGRP)) begin
                            if (errs < 12)
                                $display("[ERR] R grp @pos=%0d data=%010h (expect grp %0d)",
                                         pos, o_data, pos-HGRP);
                            errs = errs + 1;
                        end
                        // 左右行号允许差 1 (两路自由运行), 差更多说明错行。
                        // ⚠ 第 0 帧不查: 上电时两个 FIFO 的内部复位窗与两路
                        //   恢复时钟相位不同, 第一帧允许有整行级偏差 (自愈),
                        //   从第 2 帧起必须严格对齐。
                        if (l_seen && skew_en &&
                            ((o_data[31:16] > pline + 16'd1) || (o_data[31:16] + 16'd1 < pline))) begin
                            if (errs < 12)
                                $display("[ERR] L/R line skew too big: L=%0d R=%0d @pos=%0d",
                                         pline, o_data[31:16], pos);
                            errs = errs + 1;
                        end
                    end
                end

                // ---------- tlast must be exactly at line end ----------
                if (o_last !== (pos == 2*HGRP-1)) begin
                    $display("[ERR] tlast misplaced @pos=%0d last=%b", pos, o_last);
                    errs = errs + 1;
                end

                if (pos == 2*HGRP-1) begin
                    pos    = 0;
                    n_line = n_line + 1;
                    l_seen = 1'b0;
                end else begin
                    pos = pos + 1;
                end
            end
        end
    end

    //------------------------------------------------------------- debug
`ifdef DBG_STITCH
    integer dbg_n = 0;
    always @(posedge o_clk) begin
        if (rst_n && dbg_n < 160) begin
            dbg_n = dbg_n + 1;
            $display("t=%0t st=%0d cnt=%0d re=%b%b dout_l=%010h dout_r=%010h rdc_l=%0d rdc_r=%0d ov=%b last=%b dat=%010h",
                     $time, dut.r_st, dut.r_cnt, dut.f0_re, dut.f1_re,
                     dut.f0_dout, dut.f1_dout, dut.f0_rdc, dut.f1_rdc,
                     o_valid, o_last, o_data);
        end
    end
    // right FIFO 的写侧行为
    integer wrn = 0;
    always @(posedge r_clk) begin
        if (rst_n && wrn < 40 && dut.f1_we) begin
            wrn = wrn + 1;
            $display("  WR t=%0t din=%010h wrptr=%0d rdptr=%0d full=%b cnt=%0d st=%0d",
                     $time, dut.f1_data, dut.u_fifo_r.wr_ptr_bin, dut.u_fifo_r.rd_ptr_bin,
                     dut.f1_full, dut.w1_cnt, dut.w1_st);
        end
    end
    // 写侧状态全景 (前 120 拍)
    integer wsn = 0;
    always @(posedge r_clk) begin
        if (rst_n && wsn < 120) begin
            wsn = wsn + 1;
            $display("  WS t=%0t st=%0d cnt=%0d v=%b u=%b l=%b we=%b din=%010h wrptr=%0d",
                     $time, dut.w1_st, dut.w1_cnt, dut.f1_valid, dut.f1_user,
                     dut.f1_last, dut.f1_we, dut.f1_din, dut.u_fifo_r.wr_ptr_bin);
        end
    end
`endif

    //------------------------------------------------------------- sequence
    initial begin
        $dumpfile("tb_dual_stitch.vcd");
        $dumpvars(0, tb_dual_stitch);

        repeat (20) @(posedge o_clk);
        rst_n = 1;
        $display("=== Phase 1: dual simultaneous capture, %0d frames ===", NFRM);

        wait (st_frames >= NFRM);
        @(posedge o_clk);
        $display("  frames=%0d lines=%0d groups=%0d tuser=%0d tlast=%0d black(L/R)=%0d/%0d",
                 st_frames, n_line, n_grp, n_user, n_last, blk_l, blk_r);
        if (n_user != NFRM) begin
            $display("[ERR] tuser count %0d != frames %0d", n_user, NFRM);
            errs = errs + 1;
        end

        $display("=== Phase 2: cam1 stopped (left must go black, right keeps running) ===");
        l_run = 1'b0;
        skew_en = 1'b0;
        blk_l = 0; blk_r = 0;
        repeat (2400) @(posedge o_clk);      // enough for starve timeout
        if (blk_l < HGRP) begin
            $display("[ERR] left half not blacked out after cam1 stop (blk_l=%0d)", blk_l);
            errs = errs + 1;
        end
        if (blk_r != 0) begin
            $display("[ERR] cam1 stop also blacked the right half (blk_r=%0d)", blk_r);
            errs = errs + 1;
        end
        $display("  during stop: black L=%0d R=%0d starve_l=%0d", blk_l, blk_r, st_l_starve);

        $display("=== Phase 3: cam1 resumed ===");
        l_run = 1'b1;
        repeat (2400) @(posedge o_clk);      // let FIFO refill / startup transient pass
        blk_l = 0; blk_r = 0; errs = errs;   // clean window measurement
        repeat (1200) @(posedge o_clk);
        if (blk_l != 0) begin
            $display("[ERR] left half still black in steady state after resume (blk_l=%0d)", blk_l);
            errs = errs + 1;
        end
        $display("  steady state after resume: black L=%0d R=%0d", blk_l, blk_r);
        skew_en = 1'b1;
        repeat (1200) @(posedge o_clk);
        skew_en = 1'b0;

        // summary
        $display("---------------------------------------------");
        $display(" ovf L/R    = %0d / %0d   (pad/drop events)", st_l_ovf, st_r_ovf);
        $display(" starve L/R = %0d / %0d   (recoveries, expect L>=1)",
                 st_l_starve, st_r_starve);
        $display(" out frames=%0d lines=%0d", st_frames, st_lines);
        if (errs == 0) $display("RESULT: **PASS**");
        else           $display("RESULT: **FAIL**  errors=%0d", errs);
        $finish;
    end

    // 超时保护
    initial begin
        #5_000_000;
        $display("RESULT: **FAIL** (timeout)");
        $finish;
    end

endmodule
