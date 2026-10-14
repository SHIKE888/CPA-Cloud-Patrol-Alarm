//==============================================================================
//  jpeg_defs.vh
//  JPEG 标准表 —— **本文件由 tools/gen_jpeg_tables.py 自动生成, 请勿手改**
//
//  数据来源: ITU-T T.81 (JPEG) Annex K
//    K.1 量化表      -> jpeg_q_lum / jpeg_q_chr
//    K.3 DC 差分表   -> jpeg_huff_dc_lum / jpeg_huff_dc_chr
//    K.5 AC 系数表   -> jpeg_huff_ac_lum / jpeg_huff_ac_chr
//    H  无损 DC 表   -> jpeg_huff_lossless
//
//  霍夫曼查表函数返回 21 位: [20:16]=码长(1..16), [15:0]=码字(低位对齐)
//  生成时已做 Kraft 不等式与前缀性自校验, 并与规范给出的已知码字交叉比对。
//==============================================================================
`ifndef JPEG_DEFS_VH
`define JPEG_DEFS_VH

//--------------------------------------------------------------- 图像参数
localparam JPEG_H_ACTIVE = 1920;    // 有效宽度
localparam JPEG_V_ACTIVE = 1080;    // 有效高度
localparam JPEG_MCU_W    = 16;      // MCU 宽 (4:2:2 = 2 个 Y 块)
localparam JPEG_MCU_H    = 8;       // MCU 高
localparam JPEG_MCU_X    = JPEG_H_ACTIVE / JPEG_MCU_W;   // 120
localparam JPEG_MCU_Y    = JPEG_V_ACTIVE / JPEG_MCU_H;   // 135
localparam JPEG_BLK_MIN  = 0;       // 系数最小 -1023 (10 位有符号)
localparam JPEG_BLK_MAX  = 1023;

//--------------------------------------------------------------- AAN 常数 (Q15)
localparam [15:0] AAN_ONE = 16'd32768;
localparam [15:0] AAN_C1 = 16'd32138;
localparam [15:0] AAN_C2 = 16'd30274;
localparam [15:0] AAN_C3 = 16'd27246;
localparam [15:0] AAN_C5 = 16'd18205;
localparam [15:0] AAN_C6 = 16'd12540;
localparam [15:0] AAN_C7 = 16'd6393;


//--------------------------------------------------------------- 量化表 (Annex K.1)
// 亮度量化表基准值 (质量 50)
function [7:0] jpeg_q_lum;
    input [5:0] idx;
    begin
        case (idx)
            6'd0 : jpeg_q_lum = 8'd 16;
            6'd1 : jpeg_q_lum = 8'd 11;
            6'd2 : jpeg_q_lum = 8'd 10;
            6'd3 : jpeg_q_lum = 8'd 16;
            6'd4 : jpeg_q_lum = 8'd 24;
            6'd5 : jpeg_q_lum = 8'd 40;
            6'd6 : jpeg_q_lum = 8'd 51;
            6'd7 : jpeg_q_lum = 8'd 61;
            6'd8 : jpeg_q_lum = 8'd 12;
            6'd9 : jpeg_q_lum = 8'd 12;
            6'd10: jpeg_q_lum = 8'd 14;
            6'd11: jpeg_q_lum = 8'd 19;
            6'd12: jpeg_q_lum = 8'd 26;
            6'd13: jpeg_q_lum = 8'd 58;
            6'd14: jpeg_q_lum = 8'd 60;
            6'd15: jpeg_q_lum = 8'd 55;
            6'd16: jpeg_q_lum = 8'd 14;
            6'd17: jpeg_q_lum = 8'd 13;
            6'd18: jpeg_q_lum = 8'd 16;
            6'd19: jpeg_q_lum = 8'd 24;
            6'd20: jpeg_q_lum = 8'd 40;
            6'd21: jpeg_q_lum = 8'd 57;
            6'd22: jpeg_q_lum = 8'd 69;
            6'd23: jpeg_q_lum = 8'd 56;
            6'd24: jpeg_q_lum = 8'd 14;
            6'd25: jpeg_q_lum = 8'd 17;
            6'd26: jpeg_q_lum = 8'd 22;
            6'd27: jpeg_q_lum = 8'd 29;
            6'd28: jpeg_q_lum = 8'd 51;
            6'd29: jpeg_q_lum = 8'd 87;
            6'd30: jpeg_q_lum = 8'd 80;
            6'd31: jpeg_q_lum = 8'd 62;
            6'd32: jpeg_q_lum = 8'd 18;
            6'd33: jpeg_q_lum = 8'd 22;
            6'd34: jpeg_q_lum = 8'd 37;
            6'd35: jpeg_q_lum = 8'd 56;
            6'd36: jpeg_q_lum = 8'd 68;
            6'd37: jpeg_q_lum = 8'd109;
            6'd38: jpeg_q_lum = 8'd103;
            6'd39: jpeg_q_lum = 8'd 77;
            6'd40: jpeg_q_lum = 8'd 24;
            6'd41: jpeg_q_lum = 8'd 35;
            6'd42: jpeg_q_lum = 8'd 55;
            6'd43: jpeg_q_lum = 8'd 64;
            6'd44: jpeg_q_lum = 8'd 81;
            6'd45: jpeg_q_lum = 8'd104;
            6'd46: jpeg_q_lum = 8'd113;
            6'd47: jpeg_q_lum = 8'd 92;
            6'd48: jpeg_q_lum = 8'd 49;
            6'd49: jpeg_q_lum = 8'd 64;
            6'd50: jpeg_q_lum = 8'd 78;
            6'd51: jpeg_q_lum = 8'd 87;
            6'd52: jpeg_q_lum = 8'd103;
            6'd53: jpeg_q_lum = 8'd121;
            6'd54: jpeg_q_lum = 8'd120;
            6'd55: jpeg_q_lum = 8'd101;
            6'd56: jpeg_q_lum = 8'd 72;
            6'd57: jpeg_q_lum = 8'd 92;
            6'd58: jpeg_q_lum = 8'd 95;
            6'd59: jpeg_q_lum = 8'd 98;
            6'd60: jpeg_q_lum = 8'd112;
            6'd61: jpeg_q_lum = 8'd100;
            6'd62: jpeg_q_lum = 8'd103;
            6'd63: jpeg_q_lum = 8'd 99;
            default: jpeg_q_lum = 8'd255;
        endcase
    end
