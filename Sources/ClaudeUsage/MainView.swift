import SwiftUI
import Charts

// MARK: - Chart axis helpers
// 세 sparkline (Claude 5h, Cursor Ultra $, Cursor Pro requests)이 동일한 축 스타일을
// 쓰므로 chartYAxis / chartXAxis 본문을 한 자리에 모은다. 라벨 포맷만 호출부에서 조정.
fileprivate extension View {
    /// y축: 좌측 정렬, 회색 grid line + 짧은 tick + 8pt 라벨. format 으로 단위 추가.
    func sparklineYAxis(
        values: [Double],
        format: @escaping (Double) -> String
    ) -> some View {
        chartYAxis {
            AxisMarks(position: .leading, values: values) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisTick(length: 2).foregroundStyle(.secondary.opacity(0.5))
                AxisValueLabel(anchor: .trailing) {
                    if let v = value.as(Double.self) {
                        Text(format(v))
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// x축: 자동 3 tick + 8pt 날짜 라벨. format 으로 시간/날짜 단위 결정.
    func sparklineXAxis(format: Date.FormatStyle) -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisTick(length: 2).foregroundStyle(.secondary.opacity(0.5))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: format)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// chartOverlay 안에 펫 파티(WalkingCat 여러 마리)를 마운트하는 공통 블록.
    /// proxy + GeometryReader 으로 plotFrame 계산해서 각 멤버 WalkingCat 에 넘긴다.
    /// 차트 라인이 사용하는 것과 동일한 `points`를 넘겨야 펫이 plot 범위를 벗어나지 않는다.
    /// 멤버별 이펙트는 `equippedEffects` 클로저(kind→set)로 조회. wellness 말풍선은 리더(idx 0)만.
    func chartPet(
        enabled: Bool,
        points: [(Date, Double)],
        party: [PetSelection],
        equippedEffects: @escaping (PetKind) -> Set<EffectKind>,
        pct: Double?,
        anxietyAt: Double,
        bigDropThreshold: Double,
        weather: WeatherCondition = .clear,
        wellnessNudge: String? = nil,
        onDismissWellness: (() -> WellnessDismissResult)? = nil
    ) -> some View {
        chartOverlay { proxy in
            if enabled && !party.isEmpty {
                GeometryReader { geo in
                    let plotFrame = geo[proxy.plotAreaFrame]
                    ForEach(Array(party.enumerated()), id: \.element.kind) { idx, sel in
                        WalkingCat(
                            points: points,
                            proxy: proxy,
                            plotFrame: plotFrame,
                            kind: sel.kind,
                            variant: sel.variant,
                            effects: equippedEffects(sel.kind),
                            petIndex: idx,
                            partyCount: party.count,
                            mood: PetMood.from(pct: pct, anxietyAt: anxietyAt),
                            weather: weather,
                            bigDropThreshold: bigDropThreshold,
                            wellnessNudge: idx == 0 ? wellnessNudge : nil,
                            onDismissWellness: idx == 0 ? onDismissWellness : nil
                        )
                    }
                }
            }
        }
    }

    /// chartOverlay 안에 테마별 지면 장식 모티프(TerrainDecor)를 깐다.
    /// 펫보다 아래 z 에 와야 하므로 반드시 `.chartPet(...)` **앞에** 적용할 것.
    func chartTerrainDecor(enabled: Bool, theme: PetTheme) -> some View {
        chartOverlay { proxy in
            if enabled {
                GeometryReader { geo in
                    TerrainDecor(plotFrame: geo[proxy.plotAreaFrame], theme: theme)
                }
            }
        }
    }
}

/// 데이터 최댓값을 받아 보기 좋은 y-상한과 3-tick (0, ymax/2, ymax)을 계산.
/// 자릿수 절반 단위(예: 5, 50, 500)로 올림해서 chart의 y축이 들쭉날쭉하지 않도록.
fileprivate func niceYMax(dataMax: Double) -> (ymax: Double, ticks: [Double]) {
    let target = max(dataMax, 1)
    let magnitude = pow(10.0, floor(log10(target)))
    let bin = magnitude / 2
    let ymax = max(bin, (target / bin).rounded(.up) * bin)
    return (ymax, [0, ymax / 2, ymax])
}

/// pct(%) sparkline y축 상한·눈금 — 10 단위 올림 + 구간별 step. Claude/Codex 섹션이 공유.
fileprivate func pctYTicks(dataMax: Double) -> (ymax: Double, yValues: [Double]) {
    let ymax = max(10, (dataMax / 10).rounded(.up) * 10)
    let step: Double = ymax <= 30 ? 10 : (ymax <= 60 ? 20 : (ymax <= 100 ? 25 : 50))
    return (ymax, Array(stride(from: 0.0, through: ymax, by: step)))
}

/// 작은 보조 통계(라벨 + pct) — Claude/Codex 섹션이 공유.
fileprivate func smallStatView(_ label: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(label)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        Text(SectionFormat.pct(value))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}

/// reset 카운트다운 캡슐 배지 — 세 섹션(Claude/Cursor/Codex)이 공유.
private struct ResetBadge: View {
    let reset: Date
    let now: Date
    var body: some View {
        Text("⟲ " + SectionFormat.countdown(reset.timeIntervalSince(now)))
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.15)))
    }
}

