#!/usr/bin/env python3
"""check-iso-update.py —— 检测 fnOS 官方新版 ISO（版本发现 + 可下载性探测分离）。

背景：liveupdate 直链对非 residential 出口 403（实测：curl/wget/python 全灭，
UA/Referer/cookie 均无效，属 IP/ASN 层拦截），故"发现新版"与"能下载"必须分开判定。

用法：
  python3 check-iso-update.py [--page URL] [--state <file>] [--probe/--no-probe]
                              [--signed/--no-signed]

  --signed：在确定当前版本后，再调官网 download-sign 换签名 URL
  （输出 signed_url；CI 下载用它，不用裸 URL）。

输出：JSON 到 stdout，形如：
  {"current": {"version": "1.2.0701", "url": "...", "hash": "..."},
   "recorded": "1.2.0701", "changed": false, "downloadable": true}

退出码：0=无变化；10=有新版且可下载；11=有新版但下载被拦；
         2=抓取/解析失败（告警，不更新 state）。
state 文件只在成功解析后更新（失败不覆盖，避免把"抓不到"当成"无新版"）。
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
           "downloadable": None}
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
