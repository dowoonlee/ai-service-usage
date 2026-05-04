import AppKit
import SwiftUI

// 기여자 페이지 — 메인 메뉴 ("기여자 보기...")에서 별도 NSWindow로 호출.
// 데이터는 `Contributors`가 24h 캐시로 관리, 앱 시작 시 1회 refresh.

struct ContributorsPageView: View {
    @ObservedObject var contributors: Contributors

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .font(.system(size: 14))
                Text("기여해주신 분들")
                    .font(.system(size: 16, weight: .semibold))
            }
            Text("PR을 보내 프로젝트를 함께 만들어가는 분들입니다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if contributors.list.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("아직 외부 기여자가 없습니다")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("첫 PR을 환영합니다!")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(contributors.list.enumerated()), id: \.element.id) { idx, c in
                        ContributorCardView(contributor: c, rank: idx)
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("PR을 보내려면 GitHub 저장소를 방문하세요.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                if let u = URL(string: "https://github.com/dowoonlee/ai-service-usage") {
                    NSWorkspace.shared.open(u)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("저장소 열기")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct ContributorCardView: View {
    let contributor: Contributor
    let rank: Int
    @State private var expanded: Bool = false

    private var rarity: Rarity { ContributorRanking.rarity(forRank: rank) }
    private var petKind: PetKind? { ContributorRanking.pet(for: rarity, login: contributor.login) }
    private var rarityColor: Color { ContributorRanking.color(for: rarity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                petBadge
                AvatarView(url: contributor.avatarURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("@\(contributor.login)")
                            .font(.system(size: 13, weight: .semibold))
                        Button {
                            if let u = URL(string: "https://github.com/\(contributor.login)") {
                                NSWorkspace.shared.open(u)
                            }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("github.com/\(contributor.login)")
                    }
                    Text(metaText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            }
            if expanded {
                Divider().padding(.top, 10).padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(contributor.prs, id: \.number) { pr in
                        prRow(pr)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(rarityColor.opacity(rank < 3 ? 0.6 : 0.15),
                        lineWidth: rank < 3 ? 1.5 : 0.5)
        )
    }

    /// rarity 색 stroke 안에 펫 sprite 1프레임. sprite 로드 실패 시 rarity 이니셜로 fallback.
    private var petBadge: some View {
        ZStack {
            Circle()
                .fill(rarityColor.opacity(0.15))
            Circle()
                .stroke(rarityColor.opacity(rank < 3 ? 0.8 : 0.4), lineWidth: 1)
            if let kind = petKind, let img = PetSprite.image(for: kind, action: .walk, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
            } else {
                Text(String(rarity.displayName.prefix(1)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(rarityColor)
            }
        }
        .frame(width: 36, height: 36)
        .help("\(rarity.displayName) · \(contributor.prs.count)개 PR")
    }

    private var metaText: String {
        let count = contributor.prs.count
        guard let latest = contributor.prs.first else { return "PR \(count)개" }
        return "PR \(count)개 · 최근 머지 \(Self.relativeText(latest.mergedAt))"
    }

    private func prRow(_ pr: PullRequest) -> some View {
        HStack(spacing: 6) {
            Text("#\(pr.number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .leading)
            Text(pr.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(Self.relativeText(pr.mergedAt))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Button {
                if let u = URL(string: "https://github.com/dowoonlee/ai-service-usage/pull/\(pr.number)") {
                    NSWorkspace.shared.open(u)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private static func relativeText(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct AvatarView: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlStr = url, let u = URL(string: urlStr) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.25))
            Image(systemName: "person.fill")
                .foregroundStyle(.white)
                .font(.system(size: size * 0.5))
        }
    }
}

/// 순위 → rarity / 펫 / 색 매핑. 카드별로 결정적이어야 페이지 다시 열어도 동일한 펫이 나옴.
enum ContributorRanking {
    /// 1위 = Legendary, 2위 = Epic, 3위 = Rare, 4위 이하 = Common.
    nonisolated static func rarity(forRank rank: Int) -> Rarity {
        switch rank {
        case 0: return .legendary
        case 1: return .epic
        case 2: return .rare
        default: return .common
        }
    }

    /// rarity 풀에서 login 기반 deterministic 픽. `String.hashValue`는 process마다 달라져
    /// 앱 재시작 시 펫이 바뀌므로 stable djb2 해시 사용.
    @MainActor
    static func pet(for rarity: Rarity, login: String) -> PetKind? {
        let pool = Gacha.pool[rarity] ?? []
        guard !pool.isEmpty else { return nil }
        let h = stableHash(login)
        return pool[h % pool.count]
    }

    nonisolated static func color(for rarity: Rarity) -> Color {
        switch rarity {
        case .legendary: return Color(red: 1.0, green: 0.78, blue: 0.20)   // 금색
        case .epic:      return Color(red: 0.62, green: 0.36, blue: 0.86)  // 보라
        case .rare:      return Color(red: 0.30, green: 0.62, blue: 0.96)  // 파랑
        case .common:    return Color.secondary
        }
    }

    /// djb2 — 같은 입력에 대해 process/플랫폼 무관하게 동일 정수.
    nonisolated static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 5381
        for byte in s.utf8 { h = ((h << 5) &+ h) &+ UInt64(byte) }
        return Int(h & UInt64(Int.max))
    }
}

@MainActor
final class ContributorsWindowController: NSWindowController {
    static let shared = ContributorsWindowController()

    convenience init() {
        let host = NSHostingController(rootView: ContributorsPageView(contributors: Contributors.shared))
        let window = NSWindow(contentViewController: host)
        window.title = "기여자"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        // 윈도우 열 때마다 캐시 검사 — 24h 지났으면 fetch.
        Task { await Contributors.shared.refreshIfNeeded() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
