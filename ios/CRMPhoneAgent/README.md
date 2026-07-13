# CRM Phone Agent for iOS

Native SwiftUI/CallKit dialer using the MIT-licensed Telnyx iOS SDK. Calls use Telnyx WebRTC/PSTN so recording can happen automatically on the provider side and arrive in Base44 without a manual upload.

## Generate and run on macOS

Requirements: macOS, Xcode 16+ for the baseline app, Xcode 26 for the optional iOS 26 EU default-dialer experiment, an Apple Developer team, a real iPhone and a configured Telnyx account.

```bash
brew install xcodegen
cd ios/CRMPhoneAgent
xcodegen generate
open CRMPhoneAgent.xcodeproj
```

In Xcode select your Team, replace bundle ID `lt.crmphone.agent`, enable Push Notifications, and run on a real iPhone. Microphone and VoIP audio cannot be validated completely in Simulator.

The default checked-in entitlement uses `aps-environment=development`. Archive/TestFlight signing replaces this through the distribution profile. The carrier-recording build additionally needs Apple's EU Default Dialer entitlement. After Apple approves it for the team, set `CODE_SIGN_ENTITLEMENTS` to `CRMPhoneAgent.default-dialer.entitlements`; do not use that file with a provisioning profile that lacks `com.apple.developer.dialing-app`.

The primary production mode is now `Tele2 mobilus numeris`: LiveCommunicationKit starts a cellular conversation through the existing SIM/eSIM and Tele2 Mobili Stotele supplies authoritative call/recording webhooks. `Telnyx VoIP testas` remains a diagnostic fallback and does not satisfy the same-number requirement.

`Tele2 SIP + tas pats numeris` is the full-control pilot mode. It registers a
Mobili Stotele VoIP endpoint through the BSD-licensed baresip engine and exposes
mute, hold, DTMF, speaker and Bluetooth through the existing CallKit UI. Run
`bash scripts/build_baresip_xcframework.sh` before `xcodegen generate`; CI does
this automatically on the `macos-26` runner.

## First setup on the phone

1. Open Settings in CRM Phone.
2. Enter the Base44 root URL with a trailing slash, broker ID, and authenticated Base44 access token.
3. For the Tele2 SIP pilot, copy registrar, username and password from the
   Mobili Stotele VoIP endpoint screen. The password is stored in Keychain.
4. Allow microphone and notification permissions.
5. Allow Contacts when brokerio telefono kontaktai turi būti rodomi dialeryje.
6. In iPhone Settings, select CRM Phone as the default calling app. This requires iOS 26, an EU Apple ID/device region, Apple's approved entitlement, and a matching provisioning profile.
7. Place a call from the CRM Phone keypad. The app sends the selected Tele2 provider; Base44 must correlate the event with Tele2 `CallStarted`, `CallCompleted`, and `CallRecorded` by broker and phone number.
8. Verify that an answered call opens the matching Base44 lead after completion and that a missed call does not open or create a lead. For an incoming call completed while the app is backgrounded or the phone is locked, iOS requires a notification tap to foreground the lead.
9. Verify that Base44 receives the Tele2 recording URL for the same call/event without an upload button on the iPhone.

Base44 must serve the AASA file described in
`distribution/apple-app-site-association.template.json` from
`/.well-known/apple-app-site-association`, replacing `APPLE_TEAM_ID`. The app
accepts `/mobile/call?number=<E.164>&lead_id=<id>` and falls back to the
`crmphone://call` custom scheme during development.

Whenever the app launches or iOS reports a conversation-history update, it sends
the last seven days of cellular history to `functions/syncIosCellularHistory`.
The backend must deduplicate by broker and Apple history UUID. This captures
incoming call metadata even when the app was suspended during the call; Tele2
webhooks remain authoritative for answered state and recording.

The access token is stored in iOS Keychain. Telnyx API credentials are never entered into the app.

## Pilot distribution

Preferred: archive in Xcode, upload to App Store Connect, add internal testers in TestFlight. External testers require Beta App Review and builds expire after 90 days.

For a handful of known phones, create an Ad Hoc profile with registered device UDIDs and distribute the signed IPA. TestFlight remains simpler for updates.

### TestFlight signing checklist

1. Apple Developer portal: create an explicit App ID matching the bundle ID.
2. Enable Push Notifications and create an APNs key or certificate for Telnyx VoIP pushes.
3. Xcode Signing & Capabilities: add Push Notifications and Background Modes (`Audio`, `Voice over IP`, `Remote notifications`).
4. App Store Connect: create the app with the same bundle ID.
5. Xcode: `Product > Archive`, then `Distribute App > App Store Connect > Upload`.
6. App Store Connect TestFlight: wait for processing, add compliance information and assign internal testers.
7. On iPhone install TestFlight, accept the invitation, install CRM Phone and grant the three permissions shown in Settings.

PushKit itself does not show a user permission dialog. Its entitlement and APNs configuration are established during signing. Microphone, Contacts and normal CRM notifications are the user-facing permission prompts.

## Not yet implemented in this spike

- Production APNs/Telnyx certificate configuration and a real incoming-call test.
- Rich Base44 lead search beyond Contacts and Recents.
- Associated Domains entitlement for direct Universal Links outside the embedded CRM tab.
- Production Telnyx call-control function that starts recording.
- Apple-approved iOS 26 EU default dialer entitlement.
- A real Tele2 Mobili Stotele number/API pilot. The public API contract is implemented, but same-number caller ID, recording availability, webhook timing, and the exact subscription price must be verified with Tele2 on a real broker number.
