
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/03/23
*Module Name:
*File Name:
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
/*********ui_image_correction 消减图像的多余的***********
--版本号1.0  
*****************************************************************/

module ui_image_correction #(
    parameter DATA_WIDTH   = 40,
    parameter TDEST_WIDTH  = 10
)(
    input                          		I_clk   			,
    input                          		I_rst_n 			,
    input    [12:0]                    	I_img_width 		,   // V21: 运行时图像宽度
    input    [12:0]                     I_img_height		,   // V21: 运行时图像高度
    // V39: 垂直起始裁剪(要跳过的原始行数)。IMX415 4K 录制区从第 36 行开始
    //      (v_start=35)，1080p 厂商参考 v_start=19。缺这个参数会把顶部
    //      OB/EBD 当图像，并把最后 35/19 行有效像素切掉；Bayer 相位也会错。
    input    [12:0]                    	I_v_start  		,
    input    [DATA_WIDTH - 1:0]       	I_raw_data			,       
    input                             	I_raw_valid 		,     
    input                             	I_raw_frame_start	,
    input                             	I_raw_frame_end  	,    // 2026-10-21 新增: 来自 RX 的**真实行尾**。
    //   原来这里用“I_raw_valid 为低连续 10 拍”(cnt==10) 来分行,
    //   但换成 LP-free RX (mipi_csi_rx) 后, 行间只有 byte_align 找同步字的
    //   8~9 拍空隙, 刚好到不了 10 -> last 时有时无 -> h_cnt 跨行累加
    //   (0xD4/D5 从 486 涨到 738) -> v_cnt 少计 -> 画面行重复(鬼影)。
    input                              	I_raw_tlast     	,    // V21 诊断: 一行最后一个像素组编号 (用 0xD4/0xD5 回读)
    //   用来判断传感器每行实际输出多少组: 全像素 3864 宽 => ~966 组;
    //   2x2 相加(合并)到 ~1932 宽 => ~483 组。
    output reg [15:0]                 	O_line_groups      	,
    // 输出RAW10数据	
    output     [DATA_WIDTH - 1:0]     	O_raw_tdata 		,
    output                            	O_raw_tlast 		,
    output reg [TDEST_WIDTH - 1:0]    	O_raw_tdest 		,
    output                            	O_raw_tvalid		,
    output                            	O_raw_tuser 		,
    input                             	O_raw_tready
);

    reg                        I_raw_tvalid_d; 
    reg                        I_raw_tlast_d;
    reg    [DATA_WIDTH - 1:0]  I_raw_tdata_r;
    reg    [14:0]              h_cnt,v_cnt;
    wire                       V_valid,H_valid;
    wire                       tuser;
	
// V21: 运行时宽高 (4 像素/时钟)
    wire [14:0] img_width_4x  = (I_img_width >> 2);
    wire [14:0] img_height_rt = I_img_height;
    // V39: 垂直裁剪窗口 = (v_start, v_start + height]
    wire [14:0] v_start_rt    = {2'b00, I_v_start};
    wire [14:0] v_end_rt      = v_start_rt + img_height_rt;

    assign H_valid 		= (h_cnt <= img_width_4x) && (h_cnt > 0);
    
    // tuser 必须落在第一个有效行 (v_start+1)，否则 ISP/AWB/去马赛克的
    // 行计数与 Bayer 相位仍会从 OB/EBD 行开始。
    assign tuser 		= (h_cnt == 1) && (v_cnt == v_start_rt + 15'd1) && I_raw_tvalid_d;
    
    assign O_raw_tdata  = V_valid && H_valid? I_raw_tdata_r:0;
    assign I_raw_tready = O_raw_tready;
    assign O_raw_tvalid = H_valid && V_valid && I_raw_tvalid_d;
    assign O_raw_tlast  = V_valid && (h_cnt == img_width_4x) && I_raw_tvalid_d;
    assign O_raw_tuser  = tuser;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n )begin
            I_raw_tvalid_d <= 0;
            I_raw_tdata_r  <= 0;
            I_raw_tlast_d  <= 0;
        end
        else begin
            I_raw_tvalid_d <= I_raw_valid;
            I_raw_tdata_r  <= I_raw_data;
            I_raw_tlast_d  <= I_raw_tlast;   // 与 I_raw_tvalid_d 对齐
        end
    end
    
    reg  [16:0] cnt;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n )begin
            cnt <= 0;
        end
        else if(I_raw_valid)
            cnt <= 0;
        else if(!I_raw_valid)begin
            cnt <= cnt + 1;
        end
    end

    wire last = I_raw_tlast_d;   // 2026-10-21: 改用真实行尾 (原为 cnt == 10)
    // 计算行数
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_raw_frame_start)
            v_cnt <= 0;
        else if(last)
            v_cnt  <=  v_cnt + 1;
    end

    assign V_valid = (v_cnt > v_start_rt) && (v_cnt <= v_end_rt);

    // 计算每行像素个数
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_raw_frame_start) 
            h_cnt <= 0;
        else if(last)
            h_cnt <= 0;
        else if(I_raw_tvalid_d)
            h_cnt <=  h_cnt + 1;
    end


//    cwc2 cwc2_inst
//  (
//  .probe0  (v_cnt       ),
//  .probe1  (h_cnt      ),
//  .probe2  (tuser  ),
//  .probe3  (cnt    ),
//  .probe4  (O_raw_tlast        ),
//  .probe5  (O_raw_tvalid         ),
//  .probe6  (O_raw_tdata ),
//  .clk(I_clk)
//  );
    //--------------------------------------------------------------------------
    // V21 诊断: 锁存一行的像素组数
    //   本模块按 4 像素/组计数, 行内的组间隔(cnt==10)产生 last, 此刻 h_cnt 即该行
    //   最后一个组的编号 = 该行组数。注意下游只能看到 h_cnt<=480 的组(被本模块裁掉),
    //   所以在下游量不到真实行宽, 必须在这里量。
    //--------------------------------------------------------------------------
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n)      O_line_groups <= 16'd0;
        else if (last)     O_line_groups <= h_cnt;
    end

endmodule