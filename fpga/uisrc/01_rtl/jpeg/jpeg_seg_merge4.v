/*===========================================================================
 * Filename     : jpeg_seg_merge4.v
 * Description  : 4 引擎段合并 (4:1 mux)
 *
 *   与 jpeg_seg_merge (2:1, 在 jpeg_bitpack.v 内) 同构, 只是选择器扩到 4 路。
 *   一行 3840 宽 = 4 段 x 960 宽, 按 引擎0->1->2->3 顺序输出:
 *       HDR | L0(r0) RST0 | L1(r0) RST1 | L2(r0) RST2 | L3(r0) RST3
 *           | L0(r1) RST4 | L1(r1) RST5 | ...
 *
 *   切换时机必须精确: 段结束那一拍对应的最后一个字节还没被下游接住时不能切,
 *   否则那个字节会被另一个引擎的数据顶掉。所以用 done_p 锁存, 等
 *   "最后一个字节被 o_ready 接走" 或 "已经没有有效字节" 才切。
 *
 *   流水: 4 个引擎天然错开 (引擎 k 的像素在每行的第 k 个 1/4 段才到),
 *   而合并器 1 字节/拍的输出速度远高于单引擎 ~1 字节/3 拍的产生速度,
 *   所以当前段的字节在下段开始前就已经吐完 —— 一个 4:1 mux 就够。
 *==========================================================================*/
`timescale 1ns / 1ps
`default_nettype none

