create_clock -name {sys_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sysclk_25m}]
create_clock -name {ddr_clk} -period 10.000 -waveform {0.000 5.000} [get_ports {I_ddr_clk}]

derive_clocks

rename_clock -name {S_clk_24m} [get_clocks {X_ui_pll/pll_inst.clkc[0]}]
rename_clock -name {S_pclkx1}  [get_clocks {X_ui_pll/pll_inst.clkc[1]}]
rename_clock -name {S_clk_70m} [get_clocks {X_ui_pll/pll_inst.clkc[3]}]

rename_clock -name {S_dsi_25m}     [get_clocks {u_ui_pll_dsi/pll_inst.clkc[0]}]
rename_clock -name {S_dsi_byte}    [get_clocks {u_ui_pll_dsi/pll_inst.clkc[1]}]
rename_clock -name {S_dsi_hs_x2}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[2]}]
rename_clock -name {S_dsi_hs_x4}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[3]}]
rename_clock -name {S_dsi_hs_x4_q} [get_clocks {u_ui_pll_dsi/pll_inst.clkc[4]}]

# V30: 这里原来�?-exclusive(互斥时钟), 但这些时钟是【异步并发】的�?#   -exclusive 会让 STA 完全跳过这些域之间的所有路�? �?STA 覆盖率只�?~32% 的直接原因�?#   改成 -asynchronous: 域间不查(�?async FIFO 隔离), 但各域内部照查�?#=============================================================================
# V34 (2026-10-17): 重写时钟分组 —�?这是"时序不收�?的真正原�?#
# V33 的时序报告显�? 所有【域内】路径其实都是干净�?(0 违例端点):
#     dfi_clk    -> dfi_clk      SWNS +1.630   0/8121 viol
#     mcu_clk    -> mcu_clk      SWNS +8.935   0/2949 viol
#     S_dsi_byte -> S_dsi_byte   SWNS +2.612   0/1261 viol
#     sys_clk    -> sys_clk      SWNS +27.810  0/1037 viol
#     S_pclkx1   -> S_pclkx1     SWNS +0.889   0/367  viol   <- �?csi2_pack
#     S_clk_70m  -> S_clk_70m    SWNS +12.253  0/36   viol
#   而所�?违例"全部是【跨域】的, 而且 100% 端点违例:
#     S_pclkx1   -> S_dsi_byte   -4.691  197/197   (csi2_pack �?async FIFO)
#     sys_clk    -> S_pclkx1     -5.808   57/57
#     S_dsi_byte -> S_pclkx1     -2.521   14/14
#     sys_clk    -> S_clk_70m    -4.567   12/12
#   这些都是 CDC, RTL 里已用同步器/异步 FIFO 处理, 不应该有单周期时序要求�?#
# 上一版的问题:
#   (1) 用了 set_clock_groups -exclusive —�?-exclusive �?互斥时钟(同一时刻只有
#       一个在�?", 而这些时钟是【异步并发】的, 应该�?-asynchronous�?#       用错会让 STA 完全跳过域间路径, STA 覆盖率只�?~32%�?#   (2) 即便改对, 分组也不完整 —�?sys_clk �?S_clk_70m、ddr �?pll 之间都没覆盖�?#   后果: 布局布线器一直花力气�?�?�?280 个永远不可能满足�?CDC 路径,
#         反而挤占了真正要收敛的域内路径的资源�?#
# 本版: 把所有时钟域声明成互斥异步组 —�?域间不查, 域内照查�?#      同一 PLL 派生、且内部互相通信的时钟放在同一组里, 组内仍然分析�?#=============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk}] \
    -group [get_clocks {ddr_clk}] \
    -group [get_clocks {X_ui_ddr/dfi_clk X_ui_ddr/mcu_clk}] \
    -group [get_clocks {S_clk_24m S_pclkx1}] \
    -group [get_clocks {S_clk_70m}] \
    -group [get_clocks {S_dsi_25m S_dsi_byte S_dsi_hs_x2 S_dsi_hs_x4 S_dsi_hs_x4_q}]