# 시즌 이벤트 — 1번: 분위기 레이어 + 시즌 레지스트리

12월 크리스마스를 첫 사례로 하되, 할로윈·벚꽃·설날 등 다른 시즌에도 데이터만 추가해 재사용할 수 있는
구조로 만든다. 1번은 **구매도, 보상도, 서버도 없는** 순수 연출이다. 설치된 앱이 12월이 되면 알아서
겨울이 되고 1월이 되면 알아서 돌아온다. 2번(한정 코스메틱)·3번(참여 이벤트)·4번(겨울 관장)은 이 문서의
`Season` 구조체에 필드를 늘리는 방식으로 이어진다.

> 결정(사용자 확정, 2026-11-01): ①시즌 레지스트리로 추상화 ②크리스마스/연말을 시즌 2개로 분리
> ③눈은 "가짜 날씨"가 아니라 날씨와 분리된 ambient 파티클 ④사용자 토글 1개 + 환경변수 강제 + 서버 킬스위치
> ⑤사전 공지 없음(12월 1일 아침에 조용히 켜짐).
>
> 결정(2번, 2026-11-01): ⑥기존 액세서리 8종을 도트 PNG로 **이번 시즌에 함께 교체** ⑦12월 초 공지 릴리스
> 여부는 보류 ⑧구매 칭호 포함.
>
> 결정(3번, 2026-11-01): ⑨서버 훅은 `submit`("AI를 쓴 날") ⑩참여 UI는 별도 카드가 아니라 **리포트 탭의 상시
> 사용량 잔디** 위에 얹는다 ⑪리포트 탭을 리포트/꾸미기로 분리 정리 ⑫사용자 노출 용어는 "어드벤트"가 아니라
> **"보상"**(내부 식별자 `advent-*`는 유지). 시안: https://claude.ai/artifact/RuGzDhyN9dx772KcLhquf3
>
> 결정(4번, 2026-11-01): ⑬관장은 `BadgeRegion`이 아니라 별도 `SeasonalBoss` ⑭보스 팀은 **기존 펫의 흰색 리컬러
> (북극 동물) + 모자**로 만든 이벤트 전용 스킨 ⑮tier 오픈은 **3번 보상 진행도(N/24)에 연동** ⑯오픈 기준 0/6/12/18일,
> 스킨은 올해 보스 전용, 격파 보상은 지역 관장의 10~20배(1,000/3,000/6,000/15,000 + 프리미엄 가챠권) **확정**.

## 1. 추상화 — 소비자는 날짜를 보지 않는다

핵심 경계는 하나다. 렌더러·대사·상점은 **`SeasonRegistry.active(now:)`가 돌려주는 `Season`의 필드만
읽는다.** 소비자 코드에 `Calendar`/`Date` 비교가 나오면 리뷰에서 반려한다.

```swift
struct Season: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case xmas, newYear, halloween, sakura }   // case 삭제 금지
    let kind: Kind
    let window: SeasonWindow

    // ── 1번: 분위기 ──
    let ambient: ParticleStyle?        // 눈송이/꽃잎/낙엽 — WeatherCondition과 분리
    let headwear: String?              // 펫 머리 장식 리소스명 (산타모자/호박/꽃)
    let quotes: [String]
    let officeWindowParticles: Bool

    // ── 3번: 잔디 장식·보상 구간 ──
    let grassDecoration: ParticleStyle?    // 불 켜진 셀 위 장식(눈/꽃잎). 잔디 자체는 상시 기능
    let rewardDays: ClosedRange<Int>?      // 서버 일일 보상 구간(1...24). nil이면 보상 없음

    // ── 4번: 겨울 관장 ──
    let boss: SeasonalBoss?                // 뱃지·지역과 무관한 이벤트 보스. newYear는 nil
    // 상점 아이템 목록은 여기 두지 않는다 — 각 아이템이 `season: Season.Kind?`로 자기 시즌을 안다(§10).

    var id: String { kind.rawValue }                 // 코스메틱 노출 판정 키 (연도 없음)
    func instanceID(now: Date) -> String             // "xmas-2026" — 1회성 지급 dedup 키 (연도 포함)
}

enum SeasonRegistry {
    static let all: [Season]
    /// 유일한 진입점. 설정 off / 환경변수 강제 / 서버 킬스위치 / 날짜 창을 모두 여기서 합성.
    static func active(now: Date = Date(), settings: Settings = .shared) -> Season?
}
```

`SeasonWindow`는 두 형태를 지원한다.

* **매년 반복** `(월/일) ~ (월/일)` — 12/1 → 1/4처럼 연도를 넘는 창 처리 필수.
* **연도별 고정** `[년: DateInterval]` — 설날·추석(음력). 테이블에 없는 연도는 비활성.

판정은 **KST** 기준(구현 시 변경: 잔디·서버 보상·퀴즈가 전부 KST라 한 날짜선으로 통일). 1번은 연출만이라
시계를 돌려도 얻는 게 없다. 서버 게이트는 2번(상점)·3번(지급)부터 필요하다.

규칙 3개:

* **`Season.Kind` case와 상점용 enum case(`CardAccessory` 등)는 삭제 금지.** `tshirt = "scarf"`와 같은
  이유 — 저장된 rawValue가 깨진다. 시즌 폐지는 `all` 배열에서만 뺀다.
* **1회성 지급은 `instanceID`(연도 포함), 코스메틱 노출은 `id`(연도 없음).** 섞이면 내년에 보상이 안 나오거나
  작년 모자가 안 뜬다.
* **시즌 창은 서로 겹치지 않는다.** 테스트가 고정한다. 동시에 활성인 시즌은 최대 1개.

## 2. 스위치 3겹

| 층 | 수단 | 용도 |
|---|---|---|
| 사용자 | 설정 토글 `seasonalEffectsEnabled` 1개 (기본 on, 날씨 토글 바로 아래) | 모든 시즌 연출 일괄 off. 시즌별 토글은 두지 않는다 |
| 개발 | 환경변수 `AIUSAGE_SEASON=xmas` / `AIUSAGE_SEASON=none` | 프리뷰·dev run에서 날짜 무시하고 강제 |
| 운영 | `sync` 응답 선택 필드 `disabledSeasons: [String]` (`try?` 디코딩) | 배포 후 버그 시 릴리스 없이 끄는 킬스위치 |

운영 킬스위치는 2번부터 가치가 커지지만 필드 하나 수준이라 1번에서 미리 뚫는다. 눈 파티클이 특정 환경에서
CPU를 먹는다는 제보가 오면 그날 끈다.

## 3. 구성 요소

### A. ambient 파티클 (눈)

* `WeatherParticles`의 파티클 생성부를 `ParticleStyle(sprite, pixelSize, maxCount, speed, sway)`로 뽑아낸다.
  눈·비는 날씨가, 꽃잎·낙엽은 시즌이 같은 구조체를 넘긴다.
* 우선순위 **실제 강수 > 시즌 ambient**. 비·뇌우가 오면 그대로 보인다(설정 이름이 "실제 날씨 효과"다).
  실제 눈이면 실제 강도, 시즌 눈이면 고정 **0.35**(가랑눈 — 한 달 내내 떠 있으니 조용해야 한다).
* `MainView`가 `vm.weather`를 읽는 5곳(파티클 1 + 차트/WalkingCat 4)을 `vm.effectiveWeather`(실제 강수
  또는 시즌 ambient를 합성한 값) 하나로 모은다. WalkingCat에 시즌 눈이 전달되면 기존
  `Quotes.weatherCommon[.snow]` 6줄이 추가 작업 없이 살아난다.
