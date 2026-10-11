#!/usr/bin/env bash
# ============================================================================
# stor-manage-docker.sh — Docker 模式专属存储编排（宿主预建栈）
#
# 链路（与 LXC stor-manage.sh 同构，会话已实证）：
#   zvol ──nvmet──▶ nvme-loop ──▶ /dev/nvmeXnY（物理外观，有 /sys/block/<dev>/device）
#        └─ partition ─ md(raid1单盘, llbitmap, fnOS 自带 mdadm) ─ VG trim_<uuid> ─ LV 0
#        └─ ext4(+project,quota, label fnosvol)
#        └─ 输出透传集 {nvme, p1, md, dm}（state 落盘），由 fnos_deploy_docker.sh 消费
#
# 用法（sudo）：
#   stor-manage-docker.sh create    <name> [--size 16] [--volstore wd500g]
#   stor-manage-docker.sh up        <name>   # 宿主重启后自愈：reconnect + assemble + activate
#   stor-manage-docker.sh devices   <name>   # 重解析设备路径（刷新 state；打印 DEVS= 行）
#   stor-manage-docker.sh status    <name>
#   stor-manage-docker.sh register  <name>   # 容器内登记 trim.mount（CONTAINER= 覆盖容器名）
#   stor-manage-docker.sh unregister <name>
#   stor-manage-docker.sh mount     <name> [--vol 2]
#   stor-manage-docker.sh destroy   <name>   # 必须显式 name；容器在用时拒绝
#
# 安全：destroy 只拆 state 关联的本实例资源（NQN/VG/md/zvol）；
#       检测到既有阵列元数据时 assemble（不 wipe），只有全新盘才建栈。
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

CMD="${1:-}"; NAME="${2:-}"; shift 2 2>/dev/null || true
SIZE_N="${VOLSIZE:-16}"
VOLSTORE="${VOLSTORE:-wd500g}"
VOLMP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --size) SIZE_N="$2"; shift 2;;
    --volstore) VOLSTORE="$2"; shift 2;;
    --vol) VOLMP="/vol$2"; shift 2;;
    *) die "未知参数: $1";;
  esac
done
[ -n "$CMD" ] || { sed -n '2,24p' "$0"; exit 2; }
case "$CMD" in create|up|devices|status|register|unregister|mount|destroy) ;; *) die "未知动作: $CMD";; esac
[ -n "$NAME" ] || die "缺少实例名"

STATE_DIR="${STATE_DIR:-/var/lib/fnos-stor-docker}"
STATE="$STATE_DIR/$NAME.env"
IMAGE="${IMAGE:-fnos-dockermode:1.2.0701-fix}"
ZVOL_NAME="dvol-$NAME"
HOMEHOST="${HOMEHOST:-fnos-docker}"
VOLMP="${VOLMP:-/vol2}"