endfunction

// 色度量化表基准值 (质量 50)
function [7:0] jpeg_q_chr;
    input [5:0] idx;
    begin
        case (idx)
            6'd0 : jpeg_q_chr = 8'd 17;
            6'd1 : jpeg_q_chr = 8'd 18;
            6'd2 : jpeg_q_chr = 8'd 24;
            6'd3 : jpeg_q_chr = 8'd 47;
            6'd4 : jpeg_q_chr = 8'd 99;
            6'd5 : jpeg_q_chr = 8'd 99;
            6'd6 : jpeg_q_chr = 8'd 99;
            6'd7 : jpeg_q_chr = 8'd 99;
            6'd8 : jpeg_q_chr = 8'd 18;
            6'd9 : jpeg_q_chr = 8'd 21;
            6'd10: jpeg_q_chr = 8'd 26;
            6'd11: jpeg_q_chr = 8'd 66;
            6'd12: jpeg_q_chr = 8'd 99;
            6'd13: jpeg_q_chr = 8'd 99;
            6'd14: jpeg_q_chr = 8'd 99;
            6'd15: jpeg_q_chr = 8'd 99;
            6'd16: jpeg_q_chr = 8'd 24;
            6'd17: jpeg_q_chr = 8'd 26;
            6'd18: jpeg_q_chr = 8'd 56;
            6'd19: jpeg_q_chr = 8'd 99;
            6'd20: jpeg_q_chr = 8'd 99;
            6'd21: jpeg_q_chr = 8'd 99;
            6'd22: jpeg_q_chr = 8'd 99;
            6'd23: jpeg_q_chr = 8'd 99;
            6'd24: jpeg_q_chr = 8'd 47;
            6'd25: jpeg_q_chr = 8'd 26;
            6'd26: jpeg_q_chr = 8'd 66;
            6'd27: jpeg_q_chr = 8'd 99;
            6'd28: jpeg_q_chr = 8'd 99;
            6'd29: jpeg_q_chr = 8'd 99;
            6'd30: jpeg_q_chr = 8'd 99;
            6'd31: jpeg_q_chr = 8'd 99;
            6'd32: jpeg_q_chr = 8'd 99;
            6'd33: jpeg_q_chr = 8'd 99;
            6'd34: jpeg_q_chr = 8'd 99;
            6'd35: jpeg_q_chr = 8'd 99;
            6'd36: jpeg_q_chr = 8'd 99;
            6'd37: jpeg_q_chr = 8'd 99;
            6'd38: jpeg_q_chr = 8'd 99;
            6'd39: jpeg_q_chr = 8'd 99;
            6'd40: jpeg_q_chr = 8'd 99;
            6'd41: jpeg_q_chr = 8'd 99;
            6'd42: jpeg_q_chr = 8'd 99;
            6'd43: jpeg_q_chr = 8'd 99;
            6'd44: jpeg_q_chr = 8'd 99;
            6'd45: jpeg_q_chr = 8'd 99;
            6'd46: jpeg_q_chr = 8'd 99;
            6'd47: jpeg_q_chr = 8'd 99;
            6'd48: jpeg_q_chr = 8'd 99;
            6'd49: jpeg_q_chr = 8'd 99;
            6'd50: jpeg_q_chr = 8'd 99;
            6'd51: jpeg_q_chr = 8'd 99;
            6'd52: jpeg_q_chr = 8'd 99;
            6'd53: jpeg_q_chr = 8'd 99;
            6'd54: jpeg_q_chr = 8'd 99;
            6'd55: jpeg_q_chr = 8'd 99;
            6'd56: jpeg_q_chr = 8'd 99;
            6'd57: jpeg_q_chr = 8'd 99;
            6'd58: jpeg_q_chr = 8'd 99;
            6'd59: jpeg_q_chr = 8'd 99;
            6'd60: jpeg_q_chr = 8'd 99;
            6'd61: jpeg_q_chr = 8'd 99;
            6'd62: jpeg_q_chr = 8'd 99;
            6'd63: jpeg_q_chr = 8'd 99;
            default: jpeg_q_chr = 8'd255;
        endcase
    end
endfunction

//--------------------------------------------------------------- zigzag
// zigzag 顺序: 索引 k -> 自然(行优先)系数下标
function [5:0] jpeg_zigzag;
    input [5:0] k;
    begin
        case (k)
            6'd0 : jpeg_zigzag = 6'd0 ;
            6'd1 : jpeg_zigzag = 6'd1 ;
            6'd2 : jpeg_zigzag = 6'd8 ;
            6'd3 : jpeg_zigzag = 6'd16;
            6'd4 : jpeg_zigzag = 6'd9 ;
            6'd5 : jpeg_zigzag = 6'd2 ;
            6'd6 : jpeg_zigzag = 6'd3 ;
            6'd7 : jpeg_zigzag = 6'd10;
            6'd8 : jpeg_zigzag = 6'd17;
            6'd9 : jpeg_zigzag = 6'd24;
            6'd10: jpeg_zigzag = 6'd32;
            6'd11: jpeg_zigzag = 6'd25;
            6'd12: jpeg_zigzag = 6'd18;
            6'd13: jpeg_zigzag = 6'd11;
            6'd14: jpeg_zigzag = 6'd4 ;
            6'd15: jpeg_zigzag = 6'd5 ;
            6'd16: jpeg_zigzag = 6'd12;
            6'd17: jpeg_zigzag = 6'd19;
            6'd18: jpeg_zigzag = 6'd26;
            6'd19: jpeg_zigzag = 6'd33;
            6'd20: jpeg_zigzag = 6'd40;
            6'd21: jpeg_zigzag = 6'd48;
            6'd22: jpeg_zigzag = 6'd41;
            6'd23: jpeg_zigzag = 6'd34;
            6'd24: jpeg_zigzag = 6'd27;
            6'd25: jpeg_zigzag = 6'd20;
            6'd26: jpeg_zigzag = 6'd13;
            6'd27: jpeg_zigzag = 6'd6 ;
            6'd28: jpeg_zigzag = 6'd7 ;
            6'd29: jpeg_zigzag = 6'd14;
            6'd30: jpeg_zigzag = 6'd21;
            6'd31: jpeg_zigzag = 6'd28;
            6'd32: jpeg_zigzag = 6'd35;
            6'd33: jpeg_zigzag = 6'd42;
            6'd34: jpeg_zigzag = 6'd49;
            6'd35: jpeg_zigzag = 6'd56;
            6'd36: jpeg_zigzag = 6'd57;
            6'd37: jpeg_zigzag = 6'd50;
            6'd38: jpeg_zigzag = 6'd43;
            6'd39: jpeg_zigzag = 6'd36;
            6'd40: jpeg_zigzag = 6'd29;
            6'd41: jpeg_zigzag = 6'd22;
            6'd42: jpeg_zigzag = 6'd15;
            6'd43: jpeg_zigzag = 6'd23;
            6'd44: jpeg_zigzag = 6'd30;
            6'd45: jpeg_zigzag = 6'd37;
            6'd46: jpeg_zigzag = 6'd44;
            6'd47: jpeg_zigzag = 6'd51;
            6'd48: jpeg_zigzag = 6'd58;
            6'd49: jpeg_zigzag = 6'd59;
            6'd50: jpeg_zigzag = 6'd52;
            6'd51: jpeg_zigzag = 6'd45;
            6'd52: jpeg_zigzag = 6'd38;
            6'd53: jpeg_zigzag = 6'd31;
            6'd54: jpeg_zigzag = 6'd39;
            6'd55: jpeg_zigzag = 6'd46;
            6'd56: jpeg_zigzag = 6'd53;
            6'd57: jpeg_zigzag = 6'd60;
            6'd58: jpeg_zigzag = 6'd61;
            6'd59: jpeg_zigzag = 6'd54;
            6'd60: jpeg_zigzag = 6'd47;
            6'd61: jpeg_zigzag = 6'd55;
            6'd62: jpeg_zigzag = 6'd62;
            6'd63: jpeg_zigzag = 6'd63;
            default: jpeg_zigzag = 6'd0;
        endcase
    end
