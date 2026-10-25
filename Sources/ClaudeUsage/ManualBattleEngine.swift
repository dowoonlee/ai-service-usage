import Foundation

enum ManualBattleEngine {
    static func make(teamA: [BattlePetSnapshot], teamB: [BattlePetSnapshot],
                     branchesA: [String: ManualBranch] = [:], branchesB: [String: ManualBranch] = [:],
                     seed: UInt64, id: UUID = UUID(), tutorial: Bool = false) throws -> ManualBattleState {
        guard teamA.count == teamB.count, (1...5).contains(teamA.count) else { throw ManualBattleError.invalidTeam }
        var teams: [ManualTeam] = []
        for (members, branches) in [(teamA, branchesA), (teamB, branchesB)] {
            guard Set(members.map(\.kind)).count == members.count,
                  members.allSatisfy({ (0...4).contains($0.variant) && (0...15).contains($0.enhanceLevel)
                      && $0.progressUnits.isFinite && (0...8).contains($0.progressUnits) }) else {
                throw ManualBattleError.invalidTeam
            }
            let bonus = TeamSynergy.bonus(for: members)
            let fighters = members.enumerated().map { slot, pet -> ManualFighter in
                let base = PetBattleStats.compute(kind: pet.kind, variant: pet.variant,
                    enhanceLevel: pet.enhanceLevel, progressUnits: pet.progressUnits)
                func scale(_ value: Int, _ stat: StatKind) -> Int {
                    let multiplier = 1 + min(0.10, bonus.collectionMult - 1)
                        + (bonus.typeStat == stat ? min(0.05, bonus.typeAdd) : 0)
                    return max(1, Int((Double(value) * multiplier).rounded()))
                }
                let stats = BattleStats(hp: scale(base.hp, .hp), atk: scale(base.atk, .atk),
                                        def: scale(base.def, .def), spd: scale(base.spd, .spd))
                let branch = branches[pet.kind.rawValue] ?? .original
                let moves = ManualBattleRules.moves(for: pet, branch: branch)
                let pp = Dictionary(uniqueKeysWithValues: moves.compactMap { m in m.maxPP.map { (m.id, $0) } })
                return ManualFighter(id: slot, pet: pet, stats: stats, hp: stats.hp, moves: moves, pp: pp, branch: branch)
            }
            teams.append(ManualTeam(fighters: fighters))
        }
        var state = ManualBattleState(id: id, teams: teams, seed: String(seed),
            randomState: String(seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed), tutorial: tutorial)
        state.committedAI = chooseAI(state, side: 1)
        return state
    }

    static func legalCommands(_ state: ManualBattleState, side: Int) -> [ManualCommand] {
        guard (0...1).contains(side), !state.finished else { return [] }
        let team = state.teams[side]
        if team.needsReplacement {
            return team.fighters.indices.filter { team.fighters[$0].alive }.map { .replacement($0) }
        }
        // Normal actions must wait until both teams have replaced fainted leads.
        if state.teams.contains(where: \.needsReplacement) { return [] }
        let fighter = team.fighters[team.active]
        var commands = fighter.moves.compactMap { move -> ManualCommand? in
            if move.ultimate && team.charge < 10 { return nil }
            if let _ = move.maxPP, (fighter.pp[move.id] ?? 0) <= 0 { return nil }
            if move.special == "healTeam" && !team.fighters.contains(where: { $0.alive && $0.hp < $0.stats.hp }) { return nil }
            return .move(move.id)
        }
        commands += team.fighters.indices.filter { $0 != team.active && team.fighters[$0].alive }.map { .swap($0) }
        if team.lastGuard != state.turn - 1 { commands.append(.guardMove) }
        return commands
    }

