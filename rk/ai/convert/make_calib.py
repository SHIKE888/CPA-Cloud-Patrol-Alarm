#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 RKNN 量化校准集：从 COCO val2017 拉取若干含人图片。

在 PC 上运行（需要外网），生成 calib.txt + calib/*.jpg，
再把这些文件传到转换机（VM）供 convert_rknn.py --dataset 使用。

用法：python make_calib.py --out ../models/calib --n 20
"""
import argparse
import os
import sys
import urllib.request

# COCO val2017 中常见的含人/多人图片 id（不足时会自动从候选池补足）
COCO_IDS = [
    139, 285, 632, 724, 776, 785, 802, 872, 885, 1000,
    1268, 1296, 1353, 1425, 1503, 1532, 1584, 1675, 1818, 1900,
    2189, 2310, 2412, 2500, 2612, 2731, 2851, 2950, 3067, 3134,
    3250, 3388, 3516, 3668, 3784, 3901, 4013, 4125, 4237, 4399,
]

URL = 'http://images.cocodataset.org/val2017/%012d.jpg'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='calib', help='输出目录')
    ap.add_argument('--n', type=int, default=20, help='需要的图片数量')
    ap.add_argument('--timeout', type=int, default=30)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    got = []
    for cid in COCO_IDS:
        if len(got) >= args.n:
            break
        name = '%012d.jpg' % cid
        dst = os.path.join(args.out, name)
        if not os.path.isfile(dst):
            try:
                urllib.request.urlretrieve(URL % cid, dst)
            except Exception as e:  # noqa: BLE001
                print('[skip] %s : %s' % (name, e))
                if os.path.isfile(dst):
                    os.remove(dst)
                continue
        sz = os.path.getsize(dst)
        if sz < 4096:
            os.remove(dst)
            continue
        got.append(dst)
        print('[ok] %s  %d bytes' % (name, sz))

    if len(got) < args.n:
        print('[warn] 仅取到 %d 张（需要 %d 张）' % (len(got), args.n))

    txt = os.path.join(args.out, 'calib.txt')
    with open(txt, 'w', encoding='utf-8') as f:
        for p in got:
            f.write(os.path.abspath(p) + '\n')
    print('dataset -> %s' % txt)
    if len(got) < 5:
        sys.exit('校准图片太少，退出')


if __name__ == '__main__':
    main()
