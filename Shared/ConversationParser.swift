import Foundation

/// محادثة كاملة مقروءة من حساب ChatGPT
struct ParsedConversation: Equatable {
    let id: String
    let title: String
    /// آخر تحديث بالملي ثانية
    let updated: Double
    let messages: [ChatMessage]
    /// صور من الإنترنت (نتائج بحث، روابط صور في الرد): المفتاح ← الرابط
    var webImages: [String: String] = [:]
}

/// يحوّل بيانات ChatGPT (JSON) إلى رسائل نظيفة للساعة.
///
/// المحادثة في ChatGPT شجرة (كل تعديل لسؤال يصنع فرعًا جديدًا)،
/// فنمشي من الرسالة الحالية (current_node) للأعلى، فنحصل على الفرع الظاهر فقط.
enum ConversationParser {

    enum ParseError: Error { case invalid }

    // MARK: - قائمة المحادثات

    static func parseList(_ data: Data) throws -> [ConversationItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { throw ParseError.invalid }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            if (item["is_archived"] as? Bool) == true { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "محادثة بدون عنوان"
            return ConversationItem(id: id, title: title, updated: millis(item["update_time"]))
        }
        .sorted { $0.updated > $1.updated }
    }

    // MARK: - محادثة كاملة

    static func parseConversation(_ data: Data, fallbackId: String = "") throws -> ParsedConversation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mapping = root["mapping"] as? [String: Any] else { throw ParseError.invalid }

        let id = (root["conversation_id"] as? String) ?? (root["id"] as? String) ?? fallbackId
        let title = (root["title"] as? String) ?? ""
        let updated = millis(root["update_time"])

        // الفرع الظاهر: من الرسالة الحالية إلى البداية
        var chain: [[String: Any]] = []
        var cursor = (root["current_node"] as? String) ?? lastLeaf(mapping)
        var seen = Set<String>()
        while let nodeId = cursor, !seen.contains(nodeId), let node = mapping[nodeId] as? [String: Any] {
            seen.insert(nodeId)
            if let message = node["message"] as? [String: Any] { chain.append(message) }
            cursor = node["parent"] as? String
        }
        chain.reverse()

        var messages: [ChatMessage] = []
        var webImages: [String: String] = [:]
        for message in chain {
            guard let piece = piece(from: message) else { continue }
            for (key, url) in piece.web { webImages[key] = url }
            if piece.role == "assistant", let last = messages.last, last.role == "assistant" {
                // أجزاء الرد الواحد (نص + صور أدوات) تُدمج في رسالة واحدة
                let text = [last.text, piece.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                let images = last.imageKeys + piece.images
                messages[messages.count - 1] = ChatMessage(id: last.id, role: "assistant", text: text,
                                                           images: images.isEmpty ? nil : images)
            } else {
                messages.append(ChatMessage(id: piece.id, role: piece.role, text: piece.text,
                                            images: piece.images.isEmpty ? nil : piece.images))
            }
        }
        // رسالة فاضية تمامًا (بدون نص ولا صور) لا تُعرض
        messages.removeAll { $0.text.isEmpty && $0.imageKeys.isEmpty }
        return ParsedConversation(id: id, title: title, updated: updated, messages: messages,
                                  webImages: webImages)
    }

    // MARK: - رسالة واحدة

    private struct Piece {
        let id: String
        let role: String
        let text: String
        let images: [String]
        var web: [(String, String)] = []
    }

    private static func piece(from message: [String: Any]) -> Piece? {
        let id = (message["id"] as? String) ?? UUID().uuidString
        let author = message["author"] as? [String: Any]
        let role = (author?["role"] as? String) ?? ""
        let metadata = message["metadata"] as? [String: Any] ?? [:]
        let content = message["content"] as? [String: Any] ?? [:]
        let type = (content["content_type"] as? String) ?? ""
        let recipient = (message["recipient"] as? String) ?? "all"

        if (metadata["is_visually_hidden_from_conversation"] as? Bool) == true { return nil }
        if let weight = number(message["weight"]), weight == 0 { return nil }

        switch role {
        case "user":
            guard type == "text" || type == "multimodal_text" else { return nil }
            let (text, images) = textAndImages(content)
            return Piece(id: id, role: "user", text: clean(text), images: images)

        case "assistant":
            // رسائل موجهة لأداة (بحث، كود...) وليست لك
            guard recipient == "all" else { return nil }
            guard type == "text" || type == "multimodal_text" else { return nil } // تفكير، كود أدوات...
            let (raw, images) = textAndImages(content)
            // صور من الإنترنت: داخل النص ![...](رابط) أو مرفقة كنتائج بحث
            let (text, inlineURLs) = extractMarkdownImages(raw)
            let urls = dedupe(inlineURLs + referencedImageURLs(metadata)).prefix(8)
            let web = urls.map { (webKey($0), $0) }
            return Piece(id: id, role: "assistant", text: clean(text),
                         images: images + web.map { $0.0 }, web: Array(web))

        case "tool":
            // نتائج الأدوات: نأخذ الصور فقط (صور مولّدة، رسوم بيانية من تحليل البيانات)
            var images = textAndImages(content).images
            if let aggregate = metadata["aggregate_result"] as? [String: Any],
               let outputs = aggregate["messages"] as? [[String: Any]] {
                for output in outputs where (output["message_type"] as? String) == "image" {
                    if let url = output["image_url"] as? String, let key = fileKey(url) { images.append(key) }
                }
            }
            return images.isEmpty ? nil : Piece(id: id, role: "assistant", text: "", images: images)

        default:
            return nil
        }
    }

