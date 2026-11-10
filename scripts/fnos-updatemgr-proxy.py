#!/usr/bin/env python3
"""fnOS updatemgr 本地代理（LXC 专用）。

updatemgr 通过 UPDATEMGR_CLOUD_BASE_URL 指向本代理（见 updatemgr.service.d/proxy.conf），
本代理再转发到官方云端，并对响应做三件事：

1. 过滤内核相关升级包：删除顶层 `kernel` 字段、过滤 `packages[]` 中的
   linux-image / linux-modules-trim / linux-headers / linux-libc-dev。
   （容器跑 PVE 内核，装 trim 内核必坏。）

2. 中和构建号误报：`/branch/check` 返回**同一版本号**但更高的 `versionId` 时，
   把 `data.versionId` 改写为 0；真正更高的版本照常放行。

3. `/verlan/*`（WebUI 更新说明）透传到 `apiv2-liveupdate.fygonas.com`，
   并在 `data.trimUpdate`（或 `kernelUpdate`）末尾追加一行目标版本补丁集就绪状态。
   就绪状态来自 GitHub 托管的就绪索引（FNOS_INDEX_URL，TTL 10 分钟，
   失败用 stale、拒绝更旧 revision、从未成功为 unknown）。

规则：
- `/verlan/*` 只允许 GET/HEAD，不跑内核过滤/构建号中和；上游失败返回 200 + {"data":{}}。
- 转发一律去掉 `Accept-Encoding`；上游仍返回 gzip/deflate 时先解压再解析，
  并从响应中删除 `Content-Encoding`、重算 `Content-Length`。
- 上游一律启用 TLS 证书校验（create_default_context）。
- 日志只记方法与路径（去掉 query，避免签名材料入日志）。

部署位置（CT201）：/usr/local/sbin/fnos-updatemgr-proxy.py
systemd 单元：fnos-updatemgr-proxy.service（Before=updatemgr.service）
监听：127.0.0.1:8080（PROXY_PORT 可覆盖）

本文件是仓库内的规范副本；部署后与容器内文件保持一致。
"""
import gzip
import http.server
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib

CLOUD_HOST = "apiv2-liveupdate.fnnas.com"
VERLAN_HOST = "apiv2-liveupdate.fygonas.com"
LISTEN_PORT = int(os.environ.get("PROXY_PORT", "8080"))
KERNEL_KEYWORDS = ("linux-image", "linux-modules-trim", "linux-headers", "linux-libc-dev")
LOCAL_VERSION_PATH = "/usr/trim/etc/version"
INDEX_URL = os.environ.get(
    "FNOS_INDEX_URL",
    "https://raw.githubusercontent.com/xlight/fnos-docker-kit/main/toolchain/patches/index.json")
INDEX_CACHE_PATH = "/run/fnos-updatemgr/index.json"
INDEX_TTL = 600          # 10 分钟
VERLAN_TIMEOUT = 10      # /verlan 上游超时（秒）
UPSTREAM_TIMEOUT = 60    # 其他路径上游超时（秒）


def log(msg):
    print("PROXY:", msg, file=sys.stderr, flush=True)


def is_kernel_pkg(name):
    return any(kw in (name or "") for kw in KERNEL_KEYWORDS)


def local_version():
    try:
        with open(LOCAL_VERSION_PATH) as f:
            return f.read().strip()
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# 就绪索引缓存（内存 + /run 持久影子；TTL 10 分钟；stale 回退；拒绝更旧 revision）
# ---------------------------------------------------------------------------

_index_lock = threading.Lock()
_index_cache = {"data": None, "fetched_at": 0.0, "revision": 0}


def fetch_index():
    """返回 (index_or_None, source)。source: fresh/cache/stale/stale-disk/unknown。"""
    with _index_lock:
        now = time.time()
        if _index_cache["data"] is not None and now - _index_cache["fetched_at"] < INDEX_TTL:
            return _index_cache["data"], "cache"
        try:
            req = urllib.request.Request(
                INDEX_URL,
                headers={"Accept-Encoding": "identity", "User-Agent": "fnos-updatemgr-proxy/2.0"})
            with urllib.request.urlopen(req, timeout=15,
                                        context=ssl.create_default_context()) as r:
                data = json.loads(r.read().decode("utf-8"))
            rev = int(data.get("revision") or 0)
            if _index_cache["data"] is not None and rev <= _index_cache["revision"]:
                # 拒绝比缓存更旧的索引（防回放）
                return _index_cache["data"], "stale(older-revision-rejected)"
            _index_cache.update(data=data, fetched_at=now, revision=rev)
            try:
                os.makedirs(os.path.dirname(INDEX_CACHE_PATH), exist_ok=True)
                with open(INDEX_CACHE_PATH, "w") as f:
                    json.dump(data, f)
            except OSError:
                pass
            return data, "fresh"
        except Exception as e:
            log("index fetch failed: %s" % e)
            if _index_cache["data"] is not None:
                return _index_cache["data"], "stale"
            try:
                with open(INDEX_CACHE_PATH) as f:
                    data = json.load(f)
                _index_cache.update(data=data, fetched_at=now,
                                    revision=int(data.get("revision") or 0))
                return data, "stale-disk"
            except Exception:
                return None, "unknown"


