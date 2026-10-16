
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/08/07
*Module Name:key
*File Name:key.v
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*********ui_cfg_imx415 IIC控制模块 ***********
--版本号1.0
*********************************************************************/

module ui_cfg_imx415#
(
parameter	 CLK_DIV  = 16'd999
)
(
input  wire             I_clk,  //系统时钟输入
input  wire             I_rst_n,  //系统复位输入
input  wire             I_ae_req,//摄像头参数下发请求 (一拍脉冲)
// V24: 传感器读出模式 —— 0=1080p(2x2 binning), 1=4K(all-pixel), 2=720p。
//   直接透给下面的 ui_imx415reg, 让它选对应的寄存器表。
//   ⚠ 切模式必须配 I_full_reload, 否则新表不会被写下去 (> 见下面的重载分支)。
input  wire [1:0]       I_cam_mode,
// V24: 请求把整张初始化表重写一遍 (分辨率切换时用)
input  wire             I_full_reload,
input  wire	 [7:0] 		I_ae_data,//4 个增益通道的值
input  wire [19:0]      I_rt_exp,//SHR0 曝光行数 (20 bit)
output wire             O_cam_scl, //I2C总线，SCL时钟
inout  wire             IO_cam_sda, //I2C总线，SDA数据
output reg              O_cfg_done, //配置完成
output reg              O_ae_cfg_done
);	

localparam CAM_ID = 8'h34;		//器件地址 

wire 		ic_busy			; 	//I2C控制器忙信号 
wire   		O_iic_bus_error	;

wire [23:0] REG_DATA_REG	; 	//寄存器数据
wire [7 :0] REG_SIZE_REG	;	//寄存器数量

wire [1 :0] REG_SIZE_ST = 2'd2; //待机寄存器数量
wire [2 :0] REG_SIZE_AE = 3'd7; //参数寄存器数量: 4 个增益通道 + 3 字节 SHR0 曝光


reg  		O_cfg_done_r;	//待机模式寄存器配置完成信号
reg  		iic_req		;	//请求操作I2C控制器信号
reg  [7:0] 	rst_cnt		;	//复位延时计数
reg  [21:0] cnt			;	//待机模式寄存器延时配置计数

reg  [31:0] wr_data		;   //写数据寄存器

reg  [7 :0] reg_index	;   //寄存索引            
                                             
reg [23:0] 	REG_DATA;    	//寄存器数据
reg [7:0]  	REG_SIZE;    	//寄存器数量

reg [23:0] 	REG_DATA_ST;  	//待机寄存器数据
reg [23:0] 	REG_DATA_AE;  	//AE寄存器数据

reg  [1 :0] TS_S = 2'd0; 	//状态机寄存器



//=============================================================================
//  参数下发请求锁存 (★★ 修复 2026-10-16)
//-----------------------------------------------------------------------------
//  I_ae_req 从 25MHz 域展宽、同步过来之后是 24MHz 域的**单拍脉冲**; 而主表状态机
//  的 TS_S==0 每次寄存器写入(24MHz 下 ~9240 周期)只占 1 拍 => 直接拿它做条件
//  的话命中率约 1/9240, 请求基本全丢。丢了的后果: O_ae_cfg_done 不再翻转,
//  cam_param 永远等不到 ae_done -> 卡在 busy -> 网页改曝光/增益"没反应"。
//  这里先锁存住, 等状态机回到 TS_S==0 再消费。
//  置位优先, 保证"同一拍里既消费又来了新请求"时不丢;
//  只在复位结束后消费, 以免上电时那条早期请求把主初始化表打断。
//=============================================================================
reg ae_req_lat = 1'b0;

always@(posedge I_clk) begin
    if(I_ae_req)
        ae_req_lat <= 1'b1;
    else if(ae_req_lat && TS_S == 2'd0 && O_cfg_done_r && rst_cnt[7] == 1'b1)
        ae_req_lat <= 1'b0;      // 已被上面的快通道消费
end

