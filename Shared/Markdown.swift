import Foundation

/// كتلة واحدة من نص ChatGPT المنسّق
enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case code(language: String, text: String)
    case math(String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

struct MDListItem: Equatable {
    /// 0 للمستوى الأول، 1 للقائمة الداخلية...
    let level: Int
    /// "•" أو "1." ...
    let marker: String
    let text: String
}

/// يقسم نص Markdown إلى كتل (عناوين، فقرات، قوائم، كود، جداول...)
/// التنسيق داخل السطر (عريض، مائل، كود قصير) تتكفل به الساعة عند العرض.
enum Markdown {

    static func parse(_ source: String) -> [MDBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var listItems: [MDListItem] = []
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(cleanInlineMath(text))) }
            paragraph.removeAll()
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(listItems)) }
            listItems.removeAll()
        }
        func flushAll() { flushParagraph(); flushList() }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // سطر فاضي: نهاية فقرة (والقائمة تستمر لو بعدها عنصر قائمة)
            if trimmed.isEmpty {
                flushParagraph()
                if !listItems.isEmpty {
                    let next = lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    if next.map({ listItem($0) == nil }) ?? true { flushList() }
                }
                i += 1
                continue
            }

            // كود ```
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language, text: dedent(code).joined(separator: "\n")))
                i += 1 // سطر الإغلاق
                continue
            }

            // معادلة $$ ... $$ أو \[ ... \]
            if trimmed == "$$" || trimmed == "\\[" || (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4)
                || (trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]") && trimmed.count > 4) {
                flushAll()
                if trimmed.count > 4, trimmed != "$$", trimmed != "\\[" {
                    blocks.append(.math(String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
                let close = trimmed == "$$" ? "$$" : "\\]"
                var math: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != close {
                    math.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.math(math.joined(separator: "\n")))
                i += 1
                continue
            }

            // عنوان #
            if let h = heading(trimmed) {
                flushAll()
                blocks.append(.heading(level: h.0, text: cleanInlineMath(h.1)))
                i += 1
                continue
            }

            // خط فاصل
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                i += 1
                continue
            }

            // جدول: سطر | ثم سطر |---|
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                    rows.append(Array(row.prefix(max(header.count, 1))))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // اقتباس >
            if trimmed.hasPrefix(">") {
                flushAll()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(cleanInlineMath(quote.joined(separator: "\n"))))
                continue
            }

            // عنصر قائمة
            if let item = listItem(line) {
                flushParagraph()
                listItems.append(item)
                i += 1
                continue
            }

            // سطر تابع لعنصر القائمة السابق (مزاح للداخل)
            if !listItems.isEmpty, paragraph.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                let last = listItems.removeLast()
                listItems.append(MDListItem(level: last.level, marker: last.marker,
                                            text: last.text + "\n" + cleanInlineMath(trimmed)))
                i += 1
                continue
            }

            // فقرة عادية
            flushList()
            paragraph.append(trimmed)
            i += 1
        }
        flushAll()
        return blocks
    }

    // MARK: - أجزاء

    static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    static func isRule(_ line: String) -> Bool {
        let s = line.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let first = s.first, "-*_".contains(first) else { return false }
        return s.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> MDListItem? {
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
        }
        let body = line.trimmingCharacters(in: .whitespaces)
        let level = min(indent / 2, 4)

        // • - * +
        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if first != "*" || !isRule(body) {
                return MDListItem(level: level, marker: "•", text: cleanInlineMath(checkbox(text)))
            }
        }
        // 1. أو 1)
        var digits = ""
        for ch in body { if ch.isASCII, ch.isNumber { digits.append(ch) } else { break } }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return MDListItem(level: level, marker: digits + ".", text: cleanInlineMath(text))
            }
        }
        return nil
    }

    private static func checkbox(_ text: String) -> String {
        if text.hasPrefix("[ ] ") { return "☐ " + text.dropFirst(4) }
        if text.lowercased().hasPrefix("[x] ") { return "☑ " + text.dropFirst(4) }
        return text
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { cleanInlineMath($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// يشيل المسافة البادئة المشتركة من أسطر الكود
    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " }.count }
        let common = indents.min() ?? 0
        return common == 0 ? lines : lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " }.count))) }
    }

    /// \( x \) → x  (معادلات داخل السطر تعرض كنص)
    static func cleanInlineMath(_ text: String) -> String {
        text.replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "")
    }
}
