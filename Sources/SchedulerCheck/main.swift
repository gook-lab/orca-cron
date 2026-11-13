import Foundation
import SchedulerCore

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        failures += 1
        print("✗ \(what) \(detail())")
    }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Seoul")!

func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func next(_ expr: String, _ from: Date) -> Date? { Cron(expr)?.next(after: from, calendar: cal) }

// MARK: cron 다음 시각

let wed0907 = at(2026, 11, 11, 9, 7, 30)  // 수요일
check(next("3 9 * * *", wed0907) == at(2026, 11, 12, 9, 3), "매일 09:03 → 내일")
check(next("13 12,19 * * *", wed0907) == at(2026, 11, 11, 12, 13), "12·19시 → 오늘 12:13")
check(next("*/10 * * * *", wed0907) == at(2026, 11, 11, 9, 10), "10분마다")
check(next("7 9 * * *", at(2026, 11, 11, 9, 7, 0)) == at(2026, 11, 12, 9, 7), "같은 분은 건너뛴다")
check(next("0 9 * * 1-5", at(2026, 11, 13, 10, 0)) == at(2026, 11, 16, 9, 0), "평일 → 금요일 뒤 월요일")
check(next("0 9 * * 7", wed0907) == at(2026, 11, 15, 9, 0), "요일 7 = 일요일")
check(next("0 0 13 * 5", at(2026, 11, 11, 0, 0)) == at(2026, 11, 13, 0, 0), "일·요일 둘 다 지정이면 OR(13일 금요일)")
check(next("0 0 1 * 1", at(2026, 11, 11, 0, 0)) == at(2026, 11, 16, 0, 0), "OR — 1일보다 월요일이 먼저")
check(next("3 0,6,12,18 * * *", at(2026, 11, 11, 18, 4)) == at(2026, 11, 12, 0, 3), "6시간마다 → 자정 넘김")
check(Cron("61 * * * *") == nil, "분 61 은 거절")
check(Cron("* * *") == nil, "칸 수 부족은 거절")
check(Cron("5/15 * * * *").map { next($0.expression, at(2026, 11, 11, 9, 21)) } == at(2026, 11, 11, 9, 35), "5/15 = 5·20·35·50분")

// MARK: 한 줄 설명

let summaries: [(String, String)] = [
    ("3 9 * * *", "매일 09:03"),
    ("13 12,19 * * *", "매일 12:13 · 19:13"),
    ("3 0,6,12,18 * * *", "매일 00·06·12·18시 03분"),
    ("0 9 * * 1-5", "평일 09:00"),
    ("0 9 * * 1,3", "매주 월·수 09:00"),
    ("*/10 * * * *", "10분마다"),
    ("15 * * * *", "매시 15분"),
    ("0 9 1 * *", "0 9 1 * *"),
]
for (expr, want) in summaries {
    let got = Cron(expr)?.summary
    check(got == want, "설명 \(expr)", "→ \(got ?? "nil") (기대 \(want))")
}

// MARK: 입력 칸 판정

let rule = "──────────────────────────────"
check(promptState(screenTail: ["끝", rule, "❯", rule, "  ⏵⏵ bypass"]) == .empty, "빈 입력 칸")
check(promptState(screenTail: [rule, "❯                         ← 1 agent · 2 feedback drafts", rule]) == .empty, "오른쪽 안내만 있으면 빈 칸")
check(promptState(screenTail: [rule, "❯ 지난 24시간 에러", rule]) == .typing, "쓰던 글이 있음")
check(promptState(screenTail: [rule, "❯\u{a0}Try \"edit 254.html\" to...\"", rule]) == .empty, "흐린 예시 문구는 빈 칸")
check(promptState(screenTail: ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]) == .unknown, "권한 창의 ❯ 는 입력 칸이 아님")
check(promptState(screenTail: []) == .unknown, "화면 없음")

// MARK: 실행기

final class FakePort: TerminalPort, @unchecked Sendable {
    var terminals: [TerminalInfo]
    var idle: Set<String>
    var tails: [String: [String]] = [:]
    var sent: [(String, String)] = []
    var outcome: SendOutcome = .started

    init(terminals: [TerminalInfo], idle: Set<String>) {
        self.terminals = terminals
        self.idle = idle
    }

    func list() throws -> [TerminalInfo] { terminals }
    func isIdle(_ h: String) -> Bool { idle.contains(h) }
    func screenTail(_ h: String) -> [String] { tails[h] ?? [rule, "❯", rule] }
    func send(_ h: String, text: String) -> SendOutcome {
        sent.append((h, text))
        return outcome
    }
}

let termA = TerminalInfo(handle: "term_a", title: "작업 세션", agent: "claude", worktreePath: "/x/project", connected: true, writable: true)
let termB = TerminalInfo(handle: "term_b", title: "다른 세션", agent: "claude", worktreePath: "/x/toy", connected: true, writable: true)
let config = EngineConfig(cliPath: "/Apps/OrcaCron", tasksDir: URL(fileURLWithPath: "/home/.orca-cron/tasks"))
var counter = 0
func rid() -> String { counter += 1; return "run\(counter)" }

func schedule(_ id: String, cron: String, terminal: String = "term_a", task: String? = "daily-report") -> Schedule {
    Schedule(id: id, name: id, terminal: TerminalRef(handle: terminal, label: "lbl"), cron: cron, task: task)
}

do {
    // 시각 전에는 아무것도 안 보낸다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("tf", cron: "3 12 * * *")])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 10), makeRunId: rid)
    check(port.sent.isEmpty && store.schedules[0].nextRunAt == at(2026, 11, 11, 12, 3), "시각 전에는 대기만")

    // 시각이 되면 보낸다
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 3, 20), makeRunId: rid)
    check(port.sent.count == 1 && port.sent[0].0 == "term_a", "12:03 에 보냄")
    check(port.sent.first?.1.contains("/home/.orca-cron/tasks/daily-report.md") == true, "작업 파일 경로가 메시지에 있음")
    check(port.sent.first?.1.contains("finish --run run1") == true, "결과 명령에 run id")
    let s = store.schedules[0]
    check(s.runId == "run1" && s.lastStatus == "보냄" && s.pendingSince == nil, "보낸 뒤 상태")
    check(s.nextRunAt == at(2026, 11, 12, 12, 3), "다음 시각은 내일")

    // 결과가 오면 붙는다
    let log = Engine.apply(results: [RunResult(runId: "run1", status: "성공", summary: "새 이슈 2건", link: "https://x", at: at(2026, 11, 11, 12, 10))], to: &store)
    check(store.schedules[0].runId == nil && store.schedules[0].lastStatus == "성공" && store.schedules[0].history.count == 1, "결과 반영", "\(log)")
    _ = Engine.apply(results: [RunResult(runId: "zzz", status: "성공", summary: nil, link: nil, at: Date())], to: &store)
    check(store.schedules[0].history.count == 1, "모르는 run 결과는 무시")
}

do {
    // 바쁘면 기다리고, 60분 넘으면 건너뛴다
    let port = FakePort(terminals: [termA], idle: [])
    var store = StoreFile(schedules: [schedule("y", cron: "13 12 * * *")])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 0))
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 13, 10))
    check(port.sent.isEmpty && store.schedules[0].waitNote == "터미널이 작업 중", "작업 중이면 대기")
    port.idle = ["term_a"]
    port.tails["term_a"] = [rule, "❯ 쓰는 중", rule]
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 20))
    check(port.sent.isEmpty && store.schedules[0].waitNote == "입력 칸에 쓰던 글이 있음", "쓰던 글이 있으면 대기")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 13, 14))
    check(port.sent.isEmpty && store.schedules[0].lastStatus == "건너뜀" && store.schedules[0].pendingSince == nil, "60분 넘으면 건너뜀")
}

