#!/usr/bin/env bash
# ============================================================================
# sync-public.sh —— 私有真源 → 公开仓的脚本化同步
#
# 流程：allowlist（public-manifest.txt）→ 暂存区 → leak-scan 闸门 →
#       干净历史提交 → 推送公开仓。重复运行产出内容一致。
#
# 用法（在本机/私有侧运行，需 git）：
#   sudo bash sync-public.sh stage <暂存目录>     # 仅组装+扫描，不提交
#   sudo bash sync-public.sh push <公开仓目录>    # 组装+扫描+提交到公开仓工作区
#   MANIFEST=...  STAGE_KEEP=1  # 可覆盖清单路径；保留暂存区便于比对
#
# leak-scan 扫的是"待推内容"（暂存区），命中即中止、不提交不推送。
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="${MANIFEST:-$SCRIPT_DIR/public-manifest.txt}"
CMD="${1:-}"; DST="${2:-}"
[ -n "$CMD" ] || { sed -n '2,12p' "$0"; exit 2; }

log()  { printf '[sync-public] %s\n' "$*"; }
die()  { printf '[sync-public] FATAL: %s\n' "$*" >&2; exit 1; }

# INCLUDE 段：按**段头**解析（不用 sed 区间：注释里出现段名字面量会把区间
# 重新开启，导致 PRESERVE/GRAY 段被当成 INCLUDE 项）。
parse_include() { # -> 每行一个清单项（不含注释与空行）
  awk '/^\[INCLUDE\]/{f=1; next} /^\[/{f=0} f && !/^#/ && !/^$/' "$MANIFEST"
}

# [PRESERVE] 段：不由私有真源产出、但必须留在公开仓里的路径（如 CI 提交的
# 检测器状态 state/）。必须放在 [EXCLUDE-PRIVATE] **之后**（INCLUDE 解析用
# sed 截取 [INCLUDE]..[EXCLUDE-PRIVATE]，夹在中间会被误当 INCLUDE 项）。
parse_preserve() { # -> 每行一个相对路径
  sed -n '/^\[PRESERVE\]/,/^\[/p' "$MANIFEST" | grep -vE '^\[|^#|^$' | sed '/^\[PRESERVE\]/d' || true
  return 0
}

# 构建依赖契约（design D11）：构建工具自报所需文件，公开集必须齐全。
# 缺失即中止、不提交——今天的缺文件是 CI 里才炸（build 阶段 FileNotFoundError）。
assert_required_files() { # <stage-dir>
  local stage="$1" f missing=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -e "$stage/$f" ]; then
      log "缺构建依赖: $f"
      missing=1
    fi
  done < <(python3 "$REPO_ROOT/toolchain/fnos_patch.py" --required-files 2>/dev/null)
  # 补丁集是动态项：至少要有一个版本补丁集在公开集里
  if ! ls "$stage"/toolchain/patches/fnos-*.json >/dev/null 2>&1; then
    log "缺构建依赖: toolchain/patches/fnos-<ver>.json（公开集里没有任何版本补丁集）"
    missing=1
  fi
  [ "$missing" = 0 ] || die "公开集缺构建依赖（见上列），中止（不提交不推送）"
  log "构建依赖集合齐全（assert_required_files 通过）"
}

# leak 模式：凭据 / 真实账号 / 宿主专有路径与池名 / 私有文件名与方法关键词
# 说明：/mnt 仅匹配大写/数字开头（存储池式命名，如 /mnt/1T-1）；小写通用约定
# （如容器内 /mnt/hostdata）不在此列。
LEAK_RES=(
  '123qwe'
  'FNOS_PASS=[^"$ ']
  '/home/[a-z0-9_-]+'
  '/mnt/[A-Z0-9][A-Za-z0-9_-]*'
  'SEAGATE-[A-Za-z0-9_-]+'
  'aobderive\.py'
  '(^|[/ ])scripts/fnos-dirfd-shim\.py'
  'REBASE\.md'
  'n3_rodata\.py'
  'net-(n1|n2|n3|n4|all|verify)\.sh'
  'ovs-(guard|vsctl)\.sh'
  'fnos-memview\.sh'
  'memview_test\.sh'
  'memview-dmi'
  'objdump.{0,40}(dirfd|unlinkat|魔数)'
)

