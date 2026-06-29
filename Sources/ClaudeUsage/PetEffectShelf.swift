import SwiftUI

/// 한 펫(`kind`)의 RP 코스메틱 이펙트 구매/장착 관리 칩 행. PetPreviewView(가챠 미리보기)와
/// PartyView(파티 탭)가 공유한다. cf. docs/DESIGN_RP_ECONOMY.md
///
/// 칩 3-state: 미보유=구매(✦가격) / 보유+미장착=OFF / 보유+장착=ON(초록).
/// 클릭 — 보유면 장착 토글, 미보유+구매가능이면 확인 alert. hover — `onPreview` 콜백(펫 렌더 임시 반영용).
struct PetEffectShelf: View {
    let kind: PetKind
    @ObservedObject var settings: Settings
    /// hover 시 미리보기 콜백 (호버한 이펙트, out이면 nil). nil이면 프리뷰 없음.
    var onPreview: ((EffectKind?) -> Void)? = nil

    @State private var pendingEffect: EffectKind? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EffectKind.allCases) { chip($0) }
        }
        .alert("이펙트 구매", isPresented: Binding(
            get: { pendingEffect != nil },
            set: { if !$0 { pendingEffect = nil } }
        ), presenting: pendingEffect) { effect in
            Button("구매 (✦\(effect.price))") {
                _ = RankPointLedger.shared.purchaseEffect(effect, for: kind)
                pendingEffect = nil
            }
            Button("취소", role: .cancel) { pendingEffect = nil }
        } message: { effect in
            Text("\(PetMetaStore.shared.displayName(for: kind))에게 ‘\(effect.displayName)’ 이펙트를 ✦\(effect.price)에 적용할까요?\n보유 RP: \(settings.rp)")
        }
    }

    private func chip(_ effect: EffectKind) -> some View {
        let owned = settings.petEffects[kind]?.contains(effect) ?? false
        let equipped = settings.equippedEffects[kind]?.contains(effect) ?? false
        let affordable = settings.rp >= effect.price
        let tint: Color = equipped ? .green : (owned ? .primary : (affordable ? .cyan : .secondary))

        return Button {
            if owned {
                RankPointLedger.shared.toggleEquip(effect, for: kind)
            } else if affordable {
                pendingEffect = effect
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: effect.iconName)
                    .font(.system(size: 13))
                if owned {
                    Text(equipped ? "ON" : "OFF")
                        .font(.system(size: 7, weight: .bold))
                } else {
                    Text("✦\(effect.price)")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            .frame(width: 40, height: 34)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(equipped ? Color.green.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .strokeBorder(equipped ? Color.green.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .opacity(owned || affordable ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!owned && !affordable)
        .onHover { hovering in onPreview?(hovering ? effect : nil) }
        .help(owned
              ? (equipped ? "\(effect.displayName) 장착됨 — 클릭해 해제" : "\(effect.displayName) 보유 — 클릭해 장착")
              : "\(effect.displayName) · ✦\(effect.price) — 클릭해 구매")
    }
}
