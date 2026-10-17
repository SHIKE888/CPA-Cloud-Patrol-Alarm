`timescale 1ns/1ps
module tb_pack2;

    localparam integer H_ACTIVE = 3840;
    localparam integer V_ACTIVE = 6;
    localparam integer WP       = H_ACTIVE / 2;   // 1920

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
            repeat (40) @(posedge clk);
        end
        repeat (3000) @(posedge clk);
        $finish;
    end

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

    integer wcnt = 0, rows = 0;
    reg [31:0] head[0:7];
    reg [31:0] tail[0:3];
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            if (m_tuser_sof) begin
                if (rows > 0) begin
                    $display("line %0d: words=%0d  head=%0d,%0d,%0d,%0d,%0d  tail=%0d,%0d,%0d,%0d",
                             rows - 1, wcnt,
                             head[0], head[1], head[2], head[3], head[4],
                             tail[0], tail[1], tail[2], tail[3]);
                end
                head[0] = m_tdata;
                wcnt = 1; rows = rows + 1;
            end else begin
                if (wcnt < 5) head[wcnt] = m_tdata;
                tail[0] = tail[1]; tail[1] = tail[2]; tail[2] = tail[3]; tail[3] = m_tdata;
                wcnt = wcnt + 1;
            end
        end
        if (rows > V_ACTIVE) $finish;
    end

endmodule