    /// Opponent command was committed at the previous decision boundary, never in response to this command.
    static func submit(_ original: ManualBattleState, command: ManualCommand) throws -> ManualBattleState {
        guard original.rulesVersion == ManualBattleState.version else { throw ManualBattleError.incompatibleVersion }
        guard !original.finished else { throw ManualBattleError.invalidCommand }
        var state = original
        if command == .surrender {
            state.outcome = ManualOutcome(winner: 1, reason: "surrender")
            record(&state, side: 0, kind: "battleEnded", text: "항복했습니다.")
            state.revision += 1
            return state
        }
        guard legalCommands(state, side: 0).contains(command) else { throw ManualBattleError.invalidCommand }
        if case .replacement(let slot) = command {
            state.teams[0].active = slot
            record(&state, side: 0, kind: "switched", text: "\(name(state, 0)) 출전!")
            if state.teams[1].needsReplacement, case .replacement(let aiSlot) = state.committedAI {
                state.teams[1].active = aiSlot
                record(&state, side: 1, kind: "switched", text: "\(name(state, 1)) 출전!")
            }
            state.revision += 1
            state.committedAI = chooseAI(state, side: 1)
            return state
        }
        guard let ai = state.committedAI, legalCommands(state, side: 1).contains(ai) else {
            throw ManualBattleError.invalidCommand
        }
        return try resolve(state, commands: [command, ai])
    }

