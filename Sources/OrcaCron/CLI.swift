import Foundation
import SchedulerCore

/// 터미널 쪽 세션이 부르는 명령. 앱은 다음 확인 때(30초 안) 결과 파일을 읽어 예약에 붙인다.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "finish": return finish(Array(args.dropFirst()))
        case "status": return status()
        case "send": return send(Array(args.dropFirst()), test: false)
        case "test": return send(Array(args.dropFirst()), test: true)
        default: return usage()
        }
    }

    static func usage() -> Int32 {
        let text = """
        사용법:
          OrcaCron finish --run <run id> --status <성공|실패|건너뜀> --summary "<한 줄 요약>" [--link <URL>]
          OrcaCron status
          OrcaCron send --terminal <핸들> (--text "<글>" | --template <키>) [--track] [--name "<이름>"]
          OrcaCron test --terminal <핸들>      받는 에이전트가 결과 명령까지 실행하는지 한 번 확인
          OrcaCron preview <png 경로> [list|collapsed|update|undo|edit|new|multi|send|command|templates|template]

        """
        FileHandle.standardError.write(Data(text.utf8))
        return 2
    }

    static func finish(_ args: [String]) -> Int32 {
        var opts: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            guard key.hasPrefix("--"), i + 1 < args.count else { return usage() }
            opts[String(key.dropFirst(2))] = args[i + 1]
            i += 2
        }
        guard let run = opts["run"], !run.isEmpty, run.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let status = opts["status"], RunResult.allowedStatuses.contains(status)
        else { return usage() }
        let result = RunResult(runId: run, status: status, summary: opts["summary"], link: opts["link"], at: Date())
        do {
            let paths = Paths.standard()
            try paths.ensure()
            try Store.writeResult(result, paths)
            print("기록했습니다: \(run) · \(status) — 메뉴바에 30초 안에 반영됩니다.")
            return 0
        } catch {
            FileHandle.standardError.write(Data("결과를 쓰지 못했습니다: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// 앱의 「보내기」와 같은 1회 보내기를 inbox 에 남긴다. 떠 있는 앱이 바로(늦어도 30초 안에) 받아 보낸다.
    static func send(_ args: [String], test: Bool) -> Int32 {
        var opts: [String: String] = [:]
        var track = test
        var i = 0
        while i < args.count {
            let key = args[i]
            if key == "--track" { track = true; i += 1; continue }
            guard key.hasPrefix("--"), i + 1 < args.count else { return usage() }
            opts[String(key.dropFirst(2))] = args[i + 1]
            i += 2
        }
        let agents = OrcaCLI.locate().flatMap { try? OrcaCLI(binary: $0).list() }?.filter { $0.kind != nil } ?? []
        guard let handle = opts["terminal"], !handle.isEmpty else {
            var text = "--terminal 이 필요합니다. 지금 떠 있는 에이전트 터미널(Claude Code·Codex·Gemini):\n"
            text += agents.isEmpty ? "  (없음 — Orca 가 켜져 있는지 확인)\n" : agents.map { "  \($0.handle)  \($0.displayName) · \($0.kind?.displayName ?? "")\n" }.joined()
            FileHandle.standardError.write(Data(text.utf8))
            return 2
        }
        if !agents.isEmpty, !agents.contains(where: { $0.handle == handle }) {
            FileHandle.standardError.write(Data("에이전트 터미널 \(handle) 를 찾지 못했습니다. OrcaCron send 를 --terminal 없이 실행하면 목록이 나옵니다.\n".utf8))
            return 1
        }
        let paths = Paths.standard()
        let task = test ? nil : opts["template"]
        let text = test ? Engine.testPrompt : opts["text"]
        if let task, Store.readTemplate(task, paths) == nil {
            FileHandle.standardError.write(Data("템플릿 \(task) 가 없습니다: \(paths.tasks.appendingPathComponent(task + ".md").path)\n".utf8))
            return 1
        }
        guard task != nil || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return usage() }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let request = SendRequest(id: id, terminal: handle, text: task == nil ? text : nil, task: task,
                                  track: track, name: test ? "연결 시험" : opts["name"], at: Date())
        do {
            try paths.ensure()
            try Store.writeRequest(request, paths)
        } catch {
            FileHandle.standardError.write(Data("요청을 쓰지 못했습니다: \(error.localizedDescription)\n".utf8))
            return 1
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("lab.gook.orcacron.inbox"), object: nil, userInfo: nil, deliverImmediately: true)
        print("요청을 남겼습니다(once-\(id)) — 앱이 받아 그 터미널이 비면 보냅니다. 진행은 메뉴나 `OrcaCron status` 로 확인하세요.")
        if test { print("결과가 「성공 · 연결 시험 통과」로 남으면 받는 쪽 권한까지 정상입니다.") }
        return 0
    }

    static func status() -> Int32 {
        let paths = Paths.standard()
        guard let store = try? Store.load(paths) else {
            FileHandle.standardError.write(Data("예약 파일을 읽지 못했습니다: \(paths.schedules.path)\n".utf8))
            return 1
        }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        for s in store.schedules {
            let next = s.nextRunAt.map { f.string(from: $0) } ?? "-"
            let state = s.pendingSince != nil ? "대기(\(s.waitNote ?? "다음 확인"))" : (s.runId != nil ? "결과 기다림" : (s.lastStatus ?? "-"))
            print("\(s.enabled ? "켜짐" : "꺼짐")  \(s.name)  [\(Cron(s.cron)?.summary ?? s.cron)]  다음 \(next)  → \(s.terminal.label)  · \(state)")
        }
        return 0
    }
}
