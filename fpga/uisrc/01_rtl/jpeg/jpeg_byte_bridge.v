/*===========================================================================
 * Filename     : jpeg_byte_bridge.v
 * Description  : JPEG 码流跨时钟桥 —— 编码器域(300MHz) -> CSI-2 发送域(byte_clk 150MHz)
 *
 *  为什么需要它 (2026-10-26):
 *    原来 csi2_frame_tx_var (X_jv) 挂在 S_hs_rx_clk (单路 32.4MHz) 上,
 *    而它的 hs_en/hs_data 直接喂给 D-PHY TX —— 那是在 **S_dsi_byte_clk**(150MHz)
 *    域采样的。也就是说这条 JPEG 支路的最后一跳本来就是跨时钟域没做同步,
 *    又一个"从来没跑过"的证据。
 *    现在编码器要挪到 300MHz, 而 D-PHY 必须在 byte_clk 域,
 *    所以中间必须有一个异步 FIFO。
 *
 *  数据量很小: 3840x1080@60 按 Q75 约 12~18 MB/s, 256 深 (9bit) 完全够吸收突发。
 *  9bit = {last, byte}, last 只在每帧最后一个字节 (0xFF/0xD9) 置位,
 *  用来保持 csi2_frame_tx_var 的 s_tlast 语义。
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_byte_bridge #(
    parameter integer AW = 8            // 深度 = 2^AW 字节
) (
    // ---------------- 写侧: 编码器字节流 ----------------
    input  wire        w_clk,
    input  wire        w_rst_n,
    input  wire        w_valid,
    input  wire [7:0]  w_data,
    input  wire        w_last,
    output wire        w_ready,         // = ~full, 送给编码器 m_ready

    // ---------------- 读侧: csi2_frame_tx_var ----------------
    input  wire        r_clk,
    input  wire        r_rst_n,
    output wire        r_valid,
    output wire [7:0]  r_data,
    output wire        r_last,
    input  wire        r_ready,

    // ---------------- 诊断 ----------------
    //  st_bp = 写侧被 FIFO 满反压的拍数。**正常可非零** ——
    //    编码器从 m_ready 得到了反压, 不会丢字节; 这里只是记录背压量,
    //    如果它一直很大 (接近总拍数) 说明读侧 (CSI-2 发送) 卡住了。
    output reg  [15:0] st_bp,
    output wire [AW-1:0] o_level
);

    //  ★ 读侧状态必须声明在 FIFO 例化之前 (Verilog 先声明后使用)
    reg         d_v;                    // FIFO dout 有效 (rd_en 后一拍)
    reg         h_v;                    // 手上有一个字节待送
    reg  [8:0]  h_data;

    wire        f_full, f_empty;
    wire [8:0]  f_dout;
    wire [AW-1:0] f_rcnt, f_wcnt;

    wire r_rd_en = ~h_v & ~d_v & ~f_empty;

    assign o_level = f_rcnt;

    assign w_ready = ~f_full;
    wire   w_wr    = w_valid & ~f_full;

    always @(posedge w_clk or negedge w_rst_n) begin
        if (!w_rst_n) st_bp <= 16'd0;
        else if (w_valid && f_full) st_bp <= st_bp + 16'd1;
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH (9),
        .ADDR_WIDTH (AW)
    ) u_fifo (
        .rst          (~(w_rst_n & r_rst_n)),
        .wr_clk       (w_clk   ),
        .rd_clk       (r_clk   ),
        .din          ({w_last, w_data}),
        .wr_en        (w_wr    ),
        .rd_en        (r_rd_en ),
        .dout         (f_dout  ),
        .full         (f_full  ),
        .empty        (f_empty ),
        .rd_data_count(f_rcnt  ),
        .wr_data_count(f_wcnt  ),
        .wr_rst_busy  (        ),
        .rd_rst_busy  (        )
    );

    //=============================================================== 读侧 FWFT
    //  fifo_32b_async_2 的 dout 是寄存器输出: rd_en 之后晚一拍才有数据,
    //  这里用 d_v 对齐, 再用 h_data 保持住直到下游接走。
    assign r_valid = h_v;
    assign r_data  = h_data[7:0];
    assign r_last  = h_data[8];

    always @(posedge r_clk or negedge r_rst_n) begin
        if (!r_rst_n) begin
            d_v    <= 1'b0;
            h_v    <= 1'b0;
            h_data <= 9'd0;
        end else begin
            d_v <= r_rd_en;

            if (h_v && r_ready) h_v <= 1'b0;          // 字节被接走
            if (d_v) begin
                h_data <= f_dout;
                h_v    <= 1'b1;
            end
        end
    end

endmodule
