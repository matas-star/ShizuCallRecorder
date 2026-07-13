"""Audit public Mobili Stotele frontend capabilities without authentication."""

from __future__ import annotations

import sys
import urllib.request


ROOT_URL = "https://mobili-stotele.tele2.lt/"
MARKERS = {
    "create_endpoint": ".voip.endpoints.add",
    "update_endpoint": ".voip.endpoints.update",
    "renew_credentials": ".voip.endpoints.endpoint.renew",
    "registration_status": ".voip.endpoints.endpoint.get_status",
    "acl_first_registration": ".voip.endpoints.endpoint.acl.add_on_first_reg",
    "employee_route": ".contact.employee_route.set",
    "registrar": "registrar_address",
    "username": "username_copy",
    "password": "password_copy",
    "recording_permission": "allow_rec",
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "CRMPhoneAgent-audit/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def main() -> int:
    html = fetch(ROOT_URL)
    marker = 'src="main-'
    start = html.find(marker)
    if start < 0:
        print("Tele2 VoIP frontend audit: FAIL (main bundle not found)")
        return 1
    start += len('src="')
    end = html.find('"', start)
    bundle_url = ROOT_URL + html[start:end]
    javascript = fetch(bundle_url)
    missing = [name for name, value in MARKERS.items() if value not in javascript]
    if missing:
        print("Tele2 VoIP frontend audit: FAIL")
        for name in missing:
            print(f"- missing public capability marker: {name}")
        return 1
    print("Tele2 VoIP frontend audit: PASS")
    print(f"Bundle: {bundle_url}")
    for name in MARKERS:
        print(f"- {name}: present")
    print("This proves portal capabilities, not subscription entitlement or SIP interoperability.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
