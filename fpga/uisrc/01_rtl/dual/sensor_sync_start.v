//=============================================================================
// sensor_sync_start.v —— 双路传感器的"同步启动"时序
//
//  为什么需要它：
//    双目交替推流要求两颗传感器的 **帧/行是同步的**（见 dual_frame_sched 的说明）。
//    两颗模组的 MCLK 虽然都来自同一个 24MHz PLL，但各自上电/复位时刻不同，
//    内部帧计数器的相位是任意的 —— 差多少都有可能。
//    本模块用"同时释放两颗传感器 RSTn、再同时重跑初始化表"把相位拉到
//    同一个起点（两颗同频同表，之后就不会漂）。
//
//  时序（25MHz 域）：
//    idle --I_start--> PH1(RSTn=0, cfg 复位保持) 20ms
//                      PH2(RSTn=1, cfg 仍保持)   20ms   <- 给传感器内部起振留时间
//                      PH3 释放 cfg -> 两张初始化表从同一拍开始跑
//
//  ⚠ 上电默认（没有 I_start）时 O_rst_n=1、O_cfg_restart=0 ——
//    和原来"RSTn 恒高、cfg 立即启动"完全一致，不影响单目上电即正常。
//
//  ⚠ 触发条件：RK 写 0xDB 且 bit1=1（进双目）。想重来一次就再写一次同样的值。
//=============================================================================
`timescale 1ns/1ns

module sensor_sync_start #(
    parameter HOLD_CYCLES = 500_000,      // 20ms @ 25MHz
    parameter CNTW        = 20
)(
    input  wire I_clk,          // 25MHz
    input  wire I_rst_n,        // S_pll_lock
    input  wire I_start,        // 单拍脉冲: 请求同步启动
    output reg  O_rst_n,        // 同时给两颗传感器的 RSTn (高有效)
    output reg  O_cfg_restart   // 高 = 两个 ui_cfg_imx415 保持在复位
);

    localparam [1:0] PH_IDLE = 2'd0,
                     PH_RST  = 2'd1,
                     PH_WAIT = 2'd2,
                     PH_RUN  = 2'd3;

    reg [1:0]      state;
    reg [CNTW-1:0] cnt;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state         <= PH_IDLE;
            cnt           <= {CNTW{1'b0}};
            O_rst_n       <= 1'b1;
            O_cfg_restart <= 1'b0;
        end else begin
            case (state)
                PH_IDLE: begin
                    O_rst_n       <= 1'b1;
                    O_cfg_restart <= 1'b0;
                    cnt           <= {CNTW{1'b0}};
                    if (I_start) begin
                        state         <= PH_RST;
                        O_rst_n       <= 1'b0;      // 拉低两颗的 RSTn
                        O_cfg_restart <= 1'b1;      // 初始化表先按住
                    end
                end
                PH_RST: begin
                    if (cnt == HOLD_CYCLES-1) begin
                        cnt   <= {CNTW{1'b0}};
                        state <= PH_WAIT;
                        O_rst_n <= 1'b1;            // 同时释放 RSTn
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                PH_WAIT: begin
                    if (cnt == HOLD_CYCLES-1) begin
                        cnt           <= {CNTW{1'b0}};
                        state         <= PH_RUN;
                        O_cfg_restart <= 1'b0;      // 两张表同一拍开始
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                PH_RUN: begin
                    O_rst_n       <= 1'b1;
                    O_cfg_restart <= 1'b0;
                    state         <= PH_IDLE;       // 回去等下一次触发
                end
                default: state <= PH_IDLE;
            endcase
        end
    end

endmodule

//==============================================================================
//  dual_frame_sched (merged into this file)
//
//  Why here: after the project is opened, TD drops dual/dual_frame_sched.v
//  from its internal source list even though fpga_prj.al still has the
//  entry. The synthesis log never shows an "analyze verilog file" line for
//  it, so system_top instantiating it reports HDL-8007 black box.
//  Putting the module in this neighbour file (which TD does analyze) makes
//  it independent of the project file list.
//  dual/dual_frame_sched.v is kept as a comment-only stub so the .al entry
//  still points at an existing file.
//==============================================================================
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

    always @* rd_en = I_dual_en & I_v0;

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

    assign O_v = dual_r ? v0_r : (sel_r ? v1_r : v0_r);
    // 双路模式下 cam1 数据没跟上时输出 **黑**（0）而不是环形缓冲里的旧数据 ——
    // 否则板上会看到一个"冻结的 cam1 画面"，极易误判成"cam1 工作正常"。
    assign O_d = dual_r ? (parity_r ? (line_ok ? rdata : {DATA_WIDTH{1'b0}}) : d0_r)
                        : (sel_r ? d1_r : d0_r);
    assign O_u = dual_r ? u0_r : (sel_r ? u1_r : u0_r);
    assign O_l = dual_r ? (parity_r ? rline_end : l0_r)
                        : (sel_r ? l1_r : l0_r);
    assign O_src    = dual_r ? parity_r : sel_r;
    assign O_parity = parity_r;

    // 读块不就绪说明 cam1 数据没跟上（没接 / 没对齐 / 掉速）
    reg lost_r;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)             lost_r <= 1'b0;
        else if (dual_r && v0_r)  lost_r <= ~line_ok;
    end
    assign O_ch1_lost = dual_r & lost_r;

endmodule


/*===========================================================================
 * Filename     : dual_stitch.v
 * Description  : 双目【同时】采集 + 整行乒乓缓存 + 左右拼接 (Stage 1)
 *
 *  用途
 *  ----
 *  把两路各自 4 px/clk 的 RAW10 流 (40bit) 拼成一路 "3840x1080" 的流：
 *      左半幅 = cam1   (用户指定: 左目 cam1)
 *      右半幅 = cam0   (用户指定: 右目 cam0)
 *  输出仍是 4 px/clock / 40bit，所以下游 ui_isp_top / preproc / rgb_to_yuv422
 *  完全不用改位宽 —— 只把 i_h_active 从 1920 改成 3840 (4K 模式本来就在跑
 *  3840 宽，见 system_top 的 S_is_4k 分支)。
 *
 *  为什么必须"同时"
 *  ----------------
 *  旧通路 dual_frame_sched 是"逐帧交替"(每路 30fps 拼 60fps 流)，两半是
 *  不同时刻的画面。本模块让两路**每一行都同时进缓冲**，左右半幅来自
 *  同一时刻，这是双目测距/对齐的前提。
 *
 *  结构
 *  ----
 *  每个源一个独立的跨时钟 FIFO (fifo_32b_async_2，DATA_WIDTH=40)：
 *      写侧 = 该源自己的恢复时钟 (S_hs_clk0 / S_hs_clk1)
 *      读侧 = 输出时钟 o_clk (S_st_clk，规划 = pclkx1/2 = 73.75MHz)
 *  读侧按 "先吐 HGRP 组左半、再吐 HGRP 组右半" 的顺序组成一行，
 *  每行 HGRP*2 组 = 4*HGRP*2 像素 (HGRP=480 -> 3840 px)。
 *
 *  行对齐 (本模块最关键的不变量)
 *  -----------------------------
 *  读侧**每半幅固定消费 HGRP 个 word**，所以写侧必须保证每行**恰好**
 *  写入 HGRP 个 word，否则左右会永久错位一个 word。为此写侧做三件事：
 *    1) 一行内多于 HGRP 的组直接丢弃 (传感器实际可能给 486 组，
 *       裁剪后只保留前 480 组)；
 *    2) 一行内不足 HGRP (短行 / 掉行) 时**补零到 HGRP**；
 *    3) FIFO 没空间时整行不写真实数据，直接补 HGRP 个零。
 *  三种情况的共同点：FIFO 里的 word 流永远是 "每行 HGRP 个"。
 *
 *  掉一路 (没插模组 / 无 HS 时钟 / RX 没锁)
 *  ---------------------------------------
 *  该源 FIFO 永远没有数据 -> 读侧超时判定 starved -> 该半幅填黑，
 *  **整条流水线照常按另一路的节奏跑**。这就是彻底消灭"切到没时钟的源
 *  整条链死锁"的正确做法 (旧方案靠时钟 mux，切到无信号源会没有时钟)。
 *
 *  时序/带宽核算 (HGRP=480, V_ACTIVE=1080)
 *  --------------------------------------
 *  单源: 480 组 @32.4MHz = 14.8us/行  -> 1080 行 = 16.0ms = 62.5fps 上限
 *  读侧: 2*(480+1) = 962 拍 @73.75MHz = 13.05us/行 -> 有 12% 余量
 *  每像素 10bit -> 输出 3840*1080*60*10bit = 2.49Gbps 进 ISP，
 *  4px/clk 需要 >= 62.2MHz，本模块按 73.75MHz 设计留 18% 余量。
 *
 *  未做的事 (必须放在 system_top / 下游，本文件不碰)
 *  ------------------------------------------------
 *  * 时钟: 需要一个新的 73.75MHz (pclkx1/2)。本模块只要求 o_clk 比
 *          "2 倍单源像素率" 快，不关心它从哪来。
 *  * 下游宽度: ui_isp_top / preproc 的 i_h_active 要切 3840，
 *          dbuf 写侧 beats 用 4K 的那组 (960)，VTC 用 4K 的 h_frame。
 *  * JPEG / CSI-2: 见 docs/PLAN_2026-10-26_DUAL_FRONT_STITCH.md §5.5。
 *===========================================================================*/
`timescale 1ns/1ps

