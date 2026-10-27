# -*- coding: utf-8 -*-
"""把控制台页面里的 <script> 抽出来交给 node --check 做语法校验。

页面只有一份：rk/relay/web/console.html（2026-10-28 起 mipi_viewer.html 已移除）。
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = [
    os.path.join(HERE, "..", "rk", "relay", "web", "console.html"),
]

bad = 0
for src in TARGETS:
    html = io.open(src, "r", encoding="utf-8").read()
    blocks = re.findall(r"<script[^>]*>(.*?)</script>", html, re.S)
    print("%s: script blocks=%d" % (os.path.basename(src), len(blocks)))
    for i, js in enumerate(blocks):
        if not js.strip():
            continue
        p = os.path.join(HERE, "_chk_%d.js" % i)
        io.open(p, "w", encoding="utf-8").write(js)
        r = subprocess.run(["node", "--check", p], capture_output=True, text=True)
        print("  block %d: lines=%d %s" % (i, js.count("\n") + 1,
                                           "OK" if r.returncode == 0 else "FAIL"))
        if r.returncode != 0:
            bad += 1
            print(r.stderr[:2000])
        os.remove(p)
sys.exit(1 if bad else 0)
