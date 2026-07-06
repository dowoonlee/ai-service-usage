import AppKit
import SwiftUI

/// 길드 사무실 씬 — 멤버 대표 펫들이 자기 스팟 주변을 오가는 공유 공간 (docs/plans/guild.md §5-1/5-2).
///
/// 렌더 레이어 (z 오름차순): 배경(벽+바닥 프리렌더) → 벽 장식/가구(레인 순) → 빈 스팟 마커
/// → 펫(이펙트 backdrop → 스프라이트 → 파티클) → 말풍선. 레인이 뒤(위)일수록 먼저 그려
/// 앞레인이 자연히 가린다.
///
/// 멤버 배치: 자동 랜덤 — `OfficeLayout.autoAssignments` 결정적 해시로 클라이언트에서 배정
/// (수동 자리 선택은 사용자 피드백으로 폐기. 서버 office_slot은 더 이상 읽지 않는다).
/// 재배치 모드(길드장): 가구를 **마우스 드래그**로 자유 이동 — 놓으면 가장 가까운 레인에 스냅
/// 후 서버 저장 (레포트 탭 악세서리 드래그와 동일한 감각. 스왑 클릭 방식은 사용자 피드백으로 폐기).
/// 꾸미기 모드(P2b): 데코 슬롯 표시 — 빈 슬롯 클릭 → 카탈로그 구매, 찬 슬롯 → 교체/제거.
struct GuildOfficeView: View {
    let info: RankingAPI.GuildInfoResponse
    @Binding var rearrangeMode: Bool
    @Binding var decorateMode: Bool
    /// 가구 드래그 종료 시 — 직렬화된 전체 배치("setId:x:lane;…"). 호출 측이 서버 반영.
    let onSetFurniture: (String) -> Void
    /// 데코 구매 (slot, item) — 호출 측이 코인 검증·서버 반영.
    let onPlaceDecor: (Int, OfficeLayout.DecorItem) -> Void
    let onRemoveDecor: (Int) -> Void

    @StateObject private var sim = OfficeSimulation()
    @State private var popoverPetID: String?
    /// 드래그 중 작업 사본 — nil이면 서버 값 사용. 드롭 후 서버 값이 따라오면 자동 해제.
    @State private var draftPlacements: [OfficeLayout.FurniturePlacement]?
    /// 현재 드래그 중인 가구 세트 id (하이라이트용).
    @State private var draggingSetId: Int?
    /// 꾸미기 모드에서 카탈로그 popover가 열린 데코 슬롯.
    @State private var decorPopoverSlot: Int?