module dual_stitch #(
    parameter integer HGRP     = 480,   // 每半幅的像素组数 (1920px/4)
    parameter integer V_ACTIVE = 1080,  // 每帧行数 (只用于产生 tuser 帧首)
    parameter integer FIFO_AW  = 11,    // 每源 FIFO 深度 = 2^11 = 2048 word (≈4.2 行)
    // 0 = 左 cam1 / 右 cam0 (用户指定)；1 = 反过来
    parameter integer SWAP     = 0,
    // starved 判定: 连续这么多 o_clk 拍拿不到 HGRP 个组就认为该路掉了
    //   73.75MHz 下 2400 拍 ≈ 32.5us ≈ 2.2 行，够容忍一次行抖动
    parameter integer STARVE_MAX = 2400
) (
    // ---------------- 左路 (默认 cam1) ----------------
    input  wire        l_clk,
    input  wire        l_rst_n,
    input  wire        l_valid,
    input  wire [39:0] l_data,
    input  wire        l_user,      // 行(帧)首: ui_image_correction 的 tuser
    input  wire        l_last,      // 行尾:   ui_image_correction 的 tlast
    // ---------------- 右路 (默认 cam0) ----------------
    input  wire        r_clk,
    input  wire        r_rst_n,
    input  wire        r_valid,
    input  wire [39:0] r_data,
    input  wire        r_user,
    input  wire        r_last,
    // ---------------- 拼接输出 (o_clk 域) ----------------
    input  wire        o_clk,
    input  wire        o_rst_n,
    output reg         o_valid,
    output reg  [39:0] o_data,
    output reg         o_user,      // 每个输出帧的第 0 行第 0 组
    output reg         o_last,      // 每行最后一组 (第 2*HGRP-1 组)
    // ---------------- 状态 (只读, 给 I2C 寄存器回读) ----------------
    output wire [15:0] st_l_ovf,    // 左路补零/丢弃次数 (数据完整性告警)
    output wire [15:0] st_r_ovf,
    output wire [15:0] st_l_starve, // 左路从掉线恢复的次数
    output wire [15:0] st_r_starve,
    output wire [15:0] st_lines,    // 已输出行数
    output wire [23:0] st_frames    // 已输出帧数
);

    localparam integer CNTW = 13;   // 行内组计数位宽 (HGRP<=4096)
    localparam [12:0]        HGRP_C = HGRP[12:0];        // 行内组计数用
    localparam [FIFO_AW-1:0] HGRP_F = HGRP[FIFO_AW-1:0]; // FIFO 计数比较用
    localparam [15:0]        VLAST  = V_ACTIVE - 1;
    localparam [15:0]        STVMAX = STARVE_MAX[15:0];

    // 左/右到 FIFO 的物理连接由 SWAP 决定 (综合期常量)
    wire        f0_clk   = (SWAP == 0) ? l_clk   : r_clk;     // FIFO0 = "左半"
    wire        f0_rst_n = (SWAP == 0) ? l_rst_n : r_rst_n;
    wire        f0_valid = (SWAP == 0) ? l_valid : r_valid;
    wire [39:0] f0_data  = (SWAP == 0) ? l_data  : r_data;
    wire        f0_user  = (SWAP == 0) ? l_user  : r_user;
    wire        f0_last  = (SWAP == 0) ? l_last  : r_last;

    wire        f1_clk   = (SWAP == 0) ? r_clk   : l_clk;     // FIFO1 = "右半"
    wire        f1_rst_n = (SWAP == 0) ? r_rst_n : l_rst_n;
    wire        f1_valid = (SWAP == 0) ? r_valid : l_valid;
    wire [39:0] f1_data  = (SWAP == 0) ? r_data  : l_data;
    wire        f1_user  = (SWAP == 0) ? r_user  : l_user;
    wire        f1_last  = (SWAP == 0) ? r_last  : l_last;

    //=========================================================================
    //  单源写侧: 保证"FIFO 里每行恰好 HGRP 个 word"
    //=========================================================================
    //  状态:
    //    W_NORM : 正常收数
    //    W_PAD  : 补零到 HGRP (短行补齐)
    //    W_DROP : 整行丢弃 (FIFO 复位中/满), 只吞到 tlast, 一个 word 也不写
    localparam [1:0] W_NORM = 2'd0, W_PAD = 2'd1, W_DROP = 2'd2;

    //---- FIFO 例化 (两源各一套) ----
    wire [39:0] f0_dout, f1_dout;
    wire        f0_full, f0_empty, f1_full, f1_empty;
    wire [FIFO_AW-1:0] f0_rdc, f0_wdc, f1_rdc, f1_wdc;
    wire        f0_wr_rst_busy, f0_rd_rst_busy;
    wire        f1_wr_rst_busy, f1_rd_rst_busy;

    reg         f0_re, f1_re;
    // ⚠ 写使能必须是**组合**的: FIFO 的 din 直接取 f0_data，若把 we 打一拍
    //   就会让 din 与 we 错开一拍 (写进上一拍的数据)，板上表现为整幅错位。
    wire        f0_we, f1_we;
    // ⚠ W_PAD 状态必须写 0: 否则“补零”会把实时输入当成零写进去 -> 丢数据
    wire [39:0] f0_din, f1_din;

    fifo_32b_async_2 #(
        .DATA_WIDTH (40                ),
        .ADDR_WIDTH (FIFO_AW           )
    ) u_fifo_l (
        .rst          (!f0_rst_n      ),
        .wr_clk       (f0_clk         ),
        .rd_clk       (o_clk          ),
        .din          (f0_din        ),
        .wr_en        (f0_we          ),
        .rd_en        (f0_re          ),
        .dout         (f0_dout        ),
        .full         (f0_full        ),
        .empty        (f0_empty       ),
        .rd_data_count(f0_rdc         ),
        .wr_data_count(f0_wdc         ),
        .wr_rst_busy  (f0_wr_rst_busy ),
        .rd_rst_busy  (f0_rd_rst_busy )
    );

    fifo_32b_async_2 #(
        .DATA_WIDTH (40                ),
        .ADDR_WIDTH (FIFO_AW           )
    ) u_fifo_r (
        .rst          (!f1_rst_n      ),
        .wr_clk       (f1_clk         ),
        .rd_clk       (o_clk          ),
        .din          (f1_din        ),
        .wr_en        (f1_we          ),
        .rd_en        (f1_re          ),
        .dout         (f1_dout        ),
        .full         (f1_full        ),
        .empty        (f1_empty       ),
        .rd_data_count(f1_rdc         ),
        .wr_data_count(f1_wdc         ),
        .wr_rst_busy  (f1_wr_rst_busy ),
        .rd_rst_busy  (f1_rd_rst_busy )
    );

    //=========================================================================
    //  写侧 A: 左半 (FIFO0)
    //=========================================================================
    reg  [1:0]         w0_st;
    reg  [CNTW-1:0]    w0_cnt;
    reg                w0_wait_last;
    reg                w0_saw_last;
    reg  [15:0]        w0_ovf;

    // 一行内可写: 未满 且 计数未到 HGRP
    wire w0_room_word = !f0_full && (w0_cnt < HGRP_C);
    wire w0_we_norm   = (w0_st == W_NORM) && f0_valid && w0_room_word;
    wire w0_we_pad    = (w0_st == W_PAD ) && !f0_full;
    wire w0_saw_nx    = w0_saw_last | (f0_valid && f0_last);
    assign f0_we = w0_we_norm | w0_we_pad;

    always @(posedge f0_clk or negedge f0_rst_n) begin
        if (!f0_rst_n) begin
            w0_st        <= W_NORM;
            w0_cnt       <= 13'd0;
            w0_wait_last <= 1'b0;
            w0_saw_last  <= 1'b0;
            w0_ovf       <= 16'd0;
        end else begin
            case (w0_st)
            //--------------------------------------------------------------
            W_NORM: begin
                if (f0_valid && f0_user) begin
                    // 帧首(行首)。按“本拍是否真的写进 FIFO”计数
                    if (w0_cnt != 13'd0 && w0_cnt < HGRP_C) begin
                        // 上一行被截断: 补满, 再吞掉本行残余
                        w0_ovf       <= w0_ovf + 16'd1;
                        w0_st        <= W_PAD;
                        w0_wait_last <= 1'b1;
                        w0_saw_last  <= 1'b0;
                    end else if (!w0_we_norm) begin
                        // FIFO 复位中/满: 本行整行不写 (不能补零, 否则会多吐黑行)
                        w0_ovf <= w0_ovf + 16'd1;
                        w0_st  <= W_DROP;
                    end else begin
                        w0_cnt <= 13'd1;            // 本拍已写第 0 组
                    end
                end else if (f0_valid && f0_last) begin
                    // 行尾: 先按“是否真的写入”把本拍算进去, 再判断是否短行
                    if (w0_we_norm) begin
                        if ((w0_cnt + 13'd1) >= HGRP_C) begin
                            w0_cnt <= 13'd0;        // 正好 HGRP, 干净的整行
                        end else begin
                            w0_cnt       <= w0_cnt + 13'd1;
                            w0_st        <= W_PAD;  // 剩余补零
                            w0_wait_last <= 1'b0;
                            w0_saw_last  <= 1'b1;   // 本行 tlast 已到
                            w0_ovf       <= w0_ovf + 16'd1;
                        end
                    end else begin
                        if (w0_cnt >= HGRP_C) begin
                            w0_cnt <= 13'd0;
                        end else begin
                            w0_st        <= W_PAD;
                            w0_wait_last <= 1'b0;
                            w0_saw_last  <= 1'b1;
                            w0_ovf       <= w0_ovf + 16'd1;
                        end
                    end
                end else if (w0_we_norm) begin
                    w0_cnt <= w0_cnt + 13'd1;
                end
                // 一行已写满 HGRP 后, 多余的组丢弃直到 tlast
                // (传感器 486 组 / 裁剪只留 480 组就属于这种情况)
            end
            //--------------------------------------------------------------
            W_PAD: begin
                if (f0_valid && f0_user) begin
                    // 补零途中又来帧首 (异常): 重新补整行
                    w0_cnt       <= 13'd0;
                    w0_wait_last <= 1'b0;
                    w0_saw_last  <= 1'b0;
                end else if (!f0_full) begin
                    // ⚠ 只有真正写进去才计数, 否则 FIFO 满时会少数零 -> 错位
                    if ((w0_cnt + 13'd1) >= HGRP_C) begin
                        w0_cnt      <= 13'd0;
                        w0_saw_last <= 1'b0;
                        // 补零期间已经过了 tlast -> 不用再吞, 直接回正常
                        w0_st <= (w0_wait_last && !w0_saw_nx) ? W_DROP : W_NORM;
                    end else begin
                        w0_cnt      <= w0_cnt + 13'd1;
                        w0_saw_last <= w0_saw_nx;
                    end
                end
            end
            //--------------------------------------------------------------
            W_DROP: begin
                // 吞掉本行剩余直到 tlast, 一个 word 也不写
                if (f0_valid && f0_last) begin
                    w0_st  <= W_NORM;
                    w0_cnt <= 13'd0;
                end
            end
            default: w0_st <= W_NORM;
            endcase
        end
    end

    //=========================================================================
    //  写侧 B: 右半 (FIFO1)   —— 与左半完全对称
    //=========================================================================
    reg  [1:0]         w1_st;
    reg  [CNTW-1:0]    w1_cnt;
    reg                w1_wait_last;
    reg                w1_saw_last;
    reg  [15:0]        w1_ovf;

    wire w1_room_word = !f1_full && (w1_cnt < HGRP_C);
    wire w1_we_norm   = (w1_st == W_NORM) && f1_valid && w1_room_word;
    wire w1_we_pad    = (w1_st == W_PAD ) && !f1_full;
    wire w1_saw_nx    = w1_saw_last | (f1_valid && f1_last);
    assign f1_we = w1_we_norm | w1_we_pad;

    always @(posedge f1_clk or negedge f1_rst_n) begin
        if (!f1_rst_n) begin
            w1_st        <= W_NORM;
            w1_cnt       <= 13'd0;
            w1_wait_last <= 1'b0;
            w1_saw_last  <= 1'b0;
            w1_ovf       <= 16'd0;
        end else begin
            case (w1_st)
            W_NORM: begin
                if (f1_valid && f1_user) begin
                    if (w1_cnt != 13'd0 && w1_cnt < HGRP_C) begin
                        w1_ovf       <= w1_ovf + 16'd1;
                        w1_st        <= W_PAD;
                        w1_wait_last <= 1'b1;
                        w1_saw_last  <= 1'b0;
                    end else if (!w1_we_norm) begin
                        // FIFO 复位中/满: 整行不写 (不能补零, 否则会多吐黑行)
                        w1_ovf <= w1_ovf + 16'd1;
                        w1_st  <= W_DROP;
                    end else begin
                        w1_cnt <= 13'd1;
                    end
                end else if (f1_valid && f1_last) begin
                    if (w1_we_norm) begin
                        if ((w1_cnt + 13'd1) >= HGRP_C) begin
                            w1_cnt <= 13'd0;
                        end else begin
                            w1_cnt       <= w1_cnt + 13'd1;
                            w1_st        <= W_PAD;
                            w1_wait_last <= 1'b0;
                            w1_saw_last  <= 1'b1;
                            w1_ovf       <= w1_ovf + 16'd1;
                        end
                    end else begin
                        if (w1_cnt >= HGRP_C) begin
                            w1_cnt <= 13'd0;
                        end else begin
                            w1_st        <= W_PAD;
                            w1_wait_last <= 1'b0;
                            w1_saw_last  <= 1'b1;
                            w1_ovf       <= w1_ovf + 16'd1;
                        end
                    end
                end else if (w1_we_norm) begin
                    w1_cnt <= w1_cnt + 13'd1;
                end
            end
            W_PAD: begin
                if (f1_valid && f1_user) begin
                    w1_cnt       <= 13'd0;
                    w1_wait_last <= 1'b0;
                    w1_saw_last  <= 1'b0;
                end else if (!f1_full) begin
                    if ((w1_cnt + 13'd1) >= HGRP_C) begin
                        w1_cnt      <= 13'd0;
                        w1_saw_last <= 1'b0;
                        w1_st <= (w1_wait_last && !w1_saw_nx) ? W_DROP : W_NORM;
                    end else begin
                        w1_cnt      <= w1_cnt + 13'd1;
                        w1_saw_last <= w1_saw_nx;
                    end
                end
            end
            W_DROP: begin
                if (f1_valid && f1_last) begin
                    w1_st  <= W_NORM;
                    w1_cnt <= 13'd0;
                end
            end
            default: w1_st <= W_NORM;
            endcase
        end
    end

    //=========================================================================
    //  读侧 (o_clk): 每行 = HGRP 组左 + HGRP 组右
    //
    //  FIFO dout 是"读后一拍"有效 (fifo_32b_async_2 内部 dout <= mem[rd_ptr])
    //  所以半幅时序是 (HGRP+1) 拍:
    //      cnt = 0        : 发起第一个读
    //      cnt = 1..HGRP  : o_valid=1, o_data = FIFO 上一拍读出的数据
    //  这样每个半幅**恰好** HGRP 个有效组, 行宽恒定。
    //=========================================================================
    localparam [1:0] R_CHK = 2'd0,   // 等两路都够一行(或判定 starved)
                     R_HALF0 = 2'd1, // 吐左半
                     R_HALF1 = 2'd2; // 吐右半

    reg  [1:0]      r_st;
    reg  [CNTW-1:0] r_cnt;
    reg             r_l_en, r_r_en;    // 当前行左右半是否真读 (0 = 填黑)
    reg  [15:0]     age_l, age_r;
    reg             starve_l, starve_r;
    reg  [15:0]     l_starve_cnt, r_starve_cnt;
    reg  [15:0]     line_cnt;
    reg  [23:0]     frame_cnt;

    wire l_have = (f0_rdc >= HGRP_F);
    wire r_have = (f1_rdc >= HGRP_F);
    // 一路有数据就够开工; 没数据那一路要么已判定 starved, 要么这一行就填黑
    wire can_l  = l_have | starve_l;
    wire can_r  = r_have | starve_r;

    always @(posedge o_clk or negedge o_rst_n) begin
        if (!o_rst_n) begin
            r_st      <= R_CHK;
            r_cnt     <= {CNTW{1'b0}};
            r_l_en    <= 1'b0;
            r_r_en    <= 1'b0;
            age_l     <= 16'd0;
            age_r     <= 16'd0;
            starve_l  <= 1'b1;      // 上电先当"没有", 收到数据自然清掉
            starve_r  <= 1'b1;      // 避免一上电就死等两路数据
            l_starve_cnt <= 16'd0;
            r_starve_cnt <= 16'd0;
            line_cnt  <= 16'd0;
            frame_cnt <= 24'd0;
            f0_re     <= 1'b0;
            f1_re     <= 1'b0;
            o_valid   <= 1'b0;
            o_data    <= 40'd0;
            o_user    <= 1'b0;
            o_last    <= 1'b0;
        end else begin
            f0_re   <= 1'b0;
            f1_re   <= 1'b0;
            o_user  <= 1'b0;
            o_last  <= 1'b0;
            o_valid <= 1'b0;

            // ---- starved 判定 (每路独立超时) ----
            //  starve=1 期间该路填黑但不消耗 FIFO; 一旦收够 HGRP 立刻恢复。
            //  上电直接给 starve=1: 否则"两路都还没有数据"时会一直等,
            //  插一路模组时另一路的黑半幅就工作正常 (实测需求)。
            if (l_have) begin
                age_l <= 16'd0;
                if (starve_l) begin
                    starve_l     <= 1'b0;
                    l_starve_cnt <= l_starve_cnt + 16'd1;
                end
            end else if (!starve_l) begin
                if (age_l >= STVMAX) starve_l <= 1'b1;
                else                 age_l    <= age_l + 16'd1;
            end

            if (r_have) begin
                age_r <= 16'd0;
                if (starve_r) begin
                    starve_r     <= 1'b0;
                    r_starve_cnt <= r_starve_cnt + 16'd1;
                end
            end else if (!starve_r) begin
                if (age_r >= STVMAX) starve_r <= 1'b1;
                else                 age_r    <= age_r + 16'd1;
            end

            case (r_st)
            //--------------------------------------------------------------
            R_CHK: begin
                // 至少要有一路真有数据才开工, 否则两路都掉时输出会空转
                if (can_l && can_r && (l_have || r_have)) begin
                    r_l_en <= l_have;
                    r_r_en <= r_have;
                    r_cnt  <= 13'd0;
                    r_st   <= R_HALF0;
                end
            end
            //--------------------------------------------------------------
            //  半幅时序 (读延迟 2 拍: fX_re 打一拍 + FIFO dout 打一拍)
            //     cnt = 0 .. HGRP-1  : 发起读 (背靠背, 不许有气泡)
            //     cnt = 2 .. HGRP+1  : o_valid=1, o_data = dout (= 第 cnt-2 个 word)
            //  合计 HGRP 个读 / HGRP 个有效组, 行宽恒定。
            //--------------------------------------------------------------
            R_HALF0: begin
                if (r_cnt < HGRP_C) begin
                    if (r_l_en) f0_re <= 1'b1;
                end
                if (r_cnt >= 13'd2) begin
                    o_valid <= 1'b1;
                    o_data  <= r_l_en ? f0_dout : 40'd0;
                    if (r_cnt == 13'd2) o_user <= (line_cnt == 16'd0);
                end
                if (r_cnt < (HGRP_C + 13'd1)) begin
                    r_cnt <= r_cnt + 13'd1;
                end else begin
                    r_cnt <= 13'd0;
                    r_st  <= R_HALF1;
                end
            end
            //--------------------------------------------------------------
            R_HALF1: begin
                if (r_cnt < HGRP_C) begin
                    if (r_r_en) f1_re <= 1'b1;
                end
                if (r_cnt >= 13'd2) begin
                    o_valid <= 1'b1;
                    o_data  <= r_r_en ? f1_dout : 40'd0;
                    if (r_cnt == (HGRP_C + 13'd1)) o_last <= 1'b1;
                end
                if (r_cnt < (HGRP_C + 13'd1)) begin
                    r_cnt <= r_cnt + 13'd1;
                end else begin
                    r_cnt <= 13'd0;
                    r_st  <= R_CHK;
                    // 行计数 / 帧计数
                    if (line_cnt == VLAST) begin
                        line_cnt  <= 16'd0;
                        frame_cnt <= frame_cnt + 24'd1;
                    end else begin
                        line_cnt <= line_cnt + 16'd1;
                    end
                end
            end
            default: r_st <= R_CHK;
            endcase
        end
    end

    //=========================================================================
    //  说明: FIFO 复位只跟本模块的复位走 (已在例化处接 !rst_n)。
    //  ⚠ 不做"溢出即复位"的自动 flush —— fifo_32b_async_2 的 rst 是异步清指针,
    //    在另一时钟域正在读/写的瞬间拉高会丢数据。本设计的"行长恒定"机制
    //    已经保证即使丢字也只是"画面错一行", 不会累积成永久错位,
    //    所以宁可丢一行画面也不要冒异步复位 RAM 的风险。
    //=========================================================================

    // 补零拍必须写 0 (而不是把实时输入当补零写进去)
    assign f0_din = w0_we_pad ? 40'd0 : f0_data;
    assign f1_din = w1_we_pad ? 40'd0 : f1_data;

    assign st_l_ovf    = w0_ovf;
    assign st_r_ovf    = w1_ovf;
    assign st_l_starve = l_starve_cnt;
    assign st_r_starve = r_starve_cnt;
    assign st_lines    = line_cnt;
    assign st_frames   = frame_cnt;

    // 未使用的信号 (防止 lint 报悬空)
    wire _unused = f0_empty | f1_empty | f0_wr_rst_busy | f0_rd_rst_busy |
                   f1_wr_rst_busy | f1_rd_rst_busy | (|f0_wdc) | (|f1_wdc);

endmodule
