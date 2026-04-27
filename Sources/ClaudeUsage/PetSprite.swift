import AppKit
import SwiftUI

// Tiny Creatures (CC0, Clint Bellanger)에서 잘라낸 16x16 펫 스프라이트.
// PetKind에 (col, row)를 매핑하고 sheet를 한 번 로드해서 캐시.
// 시트 자체는 단일 프레임이라 "걷기"는 PetController + bob/squash로 페이크.

enum PetKind: String, CaseIterable, Identifiable, Codable {
    case cat
    case dog
    case chicken
    case sheep
    case bear
    case squirrel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cat:      return "고양이"
        case .dog:      return "강아지"
        case .chicken:  return "닭"
        case .sheep:    return "양"
        case .bear:     return "곰"
        case .squirrel: return "다람쥐"
        }
    }

    /// (col, row) on tilemap_packed.png (10 cols × 18 rows, 16px tiles, 0-indexed).
    /// tile_NNNN = row * 10 + col + 1.
    var tile: (col: Int, row: Int) {
        switch self {
        case .cat:      return (6, 15)   // tile_0157
        case .dog:      return (6, 17)   // tile_0177
        case .chicken:  return (0, 15)   // tile_0151
        case .sheep:    return (3, 15)   // tile_0154
        case .bear:     return (1, 16)   // tile_0162
        case .squirrel: return (0, 14)   // tile_0141
        }
    }
}

@MainActor
enum PetSprite {
    private static var cache: [PetKind: NSImage] = [:]

    private static let sheet: CGImage? = {
        guard let url = Bundle.module.url(forResource: "tiny-creatures", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            DebugLog.log("PetSprite: tiny-creatures.png 로드 실패")
            return nil
        }
        return bitmap.cgImage
    }()

    static func image(for kind: PetKind) -> NSImage? {
        if let cached = cache[kind] { return cached }
        guard let sheet = sheet else { return nil }
        let (col, row) = kind.tile
        let rect = CGRect(x: col * 16, y: row * 16, width: 16, height: 16)
        guard let cropped = sheet.cropping(to: rect) else { return nil }
        let img = NSImage(cgImage: cropped, size: NSSize(width: 16, height: 16))
        cache[kind] = img
        return img
    }
}
