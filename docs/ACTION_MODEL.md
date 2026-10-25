# 动作识别：从几何规则换成轻量模型

> 2026-10-23 起草。板子离线期间先把整条流水线准备好，上线后按本文顺序跑即可。

## 1. 为什么不能直接"找个现成的"

在 GitHub 上找了一圈（`action recognition rknn` / `st-gcn rknn` / `mmaction2 rknn`
/ `rknn action`），**没有任何现成工程能直接放到 RK3576 上跑**：

| 候选 | 实际情况 | 结论 |
|---|---|---|
| rknn_model_zoo（官方） | 只有 det/seg/ocr/pose/llm，没有动作识别 | 不可用 |
| `Bigtuo/YOLO-POSE-Bytetrack-STGCN` | 跌倒检测，PyTorch + x86，未见 RKNN 移植 | 只能借结构 |
| `atandra2000/ActionRecognition` | ST-GCN/CTR-GCN + ONNX/TensorRT，无 RKNN | 只能借结构 |
| `open-mmlab/mmaction2` ST-GCN++ | 训练/评测齐全，导出走 ONNX，量化到 RKNN 要自己踩 | 可参考 |
| `kennymckormick/pyskl` | 同上（ST-GCN++ / PoseC3D） | 可参考 |
| PoseC3D / TSM / MoViNet | 吃 RGB 视频段，多人时要逐人裁剪+推理 | **成本不可接受** |

关键约束让我们只能走"骨架 + 小模型"：

1. **NPU 已经很满**：det 17.3ms + pose 25.8ms（双核），再挂一个 RGB 视频模型会直接掉帧；
2. **多人**：RGB 段模型要逐人裁 8~16 帧 224×224，成本 ×人数；
3. **我们本来就有 17 点骨架**（YOLOv8-pose 已经在跑），骨架序列几乎零额外成本；
4. **NTU/Kinect 3D 骨架与我们的 2D COCO-17 分布差太远**，公开预训练权重直接迁移基本没用
   —— 必须用自己采的 2D 数据训练。

所以方案定为：**自建精简 ST-GCN（~11 万参数 / ~30 MFLOPs）+ 板上自采数据训练**。

## 2. 方案取舍

| 方案 | 精度潜力 | 单人成本 | 多人成本 | RKNN 友好度 | 采用 |
|---|---|---|---|---|---|
| PoseC3D（热图 3D CNN） | 高 | 高 | ×人数 | 中 | ✗ |
| TSM/MoViNet（RGB 段） | 高 | 高 | ×人数 | 高 | ✗ |
| ST-GCN++（原版） | 中高 | 低 | ×人数 | 中（einsum/多尺度） | 参考 |
| **精简 ST-GCN**（本项目） | 中 | **<1ms(NPU)** | ×人数，仍可忽略 | **高**（只有 MatMul/Conv/BN） | ✓ |

## 3. 已准备好的文件

| 文件 | 作用 |
|---|---|
| `rk/ai/board/action_seq.py` | 序列缓冲 + 归一化（髋中心平移 / 框高缩放 / 重采样到 32 帧）**训练与部署共用** |
| `rk/ai/convert/action_spec.py` | **共享常量**（类别/骨架拓扑/邻接矩阵），torch 与 tf 两条路共用 |
| `rk/ai/convert/action_data.py` | 数据加载 / 合成 / 数据增强（纯 numpy） |
| `rk/ai/convert/action_net.py` | 模型定义（torch 版，对照实现） |
| `rk/ai/convert/action_net_tf.py` | **模型定义（TF/Keras 版，主力）** |
| `rk/ai/convert/train_action_tf.py` | **训练（TF，本机可直接跑）** |
| `rk/ai/convert/export_action_tf.py` | **导出 TFLite + NPZ + 三方一致性校验** |
| `rk/ai/convert/train_action.py` | 训练（torch 版，需要 torch 环境） |
| `rk/ai/convert/convert_action_rknn.py` | TFLite/ONNX → RKNN（INT8 / `--no-quant` FP16） |
| `rk/ai/board/action_np.py` | numpy 前向（无需 RKNN/onnxruntime/torch） |
| `rk/ai/board/action_model.py` | `ActionModel`（rknn 优先、numpy 兜底）+ `ActionEngine`（滞回、越界几何、输出契约） |
| `rk/ai/board/test_action_engine.py` | 引擎离线单测（假模型，**17 例**，PC 上有 numpy 就能跑） |
| `rk/web/record_action.py` | 板端采集器（轮询 `/api/ai/keypoints`，不额外占 NPU） |
| `rk/ai/convert/extract_pose.py` | **公开数据集 → 训练样本**（视频/帧 → pose → npz） |
| `rk/web/mipi_webstream.py` | 新增 `GET /api/ai/keypoints`、`--ai-action-model`、`--ai-action-npz` |