endfunction

//--------------------------------------------------------------- 霍夫曼表 (Annex K.3 / H)
// DC 差分表 · 亮度 (Table K.3)
function [20:0] jpeg_huff_dc_lum;
    input [7:0] sym;
    begin
        case (sym)
            8'h00: jpeg_huff_dc_lum = 21'h20000;   // 码长 2
            8'h01: jpeg_huff_dc_lum = 21'h30002;   // 码长 3
            8'h02: jpeg_huff_dc_lum = 21'h30003;   // 码长 3
            8'h03: jpeg_huff_dc_lum = 21'h30004;   // 码长 3
            8'h04: jpeg_huff_dc_lum = 21'h30005;   // 码长 3
            8'h05: jpeg_huff_dc_lum = 21'h30006;   // 码长 3
            8'h06: jpeg_huff_dc_lum = 21'h4000E;   // 码长 4
            8'h07: jpeg_huff_dc_lum = 21'h5001E;   // 码长 5
            8'h08: jpeg_huff_dc_lum = 21'h6003E;   // 码长 6
            8'h09: jpeg_huff_dc_lum = 21'h7007E;   // 码长 7
            8'h0A: jpeg_huff_dc_lum = 21'h800FE;   // 码长 8
            8'h0B: jpeg_huff_dc_lum = 21'h901FE;   // 码长 9
            default: jpeg_huff_dc_lum = 21'h00000;
        endcase
    end
endfunction

// DC 差分表 · 色度 (Table K.4)
function [20:0] jpeg_huff_dc_chr;
    input [7:0] sym;
    begin
        case (sym)
            8'h00: jpeg_huff_dc_chr = 21'h20000;   // 码长 2
            8'h01: jpeg_huff_dc_chr = 21'h20001;   // 码长 2
            8'h02: jpeg_huff_dc_chr = 21'h20002;   // 码长 2
            8'h03: jpeg_huff_dc_chr = 21'h30006;   // 码长 3
            8'h04: jpeg_huff_dc_chr = 21'h4000E;   // 码长 4
            8'h05: jpeg_huff_dc_chr = 21'h5001E;   // 码长 5
            8'h06: jpeg_huff_dc_chr = 21'h6003E;   // 码长 6
            8'h07: jpeg_huff_dc_chr = 21'h7007E;   // 码长 7
            8'h08: jpeg_huff_dc_chr = 21'h800FE;   // 码长 8
            8'h09: jpeg_huff_dc_chr = 21'h901FE;   // 码长 9
            8'h0A: jpeg_huff_dc_chr = 21'hA03FE;   // 码长10
            8'h0B: jpeg_huff_dc_chr = 21'hB07FE;   // 码长11
            default: jpeg_huff_dc_chr = 21'h00000;
        endcase
    end
endfunction

