#!/usr/bin/env bash
# ============================================================================
# fnos_deploy_docker.sh — 把打过补丁的 fnOS rootfs 部署成 Docker 容器
#
# 对应 LXC 版 fnos_deploy.sh 的 Docker 对照实现。只**新增**专属资源；
# 卸载只删专属资源，绝不碰宿主既有磁盘/阵列/LXC 实例。
#
# 用法（sudo）：
#   fnos_deploy_docker.sh install   <name> [--image <tag>] [--device /dev/zdX]
#                                         [--port 15667] [--hostname fnos-docker]
#                                         [--volume <src>:<dst>] [--no-pgdata-volume]
#                                         [--no-www-volume] [--enable-fnos-docker] [--no-start]
#                                         [--stor-docker <name>]
#                                         # --stor-docker <name>: 读 /var/lib/fnos-stor-docker/<name>.env
#                                         #   （stor-manage-docker.sh 产物），自动注入设备集+掩码集。
#                                         # 默认挂出 postgres 数据 volume（<name>-pgdata）、
#                                         # 日志 volume（<name>-logs）与 www volume（<name>-www，
#                                         # volume-nocopy；消除 chattr -R 触发的 www 全量 copy-up
#                                         # 与 90s 超时循环）；
#                                         # 安装 trim_nginx 超时豁免 drop-in（TimeoutStartSec=900，兜底）；
#                                         # 默认停用 fnOS 内置 Docker 三单元。
#   fnos_deploy_docker.sh start     <name>
#   fnos_deploy_docker.sh smoke     <name>
#   fnos_deploy_docker.sh status    <name>
#   fnos_deploy_docker.sh uninstall <name> [--rmi] [--rm-volumes]
#                                         # 默认保留 volumes（postgres 数据）；--rm-volumes 才删。
#   fnos_deploy_docker.sh upgrade   <name> --image <newtag>
#                                         # postgres volume 保留；www volume 重建；换镜像重建容器。
#
# 幂等：install 对已存在的容器只做"补齐/更新并启动"，不重复创建。
# 安全：默认用 17 项 cap 白名单，绝不用 --privileged（防宿主盘暴露）。
# ============================================================================
set -uo pipefail
CMD="${1:-}"; NAME="${2:-}"
IMAGE="fnos-dockermode:1.2.0701-fix"; DEVICES=""; PORT="15667"
HOSTNAME_="fnos-docker"; NO_START=0; RMI=0; RM_VOLUMES=0
VOLUMES=""; NO_PGDATA=0; NO_WWW=0; UPGRADE_IMAGE=""; ENABLE_FNOS_DOCKER=0; STOR_DOCKER=""
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2;;
    --device) DEVICES="$DEVICES $2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --hostname) HOSTNAME_="$2"; shift 2;;
    --volume) VOLUMES="$VOLUMES $2"; shift 2;;
    --no-pgdata-volume) NO_PGDATA=1; shift;;
    --no-www-volume) NO_WWW=1; shift;;
    --stor-docker) STOR_DOCKER="$2"; shift 2;;
    --enable-fnos-docker) ENABLE_FNOS_DOCKER=1; shift;;
    --no-start) NO_START=1; shift;;
    --rmi) RMI=1; shift;;
    --rm-volumes) RM_VOLUMES=1; shift;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

die(){ echo "ERROR: $*" >&2; exit 1; }
need_root(){ [ "$(id -u)" = 0 ] || die "需要 root（用 sudo 运行）"; }
[ -n "$CMD" ] || { sed -n '2,20p' "$0"; exit 2; }
[ -n "$NAME" ] || die "缺少容器名"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/lib.sh" ] && source "$SCRIPT_DIR/lib.sh"

CAPS=(SYS_ADMIN SYS_PTRACE NET_ADMIN NET_BROADCAST NET_RAW MKNOD
      AUDIT_WRITE SETUID SETGID DAC_READ_SEARCH SYS_RESOURCE IPC_LOCK
      KILL CHOWN FOWNER SETFCAP LINUX_IMMUTABLE)