do {
    // 화면이 최근에 움직였으면(입력 중일 수 있음) 조용해질 때까지 기다린다
    var quiet = termA
    quiet.lastOutputAt = at(2026, 11, 11, 9, 0, 40)
    let port = FakePort(terminals: [quiet], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("q", cron: "0 23 * * *")])
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 0)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1), makeRunId: rid)
    check(port.sent.isEmpty && store.schedules[0].waitNote?.hasPrefix("화면이 1분 안에") == true, "최근 출력 → 대기")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1, 41), makeRunId: rid)
    check(port.sent.count == 1, "60초 조용하면 보냄")
}

do {
    // Orca 를 다시 켜 handle 이 바뀌어도 같은 탭·패인이면 다시 잇는다
    var before = termA
    before.tabId = "tab1"; before.leafId = "leaf1"
    let port = FakePort(terminals: [before], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("r", cron: "0 23 * * *")])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0))
    check(store.schedules[0].terminal.tabId == "tab1" && store.schedules[0].terminal.leafId == "leaf1", "살아 있는 터미널의 탭·패인 id 를 채움")
    var after = before
    after.handle = "term_new"
    port.terminals = [termB, after]
    port.idle = ["term_new"]
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 5)
    let r = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 5, 10), makeRunId: rid)
    check(store.schedules[0].terminal.handle == "term_new" && port.sent.count == 1 && port.sent[0].0 == "term_new",
          "handle 이 바뀌어도 같은 탭·패인으로 다시 이어 보냄", "\(r.log)")
    // 탭·패인까지 없어지면 「터미널 없음」
    port.terminals = [termB]
    store.schedules[0].runId = nil
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 10)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 10, 10), makeRunId: rid)
    check(store.schedules[0].lastStatus == "건너뜀" && store.schedules[0].terminal.handle == "term_new", "탭·패인도 없으면 건너뜀")
}

do {
    // 터미널이 없어지면 건너뛰고 대기를 비운다
    let port = FakePort(terminals: [termB], idle: ["term_b"])
    var store = StoreFile(schedules: [schedule("t", cron: "0 9 * * *")])
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 0)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1))
    check(port.sent.isEmpty && store.schedules[0].lastStatus == "건너뜀" && store.schedules[0].pendingSince == nil, "터미널 없음 → 건너뜀")
}

do {
    // 같은 터미널에 두 예약이 겹치면 하나만 보낸다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("a", cron: "0 12 * * *"), schedule("b", cron: "0 12 * * *")])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 11, 0))
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 0, 5), makeRunId: rid)
    check(port.sent.count == 1 && store.schedules[1].pendingSince != nil, "같은 터미널은 한 번에 하나")
}

do {
    // 지금 실행: 꺼진 예약은 안 보냄, 켜진 예약은 시각과 무관하게 보냄
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("on", cron: "0 23 * * *"), schedule("off", cron: "0 23 * * *")])
    store.schedules[1].enabled = false
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 0)
    store.schedules[1].runNowRequestedAt = at(2026, 11, 11, 9, 0)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0, 10), makeRunId: rid)
    check(port.sent.count == 1 && store.schedules[0].runId != nil && store.schedules[1].runId == nil, "지금 실행은 켜진 것만")
    // 같은 요청은 한 번만
    store.schedules[0].runId = nil
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1))
    check(port.sent.count == 1, "같은 지금 실행 요청은 다시 보내지 않음")
}

do {
    // 꺼 둔 동안 지난 시각은 다시 켜도 바로 돌지 않는다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("tf", cron: "3 12 * * *")])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0))
    store.schedules[0].enabled = false
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 30))
    store.schedules[0].enabled = true
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 31))
    check(port.sent.isEmpty && store.schedules[0].nextRunAt == at(2026, 11, 12, 12, 3), "다시 켜도 지난 시각은 돌지 않음")
}

do {
    // 결과가 6시간 안 오면 「결과 없음」
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("x", cron: "0 9 * * *")])
    store.schedules[0].runId = "old"
    store.schedules[0].sentAt = at(2026, 11, 11, 2, 0)
    store.schedules[0].nextRunAt = at(2026, 11, 12, 9, 0)
    store.schedules[0].nextRunFor = "0 9 * * *"
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 8, 30))
    check(store.schedules[0].runId == nil && store.schedules[0].lastStatus == "결과 없음", "결과 시간 초과")
}

do {
    // 보내기 실패
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    port.outcome = .failed("terminal_handle_stale")
    var store = StoreFile(schedules: [schedule("f", cron: "0 9 * * *")])
    store.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 0)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0, 30))
    check(store.schedules[0].lastStatus == "실패" && store.schedules[0].pendingSince == nil, "보내기 실패 기록")
}

do {
    // 직접 입력 예약은 프롬프트를 그대로 보낸다
    var s = schedule("p", cron: "0 9 * * *", task: nil)
    s.prompt = "지난 24시간 에러 확인"
    let text = Engine.message(for: s, runId: "r", config: config)
    check(text.hasPrefix("[예약 실행 · p] 지난 24시간 에러 확인 끝나면"), "직접 입력 메시지", text)
}

do {
    // 1회 보내기: 쓴 글 그대로 보내고, 결과를 기다리지 않으며, 24시간 뒤 지운다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var once = schedule("once-1", cron: "", task: nil)
    once.prompt = "  지금 상태 알려줘  "
    once.oneShot = true
    once.runNowRequestedAt = at(2026, 11, 11, 10, 0)
    var store = StoreFile(schedules: [once])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 10, 0, 20), makeRunId: rid)
    check(port.sent.count == 1 && port.sent[0].1 == "지금 상태 알려줘", "1회 보내기는 글 그대로", port.sent.first?.1 ?? "")
    let o = store.schedules[0]
    check(o.runId == nil && o.lastStatus == "보냄" && o.history.count == 1 && o.nextRunAt == nil, "1회 보내기는 결과를 기다리지 않음")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 18, 0), makeRunId: rid)
    check(port.sent.count == 1 && store.schedules.count == 1, "1회 보내기는 다시 보내지 않음")
    let before = store
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 12, 10, 1), makeRunId: rid)
    check(store.schedules.isEmpty, "24시간 지나면 지움")
    check(Engine.merge(before: before, after: store, current: before).schedules.isEmpty, "실행기가 지운 것은 병합에서도 지움")

    // 결과 받기를 켜면 예약과 같은 문장 + run id
    var tracked = once
    tracked.track = true
    let text = Engine.message(for: tracked, runId: "r7", config: config)
    check(text.contains("finish --run r7") && text.hasPrefix("[예약 실행 · once-1] 지금 상태 알려줘"), "1회 보내기 결과 받기", text)
}

do {
    // 틱 도중 사용자가 고치면 사용자 칸은 지키고 결과만 옮긴다
    var before = StoreFile(schedules: [schedule("m", cron: "0 9 * * *")])
    before.schedules[0].pendingSince = at(2026, 11, 11, 9, 0)
    var after = before
    after.schedules[0].runId = "r9"
    after.schedules[0].lastStatus = "보냄"
    after.schedules[0].pendingSince = nil
    var current = before
    current.schedules[0].name = "고친 이름"
    current.schedules[0].runNowRequestedAt = at(2026, 11, 11, 9, 0, 3)
    let merged = Engine.merge(before: before, after: after, current: current)
    let m = merged.schedules[0]
    check(m.name == "고친 이름" && m.runId == "r9" && m.pendingSince == nil && m.runNowRequestedAt != nil, "병합")
    let untouched = Engine.merge(before: before, after: after, current: before)
    check(untouched == after, "안 고쳤으면 틱 결과 그대로")
    var deleted = before
    deleted.schedules = []
    check(Engine.merge(before: before, after: after, current: deleted).schedules.isEmpty, "틱 도중 지운 예약은 되살리지 않음")
}

// MARK: 권한 창 · 결과 대기 중 멈춤 · 늦은 실행

