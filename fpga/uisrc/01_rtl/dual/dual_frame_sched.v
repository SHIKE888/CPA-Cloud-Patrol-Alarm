//=============================================================================
// dual_frame_sched.v —— 双目交替推流的帧调度器
//
//  需求（2026-10-21 用户确认）：
//    · 单目模式（0xDB[1]=0）：按 0xDB[0] 选一路，全速推流（1080p60 / 4K 一样）
//    · 双目模式（0xDB[1]=1）：两路传感器仍按 60fps 采，FPGA 每路"两帧取一帧"
//      得到各 30fps，再**交替**进同一条流水线 → 输出仍是 1080p60。
//      下游按帧奇偶分出 cam0 / cam1，两路都是完整 1920x1080。
//
//  为什么交替而不是左右拼接：
//    ISP + preproc 是工程的绝对大头（DSP 192/240 = 80%，preproc 独占 116），
//    复制一套放不下；交替意味着任何时刻只有一路在走 ISP，DSP 增量 = 0。
//    而 2 x 30fps 的总像素率正好等于 1 x 60fps，单条流水线吞吐刚好够。
//
//  数据通路：
//    ch0 (I_clk 域) ──寄存一级──────────────────────┐
//                                                    ├─> 帧奇偶二选一 -> 下游
//    ch1 (I_clk1 域) ──4 行环形缓冲(异步)──────────┘
//
//  为什么是「4 行」缓冲 + 固定 2 行滞后：
//    读侧**一直**按 ch0 的行节拍取数（不管当前帧用哪一路），所以进出速率
//    恒定相等，占用只在「两路行相位差」内摆动，滞后 2 行给出 +/-2 行余量。
//    前提是两颗传感器帧/行对齐 —— 由系统侧"同步释放 RSTn + 同时重跑初始化表"
//    保证。不对齐的话缓冲会长期空/满，cam1 那一帧就是黑的。
//
//  双路模式下 ch0 必须存在：它既是下游时钟源，也是行节拍源。
//    只接 cam1 请用单目模式（0xDB[1]=0, 0xDB[0]=1）。
//
//  RAM 读是寄存器输出（ERAM 特性），所以 ch0 的直通路径也打一拍对齐延迟。
//=============================================================================
`timescale 1ns/1ns

module dual_frame_sched #(
    parameter DATA_WIDTH = 40,
    parameter LINE_GRP   = 480      // 每行组数 = 1920px / 4
)(
    input  wire                  I_clk,        // 下游时钟
    input  wire                  I_clk1,       // cam1 恢复时钟 (行缓冲写侧)
    input  wire                  I_rst_n,
    input  wire                  I_dual_en,    // 1 = 双目交替
    input  wire                  I_sel,        // 单目模式的选源 (0=cam0 1=cam1)

    // ch0 (cam0, 与 I_clk 同域)
    input  wire [DATA_WIDTH-1:0] I_d0,
    input  wire                  I_v0,
    input  wire                  I_u0,
    input  wire                  I_l0,

    // ch1 (cam1, 与 I_clk1 同域)
    input  wire [DATA_WIDTH-1:0] I_d1,
    input  wire                  I_v1,
    input  wire                  I_u1,
    input  wire                  I_l1,

    // 输出 (与 I_clk 同域)
    output wire [DATA_WIDTH-1:0] O_d,
    output wire                  O_v,
    output wire                  O_u,
    output wire                  O_l,
    output wire                  O_src,        // 本帧来源: 0=cam0 1=cam1
    output wire                  O_ch1_lost,   // 1 = 读到的 cam1 行数据没准备好
    output wire                  O_parity      // 当前帧奇偶 (调试用)
);

    localparam CNTW = 9;                       // 行内计数 0..479 -> 4 行共 1920 项

    //-------------------------------------------------------------------------
    //  ★ 2026-10-31 (0x4713): 双目改成**完全对称的直通**，环形缓冲不再参与
    //
    //  原设计: cam0 走直通 d0_r，cam1 走 4 行环形缓冲 rdata，
    //          但 valid/tuser **永远取 cam0** 的 (O_v=v0_r, O_u=u0_r)。
    //          即“cam1 的数据”被挂在“cam0 的行节拍”上。
    //
    //  板上现象(用户实测): 单目完全正常；双目左目(cam1)有错位 -->>
    //    竖条位置每次切换都不同、个别次正常、伴随红绿/紫绿偏色(Bayer 相位
    //    移了非偶数个像素)，严重时整块发紫。
    //
    //  原因: 两路的帧/行相位不可能严格相等（每次换源 RX 重新 HS 对齐，
    //        相位随机）。数据来自 2 行前的缓冲，而节拍来自另一路，
    //        行内组数一旦漂移就永久累积，帧首也拿错 -> 错位 + 偏色。
    //
    //  修法: I_clk1 和 I_clk 本来就是同一个 S_hs_rx_clk（system_top 里
    //        两路 RX 的 m_axis_video_aclk 都接 S_hs_rx_clk），cam1 的数据
    //        天然与 cam0 同域，**根本不需要跨域缓冲**。
    //        所以数据、valid、tuser、tlast **四条全部一起选**，
    //        与单目模式走完全相同的直通路径 -> 两边彻底对称。
    //
    //  一键回退: DUAL_DIRECT = 1'b0 就回到原来的环形缓冲方案。
    //-------------------------------------------------------------------------
    localparam DUAL_DIRECT = 1'b1;

    //-------------------------------------------------------------------------
    //  cam1 4 行环形缓冲 —— 写侧在 I_clk1 域
    //-------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:(4*(1<<CNTW))-1];

    reg [1:0]      wblk;
    reg [CNTW-1:0] wcnt;

    wire wline_end = (wcnt == LINE_GRP[CNTW-1:0] - 1'b1);

    always @(posedge I_clk1) begin
        if (I_v1) mem[{wblk, wcnt}] <= I_d1;
    end

    always @(posedge I_clk1 or negedge I_rst_n) begin
        if (!I_rst_n) begin
            wblk <= 2'd0;
            wcnt <= {CNTW{1'b0}};
        end else if (I_v1) begin
            if (wline_end) begin
                wcnt <= {CNTW{1'b0}};
                wblk <= wblk + 2'd1;
            end else begin
                wcnt <= wcnt + 1'b1;
            end
        end
    end

    // 写块号用格雷码同步到读侧（一次只翻一位）
    wire [1:0] wgray = wblk ^ (wblk >> 1);
    reg  [1:0] wgray_s1, wgray_s2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            wgray_s1 <= 2'b00; wgray_s2 <= 2'b00;
        end else begin
            wgray_s1 <= wgray; wgray_s2 <= wgray_s1;
        end
    end

    //-------------------------------------------------------------------------
    //  读侧: 严格按 ch0 的 valid 节拍，每拍取一个组；起始滞后写侧 2 行
    //-------------------------------------------------------------------------
    reg [1:0]      rblk;
    reg [CNTW-1:0] rcnt;
    reg            rd_en;
    reg [DATA_WIDTH-1:0] rdata;
    reg            line_ok;          // 本行 cam1 数据是否就绪（行首锁一次）

    wire rline_end  = (rcnt == LINE_GRP[CNTW-1:0] - 1'b1);
    wire [1:0] rgray = rblk ^ (rblk >> 1);
    wire blk_ready   = (wgray_s2 != rgray);

    always @(posedge I_clk) begin
        if (rd_en) rdata <= mem[{rblk, rcnt}];
    end

    //-------------------------------------------------------------------------
    //  ★ 2026-10-31: 行尾必须跟 rdata 一起打一拍（双目花屏的真因）
    //  rline_end 是**组合**的 (rcnt == LG-1)，而 rdata 是同步读、天然滞后 1 拍，
    //  于是下游看到的是"tlast 在最后一个组之前" -> 每行少一组、下一行多一组
    //  -> 同一帧里行错位。tb_sched 复现：err_mix=484。
    //  cam0/cam1 直通支的 l0_r / l1_r 本来就打过拍，所以只有双目这条坏。
    //  单目路径完全不受影响（仍走 l0_r / l1_r）。
    //-------------------------------------------------------------------------
    reg rlast_q;
    always @(posedge I_clk) begin
        if (rd_en) rlast_q <= rline_end;
    end

    // 行首锁一次就绪状态。
    // ⚠ 不能逐拍判：写端一旦停住，读指针超过写指针之后 "wgray != rgray" 又会
    //   变回真（2 bit 指针分不清"落后"和"跑过头"），于是一直把环形缓冲里的旧
    //   数据当有效数据输出 —— 仿真里就表现为"cam1 没接但画面还在"。
    //   所以：**没就绪就整行出黑，且不推进读指针**，指针永远不越过写指针。
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)                            line_ok <= 1'b0;
        else if (rd_en && rcnt == {CNTW{1'b0}})  line_ok <= blk_ready;
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            rblk <= 2'd2;                      // 滞后写侧 2 行
            rcnt <= {CNTW{1'b0}};
        end else if (rd_en) begin
            if (rline_end) begin
                rcnt <= {CNTW{1'b0}};
                // 只有完整消费掉一行才换块
                if (line_ok) rblk <= rblk + 2'd1;
            end else begin
                rcnt <= rcnt + 1'b1;
            end
        end
    end

    always @* rd_en = I_dual_en & I_v0 & ~DUAL_DIRECT;

    //-------------------------------------------------------------------------
    //  ch0 直通路径也打一拍, 与 RAM 读延迟对齐
    //-------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] d0_r;
    reg                  v0_r, u0_r, l0_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d0_r <= {DATA_WIDTH{1'b0}};
            v0_r <= 1'b0; u0_r <= 1'b0; l0_r <= 1'b0;
        end else begin
            d0_r <= I_d0;
            v0_r <= I_v0; u0_r <= I_u0; l0_r <= I_l0;
        end
    end

    //-------------------------------------------------------------------------
    //  帧奇偶: 由 ch0 的帧首翻转（两路共用同一行节拍, 对两路都有效）
    //-------------------------------------------------------------------------
    reg parity_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)             parity_r <= 1'b0;
        else if (I_u0 && I_v0)    parity_r <= ~parity_r;
    end

    //-------------------------------------------------------------------------
    //  输出二选一（控制信号打一拍, 与数据路径对齐）
    //-------------------------------------------------------------------------
    reg sel_r, dual_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin sel_r <= 1'b0; dual_r <= 1'b0; end
        else          begin sel_r <= I_sel; dual_r <= I_dual_en; end
    end

    // 单目模式下两路都假设与 I_clk 同域（由上层时钟 mux 保证）
    reg [DATA_WIDTH-1:0] d1_r;
    reg                  v1_r, u1_r, l1_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            d1_r <= {DATA_WIDTH{1'b0}};
            v1_r <= 1'b0; u1_r <= 1'b0; l1_r <= 1'b0;
        end else begin
            d1_r <= I_d1;
            v1_r <= I_v1; u1_r <= I_u1; l1_r <= I_l1;
        end
    end

    //  直通模式下：本帧到底看哪一路
    //    双目 = 帧奇偶；单目 = 0xDB[0]。两条路径**完全同构**。
    wire sel_ch1 = dual_r ? parity_r : sel_r;

    assign O_v = DUAL_DIRECT ? (sel_ch1 ? v1_r : v0_r)
                             : (dual_r ? v0_r : (sel_r ? v1_r : v0_r));
    // 双路模式下 cam1 数据没跟上时输出 **黑**（0）而不是环形缓冲里的旧数据 ——
    // 否则板上会看到一个"冻结的 cam1 画面"，极易误判成"cam1 工作正常"。
    assign O_d = DUAL_DIRECT ? (sel_ch1 ? d1_r : d0_r)
                             : (dual_r ? (parity_r ? (line_ok ? rdata : {DATA_WIDTH{1'b0}}) : d0_r)
                                       : (sel_r ? d1_r : d0_r));
    assign O_u = DUAL_DIRECT ? (sel_ch1 ? u1_r : u0_r)
                             : (dual_r ? u0_r : (sel_r ? u1_r : u0_r));
    assign O_l = DUAL_DIRECT ? (sel_ch1 ? l1_r : l0_r)
                             : (dual_r ? (parity_r ? rlast_q : l0_r)
                                       : (sel_r ? l1_r : l0_r));
    assign O_src    = dual_r ? parity_r : sel_r;
    assign O_parity = parity_r;

    // 读块不就绪说明 cam1 数据没跟上（没接 / 没对齐 / 掉速）
    // 直通模式下没有"块就绪"这个概念，恒不报
    reg lost_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)             lost_r <= 1'b0;
        else if (dual_r && v0_r)  lost_r <= ~line_ok;
    end
    assign O_ch1_lost = DUAL_DIRECT ? 1'b0 : (dual_r & lost_r);

endmodule
