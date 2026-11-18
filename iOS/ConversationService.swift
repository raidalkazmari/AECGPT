import UIKit

/// يقرر أي محادثة تظهر في الساعة، ويجيبها كاملة من حسابك ويرسلها.
///
/// القاعدة:
/// - افتراضيًا: آخر محادثة تحدّثت في حسابك (من أي جهاز).
/// - إذا اخترت محادثة بنفسك (من الجوال أو الساعة) تبقى عليها،
///   إلى أن يصير نشاط جديد في محادثة ثانية بعد اختيارك.
@MainActor
final class ConversationService {
    static let shared = ConversationService()

    private let account = ChatGPTAccount.shared

    // اختيارك اليدوي الأخير
    private let manualIdKey = "manualConversationId"
    private let manualAtKey = "manualChoiceAt"
    private var manualId: String? {
        get { UserDefaults.standard.string(forKey: manualIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: manualIdKey) }
    }
    private var manualAt: Double {
        get { UserDefaults.standard.double(forKey: manualAtKey) }
        set { UserDefaults.standard.set(newValue, forKey: manualAtKey) }
    }

    /// آخر محادثة أُرسلت للساعة ووقت تحديثها
    private var shown: (id: String, updated: Double)?
    /// روابط صور الإنترنت في المحادثة المعروضة
    private var webImages: [String: String] = [:]
    private var webFallbacks: [String: [String]] = [:]
    private var loading: String?
    /// هل القراءة من الحساب شغّالة؟ لو تعطلت نرجع مؤقتًا لنسخ الصفحة
    private(set) var accountWorks = true

    // MARK: - طلبات

    /// الساعة انفتحت أو تحدّثت: آخر محادثة (أو اختيارك إن كان أحدث)
    func showLatest() {
        run { [self] in
            let recent = try await account.recentConversations(limit: 5)
            guard let top = recent.first else { return }
            let target: String
            if let manualId, manualAt > top.updated {
                target = manualId
            } else {
                target = top.id
            }
            // نفس المحادثة وما تغيّرت: نعيد إرسال الموجود فقط
            if let shown, shown.id == target, target != top.id || shown.updated >= top.updated {
                WatchLink.shared.resend()
                return
            }
            try await load(target)
        }
    }

    /// اخترت محادثة (من الجوال أو من قائمة الساعة)
    func userChose(_ id: String) {
        manualId = id
        manualAt = Date().timeIntervalSince1970 * 1000
        run { [self] in try await load(id) }
    }

    /// انتهى رد في الصفحة: نحدّث المحادثة المعروضة لو هي نفسها
    func pageReplyFinished(conversationId: String) {
        guard shown?.id == conversationId || manualId == conversationId else { return }
        run { [self] in try await load(conversationId) }
    }

    /// قائمة المحادثات الأخيرة للساعة
    func sendRecentList() {
        run { [self] in
            let items = try await account.recentConversations(limit: 25)
            WatchLink.shared.sendList(items)
        }
    }

    // MARK: - التحميل

    private func load(_ id: String) async throws {
        guard loading != id else { return }
        loading = id
        defer { loading = nil }

        let conversation = try await account.conversation(id)
        let snapshot = ChatSnapshot(title: conversation.title,
                                    messages: conversation.messages,
                                    streaming: false,
                                    stamp: Date().timeIntervalSince1970,
                                    conversationId: conversation.id)
        shown = (conversation.id, conversation.updated)
        webImages = conversation.webImages
        webFallbacks = conversation.webImageFallbacks
        WatchLink.shared.update(snapshot)
        await sendImages(of: conversation)
    }

    /// الساعة طلبت صورًا ما هي عندنا
    func fetchImages(_ keys: [String], conversationId: String) {
        run { [self] in
            for key in keys where !WatchLink.shared.hasImage(key) {
                await deliver(key, conversationId: conversationId)
            }
        }
    }

    /// الصور الناقصة: نحمّلها، نصغّرها، ونرسلها (آخرها أولًا)
    private func sendImages(of conversation: ParsedConversation) async {
        let keys = conversation.messages.flatMap(\.imageKeys).reversed()
        for key in keys.prefix(30) where !WatchLink.shared.hasImage(key) {
            await deliver(key, conversationId: conversation.id)
        }
    }

    /// صورة واحدة: من حسابك أو من الإنترنت. لو فشلت نقول للساعة السبب بالضبط بدل الانتظار
    private func deliver(_ key: String, conversationId: String) async {
        let fromWeb = webImages[key] != nil
        let source = fromWeb ? "بحث" : "ChatGPT"
        do {
            let data: Data
            if let link = webImages[key] {
                data = try await firstWorking([link] + (webFallbacks[key] ?? []))
            } else {
                data = try await account.image(fileId: key, conversationId: conversationId)
            }
            guard let image = UIImage(data: data), let jpeg = PhoneBridge.shrinkForWatch(image) else {
                WatchLink.shared.sendImageFailed(key, reason: "\(source): صيغة غير مدعومة")
                return
            }
            WatchLink.shared.sendImage(key: key, jpeg: jpeg)
        } catch ChatGPTAccount.AccountError.http(let code, let detail) {
            let id = fromWeb ? "" : " " + String(key.prefix(14))
            WatchLink.shared.sendImageFailed(key, reason: "\(source) \(code)\(id)\(detail.isEmpty ? "" : " · " + detail)")
        } catch {
            WatchLink.shared.sendImageFailed(key, reason: "\(source): \(error.localizedDescription.prefix(60))")
        }
    }

    /// يجرب روابط الصورة واحد واحد، ويرجع خطأ الأول لو كلها فشلت
    private func firstWorking(_ links: [String]) async throws -> Data {
        var firstError: Error?
        for link in links {
            do {
                let data = try await account.webImage(link)
                if UIImage(data: data) != nil { return data } // صفحة ويب وليست صورة: نكمل
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? ChatGPTAccount.AccountError.badResponse
    }

    /// يشغّل العملية، ويطلب من iOS وقتًا إضافيًا لو التطبيق في الخلفية
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "AECGPT.conversation") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        Task { @MainActor in
            do {
                try await work()
                self.accountWorks = true
            } catch {
                self.accountWorks = false
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
