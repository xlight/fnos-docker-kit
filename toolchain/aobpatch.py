#!/usr/bin/env python3
# ============================================================================
# aobpatch.py — AOB（特征码）补丁引擎
#
# 补丁以"特征"定位（定长 IDA 风格：十六进制 + ?? 通配），而非固定偏移。
# 支持：
#   - 可选符号锚定（把搜索限定在某个符号的地址范围内，fnOS 二进制未 strip）
#   - 期望命中数校验 + 逐匹配替换 + 打后校验
#   - 幂等（已打过跳过）+ 失败即停（不产出半成品）
#   - 应用报告（逐条：命中位置/命中数/状态/文件哈希）
#
# 用法：
#   aobpatch.py check --rootfs <dir> --patchset <json>
#   aobpatch.py apply --rootfs <dir> --patchset <json> [--report <json>]
#
# 补丁类型（每条 patch 的 "kind" 字段，默认 "aob"）：
#   aob  : 二进制特征码定位 + 等长替换（见上）
#   text : 文本串替换（如前端 JS），可选 mirror 把补丁后内容同步进
#          .restore/www.zip 的加密条目（Info-ZIP `zip`，python zipfile 读不了）
#
# 停用/归档（每条 patch 可选）：
#   "status":"retired"（或 "disabled":true）→ 定义**保留可查**，但**不参与**应用/预检；
#   报告里列在 report.retired。用于"某处置已由其它机制取代、留档参考"（如回收站
#   改由用户态 wrapper 处理后，filemanager 的 unlinkat 降级补丁）。
#   "disabled":true（且 status 非 retired）→ **默认不应用**，但可用 `--include-disabled`
#   显式启用（opt-in）。用于"实现出来、但默认不生效"的补丁（如磁盘 I/O 刷新）：
#   默认构建/重放跳过它；需要它的容器用容器内启动单元带 `--include-disabled` 重放。
#
# 版本锚点（file_hashes）的 orig/patched 既可为字符串，也可为**哈希列表**：
#   列表用于同一文件存在多个合法终态时（如 resmon_service 打了 opt-in 磁盘补丁后
#   的 231f… 与未打时的 9a5af… 都应被识别为"已打过/终态"，避免默认重放误报
#   unknown-file-hash 而短路整套自愈）。
#   "已打过"以**特征缺失**判定（哈希锚点只用于挡"未知/版本不符"）：这样同一文件
#   可以先停在中间终态（9a5af…），再由 opt-in 补丁推进到下一终态（231f…）。
#
# 补丁集格式（JSON）：
# {
#   "fnos_version": "V1.2.0701",
#   "patches": [
#     {"id":"libnfile.is_mountpoint","kind":"aob",
#      "file":"usr/trim/lib/libnfile.so",
#      "anchor":"is_mountpoint",                 # 可选
#      "match":"48 89 fe bf b3 ab ff ff e8 ?? ?? ?? ?? 85 c0 0f 95 c0",
#      "replace":[{"find":"b3 ab","to":"9c ff"}],
#      "expect":1},
#     {"id":"www.n4","kind":"text",
#      "file":"usr/trim/www/assets/Setting-*.js",  # 支持 glob（恰好匹配）
#      "find":"e.data.net?.","to":"e.data?.net?.","expect":1,
#      "mirror":{"archive":"usr/trim/share/.restore/www.zip"}}
#   ]
# }
# ============================================================================
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile



def parse_pattern(s):
    """'48 89 ?? ff' 或 '2be4'（无空格）-> [int|None,...]；支持半字节掩码 '?A'。"""
    s = s.strip()
    if " " not in s and len(s) > 2:
        s = " ".join(s[i:i + 2] for i in range(0, len(s), 2))
    out = []
    for tok in s.split():
        if tok in ("?", "??", "**"):
            out.append(None)
        elif len(tok) == 2:
            if "?" not in tok:
                out.append(int(tok, 16))
            else:  # 半字节掩码
                hi = tok[0]; lo = tok[1]
                b = (int(hi, 16) if hi != "?" else 0) << 4 | (int(lo, 16) if lo != "?" else 0)
                m = (0xF0 if hi != "?" else 0) | (0x0F if lo != "?" else 0)
                out.append(("~", b, m))
        else:
            raise ValueError("bad token: %s" % tok)
    return out


def _match_at(data, i, pat):
    for j, p in enumerate(pat):
        if p is None:
            continue
        if isinstance(p, tuple):
            _, b, m = p
            if (data[i + j] & m) != b:
                return False
        elif data[i + j] != p:
            return False
    return True


