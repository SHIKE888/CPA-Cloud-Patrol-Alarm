/*===========================================================================
 * Filename     : jpeg_encoder_top.v
 * Description  : JPEG 编码器顶层 (baseline 4:2:2, SOF0 有损)
 *
 *  数据流:
 *      YUV422 word -> jpeg_linebuf (8 行乒乓)
 *                  -> jpeg_dct2d   (每个 MCU: Y0,Y1,Cb,Cr 四块)
 *                  -> jpeg_quant_zz (量化 + zigzag, 直接跟随 DCT 的 8 拍输出)
 *                  -> jpeg_huff_enc (熵编码, 1 符号/拍)
 *                  -> jpeg_bitpack  (位打包 + 0xFF 填充)
 *      jpeg_headers -> 帧首 607 字节标记段
 *      FF D9        -> 帧尾
 *
 *  帧结构:  [headers 607B] [熵编码字节] [FF D9]
 *
 *  ★ 量化器【不能】由状态机驱动:
 *      jpeg_dct2d 的 o_valid 在 S_P2 阶段连续 8 拍就吐完了, 而 o_done 是
 *      第 8 拍同拍。若状态机先等 o_done 再开量化, 这 8 拍数据已经错过。
 *      所以 q_valid / q_t 直接由 dct_ovalid 驱动, 与状态机解耦。
 *
 *  吞吐 (2026-10-26 实测, 见 fpga/sim/tb_jpeg_thru.v + run_jpeg_thru.ps1):
 *      有损 (DCT/SOF0)  : 150.0 clk/MCU
 *          @300MHz -> 255.9 Mpx/s = 1080p123 / 4K30.9
 *          248.8 Mpx/s (双路1080p60 = 4K30) 只需 292MHz => 300MHz 够
 *      无损 (DPCM/SOF3) : 320.2 clk/MCU
 *          @300MHz -> 119.9 Mpx/s = 1080p58 / 4K14.5  => 差 2.5 倍, 待优化
 *
 *  ★ 旧注释写的 "每块 8+30+40=78 拍, 每 MCU 312 拍, 29fps @147.5MHz,
 *    要 60fps 需做块级流水" **已经过期**: 块级流水 (pend / qzz 双缓冲 /
 *    熵编码后台调度) 代码里已经实现, 实测就是 150 clk/MCU。不要再按
 *    312 拍去规划, 也不需要再做流水化。
 *
 *  ★ 尺寸: MCU_X / MCU_Y / NWORD 全部改成**运行时** (i_width / i_height),
 *    一个 bit 即可在 1080p / 4K / 双目拼接之间切换。W / H 参数只用于
 *    确定行缓冲深度, 必须取所有模式中的**最大值** (当前 3840x2160)。
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_encoder_top #(
    parameter integer W = 1920,
    parameter integer H = 1080,
    // ★ 2026-10-28 双引擎拼一张 3840 宽 JPEG 用的参数:
    //   左引擎 HDR_EN=1/EOI_EN=0/RST_INIT=0/RST_STEP=2
    //   右引擎 HDR_EN=0/EOI_EN=1/RST_INIT=1/RST_STEP=2
    //   两引擎交替输出半行段, RST 序号奇偶交错 -> 全局就是 RST0,1,2,...,7,0,...
    parameter integer HDR_EN   = 1,   // 1 = 本引擎输出帧头 (宽高由 i_width/i_height 给)
    parameter integer EOI_EN   = 1,   // 1 = 本引擎输出结尾 FF D9
    parameter integer RST_INIT = 0,   // 第一个 RST 的编号 (0..7)
    parameter integer RST_STEP = 1,   // 每段结束后 RST 编号的步长 (1=单引擎, 2=双引擎)
    // ★ 1 = 最后一段后面也插 RST。双引擎时左引擎必须为 1:
    //   拼完后左引擎的最后一段后面还跟着右引擎的最后一段, 那个边界是需要标记的。
    parameter integer LAST_RST_EN = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i_en,
    input  wire        i_soft_rst,
    input  wire        i_lossless,      // 1 = 无损 (SOF3 + DPCM), 0 = 有损 (SOF0 + DCT)

    input  wire [11:0] i_width,
    input  wire [11:0] i_height,

    // ★ 2026-10-28: DRI 重启间隔 (MCU 数)。0 = 不插 RST (完全旧行为)。
    //   为了把两个引擎各编出的"半行"拼成一张 3840 宽的 JPEG:
    //   每编完 i_rst_int(=120) 个 MCU 就 bit 对齐 + 发 RST0..7 + 清 DC 预测器。
    input  wire [15:0] i_rst_int,

    // ---------------- 量化表读口 ----------------
    output wire [6:0]  o_qt_idx_a,      // headers 用 (读口 A)
    input  wire [7:0]  i_qt_data_a,
    output wire [6:0]  o_qt_idx_b,      // quant 装载 recip 用 (读口 B)
    input  wire [7:0]  i_qt_data_b,

    // ---------------- 输入 YUV422 ----------------
    input  wire        s_valid,
    input  wire [31:0] s_data,
    output wire        s_ready,

    // ---------------- 输出 JPEG 字节流 ----------------
    output reg         m_valid,
    output reg  [7:0]  m_data,
    output reg         m_last,
    // 下游能否接住本拍字节。接 CSI-2 可变长发送时必须用上 ——
    // 它在攒满一个包去发包的 200+ 拍里 ready=0, 不反压就会丢掉那一整段熵字节。
    input  wire        m_ready,

    // ---------------- 状态 ----------------
    output reg  [23:0] st_frame_bytes,
    output reg         st_busy,
    output reg         st_done,
    output reg  [31:0] st_frame_cnt,

    // ★ 段结束指示 (给双引擎合并模块用): 一个半行段已经完整吐出去,
    //   合并器看到这个脉冲就可以切到另一个引擎。帧末没 RST 的那段用 st_done 顶。
    output wire        o_seg_done,

    // ★ 2026-10-28 诊断 (临时调试版): 编码器内部状态抽头, 接到 0xEA~0xED。
    //   目的: 定位"永久 busy + 帧字节恒 0"到底卡在哪一步。
    //     [3:0]  tstate        控制状态机 (T_IDLE/T_LOADQ/T_HDR/T_WGRP/T_RD/
    //                          T_WDCT/T_HUFF/T_NEXT/T_FIN/T_EOI/T_DRAIN)
    //     [5:4]  pend          已 DCT 完、未编码完的块数 (0..2)
    //     [6]    lb_avail      行缓冲里有完整 8 行
    //     [7]    q_load_done   量化表 recip 装载完成
    //     [8]    huff_run      熵编码忙
    //     [9]    huff_start    启动一个块的脉冲
    //     [10]   bp_ok         位打包器有余量
    //     [11]   m_ready       下游能否接住字节
    //     [12]   st_busy       [13] st_done
    //     [14]   huff_done     一个块编码完成
    //     [15]   bp_flush      帧尾 flush
    output wire [15:0] o_diag
);

    // ★ 2026-10-26 (紧急回退): MCU 尺寸改回**编译期**。
    //   曾经改成运行时 (MCU_X_RT/MCU_Y_RT), 但为了支持 4K 把 W/H 参数提到
    //   3840x2160 后, jpeg_linebuf 的 y_mem 变成 8192 x 64bit —— TD **无法**把它
    //   映射到 ERAM20k, 直接回退成 8192 个 LUT-RAM:
    //     综合报告: #used ram 17704 / #dram lut 17456, u_linebuf 单个模块 LUT=4539
    //     slice 43993(68.4%) -> 57186(88.9%), 布线 57 分钟还停在 50%
    //   => 先回到已验证的 1920x1080 (y_mem 4096 x 64bit), 恢复资源。
    //   4K / 拼接要上 JPEG 时, 必须重新设计行缓冲 (比如 8 行单缓冲 + 更高频),
    //   不能再简单地把 W 参数放大。
    localparam integer MCU_X = W / 16;
    localparam integer MCU_Y = H / 8;
    localparam integer NWORD = (W / 2) * H;   // 无损模式的总 word 数

    wire use_ll = i_lossless;

    // 块号 / MCU 列 (块属性逻辑与控制状态机共用, 必须提前声明)
    reg [1:0] blk;
    reg [7:0] mx_reg;

    // ---------------- block 级流水寄存器 (必须在使用点之前声明) ----------------
    reg        wr_buf;       // DCT 正在写的组
    reg        rd_buf;       // 熵编码正在读的组
    reg [1:0]  pend;         // 已 DCT 完成、尚未编码完的块数 (最大 2)
    reg [1:0]  huff_blk;     // 熵编码正在处理的块号 (决定 comp/chroma)
    reg        huff_run;     // 熵编码器忙
    reg        frame_first;  // 帧内第一个块还没开始编码
    reg [2:0]  pend_nx;
    reg [3:0]  tstate;       // 控制状态机 (也要在使用点之前)

    // ---------------- DRI 重启间隔 (2026-10-28) ----------------
    reg  [15:0] rst_cnt;       // 距上次重启已编完的 MCU 数
    reg  [2:0]  rst_idx;       // 下一个 RST 编号
    reg         rst_busy;      // 标记还没吐完 -> 禁止启动下一块
    reg         rst_pred_pend; // 下一块编码时要清 DC 预测器
    reg         rst_req;       // 给 bitpack 的插入脉冲
    reg  [15:0] enc_mcu;       // 本帧已编完的 MCU 总数
    wire        bp_rst_done;
    localparam integer TOTAL_MCU = MCU_X * MCU_Y;

    //=============================================================== linebuf
    wire        lb_ready;
    wire        lb_avail;
    wire [63:0] lb_rd_data;
    wire        lb_grp_ready;

    reg  [2:0]  rd_row;
    // ★ 2026-10-26: 组索引原来只有 8 位且只用 mx_reg[6:0] —— W=3840 时
    //   每行 240 个 MCU, 组索引要到 479 (需 9 位), 会被截断 -> 4K 画面��影。
    //   现在接全 mx_reg, 位宽 9 位 (最大 3840/8*2-1 = 959 够用)。
    reg  [8:0]  rd_grp;
    reg  [1:0]  rd_sel;
    reg         grp_done;

    jpeg_linebuf #(.W(W)) u_linebuf (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_valid     (s_valid & ~use_ll),
        .i_data      (s_data),
        .o_wr_ready  (lb_ready),
        .i_rd_row    (rd_row),
        .i_rd_grp    (rd_grp),
        .i_rd_sel    (rd_sel),
        .o_rd_data   (lb_rd_data),
        .o_rd_avail  (lb_avail),
        .o_grp_ready (lb_grp_ready),
        .i_grp_done  (grp_done)
    );

    //=============================================================== 无损 DPCM 编码器

    // ★ bp_ready = 位打包器内部还有余量(它自己的 i_ready 输出)。
    //   这里【不能】再 & m_ready: 位打包器现在 put 无条件落地, 下游冻结只影响
    //   o_valid/o_data 的吐出, acc 照收。把 m_ready 挂进来只会让熵编码提前停,
    //   白白拉低吞吐, 对正确性没有帮助。
    wire        bp_ok;
    wire        bp_ready = bp_ok;
    reg         ll_start;
    wire        ll_valid;
    wire [31:0] ll_code;
    wire [5:0]  ll_len;
    wire        ll_done;
    wire        ll_ready;

    // ★ u_ll 的 i_valid 必须用 "本拍真的可以收" 来门控, 不能只用 s_valid。
    //   上游 (tb / system_top) 在 ready 为低时会一直保持 valid=1, 这是合法的
    //   AXI 风格握手。而 s_ready 里带了 "header 发完" 这一项, u_ll 自己不知道。
    //   如果只给 s_valid, header 阶段 u_ll 会按 ll_ready=1 把第一个 word 偷偷收下,
    //   上游却还在等 s_ready, 于是同一份数据被重发/错位, ll_wcnt 只涨了 37。
    //   用 ll_run (而不是 tstate) 是因为它在此处就能声明, 不踩声明顺序的坑。
    reg         ll_run;             // 1 = 无损模式 header 已发完, 可以收 YUV
    wire ll_accept = use_ll & ll_run;

    jpeg_lossless_enc #(.W(W)) u_ll (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_start     (ll_start),
        .i_valid     (s_valid & ll_accept),
        .i_data      (s_data),
        .i_ready     (ll_ready),
        .o_valid     (ll_valid),
        .o_code      (ll_code),
        .o_len       (ll_len),
        .i_out_ready (bp_ready),
        .o_done      (ll_done),
        .o_sample_cnt()
    );

    //=============================================================== 输入就绪
    // 本模块输出无背压 (m_valid 一直保持到下游取走), 位打包的反压由它自己算。

    //=============================================================== DCT
    reg          dct_start;
    reg          dct_valid;
    wire [127:0] dct_row;
    wire         dct_ovalid;
    wire [143:0] dct_col;
    wire         dct_odone;

    genvar gp;
    generate
    for (gp = 0; gp < 8; gp = gp + 1) begin : g_px
        wire [7:0]  p  = lb_rd_data[gp*8 +: 8];
        wire [15:0] sv = {8'd0, p} - 16'd128;   // 0..255 -> -128..127
        assign dct_row[gp*16 +: 16] = sv;
    end
    endgenerate

    jpeg_dct2d #(.NENG(8)) u_dct (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_start (dct_start),
        .i_valid (dct_valid),
        .i_row   (dct_row),
        .i_ready (),
        .o_busy  (),
        .o_valid (dct_ovalid),
        .o_col   (dct_col),
        .o_done  (dct_odone)
    );

    //=============================================================== 量化 (直接跟随 DCT)
    reg         q_load;
    wire        q_load_done;
    reg  [2:0]  q_t;
    reg         q_chroma;
    wire        q_blk_done;
    wire [15:0] q_rd_data;
    wire [15:0] q_rd_data_n;
    wire [63:0] q_nz_mask;
    wire [5:0]  huff_rd_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          q_t <= 3'd0;
        else if (dct_ovalid) q_t <= (q_t == 3'd7) ? 3'd0 : (q_t + 3'd1);
        else                 q_t <= 3'd0;
    end

    jpeg_quant_zz u_quant (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_load      (q_load),
        .o_qt_idx    (o_qt_idx_b),
        .i_qt_data   (i_qt_data_b),
        .o_load_done (q_load_done),
        .i_valid     (dct_ovalid),
        .i_col       (dct_col),
        .i_t         (q_t),
        .i_chroma    (q_chroma),
        .o_wr        (),
        .o_blk_done  (q_blk_done),
        .i_rd_idx    (huff_rd_idx),
        .i_wr_buf    (wr_buf),
        .i_rd_buf    (rd_buf),
        .o_rd_data   (q_rd_data),
        .o_rd_data_n (q_rd_data_n),
        .o_nz_mask   (q_nz_mask)
    );

    //=============================================================== 熵编码
    reg         huff_start;
    reg  [1:0]  huff_comp;
    reg         huff_chroma;
    wire        huff_valid;
    wire [31:0] huff_code;
    wire [5:0]  huff_len;
    wire [31:0] huff_code2;
    wire [5:0]  huff_len2;
    wire        huff_two;
    wire        huff_done;
    // 每编完 1 个 MCU (4 块) 且不是本帧最后一个 MCU 且需要重启 -> 插 RST
    wire        mcu_end = huff_done && (huff_blk == 2'd3);
    wire        huff_rst_pred = huff_start && (frame_first || rst_pred_pend);
    // 段结束: RST 标记完全吐出, 或者整帧收尾
    assign      o_seg_done = bp_rst_done | st_done;
    // 本帧最后一个 MCU (enc_mcu 是“已完成”数, 所以在 mcu_end 那一拍 +1 前先比较)
    wire        last_mcu   = (enc_mcu == (TOTAL_MCU - 1));

    jpeg_huff_enc u_huff (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_blk_start  (huff_start),
        .i_comp       (huff_comp),
        .i_chroma_tbl (huff_chroma),
        .o_rd_idx     (huff_rd_idx),
        .i_rd_data    (q_rd_data),
        .i_rd_data_n  (q_rd_data_n),
        .i_nz_mask    (q_nz_mask),
        .o_valid      (huff_valid),
        .o_code       (huff_code),
        .o_len        (huff_len),
        .o_code2      (huff_code2),
        .o_len2       (huff_len2),
        .o_two        (huff_two),
        .i_ready      (bp_ready),
        .o_blk_done   (huff_done),
        .i_rst_pred   (huff_rst_pred)
    );

    //=============================================================== 位打包
    reg         bp_flush;
    wire        bp_valid;
    wire [7:0]  bp_data;
    wire [31:0] bp_cnt;

    jpeg_bitpack u_bitpack (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_flush    (bp_flush),
        .i_rst_req  (rst_req),
        .i_rst_idx  (rst_idx),
        .o_rst_done (bp_rst_done),
        .i_valid    (use_ll ? ll_valid : huff_valid),
        .i_code     (use_ll ? ll_code  : huff_code),
        .i_len      (use_ll ? ll_len   : huff_len),
        .i_code2    (use_ll ? 32'd0    : huff_code2),
        .i_len2     (use_ll ? 6'd0     : huff_len2),
        .i_two      (use_ll ? 1'b0     : huff_two),
        .i_ready    (bp_ok),
        .o_valid    (bp_valid),
        .o_data     (bp_data),
        .o_ready    (m_ready),
        .o_byte_cnt (bp_cnt)
    );

    // ★ 2026-10-28 诊断抽头 (只读, 不影响任何逻辑)。位定义见文件头的 o_diag 说明。
    assign o_diag = { bp_flush, huff_done, st_done, st_busy,
                      m_ready,  bp_ok,     huff_start, huff_run,
                      q_load_done, lb_avail, pend, tstate };

    //=============================================================== 头部
    reg         hdr_start;
    wire        hdr_valid;
    wire [7:0]  hdr_data;
    wire        hdr_done;

    jpeg_headers u_hdr (
        .clk      (clk),
        .rst_n    (rst_n),
        .i_start  (hdr_start),
        .i_lossless(i_lossless),
        .i_width  (i_width),
        .i_height (i_height),
        .i_rst_int(i_rst_int),
        .o_qt_idx (o_qt_idx_a),
        .i_qt_data(i_qt_data_a),
        .o_valid  (hdr_valid),
        .i_ready  (m_ready),
        .o_data   (hdr_data),
        .o_done   (hdr_done)
    );

    //=============================================================== 块属性
    // ★ 流水后 "DCT 正在做的块" 和 "熵编码正在做的块" 不再同一个,
    //   所以量化侧的 chroma 用 blk, 熵编码侧的 comp/chroma 用 huff_blk。
    always @(*) begin
        case (blk)
        2'd0:    q_chroma = 1'b0;
        2'd1:    q_chroma = 1'b0;
        default: q_chroma = 1'b1;
        endcase
        case (huff_blk)
        2'd0:    begin huff_comp = 2'd0; huff_chroma = 1'b0; end
        2'd1:    begin huff_comp = 2'd0; huff_chroma = 1'b0; end
        2'd2:    begin huff_comp = 2'd1; huff_chroma = 1'b1; end
        default: begin huff_comp = 2'd2; huff_chroma = 1'b1; end
        endcase
        case (blk)
        2'd0:    rd_grp = {mx_reg,  1'b0};
        2'd1:    rd_grp = {mx_reg,  1'b1};
        default: rd_grp = {1'b0, mx_reg};
        endcase
        rd_sel = blk;
    end

    //=============================================================== 熵编码后台调度 (block 级流水)
    //  DCT 每完成一块就 pend+1 并翻转 wr_buf; 这里一有空闲就启动编码,
    //  编码读的是 rd_buf 那一组 —— 两边永远不碰同一组缓冲, 所以 DCT(30 拍)
    //  和熵编码(跳零后 ~22 拍) 完全并行, 而不是相加。
    //  pend = 已 DCT 完成但还没编码完的块数, 最大 2 (= 两组缓冲)。
    //  pend 同拍可能既 +1 又 -1, 所以先算一个组合中间值再写回。
    always @(*) begin
        pend_nx = {1'b0, pend};
        if (q_blk_done) pend_nx = pend_nx + 3'd1;
        if (huff_done)  pend_nx = pend_nx - 3'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            huff_start    <= 1'b0;
            huff_run      <= 1'b0;
            frame_first   <= 1'b0;
            pend          <= 2'd0;
            wr_buf        <= 1'b0;
            rd_buf        <= 1'b0;
            huff_blk      <= 2'd0;
            rst_cnt       <= 16'd0;
            rst_idx       <= RST_INIT[2:0];
            rst_busy      <= 1'b0;
            rst_pred_pend <= 1'b0;
            rst_req       <= 1'b0;
            enc_mcu       <= 16'd0;
        end else if (tstate == 4'd0 && i_en) begin   // 4'd0 = T_IDLE (局部参数在后面声明)
            huff_start    <= 1'b0;
            huff_run      <= 1'b0;
            frame_first   <= 1'b1;      // 本帧第一个块要清一次 DC 预测器
            pend          <= 2'd0;
            wr_buf        <= 1'b0;
            rd_buf        <= 1'b0;
            huff_blk      <= 2'd0;
            rst_cnt       <= 16'd0;
            rst_idx       <= RST_INIT[2:0];
            rst_busy      <= 1'b0;
            rst_pred_pend <= 1'b0;
            rst_req       <= 1'b0;
            enc_mcu       <= 16'd0;
        end else begin
            huff_start <= 1'b0;
            rst_req    <= 1'b0;
            pend       <= pend_nx[1:0];

            if (q_blk_done) wr_buf <= ~wr_buf;

            // ★ 预测器复位只能给“帧内第一块的 S_DC”那一拍。
            //   i_rst_pred 的优先级高于 S_DC 更新预测器, 如果整个第一块期间都为 1,
            //   预测器就一直停在 0 —— 于是**第二块**的 DC 差分变成 zz[0]-0,
            //   而正确值是 zz1[0]-zz0[0]。实测症状: 第一个块末尾起全错位。
            //   huff_start 的下一拍正好是 S_DC, 所以这里延迟一拍给。
            if (huff_start) begin
                huff_run      <= 1'b1;
                frame_first   <= 1'b0;
                rst_pred_pend <= 1'b0;
            end

            if (huff_done) begin
                huff_run      <= 1'b0;
                rd_buf        <= ~rd_buf;
                huff_blk      <= (huff_blk == 2'd3) ? 2'd0 : (huff_blk + 2'd1);
            end

            // ---- DRI: 每编完 i_rst_int 个 MCU 插一个 RST 标记 ----
            //   ★ 本帧最后一个 MCU 之后**不能**再插 (否则 JPUF 解码器报错)。
            //   ★ 插标记期间必须禁止启动新块, 否则下一个 MCU 的符号会挤到标记前面。
            if (mcu_end) begin
                enc_mcu <= enc_mcu + 16'd1;
                if ((i_rst_int != 16'd0) && (rst_cnt == (i_rst_int - 16'd1))
                    && (!last_mcu || (LAST_RST_EN != 0))) begin
                    rst_req  <= 1'b1;
                    rst_busy <= 1'b1;
                    rst_cnt  <= 16'd0;
                    // ★ 这里**不**自增 rst_idx: bitpack 是在 rst_req 之后一拍才锁存
                    //   i_rst_idx 的, 现在自增会让第一个标记变成 RST1 (实测 D1 D2 D3)。
                    //   改成 bp_rst_done 时再自增, 保证从 RST0 开始。
                end else if (i_rst_int != 16'd0) begin
                    rst_cnt <= rst_cnt + 16'd1;
                end else begin
                    rst_cnt <= 16'd0;
                end
            end

            if (bp_rst_done) begin
                rst_busy      <= 1'b0;
                rst_pred_pend <= 1'b1;    // 重启段的第一块要清 DC 预测器
                rst_idx       <= rst_idx + RST_STEP[2:0];
            end

            // 有活就启动 (无损模式不走熵编码; RST 标记发送期间也不能启动)
            if ((pend != 2'd0) && !huff_run && !huff_start && !huff_done && !use_ll
                && !rst_busy && !rst_req)
                huff_start <= 1'b1;
        end
    end

    //=============================================================== 控制
    localparam [3:0] T_IDLE  = 4'd0;
    localparam [3:0] T_LOADQ = 4'd1;
    localparam [3:0] T_HDR   = 4'd2;
    localparam [3:0] T_WGRP  = 4'd3;
    localparam [3:0] T_RD    = 4'd4;
    localparam [3:0] T_WDCT  = 4'd5;
    localparam [3:0] T_HUFF  = 4'd6;
    localparam [3:0] T_NEXT  = 4'd7;
    localparam [3:0] T_FIN   = 4'd8;
    localparam [3:0] T_EOI   = 4'd9;
    localparam [3:0] T_HDR2  = 4'd10;   // 无损: T_IDLE 后一拍再发 hdr_start
    localparam [3:0] T_LLRUN = 4'd11;   // 无损: 等收满 NWORD 个 word
    localparam [3:0] T_DRAIN = 4'd12;   // 有损: 等熵编码把残留块编完再 flush

    //=============================================================== 输入就绪
    // ★ 无损路径必须等 header 发完、ll_start 已经把 line_buf/col/wr_buf 清干净
    //   之后才允许收数据。否则 header 期间 s_ready=ll_ready=1, 上游先把数据喂进来,
    //   紧接着 T_HDR2 的 ll_start 把 line_buf/col 全清, 那批数据就丢了 ——
    //   实测表现为整个最前面一段样本凭空消失、之后全部错位。
    //   (必须放在 tstate/T_LLRUN 声明之后, 否则 iverilog 报 bind 错误)

    reg [3:0]  rc;
    reg [8:0]  my;
    reg        eoi_ph;
    reg [2:0]  fin_cnt;
    reg [31:0] ll_wcnt;

    // ---------------- block 级流水 ----------------
    //   DCT 写完一组就交给熵编码, 自己马上去做下一块 (qzz 双缓冲)。
    //   pend = "已 DCT 完成、尚未编码完" 的块数, 最大 2 (两组缓冲).
    //   (寄存器声明已提前到文件前部)

    assign s_ready = use_ll ? (ll_ready && ll_run) : lb_ready;

    // 输出 mux
    always @(*) begin
        if (hdr_valid) begin
            m_valid = 1'b1;  m_data = hdr_data;  m_last = 1'b0;
        end else if ((tstate == T_EOI) && (EOI_EN != 0)) begin
            m_valid = 1'b1;  m_data = eoi_ph ? 8'hD9 : 8'hFF;  m_last = eoi_ph;
        end else begin
            m_valid = bp_valid;  m_data = bp_data;  m_last = 1'b0;
        end
    end

    // 无损模式: 统计已接收的 word 数 (ll_start 之后开始计)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              ll_wcnt <= 32'd0;
        else if (ll_start)       ll_wcnt <= 32'd0;
        else if (s_valid && ll_ready && ll_run)
                                 ll_wcnt <= ll_wcnt + 32'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate        <= T_IDLE;
            rc            <= 4'd0;
            mx_reg        <= 8'd0;
            my            <= 9'd0;
            blk           <= 2'd0;
            dct_start     <= 1'b0;
            dct_valid     <= 1'b0;
            q_load        <= 1'b0;
            hdr_start     <= 1'b0;
            bp_flush      <= 1'b0;
            grp_done      <= 1'b0;
            ll_start      <= 1'b0;   // ★ 必须在复位里清, 否则复位期间是 X
                                     //   会把 u_ll 的 i_ready 污染成 X,
                                     //   上游握手 while(!s_ready) 永久卡死
            ll_run        <= 1'b0;
            eoi_ph        <= 1'b0;
            fin_cnt       <= 3'd0;
            // ll_wcnt 不在这里清 —— 它有自己的 always 块 (计数 + ll_start 清零),
            // 两个块都赋值会被 TD 判成多驱动 (HDL-8007)。
            rd_row        <= 3'd0;
            st_busy       <= 1'b0;
            st_done       <= 1'b0;
            st_frame_bytes<= 24'd0;
            st_frame_cnt  <= 32'd0;
        end else begin
            dct_start <= 1'b0;
            dct_valid <= 1'b0;
            q_load    <= 1'b0;
            hdr_start <= 1'b0;
            bp_flush  <= 1'b0;
            grp_done  <= 1'b0;
            ll_start  <= 1'b0;
            st_done   <= 1'b0;

            if (i_soft_rst) begin
                tstate  <= T_IDLE;
                st_busy <= 1'b0;
            end else begin
            case (tstate)
            //----------------------------------------------------
            T_IDLE: begin
                if (i_en) begin
                    st_busy       <= 1'b1;
                    if (use_ll) begin
                        ll_start <= 1'b1;       // 清预测器/行缓冲
                        ll_run   <= 1'b0;       // header 没发完之前不许收数据
                        tstate   <= T_HDR2;
                    end else begin
                        q_load <= 1'b1;
                        tstate <= T_LOADQ;
                    end
                end
            end

            //----------------------------------------------------
            T_HDR2: begin
                hdr_start <= 1'b1;
                tstate    <= T_HDR;
            end

            //----------------------------------------------------
            T_LLRUN: begin
                // ★ 必须等 u_ll 把最后一个 word 的码也吐出来 (ll_ready 回到 1)
                //   才能 flush。u_ll 是 4 clk/word 的流水, 收到第 NWORD 个时
                //   最后一个 word 的码还在流水线里; 此时就 flush 出来的是半个码
                //   —— 实测末尾 2 字节 0C 03 变成 1 字节 1F。
                if (ll_wcnt >= NWORD && ll_ready) begin
                    ll_run   <= 1'b0;        // 停止接收, 不再允许上游推进
                    bp_flush <= 1'b1;
                    tstate   <= T_FIN;
                end
            end

            //----------------------------------------------------
            T_LOADQ: begin
                if (q_load_done) begin
                    if (HDR_EN != 0) begin
                        hdr_start <= 1'b1;
                        tstate    <= T_HDR;
                    end else begin
                        // 右引擎不发帧头, 直接开始收数据 (与 T_HDR 里的初始化一致)
                        mx_reg <= 8'd0;
                        my     <= 9'd0;
                        blk    <= 2'd0;
                        tstate <= T_WGRP;
                    end
                end
            end

            //----------------------------------------------------
            T_HDR: begin
                if (hdr_done) begin
                    if (use_ll) begin
                        ll_run <= 1'b1;      // header 发完, 现在才允许收 YUV
                        tstate <= T_LLRUN;
                    end else begin
                        mx_reg <= 8'd0;
                        my     <= 9'd0;
                        blk    <= 2'd0;
                        tstate <= T_WGRP;
                    end
                end
            end

            //----------------------------------------------------
            // 等当前读 buffer 有完整 8 行 (电平, 不是脉冲)
            T_WGRP: begin
                if (lb_avail && (pend != 2'd2)) begin
                    rc     <= 4'd0;
                    tstate <= T_RD;
                end
            end

            //----------------------------------------------------
            // rc=0    : 摆第 0 行地址 + DCT start
            // rc=1..8 : DCT 收第 rc-1 行 (RAM 数据晚一拍到)
            // rc=9    : 收尾
            T_RD: begin
                if (rc == 4'd0) begin
                    dct_start <= 1'b1;
                    rd_row    <= 3'd0;
                    rc        <= 4'd1;
                end else if (rc <= 4'd8) begin
                    dct_valid <= 1'b1;
                    // rc=1 摆 row1 (row0 已于 rc=0 摆出), 依此类推; rc=8 摆 0 并收尾
                    rd_row    <= rc[2:0];
                    rc        <= rc + 4'd1;
                end else begin
                    rd_row <= 3'd0;
                    tstate <= T_WDCT;
                end
            end

            //----------------------------------------------------
            // DCT 跑完 + 量化跑完 (q_blk_done 比 dct_odone 晚一拍)
            // ★ 流水: 这里不再等熵编码, 交给缓冲就继续做下一块。
            T_WDCT: begin
                if (q_blk_done) begin
                    tstate <= T_NEXT;
                end
            end

            //----------------------------------------------------
            // T_HUFF 已废弃: 熵编码改成后台并行调度 (见下面独立 always)。
            // 保留常量只为兼容旧代码路径。
            T_HUFF: begin
                tstate <= T_NEXT;
            end

            //----------------------------------------------------
            // 等熵编码把残留块编完
            T_DRAIN: begin
                if (pend == 2'd0 && !huff_run) begin
                    bp_flush <= 1'b1;
                    tstate   <= T_FIN;
                end
            end

            //----------------------------------------------------
            T_NEXT: begin
                if (blk != 2'd3) begin
                    if (pend != 2'd2) begin       // 有缓冲就继续, 否则等熵编码让出
                        blk    <= blk + 2'd1;
                        rc     <= 4'd0;
                        tstate <= T_RD;
                    end
                end else begin
                    blk <= 2'd0;
                    if (mx_reg == (MCU_X - 8'd1)) begin
                        mx_reg   <= 8'd0;
                        my       <= my + 9'd1;
                        grp_done <= 1'b1;       // 释放一个 8 行组
                        if (my == (MCU_Y - 9'd1)) begin
                            tstate   <= T_DRAIN;   // 等残留块编完再 flush
                        end else begin
                            tstate   <= T_WGRP;
                        end
                    end else begin
                        mx_reg <= mx_reg + 8'd1;
                        rc     <= 4'd0;
                        tstate <= T_RD;
                    end
                end
            end

            //----------------------------------------------------
            // ★ 必须等 bitpack 把 flush 的那个字节真正吐出去再进 EOI。
            //   bp_flush 在 T_NEXT 拍拉高, bitpack 下一拍才输出 o_valid;
            //   若此时直接进 T_EOI, 输出 mux 会被 EOI 抢占, 最后一个熵字节
            //   就丢了 (实测: 861 字节 vs 参考 862, 只差最后 0x63)
            T_FIN: begin
                // bp_flush 是寄存的, bitpack 的输出又晚一拍, 再加可能的
                // 0xFF->00 填充; 无损最后可能还剩 2 字节, 等 8 拍最稳。
                // ★ 还要求 bp_valid 已经下去 —— 接 CSI-2 后 m_ready 会在发包时
                //   拉低把 bitpack 冻结, 只看固定拍数会把没吐完的字节切断。
                if (fin_cnt == 3'd7 && !bp_valid) begin
                    fin_cnt <= 3'd0;
                    eoi_ph  <= 1'b0;
                    tstate  <= T_EOI;
                end else begin
                    fin_cnt <= fin_cnt + 3'd1;
                end
            end

            T_EOI: begin
                // ★ FF/D9 也要等下游接住; 否则发包期间这两个字节会丢。
                if (m_ready) begin
                    eoi_ph <= ~eoi_ph;
                    if (eoi_ph) begin
                        st_frame_bytes <= bp_cnt[23:0];
                        st_frame_cnt   <= st_frame_cnt + 32'd1;
                        st_done        <= 1'b1;
                        st_busy        <= 1'b0;
                        tstate         <= T_IDLE;
                    end
                end
            end

            default: tstate <= T_IDLE;
            endcase
            end
        end
    end

endmodule

//=============================================================================
//  以下两个模块【内联】在本文件里, 而不是各占一个 .v 文件。
//
//  原因 (2026-10-26 踩过的坑): 新增 .v 文件必须同时进 TD 工程的 <File> 列表,
//  而**已打开的 TD GUI 用的是内存里的旧列表** —— 直接综合就报
//      ERROR: jpeg_enc_if(AW=10) is a black box in .../system_top.v(655)
//  更糟的是: 用第二份 TD 实例或 TD 退出保存时, 会把它内存里的列表写回
//  fpga_prj.al, 把手工加的条目冲掉(已实测两次)。
//  => 把新增模块内联到**已在工程里**的 jpeg_encoder_top.v, 就绕开了整个问题。
//     （Verilog 一个文件含多个 module 是合法的。）
//  ⚠ 若以后要把它们拆回独立文件, 必须**先关 TD**, 再改 .al 并重新打开工程。
//=============================================================================

/*===========================================================================
 * module jpeg_enc_if
 * Description  : JPEG 编码器的输入接口 —— 跨时钟 + 反压 + 位宽转换
 *
 *  原来的接法 (system_top.v) 有三处硬伤, 导致这条 JPEG 支路**从来没有
 *  出过一帧正确的图**:
 *    ① 编码器直接挂在 S_hs_rx_clk (单路 32.4MHz) 域, 不是快时钟域;
 *    ② 312/150 拍/MCU 下, 32.4MHz 只够 1080p 6.4fps;
 *    ③ s_ready 连出来但**一根线都没用**, 而且只接了 s_data[31:0],
 *       而源是 64bit = 4 像素/拍 —— 每拍 4 个像素里只有 2 个进编码器,
 *       行缓冲永远凑不满 8 行。
 *
 *  本模块负责 ① 和 ③:
 *    源侧 (s_clk 域, 4px/拍, 64bit, 带帧首标记)
 *        -> 异步 FIFO (65bit = {sof, 4像素})
 *        -> 拆成 2 个 32bit (= 2px) word, **严格按 e_ready 反压**
 *        -> 编码器 (e_clk 域, 2px/拍)
 *
 *  关键约定 (照抄 jpeg_encoder_top / jpeg_linebuf 的契约):
 *    · 编码器是**连续流**消费者: 每帧必须恰好 (W/2)*H 个 32bit word,
 *      光栅顺序, 不能多不能少。少一个 word 整个帧就错位, 而且因为
 *      行缓冲按 8 行一组乒乓 (H 必须是 8 的倍数), 错位会传染到后续帧。
 *      => **绝对不能在帧内丢字**。整帧进/整帧不进要由上游按帧率控制。
 *    · s_ready 必须被尊重: 行缓冲满时 (o_wr_ready=0) 编码器不收数据,
 *      此时本模块把数据压在 FIFO 里, 不丢。
 *    · 字节序: 一个 64bit 源字 {Cr3,Y3,Cb2,Y2,Cr1,Y1,Cb0,Y0},
 *      低 32bit = 像素 0,1 -> 先送; 高 32bit = 像素 2,3。
 *
 *  诊断 (排查"出不了帧"时的第一手数据):
 *    st_ovf     : 源侧 FIFO 溢出次数 (= 丢了 word, 一定出问题)
 *    st_word_lo : 已转发 64bit word 数的低 16 位 (帧内进度)
 *    st_sof     : 收到的帧首个数
 *
 *  仿真: fpga/sim/tb_jpeg_enc_if.v (run_jpeg_enc_if.ps1)
 *        A: e_ready 恒1       words=768  ovf=0 sof=6 err=0
 *        B: e_ready 1/4 反压  words=1536 ovf=0 sof=12 err=0
 *        C: 编码器 20MHz 远慢于源 -> st_ovf=619 正确检出
 *===========================================================================*/
