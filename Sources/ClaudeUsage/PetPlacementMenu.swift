import SwiftUI

struct PetPlacementMenu: View {
    let pet: PetSelection
    let open: (GachaView.Tab) -> Void
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack {
            Menu("차트에 배치") {
                ForEach(settings.partyPresets) { preset in
                    let charts = PetChartSource.allCases.filter { settings.presetID(for: $0) == preset.id }
                    if !charts.isEmpty {
                        Menu(charts.map(\.displayName).joined(separator: " · ") + " — " + preset.name) {
                            if preset.members.contains(where: { $0.kind == pet.kind }) {
                                Button("배치된 펫 보기") { open(.party) }
                            } else if preset.members.count < Settings.maxPartySize {
                                Button("빈 슬롯에 추가") {
                                    settings.addToPreset(preset.id, pet)
                                    open(.party)
                                }
                            } else {
                                ForEach(preset.members, id: \.kind) { member in
                                    Button("\(name(member.kind)) 교체") {
                                        guard settings.replacePartyMember(member.kind, in: preset.id, with: pet) else { return }
                                        open(.party)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Menu("배틀 팀에 배치") {
                let team = settings.battleTeam.filter { settings.ownedPets[$0] != nil }
                if team.contains(pet.kind) {
                    Button("배치된 펫 보기") { open(.team) }
                } else if team.count < 5 {
                    Button("빈 슬롯에 추가") { placeInTeam(replacing: nil) }
                } else {
                    ForEach(team, id: \.self) { member in
                        Button("\(name(member)) 교체") { placeInTeam(replacing: member) }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func name(_ kind: PetKind) -> String { PetMetaStore.shared.displayName(for: kind) }

    private func placeInTeam(replacing kind: PetKind?) {
        if settings.placeInBattleTeam(pet.kind, replacing: kind) { open(.team) }
    }
}
