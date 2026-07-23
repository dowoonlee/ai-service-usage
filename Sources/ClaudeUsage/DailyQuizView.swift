import AppKit
import SwiftUI

// "오늘의 AI 뉴스 퀴즈" 윈도우.
//
// 흐름:
//   1) ranking opt-in 확인 (게시판/운세와 동일 게이트 — deviceId + Keychain hmacKey)
//   2) daily-quiz edge function 호출(today) — 전역 1세트: 오늘의 AI 브리핑 + 4지선다 3문항
//   3) 답 선택 → 제출(submit) → 서버 채점. 정답은 서버에만 있어 클라 조작 불가.
//   4) 코인은 서버가 reward_grants에 적재 → 다음 leaderboard 폴링의 pendingGrant로 자동 수령.
//      (즉시 "+X 코인" 표시는 예고, 실제 잔액 반영은 폴링 1회 뒤)
//
// 보상: 1/2/3문항 정답 = 100/300/1000 coin.

@MainActor
final class DailyQuizVM: ObservableObject {
    enum Phase {
        case loading
        case error(String)
        case quiz(RankingAPI.DailyQuizResponse)
    }
    @Published var phase: Phase = .loading
    /// 문항별 선택 index (nil = 미선택).
    @Published var selections: [Int?] = []
    @Published var submitting = false
    /// 방금 제출한 결과(정답 공개). 재조회로 확인한 기존 제출은 `quiz.submission`이 담당.
    @Published var justSubmitted: RankingAPI.DailyQuizSubmitResponse?

    // 서버가 KST 오늘로 강제 — 공용 `SajuEngine.kstDayFormatter`(동일 기준) 사용.
    private func todayString() -> String { SajuEngine.kstDayFormatter.string(from: Date()) }

