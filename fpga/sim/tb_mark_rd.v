//=============================================================================
//  tb_mark_rd.v —— 验证 dbuf 读侧的帧标记覆盖逻辑
//
//  被测逻辑与 system_top.v 里那段完全一致(照抄), 因为它是内联代码、
//  没法单独例化。
//
//  检查:
//    1. tuser 只来 1 拍时, 连续 4 拍都被覆盖
//    2. 覆盖后 Y 平面头 8 字节 = A5 5A src FF FF src src FF
//    3. S_out_src 切换 -> src 字节在 0x00 / 0x11 之间变
//    4. mark_en=0 -> 一个字节都不动
//    5. tuser 连续来 2 拍 -> 每次重新起一个 4 拍窗口
//=============================================================================
`timescale 1ns/1ps

module tb_mark_rd;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         mark_en = 0;
    reg         out_src = 0;
    reg         s_tuser = 0;
    reg  [31:0] s_tdata = 32'h0;
    wire [31:0] d;

    always #4 clk = ~clk;           // 125MHz 左右

    // ---------------- 被测逻辑 (与 system_top.v 一致) ----------------
    reg  d1, d2, d3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1 <= 1'b0; d2 <= 1'b0; d3 <= 1'b0;
        end else begin
            d1 <= s_tuser;
            d2 <= d1;
            d3 <= d2;
        end
    end

    wire [7:0]  src_b = out_src ? 8'h11 : 8'h00;
    wire [31:0] w0 = { 8'h80, 8'h5A, 8'h80, 8'hA5 };
    wire [31:0] wA = { 8'h80, 8'hFF, 8'h80, src_b };
    wire [31:0] wB = { 8'h80, src_b, 8'h80, 8'hFF };

    assign d = !mark_en ? s_tdata :
               s_tuser  ? w0 :
               d1       ? wA :
               d2       ? wB :
               d3       ? wA :
                          s_tdata;
    // ----------------------------------------------------------------

    integer errors = 0;
    integer n = 0;

    // Y 平面字节收集: 每个 word 低 2 字节是 Y0 Y1(小端), 见下面说明
    //  word = {Cr, Y1, Cb, Y0}  ->  Y0 = [7:0], Y1 = [23:16]
    reg [7:0] ybytes [0:31];
    integer   ycnt;

    task step(input [31:0] data, input tuser);
        begin
            s_tdata = data;
            s_tuser = tuser;
            #1;                           // 等组合逻辑稳定
            ybytes[ycnt]   = d[7:0];      // Y0
            ybytes[ycnt+1] = d[23:16];    // Y1
            ycnt = ycnt + 2;
            @(posedge clk);               // 再推一拍, 让 d1..d3 跟上
            #1;
        end
    endtask

    task reset_all;
        begin
            rst_n = 0; mark_en = 0; out_src = 0; s_tuser = 0;
            s_tdata = 32'h0; ycnt = 0;
            #20 rst_n = 1;
            @(posedge clk); #1;
        end
    endtask

    task chk(input [255:0] name, input integer got, input integer want);
        begin
            n = n + 1;
            if (got !== want) begin
                $display("  FAIL %0s: got=%02X want=%02X", name, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s = %02X", name, got);
            end
        end
    endtask

    initial begin
        // ============ 场景 1: cam0, tuser 1 拍 ============
        $display("[1] mark_en=1, src=cam0, tuser 单拍");
        reset_all;
        mark_en = 1; out_src = 0;
        // 先喂 2 个"普通" word, 让 d1..d3 干净
        step(32'h11223344, 0);
        step(32'h55667788, 0);
        ycnt = 0;
        step(32'hAA000001, 1);        // tuser 拍
        step(32'hBB000002, 0);
        step(32'hCC000003, 0);
        step(32'hDD000004, 0);
        step(32'hEE000005, 0);        // 第 5 拍应该回到原始数据

        chk("Y0", ybytes[0], 8'hA5);
        chk("Y1", ybytes[1], 8'h5A);
        chk("Y2", ybytes[2], 8'h00);   // src=cam0
        chk("Y3", ybytes[3], 8'hFF);
        chk("Y4", ybytes[4], 8'hFF);
        chk("Y5", ybytes[5], 8'h00);
        chk("Y6", ybytes[6], 8'h00);
        chk("Y7", ybytes[7], 8'hFF);
        chk("Y8(回到原始低)", ybytes[8], 8'h05);
        chk("Y9(回到原始高)", ybytes[9], 8'h00);

        // ============ 场景 2: cam1 ============
        $display("[2] mark_en=1, src=cam1");
        reset_all;
        mark_en = 1; out_src = 1;
        step(32'h00000000, 0);
        ycnt = 0;
        step(32'h00000000, 1);
        step(32'h00000000, 0);
        step(32'h00000000, 0);
        step(32'h00000000, 0);
        chk("Y0", ybytes[0], 8'hA5);
        chk("Y1", ybytes[1], 8'h5A);
        chk("Y2", ybytes[2], 8'h11);   // src=cam1
        chk("Y3", ybytes[3], 8'hFF);

        // ============ 场景 3: mark_en=0 ============
        $display("[3] mark_en=0 -> 原样透传");
        reset_all;
        mark_en = 0; out_src = 1;
        step(32'h00000000, 0);
        ycnt = 0;
        step(32'h12345678, 1);
        step(32'h9ABCDEF0, 0);
        chk("Y0(原)", ybytes[0], 8'h78);
        chk("Y1(原)", ybytes[1], 8'h34);   // 字节布局: [7:0]=Y0 [23:16]=Y1
        chk("Y2(原)", ybytes[2], 8'hF0);
        chk("Y3(原)", ybytes[3], 8'hBC);

        // ============ 场景 4: tuser 连来 2 拍 ============
        $display("[4] tuser 连 2 拍 -> 每拍都重起窗口");
        reset_all;
        mark_en = 1; out_src = 1;
        step(32'h00000000, 0);
        ycnt = 0;
        step(32'h00000000, 1);        // tuser
        step(32'h00000000, 1);        // 又一拍 tuser
        step(32'h00000000, 0);
        step(32'h00000000, 0);
        chk("Y0", ybytes[0], 8'hA5);
        chk("Y1", ybytes[1], 8'h5A);
        chk("Y2", ybytes[2], 8'hA5);   // 又是窗口起点
        chk("Y3", ybytes[3], 8'h5A);
        chk("Y4", ybytes[4], 8'h11);   // 之后才是 src/FF
        chk("Y5", ybytes[5], 8'hFF);

        $display("");
        if (errors == 0) begin
            $display("==================================================");
            $display("PASS: 读侧帧标记 %0d 项全过", n);
            $display("==================================================");
        end else begin
            $display("==================================================");
            $display("FAIL: %0d / %0d 项", errors, n);
            $display("==================================================");
        end
        $finish;
    end

endmodule
