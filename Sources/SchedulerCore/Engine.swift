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
    /// 「연결 시험」으로 보내는 글 — 받는 Claude 가 결과 명령까지 실행하는지 본다.
    public static let testPrompt = "OrcaCron 연결 시험입니다. 아무 도구도 쓰지 말고, 아래 결과 명령 하나만 상태 성공 · 요약 「연결 시험 통과」로 실행해 주세요."

    /// inbox 요청을 1회 보내기로 바꾼다. known 은 앱이 마지막으로 읽은 터미널 목록(이름 표시용).
    public static func ingest(_ requests: [SendRequest], into store: inout StoreFile, known: [TerminalInfo], now: Date) -> [String] {
        var log: [String] = []
        for r in requests where !store.schedules.contains(where: { $0.id == "once-" + r.id }) {
            let ref = known.first { $0.handle == r.terminal }?.ref ?? TerminalRef(handle: r.terminal, label: r.terminal)
            let body = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
            var s = Schedule(id: "once-" + r.id,
                             name: r.name ?? r.task ?? (firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine),
                             terminal: ref, cron: "", task: r.task, prompt: r.task == nil ? body : nil)
            s.oneShot = true
            s.track = r.track
            s.runNowRequestedAt = now
            s.pendingSince = now
            s.pendingReason = "지금 실행"
            store.schedules.append(s)
            log.append("\(s.name): 명령줄 요청 받음 → \(ref.label)")
        }
        return log
    }

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
            store.schedules[i].blocked = nil
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
                    let late = now.timeIntervalSince(next)
                    if let limit = s.lateLimit, late > limit {
                        // 맥이 잠들었거나 앱이 꺼져 있던 동안 지나간 시각 — 정한 한도보다 늦으면 보내지 않는다.
                        s.record(RunRecord(at: now, status: "건너뜀",
                                           summary: "예정 \(clock(next))보다 \(duration(late)) 늦음(잠자기·앱 꺼짐) — 늦으면 건너뜀 설정"))
                        log.append("\(s.name): 건너뜀 — \(duration(late)) 늦음")
                    } else {
                        s.pendingSince = now
                        s.pendingReason = "예약"
                    }
                }
                s.nextRunAt = Cron(s.cron)?.next(after: now)
            }
            if !s.enabled { s.clearPending() }
            if s.runId != nil, let sent = s.sentAt, now.timeIntervalSince(sent) > config.runTimeout {
                s.record(RunRecord(at: now, status: "결과 없음",
                                   summary: "보낸 뒤 \(Int(config.runTimeout / 3600))시간 안에 결과 기록이 오지 않음"))
                s.runId = nil
                s.sentAt = nil
                s.blocked = nil
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
        log += checkInFlight(&store, port: port, terminals: terminals, now: now)

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
                waitOrGiveUp("화면이 \(duration(config.quietTime)) 안에 움직임(작업 중이거나 입력 중)")
                continue
            }
            guard port.isIdle(t.handle) else { waitOrGiveUp("터미널이 작업 중"); continue }
            let tail = port.screenTail(t.handle)
            switch promptState(screenTail: tail, agent: t.kind ?? s.terminal.kind ?? .claude) {
            case .empty: break
            case .typing: waitOrGiveUp("입력 칸에 쓰던 글이 있음"); continue
            case .unknown:
                waitOrGiveUp(permissionPrompt(screenTail: tail) ? "권한 확인 창이 떠 있음" : "입력 칸이 보이지 않음(질문·선택 창이 떠 있을 수 있음)")
                continue
            }

            // 새 대화로 시작 — /clear 를 먼저 보내고, 화면이 다시 조용해지면(다음 확인) 본문을 보낸다.
            if s.clearFirst == true, s.clearedFor != s.pendingSince {
                usedHandles.insert(t.handle)
                if case .failed(let why) = port.send(t.handle, text: "/clear") {
                    s.record(RunRecord(at: now, status: "실패", summary: "대화 비우기(/clear) 실패: \(why)"))
                    s.clearPending()
                    log.append("\(s.name): /clear 실패 — \(why)")
                } else {
                    s.clearedFor = s.pendingSince
                    s.waitNote = "대화를 비웠음(/clear) — 화면이 조용해지면 보냄"
                    log.append("\(s.name): 대화 비움(/clear) → \(t.displayName)")
                }
                continue
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

    /// 결과를 기다리는 실행의 터미널을 본다. 권한 창이나 질문 창에 멈췄거나, 끝났는데 결과 명령을 안 불렀으면 적어 둔다.
    /// 터미널이 일하는 중이면 지운다. 같은 터미널은 한 번만 읽는다.
    public static func checkInFlight(_ store: inout StoreFile, port: TerminalPort, terminals: [TerminalInfo], now: Date,
                                     finishedQuiet: TimeInterval = 180) -> [String] {
        var log: [String] = []
        var seen: [String: String?] = [:]
        for i in store.schedules.indices where store.schedules[i].runId != nil {
            let handle = store.schedules[i].terminal.handle
            let note: String?
            if let cached = seen[handle] {
                note = cached
            } else {
                note = inFlightNote(port: port, terminal: terminals.first { $0.handle == handle }, now: now,
                                    finishedQuiet: finishedQuiet)
                seen[handle] = note
            }
            if note != store.schedules[i].blocked {
                store.schedules[i].blocked = note
                if let note { log.append("\(store.schedules[i].name): 결과 대기 중 멈춤 — \(note)") }
            }
        }
        return log
    }

    static func inFlightNote(port: TerminalPort, terminal t: TerminalInfo?, now: Date, finishedQuiet: TimeInterval) -> String? {
        guard let t else { return "터미널이 사라짐 — 결과가 오지 않을 수 있습니다" }
        let tail = port.screenTail(t.handle)
        if permissionPrompt(screenTail: tail) { return "권한 확인 창에서 멈춤 — 그 터미널에서 허용해 주세요" }
        guard port.isIdle(t.handle) else { return nil }
        switch promptState(screenTail: tail, agent: t.kind ?? .claude) {
        case .unknown:
            return "질문·선택 창에서 멈춘 것 같음 — 그 터미널을 확인해 주세요"
        case .empty:
            if let last = t.lastOutputAt, now.timeIntervalSince(last) >= finishedQuiet {
                return "터미널은 끝났는데 결과 기록이 없음 — 그 터미널을 확인해 주세요"
            }
            return nil
        case .typing:
            return nil
        }
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }

    public static func durationText(_ t: TimeInterval) -> String { duration(t) }

    static func duration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t))초" }
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)시간" + (m % 60 > 0 ? " \(m % 60)분" : "") : "\(m)분"
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
                // 같은 터미널에서 다른 에이전트를 띄웠으면 아이콘도 따라간다. 에이전트가 꺼진 동안(nil)은 그대로 둔다.
                if live.kind != nil, ref.agent != live.agent { store.schedules[i].terminal.agent = live.agent }
                continue
            }
            guard let tab = ref.tabId, let leaf = ref.leafId,
                  let found = terminals.first(where: { $0.tabId == tab && $0.leafId == leaf }) else { continue }
            store.schedules[i].terminal.handle = found.handle
            if found.kind != nil { store.schedules[i].terminal.agent = found.agent }
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
        // 실행기가 더한 것(명령줄 요청)은 붙인다.
        let known = Set(before.schedules.map(\.id)).union(current.schedules.map(\.id))
        out.schedules += after.schedules.filter { !known.contains($0.id) }
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
            s.blocked = a.blocked
            s.clearedFor = a.clearedFor
            s.runNowHandledAt = a.runNowHandledAt
            if a.runId != b?.runId || (a.pendingSince == nil && b?.pendingSince != nil) {
                s.clearPending()
            }
            out.schedules[i] = s
        }
        return out
    }
}
