//=============================================================================
// tb_csi_proto.v — LP-free CSI-2 RX 协议层仿真
//
// 目的: 不经过 PHY(加密 IDDR 无法仿真), 直接喂 32bit 包字, 验证
//   csi_rx_packet_handler -> csi_rx_10bit_unpack -> csi_rx_vid2stream
// 能否:
//   1) 从 FS 短包把 in_frame 置起来
//   2) 从 RAW10 长包产生 payload/in_line
//   3) 产生 AXIS 帧首 tuser 与行尾 tlast (即 FRAME_CNT/tuser 通路的根源)
//=============================================================================
`timescale 1ns/1ps

module tb_csi_proto;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;              // 100MHz

    // ---- 激励 ----
    reg  [7:0]  did;
    reg  [15:0] wc;
    reg  [23:0] ecc_in;
    wire [7:0]  ecc;
    reg  [31:0] word;
    reg         word_v = 0;

    csi_rx_hdr_ecc u_ecc (.data(ecc_in), .ecc(ecc));

    // ---- packet handler ----
    wire        in_frame, in_line, packet_done, sync_wait, vsync;
    wire [31:0] payload;
    wire        payload_valid;

    csi_rx_packet_handler #(.MIPI_LAN(4), .VC_ID(0)) u_ph (
        .I_clock        (clk),
        .I_reset_n      (rst_n),
        .I_enable       (1'b1),
        .I_data         (word),
        .I_data_valid   (word_v),
        .O_packet_done  (packet_done),
        .O_sync_wait    (sync_wait),
        .O_payload_out  (payload),
        .O_payload_valid(payload_valid),
        .O_vsync_out    (vsync),
        .O_in_frame     (in_frame),
        .O_in_line      (in_line)
    );

    // ---- 10bit unpack ----
    wire [39:0] unpack;
    wire        unpack_valid;
    csi_rx_10bit_unpack u_up (
        .I_clock        (clk),
        .I_reset_n      (rst_n),
        .I_enable       (1'b1),
        .I_line_in      (in_line),
        .I_data_in      (payload),
        .I_din_valid    (payload_valid),
        .O_data_out     (unpack),
        .O_dout_valid   (unpack_valid)
    );

    // ---- vid2stream ----
    wire        tuser, tlast, tvalid;
    wire [39:0] tdata;
    csi_rx_vid2stream u_v2s (
        .I_data_clk           (clk),
        .I_reset_n            (rst_n),
        .I_packet_done        (packet_done),
        .I_packet_line        (in_line),
        .I_packet_frame       (in_frame),
        .I_data_unpack        (unpack),
        .I_dout_unpack_valid  (unpack_valid),
        .m_axis_video_aclk    (clk),
        .m_axis_video_aresetn (rst_n),
        .m_axis_video_tready  (1'b1),
        .m_axis_video_tuser   (tuser),
        .m_axis_video_tlast   (tlast),
        .m_axis_video_tvalid  (tvalid),
        .m_axis_video_tdata   (tdata)
    );

    // ---- 统计 ----
    integer n_tuser = 0, n_tlast = 0, n_tvalid = 0, n_pay = 0, n_unpack = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (tuser)  n_tuser  = n_tuser  + 1;
            if (tlast)  n_tlast  = n_tlast  + 1;
            if (tvalid) n_tvalid = n_tvalid + 1;
            if (payload_valid) n_pay = n_pay + 1;
            if (unpack_valid)  n_unpack = n_unpack + 1;
        end
    end

    // ---- 激励任务 ----
    task send_hdr(input [6:0] did_i, input [15:0] wc_i);
        begin
            @(negedge clk);
            did    = {1'b0, did_i};      // VC=0
            wc     = wc_i;
            ecc_in = {wc_i, did};
            #1;
            word   = {ecc, wc_i, did};
            word_v = 1'b1;
            @(negedge clk);
            word_v = 1'b0;
            word   = 32'h0;
        end
    endtask

    task send_payload(input integer n_words);
        integer k;
        begin
            for (k = 0; k < n_words; k = k + 1) begin
                @(negedge clk);
                word   = 32'h11223344 + k;   // 任意载荷
                word_v = 1'b1;
            end
            @(negedge clk);
            word_v = 1'b0;
            word   = 32'h0;
        end
    endtask

    // ---- 主流程 ----
    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // 1) 帧开始短包  DT=0x00
        send_hdr(7'h00, 16'h0000);
        repeat (4) @(posedge clk);
        $display("[T=%0t] after FS : in_frame=%b in_line=%b", $time, in_frame, in_line);

        // 2) 一行 RAW10 长包  DT=0x2B, WC=16 字节
        send_hdr(7'h2B, 16'd16);
        repeat (2) @(posedge clk);
        $display("[T=%0t] after line hdr : in_frame=%b in_line=%b", $time, in_frame, in_line);

        send_payload(4);                       // 16 字节 = 4 word
        repeat (10) @(posedge clk);
        $display("[T=%0t] after payload : pay=%0d unpack=%0d", $time, n_pay, n_unpack);

        // 3) 再一行
        send_hdr(7'h2B, 16'd16);
        send_payload(4);
        repeat (10) @(posedge clk);

        // 4) 帧结束短包  DT=0x01
        send_hdr(7'h01, 16'h0000);
        repeat (20) @(posedge clk);
        $display("[T=%0t] after FE : in_frame=%b", $time, in_frame);

        repeat (40) @(posedge clk);

        $display("================ RESULT ================");
        $display("payload_valid  pulses = %0d", n_pay);
        $display("unpack_valid   pulses = %0d", n_unpack);
        $display("AXIS tvalid    beats  = %0d", n_tvalid);
        $display("AXIS tuser     pulses = %0d  <-- 决定 FRAME_CNT", n_tuser);
        $display("AXIS tlast     pulses = %0d", n_tlast);
        if (n_tuser > 0) $display("PASS: 协议层能产生帧首");
        else             $display("FAIL: 协议层没有帧首");
        $finish;
    end

endmodule
