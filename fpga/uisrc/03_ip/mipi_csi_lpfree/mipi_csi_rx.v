`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/06/17 09:00:03
// Design Name: 
// Module Name: mipi_csi_rx
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


module mipi_csi_rx#(
    parameter MIPI_LAN  = 4,
    parameter DEVICE    = "EG"
    
)(
input wire                I_debug_button  ,   

    input wire                I_ref_clock     ,   
    input wire                I_clk_hs_rx_p   , 
    input wire                I_reset_n       ,    
    input wire [MIPI_LAN-1:0] I_hs_data_p     ,
    input wire                I_enable        ,
    output wire               O_hs_div_clk    ,

    input  wire               m_axis_video_aclk,
    input  wire               m_axis_video_aresetn,
	input  wire               m_axis_video_tready,
    output wire               m_axis_video_tuser,
    output wire               m_axis_video_tlast,
    output wire               m_axis_video_tvalid,
    output wire [39:0]        m_axis_video_tdata,
    output wire               O_auto_delay_done,

    // 调试总线（hs_div_clk 域，需要在顶层 CDC 采样）
    // [3:0] = 各 lane 字节对齐有效
    // [4]   = word 对齐有效
    // [5]   = in_frame（包处理器检测到帧起始）
    // [6]   = payload_valid（包数据输出有效）
    // [7]   = unpack_valid（10-bit 解包有效）
    output wire [7:0]         O_dbg_mipi,
    // delay 调试总线（hs_div_clk 域，需要在顶层 CDC 采样）
    // [5:0] = 当前生效 delay tap
    // [6]   = 手动扫 tap 模式已锁存
    // [7]   = 本拍 delay code load pulse
    output wire [7:0]         O_dbg_delay,
    output wire [5:0]         O_dbg_best_len
    );

    wire [MIPI_LAN-1:0]     w_rx_byte_data_align_vaild;
    wire [8*MIPI_LAN-1:0]   w_rx_byte_data_align;
    wire [8*MIPI_LAN-1:0]   w_word_align_data;
    wire                    w_word_align_data_vaild;
    wire [31:0]             w_word_gear_data;
    wire                    w_word_gear_data_vaild;

    wire [31:0]             w_payload_out;
    wire                    w_payload_valid;
    wire                    w_hs_div_clk ;
    wire                    w_reset_out;
    wire [39:0]             w_data_out_unpack;    
    wire                    w_dout_unpack_valid;
    wire                    w_delay_value;
    wire                    w_sync_wait;
    wire                    w_packet_done;
    wire                    w_vsync_out;
    wire                    w_in_frame;
    wire                    w_in_line;

   assign O_hs_div_clk = w_hs_div_clk;

    assign O_dbg_mipi = {w_dout_unpack_valid,
                         w_payload_valid,
                         w_in_frame,
                         w_word_align_data_vaild,
                         w_rx_byte_data_align_vaild};
 
csi_rx_phy #(
    .MIPI_LAN   (MIPI_LAN),
    .DEVICE     (DEVICE)
)u_csi_rx_phy(

.I_debug_button(I_debug_button),

    .I_ref_clock                (I_ref_clock),
    .I_clk_hs_rx_p              (I_clk_hs_rx_p              ),
    .I_reset_n                  (I_reset_n                  ),
    .I_hs_data_p                (I_hs_data_p                ),
    .I_enable                   (I_enable                   ),
    .I_wait_for_sync            (w_sync_wait                ),
    .I_packet_done              (w_packet_done              ),
    .O_hs_div_clk               (w_hs_div_clk               ),
    .O_reset_out                (w_reset_out                ),
    .O_rx_byte_data_align_vaild (w_rx_byte_data_align_vaild ),
    .O_rx_byte_data_align       (w_rx_byte_data_align       ),
    .O_delay_value              (w_delay_value),
    .O_auto_delay_done          (O_auto_delay_done),
    .O_dbg_delay                (O_dbg_delay),
    .O_dbg_best_len             (O_dbg_best_len)
);

csi_rx_word_align #(
    .MIPI_LAN(MIPI_LAN)
)u_csi_rx_word_align(
    .I_word_clock      (w_hs_div_clk        ),
    .I_reset_n         (w_reset_out         ),
    .I_enable          (I_enable            ),
    .I_packet_done     (w_packet_done       ),
    .I_wait_for_sync   (w_sync_wait         ),
    .O_packet_done_out (),
    .I_word_in         (w_rx_byte_data_align),
    .I_valid_in        (w_rx_byte_data_align_vaild),
    .O_word_out        (w_word_align_data   ),
    .O_valid_out       (w_word_align_data_vaild)
);

csi_rx_word_gear_box #(
    .MIPI_LAN(MIPI_LAN)
)u_csi_rx_word_gear_box(
    .I_word_clock      (w_hs_div_clk           ),
    .I_reset_n         (w_reset_out            ),
    .I_enable          (I_enable               ),
    .I_lane_data       (w_word_align_data      ),
    .I_lane_data_valid (w_word_align_data_vaild),
    .O_word_out        (w_word_gear_data       ),
    .O_valid_out       (w_word_gear_data_vaild )
);


csi_rx_packet_handler #(
    .MIPI_LAN(MIPI_LAN)
)u_csi_rx_packet_handler(
    .I_clock         (w_hs_div_clk           ),
    .I_reset_n       (w_reset_out            ),
    .I_enable        (I_enable               ),
    .I_data          (w_word_gear_data       ),
    .I_data_valid    (w_word_gear_data_vaild ),
    .O_sync_wait     (w_sync_wait            ),
    .O_packet_done   (w_packet_done          ),
    .O_payload_out   (w_payload_out          ),
    .O_payload_valid (w_payload_valid        ),
    .O_vsync_out     (w_vsync_out            ),
    .O_in_frame      (w_in_frame             ),
    .O_in_line       (w_in_line              )
);


csi_rx_10bit_unpack u_csi_rx_10bit_unpack(
    .I_clock        (w_hs_div_clk       ),
    .I_reset_n      (w_reset_out        ),
    .I_enable       (I_enable           ),
    .I_line_in      (w_in_line          ),
    .I_data_in      (w_payload_out      ),
    .I_din_valid    (w_payload_valid    ),
    .O_data_out     (w_data_out_unpack  ),
    .O_dout_valid   (w_dout_unpack_valid)
);

csi_rx_vid2stream u_csi_rx_vid2stream(
    .I_data_clk           (w_hs_div_clk         ),
    .I_reset_n            (I_reset_n            ),
    .I_packet_done        (w_packet_done        ),
    .I_packet_line        (w_in_line            ),
    .I_packet_frame       (w_in_frame           ),
    .I_data_unpack        (w_data_out_unpack    ),
    .I_dout_unpack_valid  (w_dout_unpack_valid  ),
    .m_axis_video_aclk    (m_axis_video_aclk    ),
    .m_axis_video_aresetn (m_axis_video_aresetn ),
    .m_axis_video_tready  (m_axis_video_tready  ),
    .m_axis_video_tuser   (m_axis_video_tuser   ),
    .m_axis_video_tlast   (m_axis_video_tlast   ),
    .m_axis_video_tvalid  (m_axis_video_tvalid  ),
    .m_axis_video_tdata   (m_axis_video_tdata   )
);

endmodule
