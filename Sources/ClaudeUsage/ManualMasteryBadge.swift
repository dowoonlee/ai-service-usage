import SwiftUI

/// Display-only cache. All increments are performed by the server transaction, never by this store.
@MainActor
final class ManualMasteryStore: ObservableObject {
    static let shared = ManualMasteryStore()
    @Published private(set) var revision = 0
    func record(kind: PetKind, owner: String) -> ManualMasteryRecord? {
        records(owner: owner)[kind.rawValue]
    }
    func records(owner: String) -> [String: ManualMasteryRecord] {
        guard !owner.isEmpty, let data = AppEnv.defaults.data(forKey: "manual.mastery.\(owner)"),
              let records = try? JSONDecoder().decode([String: ManualMasteryRecord].self, from: data) else { return [:] }
        return records
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

struct ManualMasteryShelf: View {
    let practice: [String: ManualMasteryRecord]
    @ObservedObject private var store = ManualMasteryStore.shared
    @ObservedObject private var settings = Settings.shared
    var body: some View {
        let records = store.records(owner: settings.rankingDeviceID)
        let kinds = PetKind.allCases.filter { (records[$0.rawValue]?.wins ?? 0) > 0 || (practice[$0.rawValue]?.wins ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 6) {
            Text("레인보우 숙련 훈장").font(.headline)
            Text("공식 승리 1 · 10 · 30 · 100회에 훈장이 오르고, 궁극기 A·B는 각각 5승에 문양이 열립니다.").font(.caption).foregroundStyle(.secondary)
            if kinds.isEmpty {
                Text("레인보우 펫으로 공식 수동 전투에서 첫 승리를 거두면 훈장이 열립니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(kinds, id: \.self) { kind in
                let official = records[kind.rawValue] ?? ManualMasteryRecord()
                let local = practice[kind.rawValue] ?? ManualMasteryRecord()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(PetMetaStore.shared.displayName(for: kind))
                        if official.wins > 0 { ManualMasteryBadge(record: official) }
                    }
                    Text("공식 \(official.wins)승 · A \(official.originalWins)/5 · B \(official.alternateWins)/5")
                    Text("연습 \(local.wins)승 · A \(local.originalWins)/5 · B \(local.alternateWins)/5")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }
}
