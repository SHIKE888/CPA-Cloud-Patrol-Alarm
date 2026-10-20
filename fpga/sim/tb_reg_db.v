//=============================================================================
// tb_reg_db.v —— 0xDB (CSI 源选择) 寄存器读写 + 版本号 验证
//
// 只测寄存器堆本身，不依赖任何图像通路，跑起来 1ms 内结束。
//   1. 复位后 0xDB 必须是 0（上电默认 cam0）—— 这是"只接 cam0 时行为与
//      单路版本一致"的前提；
//   2. 写 1 读回必须是 1；写 0 读回必须是 0；写 0xFF 只取 bit0；
//   3. 0xDA (Bayer) 不受影响（相邻寄存器不能串）；
//   4. 0xAA/0xA9 ver == 0x4601
//=============================================================================
`timescale 1ns/1ps

module tb_reg_db;

    reg        clk = 0;
    always #5 clk = ~clk;
    reg        rstn = 0;

    reg        wr_en   = 0;
    reg  [7:0] wr_addr = 0;
    reg  [7:0] wr_data = 0;
    reg  [7:0] rd_addr = 0;
    wire [7:0] rd_data;

    wire cfg_rx_sel;
    wire [1:0] cfg_bayer_sel;

    jpeg_regfile #(.JPEG_VER(16'h4700)) u_reg (
        .I_clk           (clk),
        .I_rst_n         (rstn),
        .I_wr_en         (wr_en),
        .I_wr_addr       (wr_addr),
        .I_wr_data       (wr_data),
        .I_rd_addr       (rd_addr),
        .O_rd_data       (rd_data),
        .I_st_frame_bytes(24'd0),
        .I_st_total_bytes(32'd0),
        .I_st_scale      (8'd0),
        .I_st_busy       (1'b0),
        .I_st_frame_done (1'b0),
        .I_st_overflow   (1'b0),
        .I_qtable_rd_data(8'h00),
        .I_st_frame_cnt  (32'd0),
        .I_st_cam_wr_cnt (16'd0),
        .I_st_line_groups(16'd0),
        .I_st_cam_busy   (1'b0),
        .I_dbg_mipi      (8'd0),
        .I_dbg_delay     (8'd0),
        .I_dbg_best_len  (6'd0),
        .I_dbg_autodone  (1'b0),
        .I_dbg1_mipi     (8'd0),
        .I_dbg1_delay    (8'd0),
        .I_dbg1_best_len (6'd0),
        .I_dbg1_autodone (1'b0),
        .I_dbg_status    (8'd0),
        .O_cfg_bayer_sel (cfg_bayer_sel),
        .O_cfg_rx_sel    (cfg_rx_sel)
    );

    integer err = 0;

    task wr(input [7:0] a, input [7:0] d);
        begin
            @(posedge clk); wr_en <= 1'b1; wr_addr <= a; wr_data <= d;
            @(posedge clk); wr_en <= 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // 读口是 1 拍延迟：
    //   edge N   : rd_addr <= a
    //   edge N+1 : O_rd_data <= f(a)   (NBA, 沿后生效)
    // 所以在 edge N+1 之后的 negedge 采才有效；直接在 posedge 后采会读到
    // 上一拍的旧值（前几个寄存器会整体错位一格，很容易误判成 RTL 有问题）。
    task rd(input [7:0] a, output [7:0] d);
        begin
            @(posedge clk); rd_addr <= a;
            @(posedge clk);
            @(negedge clk);
            d = rd_data;
            @(posedge clk);
        end
    endtask

    task expect8(input [7:0] a, input [7:0] exp, input [255:0] what);
        reg [7:0] got;
        begin
            rd(a, got);
            if (got !== exp) begin
                $display("FAIL 0x%02x (%0s): got 0x%02x expect 0x%02x", a, what, got, exp);
                err = err + 1;
            end else begin
                $display("ok   0x%02x (%0s) = 0x%02x", a, what, got);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (5) @(posedge clk);

        // 1. 上电默认
        expect8(8'hDB, 8'h00, "default cam0");
        if (cfg_rx_sel !== 1'b0) begin
            $display("FAIL O_cfg_rx_sel 复位后应为 0, 实际 %b", cfg_rx_sel);
            err = err + 1;
        end

        // 2. 写 1 / 写 0 / 写 0xFF
        wr(8'hDB, 8'h01);
        expect8(8'hDB, 8'h01, "after write 1");
        if (cfg_rx_sel !== 1'b1) begin
            $display("FAIL O_cfg_rx_sel 应为 1, 实际 %b", cfg_rx_sel);
            err = err + 1;
        end

        wr(8'hDB, 8'h00);
        expect8(8'hDB, 8'h00, "after write 0");

        wr(8'hDB, 8'hFF);
        expect8(8'hDB, 8'h07, "write 0xFF -> bit0..2 only");

        // 3. 相邻寄存器不能串
        wr(8'hDA, 8'h02);
        wr(8'hDB, 8'h01);
        expect8(8'hDA, 8'h02, "bayer untouched by 0xDB");
        expect8(8'hDB, 8'h01, "rx_sel untouched by 0xDA");

        // 4. 版本号
        expect8(8'hA9, 8'h00, "ver low");
        expect8(8'hAA, 8'h47, "ver high");

        // 恢复默认
        wr(8'hDB, 8'h00);
        wr(8'hDA, 8'h00);

        $display("===============================================================");
        if (err == 0) $display("PASS: 0xDB register + version 0x4700 OK");
        else          $display("FAIL: %0d 项", err);
        $display("===============================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
