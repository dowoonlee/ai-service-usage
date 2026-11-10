import Foundation

/// 시즌 날짜별 선물 — 그날 앱을 열고 메인 패널의 선물 상자를 누르면 받는다(12/21~25, 갈수록 커진다).
///
/// 서버를 거치지 않는 로컬 지급이다. 일일 보상(`submit` 훅)과 달리 랭킹 미등록 사용자도 받는다.
/// 대신 시계를 돌리면 미리 열 수 있다 — 코인은 원래 로컬 경제라 감수하고, 서버가 검증하는 RP·프리미엄권은
/// 선물에 넣지 않는다.
///
/// * 그날 선물은 그날만 열린다. 놓친 날은 소급하지 않는다(뒤로 갈수록 커지는 설계가 "25일에 한꺼번에"로 무너진다).
/// * dedup은 `seasonalFlags`의 `gift:<instanceID>:<MM>-<DD>` — 연도가 붙어 내년에 다시 받는다.
/// * 시즌이 꺼져 있으면(설정 off·킬스위치·창 밖) 선물도 없다. 판정은 `SeasonRegistry.active()` 한 곳.
@MainActor
enum SeasonGiftBox {
    struct Pending: Equatable {
        let gift: SeasonGift
        /// 1부터. "오늘의 선물 (3/5)" 표기용.
        let index: Int
        let total: Int
        let flag: String
        var isLast: Bool { index == total }
    }

    nonisolated static func flagKey(instanceID: String, gift: SeasonGift) -> String {
        String(format: "gift:%@:%02d-%02d", instanceID, gift.month, gift.day)
    }

    /// 오늘(KST) 날짜에 해당하는 선물. 이미 열었는지는 보지 않는다.
    static func todays(now: Date = Date(), settings: Settings? = nil) -> Pending? {
        guard let season = SeasonRegistry.active(now: now, settings: settings), !season.gifts.isEmpty else { return nil }
        let c = Calendar.kst.dateComponents([.month, .day], from: now)
        guard let i = season.gifts.firstIndex(where: { $0.month == c.month && $0.day == c.day }) else { return nil }
        let gift = season.gifts[i]
        return Pending(gift: gift, index: i + 1, total: season.gifts.count,
                       flag: flagKey(instanceID: season.instanceID(now: now), gift: gift))
    }

    /// 아직 안 연 오늘의 선물.
    static func pending(now: Date = Date(), settings: Settings? = nil) -> Pending? {
        guard let p = todays(now: now, settings: settings) else { return nil }
        return (settings ?? Settings.shared).seasonalFlags.contains(p.flag) ? nil : p
    }

    /// 오늘의 선물을 연다. 이미 열었거나 선물 날이 아니면 nil(아무것도 지급하지 않는다).
    @discardableResult
    static func open(now: Date = Date()) -> Pending? {
        let s = Settings.shared
        guard let p = pending(now: now, settings: s) else { return nil }
        s.seasonalFlags.insert(p.flag)          // 지급보다 먼저 — 중복 클릭이 두 번 들어와도 한 번만
        CoinLedger.shared.creditBonus(p.gift.coins, reason: "season.\(p.flag)")
        if p.gift.tickets > 0 { s.gachaTickets += p.gift.tickets }
        DebugLog.log("SeasonGiftBox: \(p.flag) +\(p.gift.coins) coin, 가챠권 +\(p.gift.tickets)")
        return p
    }
}
