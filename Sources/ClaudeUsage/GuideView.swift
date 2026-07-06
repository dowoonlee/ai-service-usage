import AppKit
import SwiftUI

/// 인앱 사용 가이드 — 공지사항(확성기) 옆 책 아이콘으로 진입.
/// 좌측 기능 목록(사이드바) + 우측 스크롤 상세. 콘텐츠는 `GuideCatalog`에 기능별로 분리.
/// 공지 창과 동일하게 전용 NSWindow(`GuideWindowController`) 단일 인스턴스로 띄운다.
struct GuideView: View {
    var onClose: () -> Void

    @State private var selectedID: String = GuideCatalog.sections.first!.id

    private var selected: GuideSection {
        GuideCatalog.sections.first { $0.id == selectedID } ?? GuideCatalog.sections[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 178)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                Divider()
                detail
            }
            .frame(height: 432)
        }
        .frame(width: 660)
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(.blue)
            Text("AIUsage 가이드")
                .font(.headline)
            Spacer()
            Button("닫기") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 사이드바 (기능 목록)

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(GuideCatalog.sections) { section in
                    sidebarRow(section)
                }
            }
            .padding(8)
        }
    }

    private func sidebarRow(_ section: GuideSection) -> some View {
        let isSelected = section.id == selectedID
        return Button {
            selectedID = section.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.white : section.tint)
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 상세

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: selected.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(selected.tint)
                    Text(selected.title)
                        .font(.title3.weight(.semibold))
                }
                if !selected.summary.isEmpty {
                    Text(selected.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, 2)
                GuideBody(text: selected.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        // 섹션 전환 시 스크롤을 맨 위로 — id를 바꿔 뷰를 새로 그린다.
        .id(selectedID)
    }
}

/// 가이드 본문 렌더러 — 아주 가벼운 마크다운.
///   `## ` 소제목 / `- ` 불릿 / 빈 줄 간격 / 그 외 문단. 인라인은 `**굵게**`.
private struct GuideBody: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 3)
                } else if line.hasPrefix("## ") {
                    Text(Self.md(String(line.dropFirst(3))))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.md(String(line.dropFirst(2))))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(Self.md(line))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 인라인 마크다운만(굵게 등). 실패 시 원문.
    private static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - 콘텐츠 모델 + 카탈로그

struct GuideSection: Identifiable {
    let id: String
    let title: String
    let icon: String        // SF Symbol
    let tint: Color
    let summary: String     // 상세 상단 한 줄 요약
    let body: String        // 가벼운 마크다운
}