def find_all(data, pat, lo=0, hi=None):
    hi = len(data) if hi is None else hi
    L = len(pat)
    return [i for i in range(lo, hi - L + 1) if _match_at(data, i, pat)]


def apply_replace(pat, replace):
    """返回替换后的 pattern（等长替换）。"""
    new = list(pat)
    # 在 pattern 里定位 find（按字节序列，忽略掩码）
    fpat = parse_pattern(replace["find"])
    tpat = parse_pattern(replace["to"])
    if len(fpat) != len(tpat):
        raise ValueError("find/to 长度不一致")
    out = []
    i = 0
    while i < len(new):
        ok = i + len(fpat) <= len(new) and all(
            fpat[k] is None or new[i + k] == fpat[k] for k in range(len(fpat)))
        if ok:
            out.extend(tpat); i += len(fpat)
        else:
            out.append(new[i]); i += 1
    return out


def symbol_range(binary, symbol):
    """用 readelf 求符号的 [start, next) 地址范围（可选锚定）。失败返回 None。"""
    try:
        out = subprocess.run(["readelf", "-sW", binary], capture_output=True, text=True).stdout
    except Exception:
        return None
    syms = []
    for line in out.splitlines():
        m = re.match(r"\s*\d+:\s+([0-9a-f]+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$", line)
        if m:
            try:
                val = int(m.group(1), 16)
            except ValueError:
                continue
            name = m.group(2).split()[-1] if m.group(2).strip() else ""
            syms.append((val, name))
    syms.sort()
    for idx, (val, name) in enumerate(syms):
        if name == symbol:
            nxt = syms[idx + 1][0] if idx + 1 < len(syms) else None
            return (val, nxt)
    return None


def _as_hash_set(v):
    """哈希锚点归一化：字符串或字符串列表都接受（列表=多个合法终态）。"""
    if not v:
        return set()
    return set(v) if isinstance(v, (list, tuple)) else {v}


def _file_state(data, h):
    """版本锚点：整文件哈希判定 orig / patched / unknown。"""
    sha = hashlib.sha256(data).hexdigest()
    if sha in _as_hash_set(h.get("patched")):
        return "patched"
    if sha in _as_hash_set(h.get("orig")):
        return "orig"
    return "unknown"


def process_patch(rootfs, p, fh=None):
    path = os.path.join(rootfs, p["file"])
    rec = {"id": p["id"], "file": p["file"], "expect": p.get("expect", 1)}
    if not os.path.exists(path):
        rec["status"] = "missing-file"; return rec, False
    data = bytearray(open(path, "rb").read())
    rec["input_sha256"] = hashlib.sha256(data).hexdigest()
    h = (fh or {}).get(p["file"])
    st = None
    if h:  # 版本锚点：整文件哈希（orig/patched 皆已知，其它=被改动/版本不符）
        st = _file_state(data, h)
        rec["file_state"] = st
        if st == "unknown":
            rec["status"] = "unknown-file-hash"; return rec, False
    pat = parse_pattern(p["match"])
    lo, hi = 0, len(data)
    if p.get("anchor"):
        rng = symbol_range(path, p["anchor"])
        if rng:
            lo = rng[0]; hi = rng[1] if rng[1] else len(data)
            rec["anchor_range"] = [hex(lo), hex(hi) if rng[1] else None]
    hits = find_all(data, pat, lo, hi)
    rec["hits"] = [hex(hh) for hh in hits]
    if not hits:
        # 无命中即"已打过"——但仅当文件确为已知终态时才算成功。
        # 哈希锚点判 orig 却无特征 → 版本漂移/被改动 → 明确失败（不当作已打过）。
        if h and st == "orig":
            rec["status"] = "signature-not-found"; return rec, False
        rec["status"] = "already"; return rec, True
    if len(hits) != p.get("expect", 1):
        rec["status"] = "expect-mismatch(%d!=%d)" % (len(hits), p.get("expect", 1)); return rec, False
    # 逐匹配替换
    for hh in hits:
        for r in p["replace"]:
            fpat = parse_pattern(r["find"]); tpat = parse_pattern(r["to"])
            i = 0
            while i + len(fpat) <= len(pat):
                if all(fpat[k] is None or data[hh + i + k] == fpat[k] for k in range(len(fpat))):
                    for k in range(len(fpat)):
                        data[hh + i + k] = tpat[k] if not isinstance(tpat[k], tuple) else tpat[k][1]
                    i += len(fpat)
                else:
                    i += 1
    # 打后校验：原特征在**目标位置**应消失（应用后特征是否在别处重复存在与本 patch 无关）
    ok = not find_all(data, pat, lo, hi)
    rec["status"] = "applied" if ok else "verify-failed"
    if ok:
        open(path, "wb").write(data)
        rec["output_sha256"] = hashlib.sha256(data).hexdigest()
    return rec, ok


