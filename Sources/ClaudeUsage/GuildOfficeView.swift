import AppKit
import SwiftUI

/// 길드 사무실 씬 — 멤버 대표 펫들이 자기 스팟 주변을 오가는 공유 공간 (docs/plans/guild.md §5-1/5-2).
///
/// 렌더 순서는 전부 zIndex로 결정 (painter's algorithm): 배경(-3000) → 벽 장식(-2800) →
/// 벽 데코(-2500) → front 가구(baseline-1000, 펫이 항상 앞) → avoid 가구·펫(baseline y 그대로,
/// 아래쪽이 위를 가림) → behind 가구(baseline+1000, 펫을 가림) → 재배치 모드 가구(+3000,
/// 펫 위로 — 펫이 드래그를 가로채지 못하게 히트테스트도 차단) → 꾸미기 마커(5000).
///
/// 멤버 배치: 자동 랜덤 — `OfficeLayout.autoAssignments` 결정적 해시로 클라이언트에서 배정
/// (수동 자리 선택은 사용자 피드백으로 폐기. 서버 office_slot은 더 이상 읽지 않는다).
/// 재배치 모드(길드장): 가구를 **마우스 드래그**로 자유 이동 — 놓으면 가장 가까운 레인에 스냅
/// 후 서버 저장 (레포트 탭 악세서리 드래그와 동일한 감각. 스왑 클릭 방식은 사용자 피드백으로 폐기).
/// 상점(OfficeShopSheet): 가구(바닥/벽)·장식·테마를 카테고리 탭으로 통합 구매 —
/// 꾸미기 모드는 사용자 피드백으로 폐기, 장식은 빈 슬롯 자동 선택 + 미리보기로 단순화.
struct GuildOfficeView: View {
    let info: RankingAPI.GuildInfoResponse
    @Binding var rearrangeMode: Bool
    /// 테마 미리보기 (상점 테마 탭이 구동, 구매 확인 전) — nil이면 서버 값.
    @Binding var previewFloorTheme: Int?
    @Binding var previewWallTheme: Int?
    /// 가구 드래그 종료 시 — 직렬화된 전체 배치("setId:x:lane;…"). 호출 측이 서버 반영.
    let onSetFurniture: (String) -> Void
    /// 가구 구매 확정 (카탈로그 아이템, 새 인스턴스가 포함된 직렬화) — 호출 측이 코인 검증·서버 반영.
    let onBuyFurniture: (OfficeLayout.FurnitureKind, String) -> Void
    /// 데코 구매 (slot, item) — 호출 측이 코인 검증·서버 반영.
    let onPlaceDecor: (Int, OfficeLayout.DecorItem) -> Void
    let onRemoveDecor: (Int) -> Void
    /// 테마 미리보기 구매 확정 — 호출 측이 코인 검증·서버 반영 + 미리보기 해제.
    let onApplyTheme: () -> Void

    @StateObject private var sim = OfficeSimulation()
    @State private var popoverPetID: String?
    /// 드래그 중 작업 사본 — nil이면 서버 값 사용. 드롭 후 서버 값이 따라오면 자동 해제.
    @State private var draftPlacements: [OfficeLayout.FurniturePlacement]?
    /// 현재 드래그 중인 가구 인스턴스 uid (하이라이트용).
    @State private var draggingUid: Int?
    /// 데코 구매 확인 전 미리보기 — 씬에는 보이지만 아직 결제 안 됨 (구매/취소로 해소).
    @State private var previewDecor: (slot: Int, kind: String)?
    /// 가구 구매 popover 열림 — 컨트롤 행의 "가구 구매" 버튼이 재배치 진입과 함께 열 수
    /// 있도록 바인딩으로 노출 (진입점 발견성 피드백).
    @Binding var purchaseSheetOpen: Bool
    /// 가구 구매 확인 전 미리보기 인스턴스 — 반투명 렌더, 구매 확정 시 직렬화에 합류.
    @State private var pendingPurchase: OfficeLayout.FurniturePlacement?
    /// 액자 문구 편집 popover가 열린 인스턴스 uid (재배치 모드에서 액자 클릭).
    @State private var editingTextUid: Int?