stage_build() { # <stage-dir>
  local stage="$1" line f src dst missing=0
  rm -rf "$stage"; mkdir -p "$stage"
  while IFS= read -r line; do
    case "$line" in ""|\#*|\[*) continue;; esac
    # 重映射：src => dst（目标落点与源路径不同，如 CI workflow）
    if [[ "$line" == *"=>"* ]]; then
      src="$(echo "${line%%=>*}" | xargs)"; dst="$(echo "${line##*=>}" | xargs)"
      f="$REPO_ROOT/$src"
      # 清单即契约：声明了却不存在的条目 = 中止（不静默少文件）
      if [ ! -e "$f" ]; then log "清单项缺失: $src"; missing=1; continue; fi
      mkdir -p "$stage/$(dirname "$dst")"
      cp -a "$f" "$stage/$dst"
      continue
    fi
    # glob 展开（patches/fnos-*.json 等）：**glob 无匹配不算缺失**（例如还没有任何
    # 修正证据时 evidence/*.json 为空）；字面路径缺失 = 清单条目失效 → 中止。
    local had_glob=0
    case "$line" in *'*'*|*\?*) had_glob=1;; esac
    # shellcheck disable=SC2086
    for f in $REPO_ROOT/$line; do
      if [ ! -e "$f" ]; then
        if [ "$had_glob" = "1" ]; then log "清单 glob 无匹配（跳过）: $line"; continue; fi
        log "清单项缺失: $line"; missing=1; continue 2
      fi
      local rel="${f#$REPO_ROOT/}"
      mkdir -p "$stage/$(dirname "$rel")"
      cp -a "$f" "$stage/$rel"
    done
  done < <(parse_include)
  [ "$missing" = 0 ] || die "公开清单有条目在工作树中不存在（清单即契约），中止（不提交不推送）"
  log "暂存区组装完成: $stage"
}

leak_scan() { # <stage-dir>
  local stage="$1" pat hits=0
  for pat in "${LEAK_RES[@]}"; do
    while IFS= read -r hit; do
      printf '[sync-public] LEAK %s: %s\n' "$pat" "$hit" >&2; hits=1
    done < <(grep -rnE --exclude-dir=.git --exclude=sync-public.sh --exclude=publish.sh "$pat" "$stage" 2>/dev/null | head -5)
  done
  [ "$hits" = 0 ] || die "leak-scan 命中 $hits 类模式，中止（不提交不推送）"
  log "leak-scan 通过（0 命中）"
}