let permissionScreen = ["⏺ Bash(~/Applications/OrcaCron.app/Contents/MacOS/OrcaCron finish --run r1 ...)", rule,
                        " Bash command", "   OrcaCron finish --run r1", " Do you want to proceed?",
                        " ❯ 1. Yes", "   2. Yes, and don't ask again for OrcaCron finish commands", "   3. No, and tell Claude what to do differently (esc)"]
check(permissionPrompt(screenTail: permissionScreen), "권한 창 알아봄")
check(permissionPrompt(screenTail: ["│ Do you want to make this edit to a.md? │", "│ ❯ 1. Yes │", "│   2. No │"]), "테두리 있는 권한 창")
check(!permissionPrompt(screenTail: [rule, "❯ Do you want to proceed? 라고 쓰는 중", rule]), "입력 칸의 글은 권한 창 아님")
check(!permissionPrompt(screenTail: ["끝", rule, "❯", rule]), "빈 입력 칸은 권한 창 아님")

do {
    // 보낸 뒤 터미널이 권한 창에서 멈추면 적고, 결과가 오면 지운다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("p", cron: "0 9 * * *")])
    store.schedules[0].runId = "rp"
    store.schedules[0].sentAt = at(2026, 11, 11, 9, 0)
    port.tails["term_a"] = permissionScreen
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1))
    check(store.schedules[0].blocked?.hasPrefix("권한 확인 창") == true, "결과 대기 중 권한 창", store.schedules[0].blocked ?? "nil")
    port.tails["term_a"] = ["⏺ 작업 중", rule, "❯", rule]
    port.idle = []
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 2))
    check(store.schedules[0].blocked == nil, "다시 일하면 멈춤 표시 지움")
    _ = Engine.apply(results: [RunResult(runId: "rp", status: "성공", summary: nil, link: nil, at: at(2026, 11, 11, 9, 3))], to: &store)
    check(store.schedules[0].blocked == nil && store.schedules[0].runId == nil, "결과가 오면 멈춤 없음")

    // 끝났는데 결과 명령을 안 불렀으면 3분 조용한 뒤 알린다
    var quietA = termA
    quietA.lastOutputAt = at(2026, 11, 11, 10, 0)
    port.terminals = [quietA]
    port.idle = ["term_a"]
    port.tails["term_a"] = ["⏺ 다 했습니다", rule, "❯", rule]
    store.schedules[0].runId = "rq"
    store.schedules[0].sentAt = at(2026, 11, 11, 9, 59)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 10, 1))
    check(store.schedules[0].blocked == nil, "조용한 지 3분 전에는 기다림")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 10, 4))
    check(store.schedules[0].blocked?.hasPrefix("터미널은 끝났는데") == true, "끝났는데 결과 기록 없음", store.schedules[0].blocked ?? "nil")
    port.tails["term_a"] = ["어느 쪽으로 할까요?", "❯ 1. A", "  2. B"]
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 10, 5))
    check(store.schedules[0].blocked?.hasPrefix("질문·선택 창") == true, "질문 창에서 멈춤", store.schedules[0].blocked ?? "nil")
}

do {
    // 늦으면 건너뜀 — 한도 안이면 보내고, 넘으면 기록만 남긴다
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [schedule("late", cron: "0 9 * * *"), schedule("lazy", cron: "0 9 * * *", terminal: "term_a")])
    store.schedules[0].lateLimit = 3600
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 8, 0))
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 12, 30), makeRunId: rid)
    let late = store.schedules[0]
    check(late.lastStatus == "건너뜀" && late.pendingSince == nil && late.lastSummary?.contains("3시간 30분 늦음") == true,
          "한도보다 늦으면 건너뜀", late.lastSummary ?? "nil")
    check(late.nextRunAt == at(2026, 11, 12, 9, 0), "건너뛴 뒤 다음 시각은 내일")
    check(port.sent.count == 1 && store.schedules[1].runId != nil, "한도가 없으면 늦어도 보냄")

    var soon = StoreFile(schedules: [schedule("ok", cron: "0 9 * * *")])
    soon.schedules[0].lateLimit = 3600
    let port2 = FakePort(terminals: [termA], idle: ["term_a"])
    _ = Engine.tick(&soon, port: port2, config: config, now: at(2026, 11, 11, 8, 0))
    _ = Engine.tick(&soon, port: port2, config: config, now: at(2026, 11, 11, 9, 40), makeRunId: rid)
    check(port2.sent.count == 1, "한도 안에서 늦으면 보냄")

    // 저장 파일에 새 칸이 없어도 읽힌다(옛 판 호환)
    let old = #"{"schedules":[{"id":"a","name":"a","terminal":{"handle":"h","label":"l"},"cron":"0 9 * * *","enabled":true,"history":[]}]}"#
    let decoded = try? JSONDecoder().decode(StoreFile.self, from: Data(old.utf8))
    check(decoded?.schedules.first?.lateLimit == nil && decoded?.schedules.first?.blocked == nil, "옛 schedules.json 호환")

    // 병합은 멈춤 표시를 옮긴다
    var before = StoreFile(schedules: [schedule("mb", cron: "0 9 * * *")])
    before.schedules[0].runId = "x"
    var after = before
    after.schedules[0].blocked = "권한 확인 창에서 멈춤"
    var current = before
    current.schedules[0].name = "고침"
    check(Engine.merge(before: before, after: after, current: current).schedules[0].blocked == "권한 확인 창에서 멈춤", "병합이 멈춤 표시를 옮김")
}

// MARK: Claude 명령 · 자동완성

