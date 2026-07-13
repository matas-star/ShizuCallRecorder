import copy
import json
from pathlib import Path
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from cloudtalk_adapter import classify_recording_response, decide, retry_delay_seconds


class CloudTalkAdapterTest(unittest.TestCase):
    def payload(self, name):
        return json.loads((HERE / name).read_text(encoding="utf-8"))

    def test_answered_call_maps_to_existing_crm_contract(self):
        result = decide(self.payload("cloudtalk_payload_answered.example.json"))
        self.assertEqual("upsert_and_import", result.action)
        self.assertEqual(100001, result.recording_call_id)
        self.assertEqual("ios-cloudtalk", result.event["device_type"])
        self.assertEqual("+37060000000", result.event["phone_number"])

    def test_missed_call_is_ignored(self):
        result = decide(self.payload("cloudtalk_payload_missed.example.json"))
        self.assertEqual("ignore", result.action)
        self.assertIsNone(result.event)
        self.assertIsNone(result.recording_call_id)

    def test_duplicate_has_stable_idempotency_key(self):
        payload = self.payload("cloudtalk_payload_answered.example.json")
        self.assertEqual(decide(payload).idempotency_key, decide(copy.deepcopy(payload)).idempotency_key)

    def test_uuid_cannot_be_used_as_recording_id(self):
        payload = self.payload("cloudtalk_payload_answered.example.json")
        payload["recording_call_id"] = payload["call_id"]
        with self.assertRaises(ValueError):
            decide(payload)

    def test_retry_schedule_is_bounded(self):
        self.assertEqual([15, 30, 60, 120, 240, 300], [retry_delay_seconds(i) for i in range(6)])
        self.assertIsNone(retry_delay_seconds(6))

    def test_contradictory_answered_payload_is_ignored(self):
        payload = self.payload("cloudtalk_payload_answered.example.json")
        payload["answered"] = False
        self.assertEqual("ignore", decide(payload).action)
        payload["answered"] = True
        payload["talking_time_seconds"] = 0
        self.assertEqual("ignore", decide(payload).action)
        payload["talking_time_seconds"] = 10
        payload["status"] = "missed"
        self.assertEqual("ignore", decide(payload).action)

    def test_recording_http_policy(self):
        self.assertEqual(("store", None), classify_recording_response(200, 0))
        self.assertEqual(("retry", 15), classify_recording_response(404, 0))
        self.assertEqual(("retry", 45), classify_recording_response(429, 0, 45))
        self.assertEqual(("terminal_expired", None), classify_recording_response(410, 0))
        self.assertEqual(("terminal_auth", None), classify_recording_response(401, 0))
        self.assertEqual(("terminal_exhausted", None), classify_recording_response(500, 6))


if __name__ == "__main__":
    unittest.main()
