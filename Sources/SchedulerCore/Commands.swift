import Foundation

/// 받는 Claude Code 에서 `/이름` 으로 부를 수 있는 명령·스킬 하나.
public struct ClaudeCommand: Identifiable, Equatable, Sendable {
    public var name: String // 앞의 / 없이. 플러그인은 「플러그인:이름」
    public var detail: String
    public var source: String // 내장 · 개인 · 프로젝트 <폴더> · 플러그인
    /// 받는 Claude 가 스스로(스킬 도구로) 부를 수 있는지. 내장 명령·잠긴 스킬(disable-model-invocation)은 false.
    public var modelInvocable: Bool
    public var id: String { source + "/" + name }

    public init(name: String, detail: String, source: String, modelInvocable: Bool) {
        self.name = name
        self.detail = detail
        self.source = source
        self.modelInvocable = modelInvocable
    }
}

/// Claude Code 가 읽는 것과 같은 폴더에서 명령·스킬 목록을 모은다.
/// 개인 `~/.claude/{commands,skills}` · 프로젝트 `<작업 폴더>/.claude/{commands,skills}` · 켜진 플러그인 · 내장 명령.
public enum CommandCatalog {
    public static let builtins: [ClaudeCommand] = [
        ("clear", "대화를 비우고 새로 시작"),
        ("compact", "지금까지 대화를 요약해 맥락을 줄임"),
        ("context", "맥락 사용량 보기"),
        ("cost", "이번 세션 사용량 보기"),
        ("model", "모델 바꾸기"),
        ("memory", "메모리 파일 열기"),
        ("review", "코드 리뷰"),
        ("init", "CLAUDE.md 만들기"),
        ("status", "상태 보기"),
    ].map { ClaudeCommand(name: $0.0, detail: $0.1, source: "내장", modelInvocable: false) }

    public static func load(projectDirs: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeCommand] {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        var out: [ClaudeCommand] = []
        var seen = Set<String>()
        func add(_ list: [ClaudeCommand]) {
            for c in list where seen.insert(c.name).inserted { out.append(c) }
        }
        // 같은 이름이면 프로젝트 → 개인 → 플러그인 → 내장 순으로 앞의 것을 남긴다.
        for dir in projectDirs where !dir.isEmpty {
            let base = URL(fileURLWithPath: dir).appendingPathComponent(".claude", isDirectory: true)
            add(scan(base, source: "프로젝트 \(URL(fileURLWithPath: dir).lastPathComponent)", prefix: ""))
        }
        add(scan(claude, source: "개인", prefix: ""))
        for (plugin, path) in enabledPlugins(claude) {
            add(scan(URL(fileURLWithPath: path), source: "플러그인", prefix: plugin + ":"))
        }
        add(builtins)
        return out
    }

    /// `<base>/commands/*.md` 와 `<base>/skills/*/SKILL.md`.
    static func scan(_ base: URL, source: String, prefix: String) -> [ClaudeCommand] {
        let fm = FileManager.default
        var out: [ClaudeCommand] = []
        let commands = base.appendingPathComponent("commands", isDirectory: true)
        for file in ((try? fm.contentsOfDirectory(atPath: commands.path)) ?? []).sorted() where file.hasSuffix(".md") {
            let text = (try? String(contentsOf: commands.appendingPathComponent(file), encoding: .utf8)) ?? ""
            let meta = frontmatter(text)
            out.append(ClaudeCommand(name: prefix + String(file.dropLast(3)), detail: meta["description"] ?? firstLine(text),
                                     source: source, modelInvocable: meta["disable-model-invocation"] != "true"))
        }
        let skills = base.appendingPathComponent("skills", isDirectory: true)
        for dir in ((try? fm.contentsOfDirectory(atPath: skills.path)) ?? []).sorted() {
            let file = skills.appendingPathComponent(dir).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let meta = frontmatter(text)
            if meta["user-invocable"] == "false" { continue } // / 메뉴에 안 나오는 스킬
            out.append(ClaudeCommand(name: prefix + (meta["name"] ?? dir), detail: meta["description"] ?? "",
                                     source: source, modelInvocable: meta["disable-model-invocation"] != "true"))
        }
        return out
    }

    /// installed_plugins.json 의 설치 경로 중 settings.json enabledPlugins 에서 끄지 않은 것.
    static func enabledPlugins(_ claude: URL) -> [(String, String)] {
        func json(_ name: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: claude.appendingPathComponent(name)) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let installed = json("plugins/installed_plugins.json")["plugins"] as? [String: Any] ?? [:]
        let enabled = json("settings.json")["enabledPlugins"] as? [String: Bool] ?? [:]
        return installed.keys.sorted().compactMap { key in
            guard enabled[key] != false,
                  let entry = (installed[key] as? [[String: Any]])?.first,
                  let path = entry["installPath"] as? String else { return nil }
            return (String(key.split(separator: "@").first ?? Substring(key)), path)
        }
    }

    /// 맨 앞 `---` 사이의 `키: 값`. 값의 따옴표를 벗기고, `>`·`|` 뒤 들여쓴 줄은 한 줄로 잇는다.
    public static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            i += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == ">" || value == "|" || value == ">-" || value == "|-" {
                var parts: [String] = []
                while i < lines.count, lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t") {
                    parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                value = parts.joined(separator: " ")
            }
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "---" }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? ""
    }

    /// 글 끝의 `/조각`(줄 처음이나 공백 뒤). 자동완성을 띄울지 정한다.
    public static func trailingToken(_ text: String) -> String? {
        guard let slash = text.lastIndex(of: "/") else { return nil }
        if slash != text.startIndex {
            let before = text[text.index(before: slash)]
            guard before == " " || before == "\n" else { return nil }
        }
        let token = String(text[text.index(after: slash)...])
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || "-_:.".contains($0) }) else { return nil }
        return token
    }

    /// 조각에 맞는 명령 — 이름 앞부분이 맞는 것을 먼저, 그다음 이름·설명에 들어 있는 것.
    public static func match(_ token: String, in list: [ClaudeCommand], limit: Int = 8) -> [ClaudeCommand] {
        let q = token.lowercased()
        guard !q.isEmpty else { return Array(list.prefix(limit)) }
        let prefixHits = list.filter { $0.name.lowercased().hasPrefix(q) || $0.name.lowercased().split(separator: ":").last?.hasPrefix(q) == true }
        let others = list.filter { c in
            !prefixHits.contains(c) && (c.name.lowercased().contains(q) || c.detail.lowercased().contains(q))
        }
        return Array((prefixHits + others).prefix(limit))
    }

    /// 글 끝의 `/조각`을 `/이름 ` 으로 바꾼다.
    public static func complete(_ text: String, with name: String) -> String {
        guard let token = trailingToken(text) else { return text + "/" + name + " " }
        return String(text.dropLast(token.count + 1)) + "/" + name + " "
    }

    /// 본문에 적힌 `/이름` 중 받는 Claude 가 스스로 부를 수 없는 것(내장 명령·잠긴 스킬).
    public static func locked(in body: String, list: [ClaudeCommand]) -> [ClaudeCommand] {
        let names = Set(list.filter { !$0.modelInvocable }.map(\.name))
        var found: [String] = []
        let pattern = try? NSRegularExpression(pattern: "(?:^|\\s)/([A-Za-z0-9][A-Za-z0-9_:.-]*)")
        let ns = body as NSString
        for m in pattern?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let n = ns.substring(with: m.range(at: 1))
            if names.contains(n), !found.contains(n) { found.append(n) }
        }
        return found.compactMap { n in list.first { $0.name == n } }
    }
}
