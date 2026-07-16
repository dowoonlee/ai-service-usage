import Foundation

// 결정론적 사주 명리학 계산. 외부 의존성 0.
//
// 입력: GitHub 계정 `created_at` (UTC ISO 8601) → KST 변환 → 사주팔자(년/월/일/시주) + 오행 분포.
// 일진(오늘의 천간지지) + 일간 vs 일진 관계까지.
//
// 정확도:
//   * 절기는 평년 기준 (month, day) 비교 — ±1일 오차. 절기 경계에 태어난 사용자
//     (전체의 ~5%)는 오차가 있을 수 있지만 "재미" 기능이라 수용.
//   * 일주는 1900-01-31 (갑진일) 기준 정확 — 60갑자 일진은 천체 무관 단순 카운터.
//   * 시주는 GitHub created_at 의 UTC 시간을 KST 변환한 값 사용. 실제 출생시가 아니라
//     "참고용". LLM 프롬프트에 그 약속을 박음.

// MARK: - 천간 (10간)

enum HeavenlyStem: Int, CaseIterable, Codable {
    case gap = 0, eul, byeong, jeong, mu, gi, gyeong, sin, im, gye

    var korean: String { ["갑","을","병","정","무","기","경","신","임","계"][rawValue] }

    /// 갑을=목, 병정=화, 무기=토, 경신=금, 임계=수
    var element: FiveElement {
        switch self {
        case .gap, .eul:     return .wood
        case .byeong, .jeong: return .fire
        case .mu, .gi:       return .earth
        case .gyeong, .sin:  return .metal
        case .im, .gye:      return .water
        }
    }

    /// 갑/병/무/경/임 = 양, 을/정/기/신/계 = 음
    var yinYang: YinYang { rawValue % 2 == 0 ? .yang : .yin }
}

// MARK: - 지지 (12지)

enum EarthlyBranch: Int, CaseIterable, Codable {
    // Swift 키워드 `in` 충돌 회피 → `inwol`(인)
    case ja = 0, chuk, inwol, myo, jin, sa, o, mi, sin, yu, sul, hae

    var korean: String { ["자","축","인","묘","진","사","오","미","신","유","술","해"][rawValue] }

    /// 인묘=목, 사오=화, 진술축미=토(土가 사방에 배치), 신유=금, 자해=수
    var element: FiveElement {
        switch self {
        case .inwol, .myo:                 return .wood
        case .sa, .o:                      return .fire
        case .jin, .sul, .chuk, .mi:       return .earth
        case .sin, .yu:                    return .metal
        case .ja, .hae:                    return .water
        }
    }
}

// MARK: - 오행 + 관계

enum FiveElement: String, CaseIterable, Codable {
    case wood  = "목"
    case fire  = "화"
    case earth = "토"
    case metal = "금"
    case water = "수"
}

enum YinYang: String, Codable {
    case yin = "음"
    case yang = "양"
}

/// 일간 입장에서 본 오늘 천간 오행 관계 — 명리학 단순화 5분류.
enum ElementRelation: String, Codable {
    case same       = "비화"   // 같은 오행 — 평이한 결의 날
    case generates  = "상생"   // 일간이 오늘을 생함 — 내가 표현/배출하는 날
    case generated  = "피생"   // 오늘이 일간을 생함 — 도움/지원받는 날
    case overcomes  = "상극"   // 일간이 오늘을 극함 — 내가 다스리는 날
    case overcome   = "피극"   // 오늘이 일간을 극함 — 압박받는 날
}

// MARK: - 사주 모델

struct SajuPillar: Codable, Equatable {
    let stem: HeavenlyStem
    let branch: EarthlyBranch
    var name: String { "\(stem.korean)\(branch.korean)" }
}

struct SajuChart: Codable {
    let year: SajuPillar
    let month: SajuPillar
    let day: SajuPillar
    let hour: SajuPillar
    let fiveElementCounts: [FiveElement: Int]   // 8글자 오행 분포

    var dayStem: HeavenlyStem { day.stem }

    /// "갑자 · 을축 · 병인 · 정묘" 같은 사람이 읽을 수 있는 한 줄.
    var displayString: String {
        "\(year.name) · \(month.name) · \(day.name) · \(hour.name)"
    }
}