模型输入输出（固定契约）：

```
输入  kps   float32 (1, 32, 17, 3)   # x,y = (px-髋中心)/框高；第 3 通道 = 有效标志
输出  logits float32 (1, 11)         # idle,fall,lying,climb,fight,run,handup,squat,swing,throw,photo
```

> `intrude`（越界）**不在模型里** —— 它是空间多边形判定，由 `ActionEngine` 用几何算，
> 与模型并行输出。

## 4. 全流程（板子/VM 上线后按顺序执行）

### 4.1 采数据（板子上）

```bash
cd /root/rk/web
P=/opt/miniforge3/envs/mlk-ov/bin/python

# 先确认接口活着
curl -s http://127.0.0.1:9012/api/ai/keypoints | head -c 300

$P record_action.py --label idle  --seconds 60 --out /root/rk/ai/data
$P record_action.py --label swing --seconds 60 --out /root/rk/ai/data
# ... 其余 9 类
$P record_action.py --stats --out /root/rk/ai/data
```

**采集协议**（直接决定模型好坏，别省）：

- `idle` 采最多（建议 200+ 段），且必须包含**误报源**：走路、弯腰捡东西、说话挥手、
  双手插兜、整理头发、伸懒腰、坐着双手放腿上；
- 每个动作 ≥ 60 段，换 2~3 个距离（近/中/远）、2 个朝向、**左右手各一遍**；
- 最好换人采，否则模型学的是"这个人"；
- 采集时画面里只站一个人（多人会串 tid）。

### 4.1b 公开数据集（补充样本，可选但强烈建议）

实测本机可达的几个（其余 HuggingFace / github.com / Google Drive 都不通）：

| 数据集 | 获取 | 覆盖的类 |
|---|---|---|
| **Penn Action** | `https://www.cis.upenn.edu/~kostas/Penn_Action.tar.gz`（3.23 GB，免注册） | `squats`→squat、`baseball_swing`/`golf_swing`/`tennis_forehand`→swing、`baseball_pitch`/`bowling`/`tennis_serve`→throw、`pull_ups`→climb |
| **UR Fall** | `http://fenix.ur.edu.pl/~mkepski/ds/uf.html`（70 个 mp4，`fall-*` 30、`adl-*` 40） | `fall`→跌倒、`adl`→idle（已自动剔除“躺下”片段） |

> Penn 的服务器**限制单连接**（23 KB/s），必须分段并发：
> `curl --ssl-no-revoke -r start-end`（不加 `--ssl-no-revoke` 会因吊销列表离线失败），12 路并发能到 ~3 MB/s。

**不要用数据集自带的关节标注**（Penn 是 13 关节、UR Fall 没骨架），而是用**板上同一个 pose 模型**
从原始帧抽 COCO-17，这样和现场分布一致：

```PowerShell
$P = "D:\envs\act\Scripts\python.exe"     # 轻量环境：onnxruntime+opencv+numpy+scipy
& $P rk/ai/convert/extract_pose.py --mode penn   --src D:\datasets\Penn_Action --out D:\datasets\action_data
& $P rk/ai/convert/extract_pose.py --mode urfall --src D:\datasets\URFall       --out D:\datasets\action_data
```