    private var scene: CGSize { OfficeLayout.sceneSize }
    /// 서버 가구 배치 (검증 실패/빈 값은 기본 배치 폴백).
    private var serverPlacements: [OfficeLayout.FurniturePlacement] {
        OfficeLayout.sanitizedPlacements(info.guild.officeFurniture)
    }
    /// 렌더/시뮬레이션에 쓰는 유효 배치 — 드래그 중이면 작업 사본.
    private var placements: [OfficeLayout.FurniturePlacement] {
        draftPlacements ?? serverPlacements
    }
    private var placedDecor: [RankingAPI.GuildFurnitureItem] { info.furniture }
    /// 자동 배치 — 기여자·VP 우선 12명을 결정적 해시로 포지션에 배정. isMe 등 클라이언트마다
    /// 다른 값은 정렬에 쓰지 않는다 (모두가 같은 씬을 봐야 하므로).
    private var assignments: [String: Int] {
        let ordered = info.members.sorted {
            if $0.isTopContributor != $1.isTopContributor { return $0.isTopContributor }
            if $0.monthlyVP != $1.monthlyVP { return $0.monthlyVP > $1.monthlyVP }
            return $0.nickname < $1.nickname
        }.map(\.nickname)
        return OfficeLayout.autoAssignments(memberIds: ordered, seed: info.guild.id)
    }

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / scene.width
            ZStack(alignment: .topLeading) {
                background(scale: scale)
                furnitureLayer(scale: scale)
                decorLayer(scale: scale)
                petLayer(scale: scale)
                if decorateMode {
                    decorateLayer(scale: scale)
                }
            }
            .frame(width: geo.size.width, height: scene.height * scale)
            .coordinateSpace(name: "officeScene")   // 가구 드래그 좌표 기준
        }
        .aspectRatio(scene.width / scene.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.md)
                .strokeBorder(rearrangeMode ? Color.orange.opacity(0.6) : Color.gray.opacity(0.25),
                              lineWidth: rearrangeMode ? 1.5 : 1)
        )
        .onAppear { reconfigureSim() }
        .onDisappear { sim.stop() }
        .onChange(of: membersKey) { _ in reconfigureSim() }
        .onChange(of: rearrangeMode) { _ in
            draftPlacements = nil
            draggingSetId = nil
        }
        // 서버 값이 드래그 결과를 따라잡으면 작업 사본 해제 (refresh 후 재정합).
        .onChange(of: info.guild.officeFurniture ?? "") { _ in
            if draggingSetId == nil { draftPlacements = nil }
        }
        .onChange(of: decorateMode) { _ in decorPopoverSlot = nil }
    }

    private func reconfigureSim() {
        sim.configure(members: info.members, assignments: assignments, placements: placements,
                      decor: placedDecor.map { (slotId: $0.slotId, kind: $0.itemKind) })
    }

    /// 멤버·자동 배치·가구 배치·데코 변경 감지 키 — 순서 무관.
    private var membersKey: String {
        let assigned = assignments
        return info.members.map {
            "\($0.nickname):\(assigned[$0.nickname] ?? -1):\($0.isTopContributor):\($0.monthlyVP > 0)"
        }
            .sorted().joined(separator: ",")
            + "|furniture:" + OfficeLayout.serializePlacements(placements)
            + "|decor:" + placedDecor.map { "\($0.slotId):\($0.itemKind)" }.sorted().joined(separator: ",")
    }

    // MARK: - 배경 (floorTheme + wall 틴트 — P2b 인테리어 테마)

    @ViewBuilder
    private func background(scale: CGFloat) -> some View {
        if let bg = OfficeLayout.backgroundImage(floorTheme: info.guild.floorTheme) {
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
        // 벽지 틴트 — 벽 밴드 위 반투명 오버레이 (0 = 기본, 오버레이 없음).
        if info.guild.wallTheme > 0, info.guild.wallTheme < OfficeLayout.wallTints.count {
            OfficeLayout.wallTints[info.guild.wallTheme]
                .opacity(0.18)
                .frame(width: scene.width * scale, height: OfficeLayout.wallBottom * scale)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 데코 (배치된 기부 아이템 — 항상 표시, 호버 시 기부자 명판)

    @ViewBuilder
    private func decorLayer(scale: CGFloat) -> some View {
        ForEach(placedDecor, id: \.slotId) { placed in
            if let slot = OfficeLayout.decorSlot(id: placed.slotId),
               let item = OfficeLayout.decorItem(kind: placed.itemKind) {
                itemView(imageName: item.imageName, drawKind: nil, size: item.size,
                         anchorX: slot.anchorX, baselineY: slot.baselineY, scale: scale)
                    .help(placed.donorNickname.map { "\(item.name) — \($0) 기부" } ?? item.name)
            }
        }
    }

    /// 꾸미기 모드 오버레이 — 빈 슬롯은 점선 + 클릭 구매, 찬 슬롯은 교체/제거.
    @ViewBuilder
    private func decorateLayer(scale: CGFloat) -> some View {
        ForEach(OfficeLayout.decorSlots) { slot in
            let placed = placedDecor.first { $0.slotId == slot.id }
            decorSlotMarker(slot, placed: placed, scale: scale)
        }
    }

    private func decorSlotMarker(_ slot: OfficeLayout.DecorSlot,
                                 placed: RankingAPI.GuildFurnitureItem?,
                                 scale: CGFloat) -> some View {
        let tint: Color = slot.category == .wall ? .pink : .orange
        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [3]))
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(placed == nil ? 0.15 : 0.05)))
            .frame(width: 20 * scale, height: 18 * scale)
            .overlay(alignment: .bottom) {
                Text(placed == nil ? "+" : "↺")
                    .font(.system(size: max(8, 5 * scale), weight: .bold))
                    .foregroundStyle(tint)
            }
            // 제스처/popover는 .position보다 먼저 — 뒤에 붙이면 탭 영역이 씬 전체가 되고
            // popover 앵커도 어긋난다 (spotMarker와 동일 원인의 버그).
            .contentShape(Rectangle())
            .onTapGesture { decorPopoverSlot = slot.id }
            .popover(isPresented: Binding(
                get: { decorPopoverSlot == slot.id },
                set: { if !$0 { decorPopoverSlot = nil } }
            ), arrowEdge: .bottom) {
                DecorCatalogSheet(
                    slot: slot,
                    placed: placed,
                    canRemove: placed != nil &&
                        (info.guild.isLeader || placed?.donorNickname == Settings.shared.rankingNickname),
                    onBuy: { item in
                        decorPopoverSlot = nil
                        onPlaceDecor(slot.id, item)
                    },
                    onRemove: {
                        decorPopoverSlot = nil
                        onRemoveDecor(slot.id)
                    }
                )
            }
            .position(x: slot.anchorX * scale, y: (slot.baselineY - 9) * scale)
    }

    // MARK: - 가구

    @ViewBuilder
    private func furnitureLayer(scale: CGFloat) -> some View {
        // 벽 장식 — 붙박이 (재배치 무관).
        ForEach(Array(OfficeLayout.wallDecor.enumerated()), id: \.offset) { _, decor in
            itemView(imageName: decor.imageName, drawKind: decor.drawKind, size: decor.size,
                     anchorX: decor.anchorX, baselineY: decor.baselineY, scale: scale)
        }
        // 바닥 가구 — 자유 배치 좌표. 레인 오름차순 = 뒤부터 (드래그 중인 항목은 맨 위).
        ForEach(placements.sorted {
            if $0.setId == draggingSetId { return false }
            if $1.setId == draggingSetId { return true }
            return $0.lane < $1.lane
        }) { placement in
            furnitureView(placement, scale: scale)
        }
        // 데스크 세트의 모니터 — 가장 가까운 자리 점유자가 working이면 ON 애니.
        ForEach(placements.filter { OfficeLayout.furnitureSet(id: $0.setId)?.hasPC == true }) { placement in
            pcView(for: placement, scale: scale)
        }
    }

    /// 가구 1점 — 재배치 모드(길드장)에서는 드래그로 이동, 놓으면 레인 스냅 후 서버 저장.
    /// 제스처/하이라이트는 반드시 .position 앞에 (히트 영역 전체 확장 버그 방지 — spotMarker 참조).
    @ViewBuilder
    private func furnitureView(_ placement: OfficeLayout.FurniturePlacement, scale: CGFloat) -> some View {
        if let item = OfficeLayout.furnitureSet(id: placement.setId)?.item {
            let isDragging = draggingSetId == placement.setId
            let w = item.size.width * scale
            let h = item.size.height * scale
            let body = Group {
                if let name = item.imageName, let img = OfficeLayout.officeImage(name) {
                    Image(nsImage: img).interpolation(.none).resizable()
                } else if let kind = item.drawKind {
                    CodeDrawnFurniture(kind: kind)
                }
            }
            .frame(width: w, height: h)
            .overlay {
                if rearrangeMode {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [3]))
                        .foregroundStyle(isDragging ? Color.orange : Color.accentColor)
                }
            }
            let positionX = placement.x * scale
            let positionY = (OfficeLayout.lanes[placement.lane] - item.size.height / 2) * scale
            if rearrangeMode {
                body
                    .contentShape(Rectangle())
                    .gesture(furnitureDrag(placement, scale: scale))
                    .position(x: positionX, y: positionY)
            } else {
                body.position(x: positionX, y: positionY)
            }
        }
    }

    /// 드래그 제스처 — 이동 중 작업 사본 갱신(펫 충돌 범위도 실시간 추종), 종료 시 서버 저장.
    private func furnitureDrag(_ placement: OfficeLayout.FurniturePlacement,
                               scale: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("officeScene"))
            .onChanged { value in
                draggingSetId = placement.setId
                var working = draftPlacements ?? serverPlacements
                guard let idx = working.firstIndex(where: { $0.setId == placement.setId }) else { return }
                let snapped = OfficeLayout.clampPlacement(x: value.location.x / scale,
                                                          laneY: value.location.y / scale)
                working[idx].x = snapped.x
                working[idx].lane = snapped.lane
                draftPlacements = working
            }
            .onEnded { _ in
                draggingSetId = nil
                if let working = draftPlacements {
                    onSetFurniture(OfficeLayout.serializePlacements(working))
                }
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

    /// 데스크 위 모니터 — 데스크가 어느 자리(스팟) 근처에 있으면 그 자리 점유자의 working
    /// 여부로 ON/OFF. 가구가 자유 이동하므로 "같은 레인 + 24px 이내" 근접 기준.
    @ViewBuilder
    private func pcView(for placement: OfficeLayout.FurniturePlacement, scale: CGFloat) -> some View {
        let nearSpot = OfficeLayout.spots
            .filter { $0.lane == placement.lane && abs($0.anchorX - placement.x) < 24 }
            .min { abs($0.anchorX - placement.x) < abs($1.anchorX - placement.x) }
        let assigned = assignments
        let working = nearSpot.map { spot in
            info.members.contains {
                assigned[$0.nickname] == spot.id && $0.isTopContributor && $0.monthlyVP > 0
            }
        } ?? false
        let baseline = OfficeLayout.pcBaselineY(deskBaselineY: OfficeLayout.lanes[placement.lane])
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
                    .position(x: placement.x * scale,
                              y: (baseline - size.height / 2) * scale)
            }
        }
    }

    // MARK: - 펫

    @ViewBuilder
    private func petLayer(scale: CGFloat) -> some View {
        // 레인(=baseline) 순서로 그려 앞레인이 뒤레인을 가린다.
        // 현재 바닥선 y 순서로 그려 앞(아래)의 펫이 뒤를 가린다 — 레인 간 이동(커피 방문) 중에도 자연스럽게.
        ForEach(sim.pets.sorted { $0.y < $1.y }) { pet in
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
        // y는 시뮬레이션 상태 — 커피 방문(레인 간 이동) 중에는 자기 레인을 벗어난다.
        let laneY = pet.y + 4
        let isMythicPet = Mythic.isMythic(pet.kind)
        let height = OfficeLayout.petHeight * (isMythicPet ? 1.5 : 1.0) * scale
        let centerX = pet.x * scale
        let centerY = (laneY * scale) - height / 2

        TimelineView(.animation(minimumInterval: 1.0 / 8)) { ctx in
            // 액션은 FSM이 결정 (walk/sit/scan/special) — 프레임 없는 액션은 sit으로 폴백.
            let preferred = PetSprite.frames(for: pet.kind, action: pet.displayAction)
            let frames = preferred.isEmpty ? PetSprite.frames(for: pet.kind, action: .sit) : preferred
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
                // 히트 영역 — 펫 몸통 크기의 투명 rect에만 툴팁/탭/popover를 건다.
                // TimelineView 전체에 걸면 씬 전체가 마지막 펫의 탭 타깃이 되는 버그
                // (spotMarker의 .position 순서 버그와 동일 계열).
                Color.clear
                    .frame(width: max(20, height), height: height)
                    .contentShape(Rectangle())
                    .help("\(pet.id) · 이번 달 \(pet.monthlyVP) VP · \(pet.spot.name)")
                    .onTapGesture { onTap() }
                    .popover(isPresented: $showPopover, arrowEdge: .top) { popoverContent }
                    .position(x: centerX, y: centerY)
            }
        }
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
                equippedEffects: Set((profile.equippedEffects ?? []).compactMap { EffectKind(rawValue: $0) }),
                guildName: profile.guildName
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

// MARK: - 데코 카탈로그 시트 (꾸미기 모드 popover)

/// 데코 슬롯 클릭 시 카탈로그 — 카테고리별 아이템 목록 + 가격 + 잔액. 기부 모델이라
/// 구매 즉시 배치(교체 구매는 기존 아이템 소멸 — 기획 §2). 제거는 기부자/길드장만.
@MainActor
private struct DecorCatalogSheet: View {
    let slot: OfficeLayout.DecorSlot
    let placed: RankingAPI.GuildFurnitureItem?
    let canRemove: Bool
    let onBuy: (OfficeLayout.DecorItem) -> Void
    let onRemove: () -> Void
    @ObservedObject var settings = Settings.shared

    private var items: [OfficeLayout.DecorItem] {
        OfficeLayout.decorCatalog.filter { $0.category == slot.category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot.category == .wall ? "벽 장식" : "바닥 소품")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("🪙 \(settings.coins)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppColors.gold)
            }
            if let placed, let current = OfficeLayout.decorItem(kind: placed.itemKind) {
                HStack(spacing: 6) {
                    Text("현재: \(current.name)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let donor = placed.donorNickname {
                        Text("· \(donor) 기부").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if canRemove {
                        Button("제거", role: .destructive) { onRemove() }
                            .font(.system(size: 10)).controlSize(.small)
                    }
                }
                Divider()
            }
            ForEach(items) { item in
                let affordable = settings.coins >= item.price
                Button {
                    onBuy(item)
                } label: {
                    HStack(spacing: 8) {
                        if let img = OfficeLayout.officeImage(item.imageName) {
                            Image(nsImage: img)
                                .interpolation(.none)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        }
                        Text(item.name).font(.system(size: 11))
                        Spacer()
                        Text("🪙 \(item.price)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(affordable ? AppColors.gold : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!affordable)
                .opacity(affordable ? 1 : 0.5)
            }
            Text("구매한 장식은 길드에 기부됩니다 (교체 시 기존 장식 소멸)")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 230)
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
        func member(_ nick: String, kind: PetKind, variant: Int = 0,
                    vp: Int, top: Bool, me: Bool = false,
                    effects: [String] = []) -> RankingAPI.GuildMember {
            var card = TrainerCard.default
            card.avatar = PetSelection(kind: kind, variant: variant)
            let profile = ProfileState(
                card: card, trainerID: "DEMO", stats: TrainerStats.compute(from: Settings.shared),
                clearedBadges: [], completedCollections: [], backup: nil,
                equippedEffects: effects, integrityViolation: false,
                guildName: "데드락클럽")
            return RankingAPI.GuildMember(
                nickname: nick, monthlyVP: vp, isTopContributor: top, officeSlot: nil,
                isLeader: me, isMe: me, joinedAt: Date(), githubLogin: nil,
                profileJson: profile, deviceId: nil)
        }
        let members = [
            member("dowoon", kind: .fox, variant: 1, vp: 3120, top: true, me: true),
            member("kimcoder", kind: .warrior, vp: 2400, top: true, effects: ["glow"]),
            member("vibewolf", kind: .wolf, variant: 4, vp: 1800, top: true),
            member("nightowl", kind: .whale, vp: 700, top: true),
            member("lurker42", kind: .ninjaFrog, vp: 400, top: true),
            member("ghostdev", kind: .slime, vp: 0, top: false),
            member("newbie", kind: .pawn, vp: 120, top: false),
            member("자동배치멤버", kind: .fox, vp: 50, top: false),
        ]
        // `=visit`이면 확률 이벤트(커피 방문·Mythic 특수 모션)를 가속 — 스크린샷 검증용.
        if ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "visit" {
            OfficeSimulation.debugAccelerate = true
        }
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
        // 캡처 자동화 편의 — `AIUSAGE_OFFICE_DEMO=rearrange`면 재배치 모드,
        // `=swapped`면 스왑 배치, `=decor`면 꾸미기 모드 + 데코/테마 프리필로 시작.
        @State private var rearrange =
            ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "rearrange"
        @State private var decorate =
            ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "decor"
        /// 재배치(드래그)를 로컬에서 즉시 반영 — 서버 없이 동작 확인.
        @State private var furnitureLayout: String = {
            if ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "swapped" {
                // 소파를 창가로, 화분을 가운데로 옮긴 커스텀 배치 샘플.
                var p = OfficeLayout.defaultPlacements
                p[8].x = 35;  p[8].lane = 0
                p[0].x = 60;  p[0].lane = 2
                p[10].x = 115; p[10].lane = 1
                return OfficeLayout.serializePlacements(p)
            }
            return ""
        }()
        /// 데코 구매/제거를 로컬에서 즉시 반영 — 서버 없이 기부 흐름 확인.
        @State private var decorItems: [RankingAPI.GuildFurnitureItem] = {
            guard ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "decor" else { return [] }
            return [
                RankingAPI.GuildFurnitureItem(slotId: 0, itemKind: "SMALL_PAINTING", donorNickname: "kimcoder"),
                RankingAPI.GuildFurnitureItem(slotId: 3, itemKind: "HANGING_PLANT", donorNickname: "vibewolf"),
                RankingAPI.GuildFurnitureItem(slotId: 6, itemKind: "CACTUS", donorNickname: "dowoon"),
                RankingAPI.GuildFurnitureItem(slotId: 8, itemKind: "COFFEE_TABLE", donorNickname: "nightowl"),
            ]
        }()

        private var isDecorDemo: Bool {
            ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "decor"
        }

        private var info: RankingAPI.GuildInfoResponse {
            let guild = RankingAPI.GuildInfo(
                id: "demo", name: "데드락클럽", inviteCode: "AB3F9K2M", isLeader: true,
                floorTheme: isDecorDemo ? 4 : 0, wallTheme: isDecorDemo ? 1 : 0,
                officeFurniture: furnitureLayout, createdAt: Date(),
                score: 8420, rank: 3, memberCount: members.count)
            return RankingAPI.GuildInfoResponse(guild: guild, members: members, furniture: decorItems)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                GuildOfficeView(
                    info: info,
                    rearrangeMode: $rearrange,
                    decorateMode: $decorate,
                    onSetFurniture: { serialized in
                        furnitureLayout = serialized
                        print("OFFICE_DEMO_FURNITURE=\(serialized)")
                        fflush(stdout)
                    },
                    onPlaceDecor: { slot, item in
                        decorItems.removeAll { $0.slotId == slot }
                        decorItems.append(RankingAPI.GuildFurnitureItem(
                            slotId: slot, itemKind: item.kind, donorNickname: "dowoon"))
                        print("OFFICE_DEMO_DECOR place slot=\(slot) kind=\(item.kind)")
                        fflush(stdout)
                    },
                    onRemoveDecor: { slot in
                        decorItems.removeAll { $0.slotId == slot }
                        print("OFFICE_DEMO_DECOR remove slot=\(slot)")
                        fflush(stdout)
                    }
                )
                HStack {
                    Toggle("가구 재배치", isOn: $rearrange).font(.system(size: 11))
                    Toggle("꾸미기", isOn: $decorate).font(.system(size: 11))
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
