#!/bin/sh
# 对比左右 starve 增速 + 抓画面 + 找 FFD8
B=9
A=0x40
rd() { i2cget -y $B $A "$1" 2>/dev/null; }

echo "== left vs right starve growth (E2=left low, {CB,CA}=right) =="
printf "  %-4s %-8s %-10s %-8s %-8s\n" "t" "L_starve" "R_starve" "frames" "E2"
i=0
while [ $i -lt 6 ]; do
    e2=$(rd 0xe2); ca=$(rd 0xca); cb=$(rd 0xcb)
    e1=$(rd 0xe1); e3=$(rd 0xe3)
    printf "  %-4d 0x%-6s 0x%s%s   0x%s%s\n" "$i" "$e2" "$cb" "$ca" "$e3" "$e1"
    i=$((i + 1))
    sleep 2
done

echo
echo "== stream frame analysis =="
curl -s -m 8 "http://127.0.0.1:9012/stream" -o /tmp/s.mjpeg 2>/dev/null
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PYEOF'
import numpy as np, cv2, os
p="/tmp/s.mjpeg"
if not os.path.exists(p) or os.path.getsize(p)<100:
    print("no stream"); raise SystemExit(0)
raw=open(p,"rb").read()
fs=[]; i=0
while True:
    s=raw.find(b"\xff\xd8\xff",i)
    if s<0: break
    e=raw.find(b"\xff\xd9",s+2)
    if e<0: break
    fs.append(raw[s:e+2]); i=e+2
print("frames:",len(fs),"sizes:",[len(f) for f in fs[:5]])
for k,fb in enumerate(fs[:2]):
    a=cv2.imdecode(np.frombuffer(fb,np.uint8),cv2.IMREAD_COLOR)
    if a is None: print("dec fail"); continue
    h,w,_=a.shape
    B,G,R=a[...,0].astype(np.float32),a[...,1].astype(np.float32),a[...,2].astype(np.float32)
    print("frame %d: %dx%d"%(k,w,h))
    for ci in range(4):
        x0,x1=ci*w//4,(ci+1)*w//4
        sub=a[:,x0:x1]
        print("   x%d/4: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"%(ci,R[:,x0:x1].mean(),G[:,x0:x1].mean(),B[:,x0:x1].mean(),sub.std()))
    open("/tmp/now_%d.jpg"%k,"wb").write(fb)
PYEOF

echo
echo "== raw buffer FFD8 check =="
systemctl stop mipi-webstream
sleep 1.5
timeout 35 /opt/miniforge3/envs/mlk-ov/bin/python /tmp/pbs.py 2>&1 | grep -vE "^\[ WARN" | head -20
systemctl start mipi-webstream
sleep 1
echo "web: $(systemctl is-active mipi-webstream)"
