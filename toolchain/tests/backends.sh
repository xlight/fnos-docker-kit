#!/usr/bin/env bash
# ============================================================================
# tests/backends.sh — 3.3 btrfs / 3.4 zfs 镜像后端验证（需 root；较慢）
# 用法: ROOTFS=<打补丁后的rootfs> bash tests/backends.sh
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
ROOTFS="${ROOTFS:-}"
PS="$TC/patches/fnos-1.2.0701.json"
BTRFS_IMG="${BTRFS_IMG:-./btrfs-test.raw}"
ZFS_DS="${ZFS_DS:-wd500g/fnos-test}"
PY="${PYTHON:-python3}"
fail=0

[ -n "$ROOTFS" ] && [ -d "$ROOTFS" ] || { echo "缺少已打补丁的 rootfs：先对 ISO 跑 fnos_patch apply，再 ROOTFS=<rootfs> 重跑"; exit 2; }

echo "==================== 3.3 btrfs 后端 ===================="
"$PY" "$TC/fnos_image.py" mkraw "$ROOTFS" "$BTRFS_IMG" 12 --fs=btrfs || fail=1
"$PY" "$TC/fnos_image.py" check "$BTRFS_IMG" --patchset="$PS" || fail=1

echo "==================== 3.4 zfs 后端 ===================="
"$PY" "$TC/fnos_image.py" mkzfs "$ROOTFS" "$ZFS_DS" || fail=1
"$PY" "$TC/fnos_image.py" check "$ZFS_DS" --patchset="$PS" || fail=1

echo
[ "$fail" = 0 ] && echo "BACKENDS: PASS" || echo "BACKENDS: FAIL"
exit $fail
