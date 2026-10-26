/*===========================================================================
 * tb_jpeg_byte_bridge.v —— 码流跨时钟桥逐字节比对
 *
 *  写侧 300MHz, 读侧 150MHz, 读侧 ready 随机反压
 *  校验: 字节序列与 {last} 标记逐字节一致, 不丢不重不乱序
 *
 *  ⚠ 源必须**组合**驱动 (w_data = sent), 不能写 w_data <= sent:
 *    那样在 w_ready 拉低期间 w_data 会一直是旧的 sent, ready 恢复后
 *    同一个字节会被写两遍 —— 本 TB 第一版就是这样, 表现为首字节 00 重复。
 *    (当时误以为是 RTL bug, 实际是激励的经典的 off-by-one。)
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_byte_bridge;

    reg w_clk = 1'b0, r_clk = 1'b0;
    always #1.665 w_clk = ~w_clk;              // ~300MHz
    always #3.33  r_clk = ~r_clk;              // ~150MHz

    reg w_rst_n = 1'b0, r_rst_n = 1'b0;

    // ---------------- 源 (组合驱动) ----------------
    localparam integer NSEND = 3000;
    integer sent = 0;
    wire        w_valid = (sent < NSEND);
    wire [7:0]  w_data  = sent[7:0];
    wire        w_last  = ((sent % 100) == 99);
    wire        w_ready;

    always @(posedge w_clk) begin
        if (!w_rst_n)                    sent <= 0;
        else if (w_valid && w_ready)     sent <= sent + 1;
    end

    // ---------------- 读侧 ----------------
    wire        r_valid, r_last;
    wire [7:0]  r_data;
    reg         r_ready = 1'b1;

    wire [15:0] st_bp;
    wire [7:0]  o_level;

    jpeg_byte_bridge #(.AW(8)) dut (
        .w_clk (w_clk), .w_rst_n (w_rst_n),
        .w_valid(w_valid), .w_data(w_data), .w_last(w_last), .w_ready(w_ready),
        .r_clk (r_clk), .r_rst_n (r_rst_n),
        .r_valid(r_valid), .r_data(r_data), .r_last(r_last), .r_ready(r_ready),
        .st_bp(st_bp), .o_level(o_level)
    );

    // ready: 1/3 概率反压
    reg [3:0] lfsr = 4'h5;
    always @(posedge r_clk) begin
        lfsr    <= {lfsr[2:0], lfsr[3] ^ lfsr[2]};
        r_ready <= (lfsr[1:0] != 2'b00);
    end

    // ---------------- 参考模型 ----------------
    integer exp_b = 0, err = 0, got = 0;
    always @(posedge r_clk) begin
        if (r_rst_n && r_valid && r_ready) begin
            if (r_data !== (exp_b & 8'hFF)) begin
                if (err < 8) $display("[ERR] byte %0d: got=%02x exp=%02x", exp_b, r_data, exp_b & 8'hFF);
                err = err + 1;
            end
            if (r_last !== ((exp_b % 100) == 99)) begin
                if (err < 8) $display("[ERR] last @%0d: got=%b", exp_b, r_last);
                err = err + 1;
            end
            exp_b = exp_b + 1;
            got   = got + 1;
        end
    end

    initial begin
        #20; w_rst_n = 1'b1; r_rst_n = 1'b1;
        wait (sent == NSEND);
        #20000;
        $display("sent=%0d got=%0d backpressure=%0d err=%0d", sent, got, st_bp, err);
        if (err == 0 && got == NSEND)
            $display("\n===== PASS: jpeg_byte_bridge byte-exact 300MHz->150MHz =====");
        else
            $display("\n===== FAIL =====");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT sent=%0d got=%0d", sent, got);
        $finish;
    end

endmodule
