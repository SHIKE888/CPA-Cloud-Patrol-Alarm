//=============================================================================
// tb_csi_full.v — LP-free CSI-2 RX 整链仿真 (从串行比特输入)
//
// 链路:
//   [TB 串行比特流] -> "PHY 等价模型"(串行->字节, LSB first)
//      -> csi_rx_byte_align x4  (找 0xB8 同步字, 定字节边界)
//      -> csi_rx_word_align     (4 lane 去偏斜)
//      -> csi_rx_word_gear_box  (4 lane 拼 32bit)
//      -> csi_rx_packet_handler (包头/ECC/长短包/FS/FE)
//      -> csi_rx_10bit_unpack   (RAW10 -> 40bit)
//      -> csi_rx_vid2stream     (AXIS + tuser/tlast)
//
// 激励: 与真实 MIPI 一致
//   burst1: 各 lane 先发 0xB8 同步, lane0 发 FS 短包(全 0), 其余 lane 发 0x00
//   burst2: 各 lane 发 0xB8 同步, 然后 4 lane 各发一行 RAW10 长包(WC=16)的字节切片
//           word(k) = {ECC, WC_H, WC_L, DID}  -> lane3=ECC, lane2=WC_H, lane1=WC_L, lane0=DID
//   burst3: FE 短包
//=============================================================================
`timescale 1ns/1ps

module tb_csi_full;

    // ---------------- 时钟 ----------------
    reg bit_clk = 0;                 // 串行比特时钟 (代表 sclk 的两个边沿)
    always #5 bit_clk = ~bit_clk;    // 10ns 周期 -> 每比特 10ns (便于仿真)

    reg [2:0] bcnt2 = 0;
    always @(posedge bit_clk) bcnt2 <= bcnt2 + 1'b1;
    wire byte_clk = bcnt2[2];        // 字节时钟 = bit_clk/8

    reg rst_n = 0;

    // ---------------- 每 lane 的字节流 ----------------
    reg [7:0] mem0 [0:1023]; reg [7:0] mem1 [0:1023];
    reg [7:0] mem2 [0:1023]; reg [7:0] mem3 [0:1023];
    integer   len0, len1, len2, len3;

    integer   bit_idx = 0;

    reg run = 0;   // 复位释放后才开始发比特, 否则同步字会在复位期间就过去
    // 字节位序: 0 = 最早收到的位放 bit0 (正常, 默认); 1 = 取反 (用于反证)
    reg rev_mode = 1'b0;
    function [7:0] rev8; input [7:0] b; integer q;
        begin for (q = 0; q < 8; q = q + 1) rev8[q] = b[7-q]; end
    endfunction
    wire s0 = (run && (bit_idx/8 < len0)) ? mem0[bit_idx/8][bit_idx%8] : 1'b0;
    wire s1 = (run && (bit_idx/8 < len1)) ? mem1[bit_idx/8][bit_idx%8] : 1'b0;
    wire s2 = (run && (bit_idx/8 < len2)) ? mem2[bit_idx/8][bit_idx%8] : 1'b0;
    wire s3 = (run && (bit_idx/8 < len3)) ? mem3[bit_idx/8][bit_idx%8] : 1'b0;

    // PHY 等价模型: 串行移位, 每 8 位组装一个字节 (LSB first -> bit0 是最早的位)
    reg [7:0] sh0, sh1, sh2, sh3;
    reg [7:0] rx_byte0, rx_byte1, rx_byte2, rx_byte3;

    always @(negedge bit_clk) begin
        sh0     <= {sh0[6:0], s0};
        sh1     <= {sh1[6:0], s1};
        sh2     <= {sh2[6:0], s2};
        sh3     <= {sh3[6:0], s3};
        // 每收满 8 个比特(bit_idx%8==7)输出一个字节 —— 这是"理想解串器"的等价模型
        if (run && (bit_idx % 8) == 7) begin
            rx_byte0 <= rev_mode ? rev8(mem0[bit_idx/8]) : mem0[bit_idx/8];
            rx_byte1 <= rev_mode ? rev8(mem1[bit_idx/8]) : mem1[bit_idx/8];
            rx_byte2 <= rev_mode ? rev8(mem2[bit_idx/8]) : mem2[bit_idx/8];
            rx_byte3 <= rev_mode ? rev8(mem3[bit_idx/8]) : mem3[bit_idx/8];
        end
        bit_idx <= run ? (bit_idx + 1) : bit_idx;
    end

    // ---------------- DUT ----------------
    wire [3:0] ba_valid;
    wire [31:0] ba_data;
    wire        wa_valid;
    wire [31:0] wa_data;
    wire        gb_valid;
    wire [31:0] gb_data;
    wire        pkt_done, sync_wait, in_frame, in_line, vsync;
    wire [31:0] payload;
    wire        payload_valid;
    wire [39:0] unpack;
    wire        unpack_valid;
    wire        tuser, tlast, tvalid;
    wire [39:0] tdata;

    reg [31:0] dbg_words = 0;

    csi_rx_byte_align u_ba0 (.I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_lan_data_in(rx_byte0), .I_wait_for_sync(sync_wait), .I_packet_done(pkt_done),
        .O_data_out_vaild(ba_valid[0]), .O_data_out(ba_data[ 7: 0]));
    csi_rx_byte_align u_ba1 (.I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_lan_data_in(rx_byte1), .I_wait_for_sync(sync_wait), .I_packet_done(pkt_done),
        .O_data_out_vaild(ba_valid[1]), .O_data_out(ba_data[15: 8]));
    csi_rx_byte_align u_ba2 (.I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_lan_data_in(rx_byte2), .I_wait_for_sync(sync_wait), .I_packet_done(pkt_done),
        .O_data_out_vaild(ba_valid[2]), .O_data_out(ba_data[23:16]));
    csi_rx_byte_align u_ba3 (.I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_lan_data_in(rx_byte3), .I_wait_for_sync(sync_wait), .I_packet_done(pkt_done),
        .O_data_out_vaild(ba_valid[3]), .O_data_out(ba_data[31:24]));

    csi_rx_word_align #(.MIPI_LAN(4)) u_wa (
        .I_word_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_packet_done(pkt_done), .I_wait_for_sync(sync_wait),
        .O_packet_done_out(), .I_word_in(ba_data), .I_valid_in(ba_valid),
        .O_word_out(wa_data), .O_valid_out(wa_valid));

    csi_rx_word_gear_box #(.MIPI_LAN(4)) u_gb (
        .I_word_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_lane_data(wa_data), .I_lane_data_valid(wa_valid),
        .O_word_out(gb_data), .O_valid_out(gb_valid));

    csi_rx_packet_handler #(.MIPI_LAN(4), .VC_ID(0)) u_ph (
        .I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_data(gb_data), .I_data_valid(gb_valid),
        .O_packet_done(pkt_done), .O_sync_wait(sync_wait),
        .O_payload_out(payload), .O_payload_valid(payload_valid),
        .O_vsync_out(vsync), .O_in_frame(in_frame), .O_in_line(in_line));

    csi_rx_10bit_unpack u_up (
        .I_clock(byte_clk), .I_reset_n(rst_n), .I_enable(1'b1),
        .I_line_in(in_line), .I_data_in(payload), .I_din_valid(payload_valid),
        .O_data_out(unpack), .O_dout_valid(unpack_valid));

    csi_rx_vid2stream u_v2s (
        .I_data_clk(byte_clk), .I_reset_n(rst_n),
        .I_packet_done(pkt_done), .I_packet_line(in_line), .I_packet_frame(in_frame),
        .I_data_unpack(unpack), .I_dout_unpack_valid(unpack_valid),
        .m_axis_video_aclk(byte_clk), .m_axis_video_aresetn(rst_n),
        .m_axis_video_tready(1'b1),
        .m_axis_video_tuser(tuser), .m_axis_video_tlast(tlast),
        .m_axis_video_tvalid(tvalid), .m_axis_video_tdata(tdata));

    // 统计
    integer n_ba = 0, n_wa = 0, n_gb = 0, n_pay = 0, n_up = 0;
    integer n_ba0 = 0, n_ba1 = 0, n_ba2 = 0, n_ba3 = 0;
    integer n_syncwait = 0;

    // 调试: 打印前 14 个收到的字节 (lane0/1) 与源数据
    integer dbg_i = 0;
    always @(posedge byte_clk) if (rst_n && dbg_i < 14) begin
        $display("dbg[%0d] rx0=%02x rx1=%02x mem0=%02x mem1=%02x",
                 dbg_i, rx_byte0, rx_byte1, mem0[dbg_i], mem1[dbg_i]);
        dbg_i = dbg_i + 1;
    end

    // 调试: 打印 gear_box 出的 32bit 字
    integer dbg_w = 0;
    always @(posedge byte_clk) if (rst_n && gb_valid && dbg_w < 12) begin
        $display("word[%0d] = %08x", dbg_w, gb_data);
        dbg_w = dbg_w + 1;
    end

    // 调试: AXIS 输出与帧状态
    always @(posedge byte_clk) if (rst_n && (tvalid || payload_valid))
        $display("t=%0t tvalid=%b tuser=%b tlast=%b data=%010x | pay_v=%b in_frame=%b in_line=%b swait=%b",
                 $time, tvalid, tuser, tlast, tdata, payload_valid, in_frame, in_line, sync_wait);
    integer n_tuser = 0, n_tlast = 0, n_tvalid = 0;
    always @(posedge byte_clk) if (rst_n) begin
        if (ba_valid[0]) n_ba0 = n_ba0 + 1;
        if (ba_valid[1]) n_ba1 = n_ba1 + 1;
        if (ba_valid[2]) n_ba2 = n_ba2 + 1;
        if (ba_valid[3]) n_ba3 = n_ba3 + 1;
        if (sync_wait)   n_syncwait = n_syncwait + 1;
        if (&ba_valid) n_ba = n_ba + 1;
        if (wa_valid)  n_wa = n_wa + 1;
        if (gb_valid)  n_gb = n_gb + 1;
        if (payload_valid) n_pay = n_pay + 1;
        if (unpack_valid)  n_up  = n_up  + 1;
        if (tuser)  n_tuser  = n_tuser  + 1;
        if (tlast)  n_tlast  = n_tlast  + 1;
        if (tvalid) n_tvalid = n_tvalid + 1;
    end

    // ---------------- 组包任务 ----------------
    reg [7:0] ecc_b;
    reg [23:0] e_din;
    wire [7:0] e_dout;
    csi_rx_hdr_ecc u_ecc (.data(e_din), .ecc(e_dout));

    // 同步字 + 把一个 32bit 包字拆到 4 lane
    task push_word(input [5:0] dt, input [15:0] wc, input do_sync);
        begin
            e_din = {wc, 2'b00, dt};
            #1 ecc_b = e_dout;
            mem0[len0] = {2'b00, dt};  len0 = len0 + 1;   // DID
            mem1[len1] = wc[7:0];      len1 = len1 + 1;   // WC_L
            mem2[len2] = wc[15:8];     len2 = len2 + 1;   // WC_H
            mem3[len3] = ecc_b;        len3 = len3 + 1;   // ECC
        end
    endtask

    task push_sync;
        begin
            mem0[len0] = 8'hB8; len0 = len0 + 1;
            mem1[len1] = 8'hB8; len1 = len1 + 1;
            mem2[len2] = 8'hB8; len2 = len2 + 1;
            mem3[len3] = 8'hB8; len3 = len3 + 1;
        end
    endtask

    task push_payload_word(input [31:0] d);
        begin
            mem0[len0] = d[ 7: 0]; len0 = len0 + 1;
            mem1[len1] = d[15: 8]; len1 = len1 + 1;
            mem2[len2] = d[23:16]; len2 = len2 + 1;
            mem3[len3] = d[31:24]; len3 = len3 + 1;
        end
    endtask

    integer i, n, rep;
    integer max_len;
    initial begin
        len0 = 0; len1 = 0; len2 = 0; len3 = 0;

        // 预滚: 先发一个同步字 + 填充, 让 byte_align 在真正帧开始前就锁上同步
        // (真实传感器是连续码流, 锁定时丢的几个字节不会吃掉帧首)
        push_sync;
        for (i = 0; i < 20; i = i + 1) begin
            mem0[len0]=8'hFF; len0=len0+1; mem1[len1]=8'hFF; len1=len1+1;
            mem2[len2]=8'hFF; len2=len2+1; mem3[len3]=8'hFF; len3=len3+1;
        end

        for (rep = 0; rep < 2; rep = rep + 1) begin
        // burst1: 同步 + FS (WC=0, DID=0 -> ECC=0)
        push_sync;
        push_word(6'h00, 16'h0000, 1'b1);
        // 帧内空转几拍 (模拟包间隙)
        for (i = 0; i < 8; i = i + 1) begin
            mem0[len0]=8'h00; len0=len0+1; mem1[len1]=8'h00; len1=len1+1;
            mem2[len2]=8'h00; len2=len2+1; mem3[len3]=8'h00; len3=len3+1;
        end

        // burst2: 同步 + 一行 RAW10 长包 (WC=16 字节 -> 4 word 载荷)
        push_sync;
        push_word(6'h2B, 16'd16, 1'b1);
        for (i = 0; i < 4; i = i + 1) push_payload_word(32'h11223344 + i);
        for (n = 0; n < 8; n = n + 1) begin
            mem0[len0]=8'h00; len0=len0+1; mem1[len1]=8'h00; len1=len1+1;
            mem2[len2]=8'h00; len2=len2+1; mem3[len3]=8'h00; len3=len3+1;
        end

        // burst3: 同步 + FE
        push_sync;
        push_word(6'h01, 16'h0000, 1'b1);
        end  // rep
        // 尾部补 0
        for (i = 0; i < 16; i = i + 1) begin
            mem0[len0]=8'h00; len0=len0+1; mem1[len1]=8'h00; len1=len1+1;
            mem2[len2]=8'h00; len2=len2+1; mem3[len3]=8'h00; len3=len3+1;
        end

        max_len = len0;
        if (len1 > max_len) max_len = len1;
        if (len2 > max_len) max_len = len2;
        if (len3 > max_len) max_len = len3;
        $display("lanes: %0d/%0d/%0d/%0d bytes", len0, len1, len2, len3);
        if ($value$plusargs("NOREV=%d", i)) rev_mode = 1'b0;
        $display("rev_mode = %0d", rev_mode);

        repeat (4) @(posedge byte_clk);
        rst_n = 1;
        repeat (2) @(posedge byte_clk);
        run   = 1;

        // 等所有比特发完 + 余量
        wait (bit_idx > max_len * 8 + 64 * 8);
        repeat (200) @(posedge byte_clk);

        $display("================ RESULT ================");
        $display("sync_wait cycles                   = %0d", n_syncwait);
        $display("byte_align valid per lane          = %0d/%0d/%0d/%0d", n_ba0, n_ba1, n_ba2, n_ba3);
        $display("byte_align 4lane-all-valid cycles = %0d", n_ba);
        $display("word_align valid cycles            = %0d", n_wa);
        $display("gear_box   valid cycles            = %0d", n_gb);
        $display("payload_valid pulses               = %0d", n_pay);
        $display("unpack_valid  pulses               = %0d", n_up);
        $display("AXIS tvalid beats                  = %0d", n_tvalid);
        $display("AXIS tuser pulses                  = %0d", n_tuser);
        $display("AXIS tlast pulses                  = %0d", n_tlast);
        if (n_tuser > 0 && n_tvalid > 0)
            $display("PASS: 串行输入 -> 出图通路 全链打通");
        else
            $display("FAIL: 链路中断 (看上面哪一级先归零)");
        $finish;
    end

endmodule
