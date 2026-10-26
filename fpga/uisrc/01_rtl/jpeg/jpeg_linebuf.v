/*===========================================================================
 * Filename     : jpeg_linebuf.v
 * Description  : 8 行行缓冲 (乒乓双缓冲), 把逐行扫描的 YUV422 拆成 MCU 可直接读的形式
 *
 *  为什么必须缓冲 8 行:
 *      JPEG 4:2:2 的 MCU 是 16x8, 需要 8 行像素才能凑出一个 MCU 行。
 *      输入是逐行扫描的, 所以必须先攒满 8 行。
 *
 *  为什么乒乓:
 *      攒第 N+1 组 8 行时, 编码器要能同时读第 N 组。
 *      单缓冲就必须"写的时候停编码 / 编码的时候停写", 帧率会掉到 2/3。
 *
 *  存储布局 (每组 64bit = 8 个像素, 正好喂 jpeg_dct2d 一次):
 *      y_mem : 16 行 x (W/8)  组 x 64bit
 *      cb_mem: 16 行 x (W/16) 组 x 64bit
 *      cr_mem: 16 行 x (W/16) 组 x 64bit
 *      (16 行 = 2 组 x 8 行)
 *
 *  写: 每拍 1 个 YUV422 word (2 像素)
 *      Y0,Y1 写进 y_mem 的同一个 64bit 组 (字节对)
 *      Cb / Cr 各写 cb_mem / cr_mem 的一个字节
 *
 *  读: 每拍 1 个 64bit 组 (8 像素), 读延迟 1 拍
 *
 *  ★ 组索引约定 (与 csi2/packer 的 MCU 顺序一致):
 *      亮度块: grp = mcu_x*2 + blk   (0 .. W/8-1)
 *      色度块: grp = mcu_x           (0 .. W/16-1)
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_linebuf #(
    parameter integer W = 1920          // 有效宽度, 必须能被 16 整除
) (
    input  wire        clk,
    input  wire        rst_n,

    // ★ 2026-10-26: 行宽改成运行时。W 参数只用来定存储深度 (= 最大分辨率),
    //   否则换分辨率时 wrow 按旧 W 计行, 8 行组永远凑不满 -> 编码器永久等
    //   lb_avail (实测: 改成运行时 MCU 后帧不再完成就是这个原因)。
    input  wire [11:0] i_width,

    // ---------------- 输入: YUV422 {Cr,Y1,Cb,Y0}, 2 像素/拍 ----------------
    input  wire        i_valid,
    input  wire [31:0] i_data,
    output wire        o_wr_ready,

    // ---------------- MCU 读 ----------------
    input  wire [2:0]  i_rd_row,        // 0..7
    input  wire [8:0]  i_rd_grp,        // 组索引 (W=3840 时需要 9 位: 0..479)
    input  wire [1:0]  i_rd_sel,        // 0=Y块0 1=Y块1 2=Cb 3=Cr
    output reg  [63:0] o_rd_data,

    // ---------------- 组握手 ----------------
    output wire        o_rd_avail,      // 【电平】当前读 buffer 已写满 8 行
    output reg         o_grp_ready,     // 一组 8 行写满 (脉冲)
    input  wire        i_grp_done       // 编码器用完当前读组 (脉冲)
);

    localparam integer GY  = W / 8;     // 亮度每组像素数
    localparam integer GC  = W / 16;    // 色度每组像素数
    localparam integer WX  = W / 2;     // 每行 word 数
    localparam integer GYW = $clog2(GY);   // 组索引位宽
    localparam integer GCW = $clog2(GC);
    // ★ 每行的组数必须补齐到 2 的幂, 因为地址靠位拼接 {buf,row,grp} 形成。
    //   W=192 时 GY=24 ($clog2=5 -> 可表示 32), 拼出来的地址与
    //   buf*8*GY + row*GY + grp 不等, 会写错行/读错行 (实测多输出 3 倍字节)
    localparam integer GYP = 1 << GYW;
    localparam integer GCP = 1 << GCW;

    localparam integer YDEP = 16 * GYP;
    localparam integer CDEP = 16 * GCP;
    // ★ 2026-10-26: 地址位宽原来写死 12 位。W=3840 时 GYW=9 ->
    //   {buf,row(3),grp(9)} = 13 位, 被截成 12 位后就只能访问一半缓冲,
    //   读写都错位 (4K 模式必填)。这里改成按实际深度推导。
    localparam integer YAW = (YDEP <= 1) ? 1 : $clog2(YDEP);
    localparam integer CAW = (CDEP <= 1) ? 1 : $clog2(CDEP);

    //=============================================================== 存储
    // ★ 2026-10-21 为省 slice 改: 去掉 initial 循环清零。
    //   原来用 `for zi ... mem[zi] = 0` 做仿真初始化, 但这会让综合器**无法**
    //   把这些数组推断成 ERAM(块 RAM 不支持这种任意初值), 于是一律退回
    //   寄存器实现 —— 128 Kbit 的缓冲变成 8192 个 FF + 大 mux,
    //   实测打开 JPEG_EN 后 slice 从 44624 直接涨到 63363 (98.5%), 根本布不通线。
    //   上电未写位置是 X 没关系: 读侧只在 full0/full1 置位后才被允许读,
    //   而 full 标志只有在整 8 行写满后才拉高, 永远读不到没写过的位置。
    (* ram_style = "block" *) reg [63:0] y_mem  [0:YDEP-1];
    (* ram_style = "block" *) reg [63:0] cb_mem [0:CDEP-1];
    (* ram_style = "block" *) reg [63:0] cr_mem [0:CDEP-1];

    //=============================================================== 写侧
    reg [10:0] wx;              // word 列 0..WX-1
    reg [2:0]  wrow;            // 行 0..7
    reg        wr_buf;          // 当前写 buffer
    reg        rd_buf;          // 当前读 buffer
    reg        full0, full1;    // 该组是否已写满待编码

    assign o_wr_ready = ~((wr_buf == 1'b0) ? full0 : full1);
    assign o_rd_avail =  (rd_buf == 1'b0) ? full0 : full1;

    wire [31:0] wd  = i_data;
    wire [7:0]  w_y0 = wd[7:0];
    wire [7:0]  w_cb = wd[15:8];
    wire [7:0]  w_y1 = wd[23:16];
    wire [7:0]  w_cr = wd[31:24];

    wire [1:0]   ysub = wx[1:0];
    wire [GYW-1:0] ygrp = wx[GYW+1:2];  // /4
    wire [2:0]   csub = wx[2:0];
    wire [GCW-1:0] cgrp = wx[GCW+2:3];  // /8

    wire [YAW-1:0] yaddr = {wr_buf, wrow, ygrp};
    wire [CAW-1:0] caddr = {wr_buf, wrow, cgrp};

    // ★ 2026-10-21 改: 原来这里是**窄写** —— 每次只写 64 位存储字里的 16 位
    //   (Y) 或 8 位 (Cb/Cr)。块 RAM 推断不了这种写法, 综合器只能退回寄存器实现,
    //   128 Kbit 的缓冲变成一大堆 FF + mux, slice 直接爆到 98.5%。
    //   现在改成"攒满再整字写": Y 每 4 个输入 word 凑一个 64 位存储字,
    //   Cb/Cr 每 8 个字节凑一个。
    //   ★ 写入时机不变: ysub==3 / csub==7 正好是每个存储字的最后一个分量
    //   (WX 是 4 和 8 的整数倍), 所以 full0/full1 的置位和原来完全一样。
    reg [47:0] y_shift;         // 已收到的前 3 个 16 位分量
    reg [55:0] cb_shift;        // 已收到的前 7 个字节
    reg [55:0] cr_shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_shift  <= 48'd0;
            cb_shift <= 56'd0;
            cr_shift <= 56'd0;
        end else if (i_valid) begin
            // ★ 移位方向: sub 越大越靠**高位** (原来 csub=0 写 bit[7:0]),
            //   所以新数据从高位进, 旧数据往低位挤。
            y_shift  <= {w_y1, w_y0, y_shift[47:16]};
            cb_shift <= {w_cb, cb_shift[55:8]};
            cr_shift <= {w_cr, cr_shift[55:8]};

            if (ysub == 2'd3)
                y_mem[yaddr]  <= {w_y1, w_y0, y_shift[47:0]};
            if (csub == 3'd7) begin
                cb_mem[caddr] <= {w_cb, cb_shift[55:0]};
                cr_mem[caddr] <= {w_cr, cr_shift[55:0]};
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wx         <= 11'd0;
            wrow       <= 3'd0;
            wr_buf     <= 1'b0;
            rd_buf     <= 1'b0;
            full0      <= 1'b0;
            full1      <= 1'b0;
            o_grp_ready<= 1'b0;
        end else begin
            o_grp_ready <= 1'b0;

            // 编码器用完一组 -> 释放对应的 full 标志
            if (i_grp_done) begin
                if (rd_buf == 1'b0) full0 <= 1'b0;
                else                full1 <= 1'b0;
                rd_buf <= ~rd_buf;
            end

            if (i_valid && o_wr_ready) begin
                // 每行 word 数 = i_width/2 (每个 word 2 个像素), 与旧 WX-1 等价
                if (wx == ((i_width >> 1) - 12'd1)) begin
                    wx <= 11'd0;
                    if (wrow == 3'd7) begin
                        wrow        <= 3'd0;
                        o_grp_ready <= 1'b1;
                        if (wr_buf == 1'b0) full0 <= 1'b1;
                        else                full1 <= 1'b1;
                        wr_buf      <= ~wr_buf;
                    end else begin
                        wrow <= wrow + 3'd1;
                    end
                end else begin
                    wx <= wx + 11'd1;
                end
            end
        end
    end

    //=============================================================== 读侧
    //  raddr 用 rd_buf/row/grp 位拼接, 深度按**参数** W 取最大分辨率;
    //  运行时 W 更小时高位的组索引自然为 0, 不会越界。
    wire [YAW-1:0] raddr_y = {rd_buf, i_rd_row, i_rd_grp[GYW-1:0]};
    wire [CAW-1:0] raddr_c = {rd_buf, i_rd_row, i_rd_grp[GCW-1:0]};

    always @(posedge clk) begin
        case (i_rd_sel)
        2'd0, 2'd1: o_rd_data <= y_mem [raddr_y];
        2'd2:       o_rd_data <= cb_mem[raddr_c];
        default:    o_rd_data <= cr_mem[raddr_c];
        endcase
    end

endmodule
