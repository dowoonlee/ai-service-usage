import AppKit
import SwiftUI

/// 길드 사무실 씬 — 멤버 대표 펫들이 자기 스팟 주변을 오가는 공유 공간 (docs/plans/guild.md §5-1/5-2).
///
/// 렌더 레이어 (z 오름차순): 배경(벽+바닥 프리렌더) → 벽 장식/가구(레인 순) → 빈 스팟 마커
/// → 펫(이펙트 backdrop → 스프라이트 → 파티클) → 말풍선. 레인이 뒤(위)일수록 먼저 그려
/// 앞레인이 자연히 가린다.
///
/// 배치 모드: 빈 스팟이 하이라이트되고 클릭 → `onSelectSlot`. 점유 스팟은 클릭 불가.
/// 재배치 모드(길드장): 포지션을 두 번 클릭해 가구 세트를 스왑 → `onSetLayout`(새 순열).
struct GuildOfficeView: View {
    let info: RankingAPI.GuildInfoResponse
    @Binding var placementMode: Bool
    @Binding var rearrangeMode: Bool
    let onSelectSlot: (Int) -> Void
    let onSetLayout: ([Int]) -> Void

    @StateObject private var sim = OfficeSimulation()
    @State private var popoverPetID: String?
    /// 재배치 모드에서 첫 번째로 고른 포지션 — 두 번째 클릭과 스왑.
    @State private var rearrangeSource: Int?

