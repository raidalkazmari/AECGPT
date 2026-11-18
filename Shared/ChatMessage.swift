import Foundation

/// رسالة واحدة من المحادثة.
struct ChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String   // "user" أو "assistant"
    /// النص بتنسيق Markdown كما كتبه ChatGPT (عناوين، قوائم، كود، جداول...)
    let text: String
    /// مفاتيح الصور في هذه الرسالة (الصور نفسها تُرسل للساعة كملفات منفصلة)
    var images: [String]? = nil

    var isUser: Bool { role == "user" }
    var imageKeys: [String] { images ?? [] }
}

/// محادثة في قائمة المحادثات الأخيرة
struct ConversationItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    /// آخر تحديث بالملي ثانية
    let updated: Double
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
