//--------------------------------------------------------------------------------------------
// CSI-2 10位到8位解包模块
// 功能说明：
//   将CSI-2接口的32位输入数据解包为40位输出数据
//   支持连续的10位数据流解包为8位数据
//--------------------------------------------------------------------------------------------

module csi_rx_10bit_unpack (
    input  wire        I_clock,       // 系统时钟 (主时钟输入)
    input  wire        I_reset_n,     // 复位信号 (低电平有效)
    input  wire        I_enable,      // 模块使能信号
    input  wire        I_line_in,
    input  wire [31:0] I_data_in,     // 输入数据 (32位)
    input  wire        I_din_valid,   // 输入数据有效标志
    output wire [39:0] O_data_out,    // 解包输出数据 (40位)
    output wire        O_dout_valid   // 输出数据有效标志
);

// ===========================================================================
// 内部寄存器定义
// ===========================================================================
reg [39:0] r_dout_int;       // 中间解包数据寄存器
reg [31:0] r_bytes_int;      // 临时数据缓冲寄存器
reg [2:0]  r_byte_count;     // 字节计数器 (记录待处理字节数)
reg        r_dout_valid_int; // 中间有效信号寄存器

// 输出寄存器
reg [39:0] r_data_out;      // 输出数据寄存器
reg        r_dout_valid;     // 输出有效标志寄存器

// ===========================================================================
// 解包功能函数
// ===========================================================================
function [39:0] mipi_unpack;
    input [39:0] packed_data;
    begin
        // 将10位数据解包为8位
        mipi_unpack[9:0]   = {packed_data[7:0],   packed_data[33:32]}; // 字节0解包
        mipi_unpack[19:10] = {packed_data[15:8],  packed_data[35:34]}; // 字节1解包
        mipi_unpack[29:20] = {packed_data[23:16], packed_data[37:36]}; // 字节2解包
        mipi_unpack[39:30] = {packed_data[31:24], packed_data[39:38]}; // 字节3解包
    end
endfunction

// ===========================================================================
// 主处理逻辑：数据移位与解包
// ===========================================================================
always @(posedge I_clock or negedge I_reset_n) begin
    // 复位处理
    if (!I_reset_n) begin
        // 初始化所有寄存器
        r_dout_int      <= 40'b0;
        r_bytes_int     <= 32'b0;
        r_byte_count    <= 3'b0;
        r_dout_valid_int<= 1'b0;
    end
    // 正常工作模式
    else begin 
        if (I_enable) begin
            if (I_line_in) begin                       // 初始化所有寄存器
                r_dout_int      <= 40'b0;
                r_bytes_int     <= 32'b0;
                r_byte_count    <= 3'b0;
                r_dout_valid_int<= 1'b0; 
            end
            else begin
                if (I_din_valid) begin// 当输入数据有效时进行处理
                    case (r_byte_count)
                        // 状态0：无先前数据（开始新帧）
                        3'b000: begin  
                            r_dout_int    <= 40'b0;
                            r_bytes_int   <= I_data_in;     // 缓存输入数据
                            r_byte_count  <= 3'b100;        // 设置4字节待处理标志
                            r_dout_valid_int <= 1'b0;         // 设置解包数据有效
                        end

                        // 状态1：1字节待处理
                        3'b001: begin  
                            // 组合输入数据和缓存字节
                            r_dout_int    <= {I_data_in, r_bytes_int[7:0]};
                            r_bytes_int   <= 32'b0;          // 清除缓存
                            r_byte_count  <= 3'b0;           // 重置计数器
                            r_dout_valid_int <= 1'b1;         // 设置解包数据有效
                        end

                        // 状态2：2字节待处理
                        3'b010: begin  
                            // 组合输入数据和缓存字节
                            r_dout_int    <= {I_data_in[23:0], r_bytes_int[15:0]};
                            // 保存输入数据的高位字节
                            r_bytes_int   <= {8'b0, I_data_in[31:24]};  
                            r_byte_count  <= 3'b001;          // 更新为1字节待处理
                            r_dout_valid_int <= 1'b1;         // 设置解包数据有效
                        end

                        // 状态3：3字节待处理
                        3'b011: begin  
                            // 组合输入数据和缓存字节
                            r_dout_int    <= {I_data_in[15:0], r_bytes_int[23:0]};
                            // 保存输入数据的高位字节
                            r_bytes_int   <= {16'b0, I_data_in[31:16]};  
                            r_byte_count  <= 3'b010;          // 更新为2字节待处理
                            r_dout_valid_int <= 1'b1;         // 设置解包数据有效
                        end

                        // 状态4：4字节待处理
                        3'b100: begin  
                            // 组合输入数据和缓存字节
                            r_dout_int    <= {I_data_in[7:0], r_bytes_int[31:0]};
                            // 保存输入数据的高位字节
                            r_bytes_int   <= {24'b0, I_data_in[31:8]};  
                            r_byte_count  <= 3'b011;          // 更新为3字节待处理
                            r_dout_valid_int <= 1'b1;         // 设置解包数据有效
                        end

                        // 默认状态：处理异常情况
                        default: begin  
                            r_byte_count <= 3'b0;            // 重置计数器
                        end
                    endcase
                end
                else  r_dout_valid_int <= 1'b0;         
            end
        end
    end
end
// 传递有效标志 
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_dout_valid  <= 1'b0;
    else begin
        if (I_enable) 
            r_dout_valid  <= r_dout_valid_int;
        else 
            r_dout_valid  <= 1'b0;
    end
end

always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_data_out  <= 40'b0;
    else begin
        if (I_enable) begin
            if (r_dout_valid_int)         // 当解包数据有效时进行处理
                r_data_out <= mipi_unpack(r_dout_int);    // 执行解包操作
            else 
                r_data_out  <= 40'b0;
        end
        else 
        r_data_out  <= 40'b0;
    end
end

// ===========================================================================
// 输出分配
// ===========================================================================
assign O_data_out   = r_data_out;    // 分配输出数据
assign O_dout_valid = r_dout_valid;  // 分配输出有效标志

    //ChipWatcher_10bit ChipWatcher_10bit
    //(
 	//.clk     (I_clock),      
 	//.probe0  (I_line_in),        
 	//.probe1  (I_data_in),  
 	//.probe2  (I_din_valid), 
 	//.probe3  (O_data_out), 
 	//.probe4  (O_dout_valid), 
 	//.probe5  (r_dout_int), 
 	//.probe6  (r_bytes_int), 
 	//.probe7  (r_byte_count), 
 	//.probe8  (r_dout_valid_int), 
 	//.probe9  (r_data_out), 
 	//.probe10 (r_dout_valid)
    //);

endmodule