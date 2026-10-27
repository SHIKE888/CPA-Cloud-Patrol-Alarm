#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""云端 SQLite 自检 —— 确认事件/视频真的落在库里。

在服务器上直接跑（不需要停服务，WAL 里没合并的数据也能读到）：

    python3 cloud/tools/db_check.py                      # 默认 /opt/csi-dashboard/data/dash.db
    python3 cloud/tools/db_check.py /path/to/dash.db
"""
import os
import sqlite3
import sys
import time

DB = sys.argv[1] if len(sys.argv) > 1 else "/opt/csi-dashboard/data/dash.db"


def human(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return "%.1f %s" % (n, u)
        n /= 1024.0


def main():
    if not os.path.exists(DB):
        print("!! 找不到 %s" % DB)
        return 2
    print("=== %s ===" % DB)
    for suf in ("", "-wal", "-shm"):
        p = DB + suf
        if os.path.exists(p):
            print("  %-12s %10s" % (os.path.basename(p), human(os.path.getsize(p))))

    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row

    print("\n--- 表 ---")
    rows = list(c.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"))
    names = [r["name"] for r in rows]
    if not names:
        print("  （空库，一张表也没有）")
    for t in names:
        n = c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
        print("  %-8s %6d 行" % (t, n))

    if "alarms" in names:
        print("\n--- 报警按来源 ---")
        for r in c.execute("SELECT src, COUNT(*) n FROM alarms GROUP BY src "
                           "ORDER BY n DESC"):
            print("  %-8s %5d" % (r["src"], r["n"]))
        tot = c.execute("SELECT COUNT(*), SUM(img), SUM(clip) FROM alarms").fetchone()
        print("  合计 %d 条，带抓拍 %d，带视频 %d"
              % (tot[0], tot[1] or 0, tot[2] or 0))
        print("\n--- 最近 5 条 ---")
        for r in c.execute("SELECT id, ts, label, src, ack, clip FROM alarms "
                           "ORDER BY ts DESC LIMIT 5"):
            print("  %s  %-12s %-8s ack=%d clip=%d  %s"
                  % (time.strftime("%m-%d %H:%M:%S", time.localtime(r["ts"] or 0)),
                     r["label"], r["src"], int(r["ack"] or 0), int(r["clip"] or 0),
                     "%.1f MB" % ((os.path.getsize(
                         "/opt/csi-dashboard/data/clips/%s.mp4" % r["id"])
                         if r["clip"] else 0) / 1048576.0)))

    if "clips" in names:
        r = c.execute("SELECT COUNT(*), SUM(bytes), SUM(sec) FROM clips").fetchone()
        print("\n--- 视频 ---\n  %d 个，合计 %s，总时长 %.1f 秒"
              % (r[0] or 0, human(r[1]), r[2] or 0))
        d = "/opt/csi-dashboard/data/clips"
        if os.path.isdir(d):
            real = sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d))
            print("  clips 目录实占 %s（%d 个文件）"
                  % (human(real), len(os.listdir(d))))

    print("\n--- WAL 状态 ---")
    print("  journal_mode = %s" % c.execute("PRAGMA journal_mode").fetchone()[0])
    wal = DB + "-wal"
    if os.path.exists(wal):
        print("  -wal = %s（服务端每 10s PASSIVE checkpoint，>2MB 会 TRUNCATE；"
              "退出时 TRUNCATE）" % human(os.path.getsize(wal)))
    print("  注：只用 dash.db（不拷 -wal）也能看到已 checkpoint 的数据")
    return 0


if __name__ == "__main__":
    sys.exit(main())