//=============================================================================
//  V24: 全表重载请求锁存 (分辨率切换)
//-----------------------------------------------------------------------------
//  传感器切 1080p(2x2 binning) <-> 4K(all-pixel) 要改的不是几个寄存器, 而是
//  0x3020/21/22(HADD/VADD/ADDMODE)、0x3024/25(VMAX)、0x3028(HMAX)、
//  0x3033(SYS_MODE) 以及 0x4004..0x4074 那一整套 MIPI D-PHY 发送时序
//  (lane 速率会变)。这些寄存器**只在主表相位(O_cfg_done==0)才会被写入**,
//  所以必须让状态机回到主表重跑一遍 (201 个寄存器 ≈ 78ms)。
//
//  ⚠ 重载期间 I_cam_mode 必须已经稳定 —— 由 system_top 保证:
//    它把 S_res_chg 延后 ~32 拍再发这个脉冲, 让同步到 24MHz 域的 mode 先稳住。
//=============================================================================
reg full_reload_lat = 1'b0;

always@(posedge I_clk) begin
    if(I_full_reload)
        full_reload_lat <= 1'b1;
    else if(full_reload_lat && TS_S == 2'd0 && rst_cnt[7] == 1'b1)
        full_reload_lat <= 1'b0;      // 已被主表相位消费
end

