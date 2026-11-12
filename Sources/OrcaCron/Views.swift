import SwiftUI
import SchedulerCore

/// 화면 여백.
enum Pad {
    static let h: CGFloat = 16
    static let form: CGFloat = 16
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: AppOpener.notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppOpener.reveal() }
        }
        // 사람이 실행한 것이면 메뉴 막대 아이콘이 자리 잡은 뒤 패널을 연다.
        if AppOpener.launchedByUser {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { AppOpener.reveal() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppOpener.reveal() }
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

        // 크기를 바꿔 쓰는 창. 메뉴의 「창으로 열기」로 열고, 아이콘이 노치에 가려졌을 때 앱을 실행해도 열린다.
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

    /// 메뉴 막대 아이콘 — 템플릿 이미지라 밝은 막대에선 검게, 어두운 막대에선 희게 그려진다.
    /// 얇은 `clock` 은 배경에 따라 흐려 보여 채운 모양 · 15pt · semibold 로 둔다.
    static func icon(attention: Bool) -> NSImage {
        let name = attention ? "clock.badge.exclamationmark.fill" : "clock.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "OrcaCron")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    var body: some View {
        Image(nsImage: MenuBarLabel.icon(attention: model.needsAttention))
            .onAppear {
                AppOpener.openWindow = {
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

typealias Screen = Route

/// 화면 이동은 스택이다 — 앞으로 가면 쌓고, 뒤로·취소는 들어온 화면으로 돌아간다.
/// 저장·보내기처럼 일을 끝낸 동작은 결과가 보이는 목록으로 간다.
struct MenuView: View {
    @ObservedObject var model: AppModel
    let windowed: Bool
    @State private var nav: RouteStack
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, windowed: Bool, screen: Screen = .list) {
        self.model = model
        self.windowed = windowed
        _nav = State(initialValue: RouteStack(screen))
    }

    var screen: Screen { nav.top }
    func go(_ s: Screen) { nav.go(s) }
    func back() { nav.back() }
    func openTemplate(_ key: String?, leaving current: Screen) { nav.openTemplate(key, leaving: current) }
    func finishTemplate(key: String?, saved: String?) {
        nav.finishTemplate(key: key, saved: saved, title: saved.flatMap { model.taskTitle($0) })
    }

    var body: some View {
        content
            .completionEscape()
            .frame(width: windowed ? nil : 400)
            .frame(maxWidth: windowed ? .infinity : nil, maxHeight: windowed ? .infinity : nil, alignment: .top)
    }

    @ViewBuilder
    var content: some View {
        switch screen {
        case .list:
            ListView(model: model, windowed: windowed, go: go, openWindow: {
                openWindow(id: "main")
                NSApp.activate()
            })
        case .edit(let s, let isNew):
            EditView(model: model, draft: s, isNew: isNew, go: go, back: back,
                     openTemplate: { key, current in openTemplate(key, leaving: .edit(current, isNew: isNew)) })
                .id("edit-\(s.id)-\(isNew)-\(s.task ?? "")")
        case .send(let handle, let task):
            SendView(model: model, handle: handle, task: task, cancel: back, done: { go(.list) },
                     openTemplate: { key, h, t in openTemplate(key, leaving: .send(handle: h, task: t)) })
                .id("send-\(handle)-\(task ?? "")")
        case .templates:
            TemplatesView(model: model, windowed: windowed, go: go, back: back)
        case .template(let key):
            TemplateEditView(model: model, key: key) { saved in finishTemplate(key: key, saved: saved) }
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
    @AppStorage(AppModel.quietKey) private var quietSeconds = 60.0
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
                Text(message).font(.caption).foregroundStyle(Color.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Pad.h).padding(.bottom, 8)
            }

            if let p = model.problem {
                Text(p).font(.caption).foregroundStyle(Color.bad)
                    .padding(.horizontal, Pad.h).padding(.bottom, 8)
            }
            if let w = model.screenWarning {
                Text(w).font(.caption).foregroundStyle(Color.warn)
                    .fixedSize(horizontal: false, vertical: true)
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
                        if !model.store.schedules.contains(where: { !$0.isOneShot }) { FirstRunHint() }
                        ForEach(active) { g in
                            let folded = collapsed.contains(g.key)
                            groupHeader(g, collapsed: folded, onToggle: g.schedules.isEmpty ? nil : { toggle(g) })
                            if !folded {
                                ForEach(g.schedules.filter { !TerminalGroup.isFinishedOneShot($0) }) { s in
                                    ScheduleRow(model: model, schedule: s, onEdit: { go(.edit(s, isNew: false)) },
                                                onDuplicate: { go(.edit(model.duplicateDraft(s), isNew: true)) })
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

            UndoBanner(model: model)

            Divider()

            HStack(spacing: 14) {
                Button { go(.edit(model.newDraft(), isNew: true)) } label: { Label("예약", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("새 예약 (⌘N)")
                Button { go(.send(handle: model.terminals.first?.handle ?? "", task: nil)) } label: {
                    Label("보내기", systemImage: "paperplane")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("터미널에 지금 한 번 보내기 (⇧⌘N)")
                Button { go(.templates) } label: { Label("템플릿", systemImage: "doc.text") }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("템플릿 만들기·고치기·터미널에 할당 (⌘T)")
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("지금 다시 확인 (⌘R)")
                Menu {
                    if !windowed { Button("창으로 열기", action: openWindow) }
                    Picker("알림", selection: $notifyLevel) {
                        ForEach(NotifyLevel.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("조용한 시간", selection: $quietSeconds) {
                        Text("1분 (기본)").tag(60.0)
                        Text("3분").tag(180.0)
                        Text("5분").tag(300.0)
                        Text("10분").tag(600.0)
                    }
                    .help("터미널 화면이 이만큼 움직이지 않아야 보냅니다. 입력 칸에 글을 써 두고 자리를 비우는 일이 잦으면 늘리세요")
                    Button("결과 명령 허용 규칙 복사") { model.copyAllowRule() }
                        .help("받는 Claude Code 의 ~/.claude/settings.json permissions.allow 에 붙여 넣으면 결과 명령을 묻지 않습니다")
                    Button("화면 진단 저장") { model.saveDiagnosis() }
                        .help("터미널마다 판정 결과와 화면 끝 15줄을 파일로 남깁니다(화면 내용이 들어가니 공유 전에 확인)")
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
                    onAdd: g.live == nil ? nil : { go(.edit(model.newDraft(terminal: g.handle), isNew: true)) },
                    onTest: g.live == nil ? nil : { model.sendTest(to: g.handle) },
                    onFocus: g.live == nil ? nil : { model.focus(g.handle) })
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
                Text("업데이트 중").font(.caption.weight(.medium)).foregroundStyle(Color.info)
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
                .foregroundStyle(model.updateMessage != nil ? Color.bad : Color.secondary)
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
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.info)
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
    var onTest: (() -> Void)?
    /// Orca 의 이 터미널로 가기. 예약 없는 터미널은 머리 줄을 누르면 바로 간다.
    var onFocus: (() -> Void)?
    @State private var hover = false

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
                    .fill(group.live == nil ? Color.bad : (empty ? Color.secondary.opacity(0.5) : Color.ok))
                    .frame(width: 7, height: 7)
                if let t = group.live {
                    Text(t.place.isEmpty ? "터미널" : t.place).font(.caption.weight(.semibold))
                        .foregroundStyle(empty ? .secondary : .primary)
                    Text(t.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(group.label).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("터미널 없음 — 편집에서 다시 고르세요").font(.caption).foregroundStyle(Color.bad).lineLimit(1)
                }
                Spacer(minLength: 4)
                if collapsed { summary }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let onToggle { onToggle() } else { onFocus?() } }
            .help(onToggle != nil ? (collapsed ? "펼치기" : "접기") : onFocus != nil ? "누르면 Orca 의 이 터미널로 갑니다" : "")
            .contextMenu {
                if let onFocus {
                    Button("Orca 에서 이 터미널 보기", action: onFocus)
                }
                if let onTest {
                    Button("연결 시험 보내기", action: onTest)
                }
            }
            if let onSend {
                Button(action: onSend) { Image(systemName: "paperplane") }.help("이 터미널에 지금 보내기")
            }
            if let onAdd {
                Button(action: onAdd) { Image(systemName: "calendar.badge.plus") }.help("이 터미널에 예약 만들기")
            }
        }
        .buttonStyle(.icon)
        .font(.caption)
        .padding(.leading, Pad.h - 8).padding(.trailing, Pad.h - 4).padding(.vertical, empty ? 3 : 2)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(hover && (onToggle != nil || onFocus != nil) ? 0.05 : 0))
            .padding(.horizontal, 6))
        .onHover { hover = $0 }
        .padding(.top, empty ? 0 : 6)
    }

    /// 접혀 있을 때 오른쪽 요약 — 예약 수 · 다음 시각 · 대기/실패 수.
    var summary: some View {
        let recurring = group.schedules.filter { !$0.isOneShot }
        let next = recurring.filter(\.enabled).compactMap(\.nextRunAt).min()
        let waiting = group.schedules.filter { $0.pendingSince != nil }.count
        let failed = recurring.filter { $0.enabled && ["실패", "결과 없음"].contains($0.lastStatus ?? "") }.count
        return HStack(spacing: 4) {
            if failed > 0 { Text("실패 \(failed)").foregroundStyle(Color.bad) }
            if waiting > 0 { Text("대기 \(waiting)").foregroundStyle(Color.warn) }
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
                HStack(spacing: 8) {
                    // 예약 줄의 스위치 칸(폭 24)에 펼침 표시를 두고, 글자는 예약 이름과 같은 자리에서 시작한다.
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Image(systemName: "paperplane").font(.system(size: 9))
                    }
                    .frame(width: 24)
                    Text("보낸 기록 \(items.count)" + (last.map { " · 마지막 \(TimeText.short($0))" } ?? ""))
                }
                .font(.caption2)
            }
            .buttonStyle(.icon)
            .padding(.leading, Pad.h - 4).padding(.top, 1)
            if open {
                ForEach(items) { s in
                    HStack(spacing: 6) {
                        Text(s.name).font(.caption).lineLimit(1)
                        Text("\(s.lastStatus ?? "보냄") \(TimeText.short(s.history.first?.at ?? s.lastRunAt ?? s.sentAt))")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 4)
                        Button { model.delete(s.id, undoable: false) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.icon).help("기록 지우기 (24시간 뒤 자동으로 지워집니다)")
                    }
                    .padding(.leading, Pad.h + 32).padding(.trailing, Pad.h - 4)
                }
            }
        }
    }
}

struct ScheduleRow: View {
    @ObservedObject var model: AppModel
    let schedule: Schedule
    let onEdit: () -> Void
    let onDuplicate: () -> Void
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
            // 한 줄에 한 가지 — 언제(🕐) · 무엇을(📄, 이름과 같으면 생략) · 마지막 결과. 앞 아이콘 칸 폭을 맞춰 세로로 읽힌다.
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(s.enabled ? .primary : .secondary)
                    .padding(.bottom, 1)
                whenLine(s)
                if let what = whatText(s) {
                    InfoLine(icon: s.task != nil ? "doc.text" : s.isCommand ? "chevron.left.forwardslash.chevron.right" : "text.alignleft") {
                        Text(what).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                statusLine(s)
                if showHistory {
                    HistoryPanel(model: model, schedule: s)
                        .padding(.top, 3).padding(.leading, 2)
                        .contentShape(Rectangle()).onTapGesture {}  // 기록을 누르면 편집으로 가지 않게
                }
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
                Button { model.delete(s.id) } label: { Image(systemName: "trash") }
                    .help(s.isOneShot && s.pendingSince != nil ? "보내기 취소 — 아래 「되돌리기」로 되살립니다" : "삭제 — 아래 「되돌리기」로 되살립니다")
            }
            .buttonStyle(.icon)
        }
        .contextMenu { menu(s) }
        .font(.system(size: 11))
        .padding(.leading, Pad.h).padding(.trailing, Pad.h - 4).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.05 : 0)).padding(.horizontal, 6))
        .onHover { hover = $0 }
    }

    /// 우클릭 메뉴 — 줄의 버튼과 같은 동작 + 켜기·끄기 · 복제 · 터미널로 가기.
    @ViewBuilder
    func menu(_ s: Schedule) -> some View {
        if !s.isOneShot {
            Button("편집", action: onEdit)
            Button("지금 실행") { model.runNow(s.id) }
                .disabled(!s.enabled || s.pendingSince != nil || s.runId != nil)
            Button(s.enabled ? "끄기" : "켜기") { model.setEnabled(s.id, !s.enabled) }
            Button("복제", action: onDuplicate)
            Divider()
        }
        Button("Orca 에서 이 터미널 보기") { model.focus(s.terminal.handle) }
            .disabled(!model.terminals.contains { $0.handle == s.terminal.handle })
        Divider()
        Button(s.isOneShot && s.pendingSince != nil ? "보내기 취소" : "삭제", role: .destructive) { model.delete(s.id) }
    }

    /// 언제 — 다음 실행 시각을 앞에 진하게, 반복 규칙은 뒤에(넘치면 규칙 쪽이 잘린다).
    func whenLine(_ s: Schedule) -> some View {
        let rule = Cron(s.cron)?.summary ?? "잘못된 cron: \(s.cron)"
        let next = s.nextRunAt ?? Cron(s.cron)?.next(after: Date())
        return InfoLine(icon: s.isOneShot ? "paperplane" : "clock") {
            if s.isOneShot {
                Text("1회 보내기 · " + (s.tracksResult ? "결과 받음" : "결과 안 받음")).foregroundStyle(.secondary)
            } else if s.enabled, next == nil, Cron(s.cron) != nil {
                Text("끝남").foregroundStyle(Color.warn).fixedSize()
                Text("· \(rule) · 고른 날이 모두 지남").foregroundStyle(.secondary).lineLimit(1)
            } else if s.enabled {
                Text("다음 \(TimeText.short(next))").foregroundStyle(.primary).monospacedDigit().fixedSize()
                Text("· \(rule)").foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("꺼짐 · \(rule)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(s.isOneShot ? "" : "\(rule) · 다음 \(TimeText.short(next))")
    }

    /// 무엇을 — 템플릿 제목이 예약 이름과 같으면 줄을 생략한다.
    func whatText(_ s: Schedule) -> String? {
        if let title = s.task.flatMap({ model.taskTitle($0) }) {
            return title == s.name ? nil : "템플릿 「\(title)」"
        }
        let firstLine = (s.prompt ?? "").split(separator: "\n").first.map(String.init) ?? ""
        return s.isCommand ? "명령 \(firstLine)" : "직접 입력 · \(firstLine)"
    }

    @ViewBuilder
    func statusLine(_ s: Schedule) -> some View {
        if s.pendingSince != nil {
            InfoLine(icon: "hourglass", tint: .warn) {
                Text("대기 중 · \(s.waitNote ?? "다음 확인(30초 안)에 보냅니다")").foregroundStyle(Color.warn).lineLimit(2)
            }
        } else if s.runId != nil {
            if let b = s.blocked {
                InfoLine(icon: "exclamationmark.triangle.fill", tint: .warn) {
                    Text(b).foregroundStyle(Color.warn).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                InfoLine(icon: "ellipsis.circle", tint: .info) {
                    Text("\(s.lastStatus ?? "보냄") \(TimeText.short(s.sentAt)) · 결과 기록을 기다리는 중")
                        .foregroundStyle(Color.info).lineLimit(1)
                }
            }
        } else if let status = s.lastStatus {
            InfoLine(icon: icon(status), tint: color(status)) {
                Text("\(status) \(TimeText.short(s.history.first?.at ?? s.lastRunAt))")
                    .foregroundStyle(color(status)).fixedSize()
                if let sum = s.lastSummary, !sum.isEmpty {
                    Text("· \(sum)").foregroundStyle(.secondary).lineLimit(1).help(sum)
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
                            Text("기록")
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                                .rotationEffect(.degrees(showHistory ? 90 : 0))
                        }
                    }
                    .buttonStyle(.icon)
                    .help("날짜별 실행 기록(최근 \(RunArchive.keepDays)일)")
                }
            }
        } else {
            InfoLine(icon: "circle.dashed") {
                Text("아직 실행 기록 없음").foregroundStyle(.secondary)
            }
        }
    }

    func icon(_ status: String) -> String {
        switch status {
        case "성공": return "checkmark.circle.fill"
        case "실패", "결과 없음": return "xmark.circle.fill"
        case "건너뜀": return "forward.circle"
        default: return "paperplane.circle"
        }
    }

    func color(_ status: String) -> Color { statusColor(status) }
}

/// 실행 결과 글자 색 — 성공 초록 · 실패·결과 없음 빨강 · 나머지 흐림.
func statusColor(_ status: String) -> Color {
    switch status {
    case "성공": return .ok
    case "실패", "결과 없음": return .bad
    default: return .secondary
    }
}

/// 예약 하나의 실행 기록 — 날짜를 골라 그날 기록을 10개씩 본다(최근 30일).
struct HistoryPanel: View {
    @ObservedObject var model: AppModel
    let schedule: Schedule
    @State private var records: [RunRecord] = []
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var page = 0
    @State private var loaded = false

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let days = RunArchive.days(records)
        let shown = RunArchive.page(records, day: day, page: page)
        let pages = max(1, (shown.total + RunArchive.perPage - 1) / RunArchive.perPage)
        let earlier = days.first { $0 < day }
        let later = days.last { $0 > day }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Button { go(earlier) } label: { chevron("left") }
                    .disabled(earlier == nil).help("기록이 있는 앞 날")
                DatePicker("", selection: Binding(get: { day }, set: { go(Calendar.current.startOfDay(for: $0)) }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.compact).controlSize(.small).fixedSize()
                    .environment(\.locale, Locale(identifier: "ko_KR"))
                    .help("날짜를 골라 그날 기록 보기")
                Button { go(later) } label: { chevron("right") }
                    .disabled(later == nil).help("기록이 있는 뒷 날")
                Text(shown.total == 0 ? "기록 없음" : "\(shown.total)건").foregroundStyle(.secondary).padding(.leading, 3)
                Spacer(minLength: 4)
                if pages > 1 {
                    Button { page -= 1 } label: { chevron("left") }.disabled(page == 0).help("앞 쪽")
                    Text("\(page + 1)/\(pages)").monospacedDigit().foregroundStyle(.secondary)
                    Button { page += 1 } label: { chevron("right") }.disabled(page + 1 >= pages).help("뒤 쪽")
                }
            }
            .buttonStyle(.icon)
            ForEach(Array(shown.items.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 5) {
                    Text(HistoryPanel.clock.string(from: r.at)).foregroundStyle(.secondary).monospacedDigit()
                    Text(r.status).foregroundStyle(statusColor(r.status))
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
        .onAppear(perform: reload)
        .onChange(of: schedule.history.first?.at) { _, _ in reload() }
    }

    func chevron(_ side: String) -> some View {
        Image(systemName: "chevron.\(side)").font(.system(size: 8, weight: .bold)).frame(width: 12)
    }

    func go(_ d: Date?) {
        guard let d else { return }
        day = d
        page = 0
    }

    /// 처음 열 때는 기록이 있는 가장 최근 날로 간다. 새 기록이 오면 보던 날 그대로 다시 읽는다.
    func reload() {
        records = model.history(schedule)
        if !loaded, let newest = RunArchive.days(records).first { day = newest }
        loaded = true
    }
}

// MARK: 공통 조각

/// 예약 줄의 정보 한 줄 — 앞에 폭이 같은 작은 아이콘 칸을 두어 줄끼리 세로로 맞춘다.
struct InfoLine<Content: View>: View {
    let icon: String
    var tint: Color = .secondary
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium)).foregroundStyle(tint)
                .frame(width: 12)
            HStack(alignment: .firstTextBaseline, spacing: 4) { content }
        }
        .font(.caption)
    }
}

/// 날짜 지정 달력 — 날을 눌러 켜고 끈다. 여러 달에 걸쳐 고를 수 있고, 지난 날은 고를 수 없다(12달 앞까지).
struct DateGrid: View {
    @Binding var selection: Set<TimeSpec.DayDate>
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    static let title: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy년 M월"
        return f
    }()

    var body: some View {
        let cal = Calendar.current
        let thisMonth = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let today = TimeSpec.DayDate(Date())
        let count = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = cal.component(.weekday, from: month) - 1  // 일요일부터
        let ym = TimeSpec.DayDate(month)
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...count).map { Optional($0) }
        let canBack = month > thisMonth
        let canForward = (cal.dateComponents([.month], from: thisMonth, to: month).month ?? 0) < 12
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                    .disabled(!canBack).help("앞 달")
                Text(DateGrid.title.string(from: month)).font(.caption.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 72)
                Button { shift(1) } label: { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    .disabled(!canForward).help("다음 달")
                Spacer(minLength: 6)
                if !selection.isEmpty {
                    Text("\(selection.count)일 고름").font(.caption).foregroundStyle(.secondary)
                    Button("지우기") { selection.removeAll() }.font(.caption).help("고른 날 모두 빼기")
                }
            }
            .buttonStyle(.icon)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        Text(["일", "월", "화", "수", "목", "금", "토"][i]).font(.caption2)
                            .foregroundStyle(i == 0 ? Color.bad : .secondary).frame(width: 26)
                    }
                }
                ForEach(0..<(cells.count + 6) / 7, id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let i = row * 7 + col
                            if i < cells.count, let d = cells[i] {
                                dayCell(TimeSpec.DayDate(year: ym.year, month: ym.month, day: d), today: today, sunday: col == 0)
                            } else {
                                Color.clear.frame(width: 26, height: 22)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // 이미 고른 날이 있으면 그중 처음 오는 앞날의 달을 연다.
            if let first = selection.filter({ $0 >= today }).min(), let d = first.date() {
                month = cal.dateInterval(of: .month, for: d)?.start ?? month
            }
        }
    }

    func dayCell(_ d: TimeSpec.DayDate, today: TimeSpec.DayDate, sunday: Bool) -> some View {
        let on = selection.contains(d)
        let past = d < today
        return Button {
            if on { selection.remove(d) } else { selection.insert(d) }
        } label: {
            Text("\(d.day)")
                .font(.caption.weight(on ? .semibold : .regular)).monospacedDigit()
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: d == today && !on ? 1 : 0))
                .foregroundStyle(on ? Color.white : past ? Color.secondary.opacity(0.5) : sunday ? Color.bad : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(past && !on)
    }

    func shift(_ n: Int) {
        month = Calendar.current.date(byAdding: .month, value: n, to: month) ?? month
    }
}

