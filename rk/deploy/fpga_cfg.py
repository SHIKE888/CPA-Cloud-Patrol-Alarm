#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fpga_cfg.py —— 通过 I2C 配置 FPGA 参数 (反向传参链路, RK 端工具)

硬件连线 (底板已连好, **不需要飞线**):
    RK3576 I2C9  <--->  FPGA L18 (SCL) / M18 (SDA)
    实测 i2cdetect -y 9 能看到 0x40。
    (早先误以为是走 FMC_HPC_IIC / FPGA P14/P15 —— 那样才需要飞线, 已纠正)
    FPGA 侧是 I2C 从机, 地址 0x40。

为什么不能走 I_dsi_en
---------------------
驱动 milianke_mipi.c 用 devm_gpiod_get_optional("mipi-en") 独占了那个 GPIO,
用户态拿不到, 没法 bit-bang。所以只能走 I2C。

寄存器映射 (详见 fpga/uisrc/01_rtl/jpeg/jpeg_regfile.v 头部注释)
    0xB0 PP_EN        高级预处理总使能
    0xB1 ADV_MODE     0=关 1=Sobel 2=阈值 3=形态 4=中值 5=拉普拉斯 6=浮雕 7=Prewitt（锐化已移除）
    0xB2 ADV_SOBEL_SH Sobel 幅度右移
    0xB3 ADV_THRESH   阈值分割阈值
    0xB4 ADV_MORPH_SEL 0=腐蚀 1=膨胀
    0xB5 ADV_MORPH_TH 形态学阈值
    0xB6 ADV_LAP_SH   拉普拉斯位移
    0xB7 ADV_PREW_SH  Prewitt 位移
    0xF0 BASIC_EN     初级多选位图: bit0 灰度 bit1 高斯 bit2 HE bit3 对比度 bit4 反色
    0xF1 BASIC_GRAY   灰度系数 0=BT.601 1=BT.709
    0xF2 BASIC_GAUSS  高斯强度 0..8
    0xF3 BASIC_HE     直方图均衡强度 0..255
    0xF4 BASIC_CONTRAST 对比度强度 0..8
    0xF8 BASIC_KER    高斯核尺寸 0=3x3 1=5x5 2=7x7
    0xF9 BASIC_HE_CLIP 直方图桶上限 x64 (0=不限)
    0xFA （已废弃：HE 平滑内置固定，读回 0）
    0xFB BASIC_LINEFIX 行首左旋 16 像素 (0=关)
    0xF5 ADV_EMBOSS_GAIN 浮雕增益
    0xF6 ADV_EMBOSS_BIAS 浮雕偏置
    0xB8..0xBB 帧计数 (只读)
    0xBC 心跳 (只读, 每 256 个读时钟 +1)

用法
----
    python3 fpga_cfg.py scan                 # 扫描总线找 FPGA
    python3 fpga_cfg.py dump                 # 打印全部可读寄存器
    python3 fpga_cfg.py heartbeat            # 连读心跳, 验证 I2C 通路活着
    python3 fpga_cfg.py mode 1               # 高级: 切到 Sobel
    python3 fpga_cfg.py basic 6              # 初级: 高斯 + 直方图均衡
    python3 fpga_cfg.py set 0xB3 100         # 写任意寄存器
    python3 fpga_cfg.py get 0xB3
    python3 fpga_cfg.py demo                 # 依次切换高级模式 (配合观察画面)
