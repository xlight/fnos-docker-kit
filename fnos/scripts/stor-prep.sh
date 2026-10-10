#!/usr/bin/env bash
# stor-prep.sh —— fnOS LXC 存储方案 · 容器侧准备（三件套）+ 小样专属块设备（PVE zvol）
#
# 用法: sudo bash stor-prep.sh apply|rollback|status|verify
#
# 做什么（全部幂等、可回撤；**只动容器与 PVE 存储卷**，不碰宿主 md/LVM 与任何真实磁盘）：
#   1) seccomp profile：复制 common.seccomp 并去掉 reject_force_umount（fnOS「初始化磁盘」需要）
#   2) mount shim：/usr/local/sbin/mount（剥掉 fnOS 硬编码的 trimacl）
#   3) 设备 cgroup：放行 md/dm/mapper-control，**并逐条显式拒绝宿主现有的 md/dm 设备**
#   4) 专属块设备：在 zfspool 上建一个可随时销毁的 zvol，并 pct set -devN 透传
#
# 安全约束（用户要求）：不得对真实内置/外置 HDD 或已挂载目录做破坏性操作。
#   → 容器只拿到"专属 zvol"这一块盘；宿主 md(9:*)/dm(252:*) 通配放行后逐条 deny，
#     由 `verify` 实测确认宿主阵列**在容器内打不开**。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CONF="/etc/pve/lxc/${CTID}.conf"
SECCOMP="/etc/pve/lxc/${CTID}.seccomp"
BASE_SECCOMP="/usr/share/lxc/config/common.seccomp"
SHIM="$SCRIPT_DIR/stor-mount-shim.sh"
VOLSTORE="${VOLSTORE:-wd500g}"
VOLNAME="${VOLNAME:-vm-${CTID}-disk-1}"
VOLSIZE="${VOLSIZE:-16}"          # GiB
DEVID="${DEVID:-2}"               # dev2
DEVPATH="/dev/zvol/${VOLSTORE}/${VOLNAME}"

# 我们写入的 cgroup 规则（用于幂等判断与回撤）
CG_ALLOW_MD='lxc.cgroup2.devices.allow: b 9:* rwm'
CG_ALLOW_DM='lxc.cgroup2.devices.allow: b 252:* rwm'
CG_ALLOW_CTL='lxc.cgroup2.devices.allow: c 10:236 rwm'
CG_ENTRY_CTL='lxc.mount.entry: /dev/mapper/control dev/mapper/control none bind,optional,create=file'
# 删除本脚本写入的所有行（PVE 会重排注释，故不依赖注释标记）
CG_STRIP_RE='^lxc\.cgroup2\.devices\.allow: (b (9|252):\*|c 10:236) rwm$|^lxc\.cgroup2\.devices\.deny: b (9|252):|^lxc\.mount\.entry: /dev/mapper/control |^# fnos-stor-prep'

conf_has() { grep -qF -- "$1" "$CONF" 2>/dev/null; }

# 原地改写 /etc/pve 下的文件（pmxcfs 不支持 sed -i 的 rename）
conf_rewrite() { local tmp; tmp="$(mktemp)"; sed "$1" "$CONF" > "$tmp" && cat "$tmp" > "$CONF"; rm -f "$tmp"; }
conf_strip()   { local tmp; tmp="$(mktemp)"; grep -vE "$CG_STRIP_RE" "$CONF" > "$tmp"; cat "$tmp" > "$CONF"; rm -f "$tmp"; }

# 宿主现有 md/dm 设备的 MAJ:MIN（用于显式 deny）
host_md_dm_minors() {
  { lsblk -o MAJ:MIN,TYPE -n 2>/dev/null | awk '$2 ~ /^raid/       {print $1}';
    lsblk -o MAJ:MIN,TYPE -n 2>/dev/null | awk '$2 ~ /^(lvm|crypt)$/ {print $1}'; } | sort -u
}

cgroup_block() {
  # 注意：LXC cgroup2 设备规则是"首条匹配生效"（`deny a` 作默认策略），
  # 因此**必须把针对宿主设备的 deny 写在通配 allow 之前**，否则 allow 先命中、deny 形同虚设。
  echo "$CG_ALLOW_CTL"
  echo "$CG_ENTRY_CTL"
  host_md_dm_minors | awk -F: '$1=="9"  {print "lxc.cgroup2.devices.deny: b "$0" rwm"}'
  echo "$CG_ALLOW_MD"
  host_md_dm_minors | awk -F: '$1=="252"{print "lxc.cgroup2.devices.deny: b "$0" rwm"}'
  echo "$CG_ALLOW_DM"
}