    /// Public for deterministic two-policy simulations and cross-language parity vectors.
    static func resolve(_ original: ManualBattleState, commands: [ManualCommand]) throws -> ManualBattleState {
        guard original.rulesVersion == ManualBattleState.version, commands.count == 2,
              (0...1).allSatisfy({ legalCommands(original, side: $0).contains(commands[$0]) }),
              !original.teams.contains(where: \.needsReplacement) else { throw ManualBattleError.invalidCommand }
        var state = original
        let startingSlots = state.teams.map(\.active)
        let speeds = state.teams.map { ManualBattleRules.stat($0.fighters[$0.active], .spd) }
        func priority(_ command: ManualCommand) -> Int {
            switch command { case .swap: return 2; case .guardMove: return 1; default: return 0 }
        }
        let p0 = priority(commands[0]), p1 = priority(commands[1])
        let first: Int
        if p0 != p1 { first = p0 > p1 ? 0 : 1 }
        else if speeds[0] != speeds[1] { first = speeds[0] > speeds[1] ? 0 : 1 }
        else { first = next(&state) & 1 == 0 ? 0 : 1 }
        var guarded = [false, false]
        var attackCharge = [false, false], hitCharge = [false, false]
        record(&state, side: 0, kind: "turnStarted", text: "턴 \(state.turn)")
        observeComeback(&state)
        if first == 0, case .move = commands[0], case .move = commands[1] {
            var withoutSlow = state.teams[1].fighters[startingSlots[1]]
            withoutSlow.effects.removeAll { ["legacy", "bsod_lag"].contains($0.id) }
            if speeds[0] > speeds[1] && speeds[0] < ManualBattleRules.stat(withoutSlow, .spd) {
                record(&state, side: 0, kind: "speedReversalWindow", text: "", amount: startingSlots[1])
            }
        }
        for side in [first, 1 - first] {
            let slot = startingSlots[side]
            guard state.teams[side].fighters[slot].alive, state.teams[side].active == slot else { continue }
            if case .swap(let target) = commands[side] {
                state.teams[side].fighters[slot].effects.removeAll { ManualBattleRules.isBuff($0.id) }
                state.teams[side].active = target
                state.teams[side].lastSwitch = state.turn
                record(&state, side: side, kind: "switched", text: "\(name(state, side))에게 교체!")
                continue
            }
            if skip(&state, side: side, slot: slot) { continue }
            if commands[side] == .guardMove {
                guarded[side] = true
                state.teams[side].lastGuard = state.turn
                record(&state, side: side, kind: "guarded", text: "\(name(state, side)) 방어!")
                continue
            }
            guard case .move(let id) = commands[side],
                  let move = state.teams[side].fighters[slot].moves.first(where: { $0.id == id }) else { continue }
            if move.ultimate { state.teams[side].charge -= 10 }
            if move.maxPP != nil { state.teams[side].fighters[slot].pp[id, default: 0] -= 1 }
            record(&state, side: side, kind: "skillUsed", text: "\(name(state, side)) · \(move.name)!", moveID: id)
            let enemy = 1 - side, target = state.teams[enemy].active
            var effective = false
            if move.special == "dispelShield" {
                let old = state.teams[enemy].fighters[target].effects.count
                state.teams[enemy].fighters[target].effects.removeAll { ManualBattleRules.isShield($0.id) }
                if state.teams[enemy].fighters[target].effects.count != old {
                    effective = true
                    record(&state, side: enemy, kind: "effectRemoved", text: "실드가 제거되었습니다.")
                }
            }
            if move.power > 0 && state.teams[enemy].fighters[target].alive {
                let factor = 0.9 + 0.1 * uniform(&state)
                let amount = ManualBattleRules.damage(move, from: state.teams[side].fighters[slot],
                    to: state.teams[enemy].fighters[target], factor: factor, guarded: guarded[enemy])
                let hit = damage(&state, side: enemy, slot: target, amount: amount)
                let effectiveness = SkillCatalog.skillEffectiveness(BattleType(rawValue: move.type) ?? state.teams[side].fighters[slot].type,
                    vs: state.teams[enemy].fighters[target].type)
                if enemy == 0 && state.teams[0].lastSwitch == state.turn && hit.total > 0 && effectiveness == 0.5 {
                    record(&state, side: 0, slot: target, kind: "resistedSwitch", text: "")
                }
                if side == 0 && hit.hp > 0 && !state.teams[enemy].fighters[target].alive {
                    if effectiveness == 2 { achievementFact(&state, .typeExpert) }
                    if state.events.contains(where: { $0.kind == "resistedSwitch" && $0.slot == slot && $0.turn == state.turn - 1 }) {
                        achievementFact(&state, .switchCounter)
                    }
                    if state.events.contains(where: { $0.kind == "speedReversalWindow" && $0.slot == slot && $0.turn == state.turn && $0.amount == target }) {
                        achievementFact(&state, .speedPlanner)
                    }
                    if !move.ultimate && original.teams[0].charge == 10 && state.teams[0].fighters[slot].pet.variant >= 4 {
                        record(&state, side: 1, slot: target, kind: "reservedUltimate", text: "")
                    }
                    if move.ultimate && state.events.contains(where: { $0.kind == "reservedUltimate" && $0.slot != target && $0.turn < state.turn }) {
                        achievementFact(&state, .ultimateReserve)
                    }
                }
                if hit.total > 0 { effective = true; if !move.ultimate { attackCharge[side] = true } }
                if hit.hp > 0 { hitCharge[enemy] = true }
                if guarded[enemy] && hit.total > 0 { state.teams[enemy].fighters[target].participated = true }
                if state.teams[enemy].lastSwitch == state.turn && hit.total > 0 {
                    state.teams[enemy].fighters[target].participated = true
                }
                if move.special == "splash" {
                    for other in state.teams[enemy].fighters.indices where other != target && state.teams[enemy].fighters[other].alive {
                        let splash = damage(&state, side: enemy, slot: other, amount: max(1, Int((Double(amount) * 0.3).rounded())))
                        if side == 0 && splash.hp > 0 && !state.teams[enemy].fighters[other].alive
                            && state.events.contains(where: { $0.kind == "reservedUltimate" && $0.slot != other && $0.turn < state.turn }) {
                            achievementFact(&state, .ultimateReserve)
                        }
                        if splash.hp > 0 { hitCharge[enemy] = true }
                        effective = effective || splash.total > 0
                    }
                }
            }
            if move.special == "healSelf" { effective = heal(&state, side: side, slot: slot, fraction: 0.25) || effective }
            if move.special == "healTeam" {
                var healedCount = 0
                for i in state.teams[side].fighters.indices {
                    let healed = heal(&state, side: side, slot: i, fraction: 0.15)
                    if healed { healedCount += 1 }
                    effective = healed || effective
                }
                if side == 0 && healedCount >= 3 { achievementFact(&state, .teamRecovery) }
            }
            if move.special == "spread" {
                for i in state.teams[enemy].fighters.indices where state.teams[enemy].fighters[i].alive {
                    effective = grant(&state, side: enemy, slot: i, id: "spread_dot") || effective
                }
            }
            if let effect = move.effect {
                let recipient = move.selfTarget ? side : enemy
                let index = move.selfTarget ? slot : target
                let f = state.teams[recipient].fighters[index]
                if f.alive && !(ManualBattleRules.isControl(effect) && f.immuneUntil >= state.turn) {
                    if move.chance >= 1 || uniform(&state) < move.chance {
                        effective = grant(&state, side: recipient, slot: index, id: effect) || effective
                    }
                }
            }
            if effective {
                state.teams[side].fighters[slot].participated = true
                if move.ultimate { state.teams[side].fighters[slot].ultimateUsed = true }
            }
            observeComeback(&state)
        }
        for side in 0...1 {
            state.teams[side].charge = min(10, state.teams[side].charge + (attackCharge[side] ? 1 : 0) + (hitCharge[side] ? 1 : 0))
        }
        endTurn(&state)
        state.revision += 1
        if !state.finished {
            state.turn += 1
            // Only-AI replacement needs no player input. Simultaneous replacement stays hidden until submission.
            if state.teams[1].needsReplacement && !state.teams[0].needsReplacement,
               case .replacement(let slot) = chooseAI(state, side: 1) {
                state.teams[1].active = slot
                record(&state, side: 1, kind: "switched", text: "\(name(state, 1)) 출전!")
            }
            if state.teams[0].needsReplacement {
                let alive = state.teams[0].fighters.indices.filter { state.teams[0].fighters[$0].alive }
                if alive.count == 1 {
                    state.teams[0].active = alive[0]
                    record(&state, side: 0, kind: "switched", text: "\(name(state, 0)) 출전!")
                    if state.teams[1].needsReplacement, case .replacement(let slot) = chooseAI(state, side: 1) {
                        state.teams[1].active = slot
                        record(&state, side: 1, kind: "switched", text: "\(name(state, 1)) 출전!")
                    }
                }
            }
            state.committedAI = chooseAI(state, side: 1)
        } else { state.committedAI = nil }
        return state
    }

