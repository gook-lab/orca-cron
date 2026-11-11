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

/// 가로로 늘어놓다가 폭이 차면 다음 줄로 넘긴다(시각 칸 목록).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.items + [i], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// 항상 버튼 아래로 펼쳐지는 선택 칸.
/// macOS 기본 Picker 는 고른 항목을 버튼 자리에 맞춰 목록을 띄우므로, 아래쪽 항목을 고르면 목록이 위로 올라가 윗줄을 가린다.
struct Dropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var placeholder = "고르세요"
    /// true 면 내용 폭까지만 쓰다가 자리가 모자라면 긴 이름의 끝을 줄인다. false 면 내용 폭 그대로.
    var fill = false

    var body: some View {
        let menu = Menu {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Toggle(o.label, isOn: Binding(get: { o.value == selection }, set: { if $0 { selection = o.value } }))
            }
        } label: {
            Text(options.first { $0.value == selection }?.label ?? placeholder)
                .lineLimit(1).truncationMode(.tail)
        }
        if fill {
            menu
        } else {
            menu.fixedSize()
        }
    }
}

// MARK: 상태 색 — 테마별 진하기

extension Color {
    /// 밝은 테마는 시스템 초록·주황·빨강이 흰 바탕에서 2~3.5:1 로 흐려 진하게 바꾸고(4.5:1 이상), 어두운 테마는 시스템 색을 쓴다.
    static let ok = themed(light: NSColor(srgbRed: 20 / 255, green: 116 / 255, blue: 50 / 255, alpha: 1), dark: .systemGreen)
    static let warn = themed(light: NSColor(srgbRed: 160 / 255, green: 78 / 255, blue: 0, alpha: 1), dark: .systemOrange)
    static let info = themed(light: NSColor(srgbRed: 0, green: 88 / 255, blue: 200 / 255, alpha: 1), dark: .systemBlue)
    static let bad = themed(light: NSColor(srgbRed: 196 / 255, green: 30 / 255, blue: 28 / 255, alpha: 1), dark: .systemRed)

    static func themed(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}
