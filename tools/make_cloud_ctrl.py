# -*- coding: utf-8 -*-
"""生成云端版控制台 cloud/static/ctrl.html（部署到 https://ros.absozero.cn/ctrl）。

背景
----
板子自己的服务端完全不动：`http://<板子IP>/` 还是原来那份 `console.html`。
这里只是把同一份页面**复制**一份放到云端，让它：

  · 用和看板一样的密码逻辑（POST /api/login，HttpOnly cookie `cd_sid`，默认 admin）
  · 从 `/api/lan` 拿到板子自己上报的局域网 IP，逐个探测，选第一个能连的
  · 把地址自动填进「连接」框并自动连接（操作依然走局域网，画面/参数直连板子）
  · 原有上电启动遮罩（#bootMask）保留，只是把轮询地址改成板子地址
  · 连不上就跳 /ctrl/offline（云端版专属离线页）

为什么用生成而不是把 320KB 再抄一份入库
----------------------------------------
`rk/relay/web/console.html` 是唯一真源，复制一份进仓库必然漂移。所以这里做
**文本级替换**生成，每处替换都断言必须命中 —— 一旦 console.html 的结构变了，
生成会直接报错，而不是悄悄产出一个半坏的页面。

用法
----
    python tools/make_cloud_ctrl.py            # 写 cloud/static/ctrl.html
    python tools/make_cloud_ctrl.py --check    # 只校验、不写文件
"""

import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "rk", "relay", "web", "console.html")
OUT = os.path.join(ROOT, "cloud", "static", "ctrl.html")
# 页面里以相对路径引用的静态资源，必须一起搬到云端，否则：
#   <script src="vendor/roslib.min.js"> 404 -> ROSLIB is not defined
#   -> 地图页初始化直接抛错（视频页看着正常，很容易漏）
VENDOR = ["vendor/roslib.min.js"]


# ---------------------------------------------------------------- 备案信息条
# 按备案规范：网站底部需展示 ICP 备案号与公安网备号（公安备需带官方图标）。
# 作为 body 的最后一个 flex 子项，不遮挡任何内容；同时把视频工作台那两处
# 写死的 calc(100vh - 128px) 改成 -150px（128 + 22），否则底部会被裁掉 22px。
BEIAN = r"""
<footer id="ctrlBeian">
  <a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener">陇ICP备2024013668号</a>
  <a href="http://www.beian.gov.cn/portal/registerSystemInfo?recordcode=%2062082102202094"
     target="_blank" rel="noopener"><img
     src="https://beian.mps.gov.cn/web/assets/logo01.6189a29f.png"
     alt="公安网备">甘公网安备62082102202094号</a>
</footer>
"""


