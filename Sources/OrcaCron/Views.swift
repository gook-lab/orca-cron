import SwiftUI
import SchedulerCore

/// 화면 여백.
enum Pad {
    static let h: CGFloat = 16
    static let form: CGFloat = 16
}

/// 떠 있는 앱을 다시 실행하면 창을 연다 — 메뉴 막대가 노치까지 차서 아이콘이 가려졌을 때 쓰는 길.
/// Finder·`open` 은 reopen 이벤트로, 두 번째 프로세스는 분산 알림으로 들어온다(main.swift).
enum WindowOpener {
    static let notification = Notification.Name("lab.gook.orcacron.show")
    @MainActor static var open: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: WindowOpener.notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WindowOpener.open?() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowOpener.open?() }
        return false
    }
}

struct OrcaCronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, windowed: false)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        // 크기를 바꿔 쓰는 창. 메뉴의 「창으로 열기」나 앱 다시 실행으로 연다.
        Window("OrcaCron", id: "main") {
            MenuView(model: model, windowed: true)
                .frame(minWidth: 400, minHeight: 400)
        }
        .defaultSize(width: 640, height: 720)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// 메뉴 막대 아이콘. 늘 그려지는 뷰라 여기서 창 열기 동작을 넘겨 둔다.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.needsAttention ? "clock.badge.exclamationmark" : "clock")
            .onAppear {
                WindowOpener.open = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
    }
}

enum TimeText {
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) { return "오늘 \(f.string(from: date))" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return "내일 \(f.string(from: date))"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "어제 \(f.string(from: date))"
        }
        f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }
}

enum Screen: Equatable {
    case list
    case edit(Schedule, isNew: Bool)
    case send(handle: String, task: String?)
    case templates
    case template(key: String?)
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    let windowed: Bool
    @State private var screen: Screen
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, windowed: Bool, screen: Screen = .list) {
        self.model = model
        self.windowed = windowed
        _screen = State(initialValue: screen)
    }

    var body: some View {
        content
            .frame(width: windowed ? nil : 400)
            .frame(maxWidth: windowed ? .infinity : nil, maxHeight: windowed ? .infinity : nil, alignment: .top)
    }

    @ViewBuilder
    var content: some View {
        switch screen {
        case .list:
            ListView(model: model, windowed: windowed, go: { screen = $0 }, openWindow: {
                openWindow(id: "main")
                NSApp.activate()
            })
        case .edit(let s, let isNew):
            EditView(model: model, draft: s, isNew: isNew, go: { screen = $0 })
                .id("edit-\(s.id)-\(isNew)")
        case .send(let handle, let task):
            SendView(model: model, handle: handle, task: task) { screen = .list }
                .id("send-\(handle)-\(task ?? "")")
        case .templates:
            TemplatesView(model: model, windowed: windowed, go: { screen = $0 })
        case .template(let key):
            TemplateEditView(model: model, key: key) { screen = .templates }
                .id("template-\(key ?? "new")")
        }
    }
}

/// 팝업 목록의 최대 높이 — 화면 높이에 맞춘다.
@MainActor
func popupListMaxHeight() -> CGFloat {
    let h = NSScreen.main?.visibleFrame.height ?? 900
    return max(240, h * 0.72 - 120)
}

// MARK: 목록

struct ListView: View {
    @ObservedObject var model: AppModel
    let windowed: Bool
    let go: (Screen) -> Void
    let openWindow: () -> Void

    /// 예약 없는 터미널은 처음엔 이만큼만 보여 준다.
    static let idlePreview = 4
    @AppStorage("showAllIdleTerminals") private var showAllIdle = false
    @AppStorage("hideIdleTerminals") private var hideIdle = false
    @AppStorage(Notifier.levelKey) private var notifyLevel = NotifyLevel.problems.rawValue
    /// 접어 둔 터미널 묶음(키를 줄바꿈으로 이은 것).
    @AppStorage("collapsedGroups") private var collapsedRaw = ""

    var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    func setCollapsed(_ keys: Set<String>) {
        withAnimation(.easeOut(duration: 0.15)) { collapsedRaw = keys.sorted().joined(separator: "\n") }
    }

    func toggle(_ g: TerminalGroup) {
        var c = collapsed
        if c.contains(g.key) { c.remove(g.key) } else { c.insert(g.key) }
        setCollapsed(c)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                AppLogo(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("OrcaCron").font(.system(size: 12.5, weight: .bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                UpdateChip(model: model)
            }
            .padding(.horizontal, Pad.h).padding(.top, 10).padding(.bottom, 8)

            if model.update != nil || model.updating {
                UpdateBanner(model: model)
                    .padding(.horizontal, Pad.h).padding(.bottom, 10)
            } else if let message = model.updateMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Pad.h).padding(.bottom, 8)
            }

            if let p = model.problem {
                Text(p).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, Pad.h).padding(.bottom, 8)
            }

