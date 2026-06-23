import AppKit
import SwiftUI

// "오늘의 개발 운세" 윈도우.
//
// 흐름 (윈도우 열림 시 자동):
//   1) Prerequisite 검증 — ranking opt-in / GitHub 연동
//   2) 사주 결정론적 계산 (클라이언트)
//   3) fortune edge function 1회 호출 — 서버가 캐시 조회 → 미스 시 OpenAI 호출 → save → 반환
//   4) settings.dailyFortuneLastShownDate 갱신 (topBar dot 해제)
//
// OpenAI 키는 서버 환경변수에 박혀 클라이언트는 알 필요 없음.

@MainActor
final class DailyFortuneVM: ObservableObject {
    enum LoadState {
        case loading
        case showing(text: String, chart: SajuChart, daily: DailyFortune)
        case error(DailyFortuneError)
    }

    @Published var state: LoadState = .loading

    func load() async {
        state = .loading

        #if DEBUG
        // 로컬 프리뷰 — GitHub/랭킹 연동·서버 호출 없이 시각화만 확인.
        // `swift run ClaudeUsage --fortune-preview` 후 sparkles 버튼. 릴리스 빌드엔 미포함.
        if CommandLine.arguments.contains("--fortune-preview") {
            let birth = Settings.shared.githubCreatedAt.flatMap(Self.parseISO)
                ?? Date(timeIntervalSince1970: 1_433_309_400)  // 2015-06-03 14:30 KST
            let chart = SajuEngine.chart(for: birth)
            let daily = SajuEngine.daily(for: Date(), against: chart.dayStem)
            state = .showing(
                text: "오전의 리뷰 큐가 평소보다 빨리 비고, 막혔던 빌드도 한 번에 통과하는 흐름입니다. "
                    + "다만 오후 늦게 들어오는 급한 요청이 집중을 흩트릴 수 있으니 작업 단위를 잘게 쪼개 두세요. "
                    + "퇴근 전에 내일의 첫 작업을 한 줄 메모로 남겨두면 내일 아침이 한결 가볍습니다.",
                chart: chart, daily: daily
            )
            return
        }
        #endif

        let s = Settings.shared

        // 1) ranking opt-in 확인.
        let deviceId = s.rankingDeviceID
        guard !deviceId.isEmpty,
              let hmacKey = Keychain.loadRankingHmacKey(), !hmacKey.isEmpty else {
            state = .error(.missingRanking)
            return
        }

        // 2) GitHub 연동 + created_at 확인.
        //
        // 기존 연동 사용자는 토큰만 있고 githubCreatedAt 이 비어 있을 수 있음 (신규 필드).
        // 토큰만 있으면 1회 lazy fetch 로 채워준다 — 다음 호출부터는 settings 캐시 hit.
        if (s.githubCreatedAt ?? "").isEmpty, let token = Keychain.loadGitHubToken() {
            if let fetched = try? await GitHubAuth.shared.fetchUser(token: token),
               let created = fetched.createdAt, !created.isEmpty {
                s.githubCreatedAt = created
            }
        }
        guard let createdAtStr = s.githubCreatedAt, !createdAtStr.isEmpty,
              let birth = Self.parseISO(createdAtStr) else {
            state = .error(.missingGitHub)
            return
        }

        // 3) 사주 결정론적 계산 (외부 의존 0).
        let chart = SajuEngine.chart(for: birth)
        let daily = SajuEngine.daily(for: Date(), against: chart.dayStem)
        let today = Self.todayDateString()

        // 4) JSON 직렬화 — 서버에 프롬프트 변수로 전달.
        let sajuJson: String
        let dailyJson: String
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            sajuJson = String(data: try enc.encode(chart), encoding: .utf8) ?? "{}"
            dailyJson = String(data: try enc.encode(daily), encoding: .utf8) ?? "{}"
        } catch {
            state = .error(.server("사주 직렬화 실패: \(error.localizedDescription)"))
            return
        }

        // 5) edge function 단일 호출 — 서버가 캐시/OpenAI/save 모두 처리.
        do {
            let row = try await RankingAPI.shared.requestFortune(
                deviceId: deviceId, hmacKeyBase64: hmacKey, date: today,
                sajuJson: sajuJson, dailyJson: dailyJson
            )
            s.dailyFortuneLastShownDate = Date()
            state = .showing(text: row.fortuneText, chart: chart, daily: daily)
        } catch {
            state = .error(.server(error.localizedDescription))
        }
    }

    // MARK: - 헬퍼

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseISO(_ s: String) -> Date? { isoFormatter.date(from: s) }

    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = SajuEngine.kst
        return f
    }()
    private static func todayDateString() -> String { ymdFormatter.string(from: Date()) }
}

