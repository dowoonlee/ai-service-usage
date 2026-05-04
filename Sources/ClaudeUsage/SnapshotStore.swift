import Foundation

final class JSONLStore<T: Codable> {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `directory` 인자는 테스트 격리용 — nil이면 ~/Library/Application Support/ClaudeUsage/.
    init(filename: String, label: String, directory: URL? = nil) {
        let fm = FileManager.default
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
        }
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent(filename)
        self.queue = DispatchQueue(label: label)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func append(_ value: T) {
        queue.sync {
            guard let data = try? encoder.encode(value) else { return }
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
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
}
