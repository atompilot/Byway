#!/usr/bin/env python3
"""Byway control relay and stateless MCP server for one paired device."""

import argparse
import hmac
import ipaddress
import json
import os
import re
import ssl
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26")
TOKEN_PATTERN = re.compile(r"[!-~]{32,128}")
HEARTBEAT_SECONDS = 40
POLL_SECONDS = 15
COMMAND_SECONDS = 22
MAX_REQUEST_BYTES = 32_768

NODE_INPUT = {
    "type": "object",
    "properties": {"node_id": {"type": "string", "format": "uuid"}},
    "required": ["node_id"],
    "additionalProperties": False,
}
TOOLS = [
    {
        "name": "byway_status",
        "description": "Read the last reported iPhone connection, available nodes and selected node.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "byway_probe",
        "description": "Test HTTPS through one node on the iPhone and return latency and observed egress IP.",
        "inputSchema": NODE_INPUT,
        "annotations": {"readOnlyHint": True, "openWorldHint": True},
    },
    {
        "name": "byway_select",
        "description": "Test a node on the iPhone, make it active if reachable, then read back the active node.",
        "inputSchema": NODE_INPUT,
        "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True},
    },
]


def node_id(value):
    if not isinstance(value, str):
        raise ValueError("Expected a UUID")
    return str(uuid.UUID(value))


def clean_status(value):
    connected, nodes = value["connected"], value["nodes"]
    if type(connected) is not bool or not isinstance(nodes, list) or len(nodes) > 32:
        raise ValueError("Invalid device status")
    nodes = [{"id": node_id(node["id"]), "name": str(node["name"])[:80]} for node in nodes]
    selected = value.get("selectedNodeID")
    selected = node_id(selected) if selected else None
    if selected is not None and not any(item["id"] == selected for item in nodes):
        raise ValueError("Unknown selected node")
    return {"connected": connected, "selectedNodeID": selected, "nodes": nodes}


def clean_completion(value):
    probe = value.get("probe")
    error = value.get("error")
    if error is not None and not isinstance(error, str):
        raise ValueError("Invalid command error")
    if probe is not None:
        latency = probe["latencyMS"]
        if type(latency) is not int or not 0 <= latency <= 60_000:
            raise ValueError("Invalid latency")
        probe = {"latencyMS": latency, "exitIP": str(ipaddress.ip_address(probe["exitIP"]))}
    return {
        "id": node_id(value["id"]),
        "status": clean_status(value["status"]),
        "probe": probe,
        "error": error[:200] if error else None,
    }


@dataclass
class Job:
    id: str
    operation: str
    node: str
    deadline: float
    expires_at: float
    result: dict | None = None

    def message(self):
        return {
            "id": self.id, "operation": self.operation,
            "nodeID": self.node, "expiresAt": self.expires_at,
        }


class Relay:
    def __init__(self):
        self.condition = threading.Condition()
        self.device = None
        self.last_seen = None
        self.job = None
        self.polling = False

    def status(self):
        with self.condition:
            return self._status()

    def _status(self):
        age = None if self.last_seen is None else time.monotonic() - self.last_seen
        online = age is not None and age < HEARTBEAT_SECONDS
        device = self.device or {}
        return {
            "online": online,
            "connected": online and device.get("connected", False),
            "ageSeconds": None if age is None else int(age),
            "selectedNodeID": device.get("selectedNodeID") if online else None,
            "nodes": device.get("nodes", []),
        }

    def invoke(self, operation, node):
        with self.condition:
            status = self._status()
            if not status["connected"]:
                raise RuntimeError("Byway has not reported a connected tunnel.")
            if not any(item["id"] == node for item in status["nodes"]):
                raise RuntimeError("Node ID is absent from the latest device status.")
            if self.job:
                raise RuntimeError("Another device command is in progress.")
            job = Job(str(uuid.uuid4()), operation, node, time.monotonic() + COMMAND_SECONDS,
                      time.time() + COMMAND_SECONDS)
            self.job = job
            self.condition.notify_all()
            try:
                self.condition.wait_for(lambda: job.result is not None,
                                        timeout=max(0, job.deadline - time.monotonic()))
                if job.result is None:
                    raise RuntimeError("No device result before the deadline. Read status before retrying.")
                return job.result
            finally:
                self.job = None
                self.condition.notify_all()

    def exchange(self, status, completion):
        with self.condition:
            if self.polling:
                raise RuntimeError("A device poll is already active.")
            self.polling = True
            try:
                return self._exchange(status, completion)
            finally:
                self.polling = False
                self.condition.notify_all()

    def _exchange(self, status, completion):
        self.device = status
        self.last_seen = time.monotonic()
        acknowledged = None
        if completion:
            command_id = completion["id"]
            # Retrying the same delivery after a lost HTTP response leaves the result intact.
            if self.job and self.job.id == command_id and self.job.result is None:
                if self.job.operation == "select" and not completion["error"]:
                    if completion["status"]["selectedNodeID"] != self.job.node:
                        completion["error"] = "Device did not confirm the selected node."
                self.job.result = completion
                self.condition.notify_all()
            acknowledged = command_id
        if not status["connected"]:
            if self.job and self.job.result is None:
                self.job.result = {"id": self.job.id, "status": status, "probe": None,
                                   "error": "The tunnel disconnected."}
                self.condition.notify_all()
            return {"command": None, "acknowledged": acknowledged}
        # Deliver acknowledgements promptly. The device holds the completion until it sees this.
        if acknowledged:
            return {"command": None, "acknowledged": acknowledged}
        self.condition.wait_for(lambda: self.job is not None and self.job.result is None,
                                timeout=POLL_SECONDS)
        job = self.job
        if job and job.result is None and time.monotonic() < job.deadline:
            return {"command": job.message(), "acknowledged": None}
        return {"command": None, "acknowledged": None}


