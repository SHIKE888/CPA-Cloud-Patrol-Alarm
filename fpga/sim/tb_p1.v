`timescale 1ns/1ps
//==============================================================================
//  tb_p1.v —— P1 阶段自校验 testbench
//    覆盖: jpeg_cmd_1wire + jpeg_regfile + jpeg_qtable_ram
//
//  验证点:
//    T1  复位后量化表 = T.81 Annex K.1 标准表 (亮度[0]=16, 色度[0]=17)
//    T2  单线发命令能正确写入 MODE / QUALITY
//    T3  24 位目标码率分 3 次写入后拼装正确
//    T4  量化表可被在线改写并回读
//    T5  校验和错误的帧被丢弃, 且 O_err_cnt 递增
//    T6  未定义地址写入被忽略
//    T7  流使能闸门: 命令短脉冲不打断流; 持续低电平才关流
//
//  说明: 这里故意把 CLK_HZ/BAUD 设成很小的值 (位周期 16 个时钟),
//        逻辑不变但仿真时间从毫秒级降到微秒级。
//        位周期只有 16 拍, 比真实参数(BIT_CYCLES≈3万)苛刻得多,
//        这里过了, 真机时序余量只会更大。
//==============================================================================

module tb_p1;

    // ------------------------------------------------------------ 参数
    localparam CLK_HZ      = 1600000;
    localparam BAUD        = 100000;
    localparam integer BIT_CYCLES = CLK_HZ / BAUD;      // 16
    localparam integer EN_CYCLES  = BIT_CYCLES * 20;    // 320

    // ------------------------------------------------------------ 时钟/复位
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------ 记分
    integer pass = 0, fail = 0;

    task chk(input [8*64-1:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) begin
                pass = pass + 1;
                $display("  [OK  ] %0s = %0d", name, got);
            end else begin
                fail = fail + 1;
                $display("  [FAIL] %0s = %0d, 期望 %0d", name, got, exp);
            end
        end
    endtask

    // ------------------------------------------------------------ DUT 互连
    reg         line = 1'b1;

    wire        stream_en, wr_en;
    wire [7:0]  wr_addr, wr_data, rx_byte;
    wire        rx_valid;
    wire [7:0]  err_cnt;

    jpeg_cmd_1wire #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD),
        .EN_BITS(20)
    ) u_cmd (
        .I_clk      (clk),
        .I_rst_n    (rst_n),
        .I_line     (line),
        .O_stream_en(stream_en),
        .O_wr_en    (wr_en),
        .O_wr_addr  (wr_addr),
        .O_wr_data  (wr_data),
        .O_rx_byte  (rx_byte),
        .O_rx_valid (rx_valid),
        .O_err_cnt  (err_cnt)
    );

    reg  [7:0]  rd_addr = 8'hFF;
    wire [7:0]  rd_data;

    // 量化表读口 A 由 rd_addr 推导 (地址 0x10~0x8F -> 下标 0~127)
    wire [6:0]  qt_idx_a = rd_addr[6:0] - 7'h10;
    wire [7:0]  qt_rd_a, qt_rd_b;

    jpeg_qtable_ram u_qt (
        .I_clk     (clk),
        .I_rst_n   (rst_n),
        .I_wr_en   (wr_en),
        .I_wr_addr (wr_addr),
        .I_wr_data (wr_data),
        .I_rd_idx_a(qt_idx_a),
        .O_rd_data_a(qt_rd_a),
        .I_rd_idx_b(7'd0),
        .O_rd_data_b(qt_rd_b)
    );

    wire        cfg_lossless, cfg_bypass, cfg_single, cfg_rc_en, soft_rst;
    wire [6:0]  cfg_quality;
    wire [23:0] cfg_target;
    wire [3:0]  cfg_rc_speed;
    wire [1:0]  cfg_subsample;
    wire [7:0]  cfg_restart;
    wire [2:0]  cfg_predictor;

    jpeg_regfile #(.JPEG_VER(16'h0100)) u_reg (
        .I_clk           (clk),
        .I_rst_n         (rst_n),
        .I_wr_en         (wr_en),
        .I_wr_addr       (wr_addr),
        .I_wr_data       (wr_data),
        .I_rd_addr       (rd_addr),
        .O_rd_data       (rd_data),
        .O_cfg_lossless  (cfg_lossless),
        .O_cfg_bypass    (cfg_bypass),
        .O_cfg_single    (cfg_single),
        .O_cfg_quality   (cfg_quality),
        .O_cfg_target_bytes(cfg_target),
        .O_cfg_rc_en     (cfg_rc_en),
        .O_cfg_rc_speed  (cfg_rc_speed),
        .O_cfg_subsample (cfg_subsample),
        .O_cfg_restart_int(cfg_restart),
        .O_cfg_predictor (cfg_predictor),
        .O_soft_rst      (soft_rst),
        .I_st_frame_bytes(24'h0000FF),
        .I_st_total_bytes(32'h12345678),
        .I_st_scale      (8'h55),
        .I_st_busy       (1'b1),
        .I_st_frame_done (1'b0),
        .I_st_overflow   (1'b0),
        .I_qtable_rd_data(qt_rd_a)
    );

    // ------------------------------------------------------------ 任务
    reg [7:0] rval;

    // 读一个寄存器地址 (量化表地址走同一条路)
    task rd_reg(input [7:0] a);
        begin
            rd_addr = a;
            repeat (3) @(posedge clk);
            rval = rd_data;
        end
    endtask

    // 按 8N1 发一个字节, 模拟 RK 在 milianke_mipi.c 里用 udelay 位翻转
    task send_byte(input [7:0] b);
        integer i;
        begin
            line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);   // 空闲
            line = 1'b0; repeat (BIT_CYCLES) @(posedge clk);   // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                line = b[i];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);   // 停止位
        end
    endtask

    // 一帧: SYNC | ADDR | DATA | CHK   (CHK = ADDR ^ DATA ^ 0x5A)
    task send_cmd(input [7:0] a, input [7:0] d);
        begin
            send_byte(8'h55);
            send_byte(a);
            send_byte(d);
            send_byte(a ^ d ^ 8'h5A);
        end
    endtask

    // 故意发错校验和的帧
    task send_cmd_bad(input [7:0] a, input [7:0] d);
        begin
            send_byte(8'h55);
            send_byte(a);
            send_byte(d);
            send_byte(a ^ d ^ 8'hFF);      // 错误的 CHK
        end
    endtask

    // ------------------------------------------------------------ 主流程
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("tb_p1.vcd");
            $dumpvars(0, tb_p1);
        end

        $display("==================================================");
        $display(" P1 验证: 寄存器堆 + 量化表 + 单线命令通道");
        $display(" (位周期 %0d 时钟, 使能闸门 %0d 时钟)", BIT_CYCLES, EN_CYCLES);
        $display("==================================================");

        // ---- 复位 ----
        rst_n = 1'b0;
        line  = 1'b1;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---------------------------------------------------- T1 量化表复位值
        $display("\n[T1] 复位后量化表应为 T.81 Annex K.1 标准表");
        rd_reg(8'h10); chk("Q_L[0]  (Annex K 亮度[0]=16)", rval, 8'd16);
        rd_reg(8'h11); chk("Q_L[1]  (亮度[1]=11)",        rval, 8'd11);
        rd_reg(8'h1A); chk("Q_L[10] (亮度[10]=14)",       rval, 8'd14);
        rd_reg(8'h50); chk("Q_C[0]  (色度[0]=17)",        rval, 8'd17);
        rd_reg(8'h51); chk("Q_C[1]  (色度[1]=18)",        rval, 8'd18);
        rd_reg(8'h8F); chk("Q_C[63] (色度[63]=99)",       rval, 8'd99);

        // ---------------------------------------------------- T2 写控制寄存器
        $display("\n[T2] 通过单线命令写 MODE / QUALITY");
        send_cmd(8'h01, 8'd65);                       // QUALITY = 65
        repeat (5) @(posedge clk);
        chk("QUALITY 直出", cfg_quality, 7'd65);
        rd_reg(8'h01); chk("QUALITY 回读", rval, 8'd65);

        send_cmd(8'h00, 8'h01);                       // MODE[0] = 无损
        repeat (5) @(posedge clk);
        chk("MODE[0] 无损", cfg_lossless, 1'b1);
        rd_reg(8'h00); chk("MODE 回读", rval, 8'h01);

        send_cmd(8'h00, 8'h05);                       // MODE = 无损 + 单帧
        repeat (5) @(posedge clk);
        chk("MODE[0] 无损", cfg_lossless, 1'b1);
        chk("MODE[2] 单帧", cfg_single,   1'b1);
        chk("MODE[1] 直通(应=0)", cfg_bypass, 1'b0);

        // ---------------------------------------------------- T3 24 位目标码率
        $display("\n[T3] 24 位目标码率分 3 字节写入");
        send_cmd(8'h02, 8'h34);
        send_cmd(8'h03, 8'h12);
        send_cmd(8'h04, 8'h00);
        repeat (5) @(posedge clk);
        chk("TARGET_BYTES", cfg_target, 24'h001234);

        send_cmd(8'h05, 8'h01);                       // RC 使能
        repeat (5) @(posedge clk);
        chk("RC_EN", cfg_rc_en, 1'b1);

        send_cmd(8'h07, 8'h02);                       // 4:2:0
        repeat (5) @(posedge clk);
        chk("SUBSAMPLE 4:2:0", cfg_subsample, 2'd2);

        // ---------------------------------------------------- T4 在线改量化表
        $display("\n[T4] 在线改写量化表并回读");
        send_cmd(8'h10, 8'd3);                        // 亮度[0] = 3
        send_cmd(8'h50, 8'd7);                        // 色度[0] = 7
        repeat (5) @(posedge clk);
        rd_reg(8'h10); chk("改写后 Q_L[0]", rval, 8'd3);
        rd_reg(8'h50); chk("改写后 Q_C[0]", rval, 8'd7);
        rd_reg(8'h11); chk("未动的 Q_L[1] 应保持 11", rval, 8'd11);

        // ---------------------------------------------------- T5 校验错误
        $display("\n[T5] 校验和错误的帧必须丢弃");
        rd_reg(8'h06); chk("RC_SPEED 初值", rval, 8'd8);
        send_cmd_bad(8'h06, 8'd5);
        repeat (5) @(posedge clk);
        rd_reg(8'h06); chk("坏帧不应改写 RC_SPEED", rval, 8'd8);
        chk("O_err_cnt 应 = 1", err_cnt, 8'd1);

        // ---------------------------------------------------- T6 未定义地址
        $display("\n[T6] 未定义地址写入应被忽略");
        send_cmd(8'h30, 8'hAB);       // 0x30 其实是量化表 -> 会写进去, 换 0xEE
        send_cmd(8'hEE, 8'hCD);
        repeat (5) @(posedge clk);
        rd_reg(8'hEE); chk("未定义地址回读应为 0", rval, 8'd0);
        chk("QUALITY 未被误改", cfg_quality, 7'd65);

        // ---------------------------------------------------- T7 流使能闸门
        $display("\n[T7] 流使能闸门");
        line = 1'b1;
        repeat (EN_CYCLES + 20) @(posedge clk);
        chk("空闲高电平 -> 流使能", stream_en, 1'b1);

        // 发一条命令: 线会短暂拉低, 但不该打断流
        send_cmd(8'h01, 8'd50);
        repeat (10) @(posedge clk);
        chk("命令期间流使能应保持", stream_en, 1'b1);
        chk("命令确实生效 (QUALITY=50)", cfg_quality, 7'd50);

        // 持续拉低 -> 关流
        line = 1'b0;
        repeat (EN_CYCLES + 20) @(posedge clk);
        chk("持续低电平 -> 关流", stream_en, 1'b0);

        // 重新拉高 -> 恢复
        line = 1'b1;
        repeat (EN_CYCLES + 20) @(posedge clk);
        chk("恢复高电平 -> 重新使能", stream_en, 1'b1);

        // ---------------------------------------------------- 汇总
        $display("\n==================================================");
        $display(" 通过 %0d 项, 失败 %0d 项", pass, fail);
        if (fail == 0) $display(" >>> P1 全部通过 <<<");
        else           $display(" >>> 有失败项, 请检查 <<<");
        $display("==================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display("!! 仿真超时 !!");
        $finish;
    end

endmodule
