#!/usr/bin/env bash
# ============================================================================
# fnos_deploy.sh — 把 release 镜像部署成 PVE 容器，并做宿主侧装配 + 冒烟
#
# 与构建期分工（design D10）：构建期验"镜像本身可跑"；本脚本验"宿主侧装配正确"。
# 只**新增**专属资源；卸载只删专属资源，绝不碰宿主既有磁盘/阵列/其他实例。
#
# 用法（sudo）：
#   fnos_deploy.sh install   <id> [--image <raw>] [--storage <pool>] [--size 12]
#                                [--hostname fnos-lxc] [--cpus 2] [--mem 2048] [--no-start]
#   fnos_deploy.sh start     <id>
#   fnos_deploy.sh smoke     <id>          # 宿主侧装配 + fnOS 服务链 + 写操作
#   fnos_deploy.sh status    <id>
#   fnos_deploy.sh uninstall <id> [--storage <pool>]
#
# 幂等：install 对已存在的容器只做"补齐/更新 conf 并启动"，不重复分配卷。
# ============================================================================
set -uo pipefail
CMD="${1:-}"; ID="${2:-}"
STORAGE="${STORAGE:-}"; SIZE=12; IMAGE=""; HOSTNAME_="fnos-lxc"
CPUS=2; MEM=2048; NO_START=0
# 镜像内需 mask 的单元（与 fnos_patch.py 的 MASK_UNITS 保持一致；空格分隔）
# nfsd 是宿主内核全局态，容器内跑 nfs-server 会直接在宿主起 rpc.nfsd 并与其它实例互踩。
MASK_UNITS="nfs-server.service"
# 网络 IP：默认 DHCP；可设静态以避开被网关屏蔽的 IP（见 README「静态 IP / WAN 出口」）。
#   形式同 PVE net0： "<addr>/<mask>" 或 "<addr>/<mask>,gw=<gw>"。例：
#   FNOS_CT_IP="192.168.199.199/24,gw=192.168.199.1" fnos_deploy.sh install 201
CT_IP="${FNOS_CT_IP:-dhcp}"
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --hostname) HOSTNAME_="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    --mem) MEM="$2"; shift 2;;
    --ip) CT_IP="$2"; shift 2;;
    --no-start) NO_START=1; shift;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" = 0 ] || die "需要 root（用 sudo 运行）"; }
[ -n "$CMD" ] || { sed -n '2,20p' "$0"; exit 2; }
[ "$CMD" = "gpu-lines" ] || { [ -n "$ID" ] || die "缺少容器 id"; }

CONF="/etc/pve/lxc/${ID}.conf"
SECD="/etc/pve/lxc/${ID}.seccomp"
SYSB="/var/lib/lxc/${ID}/sysblock"
VOLNAME="vm-${ID}-disk-0.raw"
DRI_DIR="${DRI_DIR:-/dev/dri}"   # 可覆盖（测试/无 GPU 环境）

SECCOMP_TEXT='2
denylist
[all]
kexec_load errno 1
open_by_handle_at errno 1
init_module errno 1
finit_module errno 1
delete_module errno 1'

# ---- 部署对齐辅助（GPU 直通 / 稳定网络身份）--------------------------------
# 确定性 MAC（PVE OUI + 由 ID 派生，销毁重建不变）
deterministic_mac() {
  local h; h="$(printf 'fnos-lxc-%s' "$ID" | sha256sum | cut -c1-6)"
  printf 'BC:24:11:%s:%s:%s\n' "${h:0:2}" "${h:2:2}" "${h:4:2}"
}

# 从镜像 rootfs 读取组的 gid（raw 挂载只读 / vztmpl 解出 etc/group）
rootfs_gid() { # <image> <group>
  local img="$1" grp="$2" mnt
  case "$img" in
    *.tar.gz|*.tgz)
      tar xzOf "$img" ./etc/group 2>/dev/null | awk -F: -v g="$grp" '$1==g{print $3; exit}';;
    *)
      mnt="$(mktemp -d)"; mount -o loop,ro "$img" "$mnt" 2>/dev/null || { rmdir "$mnt" 2>/dev/null; return 1; }
      awk -F: -v g="$grp" '$1==g{print $3; exit}' "$mnt/etc/group" 2>/dev/null
      umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null;;
  esac
}

