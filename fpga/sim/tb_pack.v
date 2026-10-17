`timescale 1ns/1ps
// 目的: 统计 csi2_pack_yuv422_stream 每行输出的 word 数是否恒为 WORDS_PAYLOAD(=1920)
module tb_pack;

    localparam integer H_ACTIVE = 3840;   // 4K
    localparam integer V_ACTIVE = 8;
    localparam integer WP       = H_ACTIVE / 2;   // 1920

    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;      // ~125MHz

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

    // ---------------- 上游: 每行正好 WP 个 word, 行间有 blanking ----------------
    integer line, col;
    initial begin
        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        for (line = 0; line < V_ACTIVE; line = line + 1) begin
            for (col = 0; col < WP; col = col + 1) begin
                s_tvalid    <= 1'b1;
                s_tdata     <= line * 100000 + col;
                s_tuser_sof <= (col == 0);
                s_tlast     <= (col == WP - 1);
                @(posedge clk);
                while (!s_tready) @(posedge clk);
            end
            s_tvalid <= 1'b0; s_tuser_sof <= 1'b0; s_tlast <= 1'b0;
            repeat (40) @(posedge clk);      // 行消隐
        end
        repeat (2000) @(posedge clk);
        $display("[FAIL] timeout");
        $finish;
    end

    // ---------------- 下游: 模拟 csi2_frame_tx 的 tready ----------------
    // 每行吃 WP 个 word, 然后 busy 抽 30 拍 (header/CRC/GAP)
    integer cnt = 0, busy = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_tready <= 1'b0; cnt <= 0;
        end else if (busy > 0) begin
            m_tready <= 1'b0;
            busy     <= busy - 1;
            if (busy == 1) cnt <= 0;
        end else if (cnt < WP) begin
            m_tready <= 1'b1;
            if (m_tvalid && m_tready) cnt <= cnt + 1;
        end else begin
            m_tready <= 1'b0;
            busy     <= 30;
        end
    end

    // ---------------- 统计每行输出 word 数 ----------------
    integer wcnt = 0, rows = 0;
    integer prev = -1, expect_next = 0;
    reg [31:0] first_data;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tuser_sof) begin
                if (rows > 0) begin
                    if (wcnt != WP) $display("[MISMATCH] line %0d  output_words=%0d  (expect %0d)", rows - 1, wcnt, WP);
                    else            $display("[OK]       line %0d  output_words=%0d", rows - 1, wcnt);
                end
                // 数据连续性检查: 上一行最后一个 word 与这一行第一个 word 应连续
                if (rows > 0 && m_tdata != first_data + WP) begin
                    $display("           >>> 数据不连续: 期望首 word=%0d, 实际=%0d", first_data + WP, m_tdata);
                end
                first_data = m_tdata;
                wcnt  = 1;
                rows  = rows + 1;
            end else begin
                wcnt = wcnt + 1;
            end
        end
        if (rows > V_ACTIVE) begin
            $display("done: %0d lines", rows);
            $finish;
        end
    end

endmodule