// AC 系数表 · 亮度 (Table K.5), 符号 = (游程<<4)|分类
function [20:0] jpeg_huff_ac_lum;
    input [7:0] sym;
    begin
        case (sym)
            8'h00: jpeg_huff_ac_lum = 21'h4000A;   // 码长 4
            8'h01: jpeg_huff_ac_lum = 21'h20000;   // 码长 2
            8'h02: jpeg_huff_ac_lum = 21'h20001;   // 码长 2
            8'h03: jpeg_huff_ac_lum = 21'h30004;   // 码长 3
            8'h04: jpeg_huff_ac_lum = 21'h4000B;   // 码长 4
            8'h05: jpeg_huff_ac_lum = 21'h5001A;   // 码长 5
            8'h06: jpeg_huff_ac_lum = 21'h70078;   // 码长 7
            8'h07: jpeg_huff_ac_lum = 21'h800F8;   // 码长 8
            8'h08: jpeg_huff_ac_lum = 21'hA03F6;   // 码长10
            8'h09: jpeg_huff_ac_lum = 21'h10FF82;   // 码长16
            8'h0A: jpeg_huff_ac_lum = 21'h10FF83;   // 码长16
            8'h11: jpeg_huff_ac_lum = 21'h4000C;   // 码长 4
            8'h12: jpeg_huff_ac_lum = 21'h5001B;   // 码长 5
            8'h13: jpeg_huff_ac_lum = 21'h70079;   // 码长 7
            8'h14: jpeg_huff_ac_lum = 21'h901F6;   // 码长 9
            8'h15: jpeg_huff_ac_lum = 21'hB07F6;   // 码长11
            8'h16: jpeg_huff_ac_lum = 21'h10FF84;   // 码长16
            8'h17: jpeg_huff_ac_lum = 21'h10FF85;   // 码长16
            8'h18: jpeg_huff_ac_lum = 21'h10FF86;   // 码长16
            8'h19: jpeg_huff_ac_lum = 21'h10FF87;   // 码长16
            8'h1A: jpeg_huff_ac_lum = 21'h10FF88;   // 码长16
            8'h21: jpeg_huff_ac_lum = 21'h5001C;   // 码长 5
            8'h22: jpeg_huff_ac_lum = 21'h800F9;   // 码长 8
            8'h23: jpeg_huff_ac_lum = 21'hA03F7;   // 码长10
            8'h24: jpeg_huff_ac_lum = 21'hC0FF4;   // 码长12
            8'h25: jpeg_huff_ac_lum = 21'h10FF89;   // 码长16
            8'h26: jpeg_huff_ac_lum = 21'h10FF8A;   // 码长16
            8'h27: jpeg_huff_ac_lum = 21'h10FF8B;   // 码长16
            8'h28: jpeg_huff_ac_lum = 21'h10FF8C;   // 码长16
            8'h29: jpeg_huff_ac_lum = 21'h10FF8D;   // 码长16
            8'h2A: jpeg_huff_ac_lum = 21'h10FF8E;   // 码长16
            8'h31: jpeg_huff_ac_lum = 21'h6003A;   // 码长 6
            8'h32: jpeg_huff_ac_lum = 21'h901F7;   // 码长 9
            8'h33: jpeg_huff_ac_lum = 21'hC0FF5;   // 码长12
            8'h34: jpeg_huff_ac_lum = 21'h10FF8F;   // 码长16
            8'h35: jpeg_huff_ac_lum = 21'h10FF90;   // 码长16
            8'h36: jpeg_huff_ac_lum = 21'h10FF91;   // 码长16
            8'h37: jpeg_huff_ac_lum = 21'h10FF92;   // 码长16
            8'h38: jpeg_huff_ac_lum = 21'h10FF93;   // 码长16
            8'h39: jpeg_huff_ac_lum = 21'h10FF94;   // 码长16
            8'h3A: jpeg_huff_ac_lum = 21'h10FF95;   // 码长16
            8'h41: jpeg_huff_ac_lum = 21'h6003B;   // 码长 6
            8'h42: jpeg_huff_ac_lum = 21'hA03F8;   // 码长10
            8'h43: jpeg_huff_ac_lum = 21'h10FF96;   // 码长16
            8'h44: jpeg_huff_ac_lum = 21'h10FF97;   // 码长16
            8'h45: jpeg_huff_ac_lum = 21'h10FF98;   // 码长16
            8'h46: jpeg_huff_ac_lum = 21'h10FF99;   // 码长16
            8'h47: jpeg_huff_ac_lum = 21'h10FF9A;   // 码长16
            8'h48: jpeg_huff_ac_lum = 21'h10FF9B;   // 码长16
            8'h49: jpeg_huff_ac_lum = 21'h10FF9C;   // 码长16
            8'h4A: jpeg_huff_ac_lum = 21'h10FF9D;   // 码长16
            8'h51: jpeg_huff_ac_lum = 21'h7007A;   // 码长 7
            8'h52: jpeg_huff_ac_lum = 21'hB07F7;   // 码长11
            8'h53: jpeg_huff_ac_lum = 21'h10FF9E;   // 码长16
            8'h54: jpeg_huff_ac_lum = 21'h10FF9F;   // 码长16
            8'h55: jpeg_huff_ac_lum = 21'h10FFA0;   // 码长16
            8'h56: jpeg_huff_ac_lum = 21'h10FFA1;   // 码长16
            8'h57: jpeg_huff_ac_lum = 21'h10FFA2;   // 码长16
            8'h58: jpeg_huff_ac_lum = 21'h10FFA3;   // 码长16
            8'h59: jpeg_huff_ac_lum = 21'h10FFA4;   // 码长16
            8'h5A: jpeg_huff_ac_lum = 21'h10FFA5;   // 码长16
            8'h61: jpeg_huff_ac_lum = 21'h7007B;   // 码长 7
            8'h62: jpeg_huff_ac_lum = 21'hC0FF6;   // 码长12
            8'h63: jpeg_huff_ac_lum = 21'h10FFA6;   // 码长16
            8'h64: jpeg_huff_ac_lum = 21'h10FFA7;   // 码长16
            8'h65: jpeg_huff_ac_lum = 21'h10FFA8;   // 码长16
            8'h66: jpeg_huff_ac_lum = 21'h10FFA9;   // 码长16
            8'h67: jpeg_huff_ac_lum = 21'h10FFAA;   // 码长16
            8'h68: jpeg_huff_ac_lum = 21'h10FFAB;   // 码长16
            8'h69: jpeg_huff_ac_lum = 21'h10FFAC;   // 码长16
            8'h6A: jpeg_huff_ac_lum = 21'h10FFAD;   // 码长16
            8'h71: jpeg_huff_ac_lum = 21'h800FA;   // 码长 8
            8'h72: jpeg_huff_ac_lum = 21'hC0FF7;   // 码长12
            8'h73: jpeg_huff_ac_lum = 21'h10FFAE;   // 码长16
            8'h74: jpeg_huff_ac_lum = 21'h10FFAF;   // 码长16
            8'h75: jpeg_huff_ac_lum = 21'h10FFB0;   // 码长16
            8'h76: jpeg_huff_ac_lum = 21'h10FFB1;   // 码长16
            8'h77: jpeg_huff_ac_lum = 21'h10FFB2;   // 码长16
            8'h78: jpeg_huff_ac_lum = 21'h10FFB3;   // 码长16
            8'h79: jpeg_huff_ac_lum = 21'h10FFB4;   // 码长16
            8'h7A: jpeg_huff_ac_lum = 21'h10FFB5;   // 码长16
            8'h81: jpeg_huff_ac_lum = 21'h901F8;   // 码长 9
            8'h82: jpeg_huff_ac_lum = 21'hF7FC0;   // 码长15
            8'h83: jpeg_huff_ac_lum = 21'h10FFB6;   // 码长16
            8'h84: jpeg_huff_ac_lum = 21'h10FFB7;   // 码长16
            8'h85: jpeg_huff_ac_lum = 21'h10FFB8;   // 码长16
            8'h86: jpeg_huff_ac_lum = 21'h10FFB9;   // 码长16
            8'h87: jpeg_huff_ac_lum = 21'h10FFBA;   // 码长16
            8'h88: jpeg_huff_ac_lum = 21'h10FFBB;   // 码长16
            8'h89: jpeg_huff_ac_lum = 21'h10FFBC;   // 码长16
            8'h8A: jpeg_huff_ac_lum = 21'h10FFBD;   // 码长16
            8'h91: jpeg_huff_ac_lum = 21'h901F9;   // 码长 9
            8'h92: jpeg_huff_ac_lum = 21'h10FFBE;   // 码长16
            8'h93: jpeg_huff_ac_lum = 21'h10FFBF;   // 码长16
            8'h94: jpeg_huff_ac_lum = 21'h10FFC0;   // 码长16
            8'h95: jpeg_huff_ac_lum = 21'h10FFC1;   // 码长16
            8'h96: jpeg_huff_ac_lum = 21'h10FFC2;   // 码长16
            8'h97: jpeg_huff_ac_lum = 21'h10FFC3;   // 码长16
            8'h98: jpeg_huff_ac_lum = 21'h10FFC4;   // 码长16
            8'h99: jpeg_huff_ac_lum = 21'h10FFC5;   // 码长16
            8'h9A: jpeg_huff_ac_lum = 21'h10FFC6;   // 码长16
            8'hA1: jpeg_huff_ac_lum = 21'h901FA;   // 码长 9
            8'hA2: jpeg_huff_ac_lum = 21'h10FFC7;   // 码长16
            8'hA3: jpeg_huff_ac_lum = 21'h10FFC8;   // 码长16
            8'hA4: jpeg_huff_ac_lum = 21'h10FFC9;   // 码长16
            8'hA5: jpeg_huff_ac_lum = 21'h10FFCA;   // 码长16
            8'hA6: jpeg_huff_ac_lum = 21'h10FFCB;   // 码长16
            8'hA7: jpeg_huff_ac_lum = 21'h10FFCC;   // 码长16
            8'hA8: jpeg_huff_ac_lum = 21'h10FFCD;   // 码长16
            8'hA9: jpeg_huff_ac_lum = 21'h10FFCE;   // 码长16
            8'hAA: jpeg_huff_ac_lum = 21'h10FFCF;   // 码长16
            8'hB1: jpeg_huff_ac_lum = 21'hA03F9;   // 码长10
            8'hB2: jpeg_huff_ac_lum = 21'h10FFD0;   // 码长16
            8'hB3: jpeg_huff_ac_lum = 21'h10FFD1;   // 码长16
            8'hB4: jpeg_huff_ac_lum = 21'h10FFD2;   // 码长16
            8'hB5: jpeg_huff_ac_lum = 21'h10FFD3;   // 码长16
            8'hB6: jpeg_huff_ac_lum = 21'h10FFD4;   // 码长16
            8'hB7: jpeg_huff_ac_lum = 21'h10FFD5;   // 码长16
            8'hB8: jpeg_huff_ac_lum = 21'h10FFD6;   // 码长16
            8'hB9: jpeg_huff_ac_lum = 21'h10FFD7;   // 码长16
            8'hBA: jpeg_huff_ac_lum = 21'h10FFD8;   // 码长16
            8'hC1: jpeg_huff_ac_lum = 21'hA03FA;   // 码长10
            8'hC2: jpeg_huff_ac_lum = 21'h10FFD9;   // 码长16
            8'hC3: jpeg_huff_ac_lum = 21'h10FFDA;   // 码长16
            8'hC4: jpeg_huff_ac_lum = 21'h10FFDB;   // 码长16
            8'hC5: jpeg_huff_ac_lum = 21'h10FFDC;   // 码长16
            8'hC6: jpeg_huff_ac_lum = 21'h10FFDD;   // 码长16
            8'hC7: jpeg_huff_ac_lum = 21'h10FFDE;   // 码长16
            8'hC8: jpeg_huff_ac_lum = 21'h10FFDF;   // 码长16
            8'hC9: jpeg_huff_ac_lum = 21'h10FFE0;   // 码长16
            8'hCA: jpeg_huff_ac_lum = 21'h10FFE1;   // 码长16
            8'hD1: jpeg_huff_ac_lum = 21'hB07F8;   // 码长11
            8'hD2: jpeg_huff_ac_lum = 21'h10FFE2;   // 码长16
            8'hD3: jpeg_huff_ac_lum = 21'h10FFE3;   // 码长16
            8'hD4: jpeg_huff_ac_lum = 21'h10FFE4;   // 码长16
            8'hD5: jpeg_huff_ac_lum = 21'h10FFE5;   // 码长16
            8'hD6: jpeg_huff_ac_lum = 21'h10FFE6;   // 码长16
            8'hD7: jpeg_huff_ac_lum = 21'h10FFE7;   // 码长16
            8'hD8: jpeg_huff_ac_lum = 21'h10FFE8;   // 码长16
            8'hD9: jpeg_huff_ac_lum = 21'h10FFE9;   // 码长16
            8'hDA: jpeg_huff_ac_lum = 21'h10FFEA;   // 码长16
            8'hE1: jpeg_huff_ac_lum = 21'h10FFEB;   // 码长16
            8'hE2: jpeg_huff_ac_lum = 21'h10FFEC;   // 码长16
            8'hE3: jpeg_huff_ac_lum = 21'h10FFED;   // 码长16
            8'hE4: jpeg_huff_ac_lum = 21'h10FFEE;   // 码长16
            8'hE5: jpeg_huff_ac_lum = 21'h10FFEF;   // 码长16
            8'hE6: jpeg_huff_ac_lum = 21'h10FFF0;   // 码长16
            8'hE7: jpeg_huff_ac_lum = 21'h10FFF1;   // 码长16
            8'hE8: jpeg_huff_ac_lum = 21'h10FFF2;   // 码长16
            8'hE9: jpeg_huff_ac_lum = 21'h10FFF3;   // 码长16
            8'hEA: jpeg_huff_ac_lum = 21'h10FFF4;   // 码长16
            8'hF0: jpeg_huff_ac_lum = 21'hB07F9;   // 码长11
            8'hF1: jpeg_huff_ac_lum = 21'h10FFF5;   // 码长16
            8'hF2: jpeg_huff_ac_lum = 21'h10FFF6;   // 码长16
            8'hF3: jpeg_huff_ac_lum = 21'h10FFF7;   // 码长16
            8'hF4: jpeg_huff_ac_lum = 21'h10FFF8;   // 码长16
            8'hF5: jpeg_huff_ac_lum = 21'h10FFF9;   // 码长16
            8'hF6: jpeg_huff_ac_lum = 21'h10FFFA;   // 码长16
            8'hF7: jpeg_huff_ac_lum = 21'h10FFFB;   // 码长16
            8'hF8: jpeg_huff_ac_lum = 21'h10FFFC;   // 码长16
            8'hF9: jpeg_huff_ac_lum = 21'h10FFFD;   // 码长16
            8'hFA: jpeg_huff_ac_lum = 21'h10FFFE;   // 码长16
            default: jpeg_huff_ac_lum = 21'h00000;
        endcase
    end