save_state() { mkdir -p "$STATE_DIR"; { for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$STATE"; }
load_state() { [ -f "$STATE" ] && . "$STATE"; }
need_state() { load_state; [ -n "${VG:-}" ] || die "state 缺失或损坏: $STATE（先 create）"; }

# ---------- 1) zvol ----------
ensure_zvol() {
  if ! zfs list -H -o name "${VOLSTORE}/${ZVOL_NAME}" >/dev/null 2>&1; then
    zfs create -V "${SIZE_N}G" "${VOLSTORE}/${ZVOL_NAME}" >/dev/null || die "zfs create 失败"
    log "创建 zvol ${VOLSTORE}/${ZVOL_NAME} (${SIZE_N}G)"
  fi
  ZVOL="/dev/zvol/${VOLSTORE}/${ZVOL_NAME}"
  local i; for i in 1 2 3 4 5; do [ -e "$ZVOL" ] && break; sleep 1; done
  [ -e "$ZVOL" ] || die "zvol 设备未出现: $ZVOL"
}

# ---------- 2) nvmet + nvme-loop -> /dev/nvmeXnY ----------
# 按控制器 subsysnqn 选盘（拒绝回退到其他盘，对齐 LXC 多实例教训）
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
  local NQN="${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}"
  modprobe nvmet 2>/dev/null; modprobe nvme-loop 2>/dev/null; modprobe nvme-fabrics 2>/dev/null || true
  if [ ! -e "/sys/kernel/config/nvmet/subsystems/$NQN" ]; then
    mkdir -p "/sys/kernel/config/nvmet/subsystems/$NQN"
    echo 1 > "/sys/kernel/config/nvmet/subsystems/$NQN/attr_allow_any_host"
    mkdir -p "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1"
    echo -n "$ZVOL" > "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1/device_path"
    echo 1 > "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1/enable"
    log "nvmet subsystem $NQN -> $ZVOL"
  fi
  if [ ! -d /sys/kernel/config/nvmet/ports/1 ]; then
    mkdir -p /sys/kernel/config/nvmet/ports/1
    echo loop > /sys/kernel/config/nvmet/ports/1/addr_trtype
    log "nvmet port 1 (loop)"
  fi
  if [ -e "/sys/kernel/config/nvmet/subsystems/$NQN" ] \
     && [ ! -e "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN" ]; then
    ln -sfn "/sys/kernel/config/nvmet/subsystems/$NQN" "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN"
    log "nvmet port 1 挂载 $NQN"
  fi
  NVME_DEV="$(nvme_dev_for_nqn "$NQN" || true)"
  if [ -z "${NVME_DEV:-}" ]; then
    [ -e /dev/nvme-fabrics ] && echo "transport=loop,nqn=$NQN" > /dev/nvme-fabrics
    local i; for i in 1 2 3 4 5; do sleep 1; NVME_DEV="$(nvme_dev_for_nqn "$NQN" || true)"; [ -n "$NVME_DEV" ] && break; done
    log "发起 loop connect ($NQN)"
  fi
  [ -n "${NVME_DEV:-}" ] || die "未找到属于 $NQN 的 NVMe 盘（拒绝回退到其他盘）"
  NVME_PART="/dev/${NVME_DEV}p1"
  log "NVMe 盘 = /dev/$NVME_DEV (nqn=$NQN)"
}

# ---------- 3) partition + md + LVM + ext4（fnOS 配方） ----------
# fnOS 自带(patched) mdadm：优先本地缓存；缺失时从 docker 镜像离线提取
fnos_mdadm() {
  local m="$STATE_DIR/trim-mdadm"
  if [ ! -x "$m" ]; then
    mkdir -p "$STATE_DIR"
    docker run --rm --entrypoint /bin/cat "$IMAGE" /usr/trim/bin/mdadm > "$m" 2>/dev/null \
      || die "无法从镜像提取 fnOS mdadm（image=$IMAGE）"
    chmod +x "$m"
    log "缓存 fnOS mdadm -> $m"
  fi
  printf '%s' "$m"
}

# 按成员分区反查 md 设备（sysfs，绕开 symlink 依赖）
md_dev_for_member() { # <part-path> -> /dev/mdX
  local mm s
  mm="$(cat "/sys/class/block/$(basename "$1")/dev" 2>/dev/null)" || return 1
  [ -n "$mm" ] || return 1
  for s in /sys/block/md*/md/dev-*; do
    [ "$(basename "$s")" = "$mm" ] && { printf '/dev/%s\n' "$(basename "$(dirname "$(dirname "$s")")")"; return 0; }
  done
  return 1
}

ensure_stack() {
  local mdadm; mdadm="$(fnos_mdadm)"
  # 已建成
  if vgs "$VG" >/dev/null 2>&1; then
    MD_DEV="$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | tr -d ' ')"
    DM_DEV="/dev/${VG}/0"
    log "栈已存在：VG=$VG PV=$MD_DEV"
    return 0
  fi
  # 宿主重启后：阵列元数据还在 -> assemble（绝不 wipe）
  if blkid -o value -s TYPE "$NVME_PART" 2>/dev/null | grep -q linux_raid_member; then
    log "检测到既有阵列元数据 → assemble + activate（非重建）"
    "$mdadm" --assemble --force --run "$MD_TARGET" "$NVME_PART" >/dev/null 2>&1 \
      || "$mdadm" --assemble --force --run --scan >/dev/null 2>&1 || true
    sleep 1
    pvscan --cache >/dev/null 2>&1 || true
    vgchange -ay "$VG" >/dev/null 2>&1 || true
    MD_DEV="$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | tr -d ' ')"
    if [ -b "${MD_DEV:-}" ]; then
      DM_DEV="/dev/${VG}/0"
      log "既有栈已恢复：MD=$MD_DEV VG=$VG"
      return 0
    fi
    # 阵列在但无 LVM 元数据 = 上次中断的半成品 → 重置后全新建栈
    log "阵列存在但无 VG 元数据（半成品）→ 重置后全新建栈"
    "$mdadm" --stop "$MD_TARGET" >/dev/null 2>&1 || true
    wipefs -a "$NVME_PART" >/dev/null 2>&1 || true
  fi
  # 全新盘：建栈
  wipefs -a "/dev/$NVME_DEV" >/dev/null 2>&1 || true
  parted -s "/dev/$NVME_DEV" mklabel gpt
  parted -s "/dev/$NVME_DEV" mkpart primary 1MiB 100%
  # 等分区节点就绪（partprobe 后 udev 落节点有时延）
  local i; for i in $(seq 1 15); do
    [ -b "$NVME_PART" ] && break
    partprobe "/dev/$NVME_DEV" 2>/dev/null || true; sleep 1
  done
  [ -b "$NVME_PART" ] || die "分区节点未出现: $NVME_PART"
  udevadm settle 2>/dev/null || true
  local out rc
  out="$("$mdadm" --create "$MD_TARGET" --level=1 --raid-devices=1 \
        --metadata=1.2 --bitmap=lockless --force --run \
        --homehost="$HOMEHOST" --name=0 "$NVME_PART" </dev/null 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E 'started|lockless|allback|Fail|error' || true
  [ "$rc" = 0 ] || die "mdadm create 失败(rc=$rc): $(printf '%s' "$out" | tail -2)"
  sleep 1
  MD_DEV="$(readlink -f "$MD_TARGET" 2>/dev/null || true)"
  [ -b "${MD_DEV:-}" ] || MD_DEV="$(md_dev_for_member "$NVME_PART" || true)"
  [ -b "${MD_DEV:-}" ] || die "md 设备未出现（期望 $MD_TARGET）"
  vgcreate "$VG" "$MD_DEV" >/dev/null
  lvcreate -n 0 -l 100%FREE -y "$VG" >/dev/null
  mkfs.ext4 -F -O project,quota -L fnosvol "/dev/${VG}/0" >/dev/null 2>&1
  DM_DEV="/dev/${VG}/0"
  log "栈建成：MD=$MD_DEV VG=$VG LV=$DM_DEV"
}

# ---------- 设备解析（以 VG→PV 为准，落 state 并输出） ----------
save_devices() {
  local nvme_real p1_real md_real dm_real
  nvme_real="/dev/${NVME_DEV}"
  p1_real="/dev/${NVME_DEV}p1"
  md_real="$(pvs --noheadings -o pv_name --select "vg_name=$VG" 2>/dev/null | tr -d ' ')"
  dm_real="$(readlink -f "/dev/${VG}/0" 2>/dev/null || true)"
  [ -b "${md_real:-}" ] || die "md 设备解析失败（VG=$VG 的 PV 不可见）"
  [ -b "${dm_real:-}" ] || die "dm 设备解析失败（/dev/${VG}/0）"
  DEVS="$nvme_real $p1_real $md_real $dm_real"
  save_state "NAME=$NAME" "NQN=${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}" \
    "VG=$VG" "UUID=${UUID:-}" "VOLSTORE=$VOLSTORE" "ZVOL_NAME=$ZVOL_NAME" \
    "NVME_DEV=$NVME_DEV" "NVME_PART=$p1_real" "MD_DEV=$md_real" "DM_DEV=$dm_real" "DEVS=\"$DEVS\""
  printf 'DEVS="%s"\n' "$DEVS"
}

# ---------- 顶层动作 ----------
do_create() {
  need_root; load_state
  log "== stor-manage-docker create ($NAME) =="
  VG="${VG:-}"; UUID="${UUID:-}"
  NQN="${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}"
  MD_TARGET="/dev/md/fnsdk-${NAME}"
  if [ -z "$VG" ]; then
    local u; u="$(uuidgen | tr 'A-F' 'a-f')"
    VG="trim_$(echo "$u" | tr '-' '_')"
    UUID="$u"
    log "新 uuid=$UUID vg=$VG"
  fi
  ensure_zvol
  ensure_nvme
  ensure_stack
  save_devices
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage-docker","action":"create","name":"%s","vg":"%s","md":"%s","devs":"%s"}' "$(date -Is)" "$NAME" "$VG" "$MD_DEV" "$DEVS")"
  log "create 完成。部署: fnos_deploy_docker.sh install <容器名> --stor-docker $NAME"
}

do_up() {   # 宿主重启自愈：zvol 在、nvmet 重连、阵列 assemble、VG 激活
  need_root; load_state
  [ -n "${VG:-}" ] || die "state 缺失（先 create）"
  NQN="${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}"
  MD_TARGET="/dev/md/fnsdk-${NAME}"
  log "== stor-manage-docker up ($NAME) =="
  ensure_zvol
  ensure_nvme
  ensure_stack
  save_devices
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage-docker","action":"up","name":"%s","devs":"%s"}' "$(date -Is)" "$NAME" "$DEVS")"
  log "up 完成"
}

do_devices() {
  need_root; need_state
  NQN="${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}"
  MD_TARGET="/dev/md/fnsdk-${NAME}"
  NVME_DEV="$(nvme_dev_for_nqn "$NQN" || true)"
  [ -n "${NVME_DEV:-}" ] || die "未找到 NQN=$NQN 的 NVMe 盘（先跑 up）"
  save_devices
}

do_status() {
  need_root
  echo "state: $STATE"; [ -f "$STATE" ] && cat "$STATE" || echo "  (缺失)"
  if [ -f "$STATE" ]; then
    load_state
    echo "容器在跑: $(docker ps --format '{{.Names}}' 2>/dev/null | grep -cx "${CONTAINER:-$NAME}")"
    echo "vgs: $(vgs "$VG" --noheadings 2>/dev/null || echo '缺失')"
    echo "md:  $(cat "/sys/block/$(basename "${MD_DEV:-x}")/md/array_state" 2>/dev/null || echo '缺失')"
  fi
}

do_register() {
  need_root; need_state
  local CON="${CONTAINER:-$NAME}"
  docker ps --format '{{.Names}}' | grep -qx "$CON" || die "容器 $CON 未运行（CONTAINER= 可覆盖容器名）"
  local i; for i in $(seq 1 30); do
    docker exec "$CON" sudo -u postgres pg_isready >/dev/null 2>&1 && break; sleep 2
  done
  docker exec "$CON" sh -c "sudo -u postgres psql -d trim -P pager=off -c \"INSERT INTO mount(id,uuid,comment,sync_speed_min,sync_speed_max,stripe_cache_size,warn_frsize,grow,state,pool_type) VALUES (2,'${VG}-0','',-1,-1,4096,10,'',0,0) ON CONFLICT (uuid) DO NOTHING;\"" 2>&1 | tail -1
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage-docker","action":"register","name":"%s","container":"%s","uuid":"%s-0"}' "$(date -Is)" "$NAME" "$CON" "$VG")"
  log "已登记 trim.mount uuid=${VG}-0（容器 $CON）"
}

do_unregister() {
  need_root; need_state
  local CON="${CONTAINER:-$NAME}"
  docker exec "$CON" sh -c "sudo -u postgres psql -d trim -P pager=off -c \"DELETE FROM mount WHERE uuid IN ('${VG}-0','${VG}');\"" >/dev/null 2>&1 || true
  log "已反登记 uuid=${VG}-0 / ${VG}"
}

do_mount() {
  need_root; need_state
  local CON="${CONTAINER:-$NAME}"
  docker ps --format '{{.Names}}' | grep -qx "$CON" || die "容器 $CON 未运行"
  docker exec "$CON" sh -c "mkdir -p '$VOLMP' && mountpoint -q '$VOLMP' || mount -t ext4 '$DM_DEV' '$VOLMP'" \
    || die "挂载失败（$DM_DEV -> $VOLMP）"
  docker exec "$CON" df -hT "$VOLMP" | tail -1
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage-docker","action":"mount","name":"%s","container":"%s","vol":"%s"}' "$(date -Is)" "$NAME" "$CON" "$VOLMP")"
  log "已挂载 $VOLMP（$DM_DEV）"
}

do_destroy() {
  need_root
  [ -n "$NAME" ] || die "destroy 需要显式实例名（防误删）"
  [ -f "$STATE" ] || die "state 不存在: $STATE（拒绝销毁无状态目标）"
  load_state
  local CON="${CONTAINER:-$NAME}"
  if docker ps --format '{{.Names}}' | grep -qx "$CON"; then
    die "容器 $CON 正在运行（先 fnos_deploy_docker.sh uninstall $CON）"
  fi
  log "== stor-manage-docker destroy ($NAME) =="
  # 1) 反登记（best effort，容器需在）
  do_unregister 2>/dev/null || true
  # 2) LV/VG
  lvremove -f "/dev/${VG}/0" >/dev/null 2>&1 || true
  vgremove -f "$VG" >/dev/null 2>&1 || true
  log "VG $VG 已回收"
  # 3) md（只停本实例 state 记录的）
  local mdn; mdn="$(basename "${MD_DEV:-}")"
  if [ -n "$mdn" ] && [ -b "/dev/$mdn" ]; then
    mdadm --stop "/dev/$mdn" >/dev/null 2>&1 || true
    log "md $mdn 已停止"
  fi
  # 4) nvmet（只删本实例 NQN）
  local NQN="${NQN:-nqn.2026-10.io.fnos:$ZVOL_NAME}"
  rm -f "/sys/kernel/config/nvmet/ports/1/subsystems/$NQN" 2>/dev/null || true
  rmdir "/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1" 2>/dev/null || true
  rmdir "/sys/kernel/config/nvmet/subsystems/$NQN" 2>/dev/null || true
  # 5) loop 控制器（有 delete_controller 则断）
  local c; for c in /sys/class/nvme/nvme*; do
    [ -r "$c/subsysnqn" ] || continue
    [ "$(cat "$c/subsysnqn" 2>/dev/null)" = "$NQN" ] || continue
    echo 1 > "$c/delete_controller" 2>/dev/null || true
  done
  # 6) zvol
  zfs destroy "${VOLSTORE:-wd500g}/${ZVOL_NAME}" >/dev/null 2>&1 || true
  rm -f "$STATE"
  manifest_add "$(printf '{"ts":"%s","script":"stor-manage-docker","action":"destroy","name":"%s","vg":"%s"}' "$(date -Is)" "$NAME" "${VG:-}")"
  log "destroy 完成（只拆本实例资源）"
}

case "$CMD" in
  create)     do_create ;;
  up)         do_up ;;
  devices)    do_devices ;;
  status)     do_status ;;
  register)   do_register ;;
  unregister) do_unregister ;;
  mount)      do_mount ;;
  destroy)    do_destroy ;;
  *) echo "用法: $0 create|up|devices|status|register|unregister|mount|destroy <name> [...]"; exit 2 ;;
esac
