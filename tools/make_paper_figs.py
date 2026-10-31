# -*- coding: utf-8 -*-
"""生成技术报告插图：图 2-1、图 2-11 ~ 图 2-15。

纯 matplotlib 矢量绘制；中文标注，不写英文函数名。
输出：docs/figs/*.png(200dpi) + *.svg + *.pdf

用法：python tools/make_paper_figs.py
"""
from __future__ import annotations

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "figs"
OUT.mkdir(parents=True, exist_ok=True)

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei",
                                   "Noto Sans CJK SC", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

# ---------------------------------------------------------------- 配色
SENS = ("#EAF3FB", "#3C7DBF")     # 感知/执行
FGP = ("#FFF2E2", "#D98A2B")      # FPGA 硬实时
RKI = ("#EAF7E4", "#4E9A3A")      # RK 智能层
BIZ = ("#F3EAFB", "#8358BE")      # 车载业务
ACT = ("#FDEDED", "#C0504D")      # 云台/异常
NEU = ("#F4F6F9", "#7C8794")      # 中性
CLD = ("#E9F4FF", "#2F6FA8")      # 云端
INK = "#232323"
SUB = "#3A3A3A"
GREY = "#4A5561"

LSP = 2.0      # 行距（数据单位）
EXT = []       # 已绘制内容的纵向范围，用于最后裁掉空白
LAST_H = 8.4


def _mark(y0, y1):
    EXT.append((float(y0), float(y1)))


def canvas(w=15.0, h=8.4):
    global LAST_H
    EXT.clear()
    LAST_H = h
    fig = plt.figure(figsize=(w, h), facecolor="white")
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.axis("off")
    return fig, ax


def box_h(body) -> float:
    return (4.7 + LSP * len(body)) if body else 3.7


def box(ax, x, y, w, h, title, body=(), fc=NEU, ec=NEU, fs_t=9.4, fs_b=8.2,
        bold=True, lw=1.2, z=3):
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.9",
                       linewidth=lw, edgecolor=ec[1], facecolor=fc[0], zorder=z)
    ax.add_patch(p)
    n = 1 + len(body)
    y0 = y + h / 2.0 + (n - 1) * LSP / 2.0
    ax.text(x + w / 2.0, y0, title, ha="center", va="center", fontsize=fs_t,
            color=INK, fontweight="bold" if bold else "normal", zorder=z + 1)
    for i, t in enumerate(body, start=1):
        ax.text(x + w / 2.0, y0 - i * LSP, t, ha="center", va="center",
                fontsize=fs_b, color=SUB, zorder=z + 1)
    _mark(y, y + h)
    return (x, y, w, h)


def col_fill(ax, x, w, ytop, ybottom, items, min_gap=1.4, max_gap=7.5, **kw):
    """自上而下堆叠；用可调间距把整列压到同一底边。"""
    hs = [it.get("h") or box_h(it.get("b", ())) for it in items]
    n = len(items)
    gap = (ytop - ybottom - sum(hs)) / (n - 1) if n > 1 else 0.0
    gap = max(min_gap, min(max_gap, gap)) if n > 1 else 0.0
    y = ytop
    rects = []
    for it, h in zip(items, hs):
        y -= h
        rects.append(box(ax, x, y, w, h, it["t"], it.get("b", ()),
                         fc=it.get("fc", kw.get("fc", NEU)),
                         ec=it.get("ec", kw.get("ec", NEU)),
                         fs_t=kw.get("fs_t", 9.4), fs_b=kw.get("fs_b", 8.2),
                         lw=kw.get("lw", 1.2)))
        y -= gap
    return rects


def mid(r):
    return (r[0] + r[2] / 2.0, r[1] + r[3] / 2.0)


def arrow(ax, pts, dashed=False, color=GREY, lw=1.25, head=7.5, z=2):
    pts = [tuple(map(float, p)) for p in pts]
    style = (0, (4.5, 2.8)) if dashed else "-"
    for a, b in zip(pts[:-2], pts[1:-1]):
        ax.plot([a[0], b[0]], [a[1], b[1]], color=color, lw=lw, ls=style,
                solid_capstyle="round", zorder=z)
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=head, linewidth=lw, color=color,
                                 shrinkA=0, shrinkB=0, linestyle=style, zorder=z))