endfunction

// AC 系数表 · 色度 (Table K.6)
function [20:0] jpeg_huff_ac_chr;
    input [7:0] sym;
    begin
        case (sym)
            8'h00: jpeg_huff_ac_chr = 21'h20000;   // 码长 2
            8'h01: jpeg_huff_ac_chr = 21'h20001;   // 码长 2
            8'h02: jpeg_huff_ac_chr = 21'h30004;   // 码长 3
            8'h03: jpeg_huff_ac_chr = 21'h4000A;   // 码长 4
            8'h04: jpeg_huff_ac_chr = 21'h50018;   // 码长 5
            8'h05: jpeg_huff_ac_chr = 21'h50019;   // 码长 5
            8'h06: jpeg_huff_ac_chr = 21'h60038;   // 码长 6
            8'h07: jpeg_huff_ac_chr = 21'h70078;   // 码长 7
            8'h08: jpeg_huff_ac_chr = 21'h901F4;   // 码长 9
            8'h09: jpeg_huff_ac_chr = 21'hA03F6;   // 码长10
            8'h0A: jpeg_huff_ac_chr = 21'hC0FF4;   // 码长12
            8'h11: jpeg_huff_ac_chr = 21'h4000B;   // 码长 4
            8'h12: jpeg_huff_ac_chr = 21'h60039;   // 码长 6
            8'h13: jpeg_huff_ac_chr = 21'h800F6;   // 码长 8
            8'h14: jpeg_huff_ac_chr = 21'h901F5;   // 码长 9
            8'h15: jpeg_huff_ac_chr = 21'hB07F6;   // 码长11
            8'h16: jpeg_huff_ac_chr = 21'hC0FF5;   // 码长12
            8'h17: jpeg_huff_ac_chr = 21'h10FF88;   // 码长16
            8'h18: jpeg_huff_ac_chr = 21'h10FF89;   // 码长16
            8'h19: jpeg_huff_ac_chr = 21'h10FF8A;   // 码长16
            8'h1A: jpeg_huff_ac_chr = 21'h10FF8B;   // 码长16
            8'h21: jpeg_huff_ac_chr = 21'h5001A;   // 码长 5
            8'h22: jpeg_huff_ac_chr = 21'h800F7;   // 码长 8
            8'h23: jpeg_huff_ac_chr = 21'hA03F7;   // 码长10
            8'h24: jpeg_huff_ac_chr = 21'hC0FF6;   // 码长12
            8'h25: jpeg_huff_ac_chr = 21'hF7FC2;   // 码长15
            8'h26: jpeg_huff_ac_chr = 21'h10FF8C;   // 码长16
            8'h27: jpeg_huff_ac_chr = 21'h10FF8D;   // 码长16
            8'h28: jpeg_huff_ac_chr = 21'h10FF8E;   // 码长16
            8'h29: jpeg_huff_ac_chr = 21'h10FF8F;   // 码长16
            8'h2A: jpeg_huff_ac_chr = 21'h10FF90;   // 码长16
            8'h31: jpeg_huff_ac_chr = 21'h5001B;   // 码长 5
            8'h32: jpeg_huff_ac_chr = 21'h800F8;   // 码长 8
            8'h33: jpeg_huff_ac_chr = 21'hA03F8;   // 码长10
            8'h34: jpeg_huff_ac_chr = 21'hC0FF7;   // 码长12
            8'h35: jpeg_huff_ac_chr = 21'h10FF91;   // 码长16
            8'h36: jpeg_huff_ac_chr = 21'h10FF92;   // 码长16
            8'h37: jpeg_huff_ac_chr = 21'h10FF93;   // 码长16
            8'h38: jpeg_huff_ac_chr = 21'h10FF94;   // 码长16
            8'h39: jpeg_huff_ac_chr = 21'h10FF95;   // 码长16
            8'h3A: jpeg_huff_ac_chr = 21'h10FF96;   // 码长16
            8'h41: jpeg_huff_ac_chr = 21'h6003A;   // 码长 6
            8'h42: jpeg_huff_ac_chr = 21'h901F6;   // 码长 9
            8'h43: jpeg_huff_ac_chr = 21'h10FF97;   // 码长16
            8'h44: jpeg_huff_ac_chr = 21'h10FF98;   // 码长16
            8'h45: jpeg_huff_ac_chr = 21'h10FF99;   // 码长16
            8'h46: jpeg_huff_ac_chr = 21'h10FF9A;   // 码长16
            8'h47: jpeg_huff_ac_chr = 21'h10FF9B;   // 码长16
            8'h48: jpeg_huff_ac_chr = 21'h10FF9C;   // 码长16
            8'h49: jpeg_huff_ac_chr = 21'h10FF9D;   // 码长16
            8'h4A: jpeg_huff_ac_chr = 21'h10FF9E;   // 码长16
            8'h51: jpeg_huff_ac_chr = 21'h6003B;   // 码长 6
            8'h52: jpeg_huff_ac_chr = 21'hA03F9;   // 码长10
            8'h53: jpeg_huff_ac_chr = 21'h10FF9F;   // 码长16
            8'h54: jpeg_huff_ac_chr = 21'h10FFA0;   // 码长16
            8'h55: jpeg_huff_ac_chr = 21'h10FFA1;   // 码长16
            8'h56: jpeg_huff_ac_chr = 21'h10FFA2;   // 码长16
            8'h57: jpeg_huff_ac_chr = 21'h10FFA3;   // 码长16
            8'h58: jpeg_huff_ac_chr = 21'h10FFA4;   // 码长16
            8'h59: jpeg_huff_ac_chr = 21'h10FFA5;   // 码长16
            8'h5A: jpeg_huff_ac_chr = 21'h10FFA6;   // 码长16
            8'h61: jpeg_huff_ac_chr = 21'h70079;   // 码长 7
            8'h62: jpeg_huff_ac_chr = 21'hB07F7;   // 码长11
            8'h63: jpeg_huff_ac_chr = 21'h10FFA7;   // 码长16
            8'h64: jpeg_huff_ac_chr = 21'h10FFA8;   // 码长16
            8'h65: jpeg_huff_ac_chr = 21'h10FFA9;   // 码长16
            8'h66: jpeg_huff_ac_chr = 21'h10FFAA;   // 码长16
            8'h67: jpeg_huff_ac_chr = 21'h10FFAB;   // 码长16
            8'h68: jpeg_huff_ac_chr = 21'h10FFAC;   // 码长16
            8'h69: jpeg_huff_ac_chr = 21'h10FFAD;   // 码长16
            8'h6A: jpeg_huff_ac_chr = 21'h10FFAE;   // 码长16
            8'h71: jpeg_huff_ac_chr = 21'h7007A;   // 码长 7
            8'h72: jpeg_huff_ac_chr = 21'hB07F8;   // 码长11
            8'h73: jpeg_huff_ac_chr = 21'h10FFAF;   // 码长16
            8'h74: jpeg_huff_ac_chr = 21'h10FFB0;   // 码长16
            8'h75: jpeg_huff_ac_chr = 21'h10FFB1;   // 码长16
            8'h76: jpeg_huff_ac_chr = 21'h10FFB2;   // 码长16
            8'h77: jpeg_huff_ac_chr = 21'h10FFB3;   // 码长16
            8'h78: jpeg_huff_ac_chr = 21'h10FFB4;   // 码长16
            8'h79: jpeg_huff_ac_chr = 21'h10FFB5;   // 码长16
            8'h7A: jpeg_huff_ac_chr = 21'h10FFB6;   // 码长16
            8'h81: jpeg_huff_ac_chr = 21'h800F9;   // 码长 8
            8'h82: jpeg_huff_ac_chr = 21'h10FFB7;   // 码长16
            8'h83: jpeg_huff_ac_chr = 21'h10FFB8;   // 码长16
            8'h84: jpeg_huff_ac_chr = 21'h10FFB9;   // 码长16
            8'h85: jpeg_huff_ac_chr = 21'h10FFBA;   // 码长16
            8'h86: jpeg_huff_ac_chr = 21'h10FFBB;   // 码长16
            8'h87: jpeg_huff_ac_chr = 21'h10FFBC;   // 码长16
            8'h88: jpeg_huff_ac_chr = 21'h10FFBD;   // 码长16
            8'h89: jpeg_huff_ac_chr = 21'h10FFBE;   // 码长16
            8'h8A: jpeg_huff_ac_chr = 21'h10FFBF;   // 码长16
            8'h91: jpeg_huff_ac_chr = 21'h901F7;   // 码长 9
            8'h92: jpeg_huff_ac_chr = 21'h10FFC0;   // 码长16
            8'h93: jpeg_huff_ac_chr = 21'h10FFC1;   // 码长16
            8'h94: jpeg_huff_ac_chr = 21'h10FFC2;   // 码长16
            8'h95: jpeg_huff_ac_chr = 21'h10FFC3;   // 码长16
            8'h96: jpeg_huff_ac_chr = 21'h10FFC4;   // 码长16
            8'h97: jpeg_huff_ac_chr = 21'h10FFC5;   // 码长16
            8'h98: jpeg_huff_ac_chr = 21'h10FFC6;   // 码长16
            8'h99: jpeg_huff_ac_chr = 21'h10FFC7;   // 码长16
            8'h9A: jpeg_huff_ac_chr = 21'h10FFC8;   // 码长16
            8'hA1: jpeg_huff_ac_chr = 21'h901F8;   // 码长 9
            8'hA2: jpeg_huff_ac_chr = 21'h10FFC9;   // 码长16
            8'hA3: jpeg_huff_ac_chr = 21'h10FFCA;   // 码长16
            8'hA4: jpeg_huff_ac_chr = 21'h10FFCB;   // 码长16
            8'hA5: jpeg_huff_ac_chr = 21'h10FFCC;   // 码长16
            8'hA6: jpeg_huff_ac_chr = 21'h10FFCD;   // 码长16
            8'hA7: jpeg_huff_ac_chr = 21'h10FFCE;   // 码长16
            8'hA8: jpeg_huff_ac_chr = 21'h10FFCF;   // 码长16
            8'hA9: jpeg_huff_ac_chr = 21'h10FFD0;   // 码长16
            8'hAA: jpeg_huff_ac_chr = 21'h10FFD1;   // 码长16
            8'hB1: jpeg_huff_ac_chr = 21'h901F9;   // 码长 9
            8'hB2: jpeg_huff_ac_chr = 21'h10FFD2;   // 码长16
            8'hB3: jpeg_huff_ac_chr = 21'h10FFD3;   // 码长16
            8'hB4: jpeg_huff_ac_chr = 21'h10FFD4;   // 码长16
            8'hB5: jpeg_huff_ac_chr = 21'h10FFD5;   // 码长16
            8'hB6: jpeg_huff_ac_chr = 21'h10FFD6;   // 码长16
            8'hB7: jpeg_huff_ac_chr = 21'h10FFD7;   // 码长16
            8'hB8: jpeg_huff_ac_chr = 21'h10FFD8;   // 码长16
            8'hB9: jpeg_huff_ac_chr = 21'h10FFD9;   // 码长16
            8'hBA: jpeg_huff_ac_chr = 21'h10FFDA;   // 码长16
            8'hC1: jpeg_huff_ac_chr = 21'h901FA;   // 码长 9
            8'hC2: jpeg_huff_ac_chr = 21'h10FFDB;   // 码长16
            8'hC3: jpeg_huff_ac_chr = 21'h10FFDC;   // 码长16
            8'hC4: jpeg_huff_ac_chr = 21'h10FFDD;   // 码长16
            8'hC5: jpeg_huff_ac_chr = 21'h10FFDE;   // 码长16
            8'hC6: jpeg_huff_ac_chr = 21'h10FFDF;   // 码长16
            8'hC7: jpeg_huff_ac_chr = 21'h10FFE0;   // 码长16
            8'hC8: jpeg_huff_ac_chr = 21'h10FFE1;   // 码长16
            8'hC9: jpeg_huff_ac_chr = 21'h10FFE2;   // 码长16
            8'hCA: jpeg_huff_ac_chr = 21'h10FFE3;   // 码长16
            8'hD1: jpeg_huff_ac_chr = 21'hB07F9;   // 码长11
            8'hD2: jpeg_huff_ac_chr = 21'h10FFE4;   // 码长16
            8'hD3: jpeg_huff_ac_chr = 21'h10FFE5;   // 码长16
            8'hD4: jpeg_huff_ac_chr = 21'h10FFE6;   // 码长16
            8'hD5: jpeg_huff_ac_chr = 21'h10FFE7;   // 码长16
            8'hD6: jpeg_huff_ac_chr = 21'h10FFE8;   // 码长16
            8'hD7: jpeg_huff_ac_chr = 21'h10FFE9;   // 码长16
            8'hD8: jpeg_huff_ac_chr = 21'h10FFEA;   // 码长16
            8'hD9: jpeg_huff_ac_chr = 21'h10FFEB;   // 码长16
            8'hDA: jpeg_huff_ac_chr = 21'h10FFEC;   // 码长16
            8'hE1: jpeg_huff_ac_chr = 21'hE3FE0;   // 码长14
            8'hE2: jpeg_huff_ac_chr = 21'h10FFED;   // 码长16
            8'hE3: jpeg_huff_ac_chr = 21'h10FFEE;   // 码长16
            8'hE4: jpeg_huff_ac_chr = 21'h10FFEF;   // 码长16
            8'hE5: jpeg_huff_ac_chr = 21'h10FFF0;   // 码长16
            8'hE6: jpeg_huff_ac_chr = 21'h10FFF1;   // 码长16
            8'hE7: jpeg_huff_ac_chr = 21'h10FFF2;   // 码长16
            8'hE8: jpeg_huff_ac_chr = 21'h10FFF3;   // 码长16
            8'hE9: jpeg_huff_ac_chr = 21'h10FFF4;   // 码长16
            8'hEA: jpeg_huff_ac_chr = 21'h10FFF5;   // 码长16
            8'hF0: jpeg_huff_ac_chr = 21'hA03FA;   // 码长10
            8'hF1: jpeg_huff_ac_chr = 21'hF7FC3;   // 码长15
            8'hF2: jpeg_huff_ac_chr = 21'h10FFF6;   // 码长16
            8'hF3: jpeg_huff_ac_chr = 21'h10FFF7;   // 码长16
            8'hF4: jpeg_huff_ac_chr = 21'h10FFF8;   // 码长16
            8'hF5: jpeg_huff_ac_chr = 21'h10FFF9;   // 码长16
            8'hF6: jpeg_huff_ac_chr = 21'h10FFFA;   // 码长16
            8'hF7: jpeg_huff_ac_chr = 21'h10FFFB;   // 码长16
            8'hF8: jpeg_huff_ac_chr = 21'h10FFFC;   // 码长16
            8'hF9: jpeg_huff_ac_chr = 21'h10FFFD;   // 码长16
            8'hFA: jpeg_huff_ac_chr = 21'h10FFFE;   // 码长16
            default: jpeg_huff_ac_chr = 21'h00000;
        endcase
    end
