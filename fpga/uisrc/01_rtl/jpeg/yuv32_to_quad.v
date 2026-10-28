/*===========================================================================
 * Filename     : yuv32_to_quad.v
 * Description  : dbuf 读侧 (32b = 2px YUV422, 147.5MHz) -> 编码器 (64b = 4px, 70MHz)
 *
 *   为什么要有它:
 *     JPEG 编码器原来接在 dbuf **写侧** (preproc 实时流), 零缓冲。编码速度
 *     (17.45ms/帧) 略慢于输入 (16.67ms), 差 4.6%, 导致帧编到 94% 时下一个
 *     SOF 把 gate 关掉 -> linebuf 断粮 -> 永久死锁 (板上实测 0xA0 恒 0)。
 *     改到 dbuf **读侧** 后, DDR 三帧缓存天然吸收这点缺口: 编码慢就撑住
 *     当前帧不放, 写侧继续用另外两帧, 第三帧满了才阻塞输入 —— 丢整帧而
 *     不是丢行, 每帧数据完整。
 *
 *   带宽核算:
 *     读侧  32b/beat = 2px  @147.5MHz = 295 Mpx/s  (无消隐, DDR 连续读)
 *     编码  64b/beat = 4px  @70MHz    = 280 Mpx/s
 *     => 295 > 280, 余量 5.4%, 且 FIFO 反压天然限流
 *
 *   数据格式:
 *     r_data[31:0] = 2 个 YUV422 像素, 与写侧 S_yuv_data 同样的 on-wire 顺序
 *     拼装: c_data = {第二个 r_data, 第一个 r_data}
 *     每行 beat 数为偶数 (1920), 所以 ph 相位每行自然对齐
 *==========================================================================*/
`timescale 1ns / 1ps
`default_nettype none

module yuv32_to_quad (
    // ---------------- 读侧: dbuf R (147.5MHz) ----------------
    input  wire        r_clk,
    input  wire        r_rst_n,
    input  wire        r_valid,
    input  wire [31:0] r_data,
    input  wire        r_sof,       // 帧首 (O_R_tuser)
    input  wire        r_last,      // 行尾 (O_R_tlast)
    output wire        r_ready,     // -> dbuf I_R_tready (反压)

    // ---------------- 编码器侧 (70MHz) ----------------
    input  wire        c_clk,
    input  wire        c_rst_n,
    output wire        c_valid,
    output wire [63:0] c_data,
    output wire        c_sof,
    output wire        c_last,
    input  wire        c_ready
);

    //=============================================================== 写侧拼装
    //   ph=0 收第一个 32b, ph=1 收第二个并写出 64b
    reg         ph;
    reg  [31:0] low32;
    reg         low_sof;

    wire        put = r_valid && (ph == 1'b1);          // 第二拍才凑满 4px
    // ★ 半字顺序: c_data[31:0] 必须是【早】像素, [63:32] 是【晚】像素 ——
    //   与 dbuf 写侧 rgb_to_yuv422_quad 的 o_data = {pair_2_3, pair_0_1} 一致。
    //   反过来 (先 {low32, r_data}) 会让编码器看到 [2,3,0,1] 的像素顺序。
    wire [65:0] put_data = { r_last, r_sof, r_data, low32 };

    // 写侧: 只有在能写的时候才推进相位 (put 时会写 FIFO, 用 f_full 反压)
    wire        f_full;         // 由 FIFO 输出驱动, 必须是 wire
    always @(posedge r_clk or negedge r_rst_n) begin
        if (!r_rst_n) begin
            ph      <= 1'b0;
            low32   <= 32'd0;
            low_sof <= 1'b0;
        end else if (r_valid && !(ph == 1'b1 && f_full)) begin
            // 第一拍: 暂存; 第二拍: 写出并回到 0
            ph      <= ~ph;
            low32   <= r_data;
            low_sof <= r_sof;
        end
    end

    // 帧首标记: 第一个 word 的 sof 也要带上 (put_data 里用的是第二拍的 r_sof,
    // 而 r_sof 只出现在整帧第 0 拍 -> 需要把第一拍的 low_sof 一起带上)
    wire [66:0] wr_data = { low_sof, put_data };

    wire        f_empty;
    wire [66:0] f_dout;

    // r_ready = 能接收: 要么还没到第二拍(总能收), 要么 FIFO 不满
    assign r_ready = (ph == 1'b0) ? 1'b1 : ~f_full;

    //=============================================================== 读侧 (声明须在例化之前)
    //  FIFO dout 是寄存器输出, rd_en 之后晚一拍才有数据 -> 用 d_v 精确对齐
    reg        d_v;
    reg        h_v;             // 手上有一个 word
    reg [66:0] h_data;

    // ★ 只有手里没有数据、也没有"在途"读, 且 FIFO 非空时才发起一次读。
    //   不能写成 c_ready & ~f_empty —— 那样读指针每个时钟都自增, 数据会被跳过。
    wire rd_en = ~h_v & ~d_v & ~f_empty;

    fifo_32b_async_2 #(
        .DATA_WIDTH (67),
        .ADDR_WIDTH (8)         // 256 深 -> 256*4px = 1024 px ≈ 0.27 行 3840
    ) u_fifo (
        .rst          (~(r_rst_n & c_rst_n)),
        .wr_clk       (r_clk    ),
        .rd_clk       (c_clk    ),
        .din          (wr_data  ),
        .wr_en        (put & ~f_full),
        .rd_en        (rd_en    ),          // ★ aligned 读使能
        .dout         (f_dout   ),
        .full         (f_full   ),
        .empty        (f_empty  ),
        .rd_data_count(         ),
        .wr_data_count(         ),
        .wr_rst_busy  (         ),
        .rd_rst_busy  (         )
    );

    //=============================================================== 读侧逻辑
    assign c_valid = h_v;
    assign c_data  = h_data[63:0];
    assign c_last  = h_data[65];
    assign c_sof   = h_data[66];

    always @(posedge c_clk or negedge c_rst_n) begin
        if (!c_rst_n) begin
            d_v    <= 1'b0;
            h_v    <= 1'b0;
            h_data <= 67'd0;
        end else begin
            d_v <= rd_en;
            if (h_v && c_ready) h_v <= 1'b0;
            if (d_v) begin
                h_data <= f_dout;
                h_v    <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
