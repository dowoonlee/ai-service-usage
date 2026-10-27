import SwiftUI

// 리캡 장면 목록. 순서 = 재생 순서, 데이터가 빈약한 장면은 `isAvailable`로 빠진다.
//
// 연출을 다 옮긴 장면: boot / yearline / gauges / partner.
// 나머지는 `stat`(큰 숫자 + 내레이터 + 폭죽)으로 자리만 잡아 두었다 — 데모(recap-demo.html)의
// 연출을 하나씩 옮길 자리.

@MainActor
enum RecapScenes {
    static var all: [RecapScene] {
        [boot, yearline, gauges, vs, cursor, grass, golden, gacha, partner, gym, arena, life, ending]
    }

    // MARK: 공통

    private static func md(_ d: Date?) -> String {
        guard let d else { return "-" }
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)월 \(c.day ?? 0)일"
    }

    private static func fmt(_ n: Int) -> String { n.formatted() }

    /// 펫마다 셀 크기가 16~93px로 제각각이라, 목표 높이에 맞는 정수 배율을 고른다.
    static func fitScale(_ kind: PetKind, target: Double) -> Double {
        guard let h = PetSprite.frames(for: kind, action: .sit).first?.size.height, h > 0 else { return 1 }
        return max(1, (target / h).rounded(.down))
    }

    private static func narrator(_ p: RecapPainter, _ t: Double, x: Double, y: Double,
                                 action: PetController.Action = .sit, target: Double = 56) {
        let sel = p.facts.game.narrator
        p.pet(sel.kind, action, t: t, x: x, y: y, scale: fitScale(sel.kind, target: target), variant: sel.variant)
    }

    // MARK: 오프닝 — 노이즈 → "2026" 블록 낙하 → 내레이터 등장

    private static let digits: [Character: [String]] = [
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    ]

    static let boot = RecapScene(
        id: "boot", duration: 7,
        kicker: { _ in "AIUSAGE RECAP" },
        title: { f in "\(f.usage.daily.count)일" },
        draw: { p, t in
            p.bands(RecapPalette.night)
            if t < 0.9 {
                for _ in 0..<900 {
                    p.rect(.random(in: 0...240), .random(in: 0...360), 2, 2,
                           Bool.random() ? Color(hex: 0x2B2540) : Color(hex: 0x58507A))
                }
                p.rect(0, (t * 900).truncatingRemainder(dividingBy: 360), 240, 6, .white.opacity(0.13))
                return
            }
            p.stars(t)
            let b = 6.0, x0 = 51.0, y0 = 112.0
            let cols = [RecapPalette.red, RecapPalette.gold, RecapPalette.green, RecapPalette.blue]
            for (di, ch) in "2026".enumerated() {
                for (r, row) in (digits[ch] ?? []).enumerated() {
                    for (c, v) in row.enumerated() where v == "1" {
                        let st = 0.9 + Double(di) * 0.28 + Double(6 - r) * 0.05 + Double(c) * 0.02
                        let q = recapClamp((t - st) / 0.35)
                        guard q > 0 else { continue }
                        let ty = y0 + Double(r) * b, x = x0 + Double(di) * 36 + Double(c) * b
                        let y = -10 + (ty + 10) * (q < 1 ? q * q : 1)
                        p.rect(x, y, b, b, cols[di])
                        p.rect(x, y, b, 1, .white.opacity(0.5))
                        p.rect(x, y + b - 1, b, 1, .black.opacity(0.33))
                        if r == 6 {
                            p.player.once("b\(di)\(c)", q >= 1) {
                                p.player.burst(x + 3, ty + b, count: 3, colors: [.white, cols[di]], speed: 1, gravity: 0.1, life: 14)
                                p.player.shake = max(p.player.shake, 1.2)
                            }
                        }
                    }
                }
            }
            if t > 3 {
                let q = recapClamp((t - 3) / 1.4)
                narrator(p, t, x: -20 + 140 * recapEase(q), y: 236, action: q < 1 ? .run : .sit, target: 64)
                p.player.once("land", q >= 1) {
                    p.player.burst(120, 236, count: 10, colors: [.white, RecapPalette.green], speed: 1.4, life: 20)
                }
            }
            p.ground(236)
        })

    // MARK: 연간 라인 — 7일 평균선을 그리며 내레이터가 끝을 따라 달린다

    static let yearline = RecapScene(
        id: "yearline", duration: 8,
        isAvailable: { $0.usage.activeDays > 0 },
        kicker: { f in "\(md(f.usage.firstDay))부터" },
        title: { f in "\(f.usage.activeDays)일 활동" },
        draw: { p, t in
            p.bands([Color(hex: 0x141033), Color(hex: 0x1A1440), Color(hex: 0x211A4F), Color(hex: 0x2A2160)])
            p.stars(t, color: Color(hex: 0x58507A))
            let daily = p.facts.usage.daily, n = daily.count
            guard n > 1 else { return }
            let smooth = daily.indices.map { i -> Double in
                let lo = max(0, i - 3), hi = min(n - 1, i + 3)
                return daily[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            }
            let mx = max(smooth.max() ?? 1, 1e-9)
            let x0 = 14.0, x1 = 226.0, yb = 252.0, yt = 120.0
            func X(_ i: Int) -> Double { x0 + Double(i) / Double(n - 1) * (x1 - x0) }
            func Y(_ i: Int) -> Double { (yb - smooth[i] / mx * (yb - yt)).rounded() }
            let peak = smooth.firstIndex(of: smooth.max()!) ?? 0

            p.rect(x0, yb + 1, x1 - x0, 1, Color(hex: 0x58507A))
            if let first = p.facts.usage.firstDay {
                for i in 0..<n {
                    guard let d = Calendar.current.date(byAdding: .day, value: i, to: first),
                          Calendar.current.component(.day, from: d) == 1 else { continue }
                    p.rect(X(i), yb + 1, 1, 3, Color(hex: 0x9A93B3))
                    p.text("\(Calendar.current.component(.month, from: d))월", X(i) + 8, yb + 10,
                           size: 8, color: Color(hex: 0x9A93B3), outline: false)
                }
            }
            let q = recapClamp((t - 0.4) / 5), last = Int(q * Double(n - 1))
            var prevY = Y(0)
            for i in 0...last {
                let x = X(i).rounded(), y = Y(i)
                var yy = y
                while yy < yb { if Int(yy + x) % 4 == 0 { p.rect(x, yy, 1, 1, RecapPalette.blue.opacity(0.4)) }; yy += 2 }
                p.rect(x, min(y, prevY), 2, abs(y - prevY) + 2, abs(i - peak) < 4 ? RecapPalette.gold : RecapPalette.red)
                prevY = y
            }
            if last >= peak {
                let px = X(peak), py = Y(peak)
                if Bool.random() {
                    p.player.particles.append(RecapParticle(x: px + .random(in: -3...3), y: py, vx: .random(in: -0.2...0.2),
                                                            vy: .random(in: -1 ... -0.4), life: 18,
                                                            color: [RecapPalette.gold, RecapPalette.red, .white].randomElement()!,
                                                            size: 2, gravity: 0))
                }
                p.player.once("peak", true) {
                    p.player.shake = 2.5
                    p.player.burst(px, py, count: 24, colors: [RecapPalette.gold, RecapPalette.red, .white])
                }
            }
            narrator(p, t, x: X(last), y: Y(last) + 2, action: q < 1 ? .run : .sit, target: 32)
        })

    // MARK: 한도 탑 — 태운 주간 한도를 게이지 블록으로 쌓는다

    static let gauges = RecapScene(
        id: "gauges", duration: 8.5,
        isAvailable: { $0.usage.claudeWeeklyGauges + $0.usage.codexWeeklyGauges > 0 },
        kicker: { _ in "올해 태운 주간 한도" },
        title: { f in String(format: "%.1f장", f.usage.claudeWeeklyGauges + f.usage.codexWeeklyGauges) },
        draw: { p, t in
            p.bands([Color(hex: 0x1D2B4A), Color(hex: 0x22345A), Color(hex: 0x2A3F6B), Color(hex: 0x334C80)])
            p.ground(262, top: Color(hex: 0x6B8F4A), body: Color(hex: 0x3F5A2B))
            let towers = [(x: 64.0, v: p.facts.usage.claudeWeeklyGauges, c: Color(hex: 0xD97757), label: "Claude"),
                          (x: 176.0, v: p.facts.usage.codexWeeklyGauges, c: Color(hex: 0x10A37F), label: "Codex")]
                .filter { $0.v > 0 }
            // 블록이 너무 많으면 화면을 뚫는다 — 최대 14칸, 칸당 크기를 키운다.
            let maxV = towers.map(\.v).max() ?? 1, per = max(1, (maxV / 14).rounded(.up))
            for (ti, tw) in towers.enumerated() {
                let blocks = Int((tw.v / per).rounded(.up))
                for k in 0..<blocks {
                    let st = 0.4 + Double(k * 2 + ti) * 0.17, q = recapClamp((t - st) / 0.28)
                    guard q > 0 else { continue }
                    let ty = 262 - Double(k + 1) * 12, y = -14 + (ty + 14) * q * q
                    let fill = k == blocks - 1 ? (tw.v / per - Double(blocks - 1)) : 1
                    p.rect(tw.x - 28, y, 56, 11, .black)
                    p.rect(tw.x - 27, y + 1, 54, 9, RecapPalette.ink)
                    p.rect(tw.x - 26, y + 2, 52 * fill, 7, tw.c)
                    p.rect(tw.x - 26, y + 2, 52 * fill, 2, .white.opacity(0.33))
                    p.player.once("g\(ti)-\(k)", q >= 1) {
                        p.player.shake = max(p.player.shake, 1.5)
                        p.player.burst(tw.x + .random(in: -26...26), ty + 11, count: 4,
                                       colors: [Color(hex: 0xD8D0C0), .white], speed: 1, gravity: 0.1, life: 14)
                    }
                }
                if t > 0.4 + Double(blocks * 2) * 0.17 + 0.3 {
                    p.text(String(format: "%.1f장", tw.v), tw.x, 96, size: 18, color: tw.c, bold: true)
                }
                p.text(tw.label, tw.x, 272, size: 9)
            }
        })

    // MARK: 파트너 시상대 — 사용 시간 상위 3

    static let partner = RecapScene(
        id: "partner", duration: 8.5,
        isAvailable: { !$0.game.partners.isEmpty },
        kicker: { _ in "올해 가장 오래 걸은 펫" },
        title: { f in f.game.partners.first?.kind.displayName ?? "" },
        draw: { p, t in
            p.bands(RecapPalette.night)
            let partners = p.facts.game.partners
            let spots: [(x: Double, top: Double, w: Double, at: Double, c: Color)] = [
                (120, 220, 56, 2.4, RecapPalette.gold), (60, 236, 52, 1.4, Color(hex: 0xD0D0E0)), (180, 246, 52, 0.6, Color(hex: 0xD08A4A)),
            ]
            for (i, s) in spots.enumerated() where i < partners.count && t > s.at {
                var y = 60.0
                while y < 262 { let hw = (y - 60) * 0.28; p.rect(s.x - hw, y, hw * 2, 1, i == 0 ? RecapPalette.gold.opacity(0.2) : .white.opacity(0.08)); y += 2 }
            }
            p.rect(0, 262, 240, 98, RecapPalette.ink)
            for (i, s) in spots.enumerated() where i < partners.count {
                p.rect(s.x - s.w / 2, s.top, s.w, 262 - s.top, Color(hex: 0x3A3352))
                p.rect(s.x - s.w / 2, s.top, s.w, 3, s.c)
                p.text("\(i + 1)", s.x, s.top + 14, size: 11, color: s.c, bold: true)
                let q = recapClamp((t - s.at) / 0.35)
                guard q > 0 else { continue }
                let kind = partners[i].kind
                let bob = i == 0 && q >= 1 ? abs(sin(t * 3)) * 3 : 0
                p.pet(kind, .sit, t: t, x: s.x, y: s.top - (1 - q * q) * 180 - bob,
                      scale: fitScale(kind, target: i == 0 ? 64 : 48))
                p.player.once("pod\(i)", q >= 1) {
                    p.player.shake = i == 0 ? 5 : 2
                    p.player.burst(s.x, s.top, count: i == 0 ? 30 : 10, colors: [.white, s.c])
                    if i == 0 { p.player.confetti(70) }
                }
                if q >= 1 { p.text("\(Int(partners[i].hours).formatted())h", s.x, s.top - (i == 0 ? 70 : 52), size: 9, color: s.c) }
            }
        })

    // MARK: 숫자 장면 (연출 이식 전 자리)

    private static func stat(_ id: String, bg: [Color], isAvailable: @escaping (RecapFacts) -> Bool = { _ in true },
                             kicker: String, title: @escaping (RecapFacts) -> String,
                             duration: Double = 6) -> RecapScene {
        RecapScene(id: id, duration: duration, isAvailable: isAvailable, kicker: { _ in kicker }, title: title,
                   draw: { p, t in
                       p.bands(bg)
                       p.stars(t, color: .white.opacity(0.4))
                       p.ground(262)
                       narrator(p, t, x: 120, y: 262, action: .sit, target: 64)
                       let k = Int(t / 0.8)
                       p.player.once("fw\(k)", t > 1 && k < 5) { p.player.firework(.random(in: 30...210), .random(in: 100...170)) }
                   })
    }

    static let vs = stat("vs", bg: [Color(hex: 0x3A0F1F), Color(hex: 0x4A1428)],
                         isAvailable: { $0.game.coinsBySource.values.filter { $0 > 0 }.count >= 2 },
                         kicker: "올해의 대결",
                         title: { f in
                             let top = f.game.coinsBySource.max { $0.value < $1.value }
                             let sum = max(1, f.game.coinsBySource.values.reduce(0, +))
                             return "\(top?.key.capitalized ?? "") \(Int((Double(top?.value ?? 0) / Double(sum) * 100).rounded()))%"
                         })
    static let cursor = stat("cursor", bg: [Color(hex: 0x2A1F0F), Color(hex: 0x3A2A12), Color(hex: 0x4A3615)],
                             isAvailable: { $0.usage.cursorUSD >= 1 },
                             kicker: "Cursor에 쓴 돈", title: { f in "$\(fmt(Int(f.usage.cursorUSD.rounded())))" })
    static let grass = stat("grass", bg: [Color(hex: 0x0F2414), Color(hex: 0x13301A), Color(hex: 0x173C20)],
                            isAvailable: { $0.usage.longestStreak > 1 },
                            kicker: "최장 연속 사용", title: { f in "\(f.usage.longestStreak)일 연속" })
    static let golden = stat("golden", bg: [Color(hex: 0x5A2A4A), Color(hex: 0xD9576A), Color(hex: 0xFFB347)],
                             isAvailable: { $0.usage.goldenHour != nil },
                             kicker: "골든타임", title: { f in
                                 let wd = ["월", "화", "수", "목", "금", "토", "일"][f.usage.busiestWeekday ?? 0]
                                 return "\(f.usage.goldenHour ?? 0)시 · \(wd)요일"
                             })
    static let gacha = stat("gacha", bg: [Color(hex: 0x1B0F33), Color(hex: 0x24124A), Color(hex: 0x2E1660)],
                            isAvailable: { $0.game.pulls > 0 },
                            kicker: "알을 깬 횟수", title: { f in "\(fmt(f.game.pulls))번" }, duration: 8)
    static let gym = stat("gym", bg: [Color(hex: 0x0F2A2E), Color(hex: 0x13363B), Color(hex: 0x174249)],
                          isAvailable: { $0.game.badges > 0 || $0.game.collectionsCompleted > 0 },
                          kicker: "도장과 컬렉션", title: { f in "뱃지 \(f.game.badges)개" })
    static let arena = stat("arena", bg: [Color(hex: 0x2A1A10), Color(hex: 0x3A2414), Color(hex: 0x4A2E18)],
                            isAvailable: { $0.game.arenaWins > 0 },
                            kicker: "아레나", title: { f in "\(f.game.arenaWins)승 · 최고 \(fmt(f.game.arenaBestRating))" })
    static let life = stat("life", bg: [Color(hex: 0x1A0F1F), Color(hex: 0x22132A), Color(hex: 0x2A1735)],
                           kicker: "사소한 기록들", title: { f in "퀴즈 \(f.game.quizCorrect) · 웰니스 \(f.game.wellnessResponded)" })
    static let ending = stat("ending", bg: RecapPalette.night,
                             kicker: "TRAINER RECAP 2026", title: { f in f.game.nickname }, duration: 10)
}