cap_args() { local c; for c in "${CAPS[@]}"; do printf ' --cap-add %s' "$c"; done; }

# trim_nginx 超时豁免 drop-in（消除 systemd 默认 90s 杀-重启循环；见 design D7）
install_timeout_dropin() { # <container>
  local d; d="$(mktemp -d)"
  mkdir -p "$d/trim_nginx.service.d"
  cat > "$d/trim_nginx.service.d/timeout.conf" <<'EOF'
# 由 fnos_deploy_docker.sh 安装：
# chattr -R -i /usr/trim/www 在慢盘/无 www volume 时单轮可能超过 systemd 默认 90s，
# 与 Restart=always 组合会形成杀-重启循环。豁免到 900s，退化为单调等待。
[Service]
TimeoutStartSec=900
EOF
  if docker cp "$d/trim_nginx.service.d" "$1:/etc/systemd/system/" >/dev/null 2>&1; then
    echo "   trim_nginx 超时豁免 drop-in 已写入（TimeoutStartSec=900）"
    # 运行中的容器需 daemon-reload 才生效；首启前写入则开机自动读取
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; then
      docker exec "$1" systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  else
    echo "   WARN: trim_nginx drop-in 写入失败（可稍后 docker cp 重试）"
  fi
  rm -rf "$d"
}

# 从镜像内 postgresql.conf 解析 data_directory（不硬编码大版本）
pgdata_dir() { # <image>
  docker run --rm --entrypoint /bin/sh "$1" -c \
    "grep -h '^data_directory' /etc/postgresql/*/main/postgresql.conf 2>/dev/null | awk -F\"'\" '{print \$2}' | head -1" 2>/dev/null
}

