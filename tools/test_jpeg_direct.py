# -*- coding: utf-8 -*-
"""本地单元验证: mipi_webstream._jpeg_in_frame 的取帧逻辑 (不需要板子)。

覆盖 4 种真实会出现的情况:
  1. NV16 通路      -> 首字节不是 FFD8            => (False, None)
  2. 直通帧 + 补零  -> 前段 JPEG, 后面全 0        => 取到完整 JPEG
  3. 直通帧 + 残留  -> JPEG 后面是上一帧的像素     => 仍然只取到第一张
  4. 编码器半帧     -> 有 FFD8 没 FFD9            => (True, None) 计 direct_bad
"""
import numpy as np


def jpeg_in_frame(frame):
    """与 mipi_webstream.OpenCVCapture._jpeg_in_frame 完全一致。"""
    try:
        buf = frame.reshape(-1)
        if buf.size < 4 or buf[0] != 0xFF or buf[1] != 0xD8:
            return False, None
        b = buf.tobytes()
    except Exception:                                              # noqa: BLE001
        return False, None
    e = b.find(b"\xff\xd9", 2)
    if e < 1024:
        return True, None
    return True, b[:e + 2]


def pad(payload, total=4147200, tail=0):
    a = np.zeros(total, np.uint8)
    n = min(len(payload), total)
    a[:n] = np.frombuffer(payload[:n], np.uint8)
    if tail:
        a[n:n + min(tail, total - n)] = 0x5A
    return a.reshape(2160, 1920)


def main():
    jpeg = b"\xff\xd8" + bytes(range(256)) * 8 + b"\xff\xd9"   # 2048 B

    ok = True

    jf, j = jpeg_in_frame(pad(b"\x10\x20\x30\x40" * 10000))
    print("1) NV16 通路        -> (%s, %s)  期望 (False, None) %s"
          % (jf, j, "OK" if (jf, j) == (False, None) else "FAIL"))
    ok &= (jf, j) == (False, None)

    jf, j = jpeg_in_frame(pad(jpeg))
    print("2) 直通+补零        -> (%s, %d B) 期望 (True, %d B) %s"
          % (jf, len(j or b""), len(jpeg),
             "OK" if jf and j == jpeg else "FAIL"))
    ok &= jf and j == jpeg

    jf, j = jpeg_in_frame(pad(jpeg, tail=100000))
    print("3) 直通+残留        -> (%s, %d B) 期望 (True, %d B) %s"
          % (jf, len(j or b""), len(jpeg),
             "OK" if jf and j == jpeg else "FAIL"))
    ok &= jf and j == jpeg

    jf, j = jpeg_in_frame(pad(jpeg[:-2]))
    print("4) 编码器半帧       -> (%s, %s)  期望 (True, None) %s"
          % (jf, j, "OK" if (jf, j) == (True, None) else "FAIL"))
    ok &= (jf, j) == (True, None)

    # 5) 小到不像 JPEG 的尾部(只有 FFD8 + 几个字节)
    jf, j = jpeg_in_frame(pad(b"\xff\xd8" + b"\x01" * 100 + b"\xff\xd9"))
    print("5) 极小帧(300B)     -> (%s, %s)  期望 (True, None) %s"
          % (jf, j, "OK" if (jf, j) == (True, None) else "FAIL"))
    ok &= (jf, j) == (True, None)

    print("\n%s" % ("全部通过" if ok else "有失败项"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
