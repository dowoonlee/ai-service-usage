import Foundation

enum DebugLog {
    static let fileURL: URL = {
        let fm = FileManager.default
        // Application Support 조회 실패 시 (sandbox/권한 이상) NSTemporaryDirectory()로 폴백 —
        // 로그 1개 잃는 게 try! crash보다 낫다. 첫 접근 시점이 static let 초기화라 trace 없이 죽음.
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let logURL = dir.appendingPathComponent("debug.log")
        if fm.fileExists(atPath: logURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        return logURL
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
                restrictFilePermissions()
            }
        }
    }

    private static func restrictFilePermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 회전 임계 — 이 사이즈 초과면 시작 시 1회 `.bak` 으로 rename, 새 파일 시작.
    /// 매 append마다 size 체크는 비용 부담이라 launch 시 1회만 검사.
    static let rotateThreshold: Int64 = 5 * 1024 * 1024  // 5 MB

    /// App 시작 시 1회 호출. 현재 `debug.log`가 임계를 넘었으면 `debug.log.bak`으로
    /// rename(기존 `.bak`은 덮어씀) → 새 빈 `debug.log`로 다음 폴링부터 기록 시작.
    /// `applicationDidFinishLaunching` 가장 앞에서 호출되므로 다른 컴포넌트의 첫 log 호출
    /// 이전에 회전 완료 — race 없음.
    static func rotateIfNeeded() {
        queue.async {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int64,
                  size > rotateThreshold else { return }
            let bakURL = fileURL.appendingPathExtension("bak")
            try? fm.removeItem(at: bakURL)
            try? fm.moveItem(at: fileURL, to: bakURL)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bakURL.path)
        }
    }
}
