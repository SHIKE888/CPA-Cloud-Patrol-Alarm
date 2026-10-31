//=============================================================================
// sensor_sync_start.v —— 双路传感器的"同步启动"时序
//
//  为什么需要它：
//    双目交替推流要求两颗传感器的 **帧/行是同步的**（见 dual_frame_sched 的说明）。
//    两颗模组的 MCLK 虽然都来自同一个 24MHz PLL，但各自上电/复位时刻不同，
//    内部帧计数器的相位是任意的 —— 差多少都有可能。
//    本模块用"同时释放两颗传感器 RSTn、再同时重跑初始化表"把相位拉到
//    同一个起点（两颗同频同表，之后就不会漂）。
//
//  时序（25MHz 域）：
//    idle --I_start--> PH1(RSTn=0, cfg 复位保持) 20ms
//                      PH2(RSTn=1, cfg 仍保持)   20ms   <- 给传感器内部起振留时间
//                      PH3 释放 cfg -> 两张初始化表从同一拍开始跑
//
//  ⚠ 上电默认（没有 I_start）时 O_rst_n=1、O_cfg_restart=0 ——
//    和原来"RSTn 恒高、cfg 立即启动"完全一致，不影响单目上电即正常。
//
//  ⚠ 触发条件：RK 写 0xDB 且 bit1=1（进双目）。想重来一次就再写一次同样的值。
//=============================================================================
`timescale 1ns/1ns

module sensor_sync_start #(
    parameter HOLD_CYCLES = 500_000,      // 20ms @ 25MHz
    parameter CNTW        = 20
)(
    input  wire I_clk,          // 25MHz
    input  wire I_rst_n,        // S_pll_lock
    input  wire I_start,        // 单拍脉冲: 请求同步启动
    output reg  O_rst_n,        // 同时给两颗传感器的 RSTn (高有效)
    output reg  O_cfg_restart   // 高 = 两个 ui_cfg_imx415 保持在复位
);

    localparam [1:0] PH_IDLE = 2'd0,
                     PH_RST  = 2'd1,
                     PH_WAIT = 2'd2,
                     PH_RUN  = 2'd3;

    reg [1:0]      state;
    reg [CNTW-1:0] cnt;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            state         <= PH_IDLE;
            cnt           <= {CNTW{1'b0}};
            O_rst_n       <= 1'b1;
            O_cfg_restart <= 1'b0;
        end else begin
            case (state)
                PH_IDLE: begin
                    O_rst_n       <= 1'b1;
                    O_cfg_restart <= 1'b0;
                    cnt           <= {CNTW{1'b0}};
                    if (I_start) begin
                        state         <= PH_RST;
                        O_rst_n       <= 1'b0;      // 拉低两颗的 RSTn
                        O_cfg_restart <= 1'b1;      // 初始化表先按住
                    end
                end
                PH_RST: begin
                    if (cnt == HOLD_CYCLES-1) begin
                        cnt   <= {CNTW{1'b0}};
                        state <= PH_WAIT;
                        O_rst_n <= 1'b1;            // 同时释放 RSTn
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                PH_WAIT: begin
                    if (cnt == HOLD_CYCLES-1) begin
                        cnt           <= {CNTW{1'b0}};
                        state         <= PH_RUN;
                        O_cfg_restart <= 1'b0;      // 两张表同一拍开始
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
                PH_RUN: begin
                    O_rst_n       <= 1'b1;
                    O_cfg_restart <= 1'b0;
                    state         <= PH_IDLE;       // 回去等下一次触发
                end
                default: state <= PH_IDLE;
            endcase
        end
    end

endmodule
