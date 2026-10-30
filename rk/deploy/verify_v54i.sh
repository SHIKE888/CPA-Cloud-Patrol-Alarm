#!/bin/sh
# V54i (0x5406) 验收: 引擎是否推进 / cam0 starve / MIPI 错误增量
B=9
A=0x40

rd() { i2cget -y $B $A "$1" 2>/dev/null; }

echo "== CFG_VER (expect 0xA9=06 0xAA=54) =="
echo "  0xA9=$(rd 0xa9)  0xAA=$(rd 0xaa)"

echo
echo "== engines + mrg_segc, 5 samples @1s =="
printf "  %-4s %-7s %-7s %-9s %-7s %-7s\n" "t" "eng0" "eng3" "segc" "A3" "cam0st"
i=0
while [ $i -lt 5 ]; do
    ea=$(rd 0xea); eb=$(rd 0xeb); ec=$(rd 0xec); ed=$(rd 0xed)
    a6=$(rd 0xa6); a5=$(rd 0xa5); a3=$(rd 0xa3)
    ca=$(rd 0xca); cb=$(rd 0xcb)
    printf "  %-4d 0x%s%s 0x%s%s 0x%s%s 0x%-4s 0x%s%s\n" \
        "$i" "$eb" "$ea" "$ed" "$ec" "$a6" "$a5" "$a3" "$cb" "$ca"
    i=$((i + 1))
    sleep 1
done

echo
echo "== S_dbg_jpeg decode (A6 A5 A4 A3, 32bit) =="
a3=$(rd 0xa3); a4=$(rd 0xa4); a5=$(rd 0xa5); a6=$(rd 0xa6)
echo "  A3=$a3 A4=$a4 A5=$a5 A6=$a6"

echo
echo "== st_frames {E3,E1} / left starve E2 / cam0 starve {CB,CA} =="
echo "  E1=$(rd 0xe1) E3=$(rd 0xe3) E2=$(rd 0xe2) CA=$(rd 0xca) CB=$(rd 0xcb)"

echo
echo "== MIPI error growth over 4s =="
c1=$(dmesg | grep -c "MIPI_CSI2")
sleep 4
c2=$(dmesg | grep -c "MIPI_CSI2")
echo "  before=$c1 after=$c2 delta=$((c2 - c1))"

echo
echo "== web =="
curl -s -m 6 http://127.0.0.1:9012/api/jpeg 2>/dev/null
echo