    private static func textAndImages(_ content: [String: Any]) -> (text: String, images: [String]) {
        var texts: [String] = []
        var images: [String] = []
        for part in content["parts"] as? [Any] ?? [] {
            if let s = part as? String {
                texts.append(s)
            } else if let obj = part as? [String: Any],
                      (obj["content_type"] as? String) == "image_asset_pointer",
                      let pointer = obj["asset_pointer"] as? String,
                      let key = fileKey(pointer) {
                images.append(key)
            }
        }
        if texts.isEmpty, let s = content["text"] as? String { texts.append(s) }
        return (texts.joined(separator: "\n\n"), images)
    }

    /// "file-service://file-abc" أو "sediment://file_xyz" → رقم الملف
    static func fileKey(_ pointer: String) -> String? {
        for prefix in ["file-service://", "sediment://"] where pointer.hasPrefix(prefix) {
            let key = String(pointer.dropFirst(prefix.count))
            return key.isEmpty ? nil : key
        }
        return pointer.hasPrefix("file") ? pointer : nil
    }

    // MARK: - صور من الإنترنت

    private static let markdownImage = try! NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\((https?://[^)\\s]+)[^)]*\\)")

    /// يشيل ![وصف](رابط) من النص ويرجع الروابط
    static func extractMarkdownImages(_ text: String) -> (String, [String]) {
        let range = NSRange(text.startIndex..., in: text)
        let urls = markdownImage.matches(in: text, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
        guard !urls.isEmpty else { return (text, []) }
        let stripped = markdownImage.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (stripped, urls)
    }

    /// صور نتائج البحث المرفقة بالرد (مجموعات صور وبطاقات)
    static func referencedImageURLs(_ metadata: [String: Any]) -> [String] {
        guard let refs = metadata["content_references"] as? [[String: Any]] else { return [] }
        var urls: [String] = []
        for ref in refs {
            let type = ((ref["type"] as? String) ?? "").lowercased()
            guard type.contains("image") else { continue }
            let images = (ref["images"] as? [[String: Any]]) ?? [ref]
            for image in images {
                for field in ["thumbnail_url", "image_url", "content_url", "url"] {
                    if let url = image[field] as? String, url.hasPrefix("http") {
                        urls.append(url)
                        break
                    }
                }
            }
        }
        return urls
    }

    /// مفتاح ثابت لصورة من رابط (يصلح كاسم ملف)
    static func webKey(_ url: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "web-" + String(hash, radix: 16)
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - تنظيف النص

    private static let citationBlock = try! NSRegularExpression(pattern: "\u{E200}[^\u{E201}]*\u{E201}")
    private static let privateUse = try! NSRegularExpression(pattern: "[\u{E200}-\u{E2FF}]")
    private static let oldCitation = try! NSRegularExpression(pattern: "【[^】]*】")
    private static let extraSpaces = try! NSRegularExpression(pattern: "[ \t]+([.,،:;!?؟])")
    private static let manyBlankLines = try! NSRegularExpression(pattern: "\n{3,}")

    /// يشيل علامات المصادر الداخلية لـ ChatGPT (تظهر كرموز غريبة)
    static func clean(_ text: String) -> String {
        var s = text
        for (regex, replacement) in [(citationBlock, ""), (privateUse, ""), (oldCitation, ""),
                                     (extraSpaces, "$1"), (manyBlankLines, "\n\n")] {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                               withTemplate: replacement)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - مساعدات

    /// الوقت يأتي أحيانًا ثواني، وأحيانًا نص تاريخ
    static func millis(_ value: Any?) -> Double {
        if let n = number(value) { return n < 1e12 ? n * 1000 : n }
        if let s = value as? String {
            if let n = Double(s) { return n < 1e12 ? n * 1000 : n }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            // كسور ثوانٍ طويلة (6 أرقام): نشيلها ونحاول مرة ثانية
            let noFraction = s.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
            if let d = f.date(from: noFraction) { return d.timeIntervalSince1970 * 1000 }
        }
        return 0
    }

    /// رقم من JSON (قد يأتي Double أو Int أو NSNumber حسب النظام)
    static func number(_ value: Any?) -> Double? {
        if value is String { return nil }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// احتياط إذا ما فيه current_node: آخر عقدة بدون أبناء
    private static func lastLeaf(_ mapping: [String: Any]) -> String? {
        var best: (id: String, time: Double)?
        for (id, value) in mapping {
            guard let node = value as? [String: Any],
                  (node["children"] as? [Any])?.isEmpty ?? true else { continue }
            let t = millis((node["message"] as? [String: Any])?["create_time"])
            if best == nil || t > best!.time { best = (id, t) }
        }
        return best?.id
    }
}
