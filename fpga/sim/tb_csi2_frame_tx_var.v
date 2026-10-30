`timescale 1ns/1ps
//==============================================================================
//  tb_csi2_frame_tx_var.v
//  验证可变长 CSI-2 发送: 包结构 / WC / 字节序 / 补齐 / CRC / FS+FE
//
//  做法: 喂一段已知字节流, 把 hs_data 逐拍收集成字节序列, 再和"按 CSI-2 规则
//  手工算出来的期望字节流"逐字节比对。CRC 用参考函数独立算一遍。
//==============================================================================
module tb_csi2_frame_tx_var;

    localparam integer PKT = 4;      // 故意设很小, 好让一帧拆成多个包
    localparam integer GAP = 3;
    localparam integer GAPL = 5;     // ★V54g: 包间 GAP (给 D-PHY FIFO 排空)

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

    csi2_frame_tx_var #(.PKT_BYTES(PKT), .GAP_FRAME(GAP), .GAP_LINE(GAPL)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .i_dt(6'h1E),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tlast(s_tlast), .s_tready(s_tready),
        .hs_en(hs_en), .hs_data(hs_data), .hs_last(hs_last),
        .frame_cnt(frame_cnt), .packet_cnt(packet_cnt), .byte_cnt(byte_cnt)
    );

    //======================================================== ★V54g 包间 GAP 实测
    //   hs_en 掉低后到下一次拉高之间的拍数。每个 packet (hs_last) 之间
    //   必须 >= GAPL, 否则 D-PHY 的 HS TX FIFO 排不空 -> 溢出丢字节 -> CRC 错。
    integer gap_run   = 0;
    integer min_gap   = 999999;
    integer seen_pkt  = 0;
    integer gap_viol  = 0;
    always @(posedge clk) begin
        if (!hs_en) begin
            gap_run = gap_run + 1;
        end else begin
            if (seen_pkt > 0 && gap_run > 0) begin
                $display("  [GAP] packet boundary gap = %0d clk (need >= %0d)", gap_run, GAPL);
                if (gap_run < min_gap) min_gap = gap_run;
                if (gap_run < GAPL)    gap_viol = gap_viol + 1;
            end
            gap_run = 0;
        end
        if (hs_en && hs_last) seen_pkt = seen_pkt + 1;
    end

    //======================================================== 参考模型
    function [7:0] ecc8;
        input [23:0] d;
        reg   [7:0]  e;
        begin
            e[7]=0; e[6]=0;
            e[5]=d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[0]^d[1]^d[2]^d[3]^d[5]^d[6]^d[7];
            e[4]=d[20]^d[21]^d[22]^d[23]^d[8]^d[9]^d[0]^d[1]^d[2]^d[3]^d[4]^d[6]^d[7];
            e[3]=d[17]^d[18]^d[19]^d[23]^d[8]^d[9]^d[13]^d[14]^d[15]^d[3]^d[4]^d[5]^d[7];
            e[2]=d[16]^d[18]^d[19]^d[21]^d[22]^d[9]^d[11]^d[12]^d[15]^d[2]^d[4]^d[5]^d[6];
            e[1]=d[16]^d[17]^d[19]^d[20]^d[22]^d[8]^d[10]^d[12]^d[14]^d[1]^d[4]^d[5]^d[6]^d[7];
            e[0]=d[16]^d[17]^d[18]^d[20]^d[21]^d[23]^d[10]^d[11]^d[13]^d[0]^d[4]^d[5]^d[6]^d[7];
            ecc8 = e;
        end
    endfunction

    function [15:0] crc_b;
        input [15:0] cin; input [7:0] b;
        reg [15:0] c; integer i;
        begin
            c = cin ^ {8'h00, b};
            for (i=0;i<8;i=i+1) c = c[0] ? ((c>>1)^16'h8408) : (c>>1);
            crc_b = c;
        end
    endfunction

    function [31:0] shdr;   // 短包
        input [5:0] dt; input [15:0] d16;
        reg [7:0] di; reg [23:0] d24;
        begin
            di  = {2'b00, dt};
            d24 = {di, d16[7:0], d16[15:8]};
            shdr = {ecc8(d24), d16[15:8], d16[7:0], di};
        end
    endfunction

    function [31:0] lhdr;   // 长包
        input [5:0] dt; input [15:0] wc;
        reg [7:0] di; reg [23:0] d24;
        begin
            di   = {2'b00, dt};
            d24  = {di, wc[7:0], wc[15:8]};
            lhdr = {ecc8(d24), wc[15:8], wc[7:0], di};
        end
    endfunction

    //======================================================== 收集发出去的字节
    reg [7:0] got [0:4095];
    integer ngot = 0;
    integer nlast = 0;
    always @(posedge clk) begin
        if (hs_en) begin
            got[ngot]   = hs_data[7:0];
            got[ngot+1] = hs_data[15:8];
            got[ngot+2] = hs_data[23:16];
            got[ngot+3] = hs_data[31:24];
            ngot = ngot + 4;
            if (hs_last) nlast = nlast + 1;
        end
    end

    //======================================================== 主机
    // 喂 7 个字节: PKT=4 -> 第一包 4 字节, 第二包 3 字节(补齐到 4)
    reg [7:0] src [0:6];
    integer i, err;
    reg [7:0] exp [0:4095];
    integer nexp;

    initial begin
        src[0]=8'hAA; src[1]=8'hBB; src[2]=8'hCC; src[3]=8'hDD;
        src[4]=8'h11; src[5]=8'h22; src[6]=8'hD9;    // 最后一个顺便当 EOI 尾字节

        repeat (4) @(posedge clk);
        rst_n = 1; enable = 1;
        repeat (4) @(posedge clk);

        // --- 喂数据 ---
        // ★ 必须先等 ready 再给数据: 编码器在发包时 tready=0, 此时给 valid
        //   那一个字节就丢了 (实测最后一包 byte_cnt 少 1)。
        for (i = 0; i < 7; i = i + 1) begin
            while (!s_tready) @(posedge clk);
            s_tvalid = 1'b1;
            s_tdata  = src[i];
            s_tlast  = (i == 6);
            @(posedge clk);          // 这一拍被收下
        end
        s_tvalid = 1'b0; s_tlast = 1'b0;

        // 等两帧都发完 (packet_cnt>=2 且回到 idle)
        repeat (200) @(posedge clk);

        //==================================================== 期望
        nexp = 0;
        // FS
        exp[nexp+0]=shdr(6'h00,16'd0) & 8'hFF;  nexp=nexp+1;
        exp[nexp]= (shdr(6'h00,16'd0)>>8)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (shdr(6'h00,16'd0)>>16)&8'hFF; nexp=nexp+1;
        exp[nexp]= (shdr(6'h00,16'd0)>>24)&8'hFF; nexp=nexp+1;
        // 包1: WC=4   (DT=0x1E = 运行时 i_dt, rkcif 只认这个)
        exp[nexp]= (lhdr(6'h1E,16'd4)>>0)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd4)>>8)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd4)>>16)&8'hFF; nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd4)>>24)&8'hFF; nexp=nexp+1;
        exp[nexp]=8'hAA; nexp=nexp+1;
        exp[nexp]=8'hBB; nexp=nexp+1;
        exp[nexp]=8'hCC; nexp=nexp+1;
        exp[nexp]=8'hDD; nexp=nexp+1;
        begin : c1
            reg [15:0] c; integer k;
            c = 16'hFFFF;
            for (k=0;k<4;k=k+1) c = crc_b(c, src[k]);
            exp[nexp]= c[7:0];  nexp=nexp+1;
            exp[nexp]= c[15:8]; nexp=nexp+1;
            exp[nexp]= 8'h00;   nexp=nexp+1;
            exp[nexp]= 8'h00;   nexp=nexp+1;
        end
        // 包2: WC=3 (补 1 个 0)
        exp[nexp]= (lhdr(6'h1E,16'd3)>>0)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd3)>>8)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd3)>>16)&8'hFF; nexp=nexp+1;
        exp[nexp]= (lhdr(6'h1E,16'd3)>>24)&8'hFF; nexp=nexp+1;
        exp[nexp]=8'h11; nexp=nexp+1;
        exp[nexp]=8'h22; nexp=nexp+1;
        exp[nexp]=8'hD9; nexp=nexp+1;
        exp[nexp]=8'h00; nexp=nexp+1;      // 补齐
        begin : c2
            reg [15:0] c; integer k;
            c = 16'hFFFF;
            for (k=4;k<8;k=k+1) c = crc_b(c, (k<7) ? src[k] : 8'h00);
            exp[nexp]= c[7:0];  nexp=nexp+1;
            exp[nexp]= c[15:8]; nexp=nexp+1;
            exp[nexp]= 8'h00;   nexp=nexp+1;
            exp[nexp]= 8'h00;   nexp=nexp+1;
        end
        // FE
        exp[nexp]= (shdr(6'h01,16'd0)>>0)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (shdr(6'h01,16'd0)>>8)&8'hFF;  nexp=nexp+1;
        exp[nexp]= (shdr(6'h01,16'd0)>>16)&8'hFF; nexp=nexp+1;
        exp[nexp]= (shdr(6'h01,16'd0)>>24)&8'hFF; nexp=nexp+1;

        //==================================================== 比对
        err = 0;
        if (ngot != nexp) begin
            $display("LEN MISMATCH: got %0d, exp %0d", ngot, nexp);
            err = 1;
        end
        if (err || 1) begin
            $write("GOT:");
            for (i = 0; i < ngot && i < 48; i = i + 1) $write(" %02x", got[i]);
            $write("\nEXP:");
            for (i = 0; i < nexp && i < 48; i = i + 1) $write(" %02x", exp[i]);
            $write("\n");
        end
        for (i = 0; i < ((ngot < nexp) ? ngot : nexp); i = i + 1) begin
            if (got[i] !== exp[i]) begin
                $display("DIFF @%0d: got %02x exp %02x", i, got[i], exp[i]);
                err = 1;
                if (i > 40) i = nexp;   // 只报前几个
            end
        end
        // ★V54g: hs_last 拍数 = FS(1) + 包1_CRC(1) + 包2_CRC(1) + FE(1) = 4
        if (nlast != 4) begin
            $display("hs_last COUNT MISMATCH: got %0d, exp 4", nlast);
            err = 1;
        end
        $display("packet_cnt=%0d byte_cnt=%0d frame_cnt=%0d", packet_cnt, byte_cnt, frame_cnt);

        // ★V54g: 包间 GAP 必须 >= GAPL (D-PHY HS FIFO 排空)
        $display("[GAP] min packet gap = %0d clk (GAPL=%0d), violations = %0d",
                 min_gap, GAPL, gap_viol);
        if (gap_viol != 0) begin
            $display("GAP TOO SMALL: %0d packet boundaries had gap < %0d", gap_viol, GAPL);
            err = 1;
        end

        if (err) $display("RESULT: FAIL");
        else     $display("RESULT: PASS (%0d bytes)", ngot);
        $finish;
    end

endmodule
