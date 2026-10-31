import os
import shutil
import sys

# nginx 站点配置文件路径因环境而变，不写死在仓库里；用 NGINX_VHOST 指定
P = os.environ.get("NGINX_VHOST", "")
if not P:
    sys.exit("缺少 NGINX_VHOST，例：NGINX_VHOST=/www/server/panel/vhost/nginx/example.com.conf python3 patch_nginx_cache.py")
BAK = "/root/" + os.path.basename(P) + ".bak_csi2"
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
shutil.copy(P, BAK)
open(P, "w", encoding="utf-8").write(s[:i] + SNIP + s[i:])
print("patched, backup -> " + BAK)
