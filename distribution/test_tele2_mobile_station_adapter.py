import copy
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from tele2_mobile_station_adapter import (
    decide,
    dial_request,
    recording_request,
    verified_recording,
)


class Tele2MobileStationAdapterTest(unittest.TestCase):
    def completed(self):
        return {
            "eventType": "CallCompletedEvent",
            "data": {
                "callID": 1234,
                "caller": "+37060000001",
                "destination": "+37060000002",
                "direction": "out",
                "status": 1,
                "callStarted": "2026-07-13T09:00:00Z",
                "callConnected": "2026-07-13T09:00:05Z",
                "callEnded": "2026-07-13T09:00:35Z",
                "connectionTime": 30,
                "contactID": 77,
            },
        }

    def recorded(self):
        return {
            "eventType": "CallRecordedEvent",
            "data": {
                "recordingID": 987,
                "callID": 1234,
                "callStarted": "2026-07-13T09:00:00Z",
                "recordingURL": "https://recordings.example/987.wav",
                "direction": "out",
                "connectionTime": 30,
            },
        }

    def test_dial_uses_official_v2_endpoint_and_e164(self):
        url, body = dial_request("860000002", 77)
        self.assertEqual("https://mobili-stotele.tele2.lt/api/v2/dial", url)
        self.assertEqual({"destination": "+37060000002", "contactID": 77}, body)

    def test_recording_endpoint(self):
        self.assertEqual(
            "https://mobili-stotele.tele2.lt/api/v2/call_records/987",
            recording_request(987),
        )

    def test_answered_outbound_maps_to_crm(self):
        result = decide(self.completed(), broker_number="+37060000001")
        self.assertEqual("upsert_answered", result.action)
        self.assertEqual("+37060000002", result.event["phone_number"])
        self.assertEqual("outbound", result.event["direction"])
        self.assertEqual(30, result.event["duration_seconds"])

    def test_missed_call_is_ignored(self):
        payload = self.completed()
        payload["data"]["callConnected"] = None
        payload["data"]["connectionTime"] = 0
        result = decide(payload)
        self.assertEqual("ignore", result.action)
        self.assertIsNone(result.event)

    def test_inbound_uses_caller_as_external_number(self):
        payload = self.completed()
        payload["data"]["direction"] = "in"
        payload["data"]["caller"] = "+37061111111"
        payload["data"]["destination"] = "+37060000001"
        result = decide(payload, broker_number="+37060000001")
        self.assertEqual("+37061111111", result.event["phone_number"])
        self.assertEqual("inbound", result.event["direction"])

    def test_recording_webhook_requires_server_verification(self):
        result = decide(self.recorded())
        self.assertEqual("verify_and_import", result.action)
        self.assertEqual(987, result.recording_id)
        verified = verified_recording(
            self.recorded(),
            {"data": {"recordingID": 987, "callID": 1234,
                      "recordingURL": "https://recordings.example/987.wav"}},
        )
        self.assertEqual(1234, verified["provider_call_id"])

    def test_forged_recording_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            verified_recording(
                self.recorded(),
                {"data": {"recordingID": 999, "callID": 1234,
                          "recordingURL": "https://recordings.example/999.wav"}},
            )

    def test_duplicate_has_stable_idempotency_key(self):
        payload = self.completed()
        self.assertEqual(decide(payload).idempotency_key, decide(copy.deepcopy(payload)).idempotency_key)


if __name__ == "__main__":
    unittest.main()
