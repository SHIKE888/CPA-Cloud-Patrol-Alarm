module csi_rx_word_align#(
        // 全局配置参数
    parameter MIPI_LAN = 2  // 默认2通道，可配置为1/2/4
)(
    // 时钟和复位
    input         I_word_clock,
    input         I_reset_n,
    
    // 控制信号
    input         I_enable,
    input         I_packet_done,
    input         I_wait_for_sync,
    
    // 状态输出
    output        O_packet_done_out,
    
    // 数据输入
    input  [8*MIPI_LAN-1:0] I_word_in,
    input  [MIPI_LAN-1:0]   I_valid_in,
    
    // 数据输出
    output [8*MIPI_LAN-1:0] O_word_out,
    output                  O_valid_out
);  
    // 输出寄存器声明
    reg [8*MIPI_LAN-1:0] r_word_out;
    reg r_valid_out;
    
    assign O_word_out = r_word_out;
    assign O_valid_out = r_valid_out;
    
    // 内部寄存器声明
    reg [8*MIPI_LAN-1:0] r_word_dly_0;
    reg [8*MIPI_LAN-1:0] r_word_dly_1;
    reg [8*MIPI_LAN-1:0] r_word_dly_2;
    reg [8*MIPI_LAN-1:0] r_word_dly_3;
    reg [8*MIPI_LAN-1:0] r_word_dly_4;
    reg [8*MIPI_LAN-1:0] r_word_dly_5;

    reg [MIPI_LAN-1:0]   r_valid_dly_0;
    reg [MIPI_LAN-1:0]   r_valid_dly_1;
    reg [MIPI_LAN-1:0]   r_valid_dly_2;
    reg [MIPI_LAN-1:0]   r_valid_dly_3;
    reg [MIPI_LAN-1:0]   r_valid_dly_4;
    reg [MIPI_LAN-1:0]   r_valid_dly_5;

    // 通道对齐参数寄存器
    reg [2:0] r_taps [0:MIPI_LAN-1];    
    reg [2:0] r_next_taps [0:MIPI_LAN-1]; 
    
    reg r_valid;
    wire w_next_valid;
    reg [8*MIPI_LAN-1:0] r_aligned_word;
    
    // 包完成输出
    assign O_packet_done_out = I_packet_done ;
    assign w_next_valid = &r_valid_dly_0;

    integer i;  // Verilog标准整数声明
    
    // 主时序逻辑
    always @(posedge I_word_clock) begin
        if (!I_reset_n) begin
            // 复位所有寄存器
            r_valid <= 1'b0;
            r_valid_out <= 1'b0;
            r_word_out <= 0;
            
            // 初始化延时链和参数寄存器
            r_word_dly_0    <= 0;
            r_word_dly_1    <= 0;
            r_word_dly_2    <= 0;
            r_word_dly_3    <= 0;
            r_word_dly_4    <= 0;

            r_valid_dly_0   <= 0;
            r_valid_dly_1   <= 0;
            r_valid_dly_2   <= 0;
            r_valid_dly_3   <= 0;
            r_valid_dly_4   <= 0;
            
            for (i = 0; i < MIPI_LAN; i = i + 1) begin
                r_taps[i] <= 3'b000;
            end
        end
        else if (I_enable) begin
            // 三级延时链
            r_word_dly_0    <= I_word_in;
            r_valid_dly_0   <= I_valid_in;

            r_word_dly_1    <= r_word_dly_0;
            r_valid_dly_1   <= r_valid_dly_0;

            r_word_dly_2    <= r_word_dly_1;
            r_valid_dly_2   <= r_valid_dly_1;

            r_word_dly_3    <= r_word_dly_2;
            r_valid_dly_3   <= r_valid_dly_2;

            r_word_dly_4    <= r_word_dly_3;
            r_valid_dly_4   <= r_valid_dly_3;

            r_word_dly_5    <= r_word_dly_4;
            r_valid_dly_5   <= r_valid_dly_4;    
                   
            // 输出寄存器更新
            r_valid_out     <= r_valid;
            r_word_out      <= r_aligned_word;
            
            // 对齐触发条件
            if (w_next_valid && !r_valid && I_wait_for_sync) begin
                r_valid <= 1'b1;
                for (i = 0; i < MIPI_LAN; i = i + 1) begin
                    r_taps[i] <= r_next_taps[i];
                end
            end
            else if (I_packet_done) begin
                r_valid <= 1'b0;
            end
        end
    end

    // 组合逻辑块
    always @(*) begin
        // 数据对齐选择器
        for (i = 0; i < MIPI_LAN; i = i + 1) begin
            case(r_taps[i])
                3'b101: r_aligned_word[i*8 +:8] = r_word_dly_5[i*8 +:8];            
                3'b100: r_aligned_word[i*8 +:8] = r_word_dly_4[i*8 +:8];
                3'b011: r_aligned_word[i*8 +:8] = r_word_dly_3[i*8 +:8];
                3'b010: r_aligned_word[i*8 +:8] = r_word_dly_2[i*8 +:8];
                3'b001: r_aligned_word[i*8 +:8] = r_word_dly_1[i*8 +:8];
                default: r_aligned_word[i*8 +:8] = r_word_dly_0[i*8 +:8];
            endcase
        end
    end
    
    // 单独的组合逻辑块计算下一拍的最佳采样点
    genvar j;
    generate
        for (j = 0; j < MIPI_LAN; j = j + 1) begin : tap_calc
            always @(*) begin
                // 仅为配置的通道计算
                if (r_valid_dly_5[j] &&r_valid_dly_4[j] && r_valid_dly_3[j] && r_valid_dly_2[j] && r_valid_dly_1[j] && r_valid_dly_0[j]) 
                    r_next_taps[j] = 3'b101;  // T-5
                else if (r_valid_dly_4[j] && r_valid_dly_3[j] && r_valid_dly_2[j] && r_valid_dly_1[j] && r_valid_dly_0[j]) 
                    r_next_taps[j] = 3'b100;  // T-4
                else if (r_valid_dly_3[j] && r_valid_dly_2[j] && r_valid_dly_1[j] && r_valid_dly_0[j]) 
                    r_next_taps[j] = 3'b011;  // T-3
                else if (r_valid_dly_2[j] && r_valid_dly_1[j] && r_valid_dly_0[j]) 
                    r_next_taps[j] = 3'b010;  // T-2
                else if (r_valid_dly_1[j] && r_valid_dly_0[j]) 
                    r_next_taps[j] = 3'b001;  // T-1
                else 
                    r_next_taps[j] = 3'b000;  // T
            end
        end
    endgenerate


// ChipWatcher_0 ChipWatcher_0_Inst
//   (
// 	.clk     (I_word_clock),      
// 	.probe0  (I_packet_done),        
// 	.probe1  (I_wait_for_sync),  
// 	.probe2  (O_packet_done_out), 
// 	.probe3  (I_word_in), 
// 	.probe4  (I_valid_in), 
// 	.probe5  (O_word_out), 
// 	.probe6  (O_valid_out), 
// 	.probe7  (r_word_out), 
// 	.probe8  (r_valid_out), 
// 	.probe9  (r_taps[0]), 
// 	.probe10 (r_taps[1]), 
// 	.probe11 (r_valid), 
// 	.probe12 (w_next_valid), 
// 	.probe13 (r_aligned_word)
//   );
endmodule

