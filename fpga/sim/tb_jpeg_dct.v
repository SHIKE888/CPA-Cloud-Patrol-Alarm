/*===========================================================================
 * tb_jpeg_dct.v —— 把 jpeg_dct2d 的输出与 tools/jpeg_ref.py 逐位比对
 *
 *  向量文件由 tools/gen_dct_vec.py 生成:
 *      每块 128 行: 前 64 = 输入 (16bit 二补码), 后 64 = 期望系数 (18bit 二补码)
 *      输入顺序 blk[v*8+u]; 期望顺序 F[k*8+v]
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_dct;

    reg         clk;
    reg         rst_n;

    reg         start;
    reg         valid;
    reg [127:0] row;

    wire        ready;
    wire        busy;
    wire        o_valid;
    wire [143:0] o_col;
    wire        o_done;

    jpeg_dct2d #(.NENG(8)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_start (start),
        .i_valid (valid),
        .i_row   (row),
        .i_ready (ready),
        .o_busy  (busy),
        .o_valid (o_valid),
        .o_col   (o_col),
        .o_done  (o_done)
    );

    // 16 块 x 128 个数
    reg [31:0] mem [0:2047];

    integer n, r, c, t;
    integer errors;
    integer blocks;
    reg signed [17:0] got;
    reg [31:0]        exp;

    initial clk = 1'b0;
    always #3.3 clk = ~clk;          // ~150MHz

    initial begin
        $readmemh("dct_vec.hex", mem);

        rst_n = 1'b0;
        start = 1'b0;
        valid = 1'b0;
        row   = 128'd0;
        errors = 0;
        blocks = 16;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        for (n = 0; n < blocks; n = n + 1) begin

            //---------------- 喂 8 行 (第 1 拍带 start)
            for (r = 0; r < 8; r = r + 1) begin
                @(negedge clk);
                start = (r == 0);
                valid = 1'b1;
                for (c = 0; c < 8; c = c + 1)
                    row[c*16 +: 16] = mem[n*128 + r*8 + c][15:0];
            end
            @(negedge clk);
            start = 1'b0;
            valid = 1'b0;
            row   = 128'd0;

            //---------------- 收 8 拍
            for (t = 0; t < 8; t = t + 1) begin
                @(posedge clk);
                #1;
                while (!o_valid) begin
                    @(posedge clk);
                    #1;
                end
                for (c = 0; c < 8; c = c + 1) begin
                    got = o_col[c*18 +: 18];
                    exp = mem[n*128 + 64 + c*8 + t];
                    if (got !== exp[17:0]) begin
                        errors = errors + 1;
                        if (errors <= 20)
                            $display("MISMATCH blk=%0d F[%0d][%0d] got=%0d (0x%05h) exp=%0d (0x%05h)",
                                     n, c, t, got, got, exp[17:0], exp[17:0]);
                    end
                end
                @(negedge clk);
            end

            // 等 DCT 回 IDLE
            while (!ready) begin
                @(posedge clk);
                #1;
            end
        end

        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("DCT PASS: %0d blocks x 64 coeffs all match jpeg_ref.py", blocks);
        else
            $display("DCT FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
