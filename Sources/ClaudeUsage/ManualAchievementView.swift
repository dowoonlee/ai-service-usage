import SwiftUI

@MainActor
final class ManualAchievementStore: ObservableObject {
    static let shared = ManualAchievementStore()
    @Published private(set) var revision = 0
    func progress(owner: String) -> ManualAchievementProgress {
        guard !owner.isEmpty, let data = AppEnv.defaults.data(forKey: "manual.achievements.\(owner)"),
              let value = try? JSONDecoder().decode(ManualAchievementProgress.self, from: data) else { return ManualAchievementProgress() }
        return value
    }
    func replace(_ progress: ManualAchievementProgress, owner: String) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(progress) else { return }
        AppEnv.defaults.set(data, forKey: "manual.achievements.\(owner)")
        revision += 1
    }
}

struct ManualAchievementShelf: View {
    let progress: ManualAchievementProgress
    var preview: ManualAchievementProgress? = nil
    @State private var expanded: Bool
    init(progress: ManualAchievementProgress, preview: ManualAchievementProgress? = nil, expanded: Bool = false) {
        self.progress = progress; self.preview = preview; self._expanded = State(initialValue: expanded)
    }
    var body: some View {
        DisclosureGroup("전투 업적 · \(ManualAchievement.allCases.filter { progress.contains($0) }.count)/8", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("공식 업적은 보유 정보가 검증된 서버 경기에서 적립됩니다. 연습 달성은 칭호를 해금하지 않습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(ManualAchievement.allCases) { achievement in
                    let unlocked = progress.contains(achievement)
                    let practiced = preview?.contains(achievement) ?? false
                    let concealed = achievement.hidden && !unlocked && !practiced
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: unlocked ? "checkmark.seal.fill" : concealed ? "questionmark.diamond" : "seal")
                            .foregroundStyle(unlocked ? Color.orange : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(concealed ? "히든 업적" : achievement.name).font(.caption.bold())
                                Spacer()
                                if unlocked { Text("달성").foregroundStyle(.orange) }
                                else if practiced { Text("연습 달성").foregroundStyle(.secondary) }
                                else if !concealed { Text("\(progress.value(achievement))/\(achievement.target)").monospacedDigit() }
                            }.font(.caption2)
                            Text(concealed ? "특별한 전투에서 발견할 수 있습니다." : achievement.condition)
                                .font(.caption2).foregroundStyle(.secondary)
                            if !concealed {
                                Text("칭호 · \(achievement.rewardName)").font(.caption2).foregroundStyle(unlocked ? .orange : .secondary)
                                if let preview, !unlocked && preview.value(achievement) > 0 && !practiced {
                                    Text("연습 진행 \(preview.value(achievement))/\(achievement.target)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.padding(8).background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("칭호는 리포트에서 장착할 수 있습니다. 항복·만료·대여 경기는 적립되지 않습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }
}

struct OwnedManualAchievementShelf: View {
    var preview: ManualAchievementProgress?
    @ObservedObject private var store = ManualAchievementStore.shared
    @ObservedObject private var settings = Settings.shared
    var body: some View {
        ManualAchievementShelf(progress: store.progress(owner: settings.rankingDeviceID), preview: preview)
    }
}
