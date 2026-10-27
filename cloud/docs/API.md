# 云端看板接口（v1.0）

服务端只监听 `127.0.0.1:9080`，外网统一走 nginx `location ^~ /api/`。

## 存储

| 内容 | 位置 |
|---|---|
| 报警 / 视频元数据 | **SQLite** `data/dash.db`（`alarms`、`clips`、`meta` 表，WAL） |
| 报警抓拍 | `data/shots/<id>.jpg`（按条数+字节滚动） |
| 事件视频 | `data/clips/<id>.mp4`（默认总上限 1GB，滚动删） |
| 瞬时状态（遥测/指令/灯） | `data/state.json`（只留这些，报警不再重复写 JSON） |

首次启动会把旧的 `state.json` 里的报警**自动迁移**到 SQLite
（日志会打 `migrated N alarms: state.json -> SQLite`）。

> **看不到数据？先跑一眼**（服务器上，不用停服务）：
>
> ```bash
> python3 /opt/csi-dashboard/db_check.py      # 表/行数/最近报警/视频总量/WAL
> ```
>
> 用的是 **SQLite**（不是 aaPanel 里的 MySQL）。库是 WAL 模式，
> 服务端每 10s 做一次 `PASSIVE` checkpoint、`-wal > 2MB` 时 `TRUNCATE`、
> 退出时也 `TRUNCATE`，所以**单独拷 `dash.db` 一个文件就是完整数据**。

```sql
-- alarms: id ts lvl label cn en tid score src note m img ack ack_ts n
--         last_ts last_note recovered clip clip_bytes clip_sec
-- clips : alarm_id ts sec bytes path
```

## 认证

| 调用方 | 方式 | 说明 |
|---|---|---|
| 板端代理 | `X-Token: <token>` | `config.json` 的 `token`，常量时间比较 |
| 浏览器 | `POST /api/login` 换取 HttpOnly Cookie `cd_sid` | 30 天；**401 不带 `WWW-Authenticate`** |
| 脚本/curl | `curl -u admin:<ui_pass>` 或 `X-UI-Pass: <ui_pass>` | 兼容用法 |

`ui_pass` 为空时不校验（不推荐）。

* `POST /api/login` `{"pass":"..."}` → `200 {"ok":true}` + `Set-Cookie: cd_sid=...`
* `POST /api/logout` → 清 Cookie
* 未登录返回 `401 {"ok":false,"login":true}`（**不带** Basic 挑战头，避免浏览器重试）

---

## 一、板端 → 云

### `POST /api/ingest`

心跳 + 遥测。请求体可用 `Content-Encoding: gzip`（代理默认压）。

```json
{
  "node": {"id":"afc03","name":"AFC03 IMX415","ver":"V45","ip":"192.168.1.136","mode":"1080p60"},
  "tel": {
    "link":  {"ok":true,"fps":59.6,"lat":27.3,"clients":1,"dev":"/dev/video22"},
    "cam":   {"cam_exp_ms":16.6,"cam_exp_max_ms":16.7,"cam_gain_db":14.7,"ev":0,
              "wb_r_pct":100,"wb_b_pct":100,"roi_pct":100,"res_mode":0,"fps":60},
    "img":   {"brightness":0,"contrast":1.0,"saturation":1.0,"hue":0,"gamma":1.0,
              "mirror":0,"flipv":0,"rotate":0,"scale":1.0,"quality":50,"fps":60},
    "pp":    {"PP_EN":0,"ADV_MODE":0,"BASIC_EN":0,"ADV_SOBEL_SH":8,"…":"…"},
    "ai":    {"enabled":true,"active":false,"source":"detect","fps":46,"persons":0,
              "det_conf":0.25,"kpt_conf":0.30,"tune":{"fall":1.0,"run":1.0,"swing":1.0,"throw":1.0}},
    "sys":   {"cpu":33.4,"npu":0,"gpu":12,"mem":24,"temp":52.7,"disk":42.2,"uptime":33912},
    "alarm": {"risk":0,"label":null,"cn":null,"tid":null},
    "health":{"warn":[],"crit":[],"ok":[]}
  }
}
```

* `tel` 支持**部分上报**：服务端按一层字典合并，缺的字段保留旧值
  （代理每 3 次心跳才带一次 `pp`）。
* `sys.cpu` 必须是数字（板端 `/api/sys` 返回的是 `{total,cores}`，代理取 `total`）。
* `health.ok`：**刚刚恢复正常**的健康项 label 列表（`link_down` / `fps_zero` /
  `fpga_err` / `disk_full` / `temp_high`）。服务端收到后把该 label 最新那条
  健康报警标成 `recovered`，下一次同项异常才会重新记一条。
  代理只在心跳送达后才清空这个队列，避免云端错过恢复事件。