    private var scene: CGSize { OfficeLayout.sceneSize }
    /// 길드 가구 배치 — 서버 순열(검증 실패 시 기본 배치 폴백).
    private var layout: [Int] { OfficeLayout.sanitizedLayout(info.guild.officeLayout) }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / scene.width
            ZStack(alignment: .topLeading) {
                background(scale: scale)
                furnitureLayer(scale: scale)
                if !rearrangeMode {
                    spotMarkerLayer(scale: scale)
                }
                petLayer(scale: scale)
                if rearrangeMode {
                    rearrangeLayer(scale: scale)
                }
            }
            .frame(width: geo.size.width, height: scene.height * scale)
        }
        .aspectRatio(scene.width / scene.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
        )
        .onAppear { sim.configure(members: info.members, layout: layout) }
        .onDisappear { sim.stop() }
        .onChange(of: membersKey) { _ in sim.configure(members: info.members, layout: layout) }
        .onChange(of: rearrangeMode) { _ in rearrangeSource = nil }
    }

    /// 멤버·가구 배치 변경 감지 키 — 순서 무관.
    private var membersKey: String {
        info.members.map { "\($0.nickname):\($0.officeSlot ?? -1):\($0.isTopContributor):\($0.monthlyVP > 0)" }
            .sorted().joined(separator: ",")
            + "|layout:" + layout.map(String.init).joined(separator: ",")
    }

    private var occupiedSlots: Set<Int> {
        Set(info.members.compactMap(\.officeSlot))
    }

    // MARK: - 배경

    @ViewBuilder
    private func background(scale: CGFloat) -> some View {
        if let bg = OfficeLayout.backgroundImage {
            Image(nsImage: bg)
                .interpolation(.none)
                .resizable()
                .frame(width: scene.width * scale, height: scene.height * scale)
        } else {
            // 리소스 로드 실패 fallback — 단색 벽/바닥.
            VStack(spacing: 0) {
                Color(red: 0.85, green: 0.83, blue: 0.78)
                    .frame(height: OfficeLayout.wallBottom * scale)
                Color(red: 0.65, green: 0.63, blue: 0.60)
            }
        }
    }

    // MARK: - 가구

    @ViewBuilder
    private func furnitureLayer(scale: CGFloat) -> some View {
        // 벽 장식 — 붙박이 (재배치 무관).
        ForEach(Array(OfficeLayout.wallDecor.enumerated()), id: \.offset) { _, decor in
            itemView(imageName: decor.imageName, drawKind: decor.drawKind, size: decor.size,
                     anchorX: decor.anchorX, baselineY: decor.baselineY, scale: scale)
        }
        // 바닥 가구 — 포지션 순회 + layout으로 세트 결정. 레인 오름차순 = 뒤부터.
        ForEach(OfficeLayout.spots) { pos in
            if let item = OfficeLayout.furnitureSet(at: pos.id, layout: layout)?.item {
                itemView(imageName: item.imageName, drawKind: item.drawKind, size: item.size,
                         anchorX: pos.anchorX, baselineY: OfficeLayout.lanes[pos.lane], scale: scale)
            }
        }
        // 데스크 세트가 놓인 포지션의 모니터 — 점유자가 working이면 ON 애니, 아니면 OFF.
        ForEach(OfficeLayout.spots.filter { OfficeLayout.hasPC(at: $0.id, layout: layout) }) { spot in
            pcView(for: spot, scale: scale)
        }
    }

    @ViewBuilder
    private func itemView(imageName: String?, drawKind: OfficeLayout.DrawKind?, size: CGSize,
                          anchorX: CGFloat, baselineY: CGFloat, scale: CGFloat) -> some View {
        let w = size.width * scale
        let h = size.height * scale
        Group {
            if let imageName, let img = OfficeLayout.officeImage(imageName) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
            } else if let drawKind {
                CodeDrawnFurniture(kind: drawKind)
            }
        }
        .frame(width: w, height: h)
        .position(x: anchorX * scale, y: (baselineY - size.height / 2) * scale)
    }

    @ViewBuilder
    private func pcView(for spot: OfficeLayout.Spot, scale: CGFloat) -> some View {
        let working = info.members.contains {
            $0.officeSlot == spot.id && $0.isTopContributor && $0.monthlyVP > 0
        }
        let deskBaseline = OfficeLayout.lanes[spot.lane]
        let baseline = OfficeLayout.pcBaselineY(deskBaselineY: deskBaseline)
        let size = OfficeLayout.pcSize
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let name: String = {
                guard working else { return "PC_FRONT_OFF" }
                let idx = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 3 + 1
                return "PC_FRONT_ON_\(idx)"
            }()
            if let img = OfficeLayout.officeImage(name) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size.width * scale, height: size.height * scale)
                    .position(x: spot.anchorX * scale,
                              y: (baseline - size.height / 2) * scale)
            }
        }
    }

    // MARK: - 스팟 마커

    @ViewBuilder
    private func spotMarkerLayer(scale: CGFloat) -> some View {
        ForEach(OfficeLayout.spots) { spot in
            let occupied = occupiedSlots.contains(spot.id)
            if !occupied || placementMode {
                spotMarker(spot, occupied: occupied, scale: scale)
            }
        }
    }

    private func spotMarker(_ spot: OfficeLayout.Spot, occupied: Bool, scale: CGFloat) -> some View {
        let y = OfficeLayout.lanes[spot.lane]
        let selectable = placementMode && !occupied
        return VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                .foregroundStyle(selectable ? Color.accentColor : Color.gray.opacity(0.45))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selectable ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .frame(width: 26 * scale, height: 10 * scale)
            Text(spot.name)
                .font(.system(size: max(7, 4.5 * scale)))
                .foregroundStyle(selectable ? Color.accentColor : .secondary)
                .lineLimit(1)
                .fixedSize()   // 박스 폭보다 긴 이름("화이트보드 앞") 잘림 방지
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Capsule().fill(Color(NSColor.windowBackgroundColor).opacity(0.7)))
        }
        .position(x: spot.anchorX * scale, y: (y - 2) * scale)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable { onSelectSlot(spot.id) }
        }
        .opacity(occupied && placementMode ? 0.35 : 1)
    }

    // MARK: - 가구 재배치 (길드장 전용 모드)

    /// 모든 포지션에 선택 박스 오버레이 — 첫 클릭 선택(주황 하이라이트), 두 번째 클릭과 스왑.
    /// 같은 포지션 재클릭은 선택 해제. 스왑 즉시 `onSetLayout`(새 순열) 호출.
    @ViewBuilder
    private func rearrangeLayer(scale: CGFloat) -> some View {
        ForEach(OfficeLayout.spots) { pos in
            let setName = OfficeLayout.furnitureSet(at: pos.id, layout: layout)?.name ?? "?"
            let isSource = rearrangeSource == pos.id
            VStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSource ? Color.orange : Color.accentColor,
                                  lineWidth: isSource ? 2 : 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill((isSource ? Color.orange : Color.accentColor).opacity(0.15))
                    )
                    .frame(width: 44 * scale, height: 26 * scale)
                Text(setName)
                    .font(.system(size: max(7, 4.5 * scale), weight: isSource ? .bold : .regular))
                    .foregroundStyle(isSource ? Color.orange : Color.accentColor)
                    .fixedSize()
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Capsule().fill(Color(NSColor.windowBackgroundColor).opacity(0.85)))
            }
            .position(x: pos.anchorX * scale, y: (OfficeLayout.lanes[pos.lane] - 14) * scale)
            .contentShape(Rectangle())
            .onTapGesture { handleRearrangeTap(pos.id) }
        }
    }

    private func handleRearrangeTap(_ position: Int) {
        guard let source = rearrangeSource else {
            rearrangeSource = position
            return
        }
        rearrangeSource = nil
        guard source != position else { return }   // 같은 곳 재클릭 = 선택 해제
        var newLayout = layout
        newLayout.swapAt(source, position)
        onSetLayout(newLayout)
    }

    // MARK: - 펫

    @ViewBuilder
    private func petLayer(scale: CGFloat) -> some View {
        // 레인(=baseline) 순서로 그려 앞레인이 뒤레인을 가린다.
        ForEach(sim.pets.sorted { $0.spot.lane < $1.spot.lane }) { pet in
            OfficePetView(
                pet: pet,
                scale: scale,
                showPopover: Binding(
                    get: { popoverPetID == pet.id },
                    set: { if !$0 { popoverPetID = nil } }
                ),
                onTap: { popoverPetID = pet.id },
                member: info.members.first { $0.nickname == pet.id }
            )
        }
    }
}

