import UIKit
import WatchConnectivity

/// الاتصال بالساعة. يبدأ مع تشغيل التطبيق، حتى لو شغّلته الساعة في الخلفية.
/// المحادثة تُرسل بطريقتين معًا:
/// 1) فورًا إذا كانت الساعة مفتوحة (sendMessage)
/// 2) نسخة محفوظة تصل للساعة حتى لو كانت نائمة (applicationContext)
/// والصور تُرسل منفصلة: فورًا إن أمكن، وإلا كملف يصل لاحقًا (transferFile).
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// آخر محادثة. تُحفظ في الجوال، فتجدها الساعة حتى لو كان التطبيق مُغلقًا.
    private(set) var latest: ChatSnapshot = .empty
    private var lastContextPush = Date.distantPast
    private var lastSave = Date.distantPast

    private let savedKey = "lastSnapshotForWatch"

    func start() {
        if let data = UserDefaults.standard.data(forKey: savedKey),
           let saved = ChatSnapshot.unpack(data) {
            latest = saved
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(_ snapshot: ChatSnapshot) {
        latest = snapshot
        save(snapshot)
        push(snapshot)
    }

    /// يعيد إرسال آخر محادثة (المحفوظة إن كان التطبيق بدأ للتو).
    func resend() {
        guard latest.stamp > 0 else { return }
        push(latest, forceSave: true)
    }

    private func save(_ snapshot: ChatSnapshot) {
        let now = Date()
        // أثناء كتابة الرد نحفظ كل ثانيتين فقط، وعند اكتماله فورًا
        guard !snapshot.streaming || now.timeIntervalSince(lastSave) >= 2,
              let data = snapshot.trimmed().packed() else { return }
        lastSave = now
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    private func push(_ snapshot: ChatSnapshot, forceSave: Bool = false) {
        guard let session = readySession(), let data = snapshot.trimmed().packed() else { return }

        let payload: [String: Any] = [ChatSnapshot.key: data]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }

        // النسخة المحفوظة: فورًا عند اكتمال الرد، وكل ثانية أثناء الكتابة
        let now = Date()
        if forceSave || !snapshot.streaming || now.timeIntervalSince(lastContextPush) >= 1 {
            lastContextPush = now
            try? session.updateApplicationContext(payload)
        }
    }

    private func readySession() -> WCSession? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return nil }
        return session
    }

    // MARK: - الصور

    private static let imageDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func imageURL(_ key: String) -> URL {
        imageDir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    /// يحفظ الصورة في الجوال ويرسلها للساعة.
    func sendImage(key: String, jpeg: Data) {
        let url = Self.imageURL(key)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? jpeg.write(to: url, options: .atomic)
            pruneImages()
        }
        deliverImage(key: key, url: url, data: jpeg)
    }

    private func deliverImage(key: String, url: URL, data: Data) {
        guard let session = readySession() else { return }
        // صغيرة والساعة مفتوحة: فورًا. وإلا ملف يصل حتى لو كانت الساعة نائمة
        if session.isReachable && data.count < 60_000 {
            session.sendMessage(["img": key, "data": data], replyHandler: nil) { _ in
                Task { @MainActor in
                    _ = self.readySession()?.transferFile(url, metadata: ["img": key])
                }
            }
        } else {
            session.transferFile(url, metadata: ["img": key])
        }
    }

    /// الساعة طلبت صورًا ناقصة عندها
    fileprivate func resendImages(_ keys: [String]) {
        for key in keys.prefix(20) {
            let url = Self.imageURL(key)
            guard let data = try? Data(contentsOf: url) else { continue }
            deliverImage(key: key, url: url, data: data)
        }
    }

    /// نبقي آخر 150 صورة فقط في الجوال
    private func pruneImages() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.imageDir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 150 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - 150) { try? fm.removeItem(at: file) }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.resend() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.resend() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.resend() }
    }

    /// الساعة تسأل عند فتحها عن آخر محادثة، أو عن صور ناقصة.
    /// إن كان التطبيق مُغلقًا، يشغّله iOS في الخلفية ويرد بالمحادثة المحفوظة.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let sync = message["sync"] != nil
        let need = message["need"] as? [String] ?? []
        Task { @MainActor in
            if sync { self.resend() }
            if !need.isEmpty { self.resendImages(need) }
        }
    }
}