产物与 `record_action.py` **完全同格式**（`<out>/<label>/<tag>_0000.npz`），可以直接丢进训练。

### 4.2 训练（**TF 路径：本机就能跑**，不用 VM）

```bash
$ py="D:\ProgramData\anaconda3\envs\tf_gpu\python.exe"   # TF 2.10.1
$ & $py train_action_tf.py --data ./data --epochs 120 --out action_net_tf.h5
```

先跑通链路可以不带数据：`--synthetic --epochs 5`
（**合成数据只验证流程，训出来的模型没有意义**）。

> torch 版 `train_action.py` 结构等价，但它需要装了 torch 的环境（本机没有、VM 常离线），
> 日常请用 TF 版。两版的常量统一在 `action_spec.py`，权重格式（`action_net.npz`）完全一致。

### 4.3 导出 + 转换

```bash
$ & $py export_action_tf.py --ckpt action_net_tf.h5 --out action_net
#   产出 action_net.tflite（给 RKNN）+ action_net.npz（板上 CPU 兜底）
#   并自动做三方一致性校验（Keras / TFLite / numpy），diff 应为 ~1e-6

$ & $py convert_action_rknn.py --tflite action_net.tflite --data ./data --out action_net.rknn
#   没有 VM 时可先不转：直接拷 action_net.npz 到板上走 CPU（十几 ms/人）
```

### 4.4 部署（板子，**只重启一次**）

```bash
scp action_net.rknn action_net.npz afc03:/root/rk/ai/models/
```

启动参数加：

```bash
--ai-action-model /root/rk/ai/models/action_net.rknn \
--ai-action-npz  /root/rk/ai/models/action_net.npz
```

不传这两个参数 → 行为与现在**完全一致**（几何规则），所以可以随时回退。

## 5. 关键设计说明

**为什么归一化用「髋中心 + 框高」**
唯一与距离/画面位置/身材都无关的表示。人一走动，原点画会捡到镜头畸变；按肩宽归一会因
侧身失真。髋中心 + 框高是 ST-GCN 系的标准做法。

**为什么重采样到固定 32 帧**
AI 会丢帧，帧间隔不均匀。直接用"最后 N 帧"会把同一个动作因快慢不同判成两类；
按时间线性重采样后，快慢只体现为内容差异，不改变张量形状。

**为什么 10Hz 推理**
动作是秒级事件，10Hz 足够（一次前向 ~0.2ms，占 AI 线程 0.2%）。
再叠加概率 EMA（0.5）+ `hold=0.25s` 滞回，单帧抖动不会产生误报。

**三级兜底**
`rknn` → `numpy` → 几何规则。任何一级失败都自动降级，不会让动作识别整体消失。

## 6. 风险与验证点

| 风险 | 处理 |
|---|---|
| 数据量不足导致过拟合 | 每类 ≥60 段 + 增强（镜像/倒放/速度/噪声）+ 类别加权；先看混淆矩阵再上板 |
| INT8 量化掉点 | 校准集必须用真实采集骨架；不行就 `--no-quant` |
| RKNN 算子不支持 | 全网只有 MatMul/Conv/BN/ReLU/AvgPool/Gemm，正常一次过；`export_action_onnx.py` 已提前校验数值 |
| 上板后帧率影响 | 模型 <1ms/人；用 `/api/ai` 的 `infer_ms` 与 `ai fps` 复核 |
| 采集时误动/多人 | `record_action.py` 按最大框取主目标，换 tid 会清空缓冲 |

上板后必须先跑的两条自检：

```bash
/opt/miniforge3/envs/mlk-ov/bin/python /root/rk/ai/board/test_action_engine.py   # 17 例
curl -s http://127.0.0.1:9012/api/ai | head -c 400                              # backend=?
```
