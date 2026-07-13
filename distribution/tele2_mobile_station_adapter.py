"""Tele2 Mobili Stotele API mapping and CRM decisions.

The public API schema is published in Microsoft's certified connector repository.
This module intentionally contains no API key or Base44-specific persistence.
"""

from dataclasses import dataclass
from datetime import datetime
import re
from urllib.parse import urljoin


API_BASE_URL = "https://mobili-stotele.tele2.lt/api/v2/"
ANSWERED_EVENTS = {"callconnected", "callconnectedevent"}
COMPLETED_EVENTS = {"callcompleted", "callcompletedevent"}
RECORDED_EVENTS = {"callrecorded", "callrecordedevent"}


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str
    idempotency_key: str
    call_id: int
    recording_id: int | None = None
    event: dict | None = None


def api_url(path: str) -> str:
    return urljoin(API_BASE_URL, path.lstrip("/"))


def dial_request(destination: str, contact_id: int) -> tuple[str, dict]:
    if int(contact_id) <= 0:
        raise ValueError("contact_id must be positive")
    return api_url("dial"), {
        "destination": normalize_e164(destination),
        "contactID": int(contact_id),
    }

def recording_request(recording_id: int) -> str:
    if int(recording_id) <= 0:
        raise ValueError("recording_id must be positive")
    return api_url(f"call_records/{int(recording_id)}")


def normalize_e164(value: str) -> str:
    value = re.sub(r"[\s().-]", "", str(value or ""))
    if value.startswith("8") and len(value) == 9:
        value = "+370" + value[1:]
    elif value.startswith("370"):
        value = "+" + value
    if not re.fullmatch(r"\+[1-9]\d{6,14}", value):
        raise ValueError("phone number must be E.164")
    return value


def normalize_direction(value: str) -> str:
    value = str(value or "").strip().lower()
    mapping = {"in": "inbound", "incoming": "inbound", "out": "outbound", "outgoing": "outbound"}
    if value not in mapping:
        raise ValueError("unsupported direction")
    return mapping[value]


def parse_time(value, name: str) -> datetime | None:
    if value in (None, ""):
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{name} must be ISO-8601") from error


def event_name(payload: dict) -> str:
    return re.sub(r"[^a-z]", "", str(payload.get("eventType") or payload.get("type") or "").lower())


def payload_data(payload: dict) -> dict:
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ValueError("data object is required")
    return data


def external_number(data: dict, direction: str, broker_number: str | None = None) -> str:
    caller = normalize_e164(data.get("caller"))
    destination = normalize_e164(data.get("destination"))
    phone = caller if direction == "inbound" else destination
    if broker_number and phone == normalize_e164(broker_number):
        phone = destination if direction == "inbound" else caller
    return phone


def decide(payload: dict, broker_number: str | None = None) -> Decision:
    data = payload_data(payload)
    call_id = int(data.get("callID", 0) or 0)
    if call_id <= 0:
        raise ValueError("callID must be positive")
    name = event_name(payload)
    key = f"tele2_mobile_station:{name}:{call_id}"

    if name in RECORDED_EVENTS:
        recording_id = int(data.get("recordingID", 0) or 0)
        recording_url = str(data.get("recordingURL", "")).strip()
        if recording_id <= 0:
            raise ValueError("recordingID must be positive")
        if not recording_url.startswith("https://"):
            raise ValueError("recordingURL must use HTTPS")
        return Decision("verify_and_import", "recording_ready", key, call_id, recording_id)

    direction = normalize_direction(data.get("direction"))
    connected_at = parse_time(data.get("callConnected"), "callConnected")
    started_at = parse_time(data.get("callStarted"), "callStarted")
    ended_at = parse_time(data.get("callEnded"), "callEnded")

    if name in ANSWERED_EVENTS:
        if connected_at is None:
            raise ValueError("CallConnected requires callConnected")
        return Decision(
            "mark_answered",
            "connected",
            key,
            call_id,
            event=crm_event(data, direction, broker_number, started_at, connected_at, ended_at),
        )

    if name in COMPLETED_EVENTS:
        connection_time = int(data.get("connectionTime", 0) or 0)
        if connected_at is None or connection_time <= 0:
            return Decision("ignore", "not_answered", key, call_id)
        return Decision(
            "upsert_answered",
            "completed_answered",
            key,
            call_id,
            event=crm_event(data, direction, broker_number, started_at, connected_at, ended_at),
        )

    return Decision("observe", "non_terminal_event", key, call_id)


def crm_event(data, direction, broker_number, started_at, connected_at, ended_at) -> dict:
    if started_at and ended_at and ended_at < started_at:
        raise ValueError("callEnded precedes callStarted")
    duration = int(data.get("connectionTime", 0) or 0)
    if duration <= 0 and connected_at and ended_at:
        duration = max(0, int((ended_at - connected_at).total_seconds()))
    return {
        "event_id": f"tele2_mobile_station:{int(data['callID'])}",
        "event_type": "call_ended" if ended_at else "call_answered",
        "phone_number": external_number(data, direction, broker_number),
        "direction": direction,
        "started_at": started_at.isoformat() if started_at else None,
        "answered_at": connected_at.isoformat() if connected_at else None,
        "ended_at": ended_at.isoformat() if ended_at else None,
        "duration_seconds": duration,
        "provider": "tele2_mobile_station",
        "provider_call_id": int(data["callID"]),
        "provider_contact_id": int(data.get("contactID", 0) or 0),
        "device_type": "ios-carrier-recording",
        "dialer_mode": "ios-default-cellular-dialer",
    }


def verified_recording(webhook_payload: dict, api_response: dict) -> dict:
    webhook = payload_data(webhook_payload)
    response = api_response.get("data") if isinstance(api_response, dict) else None
    if not isinstance(response, dict):
        raise ValueError("Tele2 recording verification response is invalid")
    expected_recording = int(webhook.get("recordingID", 0) or 0)
    expected_call = int(webhook.get("callID", 0) or 0)
    if int(response.get("recordingID", 0) or 0) != expected_recording:
        raise ValueError("recordingID verification mismatch")
    if int(response.get("callID", 0) or 0) != expected_call:
        raise ValueError("callID verification mismatch")
    url = str(response.get("recordingURL", "")).strip()
    if not url.startswith("https://"):
        raise ValueError("verified recordingURL must use HTTPS")
    return {
        "provider": "tele2_mobile_station",
        "provider_call_id": expected_call,
        "provider_recording_id": expected_recording,
        "recording_url": url,
    }
