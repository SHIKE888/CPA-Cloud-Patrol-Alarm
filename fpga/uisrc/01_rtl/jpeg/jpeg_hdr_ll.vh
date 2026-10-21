//==============================================================================
//  jpeg_hdr_ll.vh
//  JPEG 固定头部字节 ROM —— **由 tools/gen_jpeg_hdr_rom.py 自动生成, 请勿手改**
//
//  总长 91 字节。可变位置 (ROM 里填 0 占位, RTL 输出时替换):
//     h @ 25
//     w @ 27
//==============================================================================

function [7:0] jpeg_hdr_ll;
    input [9:0] a;
    begin
        case (a)
        10'd0   : jpeg_hdr_ll = 8'hFF;
        10'd1   : jpeg_hdr_ll = 8'hD8;
        10'd2   : jpeg_hdr_ll = 8'hFF;
        10'd3   : jpeg_hdr_ll = 8'hE0;
        10'd4   : jpeg_hdr_ll = 8'h00;
        10'd5   : jpeg_hdr_ll = 8'h10;
        10'd6   : jpeg_hdr_ll = 8'h4A;
        10'd7   : jpeg_hdr_ll = 8'h46;
        10'd8   : jpeg_hdr_ll = 8'h49;
        10'd9   : jpeg_hdr_ll = 8'h46;
        10'd10  : jpeg_hdr_ll = 8'h00;
        10'd11  : jpeg_hdr_ll = 8'h01;
        10'd12  : jpeg_hdr_ll = 8'h01;
        10'd13  : jpeg_hdr_ll = 8'h00;
        10'd14  : jpeg_hdr_ll = 8'h00;
        10'd15  : jpeg_hdr_ll = 8'h01;
        10'd16  : jpeg_hdr_ll = 8'h00;
        10'd17  : jpeg_hdr_ll = 8'h01;
        10'd18  : jpeg_hdr_ll = 8'h00;
        10'd19  : jpeg_hdr_ll = 8'h00;
        10'd20  : jpeg_hdr_ll = 8'hFF;
        10'd21  : jpeg_hdr_ll = 8'hC3;
        10'd22  : jpeg_hdr_ll = 8'h00;
        10'd23  : jpeg_hdr_ll = 8'h11;
        10'd24  : jpeg_hdr_ll = 8'h08;
        10'd25  : jpeg_hdr_ll = 8'h00;
        10'd26  : jpeg_hdr_ll = 8'h00;
        10'd27  : jpeg_hdr_ll = 8'h00;
        10'd28  : jpeg_hdr_ll = 8'h00;
        10'd29  : jpeg_hdr_ll = 8'h03;
        10'd30  : jpeg_hdr_ll = 8'h01;
        10'd31  : jpeg_hdr_ll = 8'h21;
        10'd32  : jpeg_hdr_ll = 8'h00;
        10'd33  : jpeg_hdr_ll = 8'h02;
        10'd34  : jpeg_hdr_ll = 8'h11;
        10'd35  : jpeg_hdr_ll = 8'h00;
        10'd36  : jpeg_hdr_ll = 8'h03;
        10'd37  : jpeg_hdr_ll = 8'h11;
        10'd38  : jpeg_hdr_ll = 8'h00;
        10'd39  : jpeg_hdr_ll = 8'hFF;
        10'd40  : jpeg_hdr_ll = 8'hC4;
        10'd41  : jpeg_hdr_ll = 8'h00;
        10'd42  : jpeg_hdr_ll = 8'h24;
        10'd43  : jpeg_hdr_ll = 8'h00;
        10'd44  : jpeg_hdr_ll = 8'h00;
        10'd45  : jpeg_hdr_ll = 8'h01;
        10'd46  : jpeg_hdr_ll = 8'h05;
        10'd47  : jpeg_hdr_ll = 8'h01;
        10'd48  : jpeg_hdr_ll = 8'h01;
        10'd49  : jpeg_hdr_ll = 8'h01;
        10'd50  : jpeg_hdr_ll = 8'h01;
        10'd51  : jpeg_hdr_ll = 8'h01;
        10'd52  : jpeg_hdr_ll = 8'h01;
        10'd53  : jpeg_hdr_ll = 8'h01;
        10'd54  : jpeg_hdr_ll = 8'h01;
        10'd55  : jpeg_hdr_ll = 8'h01;
        10'd56  : jpeg_hdr_ll = 8'h01;
        10'd57  : jpeg_hdr_ll = 8'h01;
        10'd58  : jpeg_hdr_ll = 8'h00;
        10'd59  : jpeg_hdr_ll = 8'h00;
        10'd60  : jpeg_hdr_ll = 8'h00;
        10'd61  : jpeg_hdr_ll = 8'h01;
        10'd62  : jpeg_hdr_ll = 8'h02;
        10'd63  : jpeg_hdr_ll = 8'h03;
        10'd64  : jpeg_hdr_ll = 8'h04;
        10'd65  : jpeg_hdr_ll = 8'h05;
        10'd66  : jpeg_hdr_ll = 8'h06;
        10'd67  : jpeg_hdr_ll = 8'h07;
        10'd68  : jpeg_hdr_ll = 8'h08;
        10'd69  : jpeg_hdr_ll = 8'h09;
        10'd70  : jpeg_hdr_ll = 8'h0A;
        10'd71  : jpeg_hdr_ll = 8'h0B;
        10'd72  : jpeg_hdr_ll = 8'h0C;
        10'd73  : jpeg_hdr_ll = 8'h0D;
        10'd74  : jpeg_hdr_ll = 8'h0E;
        10'd75  : jpeg_hdr_ll = 8'h0F;
        10'd76  : jpeg_hdr_ll = 8'h10;
        10'd77  : jpeg_hdr_ll = 8'hFF;
        10'd78  : jpeg_hdr_ll = 8'hDA;
        10'd79  : jpeg_hdr_ll = 8'h00;
        10'd80  : jpeg_hdr_ll = 8'h0C;
        10'd81  : jpeg_hdr_ll = 8'h03;
        10'd82  : jpeg_hdr_ll = 8'h01;
        10'd83  : jpeg_hdr_ll = 8'h00;
        10'd84  : jpeg_hdr_ll = 8'h02;
        10'd85  : jpeg_hdr_ll = 8'h11;
        10'd86  : jpeg_hdr_ll = 8'h03;
        10'd87  : jpeg_hdr_ll = 8'h11;
        10'd88  : jpeg_hdr_ll = 8'h00;
        10'd89  : jpeg_hdr_ll = 8'h00;
        10'd90  : jpeg_hdr_ll = 8'h00;
        default: jpeg_hdr_ll = 8'h00;
        endcase
    end
endfunction
