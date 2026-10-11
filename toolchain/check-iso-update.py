#!/usr/bin/env python3
"""check-iso-update.py —— 检测 fnOS 官方新版 ISO（版本发现 + 可下载性探测分离）。

背景：liveupdate 直链对非 residential 出口 403（实测：curl/wget/python 全灭，
UA/Referer/cookie 均无效，属 IP/ASN 层拦截），故"发现新版"与"能下载"必须分开判定。

用法：
  python3 check-iso-update.py [--page URL] [--state <file>] [--probe/--no-probe]

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


def main():
    page = PAGE
    state_file = os.environ.get(STATE_ENV, "")
    do_probe = True
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--page" and i + 1 < len(args):
            page, i = args[i + 1], i + 1
        elif args[i] == "--state" and i + 1 < len(args):
            state_file, i = args[i + 1], i + 1
        elif args[i] == "--no-probe":
            do_probe = False
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
    print(json.dumps(out, ensure_ascii=False))
    if state_file:
        open(state_file, "w").write(cur["version"] + "\n")
    if not out["changed"]:
        return 0
    return 10 if out.get("downloadable") else 11


if __name__ == "__main__":
    sys.exit(main())
