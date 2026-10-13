#!/usr/bin/env python3
"""fetch-ota-debs.py —— 按版本下载 OTA .deb 包组（自签直链 + sha256 校验）。

背景：OTA 版本清单匿名可查，但包直链裸访 403；下载需现签现用
（key=b64decode(dlkey)^0x5E → sign=md5(key+path+秒级ts) → ?sign=&t=），
与 ISO 的 download-sign 是同一家族、不同密钥来源（.deb 密钥每次现取，
无静态 secret，公开可复现）。

用法：
  python3 fetch-ota-debs.py --version 1.2.0800 --out <destdir>
      [--ota-url URL] [--only trim,kernel] [--skip-scripts]

  --only：只下包名含这些子串的包（默认全下 packages[]；kernel 包名含 linux-*，
    trim 包即 packageName==trim）。
  默认连带 preupdate/postupdate 两个脚本（十几 KB，rebase 评审用）；
  --skip-scripts 跳过它们。

输出：<destdir>/<basename> + <destdir>/ota-manifest.json（清单原样存档）；
  stdout 一行 JSON 摘要。已存在且 sha256 相符的文件跳过（幂等）；
  任一包失败即停（退出非 0，不留半截文件——临时名下载，校验通过才落位）。
"""
import argparse
import base64
import hashlib
import json
import os
import sys
import time
import urllib.request

OTA_URL = "https://apiv2-liveupdate.fnnas.com/"
OTA_UA = "wb.apt/2.6.1 (linux amd64)"


def fetch_manifest(ota_url, timeout=30):
    req = urllib.request.Request(ota_url, headers={"User-Agent": OTA_UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", errors="replace")
    obj, _ = json.JSONDecoder().raw_decode(text)
    return obj


def sign_key(dlkey):
    return bytes(b ^ 0x5E for b in base64.b64decode(dlkey)).decode()


def signed_url(url, dlkey, now=None):
    ts = int(now if now is not None else time.time())
    path = "/" + url.split(".com/", 1)[1]
    sign = hashlib.md5((sign_key(dlkey) + path + str(ts)).encode()).hexdigest()
    return "%s?sign=%s&t=%s" % (url, sign, ts)


def download(entry, destdir, timeout=600):
    name = entry["url"].rsplit("/", 1)[-1]
    dest = os.path.join(destdir, name)
    want = entry.get("sign", "")
    if os.path.isfile(dest) and want:
        got = hashlib.sha256(open(dest, "rb").read()).hexdigest()
        if got == want:
            return {"file": name, "status": "already", "size": os.path.getsize(dest)}
    tmp = dest + ".downloading"
    req = urllib.request.Request(signed_url(entry["url"], entry["dlkey"]),
                                 headers={"User-Agent": OTA_UA})
    with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    got = hashlib.sha256(open(tmp, "rb").read()).hexdigest()
    if want and got != want:
        os.unlink(tmp)
        raise RuntimeError("sha256 不符 %s: want=%s got=%s" % (name, want, got))
    os.rename(tmp, dest)
    return {"file": name, "status": "downloaded", "size": os.path.getsize(dest)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="如 1.2.0800（必须与清单 trim.version 一致）")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ota-url", default=OTA_URL)
    ap.add_argument("--only", default="",
                    help="逗号分隔的包名子串过滤，如 trim,linux-（默认全下）")
    ap.add_argument("--skip-scripts", action="store_true")
    a = ap.parse_args()
    try:
        man = fetch_manifest(a.ota_url)
    except Exception as e:
        print(json.dumps({"error": "ota-failed: %s" % e}), flush=True)
        return 2
    trims = [p for p in man.get("packages", []) if p.get("packageName") == "trim"]
    if not trims or trims[0].get("version") != a.version:
        print(json.dumps({"error": "version-mismatch: want=%s ota=%s"
                                  % (a.version, trims[0].get("version") if trims else None)}),
              flush=True)
        return 2
    only = [s for s in a.only.split(",") if s]
    entries = []
    for p in man.get("packages", []):
        if only and not any(s in (p.get("packageName") or "") for s in only):
            continue
        entries.append(p)
    if not a.skip_scripts:
        entries += [man[k] for k in ("preupdate", "postupdate") if isinstance(man.get(k), dict)]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "ota-manifest.json"), "w") as f:
        json.dump(man, f, ensure_ascii=False, indent=1)
    results = []
    try:
        for e in entries:
            results.append(download(e, a.out))
    except Exception as e:
        print(json.dumps({"error": str(e)[:300], "done": results}), flush=True)
        return 1
    print(json.dumps({"version": a.version, "files": results,
                      "total_bytes": sum(r["size"] for r in results)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
