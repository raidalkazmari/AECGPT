import Foundation

/// رسالة واحدة من المحادثة.
struct ChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String   // "user" أو "assistant"
    let text: String

    var isUser: Bool { role == "user" }
}

/// نسخة كاملة من المحادثة المفتوحة حاليًا في الجوال.
/// تُرسل للساعة كاملة في كل مرة، فلا يمكن أن تختلف الساعة عن الجوال.
struct ChatSnapshot: Codable, Equatable {
    var title: String
    var messages: [ChatMessage]
    var streaming: Bool
    /// وقت إنشاء النسخة. الساعة تتجاهل أي نسخة أقدم من التي عندها.
    var stamp: Double

    static let key = "snapshot"
    static let empty = ChatSnapshot(title: "", messages: [], streaming: false, stamp: 0)

    func hasSameContent(as other: ChatSnapshot) -> Bool {
        title == other.title && streaming == other.streaming && messages == other.messages
    }

    /// يحافظ على آخر الرسائل ضمن حد آمن لحجم ما يُرسل للساعة.
    func trimmed(maxCharacters: Int = 60_000) -> ChatSnapshot {
        var budget = maxCharacters
        var kept: [ChatMessage] = []
        for message in messages.reversed() {
            if budget <= 0 { break }
            if message.text.count <= budget {
                kept.append(message)
                budget -= message.text.count
            } else {
                kept.append(ChatMessage(id: message.id, role: message.role,
                                        text: "…" + String(message.text.suffix(budget))))
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

extension String {
    /// هل يبدأ النص بحرف عربي/عبري؟ لاختيار اتجاه العرض في الساعة.
    var prefersRightToLeft: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            default:
                if CharacterSet.letters.contains(scalar) { return false }
            }
        }
        return false
    }
}
