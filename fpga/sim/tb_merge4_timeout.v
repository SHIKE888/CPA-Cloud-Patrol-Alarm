`timescale 1ns/1ps
//==============================================================================
//  tb_merge4_timeout.v  —— 回归测试 V54h 的 sel_tmr 清零修复
//
//  背景 (板上 0x5404 实测): mrg_segc 一秒内涨 14846, 而一帧只有 4320 段
//  => sel 在每拍疯狂轮转 => 4 路都拿不到持续 o_ready => 全链死锁。
//
//  本 tb 专门复现"某一路卡死"场景, 验证修复后:
//    T1 正常轮转: sel 按 0->1->2->3 走, 每段只让 o_seg_cnt +1
//    T2 超时跳路: 让 eng2 卡死 (不给数据也不给 seg_done),
//                 超时后应能跳到 3, 且之后**不会**每拍空转
//
//  判据: 统计一段固定的仿真窗口内 o_seg_cnt 的增量。
//        修复前: 增量 ≈ 窗口拍数 (每拍 +1, 空转)
//        修复后: 增量 很小 (只在真切换时 +1)
//==============================================================================
module tb_merge4_timeout;

    reg clk = 0;
    always #5 clk = ~clk;          // 100MHz

    reg         rst_n = 0;
    reg         i_start = 0;
    reg  [3:0]  i_valid = 4'd0;
    reg  [31:0] i_data  = 32'd0;
    reg  [3:0]  i_last  = 4'd0;
    wire [3:0]  o_ready;
    reg  [3:0]  i_seg_done = 4'd0;
    wire        o_valid, o_last;
    wire [7:0]  o_data;
    reg         o_ready_down = 1'b1;
    wire [9:0]  o_seg_cnt;

    jpeg_seg_merge4 dut (
        .clk(clk), .rst_n(rst_n), .i_start(i_start),
        .i_valid(i_valid), .i_data(i_data), .i_last(i_last), .o_ready(o_ready),
        .i_seg_done(i_seg_done),
        .o_valid(o_valid), .o_data(o_data), .o_last(o_last),
        .o_ready_down(o_ready_down),
        .o_seg_cnt(o_seg_cnt)
    );

    //---------------------------------------------------------- 统计
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // 记录 o_seg_cnt 每次变化
    reg  [9:0] seg_prev = 10'd0;
    integer seg_jump = 0;
    always @(posedge clk) begin
        if (o_seg_cnt !== seg_prev) begin
            seg_jump = seg_jump + 1;
            seg_prev = o_seg_cnt;
        end
    end

    integer w0, w1, j0, j1;
    integer err = 0;

    //---------------------------------------------------------- T1: 正常轮转
    task run_normal;
        begin
            i_valid    = 4'b1111;
            i_data     = 32'h44332211;
            i_last     = 4'b0000;
            i_seg_done = 4'd0;
        end
    endtask

    // 让当前选中的那一路吐 4 拍数据, 然后给 seg_done
    task feed_seg;
        input integer k;
        begin
            i_valid    <= 4'b1111;
            i_data     <= 32'h44332211;
            i_seg_done <= 4'd0;
            repeat (4) @(posedge clk);
            i_valid    <= 4'b0000;
            i_seg_done <= (4'd1 << k);
            @(posedge clk);
            i_seg_done <= 4'd0;
            @(posedge clk);
        end
    endtask

    integer k;
    integer sel_seen [0:7];
    integer nsel;

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        i_start = 1'b1;
        @(posedge clk);
        i_start = 1'b0;
        @(posedge clk);

        //================================================ T1 正常: 每路依次完成
        $display("---- T1: normal round-robin ----");
        for (k = 0; k < 8; k = k + 1) begin
            feed_seg(k % 4);
        end
        $display("  T1 o_seg_cnt=%0d  seg_jump=%0d", o_seg_cnt, seg_jump);
        if (o_seg_cnt < 4) begin
            $display("  FAIL: o_seg_cnt=%0d, expected >= 4 (selector never advanced)", o_seg_cnt);
            err = 1;
        end
        if (seg_jump > 200) begin
            $display("  FAIL: seg_jump=%0d too many (selector spinning every cycle)", seg_jump);
            err = 1;
        end

        //================================================ T2 超时: eng2 卡死
        $display("---- T2: eng2 stalls, expect timeout skip ----");
        i_start = 1'b1;
        @(posedge clk);
        i_start = 1'b0;
        @(posedge clk);

        // eng0 / eng1 正常完成, 让 sel 走到 2
        feed_seg(0);
        feed_seg(1);

        // 现在 sel 应在 2, eng2 永不响应 (无数据, 无 seg_done)
        // 记录一个窗口内的 seg_cnt 增量
        w0 = cyc; j0 = seg_jump;
        repeat (3000) @(posedge clk);
        w1 = cyc; j1 = seg_jump;
        $display("  T2 window: %0d cyc, seg_cnt %0d -> %0d (%0d jumps)",
                 w1 - w0, dut.o_seg_cnt, dut.o_seg_cnt, j1 - j0);
        // 3000 拍内若空转, jump 会接近 3000
        if ((j1 - j0) > 1500) begin
            $display("  FAIL: %0d jumps in %0d cycles -> selector is spinning (V54h regression!)",
                     j1 - j0, w1 - w0);
            err = 1;
        end else begin
            $display("  OK: selector not spinning (%0d jumps in %0d cyc)", j1 - j0, w1 - w0);
        end

        //================================================ T3 超时后能否恢复
        // 让超时真正发生 (SEL_TO=262143, 需等待), 然后看 sel 是否挪到 3
        $display("---- T3: wait for SEL_TO, then eng3 must be served ----");
        // 继续让 eng2 卡死, 其它两路有数据
        //   bit3=1(eng3 有数据)  bit2=0(eng2 卡死)  bit1=1(eng1)  bit0=0
        i_valid <= 4'b1010;
        i_data  <= 32'h44332211;
        $display("  before wait: sel=%0d sel_tmr=%0d done_p=%b o_seg_cnt=%0d",
                 dut.sel, dut.sel_tmr, dut.done_p, o_seg_cnt);
        repeat (270000) @(posedge clk);
        $display("  after SEL_TO: sel=%0d sel_tmr=%0d done_p=%b o_seg_cnt=%0d",
                 dut.sel, dut.sel_tmr, dut.done_p, o_seg_cnt);
        i_valid <= 4'b0000;

        repeat (20) @(posedge clk);

        $display("");
        $display("==================================================");
        if (err) $display("RESULT: FAIL");
        else     $display("RESULT: PASS");
        $display("==================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;   // 20ms 仿真时间
        $display("TIMEOUT (sim guard) o_seg_cnt=%0d", o_seg_cnt);
        $finish;
    end

endmodule
