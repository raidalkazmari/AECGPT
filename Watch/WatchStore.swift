import Foundation
import WatchConnectivity

/// يستقبل المحادثة من الجوال ويحفظها في الساعة.
/// المحفوظ يبقى بعد قفل الشاشة أو إغلاق التطبيق أو إعادة تشغيل الساعة.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: ChatSnapshot
    /// هل الجوال في المدى ويمكن الوصول له الآن؟
    @Published private(set) var isConnected = false

    private let storageKey = "lastSnapshot"

    override init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = ChatSnapshot.unpack(data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
        super.init()

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    fileprivate func apply(_ data: Data) {
        guard let incoming = ChatSnapshot.unpack(data),
              incoming.stamp >= snapshot.stamp else { return }   // نتجاهل أي نسخة أقدم
        snapshot = incoming
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// يطلب من الجوال آخر نسخة (عند فتح التطبيق).
    func requestSync() {
        let session = WCSession.default
        isConnected = session.activationState == .activated && session.isReachable
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["sync": true], replyHandler: nil, errorHandler: nil)
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let saved = session.receivedApplicationContext[ChatSnapshot.key] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if let saved { self.apply(saved) }
            self.requestSync()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if reachable { self.requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }
}
