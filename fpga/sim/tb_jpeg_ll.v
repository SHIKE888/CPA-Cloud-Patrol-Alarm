/*===========================================================================
 * tb_jpeg_ll.v —— 无损模式 (SOF3) 端到端仿真
 *
 *  headers(i_lossless=1) -> bitpack
 *  jpeg_lossless_enc     -> bitpack
 *  帧尾 FF D9
 *
 *  尺寸由 tools/gen_jpeg_ll_e2e.py 生成的 jpeg_sim_cfg.vh 提供
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_ll;

`include "jpeg_sim_cfg.vh"

    parameter integer W = `SIM_W;
    parameter integer H = `SIM_H;

    localparam integer NWORD = (W / 2) * H;

    reg         clk, rst_n;

    // 输入
    reg         s_valid;
    reg  [31:0] s_data;
    wire        s_ready;

    // 输出
    wire        bp_ready;      // bitpack 反压 (被 lossless_enc 引用)

    //--------------------------------------------------------------- headers
    reg         hdr_start;
    wire        hdr_valid;
    wire [7:0]  hdr_data;
    wire        hdr_done;
    wire [6:0]  hdr_qidx;

    jpeg_headers u_hdr (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_start    (hdr_start),
        .i_lossless (1'b1),
        .i_width    (W[11:0]),
        .i_height   (H[11:0]),
        .o_qt_idx   (hdr_qidx),
        .i_qt_data  (8'd0),
        .o_valid    (hdr_valid),
        .o_data     (hdr_data),
        .o_done     (hdr_done)
    );

    //--------------------------------------------------------------- 无损编码器
    reg         ll_start;
    wire        ll_ovalid;
    wire [31:0] ll_code;
    wire [5:0]  ll_len;
    wire        ll_done;
    wire [31:0] ll_cnt;

    jpeg_lossless_enc #(.W(W)) u_ll (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_start     (ll_start),
        .i_valid     (s_valid),
        .i_data      (s_data),
        .i_ready     (s_ready),
        .o_valid     (ll_ovalid),
        .o_code      (ll_code),
        .o_len       (ll_len),
        .i_out_ready (bp_ready),
        .o_done      (ll_done),
        .o_sample_cnt(ll_cnt)
    );

    //--------------------------------------------------------------- 位打包
    reg         bp_flush;
    wire        bp_valid;
    wire [7:0]  bp_data;
    wire [31:0] bp_cnt;

    jpeg_bitpack u_bp (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_flush    (bp_flush),
        .i_valid    (ll_ovalid),
        .i_code     (ll_code),
        .i_len      (ll_len),
        .i_ready    (bp_ready),
        .o_valid    (bp_valid),
        .o_data     (bp_data),
        .o_byte_cnt (bp_cnt)
    );

    //--------------------------------------------------------------- 帧尾 (FF D9)
    reg eoi_ph;        // 1 = 正在输出 EOI
    reg eoi_ff;        // 1 = 本拍输出 FF, 0 = 输出 D9

    //--------------------------------------------------------------- 时钟
    initial clk = 1'b0;
    always #3.3 clk = ~clk;

    //--------------------------------------------------------------- 输入 / 输出
    integer fin, frc;
    integer fd, nout;
    reg [31:0] vword;

    initial begin
        nout = 0;
        fd = $fopen("rtl.jpg", "wb");
        forever begin
            @(posedge clk);
            #1;
            if (hdr_valid) begin
                $fwrite(fd, "%c", hdr_data); nout = nout + 1;
            end else if (bp_valid) begin
                $fwrite(fd, "%c", bp_data);  nout = nout + 1;
            end else if (eoi_ph) begin
                $fwrite(fd, "%c", eoi_ff ? 8'hFF : 8'hD9); nout = nout + 1;
            end
        end
    end

    integer rows_done;
    integer i;
    reg     hdr_sent;

    // 前 16 个符号 (调试)
    integer sym;
    initial sym = 0;
    always @(posedge clk) begin
        if (ll_ovalid && sym < 16) begin
            $display("SYM%0d len=%0d code=%0d", sym, ll_len, ll_code);
            sym = sym + 1;
        end
    end

    // 预测器输入 (调试)
    integer pk;
    initial pk = 0;
    always @(posedge clk) begin
        if (u_ll.state == 2'd1 && u_ll.step == 2'd0 && pk < 6) begin
            $display("PRED%0d col=%0d a=%0d b=%0d c=%0d pv=%0d px=%0d d=%0d",
                     pk, u_ll.col, u_ll.lf_y1, u_ll.up_y0, u_ll.upl_y1,
                     u_ll.pv, u_ll.px, $signed(u_ll.diff));
            pk = pk + 1;
        end
    end

    always @(posedge clk) begin
        if (ll_done) rows_done = rows_done + 1;
    end

    initial begin
        rst_n     = 1'b0;
        s_valid   = 1'b0;
        s_data    = 32'd0;
        hdr_start = 1'b0;
        ll_start  = 1'b0;
        bp_flush  = 1'b0;
        eoi_ph    = 1'b0;
        eoi_ff    = 1'b0;
        rows_done = 0;
        hdr_sent  = 1'b0;

        fin = $fopen("jpeg_in.hex", "r");
        if (fin == 0) begin
            $display("ERROR: cannot open jpeg_in.hex");
            $finish;
        end

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // 1) 输出无损头部
        @(negedge clk); hdr_start = 1'b1;
        @(negedge clk); hdr_start = 1'b0;
        wait (hdr_done == 1'b1);
        repeat (3) @(negedge clk);

        // 2) 复位预测器并喂数据
        @(negedge clk); ll_start = 1'b1;
        @(negedge clk); ll_start = 1'b0;

        for (i = 0; i < NWORD; i = i + 1) begin
            @(negedge clk);
            frc = $fscanf(fin, "%h\n", vword);
            s_valid = 1'b1;
            s_data  = vword;
            #1;
            while (!s_ready) begin
                @(negedge clk);
                #1;
            end
        end
        @(negedge clk);
        s_valid = 1'b0;
        $fclose(fin);

        // 3) 等最后一行编码完, flush, 再发 EOI
        wait (rows_done >= H);
        repeat (10) @(negedge clk);
        @(negedge clk); bp_flush = 1'b1;
        @(negedge clk); bp_flush = 1'b0;
        repeat (6) @(negedge clk);
        @(negedge clk); eoi_ph = 1'b1; eoi_ff = 1'b1;
        @(negedge clk);                eoi_ff = 1'b0;
        @(negedge clk); eoi_ph = 1'b0;
        repeat (4) @(negedge clk);

        $fclose(fd);
        $display("RTL_LL: %0d bytes, rows=%0d, samples=%0d, bp=%0d",
                 nout, rows_done, ll_cnt, bp_cnt);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT: %0d bytes rows=%0d", nout, rows_done);
        $fclose(fd);
        $finish;
    end

endmodule