    private static func endTurn(_ state: inout ManualBattleState) {
        // All residual changes are computed independently before checking either team's survival.
        for side in 0...1 {
            for i in state.teams[side].fighters.indices where state.teams[side].fighters[i].alive {
                let f = state.teams[side].fighters[i]
                var delta = 0
                for e in f.effects where e.applied < state.turn && e.expires >= state.turn {
                    let amount = max(1, Int((Double(f.stats.hp) * ManualBattleRules.magnitude(e.id)).rounded()))
                    switch e.id {
                    case "mem_leak", "infinite_loop", "spread_dot": delta -= amount
                    case "autoscaling": delta += amount
                    default: break
                    }
                }
                if state.turn >= 25 { delta -= max(1, Int((Double(f.stats.hp) * 0.05).rounded())) }
                let hp = min(f.stats.hp, max(0, f.hp + delta))
                state.teams[side].fighters[i].hp = hp
                if hp != f.hp {
                    record(&state, side: side, slot: i, kind: "residual", text: "\(f.pet.kind.displayName) · 턴 종료 HP \(hp - f.hp > 0 ? "+" : "")\(hp - f.hp)", hp: hp, amount: hp - f.hp)
                }
                if hp == 0 {
                    state.teams[side].fighters[i].effects = []
                    record(&state, side: side, slot: i, kind: "fainted", text: "\(f.pet.kind.displayName) 기절!")
                } else {
                    state.teams[side].fighters[i].effects.removeAll { $0.expires <= state.turn }
                }
            }
        }
        let alive = state.teams.map(\.alive)
        observeComeback(&state)
        if !alive[0] || !alive[1] {
            state.outcome = ManualOutcome(winner: alive[0] ? 0 : (alive[1] ? 1 : nil), reason: "knockout")
        } else if state.turn >= 40 { state.outcome = ManualOutcome(winner: nil, reason: "turnLimit") }
        if let outcome = state.outcome {
            record(&state, side: outcome.winner ?? 0, kind: "battleEnded",
                   text: outcome.winner == nil ? "무승부" : (outcome.winner == 0 ? "승리했습니다!" : "패배했습니다."))
        }
    }

    private static func skip(_ state: inout ManualBattleState, side: Int, slot: Int) -> Bool {
        let f = state.teams[side].fighters[slot]
        guard f.immuneUntil < state.turn else { return false }
        let controls = f.effects.filter { ManualBattleRules.isControl($0.id) && $0.applied < state.turn && $0.expires >= state.turn }
        let fixed = controls.contains { $0.id != "deadlock" }
        let skipped = fixed || (!controls.isEmpty && uniform(&state) < 0.35)
        if skipped {
            state.teams[side].fighters[slot].effects.removeAll { ManualBattleRules.isControl($0.id) }
            state.teams[side].fighters[slot].immuneUntil = state.turn + 2
            record(&state, side: side, kind: "actionSkipped", text: "\(name(state, side)) 행동불가! 이후 2턴은 면역입니다.")
        }
        return skipped
    }

