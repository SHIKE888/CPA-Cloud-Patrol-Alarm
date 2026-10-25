# -*- coding: utf-8 -*-
"""公开数据集 → 训练样本：用**板上同一个 pose 模型**把视频抽成 COCO-17 骨架。

为什么不用数据集自带的关节标注
------------------------------
Penn Action 是 13 关节、UR Fall 根本没有骨架。硬把别的拓扑映射到 COCO-17 会让
模型去学"拓扑差异"而不是动作。这里改成：喂**原始视频/帧** → 跑 `yolov8n-pose.onnx`
（板上同一个模型）→ 得到和现场完全同分布的 COCO-17，再走 `action_seq.py` 的
归一化/切窗。这样公开数据可以直接混进训练集。

用法
----
    P=D:\\envs\\act\\Scripts\\python.exe

    # Penn Action（解压后的根目录，含 frames/ 和 labels/）
    & $P extract_pose.py --mode penn --src D:\\datasets\\Penn_Action \\
        --out D:\\datasets\\action_data

    # UR Fall（跌倒 + 日常）
    & $P extract_pose.py --mode urfall --src D:\\datasets\\URFall \\
        --out D:\\datasets\\action_data

    # 通用：子目录名 = 标签，里面放视频
    & $P extract_pose.py --mode video --src D:\\my_videos --out ...\\action_data
"""
import argparse
import glob
import json
import os
import sys
import time

import cv2
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(_HERE, '..', 'board'), _HERE):
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

from action_seq import T_LEN, normalize_frame, resample      # noqa: E402
from action_spec import ACTION_CLASSES                        # noqa: E402
from det_core import letterbox_rgb, _decode_heads             # noqa: E402

# Penn Action 的 15 类 → 我们的标签；None = 用不上，跳过
# ? mat 里的 action 字段是**单数**（squat / bowl / pullup），不是文件名里
#   那种 squats / bowling / pull_ups；之前写错导致 squat、climb 一个样本没出。
PENN_MAP = {
    'squat': 'squat',           # 231 段
    'baseball_swing': 'swing',
    'golf_swing': 'swing',
    'tennis_forehand': 'swing',
    'baseball_pitch': 'throw',
    'bowl': 'throw',            # 220 段
    'tennis_serve': 'throw',
    'pullup': 'climb',          # 199 段（引体向上≈向上攀爬）
    'jumping_jacks': None,      # 不在我们的类别里
    'clean_and_jerk': None,
    'bench_press': None,
    'pushup': None,
    'situp': None,              # 仰卧起坐≈倒地，会污染 fall
    'strum_guitar': None,
    'jump_rope': None,
}


# ---------------------------------------------------------------- 进度

class Progress(object):
    """实时进度：stdout 单行刷新 + 可选 JSON 文件（后台跑时靠它监控）。

    PowerShell 的 `*>` 重定向会缓冲子进程输出，看不到实时行；所以
    进程内同时写一个 progress.json，外部只要轮询这个文件就行。
    """

    def __init__(self, path=None, quiet=False):
        self.path = path
        self.quiet = quiet
        self.t0 = time.time()
        self.state = {}
        self._last = 0.0
        self._last_frame = -1

    def update(self, force=False, **kw):
        self.state.update(kw)
        now = time.time()
        if not force and (now - self._last) < 0.5:
            return
        self._last = now
        self.state['elapsed'] = round(now - self.t0, 1)
        el = max(self.state['elapsed'], 1e-3)
        fr = self.state.get('frame', 0)
        if fr and fr != self._last_frame:
            self._last_frame = fr
        fps = fr / el if fr else 0.0
        parts = ['[%6.1fs]' % el]
        for k in ('stage', 'i', 'n', 'file', 'frame', 'frames', 'kpt'):
            if k in self.state:
                parts.append('%s=%s' % (k, self.state[k]))
        if fps:
            parts.append('%.1f fps' % fps)
        smp = self.state.get('samples')
        if smp:
            parts.append('samples=' + ','.join('%s:%d' % (a, b) for a, b in sorted(smp.items())))
        if not self.quiet:
            sys.stdout.write('\r' + '  '.join(parts)[:150].ljust(150))
            sys.stdout.flush()
        if self.path:
            try:
                with open(self.path, 'w', encoding='utf-8') as fp:
                    json.dump(self.state, fp, ensure_ascii=False)
            except Exception:                             # noqa: BLE001
                pass

    def done(self):
        if not self.quiet:
            sys.stdout.write('\n')
            sys.stdout.flush()


# ---------------------------------------------------------------- pose 模型

