import concurrent.futures
import json
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

from server import Handler, Relay


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.relay = Relay()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.relay = self.relay
        self.server.device_key = b"a" * 32
        self.server.mcp_key = b"b" * 32
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.pool = concurrent.futures.ThreadPoolExecutor()
        self.node_a = str(uuid.uuid4())
        self.node_b = str(uuid.uuid4())
        self.status = {"connected": True, "selectedNodeID": self.node_a, "nodes": [
            {"id": self.node_a, "name": "First", "endpoint": "private"},
            {"id": self.node_b, "name": "Second"},
        ]}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.pool.shutdown()

    def post(self, path, data, key, **headers):
        url = f"http://127.0.0.1:{self.server.server_port}{path}"
        request = urllib.request.Request(url, data=json.dumps(data).encode(), headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key.decode(),
            **headers,
        })
        try:
            response = urllib.request.urlopen(request, timeout=24)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def mcp(self, method, params):
        code, body = self.post("/mcp", {"jsonrpc": "2.0", "id": 7, "method": method, "params": params},
                               self.server.mcp_key, **{"MCP-Protocol-Version": "2025-11-25"})
        self.assertEqual(code, 200)
        return body["result"]

    def test_tool_listing_auth_and_unsupported_origins(self):
        initialized = self.mcp("initialize", {"protocolVersion": "2025-11-25"})
        self.assertEqual(initialized["protocolVersion"], "2025-11-25")
        self.assertEqual(len(self.mcp("tools/list", {})["tools"]), 3)
        self.assertEqual(self.post("/mcp", {}, self.server.device_key)[0], 401)
        self.assertEqual(self.post("/device/exchange", {}, self.server.mcp_key)[0], 401)
        self.assertEqual(self.post("/mcp", {}, self.server.mcp_key, Origin="https://example.test")[0], 403)

    def test_switch_requires_device_ack_and_live_readback(self):
        pending_device = self.pool.submit(self.post, "/device/exchange", {"status": self.status},
                                          self.server.device_key)
        with self.relay.condition:
            self.assertTrue(self.relay.condition.wait_for(lambda: self.relay.polling, timeout=2))
        status = self.mcp("tools/call", {"name": "byway_status", "arguments": {}})["structuredContent"]
        self.assertEqual(status["selectedNodeID"], self.node_a)
        self.assertNotIn("endpoint", status["nodes"][0])

        pending_mcp = self.pool.submit(self.mcp, "tools/call", {
            "name": "byway_select", "arguments": {"node_id": self.node_b},
        })
        code, delivery = pending_device.result(timeout=3)
        self.assertEqual(code, 200)
        self.assertEqual(delivery["command"]["nodeID"], self.node_b)
        self.assertFalse(pending_mcp.done())

        switched = {**self.status, "selectedNodeID": self.node_b}
        command_id = delivery["command"]["id"]
        completion = {"id": command_id, "status": switched,
                      "probe": {"latencyMS": 128, "exitIP": "203.0.113.20"}}
        code, ack = self.post("/device/exchange", {"status": switched, "completion": completion},
                              self.server.device_key)
        self.assertEqual((code, ack["acknowledged"]), (200, command_id))
        result = pending_mcp.result(timeout=3)
        self.assertFalse(result["isError"])
        self.assertEqual(result["structuredContent"]["status"]["selectedNodeID"], self.node_b)
        self.assertEqual(result["structuredContent"]["probe"]["latencyMS"], 128)

    def test_stale_device_cannot_be_controlled(self):
        with self.relay.condition:
            self.relay.device = self.status
            self.relay.last_seen = time.monotonic() - 60
        result = self.mcp("tools/call", {"name": "byway_probe", "arguments": {"node_id": self.node_b}})
        self.assertTrue(result["isError"])
        self.assertIn("connected", result["structuredContent"]["error"])


if __name__ == "__main__":
    unittest.main()
