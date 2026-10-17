`timescale 1ns / 1ps
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2019/12/17
*Module Name:HDMI_IN_Test
*File Name:HDMI_IN_Test.v
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

/*******************************ui_imx415reg***************************
--1.IMX415寄存器信息
*********************************************************************/

//=============================================================================
//  MODE (V24, 2026-10-16): 传感器读出模式 —— 分辨率能不能切的关键
//------------------------------------------------------------------------------
//  0 = 1080p (2x2 binning)   1 = 4K (all-pixel)   2 = 720p (binning + FPGA 裁)
//
//  ⚠ 我们原来只有 binning 那一套。binning 下传感器输出 ~1932x1092
//    => 实测 0xD4/0xD5 = 486 组 x4 = 1944 px/行。
//    而 ui_image_correction 的 tlast = (h_cnt == img_width_4x), 4K 要 960 > 486
//    => tlast 永不触发 => 一帧都出不来。
//    必须切到 all-pixel (0x3020/21/22 = 0x00) 才能拿到 ~966 组/行。
//
//  差异表来自厂商已验证 4K 的工程:
//    07_异构方案/AFC03_IMX415_PCIE_X1/.../IMX415_PCIE_X1/uisrc/03_ip/ui_imx415_cfg/ui_imx415_reg.v
//    工程目录名就叫 imx415_pcie_4k_Runs。
//  与 1080p 不同的共 27 条, 其余 175 条两模式完全相同(已逐条 diff)。
//  详见 docs/IMX415_4K_MODE.md
//
//  V27(已废弃): 曾把 4K 改成 891Mbps 档 (SYS_MODE=5, HMAX=861, VMAX=3449)
//        => 这是自己拍脑袋的组合, 厂商表里【没有任何】全像素 4K 模式用 0x05 档。
//           891Mbps 档只出现在 binning (1080p/720p) 里, 因为像素数减半。
//
//  V35(本版): 4K 完全照抄厂商已验证工程的全部差异, 不再自己拼:
//        SYS_MODE=0x08 (1440Mbps/lane), HMAX=533(0x215)
//        INCKSEL3=0xB4, INCKSEL4=0xFC, INCKSEL6=0x01, INCKSEL7=0x00
//        BCWAIT=0x54, CPWAIT=0x3B
//        0x4004/0x4018..0x4028 整组 D-PHY 发送时序换成 1440Mbps 那一套
//        ADBIT 输出保持 10bit (0x3032=0x00) -> ui_raw10_unpacket_4lane 不用改
//  帧率: 行时间 = HMAX/74.25MHz = 533/74.25MHz = 7.178us (与厂商 4K30 一致)
//        厂商 VMAX=4503 => 30.9fps;  本版 VMAX=5572 => 40.0ms => 25.00fps
//        为什么不是 30fps: FPGA 输出端 ui_vtc 固定 25fps
//        (4K30 需要 3840x2160x2Bx30 = 497.7MB/s, 占 4lane x1000Mbps 的 99.5%, 跑不动)
//        写侧必须跟读侧同频, 否则 dbuf 溢出/欠载 -> 画面撕裂。
//  交叉验证: GitHub tipoman9/imx415_modes 的 3840x2160@30fps 表同样是
//        SYS_MODE=0x08 + INCKSEL6=1 + INCKSEL7=0 + 同量级的 D-PHY 时序。
//
//  ★ RX 侧不用改: rx_clk_gen 是从恢复出来的 MIPI 时钟 BUFIO 分频, 无速率参数,
//    891Mbps -> 1440Mbps 会自动跟随 (MIPI clk 445.5MHz -> 720MHz)。
//    cam_param.v 的 i_vmax 必须跟着模式变 (2283 <-> 4503)。
//=============================================================================
module ui_imx415reg (
    input      [1 : 0] MODE,       // 0=1080p(2x2 binning), 1=4K(all-pixel), 2=720p
    input      [8 : 0] REG_INDEX,
    output reg [31: 0] REG_DATA,
    output     [7 : 0] REG_SIZE
);

  assign REG_SIZE = 201;
  //-----------------------------------------------------------------
  /////////////////////   Config Data LUT   //////////////////////////    
  always @(*) begin
    case (REG_INDEX)
        0:   REG_DATA = {16'h3000, 8'h01};// STANDBY: 1=Standby (手册 P40: 0=Operating,1=Standby) ★先挂待机
//       ★★ V25: 这里必须是 0x00(待机), 不能是 0x01。
//         链路执行顺序是: 主表(0..200) -> 待机表(0x3000←0x01, 0x3002←0x01)
//         也就是“主表开头挂待机 -> 改完模式寄存器 -> 末尾再放运行”。
//         原来主表开头写的是 0x01(直接运行), 于是实际顺序变成
//         “先运行 -> 改模式寄存器 -> 再挂待机”, 正好是反的。
//         后果: 切到 4K 后传感器只吐出 5 帧就彻底停了(实测), RX 也再拉不回来。
//         改模式(尤其 binning <-> all-pixel)必须走 待机 -> 改 -> 运行。
      1:   REG_DATA = {16'h3001, 8'h00};// REGHOLD
        2:   REG_DATA = {16'h3002, 8'h01};// XMSTA: 1=Master operation ready, 0=start ★先停主模式
      3:   REG_DATA = {16'h3003, 8'h00};// XMASTER
      4:   REG_DATA = (MODE==2'd1) ? {16'h3008, 8'h54} : {16'h3008, 8'h5D};// BCWAIT_TIME: 4K=0x54(1440Mbps), binning=0x5D(891Mbps)
      5:   REG_DATA = {16'h3009, 8'h00};// BCWAIT_TIME[9:0]
      6:   REG_DATA = (MODE==2'd1) ? {16'h300A, 8'h3B} : {16'h300A, 8'h42};// CPWAIT_TIME: 4K=0x3B, binning=0x42
      7:   REG_DATA = {16'h300B, 8'hA0};// CPWAIT_TIME[9:0]
      8:   REG_DATA = {16'h301C, 8'h00};// WINMODE[3:0]
      9:   REG_DATA = {16'h301D, 8'h08};// -
        10:  REG_DATA = (MODE==2'd1) ? {16'h3020, 8'h00} : {16'h3020, 8'h01};// HADD: 0=no-add(4K), 1=2x2-binning
        11:  REG_DATA = (MODE==2'd1) ? {16'h3021, 8'h00} : {16'h3021, 8'h01};// VADD: 0=no-add(4K), 1=2x2-binning
        12:  REG_DATA = (MODE==2'd1) ? {16'h3022, 8'h00} : {16'h3022, 8'h01};// ADDMODE[1:0]: 0=off(4K), 1=binning
      13:  REG_DATA = {16'h3023, 8'h01};// VCMODE
      14:  REG_DATA = (MODE==2'd1) ? {16'h3024, 8'hC4} : {16'h3024, 8'hEB};// VMAX[7:0]: 4K=0xC4, binning=0xEB
      15:  REG_DATA = (MODE==2'd1) ? {16'h3025, 8'h15} : {16'h3025, 8'h08};// VMAX[15:8]: 4K=0x15 => 5572(25.00fps@533clk), binning=0x08 => 2283
      16:  REG_DATA = {16'h3026, 8'h00};// VMAX[19:0]
      17:  REG_DATA = (MODE==2'd1) ? {16'h3028, 8'h15} : {16'h3028, 8'h1E};// HMAX[7:0]: 4K=0x15(533), binning=0x1E(542)
      18:  REG_DATA = {16'h3029, 8'h02};// HMAX[15:8]: 0x02 for all modes
      19:  REG_DATA = {16'h302C, 8'h00};// WDMODE[1:0]
      20:  REG_DATA = {16'h302D, 8'h00};// WDSEL[1:0]
      21:  REG_DATA = {16'h3030, 8'h00};// HREVERSE
      22:  REG_DATA = {16'h3031, 8'h00};// ADBIT[1:0]
      23:  REG_DATA = {16'h3032, 8'h00};// MDBIT
        24:  REG_DATA = (MODE==2'd1) ? {16'h3033, 8'h08} : {16'h3033, 8'h05};// SYS_MODE: 4K=0x08(1440Mbps), binning=0x05(891Mbps) ★★
      25:  REG_DATA = {16'h3040, 8'h00};// PIX_HST[12:0]
      26:  REG_DATA = {16'h3041, 8'h00};// PIX_HST[12:0]
      27:  REG_DATA = {16'h3042, 8'h18};// PIX_HWIDTH[12:0]
      28:  REG_DATA = {16'h3043, 8'h0F};// PIX_HWIDTH[12:0]
      29:  REG_DATA = {16'h3044, 8'h00};// PIX_VST[12:0]
      30:  REG_DATA = {16'h3045, 8'h00};// PIX_VST[12:0]
      31:  REG_DATA = {16'h3046, 8'h20};// PIX_VWIDTH[12:0]
      32:  REG_DATA = {16'h3047, 8'h11};// PIX_VWIDTH[12:0]
      33:  REG_DATA = {16'h3050, 8'h08};// SHR0[19:0]
      34:  REG_DATA = {16'h3051, 8'h00};// SHR0[19:0]
      35:  REG_DATA = {16'h3052, 8'h00};// SHR0[19:0]
      36:  REG_DATA = {16'h3054, 8'h19};// SHR1[19:0]
      37:  REG_DATA = {16'h3055, 8'h00};// SHR1[19:0]
      38:  REG_DATA = {16'h3056, 8'h00};// SHR1[19:0]
      39:  REG_DATA = {16'h3058, 8'h3E};// SHR2[19:0]
      40:  REG_DATA = {16'h3059, 8'h00};// SHR2[19:0]
      41:  REG_DATA = {16'h305A, 8'h00};// SHR2[19:0]
      42:  REG_DATA = {16'h305C, 8'h66};// SHR3[19:0]
      43:  REG_DATA = {16'h305D, 8'h00};// SHR3[19:0]
      44:  REG_DATA = {16'h305E, 8'h00};// SHR3[19:0]
      45:  REG_DATA = {16'h3060, 8'h25};// RHS1[19:0]
      46:  REG_DATA = {16'h3061, 8'h00};// RHS1[19:0]
      47:  REG_DATA = {16'h3062, 8'h00};// RHS1[19:0]
      48:  REG_DATA = {16'h3064, 8'h4A};// RHS2[19:0]
      49:  REG_DATA = {16'h3065, 8'h00};// RHS2[19:0]
      50:  REG_DATA = {16'h3066, 8'h00};// RHS2[19:0]
        51:  REG_DATA = (MODE==2'd1) ? {16'h3090, 8'h10} : {16'h3090, 8'h20};// GAIN_PGC_0: 4K=0x10(4.8dB), binning=0x20(9.6dB); 之后由 AE 通道覆盖
      52:  REG_DATA = {16'h3091, 8'h00};// GAIN_PGC_0[8:0]
      53:  REG_DATA = {16'h3092, 8'h00};// GAIN_PGC_1 (HDR only)
      54:  REG_DATA = {16'h3093, 8'h00};// GAIN_PGC_1[8:0]
      55:  REG_DATA = {16'h3094, 8'h00};// GAIN_PGC_2 (HDR only)
      56:  REG_DATA = {16'h3095, 8'h00};// GAIN_PGC_2[8:0]
      57:  REG_DATA = {16'h3096, 8'h00};// GAIN_PGC_3 (HDR only)
      58:  REG_DATA = {16'h3097, 8'h00};// GAIN_PGC_3[8:0]
      59:  REG_DATA = {16'h30C0, 8'h2A};// XVSOUTSEL[1:0]
      60:  REG_DATA = {16'h30C1, 8'h00};// XVS_DRV[1:0]
      61:  REG_DATA = {16'h30CC, 8'h00};// -
      62:  REG_DATA = {16'h30CD, 8'h00};// -
      63:  REG_DATA = {16'h30CF, 8'h00};// XVSMSKCNT_INT[1:0]
        64:  REG_DATA = (MODE==2'd1) ? {16'h30D9, 8'h06} : {16'h30D9, 8'h02};// DIG_CLP_VSTART[4:0]: 4K=0x06
        65:  REG_DATA = (MODE==2'd1) ? {16'h30DA, 8'h02} : {16'h30DA, 8'h01};// DIG_CLP_VNUM[1:0]: 4K=0x02
      66:  REG_DATA = {16'h30E2, 8'h32};// BLKELVEL[9:0]
      67:  REG_DATA = {16'h30E3, 8'h00};// BLKELVEL[9:0]
      68:  REG_DATA = {16'h3115, 8'h00};// INCKSEL1[7:0]
      69:  REG_DATA = {16'h3116, 8'h23};// INCKSEL2[7:0]
        70:  REG_DATA = (MODE==2'd1) ? {16'h3118, 8'hB4} : {16'h3118, 8'hC6};// INCKSEL3: 4K=0xB4, binning=0xC6 ★★
        71:  REG_DATA = {16'h3119, 8'h00};// INCKSEL3[10:0]
        72:  REG_DATA = (MODE==2'd1) ? {16'h311A, 8'hFC} : {16'h311A, 8'hE7};// INCKSEL4: 4K=0xFC, binning=0xE7 ★
      73:  REG_DATA = {16'h311B, 8'h00};// INCKSEL4[10:0]
      74:  REG_DATA = {16'h311E, 8'h23};// INCKSEL5[7:0]
      75:  REG_DATA = {16'h3260, 8'h01};// GAIN_PGC_FIDMD
      76:  REG_DATA = {16'h32C8, 8'h01};
      77:  REG_DATA = {16'h32D4, 8'h21};
      78:  REG_DATA = {16'h32EC, 8'hA1};
      79:  REG_DATA = {16'h344C, 8'h2B};
      80:  REG_DATA = {16'h344D, 8'h01};
      81:  REG_DATA = {16'h344E, 8'hED};
      82:  REG_DATA = {16'h344F, 8'h01};
      83:  REG_DATA = {16'h3450, 8'hF6};
      84:  REG_DATA = {16'h3451, 8'h02};
      85:  REG_DATA = {16'h3452, 8'h7F};
      86:  REG_DATA = {16'h3453, 8'h03};
      87:  REG_DATA = {16'h358A, 8'h04};
      88:  REG_DATA = {16'h35A1, 8'h02};
      89:  REG_DATA = {16'h35EC, 8'h27};
      90:  REG_DATA = {16'h35EE, 8'h8D};
      91:  REG_DATA = {16'h35F0, 8'h8D};
      92:  REG_DATA = {16'h35F2, 8'h29};
      93:  REG_DATA = {16'h36BC, 8'h0C};
      94:  REG_DATA = {16'h36CC, 8'h53};
      95:  REG_DATA = {16'h36CD, 8'h00};
      96:  REG_DATA = {16'h36CE, 8'h3C};
      97:  REG_DATA = {16'h36D0, 8'h8C};
      98:  REG_DATA = {16'h36D1, 8'h00};
      99:  REG_DATA = {16'h36D2, 8'h71};
      100: REG_DATA = {16'h36D4, 8'h3C};
      101: REG_DATA = {16'h36D6, 8'h53};
      102: REG_DATA = {16'h36D7, 8'h00};
      103: REG_DATA = {16'h36D8, 8'h71};
      104: REG_DATA = {16'h36DA, 8'h8C};
      105: REG_DATA = {16'h36DB, 8'h00};
      106: REG_DATA = {16'h3701, 8'h00};
      107: REG_DATA = {16'h3720, 8'h00};
      108: REG_DATA = {16'h3724, 8'h02};
      109: REG_DATA = {16'h3726, 8'h02};
      110: REG_DATA = {16'h3732, 8'h02};
      111: REG_DATA = {16'h3734, 8'h03};
      112: REG_DATA = {16'h3736, 8'h03};
      113: REG_DATA = {16'h3742, 8'h03};
      114: REG_DATA = {16'h3862, 8'hE0};
      115: REG_DATA = {16'h38CC, 8'h30};
      116: REG_DATA = {16'h38CD, 8'h2F};
      117: REG_DATA = {16'h395C, 8'h0C};
      118: REG_DATA = {16'h39A4, 8'h07};
      119: REG_DATA = {16'h39A8, 8'h32};
      120: REG_DATA = {16'h39AA, 8'h32};
      121: REG_DATA = {16'h39AC, 8'h32};
      122: REG_DATA = {16'h39AE, 8'h32};
      123: REG_DATA = {16'h39B0, 8'h32};
      124: REG_DATA = {16'h39B2, 8'h2F};
      125: REG_DATA = {16'h39B4, 8'h2D};
      126: REG_DATA = {16'h39B6, 8'h28};
      127: REG_DATA = {16'h39B8, 8'h30};
      128: REG_DATA = {16'h39BA, 8'h30};
      129: REG_DATA = {16'h39BC, 8'h30};
      130: REG_DATA = {16'h39BE, 8'h30};
      131: REG_DATA = {16'h39C0, 8'h30};
      132: REG_DATA = {16'h39C2, 8'h2E};
      133: REG_DATA = {16'h39C4, 8'h2B};
      134: REG_DATA = {16'h39C6, 8'h25};
      135: REG_DATA = {16'h3A42, 8'hD1};
      136: REG_DATA = {16'h3A4C, 8'h77};
      137: REG_DATA = {16'h3AE0, 8'h02};
      138: REG_DATA = {16'h3AEC, 8'h0C};
      139: REG_DATA = {16'h3B00, 8'h2E};
      140: REG_DATA = {16'h3B06, 8'h29};
      141: REG_DATA = {16'h3B98, 8'h25};
      142: REG_DATA = {16'h3B99, 8'h21};
      143: REG_DATA = {16'h3B9B, 8'h13};
      144: REG_DATA = {16'h3B9C, 8'h13};
      145: REG_DATA = {16'h3B9D, 8'h13};
      146: REG_DATA = {16'h3B9E, 8'h13};
      147: REG_DATA = {16'h3BA1, 8'h00};
      148: REG_DATA = {16'h3BA2, 8'h06};
      149: REG_DATA = {16'h3BA3, 8'h0B};
      150: REG_DATA = {16'h3BA4, 8'h10};
      151: REG_DATA = {16'h3BA5, 8'h14};
      152: REG_DATA = {16'h3BA6, 8'h18};
      153: REG_DATA = {16'h3BA7, 8'h1A};
      154: REG_DATA = {16'h3BA8, 8'h1A};
      155: REG_DATA = {16'h3BA9, 8'h1A};
      156: REG_DATA = {16'h3BAC, 8'hED};
      157: REG_DATA = {16'h3BAD, 8'h01};
      158: REG_DATA = {16'h3BAE, 8'hF6};
      159: REG_DATA = {16'h3BAF, 8'h02};
      160: REG_DATA = {16'h3BB0, 8'hA2};
      161: REG_DATA = {16'h3BB1, 8'h03};
      162: REG_DATA = {16'h3BB2, 8'hE0};
      163: REG_DATA = {16'h3BB3, 8'h03};
      164: REG_DATA = {16'h3BB4, 8'hE0};
      165: REG_DATA = {16'h3BB5, 8'h03};
      166: REG_DATA = {16'h3BB6, 8'hE0};
      167: REG_DATA = {16'h3BB7, 8'h03};
      168: REG_DATA = {16'h3BB8, 8'hE0};
      169: REG_DATA = {16'h3BBA, 8'hE0};
      170: REG_DATA = {16'h3BBC, 8'hDA};
      171: REG_DATA = {16'h3BBE, 8'h88};
      172: REG_DATA = {16'h3BC0, 8'h44};
      173: REG_DATA = {16'h3BC2, 8'h7B};
      174: REG_DATA = {16'h3BC4, 8'hA2};
      175: REG_DATA = {16'h3BC8, 8'hBD};
      176: REG_DATA = {16'h3BCA, 8'hBD};
      177: REG_DATA = {16'h4000, 8'h10};
      178: REG_DATA = {16'h4001, 8'h03};//LANEMODE[2:0]
        179: REG_DATA = (MODE==2'd1) ? {16'h4004, 8'h00} : {16'h4004, 8'hC0};//TXCLKESC_FREQ: 4K=0x00, binning=0xC0
      180: REG_DATA = {16'h4005, 8'h06};//TXCLKESC_FREQ[15:0]
        181: REG_DATA = (MODE==2'd1) ? {16'h400C, 8'h01} : {16'h400C, 8'h00};//INCKSEL6: 4K=0x01, binning=0x00 ★★
        182: REG_DATA = (MODE==2'd1) ? {16'h4018, 8'h9F} : {16'h4018, 8'h7F};//TCLKPOST: 4K=0x9F, binning=0x7F
      183: REG_DATA = {16'h4019, 8'h00};//TCLKPOST[15:0]
        184: REG_DATA = (MODE==2'd1) ? {16'h401A, 8'h57} : {16'h401A, 8'h37};//TCLKPREPARE: 4K=0x57, binning=0x37
      185: REG_DATA = {16'h401B, 8'h00};//TCLKPREPARE[15:0]
        186: REG_DATA = (MODE==2'd1) ? {16'h401C, 8'h57} : {16'h401C, 8'h37};//TCLKTRAIL: 4K=0x57, binning=0x37
      187: REG_DATA = {16'h401D, 8'h00};//TCLKTRAIL[15:0]
        188: REG_DATA = (MODE==2'd1) ? {16'h401E, 8'h87} : {16'h401E, 8'hF7};//TCLKZERO[7:0]: 4K=0x87, binning=0xF7
        189: REG_DATA = (MODE==2'd1) ? {16'h401F, 8'h01} : {16'h401F, 8'h00};//TCLKZERO[15:8]: 4K=0x01, binning=0x00
        190: REG_DATA = (MODE==2'd1) ? {16'h4020, 8'h5F} : {16'h4020, 8'h3F};//THSPREPARE: 4K=0x5F, binning=0x3F
      191: REG_DATA = {16'h4021, 8'h00};//THSPREPARE[15:0]
        192: REG_DATA = (MODE==2'd1) ? {16'h4022, 8'hA7} : {16'h4022, 8'h6F};//THSZERO: 4K=0xA7, binning=0x6F
      193: REG_DATA = {16'h4023, 8'h00};//THSZERO[15:0]
        194: REG_DATA = (MODE==2'd1) ? {16'h4024, 8'h5F} : {16'h4024, 8'h3F};//THSTRAIL: 4K=0x5F, binning=0x3F
      195: REG_DATA = {16'h4025, 8'h00};//THSTRAIL[15:0]
        196: REG_DATA = (MODE==2'd1) ? {16'h4026, 8'h97} : {16'h4026, 8'h5F};//THSEXIT: 4K=0x97, binning=0x5F
      197: REG_DATA = {16'h4027, 8'h00};//THSEXIT[15:0]
        198: REG_DATA = (MODE==2'd1) ? {16'h4028, 8'h4F} : {16'h4028, 8'h2F};//TLPX: 4K=0x4F, binning=0x2F
      199: REG_DATA = {16'h4029, 8'h00};//TLPX[15:0]
        200: REG_DATA = (MODE==2'd1) ? {16'h4074, 8'h00} : {16'h4074, 8'h01};//INCKSEL7: 4K=0x00, binning=0x01 ★★
      default: REG_DATA = {16'h0000, 8'h00};
    endcase
  end

endmodule

