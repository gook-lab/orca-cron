import AppKit
import SwiftUI
import SchedulerCore

/// `OrcaCron preview <png> [list|collapsed|update|edit|new|multi|send|command|templates|template|history]` — 메뉴 화면을 창에 그려 PNG 로 남긴다. 아무것도 보내지 않는다.
/// `command` 의 입력 글은 ORCA_CRON_PREVIEW_TEXT 로 바꿀 수 있다(기본 `/zm`).
enum Preview {
    static func run(_ args: [String]) -> Never {
        guard let out = args.first else {
            FileHandle.standardError.write(Data("사용법: OrcaCron preview <png 경로> [list|collapsed|update|edit|new|multi|send|command|templates|template|history]\n".utf8))
            exit(2)
        }
        let which = args.dropFirst().first ?? "list"
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel(sending: false)
            let first = model.store.schedules.first
            let screen: Screen
            switch which {
            case "edit": screen = first.map { .edit($0, isNew: false) } ?? .list
            case "new": screen = .edit(model.newDraft(), isNew: true)
            case "undo":
                if let s = model.store.schedules.first(where: { !$0.isOneShot }) { model.delete(s.id) }  // 미리보기는 저장하지 않는다
                screen = .list
            case "multi":
                // ORCA_CRON_PREVIEW_CRON 으로 시각을 바꿔 그린다(예: 구간 반복 `*/5 7 * * 1-5; 0 8 * * 1-5`).
                var d = model.newDraft()
                d.name = "하루 두 번 점검"
                d.cron = ProcessInfo.processInfo.environment["ORCA_CRON_PREVIEW_CRON"] ?? "30 9 * * 1-5; 0 18 * * 1-5"
                screen = .edit(d, isNew: true)
            case "send": screen = .send(handle: first?.terminal.handle ?? "", task: nil)
            case "templates": screen = .templates
            case "template": screen = .template(key: model.tasks.first?.key)
            case "collapsed":
                UserDefaults.standard.set(model.groups.filter { !$0.schedules.isEmpty }.map(\.key).joined(separator: "\n"),
                                          forKey: "collapsedGroups")
                screen = .list
            case "update":
                model.previewUpdate()
                screen = .list
            default: screen = .list
            }
            let historyOf = model.store.schedules.first { !$0.history.isEmpty }
            let root = which == "history" && historyOf != nil
                ? AnyView(HistoryPanel(model: model, schedule: historyOf!).padding(12).frame(width: 380, alignment: .leading))
                : which == "command"
                ? AnyView(SendView(model: model, handle: model.terminals.first?.handle ?? first?.terminal.handle ?? "", task: nil,
                                   text: ProcessInfo.processInfo.environment["ORCA_CRON_PREVIEW_TEXT"] ?? "/zm", cancel: {}, done: {}).completionEscape().frame(width: 400))
                : AnyView(MenuView(model: model, windowed: false, screen: screen))
            let host = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            // ORCA_CRON_APPEARANCE=light|dark 로 테마를 정해 그린다(없으면 시스템 설정).
            switch ProcessInfo.processInfo.environment["ORCA_CRON_APPEARANCE"] {
            case "light": window.appearance = NSAppearance(named: .aqua)
            case "dark": window.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            window.orderFront(nil)
            // 터미널 목록을 읽을 시간을 준 뒤 그린다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let size = host.fittingSize
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])
                do {
                    try png?.write(to: URL(fileURLWithPath: out))
                    print("저장: \(out) (\(Int(size.width))×\(Int(size.height)))")
                    exit(0)
                } catch {
                    exit(1)
                }
            }
        }
        app.run()
        exit(0)
    }
}
