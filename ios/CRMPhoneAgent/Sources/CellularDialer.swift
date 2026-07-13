import Foundation

#if canImport(LiveCommunicationKit)
import LiveCommunicationKit

struct CellularHistorySnapshot: Codable {
    let id: String
    let phoneNumber: String
    let direction: String
    let status: String
    let startedAt: Date
    let durationSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case id, direction, status
        case phoneNumber = "phone_number"
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
    }
}

@available(iOS 26.0, *)
@MainActor
final class CellularDialer {
    static let shared = CellularDialer()

    private let telephony = TelephonyConversationManager.sharedInstance
    private let history = ConversationHistoryManager.sharedInstance
    private var historyToken: NotificationCenter.ObservationToken?
    var onHistoryChanged: (() -> Void)?

    private init() {
        historyToken = NotificationCenter.default.addObserver(
            of: ConversationHistoryManager.self,
            for: .conversationHistoryDidUpdateMessage
        ) { [weak self] _ in
            Task { @MainActor in self?.onHistoryChanged?() }
        }
    }

    func start(number: String) async throws {
        let handle = Handle(type: .phoneNumber, value: number)
        let action = StartCellularConversationAction(handle, cellularService: preferredService())
        try await telephony.startCellularConversation(action)
    }

    func recent(since: Date) async throws -> [CellularHistorySnapshot] {
        let predicate = #Predicate<ConversationHistoryManager.RecentConversation> { _ in true }
        let conversations = try await history.recentConversations(matching: predicate)
        return conversations
            .filter { $0.date >= since }
            .map {
                CellularHistorySnapshot(
                    id: $0.id.uuidString,
                    phoneNumber: $0.handles.first?.value ?? "",
                    direction: String(describing: $0.direction),
                    status: String(describing: $0.status),
                    startedAt: $0.date,
                    durationSeconds: $0.duration
                )
            }
    }

    private func preferredService() -> CellularService? {
        let services = telephony.cellularServices
        guard services.count > 1 else { return services.first }
        return services.first { $0.id.uuidString == AppSettings.preferredCellularServiceID }
            ?? services.first
    }
}
#endif
