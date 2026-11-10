#!/usr/bin/env python3
"""index_builder.py —— 生成就绪索引（versions + samples + coverage）（design D5/D6/D7）。

就绪索引是消费权威副本，公开仓里 `toolchain/patches/index.json` 是它，Release 里的
同名资产是归档快照。两份由同一次发布产生，sha256 必须相同。

三段：
  versions{}  每个补丁集一条：patchset / sha256 / ready / total / status / validated_at
              （+ source_commit：生成该条目时的公开仓提交；+ revoked / superseded_by）
  samples{}   **目标版本**的二进制指纹样本：source(tier-A) + state(factory|patched)
              + files{path: sha256} + generated
              只收官方公开仓 Release 资产里的 tier-A 样本；patched 态只作提示。
  coverage{}  coverage[补丁集版本][目标版本] = {covered_files, total_files, status, missing[]}
              纯哈希运算：目标版本文件的当前哈希 ∈ {orig, patched} 即覆盖。

revision 基线**唯一来源 = 公开仓当前索引**；私有副本只是缓存，不一致时告警并以公开为准。

用法：
  python3 index_builder.py build --stage <暂存目录> [--public-slug owner/name]
                                 [--source-commit <C>] [--revision N] [--offline]
  python3 index_builder.py fetch-sample --version <ver> [--public-slug owner/name] [--out f]
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

# Release 资产直链基址（可用 FNOS_RELEASE_BASE 指向本地镜像做离线测试）
RELEASE_BASE = os.environ.get("FNOS_RELEASE_BASE", "https://github.com")
RELEASE_TMPL = RELEASE_BASE + "/%s/releases/download/%s/%s"


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg):
    print("[index-builder] %s" % msg, file=sys.stderr, flush=True)


def fetch_sample(ver, slug, timeout=30):
    """按 Release 直链拉取某版本的指纹资产（匿名可取，不耗 API 配额）。

    候选 tag：v<ver>，v<ver>-r2..r9（修正发布用新修订号）。
    只接受官方公开仓（slug 由调用方给出）。
    """
    name = "fingerprints-%s.json" % ver
    cands = ["v%s" % ver] + ["v%s-r%d" % (ver, i) for i in range(2, 10)]
    for tag in cands:
        url = RELEASE_TMPL % (slug, tag, name)
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "fnos-index/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                continue
            log("拉取 %s 失败: %s" % (url, e))
            continue
        except Exception as e:
            log("拉取 %s 失败: %s" % (url, e))
            continue
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if d.get("version") != ver or not d.get("files"):
            continue
        d["_tag"] = tag
        d["_url"] = url
        return d
    return None


def norm_hashes(entry):
    """补丁集 file_hashes 的某个键 -> 允许的哈希集合（orig/patched 可能是列表）。"""
    allowed = set()
    for k in ("orig", "patched"):
        v = entry.get(k)
        if isinstance(v, list):
            allowed.update(x for x in v if x)
        elif v:
            allowed.add(v)
    return allowed


def coverage_for(file_hashes, sample_files):
    """纯哈希运算：目标版本文件哈希 ∈ {orig, patched} 即覆盖。"""
    covered, missing = 0, []
    for rel, entry in sorted((file_hashes or {}).items()):
        sha = (sample_files or {}).get(rel)
        if sha and sha in norm_hashes(entry):
            covered += 1
        else:
            missing.append(rel)
    total = len(file_hashes or {})
    return {"covered_files": covered, "total_files": total,
            "status": "ready" if covered == total and total else "partial",
            "missing": missing}


def _semantic(idx):
    """去掉 revision / generated / source_commit 后的语义体（幂等比较用）。

    source_commit 指向"内容提交"：内容变了而补丁集没变时，它会变，但索引的**语义**
    没变 —— 此时保留旧字节即可（旧 source_commit 指向的提交仍含同样的补丁集字节，
    按它固定下载依然拿到一致内容），不必为此前进 revision。
    """
    b = json.loads(json.dumps(idx))
    b.pop("revision", None)
    b.pop("generated", None)
    for e in (b.get("versions") or {}).values():
        e.pop("source_commit", None)
    return b


def _keep_base_if_same(idx, base_file, pdir):
    """索引语义与基线一致 → 保留基线字节（revision 不前进、generated 不变）。

    仅当基线**已经带 source_commit** 时才保留：首次生成时基线可能还没有
    source_commit（例如公开仓里的旧索引），那一次必须补上（容器按提交固定下载
    依赖它），不能因为"语义相同"而一直缺着。
    """
    if not base_file or not os.path.isfile(base_file):
        return None
    try:
        old = json.load(open(base_file, encoding="utf-8"))
    except Exception:
        return None
    if _semantic(old) != _semantic(idx):
        return None
    old_versions = old.get("versions") or {}
    if not old_versions or any(not (e or {}).get("source_commit") for e in old_versions.values()):
        log("基线索引缺 source_commit → 本次补上（不保留旧字节）")
        return None
    with open(base_file, "rb") as f:
        raw = f.read()
    with open(os.path.join(pdir, "index.json"), "wb") as f:
        f.write(raw)
    log("索引语义未变 → 保留基线字节（revision 不前进）")
    return old


def build(stage, slug=None, source_commit="", revision=None, offline=False, base_file=None):
    pdir = os.path.join(stage, "toolchain", "patches")
    versions = {}
    for fn in sorted(os.listdir(pdir)):
        if not (fn.startswith("fnos-") and fn.endswith(".json")):
            continue
        raw = open(os.path.join(pdir, fn), "rb").read()
        ps = json.loads(raw)
        val = ps.get("validation")
        if not val:
            continue
        ver = str(ps.get("fnos_version", "")).lstrip("Vv")
        e = {"patchset": fn,
             "sha256": hashlib.sha256(raw).hexdigest(),
             "ready": val.get("ready"), "total": val.get("total"),
             "status": "ready" if val.get("ready") == val.get("total") else "partial",
             "validated_at": val.get("validated_at")}
        if source_commit:
            e["source_commit"] = source_commit
        versions[ver] = e

    # revision：基线 = 公开仓当前索引（唯一来源；私有副本只是缓存）
    if not base_file:
        base_file = os.path.join(
            os.environ.get("FNOS_PUBLIC_REPO", os.path.expanduser("~/fnos-docker-kit")),
            "toolchain", "patches", "index.json")
    prev = 0
    if base_file and os.path.isfile(base_file):
        try:
            r = json.load(open(base_file)).get("revision")
            if isinstance(r, int) and r >= 0:
                prev = r
        except Exception:
            pass
    rev = revision if revision is not None else prev + 1

    # samples：只收官方公开仓 Release 资产（tier-A）
    samples = {}
    if not offline and slug:
        for ver in sorted(versions):
            s = fetch_sample(ver, slug)
            if not s:
                log("未取到 %s 的指纹资产（该版本不进入矩阵）" % ver)
                continue
            samples[ver] = {"source": s.get("source", "tier-A"),
                            "state": s.get("state", "factory"),
                            "files": s.get("files") or {},
                            "generated": s.get("generated_at") or now_iso(),
                            "asset": "%s/%s" % (s.get("_tag", ""), "fingerprints-%s.json" % ver)}

    # coverage：补丁集 × 目标版本
    coverage = {}
    for pver, e in versions.items():
        ps = json.load(open(os.path.join(pdir, e["patchset"]), encoding="utf-8"))
        fh = ps.get("file_hashes") or {}
        for tver, s in samples.items():
            coverage.setdefault(pver, {})[tver] = coverage_for(fh, s.get("files") or {})

    idx = {"revision": rev, "generated": now_iso(), "versions": versions}
    if samples:
        idx["samples"] = samples
    if coverage:
        idx["coverage"] = coverage
    # 幂等：语义未变 → 保留基线字节（不递增 revision、不改 generated）
    old = _keep_base_if_same(idx, base_file, pdir)
    if old is not None:
        return old
    out = json.dumps(idx, ensure_ascii=False, indent=2) + "\n"
    with open(os.path.join(pdir, "index.json"), "w", encoding="utf-8") as f:
        f.write(out)
    return idx


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--stage", required=True)
    b.add_argument("--public-slug", default=os.environ.get("FNOS_PUBLIC_SLUG", "xlight/fnos-docker-kit"))
    b.add_argument("--source-commit", default=os.environ.get("INDEX_SOURCE_COMMIT", ""))
    b.add_argument("--revision", type=int, default=None)
    b.add_argument("--base-file", default=os.environ.get("INDEX_BASE_FILE", ""))
    b.add_argument("--offline", action="store_true")
    f = sub.add_parser("fetch-sample")
    f.add_argument("--version", required=True)
    f.add_argument("--public-slug", default=os.environ.get("FNOS_PUBLIC_SLUG", "xlight/fnos-docker-kit"))
    f.add_argument("--out", default="")
    a = ap.parse_args()
    if a.cmd == "fetch-sample":
        s = fetch_sample(a.version, a.public_slug)
        if not s:
            log("未取到 %s 的指纹资产" % a.version)
            return 1
        if a.out:
            open(a.out, "w", encoding="utf-8").write(json.dumps(s, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(s, ensure_ascii=False, indent=2))
        return 0
    idx = build(a.stage, slug=a.public_slug, source_commit=a.source_commit,
                revision=a.revision, offline=a.offline, base_file=a.base_file)
    print("[index-builder] revision=%d versions=%s samples=%s coverage=%s" %
          (idx["revision"], ",".join(sorted(idx["versions"])) or "none",
           ",".join(sorted(idx.get("samples") or {})) or "none",
           ",".join(sorted(idx.get("coverage") or {})) or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
