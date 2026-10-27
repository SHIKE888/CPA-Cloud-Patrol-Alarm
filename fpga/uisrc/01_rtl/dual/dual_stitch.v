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