"""
import argparse
import os
import sys
import time

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

ADDR = 0x40
BUS_DEFAULT = 9          # RK3576 I2C9

NAMES = {
    0x00: "JPEG_MODE", 0x01: "JPEG_QUALITY",
    0xB0: "PP_EN", 0xB1: "ADV_MODE", 0xB2: "ADV_SOBEL_SH",
    0xB3: "ADV_THRESH", 0xB4: "ADV_MORPH_SEL", 0xB5: "ADV_MORPH_TH",
    0xB6: "ADV_LAP_SH", 0xB7: "ADV_PREW_SH",
    0xF0: "BASIC_EN", 0xF1: "BASIC_GRAY", 0xF2: "BASIC_GAUSS",
    0xF3: "BASIC_HE", 0xF4: "BASIC_CONTRAST",
    0xF8: "BASIC_KER", 0xF9: "BASIC_HE_CLIP",
    0xFB: "BASIC_LINEFIX",
    0xF5: "ADV_EMBOSS_GAIN", 0xF6: "ADV_EMBOSS_BIAS",
    0xB8: "FRAME_CNT[7:0]", 0xB9: "FRAME_CNT[15:8]",
    0xBA: "FRAME_CNT[23:16]", 0xBB: "FRAME_CNT[31:24]",
    0xBC: "HEARTBEAT", 0xA9: "VER_L", 0xAA: "VER_H",
}

MODE_NAME = {0: "关闭", 1: "Sobel 边缘", 2: "阈值二值", 3: "形态学",
             4: "中值", 5: "拉普拉斯", 6: "浮雕", 7: "Prewitt"}

BASIC_BITS = [(0, "灰度"), (1, "高斯"), (2, "直方图均衡"),
              (3, "对比度"), (4, "反色")]


def basic_names(mask):
    return "+".join(n for b, n in BASIC_BITS if mask & (1 << b)) or "关"


def dev_path(bus):
    return "/dev/i2c-%d" % bus


def open_bus(bus):
    try:
        import fcntl
    except ImportError:
        print("需要 Linux 上的 fcntl (本脚本请在开发板上跑)")
        sys.exit(2)
    path = dev_path(bus)
    if not os.path.exists(path):
        print("找不到 %s —— 确认 I2C%d 已在设备树里使能" % (path, bus))
        sys.exit(2)
    # ⚠ 必须 r+b: 读寄存器要先 write 子地址再 read, 用 'rb' 会报
    #   "File not open for writing"。
    f = open(path, 'r+b', buffering=0)
    return f, fcntl


I2C_SLAVE = 0x0703


def write_reg(f, fcntl, bus, reg, val):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg, val]))
    time.sleep(0.005)


def read_reg(f, fcntl, bus, reg):
    fcntl.ioctl(f, I2C_SLAVE, ADDR)
    f.write(bytes([reg]))
    return f.read(1)[0]


def cmd_scan(f, fcntl, bus):
    """用 i2cdetect 扫总线更省事; 这里只是提示。"""
    print("扫描 I2C-%d 总线 (只关心 0x%02X):" % (bus, ADDR))
    try:
        v = read_reg(f, fcntl, bus, 0xBC)
        print("  0x%02X 有应答, 心跳 = %d" % (ADDR, v))
        return 0
    except Exception as e:
        print("  0x%02X 无应答 (%s)" % (ADDR, e))
        print("\n排查:")
        print("  1) 飞线是否接上 (RK I2C9 <-> FMC_HPC_IIC P14/P15)")
        print("  2) 总线上是否有上拉 (两端通常各自有, 一般够)")
        print("  3) i2cdetect -y %d 看有没有 0x%02X" % (bus, ADDR))
        print("  4) FPGA 是否已烧录含 i2c_slave 的固件")
        return 1


def cmd_dump(f, fcntl, bus):
    print("寄存器 dump (I2C-%d @ 0x%02X):" % (bus, ADDR))
    addrs = [0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
             0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB,
             0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xA9, 0xAA]
    vals = {}
    for a in addrs:
        try:
            vals[a] = read_reg(f, fcntl, bus, a)
        except Exception as e:
            print("  读 0x%02X 失败: %s" % (a, e))
            return 1
    for a in addrs:
        nm = NAMES.get(a, "?")
        extra = ""
        if a == 0xB1:
            extra = "  -> %s" % MODE_NAME.get(vals[a], "?")
        if a == 0xB4:
            extra = "  -> %s" % ("膨胀" if vals[a] else "腐蚀")
        if a == 0xF0:
            extra = "  -> %s" % basic_names(vals[a])
        if a == 0xF1:
            extra = "  -> %s" % ("BT.709" if vals[a] else "BT.601")
        print("  0x%02X %-16s = 0x%02X (%3d)%s" % (a, nm, vals[a], vals[a], extra))
    fc = vals[0xB8] | (vals[0xB9] << 8) | (vals[0xBA] << 16) | (vals[0xBB] << 24)
    print("  帧计数 = %d" % fc)
    print("  版本 = 0x%02X%02X" % (vals[0xAA], vals[0xA9]))
    return 0


def cmd_heartbeat(f, fcntl, bus, n=6):
    print("连读心跳 (每 256 个读时钟 +1), 间隔 0.3s:")
    prev = None
    changed = 0
    for i in range(n):
        try:
            v = read_reg(f, fcntl, bus, 0xBC)
        except Exception as e:
            print("  读失败: %s" % e)
            return 1
        mark = ""
        if prev is not None:
            if v != prev:
                changed += 1
                mark = "  <- 变化"
            else:
                mark = "  (未变)"
        print("  [%d] %3d%s" % (i, v, mark))
        prev = v
        time.sleep(0.3)
    if changed:
        print("\n结论: I2C 通路**工作正常** (心跳在变)")
        return 0
    print("\n结论: 心跳没变。可能 (a) 读的是缓存值 (b) I2C 没通")
    print("      再跑一次 dump 看是否有变化")
    return 1


def cmd_demo(f, fcntl, bus, dwell=3.0):
    print("依次切换高级模式 0..8, 再演示初级组合, 每档 %.0f 秒 —— 请看 HDMI/网页画面变化" % dwell)
    write_reg(f, fcntl, bus, 0xF0, 0)          # 先关初级, 避免干扰
    for m in range(0, 9):
        write_reg(f, fcntl, bus, 0xB0, 1)      # PP_EN = 1
        write_reg(f, fcntl, bus, 0xB1, m)
        v = read_reg(f, fcntl, bus, 0xB1)
        print("  -> 高级 %d (%s)  回读 0x%02X %s"
              % (m, MODE_NAME[m], v, "OK" if v == m else "!! 回读不符"))
        time.sleep(dwell)
    write_reg(f, fcntl, bus, 0xB0, 0)          # 关高级
    for mask in (1, 2, 4, 6):
        write_reg(f, fcntl, bus, 0xF0, mask)
        v = read_reg(f, fcntl, bus, 0xF0)
        print("  -> 初级 0x%02X (%s)  回读 0x%02X %s"
              % (mask, basic_names(mask), v, "OK" if v == mask else "!! 回读不符"))
        time.sleep(dwell)
    write_reg(f, fcntl, bus, 0xF0, 0)
    print("完成")
    return 0


def main():
    global ADDR          # 必须在任何 ADDR 使用之前声明, 否则 SyntaxError
    ap = argparse.ArgumentParser()
    ap.add_argument('--bus', type=int, default=BUS_DEFAULT)
    ap.add_argument('--addr', type=lambda s: int(s, 0), default=ADDR)
    sub = ap.add_subparsers(dest='cmd', required=True)

    sub.add_parser('scan')
    sub.add_parser('dump')
    p = sub.add_parser('heartbeat')
    p.add_argument('-n', type=int, default=6)
    p = sub.add_parser('mode')
    p.add_argument('mode', type=int, help='0=关 1=Sobel 2=阈值 3=形态 4=中值 5=拉普拉斯 6=浮雕 7=Prewitt')
    p = sub.add_parser('basic')
    p.add_argument('mask', type=int, help='初级多选位图: 1灰度 2高斯 4HE 8对比度 16反色 (可相加)')
    p = sub.add_parser('set')
    p.add_argument('reg', type=lambda s: int(s, 0))
    p.add_argument('val', type=lambda s: int(s, 0))
    p = sub.add_parser('get')
    p.add_argument('reg', type=lambda s: int(s, 0))
    p = sub.add_parser('demo')
    p.add_argument('--dwell', type=float, default=3.0)

    a = ap.parse_args()
    ADDR = a.addr

    f, fcntl = open_bus(a.bus)
    try:
        if a.cmd == 'scan':
            return cmd_scan(f, fcntl, a.bus)
        if a.cmd == 'dump':
            return cmd_dump(f, fcntl, a.bus)
        if a.cmd == 'heartbeat':
            return cmd_heartbeat(f, fcntl, a.bus, a.n)
        if a.cmd == 'demo':
            return cmd_demo(f, fcntl, a.bus, a.dwell)
        if a.cmd == 'mode':
            write_reg(f, fcntl, a.bus, 0xB0, 1)
            write_reg(f, fcntl, a.bus, 0xB1, a.mode)
            v = read_reg(f, fcntl, a.bus, 0xB1)
            print("ADV_MODE <- %d (%s), 回读 0x%02X %s"
                  % (a.mode, MODE_NAME.get(a.mode, "?"), v,
                     "OK" if v == a.mode else "!! 不符"))
            return 0 if v == a.mode else 1
        if a.cmd == 'basic':
            write_reg(f, fcntl, a.bus, 0xF0, a.mask)
            v = read_reg(f, fcntl, a.bus, 0xF0)
            print("BASIC_EN <- 0x%02X (%s), 回读 0x%02X %s"
                  % (a.mask, basic_names(a.mask), v,
                     "OK" if v == (a.mask & 0x1F) else "!! 不符"))
            return 0 if v == (a.mask & 0x1F) else 1
        if a.cmd == 'set':
            write_reg(f, fcntl, a.bus, a.reg, a.val)
            v = read_reg(f, fcntl, a.bus, a.reg)
            print("0x%02X <- 0x%02X, 回读 0x%02X %s"
                  % (a.reg, a.val, v, "OK" if v == a.val else "!! 不符"))
            return 0 if v == a.val else 1
        if a.cmd == 'get':
            v = read_reg(f, fcntl, a.bus, a.reg)
            print("0x%02X = 0x%02X (%d)" % (a.reg, v, v))
            return 0
    finally:
        f.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
