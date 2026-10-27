`timescale 1ns/1ps
//==============================================================================
//  tb_jpeg_csi2_e2e.v
//  JPEG 全链路端到端: YUV -> jpeg_encoder_top -> csi2_frame_tx_var -> 解包还原
//
//  验证的事:
//    1) 编码器输出接上带反压的 CSI-2 发送后, 字节不丢 (m_ready 反压链生效)
//    2) CSI-2 包结构正确: FS + 多个 DT=0x18 长包 + FE
//    3) 把所有长包 payload 按 WC 拼接, 得到的就是完整的 JPEG 文件
//==============================================================================
module tb_jpeg_csi2_e2e;

    parameter integer W = 320;
    parameter integer H = 40;
    parameter integer PKT = 64;          // 故意设小, 让一帧拆成很多包

    localparam integer NWORD = (W/2)*H;

`include "jpeg_sim_cfg.vh"
`ifndef SIM_LL
`define SIM_LL 1'b0
`endif

    reg clk = 0, rst_n = 0;
    reg        s_valid = 0;
    reg [31:0] s_data  = 0;
    wire       s_ready;

    wire       m_valid, m_last;
    wire [7:0] m_data;
    wire       m_ready;

    wire        hs_en, hs_last;
    wire [31:0] hs_data;
    wire [31:0] fc, pc, bc;

    always #5 clk = ~clk;

    //-------------------------------------------------------------- DUT: 编码器
    wire [6:0] qt_a, qt_b;
    wire [7:0] qta, qtb;
    jpeg_qtable_ram u_qt (
        .I_clk(clk), .I_rst_n(rst_n), .I_wr_en(1'b0),
        .I_wr_addr(8'd0), .I_wr_data(8'd0),
        .I_rd_idx_a(qt_a), .O_rd_data_a(), .O_rd_data_a_asyn(qta),
        .I_rd_idx_b(qt_b), .O_rd_data_b(qtb)
    );

    jpeg_encoder_top #(.W(W), .H(H)) u_enc (
        .clk(clk), .rst_n(rst_n),
        .i_en(1'b1), .i_soft_rst(1'b0), .i_lossless(`SIM_LL),
        .i_width(W[11:0]), .i_height(H[11:0]), .i_rst_int(16'd0),
        .o_qt_idx_a(qt_a), .i_qt_data_a(qta),
        .o_qt_idx_b(qt_b), .i_qt_data_b(qtb),
        .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
        .m_valid(m_valid), .m_data(m_data), .m_last(m_last), .m_ready(m_ready),
        .st_frame_bytes(), .st_busy(), .st_done(), .st_frame_cnt()
    );

    //-------------------------------------------------------------- DUT: CSI-2 发送
    // 2026-10-27: DT 已从编译期参数改成运行时端口 i_dt
    //   (0x0B[1] 可选 0x1E / 0x18; 板上实测 rkcif 只认 0x1E)
    csi2_frame_tx_var #(.PKT_BYTES(PKT), .GAP_FRAME(8)) u_tx (
        .clk(clk), .rst_n(rst_n), .enable(1'b1),
        .i_dt(6'h1E),
        .s_tvalid(m_valid), .s_tdata(m_data), .s_tlast(m_last), .s_tready(m_ready),
        .hs_en(hs_en), .hs_data(hs_data), .hs_last(hs_last),
        .frame_cnt(fc), .packet_cnt(pc), .byte_cnt(bc)
    );

    //============================================================== 解包
    reg [7:0]  jpg [0:2_000_000];
    integer    njpg = 0;
    integer    nfs = 0, nfe = 0, npkt = 0;
    reg [7:0]  h4 [0:3];
    integer    hpos = 0;
    integer    st = 0;          // 0=等包头 1=收payload 2=收CRC
    integer    wc_left = 0;
    integer    k, ci;
    reg [7:0]  cb;

    always @(posedge clk) begin
        if (hs_en) begin
            for (ci = 0; ci < 4; ci = ci + 1) begin
                cb = hs_data[ci*8 +: 8];
                case (st)
                0: begin
                    h4[hpos] = cb; hpos = hpos + 1;
                    if (hpos == 4) begin
                        hpos = 0;
                        if (h4[0][5:0] == 6'h18) begin
                            st = 1;
                            wc_left = h4[1] | (h4[2] << 8);
                            npkt = npkt + 1;
                        end else if (h4[0][5:0] == 6'h00) nfs  = nfs  + 1;
                        else if (h4[0][5:0] == 6'h01) nfe  = nfe  + 1;
                    end
                end
                1: begin
                    if (wc_left > 0) begin
                        if (njpg < 2_000_000) jpg[njpg] = cb;
                        njpg = njpg + 1;
                        wc_left = wc_left - 1;
                        if (wc_left == 0) st = 2;
                    end
                end
                default: ; // CRC 4 字节丢弃
                endcase
            end
        end
        if (hs_last) begin st = 0; hpos = 0; end
    end

    //============================================================== 主机
    integer fin, frc, i, fd, err;
    reg [31:0] vword;
    reg [7:0]  refb [0:2_000_000];
    integer    nref = 0;

    initial begin
        fin = $fopen("jpeg_in.hex", "r");
        if (fin == 0) begin $display("cannot open jpeg_in.hex"); $finish; end
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        for (i = 0; i < NWORD; i = i + 1) begin
            while (!s_ready) @(posedge clk);
            frc      = $fscanf(fin, "%h\n", vword);
            s_valid  = 1'b1;
            s_data   = vword;
            @(posedge clk);
        end
        s_valid = 1'b0;
        $fclose(fin);

        // 等 CSI-2 把整帧发完 (FE 出现), 带超时保护
        i = 0;
        while (nfe == 0 && i < 400000) begin
            @(posedge clk);
            i = i + 1;
        end
        repeat (20) @(posedge clk);

        // 读参考
        fd = $fopen("ref.jpg", "rb");
        while (!$feof(fd) && nref < 2_000_000) begin
            refb[nref] = $fgetc(fd);
            if (refb[nref] != 8'hFF || !$feof(fd)) nref = nref + 1;
        end
        $fclose(fd);
        // $fgetc 在 EOF 返回 -1 会变成 FF, 减掉
        if (nref > 0 && refb[nref-1] == 8'hFF) nref = nref - 1;

        err = 0;
        $display("CSI2: FS=%0d FE=%0d 长包=%0d  payload字节=%0d", nfs, nfe, npkt, njpg);
        $display("REF : %0d 字节", nref);
        if (njpg < nref) begin
            $display("RESULT: FAIL (payload 少 %0d 字节 —— 反压没兜住)", nref - njpg);
            err = 1;
        end else begin
            for (i = 0; i < nref; i = i + 1)
                if (jpg[i] !== refb[i]) begin
                    $display("DIFF @%0d: got %02x exp %02x", i, jpg[i], refb[i]);
                    err = 1;
                    i = nref;
                end
            if (!err)
                $display("RESULT: PASS  前 %0d 字节与参考完全一致 (共 %0d 字节, 尾部为补齐)", nref, njpg);
        end
        $finish;
    end

    initial begin
        #(W*H*40 + 2_000_000);
        $display("TIMEOUT: payload=%0d", njpg);
        $finish;
    end

endmodule