* `weatherEffectEnabled`가 off면 시즌 눈도 안 내린다. 시즌 토글은 그 위에 한 겹 더 거는 것.

### B. headwear (산타 모자)

메뉴바 펫 + 메인 패널 차트 WalkingCat 둘 다. 길드 오피스 펫은 컨트롤러가 달라 이번엔 제외.

* **에셋**: 7×6px 도트 PNG 1장 → `Resources/seasonal/santa_hat.png`. `Resources/weather/snowflake.png`(9×9)와
  같은 방식. 벡터가 아닌 픽셀 단위 도트라 화풍 원칙에 어긋나지 않는다.
* **머리 위치**: 195종의 cellSize·여백이 전부 달라 셀 상단 고정은 작은 펫에서 모자가 뜬다. 프레임
  **알파 스캔**으로 가장 위 불투명 행 → 그 근처 불투명 픽셀의 x 중심을 머리로 본다.
  `PetSprite.hatAnchor(for:action:frameIndex:)`, (kind, action, frameIdx) 캐시. `MenuBarRenderer.tintedSpriteCache`와
  같은 키 패턴.
* **좌우 반전**: 두 렌더러 모두 ctx/scaleEffect 플립 안쪽에서 그려 모자도 함께 뒤집힌다.
* **점프·구르기**: WalkingCat의 `jumpY`/`rollAngle`(Mythic 오라가 쓰는 것)과 같은 offset 적용.
* **RenderKey**: `MenuBarRenderer.RenderKey`에 `seasonID: String?` 추가. 없으면 0시 경계에서 재합성을
  건너뛰어 모자가 안 나타난다.

### C. 시즌 대사

`Season.quotes` 풀. `WalkingCat.quoteForContext`에서 시즌 중 30% 확률로 먼저 뽑고, 나머지는 기존
날씨→종 전용 순서. `OfficePetController`(156행 근처)도 같은 풀을 섞는다. 톤은 기존 `Quotes`와 동일 —
사실 + dev 농담, 35자 이하, 비장한 문구 금지([[copy-no-ai-slop]]).

xmas 초안:

```
cron은 0 0 25 12 * 입니다.
올해 커밋 트리에 장식 다는 중.
산타도 rate limit은 못 피해요.
선물 배송은 at-least-once예요.
눈 오니 빌드가 느린 기분.
연말 배포 freeze 아직이죠?
트리 밑에 PR 두고 갔어요.
12월엔 토큰도 따뜻하게.
루돌프는 GPU 없이 뜁니다.
올해 마지막 force-push는 참아요.
```

newYear 풀은 별도 작성(연말 정산·새해 다짐 톤, 10줄).

### D. 길드 오피스

* **창문 눈**: 오피스 창문 가구는 `DrawKind.window`로 코드가 직접 그린다. 시즌 중엔 창밖이 **밤**(짙은 남색 +
  달)이 되고 눈송이 46개가 세 겹(먼 것은 작고 느리게, 가까운 것은 크고 빠르게 — 1.5~3.6초에 한 번 낙하)으로
  쏟아지며 창턱에 눈이 쌓인다(`WindowSnow`, 에셋 없음). 처음엔 낮 하늘에 2px 점 7개였는데 대비도 양도 부족해
  "잘 보이지도 않는다"는 피드백으로 바꿨다(2026-11-10). 눈은 창살 뒤로 지나간다.
* **트리 데코**: `pixel-office` 팩(33파일)에도, 그 미러(`pixel-agents-hq/pixel-agents`)의 furniture 28폴더에도
  트리는 **없음**(2026-11-10 확인). 그래서 화분은 같은 팩의 `POT.png`를 그대로 쓰고 나무·별·장식만 팩의 잎
  팔레트(`#292a2b`/`#356441`/`#458e48`/`#74b25d`)로 얹은 16×32 `CHRISTMAS_TREE.png`를 자체 제작해
  `Resources/seasonal/`에 넣었다(액세서리 T3과 같은 예외 — 사용자 컨펌 완료). `decorCatalog`에
  `CHRISTMAS_TREE`(floor, behind, 300코인, `season: .xmas`)로 등록. 전구 15개가 3그룹으로 돌아가며
  켜지는 3프레임(`_2`, `_3`)을 0.5초 간격으로 순환한다(`DecorItem.animationFrames`, PC 모니터와 같은 박자). 상점 노출만 `shopVisible`로 게이트하고,
  이미 놓인 트리는 시즌이 끝나도 그대로 그려진다. 오피스 데코는 서버에 kind 문자열로 저장돼 다른 멤버가
  보는데, 서버(`guild-office`)는 kind를 검증하지 않고 구버전 클라는 `decorItem(kind:)`가 nil이라 그 슬롯을
  그리지 않고 넘어간다 — 서버 배포 없이 클라만으로 된다.

## 4. 첫 해 캘린더

| kind | 창 | ambient | headwear | 비고 |
|---|---|---|---|---|
| xmas | **11/16** ~ 12/26 | 눈 0.35 | 산타 모자 | 올해 첫 적용. 애초 12/1 → 11/16 릴리스와 함께 켜기로(2026-11-10) |
| newYear | 12/26 ~ 1/4 | 눈 0.35 | 없음 | 연말 리캡과 시기 겹침 — 코드/PR 분리 유지 |
| halloween | 10/24 ~ 11/1 | 없음 | 호박 | `skull`·`roboPumpkin` 설명문이 이미 "할로윈 한정"을 말함. 내년 |
| sakura | 4/1 ~ 4/15 | 꽃잎 | 꽃 | `TerrainMotif.petal` 재사용. 내년 |

올해 코드에 들어가는 건 xmas·newYear 두 **데이터 항목**. 할로윈 추가가 PNG 1장 + `Season` 리터럴 1개 +
대사 10줄 이상을 요구하면 추상화가 새는 신호다.

## 5. 경계 넘김

`ViewModel.activeSeason: Season?`(`@Published`) — 폴링 tick마다 재계산 + **다음 창 경계 시각에 1회 타이머**로
0시 정각 갱신. 메뉴바는 RenderKey의 `seasonID`로 재합성.

## 6. 바뀌는 파일

* 신규 `Season.swift` — `Season`, `SeasonWindow`, `ParticleStyle`, `SeasonalItem` 프로토콜
* 신규 `SeasonRegistry.swift` — `all` 데이터 + `active(now:)` 합성(설정·환경변수·킬스위치·창)
* 신규 `Resources/seasonal/santa_hat.png`
* `Settings.swift` / `SettingsView.swift` — `seasonalEffectsEnabled`
* `ViewModel.swift` — `activeSeason`, `effectiveWeather`, 경계 타이머
* `MainView.swift` — `vm.weather` 5곳 → effective
* `WeatherParticles.swift` — `ParticleStyle` 추출
* `PetSprite.swift` — `hatAnchor` 알파 스캔 + 캐시
* `MenuBarRenderer.swift` — headwear 그리기, RenderKey `seasonID`
* `WalkingCat.swift` — headwear 레이어, `quoteForContext` 시즌 분기
* `OfficePetController.swift` — 대사 분기
* 오피스 창문 뷰 — 창밖 눈
* `RankingAPI.swift` — `sync` 응답 `disabledSeasons` 선택 디코딩

## 7. 검증

