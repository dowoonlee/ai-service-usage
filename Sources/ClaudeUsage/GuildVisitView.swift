import AppKit
import SwiftUI

/// 다른 길드 사무실 "놀러가기" 시트 (docs/plans/guild-visit.md M1).
///
/// 랭킹 탭 길드 리더보드 행과 미가입 온보딩 둘러보기 행에서 열린다. 진입 시 `guild-visit`을
/// 1회 호출하고 주기 폴링은 두지 않는다 (guild-info가 300s 루프를 걷어낸 이유와 같다).
/// 사무실은 `GuildOfficeView`를 읽기 전용으로 쓴다 — 재배치 바인딩은 상수 false, 콜백은 no-op.
/// 내 대표 펫이 방문객으로 들어가 배회한다 (`OfficeSimulation.Guest`).
///
/// 시트는 폭만 정하면 높이를 받은 만큼만 쓰므로 `minHeight`가 필수(CLAUDE.md "Sheets need an
/// explicit minHeight"). 최상위 `ScrollView` + `maxHeight`로 작은 화면에서도 안에 들어간다.
struct GuildVisitView: View {
    let guildId: String
    /// 응답이 오기 전 헤더에 보여줄 이름 (리더보드 행이 알고 있던 값).
    let guildName: String
    /// 프리뷰/테스트용 — 주입되면 네트워크를 타지 않는다.
    var preloaded: RankingAPI.GuildVisitResponse? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = Settings.shared
    @State private var response: RankingAPI.GuildVisitResponse?
    @State private var error: String?
    @State private var loading = false

    /// 방문객 = 내 대표 펫. 랭킹 미등록이면 닉네임이 비어 "나"로 표시.
    private var guest: OfficeSimulation.Guest {
        let avatar = settings.trainerCard.avatar
        let name = settings.rankingNickname.isEmpty ? "나" : settings.rankingNickname
        return OfficeSimulation.Guest(name: name, kind: avatar.kind, variant: avatar.variant,
                                      effects: settings.equippedEffects[avatar.kind] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let response {
                        header(response.guild)
                        officeSection(response)
                        membersSection(response)
                    } else if let error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("사무실로 가는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 540)
        .frame(minHeight: 460, maxHeight: 640)
        .onAppear(perform: load)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk").font(.system(size: 12))
            Text("\(response?.guild.name ?? guildName) 놀러가기")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button("닫기") { dismiss() }
                .font(.system(size: 11))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 로고 · 이름 · 이번 달 순위/점수 · 인원. 내 길드면 배지.
    private func header(_ guild: RankingAPI.GuildVisitGuild) -> some View {
        HStack(spacing: 10) {
            GuildLogoBanner(logo: guild.logo, guildID: guild.id, width: 72)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(guild.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if guild.isMine {
                        Text("내 길드")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow).font(.system(size: 10))
                    if let rank = guild.rank {
                        Text("이번 달 \(rank)위").font(.system(size: 11, weight: .semibold))
                    } else {
                        Text("이번 달 순위 없음").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("\(guild.score) VP")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.purple)
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 8))
                    Text("\(guild.memberCount)명").font(.system(size: 10))
                    Text("· \(Self.formatCreated(guild.createdAt)) 창설").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.purple.opacity(0.07)))
    }

    /// 읽기 전용 사무실 + 방문객 펫. 콜백은 전부 no-op — 방문자는 아무것도 바꿀 수 없다.
    private func officeSection(_ response: RankingAPI.GuildVisitResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GuildOfficeView(
                info: response.asInfoResponse,
                rearrangeMode: .constant(false),
                previewFloorTheme: .constant(nil),
                previewWallTheme: .constant(nil),
                onSetFurniture: { _ in },
                onSetLogoPos: { _, _ in },
                onBuyFurniture: { _, _ in },
                onPlaceDecor: { _, _ in },
                onRemoveDecor: { _ in },
                onApplyTheme: {},
                guest: guest,
                purchaseSheetOpen: .constant(false)
            )
            Text("내 대표 펫이 놀러가 있어요. 펫을 클릭하면 이름이 보여요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// 멤버 칩 — 대표 펫 + 닉네임 (+★ 기여자 / 👑 길드장). 트레이너 카드는 일부러 열지 않는다:
    /// 방문 응답은 profileJson을 싣지 않는다 (Egress — guild-visit.md §1).
    private func membersSection(_ response: RankingAPI.GuildVisitResponse) -> some View {
        let members = response.members.sorted {
            if $0.isLeader != $1.isLeader { return $0.isLeader }
            if $0.isTopContributor != $1.isTopContributor { return $0.isTopContributor }
            if $0.monthlyVP != $1.monthlyVP { return $0.monthlyVP > $1.monthlyVP }
            return $0.nickname < $1.nickname
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("멤버").font(.system(size: 12, weight: .semibold))
                Text("★ = 길드 점수 반영 중").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(members) { member in
                    memberChip(member)
                }
            }
        }
    }

    private func memberChip(_ member: RankingAPI.GuildMember) -> some View {
        let avatar = member.officeAvatar
        return HStack(spacing: 5) {
            if let frame = PetSprite.image(for: avatar.kind, action: .walk, frameIndex: 0) {
                Image(nsImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .hueRotation(.degrees(avatar.variant == PetOwnership.prestigeVariant
                        ? 0 : WalkingCat.hueDegrees(for: avatar.variant)))
                    .scaleEffect(x: avatar.kind.defaultFacingLeft ? -1 : 1, y: 1)
                    .frame(width: 22, height: 20)
            }
            if member.isLeader { Text("👑").font(.system(size: 9)) }
            Text(member.nickname).font(.system(size: 11)).lineLimit(1)
            if member.isTopContributor {
                Text("★").font(.system(size: 9)).foregroundStyle(.yellow)
            }
            Text("\(member.monthlyVP)")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.purple.opacity(0.8))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(member.isMe ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1)))
        .help("\(member.nickname) · 이번 달 \(member.monthlyVP) VP")
    }

    private func load() {
        if let preloaded {
            response = preloaded
            return
        }
        guard response == nil, !loading else { return }
        guard RankingAPI.isConfigured, settings.rankingRegistered else {
            error = "랭킹 참여 후 다른 길드를 방문할 수 있어요."
            return
        }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                response = try await RankingAPI.shared.visitGuild(
                    deviceId: settings.rankingDeviceID, guildId: guildId, hmacKeyBase64: key)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.friendlyDescription
            }
        }
    }

    private static func formatCreated(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.M.d"
        return f.string(from: date)
    }
}
