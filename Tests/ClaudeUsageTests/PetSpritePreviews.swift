import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 펫 스프라이트 육안 검수 시트.
///
/// 195종 × 액션별 strip을 하나씩 앱에서 띄워 보는 건 불가능하다. 시트 결함(셀 크기 어긋남,
/// 프레임 잘림, 빈 프레임, 좌우 반전 실수)은 자동 지표로 판정하면 오탐이 너무 많아서 —
/// 과거에 그렇게 시도했다가 접었다 — **렌더러와 같은 크롭으로 늘어놓고 눈으로 보는 것**이
/// 유일하게 작동하는 방법이다. 이 파일은 그 "늘어놓기"를 자동화한다.
///
/// 배경은 체커보드다. 단색 배경에서는 "테두리가 잘려나갔다"와 "원래 투명하다"가 같아 보인다.
/// 확대는 nearest neighbor — 보간을 켜면 도트가 뭉개져서 정작 봐야 할 픽셀 경계가 사라진다.
///
///   bash scripts/render-previews.sh pet
@MainActor
final class PetSpritePreviews: SandboxedTestCase {

    /// 컬렉션(19개) 단위로 한 장씩. 한 시트에 195종을 다 넣으면 파일이 너무 커서 못 본다.
    /// 컬렉션 단위인 이유는 그게 배틀 타입·스킬 배정의 단위이기도 해서, 같은 시트에 있는 펫끼리
    /// 화풍이 튀는지도 함께 보이기 때문이다.
    func testRenderSpriteSheetsByCollection() throws {
        _ = try PreviewRenderer.requireOutputDir()

        for collection in PetCollection.allCases {
            let rows: [(label: String, images: [NSImage])] = collection.members.map { kind in
                // 렌더러가 실제로 쓰는 세 액션(.sit이 idle strip). suffix가 alias면 같은 strip이
                // 반복되는데, 그 반복 자체가 "이 종은 애니가 하나뿐"이라는 정보라 그대로 보여준다.
                let frames = [PetController.Action.sit, .walk, .run].flatMap {
                    PetSprite.frames(for: kind, action: $0)
                }
                let facing = kind.def.defaultFacingLeft ? "◀" : "▶"
                return ("\(kind.rawValue) \(facing)", frames)
            }
            guard !rows.isEmpty else { continue }

            let sheet = PreviewRenderer.contactSheet(rows: rows, cell: CGSize(width: 44, height: 44))
            try PreviewRenderer.writeImage(
                sheet,
                section: "펫 스프라이트",
                title: collection.rawValue,
                note: "\(collection.displayName) · idle→walk→run 순. ◀/▶는 defaultFacingLeft — "
                    + "그림이 보는 방향과 다르면 WalkingCat에서 거꾸로 걷는다.")
        }
    }

