#!/usr/bin/env bash
# ============================================================================
# rehearse-build.sh —— 发布前的本地演练（design D8 预检项 [3]）
#
# 用官方 ISO 在本地跑一遍 CI 的核心链路：
#   extract（出厂 rootfs）→ apply（打补丁）→ mkraw（出镜像）→ check（fsck + 补丁在位）
# 任一步失败即非零退出，并把失败阶段写进演练记录。
#
# 为什么要有它：CI 不该是第一个在目标版本上跑这条链路的地方。CI 里发现的
# 问题（缺依赖、补丁失配、镜像自检不过）成本高（重跑半小时+），本地几分钟
# 就能撞出来。
#
# 用法（需 root：extract 会写 root 属主的文件）：
#   sudo bash rehearse-build.sh                    # 自动检测最新版 ISO 并演练
#   sudo bash rehearse-build.sh --version 1.2.1000
#   sudo bash rehearse-build.sh --iso /path/fnos.iso --version 1.2.1000
#   sudo bash rehearse-build.sh --keep             # 保留 rootfs 与镜像（默认保留镜像）
#
# 选项：
#   --version <ver>   目标 fnOS 版本（缺省 = 检测器当前版本）
#   --iso <path>      本地 ISO（缺省 = 用检测器给的签名 URL 现下）
#   --workdir <dir>   工作目录（缺省 /tmp/fnos-rehearse）
#   --keep            保留解出的 rootfs（默认删）
#   --size <GiB>      镜像大小（缺省 12，与 CI 一致）
#   --fs <ext4|btrfs> 镜像文件系统（缺省 ext4，与 CI 一致）
#
# 退出码：0 演练通过；1 演练失败（阶段见记录与 stderr）；2 用法/前置错误
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="${WORKDIR:-/tmp/fnos-rehearse}"
KEEP_ROOTFS=0
VERSION=""
ISO=""
SIZE=12
FS=ext4

log()  { printf '[rehearse] %s\n' "$*"; }
die()  { printf '[rehearse] FATAL: %s\n' "$*" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2;;
    --iso)     ISO="${2:-}"; shift 2;;
    --workdir) WORKDIR="${2:-}"; shift 2;;
    --size)    SIZE="${2:-}"; shift 2;;
    --fs)      FS="${2:-}"; shift 2;;
    --keep)    KEEP_ROOTFS=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

[ "$(id -u)" = 0 ] || die "需要 root（宿主上请 sudo 运行）"
command -v python3 >/dev/null || die "缺少 python3"

REC_DIR="${REHEARSE_REC_DIR:-$REPO_ROOT/backups/rehearsal}"
REC="$REC_DIR/fnos-${VERSION:-unknown}.json"

now() { date +%s; }

# ---------- 阶段计时（写进记录） ----------
T_EXTRACT=0; T_APPLY=0; T_MKRAW=0; T_CHECK=0
FAILED_STAGE=""; RESULT="unknown"
ISO_MD5=""; ISO_URL=""; PATCHSET_SHA=""; ROOTFS=""; IMAGE=""

record() { # <status>
  RESULT="$1"
  mkdir -p "$REC_DIR"
  python3 - "$REC" "$RESULT" "$VERSION" "$FAILED_STAGE" "$ISO_MD5" "$ISO_URL" "$PATCHSET_SHA" \
             "$ROOTFS" "$IMAGE" "$T_EXTRACT" "$T_APPLY" "$T_MKRAW" "$T_CHECK" <<'PYEOF'
import json, os, sys, datetime
(rec, result, version, failed_stage, iso_md5, iso_url, ps_sha, rootfs, image,
 t_extract, t_apply, t_mkraw, t_check) = sys.argv[1:14]
d = {
    "mech": "release", "action": "rehearse",
    "version": version or "unknown",
    "result": result,
    "failed_stage": failed_stage or None,
    "iso": {"md5": iso_md5, "url": iso_url},
    # 补丁集哈希是**私有源文件**形态（公开仓那份经 desensitize，reason 字段被改写，
    # 哈希因此不同）；比对时必须用同一形态，别拿公开哈希来对。
    "patchset_sha256": ps_sha,
    "patchset_sha256_form": "private-source",
    "paths": {"rootfs": rootfs, "image": image},
    "seconds": {"extract": int(t_extract), "apply": int(t_apply),
                "mkraw": int(t_mkraw), "check": int(t_check)},
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
tmp = rec + ".tmp"
open(tmp, "w").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, rec)
print("[rehearse] 记录已写入: %s" % rec)
PYEOF
}

