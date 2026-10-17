`timescale 1ns/1ps
module tb_pack4;

    localparam integer H_ACTIVE = 3840;
    localparam integer V_ACTIVE = 3;
    localparam integer WP       = H_ACTIVE / 2;

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
            repeat (40) @(posedge clk);
        end
        repeat (4000) @(posedge clk);
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
        end else begin
            m_tready <= 1'b0; busy <= 30;
        end
    end

    integer wcnt = 0, rows = 0;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tuser_sof) begin
                $display("---- sof line %0d", rows);
                wcnt = 0; rows = rows + 1;
            end
            if (wcnt > WP - 6)
                $display("    t=%0t  idx=%0d data=%0d  m_tlast=%b  line_active=%b priming=%b drain_done=%b drain_cnt=%0d",
                         $time, wcnt, m_tdata, m_tlast,
                         u_dut.line_active, u_dut.line_priming, u_dut.line_drain_done, u_dut.drain_cnt);
            wcnt = wcnt + 1;
        end
        if (rows > 1 && wcnt == 0) begin
        end
        if (rows > 2) $finish;
    end

endmodule