def tag(ax, x, y, s, fs=7.6, color=GREY, rot=0, ha="center", va="center"):
    ax.text(x, y, s, ha=ha, va=va, rotation=rot, fontsize=fs, color=color,
            zorder=6,
            bbox=dict(facecolor="white", edgecolor="none", pad=1.2, alpha=0.95))
    _mark(y - 2.4, y + 2.4)


def note(ax, x, y, w, lines, fs=8.3, fc="#FFFCF2", ec="#C9A227"):
    h = 3.0 + LSP * len(lines)
    ax.add_patch(FancyBboxPatch((x, y - h), w, h,
                                boxstyle="round,pad=0,rounding_size=0.8",
                                linewidth=1.0, edgecolor=ec, facecolor=fc, zorder=3))
    y0 = y - 1.6 - LSP / 2.0
    for i, t in enumerate(lines):
        ax.text(x + 1.5, y0 - i * LSP, t, ha="left", va="center", fontsize=fs,
                color=SUB, zorder=4)
    _mark(y - h, y)
    return y - h


def title(ax, s, y=97.5):
    ax.text(50, y, s, ha="center", va="center", fontsize=12.6,
            fontweight="bold", color="#111111")
    _mark(y - 2.6, y + 2.6)


def save(fig, name):
    ax = fig.axes[0]
    lo = min(a for a, _ in EXT)
    hi = max(b for _, b in EXT)
    pad = 2.2
    ax.set_ylim(lo - pad, hi + pad)
    win = (hi - lo + 2 * pad) / 100.0
    fig.set_size_inches(fig.get_size_inches()[0], LAST_H * win)
    for ext in ("png", "svg", "pdf"):
        fig.savefig(OUT / f"{name}.{ext}", dpi=200, facecolor="white",
                    bbox_inches="tight", pad_inches=0.12)
    plt.close(fig)
    print("saved", name)


