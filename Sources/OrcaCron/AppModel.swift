import AppKit
import IOKit.pwr_mgt
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

struct UndoAction {
    let id = UUID()
    let message: String
    let run: () -> Void
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
    /// 방금 지운 것을 되돌리는 동작(8초 동안 목록 아래에 보인다).
    @Published private(set) var undo: UndoAction?

    let paths: Paths
    /// false 면 화면만 채우고 아무것도 보내지 않는다(preview 용).
    let sending: Bool
    private let port: OrcaCLI?
    private var timer: Timer?
    private var updateTimer: Timer?
    private var sleepAssertion: IOPMAssertionID?
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
            // `OrcaCron send`·`test` 가 inbox 에 요청을 남기면 바로 확인한다.
            DistributedNotificationCenter.default().addObserver(forName: AppModel.inboxNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
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
            let key = "notifiedUpdateHead"
            if Notifier.level != .off, !info.head.isEmpty, UserDefaults.standard.string(forKey: key) != info.head {
                UserDefaults.standard.set(info.head, forKey: key)
                Notifier.post(title: "OrcaCron 업데이트가 있습니다",
                              body: "새 커밋 \(info.behind)개 — " + (info.subjects.first ?? "") + " · 메뉴의 「업데이트」를 누르세요")
            }
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

    static let inboxNotification = Notification.Name("lab.gook.orcacron.inbox")
    nonisolated static let quietKey = "quietSeconds"
    /// 화면이 이만큼 조용해야 보낸다(⋯ 메뉴에서 1·3·5·10분).
    nonisolated static var quietSeconds: Double {
        let v = UserDefaults.standard.double(forKey: quietKey)
        return v > 0 ? v : 60
    }

    func tick() {
        guard let port else { return }
        guard !ticking else { tickAgain = true; return }
        ticking = true
        let before = store
        let paths = self.paths
        let sending = self.sending && !loadFailed
        let config = EngineConfig(cliPath: cliPath, tasksDir: paths.tasks, quietTime: AppModel.quietSeconds)
        let known = terminals
        Task.detached(priority: .utility) {
            let now = Date()
            var after = before
            var log: [String] = []
            let results = sending ? Store.readResults(paths) : []
            let requests = sending ? Store.readRequests(paths) : []
            var listed: [TerminalInfo]?
            if sending {
                log += Engine.ingest(requests.map(\.1), into: &after, known: known, now: now)
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
                    let old = self.store
                    self.store = Engine.merge(before: before, after: finished, current: self.store)
                    self.notifyChanges(old: old, new: self.store)
                    self.persist()
                    Store.removeResults(results.map(\.0) + requests.map(\.0))
                    Store.appendLog(lines, paths, now: now)
                    self.updateSleepAssertion()
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

    /// 지운 뒤 8초 동안 「되돌리기」를 보여 준다. 끝난 보내기 기록처럼 되돌릴 필요가 없으면 undoable = false.
    func delete(_ id: String, undoable: Bool = true) {
        guard let i = store.schedules.firstIndex(where: { $0.id == id }) else { return }
        let removed = store.schedules.remove(at: i)
        persist()
        guard undoable else { return }
        offerUndo(removed.isOneShot && removed.pendingSince != nil ? "「\(removed.name)」 보내기를 취소했습니다" : "「\(removed.name)」 예약을 지웠습니다") { [weak self] in
            guard let self, !self.store.schedules.contains(where: { $0.id == removed.id }) else { return }
            self.store.schedules.insert(removed, at: min(i, self.store.schedules.count))
            self.persist()
        }
    }

    private func offerUndo(_ message: String, _ run: @escaping () -> Void) {
        let action = UndoAction(message: message, run: run)
        undo = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.undo?.id == action.id { self?.undo = nil }
        }
    }

    func performUndo() {
        let action = undo
        undo = nil
        action?.run()
    }

    func dismissUndo() { undo = nil }

    /// 사용자 칸만 같은 새 예약 초안(편집 화면에서 저장해야 생긴다).
    func duplicateDraft(_ s: Schedule) -> Schedule {
        s.duplicated(id: "s-" + String(UUID().uuidString.prefix(8)).lowercased(), name: s.name + " 사본")
    }

    /// 이 예약이 터미널에 실제로 보낼 글(실행 id 자리는 표시만).
    func messagePreview(_ s: Schedule) -> String {
        let text = Engine.message(for: s, runId: "<실행 id>", config: EngineConfig(cliPath: cliPath, tasksDir: paths.tasks))
        return s.clearFirst == true ? "/clear\n— 화면이 다시 조용해지면 —\n" + text : text
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
        // 첫 템플릿을 골라 두므로 이름도 그 제목으로 채운다(템플릿을 바꾸면 이름도 따라 바뀐다).
        return Schedule(id: "s-" + String(UUID().uuidString.prefix(8)).lowercased(),
                        name: tasks.first?.title ?? "",
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
        let saved = template(key)
        try? Store.deleteTemplate(key, paths)
        tasks = Store.listTasks(paths)
        guard let saved else { return }
        offerUndo("「\(saved.title)」 템플릿을 지웠습니다") { [weak self] in
            guard let self else { return }
            try? Store.writeTemplate(key, saved, self.paths)
            self.tasks = Store.listTasks(self.paths)
        }
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

    /// 새 결과(실패·결과 없음·건너뜀, 설정에 따라 성공)와 새 멈춤을 알린다.
    private func notifyChanges(old: StoreFile, new: StoreFile) {
        let level = Notifier.level
        guard level != .off else { return }
        let now = Date()
        if let w = Health.screenWarning(new, now: now), Health.screenWarning(old, now: now) == nil {
            Notifier.post(title: "OrcaCron · 입력 칸을 못 찾음", body: w)
        }
        for s in new.schedules {
            let o = old.schedules.first { $0.id == s.id }
            if let r = s.history.first, r.at != o?.history.first?.at {
                let problem = ["실패", "결과 없음", "건너뜀"].contains(r.status)
                if problem || (level == .all && r.status == "성공") {
                    Notifier.post(title: "OrcaCron · \(s.name)", body: r.status + (r.summary.map { " — \($0)" } ?? ""))
                }
            }
            if let b = s.blocked, b != o?.blocked {
                Notifier.post(title: "OrcaCron · \(s.name)", body: b)
            }
        }
    }

    /// 받는 Claude Code 세션이 결과 명령을 묻지 않고 실행하게 하는 권한 규칙(~/.claude/settings.json 의 permissions.allow).
    var allowRule: String { "Bash(\(cliPath) finish:*)" }

    func copyAllowRule() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\"\(allowRule)\"", forType: .string)
    }

    // MARK: Claude 명령(자동완성)

    private var commandCache: [String: (at: Date, list: [ClaudeCommand])] = [:]

    /// 그 터미널의 작업 폴더 기준 명령 목록. 60초 동안 기억한다.
    func commands(forTerminal handle: String) -> [ClaudeCommand] {
        commands(projectDirs: terminals.first { $0.handle == handle }.map { [$0.worktreePath] } ?? [])
    }

    /// 템플릿은 어느 터미널로 갈지 모르므로 떠 있는 터미널들의 작업 폴더를 모두 본다.
    var commandsForAnyTerminal: [ClaudeCommand] {
        commands(projectDirs: Array(Set(terminals.map(\.worktreePath))).sorted())
    }

    func commands(projectDirs: [String]) -> [ClaudeCommand] {
        let key = projectDirs.joined(separator: "|")
        if let hit = commandCache[key], Date().timeIntervalSince(hit.at) < 60 { return hit.list }
        let list = CommandCatalog.load(projectDirs: projectDirs)
        commandCache[key] = (Date(), list)
        return list
    }

    // MARK: 잠자기 막기

    /// 보낼 예약이 대기 중이거나 결과를 기다리는 동안(보낸 지 2시간 안) 맥이 저절로 잠들지 않게 한다.
    /// 화면은 꺼질 수 있고, 덮개를 닫으면 막지 못한다.
    private func updateSleepAssertion() {
        let now = Date()
        let busy = store.schedules.contains { s in
            s.enabled && (s.pendingSince != nil || (s.runId != nil && now.timeIntervalSince(s.sentAt ?? .distantPast) < 7200))
        }
        if busy, sleepAssertion == nil {
            var id: IOPMAssertionID = 0
            let reason = "OrcaCron: scheduled task waiting or running" as CFString  // pmset 이 한글 이름을 빈칸으로 보여 영문
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                sleepAssertion = id
            }
        } else if !busy, let id = sleepAssertion {
            IOPMAssertionRelease(id)
            sleepAssertion = nil
        }
    }

    // MARK: 연결 시험 · 화면 진단

    /// 받는 Claude 가 글을 받고 결과 명령까지 실행하는지 한 번 보낸다.
    func sendTest(to handle: String) {
        quickSend(to: handle, text: Engine.testPrompt, track: true)
        if let i = store.schedules.lastIndex(where: { $0.isOneShot && $0.terminal.handle == handle }) {
            store.schedules[i].name = "연결 시험"
            persist()
        }
    }

    var screenWarning: String? { Health.screenWarning(store, now: Date()) }

    /// Orca 의 그 터미널 탭으로 간다 — 탭을 앞으로 가져온 뒤 Orca 앱을 활성화한다(팝업은 저절로 닫힌다).
    func focus(_ handle: String) {
        guard let port else { return }
        Task.detached(priority: .userInitiated) {
            let ok = port.focus(handle)
            await MainActor.run {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: port.appURL, configuration: configuration)
                if !ok { self.refresh() }  // 핸들이 바뀌었을 수 있다 — 목록을 다시 읽는다
            }
        }
    }

    /// Claude 터미널마다 판정 결과와 화면 끝 15줄을 파일로 남기고 연다. 화면 내용이 그대로 들어가니 공유 전에 확인해야 한다.
    func saveDiagnosis() {
        guard let port else { return }
        let terms = terminals
        let base = paths.base
        let quiet = Int(AppModel.quietSeconds)
        Task.detached(priority: .utility) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmm"
            var out = """
            # OrcaCron 화면 진단 \(Date())
            # 앱 \(Updater.version) (\(Updater.shortCommit)) · 조용한 시간 \(quiet)초
            # ⚠ 아래에 터미널 화면 내용이 그대로 들어 있습니다. 공유하기 전에 지울 내용이 없는지 확인하세요.

            """
            for t in terms {
                let tail = port.screenTail(t.handle)
                out += """

                ## \(t.displayName) (\(t.handle))
                대기 상태: \(port.isIdle(t.handle) ? "idle" : "작업 중") · 입력 칸: \(promptState(screenTail: tail)) · 권한 창: \(permissionPrompt(screenTail: tail) ? "있음" : "없음")
                --- 화면 끝 15줄 ---
                \(tail.suffix(15).joined(separator: "\n"))

                """
            }
            let url = base.appendingPathComponent("diagnose-\(f.string(from: Date())).txt")
            try? out.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
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
        screenWarning != nil || store.schedules.contains {
            $0.waitNote != nil || $0.blocked != nil || ($0.enabled && ["실패", "결과 없음"].contains($0.lastStatus ?? ""))
        }
    }

    func taskTitle(_ key: String?) -> String? {
        guard let key else { return nil }
        return tasks.first { $0.key == key }?.title ?? key
    }
}
