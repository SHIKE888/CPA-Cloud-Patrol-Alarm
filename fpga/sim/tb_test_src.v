`timescale 1ns/1ps
//==============================================================================
//  tb_test_src.v —— 验证 csi2_test_src 产生的载荷确实"逐字节可校验"
//
//  验证点:
//    T1  tuser_sof 只在帧首第 1 个 word 上有效
//    T2  tlast 只在每行最后一个 word 上有效 (每 LINE_WORDS 个)
//    T3  帧内第 k 个字节 == (k & 0xFF)            <- 核心, RK 端就是按这条比对
//    T4  一帧发完计数器回绕, 下一帧完全可复现
//    T5  tvalid 全程跟随 enable
//
//  用 H_ACTIVE=1920 / V_ACTIVE=4 (帧 15360 字节, 跨 60 次 256 回绕),
//  既覆盖了行内大偏移, 又不需要跑满 1080 行。
//==============================================================================

module tb_test_src;

    localparam integer H_ACTIVE    = 1920;
    localparam integer V_ACTIVE    = 4;
    localparam integer LINE_BYTES  = H_ACTIVE * 2;         // 3840
    localparam integer LINE_WORDS  = LINE_BYTES / 4;       // 960
    localparam integer FRAME_WORDS = LINE_WORDS * V_ACTIVE;// 3840
    localparam integer FRAME_BYTES = FRAME_WORDS * 4;      // 15360

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg enable = 1'b0;
    always #5 clk = ~clk;

    wire        m_tvalid;
    wire [31:0] m_tdata;
    wire        m_tsof;
    wire        m_tlast;
    reg         m_tready = 1'b1;

    csi2_test_src #(
        .H_ACTIVE (H_ACTIVE),
        .V_ACTIVE (V_ACTIVE),
        .BPP_NUM  (2),
        .BPP_DEN  (1),
        .MODE     (0)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .m_tvalid   (m_tvalid),
        .m_tready   (m_tready),
        .m_tdata    (m_tdata),
        .m_tuser_sof(m_tsof),
        .m_tlast    (m_tlast)
    );

    integer pass = 0, fail = 0;

    task chk(input [8*44-1:0] nm, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) pass = pass + 1;
            else begin
                fail = fail + 1;
                $display("  [FAIL] %0s: got=%0d exp=%0d", nm, got, exp);
            end
        end
    endtask

    // 采集缓冲
    reg [31:0] fdata [0:FRAME_WORDS-1];
    reg        fsof  [0:FRAME_WORDS-1];
    reg        flast [0:FRAME_WORDS-1];

    integer w, i;
    integer n_sof_bad, n_last_bad, n_byte_bad, first_bad;
    reg [7:0]  b_got, b_exp;
    reg [31:0] wrap_word;
    reg        tv_ok;

    initial begin
        $display("==========================================================");
        $display(" csi2_test_src 验证 (帧 %0d 字节 = %0d word)", FRAME_BYTES, FRAME_WORDS);
        $display("==========================================================");

        rst_n = 1'b0;
        enable = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // tvalid 应跟随 enable
        tv_ok = (m_tvalid === 1'b0);

        // 关键: 必须**对齐到帧首**再开始采集。
        // 在 negedge 把 enable 拉高 —— 此时计数器还是 0/0, 组合输出就是帧首那一拍;
        // 之后每过一个 negedge 正好前进一拍。若先跑几拍再采, 就会整体偏移,
        // 后面的逐字节比对全部对不上 (第一版 TB 就是栽在这里)。
        @(negedge clk);
        enable = 1'b1;
        #1;                                     // 等组合输出更新
        tv_ok = tv_ok && (m_tvalid === 1'b1);

        for (w = 0; w < FRAME_WORDS; w = w + 1) begin
            fdata[w] = m_tdata;
            fsof [w] = m_tsof;
            flast[w] = m_tlast;
            @(negedge clk);
        end

        // 再采一拍, 应该已经回绕到帧首
        wrap_word = m_tdata;

        // ---- T5 ----
        chk("T5 tvalid 跟随 enable", {31'b0, tv_ok}, 32'd1);

        // ---- T1 ----
        n_sof_bad = 0;
        for (w = 0; w < FRAME_WORDS; w = w + 1) begin
            if (w == 0) begin
                if (fsof[w] !== 1'b1) n_sof_bad = n_sof_bad + 1;
            end else if (fsof[w] !== 1'b0) n_sof_bad = n_sof_bad + 1;
        end
        chk("T1 tuser_sof 只在帧首 (异常数)", n_sof_bad, 0);

        // ---- T2 ----
        n_last_bad = 0;
        for (w = 0; w < FRAME_WORDS; w = w + 1) begin
            if (((w + 1) % LINE_WORDS) == 0) begin
                if (flast[w] !== 1'b1) n_last_bad = n_last_bad + 1;
            end else if (flast[w] !== 1'b0) n_last_bad = n_last_bad + 1;
        end
        chk("T2 tlast 只在行尾 (异常数)", n_last_bad, 0);

        // ---- T3: 核心 —— 逐字节比对 ----
        n_byte_bad  = 0;
        first_bad   = -1;
        for (w = 0; w < FRAME_WORDS; w = w + 1) begin
            for (i = 0; i < 4; i = i + 1) begin
                b_got = fdata[w][8*i +: 8];
                b_exp = (w * 4 + i) % 256;
                if (b_got !== b_exp) begin
                    if (n_byte_bad == 0) first_bad = w * 4 + i;
                    n_byte_bad = n_byte_bad + 1;
                end
            end
        end
        $display("  T3 逐字节比对: 共 %0d 字节, 不符 %0d 个", FRAME_BYTES, n_byte_bad);
        if (n_byte_bad != 0)
            $display("     第一个不符位置: 第 %0d 字节", first_bad);
        chk("T3 载荷字节 == (k & 0xFF)", n_byte_bad, 0);

        // ---- T4: 回绕 ----
        chk("T4 一帧后回绕到帧首 (word0 == 0x03020100)", wrap_word, 32'h03020100);

        // ---- 抽样打印 ----
        $display("");
        $display("  抽样 (word 序号 -> 32 位值, 期望低字节 = 4n mod 256):");
        for (w = 0; w < FRAME_WORDS; w = w + 960) begin
            $display("    word[%0d] = 0x%08h   (期望低字节 0x%02h)",
                     w, fdata[w], (w * 4) % 256);
        end

        $display("");
        $display("==========================================================");
        $display(" 通过 %0d 项, 失败 %0d 项", pass, fail);
        if (fail == 0) $display(" >>> 测试源载荷正确 <<<");
        else           $display(" >>> 有失败项 <<<");
        $display("==========================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("!! 仿真超时 !!");
        $finish;
    end

endmodule