    @discardableResult
    private static func grant(_ state: inout ManualBattleState, side: Int, slot: Int, id: String) -> Bool {
        var f = state.teams[side].fighters[slot]
        guard f.alive, !(ManualBattleRules.isControl(id) && f.immuneUntil >= state.turn) else { return false }
        let before = f.effects
        if id == "hot_reload" {
            f.effects.removeAll { !ManualBattleRules.isBuff($0.id) }
        } else {
            let shield = ManualBattleRules.isShield(id) ? max(1, Int((Double(f.stats.hp) * ManualBattleRules.magnitude(id)).rounded())) : 0
            let expires = state.turn + ManualBattleRules.duration(id)
            if ManualBattleRules.isShield(id), let idx = f.effects.firstIndex(where: { ManualBattleRules.isShield($0.id) }) {
                let old = f.effects[idx]
                if shield > old.shield || (shield == old.shield && expires > old.expires) {
                    state.effectSequence += 1
                    f.effects[idx] = ManualEffect(id: id, applied: state.turn, expires: expires, sequence: state.effectSequence, shield: shield)
                }
            } else if let idx = f.effects.firstIndex(where: { $0.id == id }) {
                f.effects[idx].expires = max(f.effects[idx].expires, expires)
            } else {
                if f.effects.count >= 4 {
                    let remove = f.effects.indices.min { a, b in
                        let x = f.effects[a], y = f.effects[b]
                        return x.expires == y.expires ? x.sequence < y.sequence : x.expires < y.expires
                    }!
                    f.effects.remove(at: remove)
                }
                state.effectSequence += 1
                f.effects.append(ManualEffect(id: id, applied: state.turn, expires: expires, sequence: state.effectSequence, shield: shield))
            }
        }
        guard before != f.effects else { return false }
        state.teams[side].fighters[slot] = f
        record(&state, side: side, slot: slot, kind: "effectApplied", text: "\(f.pet.kind.displayName) · \(ManualBattleRules.effectName(id))")
        return true
    }

    private static func damage(_ state: inout ManualBattleState, side: Int, slot: Int, amount: Int) -> (hp: Int, total: Int) {
        var f = state.teams[side].fighters[slot]
        guard f.alive else { return (0, 0) }
        var remaining = amount
        for i in f.effects.indices where f.effects[i].shield > 0 {
            let absorbed = min(remaining, f.effects[i].shield)
            f.effects[i].shield -= absorbed; remaining -= absorbed
        }
        f.effects.removeAll { ManualBattleRules.isShield($0.id) && $0.shield == 0 }
        let hpDamage = min(f.hp, remaining)
        f.hp -= hpDamage
        if !f.alive { f.effects = [] }
        state.teams[side].fighters[slot] = f
        record(&state, side: side, slot: slot, kind: "damage", text: "\(f.pet.kind.displayName) HP −\(hpDamage)\(amount > remaining ? " · 실드 흡수 \(amount - remaining)" : "")", hp: f.hp, amount: hpDamage)
        if !f.alive { record(&state, side: side, slot: slot, kind: "fainted", text: "\(f.pet.kind.displayName) 기절!") }
        return (hpDamage, hpDamage + amount - remaining)
    }

    private static func heal(_ state: inout ManualBattleState, side: Int, slot: Int, fraction: Double) -> Bool {
        let f = state.teams[side].fighters[slot]
        guard f.alive else { return false }
        let amount = min(f.stats.hp - f.hp, max(1, Int((Double(f.stats.hp) * fraction).rounded())))
        guard amount > 0 else { return false }
        state.teams[side].fighters[slot].hp += amount
        record(&state, side: side, slot: slot, kind: "healed", text: "\(f.pet.kind.displayName) HP +\(amount)", hp: f.hp + amount, amount: amount)
        return true
    }