* **테스트**: 창 경계(11/30 23:59, 12/1 00:00, 12/26 00:00, 1/4 00:00), 연도 넘김, 창 비중첩, 연도별 고정 창
  미등록 연도 비활성, 환경변수 강제·설정 off·킬스위치 우선순위, effective weather 합성(clear→시즌 눈, rain 유지,
  토글 off 시 실제값), 앵커가 셀 안에 들어오는지 195종 순회, RenderKey에 seasonID, 대사 길이 상한.
* **프리뷰**: `AnimationPreviews` 메뉴바 30Hz GIF + 걷기 사이클에 `AIUSAGE_SEASON=xmas` 변형 추가. 모자가 머리에
  붙어 있는지, 플립 시 어긋나지 않는지는 눈으로 본다. 머리 큰 펫, 납작한 펫(슬라임), 비행 펫(박쥐·새) 중점.
* 메뉴바 dev run은 실제 키체인을 공유하므로 `AIUSAGE_SANDBOX=1`로만.

## 8. 릴리스 (2026-11-10 사용자 결정으로 전면 개정)

| 날짜 | 무엇 | 누가 |
|---|---|---|
| 11/13~14 | 서버 배포 — `_shared/season.ts`, `submit`, `daily-quiz`. 11/16 공지 row도 이때 넣는다 | 사용자 |
| **11/16(월)** | **본 릴리스** — 겨울 시즌이 이날 바로 켜진다: 눈·산타 모자·한정 상점·오피스 데코·겨울 관장(이벤트 섬). 공지 포함 | 사용자 허락 후 |
| 12/1 | 12월 일일 보상 시작(서버 `submit` 훅, 12/1~24) | 자동 |
| **12/14(월)** | **소형 릴리스** — 크리스마스 주간 선물(12/21~25) 공지. 공지는 버전에 묶여 있어 릴리스가 있어야 뜬다 | 사용자 허락 후 |
| 12/21~25 | 주간 선물 | 자동 |
| 12/26 | 겨울 시즌·겨울 관장 종료, 연말연시 시즌 시작 | 자동 |
| 1/4 | 연말연시 시즌 종료 | 자동 |

* 애초 계획("11월 넷째 주 릴리스, 12/1에 조용히 켜짐, 사전 공지 없음")은 폐기. **시즌 창은 11/16~12/26**이고
  11/16 공지에 겨울 시즌을 알린다.
* 선물 코드는 11/16 빌드에 이미 들어 있고 날짜(12/21~25)로 잠겨 있다. 12/14 릴리스를 건너뛴 사용자도 선물은
  받는다 — 12/14 릴리스가 싣는 것은 공지(와 그때까지의 수정)다. 선물 코드를 12/14 빌드로 미루면 그날 이후
  업데이트하지 않은 사용자가 선물을 통째로 놓친다.
* 창이 11월에 시작해도 일일 보상 키는 12월이다(`Season.rewardMonth = 12`, 서버 `ADVENT.month`). 11월엔 리포트 탭에
  "보상 0/24"와 "12/1~24 …" 안내만 보이고 잔디에 보상 마크는 없다.
* 서버의 퀴즈 시즌 힌트는 12/1~25 그대로(서버 상수). 11/16부터로 당기려면 서버만 고치면 된다.
* PR 단위: 나눠도 되고 합쳐도 된다(사용자). 브랜치가 30여 커밋으로 얽혀 있어 한 PR이 기본안.

### 공지 초안 — 11/16 릴리스

제목: **겨울 시즌이 열렸습니다**

```
12월 26일까지 겨울 시즌입니다.

## 겨울 관장

- 도장 탭 월드맵 위쪽 하늘에 눈 섬이 생겼습니다. 섬을 누르면 겨울 관장 Rudolph에게 도전할 수 있습니다.
- 4단계이고 단계마다 오픈일이 있습니다: localhost 11/16 · dev 11/23 · staging 11/30 · production 12/7.
- dev부터는 오픈일이 지나고, 11/16 이후 AI를 쓴 날 수(6·12·18일)나 누적 VP(400·800·1,200) 중 하나를 채우면 열립니다.
- 첫 격파 보상: 1,000 / 3,000 / 6,000 / 15,000 코인. production은 프리미엄 가챠권 1장과 칭호 "눈길 배포 성공"도 드립니다.

## 겨울 한정 상점

- 트레이너 카드: 액세서리 산타 모자·사슴뿔·목도리, 칭호 "연말 배포 freeze 위반"
- 펫 이펙트 눈내림, 맵 테마 겨울밤
- 길드 오피스 장식 6종: 크리스마스 트리, 눈사람, 선물 상자, 전구 줄, Merry Xmas 배너, 리스
- 상점에는 12/26까지만 나오고, 산 것은 계속 남습니다.

## 12월 일일 보상

- 12/1~24, AI를 쓴 날마다 50 코인(24일은 300)을 드립니다. 랭킹에 참여 중이어야 받습니다.
- 20일을 채우면 500 코인과 칭호 "12월 완주"를 드립니다.
- 리포트 탭의 사용량 잔디에서 받은 날을 확인할 수 있습니다.

## 그 밖에

- 리포트 탭이 리포트 / 꾸미기로 나뉘고, 한 달 사용량을 달력으로 보는 사용량 잔디가 생겼습니다.
- 트레이너 카드 액세서리 11종을 도트 그림으로 바꿨습니다.
- 눈과 산타 모자는 설정 → 시즌 연출에서 끌 수 있습니다. 끄면 겨울 관장과 한정 상점도 함께 숨습니다.
```

### 공지 초안 — 12/14 소형 릴리스

제목: **크리스마스 주간 선물 (12/21~25)**

```
12월 21일(월)부터 25일(금)까지 매일 선물을 하나씩 드립니다.

- 메인 패널에 뜨는 "오늘의 선물"에서 열기를 누르면 받습니다.
- 12/21 코인 1,000 + 가챠권 1장 → 12/22 2,000 + 2장 → 12/23 3,000 + 3장 → 12/24 5,000 + 4장 → 12/25 9,000 + 5장
- 닷새를 다 받으면 코인 20,000과 가챠권 15장입니다.
- 그날 선물은 그날(한국 시간)에만 열립니다. 지나간 날은 받을 수 없습니다.

겨울 관장 production 단계는 12/7부터 열려 있습니다. 겨울 시즌은 12/26에 끝납니다.
1월 1일에 AI를 쓰면 칭호 "새해 첫날에도 출근함"을 드립니다.
```

## 9. 미결

없음 — 트리 데코는 자체 제작으로 포함(§3-D), newYear 대사 10줄은 `SeasonRegistry`에 작성 완료.

---

# 2번: 한정 코스메틱

## 10. 원칙

* **한정은 "상점 노출 기간"이지 "보유 기간"이 아니다.** 산 사람은 영구 보유·장착. 시즌이 끝나면 상점에서만
  사라지고 내년에 다시 나온다.
* **가격은 같은 등급의 상시 아이템과 동일.** 희소성은 시간이 만든다. 가격 프리미엄은 코인을 덜 모은 신규
  사용자를 배제하므로 두지 않는다.
* **서버 변경 없음.** 코인·RP는 기존 ledger로만 움직이고 노출 판정은 `SeasonRegistry.active()`가 한다.
* **아이템이 자기 시즌을 안다.** 각 enum/카탈로그 항목에 `season: Season.Kind?`(상시=nil). 시즌이 아이템
  목록을 들고 있는 역방향 필드는 두지 않는다 — 같은 정보가 두 곳이면 어긋났을 때 어느 쪽이 맞는지 모른다.

