"""Deterministic stand-in for a Jev-compatible API, for tests (no API key, no network).

  noul   0.9 if any word (4+ letters) of the condition appears in the row, else 0.1
  choice the first option that appears in the row text, else the first option
  score  the middle level
Usage: python3 test/mock_jev.py [port]   (default 8788; listens on all interfaces)
"""

import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def answer(state, q):
    m = re.search(r"rows\[(\d+)\]", q.get("instructions", ""))
    row = state["rows"][int(m.group(1))] if m else state
    text = json.dumps(row).lower()
    if q["type"] == "noul":
        words = [w for w in re.findall(r"[a-z]{4,}", state.get("condition", "").lower())]
        return {"type": "noul", "noul": 0.9 if any(w in text for w in words) else 0.1}
    if q["type"] == "choice":
        opts = list(q["criteria"])
        pick = next((o for o in opts if o.lower() in text), opts[0])
        probs = {o: (0.8 if o == pick else round(0.2 / max(len(opts) - 1, 1), 4)) for o in opts}
        return {"type": "choice", "choice": pick, "confidence": 0.8, "probabilities": probs}
    levels = q["criteria"]
    mid = (len(levels) - 1) / 2
    return {"type": "score", "score": mid, "legend": {str(i): l for i, l in enumerate(levels)},
            "probabilities": {str(i): (1.0 if i == round(mid) else 0.0) for i in range(len(levels))}, "confidence": 1.0}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw)
            out = {"model": "mock-jev", "answers": {n: answer(body["state"], q) for n, q in body["questions"].items()},
                   "usage": {"input_tokens": len(raw) // 4, "output_tokens": 0}}
            code = 200
        except Exception as e:
            out, code = {"error": {"type": "bad_request", "message": f"mock: {e}"}}, 400
        data = json.dumps(out).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8788
    print(f"mock Jev API on :{port}/v1/systemone", flush=True)
    HTTPServer(("0.0.0.0", port), H).serve_forever()
