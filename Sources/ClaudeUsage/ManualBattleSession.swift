import Foundation
import Combine

struct ManualMasteryRecord: Codable, Equatable {
    var wins = 0
    var originalWins = 0
    var alternateWins = 0
    var title: String {
        switch wins { case 100...: return "마스터"; case 30...: return "베테랑"
        case 10...: return "숙련"; case 1...: return "첫 발자국"; default: return "첫 승리 도전" }
    }
    var nextThreshold: Int? { [1, 10, 30, 100].first { $0 > wins } }
    var originalEmblem: Bool { originalWins >= 5 }
    var alternateEmblem: Bool { alternateWins >= 5 }
}

/// Practice records never issue official medals or mutate currency/ownership.
struct ManualPracticeArchive: Codable {
    var state: ManualBattleState?
    var initial: ManualBattleState?
    var branchPresets: [String: [String: ManualBranch]] = [:]
    var records: [String: ManualMasteryRecord] = [:]
    var recordedBattleIDs: Set<UUID> = []
    var remoteOwner: String?
    var pendingRequest: ManualPendingRequest?
    var achievementPreview: ManualAchievementProgress?
    var achievementBattleIDs: Set<UUID>?

    mutating func recordResult() {
        guard let state, !state.tutorial, let outcome = state.outcome,
              ["knockout", "turnLimit"].contains(outcome.reason) else { return }
        if outcome.winner == 0 && recordedBattleIDs.insert(state.id).inserted {
            for fighter in state.teams[0].fighters where fighter.pet.variant >= 4 && fighter.participated {
                let key = fighter.pet.kind.rawValue
                var record = records[key] ?? ManualMasteryRecord()
                record.wins += 1
                if fighter.ultimateUsed {
                    if fighter.branch == .original { record.originalWins += 1 } else { record.alternateWins += 1 }
                }
                records[key] = record
            }
        }
        var ids = achievementBattleIDs ?? []
        if ids.insert(state.id).inserted {
            var preview = achievementPreview ?? ManualAchievementProgress()
            preview.apply(state, mastery: records)
            achievementPreview = preview; achievementBattleIDs = ids
        }
    }
}

@MainActor
final class ManualBattleSession: ObservableObject {
    @Published private(set) var archive = ManualPracticeArchive()
    @Published var error: String?
    @Published private(set) var busy = false
    @Published private(set) var serverEnabled = false
    @Published private(set) var officialRecords: [String: ManualMasteryRecord] = [:]
    @Published private(set) var officialAchievements = ManualAchievementProgress()
    @Published private(set) var newAchievements: [ManualAchievement] = []
    @Published private(set) var eligibleKinds: [String] = []
    @Published private(set) var serverStatusMessage: String?
    private let fileURL: URL
    private let transport: any ManualArenaTransport
    private let credentialsProvider: (() -> (String, String)?)?
    private var mayOverwriteSave = true
    var state: ManualBattleState? { archive.state }
    var isRemote: Bool { archive.remoteOwner != nil }
    var hasPendingRequest: Bool { archive.pendingRequest != nil }

