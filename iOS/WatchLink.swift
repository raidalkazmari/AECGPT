import UIKit
import WatchConnectivity

/// الاتصال بالساعة. يبدأ مع تشغيل التطبيق، حتى لو شغّلته الساعة في الخلفية.
/// - المحادثة: فورًا إن كانت الساعة مفتوحة، ونسخة محفوظة تصلها لو كانت نائمة.
///   المحادثات الطويلة جدًا تُرسل كملف.
/// - الصور: منفصلة، فورًا إن أمكن وإلا كملف.
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// آخر محادثة أُرسلت. محفوظة في الجوال، فتجدها الساعة حتى لو كان التطبيق مُغلقًا.
    private(set) var latest: ChatSnapshot = .empty
    private var lastContextPush = Date.distantPast
    private var lastSave = Date.distantPast

    private let savedKey = "lastSnapshotForWatch"
    /// أكبر حجم يُرسل كرسالة مباشرة (أكبر منه يُرسل كملف)
    private let messageLimit = 60_000

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

    /// "يكتب…" في أعلى الساعة أثناء كتابة الرد في الجوال
    func sendTyping(_ typing: Bool) {
        guard let session = readySession(), session.isReachable else { return }
        session.sendMessage(["typing": typing], replyHandler: nil, errorHandler: nil)
    }

    func sendList(_ items: [ConversationItem]) {
        guard let session = readySession(), let data = try? JSONEncoder().encode(items) else { return }
        if session.isReachable {
            session.sendMessage(["list": data], replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(["list": data])
        }
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

        if data.count > messageLimit {
            sendSnapshotFile(data, session: session)
            return
        }

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

    /// محادثة طويلة جدًا: ملف (بلا حد للحجم). نلغي أي ملف محادثة أقدم ما وصل بعد.
    private func sendSnapshotFile(_ data: Data, session: WCSession) {
        for transfer in session.outstandingFileTransfers where transfer.file.metadata?["snapshot"] != nil {
            transfer.cancel()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).bin")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        session.transferFile(url, metadata: ["snapshot": true])
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

    func hasImage(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.imageURL(key).path)
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
        if session.isReachable && data.count < messageLimit {
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
        var missing: [String] = []
        for key in keys.prefix(20) {
            let url = Self.imageURL(key)
            if let data = try? Data(contentsOf: url) {
                deliverImage(key: key, url: url, data: data)
            } else {
                missing.append(key)
            }
        }
        // ما هي عندنا بعد: نجيبها من حسابك
        if !missing.isEmpty, let id = latest.conversationId {
            ConversationService.shared.fetchImages(missing, conversationId: id)
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

    /// طلبات الساعة. إن كان التطبيق مُغلقًا، يشغّله iOS في الخلفية ليرد.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let sync = message["sync"] != nil
        let open = message["open"] as? String
        let wantsList = message["list"] != nil
        let need = message["need"] as? [String] ?? []
        Task { @MainActor in
            if sync {
                self.resend()                              // الموجود فورًا
                ConversationService.shared.showLatest()    // ثم آخر محادثة من حسابك
            }
            if let open { ConversationService.shared.userChose(open) }
            if wantsList { ConversationService.shared.sendRecentList() }
            if !need.isEmpty { self.resendImages(need) }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // ملفات المحادثة المؤقتة: نحذفها بعد الإرسال
        guard fileTransfer.file.metadata?["snapshot"] != nil else { return }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
