`timescale 1ns/1ps
// 参数化回归: -Ptb_gen.H_ACTIVE=1920 / 3840, -Ptb_gen.IN_GAP=0/40, -Ptb_gen.OUT_GAP=0/30
module tb_gen;

    parameter integer H_ACTIVE = 3840;
    parameter integer V_ACTIVE = 40;
    parameter integer IN_GAP   = 40;   // 行间上游消隐拍数
    parameter integer OUT_GAP  = 30;   // 下游每行忙拍数

    localparam integer WP = H_ACTIVE / 2;

    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;

    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [31:0] s_tdata = 0;
    reg         s_tuser_sof = 0;
    reg         s_tlast = 0;

    wire        m_tvalid;
    reg         m_tready = 0;
    wire [31:0] m_tdata;
    wire        m_tuser_sof, m_tlast;

    csi2_pack_yuv422_stream u_dut (
        .src_clk(clk), .src_rst_n(rst_n),
        .I_h_active(H_ACTIVE[12:0]), .I_v_active(V_ACTIVE[11:0]),
        .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tdata(s_tdata),
        .s_tuser_sof(s_tuser_sof), .s_tlast(s_tlast),
        .dst_clk(clk), .dst_rst_n(rst_n), .enable(1'b1),
        .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tdata(m_tdata),
        .m_tuser_sof(m_tuser_sof), .m_tlast(m_tlast)
    );

    integer wcnt = 0, rows = 0, errs = 0;
    reg [31:0] nx = 0;

    task send_word(input [31:0] d, input sof, input last);
        begin
            @(negedge clk);
            s_tvalid = 1'b1; s_tdata = d; s_tuser_sof = sof; s_tlast = last;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
    endtask

    integer line, col;
    initial begin
        rst_n = 0;
        repeat (20) @(posedge clk);
        @(negedge clk); rst_n = 1;
        for (line = 0; line < V_ACTIVE; line = line + 1) begin
            for (col = 0; col < WP; col = col + 1)
                send_word(line * 100000 + col, col == 0, col == WP - 1);
            @(negedge clk);
            s_tvalid = 0; s_tuser_sof = 0; s_tlast = 0;
            repeat (IN_GAP) @(posedge clk);
        end
        repeat (6000) @(posedge clk);
        $display("[FAIL] timeout: rows=%0d b_occ=%0d b_empty=%b q_cnt=%0d inflight=%b m_tvalid=%b m_tready=%b",
                 rows, u_dut.b_occ, u_dut.b_empty, u_dut.q_cnt, u_dut.rd_inflight,
                 u_dut.m_tvalid, u_dut.m_tready);
        $finish;
    end

    integer cnt = 0, busy = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1'b0; cnt <= 0;
        end else if (busy > 0) begin
            m_tready <= 1'b0; busy <= busy - 1;
            if (busy == 1) cnt <= 0;
        end else if (cnt < WP) begin
            m_tready <= 1'b1;
            if (m_tvalid && m_tready) cnt <= cnt + 1;
        end else if (OUT_GAP == 0) begin
            m_tready <= 1'b1; cnt <= 0;
        end else begin
            m_tready <= 1'b0; busy <= OUT_GAP;
        end
    end

    integer dbg_w = 0, dbg_r = 0;
    integer tprev = 0, maxcyc = 0;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready && m_tuser_sof) begin
            if (rows > 2 && ($time - tprev) / 8 > maxcyc) maxcyc = ($time - tprev) / 8;
            tprev = $time;
        end
    end
    always @(posedge clk) begin
        if (rst_n && u_dut.b_wr_en && dbg_w < 4) begin
            $display("  [wr%0d] data=%0d sof=%b last=%b", dbg_w, u_dut.yuv_data, u_dut.yuv_sof, u_dut.yuv_last);
            dbg_w = dbg_w + 1;
        end
        if (rst_n && m_tvalid && m_tready && dbg_r < 4) begin
            $display("  [rd%0d] data=%0d sof=%b last=%b", dbg_r, m_tdata, m_tuser_sof, m_tlast);
            dbg_r = dbg_r + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tuser_sof) begin
                if (rows > 0 && wcnt != WP) begin
                    $display("[ERR ] line %0d words=%0d (expect %0d)", rows - 1, wcnt, WP);
                    errs = errs + 1;
                end
                nx = m_tdata;
                wcnt = 1; rows = rows + 1;
            end else begin
                wcnt = wcnt + 1;
            end
            if (m_tdata !== nx) begin
                $display("[ERR ] data break row %0d idx %0d: got %0d expect %0d",
                         rows - 1, wcnt - 1, m_tdata, nx);
                errs = errs + 1;
            end
            nx = nx + 1;
        end
        if (rows >= V_ACTIVE) begin
            $display("RESULT H=%0d in_gap=%0d out_gap=%0d lines=%0d errors=%0d worst_line_period_cycles=%0d",
                     H_ACTIVE, IN_GAP, OUT_GAP, rows, errs, maxcyc);
            $finish;
        end
    end

endmodule
