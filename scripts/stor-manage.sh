#!/usr/bin/env bash
# stor-manage.sh —— fnOS LXC 存储方案的管理工具（把已验证配方固化）
#
# 用法: sudo bash stor-manage.sh create|up|destroy|status|register|unregister
#
# 数据安全：destroy 前检查卷上应用数据（@appmeta/用户目录/appcenter 记录），
#   有数据时默认拒绝，需 CONFIRM_DESTROY=YES 显式确认；先按提示 tar 备份再删。
#   容器未运行或 DB 不可达时按"有数据"处理（fail-closed）。
#
# 方案链路（已在 CT200 实测通过）：
#   zvol ──nvmet──▶ nvme-loop ──▶ /dev/nvmeXnY（对 fnOS 表现为物理盘，有 /sys/block/<dev>/device）
#        └─ partition ─ md(raid1单盘, llbitmap) ─ VG trim_<uuid> ─ LV 0 ─ ext4(+prjquota)
#        └─ 透传 LV 给容器 + bind /dev/dm-N /dev/mdN /dev/nvmeXnYp1
#        └─ 登记 fnOS trim.mount 一行  ──▶ fnOS 挂到 /volN，arrayState=clean，可装应用
#        └─ /sys/block 动态屏蔽（可见性==直通集合），宿主真实盘与 VM104 的盘对 fnOS 不可见
#
# 根因（实测结论）：
#   1) fnOS 的 md 健康判定要求"组件盘出现在它的磁盘列表里"；zvol/loop/dm/md 因缺
#      /sys/block/<dev>/device 而**不会**被列出 → 必须让承载盘是"物理外观"（NVMe/SCSI）。
#   2) fnOS 的 md 需要 `--bitmap=lockless`（sysfs 显示 llbitmap），要用它自带的
#      /usr/trim/bin/mdadm 创建。
#   3) 容器内自建 md/LVM 不可行：LXC cgroup2 的 allow 恒优先、deny 无法挖洞，放行
#      b 9:*/b 252:* 会暴露宿主根盘与 VM104 的盘 → 故改由**宿主**代建（S1-c）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 记录"调用者是否显式传入 CTID"——lib.sh 会把空的 CTID 默认成 200，
# 对 destroy 这类破坏性动作这是危险的（曾因 sudo 清空环境误删 CT200）。见下方 guard。
_CTID_IN="${CTID:-}"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

STATE_DIR="${STATE_DIR:-/var/lib/fnos-stor}"
STATE="$STATE_DIR/ct${CTID}.env"
VOLSTORE="${VOLSTORE:-}"
VOLNAME="${VOLNAME:-vm-${CTID}-disk-1}"
VOLSIZE="${VOLSIZE:-25}"                      # GiB（默认 25G：16G 基础够用，相册 AI 需要更大）
VOLFS="${VOLFS:-ext4}"                        # ext4 | btrfs | zfs（fnOS 三种都认）
DEVID="${DEVID:-2}"                           # devN 序号
NQN="${NQN:-nqn.2026-10.io.fnos:vol${CTID}}"
UNIT="/etc/systemd/system/fnos-stor-ct${CTID}.service"
FNO_MDADM="$STATE_DIR/trim-mdadm"             # fnOS 自带（patched）mdadm 的宿主缓存

