import SwiftUI

/// 픽셀 사무실 아래의 작업대. 배치/보관/프리셋을 한 위치에서 관리한다.
@MainActor
struct OfficeStudioPanel: View {
    enum Tab: String, CaseIterable { case placed = "배치된 가구", storage = "보관함", presets = "프리셋" }
    enum Action {
        case store(String), restore(String), delete(String)
        case savePreset(String), overwritePreset(String), applyPreset(String), deletePreset(String)
        case undo, redo
    }
    let state: OfficeStudioState
    let canUndo: Bool
    let canRedo: Bool
    @Binding var tab: Tab
    let onAction: (Action) -> Void
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("가구 작업대", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Button { onAction(.undo) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!canUndo).help("가구 변경 되돌리기").accessibilityLabel("가구 변경 되돌리기")
                Button { onAction(.redo) } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!canRedo).help("가구 변경 다시 실행").accessibilityLabel("가구 변경 다시 실행")
            }
            .controlSize(.small)
            HStack {
                Text("배치 \(state.placedCount)/60")
                Text("보관 \(state.storedCount)")
                Spacer()
                Text("보유 \(state.items.count)/180")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            Picker("가구 관리", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if tab == .presets { presets }
            else { inventory(stored: tab == .storage) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func inventory(stored: Bool) -> some View {
        let items = state.items.filter { $0.stored == stored }
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: stored ? "archivebox" : "chair.lounge")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                Text(stored ? "보관한 가구가 없습니다" : "새롭게 꾸밀 준비가 됐습니다")
                    .font(.system(size: 11, weight: .medium))
                Text(stored ? "배치된 가구를 보관하면 언제든 무료로 다시 꺼낼 수 있습니다." : "보관함에서 가구를 꺼내거나 상점에서 골라보세요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        itemCard(item)
                    }
                }
            }
            .frame(height: items.count <= 3 ? 96 : items.count <= 6 ? 192 : 200)
            Text(stored ? "꺼낸 가구는 빈 공간에 놓입니다. 드래그해서 위치를 조정하세요." : "보관은 무료입니다. 영구 삭제는 가구 메뉴에서 선택할 수 있습니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func itemCard(_ item: OfficeStudioState.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                furnitureIcon(item.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(OfficeLayout.furnitureKind(id: item.kind)?.name ?? "가구")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if let text = item.text, !text.isEmpty {
                        Text(text).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Button(item.stored ? "꺼내기" : "보관") {
                    onAction(item.stored ? .restore(item.id) : .store(item.id))
                }
                .disabled(item.stored && state.placedCount >= OfficeLayout.furnitureMaxInstances)
                Spacer()
                Menu {
                    Button("영구 삭제…", role: .destructive) { onAction(.delete(item.id)) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("가구 메뉴")
            }
            .controlSize(.small).font(.system(size: 10))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func furnitureIcon(_ id: Int) -> some View {
        if let kind = OfficeLayout.furnitureKind(id: id), let imageName = kind.imageName,
           let image = OfficeLayout.officeImage(imageName) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .frame(width: 28, height: 32)
        } else {
            Image(systemName: id == 9 ? "photo.artframe" : "desktopcomputer")
                .font(.system(size: 20)).frame(width: 28, height: 32).foregroundStyle(.secondary)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("배치 이름 (예: 월요 카페)", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: presetName) { _, value in presetName = String(value.prefix(20)) }
                Button("현재 배치 저장") {
                    onAction(.savePreset(presetName))
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.presets.count >= OfficeStudioState.presetLimit)
            }
            .controlSize(.small).font(.system(size: 11))
            if state.presets.isEmpty {
                Text("마음에 드는 배치를 최대 5개 저장해 두세요. 보유 가구만 사용하며 추가 코인은 들지 않습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(state.presets) { preset in
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.square").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.system(size: 11, weight: .medium))
                        Text("가구 \(preset.positions.count)개").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("불러오기") { onAction(.applyPreset(preset.id)) }
                    Menu {
                        Button("현재 배치로 덮어쓰기…") { onAction(.overwritePreset(preset.id)) }
                        Button("프리셋 삭제…", role: .destructive) { onAction(.deletePreset(preset.id)) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("프리셋 메뉴")
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                .controlSize(.small).font(.system(size: 10))
            }
            Text("가구 위치만 저장합니다. 액자 문구와 벽·바닥 테마는 유지됩니다.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
