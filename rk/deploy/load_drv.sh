#!/bin/bash
# 只负责加载 AIC8800 WiFi/BT 内核模块。
#
# 无线连接统一交给 NetworkManager (连接配置 509, PSK 已存系统密钥)：
#   nmcli con up 509
# 早期版本在这里手工起 wpa_supplicant + dhclient, 会和 NetworkManager 抢
# 同一张网卡: NM 显示 disconnected, 手工 supplicant 又拿不到 WPA 握手,
# 结果网卡 associated 但没有 IP —— 局域网/手机访问全部失败。
# 因此这里不再做任何网络配置。

insmod /usr/lib/firmware/aic_load_fw.ko
sleep 0.3
insmod /usr/lib/firmware/aic8800_fdrv.ko
sleep 0.3
insmod /usr/lib/firmware/aic_btusb.ko

exit 0