def reply_result(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def reply_error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def tool_result(payload, failed=False):
    return {
        "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}],
        "structuredContent": payload,
        "isError": failed,
    }


def mcp(relay, request):
    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
        return reply_error(None, -32600, "Invalid Request")
    if "id" not in request:
        return None
    request_id = request["id"]
    method = request.get("method")
    params = request.get("params", {})
    if not isinstance(params, dict):
        return reply_error(request_id, -32602, "Invalid params")
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in PROTOCOLS else PROTOCOLS[0]
        return reply_result(request_id, {
            "protocolVersion": version, "capabilities": {"tools": {}},
            "serverInfo": {"name": "byway", "version": "0.1.0"},
        })
    if method == "ping":
        return reply_result(request_id, {})
    if method == "tools/list":
        return reply_result(request_id, {"tools": TOOLS})
    if method != "tools/call":
        return reply_error(request_id, -32601, "Method not found")
    name = params.get("name")
    args = params.get("arguments", {})
    try:
        if name == "byway_status" and args == {}:
            result = tool_result(relay.status())
        elif name in ("byway_probe", "byway_select") and isinstance(args, dict) and set(args) == {"node_id"}:
            operation = "probe" if name == "byway_probe" else "select"
            output = relay.invoke(operation, node_id(args["node_id"]))
            result = tool_result(output, bool(output.get("error")))
        else:
            return reply_error(request_id, -32602, "Unknown tool or invalid arguments")
    except ValueError:
        return reply_error(request_id, -32602, "Invalid node ID")
    except RuntimeError as error:
        result = tool_result({"error": str(error)}, failed=True)
    return reply_result(request_id, result)


class Handler(BaseHTTPRequestHandler):
    server_version = "Byway"
    sys_version = ""
    timeout = 30

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"ok": True})
        else:
            self.send_json(405, {"error": "POST required"}, allow="POST")

    def do_DELETE(self):
        self.send_json(405, {"error": "POST required"}, allow="POST")

    def do_POST(self):
        if self.path not in ("/mcp", "/device/exchange"):
            self.send_json(404, {"error": "Unknown path"})
            return
        if self.headers.get("Origin") is not None:
            self.send_json(403, {"error": "Browser origins are not accepted"})
            return
        is_device = self.path == "/device/exchange"
        key = self.server.device_key if is_device else self.server.mcp_key
        given = self.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(given, b"Bearer " + key):
            self.send_json(401, {"error": "Invalid token"})
            return
        try:
            if self.headers.get_content_type() != "application/json":
                self.send_json(415, {"error": "Expected application/json"})
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= MAX_REQUEST_BYTES:
                self.send_json(413, {"error": "Invalid body size"})
                return
            data = json.loads(self.rfile.read(size))
            if is_device:
                status = clean_status(data["status"])
                completion = clean_completion(data["completion"]) if data.get("completion") else None
                self.send_json(200, self.server.relay.exchange(status, completion))
            else:
                version = self.headers.get("MCP-Protocol-Version")
                if version is not None and version not in PROTOCOLS:
                    self.send_json(400, {"error": "Unsupported MCP protocol version"})
                    return
                result = mcp(self.server.relay, data)
                self.send_json(202 if result is None else 200, result)
        except (ValueError, EOFError, KeyError, TypeError, AttributeError):
            self.send_json(400, {"error": "Invalid request body"})
        except RuntimeError as error:
            self.send_json(409, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            return

    def send_json(self, status, value, allow=None):
        data = b"" if value is None else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


def setup(args):
    tokens = [os.environ.get(name, "") for name in ("BYWAY_DEVICE_KEY", "BYWAY_MCP_KEY")]
    if any(not TOKEN_PATTERN.fullmatch(key) for key in tokens) or tokens[0] == tokens[1]:
        raise ValueError("Set different BYWAY_DEVICE_KEY and BYWAY_MCP_KEY values (32–128 printable characters).")
    if bool(args.cert) != bool(args.key):
        raise ValueError("--cert and --key must be provided together.")
    if not args.cert and args.host not in ("127.0.0.1", "localhost"):
        raise ValueError("Use TLS for a non-loopback address.")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.device_key, server.mcp_key = [key.encode() for key in tokens]
    server.relay = Relay()
    if args.cert:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(args.cert, args.key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--cert", help="PEM certificate chain for HTTPS")
    parser.add_argument("--key", help="PEM private key for HTTPS")
    args = parser.parse_args()
    try:
        with setup(args) as server:
            print(f"Byway control ready on {args.host}:{server.server_port}", flush=True)
            server.serve_forever()
    except (ValueError, OSError) as error:
        parser.exit(2, f"{error}\n")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
