import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum CallMode: String, CaseIterable, Identifiable {
        case tele2SIP = "tele2_sip"
        case tele2Carrier = "tele2_carrier"
        case telnyxVoIP = "telnyx_voip"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tele2SIP: "Tele2 SIP + tas pats numeris"
            case .tele2Carrier: "Tele2 mobilus numeris"
            case .telnyxVoIP: "Telnyx VoIP testas"
            }
        }
    }
    enum Tab: Hashable { case recents, contacts, keypad, crm }
    enum CallStatus: Equatable {
        case idle, connecting, ringing, active, ended, failed(String)
    }

    @Published var number = ""
    @Published var status: CallStatus = .idle
    @Published var isMuted = false
    @Published var isHeld = false
    @Published var showSettings = false
    @Published var selectedTab: Tab = .keypad
    @Published var recentCalls: [CRMCallItem] = []
    @Published var crmURL: URL?

    let settings = AppSettings()
    let contacts = ContactStore()
    let permissions = PermissionCenter()
    private var currentEventID: String?
    private var currentCallAnswered = false
    private lazy var crm = CRMClient(settings: settings)
    private lazy var voice = TelnyxVoiceEngine(crm: crm) { [weak self] state in
        Task { @MainActor in await self?.applyVoiceState(state) }
    }
    private lazy var sipVoice = Tele2SIPVoiceEngine { [weak self] state in
        Task { @MainActor in await self?.applyVoiceState(state) }
    }

    init() {
        VoIPPushManager.shared.onPayload = { [weak self] payload, completion in
            Task { @MainActor in
                self?.handleVoIPPush(payload, completion: completion)
            }
        }
        NotificationCenter.default.addObserver(forName: .voipTokenChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.connect() }
        }
    }

    func connect() async {
        await permissions.refresh()
        guard settings.isConfigured else {
            showSettings = true
            return
        }
        do {
            if settings.callMode == .tele2Carrier {
                sipVoice.stop()
                if crmURL == nil { crmURL = URL(string: settings.baseURL) }
                configureCellularHistoryObserver()
                await syncCellularHistory()
                await loadRecents()
                return
            }
            if settings.callMode == .tele2SIP {
                try sipVoice.connect(settings: settings)
                if let token = VoIPPushManager.shared.token {
                    try await crm.registerSIPDevice(pushToken: token)
                }
                if crmURL == nil { crmURL = URL(string: settings.baseURL) }
                await loadRecents()
                return
            }
            sipVoice.stop()
            let token = try await crm.fetchVoiceToken()
            try? KeychainStore.set(token, account: "telnyx-jwt")
            try voice.connect(token: token, pushToken: VoIPPushManager.shared.token)
            if crmURL == nil { crmURL = URL(string: settings.baseURL) }
            await loadRecents()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func call() async {
        let normalized = number.filter { $0.isNumber || $0 == "+" }
        guard normalized.count >= 7 else { return }
        do {
            let context = try await crm.prepareCall(number: normalized)
            currentEventID = context.eventId
            currentCallAnswered = false
            if settings.callMode == .tele2Carrier {
                guard #available(iOS 26.0, *) else {
                    throw CellularDialerError.requiresIOS26
                }
#if canImport(LiveCommunicationKit)
                status = .connecting
                try await CellularDialer.shared.start(number: normalized)
                return
#else
                throw CellularDialerError.sdkUnavailable
#endif
            }
            if settings.callMode == .tele2SIP {
                try sipVoice.start(number: normalized)
                return
            }
            try voice.start(number: normalized, context: context)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func end() {
        if settings.callMode == .tele2SIP { sipVoice.end() } else { voice.end() }
    }
    func sendDTMF(_ digit: String) {
        if settings.callMode == .tele2SIP { sipVoice.sendDTMF(digit) } else { voice.sendDTMF(digit) }
    }
    func setMuted(_ value: Bool) {
        isMuted = value
        if settings.callMode == .tele2SIP { sipVoice.setMuted(value) } else { voice.setMuted(value) }
    }
    func setHeld(_ value: Bool) {
        isHeld = value
        if settings.callMode == .tele2SIP { sipVoice.setHeld(value) } else { voice.setHeld(value) }
    }
    var audioRoutes: [AudioRoute] { settings.callMode == .tele2SIP ? sipVoice.audioRoutes() : voice.audioRoutes() }
    func selectAudioRoute(_ route: AudioRoute) {
        if settings.callMode == .tele2SIP { sipVoice.selectAudioRoute(route) } else { voice.selectAudioRoute(route) }
    }
    var usesCarrierCalling: Bool { settings.callMode == .tele2Carrier }

    func call(number: String) {
        self.number = number
        selectedTab = .keypad
        Task { await call() }
    }

    func loadRecents() async {
        guard settings.isConfigured else { return }
        do { recentCalls = try await crm.recentCalls() } catch { }
    }

    private func applyVoiceState(_ newState: CallStatus) async {
        status = newState
        if newState == .active { currentCallAnswered = true }
        guard newState == .ended, currentCallAnswered, let eventID = currentEventID else { return }
        currentEventID = nil
        currentCallAnswered = false
        do {
            let result = try await crm.resolvePostCall(eventID: eventID)
            if result.shouldOpen, let url = result.leadURL {
                crmURL = url
                selectedTab = .crm
            }
            await loadRecents()
        } catch { }
    }

    private func configureCellularHistoryObserver() {
        guard #available(iOS 26.0, *) else { return }
#if canImport(LiveCommunicationKit)
        CellularDialer.shared.onHistoryChanged = { [weak self] in
            Task { @MainActor in
                await self?.syncCellularHistory()
                await self?.resolveCarrierPostCall()
            }
        }
#endif
    }

    private func syncCellularHistory() async {
        guard settings.callMode == .tele2Carrier else { return }
        guard #available(iOS 26.0, *) else { return }
#if canImport(LiveCommunicationKit)
        do {
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
            let calls = try await CellularDialer.shared.recent(since: since)
            try await crm.syncCellularHistory(calls)
        } catch { }
#endif
    }

    private func resolveCarrierPostCall() async {
        guard settings.callMode == .tele2Carrier, let eventID = currentEventID else { return }
        for attempt in 0..<8 {
            do {
                let result = try await crm.resolvePostCall(eventID: eventID)
                if result.shouldOpen, let url = result.leadURL {
                    currentEventID = nil
                    status = .ended
                    crmURL = url
                    selectedTab = .crm
                    await loadRecents()
                    return
                }
                if result.terminal == true {
                    currentEventID = nil
                    currentCallAnswered = false
                    status = .ended
                    await loadRecents()
                    return
                }
            } catch { }
            if attempt < 7 { try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private func handleVoIPPush(_ payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        if settings.callMode == .tele2SIP {
            let metadata = payload["metadata"] as? [String: Any] ?? [:]
            currentEventID = metadata["event_id"] as? String
            currentCallAnswered = false
            sipVoice.processPush(payload, completion: completion)
            return
        }
        if let aps = payload["aps"] as? [String: Any],
           let alert = aps["alert"] as? String,
           alert == "Missed call!" {
            voice.reportMissedPush(payload, completion: completion)
            return
        }
        guard let metadata = payload["metadata"] as? [String: Any],
              let token = try? KeychainStore.get(account: "telnyx-jwt"),
              let token else {
            voice.reportUnavailablePush(payload, completion: completion)
            return
        }
        voice.processPush(metadata: metadata, token: token,
                          pushToken: VoIPPushManager.shared.token,
                          completion: completion)
    }

    func handle(url: URL) {
        let customCall = url.scheme == "crmphone" && url.host == "call"
        let universalCall = url.scheme == "https"
            && url.host == "011-leads-copy-3090159d.base44.app"
            && url.path == "/mobile/call"
        guard customCall || universalCall else { return }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "number" })?.value {
            number = value
            Task { await call() }
        }
    }
}

final class AppSettings: ObservableObject {
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    @Published var brokerID: String { didSet { defaults.set(brokerID, forKey: "brokerID") } }
    @Published var accessToken: String { didSet { try? KeychainStore.set(accessToken, account: "base44-token") } }
    @Published var callMode: AppModel.CallMode { didSet { defaults.set(callMode.rawValue, forKey: "callMode") } }
    @Published var sipRegistrar: String { didSet { defaults.set(sipRegistrar, forKey: "sipRegistrar") } }
    @Published var sipUsername: String { didSet { defaults.set(sipUsername, forKey: "sipUsername") } }
    @Published var sipPassword: String { didSet { try? KeychainStore.set(sipPassword, account: "tele2-sip-password") } }
    @Published var sipTransport: String { didSet { defaults.set(sipTransport, forKey: "sipTransport") } }

    static var preferredCellularServiceID: String {
        UserDefaults.standard.string(forKey: "preferredCellularServiceID") ?? ""
    }

    private let defaults = UserDefaults.standard

    init() {
        baseURL = defaults.string(forKey: "baseURL") ?? ""
        brokerID = defaults.string(forKey: "brokerID") ?? ""
        accessToken = (try? KeychainStore.get(account: "base44-token")) ?? ""
        callMode = AppModel.CallMode(rawValue: defaults.string(forKey: "callMode") ?? "") ?? .tele2Carrier
        sipRegistrar = defaults.string(forKey: "sipRegistrar") ?? ""
        sipUsername = defaults.string(forKey: "sipUsername") ?? ""
        sipPassword = (try? KeychainStore.get(account: "tele2-sip-password")) ?? ""
        sipTransport = defaults.string(forKey: "sipTransport") ?? "udp"
    }

    var isConfigured: Bool { URL(string: baseURL) != nil && !brokerID.isEmpty && !accessToken.isEmpty }
    var isSIPConfigured: Bool {
        !sipRegistrar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sipUsername.isEmpty && !sipPassword.isEmpty
    }
}

enum CellularDialerError: LocalizedError {
    case requiresIOS26
    case sdkUnavailable

    var errorDescription: String? {
        switch self {
        case .requiresIOS26: "Tele2 mobiliojo numerio dialeriui reikia iOS 26 ar naujesnes versijos."
        case .sdkUnavailable: "Buildas sukurtas be iOS 26 LiveCommunicationKit SDK."
        }
    }
}
