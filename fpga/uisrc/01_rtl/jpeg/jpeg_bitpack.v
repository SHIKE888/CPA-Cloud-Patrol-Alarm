/*===========================================================================
 * Filename     : jpeg_bitpack.v
 * Description  : JPEG 熵编码位打包 (含 0xFF -> 0xFF 00 字节填充)
 *
 *  参考实现 (jpeg_ref.py BitWriter):
 *      acc = (acc << len) | code
 *      n  += len
 *      while n >= 8: 取最高 8 位输出; 若 == 0xFF 再补一个 0x00
 *      flush: 用 1 补齐到字节边界
 *
 *  ★ 为什么 acc 要 40 位, 而不是 32 位:
 *      熵编码器把「霍夫曼码字 + 附加位」合并成一次 put, 最长 16 + 11 = 27 位。
 *      若 acc 只有 32 位, 残留 n 最多 7 位, 7+27 = 34 > 32 会溢出。
 *      40 位时 7 + 27 = 34 <= 40, 保证 put 永远不会被反压 ——
 *      这直接把每个符号从「2 拍(码字+附加位)」降到「1 拍」。
 *      1080p 每 MCU 约 150 个符号, 若每符号 2 拍就是 300 拍, 60fps 的
 *      152 拍预算根本不够; 1 拍/符号才落在预算内。
 *
 *  吞吐: 接收 1 put/拍; 输出 1 字节/拍 (0xFF 时会插一个 0x00, 占额外 1 拍)
 *===========================================================================*/
`timescale 1ns / 1ps

module jpeg_bitpack (
    input  wire        clk,
    input  wire        rst_n,

    // 一帧结束: 用 1 补齐剩余位并输出
    input  wire        i_flush,

    // 一次 put (码字 + 附加位已在上游合并)
    input  wire        i_valid,
    input  wire [31:0] i_code,
    input  wire [5:0]  i_len,        // 1..32
    output wire        i_ready,      // 累加器是否有余量接收本次 put

    // 字节流输出
    output reg         o_valid,
    output reg  [7:0]  o_data,
    input  wire        o_ready,         // 下游能接住这拍字节 (0 时冻结)

    output reg  [31:0] o_byte_cnt   // 本帧已输出字节数 (不含头部)
);

    reg [63:0] acc;
    reg [6:0]  n;
    reg        pend_00;             // 上一字节是 0xFF, 本拍必须补 0x00

    //--------------------------------------------------------------- put (组合)
    //
    //  ★ acc 是【左对齐】的位缓冲: 有效位在 acc[39 : 40-n], MSB 是最早要输出的位。
    //    插入 len 位新数据, 应该拼在已有有效位的【后面】(低地址), 所以是
    //        acc_p = acc | (code << (40 - n - len))
    //    而不是 (acc >> len) | (code << (40-len)) ——
    //    后者会把旧数据往低位搬, 导致输出的字节顺序错乱:
    //    实测 "d9 4b d6" 变成了 "d9 bd 64"。
    // ★ do_put 是【唯一】的接收条件。之前把 n_p 写成
    //     (i_len == 0) ? n : n + i_len
    //   在 i_valid=0 (符号已发完) 时 i_len 会【残留上一个符号的长度】,
    //   于是 n_p 被虚高, 而 has_byte 分支又用 n_p-8 回写 n ——
    //   空闲拍里 n 不减反增 (实测从 45 涨到 115), acc 直接溢出, 整帧葬送。
    wire        do_put = i_valid && i_ready && (i_len != 6'd0);
    wire [63:0] acc_p  = do_put
                       ? (acc | ({32'd0, i_code} << (7'd64 - n - {1'b0, i_len})))
                       : acc;
    wire [6:0]  n_p    = do_put ? (n + {1'b0, i_len}) : n;

    // 背压: 只按累加器容量判断, 【不能】把 pend_00 算进去。
    //   原因: huff 在拍 N 用 i_ready(N) 决定是否发某个符号; 若拍 N+1 因为
    //   要插填充字节而把 i_ready 拉低, 那个符号就被静默丢掉了 ——
    //   表现为熵字节数比参考少 1 字节, 之后全盘错位。
    //   pend_00 拍照常吸收数据, 只是不消耗 acc, 下一拍正常输出。
    assign i_ready = ((n + {1'b0, i_len}) <= 7'd64);

    //--------------------------------------------------------------- flush 补齐
    // 把高 n 位左移到高 8 位, 低位补 1
    wire [7:0]  fl_mask = (n == 7'd0) ? 8'hFF
                        : (8'hFF >> n[2:0]);          // (1<<(8-n))-1
    wire [7:0]  fl_byte = acc[63:56] | fl_mask;

    //--------------------------------------------------------------- 输出选择
    wire        has_byte = (n_p >= 7'd8);
    wire [7:0]  o_byte   = acc_p[63:56];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc        <= 64'd0;
            n          <= 7'd0;
            pend_00    <= 1'b0;
            o_valid    <= 1'b0;
            o_data     <= 8'd0;
            o_byte_cnt <= 32'd0;
        end else if (!o_valid || o_ready) begin
            // ★ 2026-10-21 加输出握手: 下游(CSI-2 发包时会停 200+ 拍)没接住时
            //   整个打包器冻结 (acc/n/o_data/o_valid 全部保持), 不会丢字节。
            //   原来 o_valid 是 1 拍脉冲且无 ready, 输出接任何带反压的模块都会丢数据。
            o_valid <= 1'b0;

            if (pend_00) begin
                // 必须先把填充字节吐出去; 本拍 i_ready 为低, do_put 不会成立
                if (do_put) begin
                    acc <= acc_p;
                    n   <= n_p;
                end
                o_data  <= 8'h00;
                o_valid <= 1'b1;
                pend_00 <= 1'b0;
                o_byte_cnt <= o_byte_cnt + 32'd1;
            end
            else if (i_flush) begin
                if (n != 7'd0) begin
                    o_data  <= fl_byte;
                    o_valid <= 1'b1;
                    o_byte_cnt <= o_byte_cnt + 32'd1;
                    if (fl_byte == 8'hFF) begin
                        pend_00 <= 1'b1;
                    end
                end
                acc <= 64'd0;
                n   <= 7'd0;
            end
            else begin
                if (do_put) begin
                    acc <= acc_p;
                    n   <= n_p;
                end

                if (has_byte) begin
                    o_data  <= o_byte;
                    o_valid <= 1'b1;
                    o_byte_cnt <= o_byte_cnt + 32'd1;
                    pend_00 <= (o_byte == 8'hFF);
                    // 消耗 8 位
                    acc <= acc_p << 8;
                    n   <= n_p - 7'd8;
                end
            end
        end
    end

endmodule