    private var scene: CGSize { OfficeLayout.sceneSize }
    /// 서버 가구 배치 (검증 실패/빈 값은 기본 배치 폴백).
    private var serverPlacements: [OfficeLayout.FurniturePlacement] {
        OfficeLayout.sanitizedPlacements(info.guild.officeFurniture)
    }
    /// 시뮬레이션·직렬화에 쓰는 유효 배치 — 드래그 중이면 작업 사본.
    private var placements: [OfficeLayout.FurniturePlacement] {
        draftPlacements ?? serverPlacements
    }
    /// 렌더용 배치 — 구매 미리보기 인스턴스 포함 (결제 전이라 시뮬레이션에는 미반영).
    private var renderPlacements: [OfficeLayout.FurniturePlacement] {
        pendingPurchase.map { placements + [$0] } ?? placements
    }
    private var placedDecor: [RankingAPI.GuildFurnitureItem] { info.furniture }
    /// 렌더용 데코 — 미리보기 중이면 해당 슬롯을 미리보기 아이템으로 치환.
    /// 시뮬레이션(충돌)은 실제 배치(placedDecor) 기준 유지 — 결제 전 동선 변경 방지.
    private var effectiveDecor: [RankingAPI.GuildFurnitureItem] {
        guard let pv = previewDecor else { return placedDecor }
        return placedDecor.filter { $0.slotId != pv.slot }
            + [RankingAPI.GuildFurnitureItem(slotId: pv.slot, itemKind: pv.kind, donorNickname: nil)]
    }
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
                    .zIndex(-3000)
                furnitureLayer(scale: scale)
                decorLayer(scale: scale)
                petLayer(scale: scale)
                    .allowsHitTesting(!rearrangeMode)   // 재배치 중 펫이 가구 드래그를 가로채지 않게
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
        // 사무실 상점 (가구·장식·테마 통합) — 항목 선택 = 씬 미리보기, 구매 확정 시 결제.
        // 앵커는 재배치 모드에서만 버튼으로 보이고, 그 외에는 투명 앵커 (컨트롤 행 버튼이 연다).
        .overlay(alignment: .topTrailing) {
            Group {
                if rearrangeMode {
                    Button {
                        purchaseSheetOpen = true
                    } label: {
                        Label("상점", systemImage: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color(NSColor.windowBackgroundColor).opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .popover(isPresented: Binding(
                get: { purchaseSheetOpen },
                set: { open in
                    purchaseSheetOpen = open
                    if !open { clearShopPreviews() }   // 확인 없이 닫으면 미리보기 전부 원복
                }
            ), arrowEdge: .bottom) {
                OfficeShopSheet(
                    isLeader: info.guild.isLeader,
                    placedDecor: placedDecor,
                    currentFloorTheme: info.guild.floorTheme,
                    currentWallTheme: info.guild.wallTheme,
                    previewFloorTheme: $previewFloorTheme,
                    previewWallTheme: $previewWallTheme,
                    onPreviewFurniture: { kind in setPendingPurchase(kind) },
                    onBuyFurniture: { kind in commitPurchase(kind) },
                    onPreviewDecor: { selection in previewDecor = selection },
                    onBuyDecor: { slot, item in
                        previewDecor = nil
                        onPlaceDecor(slot, item)
                    },
                    onRemoveDecor: { slot in onRemoveDecor(slot) },
                    onApplyTheme: {
                        purchaseSheetOpen = false
                        onApplyTheme()
                    }
                )
            }
            .padding(6)
        }
        .onAppear { reconfigureSim() }
        .onDisappear { sim.stop() }
        .onChange(of: membersKey) { _ in reconfigureSim() }
        .onChange(of: rearrangeMode) { on in
            draftPlacements = nil
            draggingUid = nil
            pendingPurchase = nil
            editingTextUid = nil
            // 진입 시에는 유지 — 컨트롤 행 "가구 구매" 버튼이 재배치 진입과 동시에 연다.
            if !on { purchaseSheetOpen = false }
        }
        // 서버 값이 드래그 결과를 따라잡으면 작업 사본 해제 (refresh 후 재정합).
        .onChange(of: info.guild.officeFurniture ?? "") { _ in
            if draggingUid == nil { draftPlacements = nil }
        }
    }

    /// 상점 닫힘 시 미결제 미리보기 전부 원복 (가구·장식·테마).
    private func clearShopPreviews() {
        pendingPurchase = nil
        previewDecor = nil
        previewFloorTheme = nil
        previewWallTheme = nil
    }

    private func reconfigureSim() {
        sim.configure(members: info.members, assignments: assignments, placements: placements,
                      decor: placedDecor.map { (slotId: $0.slotId, kind: $0.itemKind) })
    }

    // MARK: - 가구 구매 (미리보기 → 확정)

    /// 카탈로그 선택 → 빈 지점에 미리보기 인스턴스 생성 (nil = 미리보기 해제).
    private func setPendingPurchase(_ kind: OfficeLayout.FurnitureKind?) {
        guard let kind else {
            pendingPurchase = nil
            return
        }
        guard placements.count < OfficeLayout.furnitureMaxInstances,
              let pos = freePlacementPosition(for: kind) else {
            pendingPurchase = nil
            return
        }
        let uid = (placements.map(\.uid).max() ?? -1) + 1
        pendingPurchase = OfficeLayout.FurniturePlacement(
            uid: uid, kind: kind.id, x: pos.x, lane: pos.lane, text: nil)
    }

    /// 구매 확정 — 미리보기 인스턴스를 배치에 합류시켜 즉시 렌더하고, 결제·서버 반영은
    /// 호출 측(onBuyFurniture)에 위임. 구매 후 드래그로 원하는 위치로 옮기면 된다.
    private func commitPurchase(_ kind: OfficeLayout.FurnitureKind) {
        guard let pending = pendingPurchase else { return }
        let updated = placements + [pending]
        draftPlacements = updated
        pendingPurchase = nil
        purchaseSheetOpen = false
        onBuyFurniture(kind, OfficeLayout.serializePlacements(updated))
    }

    /// 미리보기 초기 위치 — 벽 가구는 벽 밴드, 바닥 가구는 앞레인부터 겹치지 않는 x 스캔.
    private func freePlacementPosition(
        for kind: OfficeLayout.FurnitureKind
    ) -> (x: CGFloat, lane: Int)? {
        let lanes: [Int] = kind.mount == .wall ? [OfficeLayout.wallLane] : [2, 1, 0]
        for lane in lanes {
            var x = OfficeLayout.edgeMargin + kind.size.width / 2
            while x < OfficeLayout.sceneSize.width - OfficeLayout.edgeMargin {
                if !OfficeLayout.placementCollides(uid: -1, kind: kind.id, x: x, lane: lane,
                                                   others: placements) {
                    return (x, lane)
                }
                x += 10
            }
        }
        return nil
    }

    /// 액자 문구 저장 — 드래그와 같은 즉시 저장 경로 (draft 갱신 + set_furniture).
    private func applyFrameText(_ uid: Int, text: String) {
        var working = draftPlacements ?? serverPlacements
        guard let idx = working.firstIndex(where: { $0.uid == uid }) else { return }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(OfficeLayout.furnitureTextMax))
        working[idx].text = trimmed.isEmpty ? nil : trimmed
        draftPlacements = working
        onSetFurniture(OfficeLayout.serializePlacements(working))
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
        let floorTheme = previewFloorTheme ?? info.guild.floorTheme
        let wallTheme = previewWallTheme ?? info.guild.wallTheme
        if let bg = OfficeLayout.backgroundImage(floorTheme: floorTheme) {
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
        if wallTheme > 0, wallTheme < OfficeLayout.wallTints.count {
            OfficeLayout.wallTints[wallTheme]
                .opacity(0.18)
                .frame(width: scene.width * scale, height: OfficeLayout.wallBottom * scale)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 데코 (배치된 기부 아이템 — 항상 표시, 호버 시 기부자 명판)

    @ViewBuilder
    private func decorLayer(scale: CGFloat) -> some View {
        ForEach(effectiveDecor, id: \.slotId) { placed in
            if let slot = OfficeLayout.decorSlot(id: placed.slotId),
               let item = OfficeLayout.decorItem(kind: placed.itemKind) {
                let isPreview = previewDecor?.slot == placed.slotId
                itemView(imageName: item.imageName, drawKind: nil, size: item.size,
                         anchorX: slot.anchorX, baselineY: slot.baselineY, scale: scale)
                    .opacity(isPreview ? 0.75 : 1)   // 미리보기는 반투명 — 아직 결제 전임이 보이게
                    .help(placed.donorNickname.map { "\(item.name) — \($0) 기부" } ?? item.name)
                    .zIndex(decorZ(slot: slot, item: item))
            }
        }
    }

    /// 데코 zIndex — 벽은 배경 바로 위, 바닥은 통행 특성별 (furnitureZ와 동일 규칙).
    private func decorZ(slot: OfficeLayout.DecorSlot, item: OfficeLayout.DecorItem) -> Double {
        guard slot.category == .floor else { return -2500 }
        let baseline = Double(slot.baselineY)
        switch item.passing {
        case .front: return baseline - 1000
        case .avoid, .through: return baseline
        case .behind: return baseline + 1000
        }
    }

    // MARK: - 가구

    @ViewBuilder
    private func furnitureLayer(scale: CGFloat) -> some View {
        // 벽 장식 — 붙박이 (재배치 무관).
        ForEach(Array(OfficeLayout.wallDecor.enumerated()), id: \.offset) { _, decor in
            itemView(imageName: decor.imageName, drawKind: decor.drawKind, size: decor.size,
                     anchorX: decor.anchorX, baselineY: decor.baselineY, scale: scale)
                .zIndex(-2800)
        }
        // 가구 인스턴스 — 자유 배치 좌표 (+ 구매 미리보기). 앞뒤 관계는 전부 zIndex가 결정.
        ForEach(renderPlacements) { placement in
            furnitureView(placement, scale: scale)
                .zIndex(furnitureZ(placement))
        }
        // 데스크의 모니터 — 데스크 바로 위 z. 가장 가까운 자리 점유자가 working이면 ON 애니.
        ForEach(renderPlacements.filter {
            OfficeLayout.furnitureKind(id: $0.kind)?.hasPC == true
        }) { placement in
            pcView(for: placement, scale: scale)
                .zIndex(furnitureZ(placement) + 0.01)
        }
    }

    /// 가구 zIndex — 통행 특성이 앞뒤 통과 연출을 만든다: front는 펫(y=76..146)보다 항상
    /// 아래, avoid/through는 baseline y로 펫과 상호 가림, behind는 항상 위. 벽 가구는 배경
    /// 바로 위, 상판에 올려진 소품은 표면 가구(+PC)보다 살짝 위. 재배치 모드에서는 전부
    /// 펫 위(+3000)로 올려 드래그가 펫에 가로막히지 않게 한다 (드래그 중인 건 최상단).
    private func furnitureZ(_ placement: OfficeLayout.FurniturePlacement) -> Double {
        let onWall = placement.lane == OfficeLayout.wallLane
        let baseline = onWall ? Double(OfficeLayout.wallFurnitureBaselineY)
            : Double(OfficeLayout.lanes[min(max(placement.lane, 0), 2)])
        if rearrangeMode {
            return 3000 + baseline + (draggingUid == placement.uid ? 500 : 0)
        }
        if onWall { return -2500 }
        guard let kind = OfficeLayout.furnitureKind(id: placement.kind) else { return baseline }
        if OfficeLayout.mountedSurface(of: placement, in: renderPlacements) != nil {
            return baseline + 0.02   // 상판 위 소품 — 표면(baseline)·PC(+0.01)보다 위
        }
        switch kind.passing {
        case .front: return baseline - 1000
        case .avoid, .through: return baseline
        case .behind: return baseline + 1000
        }
    }

    /// 가구 1점 — 재배치 모드(길드장)에서는 드래그로 이동(벽 가구는 벽 밴드 안), 놓으면
    /// 스냅 후 서버 저장. 액자는 클릭으로 문구 편집. 구매 미리보기 인스턴스는 반투명 +
    /// 조작 불가 (구매 확정 후 이동).
    /// 제스처/하이라이트는 반드시 .position 앞에 (히트 영역 전체 확장 버그 방지 — spotMarker 참조).
    @ViewBuilder
    private func furnitureView(_ placement: OfficeLayout.FurniturePlacement, scale: CGFloat) -> some View {
        if let kind = OfficeLayout.furnitureKind(id: placement.kind) {
            let isDragging = draggingUid == placement.uid
            let isPending = pendingPurchase?.uid == placement.uid
            let body = Group {
                if kind.supportsText {
                    TextFrameView(text: placement.text ?? "")
                } else if let name = kind.imageName, let img = OfficeLayout.officeImage(name) {
                    Image(nsImage: img).interpolation(.none).resizable()
                } else if let draw = kind.drawKind {
                    CodeDrawnFurniture(kind: draw)
                }
            }
            .frame(width: kind.size.width * scale, height: kind.size.height * scale)
            .opacity(isPending ? 0.75 : 1)   // 구매 확인 전 미리보기
            .overlay {
                if rearrangeMode && !isPending {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: [3]))
                        .foregroundStyle(isDragging ? Color.orange : Color.accentColor)
                }
            }
            let baseline = OfficeLayout.baselineY(for: placement, in: renderPlacements)
            let positionX = placement.x * scale
            // artBottomInset — 아트 하단 투명 여백만큼 내려 가시 하단을 baseline에 정렬 ("떠 보임" 방지).
            let positionY = (baseline - kind.size.height / 2 + kind.artBottomInset) * scale
            if rearrangeMode && !isPending {
                // 탭(문구 편집)은 액자에만 — 다른 가구에 TapGesture가 붙어 드래그 인식을
                // 방해하지 않도록 조건부로 분기한다.
                if kind.supportsText {
                    body
                        .contentShape(Rectangle())
                        .onTapGesture { editingTextUid = placement.uid }
                        .popover(isPresented: Binding(
                            get: { editingTextUid == placement.uid },
                            set: { if !$0 { editingTextUid = nil } }
                        ), arrowEdge: .bottom) {
                            FrameTextEditor(initial: placement.text ?? "") { newText in
                                editingTextUid = nil
                                applyFrameText(placement.uid, text: newText)
                            }
                        }
                        .gesture(furnitureDrag(placement, scale: scale))
                        .position(x: positionX, y: positionY)
                } else {
                    body
                        .contentShape(Rectangle())
                        .gesture(furnitureDrag(placement, scale: scale))
                        .position(x: positionX, y: positionY)
                }
            } else {
                body.position(x: positionX, y: positionY)
            }
        }
    }

    /// 드래그 제스처 — 이동 중 작업 사본 갱신(펫 충돌 범위도 실시간 추종), 종료 시 서버 저장.
    /// 다른 가구와 겹치는 위치는 반영하지 않는다(장애물에 걸려 멈추는 감각) — 단 탁상 소품은
    /// 데스크류 위로 올라간다 (placementCollides의 canStack×isSurface 예외).
    private func furnitureDrag(_ placement: OfficeLayout.FurniturePlacement,
                               scale: CGFloat) -> some Gesture {
        DragGesture(coordinateSpace: .named("officeScene"))
            .onChanged { value in
                draggingUid = placement.uid
                var working = draftPlacements ?? serverPlacements
                guard let idx = working.firstIndex(where: { $0.uid == placement.uid }) else { return }
                let snapped = OfficeLayout.clampPlacement(kind: placement.kind,
                                                          x: value.location.x / scale,
                                                          laneY: value.location.y / scale)
                guard !OfficeLayout.placementCollides(uid: placement.uid, kind: placement.kind,
                                                      x: snapped.x, lane: snapped.lane,
                                                      others: working) else { return }
                working[idx].x = snapped.x
                working[idx].lane = snapped.lane
                draftPlacements = working
            }
            .onEnded { _ in
                draggingUid = nil
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
        let lane = min(max(placement.lane, 0), 2)
        let nearSpot = OfficeLayout.spots
            .filter { $0.lane == lane && abs($0.anchorX - placement.x) < 24 }
            .min { abs($0.anchorX - placement.x) < abs($1.anchorX - placement.x) }
        let assigned = assignments
        let working = nearSpot.map { spot in
            info.members.contains {
                assigned[$0.nickname] == spot.id && $0.isTopContributor && $0.monthlyVP > 0
            }
        } ?? false
        let baseline = OfficeLayout.pcBaselineY(deskBaselineY: OfficeLayout.lanes[lane])
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
        // 장식 전용 — 데스크보다 위에 그려지므로(z+0.01) 히트테스트를 차단하지 않으면
        // "데스크+PC"를 PC 부분으로 잡았을 때 드래그가 삼켜진다 (재배치 불가 피드백의 원인).
        .allowsHitTesting(false)
    }

    // MARK: - 펫

    @ViewBuilder
    private func petLayer(scale: CGFloat) -> some View {
        // zIndex = 발 y — 아래(앞)의 펫이 뒤를 가리고, avoid 가구(baseline z)와도
        // 자연스럽게 상호 가림 (가구 뒤를 스치면 가구가 발을 가린다).
        ForEach(sim.pets) { pet in
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
            .zIndex(Double(pet.y))
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

// MARK: - 사무실 상점 시트 (가구·장식·테마 통합 — 꾸미기 모드 폐기 후 단일 진입점)

/// 카테고리 탭: 바닥 가구 / 벽 설치 / 장식 / 테마(길드장). 어느 탭이든 항목 클릭 =
/// 씬 미리보기, 확인 바의 "구매"를 눌러야 결제. 닫기/취소는 미리보기 원복.
/// 가구·테마는 길드장 전용(서버 권한과 쌍), 장식은 멤버 누구나 기부 가능.
@MainActor
private struct OfficeShopSheet: View {
    enum Tab: Hashable { case floorFurniture, wallFurniture, decor, theme }

    let isLeader: Bool
    let placedDecor: [RankingAPI.GuildFurnitureItem]
    let currentFloorTheme: Int
    let currentWallTheme: Int
    @Binding var previewFloorTheme: Int?
    @Binding var previewWallTheme: Int?
    let onPreviewFurniture: (OfficeLayout.FurnitureKind?) -> Void
    let onBuyFurniture: (OfficeLayout.FurnitureKind) -> Void
    let onPreviewDecor: ((slot: Int, kind: String)?) -> Void
    let onBuyDecor: (Int, OfficeLayout.DecorItem) -> Void
    let onRemoveDecor: (Int) -> Void
    let onApplyTheme: () -> Void

    @ObservedObject var settings = Settings.shared
    @State private var tab: Tab
    @State private var pendingFurniture: OfficeLayout.FurnitureKind?
    @State private var pendingDecor: (slot: Int, item: OfficeLayout.DecorItem)?

    init(isLeader: Bool, placedDecor: [RankingAPI.GuildFurnitureItem],
         currentFloorTheme: Int, currentWallTheme: Int,
         previewFloorTheme: Binding<Int?>, previewWallTheme: Binding<Int?>,
         onPreviewFurniture: @escaping (OfficeLayout.FurnitureKind?) -> Void,
         onBuyFurniture: @escaping (OfficeLayout.FurnitureKind) -> Void,
         onPreviewDecor: @escaping ((slot: Int, kind: String)?) -> Void,
         onBuyDecor: @escaping (Int, OfficeLayout.DecorItem) -> Void,
         onRemoveDecor: @escaping (Int) -> Void,
         onApplyTheme: @escaping () -> Void) {
        self.isLeader = isLeader
        self.placedDecor = placedDecor
        self.currentFloorTheme = currentFloorTheme
        self.currentWallTheme = currentWallTheme
        _previewFloorTheme = previewFloorTheme
        _previewWallTheme = previewWallTheme
        self.onPreviewFurniture = onPreviewFurniture
        self.onBuyFurniture = onBuyFurniture
        self.onPreviewDecor = onPreviewDecor
        self.onBuyDecor = onBuyDecor
        self.onRemoveDecor = onRemoveDecor
        self.onApplyTheme = onApplyTheme
        // 가구/테마는 길드장 전용 — 멤버는 장식 탭에서 시작.
        _tab = State(initialValue: isLeader ? .floorFurniture : .decor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("사무실 상점").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("🪙 \(settings.coins)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AppColors.gold)
            }
            Picker("", selection: $tab) {
                if isLeader {
                    Text("바닥 가구").tag(Tab.floorFurniture)
                    Text("벽 설치").tag(Tab.wallFurniture)
                }
                Text("장식").tag(Tab.decor)
                if isLeader {
                    Text("테마").tag(Tab.theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onChange(of: tab) { _ in clearPending() }
            switch tab {
            case .floorFurniture: furnitureRows(mount: .floor)
            case .wallFurniture: furnitureRows(mount: .wall)
            case .decor: decorTab
            case .theme: themeTab
            }
            footer
        }
        .padding(12)
        .frame(width: 260)
    }

    /// 탭 전환 시 미결제 선택 원복 — 씬 미리보기도 함께 해제.
    private func clearPending() {
        if pendingFurniture != nil {
            pendingFurniture = nil
            onPreviewFurniture(nil)
        }
        if pendingDecor != nil {
            pendingDecor = nil
            onPreviewDecor(nil)
        }
    }

    // MARK: 가구 탭 (바닥/벽 — 길드장)

    @ViewBuilder
    private func furnitureRows(mount: OfficeLayout.FurnitureMount) -> some View {
        ForEach(OfficeLayout.furnitureCatalog.filter { $0.mount == mount }) { kind in
            let affordable = settings.coins >= kind.price
            let selected = pendingFurniture?.id == kind.id
            shopRow(selected: selected, dimmed: !affordable && !selected) {
                pendingFurniture = kind
                onPreviewFurniture(kind)
            } content: {
                catalogIcon(kind)
                Text(kind.name).font(.system(size: 11))
                if kind.supportsText {
                    badge("문구", color: .blue)
                }
                Spacer()
                priceTag(kind.price, affordable: affordable)
            }
        }
        if let pending = pendingFurniture {
            confirmBar(price: pending.price) {
                pendingFurniture = nil
                onPreviewFurniture(nil)
            } buy: {
                onBuyFurniture(pending)
            }
        }
    }

    // MARK: 장식 탭 (멤버 누구나 — 기부 모델, 빈 슬롯 자동 선택)

    @ViewBuilder
    private var decorTab: some View {
        ForEach(OfficeLayout.decorCatalog) { item in
            let freeSlot = firstFreeSlot(category: item.category)
            let affordable = settings.coins >= item.price
            let selected = pendingDecor?.item.kind == item.kind
            shopRow(selected: selected,
                    dimmed: (freeSlot == nil || !affordable) && !selected) {
                guard let slot = freeSlot else { return }
                pendingDecor = (slot: slot, item: item)
                onPreviewDecor((slot: slot, kind: item.kind))
            } content: {
                if let img = OfficeLayout.officeImage(item.imageName) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                }
                Text(item.name).font(.system(size: 11))
                badge(item.category == .wall ? "벽" : "바닥",
                      color: item.category == .wall ? .pink : .orange)
                Spacer()
                if freeSlot == nil {
                    Text("자리 없음").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    priceTag(item.price, affordable: affordable)
                }
            }
        }
        if let pending = pendingDecor {
            confirmBar(price: pending.item.price) {
                pendingDecor = nil
                onPreviewDecor(nil)
            } buy: {
                let slot = pending.slot
                let item = pending.item
                pendingDecor = nil
                onBuyDecor(slot, item)
            }
        }
        // 배치된 장식 관리 — 제거는 기부자 본인 또는 길드장.
        if !placedDecor.isEmpty {
            Divider()
            Text("배치된 장식").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(placedDecor, id: \.slotId) { placed in
                if let item = OfficeLayout.decorItem(kind: placed.itemKind) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 10))
                        if let donor = placed.donorNickname {
                            Text("· \(donor) 기부").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isLeader || placed.donorNickname == Settings.shared.rankingNickname {
                            Button("제거", role: .destructive) { onRemoveDecor(placed.slotId) }
                                .font(.system(size: 9)).controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    /// 카테고리(벽/바닥)에서 비어 있는 첫 데코 슬롯 — 없으면 nil (행 비활성).
    private func firstFreeSlot(category: OfficeLayout.DecorCategory) -> Int? {
        let occupied = Set(placedDecor.map(\.slotId))
        return OfficeLayout.decorSlots
            .first { $0.category == category && !occupied.contains($0.id) }?.id
    }

    // MARK: 테마 탭 (길드장 — 바닥재/벽지, 회당 themePrice)

    @ViewBuilder
    private var themeTab: some View {
        let effFloor = previewFloorTheme ?? currentFloorTheme
        let effWall = previewWallTheme ?? currentWallTheme
        Text("바닥재").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        HStack(spacing: 6) {
            ForEach(0..<OfficeLayout.floorThemeCount, id: \.self) { i in
                Button {
                    previewFloorTheme = (i == currentFloorTheme) ? nil : i
                } label: {
                    Group {
                        if let img = OfficeLayout.officeImage("floor_\(i)") {
                            Image(nsImage: img).interpolation(.none).resizable()
                        } else {
                            Color.gray
                        }
                    }
                    .frame(width: 18, height: 18)
                    .overlay(Rectangle().stroke(
                        effFloor == i ? Color.accentColor : Color.gray.opacity(0.4),
                        lineWidth: effFloor == i ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help("바닥재 \(i + 1) 미리보기")
            }
        }
        Text("벽지").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        HStack(spacing: 6) {
            ForEach(0..<OfficeLayout.wallTints.count, id: \.self) { i in
                Button {
                    previewWallTheme = (i == currentWallTheme) ? nil : i
                } label: {
                    Circle()
                        .fill(i == 0 ? Color(NSColor.windowBackgroundColor) : OfficeLayout.wallTints[i])
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(
                            effWall == i ? Color.accentColor : Color.gray.opacity(0.4),
                            lineWidth: effWall == i ? 2 : 0.5))
                }
                .buttonStyle(.plain)
                .help(i == 0 ? "기본 벽지 미리보기" : "벽지 틴트 \(i) 미리보기")
            }
        }
        let purchaseCount = (previewFloorTheme != nil ? 1 : 0) + (previewWallTheme != nil ? 1 : 0)
        if purchaseCount > 0 {
            confirmBar(price: OfficeLayout.themePrice * purchaseCount) {
                previewFloorTheme = nil
                previewWallTheme = nil
            } buy: {
                onApplyTheme()
            }
        } else {
            Text("스와치를 누르면 씬에 미리보기가 적용됩니다 (항목당 🪙\(OfficeLayout.themePrice))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 공통 조각

    private func shopRow(selected: Bool, dimmed: Bool, action: @escaping () -> Void,
                         @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .contentShape(Rectangle())
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.6 : 1)
    }

    private func confirmBar(price: Int, cancel: @escaping () -> Void,
                            buy: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text("미리보기 중").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("취소", action: cancel)
                    .font(.system(size: 11)).controlSize(.small)
                Button("🪙 \(price) 구매", action: buy)
                    .font(.system(size: 11)).controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(settings.coins < price)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
    }

    private func priceTag(_ price: Int, affordable: Bool) -> some View {
        Text("🪙 \(price)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(affordable ? AppColors.gold : .secondary)
    }

    private var footer: some View {
        Text(tab == .decor
             ? "구매한 장식은 길드에 기부됩니다 (제거는 기부자/길드장)"
             : "구매한 가구는 길드 소유 — 재배치 모드에서 드래그로 이동 (벽 설치는 벽 안에서만)")
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func catalogIcon(_ kind: OfficeLayout.FurnitureKind) -> some View {
        Group {
            if kind.supportsText {
                TextFrameView(text: "···")
            } else if let name = kind.imageName, let img = OfficeLayout.officeImage(name) {
                Image(nsImage: img).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
            } else if let draw = kind.drawKind {
                CodeDrawnFurniture(kind: draw)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - 액자 (문구 가구 — 사용자 요청 §6)

/// 코드 드로잉 액자 + 사용자 문구 (≤10자). 문구가 없으면 "···" 플레이스홀더.
struct TextFrameView: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.45, green: 0.32, blue: 0.20))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.93, green: 0.89, blue: 0.80))
                    .padding(geo.size.width * 0.07)
                Text(text.isEmpty ? "···" : text)
                    .font(.system(size: max(5, geo.size.height * 0.30), weight: .medium))
                    .minimumScaleFactor(0.4)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.30, green: 0.25, blue: 0.20))
                    .padding(geo.size.width * 0.12)
            }
        }
    }
}

/// 액자 문구 편집 popover (재배치 모드에서 액자 클릭 — 길드장 전용 경로).
@MainActor
private struct FrameTextEditor: View {
    @State private var text: String
    let onSave: (String) -> Void

    init(initial: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("액자 문구 (최대 \(OfficeLayout.furnitureTextMax)자)")
                .font(.system(size: 11, weight: .semibold))
            TextField("문구 입력", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 170)
                .onChange(of: text) { t in
                    if t.count > OfficeLayout.furnitureTextMax {
                        text = String(t.prefix(OfficeLayout.furnitureTextMax))
                    }
                }
                .onSubmit { onSave(text) }
            HStack {
                Text("\(text.count)/\(OfficeLayout.furnitureTextMax)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button("저장") { onSave(text) }
                    .font(.system(size: 11)).controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
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
        // `=swapped`면 커스텀 배치, `=decor`면 데코/테마 프리필로 시작.
        @State private var rearrange =
            ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "rearrange"
        @State private var purchaseOpen = false
        @State private var previewFloor: Int?
        @State private var previewWall: Int?
        /// 재배치(드래그)·구매를 로컬에서 즉시 반영 — 서버 없이 동작 확인.
        @State private var furnitureLayout: String = {
            if ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] == "swapped" {
                // 구매 가구 포함 샘플 — 소파/화분/커피머신(데스크 위 마운트)/문구 액자.
                var p = OfficeLayout.defaultPlacements
                p.append(OfficeLayout.FurniturePlacement(uid: 5, kind: 4, x: 60, lane: 2, text: nil))
                p.append(OfficeLayout.FurniturePlacement(uid: 6, kind: 6, x: 115, lane: 1, text: nil))
                p.append(OfficeLayout.FurniturePlacement(uid: 7, kind: 3, x: 110, lane: 0, text: nil))
                p.append(OfficeLayout.FurniturePlacement(uid: 8, kind: 9, x: 140,
                                                         lane: OfficeLayout.wallLane, text: "정신차려"))
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
                    previewFloorTheme: $previewFloor,
                    previewWallTheme: $previewWall,
                    onSetFurniture: { serialized in
                        furnitureLayout = serialized
                        print("OFFICE_DEMO_FURNITURE=\(serialized)")
                        fflush(stdout)
                    },
                    onBuyFurniture: { kind, serialized in
                        furnitureLayout = serialized
                        print("OFFICE_DEMO_BUY kind=\(kind.id) \(kind.name)")
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
                    },
                    onApplyTheme: {
                        print("OFFICE_DEMO_THEME floor=\(previewFloor.map(String.init) ?? "-") wall=\(previewWall.map(String.init) ?? "-")")
                        fflush(stdout)
                        previewFloor = nil
                        previewWall = nil
                    },
                    purchaseSheetOpen: $purchaseOpen
                )
                HStack {
                    Toggle("가구 재배치", isOn: $rearrange).font(.system(size: 11))
                    Toggle("상점", isOn: $purchaseOpen).font(.system(size: 11))
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
