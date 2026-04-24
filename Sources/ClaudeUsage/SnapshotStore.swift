import Foundation

final class JSONLStore<T: Codable> {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String, label: String) {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
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

    func loadRecent(limit: Int = 500) -> [T] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = lines.suffix(limit)
            var out: [T] = []
            out.reserveCapacity(tail.count)
            for line in tail {
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
