import Foundation

struct CallContext: Codable {
    let eventId: String
    let leadId: String?
    let clientState: String

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id", leadId = "lead_id", clientState = "client_state"
    }
}

struct CRMCallItem: Codable, Identifiable {
    let id: String
    let phoneNumber: String
    let displayName: String?
    let direction: String
    let answered: Bool
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, direction, answered
        case phoneNumber = "phone_number", displayName = "display_name", startedAt = "started_at"
    }
}

struct PostCallResolution: Decodable {
    let shouldOpen: Bool
    let leadURL: URL?
    let terminal: Bool?
    let answered: Bool?

    enum CodingKeys: String, CodingKey {
        case shouldOpen = "should_open", leadURL = "lead_url"
        case terminal, answered
    }
}

private struct VoiceTokenResponse: Decodable { let token: String }

#if canImport(LiveCommunicationKit)
private struct CellularHistoryUpload: Encodable {
    let brokerId: String
    let provider: String
    let calls: [CellularHistorySnapshot]

    enum CodingKeys: String, CodingKey {
        case brokerId = "broker_id", provider, calls
    }
}
#endif

final class CRMClient {
    private let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }

    func fetchVoiceToken() async throws -> String {
        let response: VoiceTokenResponse = try await request("functions/issueIosVoiceToken", body: [
            "broker_id": settings.brokerID
        ])
        return response.token
    }

    func prepareCall(number: String) async throws -> CallContext {
        try await request("functions/prepareIosCall", body: [
            "broker_id": settings.brokerID,
            "phone_number": number,
            "provider": {
                switch settings.callMode {
                case .tele2SIP: "tele2_mobile_station_sip"
                case .tele2Carrier: "tele2_mobile_station"
                case .telnyxVoIP: "telnyx"
                }
            }()
        ])
    }

    func recentCalls() async throws -> [CRMCallItem] {
        try await request("functions/listIosRecentCalls", body: ["broker_id": settings.brokerID])
    }

    func resolvePostCall(eventID: String) async throws -> PostCallResolution {
        try await request("functions/resolveIosPostCall", body: [
            "broker_id": settings.brokerID,
            "event_id": eventID
        ])
    }

    func registerSIPDevice(pushToken: String) async throws {
        let _: EmptyResponse = try await request("functions/registerIosSipDevice", body: [
            "broker_id": settings.brokerID,
            "push_token": pushToken,
            "provider": "tele2_mobile_station_sip"
        ])
    }

#if canImport(LiveCommunicationKit)
    func syncCellularHistory(_ calls: [CellularHistorySnapshot]) async throws {
        guard !calls.isEmpty else { return }
        let _: EmptyResponse = try await request(
            "functions/syncIosCellularHistory",
            body: CellularHistoryUpload(
                brokerId: settings.brokerID,
                provider: "ios_livecommunicationkit",
                calls: calls
            )
        )
    }
#endif

    private func request<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        guard let base = URL(string: settings.baseURL),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

private struct EmptyResponse: Decodable {}
