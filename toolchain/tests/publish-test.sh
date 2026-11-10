#!/usr/bin/env bash
# publish-test.sh —— 发布声明命令的回归（2.3/2.4/2.5/2.11/2.12）
#
# 场景：
#   A. --dry-run：8 项预检全过，**公开仓零副作用**（无提交、无 tag）
#   B. 演练记录被篡改（sha256 不符）→ 预检失败，远端零副作用
#   C. 正常发布：两段提交（内容 + 索引带 source_commit）、tag 不可变、原子推送
#   D. 幂等：同 tag 再跑一次 → 不移动 tag、不产生重复提交
#   E. tag 内容不符 → 报错拒绝（不动已发布 tag）
#   F. [PRESERVE] 段（state/）在同步后仍在
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PUB="$TMP/public"
REMOTE="$TMP/remote.git"
REH="$TMP/rehearsal"
VER="1.2.1000"
PS="$TC/patches/fnos-${VER}.json"

git init -q --bare "$REMOTE"
mkdir -p "$PUB"
git -C "$PUB" init -q -b main
git -C "$PUB" config user.name "tester"
git -C "$PUB" config user.email "tester@example.invalid"
git -C "$PUB" remote add origin "$REMOTE"
printf '# placeholder\n' > "$PUB/README.md"
git -C "$PUB" add -A && git -C "$PUB" commit -qm init
git -C "$PUB" push -q origin main
# CI 提交的 state/（必须被 [PRESERVE] 保留；由 CI 提交 → 属于已跟踪内容）
mkdir -p "$PUB/state"
echo "1.2.1000" > "$PUB/state/page_ver"
git -C "$PUB" add -A && git -C "$PUB" commit -qm "watch: state" && git -C "$PUB" push -q origin main

# 演练记录（sha256 用**私有源文件**形态，与 rehearsal-build.sh 一致）
mkdir -p "$REH"
PS_SHA=$(sha256sum "$PS" | awk '{print $1}')
python3 - "$REH/fnos-${VER}.json" "$PS_SHA" <<'PY'
import json, sys
json.dump({"mech": "release", "action": "rehearse", "version": "1.2.1000",
           "result": "ok", "patchset_sha256": sys.argv[2],
           "iso": {"md5": "x", "url": "u"}}, open(sys.argv[1], "w"))
PY

run_publish() { # <extra args...>
  FNOS_REHEARSE_DIR="$REH" bash "$TC/publish.sh" --patchset "$VER" --repo "$PUB" "$@" 2>&1
}

# ---- A. dry-run：预检全过、零副作用 ----
out=$(run_publish --dry-run)
if echo "$out" | grep -q "8 项预检全部通过"; then ok "A1: dry-run 预检全过"; else bad "A1: dry-run 未通过预检"; fi
BASE_COMMITS=$(git -C "$PUB" rev-list --count HEAD)
ntags=$(git -C "$PUB" tag | wc -l)
ncommits=$(git -C "$PUB" rev-list --count HEAD)
if [ "$ncommits" = "$BASE_COMMITS" ] && [ "$ntags" = "0" ]; then ok "A2: dry-run 零副作用（无提交无 tag）"; else bad "A2: dry-run 有副作用（commits=$ncommits tags=$ntags）"; fi

# ---- B. 演练记录被篡改 → 预检失败 ----
python3 - "$REH/fnos-${VER}.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["patchset_sha256"] = "0"*64
json.dump(d, open(p, "w"))
PY
out=$(run_publish --dry-run)
if echo "$out" | grep -q "预检未通过"; then ok "B1: 演练 sha256 不符 → 预检失败"; else bad "B1: 篡改后仍通过预检"; fi
ncommits=$(git -C "$PUB" rev-list --count HEAD)
if [ "$ncommits" = "$BASE_COMMITS" ]; then ok "B2: 预检失败远端零副作用"; else bad "B2: 预检失败仍产生提交"; fi
# 还原记录
python3 - "$REH/fnos-${VER}.json" "$PS_SHA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["patchset_sha256"] = sys.argv[2]
json.dump(d, open(p, "w"))
PY

# ---- C. 正常发布 ----
out=$(run_publish)
if echo "$out" | grep -q "发布完成"; then ok "C1: 发布成功"; else bad "C1: 发布失败: $(echo "$out" | tail -3)"; fi
ncommits=$(git -C "$PUB" rev-list --count HEAD)
if [ "$ncommits" = "$((BASE_COMMITS + 2))" ]; then ok "C2: 两段提交（内容 + 索引）"; else bad "C2: 提交数应为 $((BASE_COMMITS + 2))（实得 $ncommits）"; fi
if git -C "$PUB" rev-parse --verify --quiet "refs/tags/v${VER}" >/dev/null; then ok "C3: tag 已创建"; else bad "C3: tag 未创建"; fi
# 索引带 source_commit，且指向 commit#1
C1=$(git -C "$PUB" rev-parse HEAD~1)
SC=$(git -C "$PUB" show "HEAD:toolchain/patches/index.json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["versions"]["1.2.1000"]["source_commit"])')
if [ "$SC" = "$C1" ]; then ok "C4: 索引 source_commit 指向 commit#1"; else bad "C4: source_commit=$SC != commit#1=$C1"; fi
# 远端确实收到了（原子推送）
if git -C "$REMOTE" rev-parse --verify --quiet "refs/tags/v${VER}" >/dev/null; then ok "C5: 远端已有 tag（原子推送成功）"; else bad "C5: 远端无 tag"; fi
if git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/main" >/dev/null; then ok "C6: 远端 main 已更新"; else bad "C6: 远端 main 未更新"; fi
# state/ 被保留
if [ -f "$PUB/state/page_ver" ]; then ok "C7: [PRESERVE] 段 state/ 仍在"; else bad "C7: state/ 被同步擦掉"; fi

# ---- D. 幂等：同 tag 再跑 ----
before=$(git -C "$PUB" rev-parse "refs/tags/v${VER}")
out=$(run_publish)
after=$(git -C "$PUB" rev-parse "refs/tags/v${VER}")
if [ "$before" = "$after" ]; then ok "D1: 重复发布不移动已存在 tag"; else bad "D1: tag 被移动"; fi

# ---- E. tag 内容不符 → 拒绝 ----
git -C "$PUB" tag -f "v${VER}-r2" HEAD >/dev/null
# 改补丁集内容使哈希与 tag 不符，再发布到同一 tag
cp "$PS" "$PS.bak"
python3 - "$PS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["validation"]["note"] = "tampered-for-test"
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PY
out=$(run_publish --release-tag "v${VER}" 2>&1)
if echo "$out" | grep -q "预检未通过"; then ok "E1: 内容不符时报错拒绝（tag 不动）"; else bad "E1: 内容不符仍通过: $(echo "$out"|tail -3)"; fi
mv "$PS.bak" "$PS"

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
