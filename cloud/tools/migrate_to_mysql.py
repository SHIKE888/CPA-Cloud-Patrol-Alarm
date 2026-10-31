#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把旧 SQLite 库（data/dash.db）里的报警 / 视频元数据 / 设置迁到 MySQL。

    python3 cloud/tools/migrate_to_mysql.py [config.json]

* 幂等：用 REPLACE INTO，反复跑不会重复
* 只迁元数据；图片和视频本体一直是文件（data/shots、data/clips）
* 迁完不清 SQLite，留作备份（data/dash.db.bak 可手动删）
"""
import json
import os
import sqlite3
import sys
import time

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    sys.exit("需要 pymysql：apt install -y python3-pymysql")

CFG_PATH = sys.argv[1] if len(sys.argv) > 1 else "/opt/csi-dashboard/config.json"
ALARM_COLS = ("id", "ts", "lvl", "label", "cn", "en", "tid", "score", "src",
              "note", "m", "img", "ack", "ack_ts", "n", "last_ts", "last_note",
              "recovered", "clip", "clip_bytes", "clip_sec")


def main():
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    db_file = os.path.join(cfg.get("data_dir", "/opt/csi-dashboard/data"), "dash.db")
    if not os.path.exists(db_file):
        print("没有旧库 %s，跳过" % db_file)
        return 0

    src = sqlite3.connect(db_file)
    src.row_factory = sqlite3.Row
    names = [r[0] for r in src.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")]

    pw = cfg.get("db_pass") or os.environ.get("CSI_DB_PASS") or ""
    cn = pymysql.connect(host=cfg.get("db_host", "127.0.0.1"),
                         port=int(cfg.get("db_port", 3306)),
                         user=cfg.get("db_user", "root"), password=pw,
                         database=cfg.get("db_name", "csi_dashboard"),
                         charset="utf8mb4",
                         cursorclass=pymysql.cursors.DictCursor)
    c = cn.cursor()

    n_a = n_c = n_m = 0
    if "alarms" in names:
        rows = list(src.execute("SELECT * FROM alarms ORDER BY ts"))
        sql = ("REPLACE INTO alarms(%s) VALUES(%s)"
               % (",".join(ALARM_COLS), ",".join(["%s"] * len(ALARM_COLS))))
        for r in rows:
            vals = []
            for k in ALARM_COLS:
                v = r[k] if k in r.keys() else None
                if k == "ts":
                    v = float(v or 0)
                vals.append(v)
            c.execute(sql, vals)
            n_a += 1
    if "clips" in names:
        for r in src.execute("SELECT * FROM clips ORDER BY ts"):
            c.execute("REPLACE INTO clips(alarm_id,ts,sec,bytes,path) "
                      "VALUES(%s,%s,%s,%s,%s)",
                      (r["alarm_id"], r["ts"], r["sec"], r["bytes"], r["path"]))
            n_c += 1
    if "meta" in names:
        for r in src.execute("SELECT k,v FROM meta"):
            c.execute("REPLACE INTO meta(k,v) VALUES(%s,%s)", (r["k"], r["v"]))
            n_m += 1
    cn.commit()
    c.execute("SELECT COUNT(*) AS n FROM alarms")
    tot = c.fetchone()["n"]
    cn.close()

    print("[%s] 迁移完成：alarms %d、clips %d、meta %d → MySQL 现共 %d 条报警"
          % (time.strftime("%m-%d %H:%M:%S"), n_a, n_c, n_m, tot))
    print("旧库保留：%s（确认无误后可删）" % db_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
