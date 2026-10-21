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

    // ---------------- 输入: YUV422 {Cr,Y1,Cb,Y0}, 2 像素/拍 ----------------
    input  wire        i_valid,
    input  wire [31:0] i_data,
    output wire        o_wr_ready,

    // ---------------- MCU 读 ----------------
    input  wire [2:0]  i_rd_row,        // 0..7
    input  wire [7:0]  i_rd_grp,        // 组索引
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

    //=============================================================== 存储
    (* ram_style = "block" *) reg [63:0] y_mem  [0:YDEP-1];
    (* ram_style = "block" *) reg [63:0] cb_mem [0:CDEP-1];
    (* ram_style = "block" *) reg [63:0] cr_mem [0:CDEP-1];

    // 仿真初始化: 未写入的位置保持 0 而不是 X, 便于定位"哪一行没写到"
    integer zi;
    initial begin
        for (zi = 0; zi < YDEP; zi = zi + 1) y_mem[zi] = 64'd0;
        for (zi = 0; zi < CDEP; zi = zi + 1) begin
            cb_mem[zi] = 64'd0;
            cr_mem[zi] = 64'd0;
        end
    end

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

    wire [11:0] yaddr = {wr_buf, wrow, ygrp};
    wire [11:0] caddr = {wr_buf, wrow, cgrp};

    always @(posedge clk) begin
        if (i_valid) begin
            case (ysub)
            2'd0: y_mem[yaddr][15: 0] <= {w_y1, w_y0};
            2'd1: y_mem[yaddr][31:16] <= {w_y1, w_y0};
            2'd2: y_mem[yaddr][47:32] <= {w_y1, w_y0};
            2'd3: y_mem[yaddr][63:48] <= {w_y1, w_y0};
            endcase

            case (csub)
            3'd0: cb_mem[caddr][ 7: 0] <= w_cb;
            3'd1: cb_mem[caddr][15: 8] <= w_cb;
            3'd2: cb_mem[caddr][23:16] <= w_cb;
            3'd3: cb_mem[caddr][31:24] <= w_cb;
            3'd4: cb_mem[caddr][39:32] <= w_cb;
            3'd5: cb_mem[caddr][47:40] <= w_cb;
            3'd6: cb_mem[caddr][55:48] <= w_cb;
            default: cb_mem[caddr][63:56] <= w_cb;
            endcase

            case (csub)
            3'd0: cr_mem[caddr][ 7: 0] <= w_cr;
            3'd1: cr_mem[caddr][15: 8] <= w_cr;
            3'd2: cr_mem[caddr][23:16] <= w_cr;
            3'd3: cr_mem[caddr][31:24] <= w_cr;
            3'd4: cr_mem[caddr][39:32] <= w_cr;
            3'd5: cr_mem[caddr][47:40] <= w_cr;
            3'd6: cr_mem[caddr][55:48] <= w_cr;
            default: cr_mem[caddr][63:56] <= w_cr;
            endcase
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
                if (wx == WX - 1) begin
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
    wire [11:0] raddr_y = {rd_buf, i_rd_row, i_rd_grp[GYW-1:0]};
    wire [11:0] raddr_c = {rd_buf, i_rd_row, i_rd_grp[GCW-1:0]};

    always @(posedge clk) begin
        case (i_rd_sel)
        2'd0, 2'd1: o_rd_data <= y_mem [raddr_y];
        2'd2:       o_rd_data <= cb_mem[raddr_c];
        default:    o_rd_data <= cr_mem[raddr_c];
        endcase
    end

endmodule