/// 사용자 에러 표현 — 메시지 + 권장 후속 액션 (설정 열기 vs 다시 시도).
enum DailyFortuneError: Equatable {
    case missingRanking
    case missingGitHub
    case server(String)

    var userMessage: String {
        switch self {
        case .missingRanking:
            return "글로벌 랭킹 옵트인이 필요합니다.\n설정에서 먼저 등록해주세요."
        case .missingGitHub:
            return "GitHub 연동이 필요합니다.\n설정에서 연결 후 다시 열어주세요."
        case .server(let m):
            return "서버 오류: \(m)"
        }
    }

    enum FixAction { case openSettings, retry }
    var fixAction: FixAction {
        switch self {
        case .missingRanking, .missingGitHub: return .openSettings
        case .server: return .retry
        }
    }
}

@MainActor
struct DailyFortuneView: View {
    @StateObject private var vm = DailyFortuneVM()
    @State private var toast: String?

    /// 말풍선 꼬리 위치 — 좌측에서 36px. 마법사 머리 위 그리고 카피 버튼은 우하단.
    private let tailOffsetX: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                header
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let msg = toast {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: 400, height: 600)
        .task { await vm.load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(AppColors.gold)  // 금색 — hud 어두운 배경에서 가장 잘 보임
            Text("오늘의 개발 운세")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text(Self.todayDisplayString())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .loading:
            loadingBlock
        case .showing(let text, let chart, let daily):
            sajuBlock(chart: chart, daily: daily)
            bubbleOnly(text: text)
                .fixedSize(horizontal: false, vertical: true)  // 텍스트 높이에 맞춤
            bottomRow(text: text, chart: chart, daily: daily)
            Spacer(minLength: 0)
        case .error(let e):
            errorBlock(e)
        }
    }

    private var loadingBlock: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("운세를 받아오는 중…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sajuBlock(chart: SajuChart, daily: DailyFortune) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                SajuPillarsGrid(chart: chart)
                Spacer(minLength: 0)
                FiveElementPentagon(
                    counts: chart.fiveElementCounts,
                    dayElement: chart.dayStem.element,
                    todayElement: daily.today.stem.element,
                    relation: daily.relation
                )
            }
            Text("오늘 일진: \(daily.today.name) · \(daily.relation.rawValue) — \(daily.relation.shortDescription)")
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.gold.opacity(0.10))
        )
    }

    /// 말풍선만 — 텍스트 높이에 맞춰 ZStack body 가 fixedSize 로 wrap.
    private func bubbleOnly(text: String) -> some View {
        ZStack(alignment: .topLeading) {
            FortuneSpeechBubble(tailOffsetFromLeft: tailOffsetX)
                .fill(Color.white.opacity(0.95))
            FortuneSpeechBubble(tailOffsetFromLeft: tailOffsetX)
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Color.black)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 22, trailing: 14))
            // bottom 는 꼬리(12px) + 여유.
        }
    }

    /// 말풍선 아래 — 좌측에 마법사, 우측에 클립보드 카피 버튼.
    private func bottomRow(text: String, chart: SajuChart, daily: DailyFortune) -> some View {
        HStack(alignment: .center, spacing: 0) {
            WizardSprite(width: 44)
                .padding(.leading, max(0, tailOffsetX - 14))  // 꼬리 중심에 마법사 중심 정렬
            Spacer()
            Button {
                copyToClipboard(text: text, chart: chart, daily: daily)
            } label: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("운세 페이지를 이미지로 클립보드에 복사")
        }
        .padding(.top, 2)
    }

    /// 클립보드용 캡처 view — 버튼/토스트 제외. light 톤 배경 + 한지 느낌 색감.
    /// hud 윈도우는 어두운 컨텍스트라 system color (.primary) 가 흰색이지만 이 캡처는
    /// 독립 light 컨텍스트로 강제 — system color 가 검은색으로 잡혀 light 배경 위에서 잘 보임.
    private func capturableContent(text: String, chart: SajuChart, daily: DailyFortune) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sajuBlock(chart: chart, daily: daily)
            bubbleOnly(text: text)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                WizardSprite(width: 44)
                    .padding(.leading, max(0, tailOffsetX - 14))
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 400, alignment: .topLeading)
        .background(Color(red: 0.98, green: 0.95, blue: 0.88))   // 한지/베이지 톤
        .environment(\.colorScheme, .light)                       // system color → 검은 글씨로
    }

    /// SwiftUI ImageRenderer (macOS 13+) 로 capturableContent 를 NSImage 로 렌더 → 클립보드.
    private func copyToClipboard(text: String, chart: SajuChart, daily: DailyFortune) {
        let renderer = ImageRenderer(content: capturableContent(text: text, chart: chart, daily: daily))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let img = renderer.nsImage else {
            showToast("이미지 렌더 실패")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.writeObjects([img]) {
            showToast("이미지가 클립보드에 복사되었어요")
        } else {
            showToast("클립보드 쓰기 실패")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeIn(duration: 0.15)) { toast = msg }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        }
    }

    @ViewBuilder
    private func errorBlock(_ e: DailyFortuneError) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: e.fixAction == .openSettings ? "gearshape.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(e.userMessage)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
            HStack(spacing: 8) {
                if e.fixAction == .openSettings {
                    Button("설정 열기") {
                        // 기존 ranking-section open notification 재사용 — App.swift 가 받아서 SettingsWindow 띄움.
                        NotificationCenter.default.post(name: .openRankingSettings, object: nil)
                        DailyFortuneWindowController.shared.dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("다시 시도") {
                        Task { await vm.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("닫기") {
                    DailyFortuneWindowController.shared.dismiss()
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy년 M월 d일"
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = SajuEngine.kst
        return f
    }()
    private static func todayDisplayString() -> String { displayFormatter.string(from: Date()) }
}

/// 말풍선 — body(라운드 사각형) + tail(아래쪽 삼각형) 한 path. ZStack 으로 fill + stroke 두 번 그림.
struct FortuneSpeechBubble: Shape {
    let tailOffsetFromLeft: CGFloat
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat

    init(tailOffsetFromLeft: CGFloat,
         cornerRadius: CGFloat = 14,
         tailWidth: CGFloat = 16,
         tailHeight: CGFloat = 12) {
        self.tailOffsetFromLeft = tailOffsetFromLeft
        self.cornerRadius = cornerRadius
        self.tailWidth = tailWidth
        self.tailHeight = tailHeight
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bodyHeight = rect.height - tailHeight
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bodyHeight)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        // 꼬리 — 좌하단 쪽, 아래 방향. tailOffsetFromLeft 는 꼬리 *왼쪽 가장자리* 위치.
        let tailX = rect.minX + tailOffsetFromLeft
        path.move(to: CGPoint(x: tailX, y: body.maxY))
        path.addLine(to: CGPoint(x: tailX + tailWidth / 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: tailX + tailWidth, y: body.maxY))
        path.closeSubpath()
        return path
    }
}

/// 마법사(WizardM) sprite — Idle strip 의 프레임을 0.4초 간격으로 순환.
/// 픽셀 아트라 `.interpolation(.none)` 으로 보간 비활성화. cellSize 16×28 비율 유지.
struct WizardSprite: View {
    let width: CGFloat
    private static let aspect: CGFloat = 28.0 / 16.0  // h/w

    var body: some View {
        let height = width * Self.aspect
        return TimelineView(.animation(minimumInterval: 0.4, paused: false)) { context in
            let frames = PetSprite.frames(for: .wizardM, action: .sit)
            if frames.isEmpty {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: height)
            } else {
                let idx = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % frames.count
                Image(nsImage: frames[idx])
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: width, height: height)
            }
        }
    }
}

@MainActor
final class DailyFortuneWindowController: NSWindowController {
    static let shared = DailyFortuneWindowController()

    convenience init() {
        let host = NSHostingController(rootView: DailyFortuneView())
        let window = NSWindow(contentViewController: host)
        window.title = "오늘의 개발 운세"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    /// 매번 호출마다 새 host 로 — `@StateObject` 가 재생성되어 load() 다시 호출.
    /// 같은 날엔 Supabase get 이 캐시 hit 이라 OpenAI 추가 호출 없음.
    func present() {
        let host = NSHostingController(rootView: DailyFortuneView())
        window?.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }
}
