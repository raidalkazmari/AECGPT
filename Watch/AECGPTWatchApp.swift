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

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    emptyState
                } else {
                    conversation
                }
            }
            .navigationTitle(store.snapshot.title.isEmpty ? "AECGPT" : store.snapshot.title)
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
                        MessageRow(message: message)
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

    var body: some View {
        Text(message.text)
            .font(.body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(message.isUser ? 8 : 2)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.isUser ? Color.gray.opacity(0.3) : Color.clear)
            )
            .environment(\.layoutDirection,
                         message.text.prefersRightToLeft ? .rightToLeft : .leftToRight)
    }
}
