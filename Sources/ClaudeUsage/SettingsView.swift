import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("표시") {
                HStack {
                    Text("창 투명도")
                    Slider(value: $settings.panelOpacity, in: 0.4...1.0)
                    Text("\(Int(settings.panelOpacity * 100))%")
                        .font(.system(size: 11)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("사용 페이스 예측 표시", isOn: $settings.showPace)
                Toggle("메뉴바에 % 표시", isOn: $settings.showMenuBar)
                Text("메뉴바 모드에서는 패널 close 시 종료 대신 숨김으로 동작.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("펫") {
                Toggle("Claude 차트에 펫 표시", isOn: $settings.petClaudeEnabled)
                if settings.ownedPets.isEmpty {
                    emptyPetsRow
                } else {
                    Picker("Claude 펫", selection: claudeSelectionBinding) {
                        ForEach(allOwnedSelections, id: \.self) { sel in
                            Text(selectionLabel(sel)).tag(sel)
                        }
                    }
                    .disabled(!settings.petClaudeEnabled)
                }
                Picker("Claude 테마", selection: $settings.themeClaudeOverride) {
                    Text("기본 (\(PetTheme.defaultFor(settings.petClaudeKind).displayName))")
                        .tag(PetTheme?.none)
                    ForEach(PetTheme.allCases) { t in
                        Text(t.displayName).tag(PetTheme?.some(t))
                    }
                }
                Toggle("Cursor 차트에 펫 표시", isOn: $settings.petCursorEnabled)
                if !settings.ownedPets.isEmpty {
                    Picker("Cursor 펫", selection: cursorSelectionBinding) {
                        ForEach(allOwnedSelections, id: \.self) { sel in
                            Text(selectionLabel(sel)).tag(sel)
                        }
                    }
                    .disabled(!settings.petCursorEnabled)
                }
                Picker("Cursor 테마", selection: $settings.themeCursorOverride) {
                    Text("기본 (\(PetTheme.defaultFor(settings.petCursorKind).displayName))")
                        .tag(PetTheme?.none)
                    ForEach(PetTheme.allCases) { t in
                        Text(t.displayName).tag(PetTheme?.some(t))
                    }
                }
                Text("사용량이 많아지면 펫이 신나고, 임계치에 가까워지면 불안해합니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("펫 반응")
                    Slider(value: $settings.bigDropThreshold, in: 0.10...0.80, step: 0.05)
                }
                Text("차트가 크게 움직일 때 펫이 얼마나 자주 반응할지.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("수집") {
                HStack(spacing: 10) {
                    CoinIcon(size: 16)
                    Text("\(settings.coins)").monospacedDigit()
                    Image(systemName: "ticket.fill")
                        .foregroundStyle(.blue)
                    Text("\(settings.gachaTickets)").monospacedDigit()
                    Spacer()
                    Button("열기") {
                        GachaWindowController.shared.present()
                    }
                }
                Text("뽑기를 돌려 펫을 모으세요. 사용량이 코인으로 적립됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("시작") {
                Toggle("로그인 시 자동 시작", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
            Section("알림") {
                Toggle("임계치 알림 사용", isOn: $settings.notifyEnabled)
                ThresholdEditor(settings: settings)
                    .disabled(!settings.notifyEnabled)
                Text("같은 주기 내에서는 임계치별로 한 번만 알림이 옵니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("정보") {
                CreditsView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
    }

    // MARK: - 펫 picker helpers (보유 펫 + variant 페어 단위 선택)

    private var allOwnedSelections: [PetSelection] {
        PetKind.allCases.flatMap { k -> [PetSelection] in
            guard let o = settings.ownedPets[k] else { return [] }
            return o.unlockedVariants.sorted().map { v in PetSelection(kind: k, variant: v) }
        }
    }

    private var claudeSelectionBinding: Binding<PetSelection> {
        Binding(
            get: { PetSelection(kind: self.settings.petClaudeKind, variant: self.settings.petClaudeVariant) },
            set: { sel in
                self.settings.petClaudeKind = sel.kind
                self.settings.petClaudeVariant = sel.variant
            }
        )
    }

    private var cursorSelectionBinding: Binding<PetSelection> {
        Binding(
            get: { PetSelection(kind: self.settings.petCursorKind, variant: self.settings.petCursorVariant) },
            set: { sel in
                self.settings.petCursorKind = sel.kind
                self.settings.petCursorVariant = sel.variant
            }
        )
    }

    private func selectionLabel(_ sel: PetSelection) -> String {
        if sel.variant == 0 { return sel.kind.displayName }
        return "\(sel.kind.displayName) \(String(repeating: "✨", count: sel.variant))"
    }

    private var emptyPetsRow: some View {
        HStack {
            Text("보유 펫 없음 — 가챠를 돌려 시작하세요")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("가챠 열기") {
                GachaWindowController.shared.present()
            }
        }
    }
}

private struct ThresholdEditor: View {
    @ObservedObject var settings: Settings
    @State private var newValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(settings.notifyThresholds, id: \.self) { t in
                HStack {
                    Text("\(t)%")
                        .font(.system(size: 12)).monospacedDigit()
                    Spacer()
                    Button {
                        settings.removeThreshold(t)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("새 임계치", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("추가") {
                    if let v = Int(newValue), v > 0 {
                        settings.addThreshold(v)
                        newValue = ""
                    }
                }
                .disabled((Int(newValue) ?? 0) <= 0)
            }
            .padding(.top, 4)
        }
    }
}

// CC-BY 4.0 attribution은 라이선스 의무 — UI에 노출 필수.
private struct CreditsView: View {
    private struct Pack: Identifiable {
        let id = UUID()
        let name: String
        let author: String
        let license: String
        let url: String
    }

    private let packs: [Pack] = [
        .init(name: "Animated Wild Animals", author: "ScratchIO",
              license: "CC0",
              url: "https://opengameart.org/content/animated-wild-animals"),
        .init(name: "Pixel Adventure 1", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pixel-adventure-1"),
        .init(name: "Pixel Adventure 2", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pixel-adventure-2"),
        .init(name: "Kings and Pigs", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/kings-and-pigs"),
        .init(name: "Pirate Bomb", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pirate-bomb"),
        .init(name: "Treasure Hunters", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/treasure-hunters"),
        .init(name: "0x72 DungeonTileset II", author: "0x72",
              license: "CC0",
              url: "https://0x72.itch.io/dungeontileset-ii"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("에셋 크레딧")
                .font(.system(size: 11, weight: .semibold))
            ForEach(packs) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 11))
                    Text("· \(p.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(p.license)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        if let u = URL(string: p.url) { NSWorkspace.shared.open(u) }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(p.url)
                }
            }
            Divider().padding(.vertical, 2)
            Text("자동 업데이트는 Sparkle (MIT 라이선스)을 사용합니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Pixel Frog 팩은 CC-BY 4.0 — 출처/저작자 표기 의무를 지킵니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "설정"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
