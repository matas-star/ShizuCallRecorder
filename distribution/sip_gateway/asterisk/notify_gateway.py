#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request


def agi_response(message: str) -> None:
    print(f'VERBOSE "{message}" 1', flush=True)


def main() -> int:
    while sys.stdin.readline().strip():
        pass
    if len(sys.argv) != 4:
        agi_response("CRM gateway: invalid arguments")
        return 1
    broker_id, call_id, caller = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", broker_id):
        return 1
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", call_id):
        return 1
    caller = re.sub(r"[^+0-9]", "", caller)[:64]
    if len(caller) < 3:
        return 1
    url = os.environ["CRM_SIP_GATEWAY_URL"].rstrip("/") + "/v1/incoming"
    secret = os.environ["CRM_SIP_GATEWAY_SECRET"]
    body = json.dumps({"broker_id": broker_id, "call_id": call_id, "caller_number": caller}).encode()
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status != 200:
                agi_response(f"CRM gateway rejected request: {response.status}")
                return 1
    except Exception as error:
        agi_response(f"CRM gateway request failed: {type(error).__name__}")
        return 1
    agi_response("CRM gateway PushKit notification accepted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