# ================================================================ 图 2-1
def fig_2_1():
    fig, ax = canvas(15.4, 8.0)
    title(ax, "图 2-1  系统整体框图", 97.6)

    # ---------------- 云端层
    ax.text(2, 94.6, "云端管理平台（跨公网 · 3 Mbit/s 上行）", fontsize=9.6,
            color=CLD[1], fontweight="bold", ha="left", va="center")
    r1 = [box(ax, x, 83.5, 27.0, 9.4, t, b, fc=CLD, ec=CLD) for x, t, b in [
        (2.0, "状态看板与报警灯", ("实时状态 · 分级告警灯",)),
        (32.3, "报警落库与事件回放", ("数据库 · 图片与视频滚动",)),
        (62.6, "远程调参与指令队列", ("白名单裁剪 · 结果回执",)),
    ]]
    for i in range(2):
        arrow(ax, [(r1[i][0] + 27.0, mid(r1[i])[1]), (r1[i + 1][0], mid(r1[i + 1])[1])])

    # ---------------- 车载层
    ax.text(2, 79.4, "车载协处理（ROS · 局域网）", fontsize=9.6, color=BIZ[1],
            fontweight="bold", ha="left", va="center")
    r2 = [box(ax, x, 66.6, 12.6, 10.4, t, b, fc=BIZ, ec=BIZ) for x, t, b in [
        (2.0, "激光定位与建图", ("栅格地图", "位姿估计")),
        (16.6, "路径规划与避障", ("代价地图", "局部避让")),
        (31.2, "定点巡航调度", ("按序到点", "停留巡视")),
        (45.8, "局域网数据中继", ("网页遥控", "状态转发")),
    ]]
    for i in range(3):
        arrow(ax, [(r2[i][0] + 12.6, mid(r2[i])[1]), (r2[i + 1][0], mid(r2[i + 1])[1])])

    # ---------------- RK 智能层
    ax.text(2, 60.6, "瑞芯微 RK3576J 非实时智能层", fontsize=9.6, color=RKI[1],
            fontweight="bold", ha="left", va="center")
    r3 = [box(ax, x, 43.6, 12.6, 13.8, t, b, fc=RKI, ec=RKI) for x, t, b in [
        (2.0, "码流接收与直通", ("按帧头帧尾定界", "不解码不重编码")),
        (16.6, "两级视觉推理", ("人体检测", "姿态关键点")),
        (31.2, "动作与风险判定", ("骨架分类", "围栏越界")),
        (45.8, "二维云台闭环", ("预测超前", "双层限幅")),
    ]]
    for i in range(3):
        arrow(ax, [(r3[i][0] + 12.6, mid(r3[i])[1]), (r3[i + 1][0], mid(r3[i + 1])[1])])
    box(ax, 74.0, 45.0, 24.0, 12.4, "云端代理",
        ("心跳遥测 · 事件上行", "指令长轮询取回"), fc=RKI, ec=RKI)

    # ---------------- FPGA 硬实时层
    ax.text(2, 34.6, "安路 PH1A90 硬实时层（单一时钟域 73.75 MHz）", fontsize=9.6,
            color=FGP[1], fontweight="bold", ha="left", va="center")
    r4 = [box(ax, x, 14.0, 10.6, 17.0, t, b, fc=FGP, ec=FGP, fs_t=9.0, fs_b=7.9)
          for x, t, b in [
              (2.0, "双路差分接收", ("采样窗口训练", "包头校验")),
              (14.3, "双目同步拼接", ("同拍复位", "行级缓冲")),
              (26.6, "图像增强", ("黑电平 · 白平衡", "去马赛克 · 伽马")),
              (38.9, "硬件预处理", ("灰度 · 高斯", "边缘 · 形态学")),
              (51.2, "硬件压缩与发送", ("四引擎并行", "分段合并 · 组包")),
          ]]
    for i in range(4):
        arrow(ax, [(r4[i][0] + 10.6, mid(r4[i])[1]), (r4[i + 1][0], mid(r4[i + 1])[1])])

    # ---------------- 感知与执行
    ax.text(2, 11.4, "感知与执行", fontsize=9.6, color=SENS[1], fontweight="bold",
            ha="left", va="center")
    box(ax, 2.0, 1.6, 54.0, 8.6, "输入：双目图像传感器、编码器与激光雷达",
        ("2×IMX415 · 1080p60 · 10 位原始数据；编码器与二维激光雷达提供定位输入",),
        fc=SENS, ec=SENS, fs_b=8.0)
    box(ax, 66.0, 1.6, 32.0, 8.6, "输出：二轴增稳云台、底盘驱动",
        ("云台经串口接收绝对角指令；底盘经局域网接收速度与导航目标",),
        fc=ACT, ec=ACT, fs_b=8.0)

    # ---------------- 跨层连线
    arrow(ax, [(7.3, 10.2), (7.3, 14.0)])
    tag(ax, 11.0, 12.1, "四通道差分 ×2", fs=7.4, ha="left")

    arrow(ax, [(56.5, 31.0), (56.5, 36.5), (8.3, 36.5), (8.3, 43.6)])
    tag(ax, 33.0, 36.5, "压缩码流（MIPI 四通道，仅传输 JPEG 码流）", fs=7.6)

    arrow(ax, [(44.8, 66.6), (44.8, 57.4)], dashed=True)
    tag(ax, 44.8, 62.0, "局域网", fs=7.4, rot=90)

    arrow(ax, [(58.4, mid(r3[3])[1]), (63.5, mid(r3[3])[1]),
               (63.5, 5.9), (66.0, 5.9)])
    tag(ax, 63.5, 26.0, "云台绝对角指令（串口）", fs=7.4, rot=90)

    arrow(ax, [(86.0, 57.4), (86.0, 83.5)])
    tag(ax, 86.0, 70.5, "加密上行：心跳 / 报警 / 指令回执", fs=7.4, rot=90)
    return fig


