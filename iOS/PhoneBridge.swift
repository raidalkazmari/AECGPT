import UIKit
import WebKit

/// قلب تطبيق الجوال: يعرض chatgpt.com (لتسجيل الدخول واختيار المحادثة).
/// الساعة تأخذ المحادثة كاملة من حسابك عبر ConversationService، والصفحة تخبرنا فقط
/// أي محادثة اخترت، ومتى يكتب ChatGPT.
@MainActor
final class PhoneBridge: NSObject, ObservableObject {
    let webView: WKWebView

    private let home = "https://chatgpt.com"
    private let lastPathKey = "lastConversationPath"
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// الصفحة تعطلت أو فشل تحميلها، وتحتاج إعادة تحميل
    private var needsReload = false
    private var retryScheduled = false

    private var lastSeenPath: String?
    /// ChatGPT يكتب ردًا الآن في الصفحة؟
    private var pageStreaming = false

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
        // يمنع "الدقرة": لا نضيف هوامش من عندنا فوق هوامش الصفحة، ولا ارتداد للصفحة كلها
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false

        super.init()
        handler.owner = self
        webView.uiDelegate = self
        webView.navigationDelegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        loadStart()
    }

    /// يفتح آخر محادثة كانت مفتوحة
    private func loadStart() {
        let path = UserDefaults.standard.string(forKey: lastPathKey) ?? "/"
        let url = URL(string: home + (path.hasPrefix("/") ? path : "/")) ?? URL(string: home)!
        webView.load(URLRequest(url: url))
    }

    /// يعيد التحميل: الصفحة الحالية إن وُجدت، وإلا آخر محادثة
    private func recover() {
        needsReload = false
        if webView.url != nil { webView.reload() } else { loadStart() }
    }

    /// فشل التحميل (غالبًا انقطاع النت): يحاول مرة ثانية كل 5 ثوانٍ ما دام التطبيق مفتوحًا
    private func scheduleRetry() {
        needsReload = true
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.needsReload else { return }
            if UIApplication.shared.applicationState == .active { self.recover() } else { self.scheduleRetry() }
        }
    }

    // MARK: - من الصفحة

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }

        // أي محادثة مفتوحة، وهل ChatGPT يكتب الآن
        let path = dict["path"] as? String
        if let path {
            trackNavigation(path)
            if path.contains("/c/") { UserDefaults.standard.set(path, forKey: lastPathKey) }
        }
        if dict["messages"] != nil {
            let streaming = (dict["streaming"] as? Bool) ?? false
            if streaming != pageStreaming {
                pageStreaming = streaming
                WatchLink.shared.sendTyping(streaming)
                if !streaming, let id = path.flatMap(Self.conversationId) {
                    ConversationService.shared.pageReplyFinished(conversationId: id)
                }
            }
        }

        // القراءة من الحساب شغّالة: هذا كل اللي نحتاجه من الصفحة
        guard !ConversationService.shared.accountWorks else { return }

        // ---- وضع احتياطي (القراءة من الحساب تعطلت): نرسل نسخة الصفحة كما كان سابقًا

        if let diagnostic = dict["diagnostic"] as? String {
            let snapshot = ChatSnapshot(title: "تشخيص",
                                        messages: [ChatMessage(id: "diagnostic", role: "assistant", text: diagnostic)],
                                        streaming: false,
                                        stamp: Date().timeIntervalSince1970)
            WatchLink.shared.update(snapshot)
            return
        }

        if let key = dict["image"] as? String {
            if let b64 = dict["data"] as? String, let data = Data(base64Encoded: b64) {
                WatchLink.shared.sendImage(key: key, jpeg: data)
            } else if let link = dict["url"] as? String, let url = URL(string: link) {
                Task { await Self.downloadImage(key: key, url: url) }
            }
            return
        }

        guard let rawMessages = dict["messages"] as? [[String: Any]] else { return }
        let messages: [ChatMessage] = rawMessages.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let role = raw["role"] as? String,
                  let text = raw["text"] as? String else { return nil }
            let images = raw["images"] as? [String]
            return ChatMessage(id: id, role: role, text: text,
                               images: (images?.isEmpty ?? true) ? nil : images)
        }
        let snapshot = ChatSnapshot(title: (dict["title"] as? String) ?? "",
                                    messages: messages,
                                    streaming: (dict["streaming"] as? Bool) ?? false,
                                    stamp: Date().timeIntervalSince1970,
                                    conversationId: path.flatMap(Self.conversationId))
        guard !snapshot.hasSameContent(as: WatchLink.shared.latest) else { return }
        WatchLink.shared.update(snapshot)
    }

    // MARK: - اختيارك من الجوال

    /// انتقلت لمحادثة ثانية في الصفحة: تصير هي اللي في الساعة
    private func trackNavigation(_ path: String) {
        defer { lastSeenPath = path }
        guard let previous = lastSeenPath, previous != path,
              let id = Self.conversationId(path) else { return }
        ConversationService.shared.userChose(id)
    }

    static func conversationId(_ path: String) -> String? {
        guard let range = path.range(of: "/c/") else { return nil }
        let id = path[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return id.isEmpty ? nil : String(id)
    }

    // MARK: - صور من مواقع خارجية (مثل صور نتائج البحث)

    private static func downloadImage(key: String, url: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data),
              let jpeg = shrinkForWatch(image) else { return }
        await MainActor.run { WatchLink.shared.sendImage(key: key, jpeg: jpeg) }
    }

    /// يصغّر الصورة لعرض شاشة الساعة، بخلفية بيضاء للرسوم الشفافة
    static func shrinkForWatch(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 396 / size.width, 900 / size.height)
        let target = CGSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.72)
    }

    // MARK: - الخلفية وقفل الشاشة

    @objc private func didEnterBackground() {
        WatchLink.shared.resend()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AECGPT.sync") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    @objc private func willEnterForeground() {
        endBackgroundTask()
        // إذا تعطلت الصفحة وأنت خارج التطبيق، تُصلَح قبل أن تراها
        if needsReload || webView.url == nil { recover() }
        WatchLink.shared.resend()
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

// MARK: - إصلاح ذاتي للصفحة

extension PhoneBridge: WKNavigationDelegate {
    /// iOS أوقف محرك الصفحة (ضغط ذاكرة): بدل الصفحة البيضاء نعيد التحميل فورًا
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if UIApplication.shared.applicationState == .active {
            recover()
        } else {
            needsReload = true
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        needsReload = false
        // نحفظ هوية المتصفح وتسجيل الدخول، حتى نقرأ من حسابك والتطبيق في الخلفية
        webView.evaluateJavaScript("navigator.userAgent") { value, _ in
            if let ua = value as? String { ChatGPTAccount.shared.userAgent = ua }
        }
        Task {
            await ChatGPTAccount.shared.refreshCookies()
            // أول مرة (أو بعد تسجيل الدخول): الساعة تاخذ آخر محادثة
            if WatchLink.shared.latest.conversationId == nil {
                ConversationService.shared.showLatest()
            }
        }
    }

    private func handleLoadError(_ error: Error) {
        let e = error as NSError
        // إلغاء التحميل بسبب الانتقال لصفحة أخرى ليس خطأ
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return } // تحميل قاطعه تنزيل/رابط خارجي
        scheduleRetry()
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
