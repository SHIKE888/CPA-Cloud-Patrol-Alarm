# -*- coding: utf-8 -*-
"""给中继 80 端口那份「合并版」console.html 加「云台」页签。

background（踩过的坑，2026-10-28 起已结构性消失）：
  * `rk/relay/web/console.html` 把 `mipi_viewer.html` 整段并了进去，
    所以**只改 9012 的 mipi_viewer.html，用户打开 http://<板子>/ 看不到任何变化**。
  * 板上的 console.html 比仓库里的新（多了白平衡 / 反色 / 中值滤波等），
    整文件覆盖会把板上已有功能冲掉 —— 所以用"按锚点打补丁"。

★ 2026-10-28: 单页 `mipi_viewer.html` 已删除（留档在 git 提交 9323912），
  现在只有 `rk/relay/web/console.html` 一个页面，所以"两份不同步"这个坑已经不存在，
  正常情况直接改 console.html 即可。本脚本保留作为**历史工具 / 磁盘版与仓库版合并**用：
  默认从 console.html 自身抽取云台面板与 JS（锚点仍然有效），因此对已含云台页签的
  文件重跑是幂等的；要从旧文件恢复时用 --src 指定源。

幂等：检测到 `id="tab-gz"` 直接退出。
用法：
    python tools/patch_console_gimbal.py <console.html> [out.html]
    python tools/patch_console_gimbal.py --dry-run        # 只看抽取结果
    python tools/patch_console_gimbal.py --src <老页面> <console.html>
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.abspath(os.path.join(HERE, "..", "rk", "relay", "web",
                                      "console.html"))
for _i, _a in enumerate(sys.argv):
    if _a == "--src" and _i + 1 < len(sys.argv):
        VIEWER = os.path.abspath(sys.argv[_i + 1])
        del sys.argv[_i:_i + 2]
        break

CSS_OLD = """#viewVideo .hint{color:var(--dim); font-size:12px; margin:6px 0 0}
#viewVideo .kv{display:flex;justify-content:space-between;gap:8px}"""

CSS_NEW = """#viewVideo .hint{color:var(--dim); font-size:12px; margin:6px 0 0}
/* ---- 云台页签：方向键盘 ----
   长按方向键持续转，松手立即停。touch-action:none 必须写 —— 手机上
   不写会被当成长按选中/滚动，pointerup 收不到，云台就会一直转。 */
#viewVideo .gzpad{
  display:grid; grid-template-columns:repeat(3,1fr);
  grid-template-rows:repeat(3,46px); gap:8px; margin:8px 0 4px;
  max-width:264px; margin-left:auto; margin-right:auto;
  user-select:none; -webkit-user-select:none;
}
#viewVideo .gzbtn{
  font-size:19px; line-height:1; padding:0; touch-action:none;
  -webkit-tap-highlight-color:transparent; user-select:none;
}
#viewVideo .gzbtn[data-jog="up"]{grid-area:1/2}
#viewVideo .gzbtn[data-jog="left"]{grid-area:2/1}
#viewVideo .gzbtn[data-jog="right"]{grid-area:2/3}
#viewVideo .gzbtn[data-jog="down"]{grid-area:3/2}
#viewVideo #gzStop{grid-area:2/2; color:var(--warn)}
#viewVideo .gzbtn.act{background:var(--acc2); border-color:var(--acc2);
  color:#fff; font-weight:600}
#viewVideo #tab-gz .kv b{font-variant-numeric:tabular-nums; font-weight:600}
#viewVideo .kv{display:flex;justify-content:space-between;gap:8px}"""

TAB_OLD = """        <button class="tab" data-tab="ai">AI 标注</button>
      </div>"""

TAB_NEW = """        <button class="tab" data-tab="ai">标注</button>
        <button class="tab" data-tab="gz">云台</button>
      </div>"""

