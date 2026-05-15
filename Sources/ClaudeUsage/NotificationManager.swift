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
    // 사용자가 설정한 임계치 리스트 중 v가 막 넘은 가장 높은 값에 대해 발송.
    func evaluate(key: String, value: Double?, resetAt: Date?, title: String, bodyMaker: (Int) -> String) {
        let s = Settings.shared
        guard s.notifyEnabled, let v = value, let reset = resetAt else { return }
        let thresholds = s.notifyThresholds.sorted()
        guard !thresholds.isEmpty else { return }
        guard let t = thresholds.last(where: { Double($0) <= v }) else { return }

        let d = UserDefaults.standard
        let resetKey = "notify.\(key).resetAt"
        let thrKey   = "notify.\(key).lastThreshold"

        let storedReset = d.object(forKey: resetKey) as? Date

        // 새 주기가 시작되었으면 카운터 리셋
        if storedReset == nil || abs((storedReset ?? .distantPast).timeIntervalSince(reset)) > 60 {
            d.set(reset, forKey: resetKey)
            d.set(0, forKey: thrKey)
        }

        let effective = d.integer(forKey: thrKey)
        if t <= effective { return }   // 이미 같거나 더 높은 임계치 알림 발송됨

        send(title: title, body: bodyMaker(t))
        d.set(t, forKey: thrKey)
    }

    /// 비공식 endpoint(claude.ai/cursor.com) 응답이 연속으로 schema-suspect 판정될 때
    /// 1회만 사용자에게 알림 — 같은 source 24시간 쿨다운.
    /// 호출은 ViewModel.updateBackoffAfterCycle에서 임계 도달 cycle에 1회.
    func endpointSuspect(source: String) {
        let d = UserDefaults.standard
        let key = "notify.endpoint.\(source).firedAt"
        if let last = d.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 { return }
        let title = "\(source) API 응답 이상"
        let body  = "\(source) 비공식 endpoint 스키마가 변경됐을 가능성이 있습니다. 앱 업데이트를 확인해주세요."
        send(title: title, body: body)
        d.set(Date(), forKey: key)
        DebugLog.log("Endpoint suspect alerted: source=\(source)")
    }

    /// 도장 클리어 알림 — 한 cycle에 N개 동시에 클리어돼도 단일 알림으로 묶어 발송.
    /// migration 자동 클리어는 `evaluate(silent: true)`로 호출되어 이쪽으로 안 옴.
    func badgesCleared(ids: [BadgeID]) {
        guard !ids.isEmpty else { return }
        let bonus = ids.reduce(0) { $0 + $1.tier.coinReward }
        if ids.count == 1 {
            let id = ids[0]
            send(title: "도장 클리어: \(id.category.displayName) · \(id.tier.displayName)",
                 body: "+\(bonus) 코인 적립")
        } else {
            let summary = ids.map { "\($0.category.displayName) \($0.tier.displayName)" }.joined(separator: ", ")
            send(title: "도장 \(ids.count)개 클리어",
                 body: "+\(bonus) 코인 — \(summary)")
        }
    }

    /// 챔피언 뱃지 획득 알림.
    func championEarned() {
        send(title: "🏆 챔피언 등극!",
             body: "모든 도장을 정복했습니다 +\(BadgeRegistry.championCoinReward) 코인")
    }

    /// 명예의 전당 보상 알림. 폴링 cycle에서 본인 row 감지 시 1회 호출 (dedup은 호출 측에서).
    func podiumRewardEarned(period: String, rank: Int, coins: Int) {
        let medal: String
        switch rank {
        case 1: medal = "🥇"
        case 2: medal = "🥈"
        case 3: medal = "🥉"
        default: medal = "🏆"
        }
        send(title: "\(medal) \(period) 명예의 전당",
             body: "\(rank)등 — +\(coins) 코인이 적립되었습니다!")
    }

    /// 기여자 보너스 적립 알림 — `ContributorBonus.sync()`에서 새 PR 발견 시 1회 호출.
    func contributorBonus(prCount: Int, totalCoins: Int, prList: String) {
        let title = "기여자 보너스 +\(totalCoins) 코인"
        let body  = prCount == 1
            ? "PR \(prList) 머지 감사합니다!"
            : "머지된 PR \(prCount)개 (\(prList)) 보너스가 적립되었습니다."
        send(title: title, body: body)
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
