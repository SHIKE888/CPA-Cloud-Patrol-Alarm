
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
    input    [12:0]                    	I_img_height		,   // V21: 运行时图像高度

    input    [DATA_WIDTH - 1:0]       	I_raw_data			,       
    input                             	I_raw_valid 		,     
    input                             	I_raw_frame_start	,
    input                             	I_raw_frame_end  	,
    // 输出RAW10数据	
    output     [DATA_WIDTH - 1:0]     	O_raw_tdata 		,
    output                            	O_raw_tlast 		,
    output reg [TDEST_WIDTH - 1:0]    	O_raw_tdest 		,
    output                            	O_raw_tvalid		,
    output                            	O_raw_tuser 		,
    input                             	O_raw_tready
);

    reg                        I_raw_tvalid_d; 
    reg    [DATA_WIDTH - 1:0]  I_raw_tdata_r;
    reg    [14:0]              h_cnt,v_cnt;
    wire                       V_valid,H_valid;
    wire                       tuser;
	
// V21: 运行时宽高 (4 像素/时钟)
    wire [14:0] img_width_4x  = (I_img_width >> 2);
    wire [14:0] img_height_rt = I_img_height;

    assign H_valid 		= (h_cnt <= img_width_4x) && (h_cnt > 0);
    
    assign tuser 		= (h_cnt == 1) && (v_cnt == 1) && I_raw_tvalid_d;
    
    assign O_raw_tdata  = V_valid && H_valid? I_raw_tdata_r:0;
    assign I_raw_tready = O_raw_tready;
    assign O_raw_tvalid = H_valid && V_valid && I_raw_tvalid_d;
    assign O_raw_tlast  = V_valid && (h_cnt == img_width_4x) && I_raw_tvalid_d;
    assign O_raw_tuser  = tuser;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n )begin
            I_raw_tvalid_d <= 0;
            I_raw_tdata_r  <= 0;
        end
        else begin
            I_raw_tvalid_d <= I_raw_valid;
            I_raw_tdata_r  <= I_raw_data;
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

    wire last = (cnt == 10);
    // 计算行数
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_raw_frame_start)
            v_cnt <= 0;
        else if(last)
            v_cnt  <=  v_cnt + 1;
    end

    assign V_valid = (v_cnt > 0) && (v_cnt <= img_height_rt);

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
endmodule