# ================================================================ 图 2-11
def fig_2_11():
    fig, ax = canvas(15.4, 8.0)
    title(ax, "图 2-11  视频采集流程", 97.2)

    heads = ["① 采集前端", "② 同步与拼接", "③ 增强与预处理", "④ 帧缓存与压缩", "⑤ 传输接口"]
    w, step = 16.4, 20.0
    xs = [2.0 + i * step for i in range(5)]

    c1 = col_fill(ax, xs[0], w, 92.0, 54.0, [
        dict(t="双目传感器输出", b=("1080p60 · 四通道", "差分串行 ×2"), fc=SENS, ec=SENS),
        dict(t="差分接收与对齐", b=("采样窗口训练", "字节对齐")),
        dict(t="包头校验与还原", b=("纠错校验", "10 位像素还原")),
        dict(t="水平裁剪", b=("每目裁至 1920",)),
        dict(t="按行节拍送出", b=()),
    ], fc=FGP, ec=FGP, fs_b=8.0)
    c2 = col_fill(ax, xs[1], w, 92.0, 54.0, [
        dict(t="同拍复位与稳定窗", b=("同时释放复位", "20 ms 稳定窗")),
        dict(t="初始化表同拍重发", b=("两颗传感器同一起点",)),
        dict(t="环形行缓冲调度", b=("左目写入 · 滞后约 2 行", "饥饿补黑不断流")),
        dict(t="左右拼接", b=("3840×1080", "4 像素/拍 · 73.75 MHz")),
    ], fc=FGP, ec=FGP, fs_b=8.0)
    c3 = col_fill(ax, xs[2], w, 92.0, 54.0, [
        dict(t="黑电平校正", b=()),
        dict(t="自动白平衡", b=()),
        dict(t="去马赛克", b=()),
        dict(t="亮度 / 对比度 / 饱和度", b=()),
        dict(t="伽马校正", b=()),
        dict(t="可编程算子级联", b=("灰度·高斯·直方图均衡", "边缘·阈值·形态学·中值")),
    ], fc=FGP, ec=FGP, fs_b=8.0)
    c4 = col_fill(ax, xs[3], w, 92.0, 54.0, [
        dict(t="色彩空间转换", b=("转 YUV422 4:2:2",)),
        dict(t="写入帧缓存乒乓", b=("吸收 0.26% 帧率微差",)),
        dict(t="固定节拍读出", b=("32 位转 64 位",)),
        dict(t="四路并行压缩", b=("每路 960×1080", "每 60 宏块一段")),
        dict(t="按段号交错合并", b=("单幅完整码流",)),
    ], fc=FGP, ec=FGP, fs_b=8.0)
    c5 = col_fill(ax, xs[4], w, 92.0, 54.0, [
        dict(t="跨时钟字节桥", b=("73.75 → 125 MHz",)),
        dict(t="变长帧组包", b=("借用 YUV422 数据类型",)),
        dict(t="高速差分发送", b=("四通道 × 1 Gbps",)),
        dict(t="接收端定界取帧", b=("扫描帧头帧尾",)),
        dict(t="交智能层使用", b=("直通推流 · 推理",)),
    ], fc=FGP, ec=FGP, fs_b=8.0)

    for x, hd in zip(xs, heads):
        ax.text(x + w / 2.0, 93.4, hd, ha="center", va="center", fontsize=9.6,
                color=FGP[1], fontweight="bold")

    chain = [c1, c2, c3, c4, c5]
    labels = ["原始双目数据", "拼接帧", "增强后图像", "单幅压缩码流"]
    for i in range(4):
        ysrc = mid(chain[i][-1])[1]
        ydst = mid(chain[i + 1][0])[1]
        x0 = xs[i] + w
        xc = x0 + (step - w) / 2.0
        arrow(ax, [(x0, ysrc), (xc, ysrc), (xc, ydst), (xs[i + 1], ydst)])
        tag(ax, xc, (ysrc + ydst) / 2.0, labels[i], fs=7.5, rot=90)

    note(ax, 2.0, min(r[1] for r in c1 + c2 + c3 + c4 + c5) - 1.6, 96.4, [
        "关键约束：拼接、增强、预处理、压缩全部收敛在同一 73.75 MHz 时钟域，4 像素／拍即 295 M 像素／秒，"
        "相对 248.8 M 像素／秒的需求留出 18.6% 余量；",
        "全链只有 3 处真实跨时钟域（两路恢复时钟→像素域、缓存读出→像素域、像素域→发送域）；"
        "压缩后码率约 72 Mbit/s（约 55:1），链路占用不足 10%。",
    ])
    return fig


