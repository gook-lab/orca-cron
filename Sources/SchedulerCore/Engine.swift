import Foundation

public struct EngineConfig: Sendable {
    /// 터미널 쪽 세션이 결과를 남길 때 부르는 실행 파일(이 앱 자신).
    public var cliPath: String
    public var tasksDir: URL
    /// 터미널이 계속 바쁘면 이만큼 기다린 뒤 건너뛴다.
    public var maxWait: TimeInterval
    /// 보낸 뒤 이 시간 안에 결과가 안 오면 「결과 없음」으로 닫는다.
    public var runTimeout: TimeInterval
    /// 터미널 화면이 이만큼 조용해야 보낸다 — 사람이 치고 있는 글에 섞이지 않게.
    public var quietTime: TimeInterval

    public init(cliPath: String, tasksDir: URL, maxWait: TimeInterval = 3600, runTimeout: TimeInterval = 6 * 3600,
                quietTime: TimeInterval = 60) {
        self.cliPath = cliPath
        self.tasksDir = tasksDir
        self.maxWait = maxWait
        self.runTimeout = runTimeout
        self.quietTime = quietTime
    }
}

public enum Engine {
    /// 결과 파일을 해당 실행(runId)에 붙인다.
    public static func apply(results: [RunResult], to store: inout StoreFile) -> [String] {
        var log: [String] = []
        for r in results {
            guard let i = store.schedules.firstIndex(where: { $0.runId == r.runId }) else {
                log.append("결과 무시 — 맞는 실행 없음(\(r.runId))")
                continue
            }
            store.schedules[i].record(RunRecord(at: r.at, status: r.status, summary: r.summary, link: r.link))
            store.schedules[i].runId = nil
            store.schedules[i].sentAt = nil
            log.append("\(store.schedules[i].name): \(r.status) — \(r.summary ?? "")")
        }
        return log
    }

    /// 한 번 확인: 시각이 된 예약을 대기에 올리고, 대기 중인 것을 터미널이 비었을 때 보낸다.
    /// 반환 terminals 는 이번에 목록을 읽었을 때만 채워진다.
    public static func tick(_ store: inout StoreFile, port: TerminalPort, config: EngineConfig, now: Date,
                            makeRunId: () -> String = { String(UUID().uuidString.prefix(8)).lowercased() })
        -> (log: [String], terminals: [TerminalInfo]?)
    {
        var log: [String] = []

        // 끝난 1회 보내기는 24시간 뒤 지운다.
        store.schedules.removeAll { s in
            guard s.isOneShot, s.pendingSince == nil, s.runId == nil, let done = s.history.first?.at else { return false }
            return now.timeIntervalSince(done) > 24 * 3600
        }

        for i in store.schedules.indices {
            var s = store.schedules[i]
            if s.nextRunFor != s.cron || s.nextRunAt == nil {
                s.nextRunAt = Cron(s.cron)?.next(after: now)
                s.nextRunFor = s.cron
            }
            if let req = s.runNowRequestedAt, req != s.runNowHandledAt {
                s.runNowHandledAt = req
                if s.enabled && s.pendingSince == nil {
                    s.pendingSince = now
                    s.pendingReason = "지금 실행"
                }
            }
            // 꺼진 예약도 시각은 굴린다 — 다시 켰을 때 지나간 시각으로 바로 돌지 않게.
            if let next = s.nextRunAt, next <= now {
                if s.enabled && s.pendingSince == nil {
                    s.pendingSince = now
                    s.pendingReason = "예약"
                }
                s.nextRunAt = Cron(s.cron)?.next(after: now)
            }
            if !s.enabled { s.clearPending() }
            if s.runId != nil, let sent = s.sentAt, now.timeIntervalSince(sent) > config.runTimeout {
                s.record(RunRecord(at: now, status: "결과 없음",
                                   summary: "보낸 뒤 \(Int(config.runTimeout / 3600))시간 안에 결과 기록이 오지 않음"))
                s.runId = nil
                s.sentAt = nil
                log.append("\(s.name): 결과 없음")
            }
            store.schedules[i] = s
        }

        let terminals: [TerminalInfo]
        do {
            terminals = try port.list()
        } catch {
            log.append("터미널 목록을 읽지 못함: \(error)")
            return (log, nil)
        }
        log += reconnect(&store, terminals: terminals)

        let pending = store.schedules.indices.filter { store.schedules[$0].pendingSince != nil }

        var usedHandles = Set<String>()
        for i in pending {
            var s = store.schedules[i]
            defer { store.schedules[i] = s }
            let waited = now.timeIntervalSince(s.pendingSince ?? now)

            func waitOrGiveUp(_ why: String) {
                if waited >= config.maxWait {
                    s.record(RunRecord(at: now, status: "건너뜀", summary: "\(Int(config.maxWait / 60))분 동안 \(why)"))
                    s.clearPending()
                    log.append("\(s.name): 건너뜀 — \(why)")
                } else {
                    s.waitNote = why
                }
            }

            if s.runId != nil { waitOrGiveUp("이전 실행이 아직 끝나지 않음"); continue }
            guard let t = terminals.first(where: { $0.handle == s.terminal.handle }), t.connected, t.writable else {
                s.record(RunRecord(at: now, status: "건너뜀",
                                   summary: "터미널(\(s.terminal.label))을 찾을 수 없음 — 메뉴에서 터미널을 다시 고르세요"))
                s.clearPending()
                log.append("\(s.name): 터미널 없음")
                continue
            }
            if usedHandles.contains(t.handle) { s.waitNote = "같은 터미널에 다른 예약을 막 보내 다음 확인 때 보냄"; continue }
            if let last = t.lastOutputAt, now.timeIntervalSince(last) < config.quietTime {
                waitOrGiveUp("화면이 \(Int(config.quietTime))초 안에 움직임(작업 중이거나 입력 중)")
                continue
            }
            guard port.isIdle(t.handle) else { waitOrGiveUp("터미널이 작업 중"); continue }
            switch promptState(screenTail: port.screenTail(t.handle)) {
            case .empty: break
            case .typing: waitOrGiveUp("입력 칸에 쓰던 글이 있음"); continue
            case .unknown: waitOrGiveUp("입력 칸이 보이지 않음(질문·권한 창이 떠 있을 수 있음)"); continue
            }

            let runId = makeRunId()
            let outcome = port.send(t.handle, text: message(for: s, runId: runId, config: config))
            usedHandles.insert(t.handle)
            switch outcome {
            case .failed(let why):
                s.record(RunRecord(at: now, status: "실패", summary: "보내기 실패: \(why)"))
                s.clearPending()
                log.append("\(s.name): 보내기 실패 — \(why)")
            case .started, .accepted:
                let status = outcome == .started ? "보냄" : "보냄(시작 미확인)"
                s.lastRunAt = now
                s.clearPending()
                if s.tracksResult {
                    s.runId = runId
                    s.sentAt = now
                    s.lastStatus = status
                    s.lastSummary = nil
                    s.lastLink = nil
                } else {
                    s.record(RunRecord(at: now, status: status))
                }
                log.append("\(s.name): \(status) → \(t.displayName)\(s.tracksResult ? " (run \(runId))" : "")")
            }
        }
        return (log, terminals)
    }