            Divider()

            let groups = model.groups
            let active = groups.filter { !$0.schedules.isEmpty || $0.live == nil }
            let idle = groups.filter { $0.schedules.isEmpty && $0.live != nil }
            if groups.isEmpty {
                Text("Orca 에 떠 있는 Claude Code 터미널이 없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(Pad.h)
                if windowed { Spacer() }
            } else {
                let list = ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(active) { g in
                            let folded = collapsed.contains(g.key)
                            groupHeader(g, collapsed: folded, onToggle: g.schedules.isEmpty ? nil : { toggle(g) })
                            if !folded {
                                ForEach(g.schedules.filter { !TerminalGroup.isFinishedOneShot($0) }) { s in
                                    ScheduleRow(model: model, schedule: s, onEdit: { go(.edit(s, isNew: false)) })
                                }
                                let sent = g.schedules.filter(TerminalGroup.isFinishedOneShot)
                                if !sent.isEmpty { SentHistory(model: model, items: sent) }
                            }
                        }
                        if !idle.isEmpty {
                            idleSection(idle, spaced: !active.isEmpty)
                        }
                    }
                    .padding(.bottom, 8)
                }
                if windowed {
                    list.frame(maxHeight: .infinity)
                } else {
                    list.frame(maxHeight: popupListMaxHeight()).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(spacing: 14) {
                Button { go(.edit(model.newDraft(), isNew: true)) } label: { Label("예약", systemImage: "plus") }
                    .help("새 예약")
                Button { go(.send(handle: model.terminals.first?.handle ?? "", task: nil)) } label: {
                    Label("보내기", systemImage: "paperplane")
                }
                .help("터미널에 지금 한 번 보내기")
                Button { go(.templates) } label: { Label("템플릿", systemImage: "doc.text") }
                    .help("템플릿 만들기·고치기·터미널에 할당")
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("지금 다시 확인")
                Menu {
                    if !windowed { Button("창으로 열기", action: openWindow) }
                    Picker("알림", selection: $notifyLevel) {
                        ForEach(NotifyLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Button("결과 명령 허용 규칙 복사") { model.copyAllowRule() }
                        .help("받는 Claude Code 의 ~/.claude/settings.json permissions.allow 에 붙여 넣으면 결과 명령을 묻지 않습니다")
                    Divider()
                    Button("터미널 묶음 모두 접기") { setCollapsed(Set(model.groups.filter { !$0.schedules.isEmpty }.map(\.key))) }
                    Button("모두 펼치기") { setCollapsed([]) }
                    Divider()
                    Button("데이터 폴더 열기") { model.openFolder() }
                    Button("실행 기록(log.txt) 열기") { model.openLog() }
                    Divider()
                    Button("OrcaCron 정보") { AboutPanel.show() }
                    Button("도움말(GitHub)") { NSWorkspace.shared.open(AboutPanel.homepage) }
                    Divider()
                    Button("종료") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight()
            }
            .buttonStyle(.icon)
            .font(.system(size: 12))
            .padding(.horizontal, Pad.h - 4).padding(.vertical, 6)
        }
        .onAppear { model.checkUpdateIfStale() }
    }

    var subtitle: String {
        let count = model.store.schedules.filter { !$0.isOneShot }.count
        guard let n = model.nextUp else { return count == 0 ? "예약 없음 — 터미널 줄의 📅+ 로 만드세요" : "켜진 예약 없음" }
        return "다음 \(TimeText.short(n.at)) · \(n.name)"
    }

    func groupHeader(_ g: TerminalGroup, collapsed: Bool = false, onToggle: (() -> Void)? = nil) -> some View {
        GroupHeader(group: g, collapsed: collapsed, onToggle: onToggle,
                    onSend: g.live == nil ? nil : { go(.send(handle: g.handle, task: nil)) },
                    onAdd: g.live == nil ? nil : { go(.edit(model.newDraft(terminal: g.handle), isNew: true)) })
    }

    /// 예약 없는 터미널 — 처음 4개만, 「더 보기」로 전부.
    @ViewBuilder
    func idleSection(_ idle: [TerminalGroup], spaced: Bool) -> some View {
        let shown = hideIdle ? [] : showAllIdle ? idle : Array(idle.prefix(Self.idlePreview))
        Button {
            withAnimation(.easeOut(duration: 0.15)) { hideIdle.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(hideIdle ? 0 : 90))
                Text("예약 없는 터미널 \(idle.count)")
            }
            .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.icon)
        .help(hideIdle ? "펼치기" : "접기")
        .padding(.leading, Pad.h - 8).padding(.top, spaced ? 10 : 6)
        ForEach(shown) { groupHeader($0) }
        if !hideIdle, idle.count > Self.idlePreview {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showAllIdle.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAllIdle ? "chevron.up" : "chevron.down")
                    Text(showAllIdle ? "접기" : "\(idle.count - Self.idlePreview)개 더 보기")
                }
                .font(.caption)
            }
            .buttonStyle(.icon)
            .padding(.horizontal, Pad.h - 4).padding(.top, 4)
        }
    }
}

