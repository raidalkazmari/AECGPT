import UIKit

/// صور المحادثة في الساعة: تُحفظ كملفات، فتبقى بعد إغلاق التطبيق أو إعادة تشغيل الساعة.
/// آمنة الاستدعاء من أي خيط.
enum WatchImages {
    private static let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let memory = NSCache<NSString, UIImage>()

    private static func url(_ key: String) -> URL {
        dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    static func has(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(key).path)
    }

    static func image(_ key: String) -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: url(key).path) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    static func save(_ key: String, data: Data) {
        try? data.write(to: url(key), options: .atomic)
        prune()
    }

    /// لازم يُستدعى داخل دالة الاستقبال نفسها، لأن النظام يحذف الملف بعدها
    static func saveFile(_ key: String, from source: URL) {
        let target = url(key)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            if let data = try? Data(contentsOf: source) { try? data.write(to: target, options: .atomic) }
        }
        prune()
    }

    /// نبقي آخر 80 صورة فقط حتى لا تمتلئ الساعة
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 80 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - 80) { try? fm.removeItem(at: file) }
    }
}
