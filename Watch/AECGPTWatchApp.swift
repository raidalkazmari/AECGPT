import SwiftUI

@main
struct AECGPTWatchApp: App {
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(store)
        }
    }
}

// MARK: - المحادثة

struct ChatView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.scenePhase) private var scenePhase

    /// حجم الخط (يتغير من زر Aa ويبقى محفوظ)
    @AppStorage("chatTextSize") private var textSize: Double = 14
    private let sizes: [Double] = [12, 14, 16, 18]
    /// ردود قديمة فتحتها كاملة
    @State private var expanded: Set<String> = []

    /// تحديث تلقائي كل 20 ثانية والتطبيق ظاهر (لو تحدّثت من جهاز ثاني)
    private let refresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var messages: [ChatMessage] { store.snapshot.messages }
    private var lastReplyId: String? { messages.last(where: { !$0.isUser })?.id }

    private var status: String {
        if !store.isConnected { return "🔴 غير متصل" }
        if store.typing { return "🟢 يكتب…" }
        return "🟢 متصل"
    }

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    emptyState
                } else {
                    conversation
                }
            }
            // حالة الاتصال بخط صغير مكان العنوان، فلا تأخذ مساحة من المحادثة
            .navigationTitle(status)
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.chatTextSize, CGFloat(textSize))
        .onChange(of: scenePhase) { phase in
            if phase == .active { store.requestLatest() }
        }
        .onReceive(refresh) { _ in
            if scenePhase == .active { store.requestLatest() }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    controls(proxy)
                        .id("top")

                    ForEach(messages) { message in
                        MessageRow(message: message,
                                   collapsed: isCollapsed(message),
                                   imagesVersion: store.imagesVersion,
                                   failed: store.failedImages,
                                   onExpand: { expanded.insert(message.id) })
                            .id(message.id)
                    }

                    if store.typing {
                        HStack(spacing: 6) {
                            ProgressView().frame(width: 20, height: 20)
                            Text("يكتب…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // آخر المحادثة: رجوع سريع للأعلى
                    Button {
                        withAnimation { proxy.scrollTo("top", anchor: .top) }
                    } label: {
                        Label("للأعلى", systemImage: "arrow.up.to.line")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 2)
            }
            // محادثة ثانية: نروح لآخر سؤال فيها
            .onChange(of: store.snapshot.conversationId) { _ in
                expanded.removeAll()
                jumpToLastQuestion(proxy)
            }
            // رسالة جديدة في نفس المحادثة: نروح لبدايتها. غير كذا تتصفح براحتك
            .onChange(of: messages.last?.id) { id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
            // سؤال من الفهرس
            .onChange(of: store.jumpTarget) { target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    proxy.scrollTo(target, anchor: .top)
                    store.jumpTarget = nil
                }
            }
            .onAppear { jumpToLastQuestion(proxy) }
        }
    }

    /// الردود القديمة الطويلة تظهر مختصرة، وآخر رد كامل
    private func isCollapsed(_ message: ChatMessage) -> Bool {
        !message.isUser && message.id != lastReplyId && !expanded.contains(message.id)
            && (message.text.count > 350 || message.imageKeys.count > 1)
    }

    private func jumpToLastQuestion(_ proxy: ScrollViewProxy) {
        guard let target = messages.last(where: \.isUser)?.id ?? messages.last?.id else { return }
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    /// أعلى المحادثة: المحادثات، فهرس الأسئلة، تحديث، حجم الخط، لآخر سؤال
    private func controls(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                NavigationLink {
                    ConversationList()
                } label: {
                    Label("المحادثات", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                NavigationLink {
                    QuestionsIndex()
                } label: {
                    Label("الأسئلة", systemImage: "list.number")
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Button {
                    store.requestLatest()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                Button {
                    let index = sizes.firstIndex(of: textSize) ?? 1
                    textSize = sizes[(index + 1) % sizes.count]
                } label: {
                    Text("Aa").font(.system(size: 14, weight: .semibold))
                }
                Button {
                    jumpToLastQuestion(proxy)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
            }
            .font(.system(size: 14))

            if !store.snapshot.title.isEmpty {
                Text(store.snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection,
                                 store.snapshot.title.prefersRightToLeft ? .rightToLeft : .leftToRight)
            }
        }
        .buttonStyle(.bordered)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.isConnected {
                ProgressView()
                Text("جاري جلب آخر محادثة…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "iphone")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("شغّل التطبيق في الجوال وسجّل دخولك")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.requestLatest() }
    }
}

// MARK: - رسالة

struct MessageRow: View {
    let message: ChatMessage
    /// رد قديم يظهر مختصر
    let collapsed: Bool
    /// يتغير عند وصول صورة جديدة، فيعاد رسم الرسالة
    let imagesVersion: Int
    let failed: [String: String]
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if collapsed {
                if !message.text.isEmpty {
                    MarkdownView(blocks: Self.preview(Markdown.parse(message.text)))
                }
                Button(action: onExpand) {
                    Label(message.imageKeys.isEmpty ? "عرض الرد كامل" : "عرض الرد كامل · 🖼 \(message.imageKeys.count)",
                          systemImage: "chevron.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            } else {
                if !message.text.isEmpty {
                    MarkdownView(message.text)
                }
                ForEach(message.imageKeys, id: \.self) { key in
                    ChatImage(key: key, version: imagesVersion, failure: failed[key])
                }
            }
        }
        .padding(message.isUser ? 8 : 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(message.isUser ? Color.gray.opacity(0.3) : Color.clear)
        )
    }

    /// أول جزء من الرد (حوالي 280 حرف) للعرض المختصر
    static func preview(_ blocks: [MDBlock], limit: Int = 280) -> [MDBlock] {
        var result: [MDBlock] = []
        var used = 0
        for block in blocks {
            let length: Int
            switch block {
            case .paragraph(let t), .heading(_, let t), .quote(let t), .math(let t): length = t.count
            case .code(_, let t): length = t.count
            case .list(let items): length = items.reduce(0) { $0 + $1.text.count }
            case .table(let h, let rows): length = (h + rows.flatMap { $0 }).joined().count
            case .rule: length = 0
            }
            if used > 0 && used + length > limit { break }
            if used == 0, length > limit, case .paragraph(let t) = block {
                result.append(.paragraph(String(t.prefix(limit)) + "…"))
                return result
            }
            result.append(block)
            used += length
        }
        return result
    }
}

/// صورة من المحادثة، أو مكان محجوز لها حتى تصل من الجوال (أو سبب فشلها)
struct ChatImage: View {
    let key: String
    let version: Int
    let failure: String?

    var body: some View {
        if let image = WatchImages.image(key) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let failure {
            Label("تعذّر عرض الصورة (\(failure))", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.15)))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 70)
                .overlay(
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                        ProgressView()
                    }
                    .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - فهرس الأسئلة

struct QuestionsIndex: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    private var questions: [ChatMessage] { store.snapshot.messages.filter(\.isUser) }

    var body: some View {
        List {
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                Button {
                    store.jumpTarget = question.id
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(Self.summary(question))
                            .font(.system(size: 13))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .environment(\.layoutDirection,
                                 question.text.prefersRightToLeft ? .rightToLeft : .leftToRight)
                }
            }
        }
        .navigationTitle("الأسئلة")
    }

    static func summary(_ message: ChatMessage) -> String {
        let flat = message.text.replacingOccurrences(of: "\n", with: " ")
        if flat.isEmpty { return message.imageKeys.isEmpty ? "…" : "🖼 صورة" }
        return String(flat.prefix(120))
    }
}

// MARK: - قائمة المحادثات

struct ConversationList: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if store.conversations.isEmpty {
                HStack {
                    Spacer()
                    if store.listLoading || store.isConnected { ProgressView() } else {
                        Text("الجوال غير متصل").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.conversations) { item in
                Button {
                    store.open(item.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.footnote.weight(item.id == store.snapshot.conversationId ? .bold : .regular))
                            .lineLimit(2)
                        if item.updated > 0 {
                            Text(Date(timeIntervalSince1970: item.updated / 1000),
                                 format: .relative(presentation: .named))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, item.title.prefersRightToLeft ? .rightToLeft : .leftToRight)
                }
            }
        }
        .navigationTitle("المحادثات")
        .onAppear { store.requestList() }
    }
}