    /// 예약이 가리키는 터미널을 지금 목록에 맞춘다.
    /// - handle 이 살아 있으면 탭·패인 id 를 채워 둔다(옛 예약에도 다음 확인 때 채워진다).
    /// - handle 이 없어졌으면(Orca 재시작 등) 같은 탭·패인 id 의 터미널로 다시 잇는다.
    public static func reconnect(_ store: inout StoreFile, terminals: [TerminalInfo]) -> [String] {
        var log: [String] = []
        for i in store.schedules.indices {
            let ref = store.schedules[i].terminal
            if let live = terminals.first(where: { $0.handle == ref.handle }) {
                if ref.tabId != live.tabId || ref.leafId != live.leafId, live.tabId != nil, live.leafId != nil {
                    store.schedules[i].terminal.tabId = live.tabId
                    store.schedules[i].terminal.leafId = live.leafId
                }
                continue
            }
            guard let tab = ref.tabId, let leaf = ref.leafId,
                  let found = terminals.first(where: { $0.tabId == tab && $0.leafId == leaf }) else { continue }
            store.schedules[i].terminal.handle = found.handle
            log.append("\(store.schedules[i].name): 터미널 다시 연결 → \(found.displayName)")
        }
        return log
    }

    public static func message(for s: Schedule, runId: String, config: EngineConfig) -> String {
        let body: String
        if let task = s.task, !task.isEmpty {
            let path = config.tasksDir.appendingPathComponent("\(task).md").path
            body = "작업 파일 \(path) 을 읽고 그 절차대로 실행한다(파일의 「실행기 finish」 줄은 요약 문구 형식 안내로만 쓴다)."
        } else {
            body = (s.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !s.tracksResult { return body }
        return "[예약 실행 · \(s.name)] \(body) 끝나면 결과를 남긴다: \(config.cliPath) finish --run \(runId) --status <성공|실패|건너뜀> --summary \"<한 줄 요약>\" [--link <URL>]"
    }

    /// 틱이 도는 사이 사용자가 고친 예약은 사용자 칸을 지키고, 실행 결과 칸만 옮긴다.
    public static func merge(before: StoreFile, after: StoreFile, current: StoreFile) -> StoreFile {
        var out = current
        // 실행기가 지운 예약(끝난 1회 보내기)은 지금 목록에서도 지운다.
        let removed = Set(before.schedules.map(\.id)).subtracting(after.schedules.map(\.id))
        out.schedules.removeAll { removed.contains($0.id) }
        for i in out.schedules.indices {
            let id = out.schedules[i].id
            guard let a = after.schedules.first(where: { $0.id == id }) else { continue }
            let b = before.schedules.first(where: { $0.id == id })
            if b == out.schedules[i] {
                out.schedules[i] = a
                continue
            }
            var s = out.schedules[i]
            if s.terminal.handle == b?.terminal.handle { s.terminal = a.terminal }
            s.runId = a.runId
            s.sentAt = a.sentAt
            s.lastRunAt = a.lastRunAt
            s.lastStatus = a.lastStatus
            s.lastSummary = a.lastSummary
            s.lastLink = a.lastLink
            s.history = a.history
            s.runNowHandledAt = a.runNowHandledAt
            if a.runId != b?.runId || (a.pendingSince == nil && b?.pendingSince != nil) {
                s.clearPending()
            }
            out.schedules[i] = s
        }
        return out
    }
}
