#!/bin/sh
# 把板上"当前这一刻"的可用状态固化成快照 -> /root/rk/deploy/state_snapshot.json
#
# 为什么需要它：
#   - 网页参数(19 项 dual/depth_fov/...)、AI 参数、云台参数本来就写在
#     /root/rk/web/state.json 里，服务启动时 ParamStore 会自动恢复 —— 不用管。
#   - 但**相机物理量**(曝光/增益/EV/白平衡/有效画面)只写进 FPGA 寄存器，
#     掉电即失效，开机回的是初始化表的值 —— 这部分必须靠快照 + cam-restore.service 回写。
#   - 标定文件 stereo_calib.json 在磁盘上，也一并记录指纹方便核对。
#
# 用法：在网页上调好参数后，板上执行  sh /root/rk/deploy/save_state.sh
# 回写：开机由 cam-restore.service 自动调用 restore_cam.sh（也可手工执行）
set -u
OUT=/root/rk/deploy/state_snapshot.json
PY=/opt/miniforge3/envs/mlk-ov/bin/python
PORT=9012

curl -sf -m 8 "http://127.0.0.1:$PORT/api/fpga"   -o /tmp/_snap_fpga.json   || { echo "取 /api/fpga 失败"; exit 1; }
curl -sf -m 8 "http://127.0.0.1:$PORT/api/params" -o /tmp/_snap_params.json || echo "{}" > /tmp/_snap_params.json
curl -sf -m 8 "http://127.0.0.1:$PORT/api/status" -o /tmp/_snap_status.json || echo "{}" > /tmp/_snap_status.json

$PY - "$OUT" <<'PY'
import json, os, sys, time
out = sys.argv[1]
fpga = json.load(open("/tmp/_snap_fpga.json"))
try:
    params = json.load(open("/tmp/_snap_params.json"))
except Exception:
    params = {}
try:
    st = json.load(open("/tmp/_snap_status.json"))
except Exception:
    st = {}

phys = fpga.get("phys") or {}
CAM_KEYS = ["cam_exp_ms", "cam_gain_db", "ev", "wb_r_pct", "wb_b_pct", "roi_pct"]
cam = {k: phys[k] for k in CAM_KEYS if k in phys}

# 标定文件指纹（深度引擎按 mtime 热加载，这里只做记录/核对）
calib = {}
cp = "/root/rk/web/stereo_calib.json"
if os.path.exists(cp):
    try:
        d = json.load(open(cp))
        calib = {"path": cp,
                 "created": d.get("created"),
                 "image_size": d.get("image_size"),
                 "baseline_m": (d.get("stereo") or {}).get("baseline_m"),
                 "rms": (d.get("stereo") or {}).get("rms"),
                 "fx": ((d.get("left") or {}).get("K") or [[None]])[0][0]}
    except Exception as e:
        calib = {"path": cp, "err": str(e)}

mode_env = ""
try:
    mode_env = open("/root/rk/deploy/mode.env").read().strip().replace("\n", " ")
except Exception:
    pass

snap = {
    "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    "fpga_ver": (st.get("fpga") or {}).get("ver") if isinstance(st.get("fpga"), dict) else st.get("ver"),
    "res_mode": phys.get("res_mode"),
    # ★ 真正需要开机回写的部分
    "cam": cam,
    # 以下仅作记录：服务端 ParamStore / state.json 已经自动恢复它们
    "params": params,
    "note": "cam 由 cam-restore.service 在上电后回写；params/ai/gimbal 由 state.json 自动恢复",
    "mode_env": mode_env,
    "calib": calib,
}
json.dump(snap, open(out, "w"), indent=1, ensure_ascii=False)
print("已固化 -> %s" % out)
print("  相机物理量 : %s" % json.dumps(cam, ensure_ascii=False))
print("  res_mode   : %s   mode.env: %s" % (phys.get("res_mode"), mode_env))
print("  网页参数   : %d 项（本就存在 state.json，重启自动恢复）" % len(params))
print("  标定       : 基线 %s m / RMS %s px / 创建 %s"
      % (calib.get("baseline_m"), calib.get("rms"), calib.get("created")))
PY
