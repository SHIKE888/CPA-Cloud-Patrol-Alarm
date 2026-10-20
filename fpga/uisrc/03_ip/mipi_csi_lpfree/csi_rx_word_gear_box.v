module csi_rx_word_gear_box #(
    parameter MIPI_LAN = 4            // 支持的 Lane 数量 (1、2、4)
)(
    input                     I_word_clock,       // 字时钟
    input                     I_reset_n,          // 低有效复位
    input                     I_enable,           // 模块使能
    input [MIPI_LAN*8-1:0]    I_lane_data,        // Lane 数据输入
    input                     I_lane_data_valid,  // Lane 数据有效标志
    output reg [31:0]         O_word_out,         // 32 位输出数据
    output reg                O_valid_out         // 输出数据有效标志
);

reg [63:0]  r_byte_buffer;  // 64位字节缓冲寄存器
reg [3:0]   r_byte_count;   // 当前缓冲字节数 (0-8)

wire        w_output_ready;   // 输出准备标志
assign      w_output_ready = (r_byte_count>>2) > 0;
// ===========================================================================
// 新数据收集逻辑 (时序逻辑)
// ===========================================================================
always @(posedge I_word_clock or negedge I_reset_n) begin
    if (!I_reset_n) begin
        r_byte_buffer <= 64'b0;          
        r_byte_count <= 4'b0;
    end
else begin
    if (I_lane_data_valid) begin
        r_byte_buffer   <= {I_lane_data,r_byte_buffer[63:MIPI_LAN*8]};          
        r_byte_count    <= w_output_ready ? r_byte_count + MIPI_LAN - 4 : r_byte_count + MIPI_LAN; 
        end
    else begin
        r_byte_buffer <= 64'b0;         
        r_byte_count <= 4'b0;
    end
    end
end

always @(posedge I_word_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        O_word_out <= 32'b0;
    else if (w_output_ready)
        O_word_out <= r_byte_buffer[63:32];  
    else
        O_word_out <= 32'b0;
end

always @(posedge I_word_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        O_valid_out <= 1'b0;
    else if (w_output_ready)
        O_valid_out <= 1'b1; 
    else
        O_valid_out <= 1'b0;
end


endmodule