* 返回值：`{"ok":true,"t":<server_ts>}`。

### `POST /api/alarm`

```json
{"label":"fall","cn":"跌倒","lvl":2,"src":"ai","tid":3,"score":0.91,
 "note":"","m":{"fps":59.6,"persons":1}}
```

返回 `{"ok":true,"id":"20261020-150127-001","dedup":false}`。

报警对象的对外字段（`/api/state`、`/api/history` 共用）：

| 字段 | 说明 |
|---|---|
| `img` / `url` | 是否有抓拍图、图地址 |
| `clip` / `clip_url` | 是否带事件视频、视频地址 |
| `clip_sec` / `clip_kb` | 视频时长（秒）/ 大小（KB） |
| `recovered` | 系统异常已恢复的时刻（仅 `src=health`） |
| `n` | 同回合合并次数（`×N`） |

* 服务端会按 `label` 统一成正式显示名（`FORMAL_CN`），例如 `swing → 挥击行为`、
  `fall → 跌倒事件`；`cn` 只作兜底。板端模型标签不变。
* 6s 内同 `label` 且未确认 → 合并（`dedup=true`，`n+1`），返回原 id。
* **系统异常（`src="health"`）是持续状态**：一次异常只保留**最早那一条**，
  恢复前重复上报只累加 `n`（`ts` 不刷新，另外记 `last_ts` / `last_note`），
  恢复后（`tel.health.ok`）再出同项异常才会新建记录。
  合并窗口 `health_hold_sec`（默认 3600s），兼作代理重启后的重复上报兜底。
* 每分钟最多 `max_rate` 条（默认 20），超出丢弃并记 `stats.dropped`。

### `POST /api/alarm/<id>/snap`

原始 JPEG 字节（`Content-Type: image/jpeg`），上限 `max_alarm_kb`（默认 600KB）。
成功 `{"ok":true,"bytes":23449}`。建议 640px / q55（约 25KB）。

### `POST /api/alarm/<id>/clip?sec=10.2`

事件视频（mp4），`Content-Type: video/mp4`，上限 `max_clip_mb`（默认 8MB）。
服务端只校验头部含 `ftyp`，落盘 `data/clips/<id>.mp4` 并写 SQLite `clips` 表。
成功 `{"ok":true,"bytes":57479}`。

* 视频总量超过 `max_clip_total_mb`（默认 **1024MB**）时从最旧的滚动删除，
  删掉后只把报警的 `clip` 标记清掉，事件记录保留。
* 报警不存在（已被滚动丢弃）时返回 400，不落盘。

### `GET /api/clip/<id>.mp4`

看板回放用（Cookie 鉴权）。支持 `Range`：

```
Range: bytes=0-99  ->  206 + Content-Range: bytes 0-99/57479
```

### `POST /api/live`

手动抓拍的原图，覆盖 `data/live.jpg`，`live.rev + 1`。
浏览器用 `GET /api/live.jpg?v=<rev>` 取。

### `GET /api/commands?since=<seq>&wait=<sec>`

长轮询取指令。`wait` 最大 25s；空闲时服务端挂起连接。

```json
{"ok":true,"seq":7,"cmds":[{"seq":7,"op":"params","p":{"brightness":25},"ts":1792479...}]}
```

### `POST /api/result`

```json
{"seq":7,"op":"params","ok":true,"msg":""}
```

服务端把该 seq 从 pending 移除，并保留最近 20 条结果给页面弹提示。

---

## 二、浏览器 → 云

### `GET /api/state?n=6`

```json
{"ok":true,"t":...,"ver":"1.0",
 "node":{...},
 "tel":{...},
 "lamp":{"state":"alarm","text":"报警","online":true,"age":2.1,
         "hb_ts":1792479665.4,"since":1792479687,"hold":180,"unacked":1,"alarms24":1,
         "risk":0,"focus":{"label":"fall","cn":"跌倒","tid":3,"ts":...},
         "notes":[]},
 "alarms":[{"id":"20261020-150127-001","ts":...,"age":20,"lvl":2,
            "label":"deploy_test","cn":"部署联调","tid":null,"score":0,
            "src":"test","note":"","m":{},"img":true,"ack":false,"n":1,
            "url":"/api/shot/20261020-150127-001.jpg"}],
 "unacked":1,"cmds":[...],"live":{"rev":1,"ts":...},
 "stats":{"alarms":1,"dropped":0,"uptime":123},"cfg":{"poll":5,...}}
```

