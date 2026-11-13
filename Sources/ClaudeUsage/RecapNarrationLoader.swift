import Foundation
import Combine

/// 원본 스냅샷, 닉네임, 토큰은 보내지 않고 내레이션에 필요한 통계만 전송한다.
struct RecapNarrationSummary: Encodable {
    let activeDays, longestStreak: Int
    let claudeWeeklyGauges, codexWeeklyGauges: Double
    let claudeFiveHourWallHits: Int
    let cursorUSD: Double
    let goldenHour, busiestWeekday: Int
    let pulls, speciesOwned, shinySpecies, prestigeSpecies: Int
    let partnerKind: String?
    let partnerHours: Double
    let badges, collectionsCompleted, arenaWins, arenaBestRating, quizCorrect, wellnessResponded: Int
    let claudeCoins, codexCoins, cursorCoins: Int

    init(_ f: RecapFacts) {
        let u = f.usage, g = f.game
        activeDays = u.activeDays; longestStreak = u.longestStreak
        claudeWeeklyGauges = u.claudeWeeklyGauges; codexWeeklyGauges = u.codexWeeklyGauges
        claudeFiveHourWallHits = u.claudeFiveHourWallHits; cursorUSD = u.cursorUSD
        goldenHour = u.goldenHour ?? -1; busiestWeekday = u.busiestWeekday ?? -1
        pulls = g.pulls; speciesOwned = g.speciesOwned; shinySpecies = g.shinySpecies
        prestigeSpecies = g.prestigeKinds.count
        partnerKind = g.partners.first?.kind.rawValue; partnerHours = g.partners.first?.hours ?? 0
        badges = g.badges; collectionsCompleted = g.collectionsCompleted
        arenaWins = g.arenaWins; arenaBestRating = g.arenaBestRating
        quizCorrect = g.quizCorrect; wellnessResponded = g.wellnessResponded
        claudeCoins = g.coinsBySource["claude"] ?? 0
        codexCoins = g.coinsBySource["codex"] ?? 0
        cursorCoins = g.coinsBySource["cursor"] ?? 0
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // nil도 서버 계약에 맞춰 명시적인 null로 전송한다.
        let data = try encoder.encode(self)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Expected recap summary object"))
        }
        if partnerKind == nil { object["partnerKind"] = NSNull() }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}

struct RecapNarrationRow: Codable, Equatable, Sendable {
    let year: Int
    let petKind: String
    let generatedAt: Date
    let persona: String
    let lines: [String: String]

    func isValid(year: Int, petKind: String) -> Bool {
        self.year == year && self.petKind == petKind && !persona.isEmpty && persona.count <= 120
            && Set(lines.keys) == Set(RecapNarration.sceneIDs)
            && lines.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 110 }
    }
}

struct RecapNarrationResponse: Decodable, Sendable {
    enum Status: String, Decodable, Sendable { case ready, pending, failed }
    let status: Status
    let row: RecapNarrationRow?
    let retryAfter: Int?
}

@MainActor
final class RecapNarrationLoader: ObservableObject {
    enum State {
        case loading
        case ready(RecapNarrationRow)
        case fallback(String)
    }
    typealias Request = (String, String, Int, String, String) async throws -> RecapNarrationResponse
    @Published private(set) var state: State = .loading
    private let request: Request
    private let sleep: (UInt64) async throws -> Void
    private var loading = false

    init(request: @escaping Request = { device, key, year, pet, summary in
        try await RankingAPI.shared.requestRecapNarration(deviceId: device, hmacKeyBase64: key,
            year: year, petKind: pet, summaryJson: summary)
    }, sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.request = request
        self.sleep = sleep
    }

    func load(facts: RecapFacts) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        state = .loading
        let device = Settings.shared.rankingDeviceID
        let pet = facts.game.narrator.kind.rawValue
        guard !device.isEmpty, let key = Keychain.loadRankingHmacKey(), !key.isEmpty else {
            state = .fallback("개인화 대사는 설정에서 글로벌 랭킹 등록 후 이용할 수 있습니다.")
            return
        }
        let cacheKey = "recap.narration.\(device).\(RecapFacts.year).\(pet)"
        if let data = AppEnv.defaults.data(forKey: cacheKey),
           let row = try? JSONDecoder().decode(RecapNarrationRow.self, from: data),
           row.isValid(year: RecapFacts.year, petKind: pet) {
            state = .ready(row)
            return
        }
        do {
            let summary = try RecapNarrationSummary(facts).json()
            for _ in 0..<40 {
                try Task.checkCancellation()
                let response = try await request(device, key, RecapFacts.year, pet, summary)
                try Task.checkCancellation()
                switch response.status {
                case .ready:
                    guard let row = response.row, row.isValid(year: RecapFacts.year, petKind: pet) else {
                        state = .fallback("개인화 대사를 읽지 못해 기본 대사를 표시합니다.")
                        return
                    }
                    AppEnv.defaults.set(try JSONEncoder().encode(row), forKey: cacheKey)
                    state = .ready(row)
                    return
                case .failed:
                    state = .fallback("개인화 대사를 준비하지 못했습니다. 잠시 후 다시 시도해 주세요.")
                    return
                case .pending:
                    try await sleep(UInt64(min(max(response.retryAfter ?? 3, 1), 5)) * 1_000_000_000)
                }
            }
            state = .fallback("대사를 아직 준비 중입니다. 잠시 후 다시 열면 저장된 이야기를 불러옵니다.")
        } catch is CancellationError {
            // 창을 닫아도 서버의 생성/저장은 계속된다. 다음에 열면 같은 결과를 받는다.
        } catch {
            if Task.isCancelled { return }
            state = .fallback("개인화 대사에 연결하지 못해 기본 대사를 표시합니다.")
        }
    }
}
