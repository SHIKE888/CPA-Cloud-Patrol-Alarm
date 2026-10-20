module csi_rx_byte_align(
   input  wire        I_clock,
   input  wire        I_reset_n,
   input  wire        I_enable,
   input  wire [7:0]  I_lan_data_in,
   input  wire        I_wait_for_sync,
   input  wire        I_packet_done,
   output wire        O_data_out_vaild,
   output wire  [7:0] O_data_out
);

  parameter [7:0] SYNC = 8'b10111000;

   reg [7:0]  r_lan_data_in_d0;
   reg [7:0]  r_lan_data_in_d1;
   reg [7:0]  r_lan_data_in_d2;

   reg        r_valid_data_int;
   reg        r_was_found;
   reg [2:0]  r_offset; 
   reg [7:0]  r_shifted_byte;
   reg [4:0]  r_error_cunt;

   assign O_data_out_vaild = r_valid_data_int;
   assign O_data_out  = r_shifted_byte;
   
   always @(posedge I_clock or negedge I_reset_n) begin
         if (!I_reset_n)begin
            r_lan_data_in_d0   <= 'b0;
            r_lan_data_in_d1   <= 'b0;
            r_lan_data_in_d2   <= 'b0;
         end
         else begin
            r_lan_data_in_d0   <= I_lan_data_in;
            r_lan_data_in_d1   <= r_lan_data_in_d0;
            r_lan_data_in_d2   <= r_lan_data_in_d1;
         end
   end
   always @(posedge I_clock or negedge I_reset_n) begin
       if (!I_reset_n) r_error_cunt <= 5'b0;
       else if (r_valid_data_int && I_wait_for_sync) 
         r_error_cunt <= r_error_cunt +1 ;
      else if (r_valid_data_int && !I_wait_for_sync) 
         r_error_cunt <= 5'b0;
      else r_error_cunt <= 5'b0;
   end

   always @(posedge I_clock or negedge I_reset_n)begin
         if (!I_reset_n)
               r_valid_data_int <= 1'b0;
         else begin
            if (I_enable == 1'b1)begin
               if (I_packet_done | r_error_cunt [4])
                  r_valid_data_int <= 1'b0;
               else if (I_wait_for_sync & r_was_found & !r_valid_data_int)
                  r_valid_data_int <= 1'b1;
               else 
                  r_valid_data_int <= r_valid_data_int;
            end
            else 
               r_valid_data_int <= 1'b0;
         end
      end

   always @(posedge I_clock or negedge I_reset_n)begin
      if (!I_reset_n) begin
         r_was_found <= 1'b0;  
         r_offset <= 3'd0;
      end else begin
         if (r_valid_data_int == 1'b0) begin
            if (({r_lan_data_in_d0[0], r_lan_data_in_d1[7:1]} == SYNC) & (r_lan_data_in_d1[0] == 0))begin
               r_was_found <= 1'b1;
               r_offset    <= 3'd0;
               end
            else if (({r_lan_data_in_d0[1:0], r_lan_data_in_d1[7:2]} == SYNC) & (r_lan_data_in_d1[1:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd1;
            end 
            else if (({r_lan_data_in_d0[2:0], r_lan_data_in_d1[7:3]} == SYNC) & (r_lan_data_in_d1[2:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd2;
            end 
            else if (({r_lan_data_in_d0[3:0], r_lan_data_in_d1[7:4]} == SYNC) & (r_lan_data_in_d1[3:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd3;
            end 
            else if (({r_lan_data_in_d0[4:0], r_lan_data_in_d1[7:5]} == SYNC) & (r_lan_data_in_d1[4:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd4;
            end
            else if (({r_lan_data_in_d0[5:0], r_lan_data_in_d1[7:6]} == SYNC) & (r_lan_data_in_d1[5:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd5;
            end
            else if (({r_lan_data_in_d0[6:0], r_lan_data_in_d1[7]} == SYNC) & (r_lan_data_in_d1[6:0] == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd6;
            end
            else if (({r_lan_data_in_d0[7:0]} == SYNC) & ((r_lan_data_in_d1[7:0]) == 0))begin
               r_was_found <= 1'b1;
               r_offset <= 3'd7;
            end
            else begin
               r_was_found <= 1'b0;  
               r_offset <= r_offset;
            end
         end
         else begin
            r_was_found <= 1'b0;  
            r_offset <= r_offset;
         end
      end
   end

  //根据判断出的模式情况进行数据拼接
  always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) begin
      r_shifted_byte   <= 8'b0;
    end else begin 
            case (r_offset)
               4'd0:    r_shifted_byte <= {r_lan_data_in_d1[0]  ,r_lan_data_in_d2[7:1]};
               4'd1:    r_shifted_byte <= {r_lan_data_in_d1[1:0],r_lan_data_in_d2[7:2]};
               4'd2:    r_shifted_byte <= {r_lan_data_in_d1[2:0],r_lan_data_in_d2[7:3]};
               4'd3:    r_shifted_byte <= {r_lan_data_in_d1[3:0],r_lan_data_in_d2[7:4]};
               4'd4:    r_shifted_byte <= {r_lan_data_in_d1[4:0],r_lan_data_in_d2[7:5]};
               4'd5:    r_shifted_byte <= {r_lan_data_in_d1[5:0],r_lan_data_in_d2[7:6]};
               4'd6:    r_shifted_byte <= {r_lan_data_in_d1[6:0],r_lan_data_in_d2[7]};
               4'd7:    r_shifted_byte <= r_lan_data_in_d1;
               default: r_shifted_byte <= r_shifted_byte;
            endcase
            end
    end

 //ChipWatcher_2 ChipWatcher_2_Inst (
 //	.clk(I_clock),                 
 //	.probe0(I_lan_data_in),         
 //	.probe1(I_wait_for_sync),   
 //	.probe2(O_data_out),          
 //	.probe3(r_valid_data_int),    
 //	.probe4(I_packet_done), 
 //	.probe5(r_was_found),     
 //	.probe6(r_offset),
 //	.probe7(r_shifted_byte),
 //   .probe8(r_error_cunt)
 //);
   
endmodule
