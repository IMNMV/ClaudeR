#!/usr/bin/env python3
"""CI smoke test: real MCP stdio handshake against the installed bridge.

Drives the server as a subprocess and keeps stdin open until both
responses have been read. Piping a fixed byte-blob in and closing stdin
immediately races the server's shutdown-on-EOF against its handling of
the final request, which fails intermittently on slow runners.
"""

import json
import subprocess
import sys

SERVER = sys.argv[1] if len(sys.argv) > 1 else "smoke/bin/clauder-mcp"

proc = subprocess.Popen(
    [SERVER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
)


def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def recv(want_id):
    while True:
        line = proc.stdout.readline()
        if not line:
            sys.exit(f"server closed stdout while waiting for id {want_id}")
        msg = json.loads(line)
        if msg.get("id") == want_id:
            return msg


try:
    send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "ci", "version": "0"},
        },
    })
    r1 = recv(1)
    assert r1["result"]["serverInfo"]["name"] == "r-studio", r1

    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    r2 = recv(2)
    tools = r2["result"]["tools"]
    assert len(tools) >= 25, f"expected >= 25 tools, got {len(tools)}"
    print(f"handshake OK, {len(tools)} tools")
finally:
    proc.stdin.close()
    proc.terminate()
    proc.wait(timeout=10)
