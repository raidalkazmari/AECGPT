import Foundation
import WatchConnectivity

/// يستقبل المحادثة من الجوال ويحفظها في الساعة، ويرسل طلباتك للجوال.
/// المحفوظ يبقى بعد قفل الشاشة أو إغلاق التطبيق أو إعادة تشغيل الساعة.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: ChatSnapshot
    /// هل الجوال في المدى ويمكن الوصول له الآن؟
    @Published private(set) var isConnected = false
    /// ChatGPT يكتب ردًا الآن (في الجوال)
    @Published private(set) var typing = false
    /// يزيد كلما وصلت صورة، فتتحدث الشاشة
    @Published private(set) var imagesVersion = 0
    /// المحادثات الأخيرة في حسابك
    @Published private(set) var conversations: [ConversationItem] = []
    @Published private(set) var listLoading = false
    /// طلبنا محادثة وننتظرها
    @Published private(set) var opening: String?
    /// صور ما قدر الجوال يجيبها: المفتاح ← السبب
    @Published private(set) var failedImages: [String: String] = [:]
    /// سؤال اخترته من الفهرس: الشاشة تنتقل له
    @Published var jumpTarget: String?

    private let storageKey = "lastSnapshot"
    private let listKey = "lastConversationList"
    private var lastNeedRequest = Date.distantPast

    override init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = ChatSnapshot.unpack(data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
        if let data = UserDefaults.standard.data(forKey: listKey),
           let list = try? JSONDecoder().decode([ConversationItem].self, from: data) {
            conversations = list
        }
        super.init()

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - طلباتك

    /// فتحت التطبيق: آخر محادثة في حسابك
    func requestLatest() {
        send(["sync": true])
        lastNeedRequest = .distantPast
        requestMissingImages()
    }

    /// اخترت محادثة من القائمة
    func open(_ id: String) {
        opening = id
        send(["open": id])
    }

    func requestList() {
        listLoading = true
        send(["list": true])
    }

    private func send(_ message: [String: Any]) {
        let session = WCSession.default
        isConnected = session.activationState == .activated && session.isReachable
        guard isConnected else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - من الجوال

    fileprivate func apply(_ data: Data) {
        guard let incoming = ChatSnapshot.unpack(data),
              incoming.stamp >= snapshot.stamp else { return }   // نتجاهل أي نسخة أقدم
        if incoming.conversationId != snapshot.conversationId { failedImages.removeAll() }
        snapshot = incoming
        if opening == nil || opening == incoming.conversationId { opening = nil }
        UserDefaults.standard.set(data, forKey: storageKey)
        requestMissingImages()
    }

    fileprivate func applyList(_ data: Data) {
        listLoading = false
        guard let list = try? JSONDecoder().decode([ConversationItem].self, from: data) else { return }
        conversations = list
        UserDefaults.standard.set(data, forKey: listKey)
    }

    fileprivate func setTyping(_ value: Bool) { typing = value }
    fileprivate func setConnected(_ value: Bool) { isConnected = value }
    fileprivate func imageArrived() { imagesVersion += 1 }
    fileprivate func imageFailed(_ key: String, reason: String) { failedImages[key] = reason }

    /// يطلب من الجوال الصور التي في المحادثة وليست عندنا (مرة كل 5 ثوانٍ كحد أقصى)
    func requestMissingImages() {
        let missing = snapshot.allImageKeys.filter { !WatchImages.has($0) && failedImages[$0] == nil }
        guard !missing.isEmpty, Date().timeIntervalSince(lastNeedRequest) > 5 else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        lastNeedRequest = Date()
        session.sendMessage(["need": Array(missing.suffix(20))], replyHandler: nil, errorHandler: nil)
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let saved = session.receivedApplicationContext[ChatSnapshot.key] as? Data
        let reachable = session.isReachable
        Task { @MainActor in
            self.setConnected(reachable)
            if let saved { self.apply(saved) }
            self.requestLatest()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.setConnected(reachable)
            if reachable { self.requestLatest() } else { self.setTyping(false) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let key = message["img"] as? String, let data = message["data"] as? Data {
            WatchImages.save(key, data: data)
            Task { @MainActor in self.imageArrived() }
            return
        }
        if let key = message["imgFailed"] as? String {
            let reason = message["reason"] as? String ?? ""
            Task { @MainActor in self.imageFailed(key, reason: reason) }
            return
        }
        if let typing = message["typing"] as? Bool {
            Task { @MainActor in self.setTyping(typing) }
            return
        }
        if let list = message["list"] as? Data {
            Task { @MainActor in self.applyList(list) }
            return
        }
        guard let data = message[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[ChatSnapshot.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let key = userInfo["imgFailed"] as? String {
            let reason = userInfo["reason"] as? String ?? ""
            Task { @MainActor in self.imageFailed(key, reason: reason) }
            return
        }
        guard let list = userInfo["list"] as? Data else { return }
        Task { @MainActor in self.applyList(list) }
    }

    /// ملف من الجوال: صورة، أو محادثة طويلة جدًا
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if let key = file.metadata?["img"] as? String {
            WatchImages.saveFile(key, from: file.fileURL)
            Task { @MainActor in self.imageArrived() }
        } else if file.metadata?["snapshot"] != nil, let data = try? Data(contentsOf: file.fileURL) {
            Task { @MainActor in self.apply(data) }
        }
    }
}