# ================================================================ 图 2-12
def fig_2_12():
    fig, ax = canvas(15.0, 8.0)
    title(ax, "图 2-12  检测、姿态与动作判定流程", 97.2)

    heads = ["① 取帧与检测", "② 姿态与可靠性约束", "③ 序列建模", "④ 判定与输出"]
    w, step = 21.4, 25.0
    xs = [2.0 + i * step for i in range(4)]

    c1 = col_fill(ax, xs[0], w, 92.0, 40.0, [
        dict(t="取最新一帧", b=("限制推理频率", "不阻塞视频通路")),
        dict(t="整幅缩放后检测", b=("640×640 · 8 位量化",)),
        dict(t="输出人体框", b=("位置与置信度",)),
        dict(t="框级跟踪编号", b=("跨帧保持同一编号",)),
    ], fc=RKI, ec=RKI)
    c2 = col_fill(ax, xs[1], w, 92.0, 40.0, [
        dict(t="按框裁剪送姿态网络", b=("单人单框",)),
        dict(t="输出 17 个关键点", b=("肩肘腕髋膝踝等",)),
        dict(t="关节合理性约束", b=("超出门限的点直接剔除", "消除飘到画外的鬼点")),
        dict(t="跳帧复用与位移补偿", b=("检测帧跳过姿态", "姿态帧跳过检测")),
    ], fc=RKI, ec=RKI)
    c3 = col_fill(ax, xs[2], w, 92.0, 40.0, [
        dict(t="骨架平滑", b=("指数滑动平均",)),
        dict(t="序列缓冲与重采样", b=("等间隔取 32 帧",)),
        dict(t="归一化", b=("髋中心平移", "按骨段长度缩放")),
        dict(t="轻量骨架分类", b=("11 类动作", "单人耗时不足 1 ms")),
    ], fc=RKI, ec=RKI)
    c4 = col_fill(ax, xs[3], w, 92.0, 40.0, [
        dict(t="围栏越界判定", b=("多边形几何计算",)),
        dict(t="置信度与时长滞回", b=("同一回合只报一次",)),
        dict(t="分级风险", b=("正常 / 预警 / 报警",)),
        dict(t="叠加显示与事件上报", b=("网页叠加 · 云端推送",)),
    ], fc=ACT, ec=ACT)

    for x, hd in zip(xs, heads):
        ax.text(x + w / 2.0, 93.4, hd, ha="center", va="center", fontsize=9.6,
                color=RKI[1], fontweight="bold")

    chain = [c1, c2, c3, c4]
    labels = ["人体框", "关键点序列", "动作类别"]
    for i in range(3):
        ysrc = mid(chain[i][-1])[1]
        ydst = mid(chain[i + 1][0])[1]
        x0 = xs[i] + w
        xc = x0 + (step - w) / 2.0
        arrow(ax, [(x0, ysrc), (xc, ysrc), (xc, ydst), (xs[i + 1], ydst)])
        tag(ax, xc, (ysrc + ydst) / 2.0, labels[i], fs=7.5, rot=90)

    note(ax, 2.0, min(r[1] for r in c1 + c2 + c3 + c4) - 1.6, 96.0, [
        "调度策略：检测与姿态交替执行（各自跳帧），逐人姿态预算默认 2 人，其余按框位移平移复用；推理绑定 NPU 双核，前处理独立线程与推理重叠；",
        "实测：一级检测 17 ms，逐人姿态 22~26 ms；无人 50 帧／秒、单人 36 帧／秒、四人 26.7 帧／秒，视频通路稳定 59 帧／秒不受影响；",
        "兜底：骨架分类模型不可用时自动退回几何规则判定；越界告警始终由几何规则独立输出，不受模型影响。",
    ])
    return fig


