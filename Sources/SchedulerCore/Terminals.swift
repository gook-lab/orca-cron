import Foundation

public struct TerminalInfo: Equatable, Identifiable, Sendable {
    public var handle: String
    public var title: String
    public var agent: String?
    public var worktreePath: String
    public var connected: Bool
    public var writable: Bool
    /// 터미널 화면이 마지막으로 움직인 시각. 키를 치면 바로 갱신된다.
    public var lastOutputAt: Date?
    public var tabId: String?
    public var leafId: String?

    public init(handle: String, title: String, agent: String?, worktreePath: String, connected: Bool, writable: Bool,
                lastOutputAt: Date? = nil, tabId: String? = nil, leafId: String? = nil) {
        self.tabId = tabId
        self.leafId = leafId
        self.handle = handle
        self.title = title
        self.agent = agent
        self.worktreePath = worktreePath
        self.connected = connected
        self.writable = writable
        self.lastOutputAt = lastOutputAt
    }

    public var id: String { handle }
    public var place: String { worktreePath.isEmpty ? "" : (worktreePath as NSString).lastPathComponent }
    public var displayName: String { place.isEmpty ? title : "\(place) · \(title)" }

    /// 예약에 저장할 연결 정보.
    public var ref: TerminalRef { TerminalRef(handle: handle, label: displayName, tabId: tabId, leafId: leafId) }
}

public enum SendOutcome: Equatable, Sendable {
    /// 에이전트가 턴을 시작한 것까지 봤다.
    case started
    /// 입력은 들어갔지만 턴 시작은 확인하지 못했다.
    case accepted
    case failed(String)
}

public protocol TerminalPort: Sendable {
    func list() throws -> [TerminalInfo]
    func isIdle(_ handle: String) -> Bool
    func screenTail(_ handle: String) -> [String]
    func send(_ handle: String, text: String) -> SendOutcome
}

public enum PromptState: Equatable, Sendable {
    case empty
    case typing
    /// 입력 칸이 안 보인다 — 질문·권한 창이 떠 있거나 Claude Code 화면이 아니다.
    case unknown
}

/// Claude Code 화면 끝의 입력 칸(가로줄 바로 아래 `❯` 줄)이 비었는지.
/// 빈 칸의 흐린 예시 문구는 `❯` 뒤에 NBSP 가 붙고(`❯\u{a0}Try "…"`), 오른쪽 끝 안내(`← 1 agent`)는 공백 여러 칸 뒤에 붙는다.
/// 주의: Orca 화면 읽기에는 사람이 쳐 둔 글이 보이지 않는다(2026-11-11 실측) — 입력 중 여부는 lastOutputAt 으로 본다.
public func promptState(screenTail lines: [String]) -> PromptState {
    guard lines.count >= 2 else { return .unknown }
    for i in stride(from: lines.count - 1, through: 1, by: -1) {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        guard let mark = line.first, promptMarks.contains(mark) else { continue }
        guard isRule(lines[i - 1]) else {
            // `>` 는 출력(인용 등)에도 흔해 가로줄 아래가 아니면 넘어간다. `❯`·`›` 는 질문·권한 창의 선택 표시다.
            if mark == ">" { continue }
            return .unknown
        }
        let rest = String(line.dropFirst())
        if rest.hasPrefix("\u{a0}") { return .empty }
        let typed = rest.components(separatedBy: "   ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return typed.isEmpty ? .empty : .typing
    }
    return .unknown
}

/// 입력 칸 앞 표시 — Claude Code 는 `❯`. 글꼴·버전에 따라 `›`·`>` 로 그려질 수 있어 함께 받는다.
let promptMarks: [Character] = ["❯", "›", ">"]

/// 입력 칸 위의 가로줄 — 줄 대부분이 가로선 글자(─ ━ ═ — - ╌ ┄)이고 10자 이상.
func isRule(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count >= 10 else { return false }
    let n = t.filter { "─━═—-╌┄".contains($0) }.count
    return Double(n) / Double(t.count) >= 0.8
}

/// Claude Code 의 도구 권한 창(「Do you want to proceed?」 + 「1. Yes」)이 화면 끝에 떠 있는지.
public func permissionPrompt(screenTail lines: [String]) -> Bool {
    let recent = lines.suffix(30).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " │|\u{a0}")) }
    let asks = recent.contains { $0.contains("Do you want to") }
    let yes = recent.contains { line in
        let l = line.drop(while: { "❯›> ".contains($0) })
        return l.hasPrefix("1. Yes") || l.hasPrefix("1.Yes")
    }
    return asks && yes
}