/// 머리 줄 오른쪽에 늘 보이는 버전·업데이트 상태. 새 커밋이 있으면 「업데이트 N」(누르면 설치), 없으면 「v1.N ✓」(누르면 다시 확인).
struct UpdateChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.updating {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("업데이트 중").font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
            .fixedSize()
        } else if let update = model.update {
            Button { model.installUpdate() } label: {
                Label("업데이트 \(update.behind)", systemImage: "arrow.down.circle.fill").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .fixedSize()
            .help("새 커밋 \(update.behind)개 — 누르면 받아서 다시 빌드하고 앱을 다시 켭니다")
        } else {
            Button { model.checkUpdate(manual: true) } label: {
                HStack(spacing: 4) {
                    if model.checkingUpdate { ProgressView().controlSize(.mini) }
                    Text("v\(Updater.version)" + (model.updateMessage != nil ? " ⚠︎" : model.checkingUpdate ? "" : " ✓"))
                }
                .font(.caption)
                .foregroundStyle(model.updateMessage != nil ? Color.red : Color.secondary)
            }
            .buttonStyle(.icon)
            .fixedSize()
            .help(help)
        }
    }

    private var help: String {
        let checked = model.lastUpdateCheck.map { "마지막 확인 " + TimeText.short($0) } ?? "아직 확인 전"
        return "v\(Updater.version) · \(Updater.shortCommit) — \(checked). 누르면 다시 확인"
    }
}

/// 새 커밋이 있으면 머리 줄 아래에 무엇이 바뀌었는지 보여 준다.
struct UpdateBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                if model.updating {
                    Text("업데이트 중… 빌드가 끝나면 앱이 다시 켜집니다(1~2분)").font(.caption.weight(.semibold))
                } else if let update = model.update {
                    HStack {
                        Text("업데이트가 있습니다 — 새 커밋 \(update.behind)개").font(.caption.weight(.semibold))
                        Spacer(minLength: 6)
                        Button("변경 내용") { NSWorkspace.shared.open(Updater.changelogURL) }
                            .buttonStyle(.icon).font(.caption)
                    }
                    ForEach(update.subjects, id: \.self) { subject in
                        Text("· " + subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
    }
}

struct GroupHeader: View {
    let group: TerminalGroup
    var collapsed = false
    /// 있으면 묶음을 접고 펼 수 있다(예약이 있는 터미널).
    var onToggle: (() -> Void)?
    let onSend: (() -> Void)?
    let onAdd: (() -> Void)?

    var body: some View {
        let empty = group.schedules.isEmpty
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 9)
                    .opacity(onToggle == nil ? 0 : 1)
                Circle()
                    .fill(group.live == nil ? Color.red : (empty ? Color.secondary.opacity(0.5) : Color.green))
                    .frame(width: 7, height: 7)
                if let t = group.live {
                    Text(t.place.isEmpty ? "터미널" : t.place).font(.caption.weight(.semibold))
                        .foregroundStyle(empty ? .secondary : .primary)
                    Text(t.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(group.label).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("터미널 없음 — 편집에서 다시 고르세요").font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer(minLength: 4)
                if collapsed { summary }
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle?() }
            .help(onToggle == nil ? "" : collapsed ? "펼치기" : "접기")
            if let onSend {
                Button(action: onSend) { Image(systemName: "paperplane") }.help("이 터미널에 지금 보내기")
            }
            if let onAdd {
                Button(action: onAdd) { Image(systemName: "calendar.badge.plus") }.help("이 터미널에 예약 만들기")
            }
        }
        .buttonStyle(.icon)
        .font(.caption)
        .padding(.leading, Pad.h - 8).padding(.trailing, Pad.h - 4).padding(.top, empty ? 1 : 8).padding(.bottom, empty ? 1 : 2)
    }

    /// 접혀 있을 때 오른쪽 요약 — 예약 수 · 다음 시각 · 대기/실패 수.
    var summary: some View {
        let recurring = group.schedules.filter { !$0.isOneShot }
        let next = recurring.filter(\.enabled).compactMap(\.nextRunAt).min()
        let waiting = group.schedules.filter { $0.pendingSince != nil }.count
        let failed = recurring.filter { $0.enabled && ["실패", "결과 없음"].contains($0.lastStatus ?? "") }.count
        return HStack(spacing: 4) {
            if failed > 0 { Text("실패 \(failed)").foregroundStyle(.red) }
            if waiting > 0 { Text("대기 \(waiting)").foregroundStyle(.orange) }
            Text("예약 \(recurring.count)" + (next.map { " · 다음 \(TimeText.short($0))" } ?? ""))
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
    }
}

/// 끝난 1회 보내기 묶음 — 한 줄로 접어 두고, 누르면 한 줄씩 보인다.
struct SentHistory: View {
    @ObservedObject var model: AppModel
    let items: [Schedule]
    @State private var open = false

    var body: some View {
        let last = items.compactMap { $0.history.first?.at ?? $0.lastRunAt ?? $0.sentAt }.max()
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: "paperplane").font(.system(size: 9))
                    Text("보낸 기록 \(items.count)" + (last.map { " · 마지막 \(TimeText.short($0))" } ?? ""))
                }
                .font(.caption2)
            }
            .buttonStyle(.icon)
            .padding(.leading, Pad.h + 24).padding(.top, 1)
            if open {
                ForEach(items) { s in
                    HStack(spacing: 6) {
                        Text(s.name).font(.caption).lineLimit(1)
                        Text("\(s.lastStatus ?? "보냄") \(TimeText.short(s.history.first?.at ?? s.lastRunAt ?? s.sentAt))")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 4)
                        Button { model.delete(s.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.icon).help("기록 지우기 (24시간 뒤 자동으로 지워집니다)")
                    }
                    .padding(.leading, Pad.h + 44).padding(.trailing, Pad.h - 4)
                }
            }
        }
    }
}

