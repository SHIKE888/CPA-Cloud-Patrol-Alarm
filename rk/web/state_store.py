# -*- coding: utf-8 -*-
"""服务端参数持久化：把「上次用过的参数」记到一个小 JSON 文件里。

为什么不存浏览器 localStorage：
  * 换浏览器 / 换电脑 / 清缓存之后参数还在；
  * 服务重启（改代码、断电恢复、start_webstream.sh 重跑）后自动恢复；
  * 页面连上时 `/api/params` 与 `/api/ai` 直接返回上次的值，前端不用自己回填。

文件结构（两个 section 互不干扰，各自读改写自己那段）：

.. code-block:: json

    {
      "params": { "brightness": 10, "quality": 75, ... },
      "ai":     { "source": "ai", "det_interval": 2, ... }
    }

写盘用「读-改-写 + os.replace 原子替换」：两个线程（HTTP 请求线程 /
AI 推理线程）同时保存时不会互相覆盖，也不会留下写了一半的坏文件。
"""
from __future__ import annotations

import json
import os
import tempfile
import threading

_LOCK = threading.Lock()


def _read(path):
    """读整个文件；路径为空、文件不存在或内容损坏都返回 {}。"""
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except Exception:                                        # noqa: BLE001
        return {}
    return d if isinstance(d, dict) else {}


def _write(path, data):
    """原子写回整个文件。成功返回 True。"""
    try:
        d = os.path.dirname(os.path.abspath(path))
        if d:
            os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d or ".", prefix=".state-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        return True
    except Exception:                                        # noqa: BLE001
        return False


def get(path, section):
    """取某个 section（不是 dict 就返回空 dict）。"""
    v = _read(path).get(section)
    return v if isinstance(v, dict) else {}


def put(path, section, values):
    """把 values 合并进 section 后写回。"""
    if not path or not isinstance(values, dict):
        return False
    with _LOCK:
        d = _read(path)
        sec = d.get(section)
        if not isinstance(sec, dict):
            sec = {}
        sec.update(values)
        d[section] = sec
        return _write(path, d)


def replace(path, section, values):
    """整段替换（用于「重置参数」）。"""
    if not path:
        return False
    with _LOCK:
        d = _read(path)
        d[section] = dict(values or {})
        return _write(path, d)


def clear(path, section=None):
    """删掉某个 section（section=None 则清空整个文件）。"""
    if not path:
        return False
    with _LOCK:
        d = {} if section is None else _read(path)
        if section is not None:
            d.pop(section, None)
        return _write(path, d)