```swift
protocol SeasonalItem { var season: Season.Kind? { get } }

extension Settings {
    /// 상점 노출 여부. 상시 아이템은 항상, 시즌 아이템은 활성 시즌 일치 또는 이미 보유 시.
    func shopVisible<T: SeasonalItem>(_ item: T, owned: Bool) -> Bool {
        guard let s = item.season else { return true }
        return owned || SeasonRegistry.active()?.kind == s
    }
}
```

상점 4곳(액세서리 `ReportView` ~390행, 이펙트 `PetEffectShelf` ~30행, 테마 `PartyView` ~299행, 칭호
`ReportView` ~306행)이 전부 `allCases`를 직접 순회한다. 각자 if를 심지 말고 `.filter { shopVisible(...) }`로
통일한다. 시즌 아이템 칩에는 "한정" 뱃지 + "12/26까지" 꼬리말, 보유한 시즌 아이템은 시즌이 끝나도 보이되
뱃지만 남긴다.

## 11. 아이템

| 종류 | 항목 | 화폐 | 가격 | 비고 |
|---|---|---|---|---|
| 액세서리 | 산타 모자 `santaHat` | 코인 | 800 | 1번 B의 도트 PNG를 확대해 그대로 사용 |
| 액세서리 | 사슴뿔 `antlers` | 코인 | 800 | |
| 액세서리 | 목도리 `muffler` | 코인 | 1500 | rawValue `scarf`는 `tshirt`가 점유 중(v0.7.0 호환) — 사용 금지 |
| 이펙트 | 눈내림 `snowfall` | RP | 400 | `.particle` 카테고리. `riser()`를 하강으로 뒤집은 `faller()` |
| 맵 테마 | 겨울밤 `winterNight` | 코인 | 2000 | 동적. 짙은 남색 하늘, 사용량↑ 위에서 전구색 점등. `TerrainMotif.bulb` 추가 |
| 칭호 | 크리스마스에도 코딩함 `codedOnChristmas` | 자동 | — | 12/25에 `UsageEvent` 1건 이상 |
| 칭호 | 연말 배포 freeze 위반 `freezeViolator` | 코인 | 1500 | dev 자조 밈 계열, 상시 구매 칭호와 같은 톤 |
| 오피스 데코 | 트리 `CHRISTMAS_TREE` | 코인 | 300 | 바닥 슬롯, 자체 제작 16×32(§3-D), 전구 3프레임 |
| 오피스 데코 | 전구 줄 `XMAS_LIGHTS` | 코인 | 500 | 벽 슬롯, 자체 제작 32×32, 전구 6개 3프레임 |
| 오피스 데코 | Merry Xmas 배너 `XMAS_BANNER` | 코인 | 500 | 벽 슬롯, 자체 제작 32×32, 정지 |
| 오피스 데코 | 리스 `XMAS_WREATH` | 코인 | 500 | 벽 슬롯, 자체 제작 16×32, 정지 |
| 오피스 데코 | 눈사람 `SNOWMAN` | 코인 | 300 | 바닥 슬롯(펫이 뒤로 지나감), 자체 제작 20×36(디테일 요청으로 1.2배), 정지 |
| 오피스 데코 | 선물 상자 `GIFT_BOXES` | 코인 | 300 | 바닥 슬롯(펫이 앞으로 지나감), 자체 제작 16×16, 정지 |

코인 싱크 합계 ≈ 6,600(뽑기 22회분), RP 400. 오피스 데코 6종(300~500)은 합계에서 제외 — 길드 기부라
슬롯마다 반복 구매할 수 있어 1인 상한이 없다.

## 12. 기존 액세서리 8종 도트 교체 (결정 ⑥)

현재 `Resources/trainer-accessories/`가 **존재하지 않는다.** 8종 전부 `fallbackSymbol`(SF Symbol, 노란색)로
그려지고 있고, 시즌 3종이 첫 실제 스프라이트가 된다. 도트 모자와 SF 안경이 한 카드에 섞이면 화풍이 갈리므로
8종을 함께 교체한다.

* **규격**: 카드에서 50pt 박스(`AccessoryTransform.scale` 배수)에 `interpolation(.none)`으로 그려진다.
  펫 아바타 110px 위에 얹히므로 **16×16 도트**가 3배 확대돼 적절하다. 11종 모두 같은 캔버스 크기로 통일.
* **소싱**: 직접 그리지 않는다([[asset-no-handdraw-source-packs]]). 16×16 아이템/장비 아이콘 CC0·CC-BY 팩을
  researcher로 조사해 `docs/research/accessory-icon-assets.md`에 정리. 후보(라이선스·크기 확인 필요): Kenney
  계열 CC0 팩, Shikashi Fantasy Icons, Kyrise RPG Icon Pack. 11종(밀짚모자·안경·왕관·티셔츠·후광·마스크·선물·
  헤드폰·산타모자·사슴뿔·목도리)이 한 팩에서 다 나오면 최선, 둘 이상 섞으면 팔레트·외곽선 두께가 맞는 것만.
* **분리 원칙**: 8종 교체는 이벤트와 무관한 개선이므로 **별도 PR**. 시즌 PR이 이 PR 위에 올라간다.
  `resourceName`(`accessory_<rawValue>`)과 `fallbackSymbol`은 그대로 두어 PNG 누락 시 폴백이 살아 있게 한다.
* **검증**: 트레이너 카드 프리뷰가 모든 액세서리 조합을 자동으로 굽는다 — PNG만 넣으면 갤러리에 나온다.
  기존 사용자의 `AccessoryTransform`(위치·배율)이 SF 심볼 기준으로 저장돼 있어 PNG 교체 후 어긋날 수 있다.
  기본값 `offsetY: -32`가 16×16 확대본에도 맞는지 프리뷰로 확인하고, 필요하면 1회 마이그레이션으로 리셋.

## 13. 구현 지점

* **액세서리**: `CardAccessory` case 3개 + `displayName`/`fallbackSymbol`/`price`/`season`. 카드 위치는 기존
  `AccessoryDragModifier`(사용자 드래그) 그대로 — 1번의 알파 스캔 앵커는 걷는 펫 전용.
* **이펙트**: `EffectKind.snowfall`(`.particle`, 400, `season: .xmas`). `PetEffectOverlay.faller()` — `riser()`와
  같은 TimelineView 구조, `dy` 부호 반대, 시작점 머리 위, 흰 `Circle` 6개, 느린 sway. 시즌 ambient 눈과 구분되게
  펫 몸 폭 안에서만 내린다.
* **테마**: `PetTheme.winterNight`, `isDynamic` true, price 2000, `season: .xmas`. `dynamicStops`는 edge-fill
  모델로 위에서 따뜻한 금색이 내려온다. `TrainerBackground.unlocked`가 `PetTheme.allCases`를 읽어 카드 배경으로
  자동 등록, 메뉴바도 `fillStops` 공유로 따라온다. `PartyView` 496행(테마 선택)은 보유 기준이라 그대로.
* **자동 칭호**: `Settings.seasonalFlags: Set<String>`에 `"codedOn:2026-12-25"`를 기록하는 `UsageEventBus`
  consumer 1개(ledger와 같은 독립 consumer 패턴). `CardTitle.unlocked`는 플래그 존재만 본다. 연도별 키라
  매년 다시 받을 수 있지만 칭호는 하나.
