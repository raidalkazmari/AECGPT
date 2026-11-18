import SwiftUI

/// حجم الخط الأساسي للمحادثة (يتغير من زر Aa)
private struct ChatTextSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 14
}

extension EnvironmentValues {
    var chatTextSize: CGFloat {
        get { self[ChatTextSizeKey.self] }
        set { self[ChatTextSizeKey.self] = newValue }
    }
}

/// يعرض نص ChatGPT المنسّق على الساعة:
/// عناوين، فقرات، قوائم (مرقمة ونقطية ومتداخلة)، كود، معادلات، اقتباس، جداول، فواصل.
/// كل كتلة تأخذ اتجاهها (عربي يمين، إنجليزي يسار) حسب نصها.
struct MarkdownView: View {
    let blocks: [MDBlock]

    init(_ text: String) {
        blocks = Markdown.parse(text)
    }

    init(blocks: [MDBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MDBlock
    @Environment(\.chatTextSize) private var size

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Inline(text)
                .font(.system(size: level <= 2 ? size + 2 : size + 1, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .directional(text)

        case .paragraph(let text):
            Inline(text)
                .font(.system(size: size))
                .directional(text)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(item.level == 0 ? item.marker : (item.marker == "•" ? "◦" : item.marker))
                            .font(.system(size: size))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Inline(item.text)
                            .font(.system(size: size))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.level) * 10)
                    .directional(item.text)
                }
            }

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 2) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: size - 2, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
            .environment(\.layoutDirection, .leftToRight) // الكود دائمًا من اليسار

        case .math(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: size - 2, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            .environment(\.layoutDirection, .leftToRight)

        case .quote(let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary)
                    .frame(width: 3)
                Inline(text)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .directional(text)

        case .table(let header, let rows):
            TableView(header: header, rows: rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// جدول: يتمرر يمين ويسار لو كان عريض
private struct TableView: View {
    let header: [String]
    let rows: [[String]]
    @Environment(\.chatTextSize) private var size

    var body: some View {
        let rtl = (header + rows.flatMap { $0 }).joined(separator: " ").prefersRightToLeft
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Inline(cell).font(.system(size: size - 1, weight: .semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Inline(cell).font(.system(size: size - 1))
                        }
                    }
                }
            }
            .padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.2)))
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
    }
}

/// سطر بتنسيق داخلي: **عريض**، *مائل*، `كود`، روابط
private struct Inline: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.attributed(text))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private extension View {
    /// اتجاه الكتلة حسب لغة نصها
    func directional(_ text: String) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, text.prefersRightToLeft ? .rightToLeft : .leftToRight)
    }
}
