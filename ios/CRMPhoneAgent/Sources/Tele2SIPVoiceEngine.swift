import AVFAudio
import CallKit
import CryptoKit
import Foundation

@MainActor
final class Tele2SIPVoiceEngine: NSObject {
    private let stateChanged: (AppModel.CallStatus) -> Void
    private let callController = CXCallController()
    private var callID: UUID?
    private var pendingNumber = ""
    private var incomingReportedFromPush = false
    private var pendingAnswerAction: CXAnswerCallAction?
    private var isOutgoing = false
    private var connected = false
    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration(localizedName: "CRM Phone")
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: .main)
        return provider
    }()

    init(stateChanged: @escaping (AppModel.CallStatus) -> Void) {
        self.stateChanged = stateChanged
        super.init()
    }

    deinit { crm_sip_stop() }

    func connect(settings: AppSettings) throws {
        guard settings.isSIPConfigured else { throw Tele2SIPError.notConfigured }
        if connected { return }
        let account = try accountURI(settings: settings)
        let result = account.withCString { accountPointer in
            settings.sipRegistrar.withCString { registrarPointer in
                crm_sip_start(accountPointer, registrarPointer, tele2SIPEventCallback,
                              Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard result == 0 else { throw Tele2SIPError.engine(code: result) }
        connected = true
        _ = provider
    }

    func start(number: String) throws {
        guard crm_sip_is_registered() else { throw Tele2SIPError.notRegistered }
        pendingNumber = number
        let id = UUID()
        callID = id
        isOutgoing = true
        let result = number.withCString { crm_sip_call($0) }
        guard result == 0 else { throw Tele2SIPError.engine(code: result) }
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: number))
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error { Task { @MainActor in self?.stateChanged(.failed(error.localizedDescription)) } }
        }
    }

    func stop() {
        crm_sip_stop()
        connected = false
    }

    func processPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let metadata = payload["metadata"] as? [String: Any] ?? payload as? [String: Any] ?? [:]
        let rawCallID = metadata["call_id"] as? String ?? UUID().uuidString
        let id = Self.stableUUID(rawCallID)
        let caller = metadata["caller_number"] as? String ?? metadata["caller"] as? String ?? "Nežinomas numeris"
        if callID == id, incomingReportedFromPush {
            completion()
            return
        }
        callID = id
        incomingReportedFromPush = true
        isOutgoing = false
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: caller)
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                if let error { self?.stateChanged(.failed(error.localizedDescription)) }
                else { self?.stateChanged(.ringing) }
                completion()
            }
        }
    }

    func end() { crm_sip_end() }
    func sendDTMF(_ digit: String) { digit.utf8.first.map { _ = crm_sip_send_dtmf(CChar($0)) } }
    func setMuted(_ value: Bool) { _ = crm_sip_set_muted(value) }
    func setHeld(_ value: Bool) { _ = crm_sip_set_held(value) }
    func audioRoutes() -> [AudioRoute] { AudioRoute.available() }
    func selectAudioRoute(_ route: AudioRoute) { route.select() }

    fileprivate func receive(event: crm_sip_event_t, value: String) {
        switch event {
        case CRM_SIP_EVENT_REGISTERING:
            break
        case CRM_SIP_EVENT_REGISTERED:
            stateChanged(.idle)
        case CRM_SIP_EVENT_REGISTRATION_FAILED:
            stateChanged(.failed(value.isEmpty ? "Tele2 SIP klaida" : value))
        case CRM_SIP_EVENT_ERROR:
            connected = false
            stateChanged(.failed(value.isEmpty ? "Tele2 SIP klaida" : value))
            crm_sip_stop()
        case CRM_SIP_EVENT_INCOMING:
            if incomingReportedFromPush {
                incomingReportedFromPush = false
                stateChanged(.ringing)
            } else {
                reportIncoming(number: Self.number(from: value))
            }
            answerPendingCallIfNeeded()
        case CRM_SIP_EVENT_OUTGOING:
            stateChanged(.connecting)
        case CRM_SIP_EVENT_RINGING:
            if isOutgoing, let callID { provider.reportOutgoingCall(with: callID, startedConnectingAt: Date()) }
            stateChanged(.ringing)
        case CRM_SIP_EVENT_ACTIVE:
            if isOutgoing, let callID { provider.reportOutgoingCall(with: callID, connectedAt: Date()) }
            stateChanged(.active)
        case CRM_SIP_EVENT_ENDED:
            pendingAnswerAction?.fail()
            pendingAnswerAction = nil
            if let callID { provider.reportCall(with: callID, endedAt: Date(), reason: .remoteEnded) }
            callID = nil
            isOutgoing = false
            stateChanged(.ended)
        default:
            break
        }
    }

    private func reportIncoming(number: String) {
        let id = UUID()
        callID = id
        isOutgoing = false
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                if let error { self?.stateChanged(.failed(error.localizedDescription)) }
                else { self?.stateChanged(.ringing) }
            }
        }
    }

    fileprivate func answer(_ action: CXAnswerCallAction) {
        let result = crm_sip_answer()
        if result == 0 {
            action.fulfill()
        } else {
            pendingAnswerAction = action
        }
    }

    private func answerPendingCallIfNeeded() {
        guard let action = pendingAnswerAction else { return }
        let result = crm_sip_answer()
        if result == 0 {
            pendingAnswerAction = nil
            action.fulfill()
        }
    }

    private func accountURI(settings: AppSettings) throws -> String {
        guard let password = try KeychainStore.get(account: "tele2-sip-password"), !password.isEmpty else {
            throw Tele2SIPError.notConfigured
        }
        let user = Self.encodeUserInfo(settings.sipUsername)
        let secret = Self.encodeUserInfo(password)
        return "CRM Phone <sip:\(user):\(secret)@\(settings.sipRegistrar);transport=\(settings.sipTransport)>;regint=300"
    }

    private static func encodeUserInfo(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    private static func number(from uri: String) -> String {
        let withoutScheme = uri.replacingOccurrences(of: "sip:", with: "")
        return withoutScheme.split(separator: "@").first.map(String.init) ?? uri
    }

    private static func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private let tele2SIPEventCallback: @convention(c) (crm_sip_event_t, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
    event, value, context in
    guard let context else { return }
    let engine = Unmanaged<Tele2SIPVoiceEngine>.fromOpaque(context).takeUnretainedValue()
    let text = value.map(String.init(cString:)) ?? ""
    Task { @MainActor in engine.receive(event: event, value: text) }
}

extension Tele2SIPVoiceEngine: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.end() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.answer(action) }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        crm_sip_end()
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        crm_sip_set_muted(action.isMuted) == 0 ? action.fulfill() : action.fail()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        crm_sip_set_held(action.isOnHold) == 0 ? action.fulfill() : action.fail()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                      options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? audioSession.setActive(true)
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum Tele2SIPError: LocalizedError {
    case notConfigured, notRegistered, engine(code: Int32)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Tele2 SIP endpointas nesukonfigūruotas."
        case .notRegistered: "Tele2 SIP dar neprisiregistravo."
        case .engine(let code): "Tele2 SIP variklio klaida: \(code)."
        }
    }
}
