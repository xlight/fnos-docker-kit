#!/usr/bin/env bash
# ============================================================================
# check-release-tag.sh —— 发布 tag 的不可变判定（design D4/D13）
#
#   发布单元（公开仓 CI）与人工旁路（publish.sh）共用这一份实现，避免两套语义。
#   判定依据是**该 tag 里那份补丁集的 sha256**（脱敏后的公开形态）：
#     · tag 不存在        → 0（可建）
#     · tag 存在且内容一致 → 0（幂等跳过，不移动 tag）
#     · tag 存在但内容不符 → 1（拒绝：既有 tag 不得移动）
#     · 查询失败          → 2（fail-closed：调用方按"已存在"处理，不发布不覆盖）
#
# 用法：
#   check-release-tag.sh --repo <公开仓工作区> --tag <tag> --patchset-file <公开形态补丁集路径>
# ============================================================================
set -uo pipefail

REPO=""
TAG=""
PS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         REPO="${2:-}"; shift 2;;
    --tag)          TAG="${2:-}"; shift 2;;
    --patchset-file) PS_FILE="${2:-}"; shift 2;;
    -h|--help)      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 2;;
  esac
done
[ -n "$REPO" ] && [ -n "$TAG" ] && [ -n "$PS_FILE" ] || {
  printf '用法: %s --repo <仓> --tag <tag> --patchset-file <路径>\n' "$0" >&2; exit 2; }

# 查询 tag 是否存在：**查询失败与"不存在"必须区分**（fail-closed）
if [ "${FNOS_RELEASE_GIT_FAIL:-0}" = "1" ]; then
  printf '[check-tag] 查询失败（fail-closed，按"已存在"处理）: %s\n' "$TAG" >&2
  exit 2
fi
if ! remote_refs="$(git -C "$REPO" ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)"; then
  printf '[check-tag] 查询失败（fail-closed，按"已存在"处理）: %s\n' "$TAG" >&2
  exit 2
fi
if [ -z "$remote_refs" ]; then
  printf '[check-tag] tag 不存在，可建: %s\n' "$TAG"
  exit 0
fi

# tag 存在：比对该 tag 里补丁集与本次要发布的补丁集（脱敏后的公开形态）
ps_rel="$(basename "$PS_FILE")"
got="$(git -C "$REPO" show "$TAG:toolchain/patches/$ps_rel" 2>/dev/null | sha256sum | awk '{print $1}')"
want="$(sha256sum "$PS_FILE" 2>/dev/null | awk '{print $1}')"
if [ -n "$want" ] && [ "$want" = "$got" ]; then
  printf '[check-tag] tag 已存在且内容一致 → 幂等跳过: %s\n' "$TAG"
  exit 0
fi
printf '[check-tag] tag 已存在但内容与本次发布不符 → 拒绝（tag 不可变）: %s\n' "$TAG" >&2
exit 1
