import AppKit
import Foundation

enum NotifyLevel: String, CaseIterable, Identifiable {
    case problems, all, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .problems: return "문제 있을 때만(실패·결과 없음·건너뜀·멈춤)"
        case .all: return "끝날 때마다(성공 포함)"
        case .off: return "끄기"
        }
    }
}

/// macOS 알림. 직접 빌드한 앱(ad-hoc 서명)은 알림 센터 권한을 받지 못해 osascript 로 띄운다 —
/// 알림 이름이 「스크립트 편집기」로 보이고, 누르면 스크립트 편집기가 열린다.
enum Notifier {
    static let levelKey = "notifyLevel"

    static var level: NotifyLevel {
        NotifyLevel(rawValue: UserDefaults.standard.string(forKey: levelKey) ?? "") ?? .problems
    }

    static func post(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \(quote(body)) with title \(quote(title))"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
