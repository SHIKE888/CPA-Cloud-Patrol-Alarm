#!/opt/miniforge3/envs/mlk-ov/bin/python
# 精查: mrg_segc 增速 + buffer 前 128 字节 + 2字节 SOI 搜索
import time, subprocess, os, sys
import numpy as np, cv2

def rd(a):
    try:
        return int(subprocess.check_output(["i2cget","-y","9","0x40",a]).strip(),16)
    except Exception:
        return -1

print("== mrg_segc growth (10 samples) ==")
prev=None; t0=time.time()
vals=[]
for i in range(10):
    a5=rd("0xa5"); a6=rd("0xa6")
    segc=((a6<<8)|a5) & 0x3FFF
    vals.append(segc)
    print("  t%d segc=0x%04x (raw A5=%02x A6=%02x)" % (i, segc, a5, a6))
    time.sleep(0.8)
d=[(vals[i+1]-vals[i]) & 0x3FFF for i in range(len(vals)-1)]
print("  deltas:", d)
print("  NOTE: mrg_segc is 10 bit inside S_dbg_jpeg; raw A5/A6 also carry")
print("        consume/encif_full in high bits, so treat trend only.")

print()
print("== raw buffer: first 128 bytes + 2-byte FFD8 search ==")
subprocess.run(["systemctl","stop","mipi-webstream"], capture_output=True)
time.sleep(1.5)
cap = cv2.VideoCapture("/dev/video22", cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
try: cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
except Exception: pass
cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)

deadline=time.time()+25; got=0
best=None
while time.time()<deadline and got<6:
    ok,f=cap.read()
    if not ok or f is None:
        time.sleep(0.05); continue
    got+=1
    buf=f.reshape(-1).tobytes()
    nz=sum(1 for b in buf[:65536] if b!=0)
    print("  frame %d: len=%d nonzero_in_first_64K=%d" % (got,len(buf),nz))
    print("    first 128: %s" % buf[:128].hex())
    hits=[]; i=0
    while True:
        i=buf.find(b"\xff\xd8", i)
        if i<0: break
        hits.append(i); i+=2
    print("    FFD8 (2-byte) hits=%d  first=%s" % (len(hits), hits[:8]))
    if hits and best is None:
        best=buf
cap.release()
subprocess.run(["systemctl","start","mipi-webstream"], capture_output=True)

if best:
    off=best.find(b"\xff\xd8")
    e=best.find(b"\xff\xd9", off+2)
    print("  SOI@%d EOI@%s" % (off,e))
    if e>0:
        jpg=best[off:e+2]
        open("/tmp/found.jpg","wb").write(jpg)
        a=cv2.imdecode(np.frombuffer(jpg,np.uint8),cv2.IMREAD_COLOR)
        print("  saved /tmp/found.jpg len=%d decode=%s shape=%s"
              % (len(jpg), a is not None, None if a is None else a.shape))
        if a is not None:
            B,G,R=a[...,0].astype(np.float32),a[...,1].astype(np.float32),a[...,2].astype(np.float32)
            print("  ALL: R=%.1f G=%.1f B=%.1f std=%.1f"%(R.mean(),G.mean(),B.mean(),a.std()))
else:
    print("  no FFD8 anywhere in any captured buffer")
