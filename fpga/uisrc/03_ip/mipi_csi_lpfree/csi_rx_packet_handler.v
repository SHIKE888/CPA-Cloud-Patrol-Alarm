//--------------------------------------------------------------------------------------------
// CSI-2 接收包处理器 (完全符合Verilog语法)
// 严格遵守：
//   1. 三段式状态机（状态声明、状态转移、输出逻辑）
//   2. Verilog-2001标准
//   3. 统一的命名规范
//--------------------------------------------------------------------------------------------

module csi_rx_packet_handler #(
    parameter MIPI_LAN = 4, // CSI-2 通道数配置（1/2/4）
    parameter VC_ID = 0     // 虚拟通道ID（0-3）
)(
    // 系统信号
    input  wire         I_clock,        // 系统时钟
    input  wire         I_reset_n,      // 低电平复位
    input  wire         I_enable,       // 模块使能
    
    // CSI-2 数据输入
    input wire [31:0]   I_data,         // 接收数据（32位）
    input wire          I_data_valid,   // 数据有效标志
    
    // 控制输出
    output wire         O_packet_done,  // 包处理完成标志
    output wire         O_sync_wait,    
    // 数据输出
    output reg [31:0]   O_payload_out,   // 有效载荷输出
    output reg          O_payload_valid, // 有效载荷有效标志
    
    // 状态输出
    output wire         O_vsync_out,    // 帧同步信号
    output wire         O_in_frame,     // 帧传输标志
    output wire         O_in_line       // 行传输标志

);

//-------------------------------------
// 状态定义（第一段：状态声明）
//-------------------------------------
// 使用localparam明确定义所有状态
localparam [1:0] 
    STATE_IDLE       = 2'b00,  // 空闲状态（复位后）
    STATE_WAIT_HDR   = 2'b01,  // 等待包头状态
    STATE_RX_PAYLOAD = 2'b10,  // 接收有效载荷状态
    STATE_PKT_END    = 2'b11;  // 包结束状态

reg [1:0] R_MS;  // 当前状态寄存器
reg [1:0] R_MS_NEXT;      // 下一状态寄存器

//-------------------------------------
// 内部信号声明（统一前缀）
//-------------------------------------
// 线网信号
wire  [7:0]   w_packet_type;     // 包类型
wire          w_long_packet;     // 长包标志
wire [15:0]   w_packet_len;      // 包长度
wire          w_valid_packet;    // 有效包标志
wire [23:0]   w_packet_for_ecc;  // ECC校验数据域
wire  [7:0]   w_expected_ecc;    // 预期ECC值

// 寄存器信号
reg [16:0]    r_bytes_read;      // 已接收字节计数器
reg [15:0]    r_packet_len_q;    // 锁存的包长度
reg           r_in_frame_d;      // 帧传输状态寄存器
reg           r_in_line_d;       // 行传输状态寄存器
reg           r_packet_done;     // 包结束标志寄存器
//防锁死信号
reg[4:0]      r_error_cunt;      //防锁死计数
reg           r_data_valid;

