import AppKit
import Foundation
import SchedulerCore

struct TerminalGroup: Identifiable {
    var handle: String
    var label: String
    var live: TerminalInfo?
    var schedules: [Schedule]
    var id: String { handle }

    /// 접힘 상태를 기억하는 키. Orca 를 다시 켜면 handle 이 바뀌므로 탭·패인 id 를 쓴다.
    var key: String {
        if let t = live, let tab = t.tabId, let leaf = t.leafId { return "\(tab):\(leaf)" }
        if let r = schedules.first?.terminal, let tab = r.tabId, let leaf = r.leafId { return "\(tab):\(leaf)" }
        return handle
    }

    /// 끝난 1회 보내기 — 목록에서는 「보낸 기록」으로 접는다.
    static func isFinishedOneShot(_ s: Schedule) -> Bool { s.isOneShot && s.pendingSince == nil && s.runId == nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var store = StoreFile()
    @Published private(set) var terminals: [TerminalInfo] = []
    @Published private(set) var tasks: [TaskFile] = []
    @Published var problem: String?
    @Published private(set) var update: UpdateInfo?
    @Published private(set) var updating = false
    @Published private(set) var updateMessage: String? // 확인 실패·설치 실패 이유
    @Published private(set) var checkingUpdate = false
    @Published private(set) var lastUpdateCheck: Date?

    let paths: Paths
    /// false 면 화면만 채우고 아무것도 보내지 않는다(preview 용).
    let sending: Bool
    private let port: OrcaCLI?
    private var timer: Timer?
    private var updateTimer: Timer?
    private var ticking = false
    private var tickAgain = false
    private var loadFailed = false
    let cliPath: String

    init(sending: Bool = true) {
        self.sending = sending
        paths = Paths.standard()
        cliPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        port = OrcaCLI.locate().map(OrcaCLI.init(binary:))
        do {
            try paths.ensure()
            store = try Store.load(paths)
        } catch {
            loadFailed = true
            problem = "예약 파일을 읽지 못해 저장을 멈췄습니다: \(paths.schedules.path)"
        }
        tasks = Store.listTasks(paths)
        if port == nil { problem = "Orca CLI 를 찾지 못했습니다(/Applications/Orca*.app)." }
        if sending {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // 업데이트는 켠 뒤 20초, 그다음 30분마다(팝업을 열 때도 10분이 지났으면).
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkUpdate() }
            updateTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkUpdate() }
            }
        }
        tick()
    }

    // MARK: 업데이트

    func checkUpdateIfStale() {
        guard sending, lastUpdateCheck.map({ Date().timeIntervalSince($0) >= 600 }) ?? true else { return }
        checkUpdate()
    }

    func checkUpdate(manual: Bool = false) {
        guard !checkingUpdate, !updating else { return }
        checkingUpdate = true
        Task.detached(priority: .utility) {
            let result = Updater.check()
            await MainActor.run { self.applyUpdateCheck(result, manual: manual) }
        }
    }

    private func applyUpdateCheck(_ result: UpdateCheck, manual: Bool) {
        checkingUpdate = false
        lastUpdateCheck = Date()
        switch result {
        case .upToDate:
            update = nil
            updateMessage = nil
        case .available(let info):
            update = info
            updateMessage = nil
        case .failed(let message, let quiet):
            update = nil
            if manual || !quiet { updateMessage = message }
        }
    }

    func installUpdate() {
        guard !updating else { return }
        updating = true
        updateMessage = nil
        Updater.install { message in
            Task { @MainActor in
                self.updating = false
                self.updateMessage = message
            }
        }
    }

    /// preview 전용.
    func previewUpdate() {
        update = UpdateInfo(behind: 2, subjects: ["feat: 템플릿 검색", "fix: 터미널 다시 연결"])
    }

    // MARK: 확인 주기

    func tick() {
        guard let port else { return }
        guard !ticking else { tickAgain = true; return }
        ticking = true
        let before = store
        let paths = self.paths
        let sending = self.sending && !loadFailed
        let config = EngineConfig(cliPath: cliPath, tasksDir: paths.tasks)
        Task.detached(priority: .utility) {
            let now = Date()
            var after = before
            var log: [String] = []
            let results = sending ? Store.readResults(paths) : []
            var listed: [TerminalInfo]?
            if sending {
                log += Engine.apply(results: results.map(\.1), to: &after)
                let r = Engine.tick(&after, port: port, config: config, now: now)
                log += r.log
                listed = r.terminals
            }
            let terms = listed ?? ((try? port.list()) ?? [])
            let finished = after
            let lines = log
            await MainActor.run {
                if sending {
                    self.store = Engine.merge(before: before, after: finished, current: self.store)
                    self.persist()
                    Store.removeResults(results.map(\.0))
                    Store.appendLog(lines, paths, now: now)
                }
                self.terminals = terms.filter { $0.agent == "claude" }
                self.tasks = Store.listTasks(paths)
                self.ticking = false
                if self.tickAgain {
                    self.tickAgain = false
                    self.tick()
                }
            }
        }
    }

    private func persist() {
        guard !loadFailed, sending else { return }
        do {
            try Store.save(store, paths)
        } catch {
            problem = "예약 파일을 쓰지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: 사용자 동작

    func save(_ s: Schedule) {
        if let i = store.schedules.firstIndex(where: { $0.id == s.id }) {
            store.schedules[i] = s
        } else {
            store.schedules.append(s)
        }
        persist()
        tick()
    }

    func delete(_ id: String) {
        store.schedules.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = store.schedules.firstIndex(where: { $0.id == id }) else { return }
        store.schedules[i].enabled = on
        if !on {
            store.schedules[i].pendingSince = nil
            store.schedules[i].pendingReason = nil
            store.schedules[i].waitNote = nil
        }
        persist()
    }

    func runNow(_ id: String) {
        guard let i = store.schedules.firstIndex(where: { $0.id == id }) else { return }
        store.schedules[i].runNowRequestedAt = Date()
        store.schedules[i].pendingSince = Date()
        store.schedules[i].pendingReason = "지금 실행"
        store.schedules[i].waitNote = nil
        persist()
        tick()
    }

    func refresh() { tick() }

    func newDraft(terminal handle: String? = nil) -> Schedule {
        let t = terminals.first { $0.handle == handle } ?? terminals.first
        return Schedule(id: "s-" + String(UUID().uuidString.prefix(8)).lowercased(),
                        name: "",
                        terminal: t?.ref ?? TerminalRef(handle: "", label: ""),
                        cron: "0 9 * * *",
                        task: tasks.first?.key)
    }

    /// 시각 없이 한 번 보낸다. 터미널이 비는 대로(조용 60초·입력 대기) 실행기가 보낸다.
    /// task 가 있으면 그 템플릿을 읽고 실행하라는 한 줄을, 없으면 text 를 그대로 보낸다.
    func quickSend(to handle: String, text: String, task: String? = nil, track: Bool) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task != nil || !body.isEmpty else { return }
        let ref = terminals.first { $0.handle == handle }?.ref ?? TerminalRef(handle: handle, label: handle)
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
        let name = task.flatMap { taskTitle($0) } ?? (firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine)
        var s = Schedule(id: "once-" + String(UUID().uuidString.prefix(8)).lowercased(),
                         name: name,
                         terminal: ref,
                         cron: "",
                         task: task,
                         prompt: task == nil ? body : nil)
        s.oneShot = true
        s.track = track
        s.runNowRequestedAt = Date()
        s.pendingSince = Date()
        s.pendingReason = "지금 실행"
        save(s)
    }

    // MARK: 템플릿(tasks/*.md)

    func template(_ key: String) -> TemplateText? { Store.readTemplate(key, paths) }

    /// key 가 nil 이면 새로 만든다. 저장한 키를 돌려준다.
    @discardableResult
    func saveTemplate(key: String?, _ t: TemplateText) -> String? {
        let k = key ?? Store.newTemplateKey(title: t.title, existing: Set(tasks.map(\.key)))
        do {
            try Store.writeTemplate(k, t, paths)
            tasks = Store.listTasks(paths)
            return k
        } catch {
            problem = "템플릿을 쓰지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteTemplate(_ key: String) {
        guard usage(of: key) == 0 else { return }
        try? Store.deleteTemplate(key, paths)
        tasks = Store.listTasks(paths)
    }

    /// 이 템플릿을 쓰는 예약 수(지우기 막음).
    func usage(of key: String) -> Int {
        store.schedules.filter { $0.task == key && !$0.isOneShot }.count
    }

    func draft(fromTemplate key: String) -> Schedule {
        var d = newDraft()
        d.task = key
        d.name = taskTitle(key) ?? ""
        return d
    }

    func openFolder() { NSWorkspace.shared.open(paths.base) }
    func openLog() { NSWorkspace.shared.open(paths.log) }

    // MARK: 화면용 값

    /// Orca 에 떠 있는 Claude 터미널 전부 + 예약은 있는데 터미널이 사라진 묶음.
    /// 예약이 있는 터미널을 위에, 없는 터미널을 아래에 둔다.
    var groups: [TerminalGroup] {
        var map: [String: TerminalGroup] = [:]
        var order: [String] = []
        for s in store.schedules {
            let h = s.terminal.handle
            if map[h] == nil {
                order.append(h)
                map[h] = TerminalGroup(handle: h, label: s.terminal.label,
                                       live: terminals.first { $0.handle == h }, schedules: [])
            }
            map[h]?.schedules.append(s)
        }
        for t in terminals where map[t.handle] == nil {
            order.append(t.handle)
            map[t.handle] = TerminalGroup(handle: t.handle, label: t.displayName, live: t, schedules: [])
        }
        return order.compactMap { map[$0] }
    }

    /// 가장 먼저 돌 예약과 그 시각.
    var nextUp: (name: String, at: Date)? {
        store.schedules.filter { $0.enabled && !$0.isOneShot }
            .compactMap { s in (s.nextRunAt ?? Cron(s.cron)?.next(after: Date())).map { (s.name, $0) } }
            .min { $0.1 < $1.1 }
            .map { (name: $0.0, at: $0.1) }
    }

    var needsAttention: Bool {
        store.schedules.contains { $0.waitNote != nil || ($0.enabled && ["실패", "결과 없음"].contains($0.lastStatus ?? "")) }
    }

    func taskTitle(_ key: String?) -> String? {
        guard let key else { return nil }
        return tasks.first { $0.key == key }?.title ?? key
    }
}
