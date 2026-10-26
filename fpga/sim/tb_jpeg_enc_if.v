/*===========================================================================
 * tb_jpeg_enc_if.v —— jpeg_enc_if 的逐字比对仿真
 *
 *  验证目标 (任何一条失败都说明 JPEG 支路会出废帧):
 *    1. 编码器收到的 32bit word 序列 == 源端 64bit word 的低/高半, 逐字一致
 *    2. 不丢字、不重字、不乱序 (全局自增序号比对)
 *    3. e_ready 随机反压时不破坏顺序
 *    4. 编码器比源慢时, st_ovf 必须置起来 (而不是静默丢字)
 *
 *  源侧字内容: {~cnt[31:0], cnt[31:0]}  -> 高/低半不同, 顺序颠倒会立刻被抓到
 *
 *  ⚠ 所有 $display 一律用 ASCII: 本机 PowerShell 控制台是 GBK,
 *    中文日志会变成乱码, 排查时反而误事。
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_enc_if;

    localparam integer FRAME_WORDS = 128;      // 每帧 64bit word 数 (128word = 512px)
    localparam integer NFRAME_A    = 6;        // 阶段 A/B 帧数

    // ---------------- 时钟 ----------------
    reg s_clk = 1'b0;
    reg e_clk = 1'b0;
    always #15.625 s_clk = ~s_clk;             // 32 MHz

    real e_half = 3.39;                        // 147.5MHz 半周期
    always #(e_half) e_clk = ~e_clk;

    reg s_rst_n = 1'b0;
    reg e_rst_n = 1'b0;

    // ---------------- 源侧 ----------------
    reg         s_valid = 1'b0;
    reg  [63:0] s_data  = 64'd0;
    reg         s_sof   = 1'b0;
    reg  [31:0] s_cnt   = 32'd0;               // 全局 word 序号
    integer     s_left  = 0;                   // 本阶段还要发多少 word
    integer     in_frame= 0;

    // ---------------- 编码器侧 ----------------
    wire        e_valid;
    wire [31:0] e_data;
    wire        e_ready;
    wire [15:0] st_ovf, st_word_lo, st_sof;
    wire [7:0]  o_level;

    // e_ready 控制: 0=恒 1, 1=1/4 随机丢弃, 2=恒 0 (卡死测试)
    integer     ready_mode = 0;
    reg  [3:0]  lfsr = 4'hA;
    always @(posedge e_clk) lfsr <= {lfsr[2:0], lfsr[3] ^ lfsr[2]};
    reg         ready_r = 1'b1;
    always @(posedge e_clk)
        ready_r <= (ready_mode == 0) ? 1'b1 :
                   (ready_mode == 2) ? 1'b0 : (lfsr[1:0] != 2'b00);
    assign e_ready = ready_r;

    jpeg_enc_if #(.AW(8)) dut (
        .s_clk      (s_clk    ),
        .s_rst_n    (s_rst_n  ),
        .s_valid    (s_valid  ),
        .s_data     (s_data   ),
        .s_sof      (s_sof    ),
        .e_clk      (e_clk    ),
        .e_rst_n    (e_rst_n  ),
        .e_valid    (e_valid  ),
        .e_data     (e_data   ),
        .e_ready    (e_ready  ),
        .st_ovf     (st_ovf   ),
        .st_word_lo (st_word_lo),
        .st_sof     (st_sof   ),
        .o_level    (o_level  )
    );

    // ---------------- 参考模型: 编码器侧逐拍比对 ----------------
    reg  [31:0] exp_cnt  = 32'd0;
    reg         exp_half = 1'b0;
    integer     err_cnt  = 0;
    integer     got_words= 0;
    reg         chk_en   = 1'b1;      // 阶段 C 预期丢字, 关掉字序比对

    always @(posedge e_clk) begin
        if (e_rst_n && chk_en && e_valid && e_ready) begin
            if (!exp_half) begin
                if (e_data !== exp_cnt) begin
                    if (err_cnt < 10)
                        $display("[ERR] lo  t=%0t got=%08x exp=%08x (word %0d)",
                                 $time, e_data, exp_cnt, exp_cnt);
                    err_cnt = err_cnt + 1;
                end
                exp_half = 1'b1;
            end else begin
                if (e_data !== ~exp_cnt) begin
                    if (err_cnt < 10)
                        $display("[ERR] hi  t=%0t got=%08x exp=%08x (word %0d)",
                                 $time, e_data, ~exp_cnt, exp_cnt);
                    err_cnt = err_cnt + 1;
                end
                exp_half = 1'b0;
                exp_cnt  = exp_cnt + 32'd1;
                got_words= got_words + 1;
            end
        end
    end

    // ---------------- 源侧驱动 ----------------
    //  连续灌 (s_valid 恒 1 直到本阶段 word 发完), 模拟 rgb_to_yuv422_quad 的连续流
    always @(posedge s_clk) begin
        if (!s_rst_n) begin
            s_valid <= 1'b0;
            s_sof   <= 1'b0;
        end else begin
            if (s_left > 0) begin
                s_valid <= 1'b1;
                s_data  <= {~s_cnt, s_cnt};
                s_sof   <= (in_frame == 0);
                s_cnt   <= s_cnt + 32'd1;
                if (in_frame == FRAME_WORDS-1) in_frame <= 0;
                else                           in_frame <= in_frame + 1;
                s_left <= s_left - 1;
            end else begin
                s_valid <= 1'b0;
                s_sof   <= 1'b0;
            end
        end
    end

    integer n_err_before;

    initial begin
        $dumpfile("tb_jpeg_enc_if.vcd");
        $dumpvars(0, tb_jpeg_enc_if);

        #200; s_rst_n = 1'b1; e_rst_n = 1'b1;
        #200;

        // ============ 阶段 A: e_ready 恒 1 ============
        ready_mode = 0;
        n_err_before = err_cnt;
        s_left = FRAME_WORDS * NFRAME_A;
        wait (s_left == 0);
        #2000;
        if (got_words != FRAME_WORDS * NFRAME_A) begin
            $display("[ERR] A: got_words=%0d exp=%0d", got_words, FRAME_WORDS*NFRAME_A);
            err_cnt = err_cnt + 1;
        end
        if (err_cnt != n_err_before) $display("[ERR] phase A failed");
        if (st_ovf != 16'd0) begin
            $display("[ERR] A: unexpected overflow st_ovf=%0d", st_ovf); err_cnt = err_cnt + 1;
        end
        $display("[A] words=%0d ovf=%0d sof=%0d level=%0d err=%0d",
                 got_words, st_ovf, st_sof, o_level, err_cnt);

        // ============ 阶段 B: e_ready 1/4 随机反压 ============
        ready_mode = 1;
        n_err_before = err_cnt;
        s_left = FRAME_WORDS * NFRAME_A;
        wait (s_left == 0);
        #20000;
        if (err_cnt != n_err_before) $display("[ERR] phase B failed");
        if (st_ovf != 16'd0) begin
            $display("[ERR] B: no overflow expected with depth-256 fifo, got st_ovf=%0d", st_ovf);
            err_cnt = err_cnt + 1;
        end
        $display("[B] words=%0d ovf=%0d sof=%0d err=%0d", got_words, st_ovf, st_sof, err_cnt);

        // ============ 阶段 C: 编码器远慢于源 -> 必须报溢出 ============
        chk_en     = 1'b0;
        ready_mode = 1;
        e_half     = 25.0;                 // e_clk -> 20MHz (远低于源 32MHz word 率)
        s_left     = FRAME_WORDS * 8;
        wait (s_left == 0);
        #2000;
        if (st_ovf == 16'd0) begin
            $display("[ERR] C: encoder far slower than source, st_ovf=0 (silent word loss!)");
            err_cnt = err_cnt + 1;
        end else begin
            $display("[C] overflow correctly reported st_ovf=%0d", st_ovf);
        end

        if (err_cnt == 0)
            $display("\n===== PASS: jpeg_enc_if word-exact (A/B) + overflow detect (C) =====");
        else
            $display("\n===== FAIL: err_cnt=%0d =====", err_cnt);
        $finish;
    end

    // 看门狗
    initial begin
        #5_000_000;
        $display("[ERR] timeout: sim did not finish within 5ms (possible handshake stall)");
        $finish;
    end

endmodule
