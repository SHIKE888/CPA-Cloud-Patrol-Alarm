//=============================================================================
// tb_idelay.v — 证明 PH1_LOGIC_DYNAMIC_IDELAY 的 indly_en 是【电平使能】
//   模型: assign o = indly_en ? dly_o : i;   // dly_o = #(170 + in_dly*23) i
//   结论: 若 indly_en 只在换 tap 时响 1 拍, 其余时间 o == i (无延时)
//=============================================================================
`timescale 1ns/1ps
module tb_idelay;

    reg  clk = 0;
    always #5 clk = ~clk;            // 100MHz, 周期 10ns

    reg  [4:0] dly = 5'd20;          // 20 tap -> 170 + 460 = 630ps
    reg        en_pulse  = 1'b0;
    reg        en_level  = 1'b1;
    wire       o_pulse, o_level;

    PH1_LOGIC_DYNAMIC_IDELAY #(.WIDTH(5)) u_pulse (
        .i(clk), .indly_en(en_pulse), .in_dly(dly), .o(o_pulse)
    );
    PH1_LOGIC_DYNAMIC_IDELAY #(.WIDTH(5)) u_level (
        .i(clk), .indly_en(en_level), .in_dly(dly), .o(o_level)
    );

    realtime tp, tl;
    initial begin
        // 只给 1 拍使能 (模拟原代码 O_delay_vaild)
        @(negedge clk); en_pulse = 1'b1;
        @(posedge clk); @(posedge clk); en_pulse = 1'b0;

        repeat (3) @(posedge clk);
        tp = $realtime;
        @(posedge o_pulse);
        tp = $realtime - tp;

        repeat (3) @(posedge clk);
        tl = $realtime;
        @(posedge o_level);
        tl = $realtime - tl;

        $display("--------------------------------------------------");
        $display("in_dly = %0d -> 模型延时 = %0d ps", dly, 170 + dly*23);
        $display("one-shot enable : 输出比输入晚 %0.3f ns", tp);
        $display("level   enable  : 输出比输入晚 %0.3f ns", tl);
        if (tl > 0.5 && tp < 0.1)
            $display("CONFIRMED: 单拍使能 == 没有延时; 必须常开电平");
        else
            $display("UNEXPECTED");
        $finish;
    end
endmodule
