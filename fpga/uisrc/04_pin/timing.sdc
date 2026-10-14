create_clock -name {sys_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sysclk_25m}]
create_clock -name {ddr_clk} -period 10.000 -waveform {0.000 5.000} [get_ports {I_ddr_clk}]

derive_clocks

rename_clock -name {S_clk_24m} [get_clocks {ui_pll/X_ui_pll.clkc[0]}]
rename_clock -name {S_pclkx1}  [get_clocks {ui_pll/X_ui_pll.clkc[1]}]
rename_clock -name {S_pclkx5}  [get_clocks {ui_pll/X_ui_pll.clkc[2]}]
rename_clock -name {S_clk_70m} [get_clocks {ui_pll/X_ui_pll.clkc[3]}]

rename_clock -name {S_dsi_25m}     [get_clocks {u_ui_pll_dsi/pll_inst.clkc[0]}]
rename_clock -name {S_dsi_byte}    [get_clocks {u_ui_pll_dsi/pll_inst.clkc[1]}]
rename_clock -name {S_dsi_hs_x2}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[2]}]
rename_clock -name {S_dsi_hs_x4}   [get_clocks {u_ui_pll_dsi/pll_inst.clkc[3]}]
rename_clock -name {S_dsi_hs_x4_q} [get_clocks {u_ui_pll_dsi/pll_inst.clkc[4]}]
rename_clock -name {S_dsi_lp}      [get_clocks {u_ui_pll_dsi/pll_inst.clkc[5]}]

set_clock_groups -exclusive -group [get_clocks {X_ui_ddr/dfi_clk}] -group [get_clocks {S_clk_24m}] -group [get_clocks {S_clk_70m}] -group [get_clocks {S_pclkx1}] -group [get_clocks {S_pclkx5}]

# DSI 时钟域与系统/视频时钟域异步隔离
# - sys_clk (S_dsi_en 同步寄存器, 输出 S_dphy_rst_n 走 async FIFO 异步复位端)
# - S_pclkx1 (ui_dbuf.R 像素域, 经 async FIFO 进入 byte_clk 域)
# - DSI 5 个 PLL 派生时钟 (csi2_pack 输出/帧 FSM/D-PHY 串化器)
set_clock_groups -asynchronous \
    -group [get_clocks {sys_clk}] \
    -group [get_clocks {S_pclkx1}] \
    -group [get_clocks {S_dsi_byte S_dsi_hs_x2 S_dsi_hs_x4 S_dsi_hs_x4_q S_dsi_lp}]
