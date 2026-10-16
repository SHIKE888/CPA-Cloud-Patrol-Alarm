`timescale 1ns/1ps
//==============================================================================
//  jpeg_regfile.v
//  JPEG 编码器参数寄存器堆 + 状态回读
//
//  传输无关设计:
//    本模块只认一个最简单的 8 位写口 (I_wr_en / I_wr_addr / I_wr_data)。
//    前端适配器可以是:
//      · jpeg_cmd_1wire.v  —— 把 I_dsi_en 那根线复用成单线命令通道 (本板唯一可用)
//      · jpeg_i2c_slave.v  —— I2C 从机 (预留, 万一后续版本有 I2C 连线)
//      · 任何其它通路
//    这样换控制通路不用动编码器本体。
//
//  寄存器映射 (字节地址):
//    ---- 控制 ----
//    0x00 MODE        [0] 1=无损 0=有损 ; [1] bypass ; [2] 单帧模式
//    0x01 QUALITY     有损质量 1..100
//    0x02 TGT_L       目标每帧字节数[7:0]
//    0x03 TGT_M       目标每帧字节数[15:8]
//    0x04 TGT_H       目标每帧字节数[23:16]
//    0x05 RC_EN       码率控制使能 [0]
//    0x06 RC_SPEED    收敛速度 1..15 (默认 8)
//    0x07 SUBSAMPLE   0=4:4:4 1=4:2:2 2=4:2:0
//    0x08 RST_INT     重启间隔(MCU 数), 0=不插 RST 标记
//    0x09 PREDICTOR   无损预测器 1..7, 0=MED(自适应)
//    0x0A SOFT_RST    写 1 -> 产生一个时钟宽的软复位脉冲
//    ---- 量化表 (本模块不管存储, 见 jpeg_qtable_ram.v) ----
//    0x10~0x4F QTABLE_L   亮度量化表 64 项
//    0x50~0x8F QTABLE_C   色度量化表 64 项
//    ---- 状态 (只读) ----
//    0xA0~0xA2 ST_FRAME_BYTES  上一帧字节数 [7:0][15:8][23:16]
//    0xA3~0xA6 ST_TOTAL_BYTES  累计字节数
//    0xA7 ST_SCALE    当前量化缩放 (随码率控制变化)
//    0xA8 ST_STATUS   [0]忙 [1]上一帧结束 [2]溢出 [3]无损模式回读
//    0xA9~0xAA ST_VER 版本号 (默认 0x0100)
//    ---- 预处理 P4/P5/P6 (Sobel / 阈值分割 / 形态学) ----
//    0xB0 PP_EN       总使能 [0]  (0 -> 强制直通原图)
//    0xB1 PP_MODE     [2:0] 0=原图 1=Sobel 2=阈值分割 3=形态学
//    0xB2 PP_SOBEL_SH 幅度右移 0..8 (默认 3, 使幅度满 0..255)
//    0xB3 PP_THRESH   二值化阈值 0..255 (默认 128)
//    0xB4 PP_MORPH    [0] 0=腐蚀(&) 1=膨胀(|)  (默认 1)
//    0xB8~0xBB ST_FRAME_CNT  已接收帧计数 (只读, RISC 可读回验证链路)
//    0xBC ST_HEARTBEAT       心跳计数 (只读, 每 256 读时钟 +1, 证明 FPGA 活着)
//
//  说明: 状态只读 —— 0x90 以下未定义的地址写入会被忽略。
//        单线命令通道是**单向**的, 回读要靠把这些状态塞进 JPEG 的 COM 段
//        (0xFFFE) 一起发出去, 见 jpeg_headers.v。
//==============================================================================

module jpeg_regfile #(
    parameter [15:0] JPEG_VER = 16'h0100
)(
    input  wire         I_clk,
    input  wire         I_rst_n,

    // ---------------- 通用 8 位写口 ----------------
    input  wire         I_wr_en,
    input  wire [7:0]   I_wr_addr,
    input  wire [7:0]   I_wr_data,

    // ---------------- 通用 8 位读口 (1 拍延迟) ----------------
    input  wire [7:0]   I_rd_addr,
    output reg  [7:0]   O_rd_data,

    // ---------------- 配置输出 ----------------
    output wire         O_cfg_lossless,     // 1 = 无损(SOF3) 0 = 有损(SOF0)
    output wire         O_cfg_bypass,       // 1 = 直通(不编码, 走原 YUV 通路)
    output wire         O_cfg_single,       // 1 = 只编一帧
    output wire [6:0]   O_cfg_quality,      // 1..100
    output wire [23:0]  O_cfg_target_bytes, // 0 = 不限
    output wire         O_cfg_rc_en,
    output wire [3:0]   O_cfg_rc_speed,
    output wire [1:0]   O_cfg_subsample,
    output wire [7:0]   O_cfg_restart_int,
    output wire [2:0]   O_cfg_predictor,
    output wire         O_soft_rst,         // 一个时钟宽

    // ---------------- 状态回读输入 ----------------
    input  wire [23:0]  I_st_frame_bytes,
    input  wire [31:0]  I_st_total_bytes,
    input  wire [7:0]   I_st_scale,
    input  wire         I_st_busy,
    input  wire         I_st_frame_done,
    input  wire         I_st_overflow,

    // ---------------- 量化表回读 (来自 jpeg_qtable_ram 的读口) ----------------
    // 地址 0x10~0x4F 对应 qtable 下标 0~63。因为范围是 0x10..0x4F,
    // 在 6 位宽下做 (addr[5:0] - 6'h10) 正好回绕得到 0..63, 不会越界。
    input  wire [7:0]   I_qtable_rd_data,

    // ---------------- 预处理 P4/P5/P6 配置输出 ----------------
    output wire         O_cfg_pp_en,
    output wire [2:0]   O_cfg_pp_mode,
    output wire [3:0]   O_cfg_pp_sobel_shift,
    output wire [7:0]   O_cfg_pp_thresh,
    output wire         O_cfg_pp_morph_sel,

    // ---------------- 补充状态输入 ----------------
    input  wire [31:0]  I_st_frame_cnt,     // 已接收帧计数 (供回读验证链路)

    // ---------------- 摄像头 / 画质参数输出 (地址 0xC0 起) ----------------
    output wire [19:0]  O_cfg_cam_exp,      // SHR0 曝光行数 (0 = 保持初始化表的值)
    output wire [7:0]   O_cfg_cam_gain,     // 0..100, 0.3dB/step (0 = 保持)
    output wire [3:0]   O_cfg_ev_bias,      // 曝光补偿, 偏移 8 表示 0EV
    output wire [7:0]   O_cfg_wb_r,         // 白平衡 R 增益, 128 = 1.0x
    output wire [7:0]   O_cfg_wb_b,         // 白平衡 B 增益, 128 = 1.0x
    output wire [2:0]   O_cfg_fps_div,      // 帧率分频 1..8 (1 = 原速)
    output wire [6:0]   O_cfg_roi_pct,      // ROI 百分比 25..100 (100 = 全画幅)
    output wire [7:0]   O_cfg_cam_trig,     // 写任意值 -> 触发一次摄像头参数下发
    // V21: 分辨率模式 0=1080p60 (默认) 1=4K30; o_res_chg 在写入时给一拍脉冲
    output wire [1:0]   O_cfg_res_mode,
    output wire         O_res_chg,

    // ---------------- 摄像头通道状态回读 ----------------
    input  wire [15:0]  I_st_cam_wr_cnt,    // 摄像头寄存器写成功次数
    // V21 诊断: 一行的像素组数 (只读, 历史最大值)
    input  wire [15:0]  I_st_line_groups,
    input  wire         I_st_cam_busy
);

    // ---------------------------------------------------------------- 控制寄存器
    reg        r_lossless;
    reg        r_bypass;
    reg        r_single;
    reg [6:0]  r_quality;
    reg [23:0] r_target;
    reg        r_rc_en;
    reg [3:0]  r_rc_speed;
    reg [1:0]  r_subsample;
    reg [7:0]  r_restart;
    reg [2:0]  r_predictor;
    reg        r_soft_rst;

    // 预处理寄存器
    reg        r_pp_en;
    reg [2:0]  r_pp_mode;
    reg [3:0]  r_pp_sobel_sh;
    reg [7:0]  r_pp_thresh;
    reg        r_pp_morph_sel;
    reg [7:0]  r_heartbeat;
    reg [31:0] s_frame_cnt;

    // 摄像头 / 画质参数 (0xC0 起)
    reg [19:0] r_cam_exp;
    reg [7:0]  r_cam_gain;
    reg [3:0]  r_ev_bias;
    reg [7:0]  r_wb_r, r_wb_b;
    reg [2:0]  r_fps_div;
    reg [6:0]  r_roi_pct;
    reg [7:0]  r_cam_trig;
    reg [1:0]  r_res_mode;     // V21: 0=1080p60, 1=4K30, 2=4K25
    reg        res_chg;        // V21: 模式寄存器写入脉冲 (自清)
    reg [15:0] s_cam_wr_cnt;
    reg        s_cam_busy;

    // 状态输入打一拍, 让跨模块路径短一点
    reg [23:0] s_frame_bytes;
    reg [31:0] s_total_bytes;
    reg [7:0]  s_scale;
    reg        s_busy, s_done, s_ovf;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s_frame_bytes <= 24'd0;
            s_total_bytes <= 32'd0;
            s_scale       <= 8'd0;
            s_busy        <= 1'b0;
            s_done        <= 1'b0;
            s_ovf         <= 1'b0;
            s_frame_cnt   <= 32'd0;
            s_cam_wr_cnt  <= 16'd0;
            s_cam_busy    <= 1'b0;
            // r_heartbeat 只在本块里复位/递增 —— 写在两个 always 块会报
            // HDL-8007 'constantly driven from multiple places'
            r_heartbeat   <= 8'd0;
        end else begin
            s_frame_bytes <= I_st_frame_bytes;
            s_total_bytes <= I_st_total_bytes;
            s_scale       <= I_st_scale;
            s_busy        <= I_st_busy;
            s_done        <= I_st_frame_done;
            s_ovf         <= I_st_overflow;
            s_frame_cnt   <= I_st_frame_cnt;
            s_cam_wr_cnt  <= I_st_cam_wr_cnt;
            s_cam_busy    <= I_st_cam_busy;
            r_heartbeat   <= r_heartbeat + 8'd1;   // 每 256 读时钟 +1, 证明时钟在跑
        end
    end

    // ---------------------------------------------------------------- 写
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            r_lossless   <= 1'b0;      // 默认有损
            r_bypass     <= 1'b0;
            r_single     <= 1'b0;
            r_quality    <= 7'd80;
            r_target     <= 24'd0;     // 0 = 不限码率
            r_rc_en      <= 1'b0;
            r_rc_speed   <= 4'd8;
            r_subsample  <= 2'd1;      // 默认 4:2:2
            r_restart    <= 8'd0;
            r_predictor  <= 3'd0;      // 0 = MED
            r_soft_rst   <= 1'b0;
            r_pp_en      <= 1'b0;
            r_pp_mode    <= 3'd0;      // 默认直通原图
            r_pp_sobel_sh<= 4'd3;      // 幅度右移 3 -> 满 0..255
            r_pp_thresh  <= 8'd128;
            r_pp_morph_sel <= 1'b1;    // 默认膨胀
            r_cam_exp    <= 20'd0;     // 0 = 不动初始化表里的曝光
            r_cam_gain   <= 8'd0;      // 0 = 不动
            r_ev_bias    <= 4'd8;      // 8 = 0EV
            r_wb_r       <= 8'd128;    // 1.0x
            r_wb_b       <= 8'd128;    // 1.0x
            r_fps_div    <= 3'd1;      // 原速
            r_roi_pct    <= 7'd100;    // 全画幅
            r_cam_trig   <= 8'd0;
            // ★★ V26 实验(2026-10-16): 默认改成 2'd2 = 以 **4K25 直接启动**。
            //   为什么要试这个: 两轮实测显示 "切到 binning 能成功、切到 4K 不能"
            //   (写 RES_MODE=2 后 RX 必死, 而写 RES_MODE=0 总能把 RX 拉回来)
            //   => 怀疑是 **4K 模式本身** 而不是切换机制的问题。
            //   另外厂商 PCIe 工程 imx415_pcie_top.v 里写的是
            //       reg_cam_mode <= 2'd1;   // Default: 4K@30fps
            //   也就是他们本来就是"上电直接以 4K 启动", 运行时热切换未必验证过。
            //   所以让 FPGA 上电就用 4K 初始化表(主表会带 MODE=1 选 all-pixel),
            //   一次性验证 4K 的表/几何/链路能不能跑通。
            //   验证完想回到 1080p: 写 RES_MODE=0 即可(实测这条恢复路径是通的),
            //   或把这一行改回 2'd0 重新编译。
            r_res_mode   <= 2'd2;      // V26: 实验 —— 默认 4K25 启动
            res_chg      <= 1'b0;
            // 注: r_heartbeat 不在这里复位, 它由上面那个自由运行计数块统一驱动
        end else begin
            r_soft_rst <= 1'b0;        // 自清, 只保持一拍
            res_chg    <= 1'b0;        // V21: 自清

            if (I_wr_en) begin
                case (I_wr_addr)
                    8'h00: begin
                        r_lossless <= I_wr_data[0];
                        r_bypass   <= I_wr_data[1];
                        r_single   <= I_wr_data[2];
                    end
                    8'h01: r_quality   <= (I_wr_data[6:0] == 7'd0) ? 7'd1
                                                                    : I_wr_data[6:0];
                    8'h02: r_target[ 7:0] <= I_wr_data;
                    8'h03: r_target[15:8] <= I_wr_data;
                    8'h04: r_target[23:16]<= I_wr_data;
                    8'h05: r_rc_en     <= I_wr_data[0];
                    8'h06: r_rc_speed  <= (I_wr_data[3:0] == 4'd0) ? 4'd1
                                                                    : I_wr_data[3:0];
                    8'h07: r_subsample <= I_wr_data[1:0];
                    8'h08: r_restart   <= I_wr_data;
                    8'h09: r_predictor <= I_wr_data[2:0];
                    8'h0A: r_soft_rst  <= I_wr_data[0];
                    // ---- 预处理 P4/P5/P6 ----
                    8'hB0: r_pp_en      <= I_wr_data[0];
                    8'hB1: r_pp_mode    <= I_wr_data[2:0];
                    8'hB2: r_pp_sobel_sh<= I_wr_data[3:0];
                    8'hB3: r_pp_thresh  <= I_wr_data;
                    8'hB4: r_pp_morph_sel <= I_wr_data[0];
                    // ---- 摄像头 / 画质参数 (0xC0 起) ----
                    8'hC0: r_cam_exp[ 7:0] <= I_wr_data;
                    8'hC1: r_cam_exp[15:8] <= I_wr_data;
                    8'hC2: r_cam_exp[19:16]<= I_wr_data[3:0];
                    8'hC3: r_cam_gain   <= I_wr_data;
                    8'hC4: r_ev_bias    <= I_wr_data[3:0];
                    8'hC5: r_wb_r       <= I_wr_data;
                    8'hC6: r_wb_b       <= I_wr_data;
                    8'hC7: r_fps_div    <= (I_wr_data[2:0] == 3'd0) ? 3'd1
                                                                : I_wr_data[2:0];
                    8'hC8: r_roi_pct    <= (I_wr_data[6:0] < 7'd25)  ? 7'd25
                                         : ((I_wr_data[6:0] > 7'd100) ? 7'd100
                                                                      : I_wr_data[6:0]);
                    8'hC9: r_cam_trig   <= I_wr_data;
                    // ---- V21: 分辨率模式 ----
                    8'hE0: begin
                        r_res_mode <= I_wr_data[1:0];
                        res_chg    <= 1'b1;
                    end
                    default: ;         // 0x50~ 状态区写入忽略; 0x10~0x4F 由 qtable RAM 处理
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- 读 (1 拍延迟)
    // 量化表整段占 0x10~0x8F (128 项 = 亮度 64 + 色度 64), 单独判断,
    // 免得在 case 里写 128 条标签。
    wire S_is_qtable = (I_rd_addr >= 8'h10) && (I_rd_addr <= 8'h8F);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_rd_data <= 8'h00;
        end else if (S_is_qtable) begin
            O_rd_data <= I_qtable_rd_data;
        end else begin
            case (I_rd_addr)
                8'h00: O_rd_data <= {5'b0, r_single, r_bypass, r_lossless};
                8'h01: O_rd_data <= {1'b0, r_quality};
                8'h02: O_rd_data <= r_target[ 7:0];
                8'h03: O_rd_data <= r_target[15:8];
                8'h04: O_rd_data <= r_target[23:16];
                8'h05: O_rd_data <= {7'b0, r_rc_en};
                8'h06: O_rd_data <= {4'b0, r_rc_speed};
                8'h07: O_rd_data <= {6'b0, r_subsample};
                8'h08: O_rd_data <= r_restart;
                8'h09: O_rd_data <= {5'b0, r_predictor};
                8'h0A: O_rd_data <= 8'h00;

                8'hA0: O_rd_data <= s_frame_bytes[ 7:0];
                8'hA1: O_rd_data <= s_frame_bytes[15:8];
                8'hA2: O_rd_data <= s_frame_bytes[23:16];
                8'hA3: O_rd_data <= s_total_bytes[ 7:0];
                8'hA4: O_rd_data <= s_total_bytes[15:8];
                8'hA5: O_rd_data <= s_total_bytes[23:16];
                8'hA6: O_rd_data <= s_total_bytes[31:24];
                8'hA7: O_rd_data <= s_scale;
                8'hA8: O_rd_data <= {4'b0, r_lossless, s_ovf, s_done, s_busy};
                8'hA9: O_rd_data <= JPEG_VER[ 7:0];
                8'hAA: O_rd_data <= JPEG_VER[15:8];

                8'hB0: O_rd_data <= {7'b0, r_pp_en};
                8'hB1: O_rd_data <= {5'b0, r_pp_mode};
                8'hB2: O_rd_data <= {4'b0, r_pp_sobel_sh};
                8'hB3: O_rd_data <= r_pp_thresh;
                8'hB4: O_rd_data <= {7'b0, r_pp_morph_sel};
                8'hB8: O_rd_data <= s_frame_cnt[ 7:0];
                8'hB9: O_rd_data <= s_frame_cnt[15:8];
                8'hBA: O_rd_data <= s_frame_cnt[23:16];
                8'hBB: O_rd_data <= s_frame_cnt[31:24];
                8'hBC: O_rd_data <= r_heartbeat;

                8'hC0: O_rd_data <= r_cam_exp[ 7:0];
                8'hC1: O_rd_data <= r_cam_exp[15:8];
                8'hC2: O_rd_data <= {4'b0, r_cam_exp[19:16]};
                8'hC3: O_rd_data <= r_cam_gain;
                8'hC4: O_rd_data <= {4'b0, r_ev_bias};
                8'hC5: O_rd_data <= r_wb_r;
                8'hC6: O_rd_data <= r_wb_b;
                8'hC7: O_rd_data <= {5'b0, r_fps_div};
                8'hC8: O_rd_data <= {1'b0, r_roi_pct};
                8'hC9: O_rd_data <= r_cam_trig;
                8'hE0: O_rd_data <= {6'b0, r_res_mode};
                8'hD0: O_rd_data <= s_cam_wr_cnt[ 7:0];
                8'hD1: O_rd_data <= s_cam_wr_cnt[15:8];
                8'hD2: O_rd_data <= {7'b0, s_cam_busy};
                // 参数区存在标志: 网页用它判断当前 bit 流里到底有没有
                // 0xC0~0xC9 这组寄存器 —— 没有的话读回来全是 0, 而 0
                // 对 EV/WB 来说恰好是“合法值”, 单看值分不出来。
                8'hD3: O_rd_data <= 8'hA5;
                // V21 诊断: 每行像素组数 (历史最大值, 小端)
                8'hD4: O_rd_data <= I_st_line_groups[ 7:0];
                8'hD5: O_rd_data <= I_st_line_groups[15:8];

                default: O_rd_data <= 8'h00;
            endcase
        end
    end

    // 量化表下标 (供顶层用): 地址 0x10~0x8F -> idx 0~127
    // 范围是 0x10..0x8F, 在 7 位宽下 (addr[6:0] - 7'h10) 正好回绕到 0..127。
    wire [6:0] S_qtable_idx = I_rd_addr[6:0] - 7'h10;

    // ---------------------------------------------------------------- 输出
    assign O_cfg_lossless    = r_lossless;
    assign O_cfg_bypass      = r_bypass;
    assign O_cfg_single      = r_single;
    assign O_cfg_quality     = r_quality;
    assign O_cfg_target_bytes= r_target;
    assign O_cfg_rc_en       = r_rc_en;
    assign O_cfg_rc_speed    = r_rc_speed;
    assign O_cfg_subsample   = r_subsample;
    assign O_cfg_restart_int = r_restart;
    assign O_cfg_predictor   = r_predictor;
    assign O_soft_rst        = r_soft_rst;

    // 预处理: PP_EN=0 时强制直通原图
    assign O_cfg_pp_en         = r_pp_en;
    assign O_cfg_pp_mode       = r_pp_en ? r_pp_mode : 3'd0;
    assign O_cfg_pp_sobel_shift= (r_pp_sobel_sh > 4'd8) ? 4'd8 : r_pp_sobel_sh;
    assign O_cfg_pp_thresh     = r_pp_thresh;
    assign O_cfg_pp_morph_sel  = r_pp_morph_sel;

    // 摄像头 / 画质参数
    assign O_cfg_cam_exp   = r_cam_exp;
    assign O_cfg_cam_gain  = r_cam_gain;
    assign O_cfg_ev_bias   = r_ev_bias;
    assign O_cfg_wb_r      = r_wb_r;
    assign O_cfg_wb_b      = r_wb_b;
    assign O_cfg_fps_div   = r_fps_div;
    assign O_cfg_roi_pct   = r_roi_pct;
    assign O_cfg_cam_trig  = r_cam_trig;
    assign O_cfg_res_mode  = r_res_mode;   // V21
    assign O_res_chg       = res_chg;      // V21

endmodule