* **구매 칭호**: `CardTitle.freezeViolator` + `purchasePrice` 1500 + `season`. `CoinLedger.purchaseTitle` 경로
  그대로.
* **오피스 데코**: `DecorItem`에 `season` 추가, 스튜디오 상점 목록도 `shopVisible`로 필터.

## 14. 공지 (결정 ⑦ 보류)

공지 시스템은 **업데이트 직후에만** 뜬다. 11월 하순 릴리스에 1·2번을 다 실으면 12/1에 상점이 조용히 열린다.
선택지: (a) 12/1~2에 공지만 실은 소형 릴리스 1회 추가 — 1번의 "조용히"와 2번의 "열렸어요"를 둘 다 지킴
(b) 11월 릴리스 공지에 "12/1 상점 오픈" 예고 — 릴리스 1회 절약, 1번 서프라이즈 포기. 결정은 릴리스 직전에.

## 15. 검증

* 테스트: `season != nil`인 모든 case가 `shopVisible`에서 시즌 밖·미보유 시 숨고 보유 시 보이는지.
  `CardAccessory.allCases` rawValue 유일성(`scarf` 충돌 방지). `winterNight.fillStops`가 pct 0/50/100에서
  stop 수·location 단조성 유지. 자동 칭호 플래그가 12/25 이벤트에서만 기록. 모든 `SeasonalItem` 채택 enum의
  `season`이 `Season.Kind`에 존재.
* 프리뷰: 트레이너 카드 조합 시트(자동, 11종 전부), `snowfall` 걷기 GIF, `winterNight` 맵 카드 + 메뉴바 GIF.

---

# 3번: 참여 이벤트 — 사용량 잔디 + 12월 일일 보상

## 16. 한 줄 정의

12/1~24 동안 **그날 AI를 실제로 쓴 날**마다 코인이 들어오고, 24일 중 20일을 채우면 칭호 "12월 완주"를 받는다.
참여 UI는 이벤트 전용 화면이 아니라 **상시 기능인 사용량 잔디** 위에 보상 표시가 얹히는 형태다. 이벤트가 끝나도
잔디는 남는다.

## 17. 사용량 잔디 (상시, 시즌 무관)

* **위치**: 리포트 탭, 트레이너 카드 아래 "리포트" 모드(§21). 메인 패널·상점 탭은 기각 — 메인 패널은 높이 부담,
  상점은 맥락 불일치.
* **창**: 캘린더 월(1일~말일), **KST**. 랭킹 보드가 이번 달 누적 기준이라 "숫자의 합 = 잔디의 합"이 성립한다.
  서버 보상 grant와 퀴즈가 KST 날짜로 끊기므로 로컬 자정을 쓰면 밤 11시대 사용분이 다른 칸에 들어간다.
* **방향**: GitHub식(열=주)이 아니라 **달력식(열=요일 월~일, 행=주)**. 한 달 창엔 이쪽이 읽히고 요일 헤더가 붙는다.
  셀 18pt, 간격 3pt. 16pt 아래로는 눈 장식(2~3px)이 안 보인다.
* **농도 5단계 = 현재 맵 테마 색**. `PetTheme`의 top/bottom/line을 보간해 0~4단계(`grassLevels`). 잔디밭=녹색,
  벚꽃=분홍, 2번 `winterNight`=남색 바탕 금색. 단계는 **본인 최근 30일 최대값 대비 사분위** — 절대값이면 Max 20x만
  진하고 Pro는 평생 연두색.
* **시즌 장식 = `Season.grassDecoration`**. xmas엔 불 켜진 셀 위 흰 눈 2~3px, sakura엔 꽃잎 점. 메인 패널 ambient와
  같은 소재라 "눈이 잔디에 쌓인다"로 읽힌다.
* **보상 표시** (rewardDays 구간, 시즌 중만): 수령한 날 = 셀 모서리 붉은 점, 쓴 날이지만 도착 전(≤1h) = 점선
  테두리, 미래 = 빈 셀, 오늘 = 흰 테두리. 호버 툴팁: 날짜 · VP · "보상 +50".
* **숫자 4개**(잔디 왼쪽): 이번 달 VP, 활동 일수/경과일, 스트릭, 보상 N/24(시즌 중만). 안내문 한 줄:
  "12/1~24 · AI를 쓴 날마다 +50 코인, 24일엔 +300 · 20일 채우면 칭호 "12월 완주". 보상은 1시간 안에 도착."
* **데이터**: 일별 VP가 로컬에 없다(`StreakLedger`는 "오늘 썼나"만). `UsageEventBus`에 consumer `DailyUsageLedger`
  추가 → `Settings.dailyVP: [KST 날짜: Int]`, 90일 보관. 코인·VP·스트릭 ledger와 같은 패턴. 과거 소급 없음 —
  11월 하순 배포 후부터 쌓인다(그래서 잔디 PR이 가장 급하다, §22).
* 보상 표시 데이터는 `Settings.claimedGrants`의 `advent-2026-12-` 접두 필터. **새 상태 없음.**

## 18. 서버 — 기존 `reward_grants` 재사용

`daily-quiz`가 쓰는 패턴 그대로: 서버가 `reward_grants`에 행을 넣고, 클라가 `leaderboard` 폴링의 `pendingGrant`
(가장 오래된 1건)를 받아 `claim-reward(rewardType=grant)`로 수령한다. 새 테이블·새 클레임 경로 없음.

* **훅 = `submit` Edge Function.** HMAC 서명 검증 + VP 증가분이 있을 때만 호출되므로 "쓴 날"이 자동 정의된다.
  `accepted` 처리 직후 KST 날짜가 보상 구간이면
  `INSERT INTO reward_grants(device_id, currency, amount, reason, grant_key) ... ON CONFLICT DO NOTHING`
  (`grant_key = 'advent-2026-12-DD'`). 한 문장이라 레이스 없음, `UNIQUE(device_id, grant_key)`가 하루 1회 보장.
* `sync`(120s, 켠 날)가 아닌 이유: 빈도와 의미. `leaderboard`는 서명 없는 GET이라 쓰기 훅 금지(남의 deviceId로
  보상 삽입 가능).
* 20번째 행을 넣는 submit에서 `advent-2026-complete`(coin 500)를 함께 삽입.
* 날짜 창 상수는 `_shared/season.ts` — 클라 `SeasonRegistry`와 같은 값 유지. 서버 시계 기준이라 클라 시계 조작 무효.
* 전달 지연 최대 1h(`claimLeaderboardIntervalSec`). 같은 날 퀴즈 보상과 겹치면 두 번째는 다음 시간.
* 알림: `NotificationManager.rewardGrantEarned`의 grantKey 접두 분기에 `advent-` 추가 → "🎄 12월 N일차 보상 +50 코인".

## 19. 보상

| 항목 | 금액 | 비고 |
|---|---|---|
| 1~23일 | 코인 50 | 스트릭 일일(15~50)과 같은 급 |
| 24일 | 코인 300 | 뽑기 1회 |
| 20일 달성 | 코인 500 + 칭호 "12월 완주" | 서버 complete 행 + 로컬 칭호 판정 |

합계 ≈ 1,950 코인(뽑기 6~7회). 진입 유인은 되지만 경제를 흔들지 않는다.

