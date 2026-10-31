#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""云端 MySQL 自检 —— 确认事件/视频是不是真的落在数据库里。

在服务器上直接跑（不需要停服务）：

    python3 cloud/tools/db_check.py                       # 默认读 /opt/csi-dashboard/config.json
    python3 cloud/tools/db_check.py /opt/csi-dashboard/config.json

会打印：表行数、报警来源分布、最近 5 条、视频条数与占用、meta 设置。
"""
import json
import os
import sys
import time

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    sys.exit("需要 pymysql：apt install -y python3-pymysql")

CFG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/csi-dashboard/config.json"
CLIP_DIR = "/opt/csi-dashboard/data/clips"


def human(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return "%.1f %s" % (n, u)
        n /= 1024.0


def load_cfg():
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    cfg = load_cfg()
    pw = cfg.get("db_pass") or os.environ.get("CSI_DB_PASS") or ""
    cn = pymysql.connect(host=cfg.get("db_host", "127.0.0.1"),
                         port=int(cfg.get("db_port", 3306)),
                         user=cfg.get("db_user", "root"), password=pw,
                         database=cfg.get("db_name", "csi_dashboard"),
                         charset="utf8mb4",
                         cursorclass=pymysql.cursors.DictCursor)
    c = cn.cursor()
    c.execute("SELECT VERSION() AS v, DATABASE() AS d")
    info = c.fetchone()
    print("=== MySQL %s / %s ===\n" % (info["v"], info["d"]))

    print("--- 表 ---")
    for t in ("alarms", "clips", "meta"):
        try:
            c.execute("SELECT COUNT(*) AS n FROM %s" % t)
            print("  %-8s %6d 行" % (t, c.fetchone()["n"]))
        except pymysql.Error as e:
            print("  %-8s 读取失败: %s" % (t, e))
            return 1

    print("\n--- 报警按来源 ---")
    c.execute("SELECT src, COUNT(*) AS n FROM alarms GROUP BY src ORDER BY n DESC")
    for r in c.fetchall():
        print("  %-8s %5d" % (r["src"], r["n"]))
    c.execute("SELECT COUNT(*) AS n, SUM(img) AS i, SUM(clip) AS cl FROM alarms")
    t = c.fetchone()
    print("  合计 %d 条，带抓拍 %d，带视频 %d"
          % (t["n"] or 0, t["i"] or 0, t["cl"] or 0))

    print("\n--- 最近 5 条 ---")
    c.execute("SELECT id, ts, label, src, ack, clip FROM alarms "
              "ORDER BY ts DESC LIMIT 5")
    for r in c.fetchall():
        sz = 0
        p = os.path.join(CLIP_DIR, "%s.mp4" % r["id"])
        if r["clip"] and os.path.exists(p):
            sz = os.path.getsize(p)
        print("  %s  %-12s %-8s ack=%d clip=%d  %s"
              % (time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"] or 0)),
                 r["label"], r["src"], int(r["ack"] or 0), int(r["clip"] or 0),
                 "%.1f MB" % (sz / 1048576.0)))

    print("\n--- 视频 ---")
    c.execute("SELECT COUNT(*) AS n, SUM(bytes) AS b, SUM(sec) AS s FROM clips")
    r = c.fetchone()
    print("  %d 个，合计 %s，总时长 %.1fs"
          % (r["n"] or 0, human(r["b"]), float(r["s"] or 0)))
    if os.path.isdir(CLIP_DIR):
        files = os.listdir(CLIP_DIR)
        real = sum(os.path.getsize(os.path.join(CLIP_DIR, f)) for f in files)
        print("  clips 目录 %s（%d 个文件）" % (human(real), len(files)))

    print("\n--- meta 设置 ---")
    c.execute("SELECT k, v FROM meta ORDER BY k")
    for r in c.fetchall():
        v = r["v"] if len(str(r["v"])) < 60 else str(r["v"])[:57] + "..."
        print("  %-20s %s" % (r["k"], v))
    cn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