fail() { # <stage> <message>
  FAILED_STAGE="$1"
  log "阶段失败 [$1]: $2"
  record "failed"
  # 审计链：与发布同一条 manifest（宿主侧有 lib.sh 就记，没有也不阻塞）
  if [ -f "$REPO_ROOT/scripts/lib.sh" ]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/lib.sh" >/dev/null 2>&1 || true
    if command -v manifest_add >/dev/null 2>&1; then
      manifest_add "$(python3 -c 'import json,sys; print(json.dumps({"mech":"release","action":"rehearse","version":sys.argv[1],"result":"failed","stage":sys.argv[2]},ensure_ascii=False))' "${VERSION:-unknown}" "$FAILED_STAGE")" || true
    fi
  fi
  exit 1
}

# ---------- 0. 磁盘断言（ISO 头峰值约 20G；与 CI 同阈值） ----------
avail_g=$(df --output=avail -BG "$WORKDIR" 2>/dev/null | tail -1 | tr -dc 0-9)
[ -n "$avail_g" ] || avail_g=$(df --output=avail -BG /tmp | tail -1 | tr -dc 0-9)
log "可用磁盘: ${avail_g}G（需要 ≥25G）"
[ "${avail_g:-0}" -ge 25 ] || die "磁盘不足（<25G），中止"

mkdir -p "$WORKDIR"

# ---------- 1. 解析 ISO 来源 ----------
DETECT_JSON=""
if [ -z "$ISO" ]; then
  log "经 check-iso-update.py --signed 取签名 URL（官方裸 URL 返回 403）"
  DETECT_JSON="$(python3 "$SCRIPT_DIR/check-iso-update.py" --signed --no-ota 2>/dev/null)"
  rc=$?
  # rc: 0=无变化 / 10=有新版可下载 / 11=有新版但**裸**URL 被拦（签名 URL 仍可用）/ 2=检测故障
  [ "$rc" = "2" ] && die "检测器故障（rc=2），无法确定 ISO 来源"
  [ "$rc" = "0" ] || [ "$rc" = "10" ] || [ "$rc" = "11" ] \
    || die "检测器返回意外 rc=$rc，无法确定 ISO 来源"
  ISO_URL="$(echo "$DETECT_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("signed_url") or d["current"]["url"])')"
  [ -n "$ISO_URL" ] && [ "$ISO_URL" != "None" ] || die "检测器未给出可用下载 URL（签名失败）"
  ISO_MD5="$(echo "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["current"]["hash"])')"
  DET_VER="$(echo "$DETECT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["current"]["version"])')"
  [ -n "$VERSION" ] || VERSION="$DET_VER"
  ISO="$WORKDIR/fnos-${VERSION}.iso"
  if [ ! -f "$ISO" ]; then
    log "下载 ISO: $ISO_URL"
    curl -fL --retry 3 -o "$ISO.downloading" "$ISO_URL" || fail "download" "ISO 下载失败"
    mv "$ISO.downloading" "$ISO"
  else
    log "复用已下载 ISO: $ISO"
  fi
else
  ISO_URL="local:${ISO}"
  # 本地 ISO：md5 从检测器取（用于校验），版本以 --version 为准
  DET_JSON="$(python3 "$SCRIPT_DIR/check-iso-update.py" --signed --no-ota 2>/dev/null)"
  ISO_MD5="$(echo "$DET_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["current"]["hash"])' 2>/dev/null || echo "")"
  [ -f "$ISO" ] || die "ISO 不存在: $ISO"
