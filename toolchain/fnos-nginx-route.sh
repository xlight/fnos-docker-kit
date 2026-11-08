#!/bin/bash
# 在 trim_nginx 启动前就位 /__updatemgr/verlan/ 路由；幂等：zip 里已有同名条目则跳过。
set -u
CONF=/usr/trim/nginx/conf/conf.d/updatemgr-verlan.conf
ZIP=/usr/trim/share/.restore/ng.conf.zip
ENTRY=conf.d/updatemgr-verlan.conf
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<'EOF'
location /__updatemgr/verlan/ {
    proxy_pass http://127.0.0.1:8080/verlan/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Accept-Encoding "";
    proxy_read_timeout 15s;
}
EOF
if [ -f "$ZIP" ] && command -v zip >/dev/null 2>&1; then
  if python3 -c "import zipfile,sys; sys.exit(0 if '$ENTRY' in zipfile.ZipFile('$ZIP').namelist() else 1)" 2>/dev/null; then
    echo "ng.conf.zip already has $ENTRY"
  else
    d="$(mktemp -d)"
    mkdir -p "$d/conf.d"
    cp "$CONF" "$d/$ENTRY"
    (cd "$d" && zip -q "$ZIP" "$ENTRY")
    rm -rf "$d"
    echo "appended $ENTRY to ng.conf.zip"
  fi
fi
/usr/trim/nginx/sbin/nginx -t
