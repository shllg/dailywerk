#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def resolve_secret():
    inline_secret = os.environ.get("DEPLOY_WEBHOOK_SECRET", "").strip()
    if inline_secret:
        return inline_secret

    op_path = os.environ.get("DEPLOY_WEBHOOK_SECRET_OP_PATH", "").strip()
    if not op_path:
        raise RuntimeError("DEPLOY_WEBHOOK_SECRET or DEPLOY_WEBHOOK_SECRET_OP_PATH is required")

    return subprocess.check_output(["op", "read", op_path], text=True).strip()


DEPLOY_SECRET = resolve_secret().encode("utf-8")


class DeployListenerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/up", "/ready"):
            self.send_error(404, "Not Found")
            return

        self._send_json(200, {"status": "ok"})

    def do_POST(self):
        if self.path != "/deploy":
            self.send_error(404, "Not Found")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        signature = self.headers.get("X-DailyWerk-Signature", "")
        expected_signature = f"sha256={hmac.new(DEPLOY_SECRET, body, hashlib.sha256).hexdigest()}"

        if not hmac.compare_digest(signature, expected_signature):
          self._send_json(401, {"error": "invalid signature"})
          return

        try:
            json.loads(body)
        except json.JSONDecodeError as error:
            self._send_json(400, {"error": f"invalid JSON payload: {error}"})
            return

        payload_file = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        try:
            payload_file.write(body)
            payload_file.flush()
            payload_file.close()

            with open(os.environ.get("DEPLOY_LISTENER_LOG", "/tmp/deploy-listener.log"), "ab") as log_file:
                subprocess.Popen(
                    ["/deploy/scripts/perform-deploy.sh", payload_file.name],
                    stdout=log_file,
                    stderr=log_file,
                    start_new_session=True,
                )
        except Exception as error:
            self._send_json(500, {"error": str(error)})
            return

        self._send_json(202, {"status": "accepted"})

    def log_message(self, format, *args):
        return

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    host = os.environ.get("DEPLOY_LISTENER_HOST", "0.0.0.0")
    port = int(os.environ.get("DEPLOY_LISTENER_PORT", "8081"))
    server = ThreadingHTTPServer((host, port), DeployListenerHandler)
    server.serve_forever()
