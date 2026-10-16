#!/bin/sh
# V28: 4K 画面取证 —— 转 PNG 并统计
echo "=== 工具可用性 ==="
which ffmpeg python3 2>/dev/null
echo ""
echo "=== 纯 python 统计 (无 PIL) ==="
python3 - <<'PYEOF'
import os
p='/tmp/f4k.raw'; W,H=3840,2160
sz=os.path.getsize(p)
FR=W*H*2
print("raw=%d  单帧=%d  帧数=%.3f" % (sz, FR, sz/FR))
if sz < FR: raise SystemExit("数据不足")
for fi in range(min(3, sz//FR)):
    d=open(p,'rb').read(FR) if fi==0 else None
if True:
    f=open(p,'rb'); f.seek(0); d=f.read(FR); f.close()
    y=d[0:W*H:1]
    print("帧0 Y  min/max/mean = %d/%d/%.1f" % (min(y),max(y),sum(y)/len(y)))
    uv=d[W*H:W*H+W*H//2]
    print("帧0 UV min/max/mean = %d/%d/%.1f" % (min(uv),max(uv),sum(uv)/len(uv)))
    # 行内取样: 看有没有整行重复/半行镜像(宽度不匹配的典型症状)
    for r in (100, 540, 1080, 2000):
        row=d[r*W:(r+1)*W]
        print("第%4d行 每240列: %s" % (r, [row[i*240] for i in range(16)]))
    # 列方向取样
    print("第1920列 每120行: %s" % [d[r*W+1920] for r in range(0,2160,120)])
    # 半行对比: 若 TX 只发 1920 宽, 右半(1920..3839)常与左半相同或为0
    l=d[1000*W:1000*W+1920]; rr=d[1000*W+1920:1001*W]
    print("第1000行 左半mean=%.1f 右半mean=%.1f" % (sum(l)/len(l), sum(rr)/len(rr)))
PYEOF
echo ""
echo "=== ffmpeg 转 PNG (YUYV422) ==="
if which ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -loglevel error -f rawvideo -pixel_format yuyv422 -video_size 3840x2160 -i /tmp/f4k.raw -frames:v 1 /tmp/f4k_color.png 2>&1 | tail -3
  ls -l /tmp/f4k_color.png 2>&1
  ffmpeg -y -loglevel error -f rawvideo -pixel_format gray -video_size 3840x2160 -i /tmp/f4k.raw -frames:v 1 -vf scale=1280:720 /tmp/f4k_gray.png 2>&1 | tail -3
  ls -l /tmp/f4k_gray.png 2>&1
else
  echo "无 ffmpeg"
fi
