`timescale 1ns/1ps
//==============================================================================
//  csi2_test_src.v
//  CSI-2 传输链路自测源 —— 产生逐字节可校验的载荷
//
//  目的:
//    在 JPEG 编码器写出来之前, 先把"FPGA -> MIPI x4 -> RK -> 用户态"这条
//    链路验证掉。这是目前风险最高的环节 (比如 rkcif 会不会丢包/错位/丢字节)。
//
//  为什么不用"塞一张 JPEG"来测:
//    一张图只能说明"大概能解出来", 说明不了**比特精确**。这里发的是
//    线性递增的字节序列 —— 帧内第 k 个字节恒等于 (k & 0xFF)。
//    RK 端抓下来逐字节比对, 一旦有任何丢字节/重复/错位, 立刻暴露。
//    而且不需要 ROM/BRAM 存图, 不依赖 $readmemh 这类工具特性。
//
//  帧结构 (与现有 YUV422 通路完全一致, 所以 RK 侧什么都不用改):
//    DT = 0x1E (YUV422-8bit), 1920x1080, 2 字节/像素
//    -> 每行 1920*2 = 3840 字节 = 960 个 32 bit word
//    -> 每帧 960 * 1080 = 1,036,800 word = 4,147,200 字节
//
//  载荷模式 (MODE):
//    0 = 32 位线性计数 (每帧归零) —— 用于逐字节校验, **默认**
//    1 = 32 位 LFSR 伪随机        —— 用于测数据跳变
//
//  握手: 本模块不产生反压, 只在 tready 有效时推进计数器 (标准 AXIS 源)。
//==============================================================================

module csi2_test_src #(
    parameter integer H_ACTIVE = 1920,
    parameter integer V_ACTIVE = 1080,
    parameter integer BPP_NUM  = 2,
    parameter integer BPP_DEN  = 1,
    parameter integer MODE     = 0,        // 0=线性计数 1=LFSR
    parameter [31:0]  LFSR_SEED= 32'hDEAD_BEEF
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,          // 1 = 开始发帧

    // ---- AXI-Stream master (接 csi2_frame_tx 的 slave 口) ----
    output reg         m_tvalid,
    input  wire        m_tready,
    output reg  [31:0] m_tdata,
    output reg         m_tuser_sof,     // 帧首
    output reg         m_tlast          // 行尾
);

    // ---- 派生常量 ----
    localparam integer LINE_BYTES  = (H_ACTIVE * BPP_NUM) / BPP_DEN;  // 3840
    localparam integer LINE_WORDS  = LINE_BYTES / 4;                  // 960
    localparam integer FRAME_WORDS = LINE_WORDS * V_ACTIVE;           // 1036800

    localparam CCOL = $clog2(LINE_WORDS)  + 1;    // 列计数器位宽
    localparam CLIN = $clog2(V_ACTIVE)    + 1;    // 行计数器位宽

    reg [CCOL-1:0]  col;          // 行内第几个 word
    reg [CLIN-1:0]  line;         // 第几行
    reg [CCOL+2:0]  wcnt;         // 帧内 word 序号 (给 LFSR 模式做种子混合)
    reg [31:0]      lfsr;

    wire fire = m_tvalid & m_tready;   // 本拍数据被接收

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col    <= 0;
            line   <= 0;
            wcnt   <= 0;
            lfsr   <= LFSR_SEED;
        end else if (!enable) begin
            // 不使能时复位到帧首, 保证重新使能后从头开始
            col    <= 0;
            line   <= 0;
            wcnt   <= 0;
            lfsr   <= LFSR_SEED;
        end else if (fire) begin
            // LFSR: x^32 + x^22 + x^2 + x^1 + 1 (最大长度)
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            wcnt <= wcnt + 1'b1;

            if (col == LINE_WORDS[CCOL-1:0] - 1'b1) begin
                col <= 0;
                if (line == V_ACTIVE[CLIN-1:0] - 1'b1) begin
                    line <= 0;             // 一帧结束, 回到帧首 -> 下一帧完全可复现
                    wcnt <= 0;
                end else begin
                    line <= line + 1'b1;
                end
            end else begin
                col <= col + 1'b1;
            end
        end
    end

    // ---- 载荷 ----
    // 目标: 帧内第 k 个字节恒等于 (k & 0xFF)。
    //
    // CSI-2 传 32 位 word 时是**低字节先发**, 所以 word 的低 8 位应等于
    // (k & 0xFF), 次 8 位等于 (k+1) & 0xFF, 依此类推。
    //
    // 帧内字节序号 k = line*LINE_BYTES + col*4, 我们只要它的低 8 位。
    // 用 (a*b) mod 256 == ((a mod 256) * (b mod 256)) mod 256 化简,
    // 只需要一个 8 位乘法, 不用引出宽的乘法器。
    wire [CCOL+2:0]  byte_off = {col, 2'b00};       // = col * 4
    wire [7:0]       lb_mod   = LINE_BYTES % 256;
    wire [CLIN+7:0]  line_lo  = line * lb_mod;      // 低 8 位才是要的
    wire [7:0]       bc       = line_lo[7:0] + byte_off[7:0];

    // ---- MODE == 2: 4K 几何/撕裂诊断图案 ----
    //  设计要点:
    //   (1) 灰度输出: 4 个字节同值 {g,g,g,g}, 所以【完全不受 YUYV 字节序影响】
    //       (Y/U/V 谁在哪个字节都得到同一个灰阶) —— 排障阶段不引入额外变量
    //   (2) 64 word (=128px) x 64 行 的棋盘: 水平重复/镜像/错位一眼可见
    //   (3) 每 64 word 一条竖亮线, 每 64 行一条横亮线: 用来定位行列错位
    //   (4) 棋盘亮度上叠加 line[5:0] 的斜坡: 垂直方向绕回/上下错位
    //       会在画面上看到亮度突然跳变
    wire        is_grid = (col[5:0] == 6'd0) || (line[5:0] == 6'd0);
    wire [7:0]  g_chk   = (col[5] ^ line[5]) ? 8'd152 : 8'd48;
    wire [7:0]  g_pat   = is_grid ? 8'd255 : (g_chk + {2'b00, line[5:0]});

    always @(*) begin
        m_tvalid    = enable;
        m_tuser_sof = enable && (line == 0) && (col == 0);
        m_tlast     = enable && (col == LINE_WORDS[CCOL-1:0] - 1'b1);
        m_tdata     = (MODE == 2) ? {g_pat, g_pat, g_pat, g_pat}
                    : (MODE == 1) ? lfsr
                                  : {bc + 8'd3, bc + 8'd2, bc + 8'd1, bc};
    end

endmodule
