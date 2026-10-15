#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_fpga_api.py —— 验证网页的 /api/fpga 接口 (在开发板上跑)

用法:  /opt/miniforge3/envs/mlk-ov/bin/python test_fpga_api.py [http://127.0.0.1:9012]

覆盖: 读 / 写 / 预设 / 越界夹取 / 未知寄存器报错 / 恢复。
"""
import json
import sys
import urllib.error
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9012"


def api(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read())


print("== 1) GET /api/fpga ==")
d = api("/api/fpga")
print("   ok      = %s" % d.get("ok"))
print("   regs    = %s" % d.get("regs"))
print("   status  = %s" % d.get("status"))
print("   可写寄存器 = %s" % [m["name"] for m in d.get("meta", {}).get("writable", [])])

print("\n== 2) POST 切到 Sobel + 阈值 100 ==")
d = api("/api/fpga", {"PP_EN": 1, "PP_MODE": 1, "PP_THRESH": 100})
print("   write_ok= %s  msg= %s" % (d.get("write_ok"), d.get("message")))
print("   回读    = %s" % d.get("regs"))

print("\n== 3) POST 预设 preset=morph ==")
d = api("/api/fpga", {"preset": "morph"})
print("   回读    = %s" % d.get("regs"))

print("\n== 4) POST 越界值 PP_THRESH=999 (应夹到 255) ==")
d = api("/api/fpga", {"PP_THRESH": 999})
print("   回读 PP_THRESH = %s" % d.get("regs", {}).get("PP_THRESH"))

print("\n== 5) POST 未知寄存器 (应报错) ==")
try:
    d = api("/api/fpga", {"NO_SUCH_REG": 1})
    print("   write_ok= %s  msg= %s" % (d.get("write_ok"), d.get("message")))
except urllib.error.HTTPError as e:
    body = json.loads(e.read())
    print("   HTTP %s (预期)  write_ok=%s  msg=%s"
          % (e.code, body.get("write_ok"), body.get("message")))

print("\n== 6) 恢复: 关闭预处理, 其余回默认 ==")
d = api("/api/fpga", {"PP_EN": 0, "PP_THRESH": 128,
                      "PP_SOBEL_SH": 3, "PP_MORPH": 1})
print("   回读    = %s" % d.get("regs"))
print("\n完成。")
