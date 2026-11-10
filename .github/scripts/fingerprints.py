#!/usr/bin/env python3
"""fingerprints.py —— 目标版本二进制指纹样本（design D5/D7）。

指纹 = 目标版本各二进制文件的 sha256。它回答"这个补丁集对我这个版本能用多少"：
补丁集声明了每个文件的 {orig, patched} 哈希，目标版本的当前哈希落在其中即覆盖。

三种来源（信任级别不同）：
  tier-A / state=factory   —— 官方 ISO 出厂 rootfs 上算出的（CI 产出，权威级）
  tier-A / state=patched   —— 从已发布镜像回填（证明"已在目标态"，**不**证明锚点有效）
  tier-B                   —— 运行中容器自报（只留本地，不进公开索引）

用法：
  # 从 CI 的 patch-report 提取出厂指纹
  python3 fingerprints.py extract --report patch-report.json --version 1.2.1000 --out fp.json
  # 从已发布镜像回填（历史版本）
  python3 fingerprints.py from-image --image xlight/fnos-dockermode:1.2.1000 \
      --patchset patches/fnos-1.2.1000.json --version 1.2.1000 --out fp.json
  # 校验：指纹哈希是否落在补丁集的 orig/patched 集合内
  python3 fingerprints.py verify --fingerprint fp.json --patchset patches/fnos-1.2.1000.json
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iter_file_records(report):
    """报告里的（文件, input_sha256）记录，按出现顺序。

    二进制补丁：记录级 {file, input_sha256}；
    文本补丁：记录内 files[] = [{file, input_sha256}, ...]。
    """
    for rec in report.get("patches") or report.get("items") or []:
        if rec.get("files"):
            for fr in rec["files"]:
                if fr.get("file") and fr.get("input_sha256"):
                    yield fr["file"], fr["input_sha256"]
        elif rec.get("file") and rec.get("input_sha256"):
            yield rec["file"], rec["input_sha256"]


def extract(report, version, state="factory", source="tier-A", patchset=None):
    """按 file 去重，**取第一条记录的 input_sha256**。

    为什么取第一条：同一文件可能被多条补丁命中，后一条记录读到的是"已被前一条
    打过"的中间态；直接遍历会得到"被打过一半"的哈希，不能代表出厂态。
    """
    files = {}
    for path, sha in iter_file_records(report):
        if path in files:
            continue
        files[path] = sha
    return {"version": version,
            "source": source,
            "state": state,
            "files": dict(sorted(files.items())),
            "patchset": patchset or report.get("patchset"),
            "patchset_sha256": report.get("patchset_sha256"),
            "generated_at": now_iso()}


def from_image(image, patchset_path, version):
    """从已发布镜像回填指纹（state=patched）。只用被补丁的文件。"""
    ps = json.load(open(patchset_path, encoding="utf-8"))
    files = {}
    cid = subprocess.run(["docker", "create", image], capture_output=True, text=True)
    if cid.returncode != 0:
        raise RuntimeError("docker create 失败: %s" % cid.stderr.strip()[:200])
    cid = cid.stdout.strip()
    try:
        for rel in sorted((ps.get("file_hashes") or {}).keys()):
            tmp = tempfile.mkdtemp()
            dest = os.path.join(tmp, os.path.basename(rel))
            cp = subprocess.run(["docker", "cp", "%s:%s" % (cid, rel), dest],
                                capture_output=True, text=True)
            if cp.returncode != 0:
                continue
            data = open(dest, "rb").read()
            files[rel] = hashlib.sha256(data).hexdigest()
            try:
                os.remove(dest)
                os.rmdir(tmp)
            except OSError:
                pass
    finally:
        subprocess.run(["docker", "rm", cid], capture_output=True, text=True)
    return {"version": version,
            "source": "tier-A",
            "state": "patched",
            "files": dict(sorted(files.items())),
            "patchset": os.path.basename(patchset_path),
            "generated_at": now_iso()}


def verify(fp, patchset_path):
    """指纹哈希是否落在补丁集的 {orig, patched} 集合内（可复算覆盖度）。"""
    ps = json.load(open(patchset_path, encoding="utf-8"))
    fh = ps.get("file_hashes") or {}
    out = {"total": 0, "covered": 0, "missing": [], "unknown": []}
    for rel, sha in (fp.get("files") or {}).items():
        out["total"] += 1
        e = fh.get(rel)
        if not e:
            out["unknown"].append(rel)
            continue
        allowed = set()
        for k in ("orig", "patched"):
            v = e.get(k)
            if isinstance(v, list):
                allowed.update(v)
            elif v:
                allowed.add(v)
        if sha in allowed:
            out["covered"] += 1
        else:
            out["missing"].append(rel)
    return out


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract")
    e.add_argument("--report", required=True)
    e.add_argument("--version", required=True)
    e.add_argument("--out", required=True)
    e.add_argument("--state", default="factory")
    b = sub.add_parser("from-image")
    b.add_argument("--image", required=True)
    b.add_argument("--patchset", required=True)
    b.add_argument("--version", required=True)
    b.add_argument("--out", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--fingerprint", required=True)
    v.add_argument("--patchset", required=True)
    a = ap.parse_args()
    try:
        if a.cmd == "extract":
            rep = json.load(open(a.report, encoding="utf-8"))
            data = extract(rep, a.version, state=a.state)
        elif a.cmd == "from-image":
            data = from_image(a.image, a.patchset, a.version)
        else:
            fp = json.load(open(a.fingerprint, encoding="utf-8"))
            print(json.dumps(verify(fp, a.patchset), ensure_ascii=False, indent=2))
            return 0
    except Exception as e:
        print("fingerprints: %s" % e, file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print("fingerprints: %s (%d 文件, state=%s)" % (a.out, len(data["files"]), data["state"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
