import AppKit
import SwiftUI

/// 길드 방명록 공용 렌더 (docs/plans/guild-visit.md M2) — 방문 시트(`GuildVisitView`)와
/// 내 길드 화면(`GuildView`)이 같은 줄 모양을 쓴다. 데이터 fetch·삭제 호출은 호출 측이 맡는다.
///
/// 게시판과 달리 비익명: 작성자 닉네임 + 소속 길드명 + 대표 펫. "○○ 길드의 △△가 다녀감"이
/// 놀러가기의 재미라서 익명화하지 않는다 (길드 표면의 관례).
@MainActor
struct GuildGuestbookRow: View {
    let entry: RankingAPI.GuildGuestbookEntry
    /// 삭제 버튼 노출 — 호출 측이 "작성자 + 윈도우 내" 또는 "길드장"을 판정해 넘긴다.
    let canDelete: Bool
    let deleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            petAvatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.nickname)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if let guild = entry.guildName, !guild.isEmpty {
                        Text("· \(guild)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(GuildGuestbookFormat.relative(entry.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if canDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            if deleting {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "trash").font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(deleting)
                        .help("방명록 삭제")
                    }
                }
                Text(entry.content)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(entry.isMine ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.06))
        )
    }

    @ViewBuilder
    private var petAvatar: some View {
        if let kind = entry.kind,
           let frame = PetSprite.image(for: kind, action: .walk, frameIndex: 0) {
            Image(nsImage: frame)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(entry.variant == PetOwnership.prestigeVariant
                    ? 0 : WalkingCat.hueDegrees(for: entry.variant)))
                .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(width: 26, height: 22)
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
    }
}

enum GuildGuestbookFormat {
    /// "방금" / "N분 전" / "N시간 전" / "N일 전" — 방명록은 정확한 시각보다 "얼마나 최근"이 중요하다.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 60 { return "방금" }
        if secs < 3_600 { return "\(Int(secs / 60))분 전" }
        if secs < 86_400 { return "\(Int(secs / 3_600))시간 전" }
        return "\(Int(secs / 86_400))일 전"
    }

    /// 작성자 본인 삭제 가능 여부 — 서버 윈도우(초)와 같은 기준. 길드장 판정은 호출 측이 OR로 더한다.
    static func isDeletableByAuthor(_ entry: RankingAPI.GuildGuestbookEntry,
                                    windowSec: Int, now: Date = Date()) -> Bool {
        entry.isMine && now.timeIntervalSince(entry.createdAt) <= TimeInterval(windowSec)
    }

    static func formatCooldown(_ sec: Int) -> String {
        if sec >= 3_600 { return "\(Int(ceil(Double(sec) / 3_600)))시간" }
        let m = sec / 60, s = sec % 60
        if m > 0 { return "\(m)분 \(s)초" }
        return "\(s)초"
    }
}
