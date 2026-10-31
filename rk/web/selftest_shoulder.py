# -*- coding: utf-8 -*-
"""_shoulder_center 的场景校验（临时脚本，跑完可删）。"""
import sys

try:
    from ai_overlay import _shoulder_center
except Exception as e:                                   # noqa: BLE001
    print("导入失败: %s: %s" % (type(e).__name__, e))
    sys.exit(1)


def _rows(d):
    """{idx: (x, y, conf)} -> COCO-17 的 17 行 [[x,y,c], ...]"""
    a = []
    for i in range(17):
        if i in d:
            x, y, c = d[i]
            a.append([x, y, c])
        else:
            a.append([0.0, 0.0, 0.0])
    return a


BOX = [26, 162, 805, 538]            # 板上实测框（宽 779 高 376）


def case(name, rows, box, want_pair):
    p = _shoulder_center(rows, box)
    got = None if p is None else (round(p["pt"][0], 1), round(p["pt"][1], 1),
                                  p["pair"])
    print("  %-28s -> %s" % (name, got))
    return p


ok = True

# 1) 正常正面：头 y=200，两肩 y=260，髋 y=420 -> 两肩中点 (415, 260)
r1 = _rows({0: (415, 195, .9), 5: (378, 262, .8), 6: (452, 258, .8),
            11: (390, 420, .8), 12: (440, 420, .8)})
p = case("正常正面（两肩）", r1, BOX, True)
ok = ok and p is not None and p["pair"] is True and abs(p["pt"][1] - 260) < 3

# 2) 板上实测的坏样本：单肩被误检到大腿处 (611, 483)
r2 = _rows({0: (415, 195, .9), 5: (611, 483, .8),
            11: (390, 420, .8), 12: (440, 420, .8)})
p = case("误检：肩落在大腿处", r2, BOX, False)
ok = ok and p is None

# 3) 两肩都被误检到框底部（差得不多，成对但位置错）
r3 = _rows({0: (415, 195, .9), 5: (370, 500, .8), 6: (460, 505, .8),
            11: (390, 420, .8), 12: (440, 420, .8)})
p = case("误检：两肩都过低", r3, BOX, False)
ok = ok and p is None

# 4) 侧身：只看见一肩，位置正常
r4 = _rows({0: (415, 195, .9), 6: (452, 258, .8),
            11: (390, 420, .8), 12: (440, 420, .8)})
p = case("侧身（单肩，位置正常）", r4, BOX, False)
ok = ok and p is not None and p["pair"] is False and abs(p["pt"][1] - 258) < 3

# 5) 没有头/髋关键点，只有两肩（位置正常）-> 用 0.55 兜底上限
r5 = _rows({5: (378, 262, .8), 6: (452, 258, .8)})
p = case("无头无髋（两肩正常）", r5, BOX, True)
ok = ok and p is not None and p["pair"] is True

# 6) 没有头/髋，只有一肩且位置过低 -> 拒绝
r6 = _rows({5: (611, 483, .8)})
p = case("无头无髋（肩过低）", r6, BOX, False)
ok = ok and p is None

# 7) 两肩高度差离谱（一个被认成手肘）-> 绝不能用"两点中点"，
#    只能退回其中一条位置合理的那侧（pair=False）
r7 = _rows({0: (415, 195, .9), 5: (700, 262, .8), 6: (760, 430, .8)})
p = case("两肩高度差过大", r7, BOX, False)
ok = ok and (p is None or (p["pair"] is False and 195 < p["pt"][1] < 369))

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 2)