do {
    let fm = CommandCatalog.frontmatter("---\nname: zm-ml-next\ndescription: \"다음 ML 번호\"\ndisable-model-invocation: true\n---\n본문")
    check(fm["name"] == "zm-ml-next" && fm["description"] == "다음 ML 번호" && fm["disable-model-invocation"] == "true", "frontmatter 따옴표", "\(fm)")
    let folded = CommandCatalog.frontmatter("---\ndescription: >\n  첫 줄\n  둘째 줄\nname: x\n---")
    check(folded["description"] == "첫 줄 둘째 줄" && folded["name"] == "x", "frontmatter 여러 줄 설명", "\(folded)")
    check(CommandCatalog.frontmatter("# 제목만").isEmpty, "frontmatter 없음")

    check(CommandCatalog.trailingToken("/zm-ml") == "zm-ml", "줄 처음 / 조각")
    check(CommandCatalog.trailingToken("먼저 /") == "", "공백 뒤 / 만")
    check(CommandCatalog.trailingToken("a/b") == nil, "경로 중간 / 는 아님")
    check(CommandCatalog.trailingToken("/zm next") == nil, "공백 지나면 끝")
    check(CommandCatalog.complete("실행: /zm-ml", with: "zm-ml-next") == "실행: /zm-ml-next ", "조각을 이름으로 바꿈")
    check(CommandCatalog.step(0, by: 1, count: 3) == 1, "↓ 다음 줄")
    check(CommandCatalog.step(2, by: 1, count: 3) == 0, "↓ 끝에서 처음으로")
    check(CommandCatalog.step(0, by: -1, count: 3) == 2, "↑ 처음에서 끝으로")
    check(CommandCatalog.step(9, by: 1, count: 3) == 0, "목록이 줄면 끝 줄 기준")
    check(CommandCatalog.step(0, by: 1, count: 0) == 0, "빈 목록")

    let list = [ClaudeCommand(name: "zm-ml-start", detail: "ML 점유", source: "프로젝트", modelInvocable: true),
                ClaudeCommand(name: "review", detail: "리뷰", source: "내장", modelInvocable: false),
                ClaudeCommand(name: "zm-ml-next", detail: "다음 번호", source: "프로젝트", modelInvocable: true),
                ClaudeCommand(name: "kakaotalk:send", detail: "보내기", source: "플러그인", modelInvocable: true)]
    check(CommandCatalog.match("zm-ml-n", in: list).map(\.name) == ["zm-ml-next"], "앞부분 맞춤")
    check(CommandCatalog.match("번호", in: list).map(\.name) == ["zm-ml-next"], "설명으로 찾기")
    check(CommandCatalog.match("send", in: list).map(\.name) == ["kakaotalk:send"], "플러그인 이름 뒷부분")
    check(CommandCatalog.match("ZM-ML", in: list).map(\.name) == ["zm-ml-start", "zm-ml-next"], "대소문자 무시 · 목록 순서 유지")
    check(CommandCatalog.match("ml", in: list, limit: 1).map(\.name) == ["zm-ml-start"], "limit 에서 자름")
    check(CommandCatalog.match("view", in: list).map(\.name) == ["review"], "이름 중간에 들어 있음")
    check(CommandCatalog.match("없는말", in: list).isEmpty, "맞는 것 없음")
    check(CommandCatalog.suggestions("zm-ml-next", in: list).isEmpty, "이름을 다 치면 후보를 닫음")
    check(CommandCatalog.suggestions("zm-ml", in: list).count == 2, "조각이면 후보")
    check(CommandCatalog.locked(in: "먼저 /review 를 하고 /zm-ml-next 를 실행", list: list).map(\.name) == ["review"], "템플릿 안 잠긴 명령 찾기")

    // 폴더에서 읽기: 명령 · 스킬 · 숨긴 스킬 · 잠긴 스킬, 프로젝트가 개인보다 앞
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orcacron-check-\(UUID().uuidString)")
    let home = tmp.appendingPathComponent("home")
    let proj = tmp.appendingPathComponent("proj")
    func put(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    put(home.appendingPathComponent(".claude/commands/deploy.md"), "# 배포한다\n본문")
    put(home.appendingPathComponent(".claude/skills/hidden/SKILL.md"), "---\nname: hidden\nuser-invocable: false\n---")
    put(home.appendingPathComponent(".claude/skills/same/SKILL.md"), "---\nname: same\ndescription: 개인판\n---")
    put(proj.appendingPathComponent(".claude/skills/same/SKILL.md"), "---\nname: same\ndescription: 프로젝트판\n---")
    put(proj.appendingPathComponent(".claude/skills/lock/SKILL.md"), "---\nname: lock\ndisable-model-invocation: true\n---")
    let loaded = CommandCatalog.load(projectDirs: [proj.path], home: home)
    check(loaded.first { $0.name == "deploy" }?.detail == "배포한다", "개인 명령은 첫 줄을 설명으로")
    check(!loaded.contains { $0.name == "hidden" }, "/ 메뉴에 안 나오는 스킬은 뺌")
    check(loaded.first { $0.name == "same" }?.detail == "프로젝트판", "같은 이름이면 프로젝트 우선")
    check(loaded.first { $0.name == "lock" }?.modelInvocable == false, "잠긴 스킬 표시")
    check(loaded.contains { $0.name == "clear" && $0.source == "내장" }, "내장 명령 포함")
    try? FileManager.default.removeItem(at: tmp)

    // 명령으로 시작하는 직접 입력은 글 그대로, 결과를 기다리지 않는다
    var cmd = Schedule(id: "c", name: "c", terminal: TerminalRef(handle: "term_a", label: "l"), cron: "0 9 * * *", prompt: "/zm-ml-next")
    check(cmd.isCommand && !cmd.tracksResult, "명령은 결과 받기 없음")
    check(Engine.message(for: cmd, runId: "r", config: config) == "/zm-ml-next", "명령은 글 그대로 보냄")
    cmd.track = true
    check(!cmd.tracksResult, "결과 받기를 켜도 명령은 안 받음")
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var store = StoreFile(schedules: [cmd])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 8, 0))
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0, 30), makeRunId: rid)
    check(port.sent.first?.1 == "/zm-ml-next" && store.schedules[0].runId == nil && store.schedules[0].lastStatus == "보냄", "예약 명령 보냄 기록")
    let task = Schedule(id: "t", name: "t", terminal: TerminalRef(handle: "h", label: "l"), cron: "0 9 * * *", task: "x", prompt: nil)
    check(!task.isCommand && task.tracksResult, "템플릿은 명령 아님")
}

// MARK: 하루 여러 번 — 분이 다른 시각
do {
    let c = Cron("30 9 * * *;0 18 * * *")
    check(c?.expression == "30 9 * * *; 0 18 * * *", "여러 식은 「; 」로 정리")
    check(c?.summary == "매일 09:30 · 18:00", "여러 식 요약은 시각을 모음", c?.summary ?? "nil")
    check(next("30 9 * * *; 0 18 * * *", at(2026, 11, 11, 10, 0)) == at(2026, 11, 11, 18, 0), "가장 이른 다음 시각")
    check(next("30 9 * * *; 0 18 * * *", at(2026, 11, 11, 18, 0)) == at(2026, 11, 12, 9, 30), "다음 날 첫 시각")
    check(Cron("0 9,13 * * 1-5; 30 18 * * 1-5")?.summary == "평일 09:00 · 13:00 · 18:30", "평일 여러 시각 요약")
    check(Cron("30 9 * * *; 61 18 * * *") == nil, "식 하나라도 틀리면 거절")
    check(Cron("0 9 * * 1; 0 18 * * *")?.summary == "매주 월 09:00 / 매일 18:00", "요일이 다르면 따로 씀")
}