# ================================================================ 图 2-13
def fig_2_13():
    fig, ax = canvas(15.0, 8.0)
    title(ax, "图 2-13  云台预测、限幅与反馈流程", 97.2)

    left = col_fill(ax, 4.0, 38.0, 92.0, 40.0, [
        dict(t="目标框中心像素", b=("取当前跟踪目标",)),
        dict(t="归一化偏差", b=("横向与俯仰两个方向",)),
        dict(t="期望角速度", b=("误差小于死区不出力", "误差达 0.35 倍半宽给满速")),
        dict(t="卡尔曼滤波（两轴）", b=("状态为位置 + 速度", "抑制框抖动引起的顿挫")),
        dict(t="时延超前预测", b=("按处理时延前推 0.15 s",)),
        dict(t="目标角积分", b=("上一拍目标 + 速度 × 周期",)),
        dict(t="双层限幅取交集", b=("绝对层：固件关节角 ±170°、俯仰 −1°", "相对层：软件零点 ±170° / ±42°")),
    ], fc=NEU, ec=NEU, fs_b=8.1)
    for i in range(len(left) - 1):
        arrow(ax, [(mid(left[i])[0], left[i][1]),
                   (mid(left[i + 1])[0], left[i + 1][1] + left[i + 1][3])])

    right = col_fill(ax, 60.0, 36.0, 92.0, 40.0, [
        dict(t="软限位刹车", b=("按速度平方除以两倍加速度预留刹车距离", "提前收速，不撞限位")),
        dict(t="加速度斜坡", b=("速度连续变化，起步不顿挫",)),
        dict(t="指令下发", b=("只发绝对角度与限速速度", "串口唯一写者，115200")),
        dict(t="固件执行并回读", b=("关节角与角速度实时回读",)),
        dict(t="状态保护", b=("堵转保护：超前超 12° 不再加码", "固件拒绝即回滚；0.8 s 未续令归零")),
    ], fc=ACT, ec=ACT, fs_b=8.1)
    for i in range(len(right) - 1):
        arrow(ax, [(mid(right[i])[0], right[i][1]),
                   (mid(right[i + 1])[0], right[i + 1][1] + right[i + 1][3])])

    # 限幅结果 -> 刹车
    arrow(ax, [(42.0, mid(left[-1])[1]), (51.0, mid(left[-1])[1]),
               (51.0, mid(right[0])[1]), (60.0, mid(right[0])[1])])
    tag(ax, 51.0, (mid(left[-1])[1] + mid(right[0])[1]) / 2.0, "已限幅目标",
        fs=7.5, rot=90)

    # 反馈闭环
    ysrc, ydst = mid(right[-1])[1], mid(left[3])[1]
    arrow(ax, [(60.0, ysrc), (54.5, ysrc), (54.5, ydst), (42.0, ydst)], dashed=True)
    tag(ax, 54.5, (ysrc + ydst) / 2.0 - 8.0, "实测角度与速度反馈", fs=7.5, rot=90,
        color="#7A4A4A")

    ynote = min(left[-1][1], right[-1][1]) - 2.0
    note(ax, 4.0, ynote, 92.0, [
        "安全约束：只发绝对角度、永不下发速度模式；两层限幅取交集，软件零点设歪也不会多转半圈；",
        "点动 0.8 s 未续令即归零，页面失焦或隐藏时主动发零；即使上位机进程被杀，云台也只停在最后一个已限幅目标上。",
    ])
    return fig


