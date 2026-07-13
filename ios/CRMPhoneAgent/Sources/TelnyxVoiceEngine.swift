import AVFAudio
import CallKit
import TelnyxRTC
import UIKit

struct AudioRoute: Identifiable {
    enum Kind { case earpiece, speaker, input(AVAudioSessionPortDescription) }
    let id: String
    let name: String
    let kind: Kind

    static func available() -> [AudioRoute] {
        let session = AVAudioSession.sharedInstance()
        var routes = [
            AudioRoute(id: "earpiece", name: "iPhone", kind: .earpiece),
            AudioRoute(id: "speaker", name: "Garsiakalbis", kind: .speaker)
        ]
        for input in session.availableInputs ?? [] where input.portType == .bluetoothHFP || input.portType == .bluetoothLE {
            routes.append(AudioRoute(id: input.uid, name: input.portName, kind: .input(input)))
        }
        return routes
    }

    func select() {
        let session = AVAudioSession.sharedInstance()
        switch kind {
        case .earpiece:
            try? session.setPreferredInput(session.availableInputs?.first(where: { $0.portType == .builtInMic }))
            try? session.overrideOutputAudioPort(.none)
        case .speaker:
            try? session.overrideOutputAudioPort(.speaker)
        case .input(let input):
            try? session.overrideOutputAudioPort(.none)
            try? session.setPreferredInput(input)
        }
    }
}

final class TelnyxVoiceEngine: NSObject, TxClientDelegate {
    private let client = TxClient()
    private let crm: CRMClient
    private let stateChanged: (AppModel.CallStatus) -> Void
    private var call: Call?
    private var reportedIncomingIDs = Set<UUID>()
    private let callController = CXCallController()
    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration(localizedName: "CRM Phone")
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
        return provider
    }()

    init(crm: CRMClient, stateChanged: @escaping (AppModel.CallStatus) -> Void) {
        self.crm = crm
        self.stateChanged = stateChanged
        super.init()
        client.delegate = self
    }

    func connect(token: String, pushToken: String?) throws {
        try client.connect(txConfig: TxConfig(token: token,
                                              pushDeviceToken: pushToken,
                                              pushEnvironment: pushEnvironment))
    }

    private var pushEnvironment: PushEnvironment {
#if DEBUG
        return .debug
#else
        return .production
#endif
    }

    func processPush(metadata: [String: Any], token: String, pushToken: String?, completion: @escaping () -> Void) {
        guard let rawID = metadata["call_id"] as? String, let callID = UUID(uuidString: rawID) else {
            completion()
            return
        }
        let caller = (metadata["caller_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (metadata["caller_number"] as? String) ?? "Nezinomas numeris"
        reportIncoming(callID: callID, caller: caller, completion: completion)
        let config = TxConfig(token: token, pushDeviceToken: pushToken, pushEnvironment: pushEnvironment)
        do {
            try client.processVoIPNotification(txConfig: config,
                                               serverConfiguration: TxServerConfiguration(environment: .production),
                                               pushMetaData: metadata)
        } catch {
            stateChanged(.failed(error.localizedDescription))
        }
    }

    func reportUnavailablePush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let metadata = payload["metadata"] as? [String: Any]
        let id = (metadata?["call_id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        reportIncoming(callID: id, caller: "CRM skambutis", completion: completion)
    }

    func reportMissedPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let metadata = payload["metadata"] as? [String: Any]
        let originalID = (metadata?["call_id"] as? String).flatMap(UUID.init(uuidString:))
        let temporaryID = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: " ")
        provider.reportNewIncomingCall(with: temporaryID, update: update) { [weak self] _ in
            let now = Date()
            self?.provider.reportCall(with: temporaryID, endedAt: now, reason: .answeredElsewhere)
            if let originalID {
                self?.provider.reportCall(with: originalID, endedAt: now, reason: .unanswered)
            }
            completion()
        }
    }

    func start(number: String, context: CallContext) throws {
        stateChanged(.connecting)
        let id = UUID()
        _ = provider
        call = try client.newCall(callerName: "CRM Phone",
                                  callerNumber: "",
                                  destinationNumber: number,
                                  callId: id,
                                  clientState: context.clientState,
                                  customHeaders: ["X-CRM-Event-ID": context.eventId])
        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: id, handle: handle)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error { self?.stateChanged(.failed(error.localizedDescription)) }
        }
    }

    func end() { call?.hangup() }
    func sendDTMF(_ digit: String) { call?.dtmf(dtmf: digit) }
    func setMuted(_ muted: Bool) { muted ? call?.muteAudio() : call?.unmuteAudio() }
    func setHeld(_ held: Bool) { held ? call?.hold() : call?.unhold() }

    func audioRoutes() -> [AudioRoute] {
        AudioRoute.available()
    }

    func selectAudioRoute(_ route: AudioRoute) {
        route.select()
    }

    func onSocketConnected() {}
    func onSocketDisconnected() { stateChanged(.ended) }
    func onClientReady() {}
    func onPushDisabled(success: Bool, message: String) {}
    func onSessionUpdated(sessionId: String) {}
    func onClientError(error: Error) { stateChanged(.failed(error.localizedDescription)) }
    func onIncomingCall(call: Call) { reportIncoming(call) }
    func onPushCall(call: Call) { reportIncoming(call) }
    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) {
        provider.reportCall(with: callId, endedAt: Date(), reason: .remoteEnded)
        stateChanged(.ended)
    }
    func onCallStateUpdated(callState: CallState, callId: UUID) {
        switch callState {
        case .ACTIVE:
            provider.reportOutgoingCall(with: callId, connectedAt: Date())
            stateChanged(.active)
        case .RINGING: stateChanged(.ringing)
        case .DONE(_): stateChanged(.ended)
        default: break
        }
    }

    private func reportIncoming(_ call: Call) {
        self.call = call
        guard let callId = call.callInfo?.callId else {
            stateChanged(.failed("Incoming call has no CallKit identifier"))
            return
        }
        if reportedIncomingIDs.contains(callId) {
            stateChanged(.ringing)
            return
        }
        let caller = call.callInfo?.callerName ?? call.callInfo?.callerNumber ?? "Nezinomas numeris"
        reportIncoming(callID: callId, caller: caller) {}
    }

    private func reportIncoming(callID: UUID, caller: String, completion: @escaping () -> Void) {
        reportedIncomingIDs.insert(callID)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: caller)
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            if let error { self?.stateChanged(.failed(error.localizedDescription)) }
            else { self?.stateChanged(.ringing) }
            completion()
        }
    }
}

extension TelnyxVoiceEngine: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        call?.hangup()
        call = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        client.answerFromCallkit(answerAction: action)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        call?.hangup()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.isMuted ? call?.muteAudio() : call?.unmuteAudio()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.isOnHold ? call?.hold() : call?.unhold()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        client.enableAudioSession(audioSession: audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        client.disableAudioSession(audioSession: audioSession)
    }
}