    static func chooseAI(_ state: ManualBattleState, side: Int) -> ManualCommand? {
        let legal = legalCommands(state, side: side)
        let team = state.teams[side], enemy = state.teams[1 - side]
        let current = team.fighters[team.active], target = enemy.fighters[enemy.active]
        func bestDamage(_ fighter: ManualFighter, _ opponent: ManualFighter) -> Double {
            fighter.moves.filter { !$0.ultimate && ($0.maxPP == nil || fighter.pp[$0.id, default: 0] > 0) }
                .map { Double(ManualBattleRules.damage($0, from: fighter, to: opponent)) }.max() ?? 0
        }
        func score(_ command: ManualCommand) -> Double {
            switch command {
            case .replacement(let slot):
                let f = team.fighters[slot]
                return bestDamage(f, target) - bestDamage(target, f) * 0.5 + Double(f.hp) * 0.1
            case .swap(let slot):
                guard team.lastSwitch != state.turn - 1 else { return -1000 }
                let f = team.fighters[slot], risk = bestDamage(target, f)
                let nowRisk = bestDamage(target, current)
                return bestDamage(f, target) - risk + (nowRisk >= Double(current.hp) ? 15 : 0) - 10
            case .guardMove:
                let incoming = bestDamage(target, current)
                return enemy.charge >= 10 && target.pet.variant >= 4 ? incoming * 0.8 + 8 : -5
            case .move(let id):
                guard let move = current.moves.first(where: { $0.id == id }) else { return -1000 }
                let damage = Double(ManualBattleRules.damage(move, from: current, to: target))
                var value = min(Double(target.hp), damage)
                if move.maxPP != nil { value -= 2 }
                if move.ultimate { value -= 8 }
                if move.power > 0 && ManualBattleRules.damage(move, from: current, to: target, factor: 0.9) >= target.hp { value += 30 }
                if let effect = move.effect {
                    let recipient = move.selfTarget ? current : target
                    if effect == "hot_reload" {
                        if recipient.effects.contains(where: { !ManualBattleRules.isBuff($0.id) }) { value += 12 }
                    } else if !recipient.effects.contains(where: { $0.id == effect })
                        && !(ManualBattleRules.isControl(effect) && recipient.immuneUntil >= state.turn) {
                        value += (move.selfTarget ? 10 : 8) * move.chance
                    }
                }
                if move.special == "healSelf" { value += Double(min(current.stats.hp - current.hp, Int(Double(current.stats.hp) * 0.25))) }
                if move.special == "healTeam" {
                    value += team.fighters.filter(\.alive).reduce(0) { $0 + Double(min($1.stats.hp - $1.hp, Int(Double($1.stats.hp) * 0.15))) }
                }
                if move.special == "splash" { value += Double(enemy.fighters.filter(\.alive).count - 1) * damage * 0.25 }
                if move.special == "spread" { value += Double(enemy.fighters.filter(\.alive).count) * 5 }
                if move.special == "dispelShield" { value += Double(target.effects.reduce(0) { $0 + $1.shield }) }
                return value
            case .surrender: return -1000
            }
        }
        // Stable tie-breaking uses legal command order, and never consumes combat RNG.
        return legal.enumerated().max { a, b in
            let x = score(a.element), y = score(b.element)
            return x == y ? a.offset > b.offset : x < y
        }?.element
    }

    private static func name(_ state: ManualBattleState, _ side: Int) -> String {
        state.teams[side].fighters[state.teams[side].active].pet.kind.displayName
    }
    private static func achievementFact(_ state: inout ManualBattleState, _ achievement: ManualAchievement) {
        record(&state, side: 0, kind: "achievementFact", text: "", moveID: achievement.rawValue)
    }
    private static func observeComeback(_ state: inout ManualBattleState) {
        if state.teams[0].fighters.filter(\.alive).count == 1 && state.teams[1].fighters.filter(\.alive).count >= 3
            && !state.events.contains(where: { $0.kind == "comebackWindow" }) {
            record(&state, side: 0, kind: "comebackWindow", text: "")
        }
    }
    private static func record(_ state: inout ManualBattleState, side: Int, slot: Int? = nil,
                               kind: String, text: String, hp: Int? = nil, amount: Int? = nil, moveID: String? = nil) {
        state.events.append(ManualEvent(id: state.events.count, turn: state.turn, side: side,
            slot: slot ?? state.teams[side].active, kind: kind, text: text, hp: hp, amount: amount, moveID: moveID))
    }
    private static func next(_ state: inout ManualBattleState) -> UInt64 {
        let value = (UInt64(state.randomState) ?? 0) &+ 0x9E37_79B9_7F4A_7C15
        state.randomState = String(value)
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    private static func uniform(_ state: inout ManualBattleState) -> Double {
        Double(next(&state) >> 11) / 9_007_199_254_740_992.0
    }
}
