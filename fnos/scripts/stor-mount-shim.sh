#!/bin/bash
# stor-mount-shim.sh —— 部署到容器 /usr/local/sbin/mount
#
# 背景：fnOS 的 triminit/storage.hdl 会用
#     mount -t btrfs -o trimacl <dev> <mnt>
#     mount -t ext4  -o trimacl,prjquota <dev> <mnt>
# 挂载存储卷；而 PVE 内核不认识 trimacl，会以 EINVAL 拒绝 → 卷挂不上。
#
# 本 shim 只做一件事：把选项里的 trimacl 剥掉，再 exec 真正的 /bin/mount。
# 其余参数原样透传；只在出现 trimacl 时改写并记一条日志。
# 幂等、无副作用、可回撤（删掉本文件即恢复原始行为）。

LOG=/var/log/fnos-mount-shim.log
new=()
argv=("$@")
n=${#argv[@]}
i=0
changed=0

while (( i < n )); do
  a="${argv[i]}"
  # 形如  -o <opts>  /  --options <opts>
  if [[ ( "$a" == "-o" || "$a" == "--options" ) && $(( i + 1 )) -lt n ]]; then
    opt="${argv[i+1]}"
    if [[ "$opt" == *trimacl* ]]; then
      cleaned="$(printf '%s' "$opt" | sed -e 's/trimacl//g' -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')"
      # fnOS 的 ACL 存在 system.trim_acl（原生内核不支持）。同时禁掉 user.* xattr，
      # 使 fnOS 的探测 setxattr(user.is_trimacl) 失败 → 触发它的「权限未适配」降级（走 POSIX ACL）。

      if [[ -n "$cleaned" ]]; then new+=("$a" "$cleaned"); else new+=("$a" "rw"); fi
      changed=1; i=$(( i + 2 )); continue
    fi
    new+=("$a" "$opt"); i=$(( i + 2 )); continue
  fi
  # 形如  -o=trimacl,...  或裸的 trimacl 选项
  if [[ "$a" == *trimacl* ]]; then
    cleaned="$(printf '%s' "$a" | sed -e 's/trimacl//g' -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')"

    [[ -n "$cleaned" ]] && new+=("$cleaned")
    changed=1; i=$(( i + 1 )); continue
  fi
  new+=("$a"); i=$(( i + 1 ))
done

if (( changed )); then
  { printf '%s [shim] in : ' "$(date '+%F %T')"; printf '%q ' "${argv[@]}"; printf '\n';
    printf '%s [shim] out: ' "$(date '+%F %T')"; printf '%q ' "${new[@]}";  printf '\n'; } \
    >> "$LOG" 2>/dev/null
fi

exec /bin/mount "${new[@]}"