conf_has() { grep -qF -- "$1" "/etc/pve/lxc/${CTID}.conf" 2>/dev/null; }
conf_rewrite() { local tmp; tmp="$(mktemp)"; sed "$1" "/etc/pve/lxc/${CTID}.conf" > "$tmp" && cat "$tmp" > "/etc/pve/lxc/${CTID}.conf"; rm -f "$tmp"; }
save_state() { mkdir -p "$STATE_DIR"; { for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$STATE"; }
load_state() { [ -f "$STATE" ] && . "$STATE"; }

ct_hostname() { ct hostname 2>/dev/null || echo "fnos-lxc"; }

# ---------- 1) zvol ----------
ensure_zvol() {
  [ -n "${VOLSTORE:-}" ] || die "需要 VOLSTORE（ZFS 池名，如 VOLSTORE=tank）"
  if ! zfs list -H -o name "${VOLSTORE}/${VOLNAME}" >/dev/null 2>&1; then
    pvesm alloc "$VOLSTORE" "$CTID" "$VOLNAME" "${VOLSIZE}G" >/dev/null
    log "创建 zvol ${VOLSTORE}/${VOLNAME} (${VOLSIZE}G)"
  fi
  ZVOL="/dev/zvol/${VOLSTORE}/${VOLNAME}"
}

# ---------- 2) nvmet + nvme-loop -> /dev/nvmeXnY ----------
# 找 NQN 对应的 NVMe 块设备（按控制器 subsysnqn，**避免误选其他实例的盘**）
nvme_dev_for_nqn() {
  local nqn="$1" c ctr d
  for c in /sys/class/nvme/nvme*; do
    [ -r "$c/subsysnqn" ] || continue
    [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$nqn" ] || continue
    ctr="$(basename "$c")"
    for d in /sys/block/${ctr}n*; do
      [ -e "$d/device" ] && [ -s "$d/dev" ] && { basename "$d"; return 0; }
    done
  done
  return 1
}

ensure_nvme() {
  modprobe nvmet 2>/dev/null; modprobe nvme-loop 2>/dev/null; modprobe nvme-fabrics 2>/dev/null || true
  if [ ! -e "/sys/kernel/config/nvmet/subsystems/$NQN" ]; then
    mkdir -p "/sys/kernel/config/nvmet/subsystems/$NQN"
    echo 1 > "/sys/kernel/config/nvmet/subsystems/$NQN/attr_allow_any_host"
    mkdir -p "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1"
    echo -n "$ZVOL" > "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1/device_path"
    echo 1 > "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1/enable"
    log "nvmet subsystem $NQN -> $ZVOL"
  fi
  # 端口（全局，只需建一次）
  if [ ! -d /sys/kernel/config/nvmet/ports/1 ]; then
    mkdir -p /sys/kernel/config/nvmet/ports/1
    echo loop > /sys/kernel/config/nvmet/ports/1/addr_trtype
    log "nvmet port 1 (loop)"
  fi
  # 把本 NQN 的子系统挂到端口（**总是确保**；修复多实例只挂第一个的 bug）
  if [ -e "/sys/kernel/config/nvmet/subsystems/$NQN" ] \
     && [ ! -e "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN" ]; then
    ln -sfn "/sys/kernel/config/nvmet/subsystems/$NQN" "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN"
    log "nvmet port 1 挂载 $NQN"
  fi
  # 若本 NQN 的盘还没出现，发起 loop connect
  NVME_DEV="$(nvme_dev_for_nqn "$NQN" || true)"
  if [ -z "${NVME_DEV:-}" ]; then
    [ -e /dev/nvme-fabrics ] && echo "transport=loop,nqn=$NQN" > /dev/nvme-fabrics
    local i; for i in 1 2 3 4 5; do
      sleep 1; NVME_DEV="$(nvme_dev_for_nqn "$NQN" || true)"; [ -n "$NVME_DEV" ] && break
    done
    log "发起 loop connect ($NQN)"
  fi
  # 兜底：仍找不到即报错（**不**回退到"第一块盘"，避免误选其他实例）
  [ -n "${NVME_DEV:-}" ] || die "未找到属于 $NQN 的 NVMe 盘（拒绝回退到其他盘）"
  NVME_PART="/dev/${NVME_DEV}p1"
  log "NVMe 盘 = /dev/$NVME_DEV (nqn=$NQN)"
}

# ---------- 3) partition + md + LVM + ext4（fnOS 配方）----------
ensure_stack() {
  load_state
  local vg="${VG:-}"
  if [ -z "$vg" ]; then
    local u; u="$(uuidgen | tr 'A-F' 'a-f')"
    vg="trim_$(echo "$u" | tr '-' '_')"
    UUID="$u"
    save_state "UUID=$UUID" "VG=$vg" "VOLSTORE=$VOLSTORE" "VOLNAME=$VOLNAME" "NQN=$NQN" "VOLFS=$VOLFS"
    log "新 uuid=$UUID vg=$vg"
  fi
  VG="$vg"
  # fnOS 的 mdadm 缓存
  if [ ! -x "$FNO_MDADM" ]; then
    pct pull "$CTID" /usr/trim/bin/mdadm "$FNO_MDADM" >/dev/null 2>&1; chmod +x "$FNO_MDADM"
    log "缓存 fnOS mdadm -> $FNO_MDADM"
  fi
  # 若 VG 已存在，说明栈已在
  if vgs "$VG" >/dev/null 2>&1; then
    MD_DEV="$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | tr -d ' ')"
    DM_DEV="/dev/${VG}/0"
    log "栈已存在：VG=$VG PV=$MD_DEV"
    save_state "UUID=${UUID:-}" "VG=$VG" "MD_DEV=$MD_DEV" "DM_DEV=$DM_DEV" "NQN=$NQN" "VOLSTORE=$VOLSTORE" "VOLNAME=$VOLNAME" "VOLFS=$VOLFS"
    return
  fi
  # 分区
  wipefs -a "/dev/$NVME_DEV" >/dev/null 2>&1 || true
  parted -s "/dev/$NVME_DEV" mklabel gpt
  parted -s "/dev/$NVME_DEV" mkpart primary 1MiB 100%
  partprobe "/dev/$NVME_DEV" 2>/dev/null; sleep 2
  # md（fnOS 配方：lockless bitmap + homehost=容器 hostname + name=0）
  local hn; hn="$(ct_hostname)"
  yes | "$FNO_MDADM" --create "/dev/md/fnos${CTID}" --level=1 --raid-devices=1 \
        --metadata=1.2 --bitmap=lockless --force --run \
        --homehost="$hn" --name=0 "$NVME_PART" 2>&1 | grep -E 'started|forbidden' || true
  sleep 1
  MD_DEV="$(readlink -f "/dev/md/fnos${CTID}" 2>/dev/null || echo "/dev/md/fnos${CTID}")"
  # LVM
  vgcreate "$VG" "$MD_DEV" >/dev/null
  lvcreate -n 0 -l 100%FREE -y "$VG" >/dev/null
  case "$VOLFS" in
    btrfs)
      mkfs.btrfs -f -L fnosvol "/dev/${VG}/0" >/dev/null 2>&1
      log "卷文件系统 = btrfs" ;;
    zfs)
      # fnOS 的 zfs 模型：池名 = trim_<guid>（= VG 名），由 fnOS 侧 import 后挂载。
      # 这里在 LV 上建同名 zpool（带 fnOS 用的池/数据集属性），随即 export，
      # 留给容器内 fnOS 的 zImport（zpool import -a -N -m）导入 → 登记 pool_type=2。
      local pool="$VG"
      zpool create -f \
          -o ashift=12 -o failmode=continue -o autoexpand=on -o autoreplace=on \
          -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posix -O recordsize=1M \
          -O mountpoint=/vol2 -O canmount=on \
          "$pool" "/dev/${VG}/0" >/dev/null 2>&1
      zpool export "$pool" >/dev/null 2>&1 || true
      log "卷文件系统 = zfs（pool=$pool，mountpoint=/vol2，已 export 待容器内 fnOS import）" ;;
    *)
      mkfs.ext4 -F -O project,quota -L fnosvol "/dev/${VG}/0" >/dev/null 2>&1
      log "卷文件系统 = ext4(+project,quota)" ;;
  esac
  DM_DEV="/dev/${VG}/0"
  save_state "UUID=$UUID" "VG=$VG" "MD_DEV=$MD_DEV" "DM_DEV=$DM_DEV" "NQN=$NQN" "VOLSTORE=$VOLSTORE" "VOLNAME=$VOLNAME" "VOLFS=$VOLFS"
  log "栈建成：MD=$MD_DEV VG=$VG LV=$DM_DEV"
}

