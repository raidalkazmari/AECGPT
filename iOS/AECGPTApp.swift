import SwiftUI
import WebKit

@main
struct AECGPTApp: App {
    // يُنشأ بعد أن يجهز iOS التطبيق، وليس في أول لحظة من التشغيل
    @StateObject private var bridge = PhoneBridge()

    var body: some Scene {
        WindowGroup {
            WebView(webView: bridge.webView)
        }
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
