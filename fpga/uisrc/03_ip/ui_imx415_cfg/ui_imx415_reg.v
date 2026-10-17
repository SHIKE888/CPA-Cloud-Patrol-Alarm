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
//  V27: 4K 改用 891Mbps 档 ->  SYS_MODE=5, HMAX=861(0x35D), VMAX=3449(0xD79)
//        => 行周期 861/74.25MHz = 11.60us => VMAX=3449 时 40.0ms -> 25.0fps
//        => cam_param.v 的 VMAX 也必须跟着模式变 (2283 <-> 3449)。
//  另外 0x4004..0x4074 是 MIPI D-PHY 发送时序, 与 lane 速率绑定
//  => V27 起 4K 与 1080p 同为 891Mbps 档, 这些寄存器两个模式用同一组值,
//     只保留真正属于 all-pixel 的差异 (HADD/VADD/ADDMODE/HMAX/VMAX/DIG_CLP)。
//
//=============================================================================
//  ★★ V38 (2026-10-17 深夜): 回退到本文件的 V27/891Mbps 版本。
//
//  V35~V37 我曾把 4K 改成厂商那套 1440Mbps (SYS_MODE=0x08, INCKSEL3=0xB4,
//  整组 D-PHY 换成 1440 档), 理由是两个外部来源都那么写。但 V36 新增的
//  CSI-2 帧首计数器把真相称了出来 (1080p 计数 61.67fps, 证明仪表准):
//
//    V37b (完全厂商原值, VMAX=4503): CSI-FS = 0.00 fps, 行组数停在 486
//    => 1440Mbps 那套在本板一个帧都收不到。
//
//  最可能的原因: 1440Mbps 意味着 MIPI 时钟 720MHz, 超过 PH1A90 LVDS 接收器
//  的能力。1080p 用的 891Mbps (445.5MHz) 在本板已被证实可用。
//  所以 4K 必须跑在 891Mbps 这个已证明能用的速率档上。
//
//  本版只改一件事: 传感器表回到 V27 (891Mbps), 其余 (帧计数仪表/CFG_VER)
//  全部保留。烧完先看 0xB8 有没有速率 —— 这一次仪器是可信的。
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
        4:   REG_DATA = {16'h3008, 8'h5D};// BCWAIT_TIME[9:0]: 速率相关 -> 两模式同用 891Mbps 档
      5:   REG_DATA = {16'h3009, 8'h00};// BCWAIT_TIME[9:0]
        6:   REG_DATA = {16'h300A, 8'h42};// CPWAIT_TIME[9:0]: 速率相关 -> 同上
      7:   REG_DATA = {16'h300B, 8'hA0};// CPWAIT_TIME[9:0]
      8:   REG_DATA = {16'h301C, 8'h00};// WINMODE[3:0]
      9:   REG_DATA = {16'h301D, 8'h08};// -
        10:  REG_DATA = (MODE==2'd1) ? {16'h3020, 8'h00} : {16'h3020, 8'h01};// HADD: 0=no-add(4K), 1=2x2-binning
        11:  REG_DATA = (MODE==2'd1) ? {16'h3021, 8'h00} : {16'h3021, 8'h01};// VADD: 0=no-add(4K), 1=2x2-binning
        12:  REG_DATA = (MODE==2'd1) ? {16'h3022, 8'h00} : {16'h3022, 8'h01};// ADDMODE[1:0]: 0=off(4K), 1=binning
      13:  REG_DATA = {16'h3023, 8'h01};// VCMODE
        14:  REG_DATA = (MODE==2'd1) ? {16'h3024, 8'h5C} : {16'h3024, 8'hEB};// VMAX[7:0]: 4K=0x5C, binning=0xEB
        15:  REG_DATA = (MODE==2'd1) ? {16'h3025, 8'h0D} : {16'h3025, 8'h08};// VMAX[15:8]: 4K=0x0D => 3420(25.04fps@861clk), binning=0x08 => 2283
        // ★★★ 上面这个 3420 必须与 system_top.v 里 cam_param 的 i_vmax 保持一致 ★★★
        //   i_vmax 只用于算曝光(SHR0), 真正决定帧长的是这里。两处不一致的话
        //   帧率不会变(V38c 就这么翻的车)。
      16:  REG_DATA = {16'h3026, 8'h00};// VMAX[19:0]
        17:  REG_DATA = (MODE==2'd1) ? {16'h3028, 8'h5D} : {16'h3028, 8'h1E};// HMAX[7:0]: 4K=0x5D, binning=0x1E(542)
        18:  REG_DATA = (MODE==2'd1) ? {16'h3029, 8'h03} : {16'h3029, 8'h02};// HMAX[15:8]: 4K 861=0x35D -> 0x03
      19:  REG_DATA = {16'h302C, 8'h00};// WDMODE[1:0]
      20:  REG_DATA = {16'h302D, 8'h00};// WDSEL[1:0]
      21:  REG_DATA = {16'h3030, 8'h00};// HREVERSE
      22:  REG_DATA = {16'h3031, 8'h00};// ADBIT[1:0]
      23:  REG_DATA = {16'h3032, 8'h00};// MDBIT
        24:  REG_DATA = {16'h3033, 8'h05};// SYS_MODE[3:0]=5 -> 891Mbps/lane ★★与 1080p 同速率, D-PHY 无需变速
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
        51:  REG_DATA = (MODE==2'd1) ? {16'h3090, 8'h10} : {16'h3090, 8'h20};// GAIN_PGC_0: 4K=0x10(4.8dB), binning=0x20(9.6dB); 之后由 AE 覆盖
      52:  REG_DATA = {16'h3091, 8'h00};// GAIN_PGC_0[8:0]
      53:  REG_DATA = {16'h3092, 8'h00};// GAIN_PGC_1 (HDR 专用, 单帧模式清零)
      54:  REG_DATA = {16'h3093, 8'h00};// GAIN_PGC_1[8:0]
      55:  REG_DATA = {16'h3094, 8'h00};// GAIN_PGC_2 (HDR 专用)
      56:  REG_DATA = {16'h3095, 8'h00};// GAIN_PGC_2[8:0]
      57:  REG_DATA = {16'h3096, 8'h00};// GAIN_PGC_3 (HDR 专用)
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
        70:  REG_DATA = {16'h3118, 8'hC6};// INCKSEL3[10:0]: 速率相关 -> 891Mbps 档
      71:  REG_DATA = {16'h3119, 8'h00};// INCKSEL3[10:0]
        72:  REG_DATA = {16'h311A, 8'hE7};// INCKSEL4[10:0]: 速率相关 -> 891Mbps 档
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
        179: REG_DATA = {16'h4004, 8'hC0};//TXCLKESC_FREQ[15:0]: 速率相关 -> 891Mbps 档
      180: REG_DATA = {16'h4005, 8'h06};//TXCLKESC_FREQ[15:0]
        181: REG_DATA = {16'h400C, 8'h00};//INCKSEL6: 速率相关 -> 891Mbps 档
        182: REG_DATA = {16'h4018, 8'h7F};//TCLKPOST[15:0]: 速率相关 -> 891Mbps 档
      183: REG_DATA = {16'h4019, 8'h00};//TCLKPOST[15:0]
        184: REG_DATA = {16'h401A, 8'h37};//TCLKPREPARE[15:0]: 速率相关 -> 891Mbps 档
      185: REG_DATA = {16'h401B, 8'h00};//TCLKPREPARE[15:0]
        186: REG_DATA = {16'h401C, 8'h37};//TCLKTRAIL[15:0]: 速率相关 -> 891Mbps 档
      187: REG_DATA = {16'h401D, 8'h00};//TCLKTRAIL[15:0]
        188: REG_DATA = {16'h401E, 8'hF7};//TCLKZERO[7:0]: 速率相关 -> 891Mbps 档
        189: REG_DATA = {16'h401F, 8'h00};//TCLKZERO[15:8]: 速率相关 -> 891Mbps 档
        190: REG_DATA = {16'h4020, 8'h3F};//THSPREPARE[15:0]: 速率相关 -> 891Mbps 档
      191: REG_DATA = {16'h4021, 8'h00};//THSPREPARE[15:0]
        192: REG_DATA = {16'h4022, 8'h6F};//THSZERO[15:0]: 速率相关 -> 891Mbps 档
      193: REG_DATA = {16'h4023, 8'h00};//THSZERO[15:0]
        194: REG_DATA = {16'h4024, 8'h3F};//THSTRAIL[15:0]: 速率相关 -> 891Mbps 档
      195: REG_DATA = {16'h4025, 8'h00};//THSTRAIL[15:0]
        196: REG_DATA = {16'h4026, 8'h5F};//THSEXIT[15:0]: 速率相关 -> 891Mbps 档
      197: REG_DATA = {16'h4027, 8'h00};//THSEXIT[15:0]
        198: REG_DATA = {16'h4028, 8'h2F};//TLPX[15:0]: 速率相关 -> 891Mbps 档
      199: REG_DATA = {16'h4029, 8'h00};//TLPX[15:0]
        200: REG_DATA = {16'h4074, 8'h01};//INCKSEL7[2:0]: 速率相关 -> 891Mbps 档
      default: REG_DATA = {16'h0000, 8'h00};
    endcase
  end

endmodule

