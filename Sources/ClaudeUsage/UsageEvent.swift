import Foundation

// ============================================================================
// 사용량 이벤트 파이프라인
// ============================================================================
//
// 모든 "사용량 비례" 적립은 UsageEvent 1개로 표현 → UsageEventBus 통해 broadcast →
// CoinLedger / VPLedger 등 독립 Consumer들이 각자 처리.
//
// 신규 사용량 소스 추가 시 (예: Gemini, OpenAI API):
//   1. UsageSource enum에 case 추가
//   2. UsageEventProducer에 ingestXxx() 정적 함수 추가 — raw API 데이터를
//      pureValue + UsageContext(coinFactor, vpFactor)로 변환 후 emit
//   3. 끝. CoinLedger/VPLedger는 자동으로 새 소스 처리 (특별 분기 불필요).
//
// 사용량 외의 적립 (badge, wellness, PR, collection, migration 보너스)은
// UsageEvent 파이프라인 거치지 않고 CoinLedger.creditBonus()/creditWellness() 등
// 직접 호출 — VP에는 영향 없음 (의도적, "사용량 비례"가 아니므로).

/// 표준화된 사용량 이벤트. Producer가 emit, Consumer들이 독립 처리.
struct UsageEvent: Sendable {
    let timestamp: Date
    let source: UsageSource
    let context: UsageContext
    /// 단위 없는 "pure 사용량". Source별 자연 단위 — Claude는 curve가 적용된 coin 환산값,
    /// Cursor Ultra는 chargedCents, Cursor Pro/Free는 request count delta.
    /// 항상 양수 (Producer가 음수/0이면 emit 안 함).
    let pureValue: Double
}

/// 사용량 소스 분류. enum 케이스 추가로 새 소스 도입.
enum UsageSource: String, Codable, Sendable {
    case claudeFiveHour
    case claudeSevenDay
    case cursorUltra            // chargedCents 기반
    case cursorProRequests
    case cursorFreeRequests
    case cursorBusinessRequests

    enum VibeCategory { case claude, cursor }

    /// 도장(Vibe Coder 카테고리) 카운터 분류용.
    var vibeCategory: VibeCategory {
        switch self {
        case .claudeFiveHour, .claudeSevenDay: return .claude
        case .cursorUltra, .cursorProRequests, .cursorFreeRequests, .cursorBusinessRequests:
            return .cursor
        }
    }

    /// CoinLedger의 fractional carry용 Settings keyPath.
    /// 새 소스 추가 시 새 fraction 필드도 추가하거나 기존을 재사용.
    var coinFractionKeyPath: ReferenceWritableKeyPath<Settings, Double> {
        switch self {
        case .claudeFiveHour:  return \.claudeFiveHourCoinFraction
        case .claudeSevenDay:  return \.claudeSevenDayCoinFraction
        case .cursorUltra, .cursorProRequests, .cursorFreeRequests, .cursorBusinessRequests:
            return \.cursorCoinFraction
        }
    }
}

/// 이벤트의 환산 컨텍스트 — 같은 pureValue도 plan별로 coin/VP 적립량이 다름.
struct UsageContext: Sendable {
    /// 표시/로깅용 (e.g. "Pro", "Max 20x"). 환산엔 쓰지 않음.
    let planName: String?
    /// pureValue × coinFactor = 적립할 가챠 코인 (소수 가능, fractional carry로 누적).
    let coinFactor: Double
    /// pureValue × vpFactor = 적립할 VP (소수 가능, fractional carry로 누적).
    let vpFactor: Double
}

/// 이벤트 수신 protocol. 모든 ledger는 이를 채택.
@MainActor
protocol UsageConsumer: AnyObject {
    func consume(_ event: UsageEvent)
}

/// 이벤트 broadcast hub. App 시작 시 ledger들이 register.
@MainActor
final class UsageEventBus {
    static let shared = UsageEventBus()
    private var consumers: [UsageConsumer] = []

    private init() {}

    /// Consumer 등록. 중복 호출 무시 (같은 인스턴스 2회 등록 시 한 번만).
    func register(_ consumer: UsageConsumer) {
        guard !consumers.contains(where: { $0 === consumer }) else { return }
        consumers.append(consumer)
        DebugLog.log("UsageEventBus: registered \(type(of: consumer)) (total=\(consumers.count))")
    }

    /// 이벤트 broadcast. 모든 consumer가 동기 처리. 어떤 consumer 실패해도 다른 consumer는 영향 없음.
    func emit(_ event: UsageEvent) {
        for c in consumers { c.consume(event) }
        DebugLog.log("UsageEvent: \(event.source.rawValue) pure=\(String(format: "%.3f", event.pureValue)) ×coin=\(event.context.coinFactor) ×vp=\(String(format: "%.4f", event.context.vpFactor))")
    }
}

// ============================================================================
// Producer — raw API 데이터 → UsageEvent 변환 + emit
// ============================================================================
//
// state machine (lastSeen pct, resetAt 추적)은 여기서 관리. Settings 필드에 영속.
// 신규 소스 추가 시 여기에 ingestXxx() 정적 함수 추가.

