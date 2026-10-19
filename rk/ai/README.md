# RK3576 NPU 人体检测 → 姿态关键点 → 危险动作识别（叠加 + Web 查看）

在 **MLK-AFC03（RK3576J）** 上跑通的两级 NPU 视觉流水线：

```
   ┌── 一级：人体检测 (yolov8n, COCO person)          ──┐
   │                                                    │  NPU
   └── 二级：肢体关节 (yolov8n-pose, 17 关键点, ROI)   ──┘
                       ↓
              跟踪(ID) + 骨架平滑(EMA) + 危险动作状态机
                       ↓
        叠加标注（框/骨架/中文动作标签/越界区）
                       ↓
              MJPEG Web 推流（浏览器实时查看）
```

**帧率解耦**：采集/渲染按视频帧率跑，AI 推理按自己的限频跑（`--ai-fps`，默认 30、最高 60；
真正的天花板由单帧耗时 `run_ms` 决定，限频只是闸门），
AI 结果通过"最近值"共享给渲染线程 —— 叠加标注不会拖慢视频帧率。

**模型档位（网页上可热切换）**：NPU 耗时几乎正比于输入面积，所以除了原始 640 模型，
还转了更小的输入尺寸各用一套：

| 模型文件 | 输入 | 用途 | 实测 NPU 耗时（双核） |
|---|---|---|---|
| `yolov8n-slim.rknn` | 640 | 一级检测（线上在用）| **17 ms**（单核 24 ms）|
| `yolov8n-slim-512.rknn` | 512 | 一级检测（已否决，漏检）| 20 ms |
| `yolov8n-pose-hybrid.rknn` | 640 | 二级姿态（线上在用）| **22~26 ms**（单核 33 ms）|
| `yolov8n-pose-384-hybrid.rknn` | 384 | 已否决（见下文）| 15 ms，但输出已损坏 |
| `yolov8n-pose-320-hybrid.rknn` | 320 | 已否决（见下文）| 24 ms，但输出已损坏 |

“双核”指 `RKNNLite` 的 `core_mask=NPU_CORE_0_1` —— RK3576 的 NPU 是双核，
而 `NPU_CORE_AUTO` **只挑一个核**（另一个全程 0%），这是早期“NPU 占用才 20~40% 却快不起来”的真正原因。
`det_core.RKNNModel` 已默认双核（init 失败自动退回 AUTO）。

网页上「模型档位」就是上面这些文件的组合；
`det_core.TwoStageDetector` 会**从文件名自动识别输入尺寸**（`-384-` → 384），
解码器也支持三种输出布局（airorckchip 分离式、合并 DFL、ultralytics 原生扁平 (1,C,N)）。

> ⚠ **小尺寸模型实测不可用（2026-10-16 结论，2026-10-19 又验证了第三条路）**：
> * det 512 → 画面里较小的人**漏检**；
> * pose 384/320 做 **INT8** → 类别分支压成 0、关键点置信度全 0
>   （把 cv2/cv3/cv4/Concat 都改 float16 也无效）→“有框无骨架”；
> * pose 384/320 做 **FP16**（`do_quantization=False`，见 `convert/vm_fp16.py`）→
>   输出完全正常，但 RK3576 的 NPU 跑 FP16 极慢：**384 = 56.6 ms、320 = 24.6 ms**，
>   都不比 640 INT8（22~26 ms）快 → 同样不可用。
>
> 所以线上只用 640 那套；“快”靠三件事：**spread_pose**（检测帧跳过姿态）、
> **pose_budget**（多人时每帧只更新 N 个人）、**NPU 双核**。
> 无人 50 fps / 1 人 36 fps / 4 人 26.7 fps（见 `../web/README.md` 的性能调优速查表）。

怎么得到小尺寸模型（VM 上，ultralytics + rknn-toolkit2）：

