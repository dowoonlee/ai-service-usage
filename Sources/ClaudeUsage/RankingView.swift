import AppKit
import SwiftUI

/// 월간 랭킹 보드. Top N + 내 순위. 5분에 한 번 자동 새로고침.
/// `GachaView`의 .ranking 탭에 임베드 — 별도 윈도우 없음. 외부에서 frame 제어.
struct RankingView: View {
    @ObservedObject var settings = Settings.shared
    @State private var entries: [RankingAPI.LeaderboardEntry] = []
    @State private var myRank: Int?
    @State private var myTotal: Int?
    @State private var totalPlayers: Int = 0
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var lastRefresh: Date?
    @State private var periodResetAt: Date?
    @State private var previousMonth: RankingAPI.PreviousMonth?
    @State private var refreshTask: Task<Void, Never>?
    /// 시상대 한마디 입력 alert 트리거 + 초안.
    @State private var editingPodium: Bool = false
    @State private var podiumDraft: String = ""

    /// 한마디 미등록 시 말풍선 기본 placeholder (남의 칸 기준). 자유롭게 교체 가능.
    private static let defaultPodiumPlaceholder = "🎉"
    /// 시상대 한마디 최대 글자수.
    private static let podiumMessageMaxLen = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !RankingAPI.isConfigured {
                placeholderView("랭킹 기능이 이 빌드에 포함되지 않았습니다.")
            } else if !settings.rankingRegistered {
                placeholderView("설정 → 랭킹에서 참여를 시작하세요.")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
        .onDisappear { refreshTask?.cancel() }
        .alert("시상대 한마디", isPresented: $editingPodium) {
            TextField("축하 인사를 남겨보세요", text: $podiumDraft)
                .onChange(of: podiumDraft) { newValue in
                    if newValue.count > Self.podiumMessageMaxLen {
                        podiumDraft = String(newValue.prefix(Self.podiumMessageMaxLen))
                    }
                }
            Button("등록") { submitPodiumMessage() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("한 번 등록하면 수정할 수 없습니다. \(Self.podiumMessageMaxLen)자 이내.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "wave.3.right").foregroundStyle(.purple)
            Text("이달의 VibeCoder").font(.system(size: 14, weight: .semibold))
            if let reset = periodResetAt {
                Text("· \(formatResetCountdown(reset))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("새로고침")
            }
        }
        .padding(12)
    }

    /// "리셋까지 18일" / "오늘 리셋" 형태 — 사용자가 월 경계 직관적으로 인지하도록.
    private func formatResetCountdown(_ reset: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: reset).day ?? 0
        if days <= 0 { return "오늘 리셋" }
        if days == 1 { return "내일 리셋" }
        return "리셋까지 \(days)일"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let prev = previousMonth, !prev.entries.isEmpty {
                podiumSection(prev)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
            }
            if let myRank, let myTotal {
                meBanner(rank: myRank, total: myTotal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider()
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(12)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        LeaderboardRowView(entry: entry, isMe: entry.nickname == settings.rankingNickname)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            footer
        }
    }

    /// 직전 달 명예의 전당 — 올림픽 시상대 구도. 가운데 1위(최고단), 왼쪽 2위, 오른쪽 3위.
    /// 메달 + 펫 아바타 + 닉네임 + 최종 VP + 보상이 높이가 다른 단(pedestal) 위에 놓인다.
    private func podiumSection(_ prev: RankingAPI.PreviousMonth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🏆").font(.system(size: 13))
                Text("\(prev.period) 명예의 전당")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
            // 단(블록)은 .bottom 정렬로 바닥을 맞추고 높이만 다르게 한다. 2-1-3 순으로
            // 배치해야 1위가 가운데·최고단. 블록끼리는 간격 0으로 맞붙인다(실제 시상대처럼).
            // 캐릭터만 단 위에 서고, 닉네임·VP·보상 코인은 단 블록 안에 적힌다.
            // 참여자가 3명 미만이면 해당 자리는 빈 단으로 형태만 유지한다.
            HStack(alignment: .bottom, spacing: 0) {
                podiumColumn(prev.entries.first { $0.rank == 2 }, rank: 2, prev: prev)
                podiumColumn(prev.entries.first { $0.rank == 1 }, rank: 1, prev: prev)
                podiumColumn(prev.entries.first { $0.rank == 3 }, rank: 3, prev: prev)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 시상대 한 열 — 한마디 말풍선(있을 때) + 캐릭터(단 위) + 등수별 높이의 단. 빈 자리는 placeholder.
    private func podiumColumn(_ entry: RankingAPI.PreviousMonthEntry?, rank: Int,
                              prev: RankingAPI.PreviousMonth) -> some View {
        VStack(spacing: 2) {
            podiumBubble(entry: entry, rank: rank, isMine: prev.myRank == rank)
            PodiumAvatar(entry: entry, rank: rank, isMine: prev.myRank == rank)
            PodiumStep(entry: entry, rank: rank)
        }
        .frame(maxWidth: .infinity)
    }

    /// 시상대 한마디 말풍선. 등록된 메시지 표시 / 내 칸 미등록이면 등록 CTA / 남의 칸 미등록이면 기본 placeholder.
    /// 폰트는 1위가 가장 크고 3위가 가장 작다. 빈 자리(entry == nil)는 말풍선 없음.
    @ViewBuilder
    private func podiumBubble(entry: RankingAPI.PreviousMonthEntry?, rank: Int, isMine: Bool) -> some View {
        if let entry {
            let size = podiumBubbleFontSize(rank)
            if let msg = entry.message, !msg.isEmpty {
                PodiumSpeechBubble(text: msg, fontSize: size, rank: rank, style: .filled)
            } else if isMine {
                Button {
                    podiumDraft = ""
                    error = nil
                    editingPodium = true
                } label: {
                    PodiumSpeechBubble(text: "✏️ 한마디 남기기", fontSize: size, rank: rank, style: .cta)
                }
                .buttonStyle(.plain)
                .help("한 번 등록하면 변경할 수 없습니다")
            } else {
                PodiumSpeechBubble(text: Self.defaultPodiumPlaceholder, fontSize: size, rank: rank, style: .placeholder)
            }
        }
    }

    /// 등수별 한마디 폰트 크기 — 1위가 가장 크고 3위가 가장 작다.
    private func podiumBubbleFontSize(_ rank: Int) -> CGFloat {
        switch rank { case 1: return 13; case 2: return 11; default: return 9 }
    }

    /// 시상대 한마디 등록 — 본인 우승 칸에 1회. trim + 길이 검증 후 서버 호출, 성공 시 refresh로 잠금 반영.
    private func submitPodiumMessage() {
        guard let prev = previousMonth, let rank = prev.myRank else { return }
        let msg = podiumDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty, msg.count <= Self.podiumMessageMaxLen else { return }
        guard let hmacKey = Keychain.loadRankingHmacKey() else {
            error = "인증 키를 찾을 수 없습니다."
            return
        }
        let deviceId = settings.rankingDeviceID
        guard !deviceId.isEmpty else { return }
        Task { @MainActor in
            do {
                _ = try await RankingAPI.shared.setPodiumMessage(
                    deviceId: deviceId, period: prev.period, rank: rank,
                    message: msg, hmacKeyBase64: hmacKey)
                refresh()   // 서버 반영분 재조회 → 말풍선이 등록 메시지로 잠긴다.
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func meBanner(rank: Int, total: Int) -> some View {
        HStack {
            Text("내 순위").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("#\(rank)").font(.system(size: 16, weight: .bold)).monospacedDigit()
            Text("/ \(totalPlayers)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text(formatVP(total))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.purple)
        }
    }

    /// VP 점수 표시 — 천 단위 콤마 + " VP" 접미사. monospaced 폰트와 함께 사용.
    private func formatVP(_ n: Int) -> String { formatVPLabel(n) }

    private var footer: some View {
        HStack {
            if let lastRefresh {
                Text("\(lastRefresh.formatted(date: .omitted, time: .shortened)) 기준")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("총 \(totalPlayers)명")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholderView(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "trophy").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        refreshTask?.cancel()
        loading = true
        error = nil
        let deviceId = settings.rankingDeviceID.isEmpty ? nil : settings.rankingDeviceID
        refreshTask = Task { @MainActor in
            defer { loading = false }
            do {
                let resp = try await RankingAPI.shared.fetchLeaderboard(deviceId: deviceId)
                entries = resp.entries
                myRank = resp.myRank
                myTotal = resp.myTotalCoins
                settings.applyMyMedals(resp.myMedals)
                totalPlayers = resp.total
                periodResetAt = resp.periodResetAt
                previousMonth = resp.previousMonth
                lastRefresh = Date()
            } catch is CancellationError {
                // 무시
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - 행 (펫 아이콘 + 호버 popover)

/// 보드 한 행. 펫 아이콘 + 닉네임 + 코인. 호버 시 트레이너 카드 popover.
/// `PetSprite.image(...)`가 @MainActor라 CI strict concurrency가 호출 컨텍스트도 같은 격리
/// 요구 — 명시. body는 어차피 main actor라 동작 영향 없음.
@MainActor
private struct LeaderboardRowView: View {
    let entry: RankingAPI.LeaderboardEntry
    let isMe: Bool
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            rankBadge
            avatarIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.nickname)
                    .font(.system(size: 12, weight: isMe ? .semibold : .regular))
                    .lineLimit(1)
                if let gh = entry.githubLogin {
                    Text("@\(gh)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            titleChip
                .frame(width: 130, alignment: .center)
            Text(formatVPRow(entry.totalCoins))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.purple)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isMe ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering, arrowEdge: .leading) {
            if let profile = entry.profileJson {
                TrainerCardView(
                    card: profile.card,
                    trainerID: profile.trainerID,
                    trainerName: entry.nickname,
                    stats: profile.stats,
                    badges: profile.badgeRowsForRender(),
                    collections: profile.collectionRowsForRender(),
                    showWatermark: false,
                    width: 460,
                    medals: entry.medals,
                    animatedAvatar: true,
                    equippedEffects: Set((profile.equippedEffects ?? []).compactMap { EffectKind(rawValue: $0) })
                )
                .padding(8)
            } else {
                // profileJson 없는 사용자 (구버전 클라이언트 등) — 닉네임/코인 정도만.
                VStack(spacing: 4) {
                    Text(entry.nickname).font(.system(size: 13, weight: .semibold))
                    Text("\(entry.totalCoins) coin").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private var rankBadge: some View {
        Text("\(entry.rank)")
            .font(.system(size: 12, weight: entry.rank <= 3 ? .bold : .regular))
            .foregroundStyle(rankColor)
            .monospacedDigit()
            .frame(width: 26, alignment: .trailing)
    }

    /// 칭호 — 트레이너 카드 정체성의 핵심. 트로피 아이콘 + 카드 frame 색의 캡슐로 강조.
    /// 짧은 한국어("신입 트레이너")부터 긴 영어("Stack Overflow Hero")까지 다양해서 maxWidth
    /// 110으로 truncate. profileJson 없는 행(미옵트인 구버전)은 미표시.
    @ViewBuilder
    private var titleChip: some View {
        if let profile = entry.profileJson {
            let title = profile.card.title
            let frame = profile.card.frame
            HStack(spacing: 3) {
                Image(systemName: "rosette")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(frame.color)
                Text(title.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(frame.color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(frame.color.opacity(0.4), lineWidth: 0.5)
            )
        } else {
            Color.clear
        }
    }

    private var rankColor: Color {
        switch entry.rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return AppColors.bronze
        default: return .primary
        }
    }

    /// 펫 아바타 — 호버 popover에 떠 있는 카드의 축소판. variant hue 반영.
    @ViewBuilder
    private var avatarIcon: some View {
        if let kind = avatarKind {
            let image = PetSprite.image(for: kind, action: .walk, frameIndex: 0)
            let isRainbow = avatarVariant == PetOwnership.prestigeVariant
            ZStack {
                if let nsImage = image {
                    Image(nsImage: nsImage)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // 리스트라 애니는 생략 — 정적 홀로 틴트 + 🌈 표식으로 레인보우 레어를 알림.
                        .hueRotation(.degrees(isRainbow ? 0 : WalkingCat.hueDegrees(for: avatarVariant)))
                        .colorMultiply(isRainbow ? WalkingCat.prestigeTint(at: 0) : .white)
                        .saturation(avatarVariant > 0 ? 1.15 : 1.0)
                        .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                if isRainbow {
                    Text("🌈").font(.system(size: 10))
                        .help("레인보우 레어 보유")
                        .offset(x: 3, y: -3)
                }
            }
        } else {
            Color.clear.frame(width: 28, height: 28)
        }
    }

    private var avatarKind: PetKind? { entry.profileJson?.card.avatar.kind }
    private var avatarVariant: Int { entry.profileJson?.card.avatar.variant ?? 0 }

    private func formatVPRow(_ n: Int) -> String { formatVPLabel(n) }
}

/// VP 점수 표시용 공유 포매터·헬퍼 — 천 단위 콤마 + " VP". body 경로에서 매번 NumberFormatter를
/// 생성하지 않도록 1회만 만들고 RankingView·LeaderboardRowView가 공유한다.
private let vpDecimalFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()
private func formatVPLabel(_ n: Int) -> String {
    "\(vpDecimalFormatter.string(from: NSNumber(value: n)) ?? "\(n)") VP"
}

// MARK: - 시상대 캐릭터 (단 위에 서는 펫)

/// 단 위에 올라간 펫 캐릭터만 렌더. 1위가 가장 크다. 빈 자리는 점선 placeholder.
/// `@MainActor` 사유는 LeaderboardRowView 와 동일 (CI strict concurrency).
@MainActor
private struct PodiumAvatar: View {
    let entry: RankingAPI.PreviousMonthEntry?
    let rank: Int

    /// 본인 칸이면 과거 스냅샷 대신 현재 트레이너 카드(레포트) 아바타·이펙트를 실시간 반영한다.
    var isMine: Bool = false
    @ObservedObject private var settings = Settings.shared

    private var size: CGFloat { rank == 1 ? 46 : 34 }
    private var avatarKind: PetKind? {
        isMine ? settings.trainerCard.avatar.kind : entry?.profileJson?.card.avatar.kind
    }
    private var variant: Int {
        isMine ? settings.trainerCard.avatar.variant : (entry?.profileJson?.card.avatar.variant ?? 0)
    }
    /// 시상대 펫에 입힐 RP 이펙트. 본인 칸은 현재 장착분, 남의 칸은 제출 스냅샷(신빌드 제출만 채워짐).
    private var effects: Set<EffectKind> {
        if isMine { return settings.equippedEffects[settings.trainerCard.avatar.kind] ?? [] }
        return Set((entry?.profileJson?.equippedEffects ?? []).compactMap { EffectKind(rawValue: $0) })
    }

    var body: some View {
        VStack(spacing: 1) {
            // 1위만 왕관 — 한눈에 챔피언임을 알린다.
            if rank == 1 {
                Text("👑")
                    .font(.system(size: 18))
                    .shadow(color: .yellow.opacity(0.7), radius: 4)
            }
            if let kind = avatarKind {
                // 단 위를 좌우로 돌아다니는 펫 — 이동 폭은 컬럼이 주는 가용 공간(상한 둠).
                GeometryReader { geo in
                    TimelineView(.animation) { ctx in
                        wanderingPet(kind: kind, width: geo.size.width,
                                     now: ctx.date.timeIntervalSinceReferenceDate)
                    }
                }
                .frame(height: size)
            } else {
                // 참여자가 없는 자리 — 점선 실루엣으로 형태만 유지.
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .frame(width: size, height: size)
            }
        }
    }

    // 컬럼 폭 안에서 좌우로 핑퐁하며 walk 사이클을 도는 펫 + RP 이펙트. 그림자도 함께 이동.
    @ViewBuilder
    private func wanderingPet(kind: PetKind, width: CGFloat, now: Double) -> some View {
        let travel = min(max(0, (width - size) / 2), size * 1.3)   // 과도한 이동 방지 상한
        let period = rank == 1 ? 3.6 : 4.4                          // 왕복 주기 (1위 약간 활발)
        let phase = (now / period).truncatingRemainder(dividingBy: 1.0)
        let tri = abs(phase * 2 - 1)                                // 1→0→1 삼각파
        let x = (1 - tri * 2) * travel                             // 좌 ↔ 우
        let movingRight = phase < 0.5
        let count = max(1, PetSprite.frames(for: kind, action: .walk).count)
        let idx = Int(now * 8) % count
        ZStack {
            // 발밑 타원 그림자 — 펫과 함께 이동.
            Ellipse()
                .fill(Color.black.opacity(0.22))
                .frame(width: size * 0.62, height: size * 0.16)
                .offset(y: size * 0.46)
                .blur(radius: 1.5)
            effectLayer(.backdrop, facingRight: movingRight)   // 광원·무지개 (뒤)
            petSprite(kind: kind, frameIndex: idx, facingRight: movingRight)
            effectLayer(.particles, facingRight: movingRight)  // 발자국·잔상 (앞)
        }
        .frame(width: size, height: size)
        .offset(x: x)
        .frame(width: width, height: size, alignment: .center)
    }

    @ViewBuilder
    private func petSprite(kind: PetKind, frameIndex: Int, facingRight: Bool) -> some View {
        if let img = PetSprite.image(for: kind, action: .walk, frameIndex: frameIndex) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(WalkingCat.hueDegrees(for: variant)))
                .scaleEffect(x: kind.defaultFacingLeft == facingRight ? -1 : 1, y: 1)
                // 1위 캐릭터는 금색 glow로 빛나게.
                .shadow(color: rank == 1 ? .yellow.opacity(0.8) : .clear,
                        radius: rank == 1 ? 8 : 0)
        } else {
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func effectLayer(_ placement: PetEffectOverlay.Placement, facingRight: Bool) -> some View {
        if !effects.isEmpty {
            PetEffectOverlay(
                effects: effects,
                placement: placement,
                center: CGPoint(x: size / 2, y: size / 2),
                footY: size * 0.92,
                petHeight: size * 0.62,
                facingRight: facingRight,
                isMoving: true
            )
            .frame(width: size, height: size)
        }
    }
}

// MARK: - 시상대 단 도형 (윗변만 둥근 사각형)

/// 윗변 두 모서리만 둥근 사각형. macOS 13 타깃이라 `UnevenRoundedRectangle`(14+) 대신
/// 직접 Path로 그린다. 시상대 단의 "윗면만 둥근" 입체 실루엣을 만든다.
private struct TopRoundedRect: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 시상대 단

/// 시상대 단(pedestal) — 등수 + 메달 + 닉네임 + 최종 VP + 보상 코인을 담는다.
/// 콘텐츠 높이는 공통이고 등수별 추가 높이(`extraHeight`)를 바닥에 채워 계단(1위 최고)을 만든다.
/// 윗변만 둥근 모양은 macOS 13 호환 위해 RoundedRectangle 전체 둥글림으로 근사.
@MainActor
private struct PodiumStep: View {
    let entry: RankingAPI.PreviousMonthEntry?
    let rank: Int

    /// 계단 형성용 — 콘텐츠 아래에 채우는 여분 높이. 1위가 가장 높다.
    private var extraHeight: CGFloat {
        switch rank { case 1: return 22; case 2: return 12; default: return 0 }
    }
    private var rewardColor: Color {
        switch rank { case 1: return .yellow; case 2: return .gray; default: return .orange }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(podiumMedal(rank)).font(.system(size: 18))
                Text("\(rank)")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(podiumColor(rank))
            }
            if let entry {
                Text(entry.nickname)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(entry.totalCoins) VP")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    CoinIcon(size: 12)
                    Text("+\(entry.rewardCoins)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(rewardColor)
            } else {
                Text("기록 없음").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            // 등수별 계단 — 콘텐츠 아래에 정확히 extraHeight만큼 바닥을 채운다.
            // Spacer는 greedy라 조상 maxHeight를 만나면 블록이 끝까지 늘어나므로 고정 높이 filler 사용.
            Color.clear.frame(height: extraHeight)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(podiumPedestal)
    }

    /// 입체 단 — 윗변만 둥근 메탈릭 그라데이션 + 윗면 하이라이트 띠 + 테두리.
    private var podiumPedestal: some View {
        let c = podiumColor(rank)
        return TopRoundedRect(radius: 8)
            .fill(
                LinearGradient(
                    colors: [c.opacity(0.55), c.opacity(0.32), c.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(alignment: .top) {
                // 윗면 하이라이트 띠 — 빛 반사처럼 보여 입체감을 준다.
                TopRoundedRect(radius: 8)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(height: 10)
            }
            .overlay(
                TopRoundedRect(radius: 8).stroke(c.opacity(0.55), lineWidth: 0.75)
            )
    }
}

// MARK: - 시상대 공용 헬퍼 (PodiumCard / PodiumStep / emptyPodiumSlot 공유)

/// 등수별 메달 이모지. 1/2/3 외에는 트로피.
private func podiumMedal(_ rank: Int) -> String {
    switch rank { case 1: return "🥇"; case 2: return "🥈"; case 3: return "🥉"; default: return "🏆" }
}

/// 등수별 강조 색 — 금/은/동.
private func podiumColor(_ rank: Int) -> Color {
    switch rank {
    case 1: return .yellow
    case 2: return .gray
    case 3: return AppColors.bronze
    default: return .secondary
    }
}

// MARK: - 시상대 한마디 말풍선

/// 우승자 한마디 말풍선 — 둥근 사각형 + 아래로 향한 꼬리. 등수색 테두리, style별 색/굵기 차이.
/// filled = 등록된 메시지 / cta = 내 칸 등록 유도 / placeholder = 남의 칸 미등록 기본값.
private struct PodiumSpeechBubble: View {
    enum Style { case filled, cta, placeholder }
    let text: String
    let fontSize: CGFloat
    let rank: Int
    let style: Style

    private var fillColor: Color {
        style == .placeholder ? Color.secondary.opacity(0.12) : Color(NSColor.windowBackgroundColor)
    }
    private var textColor: Color {
        switch style {
        case .cta:         return .accentColor
        case .placeholder: return .secondary
        case .filled:      return .primary
        }
    }
    private var borderColor: Color {
        podiumColor(rank).opacity(style == .placeholder ? 0.25 : 0.55)
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: style == .filled ? .semibold : .regular))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .lineLimit(7)   // 1위 13pt·한글 50자 ≈ 5줄 → 여유. 안 잘림 보장.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 148)   // 칸 폭(~152) 내에서 최대한 넓혀 줄 수↓ (132→148: 1위 7줄→5줄)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(fillColor)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(borderColor, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            )
            .overlay(alignment: .bottom) {
                // 아래로 향한 꼬리 — fill만(테두리 생략)으로 바닥 seam 회피. 살짝 겹쳐 자연스럽게.
                PodiumBubbleTail()
                    .fill(fillColor)
                    .frame(width: 11, height: 6)
                    .offset(y: 5)
            }
            .padding(.bottom, 5)  // 꼬리 공간 확보
    }
}

/// 아래로 향한 말풍선 꼬리 삼각형.
private struct PodiumBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// (별도 윈도우 컨트롤러 제거됨 — `GachaView`의 .ranking 탭에 임베드.
// 외부 진입은 `GachaWindowController.shared.present(tab: .ranking)`.)
