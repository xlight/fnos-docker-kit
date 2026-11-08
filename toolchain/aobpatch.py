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
# best-effort 模式（升级自愈用）：
#   --best-effort        三档判定：ready（哈希+模式都对）/ ready-unverified（哈希未知但模式
#                        唯一命中）/ skipped（0 命中或歧义）。单文件失败不阻塞其他文件；
#                        写按文件备份 + fsync + os.replace 原子替换 + 写后重读校验。
#   --fallback           回退模式（补丁集版本 < 运行版本）：unknown-hash 二进制一律 skipped，
#                        报告里带 --force-unverified --patch-id <id> 强制命令。
#   --force-unverified   配合 --patch-id，在 fallback 下强制应用该 unknown-hash 补丁。
#   --patch-id <id>      可重复；只处理指定补丁（两种模式都生效）。
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
import datetime
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


def _load_segments(binary):
    """返回 LOAD 段 [(file_off, vaddr, filesz)]，用于 vaddr ↔ file offset 换算。"""
    try:
        out = subprocess.run(["readelf", "-lW", binary], capture_output=True, text=True).stdout
    except Exception:
        return []
    segs = []
    for line in out.splitlines():
        s = line.strip()
        if not s.startswith("LOAD"):
            continue
        parts = s.split()
        try:
            off = int(parts[1], 16); va = int(parts[2], 16); fsz = int(parts[5], 16)
        except (IndexError, ValueError):
            continue
        segs.append((off, va, fsz))
    return segs


def _vaddr_to_off(segs, va):
    for off, sva, fsz in segs:
        if sva <= va < sva + fsz:
            return off + (va - sva)
    return None


def _demangle(name):
    """极简 Itanium demangle：_ZN<len><name>...E → A::B::C（够用即可）。

    只解析前缀（遇到模板参数等非 [len]name 成分即停），例如
    _ZN11NetReporter23UpdateInterfaceInfoBaseEjRSt... → "NetReporter::UpdateInterfaceInfoBase"。
    """
    if not name.startswith("_ZN"):
        return name
    body = name[3:]
    out = []
    i = 0
    while i < len(body):
        j = i
        while j < len(body) and body[j].isdigit():
            j += 1
        if j == i or j >= len(body):
            break
        n = int(body[i:j])
        out.append(body[j:j + n])
        i = j + n
    return "::".join(out) if out else name


def symbol_range(binary, symbol):
    """用 readelf 求符号的 [start, end) **文件偏移**范围（可选锚定）。失败返回 None。

    - 匹配：精确名 / demangle 后的名字 / mangled 名的子串
    - 范围：优先用符号 size，否则取下一个符号起点
    - 一律换算成 file offset：readelf 给的是 vaddr，而特征搜索跑在文件偏移上，
      两者混用会在非 identity 布局的 ELF 上把锚点指到错误位置。
    """
    try:
        out = subprocess.run(["readelf", "-sW", binary], capture_output=True, text=True).stdout
    except Exception:
        return None
    segs = _load_segments(binary)
    syms = []
    for line in out.splitlines():
        m = re.match(r"\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$", line)
        if not m:
            continue
        try:
            val = int(m.group(1), 16)
            size = int(m.group(2))
        except ValueError:
            continue
        name = m.group(3).split()[-1] if m.group(3).strip() else ""
        if name:
            syms.append((val, size, name))
    syms.sort()
    target = None
    for idx, (val, size, name) in enumerate(syms):
        if name == symbol or _demangle(name) == symbol or (len(symbol) > 4 and symbol in name):
            target = (idx, val, size, name)
            break
    if target is None:
        return None
    idx, val, size, name = target
    end_va = val + size if size > 0 else (syms[idx + 1][0] if idx + 1 < len(syms) else None)
    lo = _vaddr_to_off(segs, val)
    if lo is None:
        return None
    hi = _vaddr_to_off(segs, end_va) if end_va is not None else None
    return (lo, hi)


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
        if not rng:
            # 锚点必须解析成功：解析不了就拒绝打，绝不退化成"全文件找相似前缀"
            rec["status"] = "anchor-not-found"
            return rec, False
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
    pat = parse_pattern(p["match"])
    lo, hi = 0, len(data)
    if p.get("anchor"):
        rng = symbol_range(path, p["anchor"])
        if not rng:
            rec["status"] = "anchor-not-found"
            return rec, False
        lo = rng[0]; hi = rng[1] if rng[1] else len(data)
        rec["anchor_range"] = [hex(lo), hex(hi) if rng[1] else None]
    n = len(find_all(data, pat, lo, hi))
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