# ================================================================ 图 2-14
def fig_2_14():
    fig, ax = canvas(15.0, 7.6)
    title(ax, "图 2-14  巡航状态转移及云台联动", 97.0)

    w, step = 14.8, 19.8
    xs = [2.0 + i * step for i in range(5)]
    names = ["待机", "前往第 i 个点", "到达与停稳确认", "停留 + 云台巡视", "收尾"]
    subs = [("未开始巡航",), ("按顺序下发导航目标",),
            ("进入容差后等车真正停稳",), ("倒计时并左右扫视",),
            ("下一点 / 循环 / 完成",)]
    rects = []
    for i, (t, s) in enumerate(zip(names, subs)):
        fc = RKI if i < 4 else BIZ
        rects.append(box(ax, xs[i], 76.0, w, 10.4, t, s, fc=fc, ec=fc, fs_t=9.2))

    cl = ["开始巡航", "进入容差", "已停稳", "倒计时结束"]
    for i in range(4):
        y = mid(rects[i])[1]
        arrow(ax, [(xs[i] + w, y), (xs[i + 1], y)])
        tag(ax, (xs[i] + w + xs[i + 1]) / 2.0, y + 1.9, cl[i], fs=7.4)

    arrow(ax, [(xs[4] + w / 2.0, 86.4), (xs[4] + w / 2.0, 89.8),
               (xs[1] + w / 2.0, 89.8), (xs[1] + w / 2.0, 86.4)], dashed=True)
    tag(ax, (xs[1] + xs[4]) / 2.0 + w / 2.0, 89.8,
        "循环巡航：跑完最后一点回到第 1 点", fs=7.4, color="#6B4C9A")

    ax.text(30.0, 66.4, "云台联动（仅在停留期间）", ha="left", va="center",
            fontsize=9.4, color=ACT[1], fontweight="bold")
    box(ax, 56.0, 52.0, w, 10.4, "巡视",
        ("左右扫视，按软限位自动换向",), fc=ACT, ec=ACT, fs_t=9.2)
    box(ax, 80.0, 52.0, w, 10.4, "追踪",
        ("锁定目标 N 秒（默认 10 秒）",), fc=ACT, ec=ACT, fs_t=9.2)
    arrow(ax, [(56.0 + w, 57.2), (80.0, 57.2)])
    tag(ax, 75.4, 57.2, "检测到人员", fs=7.3, color="#7A4A4A")
    arrow(ax, [(80.0, 55.0), (56.0 + w, 55.0)])
    tag(ax, 75.4, 55.0, "到时继续巡视", fs=7.3, color="#7A4A4A")

    arrow(ax, [(mid(rects[3])[0], 76.0), (mid(rects[3])[0], 62.4)], dashed=True)
    tag(ax, mid(rects[3])[0] - 1.0, 69.0, "停稳即启动", fs=7.4, ha="right",
        color="#7A4A4A")

    note(ax, 2.0, 47.0, 96.0, [
        "① 超时分支：单个点 3 分钟仍未到达，自动跳过该点，继续下一个；",
        "② 中止分支：点「停止全部」立即停发导航目标、结束巡航，并令云台回正；",
        "③ 重启动分支：重新建图会清空当前地图上的巡航点并中止巡航，避免在旧坐标上误跑；",
        "④ 到位处理：一进入容差就取消导航目标，避免车辆在容差内反复微调、静不下来；",
        "⑤ 循环开关：开启后跑完最后一点自动回到第 1 点，直到手动「停止全部」。",
    ], fc="#FFF8F6", ec="#C0504D")
    return fig


