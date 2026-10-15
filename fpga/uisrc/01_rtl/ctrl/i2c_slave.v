//=============================================================================
//  i2c_slave.v
//  I2C 从机 (7 位地址, 默认 0x40) —— 反向传参链路
//
//  为什么必须走 I2C
//  ----------------
//  本板 FPGA 侧唯一来自 RK 的信号是 I_dsi_en (L13), 但它被内核驱动
//  (milianke_mipi.c) 用 devm_gpiod_get_optional("mipi-en") 独占, 且
//  always_on 默认为真 —— **用户态拿不到**, 没法拿来 bit-bang。
//  所以只能按竞赛方案: RK I2C9 -> 飞线到 FMC_HPC_IIC (FPGA P14/P15),
//  FPGA 侧实现 I2C 从机。
//
//  寄存器访问协议 (标准 "子地址" 式, 与 Linux i2c_smbus / i2ctransfer 一致):
//      写:  START | ADDR+W | SUB | DATA0 | DATA1 | ... | STOP
//           子地址之后的每个字节依次写入 SUB, SUB+1, SUB+2 ...
//      读:  START | ADDR+W | SUB | STOP          (先设定寄存器指针)
//           START | ADDR+R | DATA0 | DATA1 | ... | NACK | STOP
//           每读一个字节指针自动 +1
//
//  实现要点
//  --------
//  · 纯过采样: 用系统时钟(几十 MHz) 同步 SCL/SDA 并检测边沿。SCL 只有
//    100k/400kHz, 采样率绰绰有余, 不需要时钟拉伸。
//  · 开漏输出: sda_drive = 1 表示把 SDA 拉低, 0 表示释放(靠外部上拉)。
//  · 采样点 = SCL 上升沿; 从机改变数据在 SCL 下降沿 (标准 I2C 时序)。
//=============================================================================
`timescale 1ns / 1ps

module i2c_slave #(
	parameter [6:0] DEV_ADDR = 7'h40
)(
	input  wire       clk,
	input  wire       rst_n,

	// ---- I2C 引脚 (三态由顶层处理) ----
	input  wire       scl_i,
	input  wire       sda_i,
	output reg        sda_drive,     // 1 = 拉低 SDA, 0 = 释放

	// ---- 寄存器写口 ----
	output reg        o_wr_en,
	output reg [7:0]  o_wr_addr,
	output reg [7:0]  o_wr_data,

	// ---- 寄存器读口 (i_rd_data 在 o_rd_addr 之后 1 拍给出) ----
	output reg [7:0]  o_rd_addr,
	input  wire [7:0] i_rd_data,

	// ---- 调试 ----
	output reg [7:0]  o_dbg_state,
	output reg [15:0] o_dbg_wr_cnt,
	output reg [15:0] o_dbg_rd_cnt
);

	//-------------------------------------------------------------------------
	// 输入同步 + 边沿检测
	//-------------------------------------------------------------------------
	reg scl_d0, scl_d1, scl_d2;
	reg sda_d0, sda_d1, sda_d2;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			scl_d0 <= 1'b1; scl_d1 <= 1'b1; scl_d2 <= 1'b1;
			sda_d0 <= 1'b1; sda_d1 <= 1'b1; sda_d2 <= 1'b1;
		end else begin
			scl_d0 <= scl_i; scl_d1 <= scl_d0; scl_d2 <= scl_d1;
			sda_d0 <= sda_i; sda_d1 <= sda_d0; sda_d2 <= sda_d1;
		end
	end

	wire scl_rise = (~scl_d2) & scl_d1;      // 采样点
	wire scl_fall = scl_d2 & (~scl_d1);      // 从机改变数据的时刻
	wire sda_fall = sda_d2 & (~sda_d1);
	wire sda_rise = (~sda_d2) & sda_d1;

	// START: SCL 为高时 SDA 下降 ; STOP: SCL 为高时 SDA 上升
	// 注意: scl_d1 与 sda_d1 都是延迟 2 拍, 二者时间对齐
	wire start_cond = sda_fall & scl_d1;
	wire stop_cond  = sda_rise & scl_d1;

	//-------------------------------------------------------------------------
	// 状态机
	//
	// ⚠ ACK 时序 (这里踩过坑, 很重要)
	//   ACK 是第 **9** 个 SCL 时钟, 不是第 8 个。第 8 位采完(上升沿)之后:
	//     第8个下降沿 -> 从机把 SDA 拉低 (开始驱动 ACK)
	//     第9个上升沿 -> 主机采样, 看到低电平 = ACK
	//     第9个下降沿 -> 从机释放 SDA, 进入下一字节
	//   最初写成「第8个上升沿拉低、第8个下降沿释放」——ACK 早了一个时钟,
	//   主机在第9个上升沿看到已经释放的高电平, 于是全部判为 NACK
	//   (现象: 所有读写 ACK=000, 寄存器完全没写进去)。
	//   所以用 S_ACK1(驱动) / S_ACK2(释放) 两个状态覆盖完整的第 9 个时钟。
	//-------------------------------------------------------------------------
	localparam [2:0] S_IDLE = 3'd0,
	                 S_ADDR = 3'd1,   // 收 8 位设备地址
	                 S_ACK1 = 3'd2,   // 第8个下降沿: 拉低 SDA
	                 S_ACK2 = 3'd3,   // 第9个下降沿: 释放 SDA, 跳到 nxt
	                 S_SUB  = 3'd4,   // 收子地址
	                 S_DW   = 3'd5,   // 收数据字节
	                 S_DR   = 3'd6,   // 发数据字节
	                 S_MACK = 3'd7;   // 收主机的 ACK/NACK

	reg [2:0]  st, nxt;
	reg        ack_ok;      // 本次 ACK 是否真的拉低
	reg        dr7;         // 本字节的 bit7 是否已送出
	reg [3:0]  bc;          // 位计数 0..7
	reg [2:0]  bitpos;      // 读方向已发出的位数
	reg [7:0]  shreg;       // 移位寄存器 (收)
	reg [7:0]  tx_byte;     // 待发字节
	reg [7:0]  cur_addr;    // 当前寄存器指针
	reg        rw;          // 本次传输方向 1=读
	reg        addr_hit;

	wire [7:0] sh_next = {shreg[6:0], sda_d1};
	wire [7:0] addr_r  = sh_next[7:1];
	wire       rw_bit  = sh_next[0];
	wire [2:0] nidx    = 3'd6 - bitpos;      // 下一位在 tx_byte 中的位置

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st <= S_IDLE; nxt <= S_IDLE; ack_ok <= 1'b0; dr7 <= 1'b0;
			bc <= 4'd0; bitpos <= 3'd0;
			shreg <= 8'd0; tx_byte <= 8'd0; cur_addr <= 8'd0;
			rw <= 1'b0; addr_hit <= 1'b0;
			sda_drive <= 1'b0;
			o_wr_en <= 1'b0; o_wr_addr <= 8'd0; o_wr_data <= 8'd0;
			o_rd_addr <= 8'd0;
			o_dbg_state <= 8'd0; o_dbg_wr_cnt <= 16'd0; o_dbg_rd_cnt <= 16'd0;
		end else begin
			o_wr_en <= 1'b0;                        // 写脉冲默认低
			o_rd_addr <= cur_addr;                  // 读指针恒跟随寄存器指针
			tx_byte   <= i_rd_data;                 // 比 rd_addr 晚 1 拍
			o_dbg_state <= {5'b0, st};

			if (start_cond) begin
				st <= S_ADDR; bc <= 4'd0; sda_drive <= 1'b0;
			end else if (stop_cond) begin
				st <= S_IDLE; bc <= 4'd0; sda_drive <= 1'b0;
			end else begin
				case (st)

				//------------------------------------------- 设备地址
				S_ADDR: if (scl_rise) begin
					if (bc == 4'd7) begin
						addr_hit <= (addr_r == DEV_ADDR);
						rw       <= rw_bit;
						ack_ok   <= (addr_r == DEV_ADDR);
						nxt      <= (addr_r == DEV_ADDR)
						            ? (rw_bit ? S_DR : S_SUB)
						            : S_IDLE;
						bc       <= 4'd0;
						st       <= S_ACK1;      // 第8个上升沿 -> 去等第8个下降沿
					end else begin
						shreg <= sh_next;
						bc    <= bc + 4'd1;
					end
				end

				//------------------------------------------- ACK: 第8个下降沿拉低
				S_ACK1: if (scl_fall) begin
					sda_drive <= ack_ok;
					st        <= S_ACK2;
				end

				//------------------------------------------- ACK: 第9个下降沿释放
				S_ACK2: if (scl_fall) begin
					sda_drive <= 1'b0;
					if (nxt == S_DR) begin
						bitpos <= 3'd0;
						dr7    <= 1'b0;      // 交给 S_DR 在 tx_byte 跟上后再驱动 bit7
						st     <= S_DR;
					end else begin
						st <= nxt;
					end
				end

				//------------------------------------------- 子地址
				S_SUB: if (scl_rise) begin
					if (bc == 4'd7) begin
						cur_addr <= sh_next;
						ack_ok   <= 1'b1;
						nxt      <= S_DW;
						bc       <= 4'd0;
						st       <= S_ACK1;
					end else begin
						shreg <= sh_next;
						bc    <= bc + 4'd1;
					end
				end

				//------------------------------------------- 数据字节 (写)
				S_DW: if (scl_rise) begin
					if (bc == 4'd7) begin
						o_wr_en      <= 1'b1;
						o_wr_addr    <= cur_addr;
						o_wr_data    <= sh_next;
						cur_addr     <= cur_addr + 8'd1;
						o_dbg_wr_cnt <= o_dbg_wr_cnt + 16'd1;
						ack_ok       <= 1'b1;
						nxt          <= S_DW;       // 继续收后续字节
						bc           <= 4'd0;
						st           <= S_ACK1;
					end else begin
						shreg <= sh_next;
						bc    <= bc + 4'd1;
					end
				end

				//------------------------------------------- 数据字节 (读)
				S_DR: begin
					if (!dr7) begin
						// 本字节的 bit7。必须等 tx_byte 跟上再驱动: cur_addr 变化后
						// o_rd_addr -> i_rd_data -> tx_byte 共需 2 拍, 立即驱动会
						// 把**上一个字节**的最高位发出去。
						sda_drive <= ~tx_byte[3'd7];
						dr7       <= 1'b1;
					end
					if (scl_fall) begin
						if (bitpos == 3'd7) begin
							bitpos    <= 3'd0;
							dr7       <= 1'b0;
							sda_drive <= 1'b0;          // 8 位发完, 让主机给应答
							st        <= S_MACK;
						end else begin
							bitpos    <= bitpos + 3'd1;
							sda_drive <= ~tx_byte[nidx]; // 送出下一位
						end
					end
				end

				//------------------------------------------- 主机 ACK/NACK
				S_MACK: if (scl_fall) begin
					if (sda_d1 == 1'b0) begin          // ACK -> 继续读下一字节
						cur_addr     <= cur_addr + 8'd1;
						o_dbg_rd_cnt <= o_dbg_rd_cnt + 16'd1;
						bitpos       <= 3'd0;
						dr7          <= 1'b0;       // 让 S_DR 重新驱动新字节的 bit7
						st           <= S_DR;
					end else begin
						st <= S_IDLE;                  // NACK -> 本次读结束
					end
				end

				default: st <= S_IDLE;
				endcase
			end
		end
	end

endmodule