def run(rootfs, patchset, write, only="all", include_disabled=False, best_effort=False,
        fallback=False, force_unverified=False, patch_ids=None):
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
    if patch_ids:
        active = [p for p in active if p["id"] in patch_ids]
    fh = ps.get("file_hashes") or {}
    report = {"fnos_version": ps.get("fnos_version"),
              "patchset": os.path.basename(patchset),
              "patchset_sha256": hashlib.sha256(raw).hexdigest(),
              "include_disabled": include_disabled,
              "best_effort": best_effort,
              "fallback": fallback,
              "file_hashes": fh,
              "rootfs": rootfs,
              "retired": [{"id": p["id"], "file": p["file"],
                           "reason": p.get("retired_reason") or p.get("note") or "retired"}
                          for p in retired],
              "patches": []}
    if best_effort:
        return _run_best_effort(rootfs, report, active, fh, write,
                                fallback=fallback, force_unverified=force_unverified)
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


def _run_best_effort(rootfs, report, active, fh, write, fallback=False, force_unverified=False):
    """best-effort 主循环：按优先级链处理，单文件失败不阻塞；写前备份+原子替换+写后校验。"""
    # 跨文件按优先级链；**同一文件内保持补丁集原始顺序**（同文件的补丁可能互相
    # 影响匹配区，打乱顺序会让后续补丁 no-match）。
    active = [(i, p) for i, p in enumerate(active)]
    active.sort(key=lambda ip: (_priority(ip[1]), ip[0]))
    active = [p for _, p in active]
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backed = set()
    touched = set()
    report["warnings"] = []
    allok = True
    for p in active:
        try:
            if p.get("kind", "aob") == "text":
                rec, ok = process_text_patch_be(rootfs, p, write, backed, ts)
            else:
                rec, ok = process_patch_be(rootfs, p, write, fh,
                                           force_unverified=force_unverified,
                                           fallback=fallback, backed=backed, ts=ts)
        except Exception as e:
            # 单条补丁异常不得中断整轮（例如 www 正被还原守护重建）
            rec = {"id": p.get("id", "?"), "file": p.get("file", ""),
                   "status": "failed", "error": str(e)[:200]}
            ok = False
        report["patches"].append(rec)
        if write and str(rec.get("status", "")).split("(")[0] == "applied":
            touched.add(p["file"])
        st = str(rec.get("status", "")).split("(")[0]
        if st in HARD_FAIL:
            allok = False
        if st in ("skipped", "ready-unverified") and rec.get("reason"):
            report["warnings"].append("%s: %s" % (rec["id"], rec["reason"]))
        elif st == "skipped":
            report["warnings"].append("%s: skipped" % rec["id"])
    # 终态校验：被改过的文件，最终哈希应落在声明的 patched 终态集合内
    for f in sorted(touched):
        h = (fh or {}).get(f)
        if not h or not h.get("patched"):
            continue
        try:
            got = hashlib.sha256(open(os.path.join(rootfs, f), "rb").read()).hexdigest()
        except OSError:
            continue
        if got not in _as_hash_set(h.get("patched")):
            report["warnings"].append("file %s: 最终哈希不在声明的 patched 终态集合内" % f)
    if write:
        prune_backups(rootfs)
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


# ---------------------------------------------------------------------------
# best-effort：备份 / 原子写 / 优先级 / 三档判定
# ---------------------------------------------------------------------------

BACKUP_DIR = os.path.join("usr", "local", "share", "fnos-toolchain", "backups")
BACKUP_KEEP = 3
HARD_FAIL = {"signature-not-found", "verify-failed", "missing-file", "failed"}


def _priority(p):
    """固定优先级链：network N3(0) → www 文本(1) → dirfd 库(2) → filemanager(3) → 其余(4)。"""
    f = p.get("file", "")
    if p.get("kind", "aob") == "text":
        return 1
    if "network_service" in f:
        return 0
    if any(k in f for k in ("libnfile", "libnperm", "libtrimacl")):
        return 2
    if "filemanager" in f:
        return 3
    return 4


def _backup_path(rootfs, path, ts):
    return os.path.join(rootfs, BACKUP_DIR, ts, os.path.relpath(path, rootfs))


def backup_file(rootfs, path, ts, backed):
    """同一文件一次运行只备份一次。"""
    if path in backed:
        return _backup_path(rootfs, path, ts)
    dst = _backup_path(rootfs, path, ts)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(path, dst)
    backed.add(path)
    return dst