# ---------------------------------------------------------------- 注入的引导层
# 放在 <body> 之后、页面脚本之前：
#   1) 登录层（密码逻辑与看板一致）
#   2) 解析板子地址 + 自动连接
#   3) 给启动遮罩一个 CTRL_BASE（遮罩脚本紧跟其后，靠 window.CTRL_BASE 拼地址）
BOOT = r"""
<!-- ================= 云端版引导层（由 tools/make_cloud_ctrl.py 生成，勿手改） =================
     把「页面从云端加载」和「操作走局域网」这两件事接起来：
       · 密码：POST /api/login → HttpOnly cookie cd_sid（和看板同一套，默认 admin）
       · 板子地址：GET /api/lan 拿板端 cloud-agent 上报的局域网 IP 列表，逐个探测
       · 探测成功 → 自动填「连接」框 + 自动连接；失败 → 跳 /ctrl/offline
     ======================================================================================= -->
<style>
#ctrlLogin{position:fixed; inset:0; z-index:11000; display:flex;
  align-items:center; justify-content:center;
  background:radial-gradient(120% 100% at 50% 0%, #131c2b 0%, #080b11 55%, #04060a 100%);}
#ctrlLogin[hidden]{display:none}
#ctrlLogin .cl-box{width:min(360px,92vw); padding:26px 26px 20px; border-radius:16px;
  background:#12161d; border:1px solid #2a3340; box-shadow:0 24px 70px rgba(0,0,0,.7);}
#ctrlLogin .cl-title{font-size:15.5px; font-weight:700; color:#fff; line-height:1.5}
#ctrlLogin .cl-sub{color:#8b9bb0; font-size:12.5px; margin:4px 0 14px}
#ctrlLogin input{width:100%; box-sizing:border-box; background:#0c131b; color:#e6eef8;
  border:1px solid #2a3340; border-radius:9px; padding:10px 12px; font-size:14px; outline:none}
#ctrlLogin input:focus{border-color:#4ea1ff}
#ctrlLogin button{width:100%; margin-top:12px; padding:10px 0; border:none; border-radius:9px;
  background:#2f7fe0; color:#fff; font-size:14px; font-weight:600; cursor:pointer}
#ctrlLogin button:hover{background:#3c8bed}
#ctrlLogin .cl-err{color:#ff6b6b; font-size:12.5px; min-height:18px; margin-top:8px}
#ctrlLogin .cl-tip{color:#5d6b7d; font-size:11.5px; margin-top:10px; line-height:1.6}
i.cl-badge{font-style:normal; font-size:11px; color:#8fd0ff; border:1px solid #2b6ea8;
  background:#0f2740; border-radius:6px; padding:1px 6px; margin-left:8px; vertical-align:middle}
/* ---- 备案信息条（页脚）---- */
#ctrlBeian{flex:none; display:flex; align-items:center; justify-content:center; gap:18px;
  height:22px; font-size:11.5px; color:#6b7a8d; background:#0a0e14;
  border-top:1px solid #1c2430; white-space:nowrap; overflow:hidden}
#ctrlBeian a{color:#6b7a8d; text-decoration:none; display:inline-flex;
  align-items:center; gap:5px}
#ctrlBeian a:hover{color:#9fb0c4; text-decoration:underline}
#ctrlBeian img{height:13px; width:auto; display:block}
/* 页脚占 22px：把视频工作台写死的高度计算同步扣掉，避免底部被裁 */
@media(min-width:1101px){
  #viewVideo #colLeft{height:calc(100vh - 150px); max-height:calc(100vh - 150px)}
  #viewVideo #colRight{max-height:calc(100vh - 150px)}
}
</style>

<div id="ctrlLogin" hidden>
  <form class="cl-box" id="clForm">
    <div class="cl-title">云端智联定点巡航安防预警系统</div>
    <div class="cl-sub">控制台 · 请输入访问密码</div>
    <input type="password" id="clPass" autocomplete="current-password" placeholder="密码">
    <button type="submit">进入控制台</button>
    <div class="cl-err" id="clErr"></div>
  </form>
</div>

<script>
/* 云端版引导：登录 → 查板子地址 → 探测 → 自动连接 →（失败则跳离线页） */
(function () {
  var loginEl = document.getElementById('ctrlLogin');
  var passEl  = document.getElementById('clPass');
  var errEl   = document.getElementById('clErr');
  var started = false;
  var tries = 0;

  function step(t) {
    var e = document.getElementById('bmStep');
    if (e) e.textContent = t;
  }
  function offline(reason) {
    location.replace('/ctrl/offline?r=' + encodeURIComponent(reason || ''));
  }
  function showLogin(msg) {
    if (loginEl) loginEl.hidden = false;
    if (msg && errEl) errEl.textContent = msg;
    if (passEl) setTimeout(function () { passEl.focus(); }, 80);
  }

  function probe(base, ms) {
    var ctl = window.AbortController ? new AbortController() : null;
    var tm = setTimeout(function () { if (ctl) ctl.abort(); }, ms);
    return fetch(base + '/api/ping', { cache: 'no-store',
                                       signal: ctl ? ctl.signal : undefined })
      .then(function (r) { clearTimeout(tm); return !!r.ok; })
      .catch(function () { clearTimeout(tm); return false; });
  }

  function pickBoard(lan) {
    var port = lan.web_port || 80;
    var ips = (lan.ips && lan.ips.length) ? lan.ips.slice() : (lan.ip ? [lan.ip] : []);
    // 上次连通的地址优先：多网口时能省掉几轮探测。
    // 只在本轮上报列表里重排，不把已下线的旧地址当候选（否则白发一个 2.5s 超时）。
    try {
      var last = localStorage.getItem('ctrl_base') || '';
      var host = last.replace(/^https?:\/\//, '').split(':')[0];
      var at = host ? ips.indexOf(host) : -1;
      if (at > 0) { ips.splice(at, 1); ips.unshift(host); }
    } catch (e) {}
    if (!ips.length) return Promise.resolve(null);
    var i = 0;
    function next() {
      if (i >= ips.length) return Promise.resolve(null);
      var ip = ips[i++];
      var base = 'http://' + ip + (port == 80 ? '' : ':' + port);
      step('正在连接 ' + ip + ' …');
      return probe(base, 2500).then(function (ok) { return ok ? base : next(); });
    }
    return next();
  }

  function bind(board) {
    window.CTRL_BASE = board;
    var ws = board.replace(/^http/, 'ws') + '/rosbridge';
    try {
      // 地图页的 rosbridge 也要指向板子（云端页面没有同源 /rosbridge）
      localStorage.setItem('ros_ws', ws);
      localStorage.setItem('ctrl_base', board);   // 下次打开优先探测这个地址
    } catch (e) {}
    var inp = document.getElementById('vAddr');
    if (inp) inp.value = board;
    step('正在建立画面连接…');
    // 页面脚本在 body 末尾才定义 relayVideoActivate / __ctrlMapConnect，轮询等它们就绪
    var n = 0;
    var iv = setInterval(function () {
      if (++n > 200) { clearInterval(iv); return; }
      if (typeof window.relayVideoActivate !== 'function' ||
          typeof window.__ctrlMapConnect !== 'function') return;
      clearInterval(iv);
      var ea = document.getElementById('addr');
      if (ea) ea.value = ws;
      try { window.__ctrlMapConnect(); } catch (e) {}
      if (!window.__relayVideoOn) window.relayVideoActivate();
    }, 150);
  }

  function start() {
    if (started) return;
    tries++;
    step(tries > 1 ? '无法连接服务器，正在重试…' : '正在获取设备地址…');
    fetch('/api/lan', { cache: 'no-store' }).then(function (r) {
      if (r.status === 401) { showLogin(); return null; }
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (lan) {
      if (!lan) return;                       // 需要登录，登录成功后会再走一次
      started = true;
      return pickBoard(lan).then(function (base) {
        if (!base) { offline((lan.ips && lan.ips.length) ? 'unreach' : 'noip'); return; }
        bind(base);
      });
    }).catch(function () {
      // 服务器/网络抶动：退避重试，不要把遮罩钉在“接口异常”上
      if (tries < 10) setTimeout(start, Math.min(3000, 600 * tries));
      else step('无法连接服务器，请检查网络后刷新页面');
    });
  }

  if (document.getElementById('clForm')) {
    document.getElementById('clForm').addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (errEl) errEl.textContent = '';
      fetch('/api/login', {
        method: 'POST', cache: 'no-store',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pass: passEl ? passEl.value : '' })
      }).then(function (r) {
        if (r.ok) {
          if (loginEl) loginEl.hidden = true;
          started = false;
          start();
        } else if (errEl) {
          errEl.textContent = '密码错误';
        }
      }).catch(function () { if (errEl) errEl.textContent = '登录请求失败'; });
    });
  }

  // 顶栏标注：区分云端版与设备本地页面（本脚本在 <body> 开头执行，须等 DOM 就绪）
  function addBadge() {
    try {
      var sp = document.querySelector('.topnav .sp');
      if (!sp || !sp.parentNode || document.querySelector('.topnav .cl-badge')) return;
      var b = document.createElement('i');
      b.className = 'cl-badge';
      b.textContent = '云端版';
      b.title = '页面由云端提供，控制经局域网直连设备';
      sp.parentNode.insertBefore(b, sp);
    } catch (e) {}
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addBadge);
  } else {
    addBadge();
  }

  start();
})();
</script>
"""


