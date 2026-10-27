/*===========================================================================
 * Filename     : csi2_frame_tx.v
 * Description  : Layer-1 CSI-2 frame transmitter (格式无关).
 *                从 AXI-Stream slave 接口吃 payload word, 不关心内部格式.
 *                通过 DT/BPP 参数支持 YUV422/RGB888/RAW10/... 等任意 CSI-2
 *                Data Type. Payload pack 由 Layer-2 完成.
 *
 *===========================================================================*/
`timescale 1ns / 1ps

module csi2_frame_tx #(
    parameter [5:0]   DT         = 6'h1E,        // Data Type (YUV422=0x1E,RGB888=0x24,RAW10=0x2B,...)
    parameter [1:0]   VC         = 2'd0,         // Virtual Channel
    // V21: H_ACTIVE / V_ACTIVE 改为运行时端口 (见 I_h_active / I_v_active)
    parameter integer BPP_NUM    = 2,            // bytes-per-pixel numerator
    parameter integer BPP_DEN    = 1,            // bytes-per-pixel denominator
                                                 //   YUV422→2/1, RGB888→3/1, RAW10→5/4
    parameter [31:0]  GAP_LINE   = 32'd200,      // byte_clk gap between packets (inter-line)
    parameter [31:0]  GAP_FRAME  = 32'd4000      // byte_clk gap after FE
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    // V21: 运行时图像尺寸 (每帧保持稳定)
    input  wire [12:0] I_h_active,   // 有效像素/行
    input  wire [11:0] I_v_active,   // 有效行数

    // --- AXI-Stream slave (from Layer-2 packer) ---
    input  wire        s_tvalid,
    output reg         s_tready,
    input  wire [31:0] s_tdata,
    input  wire        s_tuser_sof,   // frame start flag
    input  wire        s_tlast,       // end-of-line flag

    // --- HS stream to DPHY wrapper ---
    output reg         hs_en,
    output reg  [31:0] hs_data,
    output reg         hs_last,

    // --- Statistics ---
    output reg  [31:0] frame_cnt,
    output reg  [31:0] packet_cnt
);

    // ---- Derived (V21: 运行时) -------------------------------------------
    wire [31:0] WC_INT        = (I_h_active * BPP_NUM) / BPP_DEN;
    wire [15:0] WC            = WC_INT[15:0];
    wire [31:0] WORDS_PAYLOAD = WC_INT >> 2;
    localparam [5:0]   DT_FS          = 6'h00;
    localparam [5:0]   DT_FE          = 6'h01;

    // ---- ECC (Anlogic DSI reference compatible) --------------------------
    // Input  : d24 = { DI[7:0], data_L[7:0], data_H[7:0] }
    // DI     = {VC, DT}
    function [7:0] ecc8;
        input [23:0] d;
        reg   [7:0]  e;
        begin
            e[7] = 1'b0;
            e[6] = 1'b0;
            e[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[0]^d[1]^d[2]^d[3]^d[5]^d[6]^d[7];
            e[4] = d[20]^d[21]^d[22]^d[23]^d[8]^d[9]^d[0]^d[1]^d[2]^d[3]^d[4]^d[6]^d[7];
            e[3] = d[17]^d[18]^d[19]^d[23]^d[8]^d[9]^d[13]^d[14]^d[15]^d[3]^d[4]^d[5]^d[7];
            e[2] = d[16]^d[18]^d[19]^d[21]^d[22]^d[9]^d[11]^d[12]^d[15]^d[2]^d[4]^d[5]^d[6];
            e[1] = d[16]^d[17]^d[19]^d[20]^d[22]^d[8]^d[10]^d[12]^d[14]^d[1]^d[4]^d[5]^d[6]^d[7];
            e[0] = d[16]^d[17]^d[18]^d[20]^d[21]^d[23]^d[10]^d[11]^d[13]^d[0]^d[4]^d[5]^d[6]^d[7];
            ecc8 = e;
        end
    endfunction

    // ---- CRC-16 CSI-2 ------------------------------------------------------
    function [15:0] crc16_byte;
        input [15:0] cin;
        input [7:0]  b;
        reg   [15:0] c;
        integer i;
        begin
            c = cin ^ {8'h00, b};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0]) c = (c >> 1) ^ 16'h8408;
                else      c = c >> 1;
            end
            crc16_byte = c;
        end
    endfunction

    function [15:0] crc16_word;
        input [15:0] cin;
        input [31:0] w;
        begin
            crc16_word = crc16_byte(
                           crc16_byte(
                             crc16_byte(
                               crc16_byte(cin, w[7:0]),
                               w[15:8]),
                             w[23:16]),
                           w[31:24]);
        end
    endfunction

    // ---- Short / Long packet header builders -----------------------------
    function [31:0] build_short_hdr;
        input [5:0]  dt;
        input [15:0] data16;
        reg   [7:0]  di;
        reg   [23:0] d24;
        begin
            di              = {VC, dt};
            d24             = {di, data16[7:0], data16[15:8]};
            build_short_hdr = {ecc8(d24), data16[15:8], data16[7:0], di};
        end
    endfunction

    function [31:0] build_long_hdr;
        input [5:0]  dt;
        input [15:0] wc16;
        reg   [7:0]  di;
        reg   [23:0] d24;
        begin
            di             = {VC, dt};
            d24            = {di, wc16[7:0], wc16[15:8]};
            build_long_hdr = {ecc8(d24), wc16[15:8], wc16[7:0], di};
        end
    endfunction


    localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_WAIT_SOF = 4'd1;
    localparam [3:0] S_FS       = 4'd2;
    localparam [3:0] S_LP_HDR_F = 4'd3;
    localparam [3:0] S_LP_PL_F  = 4'd4;
    localparam [3:0] S_LP_PL    = 4'd5;
    localparam [3:0] S_LP_HDR_N = 4'd6;
    localparam [3:0] S_LP_PL_N  = 4'd7;
    localparam [3:0] S_LP_CRC   = 4'd8;
    localparam [3:0] S_FE       = 4'd9;
    localparam [3:0] S_GAP      = 4'd10;

    reg [3:0]  state;
    reg [3:0]  state_after_gap;
    reg [31:0] gap_cnt;
    reg [31:0] gap_target;
    reg [15:0] pl_word_cnt;
    reg [15:0] line_cnt;
    reg [15:0] frame_num;
    reg [15:0] crc;
    reg [31:0] shadow_word;

    wire [31:0] fs_word = build_short_hdr(DT_FS, frame_num);
    wire [31:0] fe_word = build_short_hdr(DT_FE, frame_num);
    wire [31:0] lp_hdr  = build_long_hdr (DT,    WC);

    // ---- tready combinatorial: 仅在等 sof / 吃 payload 时拉高 ----
    always @(*) begin
        case (state)
            S_WAIT_SOF: s_tready = 1'b1;
            S_LP_PL:    s_tready = 1'b1;
            S_LP_PL_N:  s_tready = 1'b1;
            default:    s_tready = 1'b0;
        endcase
    end

    // ---- FSM --------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            state_after_gap <= S_IDLE;
            gap_cnt         <= 32'd0;
            gap_target      <= GAP_LINE;
            pl_word_cnt     <= 16'd0;
            line_cnt        <= 16'd0;
            frame_num       <= 16'd0;
            crc             <= 16'hFFFF;
            shadow_word     <= 32'd0;
            hs_en           <= 1'b0;
            hs_data         <= 32'd0;
            hs_last         <= 1'b0;
            frame_cnt       <= 32'd0;
            packet_cnt      <= 32'd0;
        end else if (!enable) begin
            state           <= S_IDLE;
            hs_en           <= 1'b0;
            hs_data         <= 32'd0;
            hs_last         <= 1'b0;
            pl_word_cnt     <= 16'd0;
            line_cnt        <= 16'd0;
            gap_cnt         <= 32'd0;
        end else begin
            case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    hs_en    <= 1'b0;
                    hs_data  <= 32'd0;
                    hs_last  <= 1'b0;
                    line_cnt <= 16'd0;
                    state    <= S_WAIT_SOF;
                end

                // --------------------------------------------------------
                // Handshake 第一帧第一个 word -> shadow
                S_WAIT_SOF: begin
                    hs_en   <= 1'b0;
                    hs_data <= 32'd0;
                    hs_last <= 1'b0;
                    if (s_tvalid && s_tuser_sof) begin
                        shadow_word <= s_tdata;
                        state       <= S_FS;
                    end
                    // 未对齐的 valid 丢弃 (保持 tready=1 吸收)
                end

                // --------------------------------------------------------
                S_FS: begin
                    hs_en           <= 1'b1;
                    hs_data         <= fs_word;
                    hs_last         <= 1'b1;
                    packet_cnt      <= packet_cnt + 32'd1;
                    gap_cnt         <= 32'd0;
                    gap_target      <= GAP_LINE;
                    state_after_gap <= S_LP_HDR_F;
                    state           <= S_GAP;
                end

                // --------------------------------------------------------
                S_LP_HDR_F: begin
                    hs_en       <= 1'b1;
                    hs_data     <= lp_hdr;
                    hs_last     <= 1'b0;
                    crc         <= 16'hFFFF;
                    pl_word_cnt <= 16'd0;
                    state       <= S_LP_PL_F;
                end

                // Payload word 0 = shadow
                S_LP_PL_F: begin
                    hs_en       <= 1'b1;
                    hs_data     <= shadow_word;
                    hs_last     <= 1'b0;
                    crc         <= crc16_word(16'hFFFF, shadow_word);
                    pl_word_cnt <= 16'd1;
                    if (WORDS_PAYLOAD <= 1)
                        state <= S_LP_CRC;
                    else
                        state <= S_LP_PL;
                end

                // --------------------------------------------------------
                // 首行剩余 WORDS_PAYLOAD-1 个 word 从 AXIS 吃
                S_LP_PL: begin
                    if (s_tvalid) begin
                        hs_en       <= 1'b1;
                        hs_data     <= s_tdata;
                        hs_last     <= 1'b0;
                        crc         <= crc16_word(crc, s_tdata);
                        pl_word_cnt <= pl_word_cnt + 16'd1;
                        if (pl_word_cnt == (WORDS_PAYLOAD[15:0] - 16'd1))
                            state <= S_LP_CRC;
                    end else begin

                        hs_en <= 1'b0;
                    end
                end

                // --------------------------------------------------------
                // 后续行 header (AXIS 在此 stall, tready=0)
                S_LP_HDR_N: begin
                    hs_en       <= 1'b1;
                    hs_data     <= lp_hdr;
                    hs_last     <= 1'b0;
                    crc         <= 16'hFFFF;
                    pl_word_cnt <= 16'd0;
                    state       <= S_LP_PL_N;
                end

                // 后续行从 AXIS 从 word 0 开始吃
                S_LP_PL_N: begin
                    if (s_tvalid) begin
                        hs_en       <= 1'b1;
                        hs_data     <= s_tdata;
                        hs_last     <= 1'b0;
                        crc         <= crc16_word(crc, s_tdata);
                        pl_word_cnt <= pl_word_cnt + 16'd1;
                        if (pl_word_cnt == (WORDS_PAYLOAD[15:0] - 16'd1))
                            state <= S_LP_CRC;
                    end else begin
                        hs_en <= 1'b0;
                    end
                end

                // --------------------------------------------------------
                S_LP_CRC: begin
                    hs_en           <= 1'b1;
                    hs_data         <= {16'h0000, crc};
                    hs_last         <= 1'b1;
                    packet_cnt      <= packet_cnt + 32'd1;
                    line_cnt        <= line_cnt + 16'd1;
                    gap_cnt         <= 32'd0;
                    gap_target      <= GAP_LINE;
                    state           <= S_GAP;
                    if (line_cnt == (I_v_active - 16'd1))
                        state_after_gap <= S_FE;
                    else
                        state_after_gap <= S_LP_HDR_N;
                end

                // --------------------------------------------------------
                S_FE: begin
                    hs_en           <= 1'b1;
                    hs_data         <= fe_word;
                    hs_last         <= 1'b1;
                    packet_cnt      <= packet_cnt + 32'd1;
                    frame_num       <= frame_num + 16'd1;
                    frame_cnt       <= frame_cnt + 32'd1;
                    line_cnt        <= 16'd0;
                    gap_cnt         <= 32'd0;
                    gap_target      <= GAP_FRAME;
                    state_after_gap <= S_WAIT_SOF;  // 帧末回等下一帧 sof
                    state           <= S_GAP;
                end

                // --------------------------------------------------------
                S_GAP: begin
                    hs_en   <= 1'b0;
                    hs_data <= 32'd0;
                    hs_last <= 1'b0;
                    if (gap_cnt >= gap_target) begin

                        if (state_after_gap == S_LP_HDR_N ||
                            state_after_gap == S_LP_HDR_F) begin
                            if (s_tvalid)
                                state <= state_after_gap;
                        end else begin
                            state <= state_after_gap;
                        end
                    end else begin
                        gap_cnt <= gap_cnt + 32'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

//==============================================================================
//  下面是 csi2_frame_tx_var (可变长/JPEG 专用, DT=0x18)
//  为什么合并在本文件里: TD 打开工程时会用内存里的文件列表覆盖 fpga_prj.al,
//  手工往 .al 里加新文件条目每次都被抹掉, 新模块就变成 black box。
//  放进这个已经在工程里的文件, 就完全不依赖工程文件编辑。
//==============================================================================
//==============================================================================
//  csi2_frame_tx_var.v   (v2: 乒乓双缓冲)
//  CSI-2 可变长帧发送 (JPEG 码流专用, DT=0x18)
//
//  为什么要 v2
//  -----------
//  v1 是"攒满一包 -> 停住上游 -> 发包 -> 再攒"。发包一个 PKT_BYTES 的包要
//  PKT_BYTES/4 + 3 拍, 对 PKT=1024 就是 259 拍。上游 JPEG 编码器在这种
//  几百拍的长停顿下会打乱 block 级流水 (实测 320x40 一帧 3797 字节变成 3760),
//  所以发送侧必须做到"几乎不让上游停"。
//
//  v2 用两个 bank 乒乓: 写完 A 立刻切到 B 继续收, 同时把 A 发出去。
//  D-PHY 一拍发 4 字节, 编码器平均一拍只产 0.5 字节 —— 发永远比收快,
//  所以正常运行时 s_tready 一直是 1, 只有"收得比发快两包以上"才短暂拉低。
//
//  帧结构:
//      FS 短包(DT=0x00) -> [long packet(DT=0x18) ...] -> FE 短包(DT=0x01) -> 消隐
//  最后一个包通常不满 PKT_BYTES, WC = 实际字节数; 不足 4 字节补 0,
//  补出来的 0 也计入 CRC。
//
//  hs_last 的用法与板上已验证的 csi2_frame_tx 保持一致 (FS/FE/CRC 三处拉高)。
//==============================================================================
module csi2_frame_tx_var #(
    parameter integer PKT_BYTES = 1024,     // 每个 long packet 的目标载荷字节数 (2 的幂, >= 4)
    parameter integer GAP_FRAME = 200,      // FE 之后到下一帧 FS 的空闲拍数
    parameter [1:0]   VC        = 2'b00
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    // 2026-10-27: 长包 DT 从编译期参数改成**运行时端口**。
    //   0x18 = 标准 JPEG (rkcif 当前配置拒收: 板上实测 MIPI_CSI2 ERR "err id"),
    //   0x1E = YUV422 8bit —— 与 NV16 通道同 DT, rkcif 才收 (JPEG 字节占帧缓冲前段)。
    //   FS/FE 短包固定 0x00/0x01, 不受本端口影响。
    input  wire [5:0]  i_dt,

    // ---------------- JPEG 字节流 (接 jpeg_encoder_top 的 m_valid/m_data/m_last)
    input  wire        s_tvalid,
    input  wire [7:0]  s_tdata,
    input  wire        s_tlast,       // 与最后一个有效字节同拍
    output wire        s_tready,

    // ---------------- D-PHY 发送侧
    output reg         hs_en,
    output reg  [31:0] hs_data,
    output reg         hs_last,

    // ---------------- 统计
    output reg  [31:0] frame_cnt,
    output reg  [31:0] packet_cnt,
    output reg  [31:0] byte_cnt
);

    localparam integer PW = PKT_BYTES;
    localparam integer WW = $clog2(PW);

    //==========================================================================
    //  ECC / CRC / 包头 (与 csi2_frame_tx 完全一致)
    //==========================================================================
    function [7:0] ecc8;
        input [23:0] d;
        reg   [7:0]  e;
        begin
            e[7] = 1'b0;
            e[6] = 1'b0;
            e[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[0]^d[1]^d[2]^d[3]^d[5]^d[6]^d[7];
            e[4] = d[20]^d[21]^d[22]^d[23]^d[8]^d[9]^d[0]^d[1]^d[2]^d[3]^d[4]^d[6]^d[7];
            e[3] = d[17]^d[18]^d[19]^d[23]^d[8]^d[9]^d[13]^d[14]^d[15]^d[3]^d[4]^d[5]^d[7];
            e[2] = d[16]^d[18]^d[19]^d[21]^d[22]^d[9]^d[11]^d[12]^d[15]^d[2]^d[4]^d[5]^d[6];
            e[1] = d[16]^d[17]^d[19]^d[20]^d[22]^d[8]^d[10]^d[12]^d[14]^d[1]^d[4]^d[5]^d[6]^d[7];
            e[0] = d[16]^d[17]^d[18]^d[20]^d[21]^d[23]^d[10]^d[11]^d[13]^d[0]^d[4]^d[5]^d[6]^d[7];
            ecc8 = e;
        end
    endfunction

    function [15:0] crc16_byte;
        input [15:0] cin;
        input [7:0]  b;
        reg   [15:0] c;
        integer i;
        begin
            c = cin ^ {8'h00, b};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0]) c = (c >> 1) ^ 16'h8408;
                else      c = c >> 1;
            end
            crc16_byte = c;
        end
    endfunction

    function [31:0] build_short_hdr;
        input [5:0]  dt;
        input [15:0] data16;
        reg   [7:0]  di;
        reg   [23:0] d24;
        begin
            di              = {VC, dt};
            d24             = {di, data16[7:0], data16[15:8]};
            build_short_hdr = {ecc8(d24), data16[15:8], data16[7:0], di};
        end
    endfunction

    function [31:0] build_long_hdr;
        input [5:0]  dt;
        input [15:0] wc16;
        reg   [7:0]  di;
        reg   [23:0] d24;
        begin
            di             = {VC, dt};
            d24            = {di, wc16[7:0], wc16[15:8]};
            build_long_hdr = {ecc8(d24), wc16[15:8], wc16[7:0], di};
        end
    endfunction

    //==========================================================================
    //  双 bank 缓冲
    //==========================================================================
    reg [7:0] pbuf [0:2*PW-1];

    // ---------------- 写侧 ----------------
    reg          wsel;          // 正在写的 bank
    reg [WW-1:0] wptr;
    reg [15:0]   wc;            // 本 bank 已收字节数

    // ★ pend_v 不能再当寄存器用 —— 写侧要置位、发侧要清零, 两个 always 块
    //   同时驱动同一个 reg 会被 TD 判成 HDL-8007 'constantly driven from
    //   multiple places' (iverilog 不报, 所以仿真一直是绿的)。
    //   改成指针握扌: d_wr 只由写侧翻, d_rd 只由发侧翻, pend_v 纯组合。
    reg          d_wr;
    reg          d_rd;
    wire         pend_v = (d_wr != d_rd);

    // 描述符 (只由写侧写, 发侧只读)
    reg          pend_bank;
    reg [15:0]   pend_wc;
    reg          pend_fe;       // 该 bank 内含帧尾

    // ---------------- 发侧 ----------------
    reg          tx_busy;
    reg          tx_bank;
    reg [15:0]   t_wc;
    reg          t_fe;
    reg          frame_started;

    localparam [3:0] S_IDLE = 4'd0;
    localparam [3:0] S_FS   = 4'd1;
    localparam [3:0] S_HDR  = 4'd3;
    localparam [3:0] S_PL   = 4'd4;
    localparam [3:0] S_CRC  = 4'd5;
    localparam [3:0] S_FE   = 4'd6;
    localparam [3:0] S_GAP  = 4'd7;

    reg [3:0]  state;
    reg [15:0] gap_cnt;
    reg [15:0] ridx;            // 本包内字节偏移
    reg [15:0] wcnt;            // 已发的 payload 拍数
    reg [15:0] words;           // 本包 payload 总拍数
    reg [15:0] crc;

    wire [31:0] fs_word = build_short_hdr(6'h00, frame_cnt[15:0]);
    wire [31:0] fe_word = build_short_hdr(6'h01, frame_cnt[15:0]);
    wire [31:0] lp_hdr  = build_long_hdr(i_dt, t_wc);

    // ★ 队列最多排 1 个 (描述符只有一组), 所以写侧只能在 pend_v=0 时写。
    //   这不影响吞吐: 发侧在 S_IDLE 一拍就把描述符取走, 写侧只停 1~2 拍;
    //   真正需要 259 拍的“发包”是并行在后台做的。
    assign s_tready = !pend_v && !(tx_busy && (tx_bank == wsel));

    // 一次取 4 字节 (越界补 0)
    wire [WW-1:0] ri0 = ridx[WW-1:0];
    wire [WW-1:0] ri1 = ridx[WW-1:0] + 1'b1;
    wire [WW-1:0] ri2 = ridx[WW-1:0] + 2'd2;
    wire [WW-1:0] ri3 = ridx[WW-1:0] + 2'd3;

    wire [31:0] pl_word = {
        (ridx + 16'd3 < t_wc) ? pbuf[{tx_bank, ri3}] : 8'h00,
        (ridx + 16'd2 < t_wc) ? pbuf[{tx_bank, ri2}] : 8'h00,
        (ridx + 16'd1 < t_wc) ? pbuf[{tx_bank, ri1}] : 8'h00,
        pbuf[{tx_bank, ri0}]
    };

    //==========================================================================
    //  写侧: 与状态机完全独立, 只有撞 bank 时才停
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wsel <= 1'b0; wptr <= {WW{1'b0}}; wc <= 16'd0;
            d_wr <= 1'b0; pend_bank <= 1'b0; pend_wc <= 16'd0; pend_fe <= 1'b0;
        end else if (!enable) begin
            wsel <= 1'b0; wptr <= {WW{1'b0}}; wc <= 16'd0;
            d_wr <= 1'b0; pend_bank <= 1'b0; pend_wc <= 16'd0; pend_fe <= 1'b0;
        end else if (s_tvalid && s_tready) begin
            pbuf[{wsel, wptr}] <= s_tdata;
            wptr <= wptr + 1'b1;
            wc   <= wc + 16'd1;

            if (s_tlast) begin
                // 帧尾: 立刻交出这个 (可能不满的) bank
                d_wr      <= ~d_wr;
                pend_bank <= wsel;
                pend_wc   <= wc + 16'd1;
                pend_fe   <= 1'b1;
                wsel      <= ~wsel;
                wptr      <= {WW{1'b0}};
                wc        <= 16'd0;
            end else if (wc == PKT_BYTES[15:0] - 16'd1) begin
                d_wr      <= ~d_wr;
                pend_bank <= wsel;
                pend_wc   <= PKT_BYTES[15:0];
                pend_fe   <= 1'b0;
                wsel      <= ~wsel;
                wptr      <= {WW{1'b0}};
                wc        <= 16'd0;
            end
        end
    end

    //==========================================================================
    //  发侧状态机
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            hs_en         <= 1'b0;
            hs_data       <= 32'd0;
            hs_last       <= 1'b0;
            gap_cnt       <= 16'd0;
            ridx          <= 16'd0;
            wcnt          <= 16'd0;
            words         <= 16'd0;
            crc           <= 16'hFFFF;
            tx_busy       <= 1'b0;
            tx_bank       <= 1'b0;
            d_rd          <= 1'b0;
            t_wc          <= 16'd0;
            t_fe          <= 1'b0;
            frame_started <= 1'b0;
            frame_cnt     <= 32'd0;
            packet_cnt    <= 32'd0;
            byte_cnt      <= 32'd0;
        end else if (!enable) begin
            state   <= S_IDLE;
            hs_en   <= 1'b0;
            hs_last <= 1'b0;
            tx_busy <= 1'b0;
            d_rd    <= 1'b0;
        end else begin
            hs_en   <= 1'b0;
            hs_last <= 1'b0;

            case (state)
            //------------------------------------------------------------------
            // 等一个攒满的 bank。取走的同时把 pend_v 清掉, 让写侧可以继续攒下一个。
            // (bank 的所有权在 tx_busy 期间由 tx_bank 保护, 写侧不会误写)
            S_IDLE: begin
                if (pend_v) begin
                    t_wc    <= pend_wc;
                    t_fe    <= pend_fe;
                    tx_bank <= pend_bank;
                    tx_busy <= 1'b1;
                    d_rd    <= d_wr;
                    words   <= (pend_wc + 16'd3) >> 2;
                    ridx    <= 16'd0;
                    wcnt    <= 16'd0;
                    crc     <= 16'hFFFF;
                    if (!frame_started) begin
                        frame_started <= 1'b1;
                        byte_cnt      <= 32'd0;
                        state         <= S_FS;
                    end else begin
                        state <= S_HDR;
                    end
                end
            end

            //------------------------------------------------------------------
            S_FS: begin
                hs_en   <= 1'b1;
                hs_data <= fs_word;
                hs_last <= 1'b1;
                state   <= S_HDR;
            end

            //------------------------------------------------------------------
            S_HDR: begin
                hs_en   <= 1'b1;
                hs_data <= lp_hdr;
                state   <= S_PL;
            end

            //------------------------------------------------------------------
            S_PL: begin
                hs_en   <= 1'b1;
                hs_data <= pl_word;
                crc     <= crc16_byte(
                             crc16_byte(
                               crc16_byte(
                                 crc16_byte(crc, pl_word[7:0]),
                                 pl_word[15:8]),
                               pl_word[23:16]),
                             pl_word[31:24]);
                ridx    <= ridx + 16'd4;
                wcnt    <= wcnt + 16'd1;
                if (wcnt == words - 16'd1) state <= S_CRC;
            end

            //------------------------------------------------------------------
            S_CRC: begin
                hs_en      <= 1'b1;
                hs_data    <= {16'h0000, crc};
                hs_last    <= 1'b1;
                packet_cnt <= packet_cnt + 32'd1;
                byte_cnt   <= byte_cnt + {16'd0, t_wc};
                tx_busy    <= 1'b0;
                if (t_fe) begin
                    state <= S_FE;
                end else begin
                    state <= S_IDLE;
                end
            end

            //------------------------------------------------------------------
            S_FE: begin
                hs_en         <= 1'b1;
                hs_data       <= fe_word;
                hs_last       <= 1'b1;
                frame_cnt     <= frame_cnt + 32'd1;
                gap_cnt       <= 16'd0;
                frame_started <= 1'b0;
                state         <= S_GAP;
            end

            //------------------------------------------------------------------
            S_GAP: begin
                if (gap_cnt >= GAP_FRAME) state <= S_IDLE;
                else                      gap_cnt <= gap_cnt + 16'd1;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
