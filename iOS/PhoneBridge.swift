import UIKit
import WebKit
import WatchConnectivity

/// قلب تطبيق الجوال: يعرض chatgpt.com، يستقبل المحادثة من السكربت،
/// ويرسلها للساعة بطريقتين معًا:
/// 1) فورًا إذا كانت الساعة مفتوحة (sendMessage)
/// 2) نسخة محفوظة تصل للساعة حتى لو كانت نائمة (applicationContext)
@MainActor
final class PhoneBridge: NSObject, ObservableObject {
    static let shared = PhoneBridge()

    let webView: WKWebView

    private let home = "https://chatgpt.com"
    private let lastPathKey = "lastConversationPath"
    private var latest: ChatSnapshot = .empty
    private var lastContextPush = Date.distantPast
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        let handler = ScriptHandler()
        let controller = WKUserContentController()
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: source,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        controller.add(handler, name: "aecgpt")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()   // يحفظ تسجيل الدخول
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

        super.init()
        handler.owner = self
        webView.uiDelegate = self

        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        // يفتح آخر محادثة كانت مفتوحة
        let path = UserDefaults.standard.string(forKey: lastPathKey) ?? "/"
        let url = URL(string: home + (path.hasPrefix("/") ? path : "/")) ?? URL(string: home)!
        webView.load(URLRequest(url: url))
    }

    // MARK: - من الصفحة

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any],
              let rawMessages = dict["messages"] as? [[String: Any]] else { return }

        let messages: [ChatMessage] = rawMessages.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let role = raw["role"] as? String,
                  let text = raw["text"] as? String else { return nil }
            return ChatMessage(id: id, role: role, text: text)
        }

        if let path = dict["path"] as? String, path.contains("/c/") {
            UserDefaults.standard.set(path, forKey: lastPathKey)
        }

        let snapshot = ChatSnapshot(title: (dict["title"] as? String) ?? "",
                                    messages: messages,
                                    streaming: (dict["streaming"] as? Bool) ?? false,
                                    stamp: Date().timeIntervalSince1970)

        guard !snapshot.hasSameContent(as: latest) else { return }
        latest = snapshot
        push(snapshot)
    }

    // MARK: - إلى الساعة

    private func push(_ snapshot: ChatSnapshot, forceSave: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              let data = snapshot.trimmed().packed() else { return }

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

    fileprivate func resend() {
        guard latest.stamp > 0 else { return }   // لا نمسح الساعة عند تشغيل التطبيق
        push(latest, forceSave: true)
    }

    // MARK: - الخلفية وقفل الشاشة

    @objc private func didEnterBackground() {
        resend()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AECGPT.sync") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
        resend()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - نوافذ تسجيل الدخول المنبثقة تفتح في نفس الصفحة

extension PhoneBridge: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - WatchConnectivity

extension PhoneBridge: WCSessionDelegate {
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

    /// الساعة تطلب آخر نسخة عند فتحها.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["sync"] != nil else { return }
        Task { @MainActor in self.resend() }
    }
}

// MARK: - مستقبل رسائل السكربت (مرجع ضعيف لتجنب تسرب الذاكرة)

@MainActor
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PhoneBridge?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}
