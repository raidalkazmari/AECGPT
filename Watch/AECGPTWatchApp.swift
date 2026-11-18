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

    /// تحديث تلقائي كل 20 ثانية والتطبيق ظاهر (لو تحدّثت من جهاز ثاني)
    private let refresh = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var messages: [ChatMessage] { store.snapshot.messages }

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
                    controls
                        .id("top")

                    ForEach(messages) { message in
                        MessageRow(message: message, imagesVersion: store.imagesVersion)
                            .id(message.id)
                    }

                    if store.typing {
                        HStack(spacing: 6) {
                            ProgressView().frame(width: 20, height: 20)
                            Text("يكتب…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 2)
            }
            // محادثة ثانية: نروح لآخر سؤال فيها
            .onChange(of: store.snapshot.conversationId) { _ in
                jumpToLastQuestion(proxy, animated: false)
            }
            // رسالة جديدة في نفس المحادثة: نروح لبدايتها. غير كذا تتصفح براحتك
            .onChange(of: messages.last?.id) { id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear { jumpToLastQuestion(proxy, animated: false) }
        }
    }

    private func jumpToLastQuestion(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = messages.last(where: \.isUser)?.id ?? messages.last?.id else { return }
        DispatchQueue.main.async {
            if animated { withAnimation { proxy.scrollTo(target, anchor: .top) } }
            else { proxy.scrollTo(target, anchor: .top) }
        }
    }

    /// أعلى المحادثة: عنوانها + المحادثات + تحديث
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                NavigationLink {
                    ConversationList()
                } label: {
                    Label("المحادثات", systemImage: "list.bullet")
                        .font(.footnote)
                }
                Button {
                    store.requestLatest()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .frame(width: 44)
            }
            .buttonStyle(.bordered)

            if !store.snapshot.title.isEmpty {
                Text(store.snapshot.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection,
                                 store.snapshot.title.prefersRightToLeft ? .rightToLeft : .leftToRight)
            }
        }
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
    /// يتغير عند وصول صورة جديدة، فيعاد رسم الرسالة
    let imagesVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
                MarkdownView(message.text)
            }
            ForEach(message.imageKeys, id: \.self) { key in
                ChatImage(key: key, version: imagesVersion)
            }
        }
        .padding(message.isUser ? 8 : 2)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(message.isUser ? Color.gray.opacity(0.3) : Color.clear)
        )
    }
}

/// صورة من المحادثة، أو مكان محجوز لها حتى تصل من الجوال
struct ChatImage: View {
    let key: String
    let version: Int

    var body: some View {
        if let image = WatchImages.image(key) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