    init(directory: URL? = nil, transport: (any ManualArenaTransport)? = nil,
         credentials: (() -> (String, String)?)? = nil) {
        self.transport = transport ?? RankingManualArenaTransport()
        self.credentialsProvider = credentials
        officialAchievements = ManualAchievementStore.shared.progress(owner: credentials?()?.0 ?? Settings.shared.rankingDeviceID)
        let directory = directory ?? AppEnv.dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first!.appendingPathComponent("ClaudeUsage", isDirectory: true)
        fileURL = directory.appendingPathComponent("manual-arena-v1.json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let decoded = try JSONDecoder().decode(ManualPracticeArchive.self, from: Data(contentsOf: fileURL))
                try Self.validate(decoded.state)
                try Self.validate(decoded.initial)
                archive = decoded
            }
        } catch {
            mayOverwriteSave = false
            self.error = (error as? ManualBattleError)?.localizedDescription ?? ManualBattleError.corruptSave.localizedDescription
        }
    }

    static func validate(_ state: ManualBattleState?) throws {
        guard let state else { return }
        guard state.rulesVersion == ManualBattleState.version else { throw ManualBattleError.incompatibleVersion }
        guard UInt64(state.seed) != nil, UInt64(state.randomState) != nil,
              state.teams.count == 2, (1...41).contains(state.turn), state.events.count <= 20_000,
              state.teams.allSatisfy({ team in
                  (1...5).contains(team.fighters.count) && team.fighters.indices.contains(team.active)
                  && (0...10).contains(team.charge) && team.fighters.enumerated().allSatisfy { index, f in
                      f.id == index && f.stats.hp > 0 && f.stats.atk > 0 && f.stats.def > 0 && f.stats.spd > 0
                      && (0...f.stats.hp).contains(f.hp) && !f.moves.isEmpty
                      && f.pp.values.allSatisfy { $0 >= 0 }
                  }
              }) else { throw ManualBattleError.corruptSave }
    }

    static func presetKey(_ members: [PetKind]) -> String { members.map(\.rawValue).joined(separator: "|") }
    func branches(for members: [PetKind]) -> [String: ManualBranch] {
        archive.branchPresets[Self.presetKey(members)] ?? [:]
    }
    func setBranch(_ branch: ManualBranch, kind: PetKind, team: [PetKind]) {
        var updated = archive
        updated.branchPresets[Self.presetKey(team), default: [:]][kind.rawValue] = branch
        commit(updated)
    }

    func start(teamA: [BattlePetSnapshot], teamB: [BattlePetSnapshot], tutorial: Bool = false) {
        guard !isRemote, !hasPendingRequest, !busy else { return }
        newAchievements = []
        do {
            let state = try ManualBattleEngine.make(teamA: teamA, teamB: teamB,
                branchesA: branches(for: teamA.map(\.kind)), seed: tutorial ? 20261025 : UInt64.random(in: 1...UInt64.max), tutorial: tutorial)
            var updated = archive
            updated.state = state; updated.initial = state
            commit(updated)
        } catch { self.error = error.localizedDescription }
    }

    func submit(_ command: ManualCommand) {
        guard !busy, !hasPendingRequest else { return }
        if isRemote { submitRemote(command); return }
        guard let state else { return }
        do {
            let previous = archive.achievementPreview ?? ManualAchievementProgress()
            var updated = archive
            updated.state = try ManualBattleEngine.submit(state, command: command)
            updated.recordResult()
            commit(updated)
            newAchievements = ManualAchievement.allCases.filter { !previous.contains($0) && (archive.achievementPreview?.contains($0) ?? false) }
        } catch { self.error = error.localizedDescription }
    }

    func replaySameConditions() {
        guard !isRemote, !hasPendingRequest, !busy else { return }
        newAchievements = []
        guard var initial = archive.initial else { return }
        // Keep the same ID: repeated fixed-seed practice does not farm even the preview counter.
        initial.events = []
        var updated = archive
        updated.state = initial
        commit(updated)
    }

    /// Explicit discard is the only action allowed to replace an unreadable/incompatible save.
    func discard() {
        guard !busy, !hasPendingRequest else { return }
        var updated = archive
        updated.state = nil; updated.initial = nil
        updated.remoteOwner = nil
        newAchievements = []
        mayOverwriteSave = true
        commit(updated)
    }

    private func commit(_ updated: ManualPracticeArchive) {
        guard mayOverwriteSave else {
            error = "읽지 못한 저장이 있습니다. 저장된 연습전을 삭제한 뒤 다시 시작해 주세요."
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(updated)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            archive = updated
            error = nil
        } catch { self.error = "연습전 저장 실패: \(error.localizedDescription)" }
    }

    private var credentials: (String, String)? {
        if let credentialsProvider { return credentialsProvider() }
        let settings = Settings.shared
        guard RankingAPI.isConfigured, settings.rankingRegistered,
              !settings.rankingDeviceID.isEmpty, let hmac = Keychain.loadRankingHmacKey() else { return nil }
        return (settings.rankingDeviceID, hmac)
    }

    func refreshServer() async {
        guard !busy else { return }
        guard let (owner, key) = credentials else {
            serverStatusMessage = "서버 도전은 랭킹 참여와 서버 연결이 필요합니다."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let status = try await transport.status(owner: owner, hmac: key)
            serverEnabled = status.enabled
            if status.enabled {
                officialRecords = status.records
                ManualMasteryStore.shared.replace(status.records, owner: owner)
                if let achievements = status.achievements {
                    officialAchievements = achievements
                    ManualAchievementStore.shared.replace(achievements, owner: owner)
                }
            }
            serverStatusMessage = status.enabled ? "서버 도전 · 하루 10회 · 코인·Elo 변동 없음" : "서버 수동 도전은 아직 활성화되지 않았습니다."
            if isRemote, archive.remoteOwner != owner {
                error = "다른 계정의 저장된 서버 대전입니다. 원래 계정으로 돌아가 주세요."
                return
            }
            if status.enabled, isRemote, let state {
                let request = ManualPendingRequest(id: UUID(), owner: owner, action: "state", battleID: state.id,
                    revision: state.revision, commandJSON: "{}", branchesJSON: "{}")
                let result = try await transport.send(request, hmac: key)
                try acceptRemote(result, owner: owner, clearPending: true)
            } else if let active = status.active, archive.state == nil, !hasPendingRequest {
                try acceptRemote(active, owner: owner, clearPending: false)
            }
        } catch {
            serverStatusMessage = "서버 수동 도전에 연결할 수 없습니다. 로컬 연습전은 계속 사용할 수 있습니다."
            if isRemote { self.error = error.localizedDescription }
        }
    }

    func startRemote(team: [BattlePetSnapshot]) {
        guard !busy, !hasPendingRequest, archive.state == nil, team.count == 5,
              let (owner, key) = credentials else { return }
        newAchievements = []
        busy = true
        Task {
            defer { busy = false }
            do {
                try await transport.register(team: team, owner: owner, hmac: key)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let branches = String(decoding: try encoder.encode(branches(for: team.map(\.kind))), as: UTF8.self)
                let requestedTeam = String(decoding: try encoder.encode(team), as: UTF8.self)
                let pending = ManualPendingRequest(id: UUID(), owner: owner, action: "start", battleID: nil,
                    revision: 0, commandJSON: requestedTeam, branchesJSON: branches)
                var updated = archive; updated.pendingRequest = pending
                commit(updated)
                guard archive.pendingRequest?.id == pending.id else { return }
                try await sendPending(pending, hmac: key)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func submitRemote(_ command: ManualCommand) {
        guard let state, let (owner, key) = credentials, archive.remoteOwner == owner else {
            error = "서버 대전을 시작한 계정의 인증이 필요합니다."; return
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let pending = ManualPendingRequest(id: UUID(), owner: owner, action: "command", battleID: state.id,
                revision: state.revision, commandJSON: String(decoding: try encoder.encode(command), as: UTF8.self), branchesJSON: "{}")
            var updated = archive; updated.pendingRequest = pending
            commit(updated)
            guard archive.pendingRequest?.id == pending.id else { return }
            busy = true
            Task {
                defer { busy = false }
                do { try await sendPending(pending, hmac: key) }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    func retryPending() {
        guard !busy, let pending = archive.pendingRequest, let (owner, key) = credentials, pending.owner == owner else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await sendPending(pending, hmac: key) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func sendPending(_ pending: ManualPendingRequest, hmac: String) async throws {
        do {
            let result = try await transport.send(pending, hmac: hmac)
            try acceptRemote(result, owner: pending.owner, clearPending: true)
            if result.state.finished {
                let status = try await transport.status(owner: pending.owner, hmac: hmac)
                officialRecords = status.records
                ManualMasteryStore.shared.replace(status.records, owner: pending.owner)
                if let achievements = status.achievements {
                    newAchievements = ManualAchievement.allCases.filter { !officialAchievements.contains($0) && achievements.contains($0) }
                    officialAchievements = achievements
                    ManualAchievementStore.shared.replace(achievements, owner: pending.owner)
                }
            }
        } catch let error as ManualArenaAPIError {
            // A definitive rejection allows a new request. Transport failures retain the exact ID.
            var updated = archive; updated.pendingRequest = nil; commit(updated)
            throw error
        }
    }

    private func acceptRemote(_ result: RankingAPI.ManualArenaResponse, owner: String, clearPending: Bool) throws {
        try Self.validate(result.state)
        var updated = archive
        updated.remoteOwner = owner; updated.state = result.state; updated.initial = nil
        if clearPending { updated.pendingRequest = nil }
        commit(updated)
        eligibleKinds = result.eligibleKinds
    }
}
