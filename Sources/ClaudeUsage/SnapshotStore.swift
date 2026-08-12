import Foundation

/// JSONL 파일 무한 성장 방지 기본 정책 — 8MB를 넘으면 뒤쪽 4MB만 남긴다.
/// 4MB면 스냅샷 ~16,000행(10분 폴링 기준 3개월+), cursor 이벤트 ~33,000행이라
/// `loadRecent` 상한(스냅샷 500 / 이벤트 20,000)에 충분한 여유가 있다.
private let defaultCompactThresholdBytes = 8 * 1024 * 1024
private let defaultCompactKeepBytes = 4 * 1024 * 1024
/// append마다 stat을 부르지 않도록 이 횟수에 한 번만 크기를 검사한다.
private let compactCheckInterval = 200

final class JSONLStore<T: Codable> {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let compactThresholdBytes: Int
    private let compactKeepBytes: Int
    private var appendsSinceCompactCheck = 0

    /// `directory`와 compaction 임계는 테스트 격리·주입용 — nil/기본값이면
    /// ~/Library/Application Support/ClaudeUsage/ + 위 기본 정책.
    init(filename: String, label: String, directory: URL? = nil,
         compactThresholdBytes: Int = defaultCompactThresholdBytes,
         compactKeepBytes: Int = defaultCompactKeepBytes) {
        self.compactThresholdBytes = compactThresholdBytes
        self.compactKeepBytes = compactKeepBytes
        let fm = FileManager.default
        let dir: URL
        if let directory {
            dir = directory
        } else {
            // Application Support 조회 실패 시 NSTemporaryDirectory()로 폴백 —
            // ViewModel.init이 SnapshotStore static 초기화를 트리거하므로 try! crash 시 앱 즉사.
            let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
        }
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        self.fileURL = dir.appendingPathComponent(filename)
        self.queue = DispatchQueue(label: label)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        if fm.fileExists(atPath: fileURL.path) {
            restrictFilePermissions()
        }
    }

    func append(_ value: T) {
        queue.sync {
            let data: Data
            do {
                data = try encoder.encode(value)
            } catch {
                // 인코딩 실패를 조용히 삼키면 재시작 후 history·코인 적립 기준점이 어긋나도 진단이 안 됨.
                DebugLog.log("JSONLStore.append 인코딩 실패 \(fileURL.lastPathComponent): \(error)")
                return
            }
            var line = data
            line.append(0x0A)
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: fileURL, options: .atomic)
                }
            } catch {
                DebugLog.log("JSONLStore.append 쓰기 실패 \(fileURL.lastPathComponent): \(error)")
                return
            }
            restrictFilePermissions()
            appendsSinceCompactCheck += 1
            if appendsSinceCompactCheck >= compactCheckInterval {
                appendsSinceCompactCheck = 0
                compactIfNeeded()
            }
        }
    }

    private func restrictFilePermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 파일이 상한을 넘으면 뒤쪽 `compactKeepBytes`만 남기고 잘라낸다. **`queue` 안에서만 호출.**
    ///
    /// 스냅샷은 폴링마다, cursor 이벤트는 사용마다 append돼 상한이 없었다(헤비 Ultra 사용자면
    /// 수십 MB까지 자란다). 줄 수 기준으로 자르려면 파일을 통째로 읽어야 하므로 크기로 판단하고,
    /// JSONL이라 바이트 경계에서 잘라도 첫 개행까지 버리면 항상 유효한 라인에서 시작한다
    /// (`loadRecent`의 partial 라인 처리와 같은 규칙). 쓰기는 atomic이라 도중 크래시에도
    /// 원본이 통째로 날아가지 않는다.
    private func compactIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > compactThresholdBytes else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        var tail: Data
        do {
            try handle.seek(toOffset: UInt64(max(0, size - compactKeepBytes)))
            tail = try handle.readToEnd() ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            DebugLog.log("JSONLStore compaction 읽기 실패 \(fileURL.lastPathComponent): \(error)")
            return
        }
        // 첫 라인은 바이트 경계에서 잘렸을 수 있으니 첫 개행까지 폐기.
        if let firstNL = tail.firstIndex(of: 0x0A) {
            tail.removeSubrange(tail.startIndex...firstNL)
        }
        do {
            try tail.write(to: fileURL, options: .atomic)
            restrictFilePermissions()
            DebugLog.log("JSONLStore compaction \(fileURL.lastPathComponent): \(size)B → \(tail.count)B")
        } catch {
            DebugLog.log("JSONLStore compaction 쓰기 실패 \(fileURL.lastPathComponent): \(error)")
        }
    }

    /// 파일 끝에서부터 청크 단위(64KB)로 거꾸로 읽으며 newline 수가 limit+1 도달하면 멈춘다.
    /// limit ≪ 전체 라인 수일 때 전체 파일 read보다 훨씬 빠름. 라인 수가 적으면 자연스럽게
    /// BOF까지 읽으므로 동작은 동일.
    /// BOF 미도달 시 첫 라인은 청크 경계에서 잘렸을 수 있어 byte 레벨에서 첫 0x0A까지 폐기 →
    /// String(data:encoding:.utf8)이 multi-byte 경계에서 깨지는 것 방지. (append가 항상 \n
    /// 종결자를 쓰므로 0x0A 이후는 항상 valid UTF-8 boundary.)
    func loadRecent(limit: Int = 500) -> [T] {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
            defer { try? handle.close() }
            let endOffset: UInt64
            do { endOffset = try handle.seekToEnd() }
            catch { return [] }
            if endOffset == 0 { return [] }

            let chunkSize: UInt64 = 64 * 1024
            var offset = endOffset
            var buffer = Data()
            var newlines = 0

            // limit+1 newline을 모으면 첫 partial 라인을 버려도 limit개는 보장.
            while offset > 0 && newlines < limit + 1 {
                let readSize = min(chunkSize, offset)
                offset -= readSize
                do {
                    try handle.seek(toOffset: offset)
                    let chunk = try handle.read(upToCount: Int(readSize)) ?? Data()
                    buffer = chunk + buffer
                    newlines += chunk.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
                } catch { break }
            }

            // BOF 미도달이면 첫 라인은 청크 경계 partial — 첫 0x0A 직전까지 byte로 자른다.
            if offset > 0, let firstNL = buffer.firstIndex(of: 0x0A) {
                buffer.removeSubrange(buffer.startIndex...firstNL)
            }

            guard let text = String(data: buffer, encoding: .utf8) else { return [] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
            var out: [T] = []
            out.reserveCapacity(lines.count)
            for line in lines {
                if let d = line.data(using: .utf8),
                   let v = try? decoder.decode(T.self, from: d) {
                    out.append(v)
                }
            }
            return out
        }
    }

    var storageURL: URL { fileURL }
}

enum SnapshotStore {
    static let claude = JSONLStore<UsageSnapshot>(
        filename: "snapshots.jsonl",
        label: "ClaudeUsage.ClaudeStore"
    )
    static let cursor = JSONLStore<CursorSnapshot>(
        filename: "cursor-snapshots.jsonl",
        label: "ClaudeUsage.CursorStore"
    )
    static let cursorEvents = JSONLStore<CursorEvent>(
        filename: "cursor-events.jsonl",
        label: "ClaudeUsage.CursorEvents"
    )
    static let codex = JSONLStore<CodexSnapshot>(
        filename: "codex-snapshots.jsonl",
        label: "ClaudeUsage.CodexStore"
    )
}