// MARK: 시각 — 요일 + 정한 시각 / 구간 반복
do {
    func spec(_ d: TimeSpec.Days, _ p: TimeSpec.Pattern) -> TimeSpec { TimeSpec(days: d, pattern: p) }
    func roundTrip(_ t: TimeSpec, _ what: String) {
        let back = t.cron.flatMap { TimeSpec(cron: $0) }
        check(back == t, "왕복 \(what)", "→ \(t.cron ?? "nil") → \(String(describing: back))")
    }

    // 구간 반복 — 사용자 예시: 07:00~08:00 5분마다(끝 포함)
    let win = spec(.everyDay, .every(5, from: 420, to: 480))
    check(win.cron == "*/5 7 * * *; 0 8 * * *", "구간 반복 cron", win.cron ?? "nil")
    check(win.summary == "매일 07:00~08:00 5분마다", "구간 반복 설명", win.summary)
    check(win.runsPerDay == 13, "07:00~08:00 5분마다 = 13번", "\(win.runsPerDay)")
    roundTrip(win, "구간 반복")
    check(next(win.cron!, at(2026, 11, 11, 7, 57)) == at(2026, 11, 11, 8, 0), "구간 끝 시각도 돈다")
    check(next(win.cron!, at(2026, 11, 11, 8, 0)) == at(2026, 11, 12, 7, 0), "구간이 끝나면 다음 날 시작")
    check(Cron(win.cron!)?.summary == "매일 07:00~08:00 5분마다", "목록 줄 설명도 같음")

    // 종일
    check(spec(.everyDay, .every(5, from: 0, to: 1439)).cron == "*/5 * * * *", "종일 5분마다 cron")
    check(spec(.everyDay, .every(5, from: 0, to: 1439)).summary == "5분마다", "종일 매일은 「N분마다」만")
    check(TimeSpec(cron: "*/10 * * * *") == spec(.everyDay, .every(10, from: 0, to: 1439)), "*/10 → 종일 10분마다")
    check(spec(.weekdays, .every(30, from: 0, to: 1439)).summary == "평일 30분마다", "평일 종일")
    check(spec(.everyDay, .every(120, from: 0, to: 1439)).cron == "0 */2 * * *", "2시간마다 cron")
    check(spec(.everyDay, .every(120, from: 0, to: 1439)).summary == "2시간마다", "2시간마다 설명")
    roundTrip(spec(.everyDay, .every(90, from: 0, to: 1439)), "90분마다")
    check(spec(.everyDay, .every(90, from: 0, to: 1439)).summary == "1시간 30분마다", "90분 설명")

    // 60 으로 나누어떨어지지 않는 간격은 시를 넘어도 이어진다(cron `*/7` 은 매시 0분에 다시 시작)
    let seven = spec(.weekdays, .every(7, from: 0, to: 1439))
    roundTrip(seven, "7분마다")
    check(next(seven.cron!, at(2026, 11, 11, 0, 56)) == at(2026, 11, 11, 1, 3), "7분마다 — 00:56 다음은 01:03")
    check(TimeSpec(cron: "*/7 * * * *") == nil, "옛 */7 은 cron 직접으로 연다")

    // 구간 끝이 간격에 맞지 않으면 마지막으로 도는 시각으로 다시 열린다
    let odd = spec(.everyDay, .every(15, from: 430, to: 540))
    check(odd.cron.flatMap { TimeSpec(cron: $0) } == spec(.everyDay, .every(15, from: 430, to: 535)), "07:10~09:00 15분 → 끝 08:55",
          odd.cron ?? "nil")

    // 정한 시각
    let two = spec(.some([1, 3]), .times([540, 1080]))
    check(two.cron == "0 9,18 * * 1,3", "정한 시각 cron", two.cron ?? "nil")
    check(two.summary == "매주 월·수 09:00 · 18:00", "정한 시각 설명", two.summary)
    roundTrip(two, "정한 시각")
    roundTrip(spec(.weekdays, .times([570, 1080])), "분이 다른 시각")
    check(TimeSpec(cron: "0 9,10,11 * * *")?.pattern == .times([540, 600, 660]), "쉼표로 이은 시각은 같은 간격이어도 정한 시각")
    check(spec(.everyDay, .times([540, 600, 660])).cron == "0 9,10,11 * * *", "정한 시각은 범위로 줄이지 않는다")
    check(spec(.some([0, 6]), .times([600])).summary == "매주 토·일 10:00", "요일은 월요일부터")

    // 지금 저장된 예약 모양은 그대로 열린다
    for (cron, want) in [("3 0,6,12,18 * * *", [3, 363, 723, 1083]), ("13 12,19 * * *", [733, 1153]),
                         ("0 9,14 * * *", [540, 840]), ("0 9 * * *", [540])] {
        let t = TimeSpec(cron: cron)
        check(t == spec(.everyDay, .times(want)), "기존 예약 \(cron)", String(describing: t))
        check(t?.cron == cron, "기존 예약 \(cron) 다시 저장해도 같은 식", t?.cron ?? "nil")
    }
    check(TimeSpec(cron: "0 9-18 * * 1-5") == spec(.weekdays, .every(60, from: 540, to: 1080)), "0 9-18 → 09:00~18:00 1시간마다")
    check(Cron("0 9-18 * * 1-5")?.summary == "평일 09:00~18:00 1시간마다", "1시간마다 설명")
    check(TimeSpec(cron: "15 * * * *") == spec(.everyDay, .every(60, from: 15, to: 1439)), "15 * → 매시 15분")

    // 열 수 없는 모양
    check(TimeSpec(cron: "0 9 1 * *") == nil, "날짜를 정한 식은 cron 직접")
    check(TimeSpec(cron: "0 9 * * 1; 0 18 * * *") == nil, "식마다 요일이 다르면 cron 직접")

    // 휴일(토·일)
    let weekend = spec(.weekends, .times([540]))
    check(weekend.cron == "0 9 * * 0,6", "휴일 cron", weekend.cron ?? "nil")
    check(weekend.summary == "휴일 09:00", "휴일 설명", weekend.summary)
    roundTrip(weekend, "휴일")
    check(TimeSpec(cron: "0 9 * * 6,7")?.days == .weekends, "6,7 도 휴일(7=일)")
    check(TimeSpec.Days.of([0, 6]) == .weekends, "요일 고르기 토·일 → 휴일")
    check(next(weekend.cron!, at(2026, 11, 13, 10, 0)) == at(2026, 11, 14, 9, 0), "금요일 다음 휴일 = 토요일")
    check(spec(.weekends, .every(30, from: 600, to: 720)).summary == "휴일 10:00~12:00 30분마다", "휴일 구간 반복")

    // 날짜 지정 — 여섯째 칸이 연도, 그해 그날에만
    func dd(_ y: Int, _ m: Int, _ d: Int) -> TimeSpec.DayDate { TimeSpec.DayDate(year: y, month: m, day: d) }
    let picked = spec(.dates([dd(2026, 11, 20), dd(2026, 11, 25), dd(2026, 12, 3)]), .times([540, 1080]))
    check(picked.cron == "0 9,18 20,25 11 * 2026; 0 9,18 3 12 * 2026", "날짜 지정 cron", picked.cron ?? "nil")
    check(picked.summary == "11/20, 11/25, 12/3 09:00 · 18:00", "날짜 지정 설명", picked.summary)
    roundTrip(picked, "날짜 지정")
    check(next(picked.cron!, at(2026, 11, 13, 10, 0)) == at(2026, 11, 20, 9, 0), "고른 첫날 09:00")
    check(next(picked.cron!, at(2026, 11, 25, 18, 0)) == at(2026, 12, 3, 9, 0), "다음 고른 날로 건너뜀")
    check(next(picked.cron!, at(2026, 12, 3, 18, 0)) == nil, "고른 날이 다 지나면 다음 없음")
    check(next("0 9 20 11 * 2026", at(2027, 1, 1, 0, 0)) == nil, "지난 해만 남으면 바로 없음")
    let many = spec(.dates(Set((1...5).map { dd(2026, 11, 15 + $0) })), .times([540]))
    check(many.summary == "11/16 등 5일 09:00", "날이 많으면 첫날 등 N일", many.summary)
    let dateRepeat = spec(.dates([dd(2026, 11, 20)]), .every(5, from: 420, to: 480))
    check(dateRepeat.cron == "*/5 7 20 11 * 2026; 0 8 20 11 * 2026", "날짜 + 구간 반복 cron", dateRepeat.cron ?? "nil")
    check(dateRepeat.summary == "11/20 07:00~08:00 5분마다", "날짜 + 구간 반복 설명", dateRepeat.summary)
    roundTrip(dateRepeat, "날짜 + 구간 반복")
    let newYear = spec(.dates([dd(2027, 1, 2), dd(2026, 12, 31)]), .times([600]))
    check(newYear.cron == "0 10 31 12 * 2026; 0 10 2 1 * 2027", "해를 넘기는 날 순서", newYear.cron ?? "nil")
    roundTrip(newYear, "해를 넘기는 날")
    check(next(newYear.cron!, at(2026, 12, 31, 11, 0)) == at(2027, 1, 2, 10, 0), "해를 넘겨 다음 날")
    check(spec(.dates([]), .times([540])).cron == nil, "고른 날 없음")
    check(Cron("0 9 20 11 * 1999") == nil, "연도는 2000~2099")
    check(Cron("0 9 20 11 * 2026") != nil && Cron("0 9 20 11 * 2026 1") == nil, "칸은 5개 또는 6개")
    check(TimeSpec(cron: "0 9 31 2 * 2027") == nil, "없는 날(2월 31일)만이면 cron 직접")
    check(TimeSpec(cron: "0 9 20 11 1 2026") == nil, "날짜에 요일까지 걸면 cron 직접")
    check(TimeSpec(cron: "0 9 20 11 * 2026; 0 18 25 11 * 2026") == nil, "날마다 시각이 다르면 cron 직접")
    check(TimeSpec(cron: "0 9 20 11 * 2026; 0 9 * * *") == nil, "연도 있는 식과 없는 식이 섞이면 cron 직접")
    check(TimeSpec.DayDate(year: 2026, month: 2, day: 30).date(cal) == nil, "없는 날은 날짜가 아님")

    // 시각 칸에 친 글
    for (text, want) in [("9:30", 570), ("09:30", 570), ("930", 570), ("0930", 570), ("9", 540), ("21", 1260),
                         ("9시 30분", 570), ("9시", 540), (" 7:05 ", 425), ("7.05", 425), ("7:5", 425), ("0", 0), ("23:59", 1439)] {
        check(TimeSpec.minute(fromText: text) == want, "시각 글 「\(text)」", "\(String(describing: TimeSpec.minute(fromText: text)))")
    }
    for text in ["", "24:00", "9:60", "960", "12345", "abc", "9:30:00", ":30", "1:234"] {
        check(TimeSpec.minute(fromText: text) == nil, "틀린 시각 글 「\(text)」")
    }
    check(TimeSpec.clockText(425) == "07:05" && TimeSpec.clockText(0) == "00:00", "분 → HH:MM")

    // 요일 정리 · 막는 값
    check(TimeSpec.Days.of(Set(1...5)) == .weekdays && TimeSpec.Days.of(Set(0...6)) == .everyDay, "요일 고르기 → 평일·매일")
    check(spec(.some([]), .times([540])).cron == nil, "요일 없음")
    check(spec(.everyDay, .times([])).cron == nil, "시각 없음")
    check(spec(.everyDay, .every(0, from: 0, to: 1439)).cron == nil, "간격 0")
    check(spec(.everyDay, .every(721, from: 0, to: 1439)).cron == nil, "간격 720 넘음")
    check(spec(.everyDay, .every(5, from: 600, to: 540)).cron == nil, "끝이 시작보다 빠름")
    check(spec(.everyDay, .every(60, from: 600, to: 600)).runsPerDay == 1, "시작=끝이면 한 번")
}

