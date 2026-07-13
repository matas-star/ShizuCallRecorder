from __future__ import annotations

import os
import base64
import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature


def private_key() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


BOOT_DIR = tempfile.TemporaryDirectory()
os.environ.update(
    {
        "SIP_GATEWAY_DATABASE_PATH": str(Path(BOOT_DIR.name) / "boot.sqlite3"),
        "SIP_GATEWAY_INTERNAL_SECRET": "test-internal-secret-32-bytes-long",
        "SIP_GATEWAY_BASE44_URL": "https://crm.example",
        "SIP_GATEWAY_BASE44_SERVICE_TOKEN": "base44-service",
        "SIP_GATEWAY_APNS_TEAM_ID": "TEAM123456",
        "SIP_GATEWAY_APNS_KEY_ID": "KEY1234567",
        "SIP_GATEWAY_APNS_PRIVATE_KEY": private_key(),
    }
)

from distribution.sip_gateway.app import (  # noqa: E402
    DeviceRegistration,
    Gateway,
    IncomingCall,
    Settings,
    create_app,
)


class GatewayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.requests: list[httpx.Request] = []
        self.apns_status = 200

        async def handler(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            if request.url.host == "crm.example":
                return httpx.Response(200, json={"event_id": "event-123"})
            return httpx.Response(self.apns_status, json={} if self.apns_status == 200 else {"reason": "Rejected"})

        self.outbound = httpx.AsyncClient(transport=httpx.MockTransport(handler), http2=True)
        self.settings = Settings(
            database_path=Path(self.temp.name) / "gateway.sqlite3",
            internal_secret="test-internal-secret-32-bytes-long",
            base44_url="https://crm.example",
            base44_service_token="base44-service",
            apns_team_id="TEAM123456",
            apns_key_id="KEY1234567",
            apns_private_key=private_key(),
            apns_topic="lt.crmphone.agent.voip",
            apns_environment="sandbox",
        )
        self.gateway = Gateway(self.settings, self.outbound)
        self.gateway.register(DeviceRegistration(broker_id="broker-1", push_token="ab" * 32))

    async def asyncTearDown(self) -> None:
        await self.outbound.aclose()
        self.temp.cleanup()

    async def test_incoming_prepares_crm_and_sends_voip_push_once(self) -> None:
        call = IncomingCall(broker_id="broker-1", call_id="tele2-call-1", caller_number="+37060000000")
        first = await self.gateway.incoming(call)
        second = await self.gateway.incoming(call)

        self.assertEqual("event-123", first["event_id"])
        self.assertFalse(first["duplicate"])
        self.assertTrue(second["duplicate"])
        self.assertEqual(2, len(self.requests))
        crm_payload = json.loads(self.requests[0].content)
        self.assertEqual("tele2-call-1", crm_payload["gateway_call_id"])
        apns = self.requests[1]
        self.assertEqual("voip", apns.headers["apns-push-type"])
        self.assertEqual("lt.crmphone.agent.voip", apns.headers["apns-topic"])
        payload = __import__("json").loads(apns.content)
        self.assertEqual("tele2-call-1", payload["metadata"]["call_id"])
        self.assertEqual("event-123", payload["metadata"]["event_id"])

    async def test_apns_failure_releases_call_for_retry(self) -> None:
        call = IncomingCall(broker_id="broker-1", call_id="tele2-call-2", caller_number="+37060000001")
        self.apns_status = 410
        with self.assertRaises(Exception):
            await self.gateway.incoming(call)
        self.apns_status = 200
        result = await self.gateway.incoming(call)
        self.assertFalse(result["duplicate"])
        self.assertEqual(4, len(self.requests))

    async def test_http_endpoints_require_internal_bearer(self) -> None:
        app = create_app(self.settings, self.outbound)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gateway") as client:
            denied = await client.post("/v1/devices", json={"broker_id": "b", "push_token": "cd" * 32})
            allowed = await client.post(
                "/v1/devices",
                headers={"Authorization": f"Bearer {self.settings.internal_secret}"},
                json={"broker_id": "b", "push_token": "cd" * 32},
            )
        self.assertEqual(401, denied.status_code)
        self.assertEqual(200, allowed.status_code)

    async def test_apns_jwt_has_valid_es256_signature(self) -> None:
        token = self.gateway.apns_jwt()
        encoded_header, encoded_claims, encoded_signature = token.split(".")
        raw = base64.urlsafe_b64decode(encoded_signature + "==")
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        private = serialization.load_pem_private_key(self.settings.apns_private_key.encode(), password=None)
        private.public_key().verify(
            der,
            f"{encoded_header}.{encoded_claims}".encode(),
            ec.ECDSA(hashes.SHA256()),
        )

    async def test_existing_database_is_migrated(self) -> None:
        path = Path(self.temp.name) / "old.sqlite3"
        with closing(sqlite3.connect(path)) as connection:
            connection.execute(
                "CREATE TABLE incoming_calls(call_id TEXT PRIMARY KEY, broker_id TEXT NOT NULL, event_id TEXT)"
            )
            connection.commit()
        settings = self.settings.model_copy(update={"database_path": path})
        Gateway(settings, self.outbound)
        with closing(sqlite3.connect(path)) as connection:
            columns = {row[1] for row in connection.execute("PRAGMA table_info(incoming_calls)")}
        self.assertTrue({"claimed_at", "pushed_at"}.issubset(columns))


if __name__ == "__main__":
    unittest.main()
