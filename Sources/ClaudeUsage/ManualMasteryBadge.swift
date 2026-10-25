import SwiftUI

/// Display-only cache. All increments are performed by the server transaction, never by this store.
@MainActor
final class ManualMasteryStore: ObservableObject {
    static let shared = ManualMasteryStore()
    @Published private(set) var revision = 0
    func record(kind: PetKind, owner: String) -> ManualMasteryRecord? {
        guard !owner.isEmpty, let data = AppEnv.defaults.data(forKey: "manual.mastery.\(owner)"),
              let records = try? JSONDecoder().decode([String: ManualMasteryRecord].self, from: data) else { return nil }
        return records[kind.rawValue]
    }
    func replace(_ records: [String: ManualMasteryRecord], owner: String) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(records) else { return }
        AppEnv.defaults.set(data, forKey: "manual.mastery.\(owner)")
        revision += 1
    }
}

struct ManualMasteryBadge: View {
    let record: ManualMasteryRecord
    var compact = false
    private var color: Color { record.wins >= 100 ? .purple : record.wins >= 30 ? .orange : record.wins >= 10 ? .gray : .cyan }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: record.wins >= 100 ? "sparkles" : "medal.fill")
            Text(record.title).fontWeight(.semibold)
            if !compact { Text("\(record.wins)승").monospacedDigit() }
            if record.originalEmblem && record.alternateEmblem { Image(systemName: "sparkle").help("궁극기 A·B 쌍문양") }
            else if record.originalEmblem { Text("A") }
            else if record.alternateEmblem { Text("B") }
        }.font(.system(size: compact ? 8 : 10)).padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.65), lineWidth: 1))
            .accessibilityLabel("공식 레인보우 숙련 훈장, \(record.title), \(record.wins)승")
            .help(record.nextThreshold.map { "다음 훈장까지 \($0 - record.wins)승 · A \(record.originalWins)/5 · B \(record.alternateWins)/5" } ?? "마스터 달성 · A \(record.originalWins)/5 · B \(record.alternateWins)/5")
    }
}

struct OwnedManualMasteryBadge: View {
    let kind: PetKind
    @ObservedObject private var store = ManualMasteryStore.shared
    @ObservedObject private var settings = Settings.shared
    var body: some View {
        if let record = store.record(kind: kind, owner: settings.rankingDeviceID), record.wins > 0 {
            ManualMasteryBadge(record: record)
        }
    }
}