class PoseONNX(object):
    """yolov8n-pose.onnx 的极简推理（letterbox + NMS + 取最大人）。

    解码直接复用板上的 `det_core.letterbox_rgb` / `_decode_heads`：
    这个 onnx 是 airockchip 风格的 4 输出布局（3 个 stride 头 + 单独的关键点张量），
    自己写解码很容易和板上不一致 —— 用同一份代码就不会跑偏。
    """

    def __init__(self, path, imgsz=640, conf=0.35, iou=0.5):
        import onnxruntime as ort
        so = ort.SessionOptions()
        # 28 逻辑核全开反而抢不到，实测 CPU 单帧 345ms；8 线程足够
        so.intra_op_num_threads = 8
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        avail = ort.get_available_providers()
        # DirectML = 用上显卡（装 onnxruntime-directml 即有），比 CPU 快十几倍
        self.prov = ('DmlExecutionProvider' if 'DmlExecutionProvider' in avail
                     else 'CPUExecutionProvider')
        self.sess = ort.InferenceSession(path, so, providers=[self.prov])
        self.inp = self.sess.get_inputs()[0]
        self.imgsz = int(imgsz)
        self.conf = float(conf)
        self.iou = float(iou)
        print('onnx 后端: %s' % self.prov)

    def __call__(self, img_bgr):
        """返回 (box[x1,y1,x2,y2] 像素, kps(17,3) 像素+置信度) 或 (None, None)。"""
        size = self.imgsz
        rgb, scale, px, py = letterbox_rgb(img_bgr, (size, size))
        blob = rgb.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        outs = self.sess.run(None, {self.inp.name: blob})
        objs = _decode_heads(outs, self.conf, keep_cls=[0], want_kps=True,
                             input_size=size)
        if not objs:
            return None, None
        boxes = [[o.box[0], o.box[1], o.box[2] - o.box[0], o.box[3] - o.box[1]]
                 for o in objs]
        scores = [float(o.score) for o in objs]
        idx = cv2.dnn.NMSBoxes(boxes, scores, self.conf, self.iou)
        if len(idx) == 0:
            return None, None
        idx = np.asarray(idx).ravel()
        # 取面积最大的人（与 record_action.py 的 pick_primary 一致）
        areas = np.array([boxes[i][2] * boxes[i][3] for i in idx])
        o = objs[int(idx[int(np.argmax(areas))])]
        if o.kps is None:
            return None, None
        b = o.box
        box = np.array([(b[0] - px) / scale, (b[1] - py) / scale,
                        (b[2] - px) / scale, (b[3] - py) / scale], np.float32)
        kps = np.asarray(o.kps, np.float32).copy()
        kps[:, 0] = (kps[:, 0] - px) / scale
        kps[:, 1] = (kps[:, 1] - py) / scale
        return box, kps


# ---------------------------------------------------------------- 切窗

def torso_deg(kps, box):
    """躯干与竖直方向夹角（度）。用来给 idle 剔除"躺着"的片段。"""
    if kps is None:
        return 90.0
    try:
        sx = (kps[5, 0] + kps[6, 0]) / 2
        sy = (kps[5, 1] + kps[6, 1]) / 2
        hx = (kps[11, 0] + kps[12, 0]) / 2
        hy = (kps[11, 1] + kps[12, 1]) / 2
        if kps[5, 2] <= 0 or kps[11, 2] <= 0:
            return 90.0
        return abs(np.degrees(np.arctan2(sx - hx, -(sy - hy))))
    except Exception:                                     # noqa: BLE001
        return 90.0


def max_frame_jump(seg):
    """窗口内相邻帧的最大关节位移（身高/秒）。用来剥掉“跟踪/检测跳变”。

    UR Fall 的 adl-*-cam0 是**深度相机**画面，YOLO 在灰度深度图上姿态很脏，
    会出现单帧几十身高/秒的假速度，不滤掉会把 idle 教成“抖得厉害”。
    """
    jump = 0.0
    for a, b in zip(seg[:-1], seg[1:]):
        k0, k1 = a[1], b[1]
        bh = max(1.0, float(a[2][3] - a[2][1]))
        m = (k0[:, 2] > 0) & (k1[:, 2] > 0)
        if not m.any():
            continue
        d = np.hypot(k1[m, 0] - k0[m, 0], k1[m, 1] - k0[m, 1]) / bh
        if d.max() > jump:
            jump = float(d.max())
    return jump


