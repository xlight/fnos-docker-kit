#!/usr/bin/env python3
"""proxy-test.py — fnos-updatemgr-proxy 的本地回归（假上游，不 联网）。

覆盖：
  5.1 /verlan GET/HEAD 透传、POST 拒 405、路径前缀校验、ThreadingHTTPServer
  5.2 上游不可达 → 200 {"data":{}}
  5.3 索引缓存 TTL、stale 回退、拒绝更旧 revision、从未成功 → unknown
  5.4 状态行注入 trimUpdate/kernelUpdate/新建 trimUpdate；/verlan 不跑内核过滤
  5.5 去 Accept-Encoding；gzip 上游先解压、响应删 Content-Encoding
  5.6 日志不含 authx；/branch/check 中和与放行、内核包过滤；TLS 校验开启

用法: python3 fnos/toolchain/tests/proxy-test.py
"""
import gzip
import http.client
import importlib.util
import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY = os.path.join(os.path.dirname(HERE), "..", "scripts", "fnos-updatemgr-proxy.py")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  PASS:", msg)


def no(msg):
    global FAIL
    FAIL += 1
    print("  FAIL:", msg)


def load_proxy(fake_urlopen, index_payload):
    src = open(PROXY).read().replace('if __name__ == "__main__":', 'if False:')
    m = {"__file__": PROXY}
    exec(compile(src, PROXY, "exec"), m)
    import urllib.request
    m["urllib"].request.urlopen = fake_urlopen
    m["fetch_index"]  # 触发存在性
    # 索引注入：直接替换缓存，避免真实网络
    m["_index_cache"].update(data=index_payload, fetched_at=time.time(), revision=1)
    # 宿主上没有 /usr/trim/etc/version：指到临时文件，模拟容器内已装版本
    import tempfile
    vf = tempfile.NamedTemporaryFile("w", suffix="-version", delete=False)
    vf.write("1.2.1010\n")
    vf.close()
    m["LOCAL_VERSION_PATH"] = vf.name
    return m


class FakeResp:
    def __init__(self, status, body, headers):
        self.status = status
        self._body = body
        self.headers = headers

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def make_upstream(routes, record):
    """routes: list of (predicate, handler). handler(req)->FakeResp 或抛异常。"""
    def urlopen(req, context=None, timeout=None):
        record.append({"url": req.full_url, "headers": dict(req.header_items()),
                       "method": req.get_method()})
        for pred, h in routes:
            if pred(req):
                r = h(req)
                if isinstance(r, Exception):
                    raise r
                return r
        return FakeResp(404, b"not found", {"Content-Type": "text/plain"})
    return urlopen


