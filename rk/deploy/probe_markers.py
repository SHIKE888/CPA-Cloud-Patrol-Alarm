#!/opt/miniforge3/envs/mlk-ov/bin/python
# 搜 buffer 里的 D8FF (字节序反转的 SOI) 以及其它 JPEG marker 变体
import subprocess, time, sys
import numpy as np, cv2

subprocess.run(["systemctl","stop","mipi-webstream"], capture_output=True)
time.sleep(1.5)
cap = cv2.VideoCapture("/dev/video22", cv2.CAP_V4L2)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920); cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
try: cap.set(cv2.CAP_PROP_CONVERT_RGB, 0)
except Exception: pass
cap.set(cv2.CAP_PROP_BUFFERSIZE, 4)

deadline=time.time()+25; got=0; best=None
while time.time()<deadline and got<5:
    ok,f=cap.read()
    if not ok or f is None:
        time.sleep(0.05); continue
    got+=1
    buf=f.reshape(-1).tobytes()
    n=len(buf)
    print("=== frame %d  size=%d ===" % (got,n))
    print("  first 48: %s" % buf[:48].hex())

    def cnt(pat):
        c=0;i=0
        while True:
            j=buf.find(pat,i)
            if j<0: break
            c+=1; i=j+1
        return c

    tests = [
        (b"\xff\xd8",      "FFD8  SOI normal"),
        (b"\xd8\xff",      "D8FF  SOI byte-swapped"),
        (b"\xff\xe0",      "FFE0  APP0 (JFIF follows SOI)"),
        (b"\xe0\xff",      "E0FF  APP0 swapped"),
        (b"\xff\xc0",      "FFC0  SOF0"),
        (b"\xc0\xff",      "C0FF  SOF0 swapped"),
        (b"\xff\xc4",      "FFC4  DHT"),
        (b"\xc4\xff",      "C4FF  DHT swapped"),
        (b"\xff\xdb",      "FFDB  DQT"),
        (b"\xdb\xff",      "DBFF  DQT swapped"),
        (b"\xff\xd9",      "FFD9  EOI"),
        (b"\xd9\xff",      "D9FF  EOI swapped"),
    ]
    for pat,name in tests:
        c = cnt(pat)
        print("  %-28s = %d" % (name, c))
    a=np.frombuffer(buf,dtype=np.uint8)
    print("  zero=%.3f  ff=%.4f  d8=%.4f  ff00=%.4f"
          % ((a==0).mean(), (a==0xFF).mean(), (a==0xD8).mean(), cnt(b"\xff\x00")/max(n,1)))
    if best is None: best=buf

cap.release()
subprocess.run(["systemctl","start","mipi-webstream"], capture_output=True)
print("\nweb restarted")

# 如果找到 D8FF 聚集，尝试反序 32bit word 后搜索
if best:
    print("\n=== try 32-bit word byte-swap, then search FFD8 ===")
    b=bytearray(best)
    n=len(b)//4*4
    b2=bytearray(n)
    for k in range(0,n,4):
        b2[k:k+4] = b[k:k+4][::-1]
    bb=bytes(b2)
    i=bb.find(b"\xff\xd8")
    print("  after word-swap FFD8 first hit at: %d" % i)
    if i>=0:
        e=bb.find(b"\xff\xd9", i+2)
        print("  EOI at %d" % e)
        if e>0:
            open("/tmp/swapped.jpg","wb").write(bb[i:e+2])
            a2=cv2.imdecode(np.frombuffer(bb[i:e+2],np.uint8),cv2.IMREAD_COLOR)
            print("  decode=%s shape=%s" % (a2 is not None, None if a2 is None else a2.shape))
