from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios" / "CRMPhoneAgent"
required = [
    IOS / "project.yml",
    IOS / "scripts" / "build_baresip_xcframework.sh",
    IOS / "CRMPhoneAgent.entitlements",
    IOS / "CRMPhoneAgent.default-dialer.entitlements",
    IOS / "Info.plist",
    IOS / "Sources" / "CRMPhoneAgentApp.swift",
    IOS / "Sources" / "AppModel.swift",
    IOS / "Sources" / "CellularDialer.swift",
    IOS / "Sources" / "Tele2SIPBridge.c",
    IOS / "Sources" / "Tele2SIPBridge.h",
    IOS / "Sources" / "Tele2SIPVoiceEngine.swift",
    IOS / "Sources" / "AppDelegate.swift",
    IOS / "Sources" / "ContactStore.swift",
    IOS / "Sources" / "CRMClient.swift",
    IOS / "Sources" / "PermissionCenter.swift",
    IOS / "Sources" / "TelnyxVoiceEngine.swift",
    IOS / "Sources" / "ContentView.swift",
]

errors = [f"missing: {path.relative_to(ROOT)}" for path in required if not path.is_file()]
if not errors:
    with (IOS / "CRMPhoneAgent.entitlements").open("rb") as handle:
        entitlements = plistlib.load(handle)
    if "aps-environment" not in entitlements:
        errors.append("Push Notifications entitlement is missing")
    domains = entitlements.get("com.apple.developer.associated-domains", [])
    if "applinks:011-leads-copy-3090159d.base44.app" not in domains:
        errors.append("Base44 Associated Domain is missing")
    with (IOS / "CRMPhoneAgent.default-dialer.entitlements").open("rb") as handle:
        dialer_entitlements = plistlib.load(handle)
    if dialer_entitlements.get("com.apple.developer.dialing-app") is not True:
        errors.append("EU Default Dialer entitlement is missing")
    with (IOS / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    schemes = info.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes", [])
    if "crmphone" not in schemes:
        errors.append("crmphone URL scheme is missing")

    project = (IOS / "project.yml").read_text(encoding="utf-8")
    if "team-telnyx/telnyx-webrtc-ios" not in project:
        errors.append("Telnyx Swift package is missing")

    sip_build = (IOS / "scripts" / "build_baresip_xcframework.sh").read_text(encoding="utf-8")
    for marker in ('VERSION="4.7.0"', "baresip/re.git", "baresip/baresip.git",
                   "CRMPhoneBaresip.xcframework", '-DMODULES="g711;audiounit;stun;turn;ice"'):
        if marker not in sip_build:
            errors.append(f"SIP engine build marker missing: {marker}")

    sources = "\n".join(path.read_text(encoding="utf-8") for path in required if path.suffix == ".swift")
    for marker in ("fetchVoiceToken", "prepareIosCall", "resolveIosPostCall", "X-CRM-Event-ID",
                   "CXCallController", "PKPushRegistry", "reportMissedPush", "WKWebView", "CNContactStore"):
        if marker not in sources:
            errors.append(f"required integration marker missing: {marker}")
    for marker in ("TelephonyConversationManager.sharedInstance", "StartCellularConversationAction",
                   "ConversationHistoryManager.sharedInstance", "recentConversations(matching:",
                   "syncIosCellularHistory", "NSUserActivityTypeBrowsingWeb",
                   "tele2_mobile_station", "result.terminal == true"):
        if marker not in sources:
            errors.append(f"carrier integration marker missing: {marker}")

    for marker in ("crm_sip_start", "crm_sip_call", "crm_sip_answer", "crm_sip_set_muted",
                   "crm_sip_set_held", "crm_sip_send_dtmf", "registerIosSipDevice",
                   "tele2_mobile_station_sip", "CXProviderDelegate"):
        if marker not in sources:
            errors.append(f"Tele2 SIP integration marker missing: {marker}")

    if "Vendor/CRMPhoneBaresip.xcframework" not in project:
        errors.append("Baresip XCFramework dependency is missing")

    if "CODE_SIGN_ENTITLEMENTS: CRMPhoneAgent.entitlements" not in project:
        errors.append("baseline signing entitlement changed before Apple approval")

if errors:
    print("iOS CRM Phone scaffold: FAIL")
    print("\n".join(f"- {error}" for error in errors))
    sys.exit(1)

print("iOS CRM Phone scaffold: PASS")
print(f"Project: {IOS}")
print("Compile/signing verification still requires macOS + Xcode + Apple Developer team.")
