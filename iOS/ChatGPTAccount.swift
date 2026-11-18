import UIKit
import WebKit

/// يقرأ من حسابك في ChatGPT مباشرة (قائمة المحادثات، محادثة كاملة، الصور)
/// بنفس تسجيل الدخول المحفوظ في التطبيق. يعمل حتى والتطبيق في الخلفية،
/// لأنه لا يعتمد على الصفحة المفتوحة.
@MainActor
final class ChatGPTAccount {
    static let shared = ChatGPTAccount()

    enum AccountError: Error {
        case notLoggedIn, badResponse
        /// رمز الخطأ + السبب كما قاله الخادم (مختصر)
        case http(Int, String)
    }

    /// يستخرج سبب الرفض من رد الخادم، مثل: query.conversation_id: field required
    static func reason(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(80), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let detail = json["detail"] ?? json["error"] ?? json["message"]
        if let text = detail as? String { return String(text.prefix(80)) }
        if let list = detail as? [[String: Any]], let first = list.first {
            let loc = (first["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? ""
            let msg = first["msg"] as? String ?? ""
            return String((loc.isEmpty ? msg : "\(loc): \(msg)").prefix(80))
        }
        if let obj = detail as? [String: Any], let msg = obj["message"] as? String { return String(msg.prefix(80)) }
        return ""
    }

    private let base = URL(string: "https://chatgpt.com")!
    private var token: String?
    private var cookieHeader = ""
    /// رقم الجهاز اللي يعطيه ChatGPT للمتصفح (كوكي oai-did)
    private var deviceId = ""
    /// الصفحة اللي "جاي منها" الطلب
    var referer = "https://chatgpt.com/"

    private let uaKey = "chatgptUserAgent"
    /// نفس هوية متصفح التطبيق، حتى يتعامل معنا ChatGPT مثل الصفحة
    var userAgent: String? {
        get { UserDefaults.standard.string(forKey: uaKey) }
        set { UserDefaults.standard.set(newValue, forKey: uaKey) }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: - واجهة

    func recentConversations(limit: Int = 20) async throws -> [ConversationItem] {
        let data = try await get("/backend-api/conversations?offset=0&limit=\(limit)&order=updated")
        return try ConversationParser.parseList(data)
    }

    func conversation(_ id: String) async throws -> ParsedConversation {
        let data = try await get("/backend-api/conversation/\(id)")
        return try ConversationParser.parseConversation(data, fallbackId: id)
    }

    /// يحمّل صورة من المحادثة (مرفوعة، مولّدة، أو رسم بياني)
    func image(fileId: String, conversationId: String) async throws -> Data {
        referer = "https://chatgpt.com/c/\(conversationId)"
        do {
            return try await downloadFile("/backend-api/files/download/\(fileId)?conversation_id=\(conversationId)&inline=false")
        } catch {
            // محاولة ثانية بالطريقة الأخرى اللي يستخدمها ChatGPT لبعض الصور المولدة
            if let data = try? await downloadFile("/backend-api/files/\(fileId)/download") { return data }
            throw error
        }
    }

    /// صورة من الإنترنت (نتائج بحث): لا تحتاج تسجيل دخول
    func webImage(_ link: String) async throws -> Data {
        guard let url = URL(string: link) else { throw AccountError.badResponse }
        var request = URLRequest(url: url)
        if let ua = userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        // نفس اللي يرسله المتصفح لما يعرض الصورة داخل ChatGPT
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if url.host?.hasSuffix("openai.com") == true || url.host?.hasSuffix("chatgpt.com") == true {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AccountError.http(code, Self.reason(data)) }
        return data
    }

    private func downloadFile(_ path: String) async throws -> Data {
        let info = try await get(path)
        guard let json = try JSONSerialization.jsonObject(with: info) as? [String: Any],
              let link = json["download_url"] as? String,
              let url = URL(string: link, relativeTo: base)?.absoluteURL else { throw AccountError.badResponse }
        if url.host?.hasSuffix("chatgpt.com") == true {
            return try await get(url.absoluteString)
        }
        // رابط موقّع خارجي: لا يحتاج تسجيل دخول
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw AccountError.http(code, Self.reason(data)) }
        return data
    }

    // MARK: - الطلبات

    private func get(_ path: String, authorized: Bool = true, retry: Bool = true) async throws -> Data {
        if cookieHeader.isEmpty { await refreshCookies() }
        if authorized, token == nil { try await refreshToken() }

        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw AccountError.badResponse }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ua = userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if authorized, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // رؤوس يرسلها موقع ChatGPT نفسه مع كل طلب (بعض الطلبات ترفض بدونها)
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if !deviceId.isEmpty { request.setValue(deviceId, forHTTPHeaderField: "OAI-Device-Id") }
        request.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "OAI-Language")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (code == 401 || code == 403), retry {
            // انتهت الجلسة: نجدد من تسجيل الدخول المحفوظ ونحاول مرة
            token = nil
            await refreshCookies()
            return try await get(path, authorized: authorized, retry: false)
        }
        guard (200..<300).contains(code) else { throw AccountError.http(code, Self.reason(data)) }
        return data
    }

    private func refreshToken() async throws {
        let data = try await get("/api/auth/session", authorized: false, retry: false)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty else { throw AccountError.notLoggedIn }
        self.token = token
    }

    /// كوكيز ChatGPT من متصفح التطبيق (تسجيل الدخول)
    func refreshCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        deviceId = cookies.first { $0.name == "oai-did" && $0.domain.hasSuffix("chatgpt.com") }?.value ?? deviceId
        cookieHeader = cookies
            .filter { $0.domain.hasSuffix("chatgpt.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
