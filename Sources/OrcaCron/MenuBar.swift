import AppKit
import SwiftUI

/// 앱을 「열」 때(아이콘·Spotlight·`open` 으로 실행) 무엇을 보일지 정한다.
/// 메뉴 막대 아이콘이 보이면 그 아래에 패널을 붙여 열고, 노치에 가려졌으면 창으로 연다.
/// Finder·`open` 은 reopen 이벤트로, 두 번째 프로세스는 분산 알림으로 들어온다(main.swift).
enum AppOpener {
    static let notification = Notification.Name("lab.gook.orcacron.show")
    /// 창 열기 — `openWindow` 는 뷰 안에서만 얻을 수 있어 메뉴 막대 라벨이 넘겨 둔다.
    @MainActor static var openWindow: (() -> Void)?

    @MainActor static func reveal() {
        if MenuBarPanel.show() { return }
        openWindow?()
    }

    /// launchd(로그인 자동 실행·업데이트 뒤 재실행)가 띄웠으면 조용히 메뉴 막대에만 둔다.
    /// 그 밖의 실행은 사람이 연 것이라 패널을 보인다.
    static var launchedByUser: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != LaunchAgent.label
    }
}

/// build.sh 의 LABEL 과 같아야 한다.
enum LaunchAgent {
    static let label = "lab.gook.orcacron"
}

/// 메뉴 막대 아이콘 아래 패널. SwiftUI MenuBarExtra 는 아이콘 버튼을 감춰 두어,
/// 앱 창 목록에서 상태 막대 창의 버튼을 찾아 누른다.
@MainActor
enum MenuBarPanel {
    /// 열려 있으면 앞으로 가져오고, 닫혀 있으면 아이콘을 눌러 연다. 아이콘이 안 보이면 false.
    static func show() -> Bool {
        guard let button = visibleButton() else { return false }
        if let panel = openPanel() {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            button.performClick(nil)
        }
        return true
    }

    /// 아이콘 버튼. 모니터마다 메뉴 막대가 있어 아이콘도 화면 수만큼 있으므로, 마우스가 있는 화면의 것을 고른다.
    /// 그 아이콘이 노치에 가려졌으면 nil — 사람이 보는 화면에 붙일 수 없으니 창으로 연다.
    static func visibleButton(at point: NSPoint = NSEvent.mouseLocation) -> NSStatusBarButton? {
        let items = NSApp.windows.filter { $0.className.contains("StatusBarWindow") && $0.isVisible }
            .compactMap { window in statusButton(in: window.contentView).map { (window, $0) } }
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        guard let (window, button) = items.first(where: { item in screen.map { $0.frame.intersects(item.0.frame) } ?? false })
                ?? items.first else { return nil }
        return window.occlusionState.contains(.visible) && !behindNotch(window.frame) ? button : nil
    }

    /// 열린 패널(SwiftUI 가 MenuBarExtra 에 쓰는 창).
    static func openPanel() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }
    }

    /// 노치(카메라 자리)와 겹치면 macOS 는 그 아이콘을 그리지 않는다.
    static func behindNotch(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        // 노치 영역은 그 화면 기준 좌표로 온다. 화면이 원점에 있지 않으면(외부 모니터가 주 화면) 옮긴다.
        let dx = screen.frame.contains(NSPoint(x: left.midX, y: left.midY)) ? 0 : screen.frame.minX
        return frame.maxX > left.maxX + dx && frame.minX < right.minX + dx
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = statusButton(in: sub) { return found }
        }
        return nil
    }
}

/// 메뉴 막대 아이콘 자리. macOS 는 새로 켜진 앱의 아이콘을 맨 왼쪽에 놓아, 아이콘이 많은 노치 맥에선
/// 앱을 다시 켤 때마다(업데이트 포함) 노치 뒤로 가려진다. 위치 기억 값이 없을 때만 오른쪽 끝에서 300pt
/// (배터리 292 바로 왼쪽)를 넣는다. ⌘ 를 누른 채 아이콘을 끌어 옮기면 macOS 가 이 값을 바꾸고, 그 뒤로는 건드리지 않는다.
enum MenuBarPlacement {
    static let key = "NSStatusItem Preferred Position Item-0"
    static let rightOffset = 300.0

    static func apply(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: key) == nil { defaults.set(rightOffset, forKey: key) }
    }
}