@MainActor
enum UsageEventProducer {
    /// Claude 스냅샷 ingest — 5h/7d 두 윈도우를 각각 평가, delta가 양수면 이벤트 emit.
    /// resetAt 변경 시 baseline만 갱신 (소급 적립 X). 60s slack으로 sub-second 흔들림 방어.
    static func ingestClaude(_ snapshot: UsageSnapshot) {
        let s = Settings.shared
        let multiplier = CoinLedger.planMultiplier(snapshot.planName)
        let priceVP = CoinLedger.claudePlanPriceVP(snapshot.planName)
        let vpFactor = Double(priceVP) / CoinLedger.claudeMaxPureCoinPerMonth

        // 5-hour 윈도우
        if let resetAt = snapshot.fiveHourResetAt, let pct = snapshot.fiveHourPct {
            if let lastReset = s.lastClaudeFiveHourReset,
               let lastPct = s.lastClaudeFiveHourPctSeen,
               abs(lastReset.timeIntervalSince(resetAt)) <= 60, pct > lastPct {
                let prev = CoinLedger.curve(lastPct / 100.0) * CoinLedger.claudeFiveHourMaxCoin
                let curr = CoinLedger.curve(pct / 100.0) * CoinLedger.claudeFiveHourMaxCoin
                let pureDelta = curr - prev
                if pureDelta > 0 {
                    UsageEventBus.shared.emit(UsageEvent(
                        timestamp: Date(),
                        source: .claudeFiveHour,
                        context: UsageContext(planName: snapshot.planName,
                                              coinFactor: multiplier,
                                              vpFactor: vpFactor),
                        pureValue: pureDelta
                    ))
                }
            }
            s.lastClaudeFiveHourReset = resetAt
            s.lastClaudeFiveHourPctSeen = pct
        }

        // 7-day 윈도우
        if let resetAt = snapshot.sevenDayResetAt, let pct = snapshot.sevenDayPct {
            if let lastReset = s.lastClaudeSevenDayReset,
               let lastPct = s.lastClaudeSevenDayPctSeen,
               abs(lastReset.timeIntervalSince(resetAt)) <= 60, pct > lastPct {
                let prev = CoinLedger.curve(lastPct / 100.0) * CoinLedger.claudeSevenDayMaxCoin
                let curr = CoinLedger.curve(pct / 100.0) * CoinLedger.claudeSevenDayMaxCoin
                let pureDelta = curr - prev
                if pureDelta > 0 {
                    UsageEventBus.shared.emit(UsageEvent(
                        timestamp: Date(),
                        source: .claudeSevenDay,
                        context: UsageContext(planName: snapshot.planName,
                                              coinFactor: multiplier,
                                              vpFactor: vpFactor),
                        pureValue: pureDelta
                    ))
                }
            }
            s.lastClaudeSevenDayReset = resetAt
            s.lastClaudeSevenDayPctSeen = pct
        }
    }

    /// Cursor Ultra 이벤트 ingest — 새 events의 chargedCents 합산 emit.
    /// pureValue = cents 합, coinFactor = 0.1 (cursorCentToCoin), vpFactor = 1.0 (1 cent = 1 VP).
    static func ingestCursorEvents(_ newEvents: [CursorEvent]) {
        guard !newEvents.isEmpty else { return }
        let s = Settings.shared
        let cutoff = s.lastCursorEventCredited ?? .distantPast
        let unprocessed = newEvents.filter { $0.timestamp > cutoff }
        guard !unprocessed.isEmpty else { return }
        let cents = unprocessed.reduce(0.0) { $0 + $1.chargedCents }
        if cents > 0 {
            UsageEventBus.shared.emit(UsageEvent(
                timestamp: Date(),
                source: .cursorUltra,
                context: UsageContext(planName: "Ultra",
                                      coinFactor: CoinLedger.cursorCentToCoin,
                                      vpFactor: 1.0),
                pureValue: cents
            ))
        }
        if let latest = unprocessed.map({ $0.timestamp }).max() {
            s.lastCursorEventCredited = latest
        }
    }

    /// Cursor Pro/Free/Business 스냅샷 ingest — request delta 기반.
    /// Ultra는 events 경로라 본 함수에서 스킵. startOfMonth 변경 시 baseline reset.
    /// pureValue = request delta, vpFactor = planPriceVP / maxRequests.
    static func ingestCursorSnapshot(_ snap: CursorSnapshot) {
        guard snap.plan != .ultra,
              let total = snap.totalRequests,
              let maxReq = snap.maxRequests, maxReq > 0 else { return }
        let s = Settings.shared

        // Cursor 측 startOfMonth 복원 (resetAt - 1개월).
        let cursorMonthStart: Date? = snap.resetAt.flatMap {
            Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: $0)
        }
        // 새 월 진입 — baseline만 갱신, 적립 0.
        if let newMonth = cursorMonthStart,
           let oldMonth = s.cursorLastStartOfMonth,
           abs(newMonth.timeIntervalSince(oldMonth)) > 60 {
            s.cursorLastRequestsSeen = total
            s.cursorLastStartOfMonth = newMonth
            return
        }
        s.cursorLastStartOfMonth = cursorMonthStart

        let last = s.cursorLastRequestsSeen ?? total
        let delta = total - last
        defer { s.cursorLastRequestsSeen = total }
        guard delta > 0 else { return }

        let priceVP = CoinLedger.cursorPlanPriceVP(snap.plan)
        let source: UsageSource = {
            switch snap.plan {
            case .pro:      return .cursorProRequests
            case .free:     return .cursorFreeRequests
            case .business: return .cursorBusinessRequests
            case .ultra, .unknown: return .cursorProRequests // unreachable for ultra, fallback for unknown
            }
        }()
        UsageEventBus.shared.emit(UsageEvent(
            timestamp: Date(),
            source: source,
            context: UsageContext(planName: snap.plan.rawValue,
                                  coinFactor: 0,  // Pro/Free는 가챠 코인 적립 X (현재 정책)
                                  vpFactor: Double(priceVP) / Double(maxReq)),
            pureValue: Double(delta)
        ))
    }
}
