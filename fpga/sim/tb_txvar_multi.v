`timescale 1ns/1ps
//==============================================================================
//  tb_txvar_multi.v
//  多包压力测试: 长随机流 + 小包 + 中断式反压
//  目的: 单独验证 csi2_frame_tx_var 在多包边界上不丢/不错字节
//==============================================================================
module tb_txvar_multi;

    parameter integer PKT = 8;
    parameter integer NLEN = 200;
    parameter integer GAP = 3;

    reg clk = 0, rst_n = 0, enable = 0;
    reg        s_tvalid = 0;
    reg  [7:0] s_tdata  = 0;
    reg        s_tlast  = 0;
    wire       s_tready;

    wire        hs_en;
    wire [31:0] hs_data;
    wire        hs_last;
    wire [31:0] frame_cnt, packet_cnt, byte_cnt;

    always #5 clk = ~clk;

    csi2_frame_tx_var #(.PKT_BYTES(PKT), .GAP_FRAME(GAP), .DT(6'h18)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tlast(s_tlast), .s_tready(s_tready),
        .hs_en(hs_en), .hs_data(hs_data), .hs_last(hs_last),
        .frame_cnt(frame_cnt), .packet_cnt(packet_cnt), .byte_cnt(byte_cnt)
    );

    //------------------------------------------------ 参考 CRC
    function [15:0] crc_b;
        input [15:0] cin; input [7:0] b;
        reg [15:0] c; integer i;
        begin
            c = cin ^ {8'h00, b};
            for (i=0;i<8;i=i+1) c = c[0] ? ((c>>1)^16'h8408) : (c>>1);
            crc_b = c;
        end
    endfunction

    //------------------------------------------------ 源数据
    reg [7:0] src [0:1023];
    integer i;
    initial for (i = 0; i < NLEN; i = i + 1) src[i] = (i*37 + 11) & 8'hFF;

    //------------------------------------------------ 收集 hs 字节
    reg [7:0] got [0:65535];
    integer   ngot = 0;
    always @(posedge clk) begin
        if (hs_en) begin
            got[ngot]   = hs_data[7:0];
            got[ngot+1] = hs_data[15:8];
            got[ngot+2] = hs_data[23:16];
            got[ngot+3] = hs_data[31:24];
            ngot = ngot + 4;
        end
    end

    //------------------------------------------------ 解包
    reg [7:0] pl [0:65535];
    integer npl = 0, nfs = 0, nfe = 0, npkt = 0, err = 0;
    integer p, dt, wc16, j;
    reg [15:0] crc_r, crc_c;
    reg [7:0]  d8;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1; enable = 1;
        repeat (4) @(posedge clk);

        for (i = 0; i < NLEN; i = i + 1) begin
            while (!s_tready) @(posedge clk);
            s_tvalid = 1'b1;
            s_tdata  = src[i];
            s_tlast  = (i == NLEN-1);
            @(posedge clk);
        end
        s_tvalid = 1'b0; s_tlast = 1'b0;

        repeat (GAP + 40) @(posedge clk);

        $write("RAW:");
        for (i = 0; i < 48; i = i + 1) $write(" %02x", got[i]);
        $write("\n");

        // ---- 解析 ----
        p = 0;
        while (p + 4 <= ngot) begin
            dt = got[p];
            if (dt == 8'h00) begin
                nfs = nfs + 1; p = p + 4;
            end else if (dt == 8'h01) begin
                nfe = nfe + 1; p = p + 4;
            end else if (dt == 8'h18) begin
                wc16 = got[p+1] + got[p+2]*256;
                npkt = npkt + 1;
                crc_r = 16'hFFFF;
                for (j = 0; j < wc16; j = j + 1) begin
                    d8 = got[p+4+j];
                    pl[npl] = d8; npl = npl + 1;
                    crc_r = crc_b(crc_r, d8);
                end
                // 补齐部分也计 CRC
                for (j = wc16; j < ((wc16+3)/4)*4; j = j + 1) begin
                    crc_r = crc_b(crc_r, got[p+4+j]);
                end
                crc_c = got[p+4+((wc16+3)/4)*4] + got[p+4+((wc16+3)/4)*4+1]*256;
                if (crc_r !== crc_c) begin
                    $display("  pkt%0d WC=%0d CRC 错: 算 %04x 收 %04x", npkt, wc16, crc_r, crc_c);
                    err = err + 1;
                end
                // CRC 占一整拍 (4 字节), 上位 16 位是 0
                p = p + 4 + ((wc16+3)/4)*4 + 4;
            end else begin
                $display("  位置 %0d 出现未知 DT=%02x", p, dt);
                err = err + 1;
                p = ngot;
            end
        end

        $display("PKT=%0d 源=%0d  FS=%0d FE=%0d 长包=%0d 收载荷=%0d 总字节=%0d",
                 PKT, NLEN, nfs, nfe, npkt, npl, ngot);

        if (npl < NLEN) begin
            $display("RESULT: FAIL 丢字节 (少 %0d)", NLEN - npl);
        end else begin
            for (i = 0; i < NLEN; i = i + 1) begin
                if (pl[i] !== src[i]) begin
                    $display("DIFF @%0d: got %02x exp %02x", i, pl[i], src[i]);
                    err = err + 1;
                end
            end
            if (err == 0) $display("RESULT: PASS %0d 字节完全一致", NLEN);
            else          $display("RESULT: FAIL err=%0d", err);
        end
        $finish;
    end

    initial begin #(NLEN*400 + 200000); $display("TIMEOUT"); $finish; end

endmodule
