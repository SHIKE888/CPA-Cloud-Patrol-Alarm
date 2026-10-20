//=============================================================================
// .tmp_idelay_model.v — 本地复刻 PH1_LOGIC_DYNAMIC_IDELAY 的仿真行为
//   与厂商模型等价:
//     dly_o = #(170 + in_dly*23) i      (单位 ps)
//     o     = indly_en ? dly_o : i      (indly_en 是电平使能)
//   仅用于仿真验证语义, 不进工程。
//=============================================================================
`timescale 1ps/1ps
module PH1_LOGIC_DYNAMIC_IDELAY (
    i,
    indly_en,
    in_dly,
    o
);
    parameter WIDTH = 5;
    input             i;
    input             indly_en;
    input  [WIDTH-1:0] in_dly;
    output            o;

    reg dly_int;
    always @(i) dly_int <= #(170 + in_dly*23) i;

    assign o = indly_en ? dly_int : i;
endmodule
