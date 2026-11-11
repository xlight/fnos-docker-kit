#!/usr/bin/env bash
# ============================================================================
# publish.sh —— 声明式发布命令（人工旁路 / 逃生舱；design D3/D8/D9/D13/D16）
#
#   publish.sh --patchset <ver> [--image <ver>] [--release-tag <tag>]
#              [--dry-run] [--repo <公开仓工作区>]
#
# 做什么：
#   1) 8 项预检（任何一项不过 → 非零退出，**远端零副作用**）
#   2) 内容落地：两段提交（commit#1 = 内容，commit#2 = 带 source_commit 的就绪索引）
#      + 一次推送（两个提交同时到达，消费者读不到中间态）——由 release-content.sh 执行
#   3) **不建 tag、不推 tag**：tag 的唯一创建者是发布单元（public-release.yml）；
#      本脚本只 dispatch 它（tag 不可变判定与修订号推导与发布单元共用同一份实现）
#   4) 可选 --image <ver>：发布后 dispatch 一次镜像构建（不等待、不回滚）
#
# 自动路径（搬运单元）与本旁路共用 release-content.sh / check-release-tag.sh /
# derive-release-tag.py —— 避免两套实现产生两套语义。
#
# 公开可复现：本脚本与 sync-public.sh、release-content.sh、public-manifest.txt 一起进公开仓。
# 脚本内**不得**硬编码宿主私有绝对路径（一律 $HOME 或参数）。
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATCHSET_VER=""
IMAGE_VER=""
RELEASE_TAG=""
PUB_REPO="${FNOS_PUBLIC_REPO:-$HOME/fnos-docker-kit}"
DRY_RUN=0

log()  { printf '[publish] %s\n' "$*"; }
ok()   { printf '[publish]   PASS  %s\n' "$*"; }
bad()  { printf '[publish]   FAIL  %s\n' "$*"; }
die()  { printf '[publish] FATAL: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --patchset)    PATCHSET_VER="${2:-}"; shift 2;;
    --image)       IMAGE_VER="${2:-}"; shift 2;;
    --release-tag) RELEASE_TAG="${2:-}"; shift 2;;
    --repo)        PUB_REPO="${2:-}"; shift 2;;
    --dry-run)     DRY_RUN=1; shift;;
    -h|--help)     usage;;
    *) die "未知参数: $1（--help 看用法）";;
  esac
done
[ -n "$PATCHSET_VER" ] || { usage; }
PATCHSET_VER="${PATCHSET_VER#V}"
# tag 默认**自动推导**（v<ver> 或 v<ver>-r<N+1>，与发布单元同一份实现）；
# 显式 --release-tag 优先。
TAG_AUTO=0
[ -n "$RELEASE_TAG" ] || TAG_AUTO=1

PRIVATE_PS="$SCRIPT_DIR/patches/fnos-${PATCHSET_VER}.json"
REHEARSE_REC="${FNOS_REHEARSE_DIR:-$HOME/fnos/backups/rehearsal}/fnos-${PATCHSET_VER}.json"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 自动推导发布 tag（首发 v<ver>；修正 v<ver>-r<N+1>；查询失败 → fail-closed）
if [ "$TAG_AUTO" = "1" ]; then
  RELEASE_TAG="$(python3 "$SCRIPT_DIR/derive-release-tag.py" --repo "$PUB_REPO" --version "$PATCHSET_VER")" \
    || die "无法推导发布 tag（远端查询失败，fail-closed，不发布）"
  log "自动推导发布 tag: $RELEASE_TAG"
fi

FAILED=0
precheck() { # <名称> <说明>；返回 0=通过
  if "$@"; then ok "$PRECHECK_NAME"; return 0; fi
  bad "$PRECHECK_NAME —— $PRECHECK_DESC"
  FAILED=1
  return 1
}

# ---------- 预检 1：补丁集存在 + validation 自洽 ----------
PRECHECK_NAME="[1] 补丁集存在且 validation 自洽"
PRECHECK_DESC="缺 $PRIVATE_PS 或 validation 字段不自洽"
p1() {
  [ -f "$PRIVATE_PS" ] || return 1
  python3 - "$PRIVATE_PS" <<'PY' >/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get("validation") or {}
assert v.get("total") and v.get("ready") is not None
assert d.get("fnos_version"), "fnos_version 缺失"
PY
}
precheck p1

