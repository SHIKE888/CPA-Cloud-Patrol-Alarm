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

    // done_p 同拍可能既 set 又 clear, 先用组合算下一状态再整体写回
    reg [3:0] done_nx;
    always @(*) begin
        done_nx = done_p | i_seg_done;
        if (cur_can_sw) done_nx[sel] = 1'b0;
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
            if (cur_can_sw) begin
                sel       <= sel + 2'd1;
                o_seg_cnt <= o_seg_cnt + 10'd1;
            end
        end
    end

endmodule

`default_nettype wire
