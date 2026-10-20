#!/bin/sh
#=============================================================================
# board_dual_diag.sh —— 双路 CSI 状态诊断 (0x4601+)
#
#   用法:
#     sh board_dual_diag.sh          # 只读状态 (不切源、不改任何寄存器)
#     sh board_dual_diag.sh realign  # 先写 0xE0 触发整链路重新对齐, 再读
#
#   0x4601 起调试寄存器不再跟随选源，两路可以同时看到：
#     0xD6 / 0xD7 / 0xD8  -> 固定 cam0 (子卡 J2)
#     0xDD / 0xDE / 0xDF  -> 固定 cam1 (子卡 J3)
#     0xDC                -> 两路打包实时状态
#
#   读法：
#     0xD7 bit6 = manual_mode   eye-scan 已锁定
#     0xD8 bit6 = autodone     自动扫描完成
#     0xD8[5:0] = best_len     眼图窗口长度, 正常 20~31
#     0xD6 bit5 = in_frame     正在传输
#     0xD6 bit7 = unpack_valid 真的在吐像素
#     0xD4/D5   = 每行组数历史最大值, 1080p 正常 486
#
#   ⚠ 0xD4/D5 是**历史最大值**, 只在分辨率模式切换(写 0xE0)时清零。
#=============================================================================

DEV=${DEV:-9}
ADDR=${ADDR:-0x40}

g() { printf '%s' "$(i2cget -y $DEV $ADDR $1 2>/dev/null)"; }
s() { i2cset -y $DEV $ADDR $1 $2 >/dev/null 2>&1; }

hex2() {
    lo=$(g $1); hi=$(g $2)
    echo $(( ${lo:-0} + 256 * ${hi:-0} )) 2>/dev/null || echo "?"
}

bitnote() {  # $1=值 $2=位号 -> 打印 0/1
    v=$1; b=$2
    if [ -z "$v" ]; then echo "?"; return; fi
    r=$(( v & (1 << b) ))
    if [ "$r" -ne 0 ]; then echo 1; else echo 0; fi
}

row() {  # $1=名字 $2=D6 $3=D7 $4=D8
    echo "  $1"
    echo "    D6=$2  in_frame=$(bitnote "$2" 5)  unpack_valid=$(bitnote "$2" 7)  word_align=$(bitnote "$2" 4)"
    echo "    D7=$3  manual_mode=$(bitnote "$3" 6)"
    echo "    D8=$4  autodone=$(bitnote "$4" 6)"
}

show() {
    echo "--------------------------------------------------------------"
    lo=$(g 0xa9); hi=$(g 0xaa)
    lo=${lo#0x}; hi=${hi#0x}
    echo "版本 0x${hi}${lo}    (0x4601 = 双路调试寄存器 / 0x4700 = 双目交替出帧)"
    db=$(g 0xdb); db=${db:-0x00}; dbv=${db#0x}; dbv=${dbv:-0}
    echo "0xDB = $db   rx_sel=$(bitnote "0x$dbv" 0) (0=cam0/J2 1=cam1/J3)  dual_en=$(bitnote "0x$dbv" 1)  mark_en=$(bitnote "0x$dbv" 2)"
    if [ "$(bitnote "0x$dbv" 1)" = "1" ]; then
        echo "       双目已开: 两路 60fps 采集 / 交替出帧 / 输出 30fps;"
        echo "       web 靠 Y[0..3]=A5 5A src FF 拼成 左cam0|右cam1"
    fi
    echo "0xE0 (分辨率)   = $(g 0xe0)    0 = 1080p60"
    echo "--------------------------------------------------------------"
    row "cam0 (子卡 J2)" "$(g 0xd6)" "$(g 0xd7)" "$(g 0xd8)"
    echo "    D4/D5 每行组数(历史max) = $(hex2 0xd4 0xd5)   (1080p 正常 486)"
    echo "    D0/D1 SCCB 写次数       = $(hex2 0xd0 0xd1)"
    echo "--------------------------------------------------------------"
    row "cam1 (子卡 J3)" "$(g 0xdd)" "$(g 0xde)" "$(g 0xdf)"
    echo "--------------------------------------------------------------"
    dc=$(g 0xdc)
    if [ -n "$dc" ]; then
        echo "0xDC = $dc   两路打包状态"
        echo "    cam0: in_frame=$(bitnote "$dc" 0)  autodone=$(bitnote "$dc" 2)  unpack=$(bitnote "$dc" 4)  4lane=$(bitnote "$dc" 6)"
        echo "    cam1: in_frame=$(bitnote "$dc" 1)  autodone=$(bitnote "$dc" 3)  unpack=$(bitnote "$dc" 5)  4lane=$(bitnote "$dc" 7)"
    else
        echo "0xDC 读不到 —— 板上还是 0x4600 或更早的 bit"
    fi
    echo "--------------------------------------------------------------"
    echo "web 双目状态 (9012 没起就跳过):"
    curl -s --max-time 2 localhost:9012/api/status 2>/dev/null \
        | tr ',' '\n' | grep -E 'dual|active|cam[01]_age_ms|"pair"|nomark' \
        | sed 's/^/    /' || echo "    (未启动)"
    echo "--------------------------------------------------------------"
}

case "${1:-read}" in
    realign)
        echo "写 0xE0 触发整链路重新对齐 (传感器全表重写 + RX 复位, 等 4s)..."
        s 0xe0 0
        sleep 4
        show
        ;;
    *)
        show
        ;;
esac

echo ""
echo "判读提示:"
echo "  in_frame=0 且 autodone=0 -> 没有 HS 时钟 (量 MCLK: cam0=A18, cam1=J13)"
echo "  in_frame=0 但 autodone=1 -> 时钟有、眼图锁上, 查 lane 顺序/极性 或 SCCB"
echo "  两路 in_frame 都=1       -> 两路都在跑, 可以开始做真双路"
echo "  0xD4/D5 > 486            -> 行分隔没对齐 (写 0xE0 重清再看)"
echo "  dual_en=1 但 web cam1_age_ms 一直增长 -> cam1 真的没帧, 右半边会是黑的"