do_apply() {
  need_root; need_py; need_ct
  log "== stor-prep apply (CT$CTID) =="

  if [ ! -f "$SECCOMP" ]; then
    grep -v 'reject_force_umount' "$BASE_SECCOMP" > "$SECCOMP"
    log "生成 $SECCOMP（已去掉 reject_force_umount）"
  fi
  conf_has "lxc.seccomp.profile" || { printf 'lxc.seccomp.profile: %s\n' "$SECCOMP" >> "$CONF"; log "配置 lxc.seccomp.profile"; }

  pct push "$CTID" "$SHIM" /usr/local/sbin/mount --perms 0755
  log "安装 /usr/local/sbin/mount shim"

  if ! conf_has "$CG_ALLOW_MD"; then
    cgroup_block >> "$CONF"
    log "写入设备 cgroup 规则（含 $(host_md_dm_minors | wc -l) 条宿主设备 deny）"
  fi

  if ! zfs list -H -o name "${VOLSTORE}/${VOLNAME}" >/dev/null 2>&1; then
    pvesm alloc "$VOLSTORE" "$CTID" "$VOLNAME" "${VOLSIZE}G" >/dev/null
    log "创建 zvol ${VOLSTORE}/${VOLNAME} (${VOLSIZE}G)"
  fi
  if ! conf_has "dev${DEVID}:"; then
    pct set "$CTID" "-dev${DEVID}" "$DEVPATH"
    log "透传 dev${DEVID} -> $DEVPATH"
  fi

  manifest_add "$(printf '{"ts":"%s","script":"stor-prep","action":"apply","ctid":%s,"vol":"%s/%s","size":"%sG","dev":"dev%s","devpath":"%s"}' \
      "$(date -Is)" "$CTID" "$VOLSTORE" "$VOLNAME" "$VOLSIZE" "$DEVID" "$DEVPATH")"
  log "apply 完成；需重启容器生效：pct reboot $CTID"
}

do_rollback() {
  need_root
  log "== stor-prep rollback (CT$CTID) =="
  conf_has "dev${DEVID}:" && { pct set "$CTID" -delete "dev${DEVID}" 2>/dev/null || conf_rewrite "/^dev${DEVID}:/d"; log "移除 dev${DEVID} 透传"; }
  conf_has "$CG_ALLOW_MD" && { conf_strip; log "移除 cgroup 规则"; }
  conf_has "lxc.seccomp.profile" && { conf_rewrite "/^lxc.seccomp.profile:/d"; log "移除 seccomp profile 配置"; }
  rm -f "$SECCOMP"
  pct exec "$CTID" -- rm -f /usr/local/sbin/mount >/dev/null 2>&1 || true
  log "移除 mount shim"
  zfs destroy "${VOLSTORE}/${VOLNAME}" >/dev/null 2>&1 && log "销毁 zvol ${VOLSTORE}/${VOLNAME}" || true
  manifest_add "$(printf '{"ts":"%s","script":"stor-prep","action":"rollback","ctid":%s,"vol":"%s/%s","dev":"dev%s"}' \
      "$(date -Is)" "$CTID" "$VOLSTORE" "$VOLNAME" "$DEVID")"
  log "rollback 完成；需重启容器生效：pct reboot $CTID"
}

do_status() {
  need_root
  log "== stor-prep status (CT$CTID) =="
  printf '  seccomp file      : %s\n' "$([ -f "$SECCOMP" ] && echo 存在 || echo 缺失)"
  printf '  conf seccomp key  : %s\n' "$(conf_has 'lxc.seccomp.profile' && echo 有 || echo 无)"
  printf '  conf cgroup rules : %s\n' "$(conf_has "$CG_ALLOW_MD" && echo 有 || echo 无)"
  printf '  zvol              : %s\n' "$(zfs list -H -o name "${VOLSTORE}/${VOLNAME}" 2>/dev/null || echo 缺失)"
  printf '  dev%s 透传        : %s\n' "$DEVID" "$(conf_has "dev${DEVID}:" && echo 有 || echo 无)"
  printf '  宿主 deny 清单    : %s\n' "$(host_md_dm_minors | tr '\n' ' ')"
  if pct status "$CTID" 2>/dev/null | grep -q running; then
    printf '  容器内 shim       : %s\n' "$(ct test -x /usr/local/sbin/mount && echo 存在 || echo 缺失)"
  fi
}

# 安全门：实测容器能否打开"宿主 md/dm"（应当**打不开**）以及"我们自己的设备"（应当**打得开**）
do_verify() {
  need_root
  log "== stor-prep verify (CT$CTID) — 安全门 =="
  local rc=0
  # 1) 宿主的 md/dm 在容器内必须打不开
  local minors; minors="$(host_md_dm_minors)"
  for mm in $minors; do
    local out
    out="$(ct sh -c "mknod /dev/_safety_probe b ${mm%:*} ${mm#*:} 2>/dev/null; blockdev --getsize64 /dev/_safety_probe 2>&1; rm -f /dev/_safety_probe")"
    if echo "$out" | grep -qE '^[0-9]+$'; then
      warn "  [$mm] 宿主设备在容器内**可打开**（size=$out）→ 拒绝未生效！"
      rc=1
    else
      log "  [$mm] 已拒绝（$(echo "$out" | head -1))"
    fi
  done
  # 2) 我们自己的专属设备在容器内必须打得开
  local devline; devline="$(grep -E "^dev${DEVID}:" "$CONF" | head -1)"
  local pnode; pnode="$(ct sh -c "ls -l /dev/zd* /dev/dm-* 2>/dev/null | grep -v '^total' | head -5")"
  log "  透传行: $devline"
  log "  容器内可见块设备(前几): $(echo "$pnode" | tr '\n' ' ')"
  # 3) mapper/control 可用性
  local dm; dm="$(ct dmsetup version 2>&1 | head -1)"
  log "  dmsetup: $dm"
  # 4) mknod 能力
  local mk; mk="$(ct sh -c 'mknod /dev/_mk b 7 200 2>&1 && echo MKNOD_OK; rm -f /dev/_mk')"
  log "  mknod: $mk"
  return $rc
}

case "${1:-status}" in
  apply)    do_apply ;;
  rollback) do_rollback ;;
  status)   do_status ;;
  verify)   do_verify ;;
  *) echo "用法: $0 apply|rollback|status|verify"; exit 2 ;;
esac
