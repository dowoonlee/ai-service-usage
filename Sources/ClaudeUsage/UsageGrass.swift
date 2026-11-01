import SwiftUI
import AppKit

// ============================================================================
// 사용량 잔디 — 리포트 탭 "이번 달" (cf. docs/plans/seasonal-events.md §17)
// ============================================================================
//
// GitHub 잔디처럼 하루 한 칸, 농도는 그날 VP. 창은 **캘린더 월·KST** — 랭킹 보드가 이번 달 누적
// 기준이라 "숫자의 합 = 잔디의 합"이 성립하고, 서버 일일 보상·퀴즈와 날짜 경계가 같다.
// 방향은 GitHub식(열=주)이 아니라 달력식(열=요일 월~일, 행=주) — 한 달 창엔 이쪽이 읽힌다.
//
// 순수 계산은 `UsageGrassModel`(nonisolated, 테스트 대상), 그리기는 `UsageGrassView`.
// 시즌(눈 장식·보상 마크)은 View의 선택 인자로 얹는다 — 잔디 자체는 시즌과 무관한 상시 기능.

/// 한 달치 잔디의 순수 모델.
struct UsageGrassModel: Equatable {
    struct Cell: Equatable, Identifiable {
        /// 1...말일. nil이면 달력 앞뒤의 빈 칸.
        let day: Int?
        let key: String?
        /// 0 = 사용 없음 / 1~4 = 사분위 농도. 미래·빈 칸은 0.
        let level: Int
        let vp: Double
        let isToday: Bool
        let isFuture: Bool
        /// 행×7 + 열 — 빈 칸도 고유해야 ForEach가 안정적.
        let id: Int
    }

    let year: Int
    let month: Int
    /// 7칸씩 끊은 주 단위 행. 월요일 시작.
    let weeks: [[Cell]]
    let totalVP: Int
    let activeDays: Int
    /// 1일부터 오늘까지의 일수.
    let elapsedDays: Int

    // MARK: - 날짜 키

    /// KST `yyyy-MM-dd`. `Settings.dailyVP`의 키이자 서버 보상 grant_key의 날짜 부분과 같은 경계.
    nonisolated static func dayKey(_ date: Date) -> String {
        SajuEngine.kstDayFormatter.string(from: date)
    }

    nonisolated static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    // MARK: - 농도

    /// GitHub과 같은 사분위 — 본인 최근 값의 최대 대비. 절대값으로 두면 Max 20x만 진하고 Pro는 평생
    /// 연두색이다. `max <= 0`이면(아직 아무것도 없음) 양수 값은 전부 최상위로 — 첫날부터 불이 켜져야 한다.
    nonisolated static func level(vp: Double, max: Double) -> Int {
        guard vp > 0 else { return 0 }
        guard max > 0 else { return 4 }
        let q = vp / max
        if q < 0.25 { return 1 }
        if q < 0.50 { return 2 }
        if q < 0.75 { return 3 }
        return 4
    }

    /// 사분위 기준값 — `now`를 포함한 최근 `window`일의 최대 VP(이번 달 밖의 날도 포함).
    nonisolated static func recentMax(dailyVP: [String: Double], now: Date, window: Int = 30,
                                      calendar: Calendar = .kst) -> Double {
        var best = 0.0
        for offset in 0..<window {
            guard let d = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            best = Swift.max(best, dailyVP[dayKey(d)] ?? 0)
        }
        return best
    }

    // MARK: - 빌드

    nonisolated static func build(dailyVP: [String: Double], now: Date, calendar: Calendar = .kst) -> UsageGrassModel {
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 1970, month = comps.month ?? 1, today = comps.day ?? 1
        let dayCount = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        // 1일의 요일 → 월요일 기준 선행 빈 칸 수.
        let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
        let weekday = calendar.component(.weekday, from: firstOfMonth)         // 1=일 … 7=토
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let maxVP = recentMax(dailyVP: dailyVP, now: now, calendar: calendar)

        var cells: [Cell] = []
        var total = 0.0, active = 0
        for i in 0..<leading {
            cells.append(Cell(day: nil, key: nil, level: 0, vp: 0, isToday: false, isFuture: false, id: i))
        }
        for day in 1...dayCount {
            let key = dayKey(year: year, month: month, day: day)
            let future = day > today
            let vp = future ? 0 : (dailyVP[key] ?? 0)
            if !future {
                total += vp
                if vp > 0 { active += 1 }
            }
            cells.append(Cell(day: day, key: key, level: future ? 0 : level(vp: vp, max: maxVP),
                              vp: vp, isToday: day == today, isFuture: future, id: cells.count))
        }
        while cells.count % 7 != 0 {
            cells.append(Cell(day: nil, key: nil, level: 0, vp: 0, isToday: false, isFuture: false, id: cells.count))
        }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
        return UsageGrassModel(year: year, month: month, weeks: weeks,
                               totalVP: Int(total.rounded()), activeDays: active, elapsedDays: today)
    }
}

// MARK: - 테마 → 농도 5단계

