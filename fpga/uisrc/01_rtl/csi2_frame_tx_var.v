`timescale 1ns/1ps
//==============================================================================
//  csi2_frame_tx_var.v
//  CSI-2 可变长帧发送 (JPEG 码流专用, DT=0x18)
//
//  为什么需要这个模块
//  ------------------
//  现有的 csi2_frame_tx 是**定长**的: 每行一个 long packet, WC 由
//  I_h_active 算出, 行数由 I_v_active 决定。而 JPEG 一帧是 N 个字节的连续流,
//  既不知道每包多大, 也不知道总共几包 —— 所以必须新写一个"边收边打包"的版本。
//
//  关键约束: long packet 的 Word Count 写在**包头里**, 所以必须先把整包攒齐
//  才能发头。这里用单缓冲 + 反压:
//      攒包时 s_tready=1, 攒满 PKT_BYTES 后 s_tready=0 去发包。
//  JPEG 编码器的位打包端口有 bp_ready 反压能力, 所以停一下是安全的。
//
//  帧结构:
//      FS 短包(DT=0x00) -> [long packet(DT=0x18) ...] -> FE 短包(DT=0x01) -> 消隐
//  最后一包通常不满 PKT_BYTES, WC = 实际字节数; 不足 4 字节的部分补 0,
//  补出来的 0 **也计入 CRC**(CSI-2 校验是对实际发出去的 payload 算的)。
//  接收端靠 JPEG 的 EOI(FFD9) 判断真实长度, 填充字节不影响解码。
//
//  字节序沿用 csi2_frame_tx: hs_data[7:0] 先发, 包头一拍 4 字节,
//  payload 一拍 4 字节, 最后一拍低 16 位放 CRC 并拉 hs_last。
//==============================================================================
module csi2_frame_tx_var #(
    parameter integer PKT_BYTES = 1024,     // 每个 long packet 的目标载荷字节数 (4 的倍数)
    parameter integer GAP_FRAME = 200,      // FE 之后到下一帧 FS 的空闲拍数
    parameter [5:0]   DT        = 6'h18,    // 0x18 = JPEG
    parameter [1:0]   VC        = 2'b00
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

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

    localparam integer PW = PKT_BYTES;                 // 缓冲深度
    // 写指针位宽: PKT_BYTES 必须 >= 4 (综合/py 侧都会保证), 所以直接 $clog2
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
    //  包缓冲
    //==========================================================================
    reg [7:0] pbuf [0:PW-1];
    reg [WW-1:0] wptr;
    reg [15:0]   wc;            // 本包实际字节数
    reg [15:0]   words;         // 本包要发多少拍 (补齐到 4 字节)
    reg          frame_end;     // 收到 s_tlast (本帧最后一个包)
    reg [15:0]   pcnt;

    localparam [3:0] S_IDLE = 4'd0;
    localparam [3:0] S_FS   = 4'd1;
    localparam [3:0] S_COL  = 4'd2;
    localparam [3:0] S_HDR  = 4'd3;
    localparam [3:0] S_PL   = 4'd4;
    localparam [3:0] S_CRC  = 4'd5;
    localparam [3:0] S_FE   = 4'd6;
    localparam [3:0] S_GAP  = 4'd7;

    reg [3:0]  state;
    reg [15:0] gap_cnt;
    reg [31:0] word_idx;
    reg [15:0] crc;

    wire [31:0] fs_word = build_short_hdr(6'h00, frame_cnt[15:0]);
    wire [31:0] fe_word = build_short_hdr(6'h01, frame_cnt[15:0]);
    wire [31:0] lp_hdr  = build_long_hdr(DT, wc);

    // 发包时一次取 4 字节 (越界补 0)
    wire [31:0] pl_word = {
        (word_idx*4+3 < wc) ? pbuf[word_idx*4+3] : 8'h00,
        (word_idx*4+2 < wc) ? pbuf[word_idx*4+2] : 8'h00,
        (word_idx*4+1 < wc) ? pbuf[word_idx*4+1] : 8'h00,
        pbuf[word_idx*4]
    };

    // 收集期间一直 ready; S_IDLE 也 ready, 否则上位机"先等 ready 再给数据"
    // 的握手会和 S_IDLE 等 valid 形成死锁。S_IDLE 收到首字节时直接锁存。
    assign s_tready = (state == S_COL) || (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            wptr       <= {WW{1'b0}};
            wc         <= 16'd0;
            words      <= 16'd0;
            frame_end  <= 1'b0;
            pcnt       <= 16'd0;
            gap_cnt    <= 16'd0;
            word_idx   <= 32'd0;
            crc        <= 16'hFFFF;
            hs_en      <= 1'b0;
            hs_data    <= 32'd0;
            hs_last    <= 1'b0;
            frame_cnt  <= 32'd0;
            packet_cnt <= 32'd0;
            byte_cnt   <= 32'd0;
        end else if (!enable) begin
            state   <= S_IDLE;
            hs_en   <= 1'b0;
            hs_last <= 1'b0;
            wptr    <= {WW{1'b0}};
            wc      <= 16'd0;
        end else begin
            hs_en   <= 1'b0;
            hs_last <= 1'b0;

            case (state)
            //------------------------------------------------------------------
            // ★ 必须等真的有数据才发 FS。原来无条件进 S_FS, 结果一帧发完后
            //   立刻又开始下一帧, 空中多发一个 FS 短包 (实测多 4 字节)。
            S_IDLE: begin
                wptr      <= {WW{1'b0}};
                wc        <= 16'd0;
                frame_end <= 1'b0;
                if (s_tvalid) begin
                    // 首字节直接锁存进缓冲(这一拍 S_COL 还没开始, 不能丢)
                    pbuf[0]   <= s_tdata;
                    wptr      <= {{(WW-1){1'b0}}, 1'b1};
                    wc        <= 16'd1;
                    frame_end <= s_tlast;
                    state     <= S_FS;
                end
            end

            //------------------------------------------------------------------
            S_FS: begin
                hs_en    <= 1'b1;
                hs_data  <= fs_word;
                byte_cnt <= 32'd0;
                state    <= S_COL;
            end

            //------------------------------------------------------------------
            // 攒包。写满 PKT_BYTES 或收到帧尾就转去发送。
            S_COL: begin
                if (s_tvalid) begin
                    pbuf[wptr] <= s_tdata;
                    wptr      <= wptr + 1'b1;
                    wc        <= wc + 16'd1;
                    if (s_tlast) begin
                        // 帧尾: 立刻发这一个 (可能不满的) 包
                        frame_end <= 1'b1;
                        words     <= ((wc + 16'd4) >> 2);   // 含本拍, ceil(wc/4)
                        word_idx  <= 32'd0;
                        crc       <= 16'hFFFF;
                        state     <= S_HDR;
                    end else if (wc == PKT_BYTES[15:0] - 16'd1) begin
                        // 用 wc 判断而不是 wptr: wptr 的起点会因为首字节在 S_IDLE
                        // 先被锁存而与 wc 差 1。
                        words    <= PKT_BYTES[15:0] >> 2;
                        word_idx <= 32'd0;
                        crc      <= 16'hFFFF;
                        state    <= S_HDR;
                    end
                end
            end

            //------------------------------------------------------------------
            S_HDR: begin
                hs_en   <= 1'b1;
                hs_data <= lp_hdr;
                state   <= S_PL;
            end

            //------------------------------------------------------------------
            // 每拍发 4 字节, 同时把 CRC 累加上去 (补齐的 0 也计入)
            S_PL: begin
                hs_en    <= 1'b1;
                hs_data  <= pl_word;
                crc      <= crc16_byte(
                              crc16_byte(
                                crc16_byte(
                                  crc16_byte(crc, pl_word[7:0]),
                                  pl_word[15:8]),
                                pl_word[23:16]),
                              pl_word[31:24]);
                word_idx <= word_idx + 32'd1;
                if (word_idx == words - 1) begin
                    state <= S_CRC;
                end
            end

            //------------------------------------------------------------------
            S_CRC: begin
                hs_en      <= 1'b1;
                hs_data    <= {16'h0000, crc};
                hs_last    <= 1'b1;
                packet_cnt <= packet_cnt + 32'd1;
                byte_cnt   <= byte_cnt + {16'd0, wc};
                wptr       <= {WW{1'b0}};
                wc         <= 16'd0;
                // 本帧还有数据 -> 接着攒下一包; 否则收尾
                if (frame_end) begin
                    frame_end <= 1'b0;
                    state     <= S_FE;
                end else begin
                    state     <= S_COL;
                end
            end

            //------------------------------------------------------------------
            S_FE: begin
                hs_en     <= 1'b1;
                hs_data   <= fe_word;
                frame_cnt <= frame_cnt + 32'd1;
                gap_cnt   <= 16'd0;
                state     <= S_GAP;
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