endfunction

// 无损模式 DC 表 (Annex H Table K.3), 符号 = 幅度分类 0..16
function [20:0] jpeg_huff_lossless;
    input [7:0] sym;
    begin
        case (sym)
            8'h00: jpeg_huff_lossless = 21'h20000;   // 码长 2
            8'h01: jpeg_huff_lossless = 21'h30002;   // 码长 3
            8'h02: jpeg_huff_lossless = 21'h30003;   // 码长 3
            8'h03: jpeg_huff_lossless = 21'h30004;   // 码长 3
            8'h04: jpeg_huff_lossless = 21'h30005;   // 码长 3
            8'h05: jpeg_huff_lossless = 21'h30006;   // 码长 3
            8'h06: jpeg_huff_lossless = 21'h4000E;   // 码长 4
            8'h07: jpeg_huff_lossless = 21'h5001E;   // 码长 5
            8'h08: jpeg_huff_lossless = 21'h6003E;   // 码长 6
            8'h09: jpeg_huff_lossless = 21'h7007E;   // 码长 7
            8'h0A: jpeg_huff_lossless = 21'h800FE;   // 码长 8
            8'h0B: jpeg_huff_lossless = 21'h901FE;   // 码长 9
            8'h0C: jpeg_huff_lossless = 21'hA03FE;   // 码长10
            8'h0D: jpeg_huff_lossless = 21'hB07FE;   // 码长11
            8'h0E: jpeg_huff_lossless = 21'hC0FFE;   // 码长12
            8'h0F: jpeg_huff_lossless = 21'hD1FFE;   // 码长13
            8'h10: jpeg_huff_lossless = 21'hE3FFE;   // 码长14
            default: jpeg_huff_lossless = 21'h00000;
        endcase
    end