/// 시각 칸 — `0730` · `7:30` · `7시 30분` 처럼 바로 친다. 맞는 시각이면 치는 동안 바로 반영하고,
/// 칸을 떠나거나 return 을 누르면 `07:30` 으로 맞춘다. 틀린 글은 빨간 테두리로 두었다가 칸을 떠날 때 원래 시각으로 되돌린다.
struct ClockField: View {
    @Binding var date: Date
    @State private var text = ""
    @FocusState private var focused: Bool

    var minute: Int { EditView.minute(date) }
    var valid: Bool { TimeSpec.minute(fromText: text) != nil }

    var body: some View {
        TextField("09:00", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 58)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.bad, lineWidth: valid || text.isEmpty ? 0 : 1.5))
            .help("시각을 바로 칩니다 — 0730 · 7:30 · 7시 30분")
            .onAppear { text = TimeSpec.clockText(minute) }
            .onChange(of: text) { _, new in
                if let m = TimeSpec.minute(fromText: new), m != minute { date = EditView.clock(m) }
            }
            .onChange(of: date) { _, _ in
                // 다른 곳에서 바뀌면(cron 에서 돌아옴 등) 글도 맞춘다. 치는 중에는 건드리지 않는다.
                if !focused { text = TimeSpec.clockText(minute) }
            }
            .onChange(of: focused) { _, now in if !now { text = TimeSpec.clockText(minute) } }
            .onSubmit { text = TimeSpec.clockText(minute) }
    }
}

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

    var options: [(value: String, label: String)] {
        var out = model.terminals.map { (value: $0.handle, label: $0.displayName) }
        if !handle.isEmpty, !model.terminals.contains(where: { $0.handle == handle }) {
            out.insert((handle, "\(fallbackLabel.isEmpty ? handle : fallbackLabel) (지금 없음)"), at: 0)
        }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            Dropdown(selection: $handle, options: options, fill: true)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon).help("터미널 목록 다시 읽기")
        }
    }
}

