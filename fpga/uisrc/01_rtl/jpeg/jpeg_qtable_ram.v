`timescale 1ns/1ps
//==============================================================================
//  jpeg_qtable_ram.v
//
//  为什么单独做一块 RAM:
//    量化表要能被 ·寄存器回读· 和 ·码率控制/倒数计算· 同时访问, 而参数寄存器堆
//    只需要一个简单的写口。所以把表单独放, 共享同一条写总线, 给两个读口。
//
//  写地址 (与 jpeg_regfile.v 的映射一致):
//    0x10 ~ 0x4F  -> 下标 0  ~ 63   (亮度表)
//    0x50 ~ 0x8F  -> 下标 64 ~ 127  (色度表)
//  地址范围是 0x10..0x8F, 在 7 位宽下 (addr[6:0] - 7'h10) 正好回绕得到 0..127。
//
//  复位值 = ITU-T T.81 Annex K.1 的标准表 (来自 jpeg_defs.vh),
//  所以 FPGA 一上电就有一张合法的表, 不依赖 RK 先下发。
//
//  码率控制怎么用:
//    每帧开头把 128 项全部读一遍 (128 个时钟, 相对整帧 61 万个时钟可以忽略),
//    算出 inv_q[128] = round(65536 * SCALE / (q * 16)) 存进另一块寄存器组,
//    量化时直接查。所以这里只要保证"能被顺序读完"即可。
//==============================================================================

module jpeg_qtable_ram (
    input  wire         I_clk,
    input  wire         I_rst_n,

    // ---------------- 写口 (与 jpeg_regfile 共用同一条写总线) ----------------
    input  wire         I_wr_en,
    input  wire [7:0]   I_wr_addr,
    input  wire [7:0]   I_wr_data,

    // ---------------- 读口 A: 寄存器回读 ----------------
    input  wire [6:0]   I_rd_idx_a,
    output reg  [7:0]   O_rd_data_a,

    // ---------------- 读口 B: 码率控制顺序读 ----------------
    input  wire [6:0]   I_rd_idx_b,
    output reg  [7:0]   O_rd_data_b
);

// ⚠ include 必须放在 module 内部 —— jpeg_defs.vh 里是 localparam 和 function,
//   每个用到的模块都要展开一份自己的副本 (该文件故意不加 include guard)。
`include "jpeg_defs.vh"

    reg [7:0] ram [0:127];

    // 写地址解码: 0x10..0x8F -> 0..127
    wire        S_wr_hit  = (I_wr_addr >= 8'h10) && (I_wr_addr <= 8'h8F);
    wire [6:0]  S_wr_idx  = I_wr_addr[6:0] - 7'h10;

    integer i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            // 上电即装标准表: 0..63 亮度, 64..127 色度
            for (i = 0; i < 64; i = i + 1) begin
                ram[i]     <= jpeg_q_lum(i[5:0]);
                ram[64 + i]<= jpeg_q_chr(i[5:0]);
            end
        end else if (I_wr_en && S_wr_hit) begin
            ram[S_wr_idx] <= I_wr_data;
        end
    end

    // 读口 A (1 拍延迟)
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) O_rd_data_a <= 8'h00;
        else          O_rd_data_a <= ram[I_rd_idx_a];
    end

    // 读口 B (1 拍延迟)
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) O_rd_data_b <= 8'h00;
        else          O_rd_data_b <= ram[I_rd_idx_b];
    end

endmodule
