import Foundation
import WatchConnectivity

/// يستقبل المحادثة من الجوال ويحفظها في الساعة.
/// المحفوظ يبقى بعد قفل الشاشة أو إغلاق التطبيق أو إعادة تشغيل الساعة.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: ChatSnapshot
    /// هل الجوال في المدى ويمكن الوصول له الآن؟
    @Published private(set) var isConnected = false
    /// يزيد كلما وصلت صورة، فتتحدث الشاشة
    @Published private(set) var imagesVersion = 0
    private var lastNeedRequest = Date.distantPast

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
        requestMissingImages()
    }

    fileprivate func imageArrived() {
        imagesVersion += 1
    }

    /// يطلب من الجوال الصور التي في المحادثة وليست عندنا (مرة كل 5 ثوانٍ كحد أقصى)
    func requestMissingImages() {
        let missing = snapshot.allImageKeys.filter { !WatchImages.has($0) }
        guard !missing.isEmpty, Date().timeIntervalSince(lastNeedRequest) > 5 else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        lastNeedRequest = Date()
        session.sendMessage(["need": Array(missing.suffix(20))], replyHandler: nil, errorHandler: nil)
    }

    /// يطلب من الجوال آخر نسخة (عند فتح التطبيق).
    func requestSync() {
        let session = WCSession.default
        isConnected = session.activationState == .activated && session.isReachable
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["sync": true], replyHandler: nil, errorHandler: nil)
        lastNeedRequest = .distantPast
        requestMissingImages()
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
        if let key = message["img"] as? String, let data = message["data"] as? Data {
            WatchImages.save(key, data: data)
            Task { @MainActor in self.imageArrived() }
            return
        }
        guard let data = message[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    /// صورة وصلت كملف (والساعة كانت نائمة أو الصورة كبيرة)
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let key = file.metadata?["img"] as? String else { return }
        WatchImages.saveFile(key, from: file.fileURL)
        Task { @MainActor in self.imageArrived() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }
}
