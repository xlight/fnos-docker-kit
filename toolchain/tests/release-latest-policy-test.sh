#!/usr/bin/env bash
# release-latest-policy-test.sh —— "Latest" 归属策略的回归（按版本号，不按发布时间）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(dirname "$HERE")/release-latest-policy.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

expect() { # <版本> <当前 Latest tag> <期望>
  local got; got="$(bash "$SCRIPT" "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$1 vs $2 → $3"; else bad "$1 vs $2 → $got（期望 $3）"; fi
}

# 更高的版本抢 Latest
expect "1.2.1010" "v1.2.1000" latest
# 更旧的版本不抢（补发旧版本时保持 Latest 不变）
expect "1.2.1000" "v1.2.1010-r3" not-latest
# 同版本：更高修订号抢
expect "1.2.1010-r3" "v1.2.1010-r2" latest
# 同版本的**基线**不比它的修订号新 → 不抢（r2 比裸版本新）
expect "1.2.1010" "v1.2.1010-r2" not-latest
# 同版本同修订号：允许（幂等重跑）
expect "1.2.1010-r3" "v1.2.1010-r3" latest
# 更低的修订号不抢
expect "1.2.1010-r2" "v1.2.1010-r3" not-latest
# 没有当前 Latest → 新接管
expect "1.2.0701" "" latest
# 段数不同（1.2.1000 vs 1.2.1000.1）
expect "1.2.1000.1" "v1.2.1000" latest
expect "1.2.1000" "v1.2.1000.1" not-latest
# 解析不了 → 不抢
expect "not-a-version" "v1.2.1010" not-latest

printf '== 结果: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