* **RP 금지** — 순위 전용 화폐(주간 1등 250). 참여 보상으로 주면 이펙트 가격 체계가 무너진다.
* **프리미엄 티켓 금지** — `reward_grants.currency`는 `rp|coin`뿐이고, 클라는 모르는 currency를 **클레임은 성공시키고
  적립은 건너뛴다.** 새 currency는 구버전 클라가 받아서 버리는 사고가 된다.
* 20/24인 이유: 주말·휴가. 24/24는 하루 놓치면 이탈.
* 칭호 `CardTitle.decemberFinisher`는 **로컬 판정** — `claimedGrants`의 접두 행 ≥ 20. 서버 complete 행과 독립이라
  전달 지연에 안전.

## 20. 범위 제한

랭킹 미등록 사용자는 참여 불가(`submit` 자체가 안 감). 퀴즈와 같은 제약. 잔디 안내문에 "랭킹 참여 시 수령" 한 줄.
로컬 폴백은 만들지 않는다(시계 조작 + 경로 2개 유지).

부수: `daily-quiz` 생성 프롬프트에 12월 시즌 힌트 한 줄(서버만, 릴리스 없음). 시크릿 산타·길드 눈싸움은 내년
(DM 매칭 함수·상태 테이블, 길드 RP 가드 충돌 검토 필요).

## 21. 리포트 탭 정리 (결정 ⑪, 시즌 무관 별도 PR)

현재 탭은 세 가지 일을 세로로 쌓는다 — 카드(3초 보기), 꾸미기 6섹션(월 1회 편집, 면적 70%, 칭호 66개 가로 스크롤),
공유 버튼 5개. 잔디를 그 아래 붙이면 편집기 밑에 묻힌다.

```
[ 트레이너 카드 ]                     ← 두 모드 공통, 편집 중에도 위에 유지
( 리포트 | 꾸미기 )          [공유 ▾]   ← 세그먼트, 탭 열면 항상 리포트. 공유 5버튼 → 메뉴 1개
리포트: 숫자 4개(좌) + 달력식 잔디(우) + 범례
꾸미기: 아바타 / 배경 / 프레임 / 칭호 / 액세서리 / 공유 설정 (현행 유지)
```

* 칭호: 가로 스크롤 → **보유 / 구매 가능 / 잠김 세 묶음 줄바꿈 그리드**. 시즌 한정은 붉은 테두리.
* 액세서리: 11종이라 줄바꿈 그리드.
* 세그먼트 상태 비저장. "꾸미기" 시트 방식은 카드를 보며 편집하는 경험이 깨져 기각.
* 프리뷰: `ScenePreviews.testRenderReportTab`이 리포트 모드를, 꾸미기 모드 렌더를 하나 추가. `PreviewDemoState`에
  `dailyVP` 시드 필요(빈 잔디는 검토 가치 없음).

## 22. PR 순서

1. **리포트 탭 정리** (§21) — 시즌 코드 없음.
2. **사용량 잔디** (`DailyUsageLedger`, `UsageGrassView`, `PetTheme.grassLevels`) — 시즌 코드 없음. **11월 중 배포
   필수**: 12/1에 잔디가 한 달치 쌓여 있어야 한다.
3. 액세서리 8종 도트 교체 (§12) — 2와 병렬 가능.
4. 시즌 1·2·3 PR — 그 위에 올라간다. 보상 표시·눈 장식은 3번 PR에서 잔디에 얹는다.
5. 서버: `_shared/season.ts`, `submit`, `daily-quiz` — 마이그레이션 없음, 배포 순서 제약 없음.

## 23. 검증

* 서버 `deno test`: 날짜 창 경계(11/30 KST 23:59, 12/1 00:00, 12/25 00:00), 같은 날 2회 submit → 행 1개,
  20번째에 complete 동반, 19번째엔 미삽입.
* 클라: KST 날짜 키(자정 경계), 사분위 농도(0건·1건·동일값), 테마별 5색 단조 증가, 접두 필터 수령 일수,
  20일 이상 칭호 해금, 시즌 장식·보상 행이 시즌 밖에서 숨는지. `claimedGrants`에 가짜 키로 전부 단위 테스트 가능.
* 프리뷰: 테마 12종 × 잔디, xmas 장식 on/off, `renderInWindow`로 리포트 모드·꾸미기 모드 각 1장.
* 운영: 12/1 KST 0시 이후 첫 submit 계정의 `reward_grants` 1회 육안 확인.

---

# 4번: 겨울 관장

## 24. 구조 — 지역이 아니라 이벤트 보스 (결정 ⑬)

현재 관장은 `BadgeRegion`에 1:1이고, 승리 = 그 지역 카테고리 뱃지 클리어, 도전 자격 = 지역 진행률. 즉 관장은
뱃지 시스템의 일부다. 10번째 지역으로 만들면 뱃지 카테고리 2개·보석 스프라이트 2개(19↔19 테스트가 막음)·월드맵
마을·진행률 계산이 따라오고, 시즌 후 "못 받는 뱃지"가 도감에 남는다. 그래서 **뱃지와 무관한 `SeasonalBoss`**.

```swift
struct SeasonalBoss {
    let lead: SkinnedPet                 // 루돌프(사슴 + 산타 모자)
    let supports: [SkinnedPet]           // 북극 원정대 4 (common만 — EP 밴드)
    let name: String
    let dialogues: [String]              // 4단계, 보상 진행도 연동
    let tierThresholds: [BadgeTier: Int] // 보상 일수 → tier 오픈
    let titleReward: CardTitle           // production 격파
}
struct SkinnedPet { let kind: PetKind; let skin: PetSkin?; let headwear: String? }
enum PetSkin { case snow }               // 런타임 리컬러 종류. 추가 자유
```

재사용: `team(tier:)`의 EP 역산 솔버, `BattleEngine`, `GymBattleView`, `gymLeaderSection` 카드 레이아웃.
변경: `GymLeader.team(tier:)`의 `supportKinds(region)` 직접 호출을 `team(lead:supports:tier:)`로 추출.
`GymBattleView(region:tier:)`는 승리 시 `defeatLeader`를 부르므로, 상대+승리 처리를 묶은 `GymOpponent`
(지역 관장 / 시즌 보스)를 받게 넓힌다. 지역 관장 경로 동작은 그대로.

## 25. 이벤트 스킨 — 흰색 리컬러 + 모자 (결정 ⑭)

**새 PNG를 그리지 않는다.** 이로치(variant)가 `hueRotation`/`saturation`으로 런타임 틴트하는 것과 같은 방식으로,
`PetSkin.snow`는 `CIColorMonochrome`(옅은 청백) + 밝기 보정으로 흰색화한다. 외곽선은 어둡게 남아 도트 느낌이
유지된다. 모자는 1번 B의 `hatAnchor` 알파 스캔 + headwear 오버레이 그대로. 틴트 프레임은 `tintedSpriteCache`와
같은 키로 캐시.

흰색 리컬러는 그 자체로 **북극 동물**이 된다:

| 역할 | 원본 | 스킨 | 표시명 |
|---|---|---|---|
| 선봉 | 사슴 `deer` | snow + 산타 모자 (사용자 요청으로 선봉도 흰색) | **Rudolph** |
| 서포터 | 곰 `bear` | snow | 북극곰 |
| 서포터 | 여우 `fox` | snow | 북극여우 |
| 서포터 | 늑대 `wolf` | snow | 흰늑대 |
| 서포터 | 난초 올빼미 `orchidOwl` | snow | 흰올빼미 |