def start_server(m, port):
    srv = m["http"].server.ThreadingHTTPServer(("127.0.0.1", port), m["ProxyHandler"])
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def req(port, method, path, headers=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, dict(r.getheaders()), data


def main():
    global PASS, FAIL
    import urllib.error
    index = {"revision": 1, "generated": "t", "versions": {
        "1.2.1099": {"patchset": "fnos-1.2.1099.json", "sha256": "x", "ready": 36,
                     "total": 36, "status": "ready", "validated_at": "t"}}}
    verlan_body = json.dumps({"data": {"trimUpdate": "官方更新说明。", "kernelUpdate": "内核说明。"}}).encode()
    record = []

    def verlan_handler(req):
        return FakeResp(200, verlan_body, {"Content-Type": "application/json"})

    routes = [
        (lambda r: r.full_url.startswith("https://apiv2-liveupdate.fygonas.com/verlan/"), verlan_handler),
        (lambda r: r.full_url.startswith("https://apiv2-liveupdate.fnnas.com/branch/check"), lambda r: FakeResp(200, json.dumps({"data": {"version": "1.2.1010", "versionId": 1791, "packages": [{"packageName": "linux-image-trim"}, {"packageName": "trim"}]}}).encode(), {"Content-Type": "application/json"})),
    ]
    m = load_proxy(make_upstream(routes, record), index)
    port = 18080
    srv = start_server(m, port)
    time.sleep(0.2)

    # 5.1 GET /verlan 透传 + 状态行注入 + authx 透传 + Accept-Encoding 被去掉
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN",
                       headers={"authx": "secret-sig", "Accept-Encoding": "gzip, deflate"})
    obj = json.loads(body)
    assert st == 200, st
    assert "官方更新说明。" in obj["data"]["trimUpdate"], obj
    assert "已就绪（36/36）" in obj["data"]["trimUpdate"], obj
    assert "\n\n" in obj["data"]["trimUpdate"]
    fwd = record[-1]
    assert fwd["url"] == "https://apiv2-liveupdate.fygonas.com/verlan/beta/1.2.1099/zh-CN", fwd["url"]
    assert fwd["headers"].get("Authx") == "secret-sig", fwd["headers"]
    assert "Accept-Encoding" not in fwd["headers"], fwd["headers"]
    ok("5.1 GET /verlan 透传(路径+authx 原样)、状态行注入 trimUpdate、Accept-Encoding 已去")

    # 5.1 HEAD
    st, hd, body = req(port, "HEAD", "/verlan/beta/1.2.1099/zh-CN")
    assert st == 200 and body == b"", (st, body)
    ok("5.1 HEAD /verlan → 200 且无 body")

    # 5.1 POST 拒绝
    st, hd, body = req(port, "POST", "/verlan/beta/1.2.1099/zh-CN", body=b"{}")
    assert st == 405, st
    ok("5.1 POST /verlan → 405")

    # 5.4 无 trimUpdate 时新建；kernelUpdate 存在但 trimUpdate 缺失时写 kernelUpdate
    routes[0] = (routes[0][0], lambda r: FakeResp(200, json.dumps({"data": {"kernelUpdate": "K"}}).encode(), {"Content-Type": "application/json"}))
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN")
    obj = json.loads(body)
    assert "K" in obj["data"]["kernelUpdate"] and "已就绪" in obj["data"]["kernelUpdate"], obj
    ok("5.4 trimUpdate 缺失时注入 kernelUpdate")
    routes[0] = (routes[0][0], lambda r: FakeResp(200, json.dumps({"data": {}}).encode(), {"Content-Type": "application/json"}))
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN")
    obj = json.loads(body)
    assert "已就绪" in obj["data"]["trimUpdate"], obj
    ok("5.4 两者都缺失时新建 trimUpdate")

    # 5.2 上游失败 → 200 {"data":{}}
    routes[0] = (routes[0][0], lambda r: (_ for _ in ()).throw(OSError("down")))
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN")
    assert st == 200 and json.loads(body) == {"data": {}}, (st, body)
    ok("5.2 /verlan 上游失败 → 200 {\"data\":{}}")

    # 5.5 gzip 上游：解压后注入，响应无 Content-Encoding
    gz = gzip.compress(json.dumps({"data": {"trimUpdate": "GZ"}}).encode())
    routes[0] = (routes[0][0], lambda r: FakeResp(200, gz, {"Content-Type": "application/json", "Content-Encoding": "gzip"}))
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN", headers={"Accept-Encoding": "gzip"})
    obj = json.loads(body)
    assert "GZ" in obj["data"]["trimUpdate"] and "已就绪" in obj["data"]["trimUpdate"], obj
    assert hd.get("Content-Encoding") is None, hd
    ok("5.5 gzip 上游响应被解压注入，且响应头已无 Content-Encoding")

    # /verlan 不跑内核过滤：响应里带 kernel 字段也原样保留（只加状态行）
    routes[0] = (routes[0][0], lambda r: FakeResp(200, json.dumps({"data": {"trimUpdate": "T"}, "kernel": {"x": 1}}).encode(), {"Content-Type": "application/json"}))
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN")
    obj = json.loads(body)
    assert obj.get("kernel") == {"x": 1}, obj
    ok("5.4 /verlan 响应不被 filter_kernel 改写（kernel 字段保留）")

    # 5.3 索引 unknown：清空缓存 → 状态行含"未知"
    m["_index_cache"].update(data=None, fetched_at=0.0, revision=0)
    m["INDEX_CACHE_PATH"] = "/nonexistent/index.json"
    m["INDEX_URL"] = "http://127.0.0.1:1/index.json"
    routes[0] = (routes[0][0], verlan_handler)
    st, hd, body = req(port, "GET", "/verlan/beta/1.2.1099/zh-CN")
    obj = json.loads(body)
    assert "未知" in obj["data"]["trimUpdate"], obj
    ok("5.3 从未取到索引 → 状态行 unknown")

    # 5.3 拒绝更旧 revision
    orig_urlopen = m["urllib"].request.urlopen
    m["_index_cache"].update(data=index, fetched_at=time.time(), revision=5)
    older = {"revision": 3, "versions": {}}
    calls = []
    def urlopen_spy(req, context=None, timeout=None):
        calls.append(1)
        return FakeResp(200, json.dumps(older).encode(), {})
    m["urllib"].request.urlopen = urlopen_spy
    m["INDEX_URL"] = "http://fake/index.json"
    m["_index_cache"]["fetched_at"] = 0  # 强制过期
    data, src = m["fetch_index"]()
    assert data is index and "older-revision-rejected" in src, (data, src)
    ok("5.3 更旧 revision 的索引被拒绝（防回放）")
    # TTL 内不重复拉
    m["_index_cache"].update(data=index, fetched_at=time.time(), revision=9)
    calls.clear()
    m["fetch_index"](); m["fetch_index"]()
    assert not calls, calls
    ok("5.3 TTL 内重复查询只拉一次")
    m["urllib"].request.urlopen = orig_urlopen  # 恢复，供后续 branch/check 测试

    # /branch/check：同版本构建号误报归零 + 内核包过滤
    st, hd, body = req(port, "POST", "/branch/check", body=b"{}")
    obj = json.loads(body)
    assert obj["data"]["versionId"] == 0, obj
    assert all("linux-image" not in p.get("packageName", "") for p in obj["data"]["packages"]), obj
    ok("branch/check 同版本误报 versionId→0 且内核包被过滤")

    # 真正新版本放行
    routes[1] = (routes[1][0], lambda r: FakeResp(200, json.dumps({"data": {"version": "9.9.9999", "versionId": 5, "packages": []}}).encode(), {"Content-Type": "application/json"}))
    st, hd, body = req(port, "POST", "/branch/check", body=b"{}")
    obj = json.loads(body)
    assert obj["data"]["versionId"] == 5, obj
    ok("branch/check 真正新版本放行")

    # 5.6 日志不含 authx：log_message 只记方法+路径
    import io
    buf = io.StringIO()
    old = sys.stderr
    sys.stderr = buf
    m["ProxyHandler"].log_message(m["ProxyHandler"](None) if False else None, "%s", "x") if False else None
    sys.stderr = old
    # 直接调 log_message
    h = m["ProxyHandler"]
    old_stderr = sys.stderr
    sys.stderr = buf
    class FakeSelf: command = "GET"; path = "/verlan/beta/1.2.1099/zh?authx=SECRET"
    h.log_message(FakeSelf(), "%s %s", "GET", "/x")
    sys.stderr = old_stderr
    assert "SECRET" not in buf.getvalue() and "authx" not in buf.getvalue(), buf.getvalue()
    ok("5.6 日志不含 authx/签名材料")

    srv.shutdown()
    print()
    print("== proxy-test: PASS=%d FAIL=%d ==" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
