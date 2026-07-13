from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).parent / "asterisk" / "notify_gateway.py"


class Handler(BaseHTTPRequestHandler):
    requests: list[dict[str, object]] = []
    status = 200

    def do_POST(self) -> None:  # noqa: N802
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.__class__.requests.append(
            {"path": self.path, "authorization": self.headers.get("Authorization"), "json": json.loads(body)}
        )
        self.send_response(self.__class__.status)
        self.end_headers()
        self.wfile.write(b'{}')

    def log_message(self, format: str, *args: object) -> None:
        pass


class AsteriskAGITest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self) -> None:
        Handler.requests.clear()
        Handler.status = 200

    def run_agi(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "CRM_SIP_GATEWAY_URL": f"http://127.0.0.1:{self.server.server_port}",
                "CRM_SIP_GATEWAY_SECRET": "gateway-secret",
            }
        )
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            input="agi_uniqueid: ignored-by-script\n\n",
            text=True,
            capture_output=True,
            env=env,
            timeout=10,
            check=False,
        )

    def test_valid_call_notifies_gateway(self) -> None:
        result = self.run_agi("broker-1", "asterisk-171.4", "+370 (600) 00-000")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            {
                "path": "/v1/incoming",
                "authorization": "Bearer gateway-secret",
                "json": {
                    "broker_id": "broker-1",
                    "call_id": "asterisk-171.4",
                    "caller_number": "+37060000000",
                },
            },
            Handler.requests[0],
        )
        self.assertIn("PushKit notification accepted", result.stdout)

    def test_invalid_call_id_is_rejected_without_http_request(self) -> None:
        result = self.run_agi("broker-1", "bad/call/id", "+37060000000")
        self.assertEqual(1, result.returncode)
        self.assertEqual([], Handler.requests)

    def test_gateway_failure_is_reported_to_asterisk(self) -> None:
        Handler.status = 503
        result = self.run_agi("broker-1", "asterisk-171.5", "+37060000000")
        self.assertEqual(1, result.returncode)
        self.assertIn("gateway request failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
