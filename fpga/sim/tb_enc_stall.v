`timescale 1ns/1ps
//==============================================================================
//  tb_enc_stall.v
//  只测「编码器 + 反压」: 收集 m_valid/m_data 字节流, m_ready 用人为图案
//  停/放, 和参考 jpg 逐字节比。用来判定丢字节是编码器侧还是 CSI-2 TX 侧。
//==============================================================================
module tb_enc_stall;

    parameter integer W = 320;
    parameter integer H = 40;
    parameter integer NWORD  = W*H/2;
    integer STALL = 40;   // 每隔多少拍停一次 (0 = 不停)
    integer SLEN  = 40;   // 每次停多少拍

    reg clk = 0, rst_n = 0;
    reg  [31:0] s_data  = 0;
    reg         s_valid = 0;
    wire        s_ready;
    wire        m_valid;
    wire [7:0]  m_data;
    wire        m_last;
    reg         m_ready = 1;

    wire [23:0] st_bytes;
    wire        st_busy, st_done;

    always #5 clk = ~clk;

    wire [6:0] qt_a, qt_b;
    wire [7:0] qta, qtb;
    jpeg_qtable_ram u_qt (
        .I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
        .I_wr_addr(8'd0), .I_wr_data(8'd0),
        .I_rd_idx_a(qt_a), .O_rd_data_a(), .O_rd_data_a_asyn(qta),
        .I_rd_idx_b(qt_b), .O_rd_data_b(qtb)
    );

    jpeg_encoder_top #(.W(W), .H(H)) dut (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_soft_rst(1'b0), .i_lossless(1'b0),
        .i_width(W[11:0]), .i_height(H[11:0]), .i_rst_int(16'd0),
        .o_qt_idx_a(qt_a), .i_qt_data_a(qta),
        .o_qt_idx_b(qt_b), .i_qt_data_b(qtb),
        .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
        .m_valid(m_valid), .m_data(m_data), .m_last(m_last), .m_ready(m_ready),
        .st_frame_bytes(st_bytes), .st_busy(st_busy), .st_done(st_done),
        .st_frame_cnt()
    );

    //-------------------------------------------- 反压图案
    integer tick = 0;
    always @(posedge clk) begin
        tick = tick + 1;
        if (STALL > 0)
            m_ready <= !((tick % STALL) < SLEN);   // 每 STALL 拍里停 SLEN 拍
        else
            m_ready <= 1'b1;
    end

    //-------------------------------------------- 收集
    reg [7:0] got [0:2_000_000];
    integer   ngot = 0;
    always @(posedge clk) begin
        if (m_valid && m_ready) begin
            got[ngot] = m_data;
            ngot = ngot + 1;
        end
    end

    //-------------------------------------------- 主机
    integer fin, frc, i, err;
    reg [31:0] vword;
    reg [7:0]  refb [0:2_000_000];
    integer    nref;

    initial begin
        if (!$value$plusargs("STALL=%d", STALL)) STALL = 40;
        if (!$value$plusargs("SLEN=%d",  SLEN))  SLEN  = 40;
        fin = $fopen("jpeg_in.hex", "r");
        if (fin == 0) begin $display("cannot open jpeg_in.hex"); $finish; end
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        for (i = 0; i < NWORD; i = i + 1) begin
            while (!s_ready) @(posedge clk);
            frc     = $fscanf(fin, "%h\n", vword);
            s_valid = 1'b1;
            s_data  = vword;
            @(posedge clk);
        end
        s_valid = 1'b0;
        $fclose(fin);

        i = 0;
        while (st_done === 1'b0 && i < 3_000_000) begin @(posedge clk); i = i + 1; end
        repeat (4) @(posedge clk);

        // 读参考
        fin = $fopen("ref.jpg", "rb");
        nref = 0;
        while (!$feof(fin)) begin
            frc = $fgetc(fin);
            if (frc >= 0) begin refb[nref] = frc[7:0]; nref = nref + 1; end
        end
        $fclose(fin);

        $display("STALL=%0d OUT=%0d REF=%0d", STALL, ngot, nref);
        $write("GOT:");
        for (i = 30; i < 70 && i < ngot; i = i + 1) $write(" %02x", got[i]);
        $write("\nEXP:");
        for (i = 30; i < 70 && i < nref; i = i + 1) $write(" %02x", refb[i]);
        $write("\n");
        err = 0;
        for (i = 0; i < nref && i < ngot; i = i + 1) begin
            if (got[i] !== refb[i]) begin
                if (err < 3) $display("DIFF @%0d: got %02x exp %02x", i, got[i], refb[i]);
                err = err + 1;
            end
        end
        if (ngot < nref) err = err + (nref - ngot);
        if (err == 0 && ngot == nref) $display("RESULT: PASS %0d bytes", nref);
        else                          $display("RESULT: FAIL err=%0d", err);
        $finish;
    end

    initial begin #(20_000_000); $display("TIMEOUT"); $finish; end

    //-------------------------------------------- 卡死时打内部状态
    integer dbg = 0;
    always @(posedge clk) begin
        dbg = dbg + 1;
        if (dbg > 200000 && (dbg % 20000) == 0) begin
            $display("dbg%d tstate=%0d fin_cnt=%0d bp_ok=%b bp_valid=%b n=%0d acc=%016x pend00=%b ovalid=%b mready=%b",
                dbg, dut.tstate, dut.fin_cnt, dut.bp_ok, dut.bp_valid,
                dut.u_bitpack.n, dut.u_bitpack.acc, dut.u_bitpack.pend_00,
                dut.u_bitpack.o_valid, m_ready);
        end
    end

endmodule
