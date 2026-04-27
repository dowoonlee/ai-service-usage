import Foundation
import UserNotifications

// 임계치 알림. 같은 reset 주기 내에서는 임계치별로 1회만 발송.
// 키 = (source).(metric) — 예: "claude.5h", "claude.7d", "cursor.month"
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized: Bool = false
    private var requested: Bool = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // unsigned `swift run`에서는 skip
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    // value: 0~100, resetAt: 현재 주기의 끝 시각 (주기 식별자로 사용)
    // title은 알림 제목, body는 본문 (nil이면 자동 생성)
    func evaluate(key: String, value: Double?, resetAt: Date?, title: String, bodyMaker: (Int) -> String) {
        let s = Settings.shared
        guard s.notifyEnabled, let v = value, let reset = resetAt else { return }

        let threshold = pickThreshold(v)
        guard let t = threshold else { return }
        if t == 80, !s.notifyAt80 { return }
        if t == 95, !s.notifyAt95 { return }

        let d = UserDefaults.standard
        let resetKey = "notify.\(key).resetAt"
        let thrKey   = "notify.\(key).lastThreshold"

        let storedReset = d.object(forKey: resetKey) as? Date
        let storedThr   = d.integer(forKey: thrKey)

        // 새 주기가 시작되었으면 카운터 리셋
        if storedReset == nil || abs((storedReset ?? .distantPast).timeIntervalSince(reset)) > 60 {
            d.set(reset, forKey: resetKey)
            d.set(0, forKey: thrKey)
        }

        let effective = (d.object(forKey: thrKey) as? Int) ?? storedThr
        if t <= effective { return }   // 이미 같거나 더 높은 임계치 알림 발송됨

        send(title: title, body: bodyMaker(t))
        d.set(t, forKey: thrKey)
    }

    private func pickThreshold(_ v: Double) -> Int? {
        if v >= 95 { return 95 }
        if v >= 80 { return 80 }
        return nil
    }

    private func send(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
