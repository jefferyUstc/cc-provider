"""Minimal stand-in for an Anthropic Messages API endpoint, used by tests/run.sh.

Usage: python3 tests/mock_anthropic.py LOGFILE
Binds 127.0.0.1 on a free port, prints the port on stdout, then serves forever.
Every request is appended to LOGFILE as one JSON line; every message gets "OK".
"""
import gzip
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _record(self, body):
        headers = {k.lower(): v for k, v in self.headers.items()}
        rec = {
            "method": self.command,
            "path": self.path,
            "authorization": headers.get("authorization"),
            "x_api_key": headers.get("x-api-key"),
            "test_headers": {k: v for k, v in headers.items() if k.startswith("x-test-")},
            "model": body.get("model"),
        }
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
        return rec

    def _send(self, code, ctype, payload):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._record({})
        self._send(404, "application/json", b"{}")

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if self.headers.get("content-encoding") == "gzip":
            raw = gzip.decompress(raw)
        body = json.loads(raw)
        self._record(body)
        if self.path.startswith("/v1/messages/count_tokens"):
            self._send(200, "application/json", json.dumps({"input_tokens": 1}).encode())
            return
        msg = {"id": "msg_mock", "type": "message", "role": "assistant", "model": body["model"],
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 1, "output_tokens": 1}}
        if not body.get("stream"):
            msg.update(content=[{"type": "text", "text": "OK"}], stop_reason="end_turn")
            self._send(200, "application/json", json.dumps(msg).encode())
            return
        events = [
            ("message_start", {"type": "message_start", "message": msg}),
            ("content_block_start", {"type": "content_block_start", "index": 0,
                                     "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                     "delta": {"type": "text_delta", "text": "OK"}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta",
                               "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                               "usage": {"output_tokens": 1}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        sse = "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events)
        self._send(200, "text/event-stream", sse.encode())


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
