/*===========================================================================
 * Filename     : jpeg_enc_if.v
 * Description  : JPEG 编码器的输入接口 —— 跨时钟 + 反压 + 位宽转换
 *
 *  为什么要这个模块 (2026-10-26):
 *    原来的接法 (system_top.v) 有三处硬伤, 导致这条 JPEG 支路**从来没有
 *    出过一帧正确的图**:
 *      ① 编码器直接挂在 S_hs_rx_clk (单路 32.4MHz) 域, 不是快时钟域;
 *      ② 312 拍/MCU, 32.4MHz 下 1080p 只有 6.4fps (搬到 147.5MHz 才 29fps);
 *      ③ s_ready 连出来但**一根线都没用**, 而且只接了 s_data[31:0],
 *         而源是 64bit = 4 像素/拍 —— 每拍 4 个像素里只有 2 个进编码器,
 *         行缓冲永远凑不满 8 行。
 *
 *  本模块负责 ① 和 ③:
 *    源侧 (s_clk 域, 4px/拍, 64bit, 带帧首标记)
 *        -> 异步 FIFO (65bit = {sof, 4像素})
 *        -> 拆成 2 个 32bit (= 2px) word, **严格按 e_ready 反压**
 *        -> 编码器 (e_clk 域, 2px/拍)
 *
 *  关键约定 (照抄 jpeg_encoder_top / jpeg_linebuf 的契约):
 *    · 编码器是**连续流**消费者: 每帧必须恰好 (W/2)*H 个 32bit word,
 *      光栅顺序, 不能多不能少。少一个 word 整个帧就错位, 而且因为
 *      行缓冲按 8 行一组乒乓 (H 必须是 8 的倍数), 错位会传染到后续帧。
 *      => 所以**绝对不能在帧内丢字**。要么整帧进, 要么整帧不进
 *         (后者由上游按传感器帧率控制, 本模块不负责抽帧)。
 *    · s_ready 必须被尊重: 行缓冲满时 (o_wr_ready=0) 编码器不收数据,
 *      此时本模块把数据压在 FIFO 里, 不丢。
 *    · 低位在前的字节序: 一个 64bit 源字 {Cr3,Y3,Cb2,Y2,Cr1,Y1,Cb0,Y0},
 *      低 32bit = {Cr1,Y1,Cb0,Y0} = 像素 0,1 -> 先送; 高 32bit = 像素 2,3。
 *      与 rgb_to_yuv422_quad 的输出位序一致。
 *
 *  诊断 (给 cfg_ctrl_top 只读寄存器用, 排查"出不了帧"时第一手数据):
 *    st_ovf     : 源侧 FIFO 溢出次数 (= 丢了 word, 一定出问题)
 *    st_word_lo : 已转发 64bit word 数的低 16 位 (帧内进度)
 *    st_sof     : 收到的帧首个数
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_enc_if #(
    parameter integer AW = 10,          // FIFO 深度 = 2^AW 个 65bit word
    parameter integer DW = 65
) (
    // ---------------- 源侧: YUV422 4 像素/拍 ----------------
    input  wire         s_clk,
    input  wire         s_rst_n,
    input  wire         s_valid,
    input  wire [63:0]  s_data,
    input  wire         s_sof,          // 该 word 是一个新帧的第 0 个 word

    // ---------------- 编码器侧: YUV422 2 像素/拍 ----------------
    input  wire         e_clk,
    input  wire         e_rst_n,
    output wire         e_valid,
    output wire [31:0]  e_data,
    input  wire         e_ready,

    // ---------------- 诊断 ----------------
    output reg  [15:0]  st_ovf,
    output reg  [15:0]  st_word_lo,
    output reg  [15:0]  st_sof,
    output wire [AW-1:0] o_level
);

    //=============================================================== 源侧写
    wire        f_full, f_empty;
    wire [AW-1:0] f_wcnt, f_rcnt;
    wire [DW-1:0] f_dout;

    assign o_level = f_rcnt;

    wire f_wr = s_valid & ~f_full;

    //=============================================================== 读侧状态
    //  ★ 必须全部声明在 FIFO 例化**之前** —— Verilog 先声明后使用,
    //    否则 e_rd_en 里的 w_v/d_v 会被隐式声明成 1bit wire
    //    (本工程已踩过三次, 见 memory)。
    //  ★ FIFO 的 dout 是寄存器输出, rd_en 之后**晚一拍**才有数据,
    //    所以用 d_v 精确对齐 (d_v <= rd_en), 与 csi2_pack V43 的修法同源。
    reg         d_v;
    reg         w_v;          // 手上有一个 64bit word 待拆
    reg         half;         // 0 = 送低 32bit, 1 = 送高 32bit
    reg  [63:0] w_data;

    wire e_rd_en = ~w_v & ~d_v & ~f_empty;

    always @(posedge s_clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            st_ovf <= 16'd0;
            st_sof <= 16'd0;
        end else begin
            // 源侧溢出 = 丢了 word, 帧结构必然破坏。正常情况下应恒为 0。
            if (s_valid && f_full) st_ovf <= st_ovf + 16'd1;
            if (s_valid && s_sof)  st_sof <= st_sof + 16'd1;
        end
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH (DW),
        .ADDR_WIDTH (AW)
    ) u_fifo (
        .rst          (~(s_rst_n & e_rst_n)),
        .wr_clk       (s_clk   ),
        .rd_clk       (e_clk   ),
        .din          ({s_sof, s_data}),
        .wr_en        (f_wr    ),
        .rd_en        (e_rd_en ),
        .dout         (f_dout  ),
        .full         (f_full  ),
        .empty        (f_empty ),
        .rd_data_count(f_rcnt  ),
        .wr_data_count(f_wcnt  ),
        .wr_rst_busy  (        ),
        .rd_rst_busy  (        )
    );

    //=============================================================== 读侧: 拆字
    assign e_valid = w_v;
    assign e_data  = half ? w_data[63:32] : w_data[31:0];

    always @(posedge e_clk or negedge e_rst_n) begin
        if (!e_rst_n) begin
            d_v       <= 1'b0;
            w_v       <= 1'b0;
            half      <= 1'b0;
            w_data    <= 64'd0;
            st_word_lo<= 16'd0;
        end else begin
            d_v <= e_rd_en;

            // 默认: 消化当前 word
            if (w_v && e_ready) begin
                if (!half) begin
                    half <= 1'b1;            // 低 32bit 已被接走, 接着送高 32bit
                end else begin
                    half <= 1'b0;
                    w_v  <= 1'b0;            // 一个 word 的两半都送完了
                    st_word_lo <= st_word_lo + 16'd1;
                end
            end

            // 取到新 word: 覆写 (d_v=1 时 w_v 必为 0, 见下)
            if (d_v) begin
                w_data <= f_dout[63:0];
                w_v    <= 1'b1;
                half   <= 1'b0;
            end
        end
    end

    //  ★ 上面"覆写"成立的前提: d_v=1 时 w_v 一定还是 0。
    //    证明: d_v <= e_rd_en, 而 e_rd_en 要求 ~w_v, 所以发起读的那一拍 w_v=0;
    //    之后 w_v 只可能被同一个 d_v 置 1, 不可能提前变 1。
    //    这条不变式一旦被破坏, 就会静默丢 word —— 所以 TB 里加了逐字比对。

    //  sof 标记当前未使用 (帧边界由上游按整帧喂, 本模块不抽帧),
    //  但保留在 FIFO 里, 以后做"整帧丢弃"时可以直接用。
    wire _unused_sof = f_dout[64];
    wire _unused_wcnt = |f_wcnt;

endmodule
