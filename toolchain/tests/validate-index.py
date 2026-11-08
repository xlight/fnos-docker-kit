#!/usr/bin/env python3
"""validate-index.py — 校验 toolchain/patches/index.json 与补丁集一致。

规则：
  1. 顶层 revision 必须是正整数且单调（仅校验存在性与类型；单调性由生成器保证，
     重复生成时 revision 只增不减，这里校验 revision >= 1）。
  2. 每个版本条目：patchset 文件存在；sha256 与文件实际哈希一致；
     ready/total 与补丁集 validation 一致；status 与 ready==total 一致（ready）或 partial。
  3. fnos_version（去 V）必须等于索引的版本键。

用法: python3 fnos/toolchain/tests/validate-index.py [--index <path>] [--patches-dir <dir>]
退出码: 0 全部通过；1 任一不符。
"""
import argparse, hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
TC = os.path.dirname(HERE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default=os.path.join(TC, "patches", "index.json"))
    ap.add_argument("--patches-dir", default=os.path.join(TC, "patches"))
    a = ap.parse_args()
    errs = []
    idx = json.load(open(a.index, encoding="utf-8"))
    rev = idx.get("revision")
    if not isinstance(rev, int) or rev < 1:
        errs.append("top-level revision must be a positive integer, got %r" % rev)
    versions = idx.get("versions") or {}
    if not isinstance(versions, dict) or not versions:
        errs.append("versions must be a non-empty object")
    for ver, e in sorted(versions.items()):
        ps_name = e.get("patchset")
        ps_path = os.path.join(a.patches_dir, ps_name or "")
        if not ps_name or not os.path.isfile(ps_path):
            errs.append("%s: patchset file missing: %s" % (ver, ps_name))
            continue
        raw = open(ps_path, "rb").read()
        ps = json.loads(raw)
        # 索引里的 sha256 指向的是**脱敏后发布**的文件；私有仓里的补丁集带详细
        # reason 字段，这里用与 sync-public.sh desensitize 相同的变换在内存中
        # 归一化后再算哈希（对已脱敏的公开仓文件该变换是幂等的）。
        pub = json.loads(raw)
        if isinstance(pub.get("derived_from_table"), str):
            pub["derived_from_table"] = "private-table:" + str(pub.get("fnos_version", "unknown"))
        for x in pub.get("patches", []):
            if isinstance(x, dict):
                if "retired_reason" in x:
                    x["retired_reason"] = "retired"
                if "disabled_reason" in x:
                    x["disabled_reason"] = "disabled (opt-in available)"
        sha = hashlib.sha256(json.dumps(pub, ensure_ascii=False, indent=2).encode()).hexdigest()
        if e.get("sha256") != sha:
            errs.append("%s: index sha256 mismatch (index=%s published=%s)" % (ver, e.get("sha256"), sha))
        pv = str(ps.get("fnos_version", "")).lstrip("Vv")
        if pv != ver:
            errs.append("%s: patchset fnos_version=%s != index key" % (ver, pv))
        val = ps.get("validation") or {}
        if not val:
            errs.append("%s: patchset has no validation block" % ver)
        else:
            if (e.get("ready"), e.get("total")) != (val.get("ready"), val.get("total")):
                errs.append("%s: ready/total mismatch (index=%s/%s validation=%s/%s)" % (
                    ver, e.get("ready"), e.get("total"), val.get("ready"), val.get("total")))
            want = "ready" if val.get("ready") == val.get("total") else "partial"
            if e.get("status") not in ("ready", "partial", "missing"):
                errs.append("%s: bad status %r" % (ver, e.get("status")))
            elif e.get("status") != want and e.get("status") != "missing":
                errs.append("%s: status %r but validation implies %r" % (ver, e.get("status"), want))
            if e.get("validated_at") != val.get("validated_at"):
                errs.append("%s: validated_at mismatch" % ver)
    if errs:
        for e in errs:
            print("FAIL:", e, file=sys.stderr)
        return 1
    print("index OK: revision=%s versions=%s" % (rev, ",".join(sorted(versions))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
