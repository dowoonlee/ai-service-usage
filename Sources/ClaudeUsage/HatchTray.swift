import SwiftUI

/// A hand-pixelled shell. The two halves move in whole pixels along the crack.
struct HatchEgg: View {
    let premium: Bool
    let step: Int
    let pixel: CGFloat

    private static let shell = [
        ".....oooo.....",
        "...oohhhhoo...",
        "..ohhlllmmoo..",
        "..ohlllllmmoo.",
        ".ohlllllllmmo.",
        ".ohlllalllmmo.",
        "ohlllaaalllmmo",
        "ohllllallllmmo",
        "ohllllllllmmmo",
        "omlllllllmmmoo",
        ".omllllmmmmoo.",
        ".oommmmmmmoo..",
        "...ooooooo...."
    ]
    private static let seam = [7, 7, 7, 8, 8, 7, 6, 6, 7, 8, 7, 7, 6, 6]

    var body: some View {
        Canvas { context, _ in
            let outline = Color(red: 0.10, green: 0.11, blue: 0.19)
            let shell = premium ? Color(red: 0.77, green: 0.56, blue: 0.78)
                                : Color(red: 0.75, green: 0.91, blue: 0.81)
            let colors: [Character: Color] = [
                "o": outline,
                "h": premium ? .yellow : .white,
                "l": shell,
                "m": premium ? Color(red: 0.46, green: 0.27, blue: 0.54)
                             : Color(red: 0.34, green: 0.63, blue: 0.63),
                "a": HatchTray.accent(premium)
            ]
            for (y, row) in Self.shell.enumerated() {
                for (x, mark) in row.enumerated() {
                    guard var color = colors[mark] else { continue }
                    let seam = Self.seam[x]
                    if mark == "a" && !premium { color = y == 6 ? .white : shell }
                    if step >= 1, y == seam { color = outline }
                    let rise = step >= 2 && y < seam ? 3 : 0
                    let rect = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y + 3 - rise) * pixel,
                                      width: pixel, height: pixel)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: 14 * pixel, height: 16 * pixel)
        .accessibilityHidden(true)
    }
}

struct HatchTray: View {
    let premium: Bool
    let results: [MultiPullResult]
    @Binding var step: Int
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowIsVisible) private var windowIsVisible

    static func finalStep(count: Int) -> Int { count + 2 }

    static func ink(_ premium: Bool) -> Color {
        premium ? Color(red: 0.25, green: 0.16, blue: 0.31) : Color(red: 0.10, green: 0.26, blue: 0.28)
    }

    static func accent(_ premium: Bool) -> Color {
        premium ? Color(red: 1, green: 0.81, blue: 0.42) : Color(red: 0.54, green: 0.89, blue: 0.79)
    }

    var body: some View {
        let final = Self.finalStep(count: results.count)
        let complete = step >= final
        let single = results.count == 1
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: single ? 1 : 5), spacing: 6) {
                ForEach(results.indices, id: \.self) { index in
                    slot(results[index], shellStep: max(0, step - index), single: single)
                }
            }
            .padding(8)
            .background(Self.ink(premium), in: RoundedRectangle(cornerRadius: 5))

            HStack {
                if complete {
                    let new = results.filter(\.isNew).count
                    Text("신규 \(new) · 중복 \(results.count - new)").font(.caption)
                }
                Spacer()
                Button(complete ? "확인" : "결과 바로 보기") {
                    if complete { dismiss() } else { step = final }
                }
                .controlSize(.small)
            }
        }
        .task(id: reduceMotion) {
            if reduceMotion { step = final }
            while step < final {
                do { try await Task.sleep(for: .milliseconds(step < 3 ? 300 : 110)) }
                catch { return }
                guard step < final else { return }
                step += 1
            }
        }
    }

    private func slot(_ result: MultiPullResult, shellStep: Int, single: Bool) -> some View {
        let revealed = shellStep >= 3
        let pull = result.pull
        let variant = pull.variantUnlocked ?? 0
        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    Rectangle().fill(Self.accent(premium)).frame(width: single ? 90 : 40, height: 2)
                    Rectangle().fill(Self.accent(premium).opacity(0.4)).frame(width: single ? 98 : 46, height: 3)
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: single ? 92 : 42, height: 3)
                }
                if revealed {
                    if single && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 0.16, paused: !windowIsVisible)) { context in
                            pet(pull, frame: Int(context.date.timeIntervalSinceReferenceDate / 0.16), height: 78)
                        }
                    } else {
                        pet(pull, frame: 0, height: single ? 78 : 42)
                    }
                } else {
                    HatchEgg(premium: premium, step: shellStep, pixel: single ? 4 : 2)
                        .padding(.bottom, 3)
                }
            }
            .frame(height: single ? 84 : 48, alignment: .bottom)
            Text(revealed ? PetMetaStore.shared.displayName(for: pull.kind) : " ")
                .font(single ? .headline : .caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
            Text(revealed ? pull.rarity.displayName : " ")
                .font(.caption2).foregroundStyle(Self.accent(premium))
            Text(revealed ? (variant > 0 ? "색상 \(variant) 해금" : result.isNew ? "신규" : "중복 ×\(result.count)") : " ")
                .font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.22))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func pet(_ pull: GachaPull, frame: Int, height: CGFloat) -> some View {
        if let image = PetSprite.image(for: pull.kind, action: .sit, frameIndex: frame) {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(height: height)
                .hueRotation(.degrees(WalkingCat.hueDegrees(for: pull.variantUnlocked ?? 0)))
                .padding(.bottom, 4)
        }
    }

}
