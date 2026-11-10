#!/usr/bin/env bash
# iso-detect-test.sh —— 检测器双通道 state 语义回归（2.1b）
#
# 场景：
#   A. OTA 通道失败 → 页面 state 仍被写入，rc=2
#   B. 页面通道失败 → OTA state 仍被写入，rc=2
#   C. 双通道正常 → 两个 state 都写
#   D. 连续两次 → 第二次"无变化"（rc=0）
#
# 用 FNOS_PAGE_URL / FNOS_OTA_URL 覆盖端点做 mock（不需要真网）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TC="$(dirname "$HERE")"
DET="$TC/check-iso-update.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

# 假的页面 HTML（检测器用 RE_BLOCK 解析版本块；构造一个最小可用块）
FAKE_PAGE="$TMP/page.html"
# 页面块格式与官网一致（download:{version,url,hash}；反斜杠转义）
cat > "$FAKE_PAGE" <<'HTML'
<html><body><script>
var x = {\"download\":{\"version\":\"1.2.1000\",\"url\":\"https://example.invalid/fnos.iso\",\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}};
</script></body></html>
HTML

# 假的 OTA JSON（检测器只要 packages[].packageName=="trim"）
FAKE_OTA="$TMP/ota.json"
cat > "$FAKE_OTA" <<'JSON'
{"packages":[{"packageName":"trim","version":"1.2.1010"}]}
JSON

run_det() { # <page-url> <ota-url> <state> <ota-state>
  FNOS_PAGE_URL="$1" FNOS_OTA_URL="$2" python3 "$DET" \
      --state "$3" --ota-state "$4" --no-probe >/dev/null 2>&1
  echo $?
}

# A. OTA 失败 → page state 写、rc=2
rc=$(run_det "file://$FAKE_PAGE" "http://127.0.0.1:9/ota" "$TMP/a.page" "$TMP/a.ota")
[ "$rc" = "2" ] && ok "A: OTA 失败时 rc=2" || bad "A: OTA 失败时 rc 应为 2（实得 $rc）"
[ -s "$TMP/a.page" ] && ok "A: OTA 失败时 page state 已写" || bad "A: page state 未写"
[ ! -s "$TMP/a.ota" ] && ok "A: OTA 失败时 ota state 未写" || bad "A: ota state 被错误写入"

# B. 页面失败 → ota state 写、rc=2
rc=$(run_det "http://127.0.0.1:9/page" "file://$FAKE_OTA" "$TMP/b.page" "$TMP/b.ota")
[ "$rc" = "2" ] && ok "B: 页面失败时 rc=2" || bad "B: 页面失败时 rc 应为 2（实得 $rc）"
[ ! -s "$TMP/b.page" ] && ok "B: 页面失败时 page state 未写" || bad "B: page state 被错误写入"
[ -s "$TMP/b.ota" ] && ok "B: 页面失败时 ota state 已写" || bad "B: ota state 未写"

# C. 双通道正常 → 两个 state 都写
rc=$(run_det "file://$FAKE_PAGE" "file://$FAKE_OTA" "$TMP/c.page" "$TMP/c.ota")
[ -s "$TMP/c.page" ] && ok "C: page state 已写" || bad "C: page state 未写"
[ -s "$TMP/c.ota" ] && ok "C: ota state 已写" || bad "C: ota state 未写"

# D. 第二次 → 无变化（rc=0）
rc=$(run_det "file://$FAKE_PAGE" "file://$FAKE_OTA" "$TMP/c.page" "$TMP/c.ota")
[ "$rc" = "0" ] && ok "D: 第二次运行报告无变化（rc=0）" || bad "D: 第二次 rc 应为 0（实得 $rc）"

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
