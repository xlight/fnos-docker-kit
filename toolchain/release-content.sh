#!/usr/bin/env bash
# ============================================================================
# release-content.sh —— 内容落地（design D16 阶段①）
#
#   两段提交：commit#1 = 除 index 外的全部内容；commit#2 = 仅 index（source_commit
#             指向 commit#1）。索引语义未变时保留旧字节（revision 不前进）。
#   一次推送：git push origin main —— 两个提交在同一次 ref 更新里到达远端，
#             消费者读不到"内容已更新、索引未更新"的中间态。
#
#   本脚本**不建 tag、不推 tag**：tag 的唯一创建者是发布单元（public-release.yml）。
#   搬运单元（私有仓 CI）与人工旁路（publish.sh）共用这一份实现，避免两套语义。
#
# 用法：
#   release-content.sh --repo <公开仓工作区> [--no-push] [--message <提交信息前缀>]
#
# 输出（stdout，KEY=VALUE）：
#   COMMIT1=<sha> COMMIT2=<sha> STATUS=changed|unchanged
# 退出码：0 成功（changed/unchanged 都算成功）；1 失败（远端保持原状）。
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO=""
PUSH=1
MSG_PREFIX="sync"
FAILED=0

log() { printf '[release-content] %s\n' "$*"; }
die() { printf '[release-content] FATAL: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2;;
    --no-push) PUSH=0; shift;;
    --message) MSG_PREFIX="${2:-}"; shift 2;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "未知参数: $1（--help 看用法）";;
  esac
done
[ -n "$REPO" ] || die "用法: $0 --repo <公开仓工作区> [--no-push]"
[ -d "$REPO/.git" ] || die "不是 git 仓: $REPO"

# git 身份：目标仓（公开仓的克隆）可能没有配置（CI runner 的全局身份为空）→
# 没有就补一个 bot 身份，否则 commit 会以 "Author identity unknown" 失败。
git -C "$REPO" config user.name >/dev/null 2>&1 \
  || git -C "$REPO" config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "$REPO" config user.email >/dev/null 2>&1 \
  || git -C "$REPO" config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

STAGE="$(mktemp -d)"
PRESERVE_TMP="$(mktemp -d)"
OLD_INDEX="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$PRESERVE_TMP" "$OLD_INDEX"' EXIT

# ---------- 1. 拉平基线（与 CI 的 state 提交并发时先 rebase） ----------
log "拉平基线"
git -C "$REPO" pull --rebase --autostash origin main >/dev/null 2>&1 \
  || die "pull --rebase 失败（远端保持原状）"

# ---------- 2. 组装公开内容（不含索引） ----------
log "组装公开内容（组装 + 脱敏 + 构建依赖断言 + leak-scan）"
bash "$SCRIPT_DIR/sync-public.sh" stage-noidx "$STAGE" >/dev/null \
  || die "组装/脱敏/leak-scan 失败（远端保持原状）"

# 旧索引留档：既是新 revision 的基线（公开仓为准），也要留到第二段再生成
if [ -f "$REPO/toolchain/patches/index.json" ]; then
  mkdir -p "$OLD_INDEX/toolchain/patches"
  cp -a "$REPO/toolchain/patches/index.json" "$OLD_INDEX/toolchain/patches/index.json"
fi

# ---------- 3. 保留段备份（CI 提交的 state/ 不由真源产出） ----------
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -e "$REPO/$rel" ]; then
    mkdir -p "$PRESERVE_TMP/$(dirname "$rel")"
    cp -a "$REPO/$rel" "$PRESERVE_TMP/$rel"
  fi
done < <(bash "$SCRIPT_DIR/sync-public.sh" preserve-list 2>/dev/null)

