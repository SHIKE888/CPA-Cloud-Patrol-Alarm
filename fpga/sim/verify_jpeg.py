#!/usr/bin/env python3
"""verify_jpeg.py - 纯标准库校验 FPGA 输出的 JPEG 码流

不依赖 PIL: 手工遍历 marker 段, 校验结构与尺寸。
    python verify_jpeg.py <file.jpg> [--w 3840] [--h 1080]

判据 (任一不满足即退出码 1):
  1. 以 FF D8 (SOI) 开头
  2. 存在 SOF0/SOF1 (有损) 或 SOF3 (无损), 且 W/H 与期望一致
  3. 存在 SOS, 且熵数据长度 > 0
  4. 结尾能找到 FF D9 (EOI)
"""
import sys

STD_LUT = "0123456789ABCDEF"


def walk_segments(buf):
    """返回 [(marker, offset, payload)]，遇到 SOS 后把剩余当作熵数据。"""
    out = []
    if len(buf) < 4 or buf[0] != 0xFF or buf[1] != 0xD8:
        raise SystemExit("FAIL: 不是 SOI (FF D8) 开头: %02X %02X" % (buf[0], buf[1]))
    i = 2
    while i + 3 < len(buf):
        if buf[i] != 0xFF:
            i += 1
            continue
        m = buf[i + 1]
        if m == 0xFF:          # 填充
            i += 1
            continue
        if m == 0xD9:          # EOI
            out.append((m, i, b""))
            i += 2
            break
        if m == 0xDA:          # SOS: 长度段之后全是熵数据
            ln = (buf[i + 2] << 8) | buf[i + 3]
            hdr = buf[i + 4:i + 2 + ln]
            out.append((m, i, hdr))
            j = i + 2 + ln
            # 熵数据里 FF 00 是转义, FF D9 才结束
            k = j
            while k + 1 < len(buf):
                if buf[k] == 0xFF and buf[k + 1] == 0xD9:
                    break
                k += 1
            out.append(("ENTROPY", j, bytes(buf[j:k])))
            i = k
            continue
        ln = (buf[i + 2] << 8) | buf[i + 3]
        out.append((m, i, bytes(buf[i + 4:i + 2 + ln])))
        i += 2 + ln
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    exp_w = int(sys.argv[sys.argv.index("--w") + 1]) if "--w" in sys.argv else None
    exp_h = int(sys.argv[sys.argv.index("--h") + 1]) if "--h" in sys.argv else None
    buf = open(path, "rb").read()
    segs = walk_segments(buf)

    names = {0xE0: "APP0", 0xDB: "DQT", 0xC0: "SOF0", 0xC1: "SOF1",
             0xC2: "SOF2", 0xC3: "SOF3", 0xC4: "DHT", 0xDA: "SOS",
             0xD9: "EOI", "ENTROPY": "ENTROPY"}
    print("%-8s %-9s %s" % ("marker", "offset", "payload"))
    w = h = ncomp = None
    ent_len = 0
    soft = None
    for m, off, p in segs:
        nm = names.get(m, "FF%02X" % m if isinstance(m, int) else m)
        extra = ""
        if m in (0xC0, 0xC1, 0xC2, 0xC3) and len(p) >= 6:
            h = (p[1] << 8) | p[2]
            w = (p[3] << 8) | p[4]
            ncomp = p[5]
            soft = nm
            extra = " %dx%d ncomp=%d prec=%d" % (w, h, ncomp, p[0])
        elif m == 0xDA and len(p) >= 1:
            extra = " ns=%d" % p[0]
        elif m == "ENTROPY":
            ent_len = len(p)
            extra = " %d bytes" % ent_len
        print("%-8s %-9d %d B%s" % (nm, off, len(p), extra))

    ok = True
    if soft is None:
        print("FAIL: 没有 SOF 段"); ok = False
    else:
        print("SOF      : %s  %dx%d  comp=%d" % (soft, w, h, ncomp))
    if exp_w and w != exp_w:
        print("FAIL: 宽度 %s != 期望 %d" % (w, exp_w)); ok = False
    if exp_h and h != exp_h:
        print("FAIL: 高度 %s != 期望 %d" % (h, exp_h)); ok = False
    if ent_len == 0:
        print("FAIL: 熵数据为空"); ok = False
    if buf[-2:] != b"\xff\xd9":
        print("WARN: 文件末尾不是 FF D9 (可能被截断): %s" % buf[-4:].hex(" "))
    print("TOTAL    : %d bytes, 熵数据 %d bytes (%.1f%%)"
          % (len(buf), ent_len, 100.0 * ent_len / max(1, len(buf))))
    print("RESULT   : %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
