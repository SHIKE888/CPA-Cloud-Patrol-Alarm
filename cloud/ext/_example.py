# -*- coding: utf-8 -*-
"""
扩展模块示例（文件名以下划线开头，不会被自动加载）

要真正启用：复制成 ext/gimbal.py 并实现 handle()，然后
    systemctl restart csi-dashboard

约定：
  INFO      给看板显示的名字和说明
  handle(payload, ctx) -> dict
      ctx["queue"](op, p)  往板端指令队列塞一条（和 /api/cmd 等价）
      ctx["state"]         服务端内存状态（只读用途）
      ctx["cfg"]           配置
"""

INFO = {
    "title": "云台控制（示例）",
    "desc": "把看板的按钮转发成板端 gimbal 指令；板端需先实现对应 op",
}


def handle(payload, ctx):
    op = (payload or {}).get("op")
    if op == "center":
        ctx["queue"]("gimbal", {"op": "center"})
        return {"ok": True, "queued": True}
    if op == "speed":
        yaw = float(payload.get("yaw") or 0)
        pitch = float(payload.get("pitch") or 0)
        ctx["queue"]("gimbal", {"op": "speed", "yaw": yaw, "pitch": pitch})
        return {"ok": True, "queued": True}
    return {"ok": False, "error": "unknown op"}
