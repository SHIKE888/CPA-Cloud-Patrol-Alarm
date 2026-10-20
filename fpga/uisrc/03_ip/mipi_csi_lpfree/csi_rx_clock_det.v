//--------------------------------------------------------------------------------------------
// CSI-RX 时钟检测模块
// 功能说明：
//   1. 检测外部时钟是否存在
//   2. 当外部时钟丢失时产生复位信号
//   3. 当检测到有效时钟时释放复位
//--------------------------------------------------------------------------------------------

module csi_rx_clock_det (
    input   I_ref_clock,   // 参考时钟 (用于监控外部时钟)
    input   I_ext_clock,   // 外部时钟 (需要检测的时钟)
    input   I_enable,       // 模块使能
    input   I_reset_in,     // 输入复位 (低有效)
    output  O_reset_out     // 输出复位 (低有效)
);

// ===========================================================================
// 参数定义
// ===========================================================================
localparam MAX_FAIL_COUNT = 250;  // 最大失败计数
localparam FAIL_THRESHOLD = 250;  // 失败阈值
localparam MIN_CLK_COUNT  = 2;    // 最小时钟计数

// ===========================================================================
// 内部寄存器定义
// ===========================================================================
reg [1:0] r_count_value;      // 时钟计数寄存器
reg       r_ext_clk_lat;     // 外部时钟锁存
reg       r_last_ext_clk;    // 上次外部时钟值
reg [7:0] r_clk_fail_count;  // 时钟失败计数器
reg       r_clk_fail;        // 时钟失败标志
reg       r_reset_out;       // 输出复位寄存器

// ===========================================================================
// 外部时钟域逻辑
// ===========================================================================
always @(posedge I_ext_clock or negedge I_reset_in) begin
    if (!I_reset_in) begin
        // 复位时清零计数器
        r_count_value <= 2'b0;
    end
    else if (r_clk_fail) begin
        // 时钟失败时清零计数器
        r_count_value <= 2'b0;
    end
    else if (I_enable) begin
        // 使能时递增计数器（最大到3）
        if (r_count_value < 2'b11) begin
            r_count_value <= r_count_value + 1'b1;
        end
    end
end

// ===========================================================================
// 参考时钟域逻辑
// ===========================================================================
always @(posedge I_ref_clock or negedge I_reset_in) begin
    if (!I_reset_in) begin
        // 复位时初始化寄存器
        r_ext_clk_lat    <= 1'b0;
        r_last_ext_clk   <= 1'b0;
        r_clk_fail_count <= 8'b0;
        r_clk_fail       <= 1'b0;
        r_reset_out      <= 1'b0;
    end
    else begin
        // 时钟同步链
        r_ext_clk_lat  <= I_ext_clock;
        r_last_ext_clk <= r_ext_clk_lat;
        
        // 检测时钟变化
        if (r_last_ext_clk != r_ext_clk_lat) begin
            // 检测到时钟变化，重置失败计数器
            r_clk_fail_count <= 8'b0;
            r_clk_fail       <= 1'b0;
        end
        else begin
            // 未检测到时钟变化
            if (r_clk_fail_count < MAX_FAIL_COUNT) begin
                r_clk_fail_count <= r_clk_fail_count + 1'b1;
            end
            
            // 检查是否达到失败阈值
            if (r_clk_fail_count >= FAIL_THRESHOLD) begin
                r_clk_fail <= 1'b1;
            end
        end
        
        // 输出复位逻辑
        r_reset_out <= (r_count_value >= MIN_CLK_COUNT) ? 1'b1 : 1'b0;
    end
end

// ===========================================================================
// 输出分配
// ===========================================================================
assign O_reset_out = r_reset_out;

endmodule