# ---------- 预检 2：公开集包含构建所需文件（组装一次供后续检查用） ----------
PRECHECK_NAME="[2] 公开集包含构建依赖集合"
PRECHECK_DESC="公开集缺构建依赖（sync-public.sh 会列出缺哪个）"
p2() { INDEX_BASE_FILE="$PUB_REPO/toolchain/patches/index.json" bash "$SCRIPT_DIR/sync-public.sh" stage-noidx "$STAGE" >/dev/null 2>"$STAGE/.stage-err"; }
if precheck p2; then
  [ -s "$STAGE/.stage-err" ] && tail -3 "$STAGE/.stage-err"
else
  tail -5 "$STAGE/.stage-err" 2>/dev/null
fi

# ---------- 预检 3：本地 rehearsal 有效 ----------
PRECHECK_NAME="[3] 本地演练记录有效且与本次补丁集一致"
PRECHECK_DESC="缺 $REHEARSE_REC，或 result != ok，或补丁集 sha256 与记录不符"
p3() {
  [ -f "$REHEARSE_REC" ] || return 1
  python3 - "$REHEARSE_REC" "$PRIVATE_PS" <<'PY' >/dev/null
import hashlib, json, sys
rec = json.load(open(sys.argv[1]))
ps = sys.argv[2]
assert rec.get("result") == "ok", "rehearsal result != ok"
want = rec.get("patchset_sha256")
got = hashlib.sha256(open(ps, "rb").read()).hexdigest()
assert want == got, "补丁集 sha256 与演练记录不符（rebase 后需重跑演练）"
PY
}
precheck p3

# ---------- 预检 4：目标 tag 不存在，或已存在且内容合规 ----------
PRECHECK_NAME="[4] 目标 tag 不存在或已存在且内容合规"
PRECHECK_DESC="tag $RELEASE_TAG 已存在但内容与本次发布不符（tag 不可变）；或查询失败（fail-closed）"
p4() {
  # 共享实现（发布单元与人工旁路同一份判定；查询失败 → fail-closed，视为不通过）
  bash "$SCRIPT_DIR/check-release-tag.sh" --repo "$PUB_REPO" --tag "$RELEASE_TAG" \
    --patchset-file "$STAGE/toolchain/patches/fnos-${PATCHSET_VER}.json" >/dev/null 2>"$STAGE/.tag-err"
  local rc=$?
  [ "$rc" = 2 ] && tail -2 "$STAGE/.tag-err" >&2
  return $rc
}
precheck p4

# ---------- 预检 5：索引条目 sha256 == 补丁集实际哈希（脱敏后形态） ----------
PRECHECK_NAME="[5] 就绪索引与补丁集哈希一致"
PRECHECK_DESC="索引生成后会与脱敏后补丁集不一致（同步阶段会再校验一次）"
p5() {
  INDEX_BASE_FILE="$PUB_REPO/toolchain/patches/index.json" \
  INDEX_SOURCE_COMMIT="" \
    bash "$SCRIPT_DIR/sync-public.sh" gen-index "$STAGE" >/dev/null 2>&1 || return 1
  python3 - "$STAGE/toolchain/patches/index.json" "$STAGE/toolchain/patches/fnos-${PATCHSET_VER}.json" <<'PY' >/dev/null
import hashlib, json, sys
idx = json.load(open(sys.argv[1]))
raw = open(sys.argv[2], "rb").read()
e = idx["versions"][sys.argv[2].split("fnos-")[1].split(".json")[0]]
assert e["sha256"] == hashlib.sha256(raw).hexdigest(), "索引 sha256 与补丁集实际哈希不符"
PY
}
precheck p5

# ---------- 预检 6：git 身份 / 写权限 / 远端可达 / 工作树干净 ----------
PRECHECK_NAME="[6] git 身份、写权限、远端可达、工作树干净"
PRECHECK_DESC="git 配置缺失、目录不可写、远端不可达或工作树有未提交改动"
p6() {
  [ -d "$PUB_REPO/.git" ] || return 1
  git -C "$PUB_REPO" config user.name >/dev/null 2>&1 || return 1
  git -C "$PUB_REPO" config user.email >/dev/null 2>&1 || return 1
  [ -w "$PUB_REPO" ] || return 1
  # 远端可达（不要求 HEAD 指向某个分支：裸仓的 HEAD 可能仍指向不存在的 master）
  git -C "$PUB_REPO" ls-remote origin >/dev/null 2>&1 || return 1
  [ -z "$(git -C "$PUB_REPO" status --porcelain)" ] || return 1
}
precheck p6

