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
    check(port.sent.isEmpty && store.schedules[0].waitNote?.hasPrefix("화면이 60초 안에") == true, "최근 출력 → 대기")
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

print(failures == 0 ? "✓ 점검 \(checks)개 통과" : "✗ 점검 \(checks)개 중 \(failures)개 실패")
exit(failures == 0 ? 0 : 1)