module jpeg_seg_merge4 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_start,        // 帧开始 (脉冲): 选择器回到引擎 0

    input  wire [3:0]  i_valid,
    input  wire [31:0] i_data,         // 4 x 8bit, i_data[k*8 +: 8]
    input  wire [3:0]  i_last,
    output wire [3:0]  o_ready,

    input  wire [3:0]  i_seg_done,     // 各引擎一段吐完 (脉冲)

    output reg         o_valid,
    output reg  [7:0]  o_data,
    output reg         o_last,
    input  wire        o_ready_down,   // 下游 (byte_bridge) 可接收

    output reg  [9:0]  o_seg_cnt       // 调试: 本帧已完成的段数
);

    // ★ 必须给初值: tb 里 rst_n 在 time 0 由 X 变 0, iverilog 不一定产生
    //   negedge 复位事件 -> sel 保持 X -> (sel==k) 得 X -> 下游 m_ready=X 卡死。
    reg  [1:0]  sel    = 2'd0;    // 0..3 = 输出哪一个引擎
    reg  [3:0]  done_p = 4'd0;    // 各路"本段已吐完"锁存

    // ★ 不要用 generate 循环按位 assign o_ready —— iverilog 会把未选中的位
    //   展开成 X, 下游 m_ready=X 后整条熵编码通路冻结 (踩过, 现象是 segcnt=0)。
    assign o_ready[0] = (sel == 2'd0) && o_ready_down;
    assign o_ready[1] = (sel == 2'd1) && o_ready_down;
    assign o_ready[2] = (sel == 2'd2) && o_ready_down;
    assign o_ready[3] = (sel == 2'd3) && o_ready_down;

    // ---- 当前选中路的数据 (用显式 case, 避免 +: 语法在不同工具间的差异) ----
    wire        cur_valid = i_valid[sel];
    wire        cur_last  = i_last[sel];
    reg  [7:0]  cur_data;
    always @(*) begin
        case (sel)
        2'd0:    cur_data = i_data[ 7: 0];
        2'd1:    cur_data = i_data[15: 8];
        2'd2:    cur_data = i_data[23:16];
        default: cur_data = i_data[31:24];
        endcase
    end

    always @(*) begin
        o_valid = cur_valid;
        o_data  = cur_data;
        o_last  = cur_last;
    end

    // 可以切换的条件: 本段已经吐完, 且(没有待发的字节 或 那个字节这拍被接走)
    wire cur_can_sw = done_p[sel] && (!cur_valid || o_ready_down);

    //==========================================================================
    //  ★★ V54c (2026-10-30) sel 超时兜底 ★★
    //  板上 0x5400 实测: 引擎2/3 (右半幅, cam0) 一旦卡住, 它的 o_seg_done 永远
    //  不来 -> sel 卡在它上面 -> 其它三路也拿不到 m_ready -> 全链死锁, 连
    //  看门狗都救不活 (0xA3~A6 的 enc_stall 在涨但引擎 diag 一动不动)。
    //  这里加"无进展超时": sel 在某一路停留超过 SEL_TO 拍且一个字节都没送出去,
    //  就强制切到下一路 —— 代价是丢一个 RST 段 (画面上一条横条花屏), 但不会死锁。
    //  SEL_TO 取得比"单段正常耗时"大很多: 一段 = 60 MCU x 151clk ≈ 9060 拍,
    //  取 262143 (≈3.7ms @70MHz) 不可能误触发, 只会在真卡死时生效。
    //==========================================================================
    localparam [17:0] SEL_TO = 18'd262143;
    reg  [17:0] sel_tmr;
    // 本拍真的送出了一个字节 = 有进展
    wire sel_prog = cur_valid && o_ready_down;

    wire sel_to = (sel_tmr >= SEL_TO);

    // done_p 同拍可能既 set 又 clear, 先用组合算下一状态再整体写回
    // ★ V54c: 超时也允许切换 (sel_to), 否则一路卡死就永久锁死
    wire sw_ok  = cur_can_sw || sel_to;

    //==========================================================================
    // ★★ V54h (2026-10-31): 切换时必须清 sel_tmr —— 否则"一超时就是永久超时"
    //
    //  板上 0x5404 实测: mrg_segc 在 1 秒内从 0x9683 涨到 0xd081 (= +14846),
    //  而一帧只有 1080 行 x 4 段 = 4320 段。数字本身就证明 sel 在**每拍疯狂轮转**。
    //
    //  根因: sel_tmr 原来只在 i_start / sel_prog 时清零, sw_ok 时不清。
    //    一旦 sel_tmr 撞到 SEL_TO, sel_to 就恒为 1 -> sw_ok 恒为 1 ->
    //    每拍 sel 递增一次、done_p[sel] 每拍被清一次 -> sel 空转一整圈只要 4 拍,
    //    4 路都拿不到**持续**的 o_ready -> 每路引擎输出 FIFO 逐个填满 ->
    //    引擎停在段中间 -> i_seg_done 永不来 -> 全链死锁。
    //    这与实测"eng0 停在 796、eng3 冻在 26385、encif_full[3]=1、consume=0"
    //    完全吻合; 也解释了为什么一超时之后无论等多久都救不回来。
    //
    //  修法: sw_ok 那一拍同时清 sel_tmr, 让超时只生效一拍 (占空 1 拍),
    //    切到下一路后重新完整计时。这样超时是"跳过卡死的那一路", 而不是
    //    "从此永久空转"。
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                             sel_tmr <= 18'd0;
        else if (i_start || sel_prog || sw_ok)  sel_tmr <= 18'd0;
        else if (sel_tmr != SEL_TO)             sel_tmr <= sel_tmr + 18'd1;
    end

    reg [3:0] done_nx;
    // ★★ V54o (2026-11-01): sw_ok 与 i_seg_done[sel] 同拍时不能把"新完成"吞掉 ★★
    //
    //  原来是 `if (sw_ok) done_nx[sel] = 1'b0;` —— 无差别清零。若切换的同一拍
    //  该引擎刚好又完成了一个段 (i_seg_done[sel]=1), 这个"真的完成了"会被当成
    //  "我正在消费的这个 done" 清掉, 于是下一轮要等它再 done —— 但它已经 done
    //  过了不会再发, 那一路就白等一整轮 (最坏情况一路 starve 到底)。
    //  改成: 同拍有新 done 就保留它, 只清掉被消费的那一个。
    always @(*) begin
        done_nx = done_p | i_seg_done;
        if (sw_ok) done_nx[sel] = i_seg_done[sel];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel       <= 2'd0;
            done_p    <= 4'd0;
            o_seg_cnt <= 10'd0;
        end else if (i_start) begin
            sel       <= 2'd0;
            done_p    <= 4'd0;
            o_seg_cnt <= 10'd0;
        end else begin
            done_p <= done_nx;
            if (sw_ok) begin
                sel       <= sel + 2'd1;
                o_seg_cnt <= o_seg_cnt + 10'd1;
            end
        end
    end

endmodule

`default_nettype wire