extension Settings {
    /// 펫 불안 임계 — notify 임계 첫 값(%)을 0~1로, 없으면 기본 0.8. 세 섹션이 공유.
    var petAnxietyThreshold: Double {
        guard notifyEnabled, let t = notifyThresholds.first else { return 0.8 }
        return Double(t) / 100
    }
}

/// 섹션 하단 "갱신 N분 전 · 에러" 줄 — 세 섹션이 공유. Codex만 진단 버튼을 extra로 덧붙인다.
private struct SectionFooter<Extra: View>: View {
    let lastSuccess: Date?
    let now: Date
    let error: String?
    let showError: Bool
    let extra: Extra

    init(lastSuccess: Date?, now: Date, error: String?, showError: Bool,
         @ViewBuilder extra: () -> Extra) {
        self.lastSuccess = lastSuccess
        self.now = now
        self.error = error
        self.showError = showError
        self.extra = extra()
    }

    var body: some View {
        HStack {
            if let t = lastSuccess {
                Text("갱신 \(SectionFormat.relative(t, now: now))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let err = error, showError {
                Text(err).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
            }
            extra
        }
    }
}

extension SectionFooter where Extra == EmptyView {
    init(lastSuccess: Date?, now: Date, error: String?, showError: Bool) {
        self.init(lastSuccess: lastSuccess, now: now, error: error, showError: showError) { EmptyView() }
    }
}

/// Claude/Cursor 섹션이 공유하는 토글 가능 헤더.
/// 접혔을 때는 우측에 요약 게이지(또는 needsLogin/needsSetup 같은 단순 텍스트)를 표시.
@ViewBuilder
fileprivate func sectionHeader(
    title: String,
    isCollapsed: Bool,
    onToggle: @escaping () -> Void,
    planBadge: String?,
    summary: String,
    showOnlySummary: Bool,
    gaugePct: Double?
) -> some View {
    Button {
        onToggle()
    } label: {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let plan = planBadge {
                PlanBadge(text: plan)
            }
            Spacer()
            if isCollapsed {
                if showOnlySummary {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    CollapsedGauge(text: summary, pct: gaugePct)
                }
            }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

struct MainView: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject var settings = Settings.shared
    var onLogin: () -> Void
    var onSettings: () -> Void
    var onContributors: () -> Void
    var onBugReport: () -> Void
    var onDailyFortune: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topBar
            Divider().opacity(0.3)
            ClaudeSection(vm: vm, onLogin: onLogin)
            Divider().opacity(0.3)
            CursorSection(vm: vm)
            // Codex는 선택적 소스 — 한 번이라도 성공(codexCurrent != nil)했을 때만 노출.
            // 미설치/미사용자는 빈 섹션이 패널에 보이지 않게 한다.
            if vm.codexCurrent != nil {
                Divider().opacity(0.3)
                CodexSection(vm: vm)
            }
        }
        .padding(10)
        .frame(minWidth: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .cornerRadius(10)
        )
        .overlay {
            // 실제 날씨 파티클(비/눈/뇌우). clear면 렌더 안 함. 패널 둥근 모서리로 클립.
            if settings.weatherEffectEnabled, vm.weather != .clear {
                WeatherParticles(condition: vm.weather, intensity: vm.weatherIntensity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
            }
        }
    }

    private var topBar: some View {
        VStack(spacing: 4) {
            // 1줄 — 타이틀 · 화폐(코인/티켓 · RP) · 메뉴
            HStack {
                Text("Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // 코인 잔액 — 클릭하면 가챠/도감 창 열림
                Button {
                    GachaWindowController.shared.present()
                } label: {
                    HStack(spacing: 3) {
                        CoinIcon(size: 12)
                        Text("\(settings.coins)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        if settings.gachaTickets > 0 {
                            Image(systemName: "ticket.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                            Text("\(settings.gachaTickets)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                        if settings.premiumTickets > 0 {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(Rarity.mythic.color)
                            Text("\(settings.premiumTickets)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("코인 잔액 — 클릭하여 가챠 열기")
                // RP 잔액 — 클릭하면 랭킹. 랭킹 순위 보상으로 적립되는 화폐.
                Button {
                    GachaWindowController.shared.present(tab: .ranking)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.cyan)
                        Text("\(settings.rp)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.borderless)
                .help("RP — 클릭하여 랭킹 열기")
                if vm.claudeLoading || vm.cursorLoading || vm.codexLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            // 2줄 — 액션 버튼(게시판 · 운세) · 메뉴 우측 정렬
            HStack(spacing: 12) {
                Spacer()
                // 게시판 진입 — 미확인 글 수가 우상단 빨간 배지로 표시.
                Button {
                    BoardWindowController.shared.present()
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.cyan)
                        .overlay(alignment: .topTrailing) {
                            if vm.boardUnreadCount > 0 {
                                Text("\(min(vm.boardUnreadCount, 99))")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                                    .offset(x: 6, y: -4)
                            }
                        }
                }
                .buttonStyle(.borderless)
                .help(vm.boardUnreadCount > 0 ? "게시판 (미확인 \(vm.boardUnreadCount)개)" : "게시판 열기")
                // 오늘의 개발 운세 — 오늘 한 번도 안 봤으면 빨간 dot 배지.
                Button {
                    onDailyFortune()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.gold)
                        .overlay(alignment: .topTrailing) {
                            if !Calendar.current.isDateInToday(settings.dailyFortuneLastShownDate ?? .distantPast) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 4, y: -2)
                            }
                        }
                }
                .buttonStyle(.borderless)
                .help("오늘의 개발 운세")
                // 공지사항 — 확성기. 언제든 패치 공지를 다시 볼 수 있음.
                Button {
                    AnnouncementWindowController.shared.presentBrowse()
                } label: {
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.borderless)
                .help("공지사항")
                Menu {
                    Button("지금 새로고침") {
                        Task { await vm.refreshClaude(); await vm.refreshCursor(); await vm.refreshCodex() }
                    }
                    Button("업데이트 확인...") { Updater.shared.checkForUpdates() }
                    Button("설정...") { onSettings() }
                    Button("기여자 보기...") { onContributors() }
                    Button("버그 리포트...") { onBugReport() }
                    Divider()
                    Button("Claude 재로그인") { onLogin() }
                    Button("Claude 로그아웃") { vm.claudeLogout() }
                    Divider()
                    Button("종료") { onQuit() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

// MARK: - Shared helpers

enum SectionFormat {
    static func pct(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int(v.rounded()))%"
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    static func relative(_ d: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: now)
    }

    /// 차트 데이터 부족 시 표시 — 첫 폴링 직후(~5s), 윈도우 reset 직후 첫 폴링 전,
    /// fiveHourPct=0 같이 라인 그래프가 비어 보이는 케이스에 사용. 빈 영역만 두면
    /// 사용자가 "앱이 멈췄나" 혼란 가능 — 명시적 안내로 진행 상태 알림.
    @ViewBuilder
    static func chartEmptyState(_ message: String = "데이터 수집 중...") -> some View {
        HStack {
            Spacer()
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(height: 44)
    }

    static func barColor(_ v: Double?) -> Color {
        guard let v else { return .blue }
        if v >= 80 { return .red }
        if v >= 60 { return .orange }
        return .blue
    }

    // 0% 녹색 → 100% 빨강으로 hue를 선형 보간. 100% 초과는 100%로 cap.
    static func continuousColor(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        let clamped = max(0, min(100, v)) / 100
        let hue = 0.33 * (1 - clamped)
        return Color(hue: hue, saturation: 0.75, brightness: 0.9)
    }

    static func paceColor(_ projected: Double?) -> Color {
        guard let p = projected else { return .secondary }
        if p >= 100 { return .red }
        if p >= 80  { return .orange }
        return .secondary
    }

    static func thresholdLineColor(_ t: Int) -> Color {
        if t >= 100 { return .red }
        if t >= 80  { return .orange }
        return .secondary
    }

    static func paceText(projected: Double?, exhaustionAt: Date?, now: Date) -> String? {
        guard let p = projected else { return nil }
        let pInt = Int(p.rounded())
        if let exhaust = exhaustionAt {
            let remaining = exhaust.timeIntervalSince(now)
            return "예상 \(pInt)% · \(countdown(remaining)) 후 한도"
        }
        return "예상 \(pInt)%"
    }
}

// 접힌 헤더의 요약 텍스트 뒤에 사용량 비례 게이지를 깐다.
fileprivate struct CollapsedGauge: View {
    let text: String
    let pct: Double?
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.12))
                        if let p = pct {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(SectionFormat.continuousColor(p).opacity(0.45))
                                .frame(width: geo.size.width * min(1, max(0, p) / 100))
                        }
                    }
                }
            )
    }
}

struct PaceLine: View {
    var projected: Double?
    var exhaustionAt: Date?
    var now: Date
    var body: some View {
        if let text = SectionFormat.paceText(projected: projected, exhaustionAt: exhaustionAt, now: now) {
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(SectionFormat.paceColor(projected))
                .monospacedDigit()
        }
    }
}

// MARK: - Claude section

struct ClaudeSection: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject var settings = Settings.shared
    var onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !vm.claudeCollapsed {
                if vm.claudeNeedsLogin {
                    loginPrompt
                } else {
                    body5h
                    sparkline
                    footer
                }
            }
        }
    }

    private var header: some View {
        sectionHeader(
            title: "Claude",
            isCollapsed: vm.claudeCollapsed,
            onToggle: { vm.claudeCollapsed.toggle() },
            planBadge: vm.claudeCurrent?.planName,
            summary: summary,
            showOnlySummary: vm.claudeNeedsLogin,
            gaugePct: collapsedPct
        )
    }

    private var summary: String {
        if vm.claudeNeedsLogin { return "로그인 필요" }
        let a = SectionFormat.pct(vm.claudeCurrent?.fiveHourPct)
        let b = SectionFormat.pct(vm.claudeCurrent?.sevenDayPct)
        return "5h \(a) · 주간 \(b)"
    }

    private var collapsedPct: Double? {
        [vm.claudeCurrent?.fiveHourPct, vm.claudeCurrent?.sevenDayPct]
            .compactMap { $0 }
            .max()
    }

    private var loginPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("claude.ai 로그인이 필요해요")
                .font(.system(size: 11))
            Button(action: onLogin) {
                Text("로그인").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
    }

    private var body5h: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(SectionFormat.pct(vm.claudeCurrent?.fiveHourPct))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("5시간 창")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = vm.claudeCurrent?.fiveHourResetAt {
                    ResetBadge(reset: reset, now: vm.now)
                }
            }
            ProgressView(value: (vm.claudeCurrent?.fiveHourPct ?? 0) / 100)
                .progressViewStyle(.linear)
                .tint(SectionFormat.barColor(vm.claudeCurrent?.fiveHourPct))
            if settings.showPace {
                PaceLine(projected: vm.claude5hProjectedPct, exhaustionAt: vm.claude5hExhaustionAt, now: vm.now)
            }
            HStack(alignment: .top, spacing: 12) {
                smallStat("주간", vm.claudeCurrent?.sevenDayPct)
                if settings.showPace,
                   let _ = vm.claude7dProjectedPct {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("주간 페이스")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        PaceLine(projected: vm.claude7dProjectedPct, exhaustionAt: vm.claude7dExhaustionAt, now: vm.now)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func smallStat(_ label: String, _ value: Double?) -> some View { smallStatView(label, value) }


    private var sparkline: some View {
        Group {
            // 현재 5h 창에 속하는 점만 — 이전(만료) 창이 섞이면 두 세션 사이
            // 수시간 빈 구간을 가로지르는 대각선 + 색칠 튐이 생긴다. (ViewModel 헬퍼 참조)
            // fiveHourPct=0/nil 도 여기서 함께 제외된다.
            let validData: [(Date, Double)] = ViewModel.claudeFiveHourSeries(Array(vm.claudeHistory.suffix(48)))
            if validData.count >= 2 {
                let values = validData.map(\.1)
                let dataMax = values.max() ?? 0
                let (ymax, yValues) = pctYTicks(dataMax: dataMax)
                let span = validData.last!.0.timeIntervalSince(validData.first!.0)
                let tickFormat: Date.FormatStyle = span < 24 * 3600
                    ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                    : .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted))

                Chart {
                    ForEach(validData, id: \.0) { item in
                        AreaMark(
                            x: .value("t", item.0),
                            y: .value("v", item.1)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(claudeTheme.gradient(pct: vm.claudeCurrent?.fiveHourPct, threshold: petAnxietyAt))
                        LineMark(
                            x: .value("t", item.0),
                            y: .value("v", item.1)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(claudeTheme.lineColor)
                    }
                    if settings.notifyEnabled {
                        ForEach(settings.notifyThresholds.filter { Double($0) <= ymax }, id: \.self) { t in
                            RuleMark(y: .value("threshold", Double(t)))
                                .foregroundStyle(SectionFormat.thresholdLineColor(t).opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                }
                .chartYScale(domain: 0...ymax)
                .sparklineYAxis(values: yValues, format: { "\(Int($0))" })
                .sparklineXAxis(format: tickFormat)
                // 차트 라인이 그려지는 validData와 동일한 범위를 펫에 전달.
                // 다른 데이터(예: recent 0% 포함)를 넘기면 펫의 x-도메인이 차트보다 넓어져
                // plot 좌/우로 빠져나간다.
                .chartTerrainDecor(enabled: settings.petClaudeEnabled && !settings.ownedPets.isEmpty, theme: claudeTheme)
                .chartPet(
                    enabled: settings.petClaudeEnabled && !settings.ownedPets.isEmpty,
                    points: validData,
                    party: settings.petClaudeParty,
                    equippedEffects: { settings.equippedEffects[$0] ?? [] },
                    pct: vm.claudeCurrent?.fiveHourPct,
                    anxietyAt: petAnxietyAt,
                    bigDropThreshold: settings.bigDropThreshold,
                    weather: vm.weather,
                    wellnessNudge: vm.wellnessNudge,
                    onDismissWellness: { vm.dismissWellnessNudge() }
                )
                .frame(height: 44)
            } else {
                SectionFormat.chartEmptyState()
            }
        }
    }

    private var petAnxietyAt: Double { settings.petAnxietyThreshold }

    private var claudeTheme: PetTheme {
        settings.themeClaudeOverride ?? PetTheme.defaultFor(settings.petClaudeKind)
    }

    private var footer: some View {
        SectionFooter(lastSuccess: vm.claudeLastSuccess, now: vm.now,
                      error: vm.claudeError, showError: !vm.claudeNeedsLogin)
    }
}

// MARK: - Cursor section

struct CursorSection: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !vm.cursorCollapsed {
                if vm.cursorNeedsSetup {
                    setupPrompt
                } else {
                    usageBody
                    sparkline
                    footer
                }
            }
        }
    }

    private var header: some View {
        let plan = vm.cursorCurrent?.planName.flatMap { $0.isEmpty ? nil : prettyCursorPlan($0) }
        return sectionHeader(
            title: "Cursor",
            isCollapsed: vm.cursorCollapsed,
            onToggle: { vm.cursorCollapsed.toggle() },
            planBadge: plan,
            summary: summary,
            showOnlySummary: vm.cursorNeedsSetup || vm.cursorCurrent == nil,
            gaugePct: vm.cursorCurrentPct
        )
    }

    private func prettyCursorPlan(_ s: String) -> String {
        // "ultra" → "Ultra", "pro" → "Pro"
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private var summary: String {
        if vm.cursorNeedsSetup { return "앱 로그인 필요" }
        guard let c = vm.cursorCurrent else { return "–" }
        if c.plan == .ultra, let cents = c.totalCents {
            return "$\(dollars(cents)) / $400"
        }
        if let req = c.totalRequests {
            if let max = c.maxRequests, max > 0 {
                return "\(req) / \(max) req"
            }
            return "\(req) req"
        }
        return "–"
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cursor 앱에 로그인해주세요.")
                .font(.system(size: 11))
            Text("앱 설치/로그인 후 자동 연동됩니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var usageBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if let c = vm.cursorCurrent {
                    if c.plan == .ultra, let cents = c.totalCents {
                        Text("$\(dollars(cents))")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let maxC = c.maxCents, maxC > 0 {
                            Text("/ $\(Int(maxC / 100))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else if let req = c.totalRequests {
                        Text("\(req)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        if let max = c.maxRequests, max > 0 {
                            Text("/ \(max)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text("req")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let reset = vm.cursorCurrent?.resetAt {
                    ResetBadge(reset: reset, now: vm.now)
                }
            }
            if let c = vm.cursorCurrent {
                if c.plan == .ultra, let cents = c.totalCents, let maxC = c.maxCents, maxC > 0 {
                    let pct = cents / maxC
                    ProgressView(value: min(1, pct))
                        .progressViewStyle(.linear)
                        .tint(SectionFormat.barColor(pct * 100))
                } else if let req = c.totalRequests, let max = c.maxRequests, max > 0 {
                    let pct = Double(req) / Double(max)
                    ProgressView(value: min(1, pct))
                        .progressViewStyle(.linear)
                        .tint(SectionFormat.barColor(pct * 100))
                }
            }
            if settings.showPace {
                PaceLine(projected: vm.cursorProjectedPct, exhaustionAt: vm.cursorExhaustionAt, now: vm.now)
            }
        }
    }

    private func dollars(_ cents: Double) -> String {
        let d = cents / 100.0
        return d >= 100 ? String(format: "%.0f", d) : String(format: "%.2f", d)
    }

    private var sparkline: some View {
        let isUltra = (vm.cursorCurrent?.plan ?? .unknown) == .ultra
        return Group {
            if isUltra {
                ultraCumulativeChart
            } else {
                proRequestsChart
            }
        }
    }

    private func buildCumulativePoints() -> [(Date, Double)] {
        // 이전엔 (periodStart, 0) 을 prepend 했지만,
        // 첫 이벤트까지 라인이 y=0 평지가 되어 area가 텅 비어 보이는 문제 발생.
        // 차트 x-도메인은 첫 이벤트 ~ vm.now 로 자연스럽게 잡히게 함.
        let events = vm.cursorEvents.sorted { $0.timestamp < $1.timestamp }
        var points: [(Date, Double)] = []
        var running: Double = 0
        var lastTs: Date? = nil
        for e in events {
            // 동일/더 이른 timestamp 이벤트는 0-width segment를 만들어 차트가 갭처럼 렌더 →
            // 1ms씩 밀어서 strict ascending 보장.
            var ts = e.timestamp
            if let prev = lastTs, ts <= prev {
                ts = prev.addingTimeInterval(0.001)
            }
            running += e.chargedCents
            points.append((ts, running / 100.0))
            lastTs = ts
        }
        let nowTotal = (vm.cursorCurrent?.totalCents ?? running) / 100.0
        points.append((vm.now, max(running / 100.0, nowTotal)))
        return points
    }

    // Ultra: 서버 이벤트 기반 누적 $ 차트
    private var ultraCumulativeChart: some View {
        let points = buildCumulativePoints()
        return Group {
            if points.count >= 2 {
                let dataMax = (points.map(\.1).max() ?? 0)
                let (ymax, yValues) = niceYMax(dataMax: dataMax)

                let span = points.last!.0.timeIntervalSince(points.first!.0)
                let tickFormat: Date.FormatStyle = span < 24 * 3600
                    ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                    : .dateTime.month(.twoDigits).day(.twoDigits)

                let maxDollars = (vm.cursorCurrent?.maxCents ?? 0) / 100.0
                let thresholdLines: [(Int, Double)] = (settings.notifyEnabled && maxDollars > 0)
                    ? settings.notifyThresholds.compactMap { t in
                        let d = Double(t) / 100.0 * maxDollars
                        return d <= ymax ? (t, d) : nil
                      }
                    : []
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { (_, p) in
                        AreaMark(
                            x: .value("t", p.0),
                            y: .value("$", p.1)
                        )
                        // line과 동일한 stepEnd로 통일.
                        // 다른 보간이면 segment마다 사다리꼴 빈 곳이 생김.
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(cursorTheme.gradient(pct: vm.cursorCurrentPct, threshold: petAnxietyAt))
                        LineMark(
                            x: .value("t", p.0),
                            y: .value("$", p.1)
                        )
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(cursorTheme.lineColor)
                    }
                    ForEach(thresholdLines, id: \.0) { (t, d) in
                        RuleMark(y: .value("threshold", d))
                            .foregroundStyle(SectionFormat.thresholdLineColor(t).opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .chartYScale(domain: 0...ymax)
                .sparklineYAxis(values: yValues, format: { "$\(Int($0))" })
                .sparklineXAxis(format: tickFormat)
                .chartTerrainDecor(enabled: settings.petCursorEnabled && !settings.ownedPets.isEmpty, theme: cursorTheme)
                .chartPet(
                    enabled: settings.petCursorEnabled && !settings.ownedPets.isEmpty,
                    points: points,
                    party: settings.petCursorParty,
                    equippedEffects: { settings.equippedEffects[$0] ?? [] },
                    pct: vm.cursorCurrentPct,
                    anxietyAt: petAnxietyAt,
                    bigDropThreshold: settings.bigDropThreshold,
                    weather: vm.weather,
                    wellnessNudge: vm.wellnessNudge,
                    onDismissWellness: { vm.dismissWellnessNudge() }
                )
                .frame(height: 44)
            } else {
                SectionFormat.chartEmptyState()
            }
        }
    }

    // Pro/Free: 폴링 스냅샷의 request 수 기반 차트
    private var proRequestsChart: some View {
        Group {
            let recent = Array(vm.cursorHistory.suffix(96))
            // nil 또는 0 totalRequests 스냅샷 제거 (0은 라인을 y=0 평지로 만들어 AreaMark가 텅 빔).
            // 같은 초 중복 폴은 ForEach(id: \.0) id 충돌로 삼각형 노치를 만드므로 합친다.
            let validData: [(Date, Double)] = ViewModel.dedupAdjacentByTime(recent.compactMap { s in
                s.totalRequests.flatMap { v in v > 0 ? (s.takenAt, Double(v)) : nil }
            })
            if validData.count >= 2 {
                let dataMax = (validData.map(\.1).max() ?? 0)
                let (ymax, yValues) = niceYMax(dataMax: dataMax)

                let span = validData.last!.0.timeIntervalSince(validData.first!.0)
                let tickFormat: Date.FormatStyle = span < 24 * 3600
                    ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                    : .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted))

                let maxReq = Double(vm.cursorCurrent?.maxRequests ?? 0)
                let thresholdLines: [(Int, Double)] = (settings.notifyEnabled && maxReq > 0)
                    ? settings.notifyThresholds.compactMap { t in
                        let r = Double(t) / 100.0 * maxReq
                        return r <= ymax ? (t, r) : nil
                      }
                    : []
                Chart {
                    ForEach(validData, id: \.0) { item in
                        AreaMark(
                            x: .value("t", item.0),
                            y: .value("v", item.1)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(cursorTheme.gradient(pct: vm.cursorCurrentPct, threshold: petAnxietyAt))
                        LineMark(
                            x: .value("t", item.0),
                            y: .value("v", item.1)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(cursorTheme.lineColor)
                    }
                    ForEach(thresholdLines, id: \.0) { (t, r) in
                        RuleMark(y: .value("threshold", r))
                            .foregroundStyle(SectionFormat.thresholdLineColor(t).opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .chartYScale(domain: 0...ymax)
                .sparklineYAxis(values: yValues, format: { "\(Int($0))" })
                .sparklineXAxis(format: tickFormat)
                .chartTerrainDecor(enabled: settings.petCursorEnabled && !settings.ownedPets.isEmpty, theme: cursorTheme)
                .chartPet(
                    enabled: settings.petCursorEnabled && !settings.ownedPets.isEmpty,
                    points: validData,
                    party: settings.petCursorParty,
                    equippedEffects: { settings.equippedEffects[$0] ?? [] },
                    pct: vm.cursorCurrentPct,
                    anxietyAt: petAnxietyAt,
                    bigDropThreshold: settings.bigDropThreshold,
                    weather: vm.weather,
                    wellnessNudge: vm.wellnessNudge,
                    onDismissWellness: { vm.dismissWellnessNudge() }
                )
                .frame(height: 44)
            } else {
                SectionFormat.chartEmptyState()
            }
        }
    }

    private var petAnxietyAt: Double { settings.petAnxietyThreshold }

    private var cursorTheme: PetTheme {
        settings.themeCursorOverride ?? PetTheme.defaultFor(settings.petCursorKind)
    }

    private var footer: some View {
        SectionFooter(lastSuccess: vm.cursorLastSuccess, now: vm.now,
                      error: vm.cursorError, showError: !vm.cursorNeedsSetup)
    }
}

// MARK: - Codex section
//
// PR2(표시) — 펫 차트/코인 적립 없이 게이지+스파크라인만. 펫·경제 통합은 PR3.
// 주력 창: Plus/Pro는 5h, free는 monthly (ViewModel.codexPrimary*).

struct CodexSection: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !vm.codexCollapsed {
                usageBody
                sparkline
                footer
            }
        }
    }

    private var header: some View {
        sectionHeader(
            title: "Codex",
            isCollapsed: vm.codexCollapsed,
            onToggle: { vm.codexCollapsed.toggle() },
            planBadge: vm.codexCurrent?.planName.map(prettyPlan),
            summary: summary,
            showOnlySummary: false,
            gaugePct: collapsedPct
        )
    }

    private func prettyPlan(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    private var summary: String {
        guard vm.codexCurrent != nil else { return "–" }
        if vm.codexUsesFiveHour {
            return "5h \(SectionFormat.pct(vm.codexCurrent?.fiveHourPct)) · 주간 \(SectionFormat.pct(vm.codexCurrent?.sevenDayPct))"
        }
        return "월간 \(SectionFormat.pct(vm.codexCurrent?.monthlyPct))"
    }

    private var collapsedPct: Double? {
        [vm.codexCurrent?.fiveHourPct, vm.codexCurrent?.sevenDayPct, vm.codexCurrent?.monthlyPct]
            .compactMap { $0 }.max()
    }

    private var usageBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(SectionFormat.pct(vm.codexPrimaryPct))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(vm.codexPrimaryLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = vm.codexPrimaryResetAt {
                    ResetBadge(reset: reset, now: vm.now)
                }
            }
            ProgressView(value: min(1, (vm.codexPrimaryPct ?? 0) / 100))
                .progressViewStyle(.linear)
                .tint(SectionFormat.barColor(vm.codexPrimaryPct))
            if settings.showPace {
                PaceLine(projected: vm.codexPrimaryProjectedPct, exhaustionAt: vm.codexPrimaryExhaustionAt, now: vm.now)
            }
            // 보조 창 — Plus/Pro의 주간(7d). free는 monthly 단일이라 생략.
            if vm.codexUsesFiveHour {
                HStack(alignment: .top, spacing: 12) {
                    smallStat("주간", vm.codexCurrent?.sevenDayPct)
                    if settings.showPace, vm.codex7dProjectedPct != nil {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("주간 페이스")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            PaceLine(projected: vm.codex7dProjectedPct, exhaustionAt: vm.codex7dExhaustionAt, now: vm.now)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func smallStat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(SectionFormat.pct(value))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private var sparkline: some View {
        Group {
            // codexPrimarySeries: 5h(Plus/Pro) 또는 monthly(free)를 현재 창으로 필터한 시계열.
            let validData = ViewModel.codexPrimarySeries(Array(vm.codexHistory.suffix(48)))
            if validData.count >= 2 {
                let values = validData.map(\.1)
                let dataMax = values.max() ?? 0
                let (ymax, yValues) = pctYTicks(dataMax: dataMax)
                let span = validData.last!.0.timeIntervalSince(validData.first!.0)
                let tickFormat: Date.FormatStyle = span < 24 * 3600
                    ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                    : .dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted))
                Chart {
                    ForEach(validData, id: \.0) { item in
                        AreaMark(x: .value("t", item.0), y: .value("v", item.1))
                            .interpolationMethod(.linear)
                            .foregroundStyle(codexTheme.gradient(pct: vm.codexPrimaryPct, threshold: petAnxietyAt))
                        LineMark(x: .value("t", item.0), y: .value("v", item.1))
                            .interpolationMethod(.linear)
                            .foregroundStyle(codexTheme.lineColor)
                    }
                    if settings.notifyEnabled {
                        ForEach(settings.notifyThresholds.filter { Double($0) <= ymax }, id: \.self) { t in
                            RuleMark(y: .value("threshold", Double(t)))
                                .foregroundStyle(SectionFormat.thresholdLineColor(t).opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                    }
                }
                .chartYScale(domain: 0...ymax)
                .sparklineYAxis(values: yValues, format: { "\(Int($0))" })
                .sparklineXAxis(format: tickFormat)
                .chartTerrainDecor(enabled: settings.petCodexEnabled && !settings.ownedPets.isEmpty, theme: codexTheme)
                .chartPet(
                    enabled: settings.petCodexEnabled && !settings.ownedPets.isEmpty,
                    points: validData,
                    party: settings.petCodexParty,
                    equippedEffects: { settings.equippedEffects[$0] ?? [] },
                    pct: vm.codexPrimaryPct,
                    anxietyAt: petAnxietyAt,
                    bigDropThreshold: settings.bigDropThreshold,
                    weather: vm.weather,
                    wellnessNudge: vm.wellnessNudge,
                    onDismissWellness: { vm.dismissWellnessNudge() }
                )
                .frame(height: 44)
            } else {
                SectionFormat.chartEmptyState()
            }
        }
    }

    private var footer: some View {
        SectionFooter(lastSuccess: vm.codexLastSuccess, now: vm.now,
                      error: vm.codexError, showError: !vm.codexNeedsSetup)
    }

    private var petAnxietyAt: Double { settings.petAnxietyThreshold }
    private var codexTheme: PetTheme {
        settings.themeCodexOverride ?? PetTheme.defaultFor(settings.petCodexKind)
    }
}

struct PlanBadge: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.15))
            )
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