# ---------- 4) 容器透传（devN + bind + cgroup allow）----------
ensure_passthrough() {
  load_state
  local md_mm dm_mm nv_mm mdn dmn
  mdn="$(basename "${MD_DEV:-}")"; dmn="$(basename "$(readlink -f "${DM_DEV:-}")")"
  if [ -z "$mdn" ] || [ -z "$dmn" ]; then
    die "MD_DEV/DM_DEV 为空（state 可能损坏）；请先修 /var/lib/fnos-stor/ct${CTID}.env"
  fi
  md_mm="$(cat "/sys/class/block/$mdn/dev" 2>/dev/null)"
  dm_mm="$(cat "/sys/class/block/$dmn/dev" 2>/dev/null)"
  nv_mm="$(cat "/sys/class/block/${NVME_DEV}p1/dev" 2>/dev/null)"
  local C="/etc/pve/lxc/${CTID}.conf"
  # 清掉旧的本方案行——按我们生成的**精确整行**删除（旧正则要求名字后紧跟空格，
  # 对 md125/dm-5/nvme1n1p1 这类带数字的名字失配，导致每次 create 都重复累积）
  local tmp; tmp="$(mktemp)"
  grep -vFx \
    -e "dev${DEVID}: ${DM_DEV}" \
    -e "lxc.cgroup2.devices.allow: b ${md_mm} rw" \
    -e "lxc.mount.entry: /dev/${mdn} dev/${mdn} none bind,optional,create=file" \
    -e "lxc.cgroup2.devices.allow: b ${dm_mm} rw" \
    -e "lxc.mount.entry: /dev/${dmn} dev/${dmn} none bind,optional,create=file" \
    -e "lxc.cgroup2.devices.allow: b ${nv_mm} rw" \
    -e "lxc.mount.entry: /dev/${NVME_DEV}p1 dev/${NVME_DEV}p1 none bind,optional,create=file" \
    -e "lxc.cgroup2.devices.allow: c 10:249 rw" \
    -e "lxc.mount.entry: /dev/zfs dev/zfs none bind,optional,create=file" \
    "$C" > "$tmp" || true
  cat "$tmp" > "$C"; rm -f "$tmp"
  {
    echo "dev${DEVID}: ${DM_DEV}"
    echo "lxc.cgroup2.devices.allow: b ${md_mm} rw"
    echo "lxc.mount.entry: /dev/${mdn} dev/${mdn} none bind,optional,create=file"
    echo "lxc.cgroup2.devices.allow: b ${dm_mm} rw"
    echo "lxc.mount.entry: /dev/${dmn} dev/${dmn} none bind,optional,create=file"
    echo "lxc.cgroup2.devices.allow: b ${nv_mm} rw"
    echo "lxc.mount.entry: /dev/${NVME_DEV}p1 dev/${NVME_DEV}p1 none bind,optional,create=file"
  } >> "$C"
  # zfs 卷：透传 /dev/zfs（容器内 fnOS 需 zfs 工具才能挂 zfs 卷）
  if [ "${VOLFS:-ext4}" = "zfs" ]; then
    echo "lxc.cgroup2.devices.allow: c 10:249 rw" >> "$C"
    echo "lxc.mount.entry: /dev/zfs dev/zfs none bind,optional,create=file" >> "$C"
  fi
  log "透传：dev${DEVID}=${DM_DEV} + binds(${mdn},${dmn},${NVME_DEV}p1)${VOLFS:+ [fs=$VOLFS]}"
}

