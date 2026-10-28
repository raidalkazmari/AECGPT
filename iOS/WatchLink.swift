import UIKit
import WatchConnectivity

/// الاتصال بالساعة. يبدأ مع تشغيل التطبيق، حتى لو شغّلته الساعة في الخلفية.
/// يرسل بطريقتين معًا:
/// 1) فورًا إذا كانت الساعة مفتوحة (sendMessage)
/// 2) نسخة محفوظة تصل للساعة حتى لو كانت نائمة (applicationContext)
@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// آخر ما أُرسل. stamp = 0 يعني أن التطبيق بدأ للتو (كان مُغلقًا).
    private(set) var latest: ChatSnapshot = .empty
    private var lastContextPush = Date.distantPast

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()

        // سحب التطبيق وإغلاقه: نمسح الساعة قبل أن يُغلق
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate),
                                               name: UIApplication.willTerminateNotification, object: nil)
    }

    func update(_ snapshot: ChatSnapshot) {
        latest = snapshot
        push(snapshot)
    }

    /// يمسح كل شيء من الساعة.
    func clear() {
        let empty = ChatSnapshot(title: "", messages: [], streaming: false,
                                 stamp: Date().timeIntervalSince1970)
        latest = empty
        push(empty, forceSave: true)
    }

    /// يعيد إرسال المحادثة الحالية. إذا كان التطبيق بدأ للتو (أي كان مُغلقًا)، يمسح الساعة.
    func resendOrClear() {
        if latest.stamp > 0 {
            push(latest, forceSave: true)
        } else {
            clear()
        }
    }

    @objc private func willTerminate() {
        clear()   // متزامن: يصل للنظام قبل إغلاق التطبيق
    }

    private func push(_ snapshot: ChatSnapshot, forceSave: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled,
              let data = snapshot.trimmed().packed() else { return }

        let payload: [String: Any] = [ChatSnapshot.key: data]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }

        // النسخة المحفوظة: فورًا عند اكتمال الرد، وكل ثانية أثناء الكتابة
        let now = Date()
        if forceSave || !snapshot.streaming || now.timeIntervalSince(lastContextPush) >= 1 {
            lastContextPush = now
            try? session.updateApplicationContext(payload)
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.resendOrClear() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.resendOrClear() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.resendOrClear() }
    }

    /// الساعة تسأل عند فتحها: إن كان التطبيق مُغلقًا، يشغّله iOS في الخلفية فيمسح الساعة.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["sync"] != nil else { return }
        Task { @MainActor in self.resendOrClear() }
    }
}
