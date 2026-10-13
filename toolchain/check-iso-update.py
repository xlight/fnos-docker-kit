#!/usr/bin/env python3
"""check-iso-update.py —— 检测 fnOS 官方新版（双通道：下载页触发 + OTA 预警）。

背景：官网直链裸访 403（缺签名——ISO 走 download-sign 现签，.deb 走 manifest
dlkey 自签），故"发现新版"与"能下载"必须分开判定。

用法：
  python3 check-iso-update.py [--page URL] [--state <file>] [--probe/--no-probe]
                              [--signed/--no-signed] [--no-ota]

  --signed：在确定当前版本后，再调官网 download-sign 换签名 URL
  （输出 signed_url；CI 下载用它，不用裸 URL）。
  --no-ota：跳过 OTA 预警通道（默认开启；本地离线调试用）。

通道：
  下载页嵌 JSON（版本号 + 官方 hash）→ 构建触发（changed/downloadable）。
  OTA 版本清单（apiv2-liveupdate 根路径匿名 GET，trim.version 为准）
    → 只记 ota/ota_newer 预警，MUST NOT 触发构建（无 ISO 不可构建）。
任一通道失败 → rc=2（告警，不更新 state）。

输出：JSON 到 stdout，形如：
  {"current": {"version": "1.2.0701", "url": "...", "hash": "..."},
   "recorded": "1.2.0701", "changed": false, "downloadable": true,
   "ota": {"version": "1.2.0800"}, "ota_newer": true}

退出码：0=无变化；10=有新版且可下载；11=有新版但下载被拦；
         2=任一通道抓取/解析失败（告警，不更新 state）。
state 文件只在双通道都成功后更新（失败不覆盖，避免把"抓不到"当成"无新版"）。
"""
import json
import os
import re
import sys
import urllib.request

PAGE = "https://fnnas.com/download"
STATE_ENV = "ISO_STATE_FILE"
SIGN_PATH = "/asset/download-sign"
SIGN_S1 = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
SIGN_S2 = "4fac7e99-ef43-4b6c-9ca8-5bbca4a4210e"
# OTA 版本清单：根路径匿名 GET 即可（无参数无鉴权；响应 = JSON + 不定长二进制尾巴）
OTA_URL = "https://apiv2-liveupdate.fnnas.com/"
OTA_UA = "wb.apt/2.6.1 (linux amd64)"

# 页面内嵌转义 JSON：download\":{\"version\":\"X\",\"url\":\"...\",\"hash\":\"...\",...}
RE_BLOCK = re.compile(
    r'download\\\\*":\{\\\\*"version\\\\*":\s*\\\\*"([^"\\]+)\\\\*"'
    r'.*?\\\\*"url\\\\*":\s*\\\\*"([^"\\]+\.iso[^"\\]*)\\\\*"'
    r'.*?\\\\*"hash\\\\*":\s*\\\\*"([^"\\]*)\\\\*"'
)


def fetch(url, timeout=30):
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def probe(url, timeout=20):
    """分段 GET 探测可下载性：200/206=True，403/异常=False（不断言原因）。"""
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)",
                          "Range": "bytes=0-1023"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status in (200, 206)
    except Exception:
        return False


def ota_trim_version(timeout=30):
    """匿名查询 OTA 版本清单，返回 trim 包版本号；失败抛异常。
    只解析 JSON 前缀（响应尾部有不定长二进制，保持容忍）。"""
    req = urllib.request.Request(OTA_URL, headers={"User-Agent": OTA_UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", errors="replace")
    obj, _ = json.JSONDecoder().raw_decode(text)
    for p in obj.get("packages", []):
        if p.get("packageName") == "trim" and p.get("version"):
            return p["version"]
    raise ValueError("ota parse-failed: no trim package")


def _vkey(v):
    try:
        return tuple(int(x) for x in re.findall(r"\d+", v))
    except Exception:
        return (0,)


def sign_url(url, timeout=20):
    """调官网 download-sign 接口换签名 URL（authx 算法逆自官网前端，可公开复现）。
    返回签名 URL；失败抛异常。"""
    import hashlib
    import random
    import time
    md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
    data = json.dumps({"url": url}, separators=(",", ":"))
    nonce = str(random.randint(100000, 999999))
    ts = str(int(time.time() * 1000))
    inner = md5(data)
    c = "_".join([SIGN_S1, SIGN_PATH, nonce, ts, inner, SIGN_S2])
    authx = "nonce=%s&timestamp=%s&sign=%s" % (nonce, ts, md5(c))
    req = urllib.request.Request(
        "https://fnnas.com" + SIGN_PATH, data=data.encode(),
        headers={"Content-Type": "application/json", "authx": authx,
                 "User-Agent": "Mozilla/5.0 (X11; Linux x86_64)",
                 "Origin": "https://fnnas.com",
                 "Referer": "https://fnnas.com/download"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["url"]


def main():
    page = PAGE
    state_file = os.environ.get(STATE_ENV, "")
    do_probe = True
    do_sign = False
    do_ota = True
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--page" and i + 1 < len(args):
            page, i = args[i + 1], i + 1
        elif args[i] == "--state" and i + 1 < len(args):
            state_file, i = args[i + 1], i + 1
        elif args[i] == "--no-probe":
            do_probe = False
        elif args[i] == "--signed":
            do_sign = True
        elif args[i] == "--no-ota":
            do_ota = False
        i += 1
    try:
        html = fetch(page)
    except Exception as e:
        print(json.dumps({"error": "fetch-failed: %s" % e}), flush=True)
        return 2
    found = {}
    for m in RE_BLOCK.finditer(html):
        ver, url, h = m.group(1), m.group(2), m.group(3)
        found[ver] = {"version": ver, "url": url, "hash": h}
    if not found:
        print(json.dumps({"error": "parse-failed: no download block"}), flush=True)
        return 2
    # 取最高版本（x86 主线优先： presently only x86 blocks carry Mainland-PE iso）
    cur = found[sorted(found)[-1]]
    recorded = ""
    if state_file and os.path.isfile(state_file):
        recorded = open(state_file).read().strip()
    out = {"current": cur, "recorded": recorded,
           "changed": cur["version"] != recorded if recorded else True,
           "downloadable": None, "ota": None, "ota_newer": None}
    if do_ota:
        try:
            over = ota_trim_version()
        except Exception as e:
            print(json.dumps({"error": "ota-failed: %s" % e}), flush=True)
            return 2
        out["ota"] = {"version": over}
        out["ota_newer"] = _vkey(over) > _vkey(cur["version"])
        # 人类可读行走 stderr（stdout 只留 JSON，下游按 JSON 解析）
        print("[ota] trim=%s ota_newer=%s (page=%s)" % (over, out["ota_newer"], cur["version"]),
              file=sys.stderr, flush=True)
    if do_probe:
        out["downloadable"] = probe(cur["url"])
    if do_sign:
        try:
            out["signed_url"] = sign_url(cur["url"])
        except Exception as e:
            out["signed_url"] = None
            out["sign_error"] = str(e)[:200]
    print(json.dumps(out, ensure_ascii=False))
    if state_file:
        open(state_file, "w").write(cur["version"] + "\n")
    if not out["changed"]:
        return 0
    if not do_probe:
        return 10  # --no-probe 仅用于本地调试：不断言可下载性，调用方自理
    return 10 if out.get("downloadable") else 11


if __name__ == "__main__":
    sys.exit(main())
