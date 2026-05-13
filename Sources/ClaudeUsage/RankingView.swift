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
    @State private var refreshTask: Task<Void, Never>?

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
    private func formatVP(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return "\(fmt.string(from: NSNumber(value: n)) ?? "\(n)") VP"
    }

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
                totalPlayers = resp.total
                periodResetAt = resp.periodResetAt
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
                    width: 460
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
        case 3: return Color(red: 0.8, green: 0.5, blue: 0.2)
        default: return .primary
        }
    }

    /// 펫 아바타 — 호버 popover에 떠 있는 카드의 축소판. variant hue 반영.
    @ViewBuilder
    private var avatarIcon: some View {
        if let kind = avatarKind {
            let image = PetSprite.image(for: kind, action: .walk, frameIndex: 0)
            ZStack {
                if let nsImage = image {
                    Image(nsImage: nsImage)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .hueRotation(.degrees(WalkingCat.hueDegrees(for: avatarVariant)))
                        .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
        } else {
            Color.clear.frame(width: 28, height: 28)
        }
    }

    private var avatarKind: PetKind? { entry.profileJson?.card.avatar.kind }
    private var avatarVariant: Int { entry.profileJson?.card.avatar.variant ?? 0 }

    private func formatVPRow(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        return "\(fmt.string(from: NSNumber(value: n)) ?? "\(n)") VP"
    }
}

// (별도 윈도우 컨트롤러 제거됨 — `GachaView`의 .ranking 탭에 임베드.
// 외부 진입은 `GachaWindowController.shared.present(tab: .ranking)`.)
