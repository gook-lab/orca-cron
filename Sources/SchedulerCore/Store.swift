import Foundation

/// 데이터 폴더. 기본 ~/.orca-cron(셸 명령에 그대로 쓰도록 공백 없는 경로), ORCA_CRON_HOME 으로 바꿀 수 있다.
public struct Paths: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static func standard() -> Paths {
        if let env = ProcessInfo.processInfo.environment["ORCA_CRON_HOME"], !env.isEmpty {
            return Paths(base: URL(fileURLWithPath: env, isDirectory: true))
        }
        return Paths(base: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".orca-cron", isDirectory: true))
    }

    public var schedules: URL { base.appendingPathComponent("schedules.json") }
    public var tasks: URL { base.appendingPathComponent("tasks", isDirectory: true) }
    public var results: URL { base.appendingPathComponent("results", isDirectory: true) }
    public var log: URL { base.appendingPathComponent("log.txt") }

    public func ensure() throws {
        for dir in [base, tasks, results] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum Store {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 파일이 없으면 빈 목록. 읽을 수 없으면 던진다(호출자는 그때 저장하지 않는다 — 덮어쓰기 방지).
    public static func load(_ paths: Paths) throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: paths.schedules.path) else { return StoreFile() }
        return try decoder().decode(StoreFile.self, from: Data(contentsOf: paths.schedules))
    }

    public static func save(_ store: StoreFile, _ paths: Paths) throws {
        try encoder().encode(store).write(to: paths.schedules, options: .atomic)
    }

    public static func writeResult(_ result: RunResult, _ paths: Paths) throws {
        let url = paths.results.appendingPathComponent("\(result.runId).json")
        try encoder().encode(result).write(to: url, options: .atomic)
    }

    public static func readResults(_ paths: Paths) -> [(URL, RunResult)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.results, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let r = try? decoder().decode(RunResult.self, from: data) else { return nil }
            return (url, r)
        }
    }

    public static func removeResults(_ urls: [URL]) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    public static func appendLog(_ lines: [String], _ paths: Paths, now: Date) {
        guard !lines.isEmpty else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = lines.map { "\(f.string(from: now))  \($0)\n" }.joined()
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: paths.log) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: paths.log)
        }
    }

    /// tasks/*.md — 첫 줄 `# 제목`, 둘째 줄 한 줄 설명.
    public static func listTasks(_ paths: Paths) -> [TaskFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.tasks, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.map { url in
            let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let key = url.deletingPathExtension().lastPathComponent
            let title = lines.first.map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : String($0) } ?? key
            let detail = lines.count > 1 ? String(lines[1]) : ""
            return TaskFile(key: key, title: title.isEmpty ? key : title, detail: detail)
        }.sorted { $0.title < $1.title }
    }
}

/// 템플릿 = tasks/<키>.md. 형식: `# 제목` / 한 줄 설명 / 빈 줄 / 본문.
public struct TemplateText: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var body: String

    public init(title: String, detail: String, body: String) {
        self.title = title
        self.detail = detail
        self.body = body
    }
}

extension Store {
    public static func readTemplate(_ key: String, _ paths: Paths) -> TemplateText? {
        let url = paths.tasks.appendingPathComponent("\(key).md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        let first = lines.isEmpty ? "" : lines.removeFirst()
        let title = first.hasPrefix("# ") ? String(first.dropFirst(2)) : first
        let detail = lines.isEmpty ? "" : lines.removeFirst()
        if lines.first?.isEmpty == true { lines.removeFirst() }
        return TemplateText(title: title, detail: detail,
                            body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func writeTemplate(_ key: String, _ t: TemplateText, _ paths: Paths) throws {
        let detail = t.detail.replacingOccurrences(of: "\n", with: " ")
        let text = "# \(t.title.replacingOccurrences(of: "\n", with: " "))\n\(detail)\n\n\(t.body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try text.write(to: paths.tasks.appendingPathComponent("\(key).md"), atomically: true, encoding: .utf8)
    }

    public static func deleteTemplate(_ key: String, _ paths: Paths) throws {
        try FileManager.default.removeItem(at: paths.tasks.appendingPathComponent("\(key).md"))
    }

    /// 파일 이름으로 쓸 키. 제목의 영문·숫자만 쓰고, 남는 게 없으면(한글 제목) t-xxxxxx.
    public static func newTemplateKey(title: String, existing: Set<String>) -> String {
        let ascii = title.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" }
        var slug = String(ascii).split(separator: "-").joined(separator: "-")
        if slug.count < 3 { slug = "t-" + String(UUID().uuidString.prefix(6)).lowercased() }
        var key = slug
        var n = 2
        while existing.contains(key) { key = "\(slug)-\(n)"; n += 1 }
        return key
    }
}
