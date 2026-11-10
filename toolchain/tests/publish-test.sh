#!/usr/bin/env bash
# publish-test.sh —— 发布声明命令（人工旁路）的回归（2.3/2.4/2.5/2.11/2.12 + 5.13）
#
# 场景：
#   A. --dry-run：8 项预检全过，**公开仓零副作用**（无提交、无 tag、无 dispatch）
#   B. 演练记录被篡改（sha256 不符）→ 预检失败，远端零副作用
#   C. 正常发布：内容落地（两段提交：内容 + 带 source_commit 的索引）+ 一次推送
#      + **不建 tag**（tag 归发布单元）+ dispatch 发布单元
#   D. 幂等：再跑一次 → 无新提交（内容未变 → 不重复提交、revision 不前进）
#   E. 既有 tag 内容不符 → 预检失败（tag 不可变）
#   F. [PRESERVE] 段（state/）在同步后仍在
#   G. tag 存在性查询失败 → fail-closed（预检失败，不发布）
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
BIN="$TMP/bin"
VER="1.2.1000"
PS="$TC/patches/fnos-${VER}.json"

# gh 桩：记录 dispatch 调用（不联网、不需要凭据）
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_LOG"
exit 0
EOF
chmod +x "$BIN/gh"
export GH_STUB_LOG="$TMP/gh.log"
export PATH="$BIN:$PATH"

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
if echo "$out" | grep -q "8 项预检全部通过"; then ok "A1: dry-run 预检全过"; else bad "A1: dry-run 未通过预检: $(echo "$out"|tail -3)"; fi
BASE_COMMITS=$(git -C "$PUB" rev-list --count HEAD)
ncommits=$(git -C "$PUB" rev-list --count HEAD)
ntags=$(git -C "$PUB" tag | wc -l)
if [ "$ncommits" = "$BASE_COMMITS" ] && [ "$ntags" = "0" ] && [ ! -s "$GH_STUB_LOG" ]; then
  ok "A2: dry-run 零副作用（无提交、无 tag、无 dispatch）"; else bad "A2: dry-run 有副作用（commits=$ncommits tags=$ntags）"; fi

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
python3 - "$REH/fnos-${VER}.json" "$PS_SHA" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["patchset_sha256"] = sys.argv[2]
json.dump(d, open(p, "w"))
PY

# ---- C. 正常发布（内容落地；不建 tag；dispatch 发布单元）----
out=$(run_publish)
if echo "$out" | grep -q "内容落地"; then ok "C1: 内容落地成功"; else bad "C1: 发布失败: $(echo "$out" | tail -5)"; fi
ncommits=$(git -C "$PUB" rev-list --count HEAD)
if [ "$ncommits" = "$((BASE_COMMITS + 2))" ]; then ok "C2: 两段提交（内容 + 索引）"; else bad "C2: 提交数应为 $((BASE_COMMITS + 2))（实得 $ncommits）"; fi
if git -C "$PUB" rev-parse --verify --quiet "refs/tags/v${VER}" >/dev/null; then
  bad "C3: publish.sh 建了 tag（tag 的唯一创建者应是发布单元）"; else ok "C3: publish.sh 不建 tag（归发布单元）"; fi
# 索引带 source_commit，且指向 commit#1
C1=$(git -C "$PUB" rev-parse HEAD~1)
SC=$(git -C "$PUB" show "HEAD:toolchain/patches/index.json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["versions"]["1.2.1000"].get("source_commit",""))')
if [ "$SC" = "$C1" ]; then ok "C4: 索引 source_commit 指向 commit#1"; else bad "C4: source_commit=$SC != commit#1=$C1"; fi
# 远端 main 收到（一次推送）
if git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/main" >/dev/null; then ok "C5: 远端 main 已更新"; else bad "C5: 远端 main 未更新"; fi
# state/ 被保留
if [ -f "$PUB/state/page_ver" ]; then ok "C6: [PRESERVE] 段 state/ 仍在"; else bad "C6: state/ 被同步擦掉"; fi
# 发布单元被 dispatch（带版本与 tag）
if grep -q "workflow run public-release.yml" "$GH_STUB_LOG" 2>/dev/null && grep -q "patchset=$VER" "$GH_STUB_LOG"; then
  ok "C7: 已 dispatch 发布单元（patchset=$VER）"; else bad "C7: 未 dispatch 发布单元: $(cat "$GH_STUB_LOG" 2>/dev/null)"; fi

# ---- D. 幂等：再跑一次（内容未变 → 不重复提交）----
before_commits=$(git -C "$PUB" rev-list --count HEAD)
before_rev=$(python3 -c 'import json;print(json.load(open("'"$PUB"'/toolchain/patches/index.json"))["revision"])')
out=$(run_publish)
after_commits=$(git -C "$PUB" rev-list --count HEAD)
after_rev=$(python3 -c 'import json;print(json.load(open("'"$PUB"'/toolchain/patches/index.json"))["revision"])')
if [ "$before_commits" = "$after_commits" ] && [ "$before_rev" = "$after_rev" ]; then
  ok "D1: 重复发布幂等（无新提交、revision 不前进）"; else bad "D1: 重复发布产生副作用（commits $before_commits→$after_commits, rev $before_rev→$after_rev）"; fi

# ---- E. 既有 tag 内容不符 → 拒绝（tag 不可变）----
# 造一个内容与本次不同的既有 tag
git -C "$PUB" tag "v${VER}" HEAD >/dev/null 2>&1
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
if git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/main" >/dev/null; then
  ok "E2: 拒绝后远端仍在（未被移动）"; else bad "E2: 拒绝后远端异常"; fi
mv "$PS.bak" "$PS"

# ---- G. tag 存在性查询失败 → fail-closed ----
out=$(FNOS_RELEASE_GIT_FAIL=1 run_publish --release-tag "v${VER}-r9" 2>&1)
if echo "$out" | grep -q "预检未通过\|fail-closed"; then ok "G1: tag 查询失败 → 保守不发布（fail-closed）"; else bad "G1: 查询失败仍继续: $(echo "$out"|tail -3)"; fi

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