struct ScheduleRow: View {
    @ObservedObject var model: AppModel
    let schedule: Schedule
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var hover = false
    @State private var showHistory = false

    var body: some View {
        let s = schedule
        HStack(alignment: .top, spacing: 8) {
            if s.isOneShot {
                Image(systemName: "paperplane.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 24).padding(.top, 2)
            } else {
                SmallSwitch(isOn: Binding(get: { s.enabled }, set: { model.setEnabled(s.id, $0) }))
                    .padding(.top, 2)
                    .help(s.enabled ? "켜짐 — 누르면 끕니다" : "꺼짐 — 누르면 켭니다")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(s.enabled ? .primary : .secondary)
                Text(scheduleLine(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                statusLine(s)
                if showHistory { historyList(s) }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !s.isOneShot { onEdit() } }
            .help(s.isOneShot ? "" : "누르면 편집")
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                if !s.isOneShot {
                    Button { model.runNow(s.id) } label: { Image(systemName: "play.fill") }
                        .help("지금 실행 — 터미널이 비면 바로 보냅니다")
                        .disabled(!s.enabled || s.pendingSince != nil || s.runId != nil)
                    Button(action: onEdit) { Image(systemName: "pencil") }.help("편집")
                }
                Button {
                    if confirmDelete { model.delete(s.id) } else {
                        confirmDelete = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                    }
                } label: {
                    if confirmDelete {
                        Text("삭제?").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .help(s.isOneShot && s.pendingSince != nil ? "보내기 취소 — 한 번 더 누르면 지웁니다" : "삭제 — 한 번 더 누르면 지웁니다")
            }
            .buttonStyle(.icon)
        }
        .font(.system(size: 11))
        .padding(.leading, Pad.h).padding(.trailing, Pad.h - 4).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.05 : 0)).padding(.horizontal, 6))
        .onHover { hover = $0 }
    }

    func scheduleLine(_ s: Schedule) -> String {
        let what = s.task.flatMap { model.taskTitle($0) }.map { "템플릿 「\($0)」" } ?? "직접 입력"
        if s.isOneShot { return "1회 보내기 · \(what) · " + (s.tracksResult ? "결과 받음" : "결과 안 받음") }
        let when = Cron(s.cron)?.summary ?? "잘못된 cron: \(s.cron)"
        let next = s.nextRunAt ?? Cron(s.cron)?.next(after: Date())
        return s.enabled ? "\(when) · 다음 \(TimeText.short(next)) · \(what)" : "\(when) · 꺼짐 · \(what)"
    }

    @ViewBuilder
    func statusLine(_ s: Schedule) -> some View {
        if s.pendingSince != nil {
            Text("대기 중 · \(s.waitNote ?? "다음 확인(30초 안)에 보냅니다")")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        } else if s.runId != nil {
            if let b = s.blocked {
                Text("⚠︎ \(b)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(s.lastStatus ?? "보냄") \(TimeText.short(s.sentAt)) · 결과 기록을 기다리는 중")
                    .font(.caption).foregroundStyle(.blue).lineLimit(1)
            }
        } else if let status = s.lastStatus {
            HStack(spacing: 4) {
                Text("\(status) \(TimeText.short(s.history.first?.at ?? s.lastRunAt))")
                    .foregroundStyle(color(status))
                if let sum = s.lastSummary, !sum.isEmpty {
                    Text("· \(sum)").foregroundStyle(.secondary).lineLimit(1)
                }
                if let link = s.lastLink, let url = URL(string: link) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help(link)
                }
                if s.history.count > 1 {
                    Spacer(minLength: 2)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showHistory.toggle() }
                    } label: {
                        HStack(spacing: 2) {
                            Text("기록 \(s.history.count)")
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                                .rotationEffect(.degrees(showHistory ? 90 : 0))
                        }
                    }
                    .buttonStyle(.icon)
                    .help("최근 실행 \(s.history.count)회")
                }
            }
            .font(.caption)
        } else {
            Text("아직 실행 기록 없음").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// 최근 실행 기록(최대 10회) — 날짜 · 결과 · 요약 · 링크.
    func historyList(_ s: Schedule) -> some View {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(s.history.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 5) {
                    Text(f.string(from: r.at)).foregroundStyle(.tertiary).monospacedDigit()
                    Text(r.status).foregroundStyle(color(r.status))
                    if let sum = r.summary, !sum.isEmpty {
                        Text(sum).foregroundStyle(.secondary).lineLimit(1).help(sum)
                    }
                    if let link = r.link, let url = URL(string: link) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help(link)
                    }
                }
            }
        }
        .font(.caption2)
        .padding(.top, 3).padding(.leading, 2)
    }

    func color(_ status: String) -> Color {
        switch status {
        case "성공": return .green
        case "실패", "결과 없음": return .red
        default: return .secondary
        }
    }
}

