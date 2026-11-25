"""Minimal MCP stdio client for the Roblox Studio MCP server.

Usage:
  python mcp_call.py --list
  python mcp_call.py TOOL [--args JSON] [--code-file FILE] [--out DIR] [--max N]

Each run starts the server, performs the MCP handshake, makes one call and exits.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import threading
import time

SERVER = ["cmd.exe", "/c", os.path.expandvars(r"%LOCALAPPDATA%\Roblox\mcp.bat")]


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(
            SERVER, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
        )
        self.next_id = 0
        self.responses = {}
        self.cond = threading.Condition()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "id" in msg and ("result" in msg or "error" in msg):
                with self.cond:
                    self.responses[msg["id"]] = msg
                    self.cond.notify_all()

    def send(self, payload):
        self.proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=300):
        self.next_id += 1
        rid = self.next_id
        payload = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            payload["params"] = params
        self.send(payload)
        deadline = time.time() + timeout
        with self.cond:
            while rid not in self.responses:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise TimeoutError(f"{method} timed out after {timeout}s")
                self.cond.wait(remaining)
            return self.responses.pop(rid)

    def handshake(self):
        self.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "mcp-cli", "version": "1.0"},
            },
            timeout=60,
        )
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool", nargs="?")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--args", default="{}")
    parser.add_argument("--code-file")
    parser.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--max", type=int, default=6000)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--delay", type=float, default=0)
    opts = parser.parse_args()

    client = Client()
    try:
        client.handshake()
        if opts.delay:
            time.sleep(opts.delay)
        # Studio registers with the server a few seconds after it starts; wait for it.
        if not opts.list and opts.tool != "list_roblox_studios":
            for _ in range(30):
                listing = client.request("tools/call", {"name": "list_roblox_studios", "arguments": {}}, timeout=30)
                text = "".join(i.get("text", "") for i in listing.get("result", {}).get("content", []))
                if '"id"' in text:
                    break
                time.sleep(1)
        if opts.list:
            result = client.request("tools/list")
            for tool in result["result"]["tools"]:
                print(tool["name"])
            return 0

        arguments = json.loads(opts.args)
        if opts.code_file:
            with open(opts.code_file, encoding="utf-8") as handle:
                arguments["code"] = handle.read()
        response = client.request(
            "tools/call", {"name": opts.tool, "arguments": arguments}, timeout=opts.timeout
        )
        if "error" in response:
            print("RPC ERROR:", json.dumps(response["error"])[: opts.max])
            return 1
        result = response["result"]
        if result.get("isError"):
            print("TOOL ERROR")
        for index, item in enumerate(result.get("content", [])):
            if item.get("type") == "text":
                text = item["text"]
                sys.stdout.buffer.write(text[: opts.max].encode("utf-8", errors="replace") + b"\n")
                if len(text) > opts.max:
                    print(f"... [truncated {len(text) - opts.max} chars]")
            elif item.get("type") == "image":
                ext = (item.get("mimeType") or "image/png").split("/")[-1]
                path = os.path.join(opts.out, f"{opts.tool}_{int(time.time())}_{index}.{ext}")
                with open(path, "wb") as handle:
                    handle.write(base64.b64decode(item["data"]))
                print("IMAGE:", path)
            else:
                print("CONTENT:", json.dumps(item)[:500])
        return 1 if result.get("isError") else 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
