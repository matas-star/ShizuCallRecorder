import PushKit
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VoIPPushManager.shared.start()
        return true
    }
}

final class VoIPPushManager: NSObject, PKPushRegistryDelegate {
    static let shared = VoIPPushManager()

    private var registry: PKPushRegistry?
    private var pending: [(payload: [AnyHashable: Any], completion: () -> Void)] = []
    var onPayload: (([AnyHashable: Any], @escaping () -> Void) -> Void)? {
        didSet { drainPending() }
    }

    var token: String? {
        get { UserDefaults.standard.string(forKey: "voipPushToken") }
        set { UserDefaults.standard.set(newValue, forKey: "voipPushToken") }
    }

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        token = credentials.token.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .voipTokenChanged, object: nil)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        token = nil
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        if let onPayload { onPayload(payload.dictionaryPayload, completion) }
        else { pending.append((payload.dictionaryPayload, completion)) }
    }

    private func drainPending() {
        guard let onPayload else { return }
        let queued = pending
        pending.removeAll()
        queued.forEach { onPayload($0.payload, $0.completion) }
    }
}

extension Notification.Name {
    static let voipTokenChanged = Notification.Name("voipTokenChanged")
}