struct TemplatePicker: View {
    @ObservedObject var model: AppModel
    @Binding var key: String?
    /// 템플릿 편집으로 간다 — 고른 템플릿 키(고치기) 또는 nil(새로 만들기).
    let open: (String?) -> Void

    var body: some View {
        // 골랐으면 ✎(그 템플릿 고치기), 비었으면 +(새로 만들기). 새로 만들기는 목록 맨 아래에도 있다.
        HStack(spacing: 2) {
            Dropdown(selection: Binding(get: { key ?? "" }, set: { key = $0.isEmpty ? nil : $0 }),
                     options: model.tasks.map { (value: $0.key, label: $0.title) }, fill: true,
                     extra: ("새 템플릿 만들기…", { open(nil) }))
            if let key {
                Button { open(key) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.icon)
                    .help("이 템플릿 고치기 — 마치면 이 화면으로 돌아옵니다")
            } else {
                Button { open(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.icon)
                    .help("새 템플릿 만들기 — 저장하면 골라 둔 채 이 화면으로 돌아옵니다")
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
    /// 비어 있지 않으면 `/` 자동완성을 켠다.
    var commands: [ClaudeCommand] = []
    @State private var browsing = false
    @State private var selected = 0
    /// 디바운스한 후보와 그 후보를 찾은 조각. 타자 중에는 잠깐 앞 조각의 후보가 보일 수 있다.
    @State private var shown: [ClaudeCommand] = []
    @State private var shownFor: String?
    /// esc 로 닫은 조각. 글자를 더 치거나 지워 조각이 바뀌면 다시 뜬다.
    @State private var dismissedFor: String?

    var token: String? { commands.isEmpty ? nil : CommandCatalog.trailingToken(text) }

    var body: some View {
        let list = token == nil || token == dismissedFor ? [] : shown
        let current = list.isEmpty ? 0 : min(selected, list.count - 1)
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: height, maxHeight: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                // 후보가 떠 있을 때만 ↑↓ 로 고르고 tab·return 으로 넣는다. 후보가 없으면 평소대로 커서 이동·줄바꿈.
                // esc 는 후보만 닫는다(폼 취소로 넘어가지 않음). 후보가 없으면 평소대로 폼 취소.
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape]) { press in
                    guard let token, token != dismissedFor,
                          press.modifiers.isDisjoint(with: [.shift, .command, .option, .control]) else {
                        return .ignored
                    }
                    if shownFor != token { show(CommandCatalog.suggestions(token, in: commands), for: token) } // 디바운스를 기다리지 않고 지금 조각으로
                    guard !shown.isEmpty else { return .ignored }
                    let current = min(selected, shown.count - 1)
                    switch press.key {
                    case .downArrow: selected = CommandCatalog.step(current, by: 1, count: shown.count)
                    case .upArrow: selected = CommandCatalog.step(current, by: -1, count: shown.count)
                    case .escape: dismissedFor = token
                    default: text = CommandCatalog.complete(text, with: shown[current].name)
                    }
                    return .handled
                }
                // 첫 `/` 는 바로, 이어지는 타자는 멈춘 뒤 한 번만 찾는다. 명령 목록이 새로 읽히면 다시 찾는다.
                .task(id: "\(token ?? "\u{0}")#\(commands.count)") {
                    guard let token else { dismissedFor = nil; return show([], for: nil) }
                    if shownFor != nil {
                        try? await Task.sleep(for: SearchTiming.debounce)
                        if Task.isCancelled { return }
                    }
                    show(CommandCatalog.suggestions(token, in: commands), for: token)
                }
            if !list.isEmpty {
                CommandList(items: list, selected: current, visibleRows: 6, hover: { selected = $0 }) {
                    text = CommandCatalog.complete(text, with: $0.name)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Text("↑↓ 고르기 · tab·return 넣기 · esc 닫기 · 후보 \(list.count)개").font(.caption2).foregroundStyle(.secondary)
            } else if let token, !token.isEmpty, token != dismissedFor, shownFor == token,
                      !commands.contains(where: { $0.name == token }) {
                Text("「/\(token)」에 맞는 명령이 없습니다").font(.caption2).foregroundStyle(.secondary)
            } else if !commands.isEmpty {
                Button { browsing = true } label: {
                    Label("/ 명령 넣기", systemImage: "command").font(.caption)
                }
                .buttonStyle(.icon)
                .help("이 터미널에서 쓸 수 있는 Claude 명령·스킬 \(commands.count)개. 입력 칸에서 / 를 쳐도 뜹니다")
                .popover(isPresented: $browsing, arrowEdge: .bottom) {
                    CommandBrowser(commands: commands) { c in
                        text = CommandCatalog.complete(text.hasSuffix(" ") || text.hasSuffix("\n") || text.isEmpty ? text : text + " ", with: c.name)
                        browsing = false
                    }
                }
            }
        }
        .preference(key: CompletionOpenKey.self, value: !list.isEmpty)
    }

    private func show(_ list: [ClaudeCommand], for token: String?) {
        if shownFor != token { selected = 0 }
        shown = list
        shownFor = token
    }
}

/// `/` 자동완성 후보가 떠 있는지. 떠 있으면 esc 를 폼 취소가 아니라 후보 닫기에 쓴다 —
/// 폼 「취소」의 esc 단축키가 입력 칸보다 먼저 키를 받기 때문에, 후보가 떠 있는 동안은 단축키를 내려 둔다.
struct CompletionOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct CompletionOpenEnv: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var completionOpen: Bool {
        get { self[CompletionOpenEnv.self] }
        set { self[CompletionOpenEnv.self] = newValue }
    }
}

struct CompletionEscape: ViewModifier {
    @State private var open = false
    func body(content: Content) -> some View {
        content
            .environment(\.completionOpen, open)
            .onPreferenceChange(CompletionOpenKey.self) { open = $0 }
    }
}

extension View {
    /// 안쪽 PromptEditor 의 후보가 떠 있는 동안 FormFooter 의 esc(취소)를 내려 둔다.
    func completionEscape() -> some View { modifier(CompletionEscape()) }
}

/// 검색 칸·자동완성 디바운스 — 타자가 이만큼 멈추면 찾는다.
enum SearchTiming {
    static let debounce: Duration = .milliseconds(80)
}

/// 명령 후보 줄 — 이름 · 설명 · 출처. 고른 줄은 칠하고, 줄이 많으면 `visibleRows` 높이에서 스크롤한다.
struct CommandList: View {
    static let rowHeight: CGFloat = 22
    let items: [ClaudeCommand]
    var selected: Int? = nil
    let visibleRows: Int
    /// 마우스가 올라간 줄 — 고른 줄을 그 줄로 옮겨 칠한 줄이 하나만 남게 한다.
    var hover: ((Int) -> Void)? = nil
    let pick: (ClaudeCommand) -> Void
    /// 마우스로 옮긴 줄. 이 줄로 바뀐 것은 스크롤하지 않는다(스크롤되면 마우스 밑 줄이 바뀌어 흔들린다).
    @State private var hovered: Int?
    /// 마지막으로 본 마우스 위치. 키로 스크롤해 줄이 마우스 밑으로 지나가거나 목록이 마우스 밑에 뜰 때는
    /// 마우스가 움직이지 않았으니 고른 줄을 옮기지 않는다.
    @State private var mouse = NSEvent.mouseLocation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { // 후보가 수백 개여도 보이는 줄만 그린다
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                        Button { pick(c) } label: { CommandRow(command: c) }
                            .buttonStyle(.icon)
                            .frame(height: Self.rowHeight)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(i == selected ? Color.accentColor.opacity(0.22) : .clear))
                            .onHover { inside in
                                let at = NSEvent.mouseLocation
                                guard inside, let hover, at != mouse else { return }
                                mouse = at
                                hovered = i
                                hover(i)
                            }
                            .id(c.id)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(items.count > visibleRows ? .visible : .hidden)
            .frame(height: CGFloat(min(items.count, visibleRows)) * Self.rowHeight + 4)
            .onChange(of: selected) {
                guard let selected, selected != hovered, items.indices.contains(selected) else { return }
                proxy.scrollTo(items[selected].id)
            }
        }
    }
}