# ---------- 5) /sys/block 动态屏蔽 ----------
ensure_mask() {
  load_state
  local mdn dmn; mdn="$(basename "$MD_DEV")"; dmn="$(basename "$(readlink -f "$DM_DEV")")"
  DEVS="${NVME_DEV} ${mdn} ${dmn}" bash "$SCRIPT_DIR/stor-mask.sh" apply >/dev/null 2>&1 && log "已应用 /sys/block 屏蔽（${NVME_DEV} ${mdn} ${dmn}）"
}

# ---------- 5b) zfs：容器侧挂载 unit ----------
# fnOS 的 zfs 逻辑认为「池被 import 即已挂载」（mount_storage 只跑 zpool import），
# 但原生内核下容器 OpenZFS 在 fnOS 之前就 import 了池（且不挂数据集）→ /vol 缺失。
# 因此在容器内装一个开机 unit：等 /dev/zfs → 必要时 import → `zfs mount -a`。
ensure_zfs_mount() {
  load_state
  [ "${VOLFS:-ext4}" = "zfs" ] || return 0
  local pool="$VG" helper="/usr/local/sbin/fnos-zfs-mount.sh" unit="fnos-zfs-mount.service"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
#!/bin/bash
# fnOS zfs 挂载 helper —— 由 stor-manage.sh 生成
POOL="${pool}"
for i in \$(seq 1 60); do [ -e /dev/zfs ] && break; sleep 1; done
# 若池存在但未导入则导入；随后挂载所有数据集（幂等）
zfs list -H -o name "\$POOL" >/dev/null 2>&1 || zpool import "\$POOL" 2>/dev/null || true
# 只挂载本池（禁止 -a：原生内核无池命名空间，-a 会把宿主其它池/数据集也挂进容器）
zfs mount -R "\$POOL" 2>/dev/null || true
mountpoint -q /vol${DEVID:-2} && echo "mounted \$POOL at /vol${DEVID:-2}"
EOF
  pct push "$CTID" "$tmp" "$helper" --perms 0755 >/dev/null 2>&1; rm -f "$tmp"
  pct exec "$CTID" -- sh -c "cat > /etc/systemd/system/${unit}" <<EOF
[Unit]
Description=fnOS zfs mount (${pool})
DefaultDependencies=no
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${helper}
[Install]
WantedBy=multi-user.target
EOF
  pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl enable "$unit" >/dev/null 2>&1 || true
  # 屏蔽容器自带 OpenZFS 的 zfs-mount.service（它执行 `zfs mount -a`，会把宿主其它池/数据集挂进容器）
  pct exec "$CTID" -- systemctl mask zfs-mount.service >/dev/null 2>&1 || true
  pct exec "$CTID" -- "$helper" >/dev/null 2>&1 || true
  log "已安装容器侧 zfs 挂载 unit（$unit，pool=$pool）并屏蔽 zfs-mount.service"
}