enum GuideCatalog {
    static let sections: [GuideSection] = [
        GuideSection(
            id: "usage", title: "사용량 대시보드", icon: "chart.xyaxis.line", tint: .green,
            summary: "Claude·Cursor·Codex 구독 사용량을 한 패널에서 한눈에 봅니다.",
            body: """
        패널의 각 카드는 한 서비스를 나타냅니다. 카드에는 **현재 사용률(%)**, **리셋까지 남은 시간**, 그리고 최근 사용량을 그린 **미니 차트**가 함께 표시됩니다.

        ## 서비스별 기준
        - **Claude** — 5시간 창과 7일 창을 함께 추적합니다. 각각 별도로 리셋됩니다.
        - **Cursor** — Pro는 요청 수, Ultra는 사용 금액($) 기준으로 사용률을 계산합니다.
        - **Codex** — Plus/Pro는 5시간 창, Free는 월간 한도 기준입니다.

        ## 소진 페이스 예측
        지금까지의 사용 속도를 직선으로 연장해 **언제 100%에 도달할지**를 추정해 보여줍니다. 창이 막 시작돼 데이터가 충분하지 않으면(초반 구간) 노이즈를 피하려고 예측을 띄우지 않습니다.

        ## 갱신
        기본 10분(600초)마다 자동으로 새로고침합니다. 즉시 갱신하려면 우측 상단 **⋯ 메뉴 → "지금 새로고침"**.

        > 세 서비스 모두 공식 API가 아닌 비공식 경로로 수집하므로, 서비스 쪽 변경으로 일시적으로 값이 안 맞을 수 있습니다.
        """),

        GuideSection(
            id: "menubar", title: "메뉴바 위젯", icon: "menubar.rectangle", tint: .orange,
            summary: "상단 메뉴바에서 펫이 미니 차트 위를 산책하며 사용률을 보여줍니다.",
            body: """
        **설정 → 메뉴바 표시**를 켜면 화면 상단 메뉴바에 미니 위젯이 나타납니다. 패널을 닫아도 위젯은 계속 떠 있어 상시 지표로 쓸 수 있습니다.

        ## 구성
        - **사용률 %** + 미니 라인 차트
        - **펫** — 차트 라인 위를 좌우로 산책합니다. 사용률이 높을수록 빨라지고, 가파른 구간에선 구르거나 환호하는 연출이 나옵니다.
        - **동적 맵 테마** — 동적 테마를 쓰면 사용량에 따라 메뉴바 배경도 눈·용암·심해처럼 차오릅니다(인앱 차트와 동일).
        - **이로치(반짝이)** — 파티 리더가 이로치면 메뉴바 펫에도 같은 색조가 입혀집니다.

        ## 표시 소스
        Claude·Cursor·Codex 중 어느 것을 메뉴바에 띄울지 설정에서 고를 수 있습니다. 표시되는 펫과 테마는 그 소스 **파티의 리더(맨 왼쪽 펫)** 기준입니다.
        """),

        GuideSection(
            id: "coins", title: "코인 · VP · RP", icon: "dollarsign.circle.fill", tint: AppColors.gold,
            summary: "코인은 게임 재화, VP는 랭킹 점수, RP는 랭킹 보상 화폐입니다.",
            body: """
        AIUsage를 쓰는 것만으로 포인트가 적립됩니다.

        ## 코인 (게임 재화)
        가챠 뽑기, 테마 구매, **길드**(생성권·가구·장식) 등에 쓰는 재화입니다. 적립원은 모두 **실제 사용량에 비례**합니다.
        - **Claude** — 5시간/7일 창의 사용률 증가분에 비례해 적립(플랜이 높을수록 배율↑).
        - **Cursor** — Ultra 플랜의 사용 금액(이벤트)에 비례해 적립.
        - **Codex** — 5시간/7일/월간 창의 사용률 증가분에 비례해 적립.
        - **웰니스 넛지** — 휴식 알림에 빨리 반응할수록 보너스가 커집니다.

        ## VP (랭킹 포인트)
        글로벌 랭킹 보드의 점수입니다. 코인과는 **별도 원장**으로 관리됩니다.

        ## RP (랭킹 보상 화폐)
        월간·주간 랭킹 순위 정산으로 참여자 전원에게 지급되는 보상 화폐입니다. **코스메틱 이펙트**와 **프리미엄 가챠권(sudo pull)** 구매에 씁니다.

        > 적립은 폴링(기본 10분)마다 계산됩니다. 잠자기(sleep) 동안 쌓인 시간은 과적립을 막기 위해 상한을 둡니다.
        """),

        GuideSection(
            id: "pets", title: "펫 & 가챠", icon: "pawprint.fill", tint: .pink,
            summary: "84마리 펫을 가챠로 모으고, 파티를 꾸려 차트 위를 산책시킵니다.",
            body: """
        ## 가챠
        - 총 **84마리**, 5등급(**Mythic**·레전더리·에픽·레어·커먼). 각 펫은 이로치(반짝이) 3단계 + 최상위 **레인보우 레어** 색 변형이 있습니다.
        - 뽑기는 1회 **300코인** 고정, 10연차는 1회가 보너스로 무료입니다(9회 값).
        - 뽑은 펫은 도감에 모입니다.

        ## 가챠 확률 (코인 가챠)
        - 레전더리 — **2%**
        - 에픽 — **8%**
        - 레어 — **30%**
        - 커먼 — **60%**
        - Mythic — **0%** (코인 가챠에서는 나오지 않습니다)

        ## 프리미엄 가챠권 (sudo pull)
        RP **1,500**으로 구매하는 특별 티켓입니다. **Mythic 15% / 레전더리 85%** 제한 풀에서 뽑아 꽝이 없습니다. 도장 **지역 마스터** 보상으로도 1장씩 받습니다.

        ## Mythic 펫
        1.5배 크기에 시그니처 오라·특수 모션·전용 대사가 있고, 마우스를 갖다 대면 도망가는 대신 도발합니다.

        ## 파티 산책
        - 보유 펫 최대 3마리로 **파티 프리셋**을 만들어 Claude·Cursor·Codex 차트에 각각 할당합니다.
        - 프리셋 슬롯은 기본 3개, 코인으로 늘릴 수 있습니다.
        - **리더(맨 왼쪽)** 펫이 메뉴바 위젯에 표시됩니다.

        ## 이로치 해금
        같은 펫을 중복으로 뽑거나 오래 데리고 다니면(두 경로 합산) 이로치 1~3단계가 차례로 해금됩니다. 만렙 이후 초과분은 **이로치 조각**으로 쌓이고, 조각 33개로 최상위 **레인보우 레어**(무지개 순환색) 해금에 도전할 수 있습니다 — 성공률 15%, 10번째 시도는 확정 성공.

        ## 코스메틱 이펙트
        오라·트레일·파티클 등 이펙트를 **RP**로 구매해 펫에 장착합니다. 종류(빛/궤적/입자)별로 1개씩만 장착됩니다.

        ## 펫 컬렉션 (세트 보너스)
        펫들은 개발 밈 테마의 컬렉션으로 묶여 있습니다. 한 컬렉션의 기본 펫을 모두 모으면 **일회성 보너스 코인**과 업적 카드가 열립니다.
        """),

        GuideSection(
            id: "gym", title: "도장 (Gym)", icon: "trophy.fill", tint: AppColors.gold,
            summary: "사용량·행동 목표를 달성해 지역별 도장(뱃지)을 모읍니다.",
            body: """
        도장은 지역(region)별로 나뉘고, 각 지역은 여러 카테고리 × **4단계**로 구성됩니다.

        ## 단계
        모든 카테고리는 4단계를 거칩니다: **localhost → dev → staging → production**. 단계마다 임계값이 높아지고, 클리어하면 코인을 받습니다(production이 가장 큼).

        ## 지역
        - **Coffee · Vibe · Cron · Repo · Registry** 5개 지역.
        - 예) **Vibe** 지역은 Claude·Cursor·Codex 누적 사용, **Cron**은 연속 사용일/심야 사용 등 행동 기반입니다.
        - 자기 플랜에서 불가능한 카테고리(예: Cursor 미사용)는 진행도 분모에서 제외됩니다.

        ## 보상
        - 한 지역의 도장을 전부 클리어 → **지역 마스터**: 프리미엄 가챠권 1장.
        - 가능한 모든 도장을 전부 클리어 → **챔피언** 코인 보너스.
        """),

        GuideSection(
            id: "ranking", title: "랭킹", icon: "list.number", tint: .blue,
            summary: "원하면 글로벌 리더보드에 참여해 다른 트레이너와 순위를 겨룹니다.",
            body: """
        랭킹은 **옵트인(선택)** 기능입니다. 참여하지 않아도 앱의 모든 기능은 정상 동작합니다.

        ## 참여 방법
        - **설정 → 랭킹**에서 처리방침에 동의하고 **닉네임**을 등록하면 참여가 시작됩니다.
        - 수집되는 개인정보는 **닉네임**뿐입니다(디바이스 식별자는 익명 UUID). 언제든 **계정 삭제**로 모든 데이터를 지울 수 있습니다.

        ## 보드 & 보상
        - 월간 보드로 운영되며, 상위권은 **금·은·동 메달**이 누적됩니다.
        - 이전 달 시상대(Top 3)는 명예의 전당에 동결되고, 우승자는 **시상대 한마디**를 남길 수 있습니다.
        - 월간·주간 순위 정산으로 참여자 **전원**이 RP를 받습니다(순위가 높을수록 큼). Top 3는 코인 보상도 추가로 받습니다.

        ## 기기 이전 / 복구
        - 등록 시 발급되는 **복구 코드**로 다른 기기에서 계정을 이어받을 수 있습니다.
        - **GitHub 연동**으로도 복구할 수 있습니다.
        """),

        GuideSection(
            id: "guild", title: "길드", icon: "shield.lefthalf.filled", tint: .teal,
            summary: "트레이너들과 팀을 만들어 길드 랭킹에 도전하고, 함께 사무실을 꾸밉니다.",
            body: """
        길드는 **트레이너들의 팀**입니다. 랭킹에 참여 중이면 **길드 탭**에서 이용할 수 있고, 한 사람은 **한 길드**에만 속합니다.

        ## 만들기 & 가입
        - **길드 창설** — 상점에서 **생성권(3,000코인)**을 사서 길드를 만듭니다. 만든 사람이 길드장이 됩니다.
        - **초대 코드 가입** — 길드장이 발급한 **8자리 코드**를 입력해 가입합니다.
        - 탈퇴·추방 후에는 **7일 쿨다운** 동안 다른 길드에 가입하거나 새로 만들 수 없습니다.

        ## 길드 점수 & 보상
        - 길드 점수 = 멤버 중 이번 달 **VP 상위 5명의 합산**입니다.
        - 매달 **Top 3 길드**의 기여 멤버(이번 달 VP > 0) 전원에게 RP를 드립니다 — **1·2·3위 500·300·200 RP**.
        - 길드 순위와 직전 달 길드 시상대는 **랭킹 탭 → "길드"** 스코프에서 봅니다.

        ## 길드 사무실
        멤버들의 **대표 펫**이 돌아다니는 공유 공간입니다.
        - 멤버 자리는 **자동 배치**됩니다(수동 지정 없음). 펫들은 사무실을 자유롭게 돌아다니고, 이번 달 기여 상위 멤버는 자리에서 작업하는 모션을 보입니다.
        - **사무실 상점**에서 가구·장식·테마를 삽니다. 항목을 고르면 씬에 **미리보기**가 뜨고, "구매"를 눌러야 결제됩니다.
          - **가구**(바닥·벽) — 사서 **드래그로 자유 배치**. 벽 가구(시계·액자·화이트보드)는 벽 안에서 위치를 옮길 수 있고, 액자는 클릭해 문구를 넣을 수 있습니다.
          - **장식** — 멤버 누구나 기부할 수 있습니다.
          - **테마** — 바닥재·벽지를 바꿉니다(길드장).
        - 가구 구매·재배치·테마 변경은 **길드장** 전용입니다.

        > 길드에서 쓰는 코인은 앱 공용 코인과 같습니다. 사용량 적립·배지·컬렉션·랭킹 보상으로 모읍니다.
        """),

        GuideSection(
            id: "board", title: "게시판", icon: "bubble.left.and.bubble.right.fill", tint: .teal,
            summary: "트레이너들이 익명 닉네임으로 짧은 글을 남기는 보드입니다.",
            body: """
        랭킹에 참여하면 게시판(“CEO 지시사항” 보드)을 이용할 수 있습니다.

        - **글 작성** — 짧은 메시지를 남깁니다(닉네임으로 표시).
        - **댓글** — 글마다 짧은 댓글을 달 수 있고, 댓글에도 좋아요를 누를 수 있습니다.
        - **좋아요** — 하트를 눌러 공감합니다. 누가 눌렀는지는 공개되지 않고 개수만 표시됩니다.
        - 패널 상단 말풍선 아이콘으로 열며, 미확인 글이 있으면 배지가 붙습니다.
        """),

        GuideSection(
            id: "fortune", title: "오늘의 개발 운세", icon: "sparkles", tint: AppColors.gold,
            summary: "하루 한 번 가볍게 보는 개발자 운세입니다.",
            body: """
        패널 상단의 ✨ 아이콘으로 **오늘의 개발 운세**를 봅니다.

        - 하루에 한 번 갱신됩니다.
        - **랭킹 참여 + GitHub 연동**이 필요합니다 — GitHub 계정 생성일을 사주처럼 풀이합니다.
        - 오늘 아직 안 봤으면 아이콘에 **빨간 점**이 표시됩니다.
        - 순수 재미 요소로, 사용량/적립과는 무관합니다.
        """),

        GuideSection(
            id: "theme", title: "테마 & 맵", icon: "paintpalette.fill", tint: .purple,
            summary: "차트 배경 테마를 바꾸고, 동적 테마로 사용량을 풍경으로 표현합니다.",
            body: """
        각 차트의 배경(맵)을 테마로 꾸밀 수 있습니다.

        ## 정적 테마 (무료)
        잔디밭·들판·황무지·우주 등. 기본 제공됩니다.

        ## 동적 테마 (코인 구매)
        사용량이 임계값을 넘으면 강조 효과가 한쪽에서 차오릅니다.
        - **설산**(눈) · **화산**(용암) · **바다**(심해) · **사막**(노을)
        - **오로라 · 벚꽃 · 뇌우 · 독성 늪** (프리미엄)

        동적 테마는 메뉴바 위젯에도 동일하게 반영됩니다.
        """),

        GuideSection(
            id: "settings", title: "설정", icon: "gearshape.fill", tint: .gray,
            summary: "메뉴바·알림·자동 시작·갱신 주기 등 동작을 조정합니다.",
            body: """
        **⋯ 메뉴 → 설정...**(또는 ⌘,)에서 조정합니다.

        - **메뉴바 표시** — 메뉴바 위젯 on/off + 표시 소스 선택.
        - **알림 임계값** — 사용률이 특정 %를 넘으면 알림. 한 창(window)당 한 번만 울립니다.
        - **로그인 시 자동 시작** — 맥 로그인 때 자동 실행.
        - **갱신 주기 / 패널 투명도** 등 기타 표시 옵션.

        > 알림·자동 시작·자동 업데이트는 정식 `.app`으로 실행할 때만 동작합니다(개발용 CLI 실행에선 비활성).
        """),

        GuideSection(
            id: "diagnostics", title: "진단 & 버그 리포트", icon: "stethoscope", tint: .red,
            summary: "수집이 이상할 때 진단을 첨부해 신고하거나, 터미널 대시보드로 확인합니다.",
            body: """
        ## 버그 리포트
        **⋯ 메뉴 → 버그 리포트...**에서 신고합니다. “사용량 이슈” 템플릿은 응답 원본 구조를 **비공개로** 첨부해 디버깅을 돕습니다(개인정보·잔액은 제거, GitHub 공개 이슈에는 조회용 ID만 기록).

        ## TUI 모드
        같은 데이터를 터미널 대시보드로도 볼 수 있습니다.
        - 설치본: `/Applications/AIUsage.app/Contents/MacOS/ClaudeUsage --tui`
        - 인증·폴링은 앱과 공유하므로, Claude는 앱에서 한 번 로그인해 둬야 합니다.

        ## 자동 업데이트
        Sparkle로 새 버전이 나오면 자동으로 받아 적용합니다. 상단 'Usage' 옆 **버전 칩**을 클릭해 수동 확인도 가능합니다. 새 버전이 있으면 버전 칩이 주황색으로 강조됩니다.
        """),
    ]
}

// MARK: - 윈도우 컨트롤러

/// 가이드 단일 창. 공지 창(`AnnouncementWindowController`)과 동일 패턴 — 단일 인스턴스.
/// LSUIElement 앱이라 표시 직전 `NSApp.activate`로 앞으로 가져온다.
@MainActor
final class GuideWindowController: NSWindowController {
    static let shared = GuideWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "가이드"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        // 가이드를 열면 알림 점 해제 — 사용자가 확인한 것으로 본다(MainView 배지 반응).
        Settings.shared.hasViewedGuide = true
        let root = GuideView { [weak self] in
            self?.window?.close()
        }
        window?.contentViewController = NSHostingController(rootView: root)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
