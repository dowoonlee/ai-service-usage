import Foundation

/// (실험) 서버에서 받은 펫 메타데이터(이름/대사/설명) override 저장소 + resolver.
///
/// 정책: **코드 하드코딩 = fallback, 서버 = override.**
/// - feature flag `Settings.experimentalRemotePetMeta` 가 켜졌을 때만 override 적용.
/// - flag off / 네트워크 실패 / 해당 kind 누락 / 빈 값 → 항상 코드값(`Quotes`/`PetDescriptions`/
///   `PetKind.displayName`)으로 fallback. 따라서 이 store가 비어 있어도 앱은 정상 동작.
///
/// 등급(tier)·스프라이트 렌더 메타는 의도적으로 다루지 않는다 — 코드에 고정.
struct RemotePetMeta: Codable, Sendable {
    let displayName: String
    let description: String
    let quotes: [String]
}

@MainActor
final class PetMetaStore {
    static let shared = PetMetaStore()
    private init() {}

    /// 서버 override (PetKind 매핑 완료). 비어 있으면 호출처가 코드 fallback 사용.
    private(set) var byKind: [PetKind: RemotePetMeta] = [:]

    /// `~/Library/Application Support/ClaudeUsage/pet-meta.json` — 오프라인 다음 실행용 캐시.
    /// (`JSONLStore`는 append-only라 부적합 → 단일 JSON 파일을 직접 read/write.)
    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("ClaudeUsage/pet-meta.json")
    }

    // MARK: - 로드/갱신

    /// 디스크 캐시 → 메모리. 앱 시작 시 1회 (네트워크 전에 직전 값 즉시 사용).
    func load() {
        guard let url = Self.cacheURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: RemotePetMeta].self, from: data)
        else { return }
        byKind = Self.mapKinds(decoded)
        DebugLog.log("PetMetaStore: loaded \(byKind.count) from disk cache")
    }

    /// 서버 fetch → 메모리 + 디스크. flag 무관하게 받아 둔다(override 적용은 resolver가 flag 확인).
    /// 실패해도 throw하지 않음 — 기존 캐시/코드 fallback 유지.
    func refresh() async {
        guard RankingAPI.isConfigured else { return }
        do {
            let resp = try await RankingAPI.shared.fetchPetMetadata()
            var dict: [String: RemotePetMeta] = [:]
            for row in resp.pets {
                dict[row.kind] = RemotePetMeta(displayName: row.displayName,
                                               description: row.description,
                                               quotes: row.quotes)
            }
            byKind = Self.mapKinds(dict)
            Self.persist(dict)
            DebugLog.log("PetMetaStore: refreshed \(byKind.count) from server")
        } catch {
            DebugLog.log("PetMetaStore: refresh failed (keep cache/fallback): \(error)")
        }
    }

    private static func mapKinds(_ dict: [String: RemotePetMeta]) -> [PetKind: RemotePetMeta] {
        var out: [PetKind: RemotePetMeta] = [:]
        for (k, v) in dict where !v.displayName.isEmpty {
            if let kind = PetKind(rawValue: k) { out[kind] = v }
        }
        return out
    }

    private static func persist(_ dict: [String: RemotePetMeta]) {
        guard let url = Self.cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dict)
            try data.write(to: url, options: .atomic)
        } catch {
            DebugLog.log("PetMetaStore: persist failed: \(error)")
        }
    }

    // MARK: - Resolver (override 우선 + 코드 fallback)
    // 호출처는 기존 `kind.displayName`/`Quotes.random`/`PetDescriptions.description` 대신 이걸 사용.

    func displayName(for kind: PetKind) -> String {
        if Settings.shared.experimentalRemotePetMeta, let n = byKind[kind]?.displayName, !n.isEmpty {
            return n
        }
        return kind.displayName
    }

    func description(for kind: PetKind) -> String {
        if Settings.shared.experimentalRemotePetMeta, let d = byKind[kind]?.description, !d.isEmpty {
            return d
        }
        return PetDescriptions.description(for: kind)
    }

    /// 종 전용 대사 한 줄. override가 있으면 그 풀에서 랜덤, 없으면 코드 풀.
    func quote(for kind: PetKind) -> String {
        if Settings.shared.experimentalRemotePetMeta, let q = byKind[kind]?.quotes, !q.isEmpty {
            return q.randomElement() ?? Quotes.random(for: kind)
        }
        return Quotes.random(for: kind)
    }
}