# ---------- 6) 登记 trim.mount ----------
do_register() {
  load_state
  local B uuid ptype
  # zfs：uuid=池名(trim_<uuid>)、pool_type=2；其它：uuid=<VG>-0、pool_type=0
  if [ "${VOLFS:-ext4}" = "zfs" ]; then uuid="$VG"; ptype=2; else uuid="${VG}-0"; ptype=0; fi
  B="$HOST_BACKUP_ROOT/$(ts)-mount-$$"; mkdir -p "$B"
  pct exec "$CTID" -- sh -c "sudo -u postgres pg_dump -d trim -t mount --data-only --column-inserts" > "$B/mount-before.sql" 2>/dev/null
  pct exec "$CTID" -- sh -c "sudo -u postgres psql -d trim -P pager=off -c \"INSERT INTO mount(id,uuid,comment,sync_speed_min,sync_speed_max,stripe_cache_size,warn_frsize,grow,state,pool_type) VALUES (2,'${uuid}','',-1,-1,4096,10,'',0,${ptype}) ON CONFLICT (uuid) DO NOTHING;\" 2>/dev/null"
  log "登记 trim.mount uuid=${uuid} pool_type=${ptype}（备份：$B）"
}
do_unregister() {
  load_state
  pct exec "$CTID" -- sh -c "sudo -u postgres psql -d trim -P pager=off -c \"DELETE FROM mount WHERE uuid IN ('${VG}-0','${VG}');\" 2>/dev/null" >/dev/null
  log "反登记 uuid=${VG}-0 / ${VG}"
}