// MARK: 입력 칸 판정 — 글자·가로줄 변형
do {
    let heavy = String(repeating: "━", count: 30)
    check(promptState(screenTail: [heavy, "❯ ", heavy]) == .empty, "굵은 가로줄도 입력 칸")
    check(promptState(screenTail: [rule, "› ", rule]) == .empty, "› 표시도 입력 칸")
    check(promptState(screenTail: [rule, "> 쓰는 중", rule]) == .typing, "> 표시 + 글은 입력 중")
    check(promptState(screenTail: ["  > 인용한 줄", "끝"]) == .unknown, "가로줄 없는 > 는 입력 칸 아님")
    check(promptState(screenTail: ["─────", "❯ "]) == .unknown, "짧은 줄은 가로줄 아님")
    check(promptState(screenTail: [rule, "❯ ", "> 인용"]) == .empty, "가로줄 없는 > 는 건너뛰고 위 입력 칸을 찾음")
}

// MARK: Codex·Gemini 터미널
do {
    check(AgentKind(identity: "codex") == .codex && AgentKind(identity: "Gemini") == .gemini && AgentKind(identity: nil) == nil
          && AgentKind(identity: "opencode") == nil, "Orca agentIdentity 를 에이전트 종류로")

    // Codex 0.166 실화면(2026-11-13) — 지나간 사용자 글도 › 로 시작한다
    let codexIdle = [
        "  Worked for 6m 21s • 2:25 PM",
        "› Claude입니다. 이력서 점검 고맙습니다. 사이트 수정 3개는 로컬 커",
        "  밋했습니다(104e66d, 04945c4). 대기해 주세요.",
        "  Worked for 3s • 2:28 PM",
        "  ↳ Recap: 포트폴리오 토이 UI·숫자와 이력서 검토 보고서를 완료했습니다.",
        "           중입니다.",
        "› Ask Codex to do anything",
        "  GPT-6.1-Sol low · ~/sonix/toy · 토이 섹션 교차 검토",
        "  ? for shortcuts                                         ⚠ 1 warning · f2 to view",
        "",
    ]
    check(promptState(screenTail: codexIdle, agent: .codex) == .empty, "Codex 빈 입력 칸(예시 문구)")
    check(promptState(screenTail: codexIdle, agent: .claude) == .unknown, "Claude 규칙으로는 Codex 입력 칸을 못 찾음")
    var follow = codexIdle
    follow[6] = "› Ask a follow-up question"
    check(promptState(screenTail: follow, agent: .codex) == .empty, "Codex 다른 예시 문구도 빈 칸")
    var typed = codexIdle
    typed[6] = "› 오늘 에러 정리해 줘"
    check(promptState(screenTail: typed, agent: .codex) == .typing, "Codex 쓰던 글")
    let codexAsk = [
        "  Would you like to run the following command?",
        "  $ /Apps/OrcaCron finish --run r1 --status 성공",
        "› 1. Yes, proceed (y)",
        "  2. Yes, and don't ask again for this command in this session (p)",
        "  3. No, and tell Codex what to do differently (esc)",
        "  Press enter to confirm or esc to cancel",
    ]
    check(promptState(screenTail: codexAsk, agent: .codex) == .unknown, "Codex 승인 창의 › 는 입력 칸이 아님")
    check(permissionPrompt(screenTail: codexAsk), "Codex 승인 창")
    let scrolled = ["› 지난 사용자 글", "• 답 첫 줄", "  둘째 줄", "  셋째 줄", "  넷째 줄", "  다섯째 줄", "  Worked for 3s • 2:28 PM"]
    check(promptState(screenTail: scrolled, agent: .codex) == .unknown, "맨 끝 몇 줄 밖의 지나간 사용자 글은 입력 칸 아님")
    check(!permissionPrompt(screenTail: codexIdle), "Codex 평소 화면은 승인 창 아님")

    // Gemini CLI — 둥근 상자 안의 > 줄(소스 InputPrompt 기준)
    let box = "╭────────────────────────────────────────────╮"
    let boxEnd = "╰────────────────────────────────────────────╯"
    let footer = "~/sonix/toy (main*)        no sandbox        gemini-2.5-pro (99% context left)"
    check(promptState(screenTail: ["✦ 끝났습니다.", box, "│ >   Type your message or @path/to/file    │", boxEnd, footer], agent: .gemini) == .empty,
          "Gemini 빈 입력 칸(예시 문구)")
    check(promptState(screenTail: [box, "│ > 오늘 에러 정리          │", "│   둘째 줄                 │", boxEnd, footer], agent: .gemini) == .typing,
          "Gemini 쓰던 글(여러 줄)")
    check(promptState(screenTail: [box, "│ !   Type your message or @path/to/file    │", boxEnd, footer], agent: .gemini) == .unknown,
          "Gemini 셸 모드는 보내지 않음")
    check(promptState(screenTail: ["> 지난 사용자 글", "✦ 답"], agent: .gemini) == .unknown, "상자 밖 > 는 입력 칸 아님")
    let geminiAsk = [
        "╭──────────────────────────────╮",
        "│ ?  Shell OrcaCron finish     │",
        "│ Allow execution?             │",
        "│ ● Yes, allow once            │",
        "│ ○ Yes, allow always ...      │",
        "│ ○ No (esc)                   │",
        "╰──────────────────────────────╯",
    ]
    check(permissionPrompt(screenTail: geminiAsk), "Gemini 승인 창")
    check(promptState(screenTail: geminiAsk, agent: .gemini) == .unknown, "Gemini 승인 창에는 입력 칸 없음")

    // 실행기 — Codex 터미널에 보내고, 지금 떠 있는 에이전트로 아이콘 정보를 채운다
    let codexTerm = TerminalInfo(handle: "term_c", title: "코덱스", agent: "codex", worktreePath: "/x/toy", connected: true, writable: true)
    let port = FakePort(terminals: [codexTerm], idle: ["term_c"])
    port.tails["term_c"] = codexIdle
    var store = StoreFile(schedules: [schedule("cx", cron: "0 9 * * *", terminal: "term_c")])
    store.schedules[0].runNowRequestedAt = at(2026, 11, 13, 9, 0)
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 13, 9, 0, 10), makeRunId: rid)
    check(port.sent.count == 1 && port.sent[0].0 == "term_c", "Codex 빈 입력 칸이면 보냄")
    check(store.schedules[0].terminal.kind == .codex, "예약에 에이전트 종류를 남김")
    _ = Engine.checkInFlight(&store, port: port, terminals: [codexTerm], now: at(2026, 11, 13, 9, 1), finishedQuiet: 600)
    check(store.schedules[0].runId != nil && store.schedules[0].blocked == nil, "막 보낸 Codex 는 결과를 기다림")
    port.tails["term_c"] = codexAsk
    _ = Engine.checkInFlight(&store, port: port, terminals: [codexTerm], now: at(2026, 11, 13, 9, 2), finishedQuiet: 600)
    check(store.schedules[0].blocked?.contains("권한 확인") == true, "Codex 가 결과 명령 승인 창에서 멈추면 알림")
    // 같은 탭에서 에이전트를 바꾸면 따라간다 — 에이전트가 꺼진 동안은 그대로 둔다
    port.terminals = [TerminalInfo(handle: "term_c", title: "셸", agent: nil, worktreePath: "/x/toy", connected: true, writable: true)]
    _ = Engine.reconnect(&store, terminals: port.terminals)
    check(store.schedules[0].terminal.kind == .codex, "에이전트가 꺼진 동안은 마지막 종류를 유지")
    port.terminals = [TerminalInfo(handle: "term_c", title: "제미나이", agent: "gemini", worktreePath: "/x/toy", connected: true, writable: true)]
    _ = Engine.reconnect(&store, terminals: port.terminals)
    check(store.schedules[0].terminal.kind == .gemini, "다른 에이전트를 띄우면 따라감")
    // 옛 예약 파일(agent 칸 없음)도 읽힌다
    let old = #"{"handle":"term_a","label":"x","tabId":"t","leafId":"l"}"#
    check((try? JSONDecoder().decode(TerminalRef.self, from: Data(old.utf8)))?.agent == nil, "agent 칸 없는 옛 예약도 읽음")
}

