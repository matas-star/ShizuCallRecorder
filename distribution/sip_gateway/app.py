from __future__ import annotations

import base64
import hmac
import json
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from fastapi import Depends, FastAPI, Header, HTTPException, status
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SIP_GATEWAY_", env_file=".env")

    database_path: Path = Path("/data/sip-gateway.sqlite3")
    internal_secret: str
    base44_url: str
    base44_service_token: str
    apns_team_id: str
    apns_key_id: str
    apns_private_key: str
    apns_topic: str = "lt.crmphone.agent.voip"
    apns_environment: str = "sandbox"

    @property
    def apns_base_url(self) -> str:
        return "https://api.sandbox.push.apple.com" if self.apns_environment == "sandbox" else "https://api.push.apple.com"


class DeviceRegistration(BaseModel):
    broker_id: str = Field(min_length=1, max_length=128)
    push_token: str = Field(pattern=r"^[0-9a-fA-F]{32,256}$")


class IncomingCall(BaseModel):
    broker_id: str = Field(min_length=1, max_length=128)
    call_id: str = Field(min_length=1, max_length=128)
    caller_number: str = Field(min_length=3, max_length=64)


class Gateway:
    def __init__(self, settings: Settings, client: httpx.AsyncClient | None = None):
        self.settings = settings
        self.client = client or httpx.AsyncClient(http2=True, timeout=10)
        self._jwt: tuple[str, int] | None = None
        settings.database_path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self.db()) as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS devices (
                    broker_id TEXT PRIMARY KEY,
                    push_token TEXT NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS incoming_calls (
                    call_id TEXT PRIMARY KEY,
                    broker_id TEXT NOT NULL,
                    event_id TEXT,
                    claimed_at INTEGER,
                    pushed_at INTEGER
                );
                """
            )
            columns = {row[1] for row in connection.execute("PRAGMA table_info(incoming_calls)")}
            if "claimed_at" not in columns:
                connection.execute("ALTER TABLE incoming_calls ADD COLUMN claimed_at INTEGER")
            if "pushed_at" not in columns:
                connection.execute("ALTER TABLE incoming_calls ADD COLUMN pushed_at INTEGER")
            connection.commit()

    def db(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.settings.database_path)
        connection.row_factory = sqlite3.Row
        return connection

    def register(self, registration: DeviceRegistration) -> None:
        with closing(self.db()) as connection:
            connection.execute(
                """INSERT INTO devices(broker_id, push_token, updated_at) VALUES(?, ?, ?)
                   ON CONFLICT(broker_id) DO UPDATE SET push_token=excluded.push_token,
                   updated_at=excluded.updated_at""",
                (registration.broker_id, registration.push_token.lower(), int(time.time())),
            )
            connection.commit()

    async def incoming(self, call: IncomingCall) -> dict[str, Any]:
        with closing(self.db()) as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT event_id, claimed_at, pushed_at FROM incoming_calls WHERE call_id=?", (call.call_id,)
            ).fetchone()
            if existing and existing["pushed_at"]:
                return {"ok": True, "duplicate": True, "event_id": existing["event_id"]}
            now = int(time.time())
            if existing and existing["claimed_at"] and now - existing["claimed_at"] < 30:
                return {"ok": True, "duplicate": True, "in_progress": True, "event_id": existing["event_id"]}
            token_row = connection.execute(
                "SELECT push_token FROM devices WHERE broker_id=?", (call.broker_id,)
            ).fetchone()
            if not token_row:
                raise HTTPException(status_code=404, detail="No PushKit device for broker")
            connection.execute(
                """INSERT INTO incoming_calls(call_id, broker_id, claimed_at) VALUES(?, ?, ?)
                   ON CONFLICT(call_id) DO UPDATE SET claimed_at=excluded.claimed_at""",
                (call.call_id, call.broker_id, now),
            )
            connection.commit()

        try:
            event_id = await self.prepare_base44(call)
            await self.send_apns(token_row["push_token"], call, event_id)
        except Exception:
            with closing(self.db()) as connection:
                connection.execute("UPDATE incoming_calls SET claimed_at=NULL WHERE call_id=?", (call.call_id,))
                connection.commit()
            raise
        with closing(self.db()) as connection:
            connection.execute(
                "UPDATE incoming_calls SET event_id=?, pushed_at=? WHERE call_id=?",
                (event_id, int(time.time()), call.call_id),
            )
            connection.commit()
        return {"ok": True, "duplicate": False, "event_id": event_id}

    async def prepare_base44(self, call: IncomingCall) -> str:
        url = self.settings.base44_url.rstrip("/") + "/functions/prepareIosIncomingCall"
        response = await self.client.post(
            url,
            headers={"Authorization": f"Bearer {self.settings.base44_service_token}"},
            json={
                "broker_id": call.broker_id,
                "provider": "tele2_mobile_station_sip",
                "gateway_call_id": call.call_id,
                "caller_number": call.caller_number,
            },
        )
        response.raise_for_status()
        event_id = response.json().get("event_id")
        if not isinstance(event_id, str) or not event_id:
            raise HTTPException(status_code=502, detail="Base44 did not return event_id")
        return event_id

    async def send_apns(self, push_token: str, call: IncomingCall, event_id: str) -> None:
        response = await self.client.post(
            f"{self.settings.apns_base_url}/3/device/{push_token}",
            headers={
                "authorization": f"bearer {self.apns_jwt()}",
                "apns-push-type": "voip",
                "apns-topic": self.settings.apns_topic,
                "apns-priority": "10",
                "apns-expiration": "0",
                "apns-collapse-id": call.call_id[:64],
            },
            json={
                "aps": {"content-available": 1},
                "metadata": {
                    "provider": "tele2_mobile_station_sip",
                    "call_id": call.call_id,
                    "event_id": event_id,
                    "caller_number": call.caller_number,
                },
            },
        )
        if response.status_code != 200:
            reason = response.text[:256]
            raise HTTPException(status_code=502, detail=f"APNs rejected VoIP push: {reason}")

    def apns_jwt(self) -> str:
        now = int(time.time())
        if self._jwt and now - self._jwt[1] < 50 * 60:
            return self._jwt[0]
        header = self.b64url({"alg": "ES256", "kid": self.settings.apns_key_id})
        claims = self.b64url({"iss": self.settings.apns_team_id, "iat": now})
        signing_input = f"{header}.{claims}".encode()
        key_text = self.settings.apns_private_key.replace("\\n", "\n").encode()
        key = serialization.load_pem_private_key(key_text, password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            raise ValueError("APNs key is not an EC private key")
        der_signature = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der_signature)
        signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        token = f"{header}.{claims}.{base64.urlsafe_b64encode(signature).rstrip(b'=').decode()}"
        self._jwt = (token, now)
        return token

    @staticmethod
    def b64url(value: dict[str, Any]) -> str:
        raw = json.dumps(value, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def create_app(settings: Settings | None = None, client: httpx.AsyncClient | None = None) -> FastAPI:
    config = settings or Settings()  # type: ignore[call-arg]
    gateway = Gateway(config, client)
    app = FastAPI(title="CRM Phone SIP Push Gateway", docs_url=None, redoc_url=None)

    def authenticate(authorization: str = Header(default="")) -> None:
        if not hmac.compare_digest(authorization, f"Bearer {config.internal_secret}"):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Unauthorized")

    @app.get("/health")
    async def health() -> dict[str, bool]:
        return {"ok": True}

    @app.post("/v1/devices", dependencies=[Depends(authenticate)])
    async def register_device(body: DeviceRegistration) -> dict[str, bool]:
        gateway.register(body)
        return {"ok": True}

    @app.post("/v1/incoming", dependencies=[Depends(authenticate)])
    async def incoming_call(body: IncomingCall) -> dict[str, Any]:
        return await gateway.incoming(body)

    app.state.gateway = gateway
    return app


app = create_app()
