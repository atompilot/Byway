from contextlib import ExitStack
from pathlib import Path
import json
import socket
import sys
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

binary = sys.argv[1]
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(token, path="/v1/status", method="GET", data=None, extra_headers=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    headers.update(extra_headers or {})
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(f"http://127.0.0.1:{port}"+path, data=None if data is None else json.dumps(data).encode(),
                                 headers=headers, method=method)
    try:
        with http.open(req, timeout=1) as result:
            if result.headers.get_content_type() != "application/json":
                return result.status, result.read().decode()
            return result.status, json.load(result)
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except (urllib.error.URLError, TimeoutError, ConnectionResetError):
        return None, None


def wait_for(token, expected, connected=None):
    for _ in range(60):
        status, body = request(token)
        if status == expected and (connected is None or body["connected"] == connected):
            return
        time.sleep(0.1)
    raise AssertionError(f"Expected {expected} with VPN={connected}")


with tempfile.TemporaryDirectory(prefix="byway-lan-handoff-") as folder, ExitStack() as stack:
    file = Path(folder) / "lan-control.json"

    def configure(operation):
        subprocess.run([binary, folder, operation], check=True)

    configure("enable")
    token = json.loads(file.read_text())["token"]

    def launch(role):
        p = subprocess.Popen([binary, folder, role, str(port)], stdin=subprocess.PIPE, text=True)
        def cleanup():
            if p.poll() is None:
                p.stdin.close()
                p.wait(timeout=4)
        stack.callback(cleanup)
        return p

    app = launch("app")
    wait_for(token, 200, False)
    origin = f"http://127.0.0.1:{port}"
    browser = {"Origin": origin, "Sec-Fetch-Site": "same-origin"}
    assert "连接设备" in request("", "/", extra_headers={"Sec-Fetch-Site": "none"})[1]
    assert request("", "/management.js")[0] == 200
    assert request("", "/management.css")[0] == 200
    assert request("", "/v1/device", extra_headers=browser)[0] == 401
    assert request("", "/v1/discovery")[0] == 401
    discovery = request(token, "/v1/discovery")[1]
    assert discovery["enabled"] is True and discovery["ipUrl"] == origin + "/"
    assert request(token, "/v1/discovery", "PATCH", {"enabled": False}, extra_headers=browser) == (
        200, {"enabled": False, "status": "off", "ipUrl": origin + "/"})
    assert request("", "/")[0] == 200
    assert request(token, "/v1/device", extra_headers={"Origin": "http://example.invalid"})[0] == 403
    assert request(token, "/v1/device", extra_headers={"Host": "elsewhere.invalid", "Sec-Fetch-Site": "same-origin"})[0] == 403
    assert request(token, "/v1/nodes", "POST", {}, extra_headers=browser)[0] == 403
    code, device = request(token, "/v1/device")
    assert code == 200 and device["type"] == "iphone"
    assert device["displayName"] == "iPhone-" + device["id"][:8].upper()
    assert request(token)[1]["deviceInfo"] == device
    assert request("wrong-token", "/v1/device")[0] == 401
    assert request(token, "/v1/device", "PATCH", {"displayName": ""})[0] == 422
    assert request(token, "/v1/device", "PATCH", {"displayName": " 书房手机 "}, extra_headers=browser) == (200, {**device, "displayName": "书房手机"})
    private_config = "/v1/private-network/config"
    legacy = {"provider": "tailscale", "relayHosts": ["Derp.Example.org."]}
    code, private = request(token, private_config, "PUT", legacy)
    assert code == 200 and private["configuration"]["relayMode"] == "strict"
    assert private["configuration"]["relayHosts"] == ["derp.example.org"]
    assert request(token, private_config, "PUT", {"provider": "tailscale"})[0] == 422
    follow = {"provider": "tailscale", "relayMode": "tailscaleDefault"}
    assert request(token, private_config, "PUT", {**follow, "relayHosts": ["derp.example.org"]})[0] == 422
    assert request(token, private_config, "PUT", {**follow, "provider": "headscale",
                                                 "controlURL": "https://head.example.org"})[0] == 422
    assert request(token, private_config, "PUT", {**follow, "relayMode": "invalid"})[0] == 400
    code, private = request(token, private_config, "PUT", follow)
    assert code == 200 and private["configuration"]["relayMode"] == "tailscaleDefault"
    assert private["configuration"]["relayHosts"] == []
    assert request(token, "/v1/private-network/join", "POST")[0] == 202
    vpn = launch("vpn")
    time.sleep(0.8)
    assert request(token)[1]["connected"] is False

    app.stdin.close()
    app.wait(timeout=4)
    wait_for(token, 200, True)
    assert request(token, private_config)[1]["configuration"]["relayMode"] == "tailscaleDefault"
    assert request(token, "/v1/private-network/state", "PUT", {"enabled": False})[1]["enabled"] is False
    assert request(token, "/v1/private-network/state", "PUT", {"enabled": True})[1]["enabled"] is True
    assert request(token, private_config, "PUT", legacy)[1]["configuration"]["relayMode"] == "strict"
    code, private = request(token, "/v1/private-network/membership", "DELETE")
    assert code == 200 and private.get("configuration") is None
    assert request(token, "/v1/discovery")[1]["enabled"] is False
    assert request(token, "/v1/discovery", "PATCH", {"enabled": True})[1]["enabled"] is True
    assert request("", "/")[0] == 200
    assert request(token, "/v1/device") == (200, {**device, "displayName": "书房手机"})
    assert request(token, "/v1/device", "PATCH", {"displayName": "备用手机"}) == (200, {**device, "displayName": "备用手机"})
    code, node = request(token, "/v1/nodes", "POST", {"link": "socks5://192.0.2.45:1080", "name": "Fixture"})
    assert code == 201
    assert request(token, "/v1/nodes/"+node["id"]+"/select", "POST")[1]["status"]["selectedNodeID"] == node["id"]
    assert request(token, "/v1/config", "PATCH", {"dnsServer":"dns.google"})[1]["dnsServer"] == "dns.google"
    code, dns = request(token, "/v1/config/dns")
    assert code == 200 and len(dns["servers"]) == 4
    dns["servers"].append({"id": "fixture-dns", "name": "Fixture DNS", "address": "https://dns.example.com/dns-query"})
    dns.update(mode="manual", selectedID="fixture-dns")
    assert request(token, "/v1/config/dns", "PUT", {"dnsSettings": dns}) == (200, dns)
    print("Single port passed from app process to VPN fixture process with same token and working API.")

    configure("disable")
    wait_for(token, 401)
    configure("enable")
    next_token = json.loads(file.read_text())["token"]
    assert next_token != token
    assert request(next_token)[0] == 401
    vpn.stdin.write("refresh\n")
    vpn.stdin.flush()
    wait_for(next_token, 200, True)
    wait_for(token, 401)

    app = launch("app")
    assert request(next_token)[1]["connected"] is True
    vpn.stdin.close()
    vpn.wait(timeout=4)
    wait_for(next_token, 200, False)
    assert request(next_token, "/v1/discovery")[1]["enabled"] is True
    assert request(next_token)[1]["deviceInfo"] == {**device, "displayName": "备用手机"}
    assert request(next_token, "/v1/nodes")[1][0]["id"] == node["id"]
    assert request(next_token, "/v1/config")[1]["dnsServer"] == "dns.google"
    assert request(next_token, "/v1/config/dns") == (200, dns)
    print("Token revocation and rotation passed. App reacquired port with edits persisted while app was stopped.")