# ================================================================ 图 2-15
def fig_2_15():
    fig, ax = canvas(15.4, 8.0)
    title(ax, "图 2-15  云端事件上传与指令回执流程", 97.2)

    ax.text(2.0, 93.2, "① 上行：事件与状态（板端 → 云端）", ha="left", va="center",
            fontsize=9.4, color=CLD[1], fontweight="bold")
    w, step = 13.8, 15.7
    xs = [2.0 + i * step for i in range(6)]
    up = []
    t_up = ["事件产生", "回合去抖与合并", "抓拍与短视频截取", "心跳与遥测上报",
            "鉴权校验与落库", "看板与报警灯"]
    b_up = [("分级告警", "跌倒/攀爬/越界"), ("同一回合只报一次", "六秒窗口内合并"),
            ("抓拍约 25 KB", "视频默认十秒"), ("每三至五秒一次", "仅压缩小报文"),
            ("令牌校验", "数据库与文件滚动"), ("实时状态", "报警灯与历史检索")]
    for i in range(6):
        fc = RKI if i < 4 else CLD
        up.append(box(ax, xs[i], 78.0, w, 12.4, t_up[i], b_up[i], fc=fc, ec=fc,
                      fs_t=9.0, fs_b=7.9))
    for i in range(5):
        arrow(ax, [(xs[i] + w, mid(up[i])[1]), (xs[i + 1], mid(up[i + 1])[1])])

    ax.plot([63.2, 63.2], [76.0, 92.0], ls=(0, (5, 3)), color="#AEB7C2",
            lw=1.0, zorder=1)
    tag(ax, 63.2, 92.9, "板端 ┃ 云端", fs=7.2, color="#8792A0")

    ax.text(2.0, 72.4, "② 下行：指令与回执（云端 → 板端）", ha="left", va="center",
            fontsize=9.4, color=BIZ[1], fontweight="bold")
    w2, step2 = 17.0, 19.2
    xd = [2.0 + i * step2 for i in range(5)]
    t_dn = ["本地执行", "板端长轮询取指令", "指令入队", "白名单与范围裁剪", "值班人员确认或下发"]
    b_dn = [("参数/寄存器/推理/云台/抓图",), ("空闲挂起至 25 秒", "板端主动连出"),
            ("每条指令带序号",), ("越界值先裁到合法区间",), ("单条确认或全部确认",)]
    dn = []
    for i in range(5):
        fc = RKI if i < 2 else (CLD if i == 4 else BIZ)
        dn.append(box(ax, xd[i], 56.0, w2, 11.4, t_dn[i], b_dn[i], fc=fc, ec=fc,
                      fs_t=9.0, fs_b=7.9))
    for i in range(4, 0, -1):
        arrow(ax, [(xd[i], mid(dn[i])[1]), (xd[i - 1] + w2, mid(dn[i - 1])[1])])

    w3, step3 = 27.0, 33.0
    xe = [2.0 + i * step3 for i in range(3)]
    t_rp = ["执行结果回传", "队列出栈并记录", "页面回执提示"]
    b_rp = [("成功 / 失败与提示信息",), ("最近二十条结果留档",),
            ("操作者看到生效或失败原因",)]
    rp = []
    for i in range(3):
        fc = RKI if i == 0 else CLD
        rp.append(box(ax, xe[i], 38.0, w3, 10.6, t_rp[i], b_rp[i], fc=fc, ec=fc,
                      fs_t=9.0, fs_b=7.9))
    arrow(ax, [(mid(dn[0])[0], 56.0), (mid(dn[0])[0], 48.6)])
    for i in range(2):
        arrow(ax, [(xe[i] + w3, mid(rp[i])[1]), (xe[i + 1], mid(rp[i + 1])[1])])

    arrow(ax, [(xe[2] + w3, mid(rp[2])[1]), (97.4, mid(rp[2])[1]),
               (97.4, mid(up[5])[1]), (xs[5] + w, mid(up[5])[1])], dashed=True)
    tag(ax, 97.4, 64.0, "状态刷新", fs=7.2, rot=90, color="#8792A0")

    note(ax, 2.0, 34.0, 95.6, [
        "链路开销：全链路按 3 Mbit/s 上行预算设计——心跳约 0.9 KB／5 秒（约 16 MB／天），报警抓拍 23~30 KB／张，事件视频按总量滚动清理；",
        "去抖与限流：同一标签 6 秒内未确认即合并成同一条并累加次数；每分钟最多上报 20 条，超出丢弃并计数；",
        "健康状态：系统异常按“首次发生记一条、恢复后标记已恢复”处理，心跳携带刚恢复的条目，避免重复刷屏；",
        "下行安全：板端没有公网地址，全部指令由板端主动长轮询取走；云端先做白名单与范围裁剪，板端再裁一次。",
    ])
    return fig


NAMES = {fig_2_1: "fig2-1_system", fig_2_11: "fig2-11_capture",
         fig_2_12: "fig2-12_action", fig_2_13: "fig2-13_gimbal",
         fig_2_14: "fig2-14_patrol", fig_2_15: "fig2-15_cloud"}


def main():
    for fn in (fig_2_1, fig_2_11, fig_2_12, fig_2_13, fig_2_14, fig_2_15):
        save(fn(), NAMES[fn])


if __name__ == "__main__":
    main()
