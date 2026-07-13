import AVFAudio
import Contacts
import UserNotifications

@MainActor
final class PermissionCenter: ObservableObject {
    enum State { case unknown, denied, allowed }
    @Published var microphone: State = .unknown
    @Published var contacts: State = .unknown
    @Published var notifications: State = .unknown

    func refresh() async {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: microphone = .allowed
        case .denied: microphone = .denied
        default: microphone = .unknown
        }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: contacts = .allowed
        case .denied, .restricted: contacts = .denied
        default: contacts = .unknown
        }
        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifications = .allowed
        case .denied: notifications = .denied
        default: notifications = .unknown
        }
    }

    func requestAll() async {
        microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission {
                continuation.resume(returning: $0 ? .allowed : .denied)
            }
        }
        do {
            contacts = try await CNContactStore().requestAccess(for: .contacts) ? .allowed : .denied
        } catch { contacts = .denied }
        do {
            notifications = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound]) ? .allowed : .denied
        } catch { notifications = .denied }
    }
}