module jpeg_enc_if #(
    parameter integer AW = 10,          // FIFO 深度 = 2^AW 个 65bit word
    parameter integer DW = 65,
    // ★ 2026-10-28: 起送门限 (单位 = 64bit word)
    //   背景: 四引擎方案里每个引擎只拿到一行 1/4 的像素, 送过来是"突发 32 个
    //   word + 空 3/4 行"。仿真证明 **jpeg_encoder_top 无法容忍 s_valid 断流**:
    //   突发送法下引擎吃掉 768/1024 个 word 后就卡死, 而且熵编码器持续吐垃圾
    //   (~1 byte/clk, o_seg_done 永不置位)。连续送法则 1024/1024 全部吃完。
    //   所以: FIFO 里攒够 START_LEVEL 个 word 再开始读 —— 之后源侧速率远高于
    //   引擎消耗速率, FIFO 不会见底, 引擎就能一直读到连续流。
    //   0 = 旧行为 (攒到非空就读), 不改变原有例化。
    parameter integer START_LEVEL = 0
) (
    // ---------------- 源侧: YUV422 4 像素/拍 ----------------
    input  wire         s_clk,
    input  wire         s_rst_n,
    input  wire         s_valid,
    input  wire [63:0]  s_data,
    input  wire         s_sof,          // 该 word 是一个新帧的第 0 个 word

    // ---------------- 编码器侧: YUV422 2 像素/拍 ----------------
    input  wire         e_clk,
    input  wire         e_rst_n,
    input  wire         i_flush,        // 2026-10-27: 看门狗用 —— 清 FIFO + 读侧状态
    output wire         e_valid,
    output wire [31:0]  e_data,
    input  wire         e_ready,

    // ---------------- 诊断 ----------------
    output reg  [15:0]  st_ovf,
    output reg  [15:0]  st_word_lo,
    output reg  [15:0]  st_sof,
    output wire [AW-1:0] o_level,
    // ★ 2026-10-28: 源侧满标志。给上游做反压用 ——
    //   yuv32_to_quad 的 c_ready 必须接"下游装不装得下", 而不是帧门控。
    output wire         o_full
);

    //=============================================================== 源侧写
    wire        f_full, f_empty;
    wire [AW-1:0] f_wcnt, f_rcnt;
    wire [DW-1:0] f_dout;

    assign o_level = f_rcnt;
    assign o_full  = f_full;

    wire f_wr = s_valid & ~f_full;

    //=============================================================== 读侧状态
    //  ★ 必须全部声明在 FIFO 例化**之前** —— Verilog 先声明后使用,
    //    否则 e_rd_en 里的 w_v/d_v 会被隐式声明成 1bit wire
    //    (本工程已踩过三次, 见 memory)。
    //  ★ FIFO 的 dout 是寄存器输出, rd_en 之后**晚一拍**才有数据,
    //    所以用 d_v 精确对齐 (d_v <= rd_en), 与 csi2_pack V43 的修法同源。
    reg         d_v;
    reg         w_v;          // 手上有一个 64bit word 待拆
    reg         half;         // 0 = 送低 32bit, 1 = 送高 32bit
    reg  [63:0] w_data;
    reg         rd_go;        // 起送门限已满足 (见 START_LEVEL 说明)

    // 起送: START_LEVEL=0 时直接放行; 否则等 FIFO 攒够 (一次置位后不再撤销,
    // 因为源侧持续供数, 撤了反而会在帧间隙重新攒)
    always @(posedge e_clk or negedge e_rst_n) begin
        if (!e_rst_n)                        rd_go <= (START_LEVEL == 0);
        else if (i_flush)                    rd_go <= (START_LEVEL == 0);
        else if (!rd_go && (f_rcnt >= START_LEVEL))       rd_go <= 1'b1;
    end

    wire e_rd_en = rd_go & ~w_v & ~d_v & ~f_empty;

    always @(posedge s_clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            st_ovf <= 16'd0;
            st_sof <= 16'd0;
        end else begin
            // 源侧溢出 = 丢了 word, 帧结构必然破坏。正常情况下应恒为 0。
            if (s_valid && f_full) st_ovf <= st_ovf + 16'd1;
            if (s_valid && s_sof)  st_sof <= st_sof + 16'd1;
        end
    end

    fifo_32b_async_2 #(
        .DATA_WIDTH (DW),
        .ADDR_WIDTH (AW)
    ) u_fifo (
        .rst          (~(s_rst_n & e_rst_n) | i_flush),
        .wr_clk       (s_clk   ),
        .rd_clk       (e_clk   ),
        .din          ({s_sof, s_data}),
        .wr_en        (f_wr    ),
        .rd_en        (e_rd_en ),
        .dout         (f_dout  ),
        .full         (f_full  ),
        .empty        (f_empty ),
        .rd_data_count(f_rcnt  ),
        .wr_data_count(f_wcnt  ),
        .wr_rst_busy  (        ),
        .rd_rst_busy  (        )
    );

    //=============================================================== 读侧: 拆字
    assign e_valid = w_v;
    assign e_data  = half ? w_data[63:32] : w_data[31:0];

    always @(posedge e_clk or negedge e_rst_n) begin
        if (!e_rst_n) begin
            d_v       <= 1'b0;
            w_v       <= 1'b0;
            half      <= 1'b0;
            w_data    <= 64'd0;
            st_word_lo<= 16'd0;
        end else if (i_flush) begin
            d_v    <= 1'b0;
            w_v    <= 1'b0;
            half   <= 1'b0;
            w_data <= 64'd0;
        end else begin
            d_v <= e_rd_en;

            // 默认: 消化当前 word
            if (w_v && e_ready) begin
                if (!half) begin
                    half <= 1'b1;            // 低 32bit 已被接走, 接着送高 32bit
                end else begin
                    half <= 1'b0;
                    w_v  <= 1'b0;            // 一个 word 的两半都送完了
                    st_word_lo <= st_word_lo + 16'd1;
                end
            end

            // 取到新 word: 覆写 (d_v=1 时 w_v 必为 0, 见下)
            if (d_v) begin
                w_data <= f_dout[63:0];
                w_v    <= 1'b1;
                half   <= 1'b0;
            end
        end
    end

    //  ★ 上面"覆写"成立的前提: d_v=1 时 w_v 一定还是 0。
    //    证明: d_v <= e_rd_en, 而 e_rd_en 要求 ~w_v, 所以发起读的那一拍 w_v=0;
    //    之后 w_v 只可能被同一个 d_v 置 1, 不可能提前变 1。
    //    这条不变式一旦被破坏, 就会静默丢 word —— 所以 TB 里加了逐字比对。

    wire _unused_sof  = f_dout[64];
    wire _unused_wcnt = |f_wcnt;