/// Orca CLI(`orca terminal …`)로 터미널을 다룬다.
public struct OrcaCLI: TerminalPort {
    public let binary: String

    public init(binary: String) {
        self.binary = binary
    }

    public static func locate() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ORCA_BIN"], fm.isExecutableFile(atPath: env) { return env }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let apps = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("Orca") && $0.hasSuffix(".app") }
            for app in apps.sorted() {
                let path = "\(dir)/\(app)/Contents/Resources/bin/orca"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    struct CLIError: Error, CustomStringConvertible {
        let description: String
    }

    func run(_ args: [String], timeout: TimeInterval = 20) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args + ["--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func list() throws -> [TerminalInfo] {
        guard let r = run(["terminal", "list"]) else { throw CLIError(description: "orca 응답 없음") }
        guard r["ok"] as? Bool == true,
              let terms = (r["result"] as? [String: Any])?["terminals"] as? [[String: Any]]
        else { throw CLIError(description: errorCode(r)) }
        return terms.map { t in
            TerminalInfo(handle: t["handle"] as? String ?? "",
                         title: t["title"] as? String ?? "",
                         agent: t["agentIdentity"] as? String,
                         worktreePath: t["worktreePath"] as? String ?? "",
                         connected: t["connected"] as? Bool ?? false,
                         writable: t["writable"] as? Bool ?? false,
                         lastOutputAt: (t["lastOutputAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                         tabId: t["tabId"] as? String,
                         leafId: t["leafId"] as? String)
        }
    }

    public func isIdle(_ handle: String) -> Bool {
        guard let r = run(["terminal", "wait", "--terminal", handle, "--for", "tui-idle", "--timeout-ms", "1500"]),
              r["ok"] as? Bool == true,
              let wait = (r["result"] as? [String: Any])?["wait"] as? [String: Any]
        else { return false }
        return wait["satisfied"] as? Bool == true
    }

    public func screenTail(_ handle: String) -> [String] {
        guard let r = run(["terminal", "read", "--terminal", handle, "--screen"]),
              let term = (r["result"] as? [String: Any])?["terminal"] as? [String: Any]
        else { return [] }
        return term["tail"] as? [String] ?? []
    }

    public func send(_ handle: String, text: String) -> SendOutcome {
        guard let r = run(["terminal", "send", "--terminal", handle, "--text", text, "--enter", "--wait-submit", "8"],
                          timeout: 30)
        else { return .failed("orca 응답 없음") }
        guard r["ok"] as? Bool == true else { return .failed(errorCode(r)) }
        return OrcaCLI.turnStarted(r["result"]) ? .started : .accepted
    }

    /// Orca 화면에서 그 터미널 탭을 앞으로 가져온다(syspulse 의 세션 이동과 같은 `orca terminal switch`).
    public func focus(_ handle: String) -> Bool {
        run(["terminal", "switch", "--terminal", handle])?["ok"] as? Bool == true
    }

    /// CLI 가 들어 있는 Orca 앱(…/Orca.app/Contents/Resources/bin/orca → …/Orca.app).
    public var appURL: URL {
        URL(fileURLWithPath: binary).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `result.send.prompt.stages` 에 `turn_started` 가 있으면 에이전트가 턴을 시작한 것까지 본 것이다(Orca 1.4.25x 실측).
    static func turnStarted(_ result: Any?) -> Bool {
        let prompt = ((result as? [String: Any])?["send"] as? [String: Any])?["prompt"] as? [String: Any]
        return (prompt?["stages"] as? [String])?.contains("turn_started") == true
    }

    func errorCode(_ r: [String: Any]) -> String {
        ((r["error"] as? [String: Any])?["code"] as? String) ?? "알 수 없는 오류"
    }
}
