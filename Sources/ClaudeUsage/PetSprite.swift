import AppKit
import SwiftUI

// 두 개의 sprite 출처를 함께 쓴다:
//   - Animated Wild Animals (CC0, ScratchIO): 동물 6종, sprite는 모두 좌향
//   - Pixel Adventure 1 (CC0, Pixel Frog):    캐릭터 4종, sprite는 모두 우향
// 둘 다 동작별 strip PNG (frame i → x: i*cellW, y: 0). PetController가
// (action, frameIndex)를 들고 있고, 여기서 잘린 프레임을 캐시.

/// 한 펫 종(kind)의 모든 메타데이터를 한 자리에 모은 레코드.
/// PetKind 케이스를 추가할 때 `displayName/cellSize/defaultFacingLeft/resourceName`
/// switch를 따로 늘릴 필요 없이 `PetKind.def` 한 곳만 수정하면 된다.
struct PetDefinition {
    /// 파일 prefix (예: "Fox", "MaskDude"). action별 suffix를 붙여 PNG basename을 구성.
    let prefix: String
    /// UI에 표시할 한국어 이름.
    let displayName: String
    /// 단일 frame 셀 크기. 같은 animation strip은 cellW × frameCount × cellH.
    let cellSize: (w: Int, h: Int)
    /// sprite가 기본적으로 좌측을 보고 있는지. 진행 방향과 다르면 가로 반전.
    /// (Wild Animals=true, Pixel Adventure=false)
    let defaultFacingLeft: Bool
    /// 동작별 PNG suffix. 종에 따라 alias가 다르다:
    ///   - Rabbit walk = "Hop", Wolf idle = "Howl"
    ///   - Pixel Adventure (Mask Dude/Ninja Frog/Mushroom): walk strip이 없어 "Run"으로 통합
    ///   - Slime: 모든 action이 한 "IdleRun" strip 공유
    let walkSuffix: String
    let runSuffix: String
    let idleSuffix: String

    /// (action) → 해당 strip PNG의 basename.
    func resourceName(for action: PetController.Action) -> String {
        let suffix: String
        switch action {
        case .walk:                  suffix = walkSuffix
        case .run:                   suffix = runSuffix
        case .sit, .scan, .quote:    suffix = idleSuffix
        }
        return "\(prefix)_\(suffix)"
    }
}

enum PetKind: String, CaseIterable, Identifiable, Codable {
    // wild-animals
    case fox
    case wolf
    case bear
    case boar
    case deer
    case rabbit
    // pixel-adventure
    case maskDude
    case ninjaFrog
    case mushroom
    case slime

    var id: String { rawValue }

    var def: PetDefinition {
        switch self {
        case .fox:
            return PetDefinition(prefix: "Fox", displayName: "여우",
                                 cellSize: (64, 36), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle")
        case .wolf:
            return PetDefinition(prefix: "Wolf", displayName: "늑대",
                                 cellSize: (64, 40), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Howl")
        case .bear:
            return PetDefinition(prefix: "Bear", displayName: "곰",
                                 cellSize: (64, 33), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle")
        case .boar:
            return PetDefinition(prefix: "Boar", displayName: "멧돼지",
                                 cellSize: (64, 40), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle")
        case .deer:
            return PetDefinition(prefix: "Deer", displayName: "사슴",
                                 cellSize: (72, 52), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle")
        case .rabbit:
            return PetDefinition(prefix: "Rabbit", displayName: "토끼",
                                 cellSize: (32, 26), defaultFacingLeft: true,
                                 walkSuffix: "Hop", runSuffix: "Run", idleSuffix: "Idle")
        case .maskDude:
            return PetDefinition(prefix: "MaskDude", displayName: "마스크 영웅",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle")
        case .ninjaFrog:
            return PetDefinition(prefix: "NinjaFrog", displayName: "닌자 개구리",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle")
        case .mushroom:
            return PetDefinition(prefix: "Mushroom", displayName: "버섯",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle")
        case .slime:
            return PetDefinition(prefix: "Slime", displayName: "슬라임",
                                 cellSize: (44, 30), defaultFacingLeft: false,
                                 walkSuffix: "IdleRun", runSuffix: "IdleRun", idleSuffix: "IdleRun")
        }
    }

    var displayName: String { def.displayName }
    var cellSize: (w: Int, h: Int) { def.cellSize }
    var defaultFacingLeft: Bool { def.defaultFacingLeft }

    func resourceName(for action: PetController.Action) -> String {
        def.resourceName(for: action)
    }
}

@MainActor
enum PetSprite {
    private static var cache: [String: [NSImage]] = [:]

    /// SwiftPM 의 자동 생성 Bundle.module 은 .app/<name>.bundle 만 체크하지만
    /// 표준 .app 은 Contents/Resources/ 아래에 리소스가 들어감 → 둘 다 fallback.
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "ClaudeUsage_ClaudeUsage", withExtension: "bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return .module
    }()

    /// 동물+동작에 해당하는 strip을 잘라 frame 배열로 반환. 캐시됨.
    static func frames(for kind: PetKind, action: PetController.Action) -> [NSImage] {
        let key = "\(kind.rawValue)/\(action)"
        if let cached = cache[key] { return cached }

        let name = kind.resourceName(for: action)
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let sheet = bitmap.cgImage
        else {
            DebugLog.log("PetSprite: \(name).png 로드 실패")
            cache[key] = []
            return []
        }

        let (w, h) = kind.cellSize
        let frameCount = max(1, sheet.width / w)
        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let rect = CGRect(x: i * w, y: 0, width: w, height: h)
            if let cropped = sheet.cropping(to: rect) {
                frames.append(NSImage(cgImage: cropped, size: NSSize(width: w, height: h)))
            }
        }
        cache[key] = frames
        return frames
    }

    static func image(
        for kind: PetKind,
        action: PetController.Action,
        frameIndex: Int
    ) -> NSImage? {
        let f = frames(for: kind, action: action)
        guard !f.isEmpty else { return nil }
        return f[frameIndex % f.count]
    }
}