# data-root 若在 HDD 上则告警（只提示不阻断；spec 4.1）
dataroot_warn() {
  local rootdir src dev base rota
  rootdir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  src="$(findmnt -no SOURCE -T "$rootdir" 2>/dev/null || true)"
  case "$src" in
    /dev/*)
      dev="$(basename "$src")"
      # 分区 -> 取父盘（如 sdc1 -> sdc， dm-0 -> 查 slave）
      case "$dev" in
        dm-*|md*) base="$(ls "/sys/block/$dev/slaves/" 2>/dev/null | head -1)"; [ -n "$base" ] || base="$dev";;
        *[0-9]) base="$(echo "$dev" | sed 's/[0-9]*$//;s/p$//')"; [ -e "/sys/block/$base" ] || base="$dev";;
        *) base="$dev";;
      esac
      rota="$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo ?)"
      if [ "$rota" = 1 ]; then
        echo "WARN: Docker data-root 在 HDD 上（$rootdir <- $src）：首启可能缓慢，建议放 SSD（见 19-docker-mode.md）"
      fi
      ;;
    *) ;; # zfs/tmpfs/overlay 等无法判定则静默
  esac
}

do_install() {
  need_root
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "找不到镜像: $IMAGE"
  dataroot_warn
  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "== 容器 $NAME 已存在（幂等）：仅确保启动"
    install_timeout_dropin "$NAME"
  else
    echo "== docker create（镜像=$IMAGE）"
    # 编排接线：读 stor-manage-docker state 注入设备集（与显式 --device 并集）
    if [ -n "$STOR_DOCKER" ]; then
      local stf="/var/lib/fnos-stor-docker/${STOR_DOCKER}.env"
      [ -f "$stf" ] || die "找不到 stor state: $stf（先 stor-manage-docker.sh create $STOR_DOCKER）"
      local st_devs
      st_devs="$( . "$stf" 2>/dev/null; printf '%s' "${DEVS:-}" )"
      [ -n "$st_devs" ] || die "state 无 DEVS: $stf"
      local d
      for d in $st_devs; do
        [ -b "$d" ] || die "state 设备缺失: $d（设备名可能漂移，先 stor-manage-docker.sh up $STOR_DOCKER）"
      done
      DEVICES="$DEVICES $st_devs"
      echo "   stor-docker: $STOR_DOCKER -> $st_devs"
    fi
    # /sys/block 掩码：可见性 == 配置集（空集=全隐藏；分区自动归并整盘）
    DEVS="$(for d in $DEVICES; do basename "$d"; done | tr '\n' ' ')"
    # shellcheck disable=SC2086
    DOCKER_NAME="$NAME" DEVS="$DEVS" bash "$SCRIPT_DIR/stor-mask-docker.sh" apply >/dev/null \
      || die "掩码构建失败"
    MASK="$(DOCKER_NAME="$NAME" bash "$SCRIPT_DIR/stor-mask-docker.sh" mask-path)"
    dev_args=""; for d in $DEVICES; do dev_args="$dev_args --device $d"; done
    # postgres 数据 volume（默认启用；--no-pgdata-volume 关闭）
    vol_args=""
    if [ "$NO_PGDATA" = 0 ]; then
      pgdir="$(pgdata_dir "$IMAGE")"; [ -n "$pgdir" ] || pgdir="/var/lib/postgresql/15/main"
      vol_args="$vol_args -v ${NAME}-pgdata:${pgdir}"
      echo "   pgdata volume: ${NAME}-pgdata -> $pgdir"
    fi
    # 日志 volume（默认启用；随 --rm-volumes 删除）
    vol_args="$vol_args -v ${NAME}-logs:/var/log"
    echo "   logs volume: ${NAME}-logs -> /var/log"
    # www volume（默认启用；volume-nocopy 跳过 Docker 卷首填的冗余拷贝——fnOS boot 路径自会填满）
    if [ "$NO_WWW" = 0 ]; then
      vol_args="$vol_args --mount type=volume,source=${NAME}-www,target=/usr/trim/www,volume-nocopy"
      echo "   www volume: ${NAME}-www -> /usr/trim/www (nocopy)"
    fi
    for v in $VOLUMES; do vol_args="$vol_args -v $v"; done
    # shellcheck disable=SC2086
    docker create --name "$NAME" \
      --hostname "$HOSTNAME_" \
      --entrypoint /lib/systemd/systemd \
      --stop-signal SIGRTMIN+3 \
      --tmpfs /tmp \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
      ${MASK:+-v "$MASK:/sys/block"} \
      $dev_args \
      $vol_args \
      -p "${PORT}:5666" \
      --cgroupns=host \
      --security-opt apparmor=unconfined \
      --security-opt seccomp=unconfined \
      $(cap_args) \
      "$IMAGE" >/dev/null || die "docker create 失败"
    # 超时豁免 drop-in：在首启前写入（保证第一个 start-pre 就受保护）
    install_timeout_dropin "$NAME"
    manifest_add "{\"ts\":\"$(date -Is)\",\"op\":\"docker-install\",\"name\":\"$NAME\",\"image\":\"$IMAGE\",\"devices\":\"$DEVICES\",\"volumes\":\"$VOLUMES\",\"pgdata\":\"$([ "$NO_PGDATA" = 0 ] && echo "${NAME}-pgdata" || echo off)\",\"port\":\"$PORT\",\"mask\":\"$MASK\"}" 2>/dev/null || true
  fi
  if [ "$NO_START" = 0 ]; then
    docker start "$NAME" >/dev/null 2>&1 || true
  fi
  # fnOS 内置 Docker 默认停用（容器内无 dockerd；--enable-fnos-docker 取消）
  # 注：镜像内是实体 unit 文件，systemctl mask 拒绝覆盖，改用 disable + .bak（社区验证法）
  if [ "$ENABLE_FNOS_DOCKER" = 0 ] && [ "$NO_START" = 0 ]; then
    for _ in $(seq 1 30); do
      st="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
      case "$st" in running|degraded) break;; esac
      sleep 2
    done
    docker exec "$NAME" sh -c '
      for s in docker dockermgr dsmgr; do
        systemctl disable --now $s.service >/dev/null 2>&1
        [ -f /etc/systemd/system/$s.service ] && mv /etc/systemd/system/$s.service /etc/systemd/system/$s.service.bak
      done
      systemctl daemon-reload >/dev/null 2>&1' >/dev/null 2>&1 \
      && echo "   fnOS 内置 Docker 已停用（docker/dockermgr/dsmgr → .bak）" \
      || echo "   WARN: 停用 fnOS 内置 Docker 失败（systemd 未就绪可稍后手动执行）"
  fi
  echo "== install 完成（name=$NAME, port=$PORT）"
}

do_start(){ need_root; docker start "$NAME"; }

do_status() {
  need_root
  echo "== docker ps =="; docker ps -a --filter "name=^${NAME}$" 2>&1
  echo "== inspect =="; docker inspect "$NAME" --format 'Image={{.Config.Image}} Privileged={{.HostConfig.Privileged}} Ports={{json .NetworkSettings.Ports}} Devices={{json .HostConfig.Devices}}' 2>&1
}

smoke() {
  local name="$1" ok=1
  chk(){ if [ "$2" = 1 ]; then echo "  PASS: $1"; else echo "  FAIL: $1"; ok=0; fi; }
  echo "== [1] 容器状态 =="
  st="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "?")"
  chk "容器 running (=$st)" "$([ "$st" = running ] && echo 1 || echo 0)"
  echo "== [2] 非特权 =="
  priv="$(docker inspect -f '{{.HostConfig.Privileged}}' "$name" 2>/dev/null || echo "?")"
  chk "Privileged=false (=$priv)" "$([ "$priv" = false ] && echo 1 || echo 0)"
  echo "== [3] 宿主盘隔离 =="
  # 只查非本方案透传的宿主盘（主动 --device 的 nvme3n1/md127/dm-7 不计入）
  blk="$(docker exec "$name" sh -c 'ls /dev/sda /dev/sdb /dev/sdc /dev/md0 /dev/md124 /dev/md125 /dev/md126 /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/dm-0 /dev/dm-1 /dev/dm-2 /dev/dm-3 /dev/dm-4 /dev/dm-5 /dev/dm-6 2>/dev/null | wc -l' 2>/dev/null || echo 99)"
  chk "无非预期宿主块设备 (count=$blk)" "$([ "$blk" = 0 ] && echo 1 || echo 0)"
  echo "== [4] fnOS 服务链 =="
  for svc in trim_init trim_main mediasrv filestor_service share_service trim_app_center rpc_broker postgresql containerd; do
    a="$(docker exec "$name" systemctl is-active "$svc" 2>/dev/null || echo "?")"
    chk "service $svc = active (=$a)" "$([ "$a" = active ] && echo 1 || echo 0)"
  done
  a="$(docker exec "$name" systemctl is-active trim_nginx 2>/dev/null || echo "?")"
  chk "trim_nginx = active (=$a)" "$([ "$a" = active ] && echo 1 || echo 0)"
  echo "== [5] /proc/mounts 无 trimafs =="
  m="$(docker exec "$name" sh -c 'grep -c trimafs /proc/mounts 2>/dev/null || true' 2>/dev/null)"
  chk "无 trimafs 挂载 (count=$m)" "$([ "$m" = 0 ] && echo 1 || echo 0)"
  echo "== [6] Web UI =="
  c="$(docker exec "$name" sh -c 'curl -s -o /dev/null -w "%{http_code}" -m 8 http://127.0.0.1:5666/ 2>/dev/null' 2>/dev/null || echo 000)"
  chk "HTTP 200 on :5666 (=$c)" "$([ "$c" = 200 ] && echo 1 || echo 0)"
  echo "== [7] 写操作 =="
  w="$(docker exec "$name" sh -c 'd=/tmp/.fnos-smoke.$$; mkdir -p "$d" && echo hi > "$d/f" && rm -f "$d/f" && rmdir "$d" && echo OK' 2>/dev/null || echo ERR)"
  chk "tmp 写/删成功 (=$w)" "$([ "$w" = OK ] && echo 1 || echo 0)"
  echo
  [ "$ok" = 1 ] && echo "SMOKE: PASS" || echo "SMOKE: FAIL"
  return $(( 1 - ok ))
}

do_uninstall() {
  need_root
  echo "== 停止并删除容器 $NAME"
  docker stop "$NAME" >/dev/null 2>&1 || true
  docker rm "$NAME" >/dev/null 2>&1 || true
  echo "== 删除专属掩码目录"
  DOCKER_NAME="$NAME" bash "$SCRIPT_DIR/stor-mask-docker.sh" rollback >/dev/null 2>&1 || true
  if [ "$RMI" = 1 ]; then
    echo "== 删除镜像 $IMAGE（仅 --rmi 时）"
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
  fi
  if [ "$RM_VOLUMES" = 1 ]; then
    echo "== 删除专属 volumes（仅 --rm-volumes 时；默认保留 postgres 数据与日志）"
    docker volume rm "${NAME}-pgdata" >/dev/null 2>&1 || true
    docker volume rm "${NAME}-www" >/dev/null 2>&1 || true
    docker volume rm "${NAME}-logs" >/dev/null 2>&1 || true
  else
    echo "== volumes 保留（${NAME}-pgdata/${NAME}-logs 等；--rm-volumes 才删）"
  fi
  manifest_add "{\"ts\":\"$(date -Is)\",\"op\":\"docker-uninstall\",\"name\":\"$NAME\"}" 2>/dev/null || true
  echo "== uninstall 完成（LXC 实例未受影响）"
}

do_upgrade() { # upgrade <name> --image <newtag>：postgres 保留，www 重建
  need_root
  [ -n "$UPGRADE_IMAGE" ] || UPGRADE_IMAGE="$IMAGE"
  docker image inspect "$UPGRADE_IMAGE" >/dev/null 2>&1 || die "找不到新镜像: $UPGRADE_IMAGE"
  # 记下旧容器的 devices/ports/volumes（除 www 外保留）
  old_devs="$(docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}' "$NAME" 2>/dev/null || true)"
  old_port="$(docker inspect -f '{{(index .HostConfig.PortBindings "5666/tcp" 0).HostPort}}' "$NAME" 2>/dev/null || echo "$PORT")"
  old_vols="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}} {{end}}{{end}}' "$NAME" 2>/dev/null || true)"
  echo "== 升级 $NAME -> $UPGRADE_IMAGE（postgres volume 保留，www 重建）"
  docker stop "$NAME" >/dev/null 2>&1 || true
  docker rm "$NAME" >/dev/null 2>&1 || true
  docker volume rm "${NAME}-www" >/dev/null 2>&1 || true
  echo "   www volume 已删（新镜像内容重建）；${NAME}-pgdata 保留"
  dev_flags=""; for d in $old_devs; do dev_flags="$dev_flags --device $d"; done
  # 旧 named volumes（除 pgdata/待重建的 www 外）原样带回
  vol_flags=""
  for v in $old_vols; do
    case "$v" in
      "${NAME}-pgdata:"*|"${NAME}-www:"*) ;;
      *) vol_flags="$vol_flags --volume $v";;
    esac
  done
  # shellcheck disable=SC2086
  bash "$0" install "$NAME" --image "$UPGRADE_IMAGE" $dev_flags $vol_flags --port "$old_port" >/dev/null \
    || die "重建容器失败"
  manifest_add "{\"ts\":\"$(date -Is)\",\"op\":\"docker-upgrade\",\"name\":\"$NAME\",\"image\":\"$UPGRADE_IMAGE\"}" 2>/dev/null || true
  echo "== upgrade 完成"
}

case "$CMD" in
  install)   do_install ;;
  start)     do_start ;;
  status)    do_status ;;
  smoke)     need_root; smoke "$NAME" ;;
  uninstall) do_uninstall ;;
  upgrade)   UPGRADE_IMAGE="$IMAGE"; do_upgrade ;;
  *) echo "用法: $0 install|start|smoke|status|uninstall|upgrade <name> [...]"; exit 2 ;;
esac
