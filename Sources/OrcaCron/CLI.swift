import Foundation
import SchedulerCore

/// 터미널 쪽 세션이 부르는 명령. 앱은 다음 확인 때(30초 안) 결과 파일을 읽어 예약에 붙인다.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "finish": return finish(Array(args.dropFirst()))
        case "status": return status()
        default: return usage()
        }
    }

    static func usage() -> Int32 {
        let text = """
        사용법:
          OrcaCron finish --run <run id> --status <성공|실패|건너뜀> --summary "<한 줄 요약>" [--link <URL>]
          OrcaCron status
          OrcaCron preview <png 경로> [list|update|edit|new|send|templates|template]

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