# GPU 直通行（宿主有 /dev/dri 时）；devN 序号跳过 2（留给专属存储 dev2）
gpu_dev_lines() { # <image>
  local img="$1" idx=0 d base grp mode gid
  for d in ${DRI_DIR}/card* ${DRI_DIR}/renderD*; do
    [ -e "$d" ] || continue
    base="$(basename "$d")"
    [ "$idx" = 2 ] && idx=3
    case "$base" in
      card*)    grp=video;  mode=0660;;
      renderD*) grp=render; mode=0666;;
      *)        continue;;
    esac
    gid="$(rootfs_gid "$img" "$grp")"
    [ -n "$gid" ] || gid="$([ "$grp" = render ] && echo 105 || echo 44)"
    printf 'dev%d: %s,gid=%s,uid=0,mode=%s\n' "$idx" "$d" "$gid" "$mode"
    idx=$((idx+1))
  done
}

write_conf() {
  local mac gpu
  mac="$(deterministic_mac)"
  gpu="$(gpu_dev_lines "$IMAGE")"
  {
    echo "arch: amd64"
    echo "cores: ${CPUS}"
    echo "features: nesting=1,fuse=1,mknod=1,mount=nfs;cifs"
    echo "hostname: ${HOSTNAME_}"
    echo "memory: ${MEM}"
    echo "net0: name=eth0,bridge=vmbr0,hwaddr=${mac},ip=${CT_IP},ip6=manual,type=veth"
    [ -n "$gpu" ] && printf '%s\n' "$gpu"
    echo "onboot: 0"
    echo "ostype: debian"
    echo "rootfs: ${STORAGE}:${ID}/${VOLNAME},size=${SIZE}G"
    echo "swap: 0"
    echo "unprivileged: 0"
    echo "lxc.apparmor.profile: unconfined"
    echo "lxc.seccomp.profile: ${SECD}"
    if [ -n "$gpu" ]; then
      echo "lxc.mount.entry: /dev/dri/by-path dev/dri/by-path none bind,optional,create=dir"
    fi
    echo "lxc.mount.entry: ${SYSB} sys/block none bind,create=dir"
  } > "$CONF"
}

# ---- 静态 IP：写 NM keyfile（否则镜像内 NIC fuse 的 DHCP keyfile 会把地址改回 DHCP）----
# 幂等；CT_IP=dhcp 时为空操作。形式 "<addr>/<mask>[,gw=<gw>]"。
apply_ct_ip() {
  local id="$1"; [ "$CT_IP" != "dhcp" ] || return 0
  local addr gw ipaddr tmp
  addr="${CT_IP%%,*}"; gw="${CT_IP#*gw=}"; [ "$gw" = "$CT_IP" ] && gw=""
  ipaddr="${addr%%/*}"
  tmp="$(mktemp)"
  { echo "[connection]"; echo "id=eth0"; echo "uuid=$(cat /proc/sys/kernel/random/uuid)"
    echo "type=ethernet"; echo "interface-name=eth0"; echo "autoconnect=true"; echo
    echo "[ethernet]"; echo; echo "[ipv4]"; echo "method=manual"
    echo "address1=${addr}${gw:+,$gw}"; echo "dns=${gw:-$ipaddr};"; echo
    echo "[ipv6]"; echo "addr-gen-mode=default"; echo "method=auto"; } > "$tmp"
  echo "== 写静态 NM keyfile（$addr${gw:+ gw=$gw}）"
  for _ in $(seq 1 30); do pct exec "$id" -- systemctl is-active NetworkManager >/dev/null 2>&1 && break; sleep 2; done
  pct push "$id" "$tmp" /etc/NetworkManager/system-connections/eth0.nmconnection >/dev/null 2>&1
  rm -f "$tmp"
  pct exec "$id" -- sh -c 'chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection; nmcli con reload >/dev/null 2>&1 || true; nmcli con up eth0 >/dev/null 2>&1 || true' 2>&1 | sed 's/^/   /'
}

