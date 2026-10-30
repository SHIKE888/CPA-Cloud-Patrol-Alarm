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
    // ---------------- 读口 A 的同拍异步版本 (与 I_rd_idx_a 共用地址) ----------------
    //  ★ 给 jpeg_headers 用。header 的 DQT 字节必须和 cnt 同拍对齐:
    //    一旦下游反压把 i_ready 拉低、cnt 冻结, 寄存器读口的数据就会比 cnt
    //    超前 1 个字节 —— 实测每停一次就丢一个 Q 值 (0x28 变成下一个 0x1a)。
    //    小 RAM 异步读代价极低, 换成同拍读后反压完全不影响 header。
    output wire [7:0]   O_rd_data_a_asyn,
    // ---------------- 读口 B: 码率控制顺序读 ----------------
    input  wire [6:0]   I_rd_idx_b,
    output reg  [7:0]   O_rd_data_b
);

// ⚠ include 必须放在 module 内部, 且前面要 undef 掉保护宏 ——
//   jpeg_defs.vh 有 `ifndef JPEG_DEFS_VH 保护, 多文件编译时第二个模块
//   会因宏已定义而整个文件被跳过, 表现为 "No function named jpeg_q_lum"。
`undef JPEG_DEFS_VH
`include "jpeg_defs.vh"

    reg [7:0] ram [0:127];

    //==========================================================================
    //  ★★ V54j (2026-10-31): 量化表放大系数 —— 把码率压回 MIPI 带宽以内 ★★
    //
    //  板上 0x5406 实测 (CFG_VER=0x5406):
    //      每帧字节数 2.2M~16.8M (平均约 10 MB), st_frames 增量 49.5 fps
    //      => 10MB x 49.5 = 495 MB/s
    //      而 MIPI 4lane@1Gbps (8b/10b 后) 上限 = 400 MB/s => 超 24%
    //      => D-PHY HS FIFO 溢出 => CRC/ECC 错 => 整帧报废 => 画面花/绿
    //
    //  正常 Q50 标准表压缩比应该 ~15:1 (每帧 ~500KB), 实测只有 1.56:1,
    //  说明「量化步长相对 DCT 系数太小」。这里把量化步长整体放大 Q_SCALE 倍:
    //  系数被除得更多 -> 高频大量归零 -> 熵编码输出大幅下降。
    //  Q_SCALE=4 (等效质量降到 Q12 左右) 后预计每帧 0.2~4 MB, 数据率
    //  10~200 MB/s, 稳稳落在 400MB/s 以内。
    //
    //  ⚠ 运行期无法调: 0x01 QUALITY 在 system_top 里是悬空的,
    //     且本 RAM 的 I_wr_en 硬接 1'b0, 所以只能编译期定。
    //     要改码率就改这个 Q_SCALE 参数 (1 = 标准表原始行为)。
    //==========================================================================
    parameter integer Q_SCALE = 4;

    // 饱和到 255: 标准表最大 121, x4 = 484 会溢出 8 位
    function [7:0] q_mul;
        input [7:0] q;
        reg   [15:0] t;
        begin
            t     = q * Q_SCALE;
            q_mul = (t > 16'd255) ? 8'd255 : t[7:0];
        end
    endfunction

    // 写地址解码: 0x10..0x8F -> 0..127
    wire        S_wr_hit  = (I_wr_addr >= 8'h10) && (I_wr_addr <= 8'h8F);
    wire [6:0]  S_wr_idx  = I_wr_addr[6:0] - 7'h10;

    integer i;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            // 上电即装标准表: 0..63 亮度, 64..127 色度 (按 Q_SCALE 放大)
            for (i = 0; i < 64; i = i + 1) begin
                ram[i]     <= q_mul(jpeg_q_lum(i[5:0]));
                ram[64 + i]<= q_mul(jpeg_q_chr(i[5:0]));
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

    assign O_rd_data_a_asyn = ram[I_rd_idx_a];

    // 读口 B (1 拍延迟)
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) O_rd_data_b <= 8'h00;
        else          O_rd_data_b <= ram[I_rd_idx_b];
    end

endmodule