// MARK: 공통 조각

/// 왼쪽 칸 이름 + 오른쪽 입력 한 줄.
struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).font(.callout).foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 4) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TerminalPicker: View {
    @ObservedObject var model: AppModel
    @Binding var handle: String
    var fallbackLabel: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $handle) {
                if handle.isEmpty { Text("고르세요").tag("") }
                if !handle.isEmpty, !model.terminals.contains(where: { $0.handle == handle }) {
                    Text("\(fallbackLabel.isEmpty ? handle : fallbackLabel) (지금 없음)").tag(handle)
                }
                ForEach(model.terminals) { t in Text(t.displayName).tag(t.handle) }
            }
            .labelsHidden()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon).help("터미널 목록 다시 읽기")
        }
    }
}

struct TemplatePicker: View {
    @ObservedObject var model: AppModel
    @Binding var key: String?
    let manage: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { key ?? "" }, set: { key = $0.isEmpty ? nil : $0 })) {
                if (key ?? "").isEmpty { Text("고르세요").tag("") }
                ForEach(model.tasks) { t in Text(t.title).tag(t.key) }
            }
            .labelsHidden()
            if let manage {
                Button("관리", action: manage).buttonStyle(.icon).font(.caption)
            }
        }
        if let t = model.tasks.first(where: { $0.key == key }), !t.detail.isEmpty {
            Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PromptEditor: View {
    @Binding var text: String
    var height: CGFloat = 72

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}

struct FormFooter: View {
    let primary: String
    let enabled: Bool
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("취소", action: cancel).keyboardShortcut(.cancelAction)
            Button(primary, action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
        }
    }
}

// MARK: 예약 편집

enum TimeMode: String, CaseIterable, Identifiable {
    case daily = "매일"
    case weekdays = "평일"
    case weekly = "매주 요일"
    case multi = "하루 여러 번"
    case every = "N분마다"
    case cron = "cron 직접"
    var id: String { rawValue }
}

struct EditView: View {
    @ObservedObject var model: AppModel
    @State private var draft: Schedule
    let isNew: Bool
    let go: (Screen) -> Void

    @State private var useTemplate: Bool
    @State private var mode: TimeMode
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var hoursText: String
    @State private var every: Int
    @State private var minuteOfHour: Int
    @State private var cronText: String

    init(model: AppModel, draft: Schedule, isNew: Bool, go: @escaping (Screen) -> Void) {
        self.model = model
        self.isNew = isNew
        self.go = go
        _draft = State(initialValue: draft)
        _useTemplate = State(initialValue: draft.prompt == nil)
        _cronText = State(initialValue: draft.cron)
        let f = EditView.fill(from: isNew ? "0 9 * * *" : draft.cron)
        _mode = State(initialValue: f.mode)
        _time = State(initialValue: Calendar.current.date(bySettingHour: f.hour, minute: f.minute, second: 0, of: Date()) ?? Date())
        _days = State(initialValue: f.days)
        _hoursText = State(initialValue: f.hours)
        _every = State(initialValue: f.every)
        _minuteOfHour = State(initialValue: f.minute)
    }

