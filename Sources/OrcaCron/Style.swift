import AppKit
import SwiftUI

/// 아이콘·글자 버튼 — 올리면 배경이 깔리고 글자가 진해진다. 눌린 동안은 더 진하게.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 4).padding(.vertical, 3)
                .foregroundStyle(enabled ? (hover ? Color.primary : Color.secondary) : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.16 : hover ? 0.09 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// 버튼 스타일이 안 먹는 곳(Menu)에 같은 호버 배경을 준다.
struct HoverHighlight: ViewModifier {
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.09 : 0)))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// 앱 로고 — 남색에서 하늘색으로 가는 둥근 사각형 위에 흰 시계. 앱 아이콘(scripts/make-icon.swift)과 같은 그림.
struct AppLogo: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [AppLogo.top, AppLogo.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "clock.fill")
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }

    static let top = Color(red: 0.10, green: 0.18, blue: 0.40)
    static let bottom = Color(red: 0.17, green: 0.56, blue: 0.88)
}

/// 표준 「정보」 창 — 아이콘 · 버전 · 커밋 · 저장소.
enum AboutPanel {
    static let homepage = URL(string: "https://github.com/gook-lab/orca-cron")!

    @MainActor
    static func show() {
        let credits = NSMutableAttributedString(string: "Orca 터미널 예약 전송 · 커밋 \(Updater.shortCommit)\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                             .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/gook-lab/orca-cron",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .link: homepage]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OrcaCron",
            .applicationVersion: Updater.version,
            .version: "",
            .credits: credits,
        ])
    }
}

/// 예약 줄 켜기·끄기 — 시스템 스위치(mini)보다 작은 26×15 스위치.
struct SmallSwitch: View {
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(hover ? 0.28 : 0.2))
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            }
            .frame(width: 26, height: 15)
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
