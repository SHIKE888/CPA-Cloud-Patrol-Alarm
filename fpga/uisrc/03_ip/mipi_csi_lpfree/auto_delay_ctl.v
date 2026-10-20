// ============================================================================
// auto_delay_ctl — Eye-Scan 版本 v3
//
// 修复 v2 的致命缺陷：MIPI 时钟启动后 camera 需要 50-100ms 才发第一帧，
// 但 eye-scan 只需 ~19ms，导致全部 tap 测试时无数据，best_len=0 → fallback。
//
// 新增 ST_WAIT_DATA 阶段：
//   0. 先设 tap=32，等待任一 lane 出现 byte_align_done（证明有数据）
//      或超时 ~150ms（2^24 cycles @111MHz），兼容无 camera 场景
//   1. 遍历全部 64 个 tap（0 → 63）
//   2. 每个 tap：settle 256 cycles → 测试 TEST_LEN 个 cycle
//   3. 测试期间计数"4-lane 全部 byte_align"的周期数
//      若 align_cnt >= PASS_THRESH → PASS（容忍 MIPI 包间的消隐间隔）
//   4. 找最长连续 PASS 区间（eye），取中点
//   5. 应用中点 tap 并锁定
//
// 端口保持与原版完全兼容，替换后无需改上层连线
// ============================================================================
`timescale 1ns / 1ps

module auto_delay_ctl #(
    parameter MIPI_LAN      = 4,
    parameter LAN_DATA_CUNT = 10'h3ff   // 保留旧参数名兼容（未使用）
) (
    input   wire                    I_byte_clk,
    input   wire                    I_reset_n,
    input   wire [MIPI_LAN-1:0]    I_byte_align_done,
    output  reg  [5:0]             O_delay_value,
    output  reg                    O_delay_vaild,
    output  reg                    O_auto_delay_done,
    output  wire [5:0]             O_dbg_best_len     // eye 宽度调试输出
);

// ---- 参数 ----
localparam [15:0] TEST_LEN    = 16'h7FFF;  // 32767 cycles ≈ 295?s @111MHz（~19行）
localparam [15:0] PASS_THRESH = 16'd64;    // 至少 64 周期 all-aligned → PASS

// ---- 状态定义 ----
localparam [3:0]
    ST_WAIT_DATA = 4'd0,   // 等待 camera 开始发送数据
    ST_WAIT_SET  = 4'd1,   // 初始 tap 设定后 settle
    ST_SET_TAP   = 4'd2,
    ST_SETTLE    = 4'd3,
    ST_TEST      = 4'd4,
    ST_NEXT      = 4'd5,
    ST_FIND      = 4'd6,
    ST_APPLY     = 4'd7,
    ST_DONE      = 4'd8;

reg [3:0]   state;
reg [5:0]   scan_tap;
reg [15:0]  cnt;            // settle / test 复用计数器（16-bit）
reg [15:0]  align_cnt;      // all-aligned 周期计数
reg         pass_flag;

wire w_all_aligned = & I_byte_align_done;
wire w_any_aligned = | I_byte_align_done;

// ---- 等待 camera 数据计数器 ----
reg [23:0]  wait_cnt;       // 2^24 = ~151ms @111MHz

// ---- eye 区间跟踪 ----
reg [5:0]  cur_start;
reg [5:0]  cur_len;
reg        in_run;
reg [5:0]  best_start;
reg [5:0]  best_len;

assign O_dbg_best_len = best_len;

// ---- 主状态机 ----
always @(posedge I_byte_clk or negedge I_reset_n) begin
    if (!I_reset_n) begin
        state             <= ST_WAIT_DATA;
        scan_tap          <= 6'd0;
        cnt               <= 16'd0;
        align_cnt         <= 16'd0;
        pass_flag         <= 1'b0;
        O_delay_value     <= 6'd32;
        O_delay_vaild     <= 1'b0;
        O_auto_delay_done <= 1'b0;
        wait_cnt          <= 24'd0;
        cur_start         <= 6'd0;
        cur_len           <= 6'd0;
        in_run            <= 1'b0;
        best_start        <= 6'd0;
        best_len          <= 6'd0;
    end else begin
        O_delay_vaild <= 1'b0;

        case (state)
        // ---- 等待 camera 发送数据 ----
        ST_WAIT_DATA: begin
            O_delay_value <= 6'd32;     // 初始 tap = 32（中间值）
            O_delay_vaild <= 1'b1;
            wait_cnt      <= 24'd0;
            cnt           <= 16'd0;
            state         <= ST_WAIT_SET;
        end

        ST_WAIT_SET: begin
            wait_cnt <= wait_cnt + 1'b1;
            // 任一 lane 出现对齐 → 说明 camera 在发数据，可以开始扫描
            // 或者超时（~150ms）→ 无论如何开始扫描
            if (w_any_aligned || wait_cnt[23]) begin
                scan_tap <= 6'd0;
                state    <= ST_SET_TAP;
            end
        end

        // ---- 正常 eye-scan 流程 ----
        ST_SET_TAP: begin
            O_delay_value <= scan_tap;
            O_delay_vaild <= 1'b1;
            cnt           <= 16'd0;
            align_cnt     <= 16'd0;
            state         <= ST_SETTLE;
        end

        ST_SETTLE: begin
            if (cnt == 16'hFF) begin     // 256 cycles settle
                cnt       <= 16'd0;
                pass_flag <= 1'b0;
                state     <= ST_TEST;
            end else
                cnt <= cnt + 1'b1;
        end

        ST_TEST: begin
            if (cnt == TEST_LEN) begin
                pass_flag <= (align_cnt >= PASS_THRESH);
                state     <= ST_NEXT;
            end else begin
                cnt <= cnt + 1'b1;
                if (w_all_aligned)
                    align_cnt <= align_cnt + 1'b1;
            end
        end

        ST_NEXT: begin
            if (pass_flag) begin
                if (!in_run) begin
                    in_run    <= 1'b1;
                    cur_start <= scan_tap;
                    cur_len   <= 6'd1;
                end else begin
                    cur_len   <= cur_len + 1'b1;
                end
            end else begin
                if (in_run) begin
                    if (cur_len > best_len) begin
                        best_start <= cur_start;
                        best_len   <= cur_len;
                    end
                    in_run  <= 1'b0;
                    cur_len <= 6'd0;
                end
            end

            if (scan_tap == 6'd63) begin
                state <= ST_FIND;
            end else begin
                scan_tap <= scan_tap + 1'b1;
                state    <= ST_SET_TAP;
            end
        end

        ST_FIND: begin
            if (in_run && cur_len > best_len) begin
                best_start <= cur_start;
                best_len   <= cur_len;
            end
            state <= ST_APPLY;
        end

        ST_APPLY: begin
            if (best_len != 6'd0) begin
                O_delay_value <= best_start + best_len[5:1];
            end else begin
                O_delay_value <= 6'd32;
            end
            O_delay_vaild <= 1'b1;
            state         <= ST_DONE;
        end

        ST_DONE: begin
            O_auto_delay_done <= 1'b1;
        end

        default: state <= ST_WAIT_DATA;
        endcase
    end
end

endmodule
