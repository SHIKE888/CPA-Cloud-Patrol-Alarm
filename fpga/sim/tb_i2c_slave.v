//=============================================================================
//  tb_i2c_slave.v —— I2C 从机仿真
//
//  含一个 I2C 主机模型 (开漏建模: 谁拉低谁说了算, 否则靠上拉为高)。
//  被测: 写寄存器 / 读寄存器 (含连续读自增) / 地址不匹配不 ACK。
//=============================================================================
`timescale 1ns / 1ps

module tb_i2c_slave;

	localparam [6:0] DEV_ADDR = 7'h40;
	localparam integer T = 8;            // SCL 半周期 = 8 个系统时钟

	reg clk = 1'b0;
	always #5 clk = ~clk;                // 100 MHz

	reg rst_n = 1'b0;

	//---------------------------------------------------------- 开漏总线
	reg scl_m = 1'b1;                    // 主机侧驱动 (从机不拉 SCL)
	reg sda_m = 1'b1;
	wire sda_s;                          // 从机 sda_drive: 1 = 拉低
	wire scl = scl_m;
	wire sda = (sda_m == 1'b0 || sda_s == 1'b1) ? 1'b0 : 1'b1;

	//---------------------------------------------------------- 模拟寄存器堆
	// 行为与 jpeg_regfile 一致: 读口 1 拍延迟
	reg [7:0] regs [0:255];
	reg [7:0] rd_r;
	wire        wr_en;
	wire [7:0]  wr_addr, wr_data, rd_addr;

	integer i;
	initial for (i = 0; i < 256; i = i + 1) regs[i] = 8'h00;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) rd_r <= 8'h00;
		else begin
			rd_r <= regs[rd_addr];
			if (wr_en) regs[wr_addr] <= wr_data;
		end
	end

	//---------------------------------------------------------- DUT
	i2c_slave #(.DEV_ADDR(DEV_ADDR)) u_dut (
		.clk        (clk),
		.rst_n      (rst_n),
		.scl_i      (scl),
		.sda_i      (sda),
		.sda_drive  (sda_s),
		.o_wr_en    (wr_en),
		.o_wr_addr  (wr_addr),
		.o_wr_data  (wr_data),
		.o_rd_addr  (rd_addr),
		.i_rd_data  (rd_r),
		.o_dbg_state(),
		.o_dbg_wr_cnt(),
		.o_dbg_rd_cnt()
	);

	//---------------------------------------------------------- 主机模型
	task i2c_start;
		begin
			sda_m <= 1'b1; scl_m <= 1'b1;
			repeat (T) @(posedge clk);
			sda_m <= 1'b0;                       // SCL 高时 SDA 下降
			repeat (T) @(posedge clk);
			scl_m <= 1'b0;
			repeat (T) @(posedge clk);
		end
	endtask

	task i2c_stop;
		begin
			sda_m <= 1'b0; scl_m <= 1'b0;
			repeat (T) @(posedge clk);
			scl_m <= 1'b1;
			repeat (T) @(posedge clk);
			sda_m <= 1'b1;                       // SCL 高时 SDA 上升
			repeat (T) @(posedge clk);
		end
	endtask

	// 发一个字节, 收回 ACK (1 = 从机应答)
	task i2c_wr_byte;
		input  [7:0] d;
		output       ack;
		integer k;
		begin
			for (k = 7; k >= 0; k = k - 1) begin
				sda_m <= d[k];
				repeat (T) @(posedge clk);
				scl_m <= 1'b1;
				repeat (T) @(posedge clk);
				scl_m <= 1'b0;
				repeat (T) @(posedge clk);
			end
			sda_m <= 1'b1;                       // 释放: 让从机拉低 ACK
			repeat (T) @(posedge clk);
			scl_m <= 1'b1;
			repeat (T) @(posedge clk);
			ack = ~sda;                          // SCL 高时采样
			scl_m <= 1'b0;
			repeat (T) @(posedge clk);
		end
	endtask

	// 读一个字节, 然后发 ACK(0) 或 NACK(1)
	task i2c_rd_byte;
		output [7:0] d;
		input        nack;
		integer k;
		begin
			sda_m <= 1'b1;
			for (k = 7; k >= 0; k = k - 1) begin
				scl_m <= 1'b1;
				repeat (T) @(posedge clk);
				d[k] = sda;
				scl_m <= 1'b0;
				repeat (T) @(posedge clk);
			end
			sda_m <= nack ? 1'b1 : 1'b0;
			repeat (T) @(posedge clk);
			scl_m <= 1'b1;
			repeat (T) @(posedge clk);
			scl_m <= 1'b0;
			repeat (T) @(posedge clk);
			sda_m <= 1'b1;
			// ⚠ 必须在这里再等一拍总线稳定再返回。
			//   否则下一字节循环开头的 scl_m<=1 会和这里的 sda_m<=1 被排在
			//   同一个时钟 -> 「SCL 高时 SDA 上升」= 伪 STOP, 从机直接回 IDLE。
			repeat (T) @(posedge clk);
		end
	endtask

	// 复合操作: 写单个寄存器
	task i2c_write_reg;
		input [7:0] a;
		input [7:0] d;
		reg ack1, ack2, ack3;
		begin
			i2c_start;
			i2c_wr_byte({DEV_ADDR, 1'b0}, ack1);
			i2c_wr_byte(a, ack2);
			i2c_wr_byte(d, ack3);
			i2c_stop;
			$display("  WRITE  addr=%02X data=%02X  ACK=%b%b%b", a, d, ack1, ack2, ack3);
		end
	endtask

	// 复合操作: 读单个寄存器
	task i2c_read_reg;
		input  [7:0] a;
		output [7:0] d;
		reg ack1, ack2, ack3;
		begin
			i2c_start;
			i2c_wr_byte({DEV_ADDR, 1'b0}, ack1);
			i2c_wr_byte(a, ack2);
			i2c_stop;
			i2c_start;                            // 重复起始
			i2c_wr_byte({DEV_ADDR, 1'b1}, ack3);
			i2c_rd_byte(d, 1'b1);                 // 最后一个字节给 NACK
			i2c_stop;
		end
	endtask

	//---------------------------------------------------------- 调试追踪
	reg [2:0] st_d = 3'd0;
	reg       trace_rd = 1'b0;      // 只对读方向开详细追踪
	always @(posedge clk) begin
		if (rst_n) begin
			if (u_dut.st !== st_d) begin
				$display("   [t=%0t] st %0d -> %0d (bc=%0d ack_ok=%b nxt=%0d)",
				         $time, st_d, u_dut.st, u_dut.bc, u_dut.ack_ok, u_dut.nxt);
				st_d <= u_dut.st;
			end
			if (u_dut.start_cond) trace_rd <= 1'b0;
			if (u_dut.st == 3'd1 && u_dut.bc == 4'd7 && u_dut.rw_bit)
				trace_rd <= 1'b1;                 // 识别到读地址 -> 开始详追
			if (u_dut.start_cond)
				$display("   [t=%0t] *** START *** st=%0d scl=%b sda=%b scl_d1=%b sda_d1=%b drv=%b",
				         $time, u_dut.st, scl, sda, u_dut.scl_d1, u_dut.sda_d1, u_dut.sda_drive);
			if (u_dut.stop_cond)
				$display("   [t=%0t] *** STOP  *** st=%0d scl=%b sda=%b scl_d1=%b sda_d1=%b sda_d2=%b drv=%b",
				         $time, u_dut.st, scl, sda, u_dut.scl_d1, u_dut.sda_d1, u_dut.sda_d2, u_dut.sda_drive);
			if (trace_rd && u_dut.scl_fall)
				$display("     f: st=%0d bitpos=%0d tx=%02X drv=%b sda=%b addr=%02X rd=%02X",
				         u_dut.st, u_dut.bitpos, u_dut.tx_byte, u_dut.sda_drive,
				         sda, u_dut.cur_addr, rd_r);
		end
	end

	//---------------------------------------------------------- 主流程
	integer pass_cnt = 0, fail_cnt = 0;
	reg [7:0] v;
	reg       ack_probe;

	task check;
		input [7:0] got;
		input [7:0] exp;
		input [127:0] name;
		begin
			if (got === exp) begin
				pass_cnt = pass_cnt + 1;
				$display("  OK   %0s = %02X", name, got);
			end else begin
				fail_cnt = fail_cnt + 1;
				$display("  FAIL %0s 实测 %02X 期望 %02X", name, got, exp);
			end
		end
	endtask

	initial begin
		rst_n = 1'b0;
		repeat (10) @(posedge clk);
		rst_n = 1'b1;
		repeat (10) @(posedge clk);

		$display("=========== I2C 从机仿真 (设备地址 7'h%02X) ===========", DEV_ADDR);

		$display("[1] 单寄存器写 -> 内部寄存器堆");
		i2c_write_reg(8'hB1, 8'h03);
		i2c_write_reg(8'hB3, 8'h4D);
		repeat (20) @(posedge clk);
		check(regs[8'hB1], 8'h03, "regs[B1]");
		check(regs[8'hB3], 8'h4D, "regs[B3]");

		$display("[2] 单寄存器读回");
		i2c_read_reg(8'hB1, v);  check(v, 8'h03, "read B1");
		i2c_read_reg(8'hB3, v);  check(v, 8'h4D, "read B3");

		$display("[3] 突发写: 从 0x10 起连写 4 个字节");
		i2c_start;
		i2c_wr_byte({DEV_ADDR, 1'b0}, v[0]);
		i2c_wr_byte(8'h10, v[0]);
		i2c_wr_byte(8'hAA, v[0]);
		i2c_wr_byte(8'hBB, v[0]);
		i2c_wr_byte(8'hCC, v[0]);
		i2c_wr_byte(8'hDD, v[0]);
		i2c_stop;
		repeat (20) @(posedge clk);
		check(regs[8'h10], 8'hAA, "regs[10]");
		check(regs[8'h11], 8'hBB, "regs[11]");
		check(regs[8'h12], 8'hCC, "regs[12]");
		check(regs[8'h13], 8'hDD, "regs[13]");

		$display("[4] 突发读: 从 0x10 连读 4 个字节 (指针自增)");
		i2c_start;
		i2c_wr_byte({DEV_ADDR, 1'b0}, v[0]);
		i2c_wr_byte(8'h10, v[0]);
		i2c_stop;
		i2c_start;
		i2c_wr_byte({DEV_ADDR, 1'b1}, v[0]);
		i2c_rd_byte(v, 1'b0);  check(v, 8'hAA, "burst[0]");
		i2c_rd_byte(v, 1'b0);  check(v, 8'hBB, "burst[1]");
		i2c_rd_byte(v, 1'b0);  check(v, 8'hCC, "burst[2]");
		i2c_rd_byte(v, 1'b1);  check(v, 8'hDD, "burst[3]");
		i2c_stop;

		$display("[5] 地址不匹配 -> 必须不应答");
		i2c_start;
		i2c_wr_byte(8'h55, ack_probe);     // 0x55>>1 = 0x2A, 不是本机地址
		check({7'b0, ack_probe}, 8'h00, "addr 0x2A 不应答(ack=0)");
		i2c_stop;
		repeat (20) @(posedge clk);
		check(regs[8'h10], 8'hAA, "误写没有污染 regs[10]");

		$display("=====================================================");
		$display(" 通过 %0d, 失败 %0d", pass_cnt, fail_cnt);
		$display(" %s", (fail_cnt == 0) ? "**全部通过**" : "**有失败项**");
		$display("=====================================================");
		$finish;
	end

endmodule
