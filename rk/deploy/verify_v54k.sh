#!/bin/sh
# V54k (0x5408) 验收: Q_SCALE=4 是否降码率 + buffer 是否出现 FFD8
B=9
A=0x40
rd() { i2cget -y $B $A "$1" 2>/dev/null; }

echo "== CFG_VER (expect 0xA9=08 0xAA=54) =="
echo "  0xA9=$(rd 0xa9)  0xAA=$(rd 0xaa)"
echo "  0x0B=$(rd 0x0b)"

echo
echo "== frame bytes / frames over 8s =="
printf "  %-3s %-11s %-8s %-8s\n" t bytes frames encstall
i=0
while [ $i -lt 8 ]; do
    a0=$(rd 0xa0); a1=$(rd 0xa1); a2=$(rd 0xa2)
    e1=$(rd 0xe1); e3=$(rd 0xe3)
    a3=$(rd 0xa3)
    printf "  %-3d %-11d %-8d %s\n" $i $((a2*65536+a1*256+a0)) $((e3*256+e1)) "$a3"
    i=$((i + 1))
    sleep 1
done

echo
echo "== S_dbg_jpeg =="
echo "  A3=$(rd 0xa3) A4=$(rd 0xa4) A5=$(rd 0xa5) A6=$(rd 0xa6)"

echo
echo "== MIPI error growth 4s =="
c1=$(dmesg | grep -c MIPI_CSI2); sleep 4; c2=$(dmesg | grep -c MIPI_CSI2)
echo "  delta=$((c2 - c1))"

echo
echo "== stream frame zones =="
curl -s -m 8 "http://127.0.0.1:9012/stream" -o /tmp/s2.mjpeg 2>/dev/null
/opt/miniforge3/envs/mlk-ov/bin/python - <<'PYEOF'
import numpy as np, cv2, os
p="/tmp/s2.mjpeg"
if not os.path.exists(p) or os.path.getsize(p)<100:
    print("  no stream"); raise SystemExit(0)
raw=open(p,"rb").read(); fs=[]; i=0
while True:
    s=raw.find(b"\xff\xd8\xff",i)
    if s<0: break
    e=raw.find(b"\xff\xd9",s+2)
    if e<0: break
    fs.append(raw[s:e+2]); i=e+2
print("  frames:",len(fs),"sizes:",[len(f) for f in fs[:5]])
for k,fb in enumerate(fs[:2]):
    a=cv2.imdecode(np.frombuffer(fb,np.uint8),cv2.IMREAD_COLOR)
    if a is None:
        print("  dec fail"); continue
    h,w,_=a.shape
    B_,G,R = a[...,0].astype(np.float32),a[...,1].astype(np.float32),a[...,2].astype(np.float32)
    print("  frame %d: %dx%d"%(k,w,h))
    for ci in range(4):
        x0,x1=ci*w//4,(ci+1)*w//4
        print("     x%d/4: R=%6.1f G=%6.1f B=%6.1f std=%5.1f"%(ci,R[:,x0:x1].mean(),G[:,x0:x1].mean(),B[:,x0:x1].mean(),a[:,x0:x1].std()))
    open("/tmp/now5408_%d.jpg"%k,"wb").write(fb)
PYEOF

echo
echo "== raw buffer FFD8 =="
systemctl stop mipi-webstream
sleep 1.5
timeout 35 /opt/miniforge3/envs/mlk-ov/bin/python /tmp/pbs.py 2>&1 | grep -vE "^\[ WARN" | head -18
systemctl start mipi-webstream
sleep 1
echo "web: $(systemctl is-active mipi-webstream)"