do_install() {
  need_root
  [ -n "$STORAGE" ] || die "install 需要 --storage（PVE 存储池名）"
  if [ -z "$IMAGE" ]; then
    die "找不到镜像：请显式 --image <raw|vztmpl>（不再自动猜测宿主构建目录）"
  fi
  [ -f "$IMAGE" ] || die "找不到镜像（--image）：$IMAGE"
  case "$IMAGE" in
    *.tar.gz|*.tgz) do_install_vztmpl; return 0;;
  esac

  local path; path="$(pvesm path "${STORAGE}:${ID}/${VOLNAME}" 2>/dev/null || true)"
  if [ -n "$path" ] && [ -f "$path" ]; then
    echo "== rootfs 卷已存在（幂等）：$path"
  else
    echo "== rootfs 卷不存在，创建并写入镜像"
    pvesm alloc "$STORAGE" "$ID" "$VOLNAME" "${SIZE}G" >/dev/null 2>&1 \
      || die "pvesm alloc 失败（storage=$STORAGE）"
    path="$(pvesm path "${STORAGE}:${ID}/${VOLNAME}")"
    # 同文件系统优先 reflink（xfs 上近乎瞬时 + CoW），否则退回 dd
    if cp --reflink=auto "$IMAGE" "$path" 2>/dev/null; then
      echo "   镜像写入: reflink ($(du -h "$path" | cut -f1) 引用)"
    else
      dd if="$IMAGE" of="$path" bs=8M conv=fsync status=none || die "写入镜像失败"
    fi
  fi

  echo "== 写 conf / seccomp / sysblock"
  mkdir -p "$SYSB"
  printf '%s\n' "$SECCOMP_TEXT" > "$SECD"
  write_conf
  echo "   conf -> $CONF"

  if [ "$NO_START" = 0 ]; then
    pct start "$ID" 2>&1 | sed 's/^/   /' || true
  fi
  [ "$NO_START" = 0 ] && apply_ct_ip "$ID"
  echo "== install 完成（storage=$STORAGE, 卷=$path）"
}

# vztmpl（PVE 模板 tar）部署路径：pct create -> 追加宿主侧 lxc.* 行
do_install_vztmpl() {
  need_root
  [ -f "$IMAGE" ] || die "找不到模板（--image）：$IMAGE"
  local mac gpu; mac="$(deterministic_mac)"; gpu="$(gpu_dev_lines "$IMAGE")"
  if pct status "$ID" >/dev/null 2>&1; then
    echo "== 容器 $ID 已存在（幂等）：仅补齐宿主侧配置"
  else
    echo "== pct create（模板=$IMAGE）"
    pct create "$ID" "$IMAGE" \
      --hostname "$HOSTNAME_" --cores "$CPUS" --memory "$MEM" --swap 0 \
      --unprivileged 0 --rootfs "${STORAGE}:${SIZE}" \
      --features 'nesting=1,fuse=1,mknod=1,mount=nfs;cifs' \
      --net0 "name=eth0,bridge=vmbr0,hwaddr=${mac},ip=${CT_IP},ip6=manual,type=veth" \
      --ostype debian >/dev/null 2>&1 || die "pct create 失败"
  fi
  mkdir -p "$SYSB"
  printf '%s\n' "$SECCOMP_TEXT" > "$SECD"
  # 追加宿主侧 lxc.*（pct create 不写这些）
  grep -q 'lxc.apparmor.profile' "$CONF" || echo "lxc.apparmor.profile: unconfined" >> "$CONF"
  grep -q 'lxc.seccomp.profile' "$CONF" || echo "lxc.seccomp.profile: ${SECD}" >> "$CONF"
  if [ -n "$gpu" ]; then
    grep -q 'lxc.mount.entry: /dev/dri/by-path' "$CONF" \
      || echo "lxc.mount.entry: /dev/dri/by-path dev/dri/by-path none bind,optional,create=dir" >> "$CONF"
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      grep -qF "$l" "$CONF" || echo "$l" >> "$CONF"
    done <<< "$gpu"
  fi
  grep -q "$SYSB sys/block" "$CONF" || echo "lxc.mount.entry: ${SYSB} sys/block none bind,create=dir" >> "$CONF"
  if [ "$NO_START" = 0 ]; then pct start "$ID" 2>&1 | sed 's/^/   /' || true; fi
  [ "$NO_START" = 0 ] && apply_ct_ip "$ID"
  echo "== install(vztmpl) 完成"
}

