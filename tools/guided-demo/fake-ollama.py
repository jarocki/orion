#!/usr/bin/env python3
"""Stand-in for the ollama HTTP API used ONLY to render the Nebula UI state of the
reference deck inside the demo recording container (no model runs here)."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
MODEL = {"name": "qwen2.5:3b-instruct-q4_K_M", "model": "qwen2.5:3b-instruct-q4_K_M",
         "size": 1929903264, "digest": "fb8a8b68d419c3a22f70436796ca5eb38b4f49bd787c4683ffb613aa771957d9",
         "details": {"family": "qwen2", "parameter_size": "3.1B", "quantization_level": "Q4_K_M"}}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _j(self, o, code=200):
        b = json.dumps(o).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/api/tags"): return self._j({"models": [MODEL]})
        if self.path.startswith("/api/version"): return self._j({"version": "0.12.6"})
        if self.path.startswith("/api/ps"): return self._j({"models": []})
        if self.path == "/": 
            self.send_response(200); self.end_headers(); self.wfile.write(b"Ollama is running"); return
        self._j({"error": "not found"}, 404)
    def do_POST(self): self._j({"error": "demo stand-in: no inference"}, 501)
HTTPServer(("127.0.0.1", 11434), H).serve_forever()
