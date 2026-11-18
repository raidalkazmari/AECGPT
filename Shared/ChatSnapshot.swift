import Foundation

/// المحادثة المعروضة في الساعة، كاملة.
struct ChatSnapshot: Codable, Equatable {
    var title: String
    var messages: [ChatMessage]
    var streaming: Bool
    /// وقت إنشاء النسخة. الساعة تتجاهل أي نسخة أقدم من التي عندها.
    var stamp: Double
    /// رقم المحادثة في ChatGPT
    var conversationId: String? = nil

    static let key = "snapshot"
    /// كل مفاتيح الصور في المحادثة
    var allImageKeys: [String] { messages.flatMap(\.imageKeys) }
    static let empty = ChatSnapshot(title: "", messages: [], streaming: false, stamp: 0)

    func hasSameContent(as other: ChatSnapshot) -> Bool {
        title == other.title && streaming == other.streaming && messages == other.messages
            && conversationId == other.conversationId
    }

    /// حد أعلى لحجم المحادثة (محادثات طويلة جدًا: نبقي آخرها)
    func trimmed(maxCharacters: Int = 250_000) -> ChatSnapshot {
        var budget = maxCharacters
        var kept: [ChatMessage] = []
        for message in messages.reversed() {
            if budget <= 0 { break }
            if message.text.count <= budget {
                kept.append(message)
                budget -= message.text.count
            } else {
                kept.append(ChatMessage(id: message.id, role: message.role,
                                        text: "…" + String(message.text.suffix(budget)),
                                        images: message.images))
                budget = 0
            }
        }
        var copy = self
        copy.messages = kept.reversed()
        return copy
    }

    /// تحويل مضغوط للإرسال.
    func packed() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func unpack(_ data: Data) -> ChatSnapshot? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(ChatSnapshot.self, from: json)
    }
}