전부 common(`Gacha.pool` 확인). 리컬러 결과는 기계로 판정 못 하므로 **프리뷰 시트 육안 확인** — 특정 펫이 흰색에서
형체가 뭉개지면 픽셀을 손보지 말고 다른 common 펫으로 교체한다(펭귄·얼음 좀비·토끼가 예비).

**스킨은 보스 전용이며 플레이어에게 주지 않는다**(이번 해). `BattlePetSnapshot`은 아레나 서버 파리티·HMAC 평면
페이로드에 실리는 구조체라 `skin` 필드를 넣지 않는다. 렌더 전용 맵 `[PetKind: SkinnedPet]`을 `BattleReplayView`에
기본값 빈 딕셔너리인 선택 인자로 넘긴다. 플레이어 보유 스킨은 파티·메뉴바·오피스·카드 등 모든 렌더 지점을 건드리는
별개 기능이므로 내년 후보로 둔다.

## 26. 배치·tier 오픈 (결정 ⑮)

* **진입점은 월드맵 하늘에 뜬 이벤트 섬**(2026-11-10 사용자 결정 — 애초 안은 "도장 탭 상단 카드, 월드맵에는
  넣지 않는다"였다). 시즌 중엔 월드가 위로 12행 늘어나고(`EventIsland.skyRows`) 두 대륙 사이 하늘에 눈 섬이
  뜬다. 섬을 누르면 카메라가 섬으로 줌인하고, 지역 관장·카테고리 자리에 시즌 카드(스프라이트 + 말풍선 + tier
  버튼 4개)가 나온다. 지상 지역을 누르면 평소 화면으로 돌아간다.
  * 섬은 `BadgeRegion`이 아니다(결정 ⑬ 유지) — `SeasonalBoss.island: EventIsland` 데이터이고, mapgen 지형
    (`WorldMapData`)은 건드리지 않는다. 좌표계의 음수 row에 얹는 오버레이라 시즌이 끝나면 월드는 70×38로 돌아간다.
  * "떠 있다"는 단서 셋: 가운데가 깊은 밑동 바위, 바다 위 그림자, 섬을 감싸고 흐르는 구름.
  * 맵 높이도 같은 비율로 키운다(220 → 289). 지상 지역은 평소와 같은 크기로 보인다.
  * 시즌 중엔 맵 전체에 눈이 내린다(오피스 창밖 눈과 같은 `WindowSnow`). 이 때문에 월드 뷰에서도 프레임이 돈다.
  * 섬 위: 도장(`building_dojo`, 기존 미사용 에셋), 소나무, 오피스 데코로 만든 트리·눈사람·선물 상자. 줌인하면
    Rudolph(흰 스킨 + 모자)가 도장 앞을 걷는다 — 흰 스킨이 눈밭에서 안 보여 도장 앞에 돌 광장을 깔고 크기를 키웠다.
  * 섬은 고르지 않아도 거의 어두워지지 않고 이름표("겨울 관장")가 항상 붙는다 — 사전 공지가 없으니 맵에서
    스스로 눈에 띄어야 한다.
  * 내년 다른 시즌은 `EventIsland` 리터럴 하나(terrain 문자열·데코·건물)를 더 쓰면 된다.
* **보스 기간은 11/16~12/26**(2026-11-10 사용자 결정). 시즌 창도 같은 날 켜기로 해서 올해는 둘이 같다. 보스가
  자기 창(`SeasonalBoss.window`)을 갖고 `SeasonRegistry.activeBoss()`가 시즌과 같은 스위치 3겹을 타는 구조는
  그대로 — 내년에 둘을 다르게 잡을 수 있다.
* **tier 오픈 = 오픈일 AND (사용 일수 OR 누적 VP)**(2026-11-10 사용자 결정 — 애초 안은 "12월 일일 보상 수령 일수"였다):

| tier | 오픈일 | 사용 일수 | 또는 누적 VP | 격파 보상(인스턴스당 1회) |
|---|---|---|---|---|
| localhost | 11/16 | — | — | 1,000 코인 |
| dev | 11/23 | 6일 | 400 | 3,000 코인 |
| staging | 11/30 | 12일 | 800 | 6,000 코인 |
| production | 12/7 | 18일 | 1,200 | 15,000 코인 + **프리미엄 가챠권 1장** + 칭호 **"눈길 배포 성공"** |

  * **오픈일**: 참여량을 아무리 채워도 그 날짜 전엔 안 열린다. 2026년 기준 매주 월요일(사용자 확정).
  * **사용 일수 / 누적 VP**: 보스가 열린 11/16 이후의 로컬 기록(`Settings.dailyVP`). 둘 중 하나만 채우면 된다.
    일수만 두면 12월 중순에 시작한 사람은 18일을 못 채워 production이 원천 봉쇄된다. VP만 두면 VP가 플랜 가격에
    비례해(월 최대 Free 500 / Pro 2,000 / Max 10,000 / Ultra 20,000) 저가 플랜이 막힌다. 그래서 OR —
    늦게 시작하면 몰아 써서 VP로, 저가 플랜은 꾸준히 써서 일수로.
  * VP 기준(400/800/1,200)은 Pro를 한도까지 쓸 때 일수 기준과 비슷한 시점에 닿는 **추정값**이다. 실사용 분포로
    검증하지 않았다.
  * 12월 일일 보상과의 연동은 없어졌다 → **랭킹 미등록 사용자도 전 tier에 닿는다**. 서버 의존 0.
  * 잠긴 버튼은 사유를 보여 준다: 날짜 전이면 "11/30 오픈", 날짜는 됐으면 "12일 또는 800VP".

  보상은 지역 관장(50/150/500/1500)의 **약 10~20배**로 일부러 크게 둔다(사용자 결정). 합계 25,000 코인 ≈ 뽑기 83회.
  프리미엄 가챠권은 로컬 재화(`Settings.premiumTickets`)다. 지급은 `CoinLedger.creditBonus` + 티켓 증가를 같은
  지점에서, `seasonalFlags` dedup 뒤에. tier별로 각각 1회 보상, 재도전 무제한. dedup은 `seasonalFlags`의
  `boss:xmas-2026:<tier>`. production 선봉은 레인보우(기존 규칙).
* 대사 4단계는 사용 일수로: 0 / 1~5 / 6+ / production 격파(마지막 줄 "인정"은 격파 뒤에만 — 구현 시 조정).
* 서버 변경 없음 — 관장 배틀은 완전 로컬.

대사 초안:

```
배송 큐가 비었군. 아직 아무것도 안 쓴 건가.
패킷이 들어오기 시작했다. 경로는 내가 잡지.
절반 넘겼군. 썰매도 이 정도면 autoscale 된다.
...눈길에서도 배포가 되는군. 인정.
```

## 27. 12월 칭호 정리

| 칭호 | 출처 | 조건 |
|---|---|---|
| 크리스마스에도 코딩함 | 2번 | 12/25 사용 이벤트 1건 |
| 연말 배포 freeze 위반 | 2번 | 코인 1,500 구매 |
| 12월 완주 | 3번 | 보상 20/24 |
| 눈길 배포 성공 | 4번 | production 보스 격파 |

전부 다른 행동을 보상하고 겹치지 않는다. 해금 판정은 모두 로컬(`seasonalFlags`/`claimedGrants`).

## 28. 바뀌는 곳

* `Season.swift`: `SeasonalBoss`, `SkinnedPet`, `PetSkin`
* `PetSprite.swift`: `skinned(_:skin:)` 리컬러 + 캐시 (hatAnchor는 1번에서 추가됨)
* `GymLeader.swift`: `team(lead:supports:tier:)` 추출
* `GymBattleView.swift`: `GymOpponent`, 승리 콜백 분리
* `BattleReplayView.swift`: 렌더 전용 스킨 맵 선택 인자
* `GymView.swift`: 시즌 보스 카드
* `TrainerCard.swift`: `CardTitle.snowDeployer`
* `Settings.swift`: `seasonalFlags: Set<String>` (2번 자동 칭호와 공유)
* `WorldMap.swift`: `EventIsland`, `MapCamera.worldView/regionView(skyRows:)`·`islandView`
* `WorldMapView.swift`: 섬 렌더(밑동·그림자·구름·눈)·선택·섬 아바타. `GymView`: `eventSelected`, `mapHeight`

## 29. 검증

* 테스트: 보상 일수 → 오픈 tier 집합(0/5/6/12/18 경계), tier별 보상 1회 dedup(재승리 0코인·티켓 0장, 내년 인스턴스는 재지급),
  칭호 해금, 시즌 밖 카드 숨김, 보스 팀 EP = 같은 tier 지역 관장 팀 EP(솔버 공유 증명), 기존 `GymBattle` 테스트
  회귀 없음, `BattlePetSnapshot` 인코딩이 변하지 않았음(파리티 보호).
* 프리뷰: 북극 원정대 5종 스킨 시트(원본↔snow 나란히, 체커 배경), 도장 탭 시즌 카드(`AIUSAGE_SEASON=xmas`,
  대사 4단계), 배틀 시트 `GymBattleSizeProbe`.

---

# 5번: 크리스마스 주간 선물 + 새해 칭호 (2026-11-10 추가)

## 30. 날짜별 선물 (12/21~25)

12/21(월)~12/25(금) 닷새 동안 메인 패널에 "오늘의 선물 (n/5)" 배너가 뜨고, 열면 그날 선물을 받는다. 뒤로 갈수록 커진다.

| 날짜 | 코인 | 가챠권 |
|---|---|---|
| 12/21 | 1,000 | 1 |
| 12/22 | 2,000 | 2 |
| 12/23 | 3,000 | 3 |
| 12/24 | 5,000 | 4 |
| 12/25 | 9,000 | 5 |

**합계 코인 20,000 + 가챠권 15장 — 사용자 결정(2026-11-10).** 닷새 배분은 매일 늘어나게 잡은 값이고 합계는 테스트가
고정한다. 겨울 관장 4단계 합(25,000 + 프리미엄권)에 맞먹는 규모다. 수치는 `SeasonRegistry`의 `gifts:` 배열 한 곳.

* **그날 것만 열린다. 소급 없음**(사용자 확정) — 놓친 날을 나중에 몰아 받게 하면 "점점 커진다"가 "25일에 한 번"이 된다.
* **로컬 지급**(`SeasonGiftBox`) — 서버를 거치지 않아 랭킹 미등록 사용자도 받는다(일일 보상 §20과 다른 점). 대신
  시계를 돌리면 미리 열 수 있다. 코인·일반 가챠권은 원래 로컬 경제라 감수하고, 서버가 검증하는 RP·프리미엄권은
  넣지 않는다.
* dedup은 `seasonalFlags`의 `gift:<instanceID>:<MM>-<DD>`(예: `gift:xmas-2026:12-23`). 날짜 경계는 KST.
* 시즌이 꺼져 있으면(연출 설정 off·킬스위치) 선물도 없다 — 판정은 `SeasonRegistry.active()` 한 곳.
* 날짜는 월/일 고정이라 내년엔 요일이 어긋난다(2027-12-21은 화요일). 내년에 다시 쓸 때 `gifts:`를 손본다.
* 프리뷰: `시즌/선물-배너`(1·3·5일차 × 열기 전/후).

## 31. 새해 칭호

`CardTitle.newYearFirstDay` "새해 첫날에도 출근함"(사용자 확정) — 1/1(KST)에 `UsageEvent` 1건 이상이면 자동 해금. `codedOnChristmas`와
같은 구조(`SeasonFlagLedger`가 `codedOn:<yyyy>-01-01` 기록), `season: .newYear`. 연말연시 시즌의 첫 고유 콘텐츠.

---

# 구현 상태 (2026-11-10, 브랜치 `feat/season-2026`, 미push — 릴리스 2026-11-16 · 소형 릴리스 12/14)

이슈: Feature #271 / T1 #272 · T2 #273 · T3 #274 · T4 #275 · T5 #276 · T6 #277 · T7 #278

| 커밋 | 범위 | 상태 |
|---|---|---|
| T1 `refactor(report)` #272 | 리포트/꾸미기 분리, 칭호 3묶음 그리드, 공유 메뉴, `FlowLayout` | 완료 |
| T2 `feat(report)` 잔디 #273 | `DailyUsageLedger`, `UsageGrassModel/View`, `PetTheme.grassLevels` | 완료 — 11/16 릴리스로 12/1 전 보름치 적립 |
| T4 `feat(season)` 기반 #275 | `Season`/`SeasonRegistry`(KST), `ParticleStyle`, headwear 앵커, 시즌 대사, 오피스 창문 눈, 킬스위치 | 완료 |
| T5 `feat(season)` 코스메틱 #276 | 액세서리 3·snowfall·winterNight·칭호 2·`shopVisible`·`SeasonBadge`·오피스 데코 6종(트리·전구 줄·배너·리스·눈사람·선물 상자) | 완료 — 6종 모두 컨펌 완료(2026-11-10) |
| T6 `feat(season)` 일일 보상 #277 | 서버 `_shared/season.ts`+`submit` 훅+퀴즈 힌트, 잔디 보상 마크, 12월 완주, 알림 | 완료 — 서버 배포는 11/13~14(사용자) |
| T7 `feat(season)` 겨울 관장 #278 | `SeasonalBoss`, snow 스킨, `GymOpponent`, tier 오픈, 격파 보상, 눈길 배포 성공, **월드맵 이벤트 섬 진입점**, 11/16 선오픈, tier = 오픈일 AND (일수 OR VP) | 완료 — snow 톤·이벤트 섬·tier 조건(오픈일·일수·VP 값 포함) 사용자 확정(2026-11-10) |
| T3 액세서리 11종 도트 PNG #274 | 팩 미발견 → **직접 16×16 도트 제작 예외 허용(사용자)**, 결과물 컨펌 필수 | 완료 — 컨펌 완료(7affcd9) |
| 5번 선물·새해 칭호 (이슈 없음) | `SeasonGift`/`SeasonGiftBox`, 패널 `SeasonGiftBanner`, `CardTitle.newYearFirstDay` | 완료 — 선물 합계(20,000 + 15장)·칭호 이름 사용자 확정 |

프리뷰: `bash scripts/render-previews.sh` 후 `0-headwear-*`(195종 모자 앵커), `0-season-boss-skins`, `탭-*-12월`,
`사무실-12월데코`(GIF — 트리·전구 줄 깜빡임과 벽 데코 배치), `map-xmas-월드`·`map-xmas-섬`(이벤트 섬).
main 반영: 2026-11-10 `a860732`(v0.19.4 이후)까지 **merge**(28c4be3). rebase 금지 — pre-push 훅이 첫 커밋
`18e57e6`의 자손 여부로 막으므로 해시가 바뀌면 가드가 풀린다.

테스트: `swift test` 542개(41 skip) + `deno test supabase/functions/_shared/season.test.ts`.