struct CommandRow: View {
    let command: ClaudeCommand

    var body: some View {
        // 줄이 칸 폭을 넘지 않게 모두 줄어들 수 있다. 줄어드는 순서는 설명(최소 56) → 이름 → 출처(최대 110).
        HStack(spacing: 6) {
            Text("/" + command.name).font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                .layoutPriority(2)
            Text(command.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: command.detail.isEmpty ? 0 : 56, maxWidth: .infinity, alignment: .leading)
            if !command.modelInvocable {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .help("받는 Claude 가 스스로 부를 수 없음 — 명령만 그대로 보낼 때만 실행")
            }
            Text(command.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: 110, alignment: .trailing)
                .layoutPriority(3)
        }
        .help("/" + command.name + (command.detail.isEmpty ? "" : " — " + command.detail))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 「/ 명령 넣기」 — 검색해서 고르는 목록.
struct CommandBrowser: View {
    let commands: [ClaudeCommand]
    let pick: (ClaudeCommand) -> Void
    @State private var query = ""
    @State private var selected = 0
    @State private var found: [ClaudeCommand]?
    @State private var foundFor = ""

    func search(_ q: String) -> [ClaudeCommand] {
        q.isEmpty ? commands : CommandCatalog.match(q, in: commands, limit: commands.count)
    }

    var body: some View {
        let list = found ?? commands
        let current = list.isEmpty ? 0 : min(selected, list.count - 1)
        VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $query, prompt: "명령·스킬 \(commands.count)개에서 찾기") { press in
                if foundFor != query { found = search(query); foundFor = query; selected = 0 } // 디바운스를 기다리지 않고 지금 검색어로
                let list = found ?? commands
                guard !list.isEmpty else { return .ignored }
                let current = min(selected, list.count - 1)
                switch press.key {
                case .downArrow: selected = CommandCatalog.step(current, by: 1, count: list.count)
                case .upArrow: selected = CommandCatalog.step(current, by: -1, count: list.count)
                case .return: pick(list[current])
                default: return .ignored
                }
                return .handled
            }
            .task(id: query) {
                if !query.isEmpty {
                    try? await Task.sleep(for: SearchTiming.debounce)
                    if Task.isCancelled { return }
                }
                if foundFor != query { selected = 0 }
                found = search(query)
                foundFor = query
            }
            if list.isEmpty {
                Text("「\(query)」에 맞는 명령이 없습니다").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: CommandList.rowHeight * 2)
            } else {
                CommandList(items: list, selected: current, visibleRows: 12, hover: { selected = $0 }, pick: pick)
            }
            Text("↑↓ 고르기 · return 넣기 · esc 닫기").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 380)
    }
}

