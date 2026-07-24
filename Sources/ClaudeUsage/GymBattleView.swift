import SwiftUI

// 관장 실전 배틀 (gym-battle.md) — 도장 뱃지 획득의 **게이트**. metric이 tier 임계를 넘어 도전 자격이
// 열리면(BadgeRegistry.challengeableTier), 여기서 내 파티 vs 관장 팀을 실제로 붙여 **이겨야** 그 tier
// 뱃지를 획득한다. 배틀 재생은 아레나와 동일한 공유 컴포넌트(BattleReplayView)를 그대로 쓴다.
//
// 완전 로컬 — 관장 팀은 NPC 상수(GymLeader.team(tier:))라 서버 의존 0. 승패는 BattleEngine이 확정하고
// (결정론), 승리 시 즉시 defeatLeader로 뱃지·코인을 지급한 뒤 재생을 관전한다(아레나 관례와 동일:
// 결과 확정 → 재생). 재도전은 무제한(연습), 보상은 최초 획득 1회(creditedBadgeRewards dedup).
@MainActor
struct GymBattleView: View {
    let region: BadgeRegion
    let tier: BadgeTier

    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var result: BattleResult?
    @State private var aSnaps: [BattlePetSnapshot] = []
    @State private var bSnaps: [BattlePetSnapshot] = []
    @State private var didWin = false
    @State private var rewardCoins = 0
    @State private var attempt = 0
    /// 서버에서 로드한 내 강화 레벨(kind→level). 랭킹 미등록/로드 실패 시 빈 딕셔너리(=강화 0).
    @State private var enhanceLevels: [PetKind: Int] = [:]

    private var leader: GymLeader { GymLeader.leader(for: region) }
    private var owned: [PetKind] { PetKind.allCases.filter { settings.ownedPets[$0] != nil } }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let r = result {
                BattleReplayView(aSnaps: aSnaps, bSnaps: bSnaps, result: r) {
                    outcomeCard
                }
                .id(attempt)   // 재도전 시 완전 리셋(새 재생)
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("전투 준비 중…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 176)
            }
            footer
        }
        .padding(16)
        .frame(width: 430)
        // 내 진짜 전투력으로 싸우도록 강화 레벨을 먼저 로드(랭킹 유저) 후 첫 배틀 시뮬. 재도전은 재로드 없음.
        .task {
            await loadEnhanceLevels()
            if result == nil { runBattle() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            leaderSprite
            VStack(alignment: .leading, spacing: 2) {
                Text(leader.name)
                    .font(.system(size: 13, weight: .bold))
                HStack(spacing: 6) {
                    PixelIconView(icon: region.pixelIcon, color: .secondary)
                        .frame(width: 12, height: 12)
                    Text("\(region.displayName) · \(tier.displayName) 도장전")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private var leaderSprite: some View {
        let extraScale: CGFloat = (leader.kind == .kingHuman) ? 1.4 : 1.0
        return ZStack {
            if let img = PetSprite.image(for: leader.kind, action: .scan, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable().interpolation(.none).scaledToFit()
                    .frame(width: 40, height: 40)
                    .scaleEffect(x: leader.kind.defaultFacingLeft ? -extraScale : extraScale, y: extraScale)
            }
        }
        .frame(width: 48, height: 48)
    }

    // MARK: - Outcome (재생 완료 시 배너 아래 노출)

    @ViewBuilder
    private var outcomeCard: some View {
        if didWin {
            VStack(spacing: 4) {
                Text(rewardCoins > 0
                     ? "🏅 \(region.displayName) · \(tier.displayName) 도장 획득!"
                     : "승리 — 이미 획득한 도장")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                if rewardCoins > 0 {
                    Text("🪙 +\(rewardCoins)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                Text(leader.dialogue(stage: 3))
                    .font(.system(size: 10)).italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.green.opacity(0.10)))
        } else {
            VStack(spacing: 4) {
                Text("패배… 관장을 이겨야 도장을 얻습니다")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text(leader.dialogue(stage: 0))
                    .font(.system(size: 10)).italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.red.opacity(0.08)))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { attempt += 1; runBattle() } label: {
                Label("다시 도전", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
            }.buttonStyle(.bordered)
            Spacer()
            Button { dismiss() } label: {
                Text(didWin ? "완료" : "닫기").font(.system(size: 11, weight: .semibold))
            }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Battle

    /// 서버 강화 상태 로드 — 내 진짜 전투력으로 싸우기 위해. 랭킹 미등록(=강화 불가)이면 no-op(강화 0).
    /// 아레나 `loadEnhanceState`와 동일 경로. 실패해도 강화 0으로 진행(배틀은 계속).
    private func loadEnhanceLevels() async {
        guard RankingAPI.isConfigured, settings.rankingRegistered,
              !settings.rankingDeviceID.isEmpty,
              let hmac = Keychain.loadRankingHmacKey() else { return }
        do {
            let st = try await RankingAPI.shared.fetchEnhanceState(
                deviceId: settings.rankingDeviceID, hmacKeyBase64: hmac)
            var lv: [PetKind: Int] = [:]
            for (k, v) in st.levels { if let pk = PetKind(rawValue: k) { lv[pk] = v } }
            enhanceLevels = lv
        } catch {
            DebugLog.log("Gym battle: 강화 레벨 로드 실패 — \(error) (강화 0으로 진행)")
        }
    }

    /// 내 파티(battleTeam 재활용) vs 관장 팀 → 결정론 시뮬. 승리 시 즉시 뱃지·코인 지급.
    private func runBattle() {
        var kinds = Array(settings.battleTeam.filter { settings.ownedPets[$0] != nil }.prefix(5))
        if kinds.isEmpty { kinds = Array(owned.prefix(5)) }   // 미설정 폴백 — 보유 상위 펫
        // 내 진짜 전투력 — 이로치(보유 최고 해금) + 실제 강화 레벨(서버 로드) 반영.
        let a = kinds.map { BattlePetSnapshot(kind: $0,
                                              variant: settings.ownedPets[$0]?.unlockedVariants.max() ?? 0,
                                              enhanceLevel: enhanceLevels[$0] ?? 0) }
        let bTeam = leader.team(tier: tier)
        aSnaps = a
        bSnaps = bTeam.members
        let r = BattleEngine.simulate(teamA: BattleTeam(a), teamB: bTeam, seed: .random(in: 1...UInt64.max))
        if r.winner == .a {
            didWin = true
            rewardCoins = BadgeRegistry.defeatLeader(region: region, tier: tier)
        } else {
            didWin = false
            rewardCoins = 0
        }
        result = r
    }
}