extension PetTheme {
    /// 잔디 농도 색 5단계(0 = 없음, 1~4 = 옅음→진함). 현재 맵 테마의 라인 색에서 색상·채도를 가져와
    /// 밝기만 올린다 — 잔디밭이면 GitHub과 비슷한 녹색, 벚꽃이면 분홍. 메뉴바·차트가 `fillStops`로
    /// 테마를 공유하는 것과 같은 방식이라 테마를 사면 잔디도 따라온다.
    var grassLevels: [Color] {
        let ns = NSColor(lineColor).usingColorSpace(.deviceRGB) ?? NSColor.gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // 뇌우(0.22)·설산(0.35)처럼 채도가 낮은 테마는 단계가 회색으로 뭉개져 하한을 둔다.
        let sat = Swift.max(0.40, Double(s))
        let steps: [Double] = [0.34, 0.48, 0.64, 0.82]
        return [Color.secondary.opacity(0.18)] + steps.map { Color(hue: Double(h), saturation: sat, brightness: $0) }
    }
}

// MARK: - View

/// 리포트 탭 "이번 달" — 왼쪽 숫자, 오른쪽 달력식 잔디, 아래 범례.
struct UsageGrassView: View {
    let model: UsageGrassModel
    let theme: PetTheme
    let streak: Int
    /// 시즌 보상 마크(날짜 키 → 마크). 시즌 밖·미참여면 비어 있다. (docs §17 "보상 표시")
    var rewardMarks: [String: RewardMark] = [:]
    /// 시즌 보상 구간의 총 일수(예: 24). 마크가 있을 때만 "보상 N/24" 통계가 붙는다.
    var rewardDayCount: Int? = nil
    /// 불 켜진 셀 위의 시즌 장식(눈 등). nil이면 없음.
    var decoration: GrassDecoration? = nil

    enum RewardMark: Equatable { case received, pending }

    static let cellSize: CGFloat = 18
    static let cellGap: CGFloat = 3
    private static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 28) {
                stats.frame(width: 190, alignment: .leading)
                grid
                Spacer(minLength: 0)
            }
            legend
        }
    }

    // MARK: 숫자

    private var receivedCount: Int { rewardMarks.values.filter { $0 == .received }.count }

    private var stats: some View {
        let levels = theme.grassLevels
        return VStack(alignment: .leading, spacing: 10) {
            Text("이번 달 · \(model.month)월")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                stat("VP", "\(model.totalVP.formatted())", nil)
                stat("활동 일수", "\(model.activeDays)", "/ \(model.elapsedDays)일")
                stat("스트릭", "\(streak)", "일")
                if let n = rewardDayCount {
                    stat("보상", "\(receivedCount)", "/ \(n)", color: levels[4])
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String?, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(color ?? .primary)
                if let unit {
                    Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 격자

    private var grid: some View {
        let levels = theme.grassLevels
        return VStack(alignment: .leading, spacing: Self.cellGap) {
            HStack(spacing: Self.cellGap) {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { i, name in
                    Text(name)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(i == 6 ? Color.red.opacity(0.7) : Color.secondary)
                        .frame(width: Self.cellSize, height: 12)
                }
            }
            ForEach(Array(model.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: Self.cellGap) {
                    ForEach(week) { cell in cellView(cell, levels: levels) }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: UsageGrassModel.Cell, levels: [Color]) -> some View {
        if cell.day == nil {
            Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
        } else {
            let mark = cell.key.flatMap { rewardMarks[$0] }
            RoundedRectangle(cornerRadius: 3)
                .fill(cell.isFuture ? Color.secondary.opacity(0.08) : levels[cell.level])
                .frame(width: Self.cellSize, height: Self.cellSize)
                .overlay(alignment: .top) {
                    // 시즌 장식 — 불 켜진 셀 위에 눈 2~3px. 16pt 아래 셀에선 안 보여 크기를 고정한다.
                    if decoration == .snow, cell.level >= 1 {
                        HStack(spacing: 1) {
                            Rectangle().fill(.white).frame(width: 9, height: 3)
                            Rectangle().fill(.white).frame(width: 3, height: 2)
                        }
                        .padding(.leading, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if mark == .received {
                        Circle().fill(Color(red: 0.90, green: 0.33, blue: 0.24))
                            .frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                            .padding(2)
                    }
                }
                .overlay {
                    if cell.isToday {
                        RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.75), lineWidth: 1)
                    } else if mark == .pending {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .foregroundStyle(Color.primary.opacity(0.55))
                    }
                }
                .help(tooltip(cell, mark: mark))
        }
    }

    private func tooltip(_ cell: UsageGrassModel.Cell, mark: RewardMark?) -> String {
        guard let day = cell.day else { return "" }
        var parts = ["\(model.month)/\(day)"]
        if cell.isFuture { return parts[0] }
        parts.append("\(Int(cell.vp.rounded()).formatted()) VP")
        switch mark {
        case .received: parts.append("보상 수령")
        case .pending:  parts.append("보상 도착 예정")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 범례

    private var legend: some View {
        let levels = theme.grassLevels
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("적음")
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(levels[i]).frame(width: 9, height: 9)
                    }
                }
                Text("많음")
            }
            if rewardDayCount != nil {
                HStack(spacing: 4) {
                    Circle().fill(Color(red: 0.90, green: 0.33, blue: 0.24)).frame(width: 5, height: 5)
                    Text("보상 수령")
                }
                Text("점선 = 도착 대기")
            }
            Text("테두리 = 오늘")
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}