def process_patch_check(rootfs, p, fh=None):
    """只检查（不写）：版本锚点 / 命中数是否匹配 / 是否已打过。"""
    path = os.path.join(rootfs, p["file"])
    rec = {"id": p["id"], "file": p["file"], "expect": p.get("expect", 1)}
    if not os.path.exists(path):
        rec["status"] = "missing-file"; return rec, False
    data = open(path, "rb").read()
    rec["input_sha256"] = hashlib.sha256(data).hexdigest()
    h = (fh or {}).get(p["file"])
    st = None
    if h:
        st = _file_state(data, h)
        rec["file_state"] = st
        if st == "unknown":
            rec["status"] = "unknown-file-hash"; return rec, False
    n = len(find_all(data, parse_pattern(p["match"])))
    rec["hits"] = n
    if n == 0:
        # 无命中即"已打过/终态"；仅当锚点判 orig 时才是版本漂移 → 失败。
        if h and st == "orig":
            rec["status"] = "signature-not-found"; return rec, False
        rec["status"] = "already"; return rec, True
    if n != p.get("expect", 1):
        rec["status"] = "expect-mismatch(%d!=%d)" % (n, p.get("expect", 1)); return rec, False
    rec["status"] = "ready"; return rec, True


def _is_retired(p):
    """不再适用/归档的补丁：定义保留（可查），但不参与应用/预检。"""
    if p.get("disabled"):
        return True
    return str(p.get("status", "")).lower() in ("retired", "deprecated", "disabled")


def _is_optin_disabled(p):
    """`disabled:true`（且非 retired）的补丁：默认不应用，可用 --include-disabled 启用。"""
    if not p.get("disabled"):
        return False
    return str(p.get("status", "")).lower() not in ("retired", "deprecated", "disabled")


def run(rootfs, patchset, write, only="all", include_disabled=False):
    raw = open(patchset, "rb").read()
    ps = json.loads(raw)
    # 分相应用：aob=只处理二进制补丁（trim 前），text=只处理文本/www 补丁（www 就绪后）。
    if only == "aob":
        ps["patches"] = [p for p in ps["patches"] if p.get("kind", "aob") != "text"]
    elif only == "text":
        ps["patches"] = [p for p in ps["patches"] if p.get("kind", "aob") == "text"]
    retired = [p for p in ps["patches"] if _is_retired(p)]
    active = [p for p in ps["patches"] if not _is_retired(p)]
    if include_disabled:
        # opt-in：把 disabled:true 的补丁并入应用集（status:retired 的仍永久停用）。
        optin = [p for p in retired if _is_optin_disabled(p)]
        retired = [p for p in retired if not _is_optin_disabled(p)]
        active = active + optin
    fh = ps.get("file_hashes") or {}
    report = {"fnos_version": ps.get("fnos_version"),
              "patchset": os.path.basename(patchset),
              "patchset_sha256": hashlib.sha256(raw).hexdigest(),
              "include_disabled": include_disabled,
              "file_hashes": fh,
              "rootfs": rootfs,
              "retired": [{"id": p["id"], "file": p["file"],
                           "reason": p.get("retired_reason") or p.get("note") or "retired"}
                          for p in retired],
              "patches": []}
    if write:
        # 阶段一：全量预检（不写）。任一失败则**不写任何文件**（不产出半成品）。
        checks = [process_any(rootfs, p, False, fh) for p in active]
        if not all(ok for _, ok in checks):
            report["phase"] = "precheck-failed"
            report["patches"] = [r for r, _ in checks]
            report["ok"] = False
            return report
    allok = True
    for p in active:
        # 应用阶段跳过整文件哈希门（预检已判定该文件为原版；逐条打完后文件即"中间态"）。
        rec, ok = process_any(rootfs, p, write, None if write else fh)
        report["patches"].append(rec)
        allok = allok and ok
    report["phase"] = "applied" if write else "checked"
    report["ok"] = allok
    return report


def process_any(rootfs, p, write, fh=None):
    if p.get("kind", "aob") == "text":
        return process_text_patch(rootfs, p) if write else process_text_patch_check(rootfs, p)
    return process_patch(rootfs, p, fh) if write else process_patch_check(rootfs, p, fh)


def _expand_files(rootfs, pattern):
    if any(c in pattern for c in "*?["):
        return sorted(glob.glob(os.path.join(rootfs, pattern)))
    p = os.path.join(rootfs, pattern)
    return [p] if os.path.exists(p) else []