    /// 흔한 cron 모양이면 그 칸으로 연다. 아니면 「cron 직접」.
    static func fill(from cron: String) -> (mode: TimeMode, hour: Int, minute: Int, days: Set<Int>, hours: String, every: Int) {
        let p = cron.split(separator: " ").map(String.init)
        var out: (mode: TimeMode, hour: Int, minute: Int, days: Set<Int>, hours: String, every: Int) = (.cron, 9, 0, [1], "12,19", 30)
        guard p.count == 5, p[2] == "*", p[3] == "*" else { return out }
        if p[1] == "*", p[4] == "*", p[0].hasPrefix("*/"), let n = Int(p[0].dropFirst(2)) {
            out.mode = .every
            out.every = n
            return out
        }
        guard let m = Int(p[0]) else { return out }
        out.minute = m
        let parts = p[1].split(separator: ",")
        let hours = parts.compactMap { Int($0) }
        guard !hours.isEmpty, hours.count == parts.count else { return out }
        out.hour = hours[0]
        out.hours = p[1]
        if hours.count > 1 {
            if p[4] == "*" { out.mode = .multi }
            return out
        }
        if p[4] == "*" {
            out.mode = .daily
        } else if p[4] == "1-5" {
            out.mode = .weekdays
        } else {
            let dayParts = p[4].split(separator: ",")
            let ds = dayParts.compactMap { Int($0) }.map { $0 == 7 ? 0 : $0 }
            if !ds.isEmpty, ds.count == dayParts.count, ds.allSatisfy({ (0...6).contains($0) }) {
                out.mode = .weekly
                out.days = Set(ds)
            }
        }
        return out
    }