endmodule

/*===========================================================================
 * module jpeg_byte_bridge
 * Description  : JPEG 码流跨时钟桥 —— 编码器域(300MHz) -> CSI-2 发送域(byte_clk 150MHz)
 *
 *  原来 csi2_frame_tx_var (X_jv) 挂在 S_hs_rx_clk (单路 32.4MHz) 上,
 *  而它的 hs_en/hs_data 直接喂给 D-PHY TX —— 那是在 **S_dsi_byte_clk**(150MHz)
 *  域采样的。这条 JPEG 支路的最后一跳本来就是跨时钟域没做同步,
 *  又一个"从来没跑过"的证据。
 *
 *  数据量很小: 3840x1080@60 按 Q75 约 12~18 MB/s, 256 深 (9bit) 够吸收突发。
 *  9bit = {last, byte}, last 只在每帧最后一个字节 (0xFF/0xD9) 置位,
 *  用来保持 csi2_frame_tx_var 的 s_tlast 语义。
 *
 *  仿真: fpga/sim/tb_jpeg_byte_bridge.v
 *        300MHz->150MHz, 读侧 1/3 随机反压: sent=3000 got=3000 err=0 PASS
 *===========================================================================*/
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
    //    编码器从 m_ready 得到了反压, 不会丢字节; 这里只记录背压量,
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

    wire _unused_wcnt2 = |f_wcnt;

endmodule


/*===========================================================================
 *  鈽?2026-10-28: 涓嬮潰鐨?yuv32_to_quad 鍘熸湰鏄嫭绔嬫枃浠?yuv32_to_quad.v銆?
 *    骞惰繘鏈枃浠剁殑鍘熷洜涓嶆槸椋庢牸, 鑰屾槸宸ョ▼绾︽潫:
 *    TD 閫€鍑?淇濆瓨鏃朵細閲嶅啓 fpga_prj.al / syn_1/fpga_prj.prj 鐨?<File> 鍒楄〃,
 *    鎵嬪伐鍔犵殑鏉＄洰浼氳鍐叉帀 -> 缁煎悎鎶?HDL-8007 "yuv32_to_quad is a black box"銆?
 *    jpeg_enc_if / jpeg_byte_bridge 褰撳垵涔熸槸鍥犱负杩欎釜鎵嶆斁鍦ㄦ湰鏂囦欢鏈熬銆?
 *==========================================================================*/
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