endfunction

//--------------------------------------------------------------- 工具函数
// 幅度分类: 求 |v| 的位宽, 即 JPEG 的 SSSS (0..15)
//   用 GCC 风格的分支树, 综合成 LUT 与优先级编码器
function [3:0] jpeg_ssss;
    input [15:0] mag;              // 传入 |v|
    begin
        if      (mag < 16'd1)     jpeg_ssss = 4'd0;
        else if (mag < 16'd2)     jpeg_ssss = 4'd1;
        else if (mag < 16'd4)     jpeg_ssss = 4'd2;
        else if (mag < 16'd8)     jpeg_ssss = 4'd3;
        else if (mag < 16'd16)    jpeg_ssss = 4'd4;
        else if (mag < 16'd32)    jpeg_ssss = 4'd5;
        else if (mag < 16'd64)    jpeg_ssss = 4'd6;
        else if (mag < 16'd128)   jpeg_ssss = 4'd7;
        else if (mag < 16'd256)   jpeg_ssss = 4'd8;
        else if (mag < 16'd512)   jpeg_ssss = 4'd9;
        else if (mag < 16'd1024)  jpeg_ssss = 4'd10;
        else if (mag < 16'd2048)  jpeg_ssss = 4'd11;
        else if (mag < 16'd4096)  jpeg_ssss = 4'd12;
        else if (mag < 16'd8192)  jpeg_ssss = 4'd13;
        else if (mag < 16'd16384) jpeg_ssss = 4'd14;
        else                      jpeg_ssss = 4'd15;
    end
endfunction

`endif // JPEG_DEFS_VH