/// 직접 입력이 `/` 로 시작할 때의 안내.
struct CommandNote: View {
    var body: some View {
        Text("명령으로 시작해 글 그대로 보냅니다. 받는 Claude Code 가 명령을 실행하고, 결과 받기는 할 수 없습니다.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 폼 아래 줄 — 저장이 꺼져 있으면 왼쪽에 이유를 적고, 입력이 있는데 취소(esc)하면 한 번 더 확인한다.
struct FormFooter: View {
    let primary: String
    let enabled: Bool
    /// 저장·보내기가 꺼진 이유.
    var note: String?
    /// 입력이 바뀌었는지 — 그러면 취소를 한 번 더 눌러야 버린다.
    var dirty = false
    let cancel: () -> Void
    let submit: () -> Void
    @State private var confirmDiscard = false
    @Environment(\.completionOpen) private var completionOpen

    var body: some View {
        HStack(spacing: 8) {
            if confirmDiscard {
                Text("입력한 내용이 사라집니다").font(.caption).foregroundStyle(Color.bad)
            } else if !enabled, let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(confirmDiscard ? "버리기" : "취소") {
                if dirty && !confirmDiscard {
                    confirmDiscard = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
                } else {
                    cancel()
                }
            }
            .keyboardShortcut(completionOpen ? nil : .cancelAction)
            Button(primary, action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
                .help("\(primary) (⌘↩)")
        }
    }
}

/// 「보낼 글 보기」 — 터미널에 실제로 들어갈 글(템플릿이면 파일을 읽으라는 한 줄 + 결과 명령)을 보여 준다.
struct MessagePreview: View {
    let text: () -> String
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Label("보낼 글 보기", systemImage: "eye") }
            .buttonStyle(.icon).font(.caption)
            .help("터미널에 실제로 들어갈 글을 봅니다")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    Text(text())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(width: 360)
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
    }
}

/// 예약이 하나도 없을 때 목록 맨 위에 두는 시작 안내.
struct FirstRunHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("처음 쓰신다면").font(.caption.weight(.semibold))
            Text("터미널 줄의 \(Image(systemName: "calendar.badge.plus")) 로 예약을, \(Image(systemName: "paperplane")) 로 한 번 보내기를 만듭니다. 받는 Claude 가 결과까지 남기는지는 터미널 줄 우클릭 → 「연결 시험 보내기」로 먼저 확인해 보세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, Pad.h - 6).padding(.top, 8)
    }
}

/// 방금 지운 것을 되돌리는 줄 — 8초 뒤 사라진다.
struct UndoBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let undo = model.undo {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                Text(undo.message).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Button("되돌리기") { model.performUndo() }
                    .buttonStyle(.icon).font(.caption.weight(.semibold))
                    .keyboardShortcut("z", modifiers: .command)
                    .help("되돌리기 (⌘Z)")
                Button { model.dismissUndo() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.icon).help("닫기")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, Pad.h - 6).padding(.vertical, 6)
            .transition(.opacity)
        }
    }
}