```bash
# pose（需要两阶段混合量化保住关键点 conf）
python -c "from ultralytics import YOLO; YOLO('yolov8n-pose.pt').export(format='onnx', imgsz=384, opset=12)"
python vm_hybrid.py step1 --onnx yolov8n-pose-384.onnx --dataset dataset.txt --target rk3576
python vm_hybrid.py patch --cfg yolov8n-pose-384.quantization.cfg --match "Concat_6" --backup
python vm_hybrid.py step2 --model yolov8n-pose-384.model --data yolov8n-pose-384.data \
    --cfg yolov8n-pose-384.quantization.cfg --out yolov8n-pose-384-hybrid.rknn

# det（原生导出是 (1,4+ncls,N)，先用 slim_native.py 裁成 (1,5,N)）
python -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='onnx', imgsz=512, opset=12)"
python slim_native.py      # yolov8n-512.onnx -> yolov8n-slim-512.onnx
python convert_rknn.py --onnx yolov8n-slim-512.onnx --out yolov8n-slim-512.rknn \
    --target rk3576 --dtype i8 --dataset dataset.txt
```

---

## 1. 选型调研（GitHub 上的可用方案）

| 项目 | 作用 | 与本项目的关系 |
|---|---|---|
| [airockchip/rknn_model_zoo](https://github.com/airockchip/rknn_model_zoo) | 官方模型库 + Python/C++ 例程，**明确支持 RK3576** | ✅ 采用其 `yolov8` / `yolov8_pose` 的官方预导出 ONNX 与后处理定义 |
| [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2) | 模型转换（`rknn-toolkit2`）+ 板端推理（`rknn-toolkit-lite2` / `librknnrt`） | ✅ 采用 v2.3.0（与板上 `librknnrt 2.3.0` 严格对齐） |
| [airockchip/ultralytics_yolov8](https://github.com/airockchip/ultralytics_yolov8) | 面向 RKNPU 优化的 yolov8 导出分支 | pose ONNX 的来源 |
| [rockchip-linux/rknpu2](https://github.com/rockchip-linux/rknpu2) | `librknn_api` C 例程 | 若要换 C++ 高性能版，从这里起步 |
| [longnhan/Rockchip3576-AI-camera](https://github.com/longnhan/Rockchip3576-AI-camera) | **RK3576** GStreamer + RKNN + RTSP 的 C++ 参考架构（8★） | 架构参考：RGA 预处理 + MPP 硬编码 + RTSP 输出 |
| [1781978327/rknn_yolov8_pose_Multithreading](https://github.com/1781978327/rknn_yolov8_pose_Multithreading) | yolov8-pose 多线程 + 线程池 + RTSP 推流（RK3588） | 思路参考：`rknnPool` 异步推理；注意它把 `BOX_THRESH` 提到 0.5 抑制误检 |
| [yyyy231209/rk3588-npu-multithread-reuse](https://github.com/yyyy231209/rk3588-npu-multithread-reuse) | 多线程复用 NPU + `rknn_set_core_mask` + DMA-BUF 零拷贝 | 性能优化参考（RK3576 只有 1 个 NPU 核，核掩码意义有限） |
| [march620/rknn_model_zoo-2.3.2](https://github.com/march620/rknn_model_zoo-2.3.2) | 含 `yolov8_pose_cam` DRM 实时 demo | 若要做本地 HDMI/DRM 直接显示可参考 |
| [rokkieluo/yolov8_pose_convert_rknn](https://github.com/rokkieluo/yolov8_pose_convert_rknn) | onnx → rknn 转换小工具 | 转换流程交叉验证 |
| [zhahoi/yolov8-pose-fall-detection](https://github.com/zhahoi/yolov8-pose-fall-detection) | 摔倒检测（ncnn，**几何规则**）134★ | ✅ 动作规则设计的参考（本项目把规则重写为时序状态机） |
| [Algoculus/Human-anomaly-localization-YOLOv8s-pose](https://github.com/Algoculus/Human-anomaly-localization-YOLOv8s-pose) | 摔倒 + 时序状态机 + 跟踪 | 参考：用"持续时间"而非单帧判定 |
| [Rchit13/posture-aware-fall-detection](https://github.com/Rchit13/posture-aware-fall-detection) | YOLOv8-pose + BiLSTM 姿态分类 | 进阶方案（需自行标注数据训练） |

**结论**：人体检测与关节提取用官方 `rknn_model_zoo` 的 `yolov8n` + `yolov8n-pose`（RK3576 已支持，实测精度损失极小）；
"危险动作识别"这一层没有开箱即用的 RK3576 部署方案，采用 **可解释的骨架规则 + 时序状态机** 自研实现（零额外模型、零训练、易调阈值），
后续如需识别更细的动作类别，再上 ST-GCN / PoseC3D 一类时序网络（当前硬件预算允许）。

---

## 2. 实测数据（MLK-AFC03 / RK3576J / librknnrt 2.3.0 / RKNPU driver 0.9.8）

> 表中 NPU 耗时是 **2026-10-19 双核（`NPU_CORE_0_1`）之后**的值；括号里是更早的单核数据。

| 项 | 数值 |
|---|---|
| 输入 | 1920×1080（来自 FPGA→MIPI 摄像头链路） |
| 一级 yolov8n 640×640 INT8 | **~17 ms**（单核 ~24 ms） |
| 二级 yolov8n-pose 640×640 INT8（关键点输出头 float16） | **~22~26 ms / 人**（单核 ~34 ms） |
| 两级**每帧都跑** | ~21 fps（单人） |
| 帧率优先档（检测帧跳过姿态 + 检测间隔 2） | **~36 fps（1 人）/ 50 fps（无人）** |
| 多人（姿态预算 2） | 4 人 26.7 fps（不限制时 15 fps） |
| 运行配置 | AI 限频 60；视频输出 **59 fps 不降**（与 AI 无关） |
| 检测精度（COCO 参考图） | NPU INT8 `person 0.686 / box(412,157,466,299)` vs ONNX Runtime FP32 `0.712 / box(412,156,465,298)` |
| 关键点 | NPU 与 FP32 一致：15/17 高置信 |

> **量化踩坑（重要）**：`yolov8n-pose` 直接 INT8 量化会把关键点输出里 `conf` 通道压成 **0**
> （坐标还是对的，但置信度全丢 → 画不出骨架）。解决：对输出层做**混合量化**，只把
> `/model.22/Concat_6_output_0_int8` 设为 `float16`（见下节），坐标与置信度都恢复正常，
> 代价仅约 +3 ms。
>
> **这条修法只对 640 有效**：384/320 的同一手法救不回来（2026-10-19 用 `probe_pose_model.py`
> 复验，kpt conf 仍全 0），改走 FP16 又因为 RK3576 的 FP16 太慢而不可用 —— 详见开头的模型表。

---

## 3. 目录结构

```
rk/ai/
├── README.md                     ← 本文件
├── convert/                      ← PC / VM 侧：模型准备与验证
│   ├── make_calib.py             下载 COCO 校准图（INT8 量化用）
│   ├── convert_rknn.py           ONNX → RKNN（含 onnx.mapping 兼容 shim）
│   ├── vm_hybrid.py              两阶段混合量化（step1 / patch / step2）
│   ├── verify_onnx.py            用 onnxruntime 验证输出布局与解码（x86 上先跑通）
│   └── test_det_core.py          回归测试：det_core 解码 vs onnxruntime 参考答案
├── board/                        ← 板上运行
│   ├── det_core.py               两级检测器 + 后处理 + 绘制
│   ├── action_rules.py           危险动作规则与状态机
│   ├── ai_webstream.py           主程序（采集/推理/渲染/HTTP 四线程）
│   ├── board_smoke.py            冒烟测试（设备 / 网络流 / 图片）
│   └── start_ai.sh               一键启动脚本
└── models/                       ← 模型与校准集（.rknn 可直接拷到板上）
    ├── yolov8n.onnx / .rknn              （一级：人体检测）
    ├── yolov8n-pose.onnx / -hybrid.rknn  （二级：姿态，hybrid 为推荐版）
    ├── calib/                            量化校准图片 + calib.txt
    └── dist/rknn_toolkit_lite2-2.3.0-cp38-…whl
```

---

## 4. 从零复现

### 4.1 准备 ONNX（PC，需要外网）

```bash
# 官方预导出模型（rknn_model_zoo 的下载地址）
curl -o models/yolov8n.onnx       https://ftrg.zbox.filez.com/v2/delivery/data/95f00b0fc900458ba134f8b180b3f7a1/examples/yolov8/yolov8n.onnx
curl -o models/yolov8n-pose.onnx  https://ftrg.zbox.filez.com/v2/delivery/data/95f00b0fc900458ba134f8b180b3f7a1/examples/yolov8_pose/yolov8n-pose.onnx

# 量化校准集（COCO val2017 抽 20 张）
python convert/make_calib.py --out models/calib --n 20
```

### 4.2 转换（Linux x86，本仓库用 VM `uisrc@192.168.65.128`）

```bash
conda create -y -n rknn230 python=3.12
pip install <RKNN SDK>/rknn-toolkit2/packages/x86_64/rknn_toolkit2-2.3.0-cp312-…whl
pip install "onnx==1.17.0" "onnxruntime==1.19.2" "setuptools<81"     # 版本对齐，见下
```

> 坑：`rknn-toolkit2 2.3.0` 仍引用 `onnx.mapping`，而它已在 onnx≥1.16 被删除，py3.12 又装不了 onnx≤1.15。
> 仓库里的 `convert_rknn.py` / `vm_hybrid.py` 顶部已内置 **shim** 把 `onnx.mapping` 补回来。

```bash
# 一级：普通 INT8
python convert_rknn.py --onnx yolov8n.onnx      --out yolov8n.rknn      --target rk3576 --dataset dataset.txt

# 二级：两阶段混合量化（关键点输出头保持 float16）
python vm_hybrid.py step1 --onnx yolov8n-pose.onnx --dataset dataset.txt --target rk3576
python vm_hybrid.py patch --cfg yolov8n-pose.quantization.cfg --match "Concat_6_output_0_int8" --dtype float16
python vm_hybrid.py step2 --model yolov8n-pose.model --data yolov8n-pose.data \
       --cfg yolov8n-pose.quantization.cfg --out yolov8n-pose-hybrid.rknn
```

转换前建议先在 x86 上用 `verify_onnx.py` 跑一遍，确认输出布局与后处理解码：
两个官方 ONNX 的布局并不一致（检测是 `64ch DFL + 80ch cls(已 sigmoid) + 1ch aux` 分离式；
姿态是 `65ch 合并(DFL+cls logits) + (1,17,3,8400) 关键点`），`det_core/_decode_heads` 已做自适应。

### 4.3 部署到板

```bash
# 依赖（板上有两套 python，用带 cv2 的那套 /opt/miniforge3/envs/mlk-ov，python3.8）
/opt/miniforge3/envs/mlk-ov/bin/pip install --no-deps rknn_toolkit_lite2-2.3.0-cp38-…whl
/opt/miniforge3/envs/mlk-ov/bin/pip install ruamel.yaml psutil      # 缺这两个会 import 失败

scp -r ai/ root@<BOARD>:/root/rk/         # 代码 + models
```

### 4.4 运行

**方式 A（推荐）：直接集成进 9012，不开第二个服务**

```bash
# AI 挂在既有的 mipi_webstream.py 里, 复用已经转好的 BGR 帧 —— 零二次编解码
cd /root/rk/web && AI=1 AI_SRC=ai ./start_webstream.sh        # 默认画面源=AI 标注
#   网页顶栏「画面源」按钮 / 「AI 标注」页签里可随时切回原图、调 AI 帧率与阈值
#   接口: GET /api/ai 看状态, POST /api/ai 调参
```

**方式 B：独立服务（9013）** —— 需要从别处取流（RTSP / 图片 / 别的 MJPEG）时才用：

```bash
# 接入已有推流（不占用摄像头）
SRC=http://127.0.0.1:9012/stream PORT=9013 AIFPS=6 bash /root/rk/ai/board/start_ai.sh
# 直接采集摄像头（需先停掉占用 /dev/video22 的进程）
SRC=/dev/video22 PORT=9013 bash /root/rk/ai/board/start_ai.sh
# 图片循环（演示 / 离线回归）
SRC=/root/rk/ai/000000000139.jpg PORT=9014 AIFPS=8 bash /root/rk/ai/board/start_ai.sh
```

浏览器打开 `http://<板子IP>:9013/`（本板 `http://192.168.137.100:9013/`）。

> 两种方式的模型、后处理、动作规则、跟踪平滑完全是同一套代码
> （`det_core.py` / `action_rules.py`），区别只在于“帧从哪来、往哪出”。

### 4.5 常用参数

| 参数 | 说明 |
|---|---|
| `--source` | 视频源：`/dev/video22`、`http://ip:port/stream`、`rtsp://…`、图片路径 |
| `--ai-fps` | AI 推理帧率上限（默认 30，最高 60；与视频帧率无关，真正天花板由 `run_ms` 决定） |
| `--cap-fps` | 采集限频（接网络流时默认 25，避免拉重复帧空烧 CPU） |
| `--det-conf` / `--nms-thres` | 检测阈值（误检多就调高 det-conf，漏检就调低） |
| `--max-persons` | 每帧最多跑几个 ROI 姿态（越多人越慢） |
| `--kpt-margin` | **一级框约束**：关节只保留在人体框 ± 该比例内（默认 `0.15`，`<0` 关闭）；二级关键点与三级动作判定同时生效 |
| `--roi-expand` | 二级姿态的 ROI 外扩倍数（默认 `1.15`；越小越“只盯着人看”） |
| `--kpt-scale-max` | **距框中心门限（挡鬼点主力）**：关节到框中心的距离不得超过该值 ×(框对角/2)（默认 `1.2`，`0` 关闭） |
| `--zone "x1,y1;x2,y2;…"` | 归一化坐标的越界警戒多边形 |
| `--stream-width` / `--quality` | 推流分辨率 / JPEG 质量 |
| `--no-skeleton` / `--no-score` / `--verbose-label` | 叠加内容开关 |

运行时 API：`GET /api/status`（含 fps、耗时、事件、动作）、`POST /api/ai`（在线改
`enabled` / `ai_fps` / `det_conf` / `nms_thres` / `zone` / `tune`）、`GET /snapshot.jpg`。

### 4.6 级联空间约束（一级框管住二 / 三级）

**现象**：骨架会从人身上拉出一条长线穿到画面另一角（常见是偏左上），
点看着像“自己飘”；同时动作判定被带偏。

**两个根因**（都很隐蔽，只修一个还会复发）：

1. `kpt_margin`（框 ± x%）**永远拦不住 ROI 内的鬼点** ——
   ROI 本身就是框外扩 `roi_expand` 得到的，所以 ROI 内的点最多只在框外
   `(roi_expand-1)/2 = 7.5%`，永远小于 15% 的门限，等于没有生效。
2. 原本主力的“体型门限”用肩/髀估躯干长，是**自举失败**：某个肩点一旦自己飘出去，
   用它算出的“躯干长”会被撑大 → 门限跟着变松 → 其它鬼点全部放行，
   而且髀干本身会拉出一条穿屏的长线。

**修法**：门限一律用**一级检测框**（它独立于姿态、不会自己污染自己）来定：

| 门限 | 作用 | 默认 | 说明 |
|---|---|---|---|
| `roi_expand` | 二级输入范围 | 1.15 | 姿态只在人体框外扩 15% 的 ROI 里找关节 |
| `kpt_margin` | 二级输出 | 0.15 | 超出「框 ± 15% 宽/高」的关节直接判不可见（不画、也不算） |
| **`kpt_scale_max`** | 二级输出（**主力**） | **1.2** | 到**框中心**的距离不得超过 `1.2 ×(框对角/2)`；人整个身子都在这范围内，穿屏鬼点（≥2）一律剔除 |

配套（缺一个都会复发）：

* `_kps_to_box`（跳帧时用关节外接框回写）先剔除“距框中心 > 0.6 倍对角”的点，
  否则鬼点会把框拉大拉偏，下一帧 ROI 跟着偏 —— 形成正反馈；
* `SimpleTracker._smooth` **只对“两帧都有效”的点做 EMA**，
  否则无效帧的鬼坐标会被混进历史，下一帧又拿被污染的值继续平滑 —— 表现就是“点自己游走”；
* 第三级同样裁：`action_rules.clip_to_box()` 在 `TrackState.update` 入口再过一次，
  保证速度/角度/越界用的是同一份干净数据。

**怎么调**（网页「AI 标注」页签里改完立即生效）：

* 还有点飘到远处 → 调小 **距框中心**（1.0 / 0.9）；
* 骨头缺胳膊少腿（手腕/脚踝常常在框外一点）→ 调大 **距框中心**（1.4~1.6）或 **关节范围**（0.25）；
* 想看命中情况：`GET /api/ai` 的 `kpt_dropped`（框门限剔除数）/ `kpt_far`（距框中心门限剔除数）。

---

## 5. 危险动作识别规则（`action_rules.py`）

全部以"人体框高"做尺度归一化，并用**持续时间**去抖，避免单帧误报。

| 标记 | 中文 | 英文（画面上显示的）| 判定（简化） | 级别 |
|---|---|---|---|---|
| `fall` | 跌倒 | `Fall` | 躯干与竖直夹角 > 45°(可调) **且** 髀高在 1.2s 内骤降，持续 0.35s | 🔴 报警 |
| `lying` | 倒地不起 | `Lying` | 躯干角 > 65° 持续 2.5s | 🔴 报警 |
| `climb` | 攀爬翻越 | `Climb` | 双手高于肩线 **且**（髀部 1.2s 内抬升 > 0.18 身高 或 脚高于髀） | 🔴 报警 |
| `fight` | 肢体冲突 | `Fight` | 腕部速度 > 5 身高/秒 持续 0.4s | 🔴 报警 |
| `intrude` | 越界闯入 | `Intrude` | 脚部关键点落入警戒多边形，持续 0.3s | 🟠 提醒 |
| `run` | 奔跑 | `Run` | 髀部速度 > 1.5 身高/秒 持续 0.6s | 🟠 提醒 |
| `handup` | 举手求救 | `Help` | 双手高于肩线且身体近静止，持续 2s | 🟠 提醒 |
| `squat` | 下蹲 | `Squat` | 髀部接近膝部高度 | ⚪ 记录 |

> **为什么画面上只能用英文？** opencv 的 `cv2.putText` 用的是 Hershey 字体，
> 根本没有汉字字形 —— 直接把中文传进去，渲染出来就是一串 `???`（这就是之前
> 框上时不时冒出“？？？”的原因）。所以 `ACTION_META` 里每个动作都自带英文名（`en`），
> `actions/r['actions']/events` 同时提供 `cn` 与 `en`；
> **推流画面用 en，网页列表用 en + 中文对照**。
> 另外绘制前还会过一道 `_ascii()` 兜底（非 ASCII 字符直接剔除），以后就算误传中文也不会再出问号。

页面上的 **跌倒/奔跑灵敏度滑块** 通过 `POST /api/ai {"tune":{"fall":…,"run":…}}` 实时生效，
无需重启（`ActionRecognizer.tune` 与所有 `TrackState` 共享同一份配置）。

报警事件会进入 `/api/status` 的 `events` 列表（含时间、ID、动作、置信度），页面右侧滚动显示。

---

## 6. 已验证 / 已知问题

**已端到端验证**
- 同一张参考图：NPU INT8 与 ONNX FP32 检测框/得分、关键点数量一致（见第 2 节数据）
- Web 页面显示：人体框 + `ID1 0.69` + 完整骨架 + 顶部 fps/耗时信息条
- 帧率解耦：图片源 25fps，AI 限频 8fps 稳定达成（`/api/status` 的 `video_fps≈24.7 / ai_fps≈7.98`）
- 从既有 MJPEG 流（9012）接入也可正常工作

**已知问题 / 后续优化**
1. 目前是 **Python + rknnlite** 实现，CPU 侧预处理/后处理占比不小。
   若要更高 AI 帧率，参考 `longnhan/Rockchip3576-AI-camera` 改 C++（RGA 预处理 + MPP 硬编码）。
2. **推荐直接用集成模式**（4.4 方式 A）而不是“9012 + 9013”双服务：
   双服务时同一画面被 JPEG 编码/解码各两次，还多一份回环流量。
   实测由 367%+49% CPU（两个进程）降到单进程 270%。
3. 当前画面 MIPI 链路的颜色/曝光问题（另见项目主 README）与 AI 无关，
   但会影响检测效果 —— 建议先让画面曝光正常。
4. 跌倒等规则阈值是按常见监控视角调的，**换机位后需用页面滑块重新标定**。
   空旷/纹理复杂场景建议把 `det_conf` 提到 0.45~0.5 抑制误检。
5. 若要识别更多/更细的动作（如打架、摔倒后挣扎、未戴安全帽等），
   建议采集一段自己的数据训练轻量时序网络（ST-GCN / PoseC3D 量化后跑 NPU）。