# ---------- 6b) 应用元数据目录补齐（卷重建后应用可启动）----------
# /volN/@appmeta/<app> 在卷重建后丢失会导致后端启动失败（如 trim.photos 因
# meta 软链接悬空而 mkdir panic）。按 appcenter.app 的 app_name 补建缺失目录
# （root:700，照抄 trim.media 存量约定）。只建目录，不碰应用文件与 DB。
ensure_appmeta() {
  load_state
  local vol="/vol${DEVID:-2}" apps a
  apps="$(pct exec "$CTID" -- sh -c "sudo -u postgres psql -d appcenter -t -c 'select app_name from app' 2>/dev/null" || true)"
  [ -n "$apps" ] || { log "appcenter 不可达或无已安装应用，跳过 @appmeta 补齐"; return 0; }
  for a in $apps; do
    a="$(echo "$a" | tr -d ' ')"
    [ -n "$a" ] || continue
    if pct exec "$CTID" -- sh -c "test -e '$vol/@appmeta/$a'" 2>/dev/null; then
      continue
    fi
    if pct exec "$CTID" -- sh -c "mkdir -p '$vol/@appmeta/$a' && chmod 700 '$vol/@appmeta/$a'" 2>/dev/null; then
      log "补建 $vol/@appmeta/$a"
    else
      log "补建 $vol/@appmeta/$a 失败（$vol 未挂载？）"
    fi
  done
}

# ---------- 7) 开机自愈 unit ----------
ensure_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=fnOS LXC (CT${CTID}) storage self-heal
Before=pve-container@${CTID}.service
After=zfs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SCRIPT_DIR}/stor-manage.sh up
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "fnos-stor-ct${CTID}.service" >/dev/null 2>&1 && log "已启用自愈 unit：$(basename "$UNIT")"
}

# ---------- 顶层动作 ----------
do_create() {
  need_root; need_py; need_ct
  load_state
  log "== stor-manage create (CT$CTID) =="
  ensure_zvol; ensure_nvme; ensure_stack; ensure_passthrough; ensure_mask; ensure_zfs_mount; do_register; ensure_appmeta; ensure_unit
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage","action":"create","ctid":%s,"vg":"%s","md":"%s","lv":"%s"}' "$(date -Is)" "$CTID" "${VG:-}" "${MD_DEV:-}" "${DM_DEV:-}")"
  log "create 完成；重启容器生效：pct reboot $CTID"
}
do_up() {   # 自愈：确保 zvol/nvme/栈/屏蔽/透传 都在（幂等）
  need_root
  load_state
  ensure_zvol || exit 0
  ensure_nvme  || exit 0
  ensure_stack || exit 0
  ensure_mask  || true
  log "up 完成"
}
# ---------- 0) destroy 护栏：卷上有应用数据时默认拒绝 ----------
# 检查信号（任一命中即视为有数据）：
#   容器运行时：/volN/@appmeta 非空，或 /volN 下有数字 uid 目录，或 appcenter.app 有记录；
#   容器未运行时：宿主侧 ro 挂载 LV 检查（只读，不污染）；
#   都查不到 → fail-closed（视为有数据）。
# 有数据且 CONFIRM_DESTROY != YES → 拒绝并打印备份命令。
# 返回 0=有数据（并 echo 原因），1=确认干净。
destroy_has_appdata() {
  local vol="/vol${DEVID:-2}" out n
  if pct status "$CTID" 2>/dev/null | grep -q running; then
    out="$(pct exec "$CTID" -- sh -c "ls -A $vol/@appmeta 2>/dev/null" || true)"
    [ -n "$out" ] && { echo "$vol/@appmeta 非空"; return 0; }
    out="$(pct exec "$CTID" -- sh -c "ls -d $vol/[0-9]* 2>/dev/null" || true)"
    [ -n "$out" ] && { echo "$vol 下有用户目录"; return 0; }
    n="$(pct exec "$CTID" -- sh -c "sudo -u postgres psql -d appcenter -t -c 'select count(*) from app' 2>/dev/null" | tr -d ' ' || echo err)"
    [ "$n" = err ] && { echo "appcenter DB 不可达"; return 0; }
    case "$n" in ''|*[!0-9]*) echo "appcenter DB 返回异常"; return 0;; esac
    [ "$n" -gt 0 ] && { echo "appcenter.app 有 $n 条记录"; return 0; }
    return 1
  fi
  # 容器未运行：宿主侧 ro 挂载检查
  local dev="${DM_DEV:-}"
  [ -b "$dev" ] || { echo "LV 设备不存在，无法检查"; return 0; }
  local mnt; mnt="$(mktemp -d)"
  if mount -o ro "$dev" "$mnt" 2>/dev/null; then
    local r=1
    [ -n "$(ls -A "$mnt/@appmeta" 2>/dev/null)" ] && { echo "@appmeta 非空"; r=0; }
    [ "$r" = 1 ] && [ -n "$(ls -d "$mnt"/[0-9]* 2>/dev/null)" ] && { echo "卷上有用户目录"; r=0; }
    umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true
    return $r
  fi
  rmdir "$mnt" 2>/dev/null || true
  echo "宿主侧 ro 挂载失败，无法检查"
  return 0
}