def _sub(s, old, new, tag):
    """必须命中一次，否则说明 console.html 结构变了 —— 直接报错，别产出坏页面。"""
    n = s.count(old)
    if n != 1:
        raise SystemExit("生成失败：锚点「%s」命中 %d 次（期望 1 次），"
                         "console.html 结构可能已改，请更新 tools/make_cloud_ctrl.py"
                         % (tag, n))
    return s.replace(old, new, 1)


def build(src_text):
    s = src_text

    # 1) 启动遮罩：轮询地址从「同源」改成板子地址
    s = _sub(
        s,
        "    fetch('/api/status', { cache: 'no-store' })",
        "    fetch((window.CTRL_BASE || '') + '/api/status', { cache: 'no-store' })",
        "bootMask 轮询")

    # 2) 连接框默认值：不再是 location.host（那是云端域名），而是探测到的板子地址
    s = _sub(
        s,
        '  $("vAddr").value = location.host || location.hostname;',
        '  $("vAddr").value = window.CTRL_BASE || "";',
        "vAddr 默认值")

    # 3) 取消页面自己的自动连接：必须等引导层拿到板子地址
    s = _sub(
        s,
        "if (document.getElementById('viewVideo') &&\n"
        "    !document.getElementById('viewVideo').hidden) {\n"
        "  window.relayVideoActivate();\n"
        "}",
        "/* 云端版：自动连接由引导层在探测到板子地址后发起，这里不自己连 */",
        "自动连接")

    # 4) rosbridge：同源 /rosbridge 换成板子的 /rosbridge
    s = _sub(
        s,
        "    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';",
        "    // 云端版：页面在云端，rosbridge 必须指向板子（引导层已写进 localStorage）\n"
        "    if (window.CTRL_BASE) {\n"
        "      return 'ws://' + window.CTRL_BASE.replace(/^https?:\\/\\//, '') + '/rosbridge';\n"
        "    }\n"
        "    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';",
        "rosbridge 地址")

    # 5) 地图页的 ws 不要自己连：页面加载时还不知道板子地址，
    #    直接连会去连 ws://ros.absozero.cn/rosbridge（404）。
    s = _sub(
        s,
        "  elAddr.value = defaultUrl();\n  resize();\n  connect();",
        "  elAddr.value = defaultUrl();\n  resize();\n"
        "  /* 云端版：这里不连 —— 由引导层拿到板子地址后写 window.CTRL_BASE 再调 */\n"
        "  window.__ctrlMapConnect = function () { reconnectTries = 0; connect(); };",
        "地图 ws 初始化连接")

    # 6) 启动遮罩的失败文案：云端版等的是"板子就绪"，不是"推流服务"
    s = _sub(
        s,
        "? '推流服务还没起来，继续等待…'",
        "? '正在等待板子就绪…'",
        "遮罩失败文案")

    # 6b) 还没拿到板子地址前不要抡 404：遮罩先别发请求
    s = _sub(
        s,
        "  function tick() {\n    if (done) return;\n"
        "    elEl.textContent = ((Date.now() - T0) / 1000).toFixed(1);",
        "  function tick() {\n    if (done) return;\n"
        "    elEl.textContent = ((Date.now() - T0) / 1000).toFixed(1);\n"
        "    // 云端版：引导层还没探测到板子地址，先别发请求（发了也是 404）\n"
        "    if (!window.CTRL_BASE) return;",
        "遮罩轮询前先等 base")

    # 7) 注入登录 + 引导层（必须紧跟 <body>，遮罩脚本靠 window.CTRL_BASE 拼地址）
    s = _sub(s, "<body>\n", "<body>\n" + BOOT, "body 注入")

    # 8) 备案信息页脚（备案规范要求展示 ICP 与公安网备号）
    s = _sub(s, "\n</body>\n</html>", BEIAN + "</body>\n</html>", "备案页脚")
    return s


def main():
    check = "--check" in sys.argv[1:]
    src = io.open(SRC, encoding="utf-8").read()
    out = build(src)
    if check:
        print("锚点全部命中；预计输出 %d 字节（源 %d）" % (len(out), len(src)))
        return 0
    d = os.path.dirname(OUT)
    if not os.path.isdir(d):
        os.makedirs(d)
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("已生成 %s（%d 字节，源 %d）" % (OUT, len(out), len(src)))

    # 依赖的 vendor 资源
    import shutil
    for rel in VENDOR:
        s = os.path.join(ROOT, "rk", "relay", "web", rel)
        t = os.path.join(d, rel)
        td = os.path.dirname(t)
        if not os.path.isdir(td):
            os.makedirs(td)
        shutil.copyfile(s, t)
        print("已复制 %s -> %s（%d 字节）" % (rel, t, os.path.getsize(t)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
