`timescale 1ns/1ps
//==============================================================================
//  jpeg_cmd_1wire.v
//  单线命令通道 —— 把 I_dsi_en 那一根线复用成"参数下发串口"
//
//  为什么需要它:
//    本板 RK 与 FPGA 之间**只有一根信号线**是 RK 能主动驱动的:
//    dts 里的 mipi-en-gpios = <&gpio1 RK_PD0>, 在 FPGA 侧就是 I_dsi_en (L13)。
//    MIPI CSI-2 是单向的(FPGA->RK), 没有回传通道; PCIe 硬件不可用;
//    "fpga@1a" 那个 I2C 节点是 V4L2 虚拟占位, 并不存在物理 I2C。
//    所以"动态码率/双模式"的参数只能走这根线。
//
//  线序 (RK 侧在 milianke_mipi.c 里用 udelay 位翻转生成):
//
//    空闲:            高电平 (>= 3ms 判为"流使能")
//    1 个字节(8N1):   起始位(低) D0..D7(LSB先) 停止位(高)
//    4 字节一帧:      SYNC=0x55 | ADDR | DATA | CHK,  CHK = ADDR ^ DATA ^ 0x5A
//
//  与"流使能"的关系 (关键):
//    命令脉冲会让线短暂拉低。如果直接拿这根线当 enable, 一发命令流就断了。
//    所以这里做了 **时间闸门**: 只有持续低电平超过 EN_TIMEOUT (约 20 个位时间)
//    才判为"关流", 短脉冲只当命令。这样发命令时画面不会闪断。
//
//  单向性: FPGA 无法驱动这根线, 所以**只能写不能读**。
//    需要回读状态(帧字节数/当前缩放)时, 把这些信息塞进 JPEG 的 COM 段
//    (0xFFFE) 随码流一起发出去即可 —— 见 jpeg_headers.v。
//
//  用法 (顶层):
//    jpeg_cmd_1wire u_cmd (
//        .I_line      (I_dsi_en),        // 直连 FPGA 引脚
//        .O_stream_en (S_dsi_en),        // 拿去替换原来直接用的 I_dsi_en
//        .O_wr_en     (S_cmd_we),        // 接 jpeg_regfile / jpeg_qtable_ram 的写口
//        .O_wr_addr   (S_cmd_addr),
//        .O_wr_data   (S_cmd_data),
//        ...
//    );
//==============================================================================

module jpeg_cmd_1wire #(
    parameter CLK_HZ   = 148500000,   // 工作时钟 (S_pclkx1)
    parameter BAUD     = 4800,        // 波特率: 4800 -> 208.3us/位, 对 GPIO 翻转很宽容
    parameter EN_BITS  = 20           // 连续低电平超过这么多位时间才判"关流"
)(
    input  wire         I_clk,
    input  wire         I_rst_n,

    // ---------------- 那根线 ----------------
    input  wire         I_line,       // 异步输入, 内部做两级同步

    // ---------------- 输出 ----------------
    output reg          O_stream_en,  // 过滤后的流使能 (接 D-PHY)
    output reg          O_wr_en,      // 一个时钟宽的写脉冲
    output reg  [7:0]   O_wr_addr,
    output reg  [7:0]   O_wr_data,

    // ---------------- 调试 ----------------
    output wire [7:0]   O_rx_byte,    // 最近收到的字节
    output wire         O_rx_valid,   // 字节有效脉冲
    output reg  [7:0]   O_err_cnt     // 帧校验错误计数
);

    // ---------------------------------------------------------------- 参数
    localparam integer BIT_CYCLES = CLK_HZ / BAUD;          // 一个位多少时钟
    localparam integer HALF_BIT   = BIT_CYCLES / 2;         // 半位(采样中点)
    localparam integer EN_CYCLES  = BIT_CYCLES * EN_BITS;   // 流使能闸门

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    // 计数器位宽 (取够用即可, 省逻辑)
    localparam CBIT = $clog2(BIT_CYCLES) + 1;
    localparam EBIT = $clog2(EN_CYCLES)  + 1;

    // 把 integer 常量裁到位宽, 避免在比较里直接对 integer 做位选
    // (部分综合/仿真工具对 integer 的 part-select 支持不一致)
    localparam [CBIT-1:0] BIT_C = BIT_CYCLES[CBIT-1:0];
    localparam [CBIT-1:0] HALFB = HALF_BIT  [CBIT-1:0];
    localparam [EBIT-1:0] ENC   = EN_CYCLES [EBIT-1:0];

    // ---------------------------------------------------------------- 输入同步
    reg [2:0] line_sr;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) line_sr <= 3'b111;      // 空闲态是高
        else          line_sr <= {line_sr[1:0], I_line};
    end
    wire line_s = line_sr[2];                 // 同步后的线电平
    wire line_fall = (line_sr[2:1] == 2'b10); // 下降沿

    // ---------------------------------------------------------------- 流使能闸门
    // 高电平持续 EN_CYCLES -> 使能; 低电平持续 EN_CYCLES -> 关闭
    reg [EBIT-1:0] hi_cnt, lo_cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            hi_cnt     <= 0;
            lo_cnt     <= 0;
            O_stream_en<= 1'b0;
        end else begin
            if (line_s) begin
                if (hi_cnt != ENC) hi_cnt <= hi_cnt + 1'b1;
                lo_cnt <= 0;
                if (hi_cnt == ENC) O_stream_en <= 1'b1;
            end else begin
                if (lo_cnt != ENC) lo_cnt <= lo_cnt + 1'b1;
                hi_cnt <= 0;
                if (lo_cnt == ENC) O_stream_en <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------- UART 收字节
    reg [1:0]          st;
    reg [CBIT-1:0]     cnt;
    reg [3:0]          bn;
    reg [7:0]          sh;
    reg                rx_valid;
    reg [7:0]          rx_byte;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            st       <= S_IDLE;
            cnt      <= 0;
            bn       <= 0;
            sh       <= 8'h00;
            rx_valid <= 1'b0;
            rx_byte  <= 8'h00;
        end else begin
            rx_valid <= 1'b0;                 // 默认自清

            case (st)
            // 等下降沿 = 起始位
            S_IDLE: begin
                cnt <= 0;
                if (line_fall) st <= S_START;
            end

            // 半位后回采, 确认还是低 (滤掉毛刺造成的假起始)
            S_START: begin
                if (cnt == HALFB - 1'b1) begin
                    cnt <= 0;
                    if (line_s) st <= S_IDLE;          // 假起始, 丢弃
                    else begin
                        st <= S_DATA;
                        bn <= 4'd0;
                    end
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            // 每个位的中点采样, LSB 先
            S_DATA: begin
                if (cnt == HALFB) sh <= {line_s, sh[7:1]};
                if (cnt == BIT_C - 1'b1) begin
                    cnt <= 0;
                    if (bn == 4'd7) st <= S_STOP;
                    else            bn <= bn + 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            // 停止位必须是高, 否则丢弃这一字节
            S_STOP: begin
                if (cnt == BIT_C - 1'b1) begin
                    cnt <= 0;
                    st  <= S_IDLE;
                    if (line_s) begin
                        rx_byte  <= sh;
                        rx_valid <= 1'b1;
                    end
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
            endcase
        end
    end

    assign O_rx_byte  = rx_byte;
    assign O_rx_valid = rx_valid;

    // ---------------------------------------------------------------- 4 字节成帧
    //   SYNC(0x55) | ADDR | DATA | CHK      CHK = ADDR ^ DATA ^ 0x5A
    localparam [1:0] F_SYNC = 2'd0, F_ADDR = 2'd1, F_DATA = 2'd2, F_CHK = 2'd3;
    reg [1:0] fst;
    reg [7:0] f_addr, f_data;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            fst      <= F_SYNC;
            f_addr   <= 8'h00;
            f_data   <= 8'h00;
            O_wr_en  <= 1'b0;
            O_wr_addr<= 8'h00;
            O_wr_data<= 8'h00;
            O_err_cnt<= 8'h00;
        end else begin
            O_wr_en <= 1'b0;                  // 默认自清

            if (rx_valid) begin
                case (fst)
                F_SYNC: begin
                    if (rx_byte == 8'h55) fst <= F_ADDR;
                end
                F_ADDR: begin
                    f_addr <= rx_byte;
                    fst    <= F_DATA;
                end
                F_DATA: begin
                    f_data <= rx_byte;
                    fst    <= F_CHK;
                end
                F_CHK: begin
                    fst <= F_SYNC;
                    if (rx_byte == (f_addr ^ f_data ^ 8'h5A)) begin
                        O_wr_en   <= 1'b1;
                        O_wr_addr <= f_addr;
                        O_wr_data <= f_data;
                    end else begin
                        O_err_cnt <= O_err_cnt + 8'h01;
                    end
                end
                endcase
            end
        end
    end

endmodule