    /// facing 검수 — `defaultFacingLeft` 표기값으로 묶어서 본다.
    ///
    /// 위의 컬렉션별 시트에도 ◀/▶가 붙어 있지만 그것만으로는 새는 게 잡히지 않았다. 컬렉션 시트는
    /// 종마다 기호와 그림을 하나씩 대조해야 하고, 대량 추가 때 팩 기본값을 복붙한 실수는
    /// 그 대조를 195번 해야만 드러난다. 실제로 18종이 반대로 커밋된 채 남아 있었다
    /// (luizmelo-pets 고양이·개 12종 전부 + dino 3종 + percy·chiChiBird·giantRat).
    ///
    /// **같은 표기끼리 모아놓으면 대조가 필요 없다.** "전부 오른쪽을 봐야 하는 시트"에서
    /// 왼쪽을 보는 놈은 훑기만 해도 튄다. 새 펫을 추가하면 이 시트만 확인하면 된다.
    ///
    /// 정면 스프라이트는 반전해도 화면상 차이가 없어 어느 그룹에 있든 무해하다 — 옆모습만 본다.
    func testRenderFacingAudit() throws {
        _ = try PreviewRenderer.requireOutputDir()

        for facingLeft in [true, false] {
            let kinds = PetKind.allCases.filter { $0.def.defaultFacingLeft == facingLeft }
            let expected = facingLeft ? "◀ 왼쪽" : "▶ 오른쪽"
            // 한 장에 다 넣으면 세로로 길어져 훑기가 안 된다. 24종이 한 화면에 들어오는 상한.
            let chunkSize = 24
            let chunks = stride(from: 0, to: kinds.count, by: chunkSize).map {
                Array(kinds[$0..<min($0 + chunkSize, kinds.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                let rows: [(label: String, images: [NSImage])] = chunk.map { kind in
                    // idle 첫 프레임 + run 중간 프레임. 정지 컷 하나로는 방향이 애매한 종이
                    // 달리는 자세에서는 분명해진다(다리가 뻗는 쪽이 진행 방향).
                    let idle = PetSprite.frames(for: kind, action: .sit)
                    let run = PetSprite.frames(for: kind, action: .run)
                    var picked: [NSImage] = []
                    if let first = idle.first { picked.append(first) }
                    if !run.isEmpty { picked.append(run[run.count / 2]) }
                    return ("\(kind.rawValue)", picked)
                }
                let sheet = PreviewRenderer.contactSheet(
                    rows: rows, cell: CGSize(width: 56, height: 56), labelWidth: 170)
                try PreviewRenderer.writeImage(
                    sheet,
                    section: "펫 스프라이트",
                    title: "0-facing-\(facingLeft ? "left" : "right")-\(index + 1)",
                    note: "defaultFacingLeft=\(facingLeft) 표기 \(kinds.count)종 중 \(index + 1)번째 묶음. "
                        + "이 시트의 옆모습은 전부 \(expected)을 봐야 한다 — 반대로 보는 종이 있으면 "
                        + "그 종의 PetDefinition이 틀린 것이고, WalkingCat에서 뒤로 걷는다. "
                        + "정면 스프라이트는 반전해도 같아 보이므로 무시.")
            }
        }
    }

    /// Mythic 5종의 특수 모션. 일반 펫엔 없는 strip이라 셀 크기가 종마다 제각각이고,
    /// 실제로 프레임 수가 어긋난 채 커밋된 적이 있어 따로 크게 본다.
    func testRenderMythicSpecialMotions() throws {
        _ = try PreviewRenderer.requireOutputDir()

        let mythic = Gacha.pool[.mythic] ?? []
        var rows: [(label: String, images: [NSImage])] = []
        for kind in mythic {
            for action in [PetController.Action.special1, .special2] {
                let frames = PetSprite.frames(for: kind, action: action)
                guard !frames.isEmpty else { continue }
                rows.append(("\(kind.rawValue).\(action.rawValue) (\(frames.count)f)", frames))
            }
        }
        guard !rows.isEmpty else { return XCTFail("Mythic 특수 모션이 하나도 로드되지 않았다") }

        let sheet = PreviewRenderer.contactSheet(rows: rows, cell: CGSize(width: 64, height: 64), labelWidth: 200)
        try PreviewRenderer.writeImage(
            sheet, section: "펫 스프라이트", title: "0-mythic-특수모션",
            note: "프레임 수가 PetSpriteTests의 기대값과 맞는지, 셀 경계에서 잘리지 않았는지 본다.")
    }

    /// 변종(이로치 1~3 + 프레스티지 4)이 실제로 다르게 보이는지. 색만 살짝 도는 정도면
    /// 사용자는 차이를 못 느끼고, 너무 세면 원본 도트가 죽는다 — 눈으로만 판정 가능한 균형이다.
    ///
    /// 틴트가 `.hueRotation`이라 NSImage 합성으로는 재현되지 않는다. 앱과 같은 SwiftUI 경로로 그린다.
    func testRenderVariantTints() throws {
        _ = try PreviewRenderer.requireOutputDir()

        let samples: [PetKind] = [.fox, .slime, .warrior, .heroKnight, .cat1]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(samples, id: \.self) { kind in
                HStack(spacing: 12) {
                    Text(kind.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 110, alignment: .leading)
                    ForEach(0...PetOwnership.prestigeVariant, id: \.self) { variant in
                        VStack(spacing: 2) {
                            if let img = PetSprite.image(for: kind, action: .sit, frameIndex: 0) {
                                Image(nsImage: img)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 48, height: 48)
                                    .hueRotation(.degrees(WalkingCat.hueDegrees(for: variant)))
                            }
                            Text("v\(variant)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.13))

        try PreviewRenderer.render(
            sheet, section: "펫 스프라이트", title: "0-변종-틴트",
            note: "왼쪽부터 variant 0(기본) → 1~3(이로치) → 4(프레스티지). 인접 variant끼리 "
                + "구분되는지, 프레스티지가 과하지 않은지.")
    }
}
