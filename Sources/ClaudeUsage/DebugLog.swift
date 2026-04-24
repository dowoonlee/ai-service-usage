import Foundation

enum DebugLog {
    static let fileURL: URL = {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private static let queue = DispatchQueue(label: "ClaudeUsage.DebugLog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL, options: .atomic)
                }
            }
        }
    }
}