do_start(){ need_root; pct start "$ID"; }

do_status() {
  need_root
  echo "== conf =="; [ -f "$CONF" ] && cat "$CONF" || echo "(无)"
  echo "== pct status =="; pct status "$ID" 2>&1
}

# ---- 冒烟：宿主侧装配 + 服务链 + 写操作（skill 9.1）-------------------------
smoke() {
  local id="$1" ok=1
  local tc_dir; tc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  chk(){ # <desc> <0|1>
    if [ "$2" = 1 ]; then echo "  PASS: $1"; else echo "  FAIL: $1"; ok=0; fi
  }
  echo "== [1] 宿主侧装配 =="
  grep -q 'lxc.apparmor.profile: unconfined' "$CONF" && chk "apparmor=unconfined" 1 || chk "apparmor=unconfined" 0
  [ -f "$SECD" ] && chk "seccomp profile 存在" 1 || chk "seccomp profile 存在" 0
  grep -q "sys/block" "$CONF" && chk "sys/block 掩码 bind" 1 || chk "sys/block 掩码 bind" 0
  grep -q 'features: .*nesting=1' "$CONF" && chk "features nesting/fuse/mknod" 1 || chk "features nesting/fuse/mknod" 0
  grep -q 'mount=nfs;cifs' "$CONF" && chk "features mount=nfs;cifs" 1 || chk "features mount=nfs;cifs" 0
  grep -q 'net0:.*hwaddr=' "$CONF" && chk "net0 稳定 hwaddr" 1 || chk "net0 稳定 hwaddr" 0
  if compgen -G "${DRI_DIR}/card*" >/dev/null 2>&1 || compgen -G "${DRI_DIR}/renderD*" >/dev/null 2>&1; then
    grep -qE 'dev[0-9]+: /dev/dri/' "$CONF" && chk "GPU 直通配置" 1 || chk "GPU 直通配置" 0
    pct exec "$id" -- sh -c 'ls /dev/dri/renderD* >/dev/null 2>&1' && chk "容器内 /dev/dri 可见" 1 || chk "容器内 /dev/dri 可见" 0
  else
    echo "  SKIP: 宿主无 /dev/dri（GPU 直通跳过）"
  fi
  nm="$(pct exec "$id" -- sh -c "nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -m1 '^eth0:' || true")"
  chk "eth0 被 NetworkManager 管理 (=$nm)" "$(echo "$nm" | grep -q 'connected' && echo 1 || echo 0)"
  # WAN 出口：app-center 商店目录(app/list)、更新、云等依赖外网。环境相关 → 只告警不判失败。
  wan="$(pct exec "$id" -- sh -c 'curl -s -m 8 -o /dev/null -w "%{http_code}" https://aps.fnnas.com/api/v1 2>/dev/null || true')"
  if [ -n "$wan" ] && [ "$wan" != "000" ]; then
    echo "  PASS: WAN 出口可达 aps.fnnas.com (=$wan)"
  else
    echo "  WARN: 无 WAN 出口 —— app-center 商店/更新/云会失败（常见：网关屏蔽了该容器的 IP；见 README「静态 IP / WAN 出口」）"
  fi

  echo "== [2] 容器状态 =="
  local st; st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
  chk "容器 running (=$st)" "$([ "$st" = running ] && echo 1 || echo 0)"

  echo "== [3] fnOS 服务链 =="
  for svc in trim_main trim_nginx network_service filestor_service usersrv accountsrv rpc_broker; do
    a="$(pct exec "$id" -- systemctl is-active "$svc" 2>/dev/null || true)"
    chk "service $svc = active (=$a)" "$([ "$a" = active ] && echo 1 || echo 0)"
  done
  a="$(pct exec "$id" -- sh -c 'systemctl is-active postgresql postgresql@15-main postgresql@16-main 2>/dev/null | grep -m1 active || true')"
  chk "postgresql active (=$a)" "$([ "$a" = active ] && echo 1 || echo 0)"
  r="$(pct exec "$id" -- systemctl is-active resmon_service 2>/dev/null || true)"
  chk "resmon_service active (=$r)" "$([ "$r" = active ] && echo 1 || echo 0)"
  rp="$(pct exec "$id" -- python3 -c 'd=open("/usr/trim/bin/resmon_service","rb").read();print(1 if d[0x11b6c8:0x11b6d1]==bytes.fromhex("31c0900f84a7070000") else 0)' 2>/dev/null || echo 0)"
  chk "resmon 已打 veth-kind 补丁（resmon.net 流量可用）" "$rp"
  # 磁盘 I/O 监控：opt-in 补丁，默认不生效。仅烘焙单元、按需 enable（CT201 已启用）。
  pct exec "$id" -- test -f /etc/systemd/system/fnos-disk-io-monitor.service \
    && chk "磁盘 I/O opt-in 单元已烘焙" 1 || chk "磁盘 I/O opt-in 单元已烘焙" 0
  dku="$(pct exec "$id" -- systemctl is-enabled fnos-disk-io-monitor.service 2>/dev/null || echo '')"
  if [ "$dku" = enabled ]; then
    dh="$(pct exec "$id" -- sha256sum /usr/trim/bin/resmon_service 2>/dev/null | awk '{print $1}')"
    chk "磁盘 I/O opt-in 已启用 + resmon 已打 disk-io 补丁 (sha=231f…)" \
        "$([ "$dh" = 231f239460c7e6d3bd75e54040f762e953766a403b18cc9e2b3c47089c80e5ee ] && echo 1 || echo 0)"
  else
    echo "  INFO: 磁盘 I/O 监控默认关闭（opt-in 未启用；启用见 README「磁盘 I/O 监控」）"
  fi

  echo "== [4] 镜像内兼容件 =="
  pct exec "$id" -- test -x /usr/local/sbin/mount && chk "mount shim 在位" 1 || chk "mount shim 在位" 0
  pct exec "$id" -- test -d /usr/local/share/fnos-toolchain/patches && chk "补丁集在镜像内" 1 || chk "补丁集在镜像内" 0
  pct exec "$id" -- /usr/local/sbin/fnos-dirfd-shim.py apply --only aob >/dev/null 2>&1 \
    && chk "AOB 重放（二进制相 / trim 前）成功" 1 || chk "AOB 重放（二进制相）成功" 0
  pct exec "$id" -- /usr/local/sbin/fnos-dirfd-shim.py apply --only text >/dev/null 2>&1 \
    && chk "AOB 重放（文本-www 相 / www 就绪后）成功" 1 || chk "AOB 重放（文本-www 相）成功" 0
  u="$(pct exec "$id" -- systemctl is-enabled fnos-dirfd-shim.service 2>/dev/null || echo '')"
  chk "fnos-dirfd-shim.service 已 enable (=$u)" "$([ "$u" = enabled ] && echo 1 || echo 0)"
  w="$(pct exec "$id" -- systemctl is-enabled fnos-aob-www.service 2>/dev/null || echo '')"
  chk "fnos-aob-www.service 已 enable (=$w)" "$([ "$w" = enabled ] && echo 1 || echo 0)"
  for u in $MASK_UNITS; do
    m="$(pct exec "$id" -- systemctl is-enabled "$u" 2>/dev/null || echo '')"
    chk "$u 已 mask（宿主全局 nfsd 防互踩） (=$m)" "$([ "$m" = masked ] && echo 1 || echo 0)"
  done

  echo "== [5] /proc/mounts 无 trimafs、/fs 为普通目录 =="
  m="$(pct exec "$id" -- sh -c 'grep -c trimafs /proc/mounts 2>/dev/null || true')"
  chk "无 trimafs 挂载 (count=$m)" "$([ "$m" = 0 ] && echo 1 || echo 0)"

  echo "== [6] Web UI =="
  c="$(pct exec "$id" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" -m 8 http://127.0.0.1:5666/ 2>/dev/null' || echo 000)"
  chk "HTTP 200 on :5666 (=$c)" "$([ "$c" = 200 ] && echo 1 || echo 0)"

  echo "== [7] 写操作（touch/rm + 目录挂载点可写） =="
  w="$(pct exec "$id" -- sh -c 'd=/tmp/.fnos-smoke.$$; mkdir -p "$d" && echo hi > "$d/f" && rm -f "$d/f" && rmdir "$d" && echo OK' 2>/dev/null || echo ERR)"
  chk "tmp 写/删成功 (=$w)" "$([ "$w" = OK ] && echo 1 || echo 0)"

  echo "== [8] 存储（若已建专属存储） =="
  volmap="$(pct exec "$id" -- findmnt -rno TARGET,FSTYPE,SOURCE 2>/dev/null | awk '$1 ~ /^\/vol[0-9]+$/' || true)"
  if [ -n "$volmap" ]; then
    echo "$volmap" | sed 's/^/   /'
    while read -r vt _vf _vs; do pct exec "$id" -- df -hT "$vt" 2>/dev/null | tail -1; done <<<"$volmap" | sed 's/^/   /'
    chk "fnOS 卷已挂载" 1
    vfs="$(echo "$volmap" | awk '{print $2}' | sort -u | tr '\n' ',')"
    case "$vfs" in
      *ext4*|*btrfs*|*zfs*) chk "卷 fs 类型可用 (=$vfs)" 1 ;;
      *)                    chk "卷 fs 类型可用 (=$vfs)" 0 ;;
    esac
    # zfs 专属：容器侧挂载 unit 就绪 + 标准 zfs-mount 已屏蔽 + 未误挂宿主其它 zfs 数据集
    if [ "$vfs" = "zfs," ]; then
      u="$(pct exec "$id" -- systemctl is-enabled fnos-zfs-mount.service 2>/dev/null || echo '')"
      chk "fnos-zfs-mount.service 已 enable (=$u)" "$([ "$u" = enabled ] && echo 1 || echo 0)"
      mm="$(pct exec "$id" -- systemctl is-enabled zfs-mount.service 2>/dev/null || echo '')"
      chk "zfs-mount.service 已 mask (=$mm)" "$([ "$mm" = masked ] && echo 1 || echo 0)"
      leak="$(pct exec "$id" -- sh -c 'findmnt -rno TARGET,FSTYPE 2>/dev/null | awk "\$2==\"zfs\"" | grep -vE "^/vol[0-9]+ " | wc -l' || echo 1)"
      chk "未误挂宿主其它 zfs 数据集 (leak=$leak)" "$([ "${leak:-1}" = 0 ] && echo 1 || echo 0)"
    fi
  else
    echo "  SKIP: 未建专属存储（由 stor-manage.sh 建立后再验）"
  fi

  echo "== [9] 上传文件夹/权限检查兼容垫片 =="
  # 版本无关（0701 硬编码偏移已删：0800 下偏移全变）：helper 进容器按版本戳选
  # 烘焙补丁集，跑烘焙 aobpatch check，按 (文件, find->to) 语义定位两个功能站点。
  s9="$(pct push "$id" "$tc_dir/s9-shim-check.py" /tmp/s9-shim-check.py >/dev/null 2>&1 && pct exec "$id" -- python3 /tmp/s9-shim-check.py 2>/dev/null || echo "$(printf 'FAIL\tpush-or-exec\nSOME')")"
  echo "$s9" | grep -E '^(PASS|FAIL)' | sed 's/^/   /'
  case "$s9" in *ALL*) chk "上传文件夹/权限检查垫片在位" 1 ;; *) chk "上传文件夹/权限检查垫片在位" 0 ;; esac

  echo "== [10] 内存视图（memview UI patch + 口径校验） =="
  if [ -x "$tc_dir/../scripts/smoke-memview.sh" ]; then
    CTID="$id" bash "$tc_dir/../scripts/smoke-memview.sh" 2>&1 | sed 's/^/   /'
  else
    echo "  SKIP: memview 机制不在本树（公开裁剪），跳过本节"
  fi

  echo "== [11] 文件管理读通路（file.ls RPC 只读探针） =="
  if [ -z "${FNOS_PASS:-}" ]; then
    echo "  SKIP: 未设 FNOS_PASS（需 fnOS 账号口令），跳过本节"
  else
    _fhost="$(pct exec "$id" -- sh -c 'hostname -I 2>/dev/null' | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    _fvol="$(pct exec "$id" -- sh -c 'findmnt -rno TARGET 2>/dev/null' | grep -m1 -E '^/vol[0-9]+' || true)"
    if [ -z "$_fhost" ] || [ -z "$_fvol" ]; then
      echo "  SKIP: 取不到容器 IP 或 /volN（host=${_fhost:-?} vol=${_fvol:-?}），跳过本节"
    else
      _fpath="${_fvol#/}"
      _fls="$(FNOS_HOST="$_fhost" FNOS_USER="${FNOS_USER:-xlight}" FNOS_PASS="$FNOS_PASS" FNOS_TIMEOUT=60 FNOS_PROBES="[{\"req\":\"file.ls\",\"params\":{\"path\":\"$_fpath\"}}]" python3 "$tc_dir/../scripts/fnos_rpc.py" 2>/dev/null | grep -m1 '^RESULT ' || true)"
      _fok="$(echo "$_fls" | python3 -c 'import sys,json
try:
    r=json.loads(sys.stdin.read()[7:]); f=(r.get("resp") or {}).get("files")
    print(1 if isinstance(f,list) else 0)
except Exception: print(0)')"
      chk "file.ls 返回 files 数组 (vol=$_fvol)" "$_fok"
    fi
  fi

  echo "== [12] 容器内 docker（仅 data-root 已配置时断言） =="
  _droot="$(pct exec "$id" -- cat /usr/trim/etc/dockermgr.conf 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data-root",""))' 2>/dev/null || true)"
  if [ -z "$_droot" ] || [ "$_droot" = "0" ]; then
    echo "  INFO: docker 未配置（data-root 未设），跳过本节"
  else
    _da="$(pct exec "$id" -- systemctl is-active docker 2>/dev/null || echo '')"
    chk "docker active (data-root=$_droot, =$_da)" "$([ "$_da" = active ] && echo 1 || echo 0)"
    pct exec "$id" -- docker ps >/dev/null 2>&1 && chk "docker ps 可连" 1 || chk "docker ps 可连" 0
  fi

  echo
  [ "$ok" = 1 ] && echo "SMOKE: PASS" || echo "SMOKE: FAIL"
  return $(( 1 - ok ))
}

do_uninstall() {
  need_root
  [ -n "$STORAGE" ] || die "uninstall 需要 --storage（PVE 存储池名）"
  echo "== 停止并销毁容器 $ID"
  pct stop "$ID" >/dev/null 2>&1 || true
  pct destroy "$ID" >/dev/null 2>&1 || true
  echo "== 释放 rootfs 卷（仅专属）"
  pvesm free "${STORAGE}:${ID}/${VOLNAME}" >/dev/null 2>&1 || true
  echo "== 删除专属 conf / seccomp / 掩码目录"
  rm -f "$CONF" "$SECD"
  rm -rf "/var/lib/lxc/${ID}"
  echo "== uninstall 完成（其他实例未受影响）"
}

case "$CMD" in
  install)   do_install ;;
  start)     do_start ;;
  status)    do_status ;;
  smoke)     need_root; smoke "$ID" ;;
  uninstall) do_uninstall ;;
  gpu-lines) gpu_dev_lines "$IMAGE" ;;
  *) echo "用法: $0 install|start|smoke|status|uninstall <id> [...]"; exit 2 ;;
esac