# ---------- 预检 7：声明版本与 release tag 一致 ----------
PRECHECK_NAME="[7] 声明版本与 release tag 一致"
PRECHECK_DESC="tag $RELEASE_TAG 与 --patchset $PATCHSET_VER 不属于同一版本"
p7() {
  case "$RELEASE_TAG" in
    "v${PATCHSET_VER}"|"v${PATCHSET_VER}-r"*) return 0;;
  esac
  return 1
}
precheck p7

# ---------- 预检 8：新索引 revision == 公开仓当前 revision + 1 ----------
PRECHECK_NAME="[8] 新索引 revision 只前进一格"
PRECHECK_DESC="新索引 revision 不是公开仓当前 revision + 1（防回退/跳号）"
p8() {
  local cur new
  cur=$(python3 - "$PUB_REPO/toolchain/patches/index.json" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1]))["revision"])
except Exception:
    print(0)
PY
)
  new=$(python3 - "$STAGE/toolchain/patches/index.json" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1]))["revision"])
except Exception:
    print(0)
PY
)
  [ -n "$cur" ] && [ -n "$new" ] || return 1
  # 允许两种情形：
  #   new == cur+1  索引语义变了（新增/修改补丁集、样本矩阵变化）→ 正常前进
  #   new == cur    索引**语义未变**（只有 source_commit 指向的内容提交变了）→
  #                 按 index_builder 的幂等规则保留旧字节，revision 不前进（不算回退/跳号）
  [ "$new" = "$((cur + 1))" ] || [ "$new" = "$cur" ]
}
precheck p8

if [ "$FAILED" != 0 ]; then
  die "预检未通过（$FAILED 项），中止（远端零副作用）"
fi
log "8 项预检全部通过"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN：到此为止（不提交、不打 tag、不推送、不触发构建）"
  log "计划：patchset=$PATCHSET_VER tag=$RELEASE_TAG image=${IMAGE_VER:-<无>}"
  exit 0
fi

# ================= 执行 =================
log "内容落地（两段提交 + 一次推送；tag 由发布单元创建）"
out="$(bash "$SCRIPT_DIR/release-content.sh" --repo "$PUB_REPO" --message "publish")" \
  || die "内容落地失败（远端保持原状）"
printf '%s\n' "$out" | while IFS= read -r line; do log "  $line"; done

# 触发发布单元（建 tag + 发 Release 资产）——tag 的**唯一创建者**是它
pub_repo_slug="$(git -C "$PUB_REPO" remote get-url origin 2>/dev/null \
  | sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')"
log "触发发布单元 public-release.yml：patchset=$PATCHSET_VER tag=$RELEASE_TAG"
gh workflow run public-release.yml -R "${pub_repo_slug:-xlight/fnos-docker-kit}" \
   -f patchset="$PATCHSET_VER" -f release_tag="$RELEASE_TAG" \
  || log "WARN: 发布单元 dispatch 失败（内容已落地，可手工重跑 public-release.yml）"

# 审计链
if [ -f "$REPO_ROOT/scripts/lib.sh" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib.sh" >/dev/null 2>&1 || true
  if command -v manifest_add >/dev/null 2>&1; then
    manifest_add "$(python3 -c 'import json,sys; print(json.dumps({"mech":"release","action":"publish","version":sys.argv[1],"tag":sys.argv[2],"stage":"content-landed"},ensure_ascii=False))' "$PATCHSET_VER" "$RELEASE_TAG")" || true
  fi
fi

if [ -n "$IMAGE_VER" ]; then
  log "触发镜像构建（显式声明；不等待、失败不回滚发布）"
  pub_repo_slug="$(git -C "$PUB_REPO" remote get-url origin 2>/dev/null \
    | sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##')"
  gh workflow run public-ci.yml -R "${pub_repo_slug:-xlight/fnos-docker-kit}" \
     -f version="$IMAGE_VER" -f channel=iso \
    || log "WARN: 镜像构建 dispatch 失败（发布已完成，可手工重跑）"
fi

log "发布完成：patchset=$PATCHSET_VER tag=$RELEASE_TAG"