def vkey(v):
    m = re.match(r"\s*(\d+(?:\.\d+)*)", str(v))
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)


def readiness_for(version):
    """返回 (state, ready, total, source, detail)。

    state: ready/partial/missing/unknown
    detail: {"patchset_ver":..., "missing":[...], "covered":..., "total_files":...}

    有覆盖度矩阵时，按 (目标版本, 候选补丁集) 回答：精确版本优先，否则取覆盖度最高
    的严格更早候选；部分覆盖时 detail["missing"] 点名未覆盖文件。无矩阵（旧索引）
    时退化为精确版本语义，行为与改造前一致。
    """
    data, src = fetch_index()
    if data is None:
        return "unknown", None, None, src, {}
    versions = data.get("versions") or {}
    e = versions.get(str(version))
    if e:
        detail = {}
        cov = ((data.get("coverage") or {}).get(str(version)) or {}).get(str(version))
        if cov:
            detail = {"patchset_ver": str(version), "missing": cov.get("missing") or [],
                      "covered": cov.get("covered_files"), "total_files": cov.get("total_files")}
        return str(e.get("status") or "missing"), e.get("ready"), e.get("total"), src, detail
    # 无精确命中：按覆盖度挑更早候选（仅当矩阵存在）
    cov_all = data.get("coverage") or {}
    tk = vkey(version)
    best = None
    for pver, targets in cov_all.items():
        cell = (targets or {}).get(str(version))
        if not cell:
            continue
        if vkey(pver) >= tk:
            continue
        key = (cell.get("covered_files") or 0, vkey(pver))
        if best is None or key > best[0]:
            best = (key, pver, cell)
    if best:
        _key, pver, cell = best
        pe = versions.get(pver) or {}
        detail = {"patchset_ver": pver, "missing": cell.get("missing") or [],
                  "covered": cell.get("covered_files"), "total_files": cell.get("total_files")}
        state = "ready" if not cell.get("missing") else "partial"
        return state, pe.get("ready"), pe.get("total"), src, detail
    return "missing", None, None, src, {}


def status_line(version):
    state, ready, total, src, detail = readiness_for(version)
    gap = ""
    if detail.get("missing"):
        names = list(detail["missing"])[:5]
        more = len(detail["missing"]) - len(names)
        gap = "未覆盖：%s%s" % ("、".join(names), ("…等 %d 项" % more) if more > 0 else "")
    if state == "ready":
        line = "补丁集 %s 已就绪（%s/%s），升级后会自动重新应用。" % (version, ready, total)
        if detail.get("patchset_ver") and detail["patchset_ver"] != str(version):
            line = "补丁集 %s 已就绪（用 %s 的补丁集，%s/%s），升级后会自动重新应用。" % (
                version, detail["patchset_ver"], ready, total)
        return line + (("（%s）" % gap) if gap else "")
    if state == "partial":
        line = "补丁集 %s 部分就绪（%s/%s），未命中项升级后会被跳过并记录。" % (version, ready, total)
        if detail.get("patchset_ver") and detail["patchset_ver"] != str(version):
            line = "补丁集 %s 部分就绪（用 %s 的补丁集，%s/%s），未命中项升级后会被跳过并记录。" % (
                version, detail["patchset_ver"], ready, total)
        return line + (("（%s）" % gap) if gap else "")
    if state == "missing":
        return "补丁集 %s 尚未就绪，升级后部分补丁可能不可用。" % version
    return "补丁集 %s 就绪状态未知（索引未取到，不影响升级）。" % version


def verlan_version(path):
    """/verlan/<branch>/<version>/<lang> → version（取不到返回 None）。"""
    m = re.match(r"^/verlan/[^/?]+/([^/?]+)/[^/?]+", path.split("?")[0])
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# 响应体处理
# ---------------------------------------------------------------------------

def maybe_decompress(body, content_encoding):
    enc = (content_encoding or "").lower()
    if enc == "gzip":
        try:
            return gzip.decompress(body), True
        except OSError:
            return body, False
    if enc == "deflate":
        try:
            return zlib.decompress(body), True
        except zlib.error:
            return body, False
    return body, False


