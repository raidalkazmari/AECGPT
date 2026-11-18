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

struct ChatView: View {
    @EnvironmentObject private var store: WatchStore
    @Environment(\.scenePhase) private var scenePhase

    private var messages: [ChatMessage] { store.snapshot.messages }

    private var status: String {
        if !store.isConnected { return "🔴 غير متصل" }
        if store.snapshot.streaming { return "🟢 يكتب…" }
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
            if phase == .active { store.requestSync() }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        MessageRow(message: message, imagesVersion: store.imagesVersion)
                            .id(message.id)
                    }
                    if store.snapshot.streaming {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 2)
            }
            // عند وصول رسالة جديدة ينتقل لبدايتها، ثم تقرأ بالتاج براحتك
            .onChange(of: messages.last?.id) { id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let id = messages.last?.id { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("افتح محادثة في الجوال")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    /// يتغير عند وصول صورة جديدة، فيعاد رسم الرسالة
    let imagesVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection,
                                 message.text.prefersRightToLeft ? .rightToLeft : .leftToRight)
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