def _mirror_zip(rootfs, mirror, live_path):
    """把补丁后的 live 文件同步进 .restore/www.zip 的同名条目。
    用 Info-ZIP（能处理包内加密的 `._*` 兄弟条目；python zipfile 读不了）。"""
    archive = os.path.join(rootfs, mirror["archive"])
    entry = mirror.get("entry") or ("assets/" + os.path.basename(live_path))
    if not os.path.exists(archive):
        return {"ok": False, "reason": "missing-archive", "archive": mirror["archive"]}
    if not shutil.which("zip"):
        return {"ok": False, "reason": "no-zip-tool"}
    with tempfile.TemporaryDirectory(prefix="fnos-mirror-") as td:
        dst = os.path.join(td, entry)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(live_path, dst)
        os.utime(dst, None)  # 确保比归档内条目新，强制更新
        r = subprocess.run(["zip", "-q", archive, entry], cwd=td,
                           capture_output=True, text=True)
        return {"ok": r.returncode == 0, "archive": mirror["archive"], "entry": entry,
                "detail": (r.stderr or r.stdout).strip()[-200:]}


def process_text_patch(rootfs, p):
    rec = {"id": p["id"], "kind": "text", "file": p["file"], "expect": p.get("expect", 1)}
    find = p["find"].encode(); to = p["to"].encode()
    files = _expand_files(rootfs, p["file"])
    if not files:
        rec["status"] = "missing-file"; return rec, False
    rec["files"] = []
    allok = True
    any_applied = False
    for path in files:
        fr = {"file": os.path.relpath(path, rootfs)}
        data = bytearray(open(path, "rb").read())
        fr["input_sha256"] = hashlib.sha256(data).hexdigest()
        n_find = data.count(find)
        if n_find == 0:
            fr["status"] = "already" if data.count(to) else "not-found"
            allok = allok and fr["status"] == "already"
        elif n_find != p.get("expect", 1):
            fr["status"] = "expect-mismatch(%d!=%d)" % (n_find, p.get("expect", 1))
            allok = False
        else:
            data = data.replace(find, to)
            if data.count(find) != 0:
                fr["status"] = "verify-failed"; allok = False
            else:
                open(path, "wb").write(data)
                fr["output_sha256"] = hashlib.sha256(data).hexdigest()
                fr["status"] = "applied"
                any_applied = True
                if p.get("mirror"):
                    m = _mirror_zip(rootfs, p["mirror"], path)
                    fr["mirror"] = m
                    allok = allok and m.get("ok", False)
        rec["files"].append(fr)
    rec["status"] = "failed" if not allok else ("applied" if any_applied else "already")
    return rec, allok


def process_text_patch_check(rootfs, p):
    rec = {"id": p["id"], "kind": "text", "file": p["file"], "expect": p.get("expect", 1)}
    find = p["find"].encode(); to = p["to"].encode()
    files = _expand_files(rootfs, p["file"])
    if not files:
        rec["status"] = "missing-file"; return rec, False
    rec["files"] = []
    allok = True
    for path in files:
        fr = {"file": os.path.relpath(path, rootfs)}
        data = open(path, "rb").read()
        fr["input_sha256"] = hashlib.sha256(data).hexdigest()
        n_find = data.count(find)
        if n_find == 0:
            fr["status"] = "already" if data.count(to) else "not-found"
            allok = allok and fr["status"] == "already"
        elif n_find != p.get("expect", 1):
            fr["status"] = "expect-mismatch(%d!=%d)" % (n_find, p.get("expect", 1)); allok = False
        else:
            fr["status"] = "ready"
        rec["files"].append(fr)
    rec["status"] = "ready" if allok else "failed"
    return rec, allok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["check", "apply"])
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--patchset", required=True)
    ap.add_argument("--report")
    ap.add_argument("--only", choices=["all", "aob", "text"], default="all",
                    help="只处理某类补丁：aob=二进制（trim 前）/ text=文本-www（www 就绪后）")
    ap.add_argument("--include-disabled", action="store_true",
                    help="opt-in：把 disabled:true 的补丁也纳入应用（status:retired 仍永久停用）")
    a = ap.parse_args()
    rep = run(a.rootfs, a.patchset, write=(a.cmd == "apply"), only=a.only,
              include_disabled=a.include_disabled)
    if a.report:
        json.dump(rep, open(a.report, "w"), ensure_ascii=False, indent=2)
    print(json.dumps(rep, ensure_ascii=False, indent=2))
    sys.exit(0 if rep["ok"] else 1)


if __name__ == "__main__":
    main()
