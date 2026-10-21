/*===========================================================================
 * Filename     : jpeg_headers.v
 * Description  : 生成 JPEG 标记段 (SOI/APP0/DQT/SOF0/DHT/SOS)
 *
 *  字节内容来自 jpeg_hdr_rom.vh (由 tools/gen_jpeg_hdr_rom.py 生成),
 *  只有四处是运行时可变的:
 *      DQT 里 64 个亮度 Q (zigzag 序)
 *      DQT 里 64 个色度 Q (zigzag 序)
 *      SOF0 的 H、W
 *
 *  ★ DQT 要求 zigzag 序, 而 jpeg_qtable_ram 是自然序 (k*8+u) 存放,
 *    所以读地址必须过 jpeg_zigzag()。
 *
 *  ★ qtable_ram 的读口是寄存输出 (晚 1 拍), 所以地址要【提前一拍】摆:
 *       cnt == 24  -> 摆 zigzag(0) 的地址, 同时输出 Tq=0 字节
 *       cnt == 25  -> 数据已到, 输出 zigzag(0) 的 Q
 *    若不多摆这一拍, 第一个 Q 会是 0, 解出来的图整块发灰。
 *
 *  吞吐: 1 字节/拍, 共 607 拍 (相对整帧 190 万拍可忽略)
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_headers (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         i_start,        // 脉冲
    input  wire         i_lossless,     // 1 = 无损 (SOF3), 0 = 有损 (SOF0)
    input  wire [11:0]  i_width,
    input  wire [11:0]  i_height,

    // 量化表读口 (与 jpeg_qtable_ram 读口 A 共用; 或单独一个口)
    output reg  [6:0]   o_qt_idx,
    input  wire [7:0]   i_qt_data,

    output reg          o_valid,
    output reg  [7:0]   o_data,
    // ★ 下游能否接住本拍字节。接 CSI-2 后发包时会拉低, 不尊重就会丢掉
    //   一整段 header (实测少 138 字节)。
    input  wire         i_ready,
    output reg          o_done
);

    `undef JPEG_DEFS_VH
    `include "jpeg_defs.vh"
    `include "jpeg_hdr_rom.vh"
    `include "jpeg_hdr_ll.vh"

    //---------------------------------------------------------------- 布局常量
    // 有损 (SOF0): 607 字节, 含 DQT 两段 Q 表
    localparam integer HDR_LEN_L = 607;
    localparam integer OFF_QY_L  = 25;
    localparam integer OFF_QC_L  = 90;
    localparam integer OFF_H_L   = 159;
    localparam integer OFF_W_L   = 161;

    // 无损 (SOF3): 91 字节, 无 DQT
    localparam integer HDR_LEN_LL = 91;
    localparam integer OFF_H_LL   = 25;
    localparam integer OFF_W_LL   = 27;

    wire        ll = i_lossless;
    wire [9:0]  hdr_len = ll ? HDR_LEN_LL[9:0] : HDR_LEN_L[9:0];
    wire [9:0]  off_h   = ll ? OFF_H_LL[9:0]   : OFF_H_L[9:0];
    wire [9:0]  off_w   = ll ? OFF_W_LL[9:0]   : OFF_W_L[9:0];

    //---------------------------------------------------------------- 计数
    reg [9:0] cnt;
    reg       run;

    //---------------------------------------------------------------- 地址预取
    // 提前一拍: cnt 时刻摆的地址, 是 cnt+1 时刻要输出的那一位
    //
    //   cnt 24      输出 Tq=0,       摆 zigzag(0)   -> cnt 25 用
    //   cnt 25..87  输出亮 Q,        摆 zigzag(1..63)
    //   cnt 88      输出亮 Q(第 63 个), 摆 0 (空摆, 这一拍没有下一拍要用的亮度)
    //   cnt 89      输出 Tq=1,       摆 64          -> cnt 90 用
    //   cnt 90..152 输出色 Q,        摆 64+zigzag(1..63)
    //
    //  ⚠ 原来漏了 cnt=89 这一拍的空档: cnt 88 摆的 64 数据在 cnt 89 到达,
    //    但 cnt 89 输出的是 Tq=1 字节, 这个数据被丢掉; cnt 89 又摆了 65,
    //    结果色度第一个值变成 Q_CHR[1] (18 而不是 17), 整个 DQT 段错位。
    always @(*) begin
        if (!run)                                     o_qt_idx = 7'd0;
        else if (cnt == 10'd24)                       o_qt_idx = {1'b0, jpeg_zigzag(6'd0)};
        else if (cnt >= 10'd25 && cnt <= 10'd87)      o_qt_idx = {1'b0, jpeg_zigzag(cnt[5:0] - 6'd24)};
        else if (cnt == 10'd88)                       o_qt_idx = 7'd0;
        else if (cnt == 10'd89)                       o_qt_idx = 7'd64;
        else if (cnt >= 10'd90 && cnt <= 10'd152)     o_qt_idx = 7'd64 + {1'b0, jpeg_zigzag(cnt[5:0] - 6'd25)};
        else                                          o_qt_idx = 7'd0;
    end

    //---------------------------------------------------------------- 数据选择
    // H / W 是 16 位大端, 我们的尺寸 < 4096, 所以高字节是 [11:8]
    reg [7:0] d2;
    always @(*) begin
        if (!run) begin
            d2 = 8'd0;
        end else if (!ll) begin
            // ---- 有损 SOF0: 607 字节, 含两段 Q 表 ----
            if      (cnt >= 10'd25  && cnt <= 10'd88)  d2 = i_qt_data;   // 亮度 Q (zigzag 序)
            else if (cnt >= 10'd90  && cnt <= 10'd153) d2 = i_qt_data;   // 色度 Q
            else if (cnt == 10'd159)                   d2 = {4'h0, i_height[11:8]};
            else if (cnt == 10'd160)                   d2 = i_height[7:0];
            else if (cnt == 10'd161)                   d2 = {4'h0, i_width[11:8]};
            else if (cnt == 10'd162)                   d2 = i_width[7:0];
            else                                       d2 = jpeg_hdr_rom(cnt);
        end else begin
            // ---- 无损 SOF3: 91 字节, 无 DQT ----
            if      (cnt == 10'd25)                    d2 = {4'h0, i_height[11:8]};
            else if (cnt == 10'd26)                    d2 = i_height[7:0];
            else if (cnt == 10'd27)                    d2 = {4'h0, i_width[11:8]};
            else if (cnt == 10'd28)                    d2 = i_width[7:0];
            else                                       d2 = jpeg_hdr_ll(cnt);
        end
    end

    //---------------------------------------------------------------- 主流程
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 10'd0;
            run     <= 1'b0;
            o_valid <= 1'b0;
            o_data  <= 8'd0;
            o_done  <= 1'b0;
        end else begin
            // 只有握手成功才撤销 valid / 前进; 下游没接住时保持数据和 cnt 不动
            if (i_ready) begin
                o_valid <= 1'b0;
                o_done  <= 1'b0;
            end

            if (i_start) begin
                cnt <= 10'd0;
                run <= 1'b1;
            end else if (run && i_ready) begin
                o_valid <= 1'b1;
                o_data  <= d2;
                if (cnt == hdr_len - 10'd1) begin
                    // ★ 这里必须把 run 清掉, 下一拍 o_valid 才会回 0。
                    //   否则 o_valid 一直挂 1, 下游 mux 永远选头部, 熵编码字节
                    //   全被挡住 (实测: 文件里正文全是 0x00)
                    run    <= 1'b0;
                    o_done <= 1'b1;
                end else begin
                    cnt <= cnt + 10'd1;
                end
            end
        end
    end

endmodule