tree_hash() { # <stage-dir> -> 内容哈希（排除 git）
  (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
}

# 公开形态的清单：只留**公开段**（INCLUDE / PRESERVE）。
# 排除清单里的**私有文件名**本身即敏感信息（推导工具 / 逆向机制脚本 / rebase 方法论），
# 公开它们等于把边界写进公开树——实测公开清单曾含 12 处 leak 模式命中。
redact_manifest() { # <stage-dir>
  local stage="$1" mf="$stage/toolchain/public-manifest.txt"
  [ -f "$mf" ] || return 0
  python3 - "$mf" <<'PYEOF'
import re, sys
p = sys.argv[1]
secs, cur = {}, None
for line in open(p, encoding='utf-8').read().splitlines():
    m = re.match(r'^\[([^\]]+)\]', line)   # 段头可能是 [GRAY — 结论（…）] 这类带中文的
    if m:
        cur = m.group(1); secs.setdefault(cur, []); continue
    if cur:
        secs[cur].append(line)
out = ["# 公开清单（公开形态）",
       "# 只含公开段：公开集实际包含什么，以及哪些路径不由私有真源产出但必须保留。",
       "# 私有真源侧的排除清单不在此列出——那些文件名本身即敏感信息（推导工具 /",
       "# 逆向机制脚本 / rebase 方法论）；完整清单保存在私有真源，不公开。", "",
       "[INCLUDE]"] + secs.get('INCLUDE', []) + ["", "[PRESERVE]"] + secs.get('PRESERVE', []) + [""]
open(p, 'w', encoding='utf-8').write("\n".join(out))
PYEOF
  log "公开清单已裁成公开视图（去掉排除段里的私有文件名）"
}

# 逐文件脱敏（在 leak-scan 之前；规则有增补时同步更新 LEAK_RES 注释）
desensitize() { # <stage-dir>
  local stage="$1" j
  # 补丁集 provenance 字段去私有绝对路径（保留版本号可溯性，不保留机器路径与表名）
  # reason 字段去方法细节：只保留状态语义，aobpatch 报告展示有纯状态 fallback，不影响功能
  for j in "$stage"/toolchain/patches/fnos-*.json; do
    [ -f "$j" ] || continue
    python3 - "$j" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
if isinstance(d.get("derived_from_table"), str):
    d["derived_from_table"] = "private-table:" + str(d.get("fnos_version", "unknown"))
for x in d.get("patches", []):
    if isinstance(x, dict):
        if "retired_reason" in x:
            x["retired_reason"] = "retired"
        if "disabled_reason" in x:
            x["disabled_reason"] = "disabled (opt-in available)"
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PYEOF
  done
  redact_manifest "$stage"
  # 证据文件脱敏（进仓的两类：intent / behavior）：宿主地址、容器标识、账号不外泄
  local ev
  for ev in "$stage"/toolchain/patches/evidence/*.json; do
    [ -f "$ev" ] || continue
    python3 "$REPO_ROOT/toolchain/evidence.py" scrub "$ev" >/dev/null 2>&1 || true
  done
  log "脱敏规则已应用（derived_from_table 去私有路径；reason 去方法细节；清单裁成公开视图；证据脱敏）"
}

# 在 desensitize 之后生成就绪索引：sha256 必须对**脱敏后的 staged 文件**计算，
# 否则与公开仓实际发布的文件哈希对不上。生成物同时写回私有仓（保持 revision 来源）。
gen_index() { # <stage-dir>
  # 生成逻辑在 index_builder.py（可单测）：versions + samples（tier-A 指纹）
  # + coverage（纯哈希运算）。revision 基线唯一来源 = 公开仓当前索引。
  local stage="$1"
  python3 "$REPO_ROOT/toolchain/index_builder.py" build \
    --stage "$stage" \
    --public-slug "${FNOS_PUBLIC_SLUG:-xlight/fnos-docker-kit}" \
    --source-commit "${INDEX_SOURCE_COMMIT:-}" \
    ${INDEX_BASE_FILE:+--base-file "$INDEX_BASE_FILE"} \
    ${INDEX_OFFLINE:+--offline}
}

# 私有仓副本：**仅在全部检查通过后**回写（失败的那次不该推进 revision）
write_private_index() { # <stage-dir>
  if [ ! -f "$1/toolchain/patches/index.json" ]; then
    log "暂存区无索引（内容同步路径）→ 私有副本不变"
    return 0
  fi
  cp -f "$1/toolchain/patches/index.json" "$REPO_ROOT/toolchain/patches/index.json"
  log "私有仓索引副本已回写（缓存；基线以公开仓为准）"
}

case "$CMD" in
  stage)
    [ -n "$DST" ] || die "用法: $0 stage <暂存目录>"
    stage_build "$DST"
    desensitize "$DST"
    gen_index "$DST"
    assert_required_files "$DST"
    leak_scan "$DST"
    write_private_index "$DST"
    log "STAGE_HASH=$(tree_hash "$DST")"
    [ -n "${STAGE_KEEP:-}" ] || true
    ;;
  preserve-list)
    # 打印 [PRESERVE] 段里的路径（发布脚本用它保留 CI 提交的 state/）
    parse_preserve
    ;;
  stage-noidx)
    # 组装 + 脱敏 + 依赖断言 + leak-scan，**不生成索引**（两段提交用：
    # commit#1 = 内容，commit#2 = 带 source_commit 的索引）
    [ -n "$DST" ] || die "用法: $0 stage-noidx <暂存目录>"
    stage_build "$DST"
    desensitize "$DST"
    assert_required_files "$DST"
    leak_scan "$DST"
    log "STAGE_HASH=$(tree_hash "$DST")"
    ;;
  gen-index)
    # 生成就绪索引到暂存区（INDEX_SOURCE_COMMIT 可写 source_commit=commit#1 哈希）
    [ -n "$DST" ] || die "用法: $0 gen-index <暂存目录>"
    gen_index "$DST"
    ;;
  push)
    # 内容同步（**不生成/不更新索引**）：索引与发布请走 publish.sh（两段提交，
    # 索引带 source_commit 且 revision 只前进一格）。这里保留仓库里已有的索引，
    # 避免产生"无 source_commit 的新索引"。
    [ -n "$DST" ] || die "用法: $0 push <公开仓工作区目录>"
    [ -d "$DST/.git" ] || die "目标不是 git 仓: $DST"
    tmp="$(mktemp -d)"
    stage_build "$tmp"
    desensitize "$tmp"
    rm -f "$tmp/toolchain/patches/index.json"
    assert_required_files "$tmp"
    leak_scan "$tmp"
    write_private_index "$tmp"
    # 干净历史：清空工作区（保留 .git）后填入
    # [PRESERVE] 路径（如 CI 提交的 state/）擦树前备份、擦后放回
    preserve_tmp=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -e "$DST/$rel" ]; then
        preserve_tmp="$(mktemp -d)"
        mkdir -p "$preserve_tmp/$(dirname "$rel")"
        cp -a "$DST/$rel" "$preserve_tmp/$rel"
        log "保留段: $rel"
      fi
    done < <(parse_preserve)
    # 旧索引留档（内容同步不动它；发布由 publish.sh 负责）
    old_index="$(mktemp -d)"
    if git -C "$DST" cat-file -e HEAD:toolchain/patches/index.json 2>/dev/null; then
      mkdir -p "$old_index/toolchain/patches"
      git -C "$DST" show HEAD:toolchain/patches/index.json > "$old_index/toolchain/patches/index.json"
    fi
    (cd "$DST" && git ls-files -z | xargs -0 -r rm -f; find . -path ./.git -prune -o -type d -empty -delete)
    cp -a "$tmp/." "$DST/"
    if [ -f "$old_index/toolchain/patches/index.json" ]; then
      mkdir -p "$DST/toolchain/patches"
      cp -a "$old_index/toolchain/patches/index.json" "$DST/toolchain/patches/index.json"
      log "索引保持不变（发布请用 publish.sh）"
    fi
    rm -rf "$old_index"
    if [ -n "$preserve_tmp" ]; then
      (cd "$preserve_tmp" && find . -type f -print0) | while IFS= read -r -d "" f; do
        mkdir -p "$DST/$(dirname "$f")"
        cp -a "$preserve_tmp/$f" "$DST/$f"
      done
      rm -rf "$preserve_tmp"
    fi
    rm -rf "$tmp"
    # **属主归位**：用 root 跑同步会留下 root 属主的文件，之后普通用户 git 操作
    # 会报 "insufficient permission for adding an object"（2026-11-11 踩到）。
    # 按调用者（SUDO_USER）或目标仓原属主 chown 回去。
    local owner="${SUDO_USER:-${USER:-root}}"
    [ "$owner" = "root" ] && owner="$(stat -c '%U' "$DST" 2>/dev/null || echo root)"
    if [ "$owner" != "root" ] && id "$owner" >/dev/null 2>&1; then
      chown -R "$owner":"$(id -gn "$owner")" "$DST" 2>/dev/null || true
    fi
    (cd "$DST" && git add -A && git status --short | head -5 && git commit -qm "sync: $(date -u +%Y%m%dT%H%M%SZ)" && git rev-parse --short HEAD)
    log "已提交到公开仓工作区（推送请手动 git push，或配 remote 后加推）"
    ;;
  *) echo "用法: $0 stage|push <目录>"; exit 2 ;;
esac
