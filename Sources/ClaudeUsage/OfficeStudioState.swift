import Foundation

/// 길드가 보유한 가구와 배치 프리셋. 화면의 순서와 무관한 id로 소유권을 유지한다.
struct OfficeStudioState: Codable, Equatable, Sendable {
    static let inventoryLimit = 180
    static let presetLimit = 5
    var version = 1
    var items: [Item]
    var presets: [Preset] = []

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id: String
        let kind: Int
        var x: Double
        var lane: Int
        var wallY: Double?
        var text: String?
        var stored: Bool

        init(id: String = UUID().uuidString.lowercased(), placement: OfficeLayout.FurniturePlacement,
             stored: Bool = false) {
            self.id = id
            kind = placement.kind
            x = Double(placement.x)
            lane = placement.lane
            wallY = placement.wallY.map(Double.init)
            text = placement.text
            self.stored = stored
        }
    }

    struct Position: Codable, Equatable, Sendable {
        let itemID: String
        var x: Double
        var lane: Int
        var wallY: Double?
    }

    struct Preset: Codable, Equatable, Identifiable, Sendable {
        let id: String
        var name: String
        var positions: [Position]
    }

    enum Operation: String, Sendable { case arrange, purchase, delete, presets }
    enum StudioError: LocalizedError {
        case capacity, noSpace, inventoryFull, missingFurniture, presetFull, invalidName
        var errorDescription: String? {
            switch self {
            case .capacity: return "배치할 수 있는 가구는 최대 60개입니다. 일부 가구를 보관해 주세요."
            case .noSpace: return "배치할 공간이 없습니다. 기존 가구를 이동하거나 보관해 주세요."
            case .inventoryFull: return "보유할 수 있는 가구는 최대 180개입니다. 불필요한 가구를 삭제해 주세요."
            case .missingFurniture: return "가구 구성이 변경되었습니다. 최신 사무실을 확인한 뒤 다시 시도해 주세요."
            case .presetFull: return "프리셋은 최대 5개까지 저장할 수 있습니다. 기존 프리셋을 덮어쓰거나 삭제해 주세요."
            case .invalidName: return "프리셋 이름을 1~20자로 입력해 주세요."
            }
        }
    }

    init(legacyLayout: String?) {
        items = OfficeLayout.sanitizedPlacements(legacyLayout).enumerated().map {
            Item(id: "legacy-\($0.offset)", placement: $0.element)
        }
    }

    var placedCount: Int { items.filter { !$0.stored }.count }
    var storedCount: Int { items.count - placedCount }
    var placements: [OfficeLayout.FurniturePlacement] {
        items.enumerated().compactMap { index, item in
            guard !item.stored else { return nil }
            return .init(uid: index, kind: item.kind, x: CGFloat(item.x), lane: item.lane,
                         text: item.text, wallY: item.wallY.map { CGFloat($0) })
        }
    }

    mutating func move(_ placements: [OfficeLayout.FurniturePlacement]) {
        for p in placements where items.indices.contains(p.uid) && !items[p.uid].stored {
            items[p.uid].x = Double(p.x)
            items[p.uid].lane = p.lane
            items[p.uid].wallY = p.wallY.map(Double.init)
            items[p.uid].text = p.text
        }
    }

    mutating func store(_ id: String) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw StudioError.missingFurniture }
        items[index].stored = true
    }

    mutating func restore(_ id: String) throws {
        guard placedCount < OfficeLayout.furnitureMaxInstances else { throw StudioError.capacity }
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].stored else {
            throw StudioError.missingFurniture
        }
        guard let p = OfficeLayout.freePlacement(kind: items[index].kind, uid: index, others: placements) else {
            throw StudioError.noSpace
        }
        items[index].x = Double(p.x)
        items[index].lane = p.lane
        items[index].wallY = p.wallY.map(Double.init)
        items[index].stored = false
    }

    mutating func purchase(_ placement: OfficeLayout.FurniturePlacement, stored: Bool = false) throws {
        guard items.count < Self.inventoryLimit else { throw StudioError.inventoryFull }
        if !stored && placedCount >= OfficeLayout.furnitureMaxInstances { throw StudioError.capacity }
        items.append(Item(placement: placement, stored: stored))
    }

    mutating func delete(_ id: String) throws {
        guard items.contains(where: { $0.id == id }) else { throw StudioError.missingFurniture }
        items.removeAll { $0.id == id }
        // 삭제한 가구가 프리셋을 통해 다시 생기지 않도록 참조도 함께 제거한다.
        for i in presets.indices { presets[i].positions.removeAll { $0.itemID == id } }
    }

    var currentPositions: [Position] {
        items.filter { !$0.stored }.map { Position(itemID: $0.id, x: $0.x, lane: $0.lane, wallY: $0.wallY) }
    }

    mutating func savePreset(name: String, replacing id: String? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 20 else { throw StudioError.invalidName }
        if let id {
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw StudioError.missingFurniture }
            presets[index].name = name
            presets[index].positions = currentPositions
        } else {
            guard presets.count < Self.presetLimit else { throw StudioError.presetFull }
            presets.append(Preset(id: UUID().uuidString.lowercased(), name: name, positions: currentPositions))
        }
    }

    mutating func applyPreset(_ id: String) throws {
        guard let preset = presets.first(where: { $0.id == id }) else { throw StudioError.missingFurniture }
        let positions = Dictionary(uniqueKeysWithValues: preset.positions.map { ($0.itemID, $0) })
        for index in items.indices {
            if let position = positions[items[index].id] {
                items[index].stored = false
                items[index].x = position.x
                items[index].lane = position.lane
                items[index].wallY = position.wallY
            } else {
                items[index].stored = true
            }
        }
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// 배치 변경만 되돌린다. 구매/영구 삭제 후에는 기록을 지워 가구 복제·환불을 막는다.
struct OfficeStudioHistory {
    private(set) var undo: [[OfficeStudioState.Item]] = []
    private(set) var redo: [[OfficeStudioState.Item]] = []
    mutating func record(_ items: [OfficeStudioState.Item]) {
        undo.append(items)
        if undo.count > 20 { undo.removeFirst() }
        redo.removeAll()
    }
    mutating func didUndo(current: [OfficeStudioState.Item]) { _ = undo.popLast(); redo.append(current) }
    mutating func didRedo(current: [OfficeStudioState.Item]) { _ = redo.popLast(); undo.append(current) }
    mutating func clear() { undo.removeAll(); redo.removeAll() }
}

struct OfficeStudioSave: Sendable {
    let state: OfficeStudioState
    let expectedRevision: Int
    let expectedLayout: String
    let operation: OfficeStudioState.Operation
    var purchaseKind: Int? = nil
}
