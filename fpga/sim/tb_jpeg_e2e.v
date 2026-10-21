/*===========================================================================
 * tb_jpeg_e2e.v —— JPEG 编码器端到端仿真
 *
 *  1. 从 jpeg_in.hex 读 YUV422, 按行扫进 jpeg_encoder_top
 *  2. 收集输出的 JPEG 字节流到 rtl.jpg
 *  3. 用 tools/cmp_jpeg.py 与 ref.jpg 逐字节比对 (或直接跑 cmp_jpeg.py)
 *
 *  尺寸由 tb 顶部的 W/H 决定, 必须与 gen_jpeg_e2e.py 的参数一致
 *===========================================================================*/
`timescale 1ns / 1ps

module tb_jpeg_e2e;

    localparam integer W = 64;
    localparam integer H = 16;

    reg         clk;
    reg         rst_n;

    reg         s_valid;
    reg  [31:0] s_data;
    wire        s_ready;

    wire        m_valid;
    wire [7:0]  m_data;
    wire        m_last;

    wire [6:0]  qt_idx_a, qt_idx_b;
    wire [7:0]  qt_a, qt_b;

    wire [23:0] st_bytes;
    wire        st_busy, st_done;
    wire [31:0] st_cnt;

    jpeg_encoder_top #(.W(W), .H(H)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_en         (1'b1),
        .i_soft_rst   (1'b0),
        .i_width      (W[11:0]),
        .i_height     (H[11:0]),
        .o_qt_idx_a   (qt_idx_a),
        .i_qt_data_a  (qt_a),
        .o_qt_idx_b   (qt_idx_b),
        .i_qt_data_b  (qt_b),
        .s_valid      (s_valid),
        .s_data       (s_data),
        .s_ready      (s_ready),
        .m_valid      (m_valid),
        .m_data       (m_data),
        .m_last       (m_last),
        .st_frame_bytes(st_bytes),
        .st_busy      (st_busy),
        .st_done      (st_done),
        .st_frame_cnt (st_cnt)
    );

    // 量化表 (复位即装 Annex K.1 标准表)
    jpeg_qtable_ram u_qt (
        .I_clk      (clk),
        .I_rst_n    (rst_n),
        .I_wr_en    (1'b0),
        .I_wr_addr  (8'd0),
        .I_wr_data  (8'd0),
        .I_rd_idx_a (qt_idx_a),
        .O_rd_data_a(qt_a),
        .I_rd_idx_b (qt_idx_b),
        .O_rd_data_b(qt_b)
    );

    //--------------------------------------------------------------- 时钟
    initial clk = 1'b0;
    always #3.3 clk = ~clk;         // ~150MHz

    //--------------------------------------------------------------- 输入向量
    reg [31:0] mem [0:65535];
    integer nwords;
    integer i;
    integer fd;
    integer nout;

    initial begin
        nwords = (W / 2) * H;
        $readmemh("jpeg_in.hex", mem);
    end

    //--------------------------------------------------------------- 输出收集
    initial begin
        nout = 0;
        fd = $fopen("rtl.jpg", "wb");
        forever begin
            @(posedge clk);
            #1;
            if (m_valid) begin
                $fwrite(fd, "%c", m_data);
                nout = nout + 1;
            end
        end
    end

    //--------------------------------------------------------------- 主流程
    initial begin
        rst_n   = 1'b0;
        s_valid = 1'b0;
        s_data  = 32'd0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // 按行扫描喂
        for (i = 0; i < nwords; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = mem[i];
        end
        @(negedge clk);
        s_valid = 1'b0;

        // 等帧结束
        wait (st_done == 1'b1);
        repeat (10) @(posedge clk);

        $fclose(fd);
        $display("RTL: %0d bytes output, st_frame_bytes=%0d, frames=%0d",
                 nout, st_bytes, st_cnt);
        $finish;
    end

    //--------------------------------------------------------------- 超时
    initial begin
        #20_000_000;
        $display("TIMEOUT: only %0d bytes", nout);
        $fclose(fd);
        $finish;
    end

    //--------------------------------------------------------------- 探针 (调试)
    integer hcnt;
    initial hcnt = 0;
    always @(posedge clk) begin
        if (dut.huff_valid && hcnt < 10) begin
            $display("HUFF #%0d state=%0d kk=%0d run=%0d rd=%0d code=%08x len=%0d",
                     hcnt, dut.u_huff.state, dut.u_huff.kk, dut.u_huff.run,
                     dut.u_huff.o_rd_idx, dut.huff_code, dut.huff_len);
            hcnt = hcnt + 1;
        end
    end

    // 第一个块的量化系数 (zigzag 序), 与 Python 参考比对
    integer z;
    initial begin
        wait (dut.huff_start == 1'b1);
        #1;
        $write("QZZ:");
        for (z = 0; z < 16; z = z + 1)
            $write(" %0d", $signed(dut.u_quant.qzz[z]));
        $write("\n");
    end

    initial begin
        wait (st_done == 1'b1);
        $display("PROBE rz_y[0..3]=%0d %0d %0d %0d  rz_c[0]=%0d",
                 dut.u_quant.rz_y[0], dut.u_quant.rz_y[1],
                 dut.u_quant.rz_y[2], dut.u_quant.rz_y[3],
                 dut.u_quant.rz_c[0]);
        $display("PROBE bp_cnt=%0d", dut.bp_cnt);
    end

    initial begin
        #15_000_000;
        $display("STUCK tstate=%0d mx=%0d my=%0d blk=%0d rc=%0d | n=%0d acc=%016x pend=%b bpv=%b | huff st=%0d kk=%0d run=%0d ov=%b ilen=%0d ir=%b | nout=%0d",
                 dut.tstate, dut.mx_reg, dut.my, dut.blk, dut.rc,
                 dut.u_bitpack.n, dut.u_bitpack.acc, dut.u_bitpack.pend_00, dut.bp_valid,
                 dut.u_huff.state, dut.u_huff.kk, dut.u_huff.run,
                 dut.u_huff.o_valid, dut.huff_len, dut.bp_ready, nout);
        $finish;
    end

endmodule