BODY_HEAD = "    <!-- ======== 云台（QGimbal）"
BODY_TAIL = "    <!-- ---------------- FPGA 通信状态"
BODY_OLD = """        <div class="scroll" id="aiEvents" style="max-height:140px;font-size:12px">
          <p class="hint">暂无</p>
        </div>
    </div>
"""

JS_HEAD = "/* ---------------- 云台（QGimbal）"
JS_TAIL = "/* ---------------- 状态轮询 ---------------- */"

LIST_OLD = """    ["cam", "pp", "sw", "ai"].forEach(t => {"""

LIST_NEW = """    if (b.dataset.tab !== "gz") gzReleaseAll();
    ["cam", "pp", "sw", "ai", "gz"].forEach(t => {"""

POLL_OLD = """  aiLoad(true);
  fpgaPoll();
  poll();"""

POLL_NEW = """  aiLoad(true);
  fpgaPoll();
  gzPoll();
  poll();"""

VIEW_OLD = """    } else {
      resize();          // canvas 在 hidden 时尺寸会变成 0，切回来必须重算
    }"""

VIEW_NEW = """    } else {
      // 离开视频视图：先把云台点动停住（按钮被隐藏后 pointerup 收不到）
      if (typeof window.relayGzStop === 'function') window.relayGzStop();
      resize();          // canvas 在 hidden 时尺寸会变成 0，切回来必须重算
    }"""


def extract(viewer_html):
    """从 mipi_viewer.html 抽出云台面板与云台 JS。"""
    i = viewer_html.find(BODY_HEAD)
    j = viewer_html.find(BODY_TAIL, i + 1)
    if i < 0 or j < 0 or j <= i:
        raise SystemExit("!! 在 mipi_viewer.html 里找不到云台面板的起止锚点")
    body = viewer_html[i:j].rstrip("\n") + "\n"

    a = viewer_html.find(JS_HEAD)
    b = viewer_html.find(JS_TAIL, a + 1)
    if a < 0 or b < 0 or b <= a:
        raise SystemExit("!! 在 mipi_viewer.html 里找不到云台脚本的起止锚点")
    js = viewer_html[a:b].rstrip("\n") + "\n\n"
    return body, js


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    viewer = io.open(VIEWER, "r", encoding="utf-8").read()
    body, js = extract(viewer)

    if dry:
        print("抽取自 %s" % os.path.basename(VIEWER))
        print("  面板 %d 行 / %d 字节（含 gz_speed=%s，滑块=%d 个）"
              % (body.count("\n"), len(body.encode("utf-8")),
                 "gz_speed" in body, body.count('type="range"')))
        print("  脚本 %d 行 / %d 字节（含 gzPoll=%s，卡尔曼 UI=%s）"
              % (js.count("\n"), len(js.encode("utf-8")),
                 "function gzPoll" in js, "gz_pred" in js))
        return 0

    if not args:
        print(__doc__)
        return 2
    src_path = args[0]
    out_path = args[1] if len(args) > 1 else src_path
    s = io.open(src_path, "r", encoding="utf-8").read()
    if 'id="tab-gz"' in s:
        print("already patched: %s" % src_path)
        return 0

    steps = [("css", CSS_OLD, CSS_NEW), ("tab", TAB_OLD, TAB_NEW),
             ("body", BODY_OLD, BODY_OLD + "\n" + body),
             ("list", LIST_OLD, LIST_NEW),
             ("poll", POLL_OLD, POLL_NEW), ("view", VIEW_OLD, VIEW_NEW),
             ("js", JS_TAIL, js + JS_TAIL)]
    for name, old, new in steps:
        if s.count(old) != 1:
            print("!! 锚点 %s 命中 %d 次（应为 1），已中止" % (name, s.count(old)))
            return 1
        s = s.replace(old, new, 1)
    io.open(out_path, "w", encoding="utf-8", newline="\n").write(s)
    print("patched: %s -> %s" % (src_path, out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
