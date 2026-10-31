//=============================================================================
// tb_sched.v —— dual_frame_sched 对齐性仿真（对称驱动版）
//
// 前提（用户强调）：两路摄像头采集【理论上要对称】——
//   同一颗 FPGA 提供 XCLK、RSTn 同步释放、同一份初始化表，两颗传感器
//   帧/行相位是锁在一起的。所以本 TB 用**同一个时钟**驱动 I_clk / I_clk1，
//   两路送**完全相同**的数据流。这样任何输出错误都只能来自调度器逻辑。
//
// 两轮：
//   PH = 0  两路完全同相           （理想对称）
//   PH = 3  cam1 行相位晚 3 个组   （同频、有固定相位差，检验块对齐健壮性）
//
// 每轮跑 3 个阶段：
//   P1 单目 cam0（直通）
//   P2 单目 cam1（4 行环形缓冲）
//   P3 双目交替
//
// 判据（每行必须全部满足）：
//   · 一行内所有组的 L 相同（err_mix == 0）
//   · 行内组号从 0 开始、逐 1 递增（err_zero == 0, err_seq == 0）
//   · 每行恰好 LG 个组（err_len == 0）
//   · tuser 只出现在行首（err_u == 0）
//=============================================================================
`timescale 1ns/1ps

module tb_sched;

    localparam DW     = 16;
    localparam LG     = 16;    // 每行组数（真机 480）
    localparam NLINES = 8;     // 每帧行数（真机 1080）
    localparam NGO    = 4;     // 行间空拍
    localparam FGAP   = 8;     // 帧间空拍
    localparam NFRAME = 200;   // 每路送多少帧（跑不完，靠主流程截断）

    reg clk = 0;
    always #5.000 clk = ~clk;          // 两路共用一个时钟：理论上对称

    reg rst_n = 0;
    reg go    = 0;
    reg dual_en = 0, sel = 0;
    integer phase = 0;

    reg [DW-1:0] d0; reg v0, u0, l0;
    reg [DW-1:0] d1; reg v1, u1, l1;

    wire [DW-1:0] O_d;
    wire O_v, O_u, O_l, O_src, O_parity, O_ch1_lost;
    wire [15:0] wr_lines_unused;
    wire [7:0]  lost_lines_unused;

    dual_frame_sched #(.DATA_WIDTH(DW), .LINE_GRP(LG)) dut (
        .I_clk        (clk),
        .I_clk1       (clk),
        .I_rst_n      (rst_n),
        .I_dual_en    (dual_en),
        .I_sel        (sel),
        .I_d0(d0), .I_v0(v0), .I_u0(u0), .I_l0(l0),
        .I_d1(d1), .I_v1(v1), .I_u1(u1), .I_l1(l1),
        .O_d(O_d), .O_v(O_v), .O_u(O_u), .O_l(O_l),
        .O_src(O_src), .O_parity(O_parity), .O_ch1_lost(O_ch1_lost)
    );

    function [DW-1:0] enc(input integer L, input integer g);
        reg [6:0] Lb;
        reg [8:0] gb;
        begin
            Lb  = L[6:0];
            gb  = g[8:0];
            enc = {Lb, gb};
        end
    endfunction

    //-------------------------------------------------------------------------
    //  cam0 驱动
    //-------------------------------------------------------------------------
    integer f, L, g;
    initial begin
        v0 = 0; u0 = 0; l0 = 0; d0 = 0;
        forever begin
            wait (go);
            for (f = 0; (f < NFRAME) && go; f = f + 1) begin
                for (L = 0; (L < NLINES) && go; L = L + 1) begin
                    for (g = 0; (g < LG) && go; g = g + 1) begin
                        @(negedge clk);
                        v0 = 1; d0 = enc(L, g);
                        u0 = (L == 0) && (g == 0);
                        l0 = (g == LG-1);
                    end
                    @(negedge clk); v0 = 0; u0 = 0; l0 = 0;
                    repeat (NGO) @(negedge clk);
                end
                repeat (FGAP) @(negedge clk);
            end
            @(negedge clk); v0 = 0;
            wait (!go);
        end
    end

    //-------------------------------------------------------------------------
    //  cam1 驱动：同频、同数据，相位由 phase 变量控制
    //-------------------------------------------------------------------------
    integer f1, L1, g1;
    initial begin
        v1 = 0; u1 = 0; l1 = 0; d1 = 0;
        forever begin
            wait (go);
            repeat (phase) @(negedge clk);      // 本轮的相位差（同频）
            for (f1 = 0; (f1 < NFRAME) && go; f1 = f1 + 1) begin
                for (L1 = 0; (L1 < NLINES) && go; L1 = L1 + 1) begin
                    for (g1 = 0; (g1 < LG) && go; g1 = g1 + 1) begin
                        @(negedge clk);
                        v1 = 1; d1 = enc(L1, g1);
                        u1 = (L1 == 0) && (g1 == 0);
                        l1 = (g1 == LG-1);
                    end
                    @(negedge clk); v1 = 0; u1 = 0; l1 = 0;
                    repeat (NGO) @(negedge clk);
                end
                repeat (FGAP) @(negedge clk);
            end
            @(negedge clk); v1 = 0;
            wait (!go);
        end
    end

    //-------------------------------------------------------------------------
    //  输出监视
    //-------------------------------------------------------------------------
    integer mon_on = 0;
    integer warm = 0;                       // 0 = 还没对齐到行边界，先不计错
    integer n_lines = 0, n_groups = 0;
    integer err_mix = 0, err_seq = 0, err_len = 0, err_u = 0, err_zero = 0;
    integer cur_L, prev_g, cnt_line, n_u;
    integer src0_lines, src1_lines;

    initial begin
        cur_L = -1; prev_g = -1; cnt_line = 0; n_u = 0;
        src0_lines = 0; src1_lines = 0;
    end

    always @(posedge clk) begin
        if (mon_on && O_v) begin
            if (!warm) begin
                // 等第一个行尾，把统计窗口对齐到行边界
                if (O_l) begin
                    clear_stats;
                    warm = 1;
                end
            end else begin
                if (O_u) begin
                    n_u = n_u + 1;
                    if (cnt_line != 0) err_u = err_u + 1;
                end
                if (cnt_line == 0) begin
                    cur_L  = O_d[15:9];
                    prev_g = O_d[8:0];
                    if (O_d[8:0] != 0) err_zero = err_zero + 1;
                end else begin
                    if (O_d[15:9] != cur_L)                   err_mix = err_mix + 1;
                    if (O_d[8:0]  != ((prev_g + 1) & (LG-1))) err_seq = err_seq + 1;
                    prev_g = O_d[8:0];
                end
                cnt_line = cnt_line + 1;
                n_groups = n_groups + 1;
                if (O_l) begin
                    if (cnt_line != LG) err_len = err_len + 1;
                    if (O_src) src1_lines = src1_lines + 1;
                    else       src0_lines = src0_lines + 1;
                    n_lines  = n_lines + 1;
                    cnt_line = 0;
                end
                if (cnt_line > LG + 3) cnt_line = 0;   // 保护：tlast 丢了
            end
        end
    end

    task clear_stats;
        begin
            n_lines = 0; n_groups = 0;
            err_mix = 0; err_seq = 0; err_len = 0; err_u = 0; err_zero = 0; n_u = 0;
            src0_lines = 0; src1_lines = 0; cnt_line = 0;
            warm = 0;
        end
    endtask

    integer total_fail = 0;

    task report(input [8*24-1:0] tag);
        begin
            $display("[%0s] lines=%0d groups=%0d tuser=%0d src0=%0d src1=%0d",
                     tag, n_lines, n_groups, n_u, src0_lines, src1_lines);
            $display("        err: mix=%0d seq=%0d len=%0d tuser_pos=%0d g0!=0=%0d",
                     err_mix, err_seq, err_len, err_u, err_zero);
            if ((err_mix==0) && (err_seq==0) && (err_len==0) && (err_u==0) && (err_zero==0))
                $display("        => PASS");
            else begin
                $display("        => FAIL");
                total_fail = total_fail + 1;
            end
        end
    endtask

    //-------------------------------------------------------------------------
    //  主流程
    //-------------------------------------------------------------------------
    localparam integer TFRAME = NLINES * (LG + NGO) + FGAP;

    initial begin
        $dumpfile("tb_sched.vcd");
        $dumpvars(0, tb_sched);
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        //======================= 轮 1：完全对称（同相） =======================
        phase = 0;
        go = 1;
        $display("========== PH=0  两路完全同相（理想对称） ==========");

        dual_en = 0; sel = 0;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (6*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P1 cam0 direct");

        dual_en = 0; sel = 1;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (6*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P2 cam1 ring  ");

        dual_en = 1; sel = 0;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (8*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P3 dual       ");

        //================ 轮 2：同频但 cam1 行相位晚 3 个组 =================
        go = 0;
        repeat (40) @(posedge clk);
        phase = 3;
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        go = 1;
        $display("========== PH=3  cam1 行相位晚 3 组（同频） ==========");

        dual_en = 0; sel = 0;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (6*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P1 cam0 direct");

        dual_en = 0; sel = 1;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (6*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P2 cam1 ring  ");

        dual_en = 1; sel = 0;
        repeat (5) @(posedge clk);
        clear_stats; mon_on = 1;
        repeat (8*TFRAME + 40) @(posedge clk);
        mon_on = 0;
        report("P3 dual       ");

        $display("==============================================");
        $display("TOTAL_FAIL=%0d", total_fail);
        if (total_fail == 0) $display("RESULT: ALL PASS");
        else                 $display("RESULT: %0d FAILED", total_fail);
        $finish;
    end

endmodule