// MARK: 예약 편집

/// 시각 칸의 첫 고르기 — 어느 요일에(또는 cron 직접).
enum DayChoice: String, CaseIterable, Identifiable {
    case everyDay = "매일"
    case weekdays = "평일"
    case weekends = "휴일(토·일)"
    case pick = "요일 고르기"
    case dates = "날짜 지정"
    case cron = "cron 직접"
    var id: String { rawValue }
}

/// 「정한 시각」의 시각 한 칸.
struct TimeSlot: Identifiable {
    let id = UUID()
    var date: Date
}

/// 저장된 cron 을 편집 칸으로 되돌린 값. 시각은 하루 중 분.
struct TimeFill {
    var dayChoice: DayChoice = .cron
    var days: Set<Int> = [1]
    var dates: Set<TimeSpec.DayDate> = []
    var repeating = false
    var times = [540]
    var every = 30
    var allDay = true
    var from = 540
    var to = 1080
}

struct EditView: View {
    @ObservedObject var model: AppModel
    @State private var draft: Schedule
    let isNew: Bool
    let go: (Screen) -> Void
    let back: () -> Void
    /// 템플릿 편집으로 갈 때 지금 입력을 넘긴다.
    let openTemplate: (String?, Schedule) -> Void

    @State private var useTemplate: Bool
    @State private var dayChoice: DayChoice
    @State private var days: Set<Int>
    /// 「날짜 지정」에서 달력으로 고른 날.
    @State private var dates: Set<TimeSpec.DayDate>
    /// false = 정한 시각, true = 반복(N분마다).
    @State private var repeating: Bool
    @State private var times: [TimeSlot]
    @State private var every: Int
    /// 반복 구간 — 종일이면 from·to 를 쓰지 않는다.
    @State private var allDay: Bool
    @State private var from: Date
    @State private var to: Date
    @State private var cronText: String
    /// 처음 연 때의 값 — 취소할 때 바뀐 것이 있는지 본다.
    @State private var initial: Schedule?

    init(model: AppModel, draft: Schedule, isNew: Bool, go: @escaping (Screen) -> Void, back: @escaping () -> Void,
         openTemplate: @escaping (String?, Schedule) -> Void) {
        self.model = model
        self.isNew = isNew
        self.go = go
        self.back = back
        self.openTemplate = openTemplate
        _draft = State(initialValue: draft)
        _useTemplate = State(initialValue: draft.prompt == nil)
        _cronText = State(initialValue: draft.cron)
        let f = EditView.fill(from: draft.cron.isEmpty ? "0 9 * * *" : draft.cron)
        _dayChoice = State(initialValue: f.dayChoice)
        _days = State(initialValue: f.days)
        _dates = State(initialValue: f.dates)
        _repeating = State(initialValue: f.repeating)
        _times = State(initialValue: f.times.map { TimeSlot(date: EditView.clock($0)) })
        _every = State(initialValue: f.every)
        _allDay = State(initialValue: f.allDay)
        _from = State(initialValue: EditView.clock(f.from))
        _to = State(initialValue: EditView.clock(f.to))
    }

    /// 하루 중 분 → 오늘 그 시각.
    static func clock(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    /// 시각 → 하루 중 분.
    static func minute(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 9) * 60 + (c.minute ?? 0)
    }

    /// 편집 화면이 만드는 모양(요일 + 정한 시각 · 구간 반복)이면 그 칸으로 연다. 아니면 「cron 직접」.
    static func fill(from cron: String) -> TimeFill {
        var out = TimeFill()
        guard let spec = TimeSpec(cron: cron) else { return out }
        switch spec.days {
        case .everyDay: out.dayChoice = .everyDay
        case .weekdays: out.dayChoice = .weekdays
        case .weekends: out.dayChoice = .weekends
        case .some(let set):
            out.dayChoice = .pick
            out.days = set
        case .dates(let ds):
            out.dayChoice = .dates
            out.dates = ds
        }
        switch spec.pattern {
        case .times(let list):
            out.times = list
        case .every(let n, let from, let to):
            out.repeating = true
            out.every = n
            out.allDay = from == 0 && to == 1439
            if !out.allDay { (out.from, out.to) = (from, to) }
        }
        return out
    }

    /// 지금 칸 그대로의 시각. 「cron 직접」이면 nil.
    func spec(for choice: DayChoice) -> TimeSpec? {
        let d: TimeSpec.Days
        switch choice {
        case .everyDay: d = .everyDay
        case .weekdays: d = .weekdays
        case .weekends: d = .weekends
        case .pick: d = .of(days)
        case .dates: d = .dates(dates)
        case .cron: return nil
        }
        if repeating {
            return TimeSpec(days: d, pattern: .every(every, from: allDay ? 0 : EditView.minute(from),
                                                     to: allDay ? 1439 : EditView.minute(to)))
        }
        return TimeSpec(days: d, pattern: .times(times.map { EditView.minute($0.date) }))
    }

    var cron: String {
        dayChoice == .cron ? cronText.trimmingCharacters(in: .whitespaces) : (spec(for: dayChoice)?.cron ?? "")
    }

    var parsed: Cron? { Cron(cron) }

    /// 시각이 맞지 않을 때 그 자리에 보일 이유.
    var timeProblem: String {
        switch dayChoice {
        case .cron: return cron.isEmpty ? "cron 식을 적어 주세요" : "시각 형식이 맞지 않습니다: \(cron)"
        case .pick where days.isEmpty: return "요일을 하나 이상 고르세요"
        case .dates where dates.isEmpty: return "달력에서 날을 하나 이상 고르세요"
        default: break
        }
        if repeating {
            if !(1...TimeSpec.maxEvery).contains(every) { return "간격은 1~\(TimeSpec.maxEvery)분 사이로 넣으세요" }
            if !allDay, EditView.minute(from) > EditView.minute(to) { return "끝 시각이 시작보다 빠릅니다" }
        }
        return "시각을 확인해 주세요"
    }

