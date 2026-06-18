import Foundation

/// 메인 패널에 비/눈 파티클을 띄우기 위한 현재 날씨 상태.
/// 흐림·안개·맑음 등 파티클이 필요 없는 모든 코드는 `.clear`로 접는다.
enum WeatherCondition: String, Codable, Sendable {
    case clear
    case rain
    case snow
    case thunder

    /// WMO weather interpretation code → 파티클 상태.
    /// 표: https://open-meteo.com/en/docs (weather_code).
    /// - 95~99: 뇌우 → thunder (비 + 번개 플래시)
    /// - 71~77, 85~86: 눈/소낙눈 → snow
    /// - 51~67, 80~82: 이슬비/비/어는비/소나기 → rain
    /// - 그 외(맑음·구름·안개 등): clear
    static func from(wmoCode code: Int) -> WeatherCondition {
        switch code {
        case 95, 96, 97, 98, 99:
            return .thunder
        case 71...77, 85, 86:
            return .snow
        case 51...67, 80, 81, 82:
            return .rain
        default:
            return .clear
        }
    }
}

/// 날씨 파티클을 그릴 기준 위치. IP/위치권한 없이 고정 좌표 2곳만 제공한다 —
/// 외부로 IP가 나가지 않고, CoreLocation 권한/ad-hoc 서명 이슈도 회피.
enum WeatherLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case utower   // U타워 (정자)
    case seorin   // 서린 (서울)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .utower: return "U타워 (정자)"
        case .seorin: return "서린 (서울)"
        }
    }

    /// SK u-타워(정자) / SK서린빌딩(종로) 일대 좌표. 날씨는 도시 단위면 충분해 정밀도 불필요.
    var latitude: Double {
        switch self {
        case .utower: return 37.3663
        case .seorin: return 37.5704
        }
    }
    var longitude: Double {
        switch self {
        case .utower: return 127.1082
        case .seorin: return 126.9780
        }
    }
}

/// 날씨 1회 조회 결과 — 유형 + 강도(0...1).
/// 강도는 강수/강설량을 정규화한 값으로, 파티클 밀도를 비례시키는 데 쓴다.
/// `clear`면 강도는 0 (파티클 렌더 안 함).
struct WeatherReading: Sendable {
    let condition: WeatherCondition
    let intensity: Double
}

enum WeatherError: Error {
    case http(Int)
    case transport(Error)
    case decoding(Error)
}

/// Open-Meteo(무료·API 키 불필요·HTTPS)로 현재 날씨 코드를 가져온다.
/// `UsageAPI`/`CursorAPI`와 같은 actor + async/await + 에러 분류 컨벤션을 따른다.
actor WeatherAPI {
    static let shared = WeatherAPI()

    private let ua = "AIUsage/weather (macOS)"

    // 강도 정규화 기준 — 이 값 이상이면 강도 1.0(파티클 최대 밀도).
    private let rainMaxMMPerHour = 7.0   // 강한 비~폭우 (mm/h)
    private let snowMaxCMPerHour = 2.0   // 강설 (cm/h)
    /// 코드가 비/눈이면 측정값이 적어도 최소 이만큼은 보장 (양 0 보고 시에도 약하게 표시).
    private let intensityFloor = 0.25

    func fetch(_ location: WeatherLocation) async throws -> WeatherReading {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "weather_code,precipitation,rain,showers,snowfall"),
            URLQueryItem(name: "timezone", value: "Asia/Seoul"),
        ]
        guard let url = comps.url else { throw WeatherError.http(-1) }

        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw WeatherError.transport(error)
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            DebugLog.log("Weather GET open-meteo (\(location.rawValue)) -> status=\(status) bytes=\(data.count)")
            throw WeatherError.http(status)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let cur = decoded.current
            let condition = WeatherCondition.from(wmoCode: cur.weather_code)
            let intensity = self.intensity(for: condition, current: cur)
            DebugLog.log("Weather (\(location.rawValue)) -> code=\(cur.weather_code) \(condition.rawValue) intensity=\(String(format: "%.2f", intensity))")
            return WeatherReading(condition: condition, intensity: intensity)
        } catch {
            throw WeatherError.decoding(error)
        }
    }

    /// 강수/강설량(mm·cm)을 0...1 강도로 정규화. clear는 0.
    private func intensity(for condition: WeatherCondition, current cur: OpenMeteoResponse.Current) -> Double {
        switch condition {
        case .clear:
            return 0
        case .snow:
            return normalize(cur.snowfall ?? 0, max: snowMaxCMPerHour)
        case .rain, .thunder:
            // 비/뇌우 — rain·showers·precipitation 중 가장 큰 값을 강수량으로.
            let mm = Swift.max(cur.rain ?? 0, cur.showers ?? 0, cur.precipitation ?? 0)
            return normalize(mm, max: rainMaxMMPerHour)
        }
    }

    private func normalize(_ value: Double, max: Double) -> Double {
        guard max > 0 else { return 1 }
        let v = Swift.max(0, value) / max
        return Swift.min(1.0, Swift.max(intensityFloor, v))
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let weather_code: Int
            let precipitation: Double?
            let rain: Double?
            let showers: Double?
            let snowfall: Double?
        }
        let current: Current
    }
}