def filter_kernel(body):
    """Filter kernel from JSON response. Preserve trailing binary data."""
    try:
        decoder = json.JSONDecoder()
        obj, idx = decoder.raw_decode(body.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return body
    if not isinstance(obj, dict):
        return body
    changed = False
    if isinstance(obj.get("kernel"), (dict, list)):
        del obj["kernel"]; changed = True
    data = obj.get("data")
    if isinstance(data, dict) and isinstance(data.get("packages"), list):
        kept = [p for p in data["packages"] if not is_kernel_pkg(p.get("packageName") or p.get("name"))]
        if len(kept) != len(data["packages"]):
            data["packages"] = kept; changed = True
    if not changed:
        return body
    out = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return out.encode("utf-8") + body[idx:]


def neutralise_branch_check(body):
    """同版本构建号误报 → versionId 归零；真正新版本放行。"""
    try:
        decoder = json.JSONDecoder()
        obj, idx = decoder.raw_decode(body.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return body
    if not isinstance(obj, dict):
        return body
    data = obj.get("data")
    if not isinstance(data, dict) or "versionId" not in data:
        return body
    old = data.get("versionId")
    ver = data.get("version")
    local = local_version()
    if ver and local and ver != local:
        log("OTA visible: cloud=%s > installed=%s versionId=%s (kernel filtered)" % (ver, local, old))
        return body
    if old not in (0, None):
        log("branch/check: version=%s installed=%s versionId=%s -> 0 (build-id false positive)" % (ver, local, old))
    data["versionId"] = 0
    obj["data"] = data
    out = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return out.encode("utf-8") + body[idx:]


def inject_status_line(body, version):
    """在 data.trimUpdate（缺失则 kernelUpdate，再缺失则新建 trimUpdate）末尾追加状态行。"""
    try:
        decoder = json.JSONDecoder()
        obj, idx = decoder.raw_decode(body.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return body
    if not isinstance(obj, dict):
        return body
    data = obj.get("data")
    if not isinstance(data, dict):
        return body
    line = status_line(version)
    if isinstance(data.get("trimUpdate"), str):
        data["trimUpdate"] = data["trimUpdate"] + "\n\n" + line
    elif isinstance(data.get("kernelUpdate"), str):
        data["kernelUpdate"] = data["kernelUpdate"] + "\n\n" + line
    else:
        data["trimUpdate"] = line
    obj["data"] = data
    out = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return out.encode("utf-8") + body[idx:]


# ---------------------------------------------------------------------------
# HTTP 代理
# ---------------------------------------------------------------------------

HOP_HEADERS = ("host", "content-length", "connection", "transfer-encoding",
               "accept-encoding", "keep-alive", "proxy-authorization", "te", "trailer",
               "upgrade")


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _forward(self, method):
        path_only = self.path.split("?")[0]
        is_verlan = path_only.startswith("/verlan/")
        if is_verlan and method not in ("GET", "HEAD"):
            self.send_error(405, "verlan allows GET/HEAD only")
            return
        host = VERLAN_HOST if is_verlan else CLOUD_HOST
        url = "https://%s%s" % (host, self.path)
        length = int(self.headers.get("Content-Length", 0) or 0)
        data = self.rfile.read(length) if length > 0 else None

        headers = {}
        for k, v in self.headers.items():
            if k.lower() not in HOP_HEADERS:
                headers[k] = v

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        ctx = ssl.create_default_context()  # 启用证书校验
        timeout = VERLAN_TIMEOUT if is_verlan else UPSTREAM_TIMEOUT
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
                body = resp.read()
                resp_headers = resp.headers
                status = resp.status
        except urllib.error.HTTPError as e:
            # /verlan 上游报错也返回合法 JSON，前端卡片不被 reject
            if is_verlan:
                self._send_json(200, {"data": {}})
            else:
                body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            return
        except Exception as e:
            if is_verlan:
                log("verlan upstream failed: %s" % e)
                self._send_json(200, {"data": {}})
            else:
                msg = str(e).encode()
                self.send_response(502)
                self.send_header("Content-Length", str(len(msg)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(msg)
            return

        decompressed = False
        body, decompressed = maybe_decompress(body, resp_headers.get("Content-Encoding"))
        if is_verlan:
            ver = verlan_version(self.path) or local_version().lstrip("Vv")
            body = inject_status_line(body, ver)
        else:
            body = filter_kernel(body)
            if path_only == "/branch/check":
                body = neutralise_branch_check(body)

        self.send_response(status)
        for k, v in resp_headers.items():
            lk = k.lower()
            if lk in ("content-length", "transfer-encoding", "connection"):
                continue
            if decompressed and lk == "content-encoding":
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(body)

    def _send_json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_HEAD(self):
        self._forward("HEAD")

    def log_message(self, fmt, *args):
        # 只记方法与路径（去掉 query，避免签名材料写进日志）
        path = self.path.split("?")[0]
        log("%s %s" % (self.command, path))


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler).serve_forever()