// MARK: 화면이 바뀐 것 같음 경고
do {
    var s = schedule("w", cron: "0 9 * * *")
    let now = at(2026, 11, 11, 12, 0)
    s.history = [RunRecord(at: at(2026, 11, 11, 10, 0), status: "건너뜀", summary: "60분 기다렸지만 입력 칸이 보이지 않음(질문·권한 창)")]
    check(Health.screenWarning(StoreFile(schedules: [s]), now: now) == nil, "한 번은 경고 안 함")
    var s2 = schedule("w2", cron: "0 9 * * *")
    s2.history = [RunRecord(at: at(2026, 11, 11, 11, 0), status: "건너뜀", summary: "입력 칸이 보이지 않음")]
    check(Health.screenWarning(StoreFile(schedules: [s, s2]), now: now) != nil, "24시간에 두 번이면 경고")
    check(Health.screenWarning(StoreFile(schedules: [s, s2]), now: at(2026, 11, 12, 11, 30)) == nil, "하루 지나면 경고 없음")
}

// MARK: 명령줄 요청(inbox)
do {
    var store = StoreFile(schedules: [])
    let r = SendRequest(id: "ab12", terminal: "term_a", text: "안녕", task: nil, track: true, name: nil, at: at(2026, 11, 11, 9, 0))
    _ = Engine.ingest([r], into: &store, known: [termA], now: at(2026, 11, 11, 9, 0))
    let s = store.schedules.first
    check(s?.id == "once-ab12" && s?.isOneShot == true && s?.pendingSince != nil && s?.tracksResult == true, "요청은 결과 받는 1회 보내기")
    check(s?.terminal.label == termA.ref.label && s?.name == "안녕", "터미널 이름·글 첫 줄을 씀")
    _ = Engine.ingest([r], into: &store, known: [termA], now: at(2026, 11, 11, 9, 1))
    check(store.schedules.count == 1, "같은 요청은 한 번만")

    // 확인 도중 사용자가 바꾼 목록에 실행기가 더한 것을 붙인다
    let before = StoreFile(schedules: [schedule("a", cron: "0 9 * * *")])
    var after = before
    after.schedules.append(store.schedules[0])
    var current = before
    current.schedules.append(schedule("b", cron: "0 10 * * *"))
    let merged = Engine.merge(before: before, after: after, current: current)
    check(merged.schedules.map(\.id) == ["a", "b", "once-ab12"], "합칠 때 새 요청을 붙임", merged.schedules.map(\.id).joined(separator: ","))
}

// MARK: 보내기 전 대화 비우기
do {
    let port = FakePort(terminals: [termA], idle: ["term_a"])
    var s = schedule("c", cron: "0 9 * * *")
    s.clearFirst = true
    var store = StoreFile(schedules: [s])
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 8, 0))
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 0, 30), makeRunId: rid)
    check(port.sent.map(\.1) == ["/clear"] && store.schedules[0].pendingSince != nil, "먼저 /clear 만 보냄")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 1), makeRunId: rid)
    check(port.sent.count == 2 && port.sent[1].1.contains("daily-report") && store.schedules[0].runId != nil, "다음 확인에 본문을 보냄")
    check(store.schedules[0].clearedFor == nil, "보낸 뒤 비우기 표시 지움")
    _ = Engine.tick(&store, port: port, config: config, now: at(2026, 11, 11, 9, 2), makeRunId: rid)
    check(port.sent.count == 2, "같은 실행에 /clear 를 다시 보내지 않음")
}

// MARK: 화면 이동 — 뒤로는 들어온 곳으로
do {
    let sch = schedule("e", cron: "0 9 * * *")
    // 예약 편집 → 템플릿 고치기(✎) → 취소: 편집 중이던 입력 그대로 예약 편집으로
    var nav = RouteStack()
    nav.go(.edit(sch, isNew: false))
    var typed = sch
    typed.name = "고치는 중"
    typed.cron = "30 9 * * *; 0 18 * * *"
    nav.openTemplate("daily-report", leaving: .edit(typed, isNew: false))
    check(nav.top == .template(key: "daily-report"), "✎ 는 그 템플릿 편집으로")
    nav.finishTemplate(key: "daily-report", saved: nil, title: nil)
    check(nav.top == .edit(typed, isNew: false), "템플릿 편집 취소 → 입력이 남은 예약 편집으로")
    nav.back()
    check(nav.top == .list, "예약 편집 취소 → 목록")

    // 예약 편집 → 새 템플릿(+) → 저장: 만든 템플릿을 골라 둔 채 돌아옴
    var blank = schedule("n", cron: "0 9 * * *", task: nil)
    blank.name = ""
    blank.prompt = "쓰던 글"
    var nav2 = RouteStack(.edit(blank, isNew: true))
    nav2.openTemplate(nil, leaving: .edit(blank, isNew: true))
    nav2.finishTemplate(key: nil, saved: "weekly", title: "주간 정리")
    if case .edit(let s, let isNew) = nav2.top {
        check(isNew && s.task == "weekly" && s.prompt == nil && s.name == "주간 정리", "새 템플릿 저장 → 골라 두고 이름 채움")
    } else { check(false, "새 템플릿 저장 → 예약 편집으로") }

    // 보내기 → 새 템플릿 → 저장: 고른 터미널 그대로, 새 템플릿 골라 둠
    var nav3 = RouteStack(.send(handle: "term_a", task: nil))
    nav3.openTemplate(nil, leaving: .send(handle: "term_a", task: nil))
    nav3.finishTemplate(key: nil, saved: "weekly", title: "주간 정리")
    check(nav3.top == .send(handle: "term_a", task: "weekly"), "보내기에서 만든 템플릿을 골라 둠")

    // 템플릿 목록 → 할당 → 취소: 템플릿 목록으로 / 저장: 목록으로
    var nav4 = RouteStack()
    nav4.go(.templates)
    nav4.go(.edit(sch, isNew: true))
    nav4.back()
    check(nav4.top == .templates, "템플릿에서 연 예약 편집을 취소하면 템플릿 목록으로")
    nav4.go(.send(handle: "term_a", task: "daily-report"))
    nav4.back()
    check(nav4.top == .templates, "템플릿에서 연 보내기를 취소하면 템플릿 목록으로")
    nav4.go(.edit(sch, isNew: true))
    nav4.go(.list)
    check(nav4.top == .list && nav4.stack.isEmpty, "저장하면 목록으로")

    // 템플릿 목록 → 템플릿 편집 → 저장: 템플릿 목록으로(골라 둘 화면 없음)
    var nav5 = RouteStack(.templates)
    nav5.go(.template(key: nil))
    nav5.finishTemplate(key: nil, saved: "x", title: "x")
    check(nav5.top == .templates, "템플릿 목록에서 만든 템플릿 저장 → 템플릿 목록으로")
    nav5.back()
    check(nav5.top == .list, "템플릿 목록 뒤로 → 목록")
    nav5.back()
    check(nav5.top == .list, "목록에서 뒤로는 그대로")
}

