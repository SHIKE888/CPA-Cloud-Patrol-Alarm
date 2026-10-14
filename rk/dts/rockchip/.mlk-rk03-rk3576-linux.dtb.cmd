cmd_arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb := gcc -E -Wp,-MMD,arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.d.pre.tmp -nostdinc -I./scripts/dtc/include-prefixes -undef -D__DTS__ -x assembler-with-cpp -o arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.dts.tmp arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dts ; ./scripts/dtc/dtc -o arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb -b 0 -iarch/arm64/boot/dts/rockchip/ -i./scripts/dtc/include-prefixes -Wno-interrupt_provider -@ -Wno-unit_address_vs_reg -Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-graph_child_address -Wno-simple_bus_reg -Wno-unique_unit_address   -d arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.d.dtc.tmp arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.dts.tmp ; cat arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.d.pre.tmp arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.d.dtc.tmp > arch/arm64/boot/dts/rockchip/.mlk-rk03-rk3576-linux.dtb.d

source_arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb := arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dts

deps_arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb := \
  arch/arm64/boot/dts/rockchip/rk3576.dtsi \
  scripts/dtc/include-prefixes/dt-bindings/clock/rockchip,rk3576-cru.h \
  scripts/dtc/include-prefixes/dt-bindings/interrupt-controller/arm-gic.h \
  scripts/dtc/include-prefixes/dt-bindings/interrupt-controller/irq.h \
  scripts/dtc/include-prefixes/dt-bindings/phy/phy.h \
  scripts/dtc/include-prefixes/dt-bindings/power/rk3576-power.h \
  scripts/dtc/include-prefixes/dt-bindings/pinctrl/rockchip.h \
  scripts/dtc/include-prefixes/dt-bindings/soc/rockchip,boot-mode.h \
  scripts/dtc/include-prefixes/dt-bindings/soc/rockchip-csu.h \
  scripts/dtc/include-prefixes/dt-bindings/soc/rockchip-system-status.h \
  scripts/dtc/include-prefixes/dt-bindings/suspend/rockchip-rk3576.h \
  scripts/dtc/include-prefixes/dt-bindings/thermal/thermal.h \
  arch/arm64/boot/dts/rockchip/rk3576-pinctrl.dtsi \
  arch/arm64/boot/dts/rockchip/rockchip-pinconf.dtsi \
  arch/arm64/boot/dts/rockchip/rk3576-evb1.dtsi \
  scripts/dtc/include-prefixes/dt-bindings/usb/pd.h \
  arch/arm64/boot/dts/rockchip/rk3576-evb.dtsi \
  scripts/dtc/include-prefixes/dt-bindings/gpio/gpio.h \
  scripts/dtc/include-prefixes/dt-bindings/pwm/pwm.h \
  scripts/dtc/include-prefixes/dt-bindings/input/rk-input.h \
  scripts/dtc/include-prefixes/dt-bindings/display/drm_mipi_dsi.h \
  scripts/dtc/include-prefixes/dt-bindings/display/rockchip_vop.h \
  scripts/dtc/include-prefixes/dt-bindings/sensor-dev.h \
  arch/arm64/boot/dts/rockchip/rk3576-evb-input-keymap.dtsi \
  arch/arm64/boot/dts/rockchip/rk3576-rk806.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/MLK-RK03.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/485.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/adc_key.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/can.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/csi-imx415-0.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/csi-imx415-1.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/csi-imx415-2.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/dpnew.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/es8388.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/eth.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/HDMI.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/ir_receiver.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/mmc.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/pcie.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/rk03-screen-10.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/rtc.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/saradc.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/spi1.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/ttl.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/uart.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/usb.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/gyroscope.dtsi \
  arch/arm64/boot/dts/rockchip/rk03/gpio-buttons-leds.dtsi \
  arch/arm64/boot/dts/rockchip/rk3576-linux.dtsi \

arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb: $(deps_arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb)

$(deps_arch/arm64/boot/dts/rockchip/mlk-rk03-rk3576-linux.dtb):
