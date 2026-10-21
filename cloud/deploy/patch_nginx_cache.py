import shutil
import sys

P = "/www/server/panel/vhost/nginx/<SERVER_DOMAIN>.conf"
MARK = "location = / {"
SNIP = """
    # ===== 看板首页不缓存（部署新版后浏览器立刻拿到）=====
    location = / {
        add_header Cache-Control "no-store";
        try_files /index.html =404;
    }
    location ~* \\.html$ {
        add_header Cache-Control "no-store";
    }
"""

s = open(P, encoding="utf-8").read()
if MARK in s:
    print("already patched")
    sys.exit(0)
i = s.find("# ===== CSI2RK cloud dashboard")
if i < 0:
    i = s.rstrip().rfind("}")
shutil.copy(P, "/root/<SERVER_DOMAIN>.conf.bak_csi2")
open(P, "w", encoding="utf-8").write(s[:i] + SNIP + s[i:])
print("patched, backup -> /root/<SERVER_DOMAIN>.conf.bak_csi2")
