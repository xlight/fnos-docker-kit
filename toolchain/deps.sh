#!/usr/bin/env bash
# ============================================================================
# deps.sh — fnOS 工具链依赖：检查 / 自动安装
#
# 用法:
#   deps.sh check        # 只检查，缺失则列出并退出非 0
#   deps.sh install      # 缺什么装什么（apt-get）
#   deps.sh ensure       # check -> 缺则 install（幂等；工具脚本可调用它自动兜底）
#
# 依赖（按用途）:
#   构建/提取 : isoinfo(genisoimage) dd tar gzip
#   镜像生成  : mkfs.ext4/e2fsck(e2fsprogs) rsync mount
#   特征推导  : objdump/readelf(binutils)
#   前端补丁  : zip/unzip（更新 .restore/www.zip 内加密条目）
# ============================================================================
set -uo pipefail

# 工具名 -> apt 包名
declare -A PKG=(
  [objdump]=binutils
  [readelf]=binutils
  [isoinfo]=genisoimage
  [dd]=coreutils
  [tar]=tar
  [gzip]=gzip
  [rsync]=rsync
  [mount]=util-linux
  [mkfs.ext4]=e2fsprogs
  [e2fsck]=e2fsprogs
  [mkfs.btrfs]=btrfs-progs
  [btrfs]=btrfs-progs
  [zfs]=zfsutils-linux
  [zpool]=zfsutils-linux
  [zip]=zip
  [unzip]=unzip
)

check() {
  local miss=() tools=()
  for t in "${!PKG[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then :; else miss+=("$t"); fi
  done
  if [ "${#miss[@]}" -eq 0 ]; then
    echo "OK: 依赖齐全"
    return 0
  fi
  # 去重包名
  local pkgs=()
  for t in "${miss[@]}"; do pkgs+=("${PKG[$t]}"); done
  printf '缺工具: %s\n' "${miss[*]}"
  printf '对应包: %s\n' "$(printf '%s\n' "${pkgs[@]}" | sort -u | tr '\n' ' ')"
  return 1
}

install() {
  local need=()
  for t in "${!PKG[@]}"; do command -v "$t" >/dev/null 2>&1 || need+=("${PKG[$t]}"); done
  if [ "${#need[@]}" -eq 0 ]; then echo "OK: 无需安装"; return 0; fi
  local pkgs; pkgs="$(printf '%s\n' "${need[@]}" | sort -u | tr '\n' ' ')"
  echo "安装: $pkgs"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq $pkgs
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $pkgs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $pkgs
  else
    echo "无已知包管理器（apt/apk/dnf）；请手动安装: $pkgs" >&2
    return 1
  fi
}

case "${1:-ensure}" in
  check)   check ;;
  install) install ;;
  ensure)  check || install; check ;;
  *) echo "用法: $0 check|install|ensure"; exit 2 ;;
esac
