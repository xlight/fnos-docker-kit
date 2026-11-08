#!/usr/bin/env bash
# ============================================================================
# tests/patch-status.sh — fnos_patch.status() 健康契约回归
#
# 契约：status() 每个键都表达"健康即 true"（stage_patch 用 all(values()) 判幂等）；
# 否定语义必须正写（如 "disk-io opt-in disabled by default"）。
# 用临时目录拼两种最小 rootfs 树（默认态 / opt-in 已启用态），分别断言全 true。
# 不依赖 /mnt 真实 rootfs、无需容器。
#
# 用法: bash tests/patch-status.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PY="${PYTHON:-python3}"
# fixture 补丁集文件名参数化（fnos-local-deb-head D2）：缺省取 toolchain 内最新版本，
# PATCHSET_JSON 可覆盖；永不写死具体旧版本。
PATCHSET_JSON="${PATCHSET_JSON:-$(ls "$TC"/patches/fnos-*.json 2>/dev/null | grep -v '\.bak' | sort -V | tail -1)}"
[ -n "$PATCHSET_JSON" ] || { echo "toolchain 内无可用补丁集"; exit 2; }
echo "fixture 补丁集: $(basename "$PATCHSET_JSON")"
W="$(mktemp -d /tmp/opencode/fnos-patch-status.XXXXXX)"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

mk_tree() { # $1=目标 $2=opt-in enabled? (0/1)
  local t="$1" en="$2"
  rm -rf "$t"; mkdir -p "$t/etc" \
    "$t/usr/local/sbin" "$t/usr/local/share/fnos-toolchain/patches" \
    "$t/usr/local/lib" "$t/etc/systemd/system/multi-user.target.wants" \
    "$t/etc/systemd/system/sysinit.target.wants" \
    "$t/etc/systemd/system/timers.target.wants" \
    "$t/etc/systemd/system/trim_main.service.d"
  printf '# fstab\n' > "$t/etc/fstab"
  # boot-tune 健康态：禁用 wait-online（缺该文件 = wait-online none = False）
  mkdir -p "$t/etc/default"
  printf 'WAIT_ONLINE_METHOD=none\n' > "$t/etc/default/networking"
  touch "$t/usr/local/sbin/mount" "$t/usr/local/sbin/fnos-dirfd-shim.py" \
    "$t/usr/local/sbin/fnos-nic-fuse.sh" \
    "$t/usr/local/share/fnos-toolchain/aobpatch.py" \
    "$t/usr/local/lib/libfnos-trashshim.so" \
    "$t/etc/systemd/system/trim_main.service.d/trashshim.conf" \
    "$t/etc/systemd/system/fnos-dirfd-shim.service" \
    "$t/etc/systemd/system/fnos-aob-www.service" \
    "$t/etc/systemd/system/fnos-mountdir.service" \
    "$t/etc/systemd/system/fnos-nic-fuse.service" \
    "$t/etc/systemd/system/fnos-disk-io-monitor.service" \
    "$t/etc/systemd/system/fnos-patch-status.service" \
    "$t/etc/systemd/system/fnos-patch-status.timer" \
    "$t/etc/systemd/system/fnos-patchset-fetch.service" \
    "$t/etc/systemd/system/fnos-nginx-route.service"
  # trim_app_center 状态门（appcenter-tpk-perm D5）：测试树带最小补丁集声明，
  # patched = 假二进制哈希（真实补丁集↔fixture 一致性由 selftest fixture 守卫覆盖），
  # 使契约测试在"已修复"树上仍可断言全 true。
  mkdir -p "$t/usr/trim/bin"
  printf 'status-contract fake trim_app_center\n' > "$t/usr/trim/bin/trim_app_center"
  $PY - "$t/usr/local/share/fnos-toolchain/patches/$(basename "$PATCHSET_JSON")" \
        "$t/usr/trim/bin/trim_app_center" <<'PYEOF'
import hashlib, json, sys
b = open(sys.argv[2], "rb").read()
json.dump({"fnos_version": "status-test", "patches": [],
           "file_hashes": {"usr/trim/bin/trim_app_center":
                           {"orig": "0", "patched": hashlib.sha256(b).hexdigest()}}},
          open(sys.argv[1], "w"))
PYEOF
  ln -s /etc/systemd/system/fnos-dirfd-shim.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-aob-www.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-mountdir.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-patch-status.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-patch-status.timer "$t/etc/systemd/system/timers.target.wants/"
  ln -s /etc/systemd/system/fnos-patchset-fetch.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-nginx-route.service "$t/etc/systemd/system/multi-user.target.wants/"
  ln -s /etc/systemd/system/fnos-nic-fuse.service "$t/etc/systemd/system/sysinit.target.wants/"
  ln -s /dev/null "$t/etc/systemd/system/nfs-server.service"
  ln -s /dev/null "$t/etc/systemd/system/notify_service.service"
  ln -s /dev/null "$t/etc/systemd/system/trim_trashbind.service"
  if [ "$en" = 1 ]; then
    ln -s /etc/systemd/system/fnos-disk-io-monitor.service "$t/etc/systemd/system/multi-user.target.wants/"
  fi
}

check_all_true() { # $1=rootfs $2=label
  $PY - "$TC/fnos_patch.py" "$1" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
st = m.status(sys.argv[2])
bad = {k: v for k, v in st.items() if not v}
if bad:
    print("non-true: %s" % bad)
    sys.exit(1)
print("all %d true" % len(st))
PYEOF
}

check_optin_enabled() { # $1=rootfs：除 disabled-by-default 如实 false 外其余全 true
  $PY - "$TC/fnos_patch.py" "$1" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
st = m.status(sys.argv[2])
rest = {k: v for k, v in st.items() if k != "disk-io opt-in disabled by default"}
bad = {k: v for k, v in rest.items() if not v}
if bad:
    print("non-true: %s" % bad)
    sys.exit(1)
if st.get("disk-io opt-in disabled by default", True) is not False:
    print("expected 'disk-io opt-in disabled by default' == False, got: %r"
          % st.get("disk-io opt-in disabled by default"))
    sys.exit(1)
print("opt-in enabled state ok (%d keys true + disabled-by-default False)" % len(rest))
PYEOF
}

echo "== 1) 默认态 rootfs（opt-in 未启用）status 全 true =="
T="$W/default"; mk_tree "$T" 0
if check_all_true "$T" "default"; then ok "默认态全 true"; else no "默认态非全 true"; fi

echo "== 2) opt-in 已启用态：其余全 true + disabled-by-default 如实 false =="
T="$W/optin"; mk_tree "$T" 1
if check_optin_enabled "$T"; then ok "opt-in 启用态语义正确"; else no "opt-in 启用态语义错误"; fi

rm -rf "$W"
echo
echo "== 结果: PASS=$pass FAIL=$fail =="
[ "$fail" = 0 ]
