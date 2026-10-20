#!/bin/sh
#=============================================================================
# board_dual_diag.sh —— 双路 CSI 切换诊断 (装在板上跑, 或 ssh 过来跑)
#
#   用法:
#     sh board_dual_diag.sh            # 依次测 cam0 / cam1 / 切回 cam0
#     sh board_dual_diag.sh 1          # 只看 cam1
#     sh board_dual_diag.sh 0          # 只看 cam0
#
#   每个源都会先写 0xE0 (=RES_MODE, 原值重写) 触发一次整链路重新对齐:
#     - 清掉 0xD4/0xD5 的历史最大值 (lg_max 只在 cfg_res_chg 时清)
#     - 让两路 mipi_csi_rx 重跑 eye-scan (摄像头是后插的就必须重跑)
#   代价是每次要等约 1.5s (传感器全表重写 ~100ms + RX 复位 250ms + 窗口 500ms)。
#
#   读法 (关键判据):
#     0xD7 bit6 = manual_mode   —— eye-scan 是否锁定
#     0xD8 bit6 = autodone      —— 自动扫描是否完成
#     0xD8[5:0] = best_len      —— 眼图窗口长度, 正常 20~31
#     0xD6 bit2 = in_frame      —— 当前是否在传输中 (这一位最直接)
#     0xD4/0xD5 = 每行组数历史最大值, 1080p 正常 = 486 = 0x01E6
#=============================================================================

DEV=${DEV:-9}
ADDR=${ADDR:-0x40}

g() { printf '%s' "$(i2cget -y $DEV $ADDR $1 2>/dev/null)"; }
s() { i2cset -y $DEV $ADDR $1 $2 >/dev/null 2>&1; }

hex2() {  # $1 $2 -> decimal (两次单字节读, 小端)
    lo=$(g $1); hi=$(g $2)
    echo $(( ${lo:-0} + 256 * ${hi:-0} )) 2>/dev/null || echo "?"
}

dump() {
    d6=$(g 0xd6); d7=$(g 0xd7); d8=$(g 0xd8)
    echo "  0xD6 = $d6   (bit2=in_frame)"
    echo "  0xD7 = $d7   (bit6=manual_mode, [5:0]=tap)"
    echo "  0xD8 = $d8   (bit6=autodone,  [5:0]=best_len)"
    echo "  0xD4/D5 lg_max = $(hex2 0xd4 0xd5)   (1080p 正常 486)"
    echo "  0xD0/D1 cam_wr_cnt = $(hex2 0xd0 0xd1)"
}

realign() {
    echo "    (写 0xE0 触发整链路重新对齐, 等 3s ...)"
    s 0xe0 0
    sleep 3
}

ver() {
    lo=$(g 0xa9); hi=$(g 0xaa)
    echo "版本 0x$hi$lo  (期望 0x4600)"
}

one() {
    src=$1
    echo "=============================================================="
    echo "== CSI 源 = cam$src   (0xDB=$src)"
    echo "=============================================================="
    s 0xdb $src
    echo "  0xDB 回读 = $(g 0xdb)"
    realign
    echo "  --- 第 1 次 (等 1s) ---"
    sleep 1
    dump
    echo "  --- 第 2 次 (再等 1s) ---"
    sleep 1
    dump
    echo "  --- 第 3 次 (再等 1s) ---"
    sleep 1
    dump
}

echo "=============================================================="
ver
echo "0xDB 当前 = $(g 0xdb)"
echo "=============================================================="

case "${1:-both}" in
    0)    one 0 ;;
    1)    one 1 ;;
    both) one 0; one 1; echo "== 切回 cam0 =="; s 0xdb 0; echo "  0xDB = $(g 0xdb)" ;;
    *)    echo "用法: $0 [0|1|both]"; exit 2 ;;
esac

echo "=============================================================="
echo "判读提示:"
echo "  cam1 若 0xD7 没有 bit6(manual) / 0xD8 没有 bit6(autodone)"
echo "     -> eye-scan 没锁上 = 没有 HS 时钟 或 差分信号太差"
echo "        => 先量 J3 pin8 (DSI_CLK) 有没有 24MHz 方波"
echo "  cam1 若 manual/autodone 都有, best_len 也正常, 但 0xD6 bit2 恒 0"
echo "     -> 时钟 OK, 但 lane 顺序/极性 或 SCCB 没配成功"
echo "  cam0 的 0xD4/D5 必须回到 486; 大于 486 = 行分隔没对齐"
echo "=============================================================="