`lamp.state` ∈ `ok | warn | alarm | offline`。
`lamp.hb_ts` 是最近一次心跳的服务器时间（epoch 秒，看板用它显示“最近心跳”），
`lamp.age` 是距今秒数。

### `GET /api/history`

按时间范围分页取报警（新→旧）。

| 参数 | 默认 | 说明 |
|---|---|---|
| `start` / `end` | 0 | epoch 秒，闭区间；0 表示不限 |
| `page` | 1 | 页码（从 1 开始） |
| `limit` | 20 | 每页条数，1~100（页面按「列数 × 5」传入，保证最多 5 行） |
| `unacked` | 0 | `1` 只看未确认 |
| `before` | 0 | 兼容旧用法：只取早于该时间的记录 |

```json
{"ok":true,"alarms":[...],"total":8,"page":1,"pages":1}
```

页面展示的相对时间由浏览器按 `ts` 实时计算（秒/分钟/小时/天/月+天）。

### `GET /api/stats`

报警趋势数据（「报警统计」卡片的两张小图），约 1KB，前端 ≤1 次/分钟拉取。

```json
{"ok":true,
 "hours":{"t0":1792450000,"n":[0,0,1,...24 个],"crit":[0,...]},
 "days":{"t0":1791900000,"n":[0,0,0,0,0,0,8]},
 "total24":8,"total7":8,
 "labels":[{"label":"swing","cn":"挥击行为","n":8}]}
```

| 字段 | 说明 |
|---|---|
| `hours.n[i]` | 最近 24 个整点小时间隔内的报警数（`i=23` 为当前小时） |
| `hours.crit[i]` | 同上，但只统计高等级（`lvl>=2`） |
| `days.n[i]` | 最近 7 天（自然日）报警数，`i=6` 为今天 |
| `total24` / `total7` | 汇总值，用于卡片标题「共 N 条」 |

### `POST /api/cmd`

```json
{"op":"fpga","p":{"cam_exp_ms":16.6,"cam_gain_db":9.6}}
```

返回 `{"ok":true,"seq":N}`。服务端做白名单和范围裁剪，板端还会再裁一次。

| op | p | 对应板端 |
|---|---|---|
| `params` | 亮度/对比度/饱和度/色相/伽马/镜像/翻转/旋转/缩放/质量/帧率，或 `{"reset":true}` | `POST /api/params` |
| `fpga` | 物理量 `cam_exp_ms`/`cam_gain_db`/`ev`/`wb_r_pct`/`wb_b_pct`/`roi_pct`/`fps`，或寄存器名（`PP_EN`、`ADV_*`、`BASIC_*`）、`preset` | `POST /api/fpga` |
| `ai` | `enabled`/`source`（`raw`/`detect`/`ai`）/`ai_fps`/`det_conf`/`nms_thres`/`kpt_conf`/`kpt_margin`/`kpt_scale_max`/`roi_expand`/`det_interval`/`pose_budget`/`max_persons`/`show_*`/`tune`/`zone`/`preset` | `POST /api/ai` |
| `mode` | `{"id":"4k25"}` | `POST /api/mode` |
| `jpeg` | `{"hw":true}` | `POST /api/jpeg` |
| `snap` | `{}`（服务端补 `w=800`） | 抓图 + `POST /api/live` |
| `preset` / `ppoff` | 同 `fpga` | `POST /api/fpga` |
| `reboot` | 需 `allow_reboot=true`；板端当前**未提供**接口 | — |

### `POST /api/ack`

`{"id":"..."}` 或 `{"all":true}` → `{"ok":true,"acked":1}`。

### `GET /api/shot/<id>.jpg`

报警缩略图，`Cache-Control: immutable`（一年）。浏览器靠登录 Cookie 鉴权。

### `GET /api/live.jpg`

最近一次手动抓拍，`no-store`。

### `GET /api/ext` / `POST /api/ext/<name>`

模块列表 / 调用扩展。未实现返回 `501 {"ok":false,"reserved":true}`。

### `POST /api/test`

仅 `demo` 或 `allow_test` 时可用，注入一条测试报警（不带图）。

---

## 三、扩展插件

`ext/<name>.py`：

```python
INFO = {"title": "云台控制", "desc": "yaw/pitch 速度与回零"}

def handle(payload, ctx):
    op = payload.get("op")
    if op == "center":
        ctx["queue"]("gimbal", {"op": "center"})   # 直接排一条板端指令
        return {"ok": True, "queued": True}
    return {"ok": False, "error": "unknown op"}
```

`ctx` = `{"state": 内存状态, "queue": 入队函数, "cfg": 配置}`。
主程序不重启也能生效（放在 `ext/` 后重启服务即可）。