// MARK: - 펫 1마리 렌더

@MainActor
private struct OfficePetView: View {
    let pet: OfficeSimulation.PetState
    let scale: CGFloat
    @Binding var showPopover: Bool
    let onTap: () -> Void
    let member: RankingAPI.GuildMember?

    var body: some View {
        // 펫 바닥선을 가구보다 4논리px 앞(아래)에 — 책상 "위"에 올라간 것처럼 보이는 겹침 방지.
        let laneY = OfficeLayout.lanes[pet.spot.lane] + 4
        let isMythicPet = Mythic.isMythic(pet.kind)
        let height = OfficeLayout.petHeight * (isMythicPet ? 1.5 : 1.0) * scale
        let centerX = pet.x * scale
        let centerY = (laneY * scale) - height / 2

        TimelineView(.animation(minimumInterval: 1.0 / 8)) { ctx in
            let frames = PetSprite.frames(for: pet.kind, action: pet.isWalking ? .walk : .sit)
            let frameIdx = frames.isEmpty ? 0 : Int(ctx.date.timeIntervalSinceReferenceDate * 8) % frames.count
            ZStack {
                // Mythic 오라 + 구매 이펙트 backdrop — 스프라이트 뒤.
                PetEffectOverlay(
                    effects: pet.equippedEffects,
                    placement: .backdrop,
                    center: CGPoint(x: centerX, y: centerY),
                    footY: laneY * scale,
                    petHeight: height,
                    facingRight: pet.facingRight,
                    isMoving: pet.isWalking,
                    mythicBase: isMythicPet,
                    mythicAuraStyle: Mythic.spec(for: pet.kind)?.aura ?? .crimsonGold
                )
                if !frames.isEmpty {
                    petSprite(frames[frameIdx], height: height)
                        .position(x: centerX, y: centerY)
                }
                PetEffectOverlay(
                    effects: pet.equippedEffects,
                    placement: .particles,
                    center: CGPoint(x: centerX, y: centerY),
                    footY: laneY * scale,
                    petHeight: height,
                    facingRight: pet.facingRight,
                    isMoving: pet.isWalking
                )
                if let bubble = pet.bubble {
                    bubbleView(bubble)
                        .position(x: centerX, y: centerY - height / 2 - 9)
                }
            }
        }
        .contentShape(Rectangle())
        .help("\(pet.id) · 이번 달 \(pet.monthlyVP) VP · \(pet.spot.name)")
        .onTapGesture { onTap() }
        .popover(isPresented: $showPopover, arrowEdge: .top) { popoverContent }
    }

    private func petSprite(_ frame: NSImage, height: CGFloat) -> some View {
        let isRainbow = pet.variant == PetOwnership.prestigeVariant
        // 스프라이트 원본 방향 보정 — 오른쪽 보기 = 원본이 왼쪽 보기인 팩만 flip.
        let xScale: CGFloat = (pet.facingRight != pet.kind.defaultFacingLeft) ? 1 : -1
        return Image(nsImage: frame)
            .interpolation(.none)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .hueRotation(.degrees(isRainbow ? 0 : WalkingCat.hueDegrees(for: pet.variant)))
            .colorMultiply(isRainbow
                ? WalkingCat.prestigeTint(at: Date().timeIntervalSinceReferenceDate) : .white)
            .saturation(pet.variant > 0 ? 1.15 : 1.0)
            .scaleEffect(x: xScale, y: 1)
    }