def atomic_write(path, data):
    """临时文件 flush+fsync → os.replace → 父目录 fsync。掉电只会是旧或新，不会半截。

    注意：mkstemp 默认 0600，若不保留原文件权限，替换后 www 资源会变成 600，
    nginx worker 读不到 → 403 Forbidden（务必保留原 mode）。
    """
    d = os.path.dirname(path)
    try:
        mode = os.stat(path).st_mode & 0o7777
    except OSError:
        mode = 0o644
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".aobpatch-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def prune_backups(rootfs, keep=BACKUP_KEEP):
    root = os.path.join(rootfs, BACKUP_DIR)
    if not os.path.isdir(root):
        return
    ts_list = sorted(x for x in os.listdir(root) if os.path.isdir(os.path.join(root, x)))
    for old in ts_list[:-keep] if keep > 0 else []:
        shutil.rmtree(os.path.join(root, old), ignore_errors=True)


def _apply_replaces(data, pat, hits, p):
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


def process_patch_be(rootfs, p, write, fh, force_unverified=False, fallback=False,
                     backed=None, ts=None):
    """best-effort 版 AOB 处理：unknown hash 也数命中；0/歧义 → skipped；已知 patched+0 命中 → already。"""
    path = os.path.join(rootfs, p["file"])
    rec = {"id": p["id"], "file": p["file"], "expect": p.get("expect", 1)}
    if not os.path.exists(path):
        rec["status"] = "missing-file"; return rec, False
    data = bytearray(open(path, "rb").read())
    rec["input_sha256"] = hashlib.sha256(data).hexdigest()
    h = (fh or {}).get(p["file"])
    st = _file_state(data, h) if h else None
    rec["file_state"] = st or "unanchored"
    pat = parse_pattern(p["match"])
    lo, hi = 0, len(data)
    if p.get("anchor"):
        rng = symbol_range(path, p["anchor"])
        if not rng:
            rec["status"] = "anchor-not-found"
            return rec, False
        lo = rng[0]; hi = rng[1] if rng[1] else len(data)
        rec["anchor_range"] = [hex(lo), hex(hi) if rng[1] else None]
    hits = find_all(data, pat, lo, hi)
    rec["hits"] = [hex(x) for x in hits]
    expect = p.get("expect", 1)
    n = len(hits)

    def do_apply(label):
        if not write:
            rec["status"] = label
            return rec, True
        backup_file(rootfs, path, ts, backed)
        _apply_replaces(data, pat, hits, p)
        # 单条补丁只校验“特征消失”；整文件终态哈希在跑完后统一校验
        # （逐条打补丁时中间态当然不等于 file_hashes[file].patched）。
        ok = not find_all(data, pat, lo, hi)
        if ok:
            atomic_write(path, bytes(data))
            if find_all(open(path, "rb").read(), pat, lo, hi):
                ok = False
                rec["verify"] = "reread-still-matches"
        if not ok:
            if path in backed:  # 回滚到备份（原子替换；直接 copy 会撞 Text file busy）
                atomic_write(path, open(_backup_path(rootfs, path, ts), "rb").read())
            rec["status"] = "verify-failed"
            return rec, False
        rec["output_sha256"] = hashlib.sha256(bytes(data)).hexdigest()
        rec["status"] = "applied"
        rec["applied_as"] = label  # ready / ready-unverified
        return rec, True

    if st == "patched":
        if n == 0:
            rec["status"] = "already"; return rec, True
        if n == expect:
            return do_apply("ready")
        rec["status"] = "expect-mismatch(%d!=%d)" % (n, expect); return rec, False
    if st == "orig":
        if n == 0:
            rec["status"] = "signature-not-found"; return rec, False
        if n == expect:
            return do_apply("ready")
        rec["status"] = "expect-mismatch(%d!=%d)" % (n, expect); return rec, False
    # 未验证（哈希未知或无锚点）
    if n == expect:
        if fallback and not force_unverified:
            rec["status"] = "skipped"
            rec["reason"] = "unknown-hash-fallback"
            rec["force_cmd"] = ("aobpatch.py apply --rootfs %s --patchset <patchset> "
                                "--best-effort --force-unverified --patch-id %s" % (rootfs, p["id"]))
            return rec, True
        return do_apply("ready-unverified")
    if n == 0:
        rec["status"] = "skipped"; rec["reason"] = "no-match"; return rec, True
    rec["status"] = "skipped"; rec["reason"] = "ambiguous(%d!=%d)" % (n, expect); return rec, True