//-------------------------------------
// 包头解析逻辑
//-------------------------------------
assign w_packet_type    = {2'b00,I_data[5:0]}; // 提取数据类型（6位LSB）
assign w_packet_for_ecc = I_data[23:0];        // 需要ECC校验的数据域
assign w_packet_len     = I_data[23:8];        // 包长度字段（16位）


// 长包判断：数据类型F且包有效
assign w_long_packet = (w_packet_type > 8'h0F) && w_valid_packet ;

// 有效包判断：ECC校验通过 + 允许的类型 + 虚拟通道匹配
assign w_valid_packet = (I_data[31:24] == w_expected_ecc) && (is_allowed_type (w_packet_type)) && (I_data[7:6] == VC_ID[1:0]) && I_data_valid;


function is_allowed_type;
    input [7:0] packet_type;
    begin
        is_allowed_type = 1'b0;  // 默认
        
        // 使用case语句列出所有允许的数据类型
        case(packet_type)
            // 同步包类型 (帧开始/结束)
            8'h00, 8'h01, 8'h02, 8'h03,
            // 非图像数据类型
            8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17,
            // YUV 格式数据类型
            8'h18, 8'h19, 8'h1A, 8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F,
            // RGB 格式数据类型
            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27,
            // RAW 格式数据类型
            8'h28, 8'h29, 8'h2A, 8'h2B, 8'h2C, 8'h2D, 

            8'h30, 8'h31, 8'h32, 8'h33, 8'h34, 8'h35 , 8'h36, 8'h37  : 
            is_allowed_type = 1'b1;  // 允许的类型
        default: is_allowed_type = 1'b0;  // 不允许的拉低
        endcase
    end
endfunction

//-------------------------------------
// ECC 校验实例化
//-------------------------------------
csi_rx_hdr_ecc ecc_inst (
    .data(w_packet_for_ecc),  // ECC校验数据域
    .ecc(w_expected_ecc)      // 计算得到的ECC值
);
//=====================================
// 三段式状态机实现
//=====================================
//-------------------------------------
// 第一段：状态寄存器（时序逻辑）
//-------------------------------------
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        R_MS <= STATE_IDLE;  // 复位状态
    else if (I_enable) 
        R_MS <= R_MS_NEXT;  // 状态转移
    else 
        R_MS <= R_MS;
end

//-------------------------------------
// 第二段：下一状态逻辑（组合逻辑）
//-------------------------------------
always @(*) begin
    // 默认保持当前状态
    R_MS_NEXT = R_MS;
    // 状态转移条件判断
    case (R_MS)
        STATE_IDLE       : R_MS_NEXT = STATE_WAIT_HDR;   // 空闲状态 -> 等待包头
        STATE_WAIT_HDR   : R_MS_NEXT = (w_valid_packet) ? (w_long_packet ? STATE_RX_PAYLOAD : STATE_PKT_END ): STATE_WAIT_HDR;
        STATE_RX_PAYLOAD : R_MS_NEXT = ((r_bytes_read >= (r_packet_len_q)) | (r_error_cunt==5'h1f)) ? STATE_PKT_END : STATE_RX_PAYLOAD ; // 接收完成或出错时结束       
        STATE_PKT_END    : R_MS_NEXT = STATE_IDLE; // 回到等待包头状态
        default: R_MS_NEXT = STATE_IDLE;  // 异常处理
    endcase
end

//-------------------------------------
// 第三段：状态输出逻辑（时序逻辑）
//-------------------------------------
// 包长度
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_packet_len_q <= 16'h0; 
    else begin 
        if (I_enable) begin
            if ((R_MS == STATE_WAIT_HDR) & w_long_packet)         // 在包头检查状态锁存包长度
                r_packet_len_q <= (w_packet_len < 4) ? 4 : w_packet_len;
            else 
                r_packet_len_q <= r_packet_len_q;
        end
        else 
            r_packet_len_q <= 16'h0;
    end

end

// 字节计数器逻辑
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_bytes_read <= 17'h0;
    else begin
        if (I_enable) begin
            if (R_MS == STATE_WAIT_HDR) 
                r_bytes_read <= 16'h0;
            else if (R_MS == STATE_RX_PAYLOAD) begin // 在有效载荷状态更新计数器
                if (r_bytes_read < r_packet_len_q && I_data_valid) 
                    r_bytes_read <= r_bytes_read + 4;
                else 
                    r_bytes_read <= r_bytes_read;
            end
            else 
                r_bytes_read <= r_bytes_read;
        end
        else
            r_bytes_read   <= 17'h0;
    end
end

// 数据输出逻辑
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        O_payload_valid <= 1'b0;
    else begin 
        if (I_enable) begin
            if (R_MS == STATE_RX_PAYLOAD && I_data_valid) 
                O_payload_valid <= 1'b1;
            else 
                O_payload_valid <= 1'b0;
        end
        else 
            O_payload_valid <= 1'b0;
    end
end

always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        O_payload_out   <= 32'h0;
    else begin 
        if (I_enable) begin
            // 有效载荷状态输出数据
            if (R_MS == STATE_RX_PAYLOAD && I_data_valid) 
                O_payload_out   <= I_data;
            else 
                O_payload_out <= 32'h0;// 非传输状态输出0，降低功耗
        end
        else 
        O_payload_out   <= 32'h0; 
    end
end

// 帧控制逻辑
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_in_frame_d <= 1'b0;
    else begin
        if (I_enable) begin
            if (R_MS == STATE_WAIT_HDR && w_valid_packet) begin            // 帧控制逻辑
                case (w_packet_type)              // 帧开始/结束包
                    8'h00: r_in_frame_d <= 1'b1;  // 帧开始
                    8'h01: r_in_frame_d <= 1'b0;  // 帧结束
                endcase
            end 
            else r_in_frame_d <= r_in_frame_d;
        end
        else r_in_frame_d <= r_in_frame_d;
    end 
end

// 行控制逻辑
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_in_line_d  <= 1'b0; 
    else begin
        if (I_enable) begin
            if (R_MS == STATE_WAIT_HDR  && w_valid_packet) begin        // 帧控制逻辑
                // 行开始条件（支持所有图像类型）
                if ((w_packet_type[7:4] == 4'h1) ||  // YUV
                    (w_packet_type[7:4] == 4'h2) ||  // RAW
                    (w_packet_type[7:4] == 4'h3))    // RGB
                    r_in_line_d <= 1'b1;
                else
                    r_in_line_d <= 1'b0;                 
            end 
            else 
                r_in_line_d <= 1'b0;
        end
        else 
        r_in_line_d  <= 1'b0; 
    end 
end


// 包结束标志生成
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_packet_done <= 1'b0; 
    else begin 
        if (I_enable) begin
            if (R_MS_NEXT == STATE_PKT_END) 
                r_packet_done <= 1'b1;
            else 
                r_packet_done <= 1'b0;
        end
        else 
        r_packet_done <= 1'b0; 
    end
end

// 包结束标志生成
always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_error_cunt <= 5'b0; 
    else begin 
        if (I_enable) begin
            if (R_MS == STATE_RX_PAYLOAD) begin
                if (!r_data_valid &!I_data_valid) //捕获上升沿或者下降沿
                    r_error_cunt <= r_error_cunt + 1'b1; 
                else
                    r_error_cunt <= 5'b0; 
            end
            else 
            r_error_cunt <= 5'b0; 
        end
        else 
        r_error_cunt <= 5'b0; 
    end
end

always @(posedge I_clock or negedge I_reset_n) begin
    if (!I_reset_n) 
        r_data_valid <= 1'b0; 
    else begin 
        if (I_enable) 
            r_data_valid <= I_data_valid;
        else 
            r_data_valid <= 1'b0; 
    end
end

//-------------------------------------
// 输出信号分配
//-------------------------------------
assign O_vsync_out    = (R_MS == STATE_WAIT_HDR) && 
                        (w_packet_type == 8'h00) && 
                        w_valid_packet;
                
assign O_in_frame     = r_in_frame_d;
assign O_in_line      = r_in_line_d;
assign O_packet_done  = r_packet_done;
assign O_sync_wait   = R_MS == STATE_WAIT_HDR;


    // ChipWatcher_hand ChipWatcher_hand
    //(
 	//.clk     (I_clock),      
 	//.probe0  (I_data),        
 	//.probe1  (I_data_valid),  
 	//.probe2  (O_packet_done), 
 	//.probe3  (O_payload_out), 
 	//.probe4  (O_payload_valid), 
 	//.probe5  (O_vsync_out), 
 	//.probe6  (O_in_frame), 
 	//.probe7  (O_in_line), 
 	//.probe8  (R_MS), 
 	//.probe9  (w_packet_type), 
 	//.probe10 (w_long_packet), 
 	//.probe11 (w_packet_len), 
 	//.probe12 (w_valid_packet), 
 	//.probe13 (w_expected_ecc),
 	//.probe14 (r_bytes_read), 
 	//.probe15 (r_packet_len_q),
    // .probe16 (O_sync_wait) 
    //);

endmodule