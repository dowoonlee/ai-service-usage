import SwiftUI

struct TrainerMenu: View {
    typealias Tab = GachaView.Tab
    let selected: Tab
    let sidebar: Bool
    let status: (Tab) -> String?
    let open: (Tab) -> Void
    @ObservedObject private var settings = Settings.shared
    @Environment(\.colorScheme) private var scheme

    private var paper: Color {
        scheme == .dark ? Color(red: 0.115, green: 0.12, blue: 0.15)
                        : Color(red: 0.96, green: 0.955, blue: 0.94)
    }
    private var surface: Color {
        scheme == .dark ? Color(red: 0.155, green: 0.16, blue: 0.2) : .white
    }

    var body: some View {
        ScrollView {
            if sidebar {
                VStack(alignment: .leading, spacing: 14) {
                    Button { open(.home) } label: {
                        Label("트레이너 메뉴", systemImage: "square.grid.2x2").font(.headline)
                    }.buttonStyle(.plain)
                    Divider()
                    ForEach(Tab.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 1) {
                            groupLabel(group.title, icon: group.icon)
                            ForEach(group.tabs) { row($0) }
                        }
                    }
                }.padding(12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    camp
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(Tab.groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                groupLabel(group.title, icon: group.icon).padding(.vertical, 3)
                                Divider().padding(.horizontal, 6)
                                ForEach(group.tabs) { row($0) }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(surface, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
        .background(paper)
    }

    private func groupLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: sidebar ? 10 : 12, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.mint : Color(red: 0.16, green: 0.40, blue: 0.36))
            Text(label).font(sidebar ? .caption.bold() : .headline)
        }
        .padding(.leading, 6)
    }

    private func row(_ destination: Tab) -> some View {
        let detail = status(destination)
        return Button { open(destination) } label: {
            HStack(spacing: 4) {
                Text(destination.rawValue).font(.system(size: sidebar ? 12 : 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 1)
                if !sidebar {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7).frame(minHeight: sidebar ? 23 : 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(TrainerMenuRowStyle(selected: selected == destination))
    }

    private var camp: some View {
        ZStack(alignment: .leading) {
            CampHorizon()
            HStack(alignment: .bottom, spacing: 0) {
                Spacer()
                scenery("deco_pine", height: 56)
                scenery("building_tent", height: 78)
                if let sprite = PetSprite.image(for: settings.trainerCard.avatar.kind, action: .sit, frameIndex: 0) {
                    Image(nsImage: sprite).resizable().interpolation(.none).scaledToFit()
                        .frame(width: 45, height: 45)
                        .hueRotation(.degrees(WalkingCat.hueDegrees(for: settings.trainerCard.avatar.variant)))
                }
                scenery("deco_pine", height: 74)
            }
            .padding(.trailing, 10).padding(.bottom, 5)
            .frame(maxHeight: .infinity, alignment: .bottom).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("트레이너 메뉴").font(.system(size: 25, weight: .bold))
                Text("보유 펫 \(settings.ownedPets.count)종").font(.system(size: 12, weight: .medium))
            }.foregroundStyle(.white).padding(.leading, 20)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func scenery(_ name: String, height: CGFloat) -> some View {
        if let image = PetSprite.image(named: name) {
            Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                .frame(width: height * image.size.width / image.size.height, height: height)
        }
    }
}

private struct TrainerMenuRowStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }
    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovered = false
        private var background: Color {
            if configuration.isPressed { return .accentColor.opacity(0.25) }
            if selected { return .accentColor.opacity(0.17) }
            return hovered ? .primary.opacity(0.07) : .clear
        }
        var body: some View {
            configuration.label.background(background, in: RoundedRectangle(cornerRadius: 5))
                .onHover { hovered = $0 }
        }
    }
}

/// A stepped dusk skyline behind the app's original pixel sprites.
private struct CampHorizon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.27),
                                  Color(red: 0.36, green: 0.32, blue: 0.48),
                                  Color(red: 0.83, green: 0.53, blue: 0.46)]),
                startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
            for index in 0..<16 {
                let x = CGFloat((index * 37 + 17) % 101) * w / 101
                let y = CGFloat((index * 13 + 7) % 40)
                ctx.fill(Path(CGRect(x: floor(x), y: y, width: 2, height: 2)), with: .color(.white.opacity(0.65)))
            }
            let moon = CGPoint(x: floor(w * 0.66), y: 14)
            for (i, width) in [10, 16, 20, 20, 20, 16, 10].enumerated() {
                let rect = CGRect(x: moon.x - CGFloat(width)/2, y: moon.y + CGFloat(i*3), width: CGFloat(width), height: 3)
                ctx.fill(Path(rect), with: .color(Color(red: 1, green: 0.83, blue: 0.62)))
            }
            for layer in 0..<2 {
                let color = layer == 0 ? Color(red: 0.33, green: 0.32, blue: 0.44)
                                       : Color(red: 0.17, green: 0.25, blue: 0.31)
                for x in stride(from: 0, to: Int(w) + 4, by: 4) {
                    let wave = sin(Double(x)/57 + Double(layer)*2) + 0.45*cos(Double(x)/19)
                    let y = floor((h * (layer == 0 ? 0.62 : 0.83) + wave * 9)/3)*3
                    ctx.fill(Path(CGRect(x: CGFloat(x), y: y, width: 4, height: h-y)), with: .color(color))
                }
            }
        }.accessibilityHidden(true)
    }
}
