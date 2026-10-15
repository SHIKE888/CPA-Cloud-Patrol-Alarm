#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_preproc.py —— 校验预处理流水线仿真结果

用法: python tools/check_preproc.py <preproc_log.txt>

Phase A: 直接给 preproc_edge 灌合成窗口 -> 验 Sobel/阈值/形态学 的算法
Phase B: 图像流过 preproc_top -> 验窗口生成器的行缓冲对齐

Phase B 的延迟未知(取决于流水线级数), 所以对「输出序号 -> 输入字序号」的
偏移做一次扫描, 找出让全部样本自洽的那个偏移。
"""
import sys

# Windows 上控制台默认 GBK, 打印 ✗ 之类字符会 UnicodeEncodeError, 强制 UTF-8
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

NW = 16          # 每行字数 (H_ACTIVE=64 / 4)
NLINE = 32
SHIFT = 3        # sobel_shift
THRESH = 128


def b48(v):
    """48 位窗口 -> 6 个字节, [0] 最左"""
    return [(v >> (8 * i)) & 0xFF for i in range(6)]


def hx(s):
    """解析 16 进制字段; 含 x/z (仿真未初始化) 时返回 None

    帧首两行的 A/B 行取自还没被写过的行缓冲 RAM, 仿真里读到 X —— 这是正常的,
    功能上由 o_rowmask 屏蔽 (preproc_edge 会用当前行顶替)。校验器必须能容忍。
    """
    s = s.lower()
    if 'x' in s or 'z' in s:
        return None
    return int(s, 16)


def sobel(ba, bb, bc, j):
    a0, a1, a2 = ba[j], ba[j + 1], ba[j + 2]
    b0, b1, b2 = bb[j], bb[j + 1], bb[j + 2]
    c0, c1, c2 = bc[j], bc[j + 1], bc[j + 2]
    gx = (a2 + 2 * b2 + c2) - (a0 + 2 * b0 + c0)
    gy = (c0 + 2 * c1 + c2) - (a0 + 2 * a1 + a2)
    mag = abs(gx) + abs(gy)
    return min(255, mag >> SHIFT)


def binit(ba, bb, bc, j):
    a0, a1, a2 = ba[j], ba[j + 1], ba[j + 2]
    b0, b1, b2 = bb[j], bb[j + 1], bb[j + 2]
    c0, c1, c2 = bc[j], bc[j + 1], bc[j + 2]
    # 顺序必须与 RTL 里的位拼接一致
    return [(b0 >= THRESH), (a0 >= THRESH), (a1 >= THRESH), (a2 >= THRESH),
            (b2 >= THRESH), (c0 >= THRESH), (c1 >= THRESH), (c2 >= THRESH),
            (b1 >= THRESH)]


def lane(v, j):
    return (v >> (32 * j)) & 0xFFFFFFFF


def expect_lane(mode, ba, bb, bc, rgb, j):
    if mode == 0:
        return lane(rgb, j)
    if mode == 1:
        e = sobel(ba, bb, bc, j)
        return (e << 16) | (e << 8) | e
    if mode == 2:
        b = 0xFF if bc[j + 1] >= THRESH else 0x00
        return (b << 16) | (b << 8) | b
    if mode == 3:
        m = 0xFF if any(binit(ba, bb, bc, j)) else 0x00
        return (m << 16) | (m << 8) | m
    return 0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'preproc_log.txt'
    A_lines, B_lines = [], []
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for ln in f:
            p = ln.split()
            if not p:
                continue
            if p[0] == 'A':
                A_lines.append(p)
            elif p[0] == 'B':
                B_lines.append(p)

    print("=" * 72)
    print(" 预处理流水线校验   A样本 %d   B样本 %d" % (len(A_lines), len(B_lines)))
    print("=" * 72)

    # ------------------------------------------------------------ Phase A
    print("\n[Phase A] preproc_edge 算法校验")
    bad = 0
    per_mode = [0, 0, 0, 0]
    rgb = 0x00112233_00445566_00778899_00AABBCC
    for p in A_lines:
        n = int(p[1])
        wa, wbk, wc = int(p[2], 16), int(p[3], 16), int(p[4], 16)
        outs = [int(p[5 + i], 16) for i in range(4)]
        ba, bb, bc = b48(wa), b48(wbk), b48(wc)
        for mode in range(4):
            for j in range(4):
                got = lane(outs[mode], j)
                exp = expect_lane(mode, ba, bb, bc, rgb, j)
                if got != exp:
                    per_mode[mode] += 1
                    bad += 1
                    if bad <= 6:
                        print("  ✗ n=%d mode=%d px=%d  实测 %08X  期望 %08X"
                              % (n, mode, j, got, exp))
    total = len(A_lines) * 16
    print("  样本点 %d, 不符 %d" % (total, bad))
    for mode in range(4):
        nm = ["原图", "Sobel", "阈值", "形态学"][mode]
        print("    mode %d (%-6s): 不符 %d" % (mode, nm, per_mode[mode]))
    a_ok = (bad == 0)

    # ------------------------------------------------------------ Phase B
    print("\n[Phase B] preproc_top 窗口生成器校验 (行缓冲对齐)")
    if not B_lines:
        print("  !! 没有 Phase B 样本")
        return 1

    # 每个 B 样本: m tuser tlast rowmask winA winB winC rgb
    for tl in B_lines[:3]:
        print("    首样本: m=%s tuser=%s tlast=%s rowmask=%s winC=%s"
              % (tl[1], tl[2], tl[3], tl[4], tl[7]))

    # 尾部要留出余量: TB 停驱动后 RTL 的"前一/后一组"寄存器还是最后写入的
    # 残留值, 不属于模型可预测的范围。
    NLIM = NW * NLINE - 4

    # 扫偏移: 输出第 idx 个样本 <=> 输入字第 (idx + LAT)
    # ok 表示内层循环一直跑到 k>=NLIM 都没出现不符 —— 不能用 score 是否
    # 等于 NLIM 来判断, 因为内层会提前 break, 分数上限本来就小于 NLIM。
    best = None
    best_score = -1
    best_lat = 0
    for lat in range(0, 80):
        score = 0
        ok = True
        for idx, p in enumerate(B_lines):
            k = idx + lat
            if k >= NLIM:
                break
            wc = b48(int(p[7], 16))
            w = k & 0xFF
            rec = [0 if k == 0 else (k - 1) & 0xFF, w, w, w, w, (k + 1) & 0xFF]
            if wc == rec:
                score += 1
            else:
                ok = False
                break
        if ok and score > 0:
            best, best_score = lat, score
            break
        if score > best_score:
            best_score, best_lat = score, lat
    if best is None:
        print("  ✗ 找不到自洽的延迟偏移 —— 窗口生成器有问题")
        print("    最佳偏移 LAT=%d, 连续匹配 %d / %d" % (best_lat, best_score, NLIM))
        idx = best_score
        if idx < len(B_lines):
            p = B_lines[idx]
            k = idx + best_lat
            w = k & 0xFF
            rec = [0 if k == 0 else (k - 1) & 0xFF, w, w, w, w, (k + 1) & 0xFF]
            print("    首个不符: idx=%d k=%d" % (idx, k))
            print("      实测 winC %s" % b48(int(p[7], 16)))
            print("      期望 winC %s" % rec)
        print("    前 5 个样本的 winC:")
        for p in B_lines[:5]:
            print("      m=%s winC=%s" % (p[1], p[7]))
        return 1
    print("  OK 自洽偏移 LAT = %d  (输出序号 m 对应输入字 k = m + %d), 连续匹配 %d 个"
          % (best, best, best_score))

    # 用找到的偏移做全量校验
    badw = 0
    for idx, p in enumerate(B_lines):
        k = idx + best
        if k >= NLIM:
            break
        line = k // NW
        rm = int(p[4], 2)
        wa, wb2, wc = hx(p[5]), hx(p[6]), hx(p[7])
        if wc is None:
            continue
        bc = b48(wc)
        w = k & 0xFF
        # winC 全字节可预测
        rec = [0 if k == 0 else (k - 1) & 0xFF, w, w, w, w, (k + 1) & 0xFF]
        if bc != rec:
            badw += 1
            if badw <= 5:
                print("  ✗ k=%d winC 实测 %s 期望 %s" % (k, bc, rec))
        # winB: rowmask[1]=1 时应等于 (k-NW)
        if (rm & 2) and (wb2 is not None):
            bb2 = b48(wb2)
            wb_expect = (k - NW) & 0xFF
            if not all(x == wb_expect for x in bb2[1:5]):
                badw += 1
                if badw <= 5:
                    print("  ✗ k=%d winB 实测 %s 期望中间 4 字节=%02X"
                          % (k, bb2, wb_expect))
        # winA: rowmask[2]=1 时应等于 (k-2*NW)
        if (rm & 4) and (wa is not None):
            ba2 = b48(wa)
            wa_expect = (k - 2 * NW) & 0xFF
            if not all(x == wa_expect for x in ba2[1:5]):
                badw += 1
                if badw <= 5:
                    print("  ✗ k=%d winA 实测 %s 期望中间 4 字节=%02X"
                          % (k, ba2, wa_expect))
    print("  全量样本不符 %d" % badw)

    # Sobel 输出也应能对上 (用「有效行」)
    bads = 0
    bad_ks = []
    for idx, p in enumerate(B_lines):
        k = idx + best
        if k >= NLIM:
            break
        rm = int(p[4], 2)
        wa, wb2, wc, got = hx(p[5]), hx(p[6]), hx(p[7]), hx(p[8])
        if wc is None or got is None:
            continue
        bc = b48(wc)
        ea = b48(wa) if ((rm & 4) and (wa is not None)) else bc   # 无效行用当前行顶替
        eb = b48(wb2) if ((rm & 2) and (wb2 is not None)) else bc
        hit = False
        for j in range(4):
            e = sobel(ea, eb, bc, j)
            exp = (e << 16) | (e << 8) | e
            if lane(got, j) != exp:
                bads += 1
                hit = True
                if bads <= 5:
                    print("  ✗ k=%d (行 %d 列 %d) px=%d Sobel 实测 %08X 期望 %08X"
                          % (k, k // NW, k % NW, j, lane(got, j), exp))
        if hit:
            bad_ks.append(k)
    print("  Sobel 输出不符 %d" % bads)
    if bad_ks:
        print("  涉及的字: %s" % bad_ks[:40])
        k0 = bad_ks[0]
        idx0 = k0 - best
        p0 = B_lines[idx0]
        print("  首个失败样本 k=%d 的行号=%d 列号=%d rowmask=%s"
              % (k0, k0 // NW, k0 % NW, p0[4]))
        print("    winA=%s" % p0[5])
        print("    winB=%s" % p0[6])
        print("    winC=%s" % p0[7])

    print("\n" + "=" * 72)
    ok = a_ok and badw == 0 and bads == 0
    print(" 结论: %s" % ("**全部通过**" if ok else "**有失败项**"))
    print("=" * 72)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
