import os
import shutil
import sys

# nginx 站点配置文件路径因环境而变，不写死在仓库里；用 NGINX_VHOST 指定
P = os.environ.get("NGINX_VHOST", "")
if not P:
    sys.exit("缺少 NGINX_VHOST，例：NGINX_VHOST=/www/server/panel/vhost/nginx/example.com.conf python3 patch_nginx.py")
BAK = "/root/" + os.path.basename(P) + ".bak_csi"
SNIP = """
    # ===== CSI2RK cloud dashboard（由部署脚本添加，可整段删除）=====
    location ^~ /api/ {
        access_log off;
        proxy_pass http://127.0.0.1:9080;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
        proxy_buffering off;
        client_max_body_size 2m;
    }
"""

s = open(P, encoding="utf-8").read()
if "location ^~ /api/" in s:
    print("already patched")
    sys.exit(0)
i = s.rstrip().rfind("}")
if i < 0:
    print("bad conf")
    sys.exit(1)
shutil.copy(P, BAK)
open(P, "w", encoding="utf-8").write(s[:i] + SNIP + s[i:])
print("patched, backup -> " + BAK)