def _mirror_zip_bytes(rootfs, mirror, data, entry=None):
    """把**给定内容**写进 .restore 归档的同名条目（zip 是 fnOS 还原的真源）。

    先更新 zip 再写 live：fnOS 的还原守护会从 zip 覆盖 live，若 zip 还是原版，
    任何还原都会把补丁冲掉（并触发整树重建窗口）。
    """
    archive = os.path.join(rootfs, mirror["archive"])
    entry = entry or mirror.get("entry")
    if not entry:
        return {"ok": False, "reason": "no-entry"}
    if not os.path.exists(archive):
        return {"ok": False, "reason": "missing-archive", "archive": mirror["archive"]}
    if not shutil.which("zip"):
        return {"ok": False, "reason": "no-zip-tool"}
    with tempfile.TemporaryDirectory(prefix="fnos-mirror-") as td:
        dst = os.path.join(td, entry)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(data)
        os.chmod(dst, 0o644)          # zip 条目权限必须 644：还原后 nginx 才读得到
        os.utime(dst, None)           # 确保比归档内条目新，强制更新
        r = subprocess.run(["zip", "-q", archive, entry], cwd=td,
                           capture_output=True, text=True)
        return {"ok": r.returncode == 0, "archive": mirror["archive"], "entry": entry,
                "detail": (r.stderr or r.stdout).strip()[-200:]}


def process_text_patch_be(rootfs, p, write, backed=None, ts=None):
    """best-effort 版文本补丁：原子写+备份；not-found/歧义记 skipped 不失败。"""
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
            if data.count(to):
                fr["status"] = "already"
            else:
                fr["status"] = "skipped"; fr["reason"] = "not-found"
        elif n_find != p.get("expect", 1):
            fr["status"] = "skipped"; fr["reason"] = "expect-mismatch(%d!=%d)" % (n_find, p.get("expect", 1))
        else:
            data = data.replace(find, to)
            if data.count(find) != 0:
                fr["status"] = "verify-failed"; allok = False
            else:
                if p.get("mirror") and write:
                    # 先更新 zip（还原真源），再写 live；否则还原守护会把补丁冲掉。
                    # **只在 apply 时做**：check 必须只读，不得改归档。
                    entry = p["mirror"].get("entry") or ("assets/" + os.path.basename(path))
                    fr["mirror"] = _mirror_zip_bytes(rootfs, p["mirror"], bytes(data), entry)
                if write:
                    backup_file(rootfs, path, ts, backed)
                    try:
                        atomic_write(path, bytes(data))
                        fr["write"] = "atomic"
                    except OSError as e:
                        # /usr/trim/www 受完整性守护：写入期间可能正被整体还原
                        # （临时文件被清掉 → ENOENT）。此时 zip 已是补丁版，
                        # 还原守护稍后会把它落回 live；写不进去不算失败。
                        try:
                            with open(path, "wb") as f:
                                f.write(bytes(data))
                            fr["write"] = "inplace-fallback"
                        except OSError as e2:
                            fr["write"] = "deferred-to-restore(%s/%s)" % (
                                e.__class__.__name__, e2.__class__.__name__)
                fr["output_sha256"] = hashlib.sha256(bytes(data)).hexdigest()
                fr["status"] = "applied" if write else "ready"
                any_applied = any_applied or write
                if p.get("mirror") and write:
                    m = _mirror_zip(rootfs, p["mirror"], path)
                    fr["mirror"] = m
        rec["files"].append(fr)
    statuses = [f.get("status") for f in rec["files"]]
    if not allok:
        rec["status"] = "failed"
    elif any_applied:
        rec["status"] = "applied"
    elif all(s == "already" for s in statuses):
        rec["status"] = "already"
    elif all(s in ("already", "ready") for s in statuses):
        rec["status"] = "ready"          # check 模式：待应用
    else:
        rec["status"] = "skipped"
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
    ap.add_argument("--best-effort", action="store_true",
                    help="best-effort：ready/ready-unverified/skipped 三档，单文件失败不阻塞其他文件")
    ap.add_argument("--fallback", action="store_true",
                    help="回退模式：unknown-hash 二进制一律 skipped 并带强制命令")
    ap.add_argument("--force-unverified", action="store_true",
                    help="fallback 下强制应用 unknown-hash 补丁（配合 --patch-id）")
    ap.add_argument("--patch-id", action="append", default=None,
                    help="可重复；只处理指定补丁 id")
    a = ap.parse_args()
    rep = run(a.rootfs, a.patchset, write=(a.cmd == "apply"), only=a.only,
              include_disabled=a.include_disabled, best_effort=a.best_effort,
              fallback=a.fallback, force_unverified=a.force_unverified,
              patch_ids=set(a.patch_id) if a.patch_id else None)
    if a.report:
        json.dump(rep, open(a.report, "w"), ensure_ascii=False, indent=2)
    print(json.dumps(rep, ensure_ascii=False, indent=2))
    sys.exit(0 if rep["ok"] else 1)


if __name__ == "__main__":
    main()