//内部计数器产生一个延迟复位
always@(posedge I_clk or negedge I_rst_n)  
    if(I_rst_n == 1'b0) //复位初始化寄存器
        rst_cnt<= 8'd0; 
    else if(rst_cnt[7] == 1'b0)
       rst_cnt <= rst_cnt + 1'b1; 
    else 
       rst_cnt <= rst_cnt; 
	   
always@(posedge I_clk or negedge I_rst_n)  begin
    if(I_rst_n == 1'b0) //复位初始化寄存器
         cnt <= 0;
    else if(cnt == 1000_000)
         cnt <= 0;
    else if(O_cfg_done == 1'b1)
         cnt <= cnt + 1;
    else if(O_cfg_done_r == 1'b1)
         cnt <= cnt;
end

always@(posedge I_clk or negedge I_rst_n)begin
    if(I_rst_n == 1'b0)begin
		REG_SIZE <= 8'b0;
		REG_DATA <= 24'b0;
	end
	else if(O_cfg_done == 1'b0)begin
		REG_SIZE <= REG_SIZE_REG;
		REG_DATA <= REG_DATA_REG;
	end
	else if(O_cfg_done == 1'b1 && O_cfg_done_r == 1'b0)begin
		REG_SIZE <= REG_SIZE_ST;
		REG_DATA <= REG_DATA_ST;
	end
	else if(O_cfg_done == 1'b1 && O_cfg_done_r == 1'b1)begin
		REG_SIZE <= REG_SIZE_AE;
		REG_DATA <= REG_DATA_AE;
	end
	else begin
		REG_SIZE <= 8'b0;
		REG_DATA <= 24'b0;
	end
end

always@(posedge I_clk ) begin 
    if(rst_cnt[7] == 1'b0)begin //复位初始化寄存器
        reg_index  <= 9'd0;
        iic_req    <= 1'b0;
        wr_data    <= 32'd0;
        O_cfg_done <= 1'b0;
        O_cfg_done_r <= 1'b0;
        O_ae_cfg_done <= 1'b1;
        TS_S     <= 2'd0;    
    end
    else begin
        case(TS_S)
        0:if(full_reload_lat)begin
            // ★★ V24: 分辨率切换 —— 强制回到主表相位, 整张初始化表重写一遍。
            //   注意: 这里**绝对不能**顺手推 TS_S !! REG_SIZE/REG_DATA 是上面
            //   always@(posedge) 里的**寄存器**, 要下一拍才切回 REG_DATA_REG。
            //   推早了第一笔会写成上一张表的旧值(增益那次就是这么被搞坏的)。
            //   让下面那句 (O_cfg_done&O_cfg_done_r&O_ae_cfg_done)==0 自然跳转。
            O_cfg_done    <= 1'b0;   // 回主表相位
            O_cfg_done_r  <= 1'b0;
            O_ae_cfg_done <= 1'b0;   // 允许状态机继续走
            reg_index     <= 8'd0;
        end
        else if(ae_req_lat && O_cfg_done_r)begin
            // ★★ 修复(2026-10-16): 参数下发路径原来有**三处**结构性问题 ——
            //   1) I_ae_req 是 24MHz 域的单拍脉冲, 而 TS_S==0 每次寄存器写入
            //      (~385us) 只占 1 拍, 命中率约 1/9240 => 请求几乎必然被整拍漏掉。
            //      改为上面 ae_req_lat 锁存, 保证不丢。
            //   2) 若请求正好落在主表相位 (O_cfg_done==0) 被接住, 会从 reg_index=0
            //      重跑 201 个主表寄存器(一轮 ~80ms); 更糟的是 O_cfg_done_r 在
            //      reg_index==REG_SIZE_ST(=2) 那拍才置位, 而当时 REG_DATA 还是待机
            //      表 => 真正写进去的只有 reg_index 2..6 这 5 个 => 0x3090/0x3092/
            //      0x3094 **从来没有被写过** (增益只上了一部分, 表现为增益很弱)。
            //   3) 除请求外没有别的通道能更新参数, 漏一次就"像没反应"。
            //
            //   现在: 直接把相位强制切到参数表 (O_cfg_done/O_cfg_done_r 都置 1
            //   => REG_SIZE 选 REG_SIZE_AE, REG_DATA 选 REG_DATA_AE), 从 reg_index=0
            //   开始只写 7 个参数寄存器, 一轮 ~2.7ms; 写完在 reg_index==REG_SIZE
            //   那一支拉高 O_ae_cfg_done, 给 cam_param 一个干净的完成沿。
            //   门控 O_cfg_done_r: 保证上电时先完整跑完一遍主初始化表,
            //   否则一上电就被参数请求打断, 传感器根本初始化不起来。
            O_ae_cfg_done <= 1'b0;   // 本轮开始
            O_cfg_done    <= 1'b1;   // 强制进参数相位
            O_cfg_done_r  <= 1'b1;   // (REG_SIZE/REG_DATA 选择器跟着切)
            reg_index     <= 8'd0;
            // ⚠⚠ 这里**千万不能**顺手写一句 TS_S <= 2'd1 !!
            //   REG_SIZE / REG_DATA 是上面 always@(posedge) 块里的**寄存器**(不是
            //   组合逻辑), 它们要**下一拍**才变成参数表的值。如果在这一拍就把
            //   TS_S 推到 1, 下一拍 TS_S==1 采到的还是**上一拍的 REG_DATA** =>
            //   reg_index==0 那一笔 (0x3090 = GAIN_PGC_0) 会被写成一笔重复的旧值,
            //   于是 reg_index 从 1 开始, 0x3090 永远写不到。
            //   实测(2026-10-16): 曝光/EV 都正常(index 4/5/6 没错位), 只有增益
            //   **完全没有反应**(0/18/36dB 亮度都是 41.1, 差 0.0) —— 就是这个原因。
            //   正确做法: 让状态机下一拍由下面那句
            //     else if((O_cfg_done&O_cfg_done_r&O_ae_cfg_done) == 1'b0) TS_S <= 2'd1;
            //   自然跳转, 那时 REG_DATA 已经就位(且总线必空闲)。
        end
        else if(reg_index == REG_SIZE && O_cfg_done == 1'b0) begin//如果配置完成
            O_cfg_done <= 1'b1;       //设置 cfg_done标准
        end 
        else if(reg_index == REG_SIZE && O_cfg_done == 1'b1 && O_cfg_done_r == 1'b0) begin//如果配置完成
            O_cfg_done_r <= 1'b1;       //设置 cfg_done标准
        end 
        else if(cnt== 1000_000 && O_ae_cfg_done == 1'b1)begin
            // 周期刷新要等一轮 AE 写完 —— 否则会把正在进行的 AE 序列打断,
            // reg_index 被清零后发起方(cam_param)再也等不到 ae_done。
            O_cfg_done_r <= 0;
            reg_index   <= 0;
        end
		else if(reg_index == REG_SIZE && O_cfg_done == 1'b1 && O_cfg_done_r == 1'b1) begin//如果配置完成
            O_ae_cfg_done <= 1'b1;       //设置 cfg_done标准
        end 
        else if((O_cfg_done&O_cfg_done_r&O_ae_cfg_done) == 1'b0)
            TS_S <= 2'd1;           //下一个状态
        1:if(!iic_busy)begin        //当总线非忙，才可以操作I2C控制器
            iic_req  <= 1'b1;       //请求操作I2C控制器
			wr_data[7  :0] <= CAM_ID;           //器件地址   
			wr_data[15 :8] <= REG_DATA[23:16];  //寄存器地址-高8bit    
			wr_data[23:16] <= REG_DATA[15: 8];  //寄存器地址-低8bit  
            wr_data[31:24] <= REG_DATA[7 : 0];  //寄存器数据
            TS_S      <= 2'd2; //下一个状态
        end    
        2:if(iic_busy)begin
             iic_req  <= 1'b0;  //重置 iic_req =0
             TS_S     <= 2'd3;  //下一个状态
        end
        3:if(!iic_busy)begin  //当总线非忙，才可以操作I2C控制器 
			reg_index<= reg_index + 1'b1;//寄存器索引加1
			TS_S    <= 2'd0;//回到初始状态
        end 
        endcase
   end
end

//例化I2C控制模块
ui_i2c#
(
	.WMEN_LEN	(4		),     //最大支持一次写入4BYTE(包含器件地址)
	.RMEN_LEN	(1		),     //最大支持一次读出1BYTE
	.CLK_DIV	(CLK_DIV) 	   //100KHZ I2C总线时钟
)
X_ui_i2c
(
	.I_clk			(I_clk			),//系统时钟
	.I_rstn			(rst_cnt[7]		),//系统复位
	.O_iic_scl		(O_cam_scl		),//I2C SCL总线时钟
	.IO_iic_sda		(IO_cam_sda		),//I2C SDA数据总线
	.I_wr_data		(wr_data		),//写数据寄存器
	.I_wr_cnt		(8'd4			),//需要写的数据BYTES
	.O_rd_data		(				),//读数据寄存器
	.I_rd_cnt		(8'd0			),//需要读的数据BYTES
	.I_iic_mode		(1'b0			),//读模式设置
	.I_iic_req		(iic_req		),//I2C控制器请求
	.O_iic_busy		(iic_busy		),//I2C控制器忙
	.O_iic_bus_error(O_iic_bus_error)
);


//例化CAM的寄存器配置表
ui_imx415reg X_ui_imx415reg
(
	.MODE		(I_cam_mode		),  // V24: 读出模式选表 (0=1080p binning 1=4K all-pixel)
	.REG_SIZE	(REG_SIZE_REG	),  //寄存器数量
	.REG_INDEX	(reg_index		),    //寄存索引
	.REG_DATA	(REG_DATA_REG	)   //寄存器数据
);  

always@(*)
   case(reg_index)
//      ★★ V25: 待机表在主表**之后**执行, 所以这里要写的是“放运行”。
//        配合 ui_imx415_reg.v 主表开头把 0x3000/0x3002 写 0(待机),
//        整条链就是正确的 待机 -> 改模式寄存器 -> 运行 顺序。
//        (原来这里写的是 0x00/0x00 “挂待机”, 于是全链以“待机”结尾, 顺序反了。)
		0:		REG_DATA_ST = {16'h3000, 8'h00};   // V27: 0=Operating (启动) 
		1:		REG_DATA_ST = {16'h3002, 8'h00};   // V27: 0=Master operation start 
		default:REG_DATA_ST = {16'h0000, 8'h00};
   endcase

always@(*)
   case(reg_index)
		0:		REG_DATA_AE = {16'h3090, I_ae_data}; 
		1:		REG_DATA_AE = {16'h3092, I_ae_data}; 
		2:		REG_DATA_AE = {16'h3094, I_ae_data}; 
		3:		REG_DATA_AE = {16'h3096, I_ae_data}; 
		4:		REG_DATA_AE = {16'h3050, I_rt_exp[ 7:0]}; 
		5:		REG_DATA_AE = {16'h3051, I_rt_exp[15:8]}; 
		6:		REG_DATA_AE = {16'h3052, I_rt_exp[19:16]}; 
		default:REG_DATA_AE = {16'h0000, 8'h00};
   endcase

endmodule