def windows_from_frames(frames, label, args, tag):
    """frames: list[(t, kps, box)] → 若干 (T,17,3) 样本。

    ❗ 公开数据的**视频级标签不能直接用**：
    UR Fall 的 fall-xx 视频 5~10 秒，真正倒下只有 1~2 秒，整段标成 fall
    等于把“站着”也当跌倒教 → 模型只能学成“永远空闲”。实测过：fall 的 22 个
    验证样本全被判成 idle，val_acc 0.80 是假象。
    所以这里用“躯干角从直立→躺下”的**转变**筛窗 —— 几何只当分组工具，
    不拿它当分类器（离线无实时性约束，判转变很稳）。
    """
    out = []
    n = len(frames)
    if n < T_LEN:
        return out
    for s in range(0, n - T_LEN + 1, max(1, args.stride)):
        seg = frames[s:s + T_LEN]
        n_valid = float(np.mean([(f[1][:, 2] > 0).sum() for f in seg]))
        if n_valid < args.min_kpt:
            continue
        angs = np.array([torso_deg(f[1], f[2]) for f in seg], np.float32)
        maxj = getattr(args, 'max_jump', 0.0)
        if maxj and maxj > 0 and max_frame_jump(seg) > maxj:
            continue                                   # 帧间跳变 → 跟踪/检测炸了
        if label == 'idle' and args.idle_torso_max > 0:
            # 日常视频里常混着"躺下/上床"，不能当 idle 教
            if float(angs.max()) > args.idle_torso_max:
                continue
        if label == 'fall' and getattr(args, 'require_transition', True):
            # 窗口内必须真的倒下：先直立(<35°) 后躺下(>55°)
            if not (float(angs.max()) > 55.0 and float(angs.min()) < 35.0):
                continue
        norm = [(f[0], normalize_frame(f[1], f[2])) for f in seg]
        out.append(resample(norm, T_LEN))
        if args.max_per_clip and len(out) >= args.max_per_clip:
            break
    return out


def save_samples(samples, label, out_dir, tag):
    d = os.path.join(out_dir, label)
    os.makedirs(d, exist_ok=True)
    n = 0
    for seq in samples:
        fn = os.path.join(d, '%s_%04d.npz' % (tag, n))
        np.savez(fn, seq=seq.astype(np.float32), label=np.array(label))
        n += 1
    return n


def frames_from_video(path, pose, every=1, prog=None, tag=''):
    cap = cv2.VideoCapture(path)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    out, i = [], 0
    while True:
        ok, img = cap.read()
        if not ok:
            break
        if i % every == 0:
            box, kps = pose(img)
            if box is not None:
                out.append((i / 30.0, kps, box))
            if prog is not None:
                prog.update(file=tag, frame=i, frames=total,
                            kpt=0 if box is None else int((kps[:, 2] > 0).sum()))
        i += 1
    cap.release()
    return out


# ---------------------------------------------------------------- 三种来源

def run_penn(args, pose, prog):
    root = args.src
    lab_dir = os.path.join(root, 'labels')
    frm_dir = os.path.join(root, 'frames')
    if not os.path.isdir(lab_dir):
        raise SystemExit('找不到 %s' % lab_dir)
    from scipy.io import loadmat
    total = {}
    clips = sorted(os.listdir(lab_dir))
    n_skip = 0
    for ci, fn in enumerate(clips):
        if not fn.endswith('.mat'):
            continue
        try:
            m = loadmat(os.path.join(lab_dir, fn), squeeze_me=True,
                        struct_as_record=False)
            # ? Penn 的 mat 是**扁平**的（action/pose/x/y/visibility/bbox...），
            #   不是传说中嵌在 annotation 结构里；两种都兼容一下。
            if 'annotation' in m:
                action = str(m['annotation'].action)
            else:
                action = str(m['action'])
        except Exception as e:                            # noqa: BLE001
            n_skip += 1
            if n_skip <= 5:
                print('[skip] %s: %s' % (fn, e))
            continue
        label = PENN_MAP.get(action)
        if label is None:
            continue
        only = getattr(args, 'only', None)
        if only and action not in only and label not in only:
            continue
        tag = os.path.splitext(fn)[0]
        fdir = os.path.join(frm_dir, tag)
        if not os.path.isdir(fdir):
            continue
        files = sorted(glob.glob(os.path.join(fdir, '*.jpg')))
        prog.update(force=True, stage='penn', i=ci + 1, n=len(clips),
                    file='%s(%s)' % (tag, action), frame=0)
        frames = []
        for i, fp in enumerate(files):
            img = cv2.imread(fp)
            if img is None:
                continue
            box, kps = pose(img)
            if box is not None:
                frames.append((i / 30.0, kps, box))
            prog.update(file='%s(%s)' % (tag, action), frame=i, frames=len(files),
                        kpt=0 if box is None else int((kps[:, 2] > 0).sum()))
        samples = windows_from_frames(frames, label, args, tag)
        if samples:
            total[label] = total.get(label, 0) + save_samples(
                samples, label, args.out, tag)
        prog.update(force=True, stage='penn', samples=dict(total))
    if n_skip:
        print('（%d 个标注解析失败，已跳过）' % n_skip)
    return total