do_destroy() {
  need_root
  load_state
  log "== stor-manage destroy (CT$CTID) =="
  local dreason
  if dreason="$(destroy_has_appdata)"; then
    if [ "${CONFIRM_DESTROY:-}" != "YES" ]; then
      manifest_add "$(printf '{"ts":"%s","script":"stor-manage","action":"destroy-refused","ctid":%s,"reason":"%s"}' "$(date -Is)" "$CTID" "$dreason")"
      cat >&2 <<EOF
拒绝：卷上可能有应用数据（${dreason}），destroy 会格式化整个卷。
先备份（示例，容器运行时）：
  sudo -n pct exec $CTID -- tar czf - -C /vol${DEVID:-2} @appmeta 1000 2>/dev/null > ~/vol-appdata-${CTID}.tgz
确认要删则重跑并显式确认：
  sudo -n env CTID=$CTID VOLSTORE=${VOLSTORE:-} CONFIRM_DESTROY=YES bash $0 destroy
EOF
      exit 2
    fi
    log "已显式确认销毁有数据的卷（${dreason}）"
  fi
  do_unregister 2>/dev/null || true
  systemctl disable --now "fnos-stor-ct${CTID}.service" >/dev/null 2>&1 || true; rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null || true
  DEVS="${NVME_DEV:-}" bash "$SCRIPT_DIR/stor-mask.sh" rollback >/dev/null 2>&1 || true
  # zfs：移除容器侧挂载 unit（须在 pct stop 之前）
  pct exec "$CTID" -- systemctl disable --now fnos-zfs-mount.service >/dev/null 2>&1 || true
  pct exec "$CTID" -- rm -f /etc/systemd/system/fnos-zfs-mount.service /usr/local/sbin/fnos-zfs-mount.sh >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl unmask zfs-mount.service >/dev/null 2>&1 || true
  pct exec "$CTID" -- systemctl daemon-reload >/dev/null 2>&1 || true
  pct stop "$CTID" >/dev/null 2>&1 || true
  # zfs 卷：池可能处于 export 状态（待容器 import）→ 先 import 再 destroy，最后 vgremove
  if [ -n "${VG:-}" ]; then
    zpool import -N "$VG" >/dev/null 2>&1 || true
    zpool destroy -f "$VG" >/dev/null 2>&1 || true
  fi
  [ -n "${VG:-}" ] && { vgremove -f "$VG" >/dev/null 2>&1 || true; }
  # 停**本实例**的 md（只停 state 记录的；不遍历 /proc/mdstat，避免影响其他实例）
  if [ -n "${MD_DEV:-}" ] && [ -b "$MD_DEV" ] \
     && [ "$(cat "/sys/block/$(basename "$MD_DEV")/md/level" 2>/dev/null)" = "raid1" ]; then
    mdadm --stop "$MD_DEV" >/dev/null 2>&1 || true
  fi
  # 断开本 NQN 的 loop 控制器（若有 nvme CLI）
  command -v nvme >/dev/null 2>&1 && nvme disconnect -n "$NQN" >/dev/null 2>&1 || true
  [ -e /sys/kernel/config/nvmet/ports/1/subsystems/$NQN ] && rm -f "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN" 2>/dev/null || true
  rmdir "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1" 2>/dev/null || true
  rmdir "/sys/kernel/config/nvmet/subsystems/$NQN" 2>/dev/null || true
  zfs destroy "${VOLSTORE}/${VOLNAME}" >/dev/null 2>&1 || true
  # 移除本方案的透传行（dev + bind + cgroup allow），锚定行尾，避免残留/重复
  local C="/etc/pve/lxc/${CTID}.conf"
  if [ -f "$C" ]; then
    local t; t="$(mktemp)"
    grep -vE "^(dev${DEVID}: |lxc\.mount\.entry: /dev/[^ ]+ dev/[^ ]+ none bind,optional,create=file$|lxc\.cgroup2\.devices\.allow: [bc] [0-9]+:[0-9]+ rw$)" "$C" > "$t" 2>/dev/null || true
    cat "$t" > "$C"; rm -f "$t"
  fi
  rm -f "$STATE"
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage","action":"destroy","ctid":%s,"confirm":"%s"}' "$(date -Is)" "$CTID" "${CONFIRM_DESTROY:-no}")"
  log "destroy 完成"
}
do_status() {
  need_root
  load_state
  log "== stor-manage status (CT$CTID) =="
  printf '  zvol      : %s\n' "$(zfs list -H -o name,volsize "${VOLSTORE}/${VOLNAME}" 2>/dev/null || echo 缺失)"
  printf '  nvmet NQN : %s\n' "$([ -e /sys/kernel/config/nvmet/subsystems/$NQN ] && echo 存在 || echo 缺失)"
  printf '  NVMe 盘   : %s\n' "$(nvme_dev_for_nqn "$NQN" 2>/dev/null || echo 缺失)"
  printf '  VG        : %s\n' "$(vgs "${VG:-trim_none}" --noheadings -o vg_name 2>/dev/null | tr -d ' ' || echo -)"
  printf '  md/LV     : %s / %s\n' "${MD_DEV:-?}" "${DM_DEV:-?}"
  printf '  透传 dev%s: %s\n' "$DEVID" "$(conf_has "dev${DEVID}:" && echo 有 || echo 无)"
  printf '  /sys/block 屏蔽: %s\n' "$(conf_has "sys/block" && echo 有 || echo 无)"
  printf '  自愈 unit : %s\n' "$(systemctl is-enabled "fnos-stor-ct${CTID}.service" 2>/dev/null || echo 未启用)"
  if pct status "$CTID" 2>/dev/null | grep -q running; then
    printf '  容器内 /vol: %s\n' "$(ct sh -c 'findmnt -rno TARGET,SOURCE | grep /vol | tr "\n" " "' 2>/dev/null)"
  fi
}

case "${1:-status}" in
  create)     do_create ;;
  up)         do_up ;;
  destroy)    [ -n "$_CTID_IN" ] || { echo "拒绝：destroy 必须显式指定 CTID（防误删；如: sudo -n env CTID=201 bash $0 destroy）" >&2; exit 2; }; do_destroy ;;
  status)     do_status ;;
  register)   do_register ;;
  unregister) do_unregister ;;
  *) echo "用法: $0 create|up|destroy|status|register|unregister"; exit 2 ;;
esac
