#!/usr/bin/env python3
# ============================================================================
# consumer-list-test.py —— 消费者清单**构建期**静态校验的回归（无破坏性）
#
# 覆盖 validate_consumer_list()：
#   ① 合法清单 + unit 都在镜像里 → 无错误
#   ② 清单缺失 → 报错
#   ③ 清单为空 → 报错
#   ④ 条目不是 .service → 报错
#   ⑤ unit 在镜像里不存在 → 报错并点名
#
# 用法: python3 toolchain/tests/consumer-list-test.py
# 退出码: 0 全过；1 有失败
# ============================================================================
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PATCH = os.path.join(os.path.dirname(HERE), "fnos_patch.py")
PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("PASS: %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: %s" % msg)


def load():
    spec = importlib.util.spec_from_file_location("fnos_patch", PATCH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def mkroot(units, list_body=None):
    root = tempfile.mkdtemp(prefix="fnos-cons-test.")
    d = os.path.join(root, "usr/lib/systemd/system")
    os.makedirs(d)
    for u in units:
        open(os.path.join(d, u), "w").close()
    if list_body is not None:
        p = os.path.join(root, "usr/local/share/fnos-toolchain/lib-consumers.txt")
        os.makedirs(os.path.dirname(p))
        with open(p, "w", encoding="utf-8") as f:
            f.write(list_body)
    return root


def main():
    mod = load()

    root = mkroot(["a.service", "b.service"], "a.service\nb.service\n")
    errs = mod.validate_consumer_list(root)
    if errs == []:
        ok("① 合法清单无错误")
    else:
        bad("① 合法清单报错: %s" % errs)

    root = mkroot(["a.service"], None)
    errs = mod.validate_consumer_list(root)
    if errs and "缺失" in errs[0]:
        ok("② 清单缺失 → 报错")
    else:
        bad("② 清单缺失未报错: %s" % errs)

    root = mkroot([], "# only comments\n\n")
    errs = mod.validate_consumer_list(root)
    if errs and "为空" in errs[0]:
        ok("③ 清单为空 → 报错")
    else:
        bad("③ 清单为空未报错: %s" % errs)

    root = mkroot(["a.service"], "a.service\nnot-a-unit\n")
    errs = mod.validate_consumer_list(root)
    if errs and any("不是 unit 名" in e for e in errs):
        ok("④ 非 unit 名 → 报错")
    else:
        bad("④ 非 unit 名未报错: %s" % errs)

    root = mkroot(["a.service"], "a.service\nmissing.service\n")
    errs = mod.validate_consumer_list(root)
    if errs and any("missing.service" in e and "不存在" in e for e in errs):
        ok("⑤ 镜像缺 unit → 报错并点名")
    else:
        bad("⑤ 缺 unit 未点名: %s" % errs)

    print("== consumer-list 测试: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())