    var hm: (Int, Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 9, c.minute ?? 0)
    }

    var cron: String {
        let (h, m) = hm
        switch mode {
        case .daily: return "\(m) \(h) * * *"
        case .weekdays: return "\(m) \(h) * * 1-5"
        case .weekly: return "\(m) \(h) * * \(days.isEmpty ? "1" : days.sorted().map(String.init).joined(separator: ","))"
        case .multi: return "\(minuteOfHour) \(hoursText.replacingOccurrences(of: " ", with: "")) * * *"
        case .every: return "*/\(every) * * * *"
        case .cron: return cronText.trimmingCharacters(in: .whitespaces)
        }
    }

    var parsed: Cron? {
        if mode == .every && !(1...59).contains(every) { return nil }
        return Cron(cron)
    }

    var contentOK: Bool {
        useTemplate ? !(draft.task ?? "").isEmpty : !(draft.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var valid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.terminal.handle.isEmpty && parsed != nil && contentOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "새 예약" : "예약 편집").font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                FormRow(title: "이름") {
                    TextField("예: 매일 아침 오류 요약", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                FormRow(title: "터미널") {
                    TerminalPicker(model: model, handle: $draft.terminal.handle, fallbackLabel: draft.terminal.label)
                }
                FormRow(title: "내용") {
                    Picker("", selection: $useTemplate) {
                        Text("템플릿").tag(true)
                        Text("직접 입력").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if useTemplate {
                        TemplatePicker(model: model, key: $draft.task) { go(.templates) }
                    } else {
                        PromptEditor(text: Binding(get: { draft.prompt ?? "" }, set: { draft.prompt = $0 }))
                    }
                }
                FormRow(title: "시각") {
                    timeRow
                    if let p = parsed {
                        Text("\(p.summary) · 다음 \(TimeText.short(p.next(after: Date())))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(mode == .every ? "1~59 사이 분을 넣으세요" : "시각 형식이 맞지 않습니다: \(cron)")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                FormRow(title: "늦으면") {
                    Picker("", selection: Binding(get: { draft.lateLimit ?? 0 }, set: { draft.lateLimit = $0 == 0 ? nil : $0 })) {
                        Text("늦어도 보냄").tag(0.0)
                        Text("30분 넘게 늦으면 건너뜀").tag(1800.0)
                        Text("1시간 넘게 늦으면 건너뜀").tag(3600.0)
                        Text("3시간 넘게 늦으면 건너뜀").tag(10800.0)
                        Text("6시간 넘게 늦으면 건너뜀").tag(21600.0)
                    }
                    .labelsHidden().fixedSize()
                    Text("맥이 잠들었거나 앱이 꺼져 있던 동안 지나간 시각을 깨어난 뒤 보낼지 정합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FormFooter(primary: "저장", enabled: valid, cancel: { go(.list) }, submit: save)
        }
        .padding(Pad.form)
        .onChange(of: draft.terminal.handle) { _, new in
            if let t = model.terminals.first(where: { $0.handle == new }) { draft.terminal = t.ref }
        }
        .onChange(of: draft.task) { _, new in
            // 이름이 비었거나 템플릿 제목을 그대로 쓰던 중이면 새 템플릿 제목으로 바꾼다.
            if draft.name.isEmpty || model.tasks.contains(where: { $0.title == draft.name }), let t = model.taskTitle(new) {
                draft.name = t
            }
        }
    }

    var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(TimeMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// 시각은 한 줄: [방식 ▾] [그 방식의 입력]
    @ViewBuilder
    var timeRow: some View {
        switch mode {
        case .daily, .weekdays:
            HStack(spacing: 8) { modePicker; timeField }
        case .weekly:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { modePicker; dayButtons; timeField }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { modePicker; timeField }
                    dayButtons
                }
            }
        case .multi:
            HStack(spacing: 6) {
                modePicker
                TextField("12,19", text: $hoursText).textFieldStyle(.roundedBorder).frame(width: 96)
                Text("시").foregroundStyle(.secondary)
                TextField("0", value: $minuteOfHour, format: .number).textFieldStyle(.roundedBorder).frame(width: 44)
                Text("분").foregroundStyle(.secondary)
            }
        case .every:
            HStack(spacing: 6) {
                modePicker
                TextField("30", value: $every, format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
                Text("분마다").foregroundStyle(.secondary)
            }
        case .cron:
            HStack(spacing: 8) {
                modePicker
                TextField("분 시 일 월 요일", text: $cronText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
        }
    }

    var timeField: some View {
        DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .environment(\.locale, Locale(identifier: "en_GB"))  // 24시간 표기
            .fixedSize()
    }

    var dayButtons: some View {
        HStack(spacing: 3) {
            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(["일", "월", "화", "수", "목", "금", "토"][d])
                        .font(.caption.weight(on ? .semibold : .regular))
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.primary.opacity(0.06)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func save() {
        guard valid else { return }
        var s = draft
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        s.cron = parsed?.expression ?? cron
        if useTemplate { s.prompt = nil } else { s.task = nil }
        model.save(s)
        go(.list)
    }
}

// MARK: 보내기

struct SendView: View {
    @ObservedObject var model: AppModel
    @State private var handle: String
    @State private var task: String?
    @State private var useTemplate: Bool
    @State private var text = ""
    @State private var track: Bool
    let done: () -> Void

    init(model: AppModel, handle: String, task: String?, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        _handle = State(initialValue: handle)
        _task = State(initialValue: task)
        _useTemplate = State(initialValue: task != nil)
        _track = State(initialValue: task != nil)
    }

    var valid: Bool {
        !handle.isEmpty && (useTemplate ? task != nil : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("터미널에 보내기").font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                FormRow(title: "터미널") {
                    TerminalPicker(model: model, handle: $handle)
                }
                FormRow(title: "내용") {
                    Picker("", selection: $useTemplate) {
                        Text("직접 입력").tag(false)
                        Text("템플릿").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if useTemplate {
                        TemplatePicker(model: model, key: $task, manage: nil)
                    } else {
                        PromptEditor(text: $text, height: 110)
                    }
                }
                FormRow(title: "결과") {
                    Toggle("끝나면 결과를 메뉴바에 남기게 하기", isOn: $track).toggleStyle(.checkbox)
                    Text(track
                         ? "보내는 글 끝에 결과 명령이 붙고, 그 터미널의 Claude 가 마치면 결과가 목록에 남습니다."
                         : "쓴 글을 그대로 보냅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("터미널이 입력을 기다리고 60초 조용할 때 들어갑니다. 바쁘면 최대 60분 기다립니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FormFooter(primary: "보내기", enabled: valid, cancel: done) {
                guard valid else { return }
                model.quickSend(to: handle, text: useTemplate ? "" : text, task: useTemplate ? task : nil, track: track)
                done()
            }
        }
        .padding(Pad.form)
    }
}

// MARK: 템플릿

struct TemplatesView: View {
    @ObservedObject var model: AppModel
    let windowed: Bool
    let go: (Screen) -> Void
    @State private var query = ""

    /// 팝업에서는 처음에 줄 4개쯤 높이로 두고 안을 스크롤한다.
    static let popupListHeight: CGFloat = 280

    var filtered: [TaskFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.tasks }
        return model.tasks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q)
                || $0.key.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { go(.list) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.icon).help("목록으로 (esc)")
                    .keyboardShortcut(.cancelAction)
                Text("템플릿").font(.system(size: 14, weight: .semibold))
                Text("\(model.tasks.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { go(.template(key: nil)) } label: { Label("새 템플릿", systemImage: "plus") }
                    .buttonStyle(.icon)
            }
            .padding(.horizontal, Pad.h).padding(.top, 12).padding(.bottom, 6)
            Text("터미널에 보낼 작업 내용입니다. 할당으로 터미널·시각을 정해 예약을 만들거나, 바로 한 번 보냅니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Pad.h).padding(.bottom, 10)

            if !model.tasks.isEmpty {
                SearchField(text: $query, prompt: "제목·설명·파일 이름 검색")
                    .padding(.horizontal, Pad.h).padding(.bottom, 10)
            }
            Divider()

            if model.tasks.isEmpty {
                Text("템플릿이 없습니다. 「새 템플릿」으로 만드세요.")
                    .font(.callout).foregroundStyle(.secondary).padding(Pad.h)
                if windowed { Spacer() }
            } else if filtered.isEmpty {
                Text("「\(query)」에 맞는 템플릿이 없습니다.")
                    .font(.callout).foregroundStyle(.secondary).padding(Pad.h)
                if windowed { Spacer() }
            } else {
                let list = ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { t in
                            TemplateRow(model: model, template: t, go: go)
                            Divider().padding(.leading, Pad.h)
                        }
                    }
                }
                if windowed {
                    list.frame(maxHeight: .infinity)
                } else {
                    list.frame(maxHeight: Self.popupListHeight).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.icon).help("검색 지우기")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

struct TemplateRow: View {
    @ObservedObject var model: AppModel
    let template: TaskFile
    let go: (Screen) -> Void
    @State private var confirmDelete = false
    @State private var hover = false

    var body: some View {
        let used = model.usage(of: template.key)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(template.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !template.detail.isEmpty {
                    Text(template.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(used > 0 ? "예약 \(used)개가 사용 중 · \(template.key).md" : "\(template.key).md")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                iconButton("calendar.badge.plus", help: "할당 — 터미널과 시각을 정해 예약 만들기") {
                    go(.edit(model.draft(fromTemplate: template.key), isNew: true))
                }
                iconButton("paperplane", help: "터미널에 지금 한 번 보내기") {
                    go(.send(handle: model.terminals.first?.handle ?? "", task: template.key))
                }
                iconButton("pencil", help: "편집") { go(.template(key: template.key)) }
                Button {
                    if confirmDelete { model.deleteTemplate(template.key) } else {
                        confirmDelete = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDelete = false }
                    }
                } label: {
                    Group {
                        if confirmDelete {
                            Text("삭제?").font(.caption.weight(.semibold)).foregroundStyle(.red)
                        } else {
                            Image(systemName: "trash")
                        }
                    }
                    .frame(minWidth: 16, minHeight: 16)
                }
                .disabled(used > 0)
                .help(used > 0 ? "예약 \(used)개가 쓰는 중이라 지울 수 없습니다" : "삭제 — 한 번 더 누르면 지웁니다")
            }
            .buttonStyle(.icon)
        }
        .font(.system(size: 11))
        .padding(.leading, Pad.h).padding(.trailing, Pad.h - 4).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.05 : 0)).padding(.horizontal, 6))
        .onHover { hover = $0 }
    }

    func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 16, height: 16)
        }
        .help(help)
    }
}

struct TemplateEditView: View {
    @ObservedObject var model: AppModel
    let key: String?
    let done: () -> Void
    @State private var title: String
    @State private var detail: String
    @State private var bodyText: String

    init(model: AppModel, key: String?, done: @escaping () -> Void) {
        self.model = model
        self.key = key
        self.done = done
        let t = key.flatMap { model.template($0) }
        _title = State(initialValue: t?.title ?? "")
        _detail = State(initialValue: t?.detail ?? "")
        _bodyText = State(initialValue: t?.body ?? "")
    }

    var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(key == nil ? "새 템플릿" : "템플릿 편집").font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                FormRow(title: "제목") {
                    TextField("예: 지난 24시간 오류 요약", text: $title).textFieldStyle(.roundedBorder)
                }
                FormRow(title: "설명") {
                    TextField("한 줄 설명(목록에 보임)", text: $detail).textFieldStyle(.roundedBorder)
                }
                FormRow(title: "내용") {
                    PromptEditor(text: $bodyText, height: 220)
                    Text("받는 터미널의 Claude 가 이 내용을 읽고 그대로 실행합니다. 경로·대상을 빠짐없이 적으세요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let key {
                        Text("파일: ~/.orca-cron/tasks/\(key).md").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            FormFooter(primary: "저장", enabled: valid, cancel: done) {
                guard valid else { return }
                model.saveTemplate(key: key, TemplateText(title: title.trimmingCharacters(in: .whitespaces),
                                                          detail: detail.trimmingCharacters(in: .whitespaces),
                                                          body: bodyText))
                done()
            }
        }
        .padding(Pad.form)
    }
}