    private func bubbleView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(NSColor.windowBackgroundColor).opacity(0.92)))
            .overlay(Capsule().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            .fixedSize()
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let member, let profile = member.profileJson {
            TrainerCardView(
                card: profile.card,
                trainerID: profile.trainerID,
                trainerName: member.nickname,
                stats: profile.stats,
                badges: profile.badgeRowsForRender(),
                collections: profile.collectionRowsForRender(),
                showWatermark: false,
                width: 460,
                medals: nil,
                animatedAvatar: true,
                equippedEffects: Set((profile.equippedEffects ?? []).compactMap { EffectKind(rawValue: $0) })
            )
            .padding(8)
        } else {
            VStack(spacing: 4) {
                Text(pet.id).font(.system(size: 13, weight: .semibold))
                Text("\(pet.monthlyVP) VP").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

// MARK: - DEBUG 데모 (`AIUSAGE_OFFICE_DEMO=1 swift run`)

#if DEBUG
/// 서버 없이 mock 멤버로 사무실 씬을 확인하는 로컬 미리보기. 배치/애니/충돌 범위·Mythic
/// 오라·이로치·수면/작업 모드를 한 화면에서 검증한다. 릴리스 빌드 미포함.
@MainActor
enum GuildOfficeDemo {
    private static var window: NSWindow?

    static func present() {
        func member(_ nick: String, slot: Int?, kind: PetKind, variant: Int = 0,
                    vp: Int, top: Bool, me: Bool = false,
                    effects: [String] = []) -> RankingAPI.GuildMember {
            var card = TrainerCard.default
            card.avatar = PetSelection(kind: kind, variant: variant)
            let profile = ProfileState(
                card: card, trainerID: "DEMO", stats: TrainerStats.compute(from: Settings.shared),
                clearedBadges: [], completedCollections: [], backup: nil,
                equippedEffects: effects, integrityViolation: false)
            return RankingAPI.GuildMember(
                nickname: nick, monthlyVP: vp, isTopContributor: top, officeSlot: slot,
                isLeader: me, isMe: me, joinedAt: Date(), githubLogin: nil,
                profileJson: profile, deviceId: nil)
        }
        let members = [
            member("dowoon", slot: 0, kind: .fox, variant: 1, vp: 3120, top: true, me: true),
            member("kimcoder", slot: 4, kind: .warrior, vp: 2400, top: true, effects: ["glow"]),
            member("vibewolf", slot: 5, kind: .wolf, variant: 4, vp: 1800, top: true),
            member("nightowl", slot: 8, kind: .whale, vp: 700, top: true),
            member("lurker42", slot: 6, kind: .ninjaFrog, vp: 400, top: true),
            member("ghostdev", slot: 9, kind: .slime, vp: 0, top: false),
            member("newbie", slot: 10, kind: .pawn, vp: 120, top: false),
            member("미배치멤버", slot: nil, kind: .fox, vp: 50, top: false),
        ]
        let w = NSWindow(contentViewController: NSHostingController(rootView: DemoWrapper(members: members)))
        w.title = "길드 사무실 데모"
        w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 캡처 자동화용 — `screencapture -l<이 번호>`. 파이프 실행에서도 즉시 흐르게 flush.
        print("OFFICE_DEMO_WINDOW=\(w.windowNumber)")
        fflush(stdout)
    }

    private struct DemoWrapper: View {
        let members: [RankingAPI.GuildMember]
        @State private var placement = false
        // 캡처 자동화 편의 — `AIUSAGE_OFFICE_DEMO=rearrange`면 재배치 모드로 시작,
        // `=swapped`면 스왑된 배치로 시작 (클릭 자동화 없이 두 상태를 스크린샷 검증).
        @State private var rearrange =
            ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "rearrange"
        /// 재배치를 로컬에서 즉시 반영 — 서버 없이 스왑 동작 확인.
        @State private var layout: [Int] = {
            if ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "swapped" {
                var l = OfficeLayout.defaultLayout
                l.swapAt(0, 8)    // 데스크+PC ↔ 소파
                l.swapAt(5, 10)   // 데스크+PC ↔ 화분
                return l
            }
            return OfficeLayout.defaultLayout
        }()

        private var info: RankingAPI.GuildInfoResponse {
            let guild = RankingAPI.GuildInfo(
                id: "demo", name: "데드락클럽", inviteCode: "AB3F9K2M", isLeader: true,
                floorTheme: 0, wallTheme: 0, officeLayout: layout, createdAt: Date(),
                score: 8420, rank: 3, memberCount: members.count)
            return RankingAPI.GuildInfoResponse(guild: guild, members: members, furniture: [])
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                GuildOfficeView(
                    info: info,
                    placementMode: $placement,
                    rearrangeMode: $rearrange,
                    onSelectSlot: { slot in print("OFFICE_DEMO_SELECT slot=\(slot)") },
                    onSetLayout: { newLayout in
                        layout = newLayout
                        print("OFFICE_DEMO_LAYOUT=\(newLayout.map(String.init).joined(separator: ","))")
                        fflush(stdout)
                    }
                )
                HStack {
                    Toggle("배치 모드", isOn: $placement).font(.system(size: 11))
                    Toggle("가구 재배치", isOn: $rearrange).font(.system(size: 11))
                }
            }
            .padding(12)
            // NSHostingController fitting-size 패스는 (nil,nil) 제안이라 aspectRatio가 ideal(10pt)로
            // 붕괴한다 — 실사용(GachaView 고정 560×640 + ScrollView)처럼 크기를 명시해 재현 환경을 맞춘다.
            .frame(width: 560, height: 420)
        }
    }
}
#endif

// MARK: - 코드 드로잉 가구 (에셋 공백 3종 — research/office-assets.md)

/// 서버랙·스탠딩 데스크·창문 — CC0 팩에 없는 3종을 단순 도형으로. 씬 좌표 체계만 유지하면
/// 추후 에셋 교체 비용이 낮다 (기획 §5-2 fallback 원칙).
private struct CodeDrawnFurniture: View {
    let kind: OfficeLayout.DrawKind

    var body: some View {
        switch kind {
        case .serverRack: serverRack
        case .standingDesk: standingDesk
        case .window: window
        }
    }

    /// 수직 랙 + 점멸 LED — 형태가 단순해 코드 드로잉 리스크가 가장 낮은 소품.
    private var serverRack: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.16, green: 0.17, blue: 0.20))
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(Color.black.opacity(0.7), lineWidth: 1)
                VStack(spacing: h * 0.06) {
                    ForEach(0..<4, id: \.self) { row in
                        HStack(spacing: w * 0.08) {
                            TimelineView(.periodic(from: .now, by: 0.8)) { ctx in
                                let on = (Int(ctx.date.timeIntervalSinceReferenceDate / 0.8) + row) % 3 != 0
                                Circle().fill(on ? Color.green : Color.green.opacity(0.25))
                                    .frame(width: w * 0.12, height: w * 0.12)
                            }
                            Rectangle().fill(Color.white.opacity(0.12))
                                .frame(width: w * 0.5, height: h * 0.05)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, w * 0.15)
                    }
                }
            }
        }
    }

    private var standingDesk: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 상판
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.55, green: 0.38, blue: 0.24))
                    .frame(height: h * 0.18)
                    .position(x: w / 2, y: h * 0.12)
                // 다리 2개
                ForEach([0.2, 0.8], id: \.self) { fx in
                    Rectangle()
                        .fill(Color(red: 0.35, green: 0.35, blue: 0.38))
                        .frame(width: w * 0.07, height: h * 0.8)
                        .position(x: w * fx, y: h * 0.6)
                }
                // 노트북 실루엣
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(red: 0.75, green: 0.76, blue: 0.78))
                    .frame(width: w * 0.3, height: h * 0.14)
                    .position(x: w / 2, y: h * 0.02)
            }
        }
    }

    private var window: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.75, blue: 0.95),
                                                  Color(red: 0.75, green: 0.88, blue: 0.98)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(Color(red: 0.45, green: 0.35, blue: 0.25), lineWidth: 1.5)
                Rectangle().fill(Color(red: 0.45, green: 0.35, blue: 0.25))
                    .frame(width: 1.5)
                Rectangle().fill(Color(red: 0.45, green: 0.35, blue: 0.25))
                    .frame(height: 1.5)
                // 구름 한 점
                Capsule().fill(Color.white.opacity(0.8))
                    .frame(width: w * 0.3, height: h * 0.15)
                    .position(x: w * 0.35, y: h * 0.3)
            }
        }
    }
}