    func load() async {
        phase = .loading
        justSubmitted = nil
        let s = Settings.shared
        let deviceId = s.rankingDeviceID
        guard !deviceId.isEmpty,
              let hmacKey = Keychain.loadRankingHmacKey(), !hmacKey.isEmpty else {
            phase = .error("랭킹 참여가 필요합니다. 설정에서 랭킹을 켜면 오늘의 퀴즈를 풀 수 있어요.")
            return
        }
        do {
            let resp = try await RankingAPI.shared.fetchDailyQuiz(
                deviceId: deviceId, hmacKeyBase64: hmacKey, date: todayString())
            selections = Array(repeating: nil, count: resp.questions.count)
            if resp.submission != nil { s.dailyQuizLastSolvedDate = Date() }  // dot 동기화
            phase = .quiz(resp)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func submit(_ quiz: RankingAPI.DailyQuizResponse) async {
        guard !submitting else { return }
        let answers = selections.compactMap { $0 }
        guard answers.count == quiz.questions.count else { return }
        submitting = true
        defer { submitting = false }
        let s = Settings.shared
        guard let hmacKey = Keychain.loadRankingHmacKey(), !hmacKey.isEmpty else { return }
        do {
            let res = try await RankingAPI.shared.submitDailyQuiz(
                deviceId: s.rankingDeviceID, hmacKeyBase64: hmacKey,
                date: todayString(), answers: answers)
            s.dailyQuizLastSolvedDate = Date()
            // 도장 Daily 카운터 — Quiz 정답 누적 + Ritual streak.
            s.dailyQuizCorrectTotal += res.correctCount
            Settings.bumpDailyRitual()
            justSubmitted = res
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}

struct DailyQuizView: View {
    @StateObject private var vm = DailyQuizVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear { Task { await vm.load() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "newspaper.fill")
                .foregroundColor(.accentColor)
            Text("오늘의 AI 퀴즈")
                .font(.headline)
            Spacer()
            Button {
                Task { await vm.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("새로고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("오늘의 AI 근황을 정리하는 중…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let msg):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(msg)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("다시 시도") { Task { await vm.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

        case .quiz(let quiz):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    briefCard(quiz)
                    if let result = resultFor(quiz) {
                        resultBanner(result)
                        questionList(quiz, result: result)
                    } else {
                        questionList(quiz, result: nil)
                        submitButton(quiz)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - 결과 소스 통합 (방금 제출 or 기존 제출)

    private struct Result {
        let correct: [Int]
        let submitted: [Int]
        let correctCount: Int
        let rewardCoins: Int
        let alreadyToday: Bool
    }

    private func resultFor(_ quiz: RankingAPI.DailyQuizResponse) -> Result? {
        if let r = vm.justSubmitted {
            return Result(correct: r.correct, submitted: r.submitted,
                          correctCount: r.correctCount, rewardCoins: r.rewardCoins,
                          alreadyToday: false)
        }
        if let sub = quiz.submission, let correct = sub.correct {
            return Result(correct: correct, submitted: sub.answers,
                          correctCount: sub.correctCount, rewardCoins: sub.rewardCoins,
                          alreadyToday: true)
        }
        return nil
    }

    // MARK: - 조각들

    private func briefCard(_ quiz: RankingAPI.DailyQuizResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("오늘의 AI 근황")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(quiz.brief)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // 지문 바로 아래 원문 링크 — 맨 아래 footer 대신 여기에 둔다.
            sourceLink(quiz)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func resultBanner(_ r: Result) -> some View {
        let coinText = r.rewardCoins > 0
            ? "+\(r.rewardCoins) 코인" : "코인 없음"
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(r.correctCount) / 3 정답 · \(coinText)")
                .font(.title3.bold())
                .foregroundColor(r.correctCount > 0 ? .accentColor : .secondary)
            Text(r.alreadyToday
                 ? "오늘은 이미 풀었어요. 내일 새 문제로 다시 만나요."
                 : (r.rewardCoins > 0
                    ? "코인은 잠시 후 잔액에 반영됩니다."
                    : "아쉽네요. 내일 다시 도전해 보세요."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func questionList(_ quiz: RankingAPI.DailyQuizResponse, result: Result?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(quiz.questions.enumerated()), id: \.offset) { qi, q in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Q\(qi + 1). \(q.question)")
                        .font(.callout.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(q.choices.enumerated()), id: \.offset) { ci, choice in
                        choiceRow(qi: qi, ci: ci, text: choice, result: result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func choiceRow(qi: Int, ci: Int, text: String, result: Result?) -> some View {
        let picked = (result?.submitted[safe: qi] ?? vm.selections[safe: qi] ?? nil) == ci
        let isAnswer = result?.correct[safe: qi] == ci
        let showResult = result != nil

        // 색상: 결과 표시 시 정답=초록, 내 오답=빨강. 풀이 중엔 선택=강조.
        let bg: Color = {
            if showResult {
                if isAnswer { return Color.green.opacity(0.18) }
                if picked { return Color.red.opacity(0.16) }
                return Color.clear
            }
            return picked ? Color.accentColor.opacity(0.18) : Color.clear
        }()
        let border: Color = {
            if showResult {
                if isAnswer { return .green }
                if picked { return .red }
                return Color.secondary.opacity(0.25)
            }
            return picked ? .accentColor : Color.secondary.opacity(0.25)
        }()

        Button {
            guard !showResult else { return }
            vm.selections[qi] = ci
        } label: {
            HStack(spacing: 8) {
                Image(systemName: markSymbol(showResult: showResult, isAnswer: isAnswer, picked: picked))
                    .foregroundColor(markColor(showResult: showResult, isAnswer: isAnswer, picked: picked))
                Text(text)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(showResult)
    }

    private func markSymbol(showResult: Bool, isAnswer: Bool, picked: Bool) -> String {
        if showResult {
            if isAnswer { return "checkmark.circle.fill" }
            if picked { return "xmark.circle.fill" }
            return "circle"
        }
        return picked ? "largecircle.fill.circle" : "circle"
    }

    private func markColor(showResult: Bool, isAnswer: Bool, picked: Bool) -> Color {
        if showResult {
            if isAnswer { return .green }
            if picked { return .red }
            return .secondary
        }
        return picked ? .accentColor : .secondary
    }

    private func submitButton(_ quiz: RankingAPI.DailyQuizResponse) -> some View {
        let allAnswered = vm.selections.allSatisfy { $0 != nil }
        return Button {
            Task { await vm.submit(quiz) }
        } label: {
            HStack {
                if vm.submitting { ProgressView().controlSize(.small) }
                Text(vm.submitting ? "채점 중…" : "제출하기")
                    .frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!allAnswered || vm.submitting)
        .help(allAnswered ? "답안을 제출합니다" : "모든 문항에 답해 주세요")
    }

    /// 지문(brief) 하단 원문 링크. URL이 유효하면 "본문으로 가기" 링크 + 출처명,
    /// 없으면 출처명만 텍스트로.
    @ViewBuilder
    private func sourceLink(_ quiz: RankingAPI.DailyQuizResponse) -> some View {
        if !quiz.sourceUrl.isEmpty, let url = URL(string: quiz.sourceUrl) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Link("본문으로 가기", destination: url)
                    .font(.caption.bold())
                if !quiz.sourceName.isEmpty {
                    Text("· \(quiz.sourceName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        } else if !quiz.sourceName.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("출처: \(quiz.sourceName)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }
}

/// 배열 범위 밖 접근 시 nil — 서버/클라 길이 불일치에도 크래시 없이 렌더.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Window Controller

@MainActor
final class QuizWindowController: NSWindowController, SingleWindowPresenting {
    static let shared = QuizWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: DailyQuizView())
        let window = NSWindow(contentViewController: host)
        window.title = "오늘의 AI 퀴즈"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 640))
        window.minSize = NSSize(width: 460, height: 480)
        window.center()
        self.init(window: window)
    }

    func present() {
        bringToFront()
    }
}