def run_urfall(args, pose, prog):
    files = sorted(glob.glob(os.path.join(args.src, '*.mp4')))
    if not getattr(args, 'allow_cam0', False):
        # cam0 = 深度相机（灰度），姿态质量太差；只保留 RGB 的 cam1
        keep = [f for f in files if '-cam1' in os.path.basename(f).lower()]
        if keep:
            files = keep
    total = {}
    for i, fp in enumerate(files):
        name = os.path.basename(fp).lower()
        label = 'fall' if name.startswith('fall') else 'idle'
        tag = os.path.splitext(os.path.basename(fp))[0]
        prog.update(force=True, stage='urfall', i=i + 1, n=len(files),
                    file=tag, frame=0)
        frames = frames_from_video(fp, pose, args.every, prog, tag)
        samples = windows_from_frames(frames, label, args, tag)
        if samples:
            total[label] = total.get(label, 0) + save_samples(
                samples, label, args.out, tag)
        prog.update(force=True, stage='urfall', samples=dict(total))
    return total


def run_video(args, pose, prog):
    """子目录名 = 标签。"""
    total = {}
    for label in sorted(os.listdir(args.src)):
        d = os.path.join(args.src, label)
        if not os.path.isdir(d) or label not in ACTION_CLASSES:
            continue
        vids = []
        for ext in ('*.mp4', '*.avi', '*.MOV', '*.mov'):
            vids += glob.glob(os.path.join(d, ext))
        for k, fp in enumerate(sorted(vids)):
            tag = os.path.splitext(os.path.basename(fp))[0]
            prog.update(force=True, stage='video', i=k + 1, n=len(vids),
                        file='%s/%s' % (label, tag), frame=0)
            frames = frames_from_video(fp, pose, args.every, prog, tag)
            samples = windows_from_frames(frames, label, args, tag)
            if samples:
                total[label] = total.get(label, 0) + save_samples(
                    samples, label, args.out, tag)
            prog.update(force=True, stage='video', samples=dict(total))
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', default='penn', choices=['penn', 'urfall', 'video'])
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', default=r'D:\datasets\action_data')
    ap.add_argument('--onnx', default='')
    ap.add_argument('--imgsz', type=int, default=640)
    ap.add_argument('--conf', type=float, default=0.35)
    ap.add_argument('--iou', type=float, default=0.5)
    ap.add_argument('--stride', type=int, default=8, help='切窗步长(帧)')
    ap.add_argument('--every', type=int, default=1, help='视频抽帧间隔')
    ap.add_argument('--min-kpt', type=int, default=9,
                    help='窗口内平均有效关键点数下限')
    ap.add_argument('--max-per-clip', type=int, default=40,
                    help='单个视频最多切几个窗口(0=不限)')
    ap.add_argument('--idle-torso-max', type=float, default=45.0,
                    help='idle 样本剔除躯干角超过该值的窗口(排除"躺下")')
    ap.add_argument('--no-require-transition', dest='require_transition',
                    action='store_false',
                    help='关掉 fall 的“必须发生倒下”筛选（不建议）')
    ap.add_argument('--max-jump', type=float, default=1.5,
                    help='帧间最大关节位移(身高)；超过视为跟踪/检测跳变，丢弃该窗（0=不过滤）')
    ap.add_argument('--allow-cam0', action='store_true',
                    help='允许使用 UR Fall 的深度相机视频(cam0)；默认只用 RGB(cam1)')
    ap.add_argument('--progress', default='',
                    help='进度 JSON 路径（后台跑时轮询它看实时进度）')
    ap.add_argument('--only', nargs='+', default=None,
                    help='只处理指定动作名或目标标签，如 --only squat pullup')
    args = ap.parse_args()

    onnx = args.onnx or os.path.join(_HERE, '..', 'models', 'yolov8n-pose.onnx')
    onnx = os.path.abspath(onnx)
    if not os.path.isfile(onnx):
        raise SystemExit('找不到 pose 模型: %s' % onnx)
    pose = PoseONNX(onnx, args.imgsz, args.conf, args.iou)
    prog = Progress(args.progress or os.path.join(args.out, 'progress.json'))
    print('pose 模型: %s' % onnx)
    print('模式 %s  源 %s  输出 %s' % (args.mode, args.src, args.out))

    total = {'penn': run_penn, 'urfall': run_urfall, 'video': run_video}[args.mode](
        args, pose, prog)
    prog.done()
    print('-' * 60)
    for k in sorted(total):
        print('  %-8s %5d 段' % (k, total[k]))
    print('  合计     %5d 段  -> %s' % (sum(total.values()), args.out))
    with open(os.path.join(args.out, 'extract_summary.json'), 'w',
              encoding='utf-8') as fp:
        json.dump(total, fp, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
