create_clock -name {sys_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sysclk_25m}]
create_clock -name {ddr_clk} -period 10.000 -waveform {0.000 5.000} [get_ports {I_ddr_clk}]

derive_clocks

#=============================================================================
# ⚠⚠ 改名路径**必须**是 X_ui_pll/pll_inst.clkc[N]
#
# 2026-10-31 事故复盘 (0x470A bit 花屏 + ui_dbuf 写状态机不走)：
#   回档到 V47.8 (commit 90abc39) 把 uisrc/** 整体回退，连本文件也回到了
#   改名路径写错的那一版：
#     rename_clock -name {S_pclkx1} [get_clocks {ui_pll/X_ui_pll.clkc[1]}]  <- 错
#   实际实例路径是 X_ui_pll/pll_inst.clkc[1] -> get_clocks 返回空 -> rename
#   静默失效（时钟包里仍叫 X_ui_pll/pll_inst.clkc[1]）-> 下面 set_clock_groups
#   里的组变成空组 -> TD 把**整条 set_clock_groups 命令拒掉** ->
#   所有 CDC 被当成单周期同步路径去收敛。
#   后果（route.qor 实读）：SWNS -5.617ns / STNS -300.9ns / 103 个违例端点,
#   HWNS -2.512ns / HTNS -50.4ns / 33 个违例端点, 时钟偏斜 2830ps,
#   STA 覆盖率 12.96%。Hold 违例 = 确定性错数据。
#   这条修复之前在 commit 4574e77 / 41ff242 已经做过，别再回退掉。
#
# ⚠ set_clock_groups 里**只列当前设计真实存在的时钟**：
#   本版 clock summary 里没有 clkc[2](S_pclkx5) / clkc[3](S_clk_70m) /
#   dsi clkc[5](S_dsi_lp) —— 它们 fanout=0。写不存在的名字会再次产生空组，
#   把整条命令弄挂。以后真要启用，先跑一遍综合看时钟表再改。
#=============================================================================
rename_clock -name {S_clk_24m} [get_clocks {X_ui_pll/pll_inst.clkc[0]}]
rename_clock -name {S_pclkx1}  [get_clocks {X_ui_pll/pll_inst.clkc[1]}]

rename_clock -name {S_dsi_25m}     [get_clocks {u_ui_pll_dsi/pll_inst.clkc[0]}]
rename_clock -name {S_dsi_byte}    [get_clocks {u_ui_pll_dsi/pll_inst.clkc[1]}]
rename_clock -name {S_dsi_hs_x2}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[2]}]
rename_clock -name {S_dsi_hs_x4}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[3]}]
rename_clock -name {S_dsi_hs_x4_q} [get_clocks {u_ui_pll_dsi/pll_inst.clkc[4]}]

# V30: 这里原来是 -exclusive(互斥时钟), 但这些时钟是【异步并发】的。
#   -exclusive 会让 STA 完全跳过这些域之间的所有路径, 是 STA 覆盖率只有 ~32% 的直接原因。
#   改成 -asynchronous: 域间不查(有 async FIFO 隔离), 但各域内部照查。
#=============================================================================
# V34 (2026-10-17): 重写时钟分组 —— 这是"时序不收敛"的真正原因
#
# V33 的时序报告显示, 所有【域内】路径其实都是干净的 (0 违例端点):
#     dfi_clk    -> dfi_clk      SWNS +1.630   0/8121 viol
#     mcu_clk    -> mcu_clk      SWNS +8.935   0/2949 viol
#     S_dsi_byte -> S_dsi_byte   SWNS +2.612   0/1261 viol
#     sys_clk    -> sys_clk      SWNS +27.810  0/1037 viol
#     S_pclkx1   -> S_pclkx1     SWNS +0.889   0/367  viol   <- 含 csi2_pack
#     S_clk_70m  -> S_clk_70m    SWNS +12.253  0/36   viol
#   而所有"违例"全部是【跨域】的, 而且 100% 端点违例:
#     S_pclkx1   -> S_dsi_byte   -4.691  197/197   (csi2_pack 的 async FIFO)
#     sys_clk    -> S_pclkx1     -5.808   57/57
#     S_dsi_byte -> S_pclkx1     -2.521   14/14
#     sys_clk    -> S_clk_70m    -4.567   12/12
#   这些都是 CDC, RTL 里已用同步器/异步 FIFO 处理, 不应该有单周期时序要求。
#
# 上一版的问题:
#   (1) 用了 set_clock_groups -exclusive —— -exclusive 是"互斥时钟(同一时刻只有
#       一个在跑)", 而这些时钟是【异步并发】的, 应该用 -asynchronous。
#       用错会让 STA 完全跳过域间路径, STA 覆盖率只有 ~32%。
#   (2) 即便改对, 分组也不完整 —— sys_clk 与 S_clk_70m、ddr 与 pll 之间都没覆盖。
#   后果: 布局布线器一直花力气去"修"这 280 个永远不可能满足的 CDC 路径,
#         反而挤占了真正要收敛的域内路径的资源。
#
# 本版: 把所有时钟域声明成互斥异步组 —— 域间不查, 域内照查。
#      同一 PLL 派生、且内部互相通信的时钟放在同一组里, 组内仍然分析。
#=============================================================================
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk}] \
    -group [get_clocks {ddr_clk}] \
    -group [get_clocks {X_ui_ddr/dfi_clk X_ui_ddr/mcu_clk}] \
    -group [get_clocks {S_clk_24m S_pclkx1}] \
    -group [get_clocks {S_dsi_25m S_dsi_byte S_dsi_hs_x2 S_dsi_hs_x4 S_dsi_hs_x4_q}]