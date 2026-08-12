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
