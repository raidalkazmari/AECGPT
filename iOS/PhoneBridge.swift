import UIKit
import WebKit

/// قلب تطبيق الجوال: يعرض chatgpt.com، يستقبل المحادثة من السكربت،
/// ويسلّمها لـ WatchLink ليرسلها للساعة.
@MainActor
final class PhoneBridge: NSObject, ObservableObject {
    let webView: WKWebView

    private let home = "https://chatgpt.com"
    private let lastPathKey = "lastConversationPath"
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
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
        // يعرّف نفسه كـ Safari بنفس إصدار iOS الذي في جوالك، فيعرض الموقع نفس واجهة Safari
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        config.applicationNameForUserAgent = "Version/\(version) Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true

        super.init()
        handler.owner = self
        webView.uiDelegate = self

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
        guard let dict = body as? [String: Any] else { return }

        // السكربت لم يجد الرسائل: نعرض وصف الصفحة على الساعة للتشخيص
        if let diagnostic = dict["diagnostic"] as? String {
            let snapshot = ChatSnapshot(title: "تشخيص",
                                        messages: [ChatMessage(id: "diagnostic", role: "assistant", text: diagnostic)],
                                        streaming: false,
                                        stamp: Date().timeIntervalSince1970)
            WatchLink.shared.update(snapshot)
            return
        }

        guard let rawMessages = dict["messages"] as? [[String: Any]] else { return }

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

        guard !snapshot.hasSameContent(as: WatchLink.shared.latest) else { return }
        WatchLink.shared.update(snapshot)
    }

    // MARK: - الخلفية وقفل الشاشة

    @objc private func didEnterBackground() {
        WatchLink.shared.resendOrClear()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AECGPT.sync") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
        WatchLink.shared.resendOrClear()
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

// MARK: - مستقبل رسائل السكربت (مرجع ضعيف لتجنب تسرب الذاكرة)

@MainActor
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PhoneBridge?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}