fi

# ---------- 2. md5 校验（不接受未校验的 ISO） ----------
got_md5="$(md5sum "$ISO" | awk '{print $1}')"
log "ISO md5: $got_md5（官方: ${ISO_MD5:-未知}）"
if [ -n "$ISO_MD5" ] && [ "$got_md5" != "$ISO_MD5" ]; then
  fail "verify" "ISO md5 不符：want=${ISO_MD5} got=${got_md5}"
fi

# ---------- 3. 补丁集 ----------
[ -n "$VERSION" ] || fail "verify" "无法确定目标版本（--version 或检测器）"
PATCHSET="$SCRIPT_DIR/patches/fnos-${VERSION#V}.json"
[ -f "$PATCHSET" ] || fail "patchset" "无该版本补丁集：$PATCHSET（需人工 rebase）"
PATCHSET_SHA="$(sha256sum "$PATCHSET" | awk '{print $1}')"
log "补丁集: $(basename "$PATCHSET") sha256=$PATCHSET_SHA"

# ---------- 4. extract ----------
ROOTFS="$WORKDIR/rootfs-${VERSION#V}"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
log "extract 出厂 rootfs -> $ROOTFS"
t0=$(now)
python3 "$SCRIPT_DIR/fnos_iso.py" extract "$ISO" "$ROOTFS" >/dev/null 2>&1 \
  || fail "extract" "fnos_iso.py extract 失败"
T_EXTRACT=$(( $(now) - t0 ))

# ---------- 5. apply ----------
log "apply 补丁集"
t0=$(now)
python3 "$SCRIPT_DIR/fnos_patch.py" apply --rootfs "$ROOTFS" --patches "$PATCHSET" >/dev/null 2>&1 \
  || fail "apply" "fnos_patch.py apply 失败（补丁施加阶段）"
T_APPLY=$(( $(now) - t0 ))

# ---------- 6. mkraw ----------
IMAGE="$WORKDIR/image-${VERSION#V}.raw"
rm -f "$IMAGE"
log "mkraw -> $IMAGE（${SIZE}G ${FS}）"
t0=$(now)
python3 "$SCRIPT_DIR/fnos_image.py" mkraw "$ROOTFS" "$IMAGE" "$SIZE" "--fs=$FS" >/dev/null 2>&1 \
  || fail "mkraw" "fnos_image.py mkraw 失败（镜像生成阶段）"
T_MKRAW=$(( $(now) - t0 ))

# ---------- 7. check（fsck + 补丁在位） ----------
log "check 镜像（fsck + 补丁在位）"
t0=$(now)
python3 "$SCRIPT_DIR/fnos_image.py" check "$IMAGE" "--patchset=$PATCHSET" >/dev/null 2>&1 \
  || fail "check" "fnos_image.py check 失败（镜像自检阶段）"
T_CHECK=$(( $(now) - t0 ))

# ---------- 8. 收尾 ----------
if [ "$KEEP_ROOTFS" = "0" ]; then
  rm -rf "$ROOTFS"
fi
record "ok"
# 审计链：成功也要记（与失败同一入口，便于发布预检追溯）
if [ -f "$REPO_ROOT/scripts/lib.sh" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib.sh" >/dev/null 2>&1 || true
  if command -v manifest_add >/dev/null 2>&1; then
    manifest_add "$(python3 -c 'import json,sys; print(json.dumps({"mech":"release","action":"rehearse","version":sys.argv[1],"result":"ok"},ensure_ascii=False))' "${VERSION:-unknown}")" || true
  fi
fi
log "演练通过：extract=${T_EXTRACT}s apply=${T_APPLY}s mkraw=${T_MKRAW}s check=${T_CHECK}s"
log "镜像: $IMAGE"
exit 0
