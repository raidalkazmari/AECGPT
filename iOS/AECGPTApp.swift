import SwiftUI
import WebKit

@main
struct AECGPTApp: App {
    init() {
        _ = PhoneBridge.shared   // يبدأ الاتصال بالساعة فور تشغيل التطبيق
    }

    var body: some Scene {
        WindowGroup {
            WebView(webView: PhoneBridge.shared.webView)
        }
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