struct DailyFortune: Codable {
    let today: SajuPillar
    let relation: ElementRelation
}

// MARK: - 계산기

enum SajuEngine {
    /// 명리학 기준 시간대. GitHub created_at(UTC) 을 KST 로 변환해 사용.
    static let kst = TimeZone(identifier: "Asia/Seoul")!

    /// 서버 KST "오늘"과 동기화되는 `yyyy-MM-dd` 포맷터. 퀴즈/운세 VM이 각자 동일 4줄로
    /// 정의하던 것을 하나로 모은다. 서버가 콘텐츠 갱신 경계를 KST 자정으로 고정하므로,
    /// 클라의 today 문자열도 반드시 이 포맷터(로컬 타임존 아님)를 써야 일치한다.
    static let kstDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = kst
        return f
    }()

    /// 출생일(또는 GitHub 가입일)로부터 사주팔자 생성.
    static func chart(for birth: Date, in tz: TimeZone = SajuEngine.kst) -> SajuChart {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: birth)
        let year = comps.year ?? 2000
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 12

        // 년주 — 입춘(2월 4일경) 이전은 전년도로 본다.
        let sajuYear = (month < 2 || (month == 2 && day < 4)) ? year - 1 : year
        let yearStemIdx = mod(sajuYear - 4, 10)
        let yearBranchIdx = mod(sajuYear - 4, 12)
        let yearPillar = SajuPillar(
            stem: HeavenlyStem(rawValue: yearStemIdx)!,
            branch: EarthlyBranch(rawValue: yearBranchIdx)!
        )

        // 월주 — 절기 기준 (양력 month/day 로 단순화)
        let monthBranch = monthBranch(month: month, day: day)
        // 五虎遁: 인월(寅月) 천간 = (yearStem * 2 + 2) % 10
        //   甲己→丙寅, 乙庚→戊寅, 丙辛→庚寅, 丁壬→壬寅, 戊癸→甲寅
        let inStemIdx = (yearStemIdx * 2 + 2) % 10
        let monthOffset = mod(monthBranch.rawValue - EarthlyBranch.inwol.rawValue, 12)
        let monthStemIdx = (inStemIdx + monthOffset) % 10
        let monthPillar = SajuPillar(
            stem: HeavenlyStem(rawValue: monthStemIdx)!,
            branch: monthBranch
        )

        // 일주 — 60갑자 일진
        let dayPillar = pillar(forDayAt: birth, in: tz)

        // 시주 — 五鼠遁
        // 시지지: 23-01=자, 01-03=축, 03-05=인, ..., 21-23=해
        let hourBranchIdx = ((hour + 1) / 2) % 12
        // 子時 천간: 甲己→甲子, 乙庚→丙子, 丙辛→戊子, 丁壬→庚子, 戊癸→壬子
        let jaSiStemIdx = (dayPillar.stem.rawValue * 2) % 10
        let hourStemIdx = (jaSiStemIdx + hourBranchIdx) % 10
        let hourPillar = SajuPillar(
            stem: HeavenlyStem(rawValue: hourStemIdx)!,
            branch: EarthlyBranch(rawValue: hourBranchIdx)!
        )

        // 오행 분포 — 4 stem + 4 branch.
        var counts: [FiveElement: Int] = [
            .wood: 0, .fire: 0, .earth: 0, .metal: 0, .water: 0,
        ]
        for p in [yearPillar, monthPillar, dayPillar, hourPillar] {
            counts[p.stem.element, default: 0] += 1
            counts[p.branch.element, default: 0] += 1
        }

        return SajuChart(
            year: yearPillar,
            month: monthPillar,
            day: dayPillar,
            hour: hourPillar,
            fiveElementCounts: counts
        )
    }

    /// 오늘(또는 임의의 날짜)의 60갑자 일진 + 사용자 일간과의 관계.
    static func daily(for date: Date,
                      against userDayStem: HeavenlyStem,
                      in tz: TimeZone = SajuEngine.kst) -> DailyFortune {
        let today = pillar(forDayAt: date, in: tz)
        let userEl = userDayStem.element
        let todayEl = today.stem.element
        return DailyFortune(today: today, relation: relation(from: userEl, to: todayEl))
    }

    // MARK: - 내부 헬퍼

    /// 1900-01-31 갑진(甲辰)일 기준. 일수 차이로 60갑자 매핑 — 천체 무관 단순 카운터.
    private static func pillar(forDayAt date: Date, in tz: TimeZone) -> SajuPillar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let reference = cal.date(from: DateComponents(
            timeZone: tz, year: 1900, month: 1, day: 31
        ))!
        let refStart = cal.startOfDay(for: reference)
        let inputStart = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: refStart, to: inputStart).day ?? 0
        // 1900-01-31 = stem 0 (갑), branch 4 (진)
        let stemIdx = mod(days, 10)
        let branchIdx = mod(days + 4, 12)
        return SajuPillar(
            stem: HeavenlyStem(rawValue: stemIdx)!,
            branch: EarthlyBranch(rawValue: branchIdx)!
        )
    }

    /// 양력 (month, day) → 12지지 월. 절기 경계는 평년 기준 ±1일 오차 허용.
    /// 12개 절(節): 입춘(2/4), 경칩(3/5), 청명(4/5), 입하(5/5), 망종(6/6), 소서(7/7),
    ///              입추(8/7), 백로(9/8), 한로(10/8), 입동(11/7), 대설(12/7), 소한(1/5)
    private static func monthBranch(month: Int, day: Int) -> EarthlyBranch {
        // 절기 경계는 "그 날부터 다음 절기까지"가 해당 월.
        // 표 항목: 각 절 시작일과 그 결과 지지.
        let m = month, d = day
        if (m == 1  && d <  5) || (m == 12 && d >= 7) { return .ja    } // 대설~소한 = 자월
        if (m == 1  && d >= 5) || (m == 2  && d <  4) { return .chuk  } // 소한~입춘 = 축월
        if (m == 2  && d >= 4) || (m == 3  && d <  5) { return .inwol } // 입춘~경칩 = 인월
        if (m == 3  && d >= 5) || (m == 4  && d <  5) { return .myo   } // 경칩~청명 = 묘월
        if (m == 4  && d >= 5) || (m == 5  && d <  5) { return .jin   } // 청명~입하 = 진월
        if (m == 5  && d >= 5) || (m == 6  && d <  6) { return .sa    } // 입하~망종 = 사월
        if (m == 6  && d >= 6) || (m == 7  && d <  7) { return .o     } // 망종~소서 = 오월
        if (m == 7  && d >= 7) || (m == 8  && d <  7) { return .mi    } // 소서~입추 = 미월
        if (m == 8  && d >= 7) || (m == 9  && d <  8) { return .sin   } // 입추~백로 = 신월
        if (m == 9  && d >= 8) || (m == 10 && d <  8) { return .yu    } // 백로~한로 = 유월
        if (m == 10 && d >= 8) || (m == 11 && d <  7) { return .sul   } // 한로~입동 = 술월
        if (m == 11 && d >= 7) || (m == 12 && d <  7) { return .hae   } // 입동~대설 = 해월
        return .ja  // unreachable — 모든 (month, day) 가 위 조건 중 하나에 매칭됨.
    }

    /// 오행 상생/상극 관계 — 일간(a) 입장에서 오늘 천간 오행(b) 을 본다.
    /// 상생 순환: 목→화→토→금→수→목 (cycle index diff=1)
    /// 상극 순환: 목→토→수→화→금→목 (cycle index diff=2 in 상생 순환)
    private static func relation(from a: FiveElement, to b: FiveElement) -> ElementRelation {
        if a == b { return .same }
        let cycle: [FiveElement] = [.wood, .fire, .earth, .metal, .water]
        let ai = cycle.firstIndex(of: a)!
        let bi = cycle.firstIndex(of: b)!
        let diff = (bi - ai + 5) % 5
        switch diff {
        case 1: return .generates   // a → b
        case 4: return .generated   // b → a (역방향 한 칸)
        case 2: return .overcomes   // a 가 b 를 극함
        case 3: return .overcome    // b 가 a 를 극함 (역방향 한 칸 = 한 칸 건너 반대)
        default: return .same       // unreachable
        }
    }

    /// 음수 입력도 양수 결과를 주는 mod. Swift `%` 는 음수를 그대로 두므로 직접 보정.
    private static func mod(_ a: Int, _ n: Int) -> Int {
        let r = a % n
        return r < 0 ? r + n : r
    }
}
