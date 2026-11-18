import UIKit
import WebKit

/// يقرأ من حسابك في ChatGPT مباشرة (قائمة المحادثات، محادثة كاملة، الصور)
/// بنفس تسجيل الدخول المحفوظ في التطبيق. يعمل حتى والتطبيق في الخلفية،
/// لأنه لا يعتمد على الصفحة المفتوحة.
@MainActor
final class ChatGPTAccount {
    static let shared = ChatGPTAccount()

    enum AccountError: Error { case notLoggedIn, http(Int), badResponse }

    private let base = URL(string: "https://chatgpt.com")!
    private var token: String?
    private var cookieHeader = ""

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
        let path = "/backend-api/files/download/\(fileId)?conversation_id=\(conversationId)&inline=false"
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
        guard (200..<300).contains(code) else { throw AccountError.http(code) }
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

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (code == 401 || code == 403), retry {
            // انتهت الجلسة: نجدد من تسجيل الدخول المحفوظ ونحاول مرة
            token = nil
            await refreshCookies()
            return try await get(path, authorized: authorized, retry: false)
        }
        guard (200..<300).contains(code) else { throw AccountError.http(code) }
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
        cookieHeader = cookies
            .filter { $0.domain.hasSuffix("chatgpt.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}