// MARK: 복제 — 사용자 칸만
do {
    var s = schedule("orig", cron: "30 9 * * *; 0 18 * * *")
    s.clearFirst = true
    s.lateLimit = 3600
    s.enabled = false
    s.lastStatus = "성공"
    s.history = [RunRecord(at: at(2026, 11, 11, 9, 30), status: "성공", summary: "x")]
    s.pendingSince = at(2026, 11, 11, 9, 0)
    s.runId = "r9"
    let d = s.duplicated(id: "copy", name: "orig 사본")
    check(d.id == "copy" && d.name == "orig 사본" && d.cron == s.cron && d.task == s.task && d.terminal == s.terminal,
          "복제는 시각·내용·터미널을 옮김")
    check(d.clearFirst == true && d.lateLimit == 3600 && d.enabled == false, "복제는 선택 칸도 옮김")
    check(d.history.isEmpty && d.lastStatus == nil && d.pendingSince == nil && d.runId == nil && d.nextRunAt == nil,
          "복제는 실행 기록·대기 상태를 비움")
}

// MARK: 실행 기록 보관 — 날짜별 · 한 쪽 10개
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orcacron-archive-\(UUID().uuidString)")
    let paths = Paths(base: tmp)
    try? paths.ensure()
    defer { try? FileManager.default.removeItem(at: tmp) }
    func rec(_ d: Date, _ status: String = "성공") -> RunRecord { RunRecord(at: d, status: status) }
    func sched(_ history: [RunRecord]) -> Schedule {
        var s = Schedule(id: "s-arch", name: "a", terminal: TerminalRef(handle: "h", label: "l"), cron: "0 9 * * *", task: "x")
        s.history = history
        return s
    }

    let r1 = rec(at(2026, 11, 10, 9, 0)), r2 = rec(at(2026, 11, 11, 9, 0)), r3 = rec(at(2026, 11, 11, 18, 0), "실패")
    check(RunArchive.added(old: sched([r1]), new: sched([r3, r2, r1])) == [r2, r3], "새 기록만 · 오래된 것부터")
    check(RunArchive.added(old: nil, new: sched([r1])) == [r1], "새 예약은 전부")
    check(RunArchive.added(old: sched([r1]), new: sched([r1])).isEmpty, "그대로면 없음")

    // 처음엔 가진 최근 기록 전부로 시작, 그다음은 새 것만 덧붙인다
    let now = at(2026, 11, 11, 18, 1)
    RunArchive.record(old: StoreFile(schedules: [sched([r1])]), new: StoreFile(schedules: [sched([r2, r1])]), paths, now: now)
    check(RunArchive.load("s-arch", fallback: [], paths) == [r2, r1], "처음 쓸 때 최근 기록으로 시작")
    RunArchive.record(old: StoreFile(schedules: [sched([r2, r1])]), new: StoreFile(schedules: [sched([r3, r2, r1])]), paths, now: now)
    check(RunArchive.load("s-arch", fallback: [], paths) == [r3, r2, r1], "새 기록 덧붙임 · 새것이 위")
    check(RunArchive.load("없음", fallback: [r1], paths) == [r1], "파일이 없으면 최근 기록")

    // schedules.json 이 10개로 잘려도 보관은 계속 쌓인다
    var many = sched([r3, r2, r1])
    var before = many
    for i in 1...12 {
        before = many
        many.history.insert(rec(at(2026, 11, 12, 0, i)), at: 0)
        if many.history.count > Schedule.historyLimit { many.history.removeLast() }
        RunArchive.record(old: StoreFile(schedules: [before]), new: StoreFile(schedules: [many]), paths, now: now)
    }
    check(RunArchive.load("s-arch", fallback: [], paths).count == 15, "10개를 넘어도 보관", "\(RunArchive.load("s-arch", fallback: [], paths).count)")

    // 1회 보내기는 쌓지 않는다
    var once = sched([r1])
    once.id = "once-x"
    once.oneShot = true
    RunArchive.record(old: StoreFile(), new: StoreFile(schedules: [once]), paths, now: now)
    check(!FileManager.default.fileExists(atPath: paths.history.appendingPathComponent("once-x.jsonl").path), "1회 보내기는 쌓지 않음")

    // 30일 넘은 기록은 지운다
    let old = rec(at(2026, 9, 1, 9, 0))
    var aged = sched([r1, old])
    aged.id = "s-aged"
    RunArchive.record(old: StoreFile(), new: StoreFile(schedules: [aged]), paths, now: now)
    var aged2 = aged
    aged2.history.insert(r2, at: 0)
    RunArchive.record(old: StoreFile(schedules: [aged]), new: StoreFile(schedules: [aged2]), paths, now: now)
    check(RunArchive.load("s-aged", fallback: [], paths) == [r2, r1], "30일 지난 기록 지움")

    // 날짜 · 쪽
    let day = at(2026, 11, 12, 0, 0)
    let list = (0..<23).map { rec(at(2026, 11, 12, 9, 59 - $0)) } + [r3, r2, r1]
    check(RunArchive.days(list, calendar: cal) == [day, at(2026, 11, 11, 0, 0), at(2026, 11, 10, 0, 0)], "기록 있는 날 · 새 날이 위")
    let p0 = RunArchive.page(list, day: day, page: 0, calendar: cal)
    let p2 = RunArchive.page(list, day: day, page: 2, calendar: cal)
    check(p0.items.count == 10 && p0.total == 23 && p0.items.first == list[0], "첫 쪽 10개 · 그날 23개")
    check(p2.items.count == 3 && p2.items.last == list[22], "셋째 쪽 3개")
    check(RunArchive.page(list, day: day, page: 3, calendar: cal).items.isEmpty, "넘친 쪽은 빔")
    check(RunArchive.page(list, day: at(2026, 11, 9, 0, 0), page: 0, calendar: cal).total == 0, "기록 없는 날")

    // 지운 예약의 기록 — 하루 지나면 지운다
    let orphan = paths.history.appendingPathComponent("s-gone.jsonl")
    try? Data().write(to: orphan)
    RunArchive.removeOrphans(keeping: ["s-arch"], paths, now: Date())
    check(FileManager.default.fileExists(atPath: orphan.path), "방금 지운 예약 기록은 남김(되돌리기)")
    RunArchive.removeOrphans(keeping: ["s-arch"], paths, now: Date().addingTimeInterval(2 * 86400))
    check(!FileManager.default.fileExists(atPath: orphan.path), "하루 지난 고아 기록 지움")
    check(FileManager.default.fileExists(atPath: paths.history.appendingPathComponent("s-arch.jsonl").path), "있는 예약 기록은 남김")
}

print(failures == 0 ? "✓ 점검 \(checks)개 통과" : "✗ 점검 \(checks)개 중 \(failures)개 실패")
exit(failures == 0 ? 0 : 1)