# ---------- 4. 清空工作区（保留 .git）后填入暂存区 ----------
(cd "$REPO" && git ls-files -z | xargs -0 -r rm -f; find . -path ./.git -prune -o -type d -empty -print0 | xargs -0 -r rmdir 2>/dev/null || true)
cp -a "$STAGE/." "$REPO/"
# 暂存区里的 index.json 是**私有副本**（仅缓存，基线以公开仓为准）——内容提交必须
# 保留公开仓当前那份（否则两次运行之间会在"有/无 index.json"之间来回翻转）。
if [ -f "$OLD_INDEX/toolchain/patches/index.json" ]; then
  mkdir -p "$REPO/toolchain/patches"
  cp -a "$OLD_INDEX/toolchain/patches/index.json" "$REPO/toolchain/patches/index.json"
fi
if [ -n "$(ls -A "$PRESERVE_TMP" 2>/dev/null)" ]; then
  (cd "$PRESERVE_TMP" && find . -type f -print0) | while IFS= read -r -d "" f; do
    mkdir -p "$REPO/$(dirname "$f")"
    cp -a "$PRESERVE_TMP/$f" "$REPO/$f"
  done
fi
# 索引不进内容提交：它由第二段提交单独更新（内容提交保留公开仓当前那份）
mkdir -p "$REPO/toolchain/patches"

# ---------- 5. commit#1：内容 ----------
git -C "$REPO" add -A
COMMIT1=""
CHANGED=0
if git -C "$REPO" diff --cached --quiet; then
  log "公开内容无变化 → 跳过 commit#1（幂等）"
else
  git -C "$REPO" commit -q -m "$MSG_PREFIX: 内容 $(date -u +%Y%m%dT%H%M%SZ)" \
    || die "commit#1 失败（远端保持原状）"
  COMMIT1="$(git -C "$REPO" rev-parse HEAD)"
  CHANGED=1
  log "commit#1 = $COMMIT1"
fi

# ---------- 6. commit#2：索引（source_commit = commit#1） ----------
mkdir -p "$REPO/toolchain/patches"
INDEX_BASE_FILE="$OLD_INDEX/toolchain/patches/index.json" \
INDEX_SOURCE_COMMIT="$COMMIT1" \
  bash "$SCRIPT_DIR/sync-public.sh" gen-index "$REPO" >/dev/null \
  || die "索引生成失败（远端保持原状）"

COMMIT2=""
# 与 HEAD 里的那份比内容哈希（**不能**用 `git diff -- path`：索引文件在 commit#1 里
# 是"删除"状态，git diff 不看未跟踪路径，会误判成"没变"）
new_idx_sha="$(git -C "$REPO" hash-object toolchain/patches/index.json 2>/dev/null || echo "")"
old_idx_sha="$(git -C "$REPO" rev-parse HEAD:toolchain/patches/index.json 2>/dev/null || echo "")"
if [ -n "$new_idx_sha" ] && [ "$new_idx_sha" = "$old_idx_sha" ]; then
  log "索引与 HEAD 一致 → 不提交（revision 不前进）"
  COMMIT2="$(git -C "$REPO" rev-parse HEAD)"
else
  git -C "$REPO" add toolchain/patches/index.json
  git -C "$REPO" commit -q -m "$MSG_PREFIX: 索引 revision+1 (source_commit=${COMMIT1:-none})" \
    || die "commit#2 失败（远端保持原状）"
  COMMIT2="$(git -C "$REPO" rev-parse HEAD)"
  CHANGED=1
  log "commit#2 = $COMMIT2"
fi

# ---------- 7. 一次推送（两个提交同时到达） ----------
if [ "$PUSH" = "1" ]; then
  if [ "$CHANGED" = "0" ]; then
    log "无变化 → 不推送"
  else
    log "推送 main（一次 ref 更新，内容与索引同时到达）"
    git -C "$REPO" push origin main || die "推送失败（远端保持原状）"
  fi
fi

[ "$CHANGED" = "1" ] && STATUS="changed" || STATUS="unchanged"
printf 'COMMIT1=%s COMMIT2=%s STATUS=%s\n' "$COMMIT1" "$COMMIT2" "$STATUS"
exit 0
