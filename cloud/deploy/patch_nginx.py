import shutil
import sys

P = "/www/server/panel/vhost/nginx/<SERVER_DOMAIN>.conf"
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
shutil.copy(P, "/root/<SERVER_DOMAIN>.conf.bak_csi")
open(P, "w", encoding="utf-8").write(s[:i] + SNIP + s[i:])
print("patched, backup -> /root/<SERVER_DOMAIN>.conf.bak_csi")
