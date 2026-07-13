"""Pure CloudTalk-to-CRM decision logic shared by tests and Base44 implementation."""

from dataclasses import dataclass
from datetime import datetime
import re

NON_ANSWERED = {"missed", "failed", "no-answer", "no_answer", "unanswered", "rejected"}


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str
    idempotency_key: str
    event: dict | None = None
    recording_call_id: int | None = None


def as_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"true", "1", "yes", "answered", "connected"}


def normalize_direction(value: str) -> str:
    value = str(value).strip().lower()
    mapping = {"incoming": "inbound", "inbound": "inbound", "outgoing": "outbound", "outbound": "outbound"}
    if value not in mapping:
        raise ValueError("unsupported call direction")
    return mapping[value]


def normalize_e164(value: str) -> str:
    value = re.sub(r"[\s().-]", "", str(value))
    if not re.fullmatch(r"\+[1-9]\d{6,14}", value):
        raise ValueError("external_number must be E.164")
    return value


def decide(payload: dict) -> Decision:
    call_uuid = str(payload.get("call_id", "")).strip()
    if not call_uuid:
        raise ValueError("call_id is required")
    key = f"cloudtalk:{call_uuid}"
    status = str(payload.get("status", "")).strip().lower()
    talking = int(payload.get("talking_time_seconds", 0) or 0)
    if not as_bool(payload.get("answered")) or talking <= 0 or status in NON_ANSWERED:
        return Decision("ignore", "not_answered", key)

    recording_call_id = int(payload.get("recording_call_id", 0) or 0)
    if recording_call_id <= 0:
        raise ValueError("recording_call_id must contain CloudTalk cdr_id")
    started_at = parse_time(payload.get("started_at"), "started_at")
    ended_at = parse_time(payload.get("ended_at"), "ended_at")
    if ended_at < started_at:
        raise ValueError("ended_at precedes started_at")
    direction = normalize_direction(payload.get("direction"))
    phone = normalize_e164(payload.get("external_number"))
    event = {
        "event_id": key,
        "event_type": "call_ended",
        "phone_number": phone,
        "direction": direction,
        "started_at": started_at.isoformat(),
        "duration_seconds": talking,
        "broker_email": str(payload.get("agent_email", "")).strip(),
        "device_type": "ios-cloudtalk",
        "dialer_mode": "cloudtalk-default-calling",
        "provider_call_id": call_uuid,
        "provider_recording_call_id": recording_call_id,
    }
    return Decision("upsert_and_import", "answered", key, event, recording_call_id)


def parse_time(value, name: str) -> datetime:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{name} must be ISO-8601") from error


def retry_delay_seconds(attempt: int) -> int | None:
    schedule = (15, 30, 60, 120, 240, 300)
    return schedule[attempt] if 0 <= attempt < len(schedule) else None


def classify_recording_response(status: int, attempt: int, retry_after: int | None = None) -> tuple[str, int | None]:
    if status == 200:
        return "store", None
    if status == 410:
        return "terminal_expired", None
    if status in {401, 403}:
        return "terminal_auth", None
    if status == 429 and retry_after is not None and 0 < retry_after <= 600:
        return "retry", retry_after
    if status == 404 or status == 429 or 500 <= status <= 599:
        delay = retry_delay_seconds(attempt)
        return ("retry", delay) if delay is not None else ("terminal_exhausted", None)
    return "terminal_http", None
