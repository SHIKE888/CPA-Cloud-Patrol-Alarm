`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/07/18 16:34:28
// Design Name: 
// Module Name: mipi_csi_rx_phy
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module csi_rx_phy#(
    parameter MIPI_LAN  = 4 ,
    parameter DEVICE    = "EG"
)(

input wire I_debug_button,

    input wire                      I_ref_clock     ,   
    input wire                      I_clk_hs_rx_p   , 
    input wire                      I_reset_n       ,    
    input wire [MIPI_LAN-1:0]       I_hs_data_p     ,
    input wire                      I_enable        ,
    input  wire                     I_wait_for_sync ,
    input  wire                     I_packet_done   ,
    output wire                     O_hs_div_clk    ,
    output wire                     O_reset_out     ,      
    output wire [MIPI_LAN-1:0]      O_rx_byte_data_align_vaild,
    output wire [8*MIPI_LAN-1:0]    O_rx_byte_data_align, 
    output wire                     O_delay_value        ,
    output wire                     O_auto_delay_done,
    output wire [7:0]               O_dbg_delay,
    output wire [5:0]               O_dbg_best_len
    );

wire                    w_hs_clk   ;
wire                    w_hs_clk_x2;
wire                    w_hs_clk_x4;
wire                    w_reset_out  ;

wire [8*MIPI_LAN-1:0]   w_rx_byte_data;                   //synthesis keep
wire [MIPI_LAN-1:0]     w_rx_byte_data_align_vaild;       //synthesis keep
wire [8*MIPI_LAN-1:0]   w_rx_byte_data_align;             //synthesis keep
wire [5:0]              w_auto_delay_value;
wire 	                w_auto_delay_vaild;
wire                    w_auto_delay_done;
wire [5:0]              w_auto_delay_best_len;
wire [5:0]              w_lane_delay_value;
wire                    w_lane_delay_vaild;
wire 	                w_delay_data_val[MIPI_LAN-1:0];


assign O_hs_div_clk                 = w_hs_clk              ;
assign O_reset_out                  = w_reset_out               ;    
assign O_rx_byte_data_align_vaild   = w_rx_byte_data_align_vaild;
assign O_rx_byte_data_align         = w_rx_byte_data_align      ;
assign O_delay_value                = w_lane_delay_value[0]     ;
assign O_auto_delay_done            = r_manual_mode ? 1'b1 : w_auto_delay_done;
assign O_dbg_best_len               = w_auto_delay_best_len;
assign O_dbg_delay                  = {w_lane_delay_vaild, r_manual_mode, w_lane_delay_value};


// debug
// µÍµçÆ½°´ÏÂ¡¢ÊÍ·ÅÑØ(+1 tap)£º
//   1. Î´½øÈëÊÖ¶¯Ä£Ê½Ç°£¬Ê×´ÎÊÍ·ÅÑØËø´æ auto-delay µ±Ç°Öµ
//   2. ½øÈëÊÖ¶¯Ä£Ê½ºó£¬Ã¿´ÎÊÍ·ÅÑØ delay tap + 1
reg  [1:0] r_debug_button_sync;
reg        r_manual_mode;
reg  [5:0] r_manual_delay;
reg        r_manual_delay_load;

// ------------------------------------------------------------------
// 2026-10-21: eye-scan ?? + ??
//   ??: ??? bit ?(????????, ?????)??????????
//         ??, ???? tap=1 ????? -> ??; ?????????
//         (best_len=32, tap=16)?????????????, ????
//   ??:  ?????? best_len ?????(?? MAX_TRY ?);
//         ????????????, ? ???? ? tap ??:
//           ?? -> ????????  ??? -> ????? FIXED_TAP
//         ????????????, ????????
// ------------------------------------------------------------------
localparam [5:0] GOOD_LEN  = 6'd8;    // best_len >= 8 ??????
localparam [5:0] FIXED_TAP = 6'd16;   // ??: ?????
localparam [2:0] MAX_TRY   = 3'd4;    // ??? 4 ?

reg  [2:0] r_try;
reg        r_rescan;      // 1 ?: ?????/??????
reg        r_latched;     // ?????
reg        r_fix_done;    // ????? tap ??????

wire w_scan_rstn = w_reset_out & ~r_rescan;

wire w_debug_release = (r_debug_button_sync == 2'b01);

always @(posedge w_hs_clk or negedge w_reset_out) begin
    if (!w_reset_out) begin
        r_debug_button_sync <= 2'b11;
        r_manual_mode       <= 1'b0;
        r_manual_delay      <= 6'd0;
        r_manual_delay_load <= 1'b0;
        r_fix_done          <= 1'b0;
    end else begin
        r_debug_button_sync <= {r_debug_button_sync[0], I_debug_button};
        r_manual_delay_load <= 1'b0;

        if (w_debug_release) begin
            r_manual_mode       <= 1'b1;
            r_manual_delay_load <= 1'b1;

            if (!r_manual_mode)
                r_manual_delay <= w_auto_delay_value;
            else
                r_manual_delay <= r_manual_delay + 1'b1;
        end else if (r_latched && !r_fix_done && !r_manual_mode) begin
            // ????: ?????? tap ??
            r_fix_done          <= 1'b1;
            r_manual_mode       <= 1'b1;
            r_manual_delay      <= (w_auto_delay_best_len >= GOOD_LEN) ? w_auto_delay_value
                                                                     : FIXED_TAP;
            r_manual_delay_load <= 1'b1;
        end
    end
end

// ??????: ???????????????
always @(posedge w_hs_clk or negedge w_reset_out) begin
    if (!w_reset_out) begin
        r_try     <= 3'd0;
        r_rescan  <= 1'b0;
        r_latched <= 1'b0;
    end else begin
        r_rescan <= 1'b0;
        if (!r_latched && w_auto_delay_done) begin
            if ((w_auto_delay_best_len >= GOOD_LEN) || (r_try >= (MAX_TRY - 1'b1)))
                r_latched <= 1'b1;              // ?? ? ???? -> ??
            else begin
                r_try    <= r_try + 1'b1;
                r_rescan <= 1'b1;               // ????
            end
        end
    end
end

assign w_lane_delay_value = r_manual_mode ? r_manual_delay      : w_auto_delay_value;
assign w_lane_delay_vaild = r_manual_mode ? r_manual_delay_load : w_auto_delay_vaild;


csi_rx_clk_gen #(
    .DEVICE (DEVICE)
)u_csi_rx_clk_gen(
    .I_mipi_clk_p (I_clk_hs_rx_p ),
    .I_rst        (~I_reset_n    ),
    .O_clk        (w_hs_clk      ),//ï¿½ï¿½ï¿½ï¿½8Î»ï¿½ï¿½ï¿½ï¿½Ê±ï¿½ï¿½
    .O_clk_x2     (w_hs_clk_x2   ),//ï¿½ï¿½ï¿½ï¿½4Î»ï¿½ï¿½ï¿½ï¿½Ê±ï¿½ï¿½
    .O_clk_x4     (w_hs_clk_x4   ) //4ï¿½ï¿½Ê±ï¿½Ó£ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½ï¿½Ê±ï¿½ï¿½

);

csi_rx_clock_det u_csi_rx_clock_det(
    .I_ref_clock (I_ref_clock ),
    .I_ext_clock (w_hs_clk),
    .I_enable    (I_enable    ),
    .I_reset_in  (I_reset_n  ),
    .O_reset_out (w_reset_out )
);

auto_delay_ctl #(
  .MIPI_LAN(MIPI_LAN),
  .LAN_DATA_CUNT(10'h3ff)  
)u_auto_delay_ctl(
    .I_byte_clk        (w_hs_clk),
    .I_reset_n         (w_scan_rstn),
    .I_byte_align_done (w_rx_byte_data_align_vaild),
        .O_delay_value     (w_auto_delay_value),
        .O_delay_vaild     (w_auto_delay_vaild),
        .O_auto_delay_done (w_auto_delay_done),
        .O_dbg_best_len    (w_auto_delay_best_len)
);

generate 
genvar i;
for (i=0; i<MIPI_LAN; i=i+1) begin : gen_channel_wrapper	
csi_rx_hs_data_phy #(
    .DEVICE (DEVICE)
) u_csi_rx_hs_data_phy(
    .I_rxclk        (w_hs_clk      ),
    .I_rxclk_div_x2 (w_hs_clk_x2   ),
    .I_rxclk_div_x4 (w_hs_clk_x4   ),
    .I_reset_n      (w_reset_out   ),
    .I_hs_data_p    (I_hs_data_p[i]),
    .I_delay_value  (w_lane_delay_value),
    .I_delay_vaild  (w_lane_delay_vaild),
    .O_rx_data      (w_rx_byte_data[(8 * i) + 7:8 * i]),
    .O_delay_data_val(w_delay_data_val[i])
);

csi_rx_byte_align u_csi_rx_byte_align(
    .I_clock           (w_hs_clk    ),
    .I_reset_n         (w_scan_rstn     ),
    .I_enable          (I_enable        ),
    .I_lan_data_in     (w_rx_byte_data[(8 * i) + 7:8 * i]),
    .I_wait_for_sync   (I_wait_for_sync ),
    .I_packet_done     (I_packet_done   ),
    .O_data_out_vaild  (w_rx_byte_data_align_vaild[i]),
    .O_data_out        (w_rx_byte_data_align[(8 * i) + 7:8 * i])
);

end
endgenerate	

//cwc cwc(
//.probe0(I_hs_data_p				),
//.probe1(O_auto_delay_done		),
//.probe2(w_delay_data_val[0]		),
//.probe3(w_delay_data_val[1]		),
//.probe4(w_delay_data_val[2]		),
//.probe5(w_delay_data_val[3]		),
//.probe6(w_rx_byte_data[7:0]		),
//.probe7(w_rx_byte_data[15:8]	),
//.probe8(w_rx_byte_data[23:16]	),
//.probe9(w_rx_byte_data[31:24]	),
//.probe10(r_debug_delay	),
//.clk(w_hs_clk)
//);

endmodule
