import AppKit
import SwiftUI

// 두 개의 sprite 출처를 함께 쓴다:
//   - Animated Wild Animals (CC0, ScratchIO): 동물 6종, sprite는 모두 좌향
//   - Pixel Adventure 1 (CC0, Pixel Frog):    캐릭터 4종, sprite는 모두 우향
// 둘 다 동작별 strip PNG (frame i → x: i*cellW, y: 0). PetController가
// (action, frameIndex)를 들고 있고, 여기서 잘린 프레임을 캐시.

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

    var displayName: String {
        switch self {
        case .fox:       return "여우"
        case .wolf:      return "늑대"
        case .bear:      return "곰"
        case .boar:      return "멧돼지"
        case .deer:      return "사슴"
        case .rabbit:    return "토끼"
        case .maskDude:  return "마스크 영웅"
        case .ninjaFrog: return "닌자 개구리"
        case .mushroom:  return "버섯"
        case .slime:     return "슬라임"
        }
    }

    var cellSize: (w: Int, h: Int) {
        switch self {
        case .fox:       return (64, 36)
        case .wolf:      return (64, 40)
        case .bear:      return (64, 33)
        case .boar:      return (64, 40)
        case .deer:      return (72, 52)
        case .rabbit:    return (32, 26)
        case .maskDude:  return (32, 32)
        case .ninjaFrog: return (32, 32)
        case .mushroom:  return (32, 32)
        case .slime:     return (44, 30)
        }
    }

    /// sprite가 기본적으로 좌측을 보고 있는지. 우측 이동 시 반전 여부 결정.
    /// Wild Animals 는 모두 좌향, Pixel Adventure 는 모두 우향.
    var defaultFacingLeft: Bool {
        switch self {
        case .fox, .wolf, .bear, .boar, .deer, .rabbit:
            return true
        case .maskDude, .ninjaFrog, .mushroom, .slime:
            return false
        }
    }

    /// 동작 → 파일 basename. 스프라이트 별로 가능한 strip이 달라서 alias 처리:
    ///   - Rabbit은 Walk 대신 Hop, Wolf는 Idle 대신 Howl
    ///   - Pixel Adventure 캐릭터들은 Walk strip 자체가 없어 Run으로 대체
    ///   - Slime은 Idle/Run 한 strip(IdleRun)으로 합쳐져 있음
    func resourceName(for action: PetController.Action) -> String {
        let prefix: String
        switch self {
        case .fox:       prefix = "Fox"
        case .wolf:      prefix = "Wolf"
        case .bear:      prefix = "Bear"
        case .boar:      prefix = "Boar"
        case .deer:      prefix = "Deer"
        case .rabbit:    prefix = "Rabbit"
        case .maskDude:  prefix = "MaskDude"
        case .ninjaFrog: prefix = "NinjaFrog"
        case .mushroom:  prefix = "Mushroom"
        case .slime:     prefix = "Slime"
        }
        // Slime은 모든 action이 한 파일.
        if self == .slime {
            return "\(prefix)_IdleRun"
        }
        switch action {
        case .walk:
            switch self {
            case .rabbit:    return "\(prefix)_Hop"
            case .maskDude, .ninjaFrog, .mushroom:
                return "\(prefix)_Run"
            default:         return "\(prefix)_Walk"
            }
        case .run:
            return "\(prefix)_Run"
        case .sit, .scan, .quote:
            return self == .wolf ? "\(prefix)_Howl" : "\(prefix)_Idle"
        }
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