    var contentOK: Bool {
        useTemplate ? !(draft.task ?? "").isEmpty : !(draft.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var valid: Bool { invalidReason == nil }

    var invalidReason: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "이름을 적어 주세요" }
        if draft.terminal.handle.isEmpty { return "터미널을 골라 주세요" }
        if !contentOK { return useTemplate ? "템플릿을 골라 주세요" : "보낼 글을 적어 주세요" }
        if parsed == nil { return "시각을 확인해 주세요" }
        return nil
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
                        TemplatePicker(model: model, key: $draft.task) { openTemplate($0, current) }
                    } else {
                        PromptEditor(text: Binding(get: { draft.prompt ?? "" }, set: { draft.prompt = $0 }),
                                     commands: model.commands(forTerminal: draft.terminal.handle))
                        if draft.isCommand { CommandNote() }
                    }
                    if contentOK { MessagePreview { model.messagePreview(current) } }
                }
                FormRow(title: "시각") {
                    timeRow
                    if let p = parsed {
                        let runs = dayChoice != .cron && repeating ? spec(for: dayChoice).map { " · 하루 \($0.runsPerDay)번" } ?? "" : ""
                        if let next = p.next(after: Date()) {
                            Text("\(p.summary)\(runs) · 다음 \(TimeText.short(next))")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("\(p.summary) · 고른 날이 모두 지나 더 돌지 않습니다")
                                .font(.caption).foregroundStyle(Color.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(timeProblem).font(.caption).foregroundStyle(Color.bad)
                    }
                }
                FormRow(title: "늦으면") {
                    Dropdown(selection: Binding(get: { draft.lateLimit ?? 0 }, set: { draft.lateLimit = $0 == 0 ? nil : $0 }),
                             options: [(0, "늦어도 보냄"), (1800, "30분 넘게 늦으면 건너뜀"), (3600, "1시간 넘게 늦으면 건너뜀"),
                                       (10800, "3시간 넘게 늦으면 건너뜀"), (21600, "6시간 넘게 늦으면 건너뜀")])
                    Text("맥이 잠들었거나 앱이 꺼져 있던 동안 지나간 시각을 깨어난 뒤 보낼지 정합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FormRow(title: "새 대화") {
                    Toggle("보내기 전에 대화 비우기(/clear)", isOn: Binding(get: { draft.clearFirst == true },
                                                                       set: { draft.clearFirst = $0 ? true : nil }))
                        .toggleStyle(.checkbox)
                    Text("매번 빈 대화에서 시작해 맥락이 쌓이지 않습니다. 그 터미널의 지금 대화가 지워지니 예약 전용 터미널에만 켜세요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            FormFooter(primary: "저장", enabled: valid, note: invalidReason, dirty: initial.map { $0 != current } ?? false,
                       cancel: back, submit: save)
        }
        .padding(Pad.form)
        .onChange(of: draft.terminal.handle) { _, new in
            if let t = model.terminals.first(where: { $0.handle == new }) { draft.terminal = t.ref }
        }
        .onAppear { if initial == nil { initial = current } }
        .onChange(of: dayChoice) { old, new in
            // 매일·평일·휴일에서 「요일 고르기」로 오면 그 요일을 켜 둔다.
            if new == .pick, let set = [DayChoice.everyDay: Set(0...6), .weekdays: Set(1...5), .weekends: [0, 6]][old] { days = set }
            // 「cron 직접」으로 가면 지금 시각을 식으로 옮기고, 거기서 돌아오면 읽을 수 있는 식을 칸으로 옮긴다.
            if new == .cron, let c = spec(for: old)?.cron { cronText = c }
            if old == .cron, TimeSpec(cron: cronText) != nil {
                let f = EditView.fill(from: cronText)
                if new == .pick, f.dayChoice == .pick { days = f.days }
                if new == .dates, f.dayChoice == .dates { dates = f.dates }
                repeating = f.repeating
                times = f.times.map { TimeSlot(date: EditView.clock($0)) }
                every = f.every
                allDay = f.allDay
                (from, to) = (EditView.clock(f.from), EditView.clock(f.to))
            }
        }
        .onChange(of: draft.task) { _, new in
            // 이름이 비었거나 템플릿 제목을 그대로 쓰던 중이면 새 템플릿 제목으로 바꾼다.
            if draft.name.isEmpty || model.tasks.contains(where: { $0.title == draft.name }), let t = model.taskTitle(new) {
                draft.name = t
            }
        }
    }

    /// 시각 — [요일 ▾] [정한 시각 | 반복], 그 아래 요일 칩 · 시각 칸.
    var timeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Dropdown(selection: $dayChoice, options: DayChoice.allCases.map { (value: $0, label: $0.rawValue) })
                if dayChoice != .cron {
                    Picker("", selection: $repeating) {
                        Text("정한 시각").tag(false)
                        Text("반복").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            if dayChoice == .pick { dayButtons }
            if dayChoice == .dates { DateGrid(selection: $dates) }
            if dayChoice == .cron {
                TextField("분 시 일 월 요일", text: $cronText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            } else if repeating {
                repeatRow
            } else {
                timesRow
            }
        }
    }

    /// 정한 시각 — 칸 여럿 + 추가.
    var timesRow: some View {
        FlowRow(spacing: 10) {
            ForEach($times) { $slot in
                HStack(spacing: 2) {
                    clockField($slot.date)
                    Button {
                        times.removeAll { $0.id == slot.id }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.icon)
                    .disabled(times.count <= 1)
                    .help("이 시각 빼기")
                }
            }
            Button(action: addTime) { Label("추가", systemImage: "plus") }
                .buttonStyle(.icon).font(.caption)
                .help("시각 하나 더하기")
        }
    }

    /// 반복 — [N] 분마다 [종일 | 구간] (구간이면 시작 ~ 끝, 끝 시각 포함).
    var repeatRow: some View {
        let interval = HStack(spacing: 6) {
            TextField("30", value: $every, format: .number).textFieldStyle(.roundedBorder).frame(width: 52)
            Text("분마다").foregroundStyle(.secondary)
            Picker("", selection: $allDay) {
                Text("종일").tag(true)
                Text("구간").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        let window = HStack(spacing: 4) {
            clockField($from)
            Text("~").foregroundStyle(.secondary)
            clockField($to)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                interval
                if !allDay { window }
            }
            VStack(alignment: .leading, spacing: 6) {
                interval
                if !allDay { window }
            }
        }
    }

    func clockField(_ value: Binding<Date>) -> some View { ClockField(date: value) }

    /// 마지막 시각에서 한 시간씩 뒤로 가며 아직 없는 시각을 더한다.
    func addTime() {
        let taken = Set(times.map { EditView.minute($0.date) })
        let last = times.last.map { EditView.minute($0.date) } ?? 540
        for step in 1...24 {
            let t = (last + step * 60) % 1440
            if !taken.contains(t) {
                times.append(TimeSlot(date: EditView.clock(t)))
                return
            }
        }
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

    /// 지금 입력 그대로의 예약(저장 전). 템플릿을 고치고 돌아올 때 이 값으로 다시 연다.
    var current: Schedule {
        var s = draft
        s.cron = parsed?.expression ?? cron
        if useTemplate { s.prompt = nil } else { s.task = nil }
        return s
    }

    func save() {
        guard valid else { return }
        var s = current
        s.name = s.name.trimmingCharacters(in: .whitespaces)
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
    @State private var text: String
    @State private var track: Bool
    let cancel: () -> Void
    let done: () -> Void
    /// 템플릿 편집으로 갈 때 고른 터미널·템플릿을 넘긴다. nil 이면 템플릿 고치기 버튼이 없다.
    var openTemplate: ((String?, String, String?) -> Void)?

    init(model: AppModel, handle: String, task: String?, text: String = "", cancel: @escaping () -> Void,
         done: @escaping () -> Void, openTemplate: ((String?, String, String?) -> Void)? = nil) {
        self.model = model
        self.cancel = cancel
        self.done = done
        self.openTemplate = openTemplate
        _text = State(initialValue: text)
        _handle = State(initialValue: handle)
        _task = State(initialValue: task)
        _useTemplate = State(initialValue: task != nil)
        _track = State(initialValue: task != nil)
    }

    var valid: Bool {
        !handle.isEmpty && (useTemplate ? task != nil : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var isCommand: Bool { !useTemplate && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") }

    var invalidReason: String? {
        if handle.isEmpty { return "터미널을 골라 주세요" }
        if useTemplate ? task == nil : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return useTemplate ? "템플릿을 골라 주세요" : "보낼 글을 적어 주세요"
        }
        return nil
    }

    /// 보낼 때 만들어질 1회 보내기(미리보기용).
    var oneShot: Schedule {
        var s = Schedule(id: "preview", name: useTemplate ? (model.taskTitle(task) ?? "") : "보내기",
                         terminal: TerminalRef(handle: handle, label: ""), cron: "",
                         task: useTemplate ? task : nil, prompt: useTemplate ? nil : text)
        s.oneShot = true
        s.track = track
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("터미널에 보내기").font(.system(size: 14, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                FormRow(title: "터미널") {
                    TerminalPicker(model: model, handle: $handle)
                    Button {
                        model.sendTest(to: handle)
                        done()
                    } label: { Label("연결 시험 보내기", systemImage: "checkmark.seal") }
                    .buttonStyle(.icon).font(.caption)
                    .disabled(handle.isEmpty)
                    .help("받는 Claude 가 글을 받고 결과 명령까지 실행하는지 한 번 확인합니다. 결과는 목록에 「연결 시험」으로 남습니다")
                }
                FormRow(title: "내용") {
                    Picker("", selection: $useTemplate) {
                        Text("직접 입력").tag(false)
                        Text("템플릿").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if useTemplate {
                        TemplatePicker(model: model, key: $task) { openTemplate?($0, handle, task) }
                    } else {
                        PromptEditor(text: $text, height: 110, commands: model.commands(forTerminal: handle))
                        if isCommand { CommandNote() }
                    }
                    if invalidReason == nil { MessagePreview { model.messagePreview(oneShot) } }
                }
                FormRow(title: "결과") {
                    Toggle("끝나면 결과를 메뉴바에 남기게 하기", isOn: $track).toggleStyle(.checkbox)
                        .disabled(isCommand)
                    Text(isCommand ? "명령은 결과를 받을 수 없습니다." : track
                         ? "보내는 글 끝에 결과 명령이 붙고, 그 터미널의 Claude 가 마치면 결과가 목록에 남습니다."
                         : "쓴 글을 그대로 보냅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("터미널이 입력을 기다리고 \(Engine.durationText(AppModel.quietSeconds)) 조용할 때 들어갑니다. 바쁘면 최대 60분 기다립니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FormFooter(primary: "보내기", enabled: valid, note: invalidReason,
                       dirty: !useTemplate && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, cancel: cancel) {
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
    let back: () -> Void
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
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.icon).help("뒤로 (esc)")
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
            UndoBanner(model: model)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    /// 아래 목록을 키보드로 고를 때 ↑↓·return 을 넘겨받는다. 주면 처음 뜰 때 입력 초점도 가져간다.
    var onKey: ((KeyPress) -> KeyPress.Result)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in onKey?(press) ?? .ignored }
                .onAppear { if onKey != nil { focused = true } }
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
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { go(.template(key: template.key)) }
            .help("누르면 편집")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                iconButton("calendar.badge.plus", help: "할당 — 터미널과 시각을 정해 예약 만들기") {
                    go(.edit(model.draft(fromTemplate: template.key), isNew: true))
                }
                iconButton("paperplane", help: "터미널에 지금 한 번 보내기") {
                    go(.send(handle: model.terminals.first?.handle ?? "", task: template.key))
                }
                iconButton("pencil", help: "편집") { go(.template(key: template.key)) }
                Button { model.deleteTemplate(template.key) } label: {
                    Image(systemName: "trash").frame(width: 16, height: 16)
                }
                .disabled(used > 0)
                .help(used > 0 ? "예약 \(used)개가 쓰는 중이라 지울 수 없습니다" : "삭제 — 아래 「되돌리기」로 되살립니다")
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
    /// 저장한 키(취소면 nil)를 넘긴다.
    let done: (String?) -> Void
    @State private var title: String
    @State private var detail: String
    @State private var bodyText: String
    /// 처음 연 때의 제목·설명·내용 — 취소할 때 바뀐 것이 있는지 본다.
    let original: [String]

    init(model: AppModel, key: String?, done: @escaping (String?) -> Void) {
        self.model = model
        self.key = key
        self.done = done
        let t = key.flatMap { model.template($0) }
        _title = State(initialValue: t?.title ?? "")
        _detail = State(initialValue: t?.detail ?? "")
        _bodyText = State(initialValue: t?.body ?? "")
        original = [t?.title ?? "", t?.detail ?? "", t?.body ?? ""]
    }

    var invalidReason: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "제목을 적어 주세요" }
        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "내용을 적어 주세요" }
        return nil
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
                    PromptEditor(text: $bodyText, height: 220, commands: model.commandsForAnyTerminal)
                    let locked = CommandCatalog.locked(in: bodyText, list: model.commandsForAnyTerminal)
                    if !locked.isEmpty {
                        Text("⚠︎ " + locked.map { "/" + $0.name }.joined(separator: " · ")
                             + " 은(는) 받는 Claude 가 스스로 부를 수 없어 템플릿으로는 실행되지 않습니다(내장 명령·잠긴 스킬). 「보내기」나 예약의 직접 입력에 명령만 넣어 주세요.")
                            .font(.caption).foregroundStyle(Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("받는 터미널의 Claude 가 이 내용을 읽고 그대로 실행합니다. 경로·대상을 빠짐없이 적으세요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let key {
                        Text("파일: ~/.orca-cron/tasks/\(key).md").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            FormFooter(primary: "저장", enabled: valid, note: invalidReason, dirty: [title, detail, bodyText] != original,
                       cancel: { done(nil) }) {
                guard valid else { return }
                let saved = model.saveTemplate(key: key, TemplateText(title: title.trimmingCharacters(in: .whitespaces),
                                                                      detail: detail.trimmingCharacters(in: .whitespaces),
                                                                      body: bodyText))
                done(saved)
            }
        }
        .padding(Pad.form)
    }
}
