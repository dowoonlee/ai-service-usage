import AppKit
import SwiftUI

/// 길드 랭킹 렌더 — 직전 달 길드 시상대(2-1-3 단상) + 이번 달 길드 순위 리스트.
/// 데이터 fetch는 상위(`RankingView`)가 담당하고 여기서는 순수 렌더만 한다
/// (기존 GuildView 임베드 → 랭킹 탭 이동, 개인/길드 스코프 전환용으로 분리).
@MainActor
struct GuildLeaderboardView: View {
    let board: RankingAPI.GuildLeaderboardResponse
    /// 내 길드 id — 리스트·시상대에서 하이라이트. 무소속이면 nil.
    let highlightGuildId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 직전 달 길드 명예의 전당 — 개인 시상대와 동일한 2-1-3 단상 구도 (P2a).
            if let prev = board.previousMonth, !prev.entries.isEmpty {
                guildPodiumSection(prev)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 6) {
                Text("🏆 길드 랭킹").font(.system(size: 12, weight: .semibold))
                Text("총 \(board.total)개").font(.system(size: 10)).foregroundStyle(.secondary)
                if let reset = board.periodResetAt {
                    Text("· \(formatResetCountdown(reset))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 2)
            ForEach(board.entries) { entry in
                guildRow(entry)
            }
        }
    }

    /// 길드 한 줄 — 로고 배너 + 이름 + 점수, 그 아래 상위 기여자 펫 줄.
    /// 한 줄에 다 넣기엔 정보가 많아 2단으로 나눴다(위: 정체성·점수 / 아래: 사람).
    private func guildRow(_ entry: RankingAPI.GuildLeaderboardEntry) -> some View {
        let isMine = entry.guildId == highlightGuildId
        return HStack(alignment: .top, spacing: 10) {
            Text("\(entry.rank)")
                .font(.system(size: 15, weight: entry.rank <= 3 ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(entry.rank <= 3 ? AppColors.gold : .secondary)
                .frame(width: 26, alignment: .trailing)
                .padding(.top, 2)
            GuildLogoBanner(logo: entry.logo, guildID: entry.guildId, width: 72)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if isMine {
                        Text("내 길드")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                    Spacer(minLength: 4)
                    Text("\(entry.score) VP")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.purple)
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 8))
                    Text("\(entry.memberCount)명").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                topContributorsRow(entry)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .fill(isMine ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06))
        )
    }

    /// 점수에 반영되는 상위 기여자 — 펫 아바타 + 닉네임. 구버전 서버(topMembers 없음)에선 숨긴다.
    @ViewBuilder
    private func topContributorsRow(_ entry: RankingAPI.GuildLeaderboardEntry) -> some View {
        if let members = entry.topMembers, !members.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(members) { m in
                    VStack(spacing: 1) {
                        memberPet(m)
                        Text(m.nickname)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 54)
                        Text("\(m.vp)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.purple.opacity(0.8))
                    }
                    .help("\(m.nickname) · \(m.vp) VP")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    /// 기여자 대표 펫. 프로필이 없거나 모르는 종이면 발자국으로 대체 (시상대와 같은 폴백).
    @ViewBuilder
    private func memberPet(_ m: RankingAPI.GuildTopMember) -> some View {
        if let kind = m.kind,
           let nsImage = PetSprite.image(for: kind, action: .walk, frameIndex: 0) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(m.variant == PetOwnership.prestigeVariant
                    ? 0 : WalkingCat.hueDegrees(for: m.variant)))
                .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(width: 34, height: 30)
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 30)
        }
    }

    /// 직전 달 길드 시상대 — 2-1-3 단상 (개인 시상대의 길드판). 단 위에는 정산 시점
    /// 길드장 대표 펫, 단 안에는 길드명·최종 점수·멤버 수. 내 길드 단은 하이라이트.
    private func guildPodiumSection(_ prev: RankingAPI.GuildPreviousMonth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("🏆").font(.system(size: 13))
                Text("\(prev.period) 길드 명예의 전당")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach([2, 1, 3], id: \.self) { rank in
                    guildPodiumBlock(prev.entries.first { $0.rank == rank }, rank: rank,
                                     isMine: prev.myGuildRank == rank)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func guildPodiumBlock(_ entry: RankingAPI.GuildPreviousMonthEntry?,
                                  rank: Int, isMine: Bool) -> some View {
        let heights: [Int: CGFloat] = [1: 74, 2: 58, 3: 48]
        let medals: [Int: String] = [1: "🥇", 2: "🥈", 3: "🥉"]
        return VStack(spacing: 2) {
            if let entry {
                podiumLeaderAvatar(entry)
                Text(medals[rank] ?? "").font(.system(size: 12))
            }
            VStack(spacing: 1) {
                Text(entry?.name ?? " ")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                if let entry {
                    Text("\(entry.score) VP")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.purple)
                    Text("\(entry.memberCount)명")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: heights[rank] ?? 48)
            .background(
                Rectangle().fill(
                    isMine ? Color.accentColor.opacity(0.25)
                           : Color.gray.opacity(rank == 1 ? 0.22 : 0.14))
            )
            .overlay(Rectangle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
    }

    /// 정산 시점 길드장 대표 펫 — 스냅샷 프로필에서 렌더 (없으면 발자국 아이콘).
    @ViewBuilder
    private func podiumLeaderAvatar(_ entry: RankingAPI.GuildPreviousMonthEntry) -> some View {
        if let selection = entry.leaderProfileJson?.card.avatar,
           let nsImage = PetSprite.image(for: selection.kind, action: .walk, frameIndex: 0) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(selection.variant == PetOwnership.prestigeVariant
                    ? 0 : WalkingCat.hueDegrees(for: selection.variant)))
                .scaleEffect(x: selection.kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(height: 26)
                .help(entry.leaderNickname.map { "길드장 \($0)" } ?? "")
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(height: 26)
        }
    }

    /// "리셋까지 18일" / "오늘 리셋" — RankingView와 동일 포맷 (월 경계 직관화).
    private func formatResetCountdown(_ reset: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: reset).day ?? 0
        if days <= 0 { return "오늘 리셋" }
        if days == 1 { return "내일 리셋" }
        return "리셋까지 \(days)일"
    }
}
